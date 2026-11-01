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
        (dots("1"), "previous item", .key("turnover+leftArrow")),
        (dots("4"), "next item", .key("turnover+rightArrow")),
        (dots("3"), "move up", .key("upArrow")),
        (dots("6"), "move down", .key("downArrow")),
        (dots("123"), "first item", .run { BrailleCommands.toEnd(first: true) }),
        (dots("456"), "last item", .run { BrailleCommands.toEnd(first: false) }),
        (dots("236"), "start interacting", .key("turnover+shift+downArrow")),
        (dots("356"), "stop interacting", .key("turnover+shift+upArrow")),
        (dots("24"), "item chooser", .key("turnover+i")),
        (dots("124"), "find", .key("command+f")),
        (dots("234"), "menu bar", .key("turnover+m")),
        (dots("25"), "shortcut menu", .key("turnover+shift+m")),
        (dots("12"), "escape", .key("escape")),
        // Scrolling
        (dots("246"), "scroll left", .key("shift+pageUp")),
        (dots("135"), "scroll right", .key("shift+pageDown")),
        (dots("3456"), "page up", .key("pageUp")),
        (dots("1456"), "page down", .key("pageDown")),
        // Interaction
        (dots("36"), "perform action", .key("turnover+space")),
        (dots("34"), "where you are: page and line", .key("turnover+delete")),
        // Reading
        (dots("2456"), "read from the top", .run { BrailleCommands.readFromTop() }),
        (dots("1235"), "read the current item", .key("turnover+l")),
        (dots("23456"), "text attributes", .key("turnover+t")),
        // Editing
        (dots("2356"), "select all", .key("command+a")),
        (dots("235"), "select left", .key("shift+leftArrow")),
        (dots("256"), "select right", .key("shift+rightArrow")),
        // Control
        (dots("136"), "TurnOver menu", .key("turnover+n")),
        (dots("123456"), "Screen Curtain", .run { ScriptHandler.findScript(named: "screenCurtain").map { $0.handler(KeyboardGesture(identifier: "kb:turnover+shift+escape")!) } }),
        (dots("1234"), "pause or continue speech", .run { Speech.togglePause() }),
        (dots("134"), "speech on or off", .run { ScriptHandler.findScript(named: "speechMode").map { $0.handler(KeyboardGesture(identifier: "kb:turnover+s")!) } }),
        (dots("125"), "help", .key("turnover+/")),
        (dots("13"), "keyboard help", .key("turnover+k")),
        (dots("12345"), "quick navigation on or off", .key("turnover+q")),
        // Braille
        (dots("2"), "pan left", .braille("scrollBack")),
        (dots("5"), "pan right", .braille("scrollForward")),
        (dots("1245"), "contracted or uncontracted braille", .run {
            config.braille.contractedInput.toggle(); config.save()
            Speech.speakMessage(config.braille.contractedInput ? "contracted braille input" : "uncontracted braille input")
        }),
        (dots("145"), "delete", .key("delete")),
        (dots("15"), "return", .key("return")),
        (dots("2345"), "tab", .key("tab")),
        (dots("2567"), "desktop", .run { Speech.speakMessage("Go to Desktop is not available in TurnOver yet") }),
        // Modifiers: with dot 7 for the next key, with dot 8 locked until the same chord again.
        (dots("47"), "shift", .run { BrailleInput.modifier(.shift, name: "shift", lock: false) }),
        (dots("48"), "shift lock", .run { BrailleInput.modifier(.shift, name: "shift", lock: true) }),
        (dots("17"), "command", .run { BrailleInput.modifier(.command, name: "command", lock: false) }),
        (dots("18"), "command lock", .run { BrailleInput.modifier(.command, name: "command", lock: true) }),
        (dots("37"), "control", .run { BrailleInput.modifier(.control, name: "control", lock: false) }),
        (dots("38"), "control lock", .run { BrailleInput.modifier(.control, name: "control", lock: true) }),
        (dots("27"), "option", .run { BrailleInput.modifier(.option, name: "option", lock: false) }),
        (dots("28"), "option lock", .run { BrailleInput.modifier(.option, name: "option", lock: true) }),
        (dots("57"), "fn", .run { Speech.speakMessage("Fn is not available from the display yet") }),
        (dots("58"), "fn lock", .run { Speech.speakMessage("Fn is not available from the display yet") }),
        (dots("7"), "delete", .key("backspace")),
        (dots("8"), "return", .key("enter")),
        // Rotor: TurnOver's rotor opens; Left and Right (or the joystick) change its kind.
        (dots("23"), "rotor", .key("turnover+u")),
        (dots("56"), "rotor", .key("turnover+u")),
        // Volume
        (dots("345"), "volume up", .run { BrailleCommands.volume(by: 10) }),
        (dots("126"), "volume down", .run { BrailleCommands.volume(by: -10) }),
        // Announcements and typing
        (dots("1345"), "announcement history", .run { Braille.toggleHistory() }),
        (dots("45"), "translate", .run { BrailleInput.flush() }),
        (dots("137"), "keyboard help", .key("turnover+k")),
        (dots("1347"), "speech on or off", .run { ScriptHandler.findScript(named: "speechMode").map { $0.handler(KeyboardGesture(identifier: "kb:turnover+s")!) } }),
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
        Speech.speakMessage("volume \(config.speech.volume) percent")
    }

    private static func readFromTop() {
        press("command+upArrow")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { press("turnover+a") }
    }
}
