// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

func typingEchoTests() {
    test("typing: the new switches keep their defaults and survive a save") {
        var c = Config()
        expect(c.speech.deletedPitch, 0, "deleted is said unless a pitch is chosen")
        expect(c.keyboard.speakSpaceAfterWord, true)
        c.speech.deletedPitch = 30; c.keyboard.speakSpaceAfterWord = false
        let back = try? JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        expect(back?.speech.deletedPitch, 30)
        expect(back?.keyboard.speakSpaceAfterWord, false)
        let old = try? JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        expect(old?.speech.deletedPitch, 0, "a file from before the setting existed")
        expect(old?.keyboard.speakSpaceAfterWord, true)
    }
    test("typing: a space after a spoken word is not said when the switch is off") {
        let saved = (config.keyboard.speakTypedCharacters, config.keyboard.speakTypedWords, config.keyboard.speakSpaceAfterWord)
        defer { (config.keyboard.speakTypedCharacters, config.keyboard.speakTypedWords, config.keyboard.speakSpaceAfterWord) = saved }
        config.keyboard.speakTypedCharacters = .always; config.keyboard.speakTypedWords = .always
        let oldSink = Speech.sink; defer { Speech.sink = oldSink; MainActor.assumeIsolated { Speech.clearTypedWordBuffer() } }
        func typed(_ s: String) -> [String] {
            let said = Locked<[String]>([])
            return MainActor.assumeIsolated {
                Speech.sink = { said.value.append($0) }
                Speech.clearTypedWordBuffer()
                for ch in s { Speech.speakTypedCharacter(ch, inEditable: true, wordBefore: { String(s.dropLast()) }) }
                return said.value
            }
        }
        config.keyboard.speakSpaceAfterWord = true
        check(typed("hi ").contains("space"), "on: the space is said")
        config.keyboard.speakSpaceAfterWord = false
        check(!typed("hi ").contains("space"), "off: the word was the echo of the space")
        check(typed(" ").contains("space"), "off: a space on its own is still said")
    }
}
