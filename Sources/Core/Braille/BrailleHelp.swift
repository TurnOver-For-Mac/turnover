// SPDX-License-Identifier: GPL-3.0-or-later
// What the display's keys and chords do, for input help (TurnOver 1: each key says what it does instead of doing
// it) and for the shortcuts list (TurnOver slash), which gains a Braille display section while one is connected.
import Foundation

enum BrailleHelp {
    /// TurnOver's actions for the display's keys, in words.
    static let actions: [String: String] = [
        "scrollBack": "pans left; at the start of a line, goes to the end of the previous line",
        "scrollForward": "pans right; at the end of a line, goes on to the next line",
        "previousLine": "previous line, or the previous item in a list, spoken",
        "nextLine": "next line, or the next item in a list, spoken",
        "activate": "activates the item: presses a link or button",
    ]

    /// The keys as VoiceOver names them in each display's key table.
    static let keyNames: [String: String] = [
        "SCRBraille.panLeft": "Pan left key", "SCRBraille.panRight": "Pan right key",
        "Global.interactUp": "Up (joystick up, or the key VoiceOver uses to move up)",
        "Global.interactDown": "Down (joystick down, or the key VoiceOver uses to move down)",
        "Global.interactLeft": "Left (joystick left)", "Global.interactRight": "Right (joystick right)",
        "Global.defaultAction": "Action (joystick pressed in)",
        "d1": "Display key 1", "d2": "Display key 2", "d3": "Display key 3", "d5": "Display key 5",
        "joystickUp": "Joystick up", "joystickDown": "Joystick down", "joystickLeft": "Joystick left", "joystickRight": "Joystick right", "joystickPress": "Joystick pressed in",
    ]

    static func describe(_ key: BrailleKey) -> String {
        switch key {
        case .routing(let i): return "Routing key \(i + 1): moves the cursor to this character; on a link or button, presses it"
        case .key(let name):
            let what = Braille.keyMap[name].flatMap { actions[$0] } ?? "does nothing yet"
            return "\(keyNames[name] ?? name): \(what)"
        }
    }

    static func describe(dots: Set<Int>, space: Bool) -> String {
        let spoken = "dot\(dots.count == 1 ? "" : "s") " + dots.sorted().map(String.init).joined(separator: " ")
        if space && dots.isEmpty { return "Space: types a space; on its own after a word, translates it" }
        if space {
            if let (_, name, _) = BrailleCommands.table.first(where: { $0.0 == dots }) { return "Space with \(spoken): \(name)" }
            // Not one of VoiceOver's commands: say so plainly ("nothing yet" sounded unfinished, 7 Oct 2026), and what
            // it does when typing runs into the space.
            return "Space with \(spoken): not a command. While typing, it types the letter and a space"
        }
        if dots == [7] { return "Dot 7: Backspace; held, keeps deleting" }
        if dots == [8] { return "Dot 8: Return" }
        let cell = dots.reduce(UInt8(0)) { $0 | UInt8(1 << ($1 - 1)) }
        // Dots 7 and 8 alone, together, are no character ("types space" was said).
        if cell & 0x3F == 0 { return "\(spoken.prefix(1).uppercased() + spoken.dropFirst()): nothing" }
        let text = BrailleOutput.backTranslate([cell], contracted: false)
        return "\(spoken.prefix(1).uppercased() + spoken.dropFirst()): types \(text.isEmpty ? "nothing on its own" : Symbols.spelled(text))"
    }

    /// Input help: said and shown, not done.
    static func explain(_ s: String) {
        Speech.speakMessage(s)
    }

    /// For the shortcuts list, while a display is connected: its keys, then the space-with-dots commands.
    static func shortcutItems() -> [MenuItem] {
        guard Braille.display != nil else { return [] }
        var keys: [MenuItem] = []
        var seen = Set<String>()
        for name in (Braille.displayKeyNames() ?? []) where !seen.contains(name) {
            seen.insert(name)
            guard let action = Braille.keyMap[name], let what = actions[action] else { continue }
            keys.append(MenuItem("\(keyNames[name] ?? name), \(what)", .action {}))
        }
        keys.append(MenuItem("Routing keys, move the cursor to that character; on a link or button, press it", .action {}))
        keys.append(MenuItem("Dot 7, Backspace; held, keeps deleting. Dot 8, Return. Space, a space", .action {}))
        let chords = BrailleCommands.table.map { entry in
            MenuItem("Space with dots \(entry.0.sorted().map(String.init).joined(separator: " ")), \(entry.1)", .action { _ = BrailleCommands.run(entry.0) })
        }
        return [
            MenuItem("Braille display keys, \(keys.count)", .submenu { keys }),
            MenuItem("Braille chords (space with dots), \(chords.count)", .submenu { chords }),
        ]
    }
}
