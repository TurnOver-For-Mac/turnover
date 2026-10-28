// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreGraphics
import TurnOverCore

func keyboardPrivacyTests() {
    func gesture(_ code: Int64, _ modifiers: Modifiers = [], _ characters: String = "") -> KeyboardGesture {
        KeyboardGesture(keyCode: code, modifiers: modifiers, characters: characters, timestamp: 0, isRepeat: false, flags: [])
    }

    test("privacy: keyboard diagnostics hide plain, shifted and Option typing") {
        let typing: [(String, KeyboardGesture)] = [
            ("plain letter", gesture(0, [], "a")),
            ("shifted letter", gesture(0, .shift, "A")),
            ("shifted punctuation", gesture(18, .shift, "!")),
            ("Option character", gesture(1, .option, "ß")),
            ("Option Shift character", gesture(2, [.option, .shift], "Î")),
            ("space", gesture(49, [], " ")),
            ("number pad", gesture(83, [], "1")),
            ("non-Latin character", gesture(0, [], "ش")),
            ("backspace", gesture(51, [], "\u{7f}")),
        ]
        for (name, key) in typing {
            expect(key.logDescription(), "(a typed key)", name)
            expect(key.logDescription(secure: true), "(a typed key)", "password: \(name)")
        }
    }

    test("privacy: keyboard diagnostics hide dead keys and composed text") {
        let typing: [(String, KeyboardGesture)] = [
            ("dead key", gesture(14, .option)),
            ("shifted dead key", gesture(14, [.option, .shift])),
            ("composed text", gesture(0, [], "ab")),
            ("unmapped text key", gesture(255)),
        ]
        for (name, key) in typing {
            check(key.typedCharacter == nil, "\(name) is not represented by the single-character typing event")
            expect(key.logDescription(), "(a typed key)", name)
        }
    }

    test("privacy: keyboard diagnostics retain navigation and command identifiers") {
        for name in ["kb:command+a", "kb:control+c", "kb:turnover+h", "kb:upArrow", "kb:option+rightArrow", "kb:shift+f12", "kb:escape"] {
            guard let key = KeyboardGesture(identifier: name) else { Harness.fail("no gesture for \(name)"); continue }
            expect(key.logDescription(), key.identifier, name)
            expect(key.logDescription(secure: true), key.identifier, "password: \(name)")
        }
        expect(gesture(56).logDescription(), "kb:shift", "a modifier key alone remains identifiable")
    }

    test("privacy: a known browse command is named except in a password field") {
        let heading = gesture(4, [], "h")
        expect(heading.logDescription(commandName: "nextHeading"), "kb:h → nextHeading")
        expect(heading.logDescription(commandName: "nextHeading", secure: true), "(a typed key)")
        expect(heading.logDescription(), "(a typed key)", "without a resolved script the letter stays private")
        let navigation = gesture(126, .turnover)
        expect(navigation.logDescription(commandName: "readLine", secure: true), "kb:turnover+upArrow → readLine")
    }
}
