// SPDX-License-Identifier: GPL-3.0-or-later
// What counts as an item, answered from a window's snapshot (AXSnapshot) instead of by asking the app again for
// every element. The rules are ObjectNavigator.isItem's and the Item Chooser's own, unchanged (10 Nov 2026): what
// moved is where the answers come from. The three things a snapshot does not hold are asked for through `Live`,
// and only for the few elements whose answer depends on them.
import Foundation
import ApplicationServices
import TurnOverAX

nonisolated package enum SnapshotItems {
    /// The questions a snapshot cannot answer. The reader passes the real ones; a test passes its own.
    package struct Live: Sendable {
        /// A plugin profile gives this element a label.
        package var profileNamed: @Sendable (AXUIElement) -> Bool
        /// A plugin profile silences this element.
        package var isSilenced: @Sendable (AXUIElement) -> Bool
        /// The element's action names (never part of a batched read: actions are not attributes).
        package var actions: @Sendable (AXUIElement) -> [String]

        package init(profileNamed: @escaping @Sendable (AXUIElement) -> Bool, isSilenced: @escaping @Sendable (AXUIElement) -> Bool,
                     actions: @escaping @Sendable (AXUIElement) -> [String]) {
            self.profileNamed = profileNamed; self.isSilenced = isSilenced; self.actions = actions
        }

        static let reader = Live(
            profileNamed: { ProfileStore.shared.label(for: $0, pid: $0.pid)?.0 != nil },
            isSilenced: { ProfileStore.shared.isSilenced($0, pid: $0.pid) },
            actions: { ($0.actionNamesResult().value as? [String]) ?? [] })
    }

    private static func blank(_ text: String?) -> Bool { (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private static func text(_ value: AXSnapshot.Value?) -> String? { if case .text(let t) = value { return t }; return nil }

    /// ObjectNavigator.hasWords over the snapshot: the element or anything just inside it has a value, title or
    /// description; twelve elements at most, nearest first.
    static func hasWords(_ s: AXSnapshot, _ index: Int) -> Bool {
        var queue = [index], n = 0
        while !queue.isEmpty, n < 12 {
            let node = s.nodes[queue.removeFirst()]; n += 1
            if !blank(text(node.value)) || !blank(node.title) || !blank(node.label) { return true }
            queue.append(contentsOf: node.children)
        }
        return false
    }

    /// ObjectNavigator.isItem over the snapshot: an element worth stopping on.
    static func isItem(_ s: AXSnapshot, _ index: Int, live: Live) -> Bool {
        let node = s.nodes[index]
        let role = node.role
        if !node.isFilled || role.isEmpty || ObjectNavigator.skippedRoles.contains(role) || role == "AXWindow" || role == "AXApplication" { return false }
        if role == "AXStaticText" { return !blank((text(node.value) ?? "") + (node.label ?? "")) }
        // Asked for only where the answer can turn on it: most elements are settled by their own title or label.
        let named = node.title != nil || node.label != nil || live.profileNamed(node.element)
        if role == "AXCell" || role == "AXRow", !named, !hasWords(s, index) { return false }
        if role == "AXColumn", !named { return false }
        if role == "AXImage" { return named || live.actions(node.element).contains("AXPress") }
        if ObjectNavigator.layoutRoles.contains(role) {
            if live.isSilenced(node.element) { return false }
            guard node.listedChildren == 0 else { return false }
            return named || live.actions(node.element).contains("AXPress")
        }
        return !live.isSilenced(node.element)
    }

    static let chooserContainers: Set<String> = ["AXTable", "AXOutline", "AXList", "AXBrowser", "AXHeading"]

    /// The Item Chooser's list: every item in the window in the app's own order, with the label it is listed by.
    ///
    /// `onceByName` leaves out a text that only repeats what the item holding it is already listed as. Mail's
    /// sidebar listed "Favourites, cell" then "Favourites, text", and a mailbox the user made as "Important, cell"
    /// then "Important, text field": every mailbox twice (Oliver's trial, 10 Nov 2026; the old walk listed the
    /// same pairs). The outer item is the one kept: it is the stop VO Left and Right make too (a row or cell that
    /// says something is one stop). A text field is left out only inside a cell or row of the same name, and a
    /// button or any other control is never left out: it is somewhere to go and something to press.
    package static func chooserItems(_ s: AXSnapshot, live: Live, limit: Int = 1500, onceByName: Bool = true) -> [ItemChooser.Found] {
        var found: [ItemChooser.Found] = []
        /// The name each listed node is listed by, by its index in the snapshot.
        var listedName: [Int: String] = [:]
        for (index, node) in s.nodes.enumerated() where node.isFilled {
            guard found.count < limit else { break }
            let role = node.role
            guard !ObjectNavigator.skippedRoles.contains(role), role != "AXWindow",
                  chooserContainers.contains(role) || isItem(s, index, live: live) else { continue }
            let name = node.title ?? node.label ?? text(node.value).map { String($0.prefix(120)) } ?? ""
            guard !name.isEmpty || chooserContainers.contains(role) else { continue }
            if onceByName, !name.isEmpty, role == "AXStaticText" || role == "AXTextField" {
                let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
                var repeated = false
                var up = node.parent
                while let p = up {
                    if let outer = listedName[p], outer == wanted,
                       role == "AXStaticText" || s.nodes[p].role == "AXCell" || s.nodes[p].role == "AXRow" { repeated = true; break }
                    up = s.nodes[p].parent
                }
                if repeated { continue }
            }
            listedName[index] = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = [name, node.roleDescription ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
            found.append(ItemChooser.Found(element: node.element, label: label, role: role, subrole: node.subrole ?? ""))
        }
        return found
    }
}
