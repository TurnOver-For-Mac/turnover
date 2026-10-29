// SPDX-License-Identifier: GPL-3.0-or-later
// Symbols and punctuation. Every symbol has a level; it is spoken by name when
// its level is at or below the user's setting (none, some, most, all, as screen
// readers commonly offer), otherwise it goes to the synthesizer as-is (a pause
// for a comma, nothing for a quote). A lone character is always named. The names
// are TurnOver's own: the plain English names, as macOS and VoiceOver use them.
import Foundation
import Carbon
import NaturalLanguage

nonisolated public enum Symbols {
    private struct Symbol { let name: String; let level: SymbolLevel }

    private static let table: [Character: Symbol] = [
        "#": .init(name: String(localized: "symbol.number", defaultValue: "number", comment: "The symbol #"), level: .some), "%": .init(name: String(localized: "symbol.percent", defaultValue: "percent", comment: "The symbol %"), level: .some), "&": .init(name: String(localized: "symbol.and", defaultValue: "and", comment: "The symbol &"), level: .some),
        "*": .init(name: String(localized: "symbol.star", defaultValue: "star", comment: "The symbol *"), level: .some), "@": .init(name: String(localized: "symbol.at", defaultValue: "at", comment: "The symbol @"), level: .some), "/": .init(name: String(localized: "symbol.slash", defaultValue: "slash", comment: "The symbol /"), level: .some),
        "\\": .init(name: String(localized: "symbol.backslash", defaultValue: "backslash", comment: "The symbol \\"), level: .some), "+": .init(name: String(localized: "symbol.plus", defaultValue: "plus", comment: "The symbol +"), level: .some), "=": .init(name: String(localized: "symbol.equals", defaultValue: "equals", comment: "The symbol ="), level: .some),
        "<": .init(name: String(localized: "symbol.less than", defaultValue: "less than", comment: "The symbol <"), level: .some), ">": .init(name: String(localized: "symbol.greater than", defaultValue: "greater than", comment: "The symbol >"), level: .some), "^": .init(name: String(localized: "symbol.caret", defaultValue: "caret", comment: "The symbol ^"), level: .some),
        "|": .init(name: String(localized: "symbol.bar", defaultValue: "bar", comment: "The symbol |"), level: .some), "~": .init(name: String(localized: "symbol.tilde", defaultValue: "tilde", comment: "The symbol ~"), level: .some), "`": .init(name: String(localized: "symbol.grave", defaultValue: "grave", comment: "The symbol `"), level: .some),
        "$": .init(name: String(localized: "symbol.dollar", defaultValue: "dollar", comment: "The symbol $"), level: .some), "£": .init(name: String(localized: "symbol.pound", defaultValue: "pound", comment: "The symbol £"), level: .some), "€": .init(name: String(localized: "symbol.euro", defaultValue: "euro", comment: "The symbol €"), level: .some),
        "¥": .init(name: String(localized: "symbol.yen", defaultValue: "yen", comment: "The symbol ¥"), level: .some), "©": .init(name: String(localized: "symbol.copyright", defaultValue: "copyright", comment: "The symbol ©"), level: .some), "®": .init(name: String(localized: "symbol.registered", defaultValue: "registered", comment: "The symbol ®"), level: .some),
        "™": .init(name: String(localized: "symbol.trademark", defaultValue: "trademark", comment: "The symbol ™"), level: .some), "°": .init(name: String(localized: "symbol.degrees", defaultValue: "degrees", comment: "The symbol °"), level: .some), "§": .init(name: String(localized: "symbol.section", defaultValue: "section", comment: "The symbol §"), level: .some),
        "¶": .init(name: String(localized: "symbol.pilcrow", defaultValue: "pilcrow", comment: "The symbol ¶"), level: .some), "•": .init(name: String(localized: "symbol.bullet", defaultValue: "bullet", comment: "The symbol •"), level: .some), "·": .init(name: String(localized: "symbol.middle dot", defaultValue: "middle dot", comment: "The symbol ·"), level: .some),
        "\"": .init(name: String(localized: "symbol.quote", defaultValue: "quote", comment: "The symbol \""), level: .most), "'": .init(name: String(localized: "symbol.apostrophe", defaultValue: "apostrophe", comment: "The symbol '"), level: .most), "‘": .init(name: String(localized: "symbol.left single quote", defaultValue: "left single quote", comment: "The symbol ‘"), level: .most),
        "’": .init(name: String(localized: "symbol.right single quote", defaultValue: "right single quote", comment: "The symbol ’"), level: .most), "“": .init(name: String(localized: "symbol.left quote", defaultValue: "left quote", comment: "The symbol “"), level: .most), "”": .init(name: String(localized: "symbol.right quote", defaultValue: "right quote", comment: "The symbol ”"), level: .most),
        "(": .init(name: String(localized: "symbol.left paren", defaultValue: "left paren", comment: "The symbol ("), level: .most), ")": .init(name: String(localized: "symbol.right paren", defaultValue: "right paren", comment: "The symbol )"), level: .most), "[": .init(name: String(localized: "symbol.left bracket", defaultValue: "left bracket", comment: "The symbol ["), level: .most),
        "]": .init(name: String(localized: "symbol.right bracket", defaultValue: "right bracket", comment: "The symbol ]"), level: .most), "{": .init(name: String(localized: "symbol.left brace", defaultValue: "left brace", comment: "The symbol {"), level: .most), "}": .init(name: String(localized: "symbol.right brace", defaultValue: "right brace", comment: "The symbol }"), level: .most),
        "-": .init(name: String(localized: "symbol.dash", defaultValue: "dash", comment: "The symbol -"), level: .most), "–": .init(name: String(localized: "symbol.en dash", defaultValue: "en dash", comment: "The symbol –"), level: .most), "—": .init(name: String(localized: "symbol.em dash", defaultValue: "em dash", comment: "The symbol —"), level: .most),
        ":": .init(name: String(localized: "symbol.colon", defaultValue: "colon", comment: "The symbol :"), level: .most), ";": .init(name: String(localized: "symbol.semicolon", defaultValue: "semicolon", comment: "The symbol ;"), level: .most), "_": .init(name: String(localized: "symbol.underscore", defaultValue: "underscore", comment: "The symbol _"), level: .most),
        ",": .init(name: String(localized: "symbol.comma", defaultValue: "comma", comment: "The symbol ,"), level: .all), ".": .init(name: String(localized: "symbol.period", defaultValue: "period", comment: "The symbol ."), level: .all), "!": .init(name: String(localized: "symbol.exclamation", defaultValue: "exclamation", comment: "The symbol !"), level: .all),
        "?": .init(name: String(localized: "symbol.question mark", defaultValue: "question mark", comment: "The symbol ?"), level: .all), "…": .init(name: String(localized: "symbol.ellipsis", defaultValue: "ellipsis", comment: "The symbol …"), level: .all),
    ]

    /// The name of one character, always (the caret-character and spelling rule).
    /// The name of one character, with "cap" before a capital when the setting says so (main thread: the setting).
    /// `locale`: the language the letter is in, for lowering a capital (`letterLocale`); nil, TurnOver's own.
    @MainActor public static func name(of c: Character, locale: Locale? = nil) -> String {
        let n = name(of: c, sayCap: config.speech.sayCapForCapitals, locale: locale)
        // A capital with its pitch to be raised: marked for the speech queue, which strips the mark (Speech.enqueue).
        return c.isUppercase && config.speech.capitalPitch > 0 ? Speech.capitalMark + n : n
    }

    /// The language TurnOver's own words are in (the catalog's, from the Mac's language): a capital's letter is lowered
    /// by its rules when nothing says what language the letter itself is in.
    nonisolated public static var interfaceLocale: Locale { Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en") }

    // The language a capital's letter is lowered in (Oliver's review of PR 123, 29 Oct 2026: an English text read by a
    // Turkish TurnOver said dotless ı for I). Typing, the keyboard layout's language: Turkish Q and F type Turkish.
    // Moving through text, the text's own language, when the line says it clearly enough. Else TurnOver's language.

    /// The keyboard layout's language, from the input source in use (Turkish Q and Turkish F are "tr").
    @MainActor public static var typingLocale: Locale? {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages) else { return nil }
        return typingLocale(layoutLanguages: Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String] ?? [])
    }
    /// The first of a layout's languages (the one it is for), or nil when it names none.
    public static func typingLocale(layoutLanguages: [String]) -> Locale? { layoutLanguages.first.map { Locale(identifier: $0) } }

    /// The language of a line of text, when it is long enough and recognised with confidence; nil otherwise.
    public static func textLocale(_ text: String) -> Locale? {
        guard text.filter(\.isLetter).count >= 12 else { return nil }
        let r = NLLanguageRecognizer()
        r.processString(String(text.prefix(400)))
        guard let (language, p) = r.languageHypotheses(withMaximum: 1).first, p >= 0.8 else { return nil }
        return Locale(identifier: language.rawValue)
    }

    /// A capital lowered by its language's rules: in Turkish I is ı and İ is i, where lowercased(), which ignores the
    /// language, makes both i (a tester building PR 123 with JAWS fixes, 28 Oct 2026).
    public static func lowered(_ c: Character, locale: Locale = interfaceLocale) -> String { lowered(String(c), locale: locale) }
    /// Words lowered or raised by the same rules, for words said in the interface's language (an App Store count,
    /// the Keyboard Commander's letters).
    public static func lowered(_ s: String, locale: Locale = interfaceLocale) -> String { s.lowercased(with: locale) }
    public static func raised(_ s: String, locale: Locale = interfaceLocale) -> String { s.uppercased(with: locale) }

    public static func name(of c: Character, sayCap: Bool, locale: Locale? = nil) -> String {
        if let s = table[c] { return s.name }
        switch c {
        case " ": return String(localized: "symbol.space", defaultValue: "space", comment: "The space character")
        case "\u{a0}": return String(localized: "symbol.space", defaultValue: "space", comment: "The space character")   // a non-breaking space: to the listener, a space
        case "\r", "\n", "\u{2029}", "\r\n": return String(localized: "new line", comment: "A line ending, spoken as a character")
        case "\u{b}", "\u{2028}": return String(localized: "line break", comment: "A line break inside a paragraph, spoken as a character")
        case "\u{c}": return String(localized: "page break", comment: "A page break, spoken as a character")
        case "\t": return String(localized: "symbol.tab", defaultValue: "tab", comment: "The tab character")
        case "\u{8}": return String(localized: "key.backspace", defaultValue: "backspace", comment: "A key's name")
        default:
            if c.isUppercase, sayCap { return String(localized: "cap \(lowered(c, locale: locale ?? interfaceLocale))", comment: "A capital letter: %@ is the letter") }
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
