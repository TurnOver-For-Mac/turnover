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
        if spots[n] != nil { spots[n] = nil; watches[n]?.invalidate(); watches[n] = nil; Speech.speakMessage("hot spot \(n) removed"); return }
        guard let e = VoiceOverKeysPlugin.cursorElement() else { Speech.speakMessage("nothing here"); return }
        let app = NSRunningApplication(processIdentifier: e.pid)?.localizedName ?? ""
        spots[n] = Spot(element: e, app: app, name: name(e))
        Speech.speakMessage("hot spot \(n) set, \(spots[n]!.name)")
    }

    static func go(_ n: Int) {
        guard let s = spots[n] else { Speech.speakMessage("no hot spot \(n)"); return }
        guard alive(s.element) else { Speech.speakMessage("hot spot \(n), \(s.name), is no longer there"); return }
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
        guard let s = spots[n] else { Speech.speakMessage("no hot spot \(n)"); return }
        guard alive(s.element) else { Speech.speakMessage("hot spot \(n), \(s.name), is no longer there"); return }
        Speech.speakObject(ObjectFactory.make(s.element), reason: .focus)
    }

    static func snapshot(_ e: AXUIElement) -> String {
        let o = ObjectFactory.make(e)
        return [o.name, o.value ?? "", "\(e.elements(kAXChildrenAttribute).count)"].joined(separator: "|")
    }

    static func watch(_ n: Int) {
        if let t = watches[n] { t.invalidate(); watches[n] = nil; Speech.speakMessage("stopped watching hot spot \(n)"); return }
        guard let s = spots[n], alive(s.element) else { Speech.speakMessage("no hot spot \(n)"); return }
        seen[n] = snapshot(s.element)
        watches[n] = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { check(n) } }
        Speech.speakMessage("watching hot spot \(n), \(s.name)")
    }

    nonisolated(unsafe) static var seen: [Int: String] = [:]
    static func check(_ n: Int) {
        guard let s = spots[n], alive(s.element) else { watches[n]?.invalidate(); watches[n] = nil; Speech.speakNews("hot spot \(n) is gone"); return }
        let now = snapshot(s.element)
        guard now != seen[n] else { return }
        seen[n] = now
        let o = ObjectFactory.make(s.element)
        Speech.speakNews("hot spot \(n), " + [o.name, o.value ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    static func step(_ by: Int) {
        let keys = spots.keys.sorted()
        guard !keys.isEmpty else { Speech.speakMessage("no hot spots"); return }
        let i = last.flatMap { keys.firstIndex(of: $0) }.map { ($0 + by + keys.count) % keys.count } ?? (by > 0 ? 0 : keys.count - 1)
        go(keys[i])
    }

    static func chooser() {
        let items = spots.keys.sorted().map { n -> MenuItem in
            let s = spots[n]!
            return MenuItem("\(n), \(s.name)\(s.app.isEmpty ? "" : ", \(s.app)")\(watches[n] != nil ? ", watched" : "")", .action { go(n) })
        }
        TurnOverMenu.shared.openList("Hot spots", items: items)
    }
}

public enum TurnOverGuide {
    /// The TurnOver guide (VO-Shift-Slash, VO-Command-F8, Command Control H).
    public static func open() {
        guard let g = Bundle.main.url(forResource: Edition.guideName, withExtension: "txt") else { Speech.speakMessage("The guide is not in this copy of TurnOver"); return }
        NSWorkspace.shared.open(g)
        Speech.speakMessage("TurnOver guide")
    }
}

extension VoiceOverKeysPlugin {

    func addVoiceOverDecisions(_ add: (String, String, [String], @escaping (KeyboardGesture) -> Void) -> Void) {
        func count() -> Int { ScriptHandler.lastScriptRepeatCount }

        // 1. VO-N: the notifications heard lately. (The TurnOver menu: Command Control N.)
        add("notifications", "The notifications heard lately (VO-N)", ["kb:turnover+n"]) { _ in
            let items = NotificationHistory.items.reversed().map { n -> MenuItem in
                let mins = Int(Date().timeIntervalSince(n.at) / 60)
                let when = mins < 1 ? "just now" : mins == 1 ? "1 minute ago" : mins < 60 ? "\(mins) minutes ago" : "\(mins / 60) hours ago"
                return MenuItem("\(n.text), \(when)", .action { Speech.speakPrivate(n.text) })
            }
            guard !items.isEmpty else { Speech.speakMessage("no notifications"); return }
            TurnOverMenu.shared.openList("Notifications", items: items)
        }
        // 2. VO-V: verbosity. (Handing over: Command Control Shift T.)
        add("verbosity", "Verbosity: punctuation, item details and hints (VO-V)", ["kb:turnover+v"]) { _ in TurnOverMenu.shared.openVerbosity() }
        // 3. VO-Shift-K: the Option key Commander. (The keyboard style: Command Control K.)
        add("optionCommander", "Option key Commander on or off: right Option with a letter runs a command (VO-Shift-K)", ["kb:turnover+shift+k"]) { _ in
            config.keyboard.optionCommander.toggle(); config.save(); KeySettings.refresh()
            Speech.speakMessage(config.keyboard.optionCommander ? "Option key commander on" : "Option key commander off")
        }
        // 4. VO-Shift-J: the input method or autocorrect panel. (The "that was wrong" mark: Command Control J.)
        add("inputPanel", "Jumps to the input method or autocorrect panel (VO-Shift-J)", ["kb:turnover+shift+j"]) { _ in
            guard let panel = Self.inputPanel() else { Speech.speakMessage("no input method or autocorrect panel"); return }
            ObjectNavigator.shared.moveTo(panel)
        }
        // 5. VO-Slash: the plugin maker (its first job, a label: VoiceOver's custom label). VO-Shift-Slash: the guide.
        add("customLabel", "Labels the item, and more: the plugin maker (VO-Slash)", ["kb:turnover+/"]) { g in
            (ScriptHandler.findScript(named: "makePlugin") ?? GlobalCommands.shared.script(named: "makePlugin"))?.handler(g)
        }
        add("guide", "Opens the TurnOver guide (VO-Shift-Slash)", ["kb:turnover+shift+/", "kb:turnover+?"]) { _ in TurnOverGuide.open() }
        // 6. VO-Command-C: the next style change. (Copying the last thing spoken: VO-Shift-C, Command Control C.)
        add("nextStyleChange", "Next style change (VO-Command-C)", ["kb:turnover+command+c"]) { _ in Self.styleChange(forward: true) }
        add("previousStyleChange", "Previous style change (VO-Command-Shift-C)", ["kb:turnover+command+shift+c"]) { _ in Self.styleChange(forward: false) }
        // 7. VO-Command-M: the next heading of the same level.
        add("nextSameHeading", "Next heading of the same level (VO-Command-M)", ["kb:turnover+command+m"]) { g in Self.sameLevelHeading(forward: true, g) }
        add("previousSameHeading", "Previous heading of the same level (VO-Command-Shift-M)", ["kb:turnover+command+shift+m"]) { g in Self.sameLevelHeading(forward: false, g) }
        // 9. VO-Backspace: a tab stop on a ruler. (Back to the focus: VO-Shift-F4.)
        add("deleteTabStop", "Deletes the tab stop on a ruler (VO-Backspace)", ["kb:turnover+backspace"]) { _ in
            guard let e = Self.cursorElement(), e.role == "AXRulerMarker" else { Speech.speakMessage("not on a tab stop"); return }
            let r = AXUIElementPerformAction(e, "AXDelete" as CFString)
            Speech.speakMessage(r == .success ? "tab stop deleted" : "this tab stop can't be deleted")
        }
        // 8. Hot spots.
        for n in 0...9 {
            add("hotSpotSet\(n)", "Sets or removes hot spot \(n) (VO-Shift-\(n))", ["kb:turnover+shift+\(n)"]) { _ in HotSpots.set(n) }
            add("hotSpotGo\(n)", "Goes to hot spot \(n) (VO-\(n))", ["kb:turnover+\(n)"]) { _ in HotSpots.go(n) }
            add("hotSpotDescribe\(n)", "Describes hot spot \(n) (VO-Command-\(n))", ["kb:turnover+command+\(n)"]) { _ in HotSpots.describe(n) }
            add("hotSpotWatch\(n)", "Watches hot spot \(n) for changes, or stops (VO-Command-Shift-\(n))", ["kb:turnover+command+shift+\(n)"]) { _ in HotSpots.watch(n) }
        }
        add("hotSpotChooser", "The hot spot chooser (VO-Shift-X)", ["kb:turnover+shift+x"]) { _ in HotSpots.chooser() }
        add("nextHotSpot", "Next hot spot (VO-Shift-Right Bracket)", ["kb:turnover+shift+]"]) { _ in HotSpots.step(1) }
        add("previousHotSpot", "Previous hot spot (VO-Shift-Left Bracket)", ["kb:turnover+shift+["]) { _ in HotSpots.step(-1) }
        // 13. VO-Clear: the NumPad Commander (Keypad.swift).
        add("numpadCommander", "NumPad Commander on or off: the keypad runs VoiceOver's commands (VO-Clear)", ["kb:turnover+numpadClear"]) { _ in Keypad.toggleCommander() }
        // VoiceOver's speech settings (12 Oct 2026; on an Apple page the first audit missed): VO-Command-Left
        // and Right choose a setting, VO-Command-Up and Down change it (older VoiceOver); Apple's guide now says
        // VO-Command-Shift with the arrows (unac009): both. The same ring as NVDA's (SynthRing).
        // VO-Command-Shift with the arrows (Apple's guide, unac009); VO-Command with the arrows is the rotor (17 Oct 2026).
        add("speechSettingNext", "Next speech setting: voice, rate, pitch, volume, punctuation (VO-Command-Shift-Right)", ["kb:turnover+command+shift+rightArrow"]) { _ in SynthRing.step(1) }
        add("speechSettingPrevious", "Previous speech setting (VO-Command-Shift-Left)", ["kb:turnover+command+shift+leftArrow"]) { _ in SynthRing.step(-1) }
        add("speechSettingUp", "Raises the speech setting (VO-Command-Shift-Up)", ["kb:turnover+command+shift+upArrow"]) { _ in SynthRing.change(1, large: false) }
        add("speechSettingDown", "Lowers the speech setting (VO-Command-Shift-Down)", ["kb:turnover+command+shift+downArrow"]) { _ in SynthRing.change(-1, large: false) }
        // The rotor without opening it: the kind with Left and Right, the items with Up and Down (QuickRotor.swift).
        add("rotorNextKind", "The rotor's next kind: headings, links, form controls, tables… (VO-Command-Right)", ["kb:turnover+command+rightArrow"]) { _ in QuickRotor.step(1) }
        add("rotorPreviousKind", "The rotor's previous kind (VO-Command-Left)", ["kb:turnover+command+leftArrow"]) { _ in QuickRotor.step(-1) }
        add("rotorNextItem", "The next item of the rotor's kind (VO-Command-Down)", ["kb:turnover+command+downArrow"]) { g in QuickRotor.move(forward: true, gesture: g) }
        add("rotorPreviousItem", "The previous item of the rotor's kind (VO-Command-Up)", ["kb:turnover+command+upArrow"]) { g in QuickRotor.move(forward: false, gesture: g) }
        // 10, 11. VoiceOver Utility and the Tutorial.
        // VoiceOver Utility itself (18 Oct 2026: "vo f8 needs to be returned to opening voiceover utility");
        // TurnOver's settings are Command Control Comma, S.
        add("utility", "VoiceOver Utility (VO-F8); TurnOver's own settings are Command Control Comma, S", ["kb:turnover+f8"]) { _ in
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.VoiceOverUtility") { NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) }
            else { TurnOverMenu.shared.openSettings() }
        }
        add("tutorial", "The TurnOver guide, until there is a tutorial (VO-Command-F8)", ["kb:turnover+command+f8"]) { _ in TurnOverGuide.open() }
        // 14. Activities: TurnOver's settings profiles (SettingsProfiles.swift). In VoiceOver's apps VO-X is VoiceOver's
        // own (TurnOver isn't taking the keys there). Passing it to VoiceOver from TurnOver's apps (18 Oct 2026, for
        // the Activity way of CoExist) opened VoiceOver's chooser where the tap keeps VoiceOver silent: unheard.
        add("activities", "Activities: sets of speech, verbosity, web and braille settings, by hand or for an app (VO-X)", ["kb:turnover+x"]) { _ in
            SettingsProfiles.openChooser()
        }
        // 12, 14, 15. Not in TurnOver yet: said, so the key is known to have been heard.
        for (name, what, keys) in [("captionPanel", "The caption panel (VO-Command-F10)", ["kb:turnover+command+f10"]),
                                   ("captionPanelMove", "Moving the caption panel (VO-Shift-F10)", ["kb:turnover+shift+f10"]),
                                   ("braillePanel", "The braille panel (VO-Command-F9)", ["kb:turnover+command+f9"]),
                                   ("braillePanelMove", "Moving the braille panel (VO-Shift-F9)", ["kb:turnover+shift+f9"]),
                                   ("tileVisuals", "Tile visuals (VO-F10)", ["kb:turnover+f10"]),
                                   ("visuals", "The cursor and panels on screen (VO-Command-F11)", ["kb:turnover+command+f11"])] {
            add(name, "\(what): not in TurnOver yet", keys) { _ in Speech.speakMessage("\(what.components(separatedBy: " (").first ?? what) isn't available in TurnOver yet") }
        }
        for (name, what, keys) in [("nextPageColumn", "Next column (VO-Command-Y)", ["kb:turnover+command+y"]),
                                   ("previousPageColumn", "Previous column (VO-Command-Shift-Y)", ["kb:turnover+command+shift+y"]),
                                   ("tableGrouping", "Grouping in a table (VO-Command-Equals)", ["kb:turnover+command+="])] {
            add(name, "\(what): pages don't offer it to TurnOver", keys) { _ in Speech.speakMessage("\(what.components(separatedBy: " (").first ?? what) isn't available in TurnOver") }
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
        if let d = API.focusTreeInterceptor, !d.passThrough { d.searchKey("AXStyleChangeSearchKey", spoken: "style change", forward: forward); return }
        guard let obj = API.caretObject, let info = try? obj.makeTextInfo(.caret) else { Speech.speakMessage("not in text"); return }
        func style(_ i: TextInfo) -> String { let c = i.copy(); c.expand(.character); return c.formatField()?.fullDescription ?? "" }
        let start = style(info)
        // A third of a second at most, and never past another key: one character at a time is slow, and a long note
        // in one style held the main thread for seconds (the code review, 12 Oct 2026). Later: by attribute runs.
        let began = Date(), keys = ScriptHandler.keysArrivedCount
        func outOfTime() -> Bool { Date().timeIntervalSince(began) > 0.3 || ScriptHandler.keysArrivedCount != keys }
        var found = false
        while !outOfTime() {
            guard info.move(.character, forward ? 1 : -1) != 0 else { Tones.edge(); Speech.speakMessage(forward ? "no next style change" : "no previous style change"); return }
            if style(info) != start { found = true; break }
        }
        guard found else { Log.io("style change: none within 300 ms"); Speech.speakMessage("no style change found nearby"); return }
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
            if let s = ScriptHandler.findScript(named: forward ? "nextHeading" : "previousHeading") { s.handler(g) } else { Speech.speakMessage("not in a document") }
            return
        }
        var e = cursorElement(); var hops = 0
        while let x = e, x.role != "AXHeading", hops < 6 { e = x.element(kAXParentAttribute); hops += 1 }
        if e?.role != "AXHeading", let (_, h) = d.buffer.find(from: d.position, forward: false, roles: ["AXHeading"], headingLevel: nil) { e = h }
        guard let heading = e, heading.role == "AXHeading" else { Speech.speakMessage("not on a heading"); return }
        let level = (heading.attr(kAXValueAttribute) as? NSNumber)?.intValue ?? 0
        guard (1...6).contains(level), let s = d.script(named: (forward ? "next" : "previous") + "Heading\(level)") else {
            d.script(named: forward ? "nextHeading" : "previousHeading")?.handler(g); return
        }
        s.handler(g)
    }
}
