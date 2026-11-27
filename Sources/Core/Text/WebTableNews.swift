// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverAX

/// What a web table says as the reading moves in it: its size on arrival, then the row as it changes (26 Nov 2026,
/// at Oliver's ask; TextEdit's and Word's tables already say the same, as NVDA does).
package enum WebTableNews {
    /// The decision, apart from the accessibility tree. `entering`: the reading is in a table the previous reading was
    /// not in. `rowChanged`: the same table, another row. `row`: the 1-based row number, when known. `rows` or
    /// `columns` of 0 or less is unknown. `tone`: play the table sound first. `words`: what to say, in order.
    package nonisolated static func words(entering: Bool, rowChanged: Bool, row: Int?, rows: Int, columns: Int,
                                          mode: ElementReport, coordinates: Bool) -> (tone: Bool, words: [String]) {
        guard mode != .off else { return (false, []) }
        var words: [String] = []
        if entering {
            if mode == .speech {
                words.append(rows > 0 && columns > 0 ? WordTableWords.size(rows: rows, columns: columns) : Role.table.displayString)
            }
            if coordinates, let row { words.append(Phrases.row(row)) }
            return (mode == .tone, words)
        }
        if rowChanged, coordinates, let row { words.append(Phrases.row(row)) }
        return (false, words)
    }

    /// Where this reading is against the last one. `lastInTable`: the last reading was in this table, nil when there is
    /// no last reading to go by (say all's first piece, the current line, find); `lastInRow`: it was in this row (true
    /// when this reading is in no row); `beginsHere`: the table's first line is in this reading. With no last reading
    /// the table is said only where it begins, where "table" always was: said on every line, say all gave the size
    /// before each cell (review, 26 Nov 2026).
    package nonisolated static func change(lastInTable: Bool?, lastInRow: Bool, beginsHere: Bool) -> (entering: Bool, rowChanged: Bool) {
        guard let lastInTable else { return (beginsHere, false) }
        return (!lastInTable, lastInTable && !lastInRow)
    }

    /// The table and the row an element chain (nearest first) is inside; the row is the nearest one below the table.
    static func tableAndRow(inChainNearestFirst chain: [AXUIElement]) -> (table: AXUIElement?, row: AXUIElement?) {
        var row: AXUIElement?
        for el in chain {
            let r = el.role
            if r == "AXRow", row == nil { row = el }
            if r == "AXTable" { return (el, row) }
            if r == "AXGrid" { return (nil, nil) }
        }
        return (nil, nil)
    }

    /// The row's 1-based number: its own AXIndex, else its first cell's row range.
    static func rowNumber(_ row: AXUIElement) -> Int? {
        if let n = (row.attr(kAXIndexAttribute) as? NSNumber)?.intValue { return n + 1 }
        for c in row.elements(kAXChildrenAttribute) where c.role == "AXCell" {
            return VoiceOverKeysPlugin.index(c, "AXRowIndexRange").map { $0 + 1 }
        }
        return nil
    }

    /// For one reading: asks the tree only for what the decision needs, and adds nothing to the chain itself.
    static func news(table: AXUIElement?, row: AXUIElement?, previousChain: [AXUIElement]?, beginsHere: Bool) -> (tone: Bool, words: [String]) {
        guard let table else { return (false, []) }
        let f = config.documentFormatting
        guard f.tables != .off else { return (false, []) }
        func was(_ e: AXUIElement) -> Bool? { previousChain.map { chain in chain.contains { $0.isSame(e) } } }
        let (entering, rowChanged) = change(lastInTable: was(table), lastInRow: row.flatMap(was) ?? true, beginsHere: beginsHere)
        guard entering || rowChanged else { return (false, []) }
        let number = f.tableCellCoordinates ? row.flatMap { rowNumber($0) } : nil
        // Counted, not fetched: a long table's rows are not copied over just to be counted.
        let size = entering && f.tables == .speech
        let rows = size ? table.attributeValueCountResult(kAXRowsAttribute).value ?? 0 : 0
        let columns = size ? table.attributeValueCountResult(kAXColumnsAttribute).value ?? 0 : 0
        return words(entering: entering, rowChanged: rowChanged, row: number, rows: rows, columns: columns,
                     mode: f.tables, coordinates: f.tableCellCoordinates)
    }
}
