// SPDX-License-Identifier: GPL-3.0-or-later
// Microsoft Excel (Day 2, 10 Oct 2026). Measured with the test workbook, read-only (no licence on this Mac):
// - The grid is an AXTable described "<sheet>Grid" (TidesGrid). Each cell is an AXCell in an AXRow, and inside it the
//   part Excel calls focused: another AXCell described by the address, an AXTextArea described by the address, or an
//   AXGroup holding the value, depending on Excel's state. All of them carry AXRowIndexRange and AXColumnIndexRange
//   (row 1 is index 1, column A is index 1).
// - Arrows post AXSelectedCellsChanged on the table; the focus follows only sometimes (AXHandlerNotifications).
// - The cells report AXEnabled false while the workbook is read-only.
// Read as NVDA and VoiceOver do: the content, then the address ("Monday, A2"; an empty cell "blank, E3"); a formula
// says so after the address.
import Foundation
import ApplicationServices

final class ExcelAppModule: AppModule {
    static let bundleID = "com.microsoft.Excel"

    required init(pid: pid_t, bundleIdentifier: String, appName: String) {
        super.init(pid: pid, bundleIdentifier: bundleIdentifier, appName: appName)
        declareNVDAKeys()   // ExcelNVDAKeys.swift
    }

    /// The cell in the row that this element is, or is part of.
    nonisolated static func outerCell(_ e: AXUIElement) -> AXUIElement? {
        var cur: AXUIElement? = e
        for _ in 0..<4 {
            guard let c = cur else { return nil }
            if c.role == "AXCell", c.element(kAXParentAttribute)?.role == "AXRow" { return c }
            guard c.attr("AXRowIndexRange") != nil else { return nil }
            cur = c.element(kAXParentAttribute)
        }
        return nil
    }

    override func redirectFocus(_ element: AXUIElement) -> AXUIElement? {
        guard element.attr("AXRowIndexRange") != nil, let cell = Self.outerCell(element), !cell.isSame(element) else { return nil }
        return cell
    }

    // MARK: Opened cold
    // Opened while TurnOver leads, Excel builds no grid: the focus stays on "Content Area" and the arrows bring no
    // news. Asking again (AXEnhancedUserInterface off and on, a fresh client, a walk of the window, 20 s of waiting,
    // VoiceOver on in the background) changed nothing. In front under VoiceOver for a few seconds, it builds the grid
    // and keeps it (Day 3, 10 Oct 2026: tested cold, "Tides, sheet", "Day, A1" at once). So: ask once more; if there
    // is still no grid, lend Excel to VoiceOver for three seconds, once per launch, and take the focus afresh.

    override func event_appModuleGainFocus() { wakeGrid(tries: 5) }
    private var lent = false

    private func wakeGrid(tries: Int) {
        guard tries > 0 else { Log.io("excel: no grid after asking again"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, API.focusPid == self.pid else { return }
            let app = AXUIElementCreateApplication(self.pid)
            guard let f = app.element(kAXFocusedUIElementAttribute), f.role == "AXLayoutArea" || f.role == "AXUnknown" else { return }
            if !self.lent, let lend = Core.lendToVoiceOver {
                self.lent = true
                Log.io("excel: no grid; lending Excel to VoiceOver for a moment, once")
                Speech.speakMessage(String(localized: "Getting Excel ready", comment: "Spoken message"))
                lend(3)
                return
            }
            Log.io("excel: no grid yet; asking for it again")
            _ = app.set("AXEnhancedUserInterface", kCFBooleanFalse)
            _ = app.set("AXEnhancedUserInterface", kCFBooleanTrue)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, API.focusPid == self.pid else { return }
                if let g = app.element(kAXFocusedUIElementAttribute), g.role != "AXLayoutArea", g.role != "AXUnknown" {
                    Log.io("excel: the grid is there")
                    AXHandler.shared.focusChanged(g, pid: self.pid)
                } else { self.wakeGrid(tries: tries - 1) }
            }
        }
    }

    // MARK: Highlighting (Shift with the arrows, 10 Oct 2026, "it's not saying what I've highlighted")
    // Excel keeps the focus on the cell where the highlight started and only reports the selected cells. Said as NVDA
    // and VoiceOver do: the cell just reached, then the range ("12000, B3, B1 to B3 selected"); back to one cell, that
    // cell again.

    private var hadRange = false
    private var lastRange: (String, Date)?

    override func gridSelectionChanged(_ table: AXUIElement, count: Int) -> Bool {
        if count <= 1 {
            guard hadRange else { return false }
            hadRange = false; lastRange = nil
            guard let c = Self.selectedCell(table, 0) else { return false }
            Speech.cancel()
            Speech.speakObject(ObjectFactory.make(Self.outerCell(c) ?? c), reason: .focus)
            return true
        }
        guard let first = Self.selectedCell(table, 0), let last = Self.selectedCell(table, count - 1),
              let a = Self.index(first), let b = Self.index(last) else { return true }
        let top = min(a.row, b.row), bottom = max(a.row, b.row), left = min(a.col, b.col), right = max(a.col, b.col)
        // The anchor is where the focus stayed; the end that moves is the opposite corner.
        let anchor = API.focusObject.flatMap { Self.outerCell($0.element) }.flatMap(Self.index) ?? a
        let end = (row: anchor.row == top ? bottom : top, col: anchor.col == left ? right : left)
        let range = "\(Self.address(top, left)) to \(Self.address(bottom, right))"
        if let (r, at) = lastRange, r == range, Date().timeIntervalSince(at) < 0.5 { return true }   // Excel posts each change twice
        lastRange = (range, Date()); hadRange = true
        let endCell = [first, last].first { Self.index($0).map { $0.row == end.row && $0.col == end.col } ?? false }
        let endName = endCell.map { ObjectFactory.make(Self.outerCell($0) ?? $0).name } ?? Self.address(end.row, end.col)
        Log.io("excel: \(count) cells highlighted")
        Speech.cancel()
        Speech.speakMessage(String(localized: "\(endName), \(Self.address(top, left)) to \(Self.address(bottom, right)) selected", comment: "Excel: the cell reached, then the range selected: A1 to C4"))
        return true
    }

    nonisolated static func selectedCell(_ table: AXUIElement, _ i: Int) -> AXUIElement? {
        var v: CFArray?
        guard AXUIElementCopyAttributeValues(table, "AXSelectedCells" as CFString, i, 1, &v) == .success else { return nil }
        return (v as? [AXUIElement])?.first
    }

    nonisolated static func index(_ e: AXUIElement) -> (row: Int, col: Int)? {
        guard let rv = e.attr("AXRowIndexRange"), let cv = e.attr("AXColumnIndexRange") else { return nil }
        var r = CFRange(), c = CFRange()
        guard axValue(rv, .cfRange, &r), axValue(cv, .cfRange, &c) else { return nil }
        return (r.location, c.location)
    }

    nonisolated static func address(_ row: Int, _ col: Int) -> String { ExcelAddress.columnLetters(col) + "\(row)" }

    override func objectClass(for element: AXUIElement, role: Role, subrole: String?) -> TurnOverObject.Type? {
        let r = element.role
        if r == "AXCell", element.element(kAXParentAttribute)?.role == "AXRow" { return ExcelCell.self }
        if r == "AXTable", (element.string(kAXDescriptionAttribute) ?? "").hasSuffix("Grid") { return ExcelGrid.self }
        return nil
    }
}

/// A sheet's grid: "Tides, sheet", not "TidesGrid, table".
final class ExcelGrid: TurnOverObject {
    override var name: String { String((element.string(kAXDescriptionAttribute) ?? "").dropLast(4)) }
    override var roleText: String? { "sheet" }
}

/// A cell: "1.2, B2", "blank, E3", "3.6, D2, formula".
final class ExcelCell: TurnOverObject {
    override var role: Role { .tableCell }
    override var value: String? { nil }
    override var positionInfo: PositionInfo? { nil }
    override var description: String? { parts.formula ? "formula" : nil }
    override var name: String { "\(parts.content.isEmpty ? "blank" : parts.content), \(parts.address)" }

    private lazy var parts: (content: String, address: String, formula: Bool) = {
        var content = "", address = "", formula = false
        var queue = [element], seen = 0
        while !queue.isEmpty, seen < 12 {
            let e = queue.removeFirst(); seen += 1
            if content.isEmpty, let v = e.attr(kAXValueAttribute) {
                let s = (v as? String) ?? (v as? NSNumber)?.stringValue ?? ""
                if !s.trimmingCharacters(in: .whitespaces).isEmpty { content = s }
            }
            let d = e.string(kAXDescriptionAttribute) ?? ""
            if address.isEmpty, d.range(of: #"^[A-Z]{1,3}[0-9]+$"#, options: .regularExpression) != nil { address = d }
            if d.localizedCaseInsensitiveContains("formula") || (e.string(kAXHelpAttribute) ?? "").localizedCaseInsensitiveContains("formula") { formula = true }
            queue += e.elements(kAXChildrenAttribute)
        }
        if address.isEmpty { address = Self.address(of: element) ?? "" }
        return (content, address, formula)
    }()

    /// From the index ranges: column 1 is A, row 1 is 1.
    nonisolated static func address(of e: AXUIElement) -> String? {
        guard let rv = e.attr("AXRowIndexRange"), let cv = e.attr("AXColumnIndexRange") else { return nil }
        var r = CFRange(), c = CFRange()
        guard axValue(rv, .cfRange, &r), axValue(cv, .cfRange, &c), c.location > 0 else { return nil }
        return ExcelAddress.columnLetters(c.location) + "\(r.location)"
    }

}

/// Column letters from a grid index: 1 is A, 27 is AA.
public enum ExcelAddress {
    nonisolated public static func columnLetters(_ n: Int) -> String {
        var n = n, s = ""
        while n > 0 { let m = (n - 1) % 26; s = String(UnicodeScalar(65 + m)!) + s; n = (n - 1) / 26 }
        return s
    }
}
