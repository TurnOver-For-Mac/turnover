// SPDX-License-Identifier: GPL-3.0-or-later
// The plain signs in a store entry that an add-on is not for the Mac. One small table, easy to add to: each row is a reason, in a
// few words, and the words in a name or description that give it. Matching ignores case and matches whole words or phrases.
// Only "not for the Mac" is ever decided here: the list alone never says an add-on can be converted.
import Foundation

nonisolated public enum ConvertSigns {
    public struct Sign: Sendable { public let reason: String; public let words: [String] }

    public static let table: [Sign] = [
        Sign(reason: "a speech synthesizer; TurnOver's voices are its own", words: ["synthesizer", "synthesiser", "synth driver", "speech synth", "text-to-speech engine", "text to speech engine", "sapi", "sapi4", "sapi5", "onecore", "espeak", "rhvoice"]),
        Sign(reason: "a braille display driver; braille is TurnOver's own", words: ["braille display driver", "braille driver", "braille display support", "braille display"]),
        Sign(reason: "remote access to another computer", words: ["nvda remote", "remote access", "remote desktop", "remote control", "remote nvda"]),
        Sign(reason: "names Notepad++, which is Windows only", words: ["notepad++"]),
        Sign(reason: "names Windows Explorer, which is Windows only", words: ["windows explorer", "file explorer"]),
        Sign(reason: "names Outlook for Windows", words: ["outlook for windows", "classic outlook"]),
        Sign(reason: "names Windows 10 or 11", words: ["windows 10", "windows 11", "windows 8", "windows 7", "windows defender", "windows terminal", "windows registry"]),
        Sign(reason: "names a Windows-only program", words: ["foobar2000", "winamp", "visual studio", "microsoft access", "internet explorer"]),
    ]

    /// The reason an entry is not for the Mac, or nil. Looks at the name, id and description.
    public static func notForMac(name: String, id: String, description: String) -> String? {
        let text = " " + [name, id, description].joined(separator: " ").lowercased() + " "
        for sign in table {
            for word in sign.words where contains(text, word) { return sign.reason }
        }
        return nil
    }

    static func contains(_ text: String, _ phrase: String) -> Bool {
        var start = text.startIndex
        while let r = text.range(of: phrase, range: start..<text.endIndex) {
            let before = r.lowerBound == text.startIndex ? " " : text[text.index(before: r.lowerBound)]
            let after = r.upperBound == text.endIndex ? " " : text[r.upperBound]
            func edge(_ c: Character) -> Bool { !(c.isLetter || c.isNumber) }
            // A phrase ending in a symbol (notepad++) needs no edge after it.
            if edge(before) && (edge(after) || !(phrase.last!.isLetter || phrase.last!.isNumber)) { return true }
            start = r.upperBound
        }
        return false
    }
}
