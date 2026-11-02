// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import AppKit

/// A cell of a Word table. Word exposes real tables (AXTable, AXRow, AXCell, with AXRowIndexRange and
/// AXColumnIndexRange), each cell's text its own text area that takes the focus as the caret enters it, so Tab,
/// the arrows and clicks all arrive as focus changes. NVDA's table reading: say what changed (entering: the table's
/// size; then row and column), the column's title (the first row's text) and the row's title (the first column's,
/// as in a form: "Telephone"), then the text, or "blank"; "selected" when Tab selected the whole cell, as typing
/// then replaces it. TurnOver plus the arrows go cell to cell with the caret at the start, nothing selected.
/// (4 Oct 2026: this replaced asking Word by AppleScript, which took 150 ms a cell and hung with the Automation
/// alert unanswered.)
final class WordTableCell: WordTextArea {
    struct Place { let table: AXUIElement; let row: Int; let column: Int }
    /// The last cell spoken, to say only what changed; nil once the focus leaves the tables.
    static var last: Place?
    /// The last table spoken and when: its size is said once, not after every focus bounce through the page.
    static var lastTable: (AXUIElement, Date)?

    static func cell(of e: AXUIElement) -> AXUIElement? {
        // Up to six parents (asked for it; two missed the cells of later tables, which sit deeper: a tester,
        // 19 Oct 2026, "only the first table is navigable"). Stops at the table, the window or the page.
        var p = e.element(kAXParentAttribute)
        for _ in 0..<6 {
            guard let x = p else { return nil }
            if x.role == "AXCell" { return x }
            if x.role == "AXTable" || x.role == "AXWindow" || WordAppModule.isPageArea(x) { return nil }
            p = x.element(kAXParentAttribute)
        }
        return nil
    }
    var place: Place? {
        guard let c = Self.cell(of: element), let row = c.element(kAXParentAttribute), let table = row.element(kAXParentAttribute),
              table.role == "AXTable", let r = cfRange(c.attr("AXRowIndexRange")), let col = cfRange(c.attr("AXColumnIndexRange")) else { return nil }
        return Place(table: table, row: r.location, column: col.location)
    }
    /// The text area of a cell (rows and columns from 0).
    static func textArea(_ table: AXUIElement, row: Int, column: Int) -> AXUIElement? {
        guard row >= 0, column >= 0, let c = table.param("AXCellForColumnAndRow", [column, row] as CFArray),
              CFGetTypeID(c) == AXUIElementGetTypeID() else { return nil }
        return (c as! AXUIElement).firstDescendant(role: "AXTextArea", maxVisited: 6)
    }
    static func text(of area: AXUIElement) -> String {
        (area.string(kAXValueAttribute) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\r\n\u{7}").union(.whitespaces))
    }

    override func reportFocus() { Speech.speakMessage(describe()) }

    func describe() -> String {
        let t = Self.text(of: element)
        guard let p = place else { return t.isEmpty ? "blank" : t }
        let old = Self.last
        Self.last = p
        // The same table within a few seconds (Word hands the focus to the page between cells, which clears `last`):
        // its size is not news again (it was said at every cell, a tester's log, 8 Oct 2026).
        let sameTable = old.map { $0.table.isSame(p.table) } ?? (Self.lastTable.map { $0.0.isSame(p.table) && Date().timeIntervalSince($0.1) < 10 } ?? false)
        Self.lastTable = (p.table, Date())
        var parts: [String] = []
        if !sameTable {
            let rows = (p.table.attr("AXRowCount") as? Int) ?? p.table.elements("AXRows").count
            let columns = (p.table.attr("AXColumnCount") as? Int) ?? p.table.elements("AXColumns").count
            parts.append(String(localized: "table with \(String(rows)) rows and \(String(columns)) columns", comment: "A Word table reached: its size"))
        }
        // Back in the same table within the 10 s, but with no last cell (the focus went to the page between): row and
        // column are news. The force-unwrap here crashed TurnOver in a 201-row table (a tester, 12 Oct 2026).
        let rowChanged = !sameTable || (old.map { $0.row != p.row } ?? true)
        let columnChanged = !sameTable || (old.map { $0.column != p.column } ?? true)
        let coords = config.documentFormatting.tableCellCoordinates
        if rowChanged, coords { parts.append(Phrases.row(p.row + 1)) }
        if columnChanged, coords { parts.append(Phrases.column(p.column + 1)) }
        if config.documentFormatting.tableHeaders, columnChanged, p.row > 0, let h = Self.textArea(p.table, row: 0, column: p.column).map(Self.text(of:)), !h.isEmpty { parts.append(h) }
        if config.documentFormatting.tableHeaders, rowChanged, p.row > 0, p.column > 0, let h = Self.textArea(p.table, row: p.row, column: 0).map(Self.text(of:)), !h.isEmpty { parts.append(h) }
        parts.append(t.isEmpty ? Phrases.blank : t)
        if !t.isEmpty, let sel = cfRange(element.attr(kAXSelectedTextRangeAttribute)), sel.length > 0, sel.length >= t.count { parts.append(State.selected.displayString) }
        return parts.joined(separator: ", ")
    }

    override func initOverlay() {
        super.initOverlay()
        let cat = "Microsoft Word"
        for (name, dr, dc, keys) in [("table_nextColumn", 0, 1, [String]()), ("table_previousColumn", 0, -1, []),
                                     ("table_nextRow", 1, 0, ["kb:turnover+downArrow"]), ("table_previousRow", -1, 0, ["kb:turnover+upArrow"])] {
            let description = dr == 0 ? (dc > 0 ? String(localized: "In a table: the next cell in the row, the caret at its start (NVDA's table keys; TurnOver plus the arrows)", comment: "A command, as the key list and keyboard help say it")
                                                : String(localized: "In a table: the previous cell in the row, the caret at its start (NVDA's table keys; TurnOver plus the arrows)", comment: "A command, as the key list and keyboard help say it"))
                : (dr > 0 ? String(localized: "In a table: the cell below, the caret at its start (NVDA's table keys; TurnOver plus the arrows)", comment: "A command, as the key list and keyboard help say it")
                          : String(localized: "In a table: the cell above, the caret at its start (NVDA's table keys; TurnOver plus the arrows)", comment: "A command, as the key list and keyboard help say it"))
            script(name, description, gestures: keys, category: cat) { [weak self] _ in
                self?.move(dr, dc)
            }
        }
    }

    func move(_ dr: Int, _ dc: Int) {
        guard let p = place else { return }
        guard let target = Self.textArea(p.table, row: p.row + dr, column: p.column + dc) else {
            Tones.edge(); Speech.speakOnly(String(localized: "edge of table", comment: "Spoken message")); return
        }
        _ = target.set(kAXSelectedTextRangeAttribute, axRangeValue(0, 0))
        AXHandler.shared.focusChanged(target, pid: element.pid)
    }
}
