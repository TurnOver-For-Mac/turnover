// SPDX-License-Identifier: GPL-3.0-or-later
// VoiceOver's Item Chooser (VO-I), anywhere TurnOver leads: every item in the window (or every line of the page,
// in browse mode) in reading order, in a list that narrows as you type. Enter goes there: the focus if the item
// can take it, otherwise the object navigator (or, on a page, the reading position).
import Foundation
import AppKit
import ApplicationServices
import TurnOverAX

public enum ItemChooser {
    private static let walkQueue = DispatchQueue(label: "turnover.itemchooser", qos: .userInitiated)

    public static func open() {
        if let d = API.focusTreeInterceptor, !d.passThrough { d.openItemChooser(); return }
        var generation = 0
        collect { found, isFill in
            let items = found.map { f in MenuItem(verbatim: f.label, .action { go(to: f.element) }, tag: f.tag) }
            if isFill { TurnOverMenu.shared.refillChooser(generation: generation, items: items); return }
            TurnOverMenu.shared.openChooser("Items", items: items)
            generation = TurnOverMenu.shared.listGeneration
        }
    }

    /// VoiceOver's Rotor (VO-U) for a window: its items by kind. (On a page, browse mode's own rotor answers first.)
    public static func openRotor() {
        var generation = 0
        collect { found, isFill in
            let kinds: [(String, (String, String) -> Bool)] = [
                ("Buttons", { r, _ in ["AXButton", "AXMenuButton", "AXDisclosureTriangle"].contains(r) }),
                ("Text fields", { r, _ in ["AXTextField", "AXTextArea", "AXComboBox"].contains(r) }),
                ("Check boxes and radio buttons", { r, sub in ["AXCheckBox", "AXRadioButton"].contains(r) && sub != "AXTabButton" }),
                ("Tabs", { _, sub in sub == "AXTabButton" }),
                ("Pop-up menus", { r, _ in r == "AXPopUpButton" }),
                ("Lists and tables", { r, _ in ["AXTable", "AXOutline", "AXList", "AXBrowser"].contains(r) }),
                ("Links", { r, _ in r == "AXLink" }),
                ("Headings", { r, _ in r == "AXHeading" }),
                ("Text", { r, _ in r == "AXStaticText" }),
            ]
            let groups = kinds.map { (name, test) in
                (name: name, items: found.filter { test($0.role, $0.subrole) }.map { f in MenuItem(verbatim: f.label, .action { go(to: f.element) }, tag: f.tag) })
            }
            if isFill { TurnOverMenu.shared.refillRotor(generation: generation, categories: groups); return }
            TurnOverMenu.shared.openRotor(groups)
            generation = TurnOverMenu.shared.listGeneration
        }
    }

    nonisolated package struct Found: Sendable {
        package let element: AXUIElement; package let label: String; package let role: String; package let subrole: String
        /// Which thing this is across the two lists of one opening (what is on screen, then everything): see `tagged`.
        package var tag: Int? = nil
    }

    /// `defaults write com.turnover.reader itemChooserOldWalk -bool true` goes back to the walk used until build 24,
    /// for comparing the two by ear and as the way back if the snapshot misleads in some app.
    nonisolated static var usesOldWalk: Bool { UserDefaults.standard.bool(forKey: "itemChooserOldWalk") }

    /// The focused window's items in reading order, collected off the main thread (a window can hold thousands of
    /// elements, Mail's message list; a slow walk on the main thread trips the watchdog). Delivered on the main thread:
    /// first what is on screen, so the list opens at once, and then, if rows were scrolled out of sight, everything,
    /// to fill the open list in (`isFill`). Oliver's idea, 10 Nov 2026: Mail's list opened after two seconds, cut
    /// short; its on-screen part takes a tenth of that.
    private static func collect(_ done: @escaping @MainActor (_ found: [Found], _ isFill: Bool) -> Void) {
        guard let f = API.focusObject, let window = f.element.element(kAXWindowAttribute) ?? (f.role == .window ? f.element : nil) else {
            Speech.speakMessage(String(localized: "no items", comment: "Spoken message")); return
        }
        walkQueue.async {
            func timedItems(_ body: () -> (items: [Found], note: String, rowsLeftOut: Int)) -> (items: [Found], line: String, rowsLeftOut: Int) {
                let started = DispatchTime.now().uptimeNanoseconds
                let found = body()
                let ms = Double(DispatchTime.now().uptimeNanoseconds &- started) / 1e6
                return (found.items, String(format: "item chooser: %d items in %.0f ms (%@)", found.items.count, ms, found.note), found.rowsLeftOut)
            }
            if usesOldWalk {
                let old = timedItems { let w = oldWalkItems(in: window); return (w.items, w.note, 0) }
                DispatchQueue.main.async { Log.info(old.line); done(old.items, false) }
                return
            }
            let first = timedItems { snapshotItems(in: window, onScreenRowsOnly: true) }
            let shown = tagged(first.items, after: [])
            guard first.rowsLeftOut > 0 else {
                DispatchQueue.main.async { Log.info(first.line); done(shown, false) }
                return
            }
            // The list waits a moment for the rows out of sight, so that it opens saying the full count when they
            // come quickly ("Items, 77 items" and then "2 of 87" 40 ms later, Oliver's trial in Mail, 10 Nov 2026).
            // When they do not come within `openHold`, it opens on what is on screen and is filled in as before.
            let opening = Opening()
            DispatchQueue.main.asyncAfter(deadline: .now() + openHold) {
                guard !opening.opened else { return }
                opening.opened = true
                Log.info(first.line); done(shown, false)
            }
            let rest = timedItems { snapshotItems(in: window) }
            let all = tagged(rest.items, after: shown)
            DispatchQueue.main.async {
                // Never a shorter list than the one on screen: the fuller read can be cut short by its time limit.
                let fuller = all.count > shown.count
                if !opening.opened {
                    opening.opened = true
                    Log.info(first.line)
                    if fuller { Log.info(rest.line + ", with \(first.rowsLeftOut) rows out of sight, before the list opened") }
                    done(fuller ? all : shown, false)
                } else if fuller {
                    Log.info(rest.line + ", filling in \(first.rowsLeftOut) rows out of sight")
                    done(all, true)
                }
            }
        }
    }

    /// How long the list waits for the rows out of sight before opening without them.
    nonisolated static let openHold = 0.12
    /// Whether this opening's list has been shown yet. Main thread only.
    private final class Opening { var opened = false }

    /// Tags for the second list that agree with the first: an element in both keeps its tag, so the open list's
    /// cursor stays where it was when the fuller list arrives.
    nonisolated package static func tagged(_ items: [Found], after earlier: [Found]) -> [Found] {
        var known: [ElementKey: Int] = [:]
        for item in earlier { if let tag = item.tag { known[ElementKey(item.element)] = tag } }
        var next = (earlier.compactMap(\.tag).max() ?? -1) + 1
        return items.map { item in
            var item = item
            if let tag = known[ElementKey(item.element)] { item.tag = tag } else { item.tag = next; next += 1 }
            return item
        }
    }

    /// The first user of the window snapshot (10 Nov 2026): one batched question an element copies the window, and
    /// the items are then picked from the copy. The old walk asked the same batched question and then several more
    /// of every element to decide whether it was an item; on a 5,774-element Notes window that was 57,740 questions
    /// against 5,775. The public batched read only: the private whole-subtree read can time out and leave an app
    /// busy (AXHierarchyBridge), which a list the user is waiting for must not risk.
    nonisolated package static func snapshotItems(in window: AXUIElement, onceByName: Bool = true, onScreenRowsOnly: Bool = false) -> (items: [Found], note: String, rowsLeftOut: Int) {
        let snapshot = AXSnapshotCapture.capture(window, limits: AXSnapshotLimits(maxNodes: 6000, maxDepth: 200, seconds: 2), onScreenRowsOnly: onScreenRowsOnly)
        // Two seconds for the copy, not the old walk's two and a half: picking the items from a very large copy
        // still asks a few elements for their actions (Notes, 3,800 elements: 0.6 s more, 10 Nov 2026).
        let items = SnapshotItems.chooserItems(snapshot, live: .reader, onceByName: onceByName)
        let note = "snapshot of \(snapshot.nodes.count) elements in \(Int(snapshot.milliseconds)) ms, \(snapshot.questions) questions, stop \(snapshot.stop?.rawValue ?? "none")"
        return (items, note, snapshot.rowsLeftOut)
    }

    /// The walk as it was until build 24, kept whole: the tests hold the snapshot to it on every recorded window.
    nonisolated package static func oldWalkItems(in window: AXUIElement) -> (items: [Found], note: String) {
        let deadline = Date().addingTimeInterval(2.5)
        let names = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXRoleDescriptionAttribute, kAXChildrenAttribute, kAXSubroleAttribute] as CFArray
        let containers: Set<String> = ["AXTable", "AXOutline", "AXList", "AXBrowser", "AXHeading"]
        var found: [Found] = []
        var stack: [AXUIElement] = [window]
        var visited = 0
        while let e = stack.popLast(), visited < 6000, found.count < 1500, Date() < deadline {
            visited += 1
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(e, names, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
                  let v = values as? [AnyObject], v.count == 7 else { continue }
            let role = v[0] as? String ?? ""
            let sub = v[6] as? String ?? ""
            if !ObjectNavigator.skippedRoles.contains(role), role != "AXWindow", containers.contains(role) || ObjectNavigator.isItem(e) {
                let name = [v[1], v[2]].compactMap { $0 as? String }.first { !$0.isEmpty } ?? (v[3] as? String).map { String($0.prefix(120)) } ?? ""
                let kind = v[4] as? String ?? ""
                let label = [name.isEmpty ? "" : name, kind].filter { !$0.isEmpty }.joined(separator: ", ")
                if !name.isEmpty || containers.contains(role) { found.append(Found(element: e, label: label, role: role, subrole: sub)) }
            }
            if let kids = v[5] as? [AXUIElement] { stack.append(contentsOf: kids.reversed()) }
        }
        return (found, "old walk")
    }

    private static func go(to e: AXUIElement) {
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(e, kAXFocusedAttribute as CFString, &settable) == .success, settable.boolValue,
           e.set(kAXFocusedAttribute, kCFBooleanTrue) == .success { return }   // the focus event reads it
        ObjectNavigator.shared.focusMoved(to: e, pid: e.pid)
        ObjectNavigator.shared.reportCurrent()
    }
}
