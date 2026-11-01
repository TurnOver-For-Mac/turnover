// SPDX-License-Identifier: GPL-3.0-or-later
// Reminders (18 Oct 2026, the Apple apps sweep). What Reminders gives accessibility (probe): a sidebar outline
// ("Account Lists") whose rows are the lists, each described "Tomorrow, 4 reminders, List badge, Green", at level 2
// under "My Lists"; and a reminders outline whose rows hold a cell described "Incomplete, <title>" (its parts: a
// "Mark as Completed" control, the title as a text field, an "Edit Details" button), with a "1 Completed" header.
// What TurnOver changes:
// - A list says its name and count: "Tomorrow, 4 reminders" (not "List badge, Green", not "level 2").
// - A reminder says its title first, and "completed" only when it is: "Buy milk", "Buy milk, completed" (it was
//   "Incomplete, Buy milk" every time).
// - Tab and Shift-Tab go between the lists and the reminders. Reminders' own Tab went from the sidebar to a list's
//   Share button, then to the window, and never reached the reminders (driver).
import Foundation
import ApplicationServices

final class RemindersAppModule: AppModule {
    static let bundleID = "com.apple.reminders"

    required init(pid: pid_t, bundleIdentifier: String, appName: String) {
        super.init(pid: pid, bundleIdentifier: bundleIdentifier, appName: appName)
        script("reminders_toReminders", String(localized: "From the lists to the reminders", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:tab"], category: "Reminders") { [weak self] _ in
            self?.focus(outline: self?.remindersOutline(), name: "reminders")
        }.isAvailable = { [weak self] in self?.inOutline(sidebar: true) == true }
        script("reminders_toLists", String(localized: "From the reminders to the lists", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+tab"], category: "Reminders") { [weak self] _ in
            self?.focus(outline: self?.sidebarOutline(), name: "lists")
        }.isAvailable = { [weak self] in self?.inOutline(sidebar: false) == true }
    }

    // MARK: Where

    private func outlines() -> [AXUIElement] {
        guard let w = AXUIElementCreateApplication(pid).element(kAXFocusedWindowAttribute),
              let split = w.elements(kAXChildrenAttribute).first(where: { $0.role == "AXSplitGroup" }) else { return [] }
        return split.elements(kAXChildrenAttribute).filter { $0.role == "AXScrollArea" }
            .compactMap { $0.elements(kAXChildrenAttribute).first { $0.role == "AXOutline" } }
    }
    /// The sidebar: the outline of lists (the first; described "Account Lists").
    private func sidebarOutline() -> AXUIElement? { outlines().first }
    /// The reminders of the chosen list (the second outline).
    private func remindersOutline() -> AXUIElement? { let o = outlines(); return o.count > 1 ? o[1] : nil }

    /// The focus is in the sidebar's outline (or the reminders') itself or one of its rows.
    private func inOutline(sidebar: Bool) -> Bool {
        guard let f = API.focusObject, f.pid == pid, let target = sidebar ? sidebarOutline() : remindersOutline() else { return false }
        var e: AXUIElement? = f.element; var hops = 0
        while let x = e, hops < 6 { if x.isSame(target) { return true }; e = x.element(kAXParentAttribute); hops += 1 }
        return false
    }

    private func focus(outline: AXUIElement?, name: String) {
        guard let outline else { Tones.edge(); return }
        // Something chosen there already: it stays; nothing: the first row.
        if outline.elements(kAXSelectedRowsAttribute).isEmpty, let first = outline.elements(kAXRowsAttribute).first(where: { Self.rowWords($0) != nil }) {
            _ = outline.set(kAXSelectedRowsAttribute, [first] as CFArray)
        }
        if outline.set(kAXFocusedAttribute, kCFBooleanTrue) != .success { Log.io("reminders: the \(name) outline refused the focus") }
    }

    // MARK: Reading

    override func objectClass(for element: AXUIElement, role: Role, subrole: String?) -> TurnOverObject.Type? {
        [.treeViewItem, .tableRow].contains(role) ? RemindersRow.self : nil
    }

    /// The list chosen in the sidebar, by name ("Tomorrow"), from any element of the window.
    static func chosenList(near element: AXUIElement) -> String? {
        guard let w = element.element(kAXWindowAttribute),
              let split = w.elements(kAXChildrenAttribute).first(where: { $0.role == "AXSplitGroup" }),
              let sidebar = split.elements(kAXChildrenAttribute).first(where: { $0.role == "AXScrollArea" })?.elements(kAXChildrenAttribute).first(where: { $0.role == "AXOutline" }),
              let row = sidebar.elements(kAXSelectedRowsAttribute).first, let words = rowWords(row) else { return nil }
        return words.components(separatedBy: ", ").first
    }

    /// What a row says: a list's name and count, or a reminder's title and whether it is done. nil: not a row of ours.
    static func rowWords(_ row: AXUIElement) -> String? {
        guard let cell = row.elements(kAXChildrenAttribute).first(where: { $0.role == "AXCell" }) else { return nil }
        let d = (cell.string(kAXDescriptionAttribute) ?? "").trimmingCharacters(in: .whitespaces)
        guard !d.isEmpty else { return nil }
        let parts = d.components(separatedBy: ", ")
        // A reminder: "Incomplete, <title>" or "Completed, <title>".
        if let state = parts.first, ["Incomplete", "Completed"].contains(state), parts.count > 1 {
            let title = parts.dropFirst().joined(separator: ", ")
            return state == "Completed" ? "\(title), completed" : title
        }
        // A list: "<name>, <n> reminders, List badge, <colour>": the badge and its colour go.
        if let badge = parts.firstIndex(where: { $0.hasPrefix("List badge") }) { return parts[..<badge].joined(separator: ", ") }
        return d
    }
}

/// A row of Reminders' lists or reminders, said as RemindersAppModule.rowWords has it, without the outline's level.
final class RemindersRow: TurnOverObject {
    override var name: String {
        if let w = RemindersAppModule.rowWords(element) { return w }
        let own = super.name
        // The reminders' group row has no words ("expanded, 2 of 9"): it's said as the list it holds, like a heading.
        if own.isEmpty, let list = RemindersAppModule.chosenList(near: element) { return list }
        return own
    }
    override var positionInfo: PositionInfo? {
        guard var p = super.positionInfo else { return nil }
        p.level = nil
        return p
    }
}
