// SPDX-License-Identifier: GPL-3.0-or-later
// An app as named parts (docs/APP-RECIPES-PLAN.md: the sidebar, list, detail shape, 8 Oct 2026). The recipe names the
// parts in order with a match for each; Tab and Shift Tab go round them, Command Control 1 to 9 straight to one. Moving to
// a part: one that takes the keyboard gets it (a table, an outline, a text area, a field), and TurnOver reads it as
// any focus; a list that cannot take it is held by TurnOver's cursor, row by row (as Finder's sidebar); anything
// else (a toolbar, a group) is put under the cursor and read. Nothing else changes: inside a part the app's own
// keys work as they do.
import Foundation
import ApplicationServices

public final class PanesView {
    public let pid: pid_t
    public let parts: [RecipeView.Panes.Part]
    private var hinted = Set<Int>()
    /// Elements found, kept for a moment: finding one walks the window.
    private var found: [Int: (AXUIElement, Date)] = [:]

    public init(pid: pid_t, panes: RecipeView.Panes) { self.pid = pid; parts = panes.parts }

    /// The element of a part, now. Parts are containers, so the search never goes into rows, cells, text and the
    /// like, and visits a few hundred elements at most: a search that walked Notes' 800-row list held the main
    /// thread for seconds and the watchdog handed over (8 Oct 2026). Kept for ten seconds once found.
    public func element(of i: Int) -> AXUIElement? {
        guard parts.indices.contains(i) else { return nil }
        if let (e, at) = found[i], Date().timeIntervalSince(at) < 10, e.role != "?" { return e }
        guard let e = Self.find(parts[i].match, pid: pid) else { found[i] = nil; return nil }
        found[i] = (e, Date())
        return e
    }

    /// Roles a part is never inside: the search stops at them.
    static let leafRoles: Set<String> = ["AXRow", "AXCell", "AXStaticText", "AXImage", "AXButton", "AXMenuBar", "AXMenu", "AXTextField", "AXCheckBox",
                                         "AXRadioButton", "AXPopUpButton", "AXSlider", "AXLink", "AXHeading", "AXColumn", "AXDisclosureTriangle"]
    /// The first element in the app's front window that matches, breadth first, without entering leaves or
    /// the rows of a list, and within a time budget (any thread).
    static func find(_ m: ElementMatch, pid: pid_t, budget: TimeInterval = 0.9) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        let started = Date()
        var queue = [app.element(kAXFocusedWindowAttribute) ?? app.element(kAXMainWindowAttribute)].compactMap { $0 }
        if queue.isEmpty { queue = app.elements(kAXWindowsAttribute) }
        var visited = 0
        // 3,000 and a longer budget: Libation's grid (.NET's Avalonia) sits deep under layers of nameless groups and
        // was never found within 800 (parts request #6, 14 Oct 2026). The result is cached per part.
        while !queue.isEmpty, visited < 3000, Date().timeIntervalSince(started) < budget {
            let e = queue.removeFirst(); visited += 1
            if ElementMatcher.matches(e, m) { return e }
            let role = e.role
            if leafRoles.contains(role) { continue }
            // A table or outline is a part itself; its rows are not where another part lives.
            if ["AXTable", "AXOutline", "AXList"].contains(role) { continue }
            queue.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
        return nil
    }

    /// Which part the user is in: the one holding the keyboard focus, or TurnOver's cursor.
    public func currentIndex() -> Int? {
        let nav = ObjectNavigator.shared
        for i in parts.indices {
            guard let e = element(of: i) else { continue }
            // (element(of:) is bounded and cached, so this is a few calls per part.)
            if let f = API.focusObject, isInside(f.element, e) { return i }
            if nav.isHolding, let h = nav.heldList, h.isSame(e) { return i }
        }
        for i in parts.indices { if let e = element(of: i), nav.isWithin(e), nav.isHolding == false, nav.cursorWindow != nil { return i } }
        return nil
    }

    private func isInside(_ x: AXUIElement, _ root: AXUIElement) -> Bool {
        var p: AXUIElement? = x; var hops = 0
        while let e = p, hops < 40 { if e.isSame(root) { return true }; p = e.element(kAXParentAttribute); hops += 1 }
        return false
    }

    /// Tab and Shift Tab: the next or previous part, round the end.
    public func step(forward: Bool) {
        guard !parts.isEmpty else { return }
        let cur = currentIndex()
        var i = cur.map { ($0 + (forward ? 1 : -1) + parts.count) % parts.count } ?? (forward ? 0 : parts.count - 1)
        // A part not on screen now (a hidden sidebar) is skipped.
        var tries = 0
        while element(of: i) == nil, tries < parts.count { i = (i + (forward ? 1 : -1) + parts.count) % parts.count; tries += 1 }
        go(to: i)
    }

    /// Command Control 1 to 9.
    public func go(to i: Int) {
        guard parts.indices.contains(i) else { Tones.edge(); return }
        guard let e = element(of: i) else { Tones.edge(); Speech.speakMessage(String(localized: "\(parts[i].name) is not on screen", comment: "Spoken message: %@ is a part of the window")); return }
        let part = parts[i]
        let obj = ObjectFactory.make(e)
        var settable: DarwinBoolean = false
        let takesKeys = AXUIElementIsAttributeSettable(e, kAXFocusedAttribute as CFString, &settable) == .success && settable.boolValue
        Log.io("panes: to \(part.name) (\(e.role), takes the keyboard \(takesKeys))")
        ObjectNavigator.shared.releaseHold()
        if takesKeys, e.set(kAXFocusedAttribute, kCFBooleanTrue) == .success {
            // The focus event reads the element; the part's name first.
            Speech.speakMessage(part.name)
        } else if !e.elements(kAXRowsAttribute).isEmpty {
            ObjectNavigator.shared.enterHold(e, name: part.name)
        } else {
            Speech.speakMessage(part.name)
            ObjectNavigator.shared.focusMoved(to: e, pid: pid)
            ObjectNavigator.shared.reportCurrent()
        }
        if let h = part.hint, !hinted.contains(i) { hinted.insert(i); Hints.schedule(h) }
        _ = obj
    }

    /// Where you are, in words.
    public func whereAmI() -> String {
        guard let i = currentIndex() else { return "not in a part of \(parts.map(\.name).joined(separator: ", "))" }
        return "\(parts[i].name), part \(i + 1) of \(parts.count)"
    }
}
