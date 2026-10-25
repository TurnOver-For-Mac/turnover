// SPDX-License-Identifier: GPL-3.0-or-later
// Phrases spoken in many places, each one translatable string (Resources/Localizable.xcstrings, 23 Oct 2026): other
// languages put the parts in another order ("3 of 9" is "3/9" in Turkish). Numbers go in as text, so English stays as
// it was: String(localized:) formats a number for the Mac's region ("1,234", "3.500000").
import Foundation

nonisolated public enum Phrases {
    /// "3 of 9": an item's place among the others.
    public static func position(_ index: Int, of count: Int) -> String {
        String(localized: "\(String(index)) of \(String(count))", comment: "An item's position among the others: 3 of 9")
    }

    /// Whether words are a position as `position` says it ("3 of 9"), in the reader's language.
    public static func isPosition(_ words: String) -> Bool {
        let numbers = words.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        return numbers.count == 2 && words == position(numbers[0], of: numbers[1])
    }

    /// "level 2": how deep an item is (an outline's rows, a list inside a list).
    public static func level(_ level: Int) -> String {
        String(localized: "level \(String(level))", comment: "How deep an item is, in an outline or a nested list")
    }

    /// "heading level 2".
    public static func headingLevel(_ level: Int) -> String {
        String(localized: "heading level \(String(level))", comment: "A heading's level: heading level 2")
    }

    /// "page 4": where the caret is in a document.
    public static func page(_ n: Int) -> String { String(localized: "page \(String(n))", comment: "A page number in a document") }

    /// "row 3" and "column 2": a table cell's coordinates.
    public static func row(_ n: Int) -> String { String(localized: "row \(String(n))", comment: "A table cell's row number") }
    public static func column(_ n: Int) -> String { String(localized: "column \(String(n))", comment: "A table cell's column number") }

    /// "1 character", "12 characters".
    public static func characters(_ count: Int) -> String {
        count == 1 ? String(localized: "1 character", comment: "A count of characters (a password's, a long text's)")
            : String(localized: "\(String(count)) characters", comment: "A count of characters (a password's, a long text's)")
    }

    /// "1 item", "5 items".
    public static func items(_ count: Int) -> String {
        count == 1 ? String(localized: "1 item", comment: "A count of items in a list or table")
            : String(localized: "\(String(count)) items", comment: "A count of items in a list or table")
    }

    /// A language by name ("English (United Kingdom)" for "en_GB"), in the language TurnOver speaks: British English
    /// names in English, as before.
    public static func languageName(_ identifier: String) -> String {
        let reader = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale(identifier: reader == "en" ? "en_GB" : reader).localizedString(forIdentifier: identifier) ?? identifier
    }

    /// "no next heading", "no previous link": nothing more of a kind that way.
    public static func noNext(_ kind: String, forward: Bool) -> String {
        forward ? String(localized: "no next \(kind)", comment: "Nothing more of a kind ahead: %@ is the kind (heading)")
            : String(localized: "no previous \(kind)", comment: "Nothing more of a kind behind: %@ is the kind (heading)")
    }

    /// " and ", between the names in a list ("Mail and Safari").
    public static var and: String { String(localized: " and ", comment: "Between names in a list, with its spaces") }

    /// "deleted more": text deleted, as typing echo says it.
    public static func deleted(_ text: String) -> String { String(localized: "deleted \(text)", comment: "Text deleted: %@ is the text") }

    /// "45 percent".
    public static func percent(_ n: Int) -> String { String(localized: "\(String(n)) percent", comment: "A percentage: 45 percent") }

    /// "on" or "off", as a setting is.
    public static func onOff(_ on: Bool) -> String { on ? State.on.displayString : State.off.displayString }

    /// "rate 55": the speech rate, as a percentage.
    public static func rate(_ percent: Int) -> String {
        String(localized: "rate \(String(percent))", comment: "The speech rate changed: %@ is the new rate, out of 100")
    }

    /// "blank": nothing there (an empty line, a field with nothing in it).
    public static var blank: String { String(localized: "blank", comment: "Nothing there: an empty line, an empty field") }
}
