// SPDX-License-Identifier: GPL-3.0-or-later
// Symbols and punctuation. Every symbol has a level; it is spoken by name when
// its level is at or below the user's setting (none, some, most, all, as screen
// readers commonly offer), otherwise it goes to the synthesizer as-is (a pause
// for a comma, nothing for a quote). A lone character is always named. The names
// are TurnOver's own: the plain English names, as macOS and VoiceOver use them.
import Foundation

nonisolated public enum Symbols {
    private struct Symbol { let name: String; let level: SymbolLevel }

    private static let table: [Character: Symbol] = [
        "#": .init(name: "number", level: .some), "%": .init(name: "percent", level: .some), "&": .init(name: "and", level: .some),
        "*": .init(name: "star", level: .some), "@": .init(name: "at", level: .some), "/": .init(name: "slash", level: .some),
        "\\": .init(name: "backslash", level: .some), "+": .init(name: "plus", level: .some), "=": .init(name: "equals", level: .some),
        "<": .init(name: "less than", level: .some), ">": .init(name: "greater than", level: .some), "^": .init(name: "caret", level: .some),
        "|": .init(name: "bar", level: .some), "~": .init(name: "tilde", level: .some), "`": .init(name: "grave", level: .some),
        "$": .init(name: "dollar", level: .some), "£": .init(name: "pound", level: .some), "€": .init(name: "euro", level: .some),
        "¥": .init(name: "yen", level: .some), "©": .init(name: "copyright", level: .some), "®": .init(name: "registered", level: .some),
        "™": .init(name: "trademark", level: .some), "°": .init(name: "degrees", level: .some), "§": .init(name: "section", level: .some),
        "¶": .init(name: "pilcrow", level: .some), "•": .init(name: "bullet", level: .some), "·": .init(name: "middle dot", level: .some),
        "\"": .init(name: "quote", level: .most), "'": .init(name: "apostrophe", level: .most), "‘": .init(name: "left single quote", level: .most),
        "’": .init(name: "right single quote", level: .most), "“": .init(name: "left quote", level: .most), "”": .init(name: "right quote", level: .most),
        "(": .init(name: "left paren", level: .most), ")": .init(name: "right paren", level: .most), "[": .init(name: "left bracket", level: .most),
        "]": .init(name: "right bracket", level: .most), "{": .init(name: "left brace", level: .most), "}": .init(name: "right brace", level: .most),
        "-": .init(name: "dash", level: .most), "–": .init(name: "en dash", level: .most), "—": .init(name: "em dash", level: .most),
        ":": .init(name: "colon", level: .most), ";": .init(name: "semicolon", level: .most), "_": .init(name: "underscore", level: .most),
        ",": .init(name: "comma", level: .all), ".": .init(name: "period", level: .all), "!": .init(name: "exclamation", level: .all),
        "?": .init(name: "question mark", level: .all), "…": .init(name: "ellipsis", level: .all),
    ]

    /// The name of one character, always (the caret-character and spelling rule).
    /// The name of one character, with "cap" before a capital when the setting says so (main thread: the setting).
    @MainActor public static func name(of c: Character) -> String {
        let n = name(of: c, sayCap: config.speech.sayCapForCapitals)
        // A capital with its pitch to be raised: marked for the speech queue, which strips the mark (Speech.enqueue).
        return c.isUppercase && config.speech.capitalPitch > 0 ? Speech.capitalMark + n : n
    }

    public static func name(of c: Character, sayCap: Bool) -> String {
        if let s = table[c] { return s.name }
        switch c {
        case " ": return "space"
        case "\u{a0}": return "space"   // a non-breaking space: to the listener, a space
        case "\r", "\n", "\u{2029}", "\r\n": return "new line"
        case "\u{b}", "\u{2028}": return "line break"
        case "\u{c}": return "page break"
        case "\t": return "tab"
        case "\u{8}": return "backspace"
        default:
            if c.isUppercase, sayCap { return "cap " + c.lowercased() }
            return String(c)
        }
    }

    /// Text for reading: symbols at or below `level` are replaced by their names.
    public static func process(_ text: String, level: SymbolLevel) -> String {
        guard level != .none else { return text }
        // A dot between words is a separator, said as a pause, not "bullet": Byword's status line, "Markdown • 61
        // words • 356 characters" (Day 2, 10 Oct 2026). A bullet at the start of a line, or alone, keeps its name.
        if level != .all, text.contains(" • ") || text.contains(" · ") {
            return process(text.replacingOccurrences(of: " • ", with: ", ").replacingOccurrences(of: " · ", with: ", "), level: level)
        }
        var out = ""
        out.reserveCapacity(text.count + 16)
        var lastWasName = false
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            // A tick between two letters is an apostrophe (I’m, don't): a word's part, named only at "all".
            let isApostrophe = (c == "’" || c == "'") && i > 0 && i + 1 < chars.count && chars[i - 1].isLetter && chars[i + 1].isLetter
            let effective = isApostrophe ? SymbolLevel.all : (table[c]?.level ?? .all)
            if let s = table[c], effective.rawValue <= level.rawValue {
                if !out.isEmpty, out.last != " " { out.append(" ") }
                out.append(s.name)
                lastWasName = true
            } else {
                if lastWasName, c != " " { out.append(" ") }
                out.append(c)
                lastWasName = false
            }
        }
        return out
    }

    /// True when the text has nothing but symbols and whitespace: spoken by name whatever the level.
    public static func isAllSymbols(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t.allSatisfy { $0.isPunctuation || $0.isSymbol }
    }

    /// Spelled out: every character by name.
    @MainActor public static func spelled(_ text: String) -> String {
        text.map { name(of: $0) }.joined(separator: ", ")
    }
}
