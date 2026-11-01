// SPDX-License-Identifier: GPL-3.0-or-later
// What text looks like on the display: macOS's own braille translation (the tables VoiceOver offers: Unified English
// contracted by default, as UK readers expect), with the word at the cursor uncontracted while editing so each
// letter can be checked and routed to (NVDA's "expand to computer braille for the word at the cursor"). Without
// the system translator, TurnOver's own computer braille.
import Foundation
import TurnOverBraille

public enum BrailleOutput {
    /// The table in use: the one chosen, or the system's contracted default for the user's language.
    public static var tableIdentifier: String? {
        if !config.braille.table.isEmpty { return config.braille.table }
        return TOBrailleTranslator.defaultTable(forLocale: Locale.current.identifier, contracted: true)
    }

    /// Cells, and for each the offset in `text` it shows.
    static func translate(_ text: String, cursor: Int?) -> (cells: [UInt8], map: [Int]) {
        guard !text.isEmpty else { return ([], []) }
        guard let id = tableIdentifier, let tr = TOBrailleTranslator(forTable: id) else { return computer(text) }
        let ns = text as NSString
        // The word under the cursor, uncontracted, while there is a cursor (editing, browse mode's caret).
        if config.braille.expandAtCursor, let c = cursor, c <= ns.length, let word = wordRange(in: ns, at: c), word.length > 0,
           let plainID = uncontracted(id), plainID != id, let plain = TOBrailleTranslator(forTable: plainID) {
            var cells: [UInt8] = [], map: [Int] = []
            for (part, translator) in [(NSRange(location: 0, length: word.location), tr), (word, plain),
                                       (NSRange(location: NSMaxRange(word), length: ns.length - NSMaxRange(word)), tr)] where part.length > 0 {
                let (c2, m2) = run(translator, ns.substring(with: part))
                cells += c2; map += m2.map { $0 + part.location }
            }
            return (cells, map)
        }
        return run(tr, text)
    }

    private static func run(_ tr: TOBrailleTranslator, _ text: String) -> (cells: [UInt8], map: [Int]) {
        var loc: NSArray?
        let braille = tr.braille(forText: text, locations: &loc)
        let cells = braille.unicodeScalars.map { s -> UInt8 in (0x2800...0x28FF).contains(s.value) ? UInt8(s.value - 0x2800) : 0 }
        var map = (loc as? [NSNumber])?.map(\.intValue) ?? []
        if map.count != cells.count { map = (0..<cells.count).map { min($0, max(0, (text as NSString).length - 1)) } }
        return (cells, map)
    }

    private static func computer(_ text: String) -> (cells: [UInt8], map: [Int]) {
        let cells = BrailleTable.cells(for: text)
        return (cells, Array(0..<cells.count))
    }

    /// The same table without contractions: "…eng-xueb_g2" → "…eng-xueb_g1".
    static func uncontracted(_ id: String) -> String? {
        id.hasSuffix("_g2") ? String(id.dropLast(3)) + "_g1" : nil
    }

    private static func wordRange(in s: NSString, at c: Int) -> NSRange? {
        func isWord(_ i: Int) -> Bool {
            guard i >= 0, i < s.length, let u = UnicodeScalar(s.character(at: i)) else { return false }
            return CharacterSet.alphanumerics.contains(u) || u == "'" || u == "\u{2019}"
        }
        var a = c, b = c
        if !isWord(c) { if isWord(c - 1) { a = c - 1; b = c - 1 } else { return nil } }
        while isWord(a - 1) { a -= 1 }
        while isWord(b) { b += 1 }
        return NSRange(location: a, length: b - a)
    }

    /// Braille typed on the display's keyboard, as text: the output table, or its uncontracted form.
    public static func backTranslate(_ cells: [UInt8], contracted: Bool) -> String {
        let braille = String(String.UnicodeScalarView(cells.compactMap { UnicodeScalar(0x2800 + UInt32($0)) }))
        guard let out = tableIdentifier else { return "" }
        let id = contracted ? out : (uncontracted(out) ?? out)
        guard let tr = TOBrailleTranslator(forTable: id) else { return "" }
        return tr.text(forBraille: braille)
    }
}

/// The braille tables for the user's language, for the TurnOver menu: macOS's tables, one entry per name (the same
/// code comes from several translators; the system's own come first).
public enum TOBrailleTranslatorTables {
    static func forUser() -> [(id: String, name: String)] {
        var seen = Set<String>(), out: [(String, String)] = []
        for pair in TOBrailleTranslator.tables(forLocale: Locale.current.identifier) where pair.count == 2 {
            if seen.insert(pair[1]).inserted { out.append((pair[0], pair[1])) }
        }
        return out
    }

    /// Every other language macOS has tables for, by name, each with its tables (a tester, 6 Oct 2026: his Mac is in
    /// English and he reads Slovenian braille). Read when the menu opens.
    public static func otherLanguages() -> [(language: String, tables: [(id: String, name: String)])] {
        let mine = Locale.current.language.languageCode?.identifier ?? "en"
        var langs = Set<String>()
        for id in Locale.availableIdentifiers { if let l = Locale(identifier: id).language.languageCode?.identifier, l != mine { langs.insert(l) } }
        var out: [(String, [(String, String)])] = []
        for l in langs {
            var seen = Set<String>(), tables: [(String, String)] = []
            for pair in TOBrailleTranslator.tables(forLocale: l) where pair.count == 2 {
                if seen.insert(pair[1]).inserted { tables.append((pair[0], pair[1])) }
            }
            // A language whose list is only English (macOS's fallback) has no tables of its own.
            if !tables.isEmpty, !tables.allSatisfy({ $0.1.lowercased().contains("english") }) {
                out.append((Locale.current.localizedString(forLanguageCode: l) ?? l, tables))
            }
        }
        return out.sorted { $0.0 < $1.0 }
    }
}
