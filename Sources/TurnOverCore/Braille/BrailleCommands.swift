// SPDX-License-Identifier: GPL-3.0-or-later
// Space with dots: VoiceOver's braille commands for the Mac (Apple's "Common braille commands for VoiceOver on
// Mac", support.apple.com/103560), so a VoiceOver braille user's fingers work in TurnOver too. Each runs as the key
// it stands for would: TurnOver's own command for that key (its VoiceOver keys, VO-Left and so on), or the key itself.
import Foundation

enum BrailleCommands {
    enum Action {
        case key(String)            // a keyboard gesture, as if pressed
        case braille(String)        // a display action: "scrollBack", "scrollForward"
        case run(() -> Void)
    }

    static func dots(_ s: String) -> Set<Int> { Set(s.compactMap { $0.wholeNumberValue }) }

    static let table: [(Set<Int>, String, Action)] = [
        // Navigation
        (dots("1"), String(localized: "previous item", comment: "A braille chord's command, as braille help says it"), .key("turnover+leftArrow")),
        (dots("4"), String(localized: "next item", comment: "A braille chord's command, as braille help says it"), .key("turnover+rightArrow")),
        (dots("3"), String(localized: "move up", comment: "A braille chord's command, as braille help says it"), .key("upArrow")),
        (dots("6"), String(localized: "move down", comment: "A braille chord's command, as braille help says it"), .key("downArrow")),
        (dots("123"), String(localized: "first item", comment: "A braille chord's command, as braille help says it"), .run { BrailleCommands.toEnd(first: true) }),
        (dots("456"), String(localized: "last item", comment: "A braille chord's command, as braille help says it"), .run { BrailleCommands.toEnd(first: false) }),
        (dots("236"), String(localized: "start interacting", comment: "A braille chord's command, as braille help says it"), .key("turnover+shift+downArrow")),
        (dots("356"), String(localized: "stop interacting", comment: "A braille chord's command, as braille help says it"), .key("turnover+shift+upArrow")),
        (dots("24"), String(localized: "item chooser", comment: "A braille chord's command, as braille help says it"), .key("turnover+i")),
        (dots("124"), String(localized: "find", comment: "A braille chord's command, as braille help says it"), .key("command+f")),
        (dots("234"), String(localized: "menu bar", comment: "A braille chord's command, as braille help says it"), .key("turnover+m")),
        (dots("25"), String(localized: "shortcut menu", comment: "A braille chord's command, as braille help says it"), .key("turnover+shift+m")),
        (dots("12"), String(localized: "escape", comment: "A braille chord's command, as braille help says it"), .key("escape")),
        // Scrolling
        (dots("246"), String(localized: "scroll left", comment: "A braille chord's command, as braille help says it"), .key("shift+pageUp")),
        (dots("135"), String(localized: "scroll right", comment: "A braille chord's command, as braille help says it"), .key("shift+pageDown")),
        (dots("3456"), String(localized: "page up", comment: "A braille chord's command, as braille help says it"), .key("pageUp")),
        (dots("1456"), String(localized: "page down", comment: "A braille chord's command, as braille help says it"), .key("pageDown")),
        // Interaction
        (dots("36"), String(localized: "perform action", comment: "A braille chord's command, as braille help says it"), .key("turnover+space")),
        (dots("34"), String(localized: "where you are: page and line", comment: "A braille chord's command, as braille help says it"), .key("turnover+delete")),
        // Reading
        (dots("2456"), String(localized: "read from the top", comment: "A braille chord's command, as braille help says it"), .run { BrailleCommands.readFromTop() }),
        (dots("1235"), String(localized: "read the current item", comment: "A braille chord's command, as braille help says it"), .key("turnover+l")),
        (dots("23456"), String(localized: "text attributes", comment: "A braille chord's command, as braille help says it"), .key("turnover+t")),
        // Editing
        (dots("2356"), String(localized: "select all", comment: "A braille chord's command, as braille help says it"), .key("command+a")),
        (dots("235"), String(localized: "select left", comment: "A braille chord's command, as braille help says it"), .key("shift+leftArrow")),
        (dots("256"), String(localized: "select right", comment: "A braille chord's command, as braille help says it"), .key("shift+rightArrow")),
        // Control
        (dots("136"), String(localized: "TurnOver menu", comment: "A braille chord's command, as braille help says it"), .key("turnover+n")),
        (dots("123456"), String(localized: "Screen Curtain", comment: "A braille chord's command, as braille help says it"), .run { ScriptHandler.findScript(named: "screenCurtain").map { $0.handler(KeyboardGesture(identifier: "kb:turnover+shift+escape")!) } }),
        (dots("1234"), String(localized: "pause or continue speech", comment: "A braille chord's command, as braille help says it"), .run { Speech.togglePause() }),
        (dots("134"), String(localized: "speech on or off", comment: "A braille chord's command, as braille help says it"), .run { ScriptHandler.findScript(named: "speechMode").map { $0.handler(KeyboardGesture(identifier: "kb:turnover+s")!) } }),
        (dots("125"), String(localized: "help", comment: "A braille chord's command, as braille help says it"), .key("turnover+/")),
        (dots("13"), String(localized: "keyboard help", comment: "A braille chord's command, as braille help says it"), .key("turnover+k")),
        (dots("12345"), String(localized: "quick navigation on or off", comment: "A braille chord's command, as braille help says it"), .key("turnover+q")),
        // Braille
        (dots("2"), String(localized: "pan left", comment: "A braille chord's command, as braille help says it"), .braille("scrollBack")),
        (dots("5"), String(localized: "pan right", comment: "A braille chord's command, as braille help says it"), .braille("scrollForward")),
        (dots("1245"), String(localized: "contracted or uncontracted braille", comment: "A braille chord's command, as braille help says it"), .run {
            config.braille.contractedInput.toggle(); config.save()
            Speech.speakMessage(config.braille.contractedInput ? String(localized: "contracted braille input", comment: "Spoken message") : String(localized: "uncontracted braille input", comment: "Spoken message"))
        }),
        (dots("145"), String(localized: "delete", comment: "A braille chord's command, as braille help says it"), .key("delete")),
        (dots("15"), String(localized: "return", comment: "A braille chord's command, as braille help says it"), .key("return")),
        (dots("2345"), String(localized: "tab", comment: "A braille chord's command, as braille help says it"), .key("tab")),
        (dots("2567"), String(localized: "desktop", comment: "A braille chord's command, as braille help says it"), .run { Speech.speakMessage(String(localized: "Go to Desktop is not available in TurnOver yet", comment: "Spoken message")) }),
        // Modifiers: with dot 7 for the next key, with dot 8 locked until the same chord again.
        (dots("47"), String(localized: "shift", comment: "A braille chord's command, as braille help says it"), .run { BrailleInput.modifier(.shift, name: KeyNames.spokenNames["shift"] ?? "shift", lock: false) }),
        (dots("48"), String(localized: "shift lock", comment: "A braille chord's command, as braille help says it"), .run { BrailleInput.modifier(.shift, name: KeyNames.spokenNames["shift"] ?? "shift", lock: true) }),
        (dots("17"), String(localized: "command", comment: "A braille chord's command, as braille help says it"), .run { BrailleInput.modifier(.command, name: KeyNames.spokenNames["command"] ?? "command", lock: false) }),
        (dots("18"), String(localized: "command lock", comment: "A braille chord's command, as braille help says it"), .run { BrailleInput.modifier(.command, name: KeyNames.spokenNames["command"] ?? "command", lock: true) }),
        (dots("37"), String(localized: "control", comment: "A braille chord's command, as braille help says it"), .run { BrailleInput.modifier(.control, name: KeyNames.spokenNames["control"] ?? "control", lock: false) }),
        (dots("38"), String(localized: "control lock", comment: "A braille chord's command, as braille help says it"), .run { BrailleInput.modifier(.control, name: KeyNames.spokenNames["control"] ?? "control", lock: true) }),
        (dots("27"), String(localized: "option", comment: "A braille chord's command, as braille help says it"), .run { BrailleInput.modifier(.option, name: KeyNames.spokenNames["option"] ?? "option", lock: false) }),
        (dots("28"), String(localized: "option lock", comment: "A braille chord's command, as braille help says it"), .run { BrailleInput.modifier(.option, name: KeyNames.spokenNames["option"] ?? "option", lock: true) }),
        (dots("57"), String(localized: "fn", comment: "A braille chord's command, as braille help says it"), .run { Speech.speakMessage(String(localized: "Fn is not available from the display yet", comment: "Spoken message")) }),
        (dots("58"), String(localized: "fn lock", comment: "A braille chord's command, as braille help says it"), .run { Speech.speakMessage(String(localized: "Fn is not available from the display yet", comment: "Spoken message")) }),
        (dots("7"), String(localized: "delete", comment: "A braille chord's command, as braille help says it"), .key("backspace")),
        (dots("8"), String(localized: "return", comment: "A braille chord's command, as braille help says it"), .key("enter")),
        // Rotor: TurnOver's rotor opens; Left and Right (or the joystick) change its kind.
        (dots("23"), String(localized: "rotor", comment: "A braille chord's command, as braille help says it"), .key("turnover+u")),
        (dots("56"), String(localized: "rotor", comment: "A braille chord's command, as braille help says it"), .key("turnover+u")),
        // Volume
        (dots("345"), String(localized: "volume up", comment: "A braille chord's command, as braille help says it"), .run { BrailleCommands.volume(by: 10) }),
        (dots("126"), String(localized: "volume down", comment: "A braille chord's command, as braille help says it"), .run { BrailleCommands.volume(by: -10) }),
        // Announcements and typing
        (dots("1345"), String(localized: "announcement history", comment: "A braille chord's command, as braille help says it"), .run { Braille.toggleHistory() }),
        (dots("45"), String(localized: "translate", comment: "A braille chord's command, as braille help says it"), .run { BrailleInput.flush() }),
        (dots("137"), String(localized: "keyboard help", comment: "A braille chord's command, as braille help says it"), .key("turnover+k")),
        (dots("1347"), String(localized: "speech on or off", comment: "A braille chord's command, as braille help says it"), .run { ScriptHandler.findScript(named: "speechMode").map { $0.handler(KeyboardGesture(identifier: "kb:turnover+s")!) } }),
    ]

    /// Space with these dots: true if it is a command.
    static func run(_ dots: Set<Int>) -> Bool {
        guard let (_, name, action) = table.first(where: { $0.0 == dots }) else { return false }
        Log.io("braille command: \(name)")
        switch action {
        case .key(let k): press(k)
        case .braille(let b): Braille.handle(.key(b == "scrollBack" ? "SCRBraille.panLeft" : "SCRBraille.panRight"))
        case .run(let f): f()
        }
        return true
    }

    /// A key, as if pressed: TurnOver's command for it, or else the key itself (never a TurnOver-key combination,
    /// which means nothing to the application).
    static func press(_ key: String) {
        // A modifier held from the display goes with a plain key (Command with Tab), not with TurnOver's own.
        let key = key.hasPrefix("turnover+") ? key : BrailleInput.takeModifiers() + key
        guard let g = KeyboardGesture(identifier: "kb:\(key)") else { return }
        // The TurnOver menu open: the key goes to it (space with 1 2 is its Escape, 3 and 6 move in it).
        if TurnOverMenu.shared.isOpen, !key.hasPrefix("turnover+") { TurnOverMenu.shared.handle(g); return }
        if let s = ScriptHandler.findScript(for: g) { ScriptHandler.executeScript(s, gesture: g) }
        else if key.hasPrefix("turnover+") { Tones.edge() }
        else { g.send() }
    }

    /// VoiceOver's first and last item, in TurnOver's terms: the first or last row of a list, the top or bottom of a
    /// page in browse mode or of a document being edited, and in Terminal the first or last line of its history.
    static func toEnd(first: Bool) {
        let terminal = ScriptHandler.findScript(for: KeyboardGesture(identifier: first ? "kb:turnover+home" : "kb:turnover+end")!)
        if let t = terminal { ScriptHandler.executeScript(t, gesture: KeyboardGesture(identifier: first ? "kb:turnover+home" : "kb:turnover+end")!); return }
        if let f = API.focusObject, API.focusTreeInterceptor.map({ $0.passThrough }) ?? true,
           [.table, .list, .treeView].contains(f.role) || ["AXTable", "AXOutline", "AXList", "AXBrowser"].contains(f.axRole) {
            press(first ? "home" : "end"); return
        }
        press(first ? "command+upArrow" : "command+downArrow")
    }

    static func volume(by step: Int) {
        config.speech.volume = min(200, max(10, config.speech.volume + step))
        Speech.player?.volume = Float(config.speech.volume) / 100
        config.save()
        Speech.speakMessage(String(localized: "volume \(String(config.speech.volume)) percent", comment: "The speech volume changed: %@ is the percentage"))
    }

    private static func readFromTop() {
        press("command+upArrow")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { press("turnover+a") }
    }
}
