// SPDX-License-Identifier: GPL-3.0-or-later
// VoiceOver's Item Chooser (VO-I), anywhere TurnOver leads: every item in the window (or every line of the page,
// in browse mode) in reading order, in a list that narrows as you type. Enter goes there: the focus if the item
// can take it, otherwise the object navigator (or, on a page, the reading position).
import Foundation
import AppKit
import ApplicationServices

public enum ItemChooser {
    private static let walkQueue = DispatchQueue(label: "turnover.itemchooser", qos: .userInitiated)

    public static func open() {
        if let d = API.focusTreeInterceptor, !d.passThrough { d.openItemChooser(); return }
        collect { found in
            TurnOverMenu.shared.openChooser("Items", items: found.map { f in MenuItem(verbatim: f.label, .action { go(to: f.element) }) })
        }
    }

    /// VoiceOver's Rotor (VO-U) for a window: its items by kind. (On a page, browse mode's own rotor answers first.)
    public static func openRotor() {
        collect { found in
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
                (name: name, items: found.filter { test($0.role, $0.subrole) }.map { f in MenuItem(verbatim: f.label, .action { go(to: f.element) }) })
            }
            TurnOverMenu.shared.openRotor(groups)
        }
    }

    struct Found { let element: AXUIElement; let label: String; let role: String; let subrole: String }

    /// The focused window's items in reading order, walked off the main thread (a window can hold thousands of
    /// elements, Mail's message list; a slow walk on the main thread trips the watchdog). Delivered on the main thread.
    private static func collect(_ done: @escaping @MainActor ([Found]) -> Void) {
        guard let f = API.focusObject, let window = f.element.element(kAXWindowAttribute) ?? (f.role == .window ? f.element : nil) else {
            Speech.speakMessage(String(localized: "no items", comment: "Spoken message")); return
        }
        walkQueue.async {
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
            DispatchQueue.main.async { done(found) }
        }
    }

    private static func go(to e: AXUIElement) {
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(e, kAXFocusedAttribute as CFString, &settable) == .success, settable.boolValue,
           e.set(kAXFocusedAttribute, kCFBooleanTrue) == .success { return }   // the focus event reads it
        ObjectNavigator.shared.focusMoved(to: e, pid: e.pid)
        ObjectNavigator.shared.reportCurrent()
    }
}
