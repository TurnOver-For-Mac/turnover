// SPDX-License-Identifier: GPL-3.0-or-later
// VoiceOver's keys that TurnOver had given to its own commands, now VoiceOver's again (the decisions, 12 Oct
// 2026, docs/VOICEOVER-PARITY.md items 1 to 15). TurnOver's own commands moved to Command Control keys, which work in
// both styles (MenuAnywhere, in the app). Declared after the rest of VoiceOverKeysPlugin, so these answer first.
import Foundation
import AppKit
import ApplicationServices

/// Notifications heard lately, newest last (VO-N lists them, as VoiceOver's Notifications menu).
public enum NotificationHistory {
    nonisolated(unsafe) public private(set) static var items: [(text: String, at: Date)] = []
    public static func add(_ text: String) {
        items.append((text, Date()))
        if items.count > 50 { items.removeFirst(items.count - 50) }
    }
}

/// VoiceOver's hot spots: ten places to come back to (VO-Shift-digit sets or removes, VO-digit goes there,
/// VO-Command-digit describes, VO-Command-Shift-digit watches for changes). Kept while TurnOver runs.
enum HotSpots {
    struct Spot { let element: AXUIElement; let app: String; let name: String }
    nonisolated(unsafe) static var spots: [Int: Spot] = [:]
    nonisolated(unsafe) static var watches: [Int: Timer] = [:]
    nonisolated(unsafe) static var last: Int?

    static func alive(_ e: AXUIElement) -> Bool { let r = e.role; return !r.isEmpty && r != "?" }
    static func name(_ e: AXUIElement) -> String {
        let n = VoiceOverKeysPlugin.text(e)
        return n.isEmpty ? ObjectFactory.make(e).role.displayString : n
    }

    static func set(_ n: Int) {
        if spots[n] != nil { spots[n] = nil; watches[n]?.invalidate(); watches[n] = nil; Speech.speakMessage(String(localized: "hot spot \(String(n)) removed", comment: "A hot spot: its number")); return }
        guard let e = VoiceOverKeysPlugin.cursorElement() else { Speech.speakMessage(String(localized: "nothing here", comment: "Spoken message")); return }
        let app = NSRunningApplication(processIdentifier: e.pid)?.localizedName ?? ""
        spots[n] = Spot(element: e, app: app, name: name(e))
        Speech.speakMessage(String(localized: "hot spot \(String(n)) set, \(spots[n]!.name)", comment: "A hot spot set: its number, then the item"))
    }

    static func go(_ n: Int) {
        guard let s = spots[n] else { Speech.speakMessage(String(localized: "no hot spot \(String(n))", comment: "A hot spot: its number")); return }
        guard alive(s.element) else { Speech.speakMessage(String(localized: "hot spot \(String(n)), \(s.name), is no longer there", comment: "A hot spot gone: its number, then the item")); return }
        last = n
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != s.element.pid {
            NSRunningApplication(processIdentifier: s.element.pid)?.activate()
            if let w = s.element.element(kAXWindowAttribute) { _ = AXUIElementPerformAction(w, kAXRaiseAction as CFString) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { ObjectNavigator.shared.moveTo(s.element) }
        } else {
            ObjectNavigator.shared.moveTo(s.element)
        }
    }

    static func describe(_ n: Int) {
        guard let s = spots[n] else { Speech.speakMessage(String(localized: "no hot spot \(String(n))", comment: "A hot spot: its number")); return }
        guard alive(s.element) else { Speech.speakMessage(String(localized: "hot spot \(String(n)), \(s.name), is no longer there", comment: "A hot spot gone: its number, then the item")); return }
        Speech.speakObject(ObjectFactory.make(s.element), reason: .focus)
    }

    static func snapshot(_ e: AXUIElement) -> String {
        let o = ObjectFactory.make(e)
        return [o.name, o.value ?? "", "\(e.elements(kAXChildrenAttribute).count)"].joined(separator: "|")
    }

    static func watch(_ n: Int) {
        if let t = watches[n] { t.invalidate(); watches[n] = nil; Speech.speakMessage(String(localized: "stopped watching hot spot \(String(n))", comment: "A hot spot: its number")); return }
        guard let s = spots[n], alive(s.element) else { Speech.speakMessage(String(localized: "no hot spot \(String(n))", comment: "A hot spot: its number")); return }
        seen[n] = snapshot(s.element)
        watches[n] = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { check(n) } }
        Speech.speakMessage(String(localized: "watching hot spot \(String(n)), \(s.name)", comment: "A hot spot watched: its number, then the item"))
    }

    nonisolated(unsafe) static var seen: [Int: String] = [:]
    static func check(_ n: Int) {
        guard let s = spots[n], alive(s.element) else { watches[n]?.invalidate(); watches[n] = nil; Speech.speakNews(String(localized: "hot spot \(String(n)) is gone", comment: "A hot spot: its number")); return }
        let now = snapshot(s.element)
        guard now != seen[n] else { return }
        seen[n] = now
        let o = ObjectFactory.make(s.element)
        Speech.speakNews(String(localized: "hot spot \(String(n))", comment: "A hot spot: its number") + ", " + [o.name, o.value ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    static func step(_ by: Int) {
        let keys = spots.keys.sorted()
        guard !keys.isEmpty else { Speech.speakMessage(String(localized: "no hot spots", comment: "Spoken message")); return }
        let i = last.flatMap { keys.firstIndex(of: $0) }.map { ($0 + by + keys.count) % keys.count } ?? (by > 0 ? 0 : keys.count - 1)
        go(keys[i])
    }

    static func chooser() {
        let items = spots.keys.sorted().map { n -> MenuItem in
            let s = spots[n]!
            var title = "\(n), \(s.name)\(s.app.isEmpty ? "" : ", \(s.app)")"
            if watches[n] != nil { title = String(localized: "\(title), watched", comment: "A hot spot being watched for changes") }
            return MenuItem(verbatim: title, .action { go(n) })
        }
        TurnOverMenu.shared.openList("Hot spots", items: items)
    }
}

public enum TurnOverGuide {
    /// The TurnOver guide (VO-Shift-Slash, VO-Command-F8, Command Control H).
    public static func open() {
        guard let g = Bundle.main.url(forResource: Edition.guideName, withExtension: "txt") else { Speech.speakMessage(String(localized: "The guide is not in this copy of TurnOver", comment: "Spoken message")); return }
        NSWorkspace.shared.open(g)
        Speech.speakMessage(String(localized: "TurnOver guide", comment: "Spoken message"))
    }
}

extension VoiceOverKeysPlugin {

    func addVoiceOverDecisions(_ add: (String, String, [String], @escaping (KeyboardGesture) -> Void) -> Void) {
        func count() -> Int { ScriptHandler.lastScriptRepeatCount }

        // 1. VO-N: the notifications heard lately. (The TurnOver menu: Command Control N.)
        add("notifications", String(localized: "The notifications heard lately (VO-N)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+n"]) { _ in
            let items = NotificationHistory.items.reversed().map { n -> MenuItem in
                let mins = Int(Date().timeIntervalSince(n.at) / 60)
                let when = mins < 1 ? String(localized: "just now", comment: "When a notification came") : mins == 1 ? String(localized: "1 minute ago", comment: "When a notification came")
                    : mins < 60 ? String(localized: "\(String(mins)) minutes ago", comment: "When a notification came") : String(localized: "\(String(mins / 60)) hours ago", comment: "When a notification came")
                return MenuItem(verbatim: "\(n.text), \(when)", .action { Speech.speakPrivate(n.text) })
            }
            guard !items.isEmpty else { Speech.speakMessage(String(localized: "no notifications", comment: "Spoken message")); return }
            TurnOverMenu.shared.openList("Notifications", items: items)
        }
        // 2. VO-V: verbosity. (Handing over: Command Control Shift T.)
        add("verbosity", String(localized: "Verbosity: punctuation, item details and hints (VO-V)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+v"]) { _ in TurnOverMenu.shared.openVerbosity() }
        // 3. VO-Shift-K: the Option key Commander. (The keyboard style: Command Control K.)
        add("optionCommander", String(localized: "Option key Commander on or off: right Option with a letter runs a command (VO-Shift-K)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+shift+k"]) { _ in
            config.keyboard.optionCommander.toggle(); config.save(); KeySettings.refresh()
            Speech.speakMessage(config.keyboard.optionCommander ? String(localized: "Option key commander on", comment: "Spoken message") : String(localized: "Option key commander off", comment: "Spoken message"))
        }
        // 4. VO-Shift-J: the input method or autocorrect panel. (The "that was wrong" mark: Command Control J.)
        add("inputPanel", String(localized: "Jumps to the input method or autocorrect panel (VO-Shift-J)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+shift+j"]) { _ in
            guard let panel = Self.inputPanel() else { Speech.speakMessage(String(localized: "no input method or autocorrect panel", comment: "Spoken message")); return }
            ObjectNavigator.shared.moveTo(panel)
        }
        // 5. VO-Slash: the plugin maker (its first job, a label: VoiceOver's custom label). VO-Shift-Slash: the guide.
        add("customLabel", String(localized: "Labels the item, and more: the plugin maker (VO-Slash)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+/"]) { g in
            (ScriptHandler.findScript(named: "makePlugin") ?? GlobalCommands.shared.script(named: "makePlugin"))?.handler(g)
        }
        add("guide", String(localized: "Opens the TurnOver guide (VO-Shift-Slash)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+shift+/", "kb:turnover+?"]) { _ in TurnOverGuide.open() }
        // 6. VO-Command-C: the next style change. (Copying the last thing spoken: VO-Shift-C, Command Control C.)
        add("nextStyleChange", String(localized: "Next style change (VO-Command-C)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+command+c"]) { _ in Self.styleChange(forward: true) }
        add("previousStyleChange", String(localized: "Previous style change (VO-Command-Shift-C)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+command+shift+c"]) { _ in Self.styleChange(forward: false) }
        // 7. VO-Command-M: the next heading of the same level.
        add("nextSameHeading", String(localized: "Next heading of the same level (VO-Command-M)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+command+m"]) { g in Self.sameLevelHeading(forward: true, g) }
        add("previousSameHeading", String(localized: "Previous heading of the same level (VO-Command-Shift-M)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+command+shift+m"]) { g in Self.sameLevelHeading(forward: false, g) }
        // 9. VO-Backspace: a tab stop on a ruler. (Back to the focus: VO-Shift-F4.)
        add("deleteTabStop", String(localized: "Deletes the tab stop on a ruler (VO-Backspace)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+backspace"]) { _ in
            guard let e = Self.cursorElement(), e.role == "AXRulerMarker" else { Speech.speakMessage(String(localized: "not on a tab stop", comment: "Spoken message")); return }
            let r = AXUIElementPerformAction(e, "AXDelete" as CFString)
            Speech.speakMessage(r == .success ? String(localized: "tab stop deleted", comment: "Spoken message") : String(localized: "this tab stop can't be deleted", comment: "Spoken message"))
        }
        // 8. Hot spots.
        for n in 0...9 {
            let k = String(n)
            add("hotSpotSet\(n)", String(localized: "Sets or removes hot spot \(k) (VO-Shift-\(k))", comment: "A command: %@ is the hot spot's number"), ["kb:turnover+shift+\(n)"]) { _ in HotSpots.set(n) }
            add("hotSpotGo\(n)", String(localized: "Goes to hot spot \(k) (VO-\(k))", comment: "A command: %@ is the hot spot's number"), ["kb:turnover+\(n)"]) { _ in HotSpots.go(n) }
            add("hotSpotDescribe\(n)", String(localized: "Describes hot spot \(k) (VO-Command-\(k))", comment: "A command: %@ is the hot spot's number"), ["kb:turnover+command+\(n)"]) { _ in HotSpots.describe(n) }
            add("hotSpotWatch\(n)", String(localized: "Watches hot spot \(k) for changes, or stops (VO-Command-Shift-\(k))", comment: "A command: %@ is the hot spot's number"), ["kb:turnover+command+shift+\(n)"]) { _ in HotSpots.watch(n) }
        }
        add("hotSpotChooser", String(localized: "The hot spot chooser (VO-Shift-X)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+shift+x"]) { _ in HotSpots.chooser() }
        add("nextHotSpot", String(localized: "Next hot spot (VO-Shift-Right Bracket)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+shift+]"]) { _ in HotSpots.step(1) }
        add("previousHotSpot", String(localized: "Previous hot spot (VO-Shift-Left Bracket)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+shift+["]) { _ in HotSpots.step(-1) }
        // 13. VO-Clear: the NumPad Commander (Keypad.swift).
        add("numpadCommander", String(localized: "NumPad Commander on or off: the keypad runs VoiceOver's commands (VO-Clear)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+numpadClear"]) { _ in Keypad.toggleCommander() }
        // VoiceOver's speech settings (12 Oct 2026; on an Apple page the first audit missed): VO-Command-Left
        // and Right choose a setting, VO-Command-Up and Down change it (older VoiceOver); Apple's guide now says
        // VO-Command-Shift with the arrows (unac009): both. The same ring as NVDA's (SynthRing).
        // VO-Command-Shift with the arrows (Apple's guide, unac009); VO-Command with the arrows is the rotor (17 Oct 2026).
        add("speechSettingNext", String(localized: "Next speech setting: voice, rate, pitch, volume, punctuation (VO-Command-Shift-Right)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+command+shift+rightArrow"]) { _ in SynthRing.step(1) }
        add("speechSettingPrevious", String(localized: "Previous speech setting (VO-Command-Shift-Left)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+command+shift+leftArrow"]) { _ in SynthRing.step(-1) }
        add("speechSettingUp", String(localized: "Raises the speech setting (VO-Command-Shift-Up)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+command+shift+upArrow"]) { _ in SynthRing.change(1, large: false) }
        add("speechSettingDown", String(localized: "Lowers the speech setting (VO-Command-Shift-Down)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+command+shift+downArrow"]) { _ in SynthRing.change(-1, large: false) }
        // The rotor without opening it: the kind with Left and Right, the items with Up and Down (QuickRotor.swift).
        add("rotorNextKind", String(localized: "The rotor's next kind: headings, links, form controls, tables… (VO-Command-Right)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+command+rightArrow"]) { _ in QuickRotor.step(1) }
        add("rotorPreviousKind", String(localized: "The rotor's previous kind (VO-Command-Left)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+command+leftArrow"]) { _ in QuickRotor.step(-1) }
        add("rotorNextItem", String(localized: "The next item of the rotor's kind (VO-Command-Down)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+command+downArrow"]) { g in QuickRotor.move(forward: true, gesture: g) }
        add("rotorPreviousItem", String(localized: "The previous item of the rotor's kind (VO-Command-Up)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+command+upArrow"]) { g in QuickRotor.move(forward: false, gesture: g) }
        // 10, 11. VoiceOver Utility and the Tutorial.
        // VoiceOver Utility itself (18 Oct 2026: "vo f8 needs to be returned to opening voiceover utility");
        // TurnOver's settings are Command Control Comma, S.
        add("utility", String(localized: "VoiceOver Utility (VO-F8); TurnOver's own settings are Command Control Comma, S", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+f8"]) { _ in
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.VoiceOverUtility") { NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) }
            else { TurnOverMenu.shared.openSettings() }
        }
        add("tutorial", String(localized: "The TurnOver guide, until there is a tutorial (VO-Command-F8)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+command+f8"]) { _ in TurnOverGuide.open() }
        // 14. Activities: TurnOver's settings profiles (SettingsProfiles.swift). In VoiceOver's apps VO-X is VoiceOver's
        // own (TurnOver isn't taking the keys there). Passing it to VoiceOver from TurnOver's apps (18 Oct 2026, for
        // the Activity way of CoExist) opened VoiceOver's chooser where the tap keeps VoiceOver silent: unheard.
        add("activities", String(localized: "Activities: sets of speech, verbosity, web and braille settings, by hand or for an app (VO-X)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+x"]) { _ in
            SettingsProfiles.openChooser()
        }
        // 12, 14, 15. Not in TurnOver yet: said, so the key is known to have been heard.
        for (name, what, keys) in [("captionPanel", String(localized: "The caption panel (VO-Command-F10)", comment: "A VoiceOver feature"), ["kb:turnover+command+f10"]),
                                   ("captionPanelMove", String(localized: "Moving the caption panel (VO-Shift-F10)", comment: "A VoiceOver feature"), ["kb:turnover+shift+f10"]),
                                   ("braillePanel", String(localized: "The braille panel (VO-Command-F9)", comment: "A VoiceOver feature"), ["kb:turnover+command+f9"]),
                                   ("braillePanelMove", String(localized: "Moving the braille panel (VO-Shift-F9)", comment: "A VoiceOver feature"), ["kb:turnover+shift+f9"]),
                                   ("tileVisuals", String(localized: "Tile visuals (VO-F10)", comment: "A VoiceOver feature"), ["kb:turnover+f10"]),
                                   ("visuals", String(localized: "The cursor and panels on screen (VO-Command-F11)", comment: "A VoiceOver feature"), ["kb:turnover+command+f11"])] {
            add(name, String(localized: "\(what): not in TurnOver yet", comment: "A VoiceOver feature TurnOver lacks: %@ is the feature"), keys) { _ in Speech.speakMessage(String(localized: "\(what.components(separatedBy: " (").first ?? what) isn't available in TurnOver yet", comment: "A VoiceOver feature TurnOver lacks: %@ is the feature")) }
        }
        for (name, what, keys) in [("nextPageColumn", String(localized: "Next column (VO-Command-Y)", comment: "A VoiceOver feature"), ["kb:turnover+command+y"]),
                                   ("previousPageColumn", String(localized: "Previous column (VO-Command-Shift-Y)", comment: "A VoiceOver feature"), ["kb:turnover+command+shift+y"]),
                                   ("tableGrouping", String(localized: "Grouping in a table (VO-Command-Equals)", comment: "A VoiceOver feature"), ["kb:turnover+command+="])] {
            add(name, String(localized: "\(what): pages don't offer it to TurnOver", comment: "A VoiceOver feature pages don't give TurnOver: %@ is the feature"), keys) { _ in Speech.speakMessage(String(localized: "\(what.components(separatedBy: " (").first ?? what) isn't available in TurnOver", comment: "A VoiceOver feature TurnOver lacks: %@ is the feature")) }
        }
    }

    /// The input method's candidate window or the autocorrect panel: a floating window of the app in front, or of an
    /// input method's own process. (Built from Apple's documentation, not yet seen on screen.)
    static func inputPanel() -> AXUIElement? {
        var apps: [pid_t] = []
        if let f = NSWorkspace.shared.frontmostApplication?.processIdentifier { apps.append(f) }
        apps += NSWorkspace.shared.runningApplications.filter {
            let b = $0.bundleIdentifier ?? ""
            return b.contains("inputmethod") || b.contains("TextInput") || b.contains("CharacterPalette")
        }.map(\.processIdentifier)
        for pid in apps {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.5)
            for w in app.elements(kAXWindowsAttribute) {
                let sub = w.string(kAXSubroleAttribute) ?? ""
                if ["AXSystemFloatingWindow", "AXFloatingWindow", "AXUnknown"].contains(sub), !w.elements(kAXChildrenAttribute).isEmpty {
                    return w.elements(kAXChildrenAttribute).first
                }
            }
        }
        return nil
    }

    /// VO-Command-C: where the formatting changes. A page: WebKit's own search; text: the formatting compared
    /// character by character from the caret.
    static func styleChange(forward: Bool) {
        if let d = API.focusTreeInterceptor, !d.passThrough { d.searchKey("AXStyleChangeSearchKey", spoken: String(localized: "style change", comment: "A kind of thing to find, after next or previous"), forward: forward); return }
        guard let obj = API.caretObject, let info = try? obj.makeTextInfo(.caret) else { Speech.speakMessage(String(localized: "not in text", comment: "Spoken message")); return }
        func style(_ i: TextInfo) -> String { let c = i.copy(); c.expand(.character); return c.formatField()?.fullDescription ?? "" }
        let start = style(info)
        // A third of a second at most, and never past another key: one character at a time is slow, and a long note
        // in one style held the main thread for seconds (the code review, 12 Oct 2026). Later: by attribute runs.
        let began = Date(), keys = ScriptHandler.keysArrivedCount
        func outOfTime() -> Bool { Date().timeIntervalSince(began) > 0.3 || ScriptHandler.keysArrivedCount != keys }
        var found = false
        while !outOfTime() {
            guard info.move(.character, forward ? 1 : -1) != 0 else { Tones.edge(); Speech.speakMessage(forward ? String(localized: "no next style change", comment: "Spoken message") : String(localized: "no previous style change", comment: "Spoken message")); return }
            if style(info) != start { found = true; break }
        }
        guard found else { Log.io("style change: none within 300 ms"); Speech.speakMessage(String(localized: "no style change found nearby", comment: "Spoken message")); return }
        if !forward {   // to the start of that run, within the same budget
            let s = style(info)
            while !outOfTime(), info.move(.character, -1) != 0 { if style(info) != s { _ = info.move(.character, 1); break } }
        }
        info.updateCaret()
        let word = info.copy(); word.expand(.word)
        Speech.speakMessage([style(info), word.text.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    /// VO-Command-M: the next heading at the level of the one here (or the last one before here).
    static func sameLevelHeading(forward: Bool, _ g: KeyboardGesture) {
        guard let d = API.focusTreeInterceptor else {
            // Word and the like: no levels to compare, so the next heading.
            if let s = ScriptHandler.findScript(named: forward ? "nextHeading" : "previousHeading") { s.handler(g) } else { Speech.speakMessage(String(localized: "not in a document", comment: "Spoken message")) }
            return
        }
        var e = cursorElement(); var hops = 0
        while let x = e, x.role != "AXHeading", hops < 6 { e = x.element(kAXParentAttribute); hops += 1 }
        if e?.role != "AXHeading", let (_, h) = d.buffer.find(from: d.position, forward: false, roles: ["AXHeading"], headingLevel: nil) { e = h }
        guard let heading = e, heading.role == "AXHeading" else { Speech.speakMessage(String(localized: "not on a heading", comment: "Spoken message")); return }
        let level = (heading.attr(kAXValueAttribute) as? NSNumber)?.intValue ?? 0
        guard (1...6).contains(level), let s = d.script(named: (forward ? "next" : "previous") + "Heading\(level)") else {
            d.script(named: forward ? "nextHeading" : "previousHeading")?.handler(g); return
        }
        s.handler(g)
    }
}
