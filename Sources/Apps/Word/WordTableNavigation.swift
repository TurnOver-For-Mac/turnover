// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import AppKit

extension WordAppModule {
    /// The cell the caret is in now. Word's focus stays on the page (or its scroll area) while the caret is in a
    /// table, so: the focused element when it is a cell's text area; else the cell TurnOver last spoke (a move by
    /// row or column starts from it); else, in a small table, the cell marked focused.
    func liveCell() -> WordTableCell? {
        let app = AXUIElementCreateApplication(pid)
        if let f = app.element(kAXFocusedUIElementAttribute), f.role == "AXTextArea", WordTableCell.cell(of: f) != nil { return WordTableCell(element: f) }
        if let last = WordTableCell.last, let area = WordTableCell.textArea(last.table, row: last.row, column: last.column) { return WordTableCell(element: area) }
        // The focused cell in any table of the window, not only the first: the first table's cell was found in
        // every later table, and its moves said "top" and "bottom" (19 Oct 2026). Small tables only (each cell is asked).
        guard let win = app.element(kAXFocusedWindowAttribute) else { return nil }
        var stack = [win], seen = 0
        while let e = stack.popLast(), seen < 1500 {
            seen += 1
            if e.role == "AXTable" {
                guard let rows = e.attr("AXRowCount") as? Int, rows <= 60 else { continue }
                for row in e.elements(kAXRowsAttribute) {
                    for cell in row.elements(kAXChildrenAttribute) where cell.role == "AXCell" && (cell.attr(kAXFocusedAttribute) as? Bool) == true {
                        if let area = cell.firstDescendant(role: "AXTextArea", maxVisited: 6) { return WordTableCell(element: area) }
                    }
                }
                continue
            }
            stack.append(contentsOf: e.elements(kAXChildrenAttribute).reversed())
        }
        return nil
    }
    /// Table moves by the live caret (TurnOver plus the arrows in the Windows style; the VO keys ask by name).
    func declareTableScripts() {
        // VO-Command-T and Shift from inside a table: the focus is the cell, so the page's own nextTable wasn't found
        // by name and VoiceOver's window walk ran instead, "no next table" with tables below (a tester,
        // 16 Oct 2026). The module answers by name and hands the page's script the move.
        for (name, forward) in [("nextTable", true), ("previousTable", false)] {
            script(name, "Moves to the \(forward ? "next" : "previous") table, the caret in its first cell", gestures: [], category: "Microsoft Word") { [weak self] _ in
                guard let self else { return }
                if let d = API.focusObject as? WordDocument { d.goToTable(forward: forward); return }
                // (lastDocument is cleared by the loseFocus the first move queued, so the second press from the cell
                // needs the caret's area: code review, 16 Oct 2026.)
                guard let page = lastDocument?.element ?? caretArea else { Tones.edge(); Speech.speakMessage(String(localized: "not in a document", comment: "Spoken message")); return }
                Log.io("Word: \(name) from a table cell, through the page")
                WordDocument(element: page).goToTable(forward: forward)
            }
        }
        // The page's other moves likewise answered by name from a cell (the rotor: headings, comments, tracked
        // changes, misspelled words, pages; a code review on 17 Oct 2026).
        for name in ["nextHeading", "previousHeading", "nextComment", "previousComment", "nextRevision", "previousRevision", "nextSpellingError", "previousSpellingError", "nextPage", "previousPage"] {
            script(name, "Moves to the \(name.hasPrefix("next") ? "next" : "previous") \(name.replacingOccurrences(of: "next", with: "").replacingOccurrences(of: "previous", with: "").lowercased())", gestures: [], category: "Microsoft Word") { [weak self] g in
                guard let self else { return }
                if let d = API.focusObject as? WordDocument, let s = d.script(named: name) { s.handler(g); return }
                guard let page = lastDocument?.element ?? caretArea else { Tones.edge(); Speech.speakMessage(String(localized: "not in a document", comment: "Spoken message")); return }
                let doc = WordDocument(element: page)
                guard let s = doc.script(named: name) else { Tones.edge(); Speech.speakMessage(String(localized: "not in a document", comment: "Spoken message")); return }
                Log.io("Word: \(name) from a table cell, through the page")
                s.handler(g)
            }
        }
        for (name, dr, dc, keys) in [("table_nextColumn", 0, 1, ["kb:turnover+rightArrow"]), ("table_previousColumn", 0, -1, ["kb:turnover+leftArrow"]),
                                     ("table_nextRow", 1, 0, ["kb:turnover+downArrow"]), ("table_previousRow", -1, 0, ["kb:turnover+upArrow"])] {
            let description = dr == 0 ? (dc > 0 ? String(localized: "In a table: the next cell in the row, the caret at its start (NVDA's table keys; TurnOver plus the arrows)", comment: "A command, as the key list and keyboard help say it")
                                                : String(localized: "In a table: the previous cell in the row, the caret at its start (NVDA's table keys; TurnOver plus the arrows)", comment: "A command, as the key list and keyboard help say it"))
                : (dr > 0 ? String(localized: "In a table: the cell below, the caret at its start (NVDA's table keys; TurnOver plus the arrows)", comment: "A command, as the key list and keyboard help say it")
                          : String(localized: "In a table: the cell above, the caret at its start (NVDA's table keys; TurnOver plus the arrows)", comment: "A command, as the key list and keyboard help say it"))
            script(name, description, gestures: keys, category: "Microsoft Word") { [weak self] _ in
                self?.liveCell()?.move(dr, dc)
            }.isAvailable = { [weak self] in
                guard let self, API.focusPid == pid else { return false }
                // Once a second: liveCell searches the window (up to 1,500 elements) when no cell is known, and this
                // ran before every arrow key outside a table, with the keyboard waiting (a code review, 14 Oct 2026).
                if Date().timeIntervalSince(inTableCheckedAt) < 1 { return inTableLastAnswer }
                inTableLastAnswer = liveCell() != nil; inTableCheckedAt = Date()
                return inTableLastAnswer
            }
        }
    }
}
