// SPDX-License-Identifier: GPL-3.0-or-later
// The TurnOver menu (NVDA: the NVDA menu on NVDA+N, and its Preferences dialogs),
// spoken rather than drawn: Up and Down move, Right or Enter opens a submenu or
// changes a value, Left goes back or changes the other way, Escape closes.
// While it is open every key belongs to it. Settings save as they change.
import Foundation
import AVFoundation
import AppKit
import TurnOverSpeech

public struct MenuItem {
    public enum Kind {
        case submenu(() -> [MenuItem])
        case cycle(options: [String], get: () -> Int, set: (Int) -> Void)
        case toggle(get: () -> Bool, set: (Bool) -> Void)
        case number(get: () -> Double, set: (Double) -> Void, step: Double, min: Double, max: Double, format: (Double) -> String)
        case action(() -> Void)
        /// Runs and stays in the menu (choosing a voice, with a preview).
        case select(() -> Void)
    }
    public let title: String
    public let kind: Kind
    /// What it means, said after a pause on the item (docs/MENU-PLAN.md: names in titles, explanations after).
    public var hint: String?
    public init(_ title: String, _ kind: Kind, hint: String? = nil) { self.title = title; self.kind = kind; self.hint = hint }

    var valueText: String? {
        switch kind {
        case .cycle(let options, let get, _): return options[max(0, min(options.count - 1, get()))]
        case .toggle(let get, _): return get() ? "on" : "off"
        case .number(let get, _, _, _, _, let format): return format(get())
        case .submenu: return "submenu"
        case .action, .select: return nil
        }
    }
}

public final class TurnOverMenu {
    public static let shared = TurnOverMenu()
    /// Read on the keyboard thread as well; written here, on the main thread.
    private let _isOpen = Locked(false)
    nonisolated public private(set) var isOpen: Bool { get { _isOpen.value } set { _isOpen.value = newValue; Self.anyOpen.value = newValue } }
    /// The same, without the shared menu itself (main actor): for the key tap's thread.
    nonisolated public static let anyOpen = Locked(false)
    private var stack: [(title: String, items: [MenuItem], index: Int)] = []

    /// Extra top-level items the app or add-ons contribute (kept for add-ons; the app uses the hooks below).
    public var extraItems: [MenuItem] = []
    /// The app's own items: "Hand over to VoiceOver" (in Hand over or quit), and Updates, Uninstall (in
    /// About and updates). Set by the app (TurnOverApp).
    public var handOverItem: MenuItem?
    public var aboutItems: [MenuItem] = []
    /// Whether TurnOver reads an app (the lead watcher's answer), and switching the app in front to the other reader.
    public var readsApp: ((String) -> Bool)?
    public var switchReader: (() -> Void)?
    /// Quitting, the app's way (coexisting: VoiceOver gets its apps back first).
    public var quit: (() -> Void)?
    /// The coexist option: VoiceOver stays on and is silenced in the apps of the list, instead of being turned off
    /// where TurnOver reads. Needs a restart.
    public static func setCoexist(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "coexist")
        Speech.speakMessage(on ? "CoExist on. TurnOver restarts, then VoiceOver Utility opens and closes by itself to set VoiceOver up." : "CoExist off. TurnOver restarts, and VoiceOver's settings are put back.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { TurnOverMenu.shared.relaunch?() }
    }
    /// Starts TurnOver again (set by the app): after a change of CoExist.
    public var relaunch: (() -> Void)?
    /// CoExist: VoiceOver's quiet list made again from the apps on the Mac now (set by the app). Nil without CoExist.
    /// The Screen Curtain setting changed: the app puts it into effect (the curtain lives in the app, not the core).
    public var onScreenCurtainChanged: (() -> Void)?

    public func open() {
        stack = [("TurnOver menu", rootItems(), 0)]
        isOpen = true
        Speech.cancel()
        Speech.speakMessage("TurnOver menu")
        announce()
    }

    /// NVDA's settings keys (NVDA+Control+V and the rest, Windows style), JAWS's Insert+F2, and VO-F8 when VoiceOver
    /// Utility isn't there: the Settings window, at one of its sections by title. The section names are the Settings
    /// window's own (Speech, Keyboard, Item details, Web pages, Documents); any other name opens the window as it was.
    /// Until 23 Oct 2026 this walked a Settings submenu of the TurnOver menu that no longer existed (Settings became
    /// an action opening the window), so every settings key fell through to the plain menu.
    public func openSettings(_ section: String? = nil) {
        SettingsBridge.open(section: section)
    }

    /// For tests: the open list as an outline, submenus expanded.
    public func debugOutline(depth maxDepth: Int = 2, values: Bool = false) -> String {
        func walk(_ items: [MenuItem], _ depth: Int) -> [String] {
            items.flatMap { it -> [String] in
                var out = [String(repeating: "  ", count: depth) + it.title + (values ? it.valueText.map { ": \($0)" } ?? "" : "")]
                if case .submenu(let make) = it.kind, depth < maxDepth { out += walk(make(), depth + 1) }
                return out
            }
        }
        return walk(stack.first?.items ?? [], 0).joined(separator: "\n")
    }

    /// A spoken list of the caller's own items (NVDA's elements list): Enter runs the item and closes.
    /// The reading mode was changed in the menu: the app now gets its reader (set by the app).
    public var leadModeChanged: (() -> Void)?
    public func openList(_ title: String, items: [MenuItem]) {
        guard !items.isEmpty else { Speech.speakMessage("\(title): none"); return }
        stack = [(title, items, 0)]
        isOpen = true
        Speech.cancel()
        Speech.speakMessage("\(title), \(items.count)")
        announce()
    }

    /// Run when the menu or list closes, however it closes (the elements list restores Word's sidebar).
    public var onClose: (() -> Void)?
    private var typeahead = ""
    private var typeaheadAt = Date.distantPast

    public func close() {
        isOpen = false
        stack.removeAll()
        filterSource = nil; filter = ""; rotor = nil
        config.save()
        let hook = onClose; onClose = nil
        Braille.releaseItem()
        hook?()
        Speech.speakMessage("closed")
    }

    private var hintWork: DispatchWorkItem?
    private func announce(valueOnly: Bool = false) {
        guard let top = stack.last, top.items.indices.contains(top.index) else { return }
        let item = top.items[top.index]
        hintWork?.cancel()
        if let hint = item.hint, !valueOnly {
            let depth = stack.count, index = top.index
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isOpen, self.stack.count == depth, self.stack.last?.index == index else { return }
                Speech.speakMessage(hint)
            }
            hintWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
        }
        if valueOnly { Speech.speakItem("\(item.title): \(item.valueText ?? "")"); return }
        var parts = [item.title]
        if let v = item.valueText { parts.append(v) }
        parts.append("\(top.index + 1) of \(top.items.count)")
        Speech.speakItem(Speech.joined(parts))
    }

    /// A list that narrows as you type (VoiceOver's Item Chooser): every item whose title contains the text.
    public func openChooser(_ title: String, items: [MenuItem]) {
        guard !items.isEmpty else { Speech.speakMessage("\(title): none"); return }
        filterSource = items; filter = ""
        stack = [(title, items, 0)]
        isOpen = true
        Speech.cancel()
        Speech.speakMessage("\(title), \(items.count) items, type to filter")
        announce()
    }
    private var filterSource: [MenuItem]?
    private var filter = ""

    /// VoiceOver's Rotor (VO-U), NVDA's Elements List: kinds of item (Headings, Links, Form controls…). Left and
    /// Right change kind, Up and Down move through it, typing narrows it, Enter goes there. It opens on the kind
    /// used last, as VoiceOver's does.
    public func openRotor(_ categories: [(name: String, items: [MenuItem])]) {
        let kinds = categories.filter { !$0.items.isEmpty }
        guard !kinds.isEmpty else { Speech.speakMessage("nothing to list here"); return }
        rotor = kinds
        rotorIndex = kinds.firstIndex { $0.name == lastRotorKind } ?? 0
        isOpen = true
        Speech.cancel()
        showRotorKind(intro: "rotor")
    }
    private var rotor: [(name: String, items: [MenuItem])]?
    private var rotorIndex = 0
    private var lastRotorKind = ""

    private func showRotorKind(intro: String? = nil) {
        guard let rotor else { return }
        let kind = rotor[rotorIndex]
        lastRotorKind = kind.name
        filterSource = kind.items; filter = ""
        stack = [(kind.name, kind.items, 0)]
        Speech.speakMessage(Speech.joined([intro ?? "", kind.name, "\(kind.items.count)"]))
        announce()
    }

    /// Typing in a chooser: the list narrows to the items containing the text; Backspace widens it again.
    private func filterKey(_ g: KeyboardGesture) -> Bool {
        guard let source = filterSource, stack.count == 1, g.modifiers.subtracting(.shift).isEmpty else { return false }
        var text = filter
        if g.keyName == "backspace" {
            guard !text.isEmpty else { Tones.edge(); return true }
            text.removeLast()
        } else {
            var ch = g.characters
            if ch.isEmpty || ch.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { ch = g.keyName == "space" ? " " : g.keyName.count == 1 ? g.keyName : "" }
            guard ch.count == 1, !(ch == " " && text.isEmpty) else { return false }
            text += ch
        }
        let matches = text.isEmpty ? source : source.filter { $0.title.lowercased().contains(text.lowercased()) }
        guard !matches.isEmpty else { Tones.edge(); Speech.speakMessage("no match for \(text)"); return true }
        filter = text
        stack[0] = (stack[0].title, matches, 0)
        Speech.cancel()
        Speech.speakMessage(text.isEmpty ? "all \(matches.count) items" : "\(matches.count) matching")
        announce()
        return true
    }

    /// A key while the menu is open (main thread).
    public func handle(_ g: KeyboardGesture) {
        if let r = rotor, stack.count == 1, g.modifiers.isEmpty, g.keyName == "leftArrow" || g.keyName == "rightArrow" {
            rotorIndex = (rotorIndex + (g.keyName == "rightArrow" ? 1 : r.count - 1)) % r.count
            Speech.cancel()
            showRotorKind()
            return
        }
        if filterKey(g) { return }
        guard var top = stack.last else { return }
        let n = top.items.count
        switch g.keyName {
        case "downArrow" where !g.modifiers.contains(.shift): top.index = (top.index + 1) % n; stack[stack.count - 1] = top; announce()
        case "upArrow" where !g.modifiers.contains(.shift): top.index = (top.index - 1 + n) % n; stack[stack.count - 1] = top; announce()
        case "home": top.index = 0; stack[stack.count - 1] = top; announce()
        case "end": top.index = n - 1; stack[stack.count - 1] = top; announce()
        case "rightArrow":
            // Right opens a submenu or steps a value, as in a menu; it never runs a command (that is Enter's job).
            let item = top.items[top.index]
            if case .action = item.kind { Tones.edge() } else if case .select = item.kind { Tones.edge() } else { activate(item, forward: true) }
        case "enter", "numpadEnter", "space": activate(top.items[top.index], forward: true)
        case "leftArrow":
            // On a value (rate, a choice, a switch) Left steps it back, as Right steps it on: Right could raise the
            // rate but Left left the menu, so it could not come down again (5 Oct 2026). Anywhere else, Left goes up
            // a level; at the top it stays (a bump).
            // Only a number (rate, volume) is turned down by Left: in a submenu made of choices and switches
            // (Preferences, General), Left on any of them left no way back up but Escape, which closes it all
            // (a tester, 6 Oct 2026). A choice steps back with Shift Up or Shift Down.
            switch top.items[top.index].kind {
            case .number: activate(top.items[top.index], forward: false)
            default: if stack.count > 1 { back() } else { Tones.edge() }
            }
        case "escape":
            // Escape closes the whole menu at once (the owner's choice, 5 Oct 2026); Left is for going up a level.
            close()
        case "upArrow" where g.modifiers.contains(.shift), "downArrow" where g.modifiers.contains(.shift):
            // Shift+Up/Down step a value the other way.
            activate(top.items[top.index], forward: false)
        default:
            // Letters typed quickly find the item that starts with them ("ma" for "Main navigation"); one letter
            // alone jumps to the next item starting with it, as in a menu.
            if g.characters.count == 1, let c = g.characters.lowercased().first, !c.isWhitespace || !typeahead.isEmpty {
                let now = Date()
                typeahead = now.timeIntervalSince(typeaheadAt) < 1 ? typeahead + String(c) : String(c)
                typeaheadAt = now
                let prefix = typeahead
                let start = prefix.count > 1 ? 0 : 1   // a longer prefix may still match the item we are on
                for step in start...n {
                    let i = (top.index + step) % n
                    if top.items[i].title.lowercased().hasPrefix(prefix) { top.index = i; stack[stack.count - 1] = top; announce(); return }
                }
                Tones.edge()
            }
        }
    }

    private func back() {
        if stack.count > 1 { stack.removeLast(); Speech.speakMessage(stack.last!.title); announce() } else { close() }
    }

    private func activate(_ item: MenuItem, forward: Bool) {
        switch item.kind {
        case .submenu(let make):
            let items = make()
            guard !items.isEmpty else { Speech.speakMessage("empty"); return }
            stack.append((item.title, items, 0))
            Speech.speakMessage(item.title)
            announce()
        case .cycle(let options, let get, let set):
            let i = (get() + (forward ? 1 : options.count - 1)) % options.count
            set(i); config.save(); announce(valueOnly: true)
        case .toggle(let get, let set):
            set(!get()); config.save(); announce(valueOnly: true)
        case .number(let get, let set, let step, let lo, let hi, _):
            set(Swift.min(hi, Swift.max(lo, get() + (forward ? step : -step)))); config.save(); announce(valueOnly: true)
        case .action(let run):
            close()
            run()
        case .select(let run):
            run()
        }
    }

    // MARK: The tree

    /// The menu (docs/MENU-PLAN.md, 12 Oct 2026: "This app" first), in NVDA's shape since 21 Oct 2026: no settings in
    /// the menu, every setting in the Settings window; the menu is This app, Settings, Keys, Tools, Help, Support and
    /// Quit ("way too busy", Oliver; "should all settings be moved there and the menu cleaned up", a contributor).
    private func rootItems() -> [MenuItem] {
        var items: [MenuItem] = []
        if let app = thisAppItem() { items.append(app) }
        items.append(MenuItem("Settings", .action { SettingsBridge.open() }, hint: "Every setting, in a window with sections down the side"))
        items.append(MenuItem("Keys", .submenu { self.keysItems() }, hint: "Every shortcut here, keyboard help, and your own keys"))
        items.append(MenuItem("Tools", .submenu { self.toolItems() }, hint: "The apps TurnOver reads, the VoiceOver settings copy, feedback, force quit, plugins"))
        items.append(MenuItem("Help", .submenu { self.helpItems() }, hint: "The guide, about TurnOver, updates and previous builds"))
        items.append(Self.supportItem)
        items.append(contentsOf: extraItems)
        items.append(MenuItem("Quit TurnOver", .action { Speech.speakMessage("TurnOver quitting"); DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { (TurnOverMenu.shared.quit ?? { NSApp.terminate(nil) })() } },
                              hint: "VoiceOver takes over everywhere. Command Control Period starts TurnOver again"))
        return items
    }

    /// Help: what is new to try, about, then the guide, updates, previous builds and uninstall (aboutItems, set by the app).
    private func helpItems() -> [MenuItem] {
        var items: [MenuItem] = []
        if let l = NewToTry.latest { items.append(MenuItem("What to test in build \(l.build)", .submenu { NewToTry.menuItems() })) }
        items.append(MenuItem("About TurnOver", .action {
            Speech.speakMessage("TurnOver \(Edition.version), build \(Edition.build), a screen reader for the Mac. It reads the apps you give it under Tools\(Coexist.on ? "; with CoExist on, VoiceOver reads the rest" : ""). Feature requests and bug reports through GitHub.")
        }))
        items.append(contentsOf: aboutItems)
        return items
    }

    /// How items are read in this app (28 Oct 2026; Ash's idea, as Oliver read it: the order the pieces of an
    /// announcement come in, and which are said, app by app). A list of the pieces in their spoken order; each opens
    /// a short submenu: said or not, move up, move down. Saved for this app; the Settings window keeps the default.
    private func readingOrderItem(bundle: String, name: String) -> MenuItem {
        func current() -> Config.Verbosity { config.presentation.verbosityByApp[bundle] ?? config.presentation.verbosity }
        func save(_ v: Config.Verbosity) { var t = v; t.tidy(); config.presentation.verbosityByApp[bundle] = t; config.save() }
        func title(_ piece: String, at i: Int, in v: Config.Verbosity) -> String {
            "\(i + 1). \(Config.Verbosity.titles[piece] ?? piece), \(v.says(piece) ? "said" : "not said")"
        }
        func list() -> [MenuItem] {
            let v = current()
            var out: [MenuItem] = []
            for (i, piece) in v.order.enumerated() {
                out.append(MenuItem(title(piece, at: i, in: v), .submenu {
                    [MenuItem("Said", .toggle(get: { current().says(piece) }, set: { [weak self] on in
                         var v = current(); v.set(piece, said: on); save(v)
                         self?.refreshParent(with: list())   // the list under this submenu says "said" or "not said" (a review, 28 Oct 2026)
                     }), hint: "Return switches whether this piece is spoken in \(name)"),
                     MenuItem("Move up", .select { [weak self] in
                         var v = current(); guard let j = v.order.firstIndex(of: piece), j > 0 else { Speech.speakMessage("already first"); return }
                         v.order.swapAt(j, j - 1); save(v)
                         self?.popAndReplace(with: list(), index: j - 1, say: "\(Config.Verbosity.titles[piece] ?? piece) is now \(j)\(Self.ordinal(j))")
                     }, hint: "Said earlier"),
                     MenuItem("Move down", .select { [weak self] in
                         var v = current(); guard let j = v.order.firstIndex(of: piece), j < v.order.count - 1 else { Speech.speakMessage("already last"); return }
                         v.order.swapAt(j, j + 1); save(v)
                         self?.popAndReplace(with: list(), index: j + 1, say: "\(Config.Verbosity.titles[piece] ?? piece) is now \(j + 2)\(Self.ordinal(j + 2))")
                     }, hint: "Said later")]
                }, hint: "Return: said or not, move up, move down"))
            }
            if config.presentation.verbosityByApp[bundle] != nil {
                out.append(MenuItem("Use the default order in \(name) again", .select { [weak self] in
                    config.presentation.verbosityByApp[bundle] = nil; config.save()
                    self?.replaceTop(with: list(), index: 0, say: "the default order")
                }, hint: "Forgets this app's own order; the Settings window's default applies"))
            }
            return out
        }
        return MenuItem("How items are read in \(name)", .submenu { list() },
                        hint: "The pieces of an announcement in the order they are said; each can be moved or switched off, for this app only")
    }
    private static func ordinal(_ n: Int) -> String {
        switch n % 10 { case 1 where n % 100 != 11: return "st"; case 2 where n % 100 != 12: return "nd"; case 3 where n % 100 != 13: return "rd"; default: return "th" }
    }
    /// The list on top of the menu rebuilt in place (a change made from a submenu of it): back to it, at `index`.
    private func popAndReplace(with items: [MenuItem], index: Int, say: String) {
        if stack.count > 1 { stack.removeLast() }
        replaceTop(with: items, index: index, say: say)
    }
    /// The list under the top one rebuilt, its place kept (a toggle in a submenu changed what the parent shows).
    private func refreshParent(with items: [MenuItem]) {
        guard stack.count > 1 else { return }
        let parent = stack[stack.count - 2]
        stack[stack.count - 2] = (parent.title, items, max(0, min(items.count - 1, parent.index)))
    }
    private func replaceTop(with items: [MenuItem], index: Int, say: String) {
        guard !stack.isEmpty else { return }
        let top = stack.removeLast()
        stack.append((top.title, items, max(0, min(items.count - 1, index))))
        Speech.speakMessage(say)
        announce()
    }

    private func thisAppItem() -> MenuItem? {
        guard let pid = API.focusPid, let app = NSRunningApplication(processIdentifier: pid), let bundle = app.bundleIdentifier,
              bundle != Bundle.main.bundleIdentifier else { return nil }
        let name = app.bundleIdentifier == Games.steamHelperBundle ? "Steam" : (app.localizedName ?? "this app")   // Big Picture's process, to the person: Steam
        let module = AppModuleHandler.shared.appModule(for: pid)
        let settling = Edition.experimentalApps.contains(bundle) ? ", experimental support" : ""
        let own = module.menuItems()
        return MenuItem("This app: \(name)\(settling)", .submenu {
            var items: [MenuItem] = []
            let turnOver = self.readsApp?(bundle) ?? config.applications.listedForTurnOver(bundle)
            items.append(MenuItem("\(name) is read by \(turnOver ? "TurnOver" : "VoiceOver")", .action { self.switchReader?() },
                                  hint: "Return gives it to \(turnOver ? "VoiceOver" : "TurnOver"), and remembers"))
            items += own
            items.append(self.readingOrderItem(bundle: bundle, name: name))
            items.append(MenuItem("Describe the image at the cursor", .action { GlobalCommands.shared.script(named: "describeImage")?.handler(KeyboardGesture(keyCode: 0, modifiers: [], characters: "", timestamp: 0, isRepeat: false, flags: [])) },
                                  hint: "What the picture shows and any text in it"))
            if Edition.includesPlugins {
                items.append(MenuItem("Change the item I'm on", .action { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { PluginMaker.open() } },
                                      hint: "Label it, give it a key, read it when it changes, or keep it quiet. TurnOver Shift Slash does the same"))
            }
            if !Edition.isVerified(bundle) {
                items.append(MenuItem("Ask for \(name) to be tuned", .action { AppRequest.request() }, hint: "Finds what the app is built with and writes the request for you, by email. (Plugins are parked for now.)"))
            }
            return items
        })
    }

    private func keysItems() -> [MenuItem] {
        [
            MenuItem("Every shortcut here", .action { GlobalCommands.openShortcutsList() }, hint: "Return runs one"),
            MenuItem("Keyboard help", .action { InputManager.toggleInputHelp() }, hint: "Each key says what it does, without doing it; VO-K turns it off again"),
            // Back (19 Oct 2026): it went with the small TurnOver of 16 Oct and stayed out when the full one came back,
            // though testers used it (a tester).
            MenuItem("My own keys", .submenu { self.userKeyItems() }, hint: "Give any key to a command or an app, or take a key away from TurnOver"),
        ]
    }

    /// Support TurnOver: opens Ko-fi, which needs no account. (GitHub Sponsors joins it as a second item once
    /// GitHub has approved the project's profile; Edition.sponsorsURL is ready for that.)
    static var supportItem: MenuItem {
        MenuItem("Support TurnOver", .action {
            NSWorkspace.shared.open(URL(string: Edition.kofiURL)!)
            Speech.speakMessage("Ko-fi is open in your browser")
        }, hint: "TurnOver is free, made in spare time; a tip on Ko-fi helps cover its running costs. No account needed")
    }

    private func feedbackItems() -> [MenuItem] {
        var items: [MenuItem] = []
        if !Feedback.marks.isEmpty {
            items.append(MenuItem("Send your \(Feedback.marks.count) marked moment\(Feedback.marks.count == 1 ? "" : "s")", .action { Self.saveFeedback(includeSpeech: true) },
                                  hint: "The moments you marked, with what TurnOver said"))
            // Marks only went with a report, so they mounted up (13 on one Mac, a tester's too, 13 Oct 2026): forget them here.
            items.append(MenuItem("Forget the \(Feedback.marks.count) marked moment\(Feedback.marks.count == 1 ? "" : "s")", .action {
                Feedback.clearMarks(); Speech.speakMessage("marked moments forgotten")
            }, hint: "Starts the count again without sending anything"))
        }
        items.append(MenuItem("Send a report with what TurnOver said", .action { Self.saveFeedback(includeSpeech: true) },
                              hint: "Best for finding a problem. It includes what TurnOver said in the last 15 minutes and around your marked moments, which may be the text of emails and pages you read"))
        items.append(MenuItem("Send a report without what TurnOver said", .action { Self.saveFeedback(includeSpeech: false) },
                              hint: "Keeps what you were reading private"))
        return items
    }

    private func toolItems() -> [MenuItem] {
        var items: [MenuItem] = []
        if config.applications.perAppReaders {
            items.append(MenuItem("Apps TurnOver reads", .submenu { self.applicationItems() }, hint: "Which apps TurnOver reads, and which VoiceOver reads (readers per app, Settings, Experimental)"))
        }
        items += [
            Self.copyVoiceOverItem,
            MenuItem("Send feedback", .submenu { self.feedbackItems() }, hint: "A report in TurnOver's reports folder, and the problem form on GitHub"),
            MenuItem("Force quit an app", .action { ForceQuit.open() }, hint: "Lists the apps that are running; the Mac's own window is silent while TurnOver reads"),
        ]
        if let h = handOverItem { items.append(h) }
        if Edition.includesPlugins { items.append(MenuItem("Plugins", .submenu { self.pluginItems() }, hint: "Make, install and reload plugins")) }
        if Trackpad.available {
            items.append(MenuItem("Gesture control", .toggle(get: { Trackpad.controlOn }, set: { Trackpad.set($0) }), hint: "The trackpad's gestures: VoiceOver's, or NVDA's in the Windows style. Also Command Control Comma, G"))
        }
        if Games.available { items.append(MenuItem("Games", .submenu { Games.menuItems() }, hint: "Steam and Windows games speaking through TurnOver")) }
        // Until the Settings window has a Braille section (a contributor's, 21 Oct 2026), braille stays here.
        items.append(MenuItem("Braille", .submenu { self.brailleItems() }, hint: "Until braille has its section in Settings"))
        return items
    }

    static func saveFeedback(includeSpeech: Bool) {
        Speech.speakMessage("Saving a report")
        DispatchQueue.main.async {
            do {
                let zip = try Feedback.save(includeSpeech: includeSpeech)
                defer { Feedback.clearMarks() }   // in this report now (and in the email's text, written below)
                let name = zip.deletingPathExtension().lastPathComponent
                let where_ = includeSpeech ? "Report saved in TurnOver's reports folder, open in Finder, as \(name). It includes what TurnOver said, which may be the text of emails and pages: issues are public, so attach it only if nothing private was read." : "Report saved on your Desktop, as \(name)."
                if Feedback.compose(with: zip, includesSpeech: includeSpeech) {
                    Speech.speakMessage("\(where_) TurnOver's problem form is open in your browser: say what happened, and drag the report in if you like.")
                } else {
                    Speech.speakMessage("\(where_) Report the problem at github.com/TurnOver-For-Mac/turnover/issues.")
                }
            } catch {
                Speech.speakMessage("Could not save the report: \(error.localizedDescription)")
            }
        }
    }

    /// The VoiceOver settings copy: one item in Settings opening out to the copy and its revert (18 Oct 2026:
    /// "should be in there… it should also open out to copy and then revert").
    static var copyVoiceOverItem: MenuItem {
        MenuItem("Copy VoiceOver settings", .submenu { [
            MenuItem("Copy", .action { VoiceOverSettings.startFlow() },
                     hint: "Your VoiceOver voice, rate, pitch, volume, verbosity and typing echo, into TurnOver. About ten seconds; VoiceOver Utility opens and closes by itself"),
            MenuItem("Revert", .action { Speech.speakMessage(VoiceOverSettings.undo()) },
                     hint: "Puts back TurnOver's settings from before the last copy"),
        ] }, hint: "Copy your VoiceOver settings into TurnOver, or revert the last copy")
    }

    /// Making, reloading and listing plugins (the plugin design notes).
    private func pluginItems() -> [MenuItem] {
        var items: [MenuItem] = []
        if let pid = API.focusPid, let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier != Bundle.main.bundleIdentifier {
            let name = app.bundleIdentifier == Games.steamHelperBundle ? "Steam" : (app.localizedName ?? "this app")   // Big Picture's process, to the person: Steam
            for ai in PluginAI.allCases {
                items.append(MenuItem("Make a plugin for \(name) with \(ai.rawValue)", .action { PluginAI.start(ai, pid: pid) },
                                      hint: "Gives \(ai.rawValue) the window's labels, text and menus, and TurnOver's log with typing and speech left out"))
            }
            items.append(MenuItem("Write a plugin for \(name) yourself", .action { PluginAI.startByHand(pid: pid) }, hint: "A starter folder with the guide, a snapshot of the app and its menus"))
        }
        items.append(MenuItem("Plugin library", .action { DispatchQueue.main.async { PluginLibrary.open() } }, hint: "Plugins others have made, checked and signed; each says what it can do before it installs"))
        items.append(MenuItem("Open the plugin guide", .action { DispatchQueue.main.async { PluginAI.openGuide() } }))
        if Trackpad.available {
            items.append(MenuItem("Gesture control", .toggle(get: { Trackpad.controlOn }, set: { Trackpad.set($0) }), hint: "The trackpad's gestures: VoiceOver's, or NVDA's in the Windows style. Also Command Control Comma, G; or hold the TurnOver key and turn two fingers, clockwise for on"))
        }
        if PluginTry.anyConsent {
            items.append(MenuItem("Stop AIs trying keys", .action { PluginTry.revokeAll() }, hint: "Making a plugin let an AI try keys in that app for three hours; this ends it now"))
        }
        items.append(MenuItem("Install my plugin from its folder", .action { DispatchQueue.main.async { PluginAI.installStarter() } }, hint: "The starter folder you are writing in"))
        items.append(MenuItem("Install a plugin from the clipboard", .action { DispatchQueue.main.async { PluginAI.installFromClipboard() } }))
        items.append(MenuItem("Reload plugins", .action {
            ProfileStore.shared.reload(force: true)
            let all = ProfileStore.shared.plugins
            let bad = all.filter { $0.error != nil }.count
            Speech.speakMessage("\(all.count - bad) plugin\(all.count - bad == 1 ? "" : "s") loaded" + (bad > 0 ? ", \(bad) with problems" : ""))
        }))
        for (file, reason) in Recipes.problems { items.append(MenuItem("Recipe \(file) does not load: \(reason)", .action {})) }
        for p in ProfileStore.shared.plugins {
            if let m = p.manifest {
                // The app's name when it isn't running too (the list said "for com.bambulab.bambu-studio"), and the
                // library's author for a library plugin, as the library itself said (14 Oct 2026).
                let apps = m.apps.map { b in NSRunningApplication.runningApplications(withBundleIdentifier: b).first?.localizedName ?? Self.appName(for: b) }.joined(separator: ", ")
                let folder = p.folder
                let author = PluginLibrary.receipt(folder)?.author ?? m.author
                items.append(MenuItem("\(m.name) \(m.version), for \(apps)\(author.map { ", by \($0)" } ?? "")\(p.profile?.view.map { ", a \($0.kind) view" } ?? "")", .submenu {[
                    MenuItem("About", .action {
                        let p2 = ProfileStore.shared.plugins.first { $0.manifest?.id == m.id }?.profile
                        let n = (p2?.labels?.count ?? 0, p2?.keys?.count ?? 0, p2?.watch?.count ?? 0)
                        Speech.speakMessage("\(m.description ?? m.name). \(n.0) labels, \(n.1) keys, \(n.2) watched.")
                    }),
                    MenuItem("Remove", .action { Self.removePlugin(at: folder, name: m.name) }, hint: "Moves it to the Trash; put it back from there to have it again"),
                ]}))
            } else {
                let folder = p.folder
                items.append(MenuItem("\(p.folder.lastPathComponent): does not load. \(p.error ?? "")", .submenu {[
                    MenuItem("Remove", .action { Self.removePlugin(at: folder, name: folder.lastPathComponent) }, hint: "Moves it to the Trash"),
                ]}))
            }
        }
        return items
    }

    /// Removing a plugin, as NVDA's add-on store does (14 Oct 2026: build 19's library could install but nothing
    /// could take a plugin away). To the Trash, not deleted, so it can be put back; then the plugins are reloaded.
    static func removePlugin(at folder: URL, name: String) {
        guard folder.deletingLastPathComponent().standardizedFileURL == ProfileStore.folder.standardizedFileURL else {
            Log.warning("plugin remove refused: \(folder.lastPathComponent) is not in the plugins folder"); return
        }
        do {
            try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
            Log.io("plugin removed to the Trash: \(folder.lastPathComponent)")
            ProfileStore.shared.reload(force: true, quiet: true)
            shared.close()
            Speech.speakMessage("\(name) removed. It is in the Trash.")
        } catch {
            Log.warning("plugin remove failed: \(folder.lastPathComponent): \(error.localizedDescription)")
            Speech.speakMessage("\(name) could not be removed: \(error.localizedDescription)")
        }
    }

    /// Installed by the app: applying "open at login" and "show in the menu bar" is the Mac layer's job.
    public var onGeneralChanged: (() -> Void)?
    /// Which applications TurnOver leads in: the listed ones and every regular application running now.
    private func applicationItems() -> [MenuItem] {
        // Each app is in one list or another, so where it is says who reads it (docs/MENU-PLAN.md).
        var items: [MenuItem] = []
        if let app = AppRequest.frontApp, let bundle = app.bundleIdentifier {
            let turnOver = readsApp?(bundle) ?? config.applications.listedForTurnOver(bundle)
            items.append(MenuItem("\(app.localizedName ?? "The app in front"), the app in front: read by \(turnOver ? "TurnOver" : "VoiceOver")", .action { self.switchReader?() },
                                  hint: "Return gives it to \(turnOver ? "VoiceOver" : "TurnOver")"))
        }
        items.append(MenuItem("Switch between TurnOver and VoiceOver as I change apps", .toggle(get: { config.applications.automaticHandOver }, set: { config.applications.automaticHandOver = $0 })))
        // Who reads, everywhere at once (wishlist 2): also Command Control Comma, then A.
        items.append(MenuItem("Who reads", .cycle(options: Config.Applications.leadModes.map(Config.Applications.leadModeName),
            get: { Config.Applications.leadModes.firstIndex(of: config.applications.leadMode) ?? 0 },
            set: { i in config.applications.leadMode = Config.Applications.leadModes[i]; config.save(); self.leadModeChanged?() }),
            hint: "TurnOver in its apps, TurnOver everywhere, or VoiceOver everywhere. Command Control Comma, then A, does this anywhere"))
        let installed = Self.installedApps()
        func name(_ b: String) -> String {
            if let n = (Edition.supportedApps + Edition.devApps).first(where: { $0.bundle == b })?.name { return Self.plainName(n) }
            return installed.first { $0.0 == b }?.1 ?? NSRunningApplication.runningApplications(withBundleIdentifier: b).first?.localizedName ?? Self.appName(for: b)
        }
        func move(_ b: String, toTurnOver: Bool) -> MenuItem.Kind {
            .action {
                // The current mode's own list (code review, 13 Oct: these menus only ever changed the apps-mode list).
                guard config.applications.leadMode != "voiceover" else {
                    Speech.speakMessage("VoiceOver reads everywhere. Change Who reads first."); return
                }
                config.applications.give(b, toTurnOver: toTurnOver)
                config.save()
                Speech.speakMessage("\(name(b)): \(toTurnOver ? "TurnOver" : "VoiceOver") reads it now")
            }
        }
        let apps = config.applications
        // Every app the lists know of, and every installed one, shown by who reads it in this mode.
        let known = Set(apps.leadBundles + apps.voiceOverBundles + installed.map(\.0) + (Edition.supportedApps + Edition.devApps).map(\.bundle))
        let byTurnOver = known.filter { b in b != Bundle.main.bundleIdentifier && apps.listedForTurnOver(b)
            && (apps.leadMode == "apps" || NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) != nil) }
            .sorted { name($0).lowercased() < name($1).lowercased() }
        items.append(MenuItem("Read by TurnOver, \(byTurnOver.count) app\(byTurnOver.count == 1 ? "" : "s")", .submenu {
            byTurnOver.isEmpty ? [MenuItem("None yet", .action {})] : byTurnOver.map { b in
                MenuItem(name(b) + (Edition.isVerified(b) ? "" : ", not yet checked"), move(b, toTurnOver: false), hint: "Return gives it to VoiceOver")
            }
        }))
        let supported = (Edition.supportedApps + Edition.devApps).filter { a in
            !apps.listedForTurnOver(a.bundle) && NSWorkspace.shared.urlForApplication(withBundleIdentifier: a.bundle) != nil
        }
        items.append(MenuItem("Read by VoiceOver, supported, \(supported.count) app\(supported.count == 1 ? "" : "s")", .submenu {
            supported.isEmpty ? [MenuItem("None: TurnOver reads them all", .action {})] : supported.map { a in
                MenuItem(Self.plainName(a.name) + (a.name.contains("preview") ? ", preview" : ""), move(a.bundle, toTurnOver: true), hint: "Return gives it to TurnOver")
            }
        }, hint: "Apps TurnOver works with, which VoiceOver reads for now"))
        let others = installed.filter { !Edition.isVerified($0.0) && !apps.listedForTurnOver($0.0) }
        items.append(MenuItem("Other apps on this Mac, \(others.count)", .submenu {
            others.sorted { $0.1.lowercased() < $1.1.lowercased() }.map { a in
                MenuItem(a.1, move(a.0, toTurnOver: true), hint: "Not yet checked with TurnOver; it may read badly. Return gives it to TurnOver")
            }
        }, hint: "Not yet checked with TurnOver. Type the start of a name to move to it"))
        items += requestItem()
        return items
    }

    /// "Finder (preview, off until you turn it on)" as a name: "Finder".
    static func plainName(_ n: String) -> String {
        n.range(of: " (").map { String(n[..<$0.lowerBound]) } ?? n
    }

    /// The beta's unverified apps (6 Oct 2026): any app that is open, and any already given to TurnOver, can be
    /// switched to TurnOver to try. VoiceOver leads in them unless chosen; TurnOver's general reading applies, with no
    /// app-specific work, so some read badly.
    /// Bundle identifier and name of apps in the supplied roots, or the standard Applications folders.
    public static func installedApps(in roots: [URL]? = nil) -> [(String, String)] {
        let fm = FileManager.default
        let roots = roots ?? ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"].map { URL(fileURLWithPath: $0) }
        var out: [(String, String)] = []
        func entries(in directory: URL) -> [URL] {
            let keys: Set<URLResourceKey> = [.isHiddenKey, .isSymbolicLinkKey]
            return ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []).filter { url in
                let values = try? url.resourceValues(forKeys: keys)
                guard values?.isHidden == true else { return true }
                // Safari's Applications entry is a hidden link to a visible app on the system volume.
                guard url.pathExtension == "app", !url.lastPathComponent.hasPrefix("."), values?.isSymbolicLink == true else { return false }
                return (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isHiddenKey]).isHidden) == false
            }
        }
        func add(_ url: URL) {
            guard url.pathExtension == "app", let b = Bundle(url: url)?.bundleIdentifier, b != Bundle.main.bundleIdentifier,
                  !out.contains(where: { $0.0 == b }) else { return }
            out.append((b, fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")))
        }
        for root in roots {
            for u in entries(in: root) {
                if u.pathExtension == "app" { add(u) }
                else if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    for v in entries(in: u) where v.pathExtension == "app" { add(v) }
                }
            }
        }
        return out
    }

    /// Last in the list: ask for the application in front to be supported (AppRequest).
    private func requestItem() -> [MenuItem] {
        guard let app = AppRequest.frontApp, !Edition.isVerified(app.bundleIdentifier ?? "") else { return [] }   // only for an app not yet supported
        return [MenuItem("Ask for \(app.localizedName ?? "this app") to be tuned", .action { AppRequest.request() }, hint: "Finds what the app is built with and writes the request for you, by email.")]
    }

    private static func appName(for bundle: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) { return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "") }
        return bundle
    }

    /// Braille: the table (macOS's own, the ones VoiceOver offers) and the word at the cursor.
    private func brailleItems() -> [MenuItem] {
        let current = BrailleOutput.tableIdentifier
        var tables = TOBrailleTranslatorTables.forUser()
        if tables.isEmpty { tables = [("", "Computer braille")] }
        return [
            MenuItem("Bluetooth displays", .toggle(get: { config.braille.bluetooth }, set: {
                config.braille.bluetooth = $0
                if $0 { Speech.speakMessage("Looking for a paired braille display. macOS may ask whether TurnOver can use Bluetooth."); BrailleDisplays.shared.lookNow() }
            })),
            MenuItem("Braille table", .submenu {
                @MainActor func item(_ t: (id: String, name: String)) -> MenuItem {
                    MenuItem("\(t.name)\(t.id == current ? ", current" : "")", .select {
                        config.braille.table = t.id; config.save(); Braille.refreshSoon()
                        Speech.speakMessage(t.name)
                    })
                }
                return tables.map(item) + [MenuItem("Other languages", .submenu {
                    TOBrailleTranslatorTables.otherLanguages().map { lang in MenuItem(lang.language, .submenu { lang.tables.map(item) }) }
                })]
            }),
            MenuItem("Typing on the braille keyboard", .cycle(options: ["contracted, a word at a time", "uncontracted, letter by letter"],
                get: { config.braille.contractedInput ? 0 : 1 }, set: { config.braille.contractedInput = $0 == 0 })),
            MenuItem("Speak braille typing", .cycle(options: ["words", "characters", "characters and words", "off"],
                get: { ["words", "characters", "both", "off"].firstIndex(of: config.braille.inputEcho) ?? 0 },
                set: { config.braille.inputEcho = ["words", "characters", "both", "off"][$0] })),
            MenuItem("Messages", .submenu { [
                MenuItem("Messages on the display", .cycle(options: ["for a time", "until a key is pressed", "off"],
                    get: { ["timeout", "indefinitely", "off"].firstIndex(of: config.braille.showMessages) ?? 0 },
                    set: { config.braille.showMessages = ["timeout", "indefinitely", "off"][$0] })),
                MenuItem("How long", .number(get: { Double(config.braille.messageSeconds) }, set: { config.braille.messageSeconds = Int($0) },
                    step: 1, min: 1, max: 30, format: { "\(Int($0.rounded())) second\(Int($0.rounded()) == 1 ? "" : "s")" }), hint: "For each display's width of message"),
            ] }),
            MenuItem("Keep words whole", .toggle(get: { config.braille.wordWrap }, set: { config.braille.wordWrap = $0; Braille.refreshSoon() }), hint: "A word is not split across the end of the display"),
            MenuItem("Cursor", .submenu { [
                MenuItem("Show the cursor", .toggle(get: { config.braille.showCursor }, set: { config.braille.showCursor = $0; Braille.refreshSoon() })),
                MenuItem("Blink", .toggle(get: { config.braille.blinkCursor }, set: { config.braille.blinkCursor = $0; Braille.refreshSoon() })),
                MenuItem("Blink rate", .number(get: { Double(config.braille.blinkRateMs) }, set: { config.braille.blinkRateMs = Int($0) },
                    step: 100, min: 200, max: 2000, format: { "\(Int($0.rounded())) milliseconds" })),
                MenuItem("Shape", .cycle(options: ["dots 7 and 8", "dot 8", "all dots"],
                    get: { ["78", "8", "all"].firstIndex(of: config.braille.cursorShape) ?? 0 },
                    set: { config.braille.cursorShape = ["78", "8", "all"][$0]; Braille.refreshSoon() })),
                MenuItem("Selection with dots 7 and 8", .toggle(get: { config.braille.showSelection }, set: { config.braille.showSelection = $0; Braille.refreshSoon() })),
            ] }),
            MenuItem("Stop speech while panning", .toggle(get: { config.braille.interruptSpeechWhileScrolling }, set: { config.braille.interruptSpeechWhileScrolling = $0 })),
            MenuItem("Show the word at the cursor uncontracted", .toggle(get: { config.braille.expandAtCursor }, set: { config.braille.expandAtCursor = $0; Braille.refreshSoon() })),
        ]
    }

    /// The keyboard commands editor (NVDA's Input Gestures; VoiceOver's Keyboard and NumPad Commanders).
    private func userKeyItems() -> [MenuItem] {
        var items = [
            MenuItem("Give a key to a command", .action { [weak self] in self?.chooseCommandForKey() }),
            MenuItem("Give a key to open an app", .action { [weak self] in self?.chooseAppForKey() }, hint: "Right Option keys work, as in VoiceOver's Keyboard Commander"),
            MenuItem("Take a key away from TurnOver, so it goes to the app", .action { Self.captureKey(prompt: "Press the key to take away") { g in
                let had = ScriptHandler.findScript(for: g)?.description
                UserGestures.set(g, to: .removed)
                Speech.speakMessage("\(UserGestures.spoken(UserGestures.storedIdentifier(of: g))) now goes to the application\(had.map { "; it was: \($0)" } ?? "")")
            } }),
        ]
        let mine = config.keyboard.userGestures.sorted { $0.key < $1.key }
        if mine.isEmpty { items.append(MenuItem("No keys of your own yet", .action {})) }
        for (id, stored) in mine {
            guard let t = UserGestures.Target(stored) else { continue }
            items.append(MenuItem("\(UserGestures.spoken(id)): \(UserGestures.describe(t)). Return to remove", .select {
                UserGestures.clear(id); Speech.speakMessage("\(UserGestures.spoken(id)) is back to TurnOver's own")
            }))
        }
        return items
    }

    private func chooseCommandForKey() {
        let commands = UserGestures.availableCommands()
        let items = commands.map { s in MenuItem("\(s.description) (\(s.category))", .action { [weak self] in
            Self.captureKey(prompt: "Press the key for: \(s.description)") { [weak self] g in
                UserGestures.set(g, to: .script(s.name))
                Speech.speakMessage("\(UserGestures.spoken(UserGestures.storedIdentifier(of: g))) now: \(s.description)")
                // The list again, for the next key; Escape leaves it (a tester, 20 Oct 2026: it closed after each one).
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.chooseCommandForKey() }
            }
        }) }
        openChooser("Commands here", items: items)
    }

    private func chooseAppForKey() {
        let apps = Self.installedApps().sorted { $0.1.lowercased() < $1.1.lowercased() }
        let items = apps.map { a in MenuItem(a.1, .action { [weak self] in
            Self.captureKey(prompt: "Press the key to open \(a.1). Right Option and a letter, as VoiceOver's Keyboard Commander, is a good choice") { [weak self] g in
                UserGestures.set(g, to: .app(a.0))
                Speech.speakMessage("\(UserGestures.spoken(UserGestures.storedIdentifier(of: g))) now opens \(a.1)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.chooseAppForKey() }
            }
        }) }
        openChooser("Applications", items: items)
    }

    /// Wait for the next key, after the prompt; Escape cancels.
    static func captureKey(prompt: String, _ done: @escaping (KeyboardGesture) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            Speech.speakMessage(prompt + ". Escape to cancel")
            InputManager.captureNext = { g in
                guard let g else { Speech.speakMessage("cancelled"); return }
                done(g)
            }
        }
    }

    /// VO-V, VoiceOver's Verbosity rotor: punctuation, item details and hints, in one short list.
    public func openVerbosity() {
        openList("Verbosity", items: [
            MenuItem("Punctuation level", .cycle(options: SymbolLevel.allCases.map(\.name), get: { config.speech.symbolLevel.rawValue }, set: { config.speech.symbolLevel = SymbolLevel(rawValue: $0)! })),
        ] + presentationItems())
    }

    private func presentationItems() -> [MenuItem] {
        [
            MenuItem("Help text of items", .toggle(get: { config.presentation.reportObjectDescriptions }, set: { config.presentation.reportObjectDescriptions = $0 })),
            MenuItem("Say which plugin an app has as it comes to the front", .toggle(get: { config.presentation.announcePlugins }, set: { config.presentation.announcePlugins = $0 })),
            MenuItem("Each item's keyboard shortcut", .toggle(get: { config.presentation.reportKeyboardShortcuts }, set: { config.presentation.reportKeyboardShortcuts = $0 })),
            MenuItem("Position, such as 3 of 10", .toggle(get: { config.presentation.reportObjectPositionInformation }, set: { config.presentation.reportObjectPositionInformation = $0 })),
            MenuItem("Hints after a pause", .toggle(get: { config.presentation.speakHints }, set: { config.presentation.speakHints = $0 }), hint: "What you can do with an item"),
            // A tester T, 7 Oct 2026: "AppleVis, heading level 1", as VoiceOver, rather than NVDA's "heading level 1, AppleVis".
            MenuItem("Heading, link and button: when to say them", .cycle(options: ["by keyboard style", "before the words, as NVDA", "after the words, as VoiceOver"],
                get: { ["auto", "before", "after"].firstIndex(of: config.documentFormatting.roleOrder) ?? 0 },
                set: { config.documentFormatting.roleOrder = ["auto", "before", "after"][$0] }), hint: "By keyboard style: after the words in the Mac style, before them in the Windows style"),
        ]
    }
}
