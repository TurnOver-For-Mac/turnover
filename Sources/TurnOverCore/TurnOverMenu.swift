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

    /// NVDA's settings keys (NVDA+Control+V and the rest, Windows style): the menu opened at Settings, or at one of
    /// its sections by title.
    public func openSettings(_ section: String? = nil) {
        let root = rootItems()
        guard let si = root.firstIndex(where: { $0.title == "Settings" }), case .submenu(let make) = root[si].kind else { open(); return }
        let sections = make()
        stack = [("TurnOver menu", root, si), ("Settings", sections, 0)]
        if let section, let i = sections.firstIndex(where: { $0.title == section }), case .submenu(let inner) = sections[i].kind {
            stack[1].index = i
            stack.append((section, inner(), 0))
        }
        isOpen = true
        Speech.cancel()
        Speech.speakMessage("TurnOver menu, \(stack.last?.title ?? "Settings")")
        announce()
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

    /// The menu (docs/MENU-PLAN.md, 12 Oct 2026: "This app" first; hand over and quit in one submenu).
    private func rootItems() -> [MenuItem] {
        var items: [MenuItem] = []
        if let app = thisAppItem() { items.append(app) }
        items.append(MenuItem("Settings", .submenu { self.preferences() }))
        items.append(MenuItem("Apps", .submenu { self.applicationItems() }, hint: "Which apps TurnOver reads, and which VoiceOver reads"))
        items.append(MenuItem("Keys", .submenu { self.keysItems() }, hint: "Every shortcut here, keyboard help, and your own keys"))
        if Trackpad.available {
            items.append(MenuItem("Gesture control", .toggle(get: { Trackpad.controlOn }, set: { Trackpad.set($0) }), hint: "The trackpad's gestures: VoiceOver's, or NVDA's in the Windows style. Also Command Control Comma, G; or hold the TurnOver key and turn two fingers, clockwise for on"))
        }
        if let l = NewToTry.latest { items.append(MenuItem("What to test in build \(l.build)", .submenu { NewToTry.menuItems() })) }
        items.append(MenuItem("Tools", .submenu { self.toolItems() }, hint: "Force quit an app\(Edition.includesPlugins ? ", plugins" : "")"))
        items.append(MenuItem("Send feedback", .submenu { self.feedbackItems() }, hint: "A report on your Desktop, and the problem form on GitHub"))
        items.append(Self.supportItem)
        items.append(contentsOf: extraItems)
        items.append(MenuItem("About and updates", .submenu { [
            MenuItem("About TurnOver", .action {
                Speech.speakMessage("TurnOver \(Edition.version), build \(Edition.build), a screen reader for the Mac. It reads the apps you give it under Apps\(Coexist.on ? "; with CoExist on, VoiceOver reads the rest" : ""). Features still settling are under Settings, Experimental. TurnOver is free and made in spare time: Support TurnOver, in this menu, helps cover its costs.")
            }),
        ] + self.aboutItems }))
        items.append(MenuItem("Hand over or quit", .submenu { (self.handOverItem.map { [$0] } ?? []) + [
            MenuItem("Quit TurnOver", .action { Speech.speakMessage("TurnOver quitting"); DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { (TurnOverMenu.shared.quit ?? { NSApp.terminate(nil) })() } },
                     hint: "VoiceOver takes over everywhere. Command Control Period starts TurnOver again"),
        ] }))
        return items
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
        var items = [MenuItem("Force quit an app", .action { ForceQuit.open() }, hint: "Lists the apps that are running; the Mac's own window is silent while TurnOver reads")]
        if Edition.includesPlugins { items.append(MenuItem("Plugins", .submenu { self.pluginItems() }, hint: "Make, install and reload plugins")) }
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

    /// What you hear as TurnOver takes over and hands back: words, a sound, or nothing.
    static var handOverItem: MenuItem {
        MenuItem("When TurnOver takes over", .cycle(options: ["words", "a sound", "nothing"],
            get: { config.general.handOverNothing ? 2 : config.general.handOverChimes ? 1 : 0 },
            set: { i in config.general.handOverNothing = i == 2; config.general.handOverChimes = i == 1; config.save() }),
            hint: "What you hear as TurnOver takes over from VoiceOver and hands back: \"TurnOver on\", a sound, or nothing")
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

    /// The coexist option restarts TurnOver and changes VoiceOver's settings, so it is not a switch that Right Arrow
    /// flips: a plainly named action that only Return runs. Right on a switch had restarted TurnOver three times in a
    /// minute while someone looked round Settings (17 Oct 2026: "completely lost focus").
    /// CoExist: one line, on or off (17 Oct 2026: "it should either be on or off").
    static var coexistItem: MenuItem {
        let on = Coexist.wouldBeOn
        return MenuItem("CoExist: \(on ? "on" : "off")", .action { Self.setCoexist(!on) },
                        hint: "CoExist keeps VoiceOver running alongside TurnOver: TurnOver reads the apps on your list and VoiceOver, kept quiet there, reads every other app, password fields and macOS's own prompts straight away. Return switches it; TurnOver restarts")
    }
    /// Whose sounds: VoiceOver's files or TurnOver's tones (17 Oct 2026: "people seemed to like those").
    static var soundsItem: MenuItem {
        MenuItem("Sounds", .cycle(options: ["VoiceOver's", "TurnOver's"], get: { config.general.effectiveSounds == "turnover" ? 1 : 0 },
                                  set: { config.general.sounds = $0 == 1 ? "turnover" : "voiceover"; config.save() }),
                 hint: "VoiceOver's sounds for links, misspellings, edges, the rotor and the trackpad, or TurnOver's own tones and bells")
    }

    private func preferences() -> [MenuItem] {
        // The VoiceOver settings copy and its undo first (15 Oct 2026), then the sections.
        var items: [MenuItem] = [MenuItem("Open the Settings window", .action { SettingsBridge.open() }, hint: "Every setting in a window, sections down the side")]
            + [MenuItem("Speech", .submenu { self.speechItems() }), Self.copyVoiceOverItem] + [
            MenuItem("Keyboard", .submenu { self.keyboardItems() }),
            MenuItem("Braille", .submenu { self.brailleItems() }),
            MenuItem("Documents", .submenu { self.formattingItems() }, hint: "Headings, links, lists, tables, graphics and fonts: said, a tone, or nothing"),
            MenuItem("Web pages", .submenu { self.browseModeItems() }),
        ] + [
            MenuItem("Item details", .submenu { self.presentationItems() }, hint: "What is said about each item: its help text, shortcut and position"),
            MenuItem("Sounds and alerts", .submenu { self.generalItems() }),
            MenuItem("Apps that speak through TurnOver", .submenu { SpeechPort.shared.menuItems() },
                     hint: "Apps that asked TurnOver to speak for them (a game, say), and whether you allowed it"),
            MenuItem("Screen recognition", .submenu { [
                MenuItem("Read new text as it appears", .toggle(get: { config.recognition.autoRefresh }, set: { config.recognition.autoRefresh = $0 }), hint: "While a recognition result is open"),
                MenuItem("Read the whole result as it opens", .toggle(get: { config.recognition.autoSayAll }, set: { config.recognition.autoSayAll = $0 })),
            ] }),
            MenuItem("Starting", .submenu { [
                MenuItem("Open TurnOver at login", .toggle(get: { config.general.openAtLogin }, set: { config.general.openAtLogin = $0; config.save(); self.onGeneralChanged?() })),
                MenuItem("Show TurnOver in the menu bar", .toggle(get: { config.general.showInMenuBar }, set: { config.general.showInMenuBar = $0; config.save(); self.onGeneralChanged?() })),
            ] }),
        ]
        items.append(MenuItem("Experimental", .submenu { self.experimentalItems() },
                              hint: "Newer features still settling: CoExist and others. Each says what it does"))
        return items
    }

    /// The newer features, still settling (18 Oct 2026: "all the newer stuff which is a bit shaky we can
    /// label experimental").
    private func experimentalItems() -> [MenuItem] {
        var items: [MenuItem] = [Self.coexistItem]
        // This Mac only (the "games" default): Steam and CrossOver games speaking through TurnOver.
        if Games.available { items.append(MenuItem("Games", .submenu { Games.menuItems() }, hint: "Steam and Windows games speaking through TurnOver")) }
        if Trackpad.available {
            items.append(MenuItem("Gesture haptics", .cycle(options: Trackpad.HapticLevel.allCases.map(\.name), get: { Trackpad.HapticLevel.allCases.firstIndex(of: Trackpad.hapticLevel) ?? 0 },
                                                         set: { Trackpad.hapticLevel = Trackpad.HapticLevel.allCases[$0] }), hint: "What you feel under your finger in gesture control"))
        }
        return items
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
    private func generalItems() -> [MenuItem] {
        [
            Self.soundsItem,
            MenuItem("Sounds as I move and press", .toggle(get: { config.general.navigationSounds }, set: { config.general.navigationSounds = $0; config.save() }),
                     hint: "A tick as the focus moves, a click as an item is pressed"),
            Self.handOverItem,
            MenuItem("Notifications from other apps", .toggle(get: { config.presentation.reportNotifications }, set: { config.presentation.reportNotifications = $0; config.save() }),
                     hint: "Read as they appear"),
            MenuItem("Screen Curtain while TurnOver reads", .cycle(options: ["the same as VoiceOver's", "always on", "off"],
                get: { ["follow", "on", "off"].firstIndex(of: config.general.screenCurtain) ?? 0 },
                set: { config.general.screenCurtain = ["follow", "on", "off"][$0]; TurnOverMenu.shared.onScreenCurtainChanged?() }), hint: "The screen goes black; TurnOver reads as normal"),
        ]
    }

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

    private func speechItems() -> [MenuItem] {
        // Say all's own voice (18 Oct 2026: "Kokoro needs to be under Say All Voice"): the speech voice, or a
        // natural one made on the Mac where it is installed. Moving around always uses the speech voice.
        let kokoro: [MenuItem] = KokoroVoice.available ? [MenuItem("Say all voice: \(KokoroVoice.mode == "reading" ? KokoroVoice.displayName(KokoroVoice.voice) : "same as speech")", .submenu {
            [MenuItem("Same as speech" + (KokoroVoice.mode == "off" ? ", current" : ""), .select { KokoroVoice.mode = "off"; Speech.speakMessage("Say all uses the speech voice") },
                      hint: "Say all reads in the voice you hear everywhere")]
            + KokoroVoice.englishVoices.map { v in
                MenuItem("\(KokoroVoice.displayName(v)), natural" + (KokoroVoice.mode == "reading" && v == KokoroVoice.voice ? ", current" : ""), .select {
                    KokoroVoice.voice = v; KokoroVoice.mode = "reading"
                    KokoroVoice.preview(v)
                }, hint: "A natural voice for say all, made on this Mac; moving around stays in your speech voice")
            }
            + [MenuItem("Natural voice speed", .number(get: { KokoroVoice.speed }, set: { KokoroVoice.speed = $0; KokoroVoice.preview(KokoroVoice.voice, text: String(format: "Speed %.1f.", $0)) },
                                                   step: 0.1, min: 0.6, max: 2.0, format: { String(format: "%.1f", $0) }),
                        hint: "Also on the speech settings keys: VO-Command-Shift with the arrows")]
        }, hint: "The voice say all reads in")] : []
        // Say all voice comes last (18 Oct 2026: "the say all should be further down the list").
        return [
            MenuItem("Voice", .submenu { self.voiceItems() }),
            MenuItem("Voices in the rotor: \(config.speech.rotorVoices.isEmpty ? "all" : "\(config.speech.rotorVoices.count) chosen")", .submenu { self.rotorVoiceItems() },
                     hint: "Which voices VO-Command-Shift steps through: tick the ones you want, Alex and Eddy say, not every voice on the Mac"),
            MenuItem("Language switching", .toggle(get: { config.speech.autoLanguageSwitching }, set: { config.speech.autoLanguageSwitching = $0 }),
                     hint: "Text marked as another language is read in that language's voice"),
            MenuItem("Voices for other languages", .submenu { self.languageItems() }),
            MenuItem("Where speech plays", .submenu { self.outputItems() }, hint: "The Mac's default output, or one device by name"),
            MenuItem("Lower other sounds while TurnOver speaks", .cycle(options: Ducking.modes.map(Ducking.name),
                get: { Ducking.modes.firstIndex(of: config.speech.ducking) ?? 0 },
                set: { i in config.speech.ducking = Ducking.modes[i]; config.save(); Ducking.apply() }),
                     hint: "NVDA's audio ducking: other apps are lowered while TurnOver speaks, with macOS's own ducking. Nothing is recorded"),
            MenuItem("Volume", .number(get: { Double(config.speech.volume) }, set: { config.speech.volume = Int($0); Speech.player.volume = Float($0) / 100 }, step: 10, min: 10, max: 200, format: { "\(Int($0.rounded())) percent" })),
            MenuItem("Pitch", .number(get: { Double(config.speech.pitch) * 100 }, set: { config.speech.pitch = Float($0 / 100); Speech.player.pitch = config.speech.pitchMultiplier }, step: 5, min: 0, max: 100, format: { "\(Int($0.rounded()))" }),
                     hint: "VoiceOver's scale: 50 is the voice's own"),
            MenuItem("Rate", .number(get: { Double(config.speech.rate) * 100 }, set: { config.speech.rate = Float($0 / 100); Speech.player.rate = config.speech.rate }, step: 5, min: 10, max: 100, format: { "\(Int($0.rounded()))" })),
            MenuItem("Punctuation level", .cycle(options: SymbolLevel.allCases.map(\.name), get: { config.speech.symbolLevel.rawValue }, set: { config.speech.symbolLevel = SymbolLevel(rawValue: $0)! })),
            MenuItem("Capitals", .submenu { [
                MenuItem("Say cap before a capital", .toggle(get: { config.speech.sayCapForCapitals }, set: { config.speech.sayCapForCapitals = $0 })),
                MenuItem("Raise the pitch", .number(get: { Double(config.speech.capitalPitch) }, set: { config.speech.capitalPitch = Int($0) }, step: 10, min: 0, max: 100,
                    format: { $0 == 0 ? "off" : "\(Int($0)) percent" }), hint: "For a capital said on its own: spelling, moving by character, typing"),
            ] }),
        ] + kokoro
    }

    private func voiceItems() -> [MenuItem] {
        // English, and every language set on this Mac (System Settings, Language & Region): a Spanish speaker can make
        // a Spanish voice TurnOver's own (a tester, 10 Oct 2026: English voices are harder to follow). The
        // Mac's own languages come first.
        let mine = Locale.preferredLanguages.map { String($0.prefix(2)) }
        let wanted = Set(mine + ["en"])
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { wanted.contains(String($0.language.prefix(2))) }
            .sorted { a, b in
                let la = mine.firstIndex(of: String(a.language.prefix(2))) ?? 99, lb = mine.firstIndex(of: String(b.language.prefix(2))) ?? 99
                if la != lb { return la < lb }
                let ea = a.identifier.contains("eloquence"), eb = b.identifier.contains("eloquence")
                if ea != eb { return ea }
                return a.name < b.name
            }
        return voices.map { v in
            let label = "\(v.name), \(v.language)\(v.identifier == config.speech.voice ? ", current" : "")"
            return MenuItem(label, .select {
                config.speech.voice = v.identifier
                Speech.player.voiceIdentifier = v.identifier
                config.save(); Languages.forget()
                Speech.speakMessage("This is \(v.name).")
            })
        }
    }

    /// The speech rotor's voices: a tick for each, so the rotor steps through your own few (18 Oct 2026). None
    /// ticked: every voice, as before.
    private func rotorVoiceItems() -> [MenuItem] {
        let mine = Locale.preferredLanguages.map { String($0.prefix(2)) }
        let wanted = Set(mine + ["en"])
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { wanted.contains(String($0.language.prefix(2))) }
            .sorted { $0.name == $1.name ? $0.language < $1.language : $0.name < $1.name }
        var items: [MenuItem] = [MenuItem("Every voice" + (config.speech.rotorVoices.isEmpty ? ", current" : ""), .action {
            config.speech.rotorVoices = []; config.save(); Speech.speakMessage("The rotor has every voice")
        }, hint: "Clears your list")]
        items += voices.map { v in
            MenuItem("\(v.name), \(v.language)", .toggle(get: { config.speech.rotorVoices.contains(v.identifier) }, set: { on in
                config.speech.rotorVoices.removeAll { $0 == v.identifier }
                if on { config.speech.rotorVoices.append(v.identifier) }
                config.save()
            }))
        }
        return items
    }

    /// One submenu per language with an installed voice: Automatic (the best installed) or a voice of the user's.
    /// Where speech plays: the Mac's default output, or one device by name (VoiceOver Utility's Sound pane, NVDA's
    /// output device setting; 10 Oct 2026). Chosen while the headphones are off, the choice waits for them.
    private func outputItems() -> [MenuItem] {
        let chosen = config.speech.outputDevice
        func pick(_ uid: String) {
            config.speech.outputDevice = uid; config.save()
            Speech.player.outputDeviceUID = uid.isEmpty ? nil : uid
            Log.io("speech output set to \(uid.isEmpty ? "the default output" : uid)")
            // Said once the player has moved: where speech really is (a device that is absent: the default).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Speech.speakMessage("Speech on \(Speech.player.outputDescription)") }
        }
        var items = [MenuItem("The Mac's default output\(chosen.isEmpty ? ", current" : "")", .select { pick("") })]
        items += SpeechPlayer.outputDevices().map { d in
            MenuItem("\(d.name)\(d.uid == chosen ? ", current" : "")", .select { pick(d.uid) })
        }
        return items
    }

    private func languageItems() -> [MenuItem] {
        let languages = Languages.otherLanguages()
        guard !languages.isEmpty else { return [MenuItem("No voices for other languages are installed", .action {})] }
        return languages.map { lang in
            MenuItem(lang.name, .submenu {
                let picked = config.speech.languageVoices[lang.code]
                let voices = Languages.voices(for: lang.code)
                var items = [MenuItem("Automatic\(voices.first.map { ": \($0.name)" } ?? "")\(picked == nil ? ", current" : "")", .select {
                    config.speech.languageVoices[lang.code] = nil
                    config.save(); Languages.forget()
                    Speech.speakMessage("\(lang.name): automatic")
                })]
                items += voices.map { v in
                    MenuItem("\(v.name), \(v.language)\(v.identifier == picked ? ", current" : "")", .select {
                        config.speech.languageVoices[lang.code] = v.identifier
                        config.save(); Languages.forget()
                        Speech.speakMessage("\(lang.name): \(v.name)")
                    })
                }
                // Its own rate, last (a tester): "same as the main voice" until changed.
                items.append(MenuItem("Rate", .number(get: { Double(config.speech.languageRates[lang.code] ?? config.speech.rate) * 100 },
                    set: { config.speech.languageRates[lang.code] = Float($0 / 100) }, step: 5, min: 10, max: 100,
                    format: { v in config.speech.languageRates[lang.code] == nil ? "\(Int(v.rounded())), same as the main voice" : "\(Int(v.rounded()))" })))
                return items
            })
        }
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

    private func keyboardItems() -> [MenuItem] {
        let echo = TypingEcho.allCases.map(\.name)
        return [
            MenuItem("Keyboard style", .cycle(options: GlobalCommands.offeredStyles.map(\.spokenName),
                get: { GlobalCommands.offeredStyles.firstIndex(of: config.general.style) ?? 0 },
                set: { i in if GlobalCommands.offeredStyles.indices.contains(i), GlobalCommands.offeredStyles[i] != config.general.style { GlobalCommands.setKeyboardStyle(GlobalCommands.offeredStyles[i]) } }), hint: "Command Control Comma, then K, goes round them"),
            MenuItem("Keypad commands, Mac style", .toggle(get: { config.keyboard.numpadCommander }, set: { config.keyboard.numpadCommander = $0; KeySettings.refresh() }),
                     hint: "VoiceOver's NumPad Commander: the keypad runs VoiceOver's commands. VO Clear switches"),
            MenuItem("Keypad commands, Windows style", .toggle(get: { config.keyboard.keypadCommands }, set: { config.keyboard.keypadCommands = $0; KeySettings.refresh() }),
                     hint: "NVDA's keypad commands, as with Num Lock off. Clear switches between commands and numbers"),
            MenuItem("TurnOver key", .cycle(options: ["Caps Lock", "Control Option, VoiceOver's keys", "Caps Lock or Control Option"],
                get: { ["caps", "controlOption", "both"].firstIndex(of: config.general.turnOverKey) ?? 0 },
                set: { config.general.turnOverKey = ["caps", "controlOption", "both"][$0] })),
            MenuItem("Typing echo", .submenu { [
                MenuItem("Characters", .cycle(options: echo, get: { config.keyboard.speakTypedCharacters.rawValue }, set: { config.keyboard.speakTypedCharacters = TypingEcho(rawValue: $0)! })),
                MenuItem("Words", .cycle(options: echo, get: { config.keyboard.speakTypedWords.rawValue }, set: { config.keyboard.speakTypedWords = TypingEcho(rawValue: $0)! })),
                MenuItem("New line on Return", .toggle(get: { config.keyboard.speakNewLine }, set: { config.keyboard.speakNewLine = $0 })),
                MenuItem("Command keys", .toggle(get: { config.keyboard.speakCommandKeys }, set: { config.keyboard.speakCommandKeys = $0 }), hint: "Command C, Command V and the like are said as you press them"),
            ] }),
            MenuItem("Groups, Mac style", .toggle(get: { config.general.navigateByGroups }, set: { config.general.navigateByGroups = $0 }),
                     hint: "VoiceOver's keys move by groups, as VoiceOver does"),
            MenuItem("Groups, Windows style", .toggle(get: { config.general.groupsInWindowsStyle }, set: { config.general.groupsInWindowsStyle = $0; if $0 { config.general.navigateByGroups = true } }),
                     hint: "TurnOver Left and Right move by groups too"),
            MenuItem("Moving the cursor moves the keyboard focus", .cycle(options: ["by style: in the Mac style only", "always", "never"],
                get: { ["auto", "on", "off"].firstIndex(of: config.general.focusFollowsCursor) ?? 0 },
                set: { config.general.focusFollowsCursor = ["auto", "on", "off"][$0] })),
            MenuItem("Keyboard layout", .cycle(options: ["laptop", "desktop"], get: { config.keyboard.layout == "desktop" ? 1 : 0 }, set: { config.keyboard.layout = $0 == 1 ? "desktop" : "laptop" }),
                     hint: "Desktop gives the number pad its NVDA keys"),
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

    private func element(_ title: String, _ get: @escaping () -> ElementReport, _ set: @escaping (ElementReport) -> Void) -> MenuItem {
        MenuItem(title, .cycle(options: ElementReport.allCases.map(\.name), get: { ElementReport.allCases.firstIndex(of: get()) ?? 0 }, set: { set(ElementReport.allCases[$0]) }))
    }

    private func formattingItems() -> [MenuItem] {
        [
            element("Headings", { config.documentFormatting.headings }, { config.documentFormatting.headings = $0 }),
            MenuItem("Heading level", .toggle(get: { config.documentFormatting.reportHeadingLevel }, set: { config.documentFormatting.reportHeadingLevel = $0 })),
            element("Links", { config.documentFormatting.links }, { config.documentFormatting.links = $0 }),
            element("Lists", { config.documentFormatting.lists }, { config.documentFormatting.lists = $0 }),
            element("Landmarks", { config.documentFormatting.landmarks }, { config.documentFormatting.landmarks = $0 }),
            MenuItem("Tables", .submenu { [
                self.element("Tables", { config.documentFormatting.tables }, { config.documentFormatting.tables = $0 }),
                MenuItem("Cell coordinates", .toggle(get: { config.documentFormatting.tableCellCoordinates }, set: { config.documentFormatting.tableCellCoordinates = $0 })),
                MenuItem("Row and column headers", .toggle(get: { config.documentFormatting.tableHeaders }, set: { config.documentFormatting.tableHeaders = $0 })),
            ] }),
            element("Graphics", { config.documentFormatting.graphics }, { config.documentFormatting.graphics = $0 }),
            element("Block quotes", { config.documentFormatting.blockQuotes }, { config.documentFormatting.blockQuotes = $0 }),
            element("Spelling errors", { config.documentFormatting.spellingErrors }, { config.documentFormatting.spellingErrors = $0 }),
            MenuItem("Fonts", .submenu { [
                MenuItem("Font name", .toggle(get: { config.documentFormatting.reportFontName }, set: { config.documentFormatting.reportFontName = $0 })),
                MenuItem("Font size", .toggle(get: { config.documentFormatting.reportFontSize }, set: { config.documentFormatting.reportFontSize = $0 })),
                MenuItem("Bold, italic and the like", .toggle(get: { config.documentFormatting.reportFontAttributes }, set: { config.documentFormatting.reportFontAttributes = $0 })),
            ] }, hint: "Said as the caret moves into new formatting"),
        ]
    }

    private func browseModeItems() -> [MenuItem] {
        [
            MenuItem("Read the page automatically when it loads", .toggle(get: { config.virtualBuffers.autoSayAllOnPageLoad }, set: { config.virtualBuffers.autoSayAllOnPageLoad = $0; config.save() })),
            MenuItem("Quick keys go round the page", .toggle(get: { config.virtualBuffers.wrapQuickNav }, set: { config.virtualBuffers.wrapQuickNav = $0; config.save() }), hint: "H, K and the rest go on from the other end, and say so"),
            MenuItem("Links and buttons in the line, as on screen", .toggle(get: { config.virtualBuffers.screenLayout }, set: { config.virtualBuffers.screenLayout = $0; config.save() }), hint: "Off: each link and control on a line of its own"),
            MenuItem("Name undescribed pictures by their file name", .toggle(get: { config.virtualBuffers.imageFileNames }, set: { config.virtualBuffers.imageFileNames = $0; config.save() })),
            MenuItem("Focus mode when a field takes the focus", .toggle(get: { config.virtualBuffers.autoFocusMode }, set: { config.virtualBuffers.autoFocusMode = $0; config.save() })),
            MenuItem("Maximum line length", .number(get: { Double(config.virtualBuffers.maxLineLength) }, set: { config.virtualBuffers.maxLineLength = Int($0) }, step: 10, min: 40, max: 250, format: { "\(Int($0)) characters" })),
        ]
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
