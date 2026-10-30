// SPDX-License-Identifier: GPL-3.0-or-later
// Tables in a Cocoa text view (TextEdit's tables, a tester, 14 Oct 2026: "not detected at all"). TextEdit
// marks them in its attributed text: AXTextTable over the whole table, and on each cell AXTextTableCell with AXRow
// and AXCol (from 0) and their spans (probed 14 Oct 2026). TurnOver said none of it. Now, as NVDA does on a caret
// move: entering, "table with 2 rows and 2 columns, row 1, column 1"; moving, what changed ("row 2", "column 1");
// leaving, "out of table". Before the line or character is read.
import Foundation
import ApplicationServices
import TurnOverAX

public enum TextTables {
    /// Where the caret is: the table (its character range and size) and the cell.
    public struct Place: Equatable {
        public var table: NSRange
        public var rows: Int, columns: Int
        public var row: Int, column: Int
        public init(table: NSRange, rows: Int, columns: Int, row: Int, column: Int) {
            self.table = table; self.rows = rows; self.columns = columns; self.row = row; self.column = column
        }
    }

    /// With tables reported by a sound (the "tone" setting, as web pages do): the sound marks entering and
    /// leaving, and the row and column are still said, as NVDA's cell coordinates are (the maintainer's Mac, 14 Oct 2026).
    nonisolated public static func newsWithTone(from last: Place?, to now: Place?) -> (tone: Bool, words: String?) {
        switch (last, now) {
        case (nil, nil): return (false, nil)
        case (.some, nil): return (true, nil)
        case (let l, .some(let n)):
            guard let l, l.table == n.table else { return (true, "\(Phrases.row(n.row + 1)), \(Phrases.column(n.column + 1))") }
            return (false, news(from: l, to: n))
        }
    }

    /// The words for moving from `last` to `now` (nil: outside a table). Pure.
    nonisolated public static func news(from last: Place?, to now: Place?) -> String? {
        switch (last, now) {
        case (nil, nil): return nil
        case (.some, nil): return String(localized: "out of table", comment: "The caret left a table")
        case (let l, .some(let n)):
            let cell = "\(Phrases.row(n.row + 1)), \(Phrases.column(n.column + 1))"
            guard let l, l.table == n.table else {
                let rows = n.rows == 1 ? String(localized: "1 row", comment: "A table's size") : String(localized: "\(String(n.rows)) rows", comment: "A table's size")
                let columns = n.columns == 1 ? String(localized: "1 column", comment: "A table's size") : String(localized: "\(String(n.columns)) columns", comment: "A table's size")
                return String(localized: "table with \(rows) and \(columns), \(cell)", comment: "A table entered: its rows, its columns, then the cell")
            }
            if l.row != n.row && l.column != n.column { return cell }
            if l.row != n.row { return Phrases.row(n.row + 1) }
            if l.column != n.column { return Phrases.column(n.column + 1) }
            return nil
        }
    }

    /// The text element the caret moved in, and where the caret was last time in it.
    private static var last: (element: AXUIElement, place: Place?)?
    /// The table found last, so a move inside it reads one character's marks, not the whole table again.
    private static var known: (element: AXUIElement, table: NSRange, rows: Int, columns: Int)?

    /// What to say for the caret now at `offset` in `element` (nil: nothing). Reads one character's marks; the
    /// table's size only when entering one.
    /// Says it: words, or with the tone setting the table sound and the cell.
    static func report(element: AXUIElement, offset: Int, length: Int, tone: Bool) {
        let now = place(element: element, offset: offset, length: length)
        let before = last.flatMap { $0.element.isSame(element) ? $0.place : nil }
        // Another text area: no "out of table" for the one left behind (the focus news says where you are).
        if let l = last, !l.element.isSame(element), now == nil { last = (element, nil); return }
        last = (element, now)
        if tone {
            let (sound, words) = newsWithTone(from: before, to: now)
            if sound { Tones.table() }
            if let words { Speech.speakMessage(words) }
        } else if let words = news(from: before, to: now) {
            Speech.speakMessage(words)
        }
    }

    private static func place(element: AXUIElement, offset: Int, length: Int) -> Place? {
        guard length > 0 else { return nil }
        let at = min(max(0, offset), length - 1)
        guard let one = element.param(kAXAttributedStringForRangeParameterizedAttribute, axRangeValue(at, 1)) as? NSAttributedString,
              one.length > 0 else { return nil }
        let marks = one.attributes(at: 0, effectiveRange: nil)
        guard (marks[NSAttributedString.Key("AXTextTable")] as? NSNumber)?.boolValue == true,
              let cell = marks[NSAttributedString.Key("AXTextTableCell")] as? [String: Any],
              let row = (cell["AXRow"] as? NSNumber)?.intValue, let col = (cell["AXCol"] as? NSNumber)?.intValue else { return nil }
        if let k = known, k.element.isSame(element), NSLocationInRange(at, k.table) {
            return Place(table: k.table, rows: k.rows, columns: k.columns, row: row, column: col)
        }
        // Entering a table: its extent and size from the marks around the caret (at most 50,000 characters each way).
        let from = max(0, at - 50_000), to = min(length, at + 50_000)
        guard let around = element.param(kAXAttributedStringForRangeParameterizedAttribute, axRangeValue(from, to - from)) as? NSAttributedString else { return nil }
        var table = NSRange(location: NSNotFound, length: 0)
        _ = around.attribute(NSAttributedString.Key("AXTextTable"), at: at - from, longestEffectiveRange: &table, in: NSRange(location: 0, length: around.length))
        guard table.location != NSNotFound else { return nil }
        var rows = 0, columns = 0
        around.enumerateAttribute(NSAttributedString.Key("AXTextTableCell"), in: table) { v, _, _ in
            guard let c = v as? [String: Any] else { return }
            let r = ((c["AXRow"] as? NSNumber)?.intValue ?? 0) + ((c["AXRowSpan"] as? NSNumber)?.intValue ?? 1)
            let k = ((c["AXCol"] as? NSNumber)?.intValue ?? 0) + ((c["AXColSpan"] as? NSNumber)?.intValue ?? 1)
            rows = max(rows, r); columns = max(columns, k)
        }
        let absolute = NSRange(location: table.location + from, length: table.length)
        known = (element, absolute, rows, columns)
        Log.io("table: \(rows) by \(columns) at \(absolute.location)-\(NSMaxRange(absolute))")
        return Place(table: absolute, rows: rows, columns: columns, row: row, column: col)
    }
}
