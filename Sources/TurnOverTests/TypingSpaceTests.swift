// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

func typingSpaceTests() {
    test("typing: after a word said as the space is typed, VoiceOver's keys do not say space; NVDA's and JAWS's do") {
        let saved = (config.keyboard.speakTypedCharacters, config.keyboard.speakTypedWords, config.general.keyboardStyle)
        defer { (config.keyboard.speakTypedCharacters, config.keyboard.speakTypedWords, config.general.keyboardStyle) = saved }
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
        config.general.keyboardStyle = KeyboardStyle.voiceOver.rawValue
        check(!typed("hi ").contains("space"), "VoiceOver keys: the word was the echo of the space")
        check(typed(" ").contains("space"), "VoiceOver keys: a space on its own is still said")
        config.general.keyboardStyle = KeyboardStyle.nvda.rawValue
        check(typed("hi ").contains("space"), "NVDA keys: the space is said after the word")
    }
}
