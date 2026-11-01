// SPDX-License-Identifier: GPL-3.0-or-later
// What the display's keys and chords do, for input help (TurnOver 1: each key says what it does instead of doing
// it) and for the shortcuts list (TurnOver slash), which gains a Braille display section while one is connected.
import Foundation

enum BrailleHelp {
    /// TurnOver's actions for the display's keys, in words.
    static let actions: [String: String] = [
        "scrollBack": String(localized: "pans left; at the start of a line, goes to the end of the previous line", comment: "What a braille display key does"),
        "scrollForward": String(localized: "pans right; at the end of a line, goes on to the next line", comment: "What a braille display key does"),
        "previousLine": String(localized: "previous line, or the previous item in a list, spoken", comment: "What a braille display key does"),
        "nextLine": String(localized: "next line, or the next item in a list, spoken", comment: "What a braille display key does"),
        "activate": String(localized: "activates the item: presses a link or button", comment: "What a braille display key does"),
    ]

    /// The keys as VoiceOver names them in each display's key table.
    static let keyNames: [String: String] = [
        "SCRBraille.panLeft": String(localized: "Pan left key", comment: "A braille display key, as VoiceOver names it"), "SCRBraille.panRight": String(localized: "Pan right key", comment: "A braille display key, as VoiceOver names it"),
        "Global.interactUp": String(localized: "Up (joystick up, or the key VoiceOver uses to move up)", comment: "A braille display key, as VoiceOver names it"),
        "Global.interactDown": String(localized: "Down (joystick down, or the key VoiceOver uses to move down)", comment: "A braille display key, as VoiceOver names it"),
        "Global.interactLeft": String(localized: "Left (joystick left)", comment: "A braille display key, as VoiceOver names it"), "Global.interactRight": String(localized: "Right (joystick right)", comment: "A braille display key, as VoiceOver names it"),
        "Global.defaultAction": String(localized: "Action (joystick pressed in)", comment: "A braille display key, as VoiceOver names it"),
        "d1": String(localized: "Display key 1", comment: "A braille display key, as VoiceOver names it"), "d2": String(localized: "Display key 2", comment: "A braille display key, as VoiceOver names it"), "d3": String(localized: "Display key 3", comment: "A braille display key, as VoiceOver names it"), "d5": String(localized: "Display key 5", comment: "A braille display key, as VoiceOver names it"),
        "joystickUp": String(localized: "Joystick up", comment: "A braille display key, as VoiceOver names it"), "joystickDown": String(localized: "Joystick down", comment: "A braille display key, as VoiceOver names it"), "joystickLeft": String(localized: "Joystick left", comment: "A braille display key, as VoiceOver names it"), "joystickRight": String(localized: "Joystick right", comment: "A braille display key, as VoiceOver names it"), "joystickPress": String(localized: "Joystick pressed in", comment: "A braille display key, as VoiceOver names it"),
    ]

    static func describe(_ key: BrailleKey) -> String {
        switch key {
        case .routing(let i): return String(localized: "Routing key \(String(i + 1)): moves the cursor to this character; on a link or button, presses it", comment: "Braille help: %@ is the key's number")
        case .key(let name):
            let what = Braille.keyMap[name].flatMap { actions[$0] } ?? String(localized: "does nothing yet", comment: "Braille help: a key with no command")
            return "\(keyNames[name] ?? name): \(what)"
        }
    }

    static func describe(dots: Set<Int>, space: Bool) -> String {
        let numbers = dots.sorted().map(String.init).joined(separator: " ")
        let spoken = dots.count == 1 ? String(localized: "dot \(numbers)", comment: "Braille dots: dot 4") : String(localized: "dots \(numbers)", comment: "Braille dots: dots 1 2 5")
        if space && dots.isEmpty { return String(localized: "Space: types a space; on its own after a word, translates it", comment: "Braille help") }
        if space {
            if let (_, name, _) = BrailleCommands.table.first(where: { $0.0 == dots }) { return String(localized: "Space with \(spoken): \(name)", comment: "Braille help: the dots, then the command") }
            // Not one of VoiceOver's commands: say so plainly ("nothing yet" sounded unfinished, 7 Oct 2026), and what
            // it does when typing runs into the space.
            return String(localized: "Space with \(spoken): not a command. While typing, it types the letter and a space", comment: "Braille help: %@ is the dots")
        }
        if dots == [7] { return String(localized: "Dot 7: Backspace; held, keeps deleting", comment: "Braille help") }
        if dots == [8] { return String(localized: "Dot 8: Return", comment: "Braille help") }
        let cell = dots.reduce(UInt8(0)) { $0 | UInt8(1 << ($1 - 1)) }
        // Dots 7 and 8 alone, together, are no character ("types space" was said).
        if cell & 0x3F == 0 { return String(localized: "\(spoken.prefix(1).uppercased() + spoken.dropFirst()): nothing", comment: "Braille help: dots that type nothing") }
        let text = BrailleOutput.backTranslate([cell], contracted: false)
        let typed = text.isEmpty ? String(localized: "nothing on its own", comment: "Braille help: dots that type nothing alone") : Symbols.spelled(text)
        return String(localized: "\(spoken.prefix(1).uppercased() + spoken.dropFirst()): types \(typed)", comment: "Braille help: the dots, then what they type")
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
            keys.append(MenuItem(verbatim: "\(keyNames[name] ?? name), \(what)", .action {}))
        }
        keys.append(MenuItem("Routing keys, move the cursor to that character; on a link or button, press it", .action {}))
        keys.append(MenuItem("Dot 7, Backspace; held, keeps deleting. Dot 8, Return. Space, a space", .action {}))
        let chords = BrailleCommands.table.map { entry in
            MenuItem(verbatim: String(localized: "Space with dots \(entry.0.sorted().map(String.init).joined(separator: " ")), \(entry.1)", comment: "A braille chord: the dots, then the command"), .action { _ = BrailleCommands.run(entry.0) })
        }
        return [
            MenuItem("Braille display keys, \(String(keys.count))", .submenu { keys }),
            MenuItem("Braille chords (space with dots), \(String(chords.count))", .submenu { chords }),
        ]
    }
}
