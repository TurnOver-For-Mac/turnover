// SPDX-License-Identifier: GPL-3.0-or-later
// Numbers (17 Oct 2026, the Apple apps sweep). What Numbers gives accessibility: the sheet is a layout area holding
// each table (AXTable, titled "numbers-test, 13 rows, 5 columns") with its cells (AXCell, the value as the title,
// "Month, Column header cell, Row header cell" for headers, AXRowIndexRange and AXColumnIndexRange for the place).
// Once a cell is selected the arrows move by cell and Numbers announces each (AXSelectedCellsChanged); two things
// it needs from TurnOver:
// - A way in from the keyboard: with the sheet focused and nothing selected, the arrows did nothing, and neither
//   focusing nor pressing a cell by accessibility selects it (probe). VoiceOver gets in by clicking (VO-Shift-Space);
//   so does TurnOver: an arrow, Tab or Return on the sheet clicks the first table's first cell, the pointer put back,
//   and leaves the cell's editing at once if the click started it.
// - The headings with the value, as VoiceOver says them: moving along a row, the column's heading ("Sales, 1521");
//   down a column, the row's ("February, 1521"); the bare value said nothing of where it was.
import Foundation
import ApplicationServices

final class NumbersAppModule: AppModule {
    static let bundleID = "com.apple.Numbers"
    private var lastPlace: (row: Int, col: Int)?
    private var enteredAt = Date.distantPast

    required init(pid: pid_t, bundleIdentifier: String, appName: String) {
        super.init(pid: pid, bundleIdentifier: bundleIdentifier, appName: appName)
        let cat = "Numbers"
        script("nextTable", String(localized: "The sheet's next table (VO-Command-T)", comment: "A command, as the key list and keyboard help say it"), gestures: [], category: cat) { [weak self] g in self?.moveTable(forward: true, g) }
            .isAvailable = { [weak self] in self?.sheet() != nil }
        script("previousTable", String(localized: "The sheet's previous table (VO-Command-Shift-T)", comment: "A command, as the key list and keyboard help say it"), gestures: [], category: cat) { [weak self] g in self?.moveTable(forward: false, g) }
            .isAvailable = { [weak self] in self?.sheet() != nil }
        for key in ["upArrow", "downArrow", "leftArrow", "rightArrow", "tab", "enter"] {
            script("numbers_enterTable_\(key)", String(localized: "Into the sheet's first table (Numbers selects nothing from the keyboard)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:\(key)"], category: cat) { [weak self] g in
                guard let self, self.enterFirstTable() else { g.send(); return }
            }.isAvailable = { [weak self] in self?.onEmptySheet() == true }
        }
    }

    // MARK: Between tables

    /// VO-Command-T and Shift-T: the sheet's next or previous table (VoiceOverKeys' find asks the module for
    /// "nextTable" first), into its first cell, named as it is reached.
    private func moveTable(forward: Bool, _ g: KeyboardGesture) {
        guard let layout = sheet() else { Speech.speakMessage(String(localized: "not in a sheet", comment: "Spoken message")); return }
        let all = tables(in: layout)
        guard !all.isEmpty else { Speech.speakMessage(String(localized: "no tables on this sheet", comment: "Spoken message")); return }
        let current = all.firstIndex { !$0.elements("AXSelectedCells").isEmpty }
        let target: Int
        if let c = current { target = c + (forward ? 1 : -1) } else { target = forward ? 0 : all.count - 1 }
        guard target >= 0, target < all.count else { Tones.edge(); Speech.speakMessage(forward ? String(localized: "no next table", comment: "Spoken message") : String(localized: "no previous table", comment: "Spoken message")); return }
        let t = all[target]
        Speech.cancel(); Speech.speakMessage(t.string(kAXTitleAttribute) ?? String(localized: "table \(String(target + 1))", comment: "A Numbers table with no name: its number"))
        lastPlace = nil
        _ = click(firstCellOf: t)
    }

    /// The sheet the keyboard is on: the layout area itself, or the one holding the focused table or cell.
    private func sheet() -> AXUIElement? {
        guard let f = API.focusObject, f.pid == pid else { return nil }
        var e: AXUIElement? = f.element
        var hops = 0
        while let x = e, hops < 6 { if x.role == "AXLayoutArea" { return x }; e = x.element(kAXParentAttribute); hops += 1 }
        return nil
    }

    // MARK: Getting in

    /// The keyboard is on the sheet itself, with no cell selected in any table on it.
    private func onEmptySheet() -> Bool {
        guard let f = API.focusObject, f.pid == pid, f.element.role == "AXLayoutArea" else { return false }
        return !tables(in: f.element).contains { !($0.elements("AXSelectedCells")).isEmpty }
    }

    private func tables(in layout: AXUIElement) -> [AXUIElement] {
        layout.elements(kAXChildrenAttribute).filter { $0.role == "AXTable" }
    }

    private func enterFirstTable() -> Bool {
        guard let f = API.focusObject, let table = tables(in: f.element).first else { return false }
        return click(firstCellOf: table)
    }

    private func click(firstCellOf table: AXUIElement) -> Bool {
        guard let cell = table.elements("AXVisibleCells").first, let frame = TurnOverObject.frame(cell) else { return false }
        Log.io("numbers: into the table by a click on its first cell")
        enteredAt = Date(); lastPlace = nil
        let at = CGPoint(x: frame.midX, y: frame.midY)
        let back = CGEvent(source: nil)?.location ?? at
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(30_000)
        }
        CGWarpMouseCursorPosition(back)
        // A click on a cell already chosen starts editing it: leave the editing, keep the cell.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, let focus = AXUIElementCreateApplication(self.pid).element(kAXFocusedUIElementAttribute), focus.role == "AXTextArea" else { return }
            KeyboardGesture(identifier: "kb:escape")?.send()
        }
        return true
    }

    // MARK: Reading cells

    static func range(_ e: AXUIElement, _ name: String) -> Int? {
        guard let v = e.attr(name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange(); axValue(v, .cfRange, &r)
        return r.location
    }

    /// A cell's words without Numbers' notes about it ("Month, Column header cell, Row header cell" is "Month").
    static func value(_ cell: AXUIElement) -> String {
        var t = cell.string(kAXTitleAttribute) ?? cell.string(kAXValueAttribute) ?? ""
        for note in [", Column header cell", ", Row header cell", ", Is Editing", ", Footer row cell"] { t = t.replacingOccurrences(of: note, with: "") }
        // An empty header cell is titled only with the note.
        if ["Column header cell", "Row header cell", "Footer row cell", "Is Editing"].contains(t.trimmingCharacters(in: .whitespaces)) { t = "" }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private func cell(in table: AXUIElement, row: Int, col: Int) -> AXUIElement? {
        table.elements("AXVisibleCells").first { Self.range($0, "AXRowIndexRange") == row && Self.range($0, "AXColumnIndexRange") == col }
    }

    /// The heading of a column (its header row's cell) or a row (its header column's), when the table has them.
    private func heading(in table: AXUIElement, row: Int?, col: Int?) -> String? {
        guard let h = cell(in: table, row: row ?? 0, col: col ?? 0) else { return nil }
        let title = h.string(kAXTitleAttribute) ?? ""
        guard title.contains(row == nil ? "Column header cell" : "Row header cell") else { return nil }
        let v = Self.value(h)
        return v.isEmpty ? nil : v
    }

    override func handleEvent(_ event: Event, next: () -> Void) {
        guard event.kind == .gainFocus, event.obj.pid == pid else { next(); return }
        let e = event.obj.element
        // The click's moment of editing, left at once: not read.
        if e.role == "AXTextArea", Date().timeIntervalSince(enteredAt) < 0.8 { return }
        // The table itself announced as focus while one of its cells is the selection (Escape out of editing):
        // its cell is what matters, and it follows in a moment.
        if e.role == "AXTable", !e.elements("AXSelectedCells").isEmpty { return }
        guard e.role == "AXCell", let row = Self.range(e, "AXRowIndexRange"), let col = Self.range(e, "AXColumnIndexRange"),
              let table = e.element(kAXParentAttribute).flatMap({ $0.role == "AXTable" ? $0 : $0.element(kAXParentAttribute) }) else { next(); return }
        let v = Self.value(e)
        let words = v.isEmpty ? "blank" : v
        var out = words
        if let last = lastPlace {
            if last.row == row, last.col != col, row > 0, let h = heading(in: table, row: nil, col: col) { out = "\(h), \(words)" }
            else if last.col == col, last.row != row, col > 0, let h = heading(in: table, row: row, col: nil) { out = "\(h), \(words)" }
        } else {
            let colHead = row > 0 ? heading(in: table, row: nil, col: col) : nil
            out = [words, colHead].compactMap { $0 }.joined(separator: ", ")
        }
        lastPlace = (row, col)
        // The cell's address ("B3"), as VoiceOver says it, only with Cell coordinates on (Documents, Tables): a tester
        // heard them with the setting off (build 19, before this module); the module then never said them.
        if config.documentFormatting.tableCellCoordinates { out += ", \(CellAddress.of(row: row, col: col))" }
        Speech.cancel()
        Speech.speakMessage(out)
    }
}

/// A cell's address as Numbers and Excel name it: column letters, then the row from 1 ("A1", "AB12"). Pure, for the
/// tests.
public enum CellAddress {
    public static func of(row: Int, col: Int) -> String {
        var letters = "", n = col + 1
        while n > 0 { let r = (n - 1) % 26; letters = String(Character(UnicodeScalar(UInt8(65 + r)))) + letters; n = (n - 1) / 26 }
        return "\(letters)\(row + 1)"
    }
}
