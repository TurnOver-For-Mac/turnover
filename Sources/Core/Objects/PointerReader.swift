// SPDX-License-Identifier: GPL-3.0-or-later
// What is under the mouse pointer, worked out entirely on the lookup queue and handed to the main thread as finished
// words. The maintainer asked that all of the pointer's reading stay off the main thread, so a slow app cannot freeze
// TurnOver ten times a second; the keyboard path's object classes and speech rules need main-actor state, so this is
// a smaller reader of its own that uses plain accessibility calls only.
//
// What it does NOT do, compared with the keyboard path (ObjectFactory and Speech.objectPropertiesSpeech), 10 Nov 2026:
// - the ObjectFactory subclasses' app-specific names, roles and values (Mail, Excel, Finder, Calendar, Dock,
//   Terminal, Word and the rest);
// - plugin and ProfileStore label overrides;
// - the per-app verbosity order and the item-detail toggles: the order is name, role, value, states, then a group's count;
// - the placeholder, SwiftUI label and window-button name fallbacks;
// - the long check box label reordering;
// - the progress bar watch;
// - the "VO Shift Down goes in." hint, and a group's count is its children, not the keyboard's group walk;
// - position information ("2 of 5") and shortcuts.
// A name the keyboard path would find by other means can be missing here: the role word alone is said then.
import Foundation
import ApplicationServices

/// Everything the words are made of, as plain values, so the wording is tested without an accessibility server.
nonisolated package struct PointerSnapshot: Sendable, Equatable {
    package init() {}
    package var axRole = ""
    package var subrole = ""
    package var title = ""
    package var description = ""
    package var value = ""
    /// A number the control holds as its value (a check box's 0, 1 or 2).
    package var number: Int?
    package var help = ""
    /// The app's own, localized, word for the role.
    package var roleDescription = ""
    package var enabled = true
    package var selected = false
    package var expanded: Bool?
    /// What a group holds, when it was counted in time.
    package var groupItemCount: Int?
    package var isGroup = false

    package var isSecure: Bool { subrole == "AXSecureTextField" }
}

/// What the lookup queue made: handed to main once, then only main touches the element.
nonisolated package struct PointerReading: @unchecked Sendable {
    // An AXUIElement is not Sendable. It is made on the lookup queue, handed to the main thread once, and the queue
    // does not touch it again: one owner at a time.
    package let element: AXUIElement
    package let text: String
}

nonisolated package enum PointerReader {
    /// Roles whose number is a state (checked, selected, expanded), not a value.
    private static let numberStates: Set<String> = ["AXCheckBox", "AXRadioButton", "AXMenuItem", "AXTab", "AXDisclosureTriangle"]
    /// Roles whose value is a state, not words: never said as a value.
    private static let silentValues: Set<String> = ["AXCheckBox", "AXRadioButton", "AXLink", "AXMenuItem", "AXApplication", "AXBusyIndicator"]
    /// Containers with nothing to say of their state when the app calls them disabled.
    private static let neverUnavailable: Set<String> = ["AXList", "AXGroup", "AXScrollArea", "AXSplitGroup", "AXStaticText", "AXImage",
        "AXToolbar", "AXTable", "AXOutline", "AXWindow", "AXWebArea", "AXLayoutArea", "AXLayoutItem", "AXUnknown", "AXCell", "AXRow", "AXTabGroup"]
    private static let groupRoles: Set<String> = ["AXToolbar", "AXBrowser", "AXTabGroup", "AXRadioGroup", "AXGrid"]
    private static let longestValue = 300
    /// How long one accessibility question may take before the app is given up on.
    static let messagingTimeout: Float = 0.3

    // MARK: Words

    /// The spoken text: name, role, value, states, and a group's count.
    package static func compose(_ s: PointerSnapshot) -> String {
        // A text is its words ("Home", not "Home, text"). Never a secure field's.
        if s.axRole == "AXStaticText", !s.isSecure, !s.value.isEmpty { return s.value }
        let name = [s.title, s.description].first { !$0.isEmpty } ?? ""
        var parts: [String] = []
        if !name.isEmpty { parts.append(name) }
        // The app's own words for the role, never "unknown" (it tells nothing).
        let role = roleWord(s)
        if s.axRole != "AXStaticText", !role.isEmpty, role.lowercased() != "unknown" { parts.append(role) }
        // (Not a value that only repeats the name, nor one the role keeps as a state, nor a protected one.)
        if !s.isSecure, !silentValues.contains(s.axRole), !s.value.isEmpty, s.value != name,
           !(s.number != nil && numberStates.contains(s.axRole)) { parts.append(s.value) }
        parts.append(contentsOf: stateWords(s))
        if let n = s.groupItemCount, s.isGroup { parts.append(Phrases.items(n)) }
        if parts.isEmpty { return role }
        return parts.joined(separator: ", ")
    }

    private static func roleWord(_ s: PointerSnapshot) -> String {
        if !s.roleDescription.isEmpty { return s.roleDescription }
        if s.axRole.hasPrefix("AX"), s.axRole.count > 2 { return String(s.axRole.dropFirst(2)).lowercased() }
        return s.axRole == "?" ? "" : s.axRole
    }

    private static func stateWords(_ s: PointerSnapshot) -> [String] {
        var out: [String] = []
        let n = s.number ?? 0
        switch s.axRole {
        case "AXCheckBox", "AXRadioButton":
            if s.number != nil { out.append(n == 2 ? State.halfChecked.displayString : n != 0 ? State.checked.displayString : State.checked.negativeDisplayString) }
        case "AXMenuItem":
            if n != 0 { out.append(n == 2 ? State.halfChecked.displayString : State.checked.displayString) }
        case "AXDisclosureTriangle":
            out.append(n != 0 ? State.expanded.displayString : State.collapsed.displayString)
        case "AXTab":
            if n != 0 { out.append(State.selected.displayString) }
        default:
            if s.subrole == "AXSwitch" { out.append(n != 0 ? State.on.displayString : State.on.negativeDisplayString) }
            else if s.subrole == "AXToggle", n != 0 { out.append(State.pressed.displayString) }
        }
        if s.selected, !out.contains(State.selected.displayString) { out.append(State.selected.displayString) }
        if s.axRole != "AXDisclosureTriangle", let e = s.expanded, ["AXPopUpButton", "AXComboBox", "AXMenuButton", "AXRow", "AXButton"].contains(s.axRole) {
            // (Chromium reports every button as not expanded: only an expanded one is news.)
            if e || s.axRole != "AXButton" { out.append(e ? State.expanded.displayString : State.collapsed.displayString) }
        }
        if !s.enabled, !neverUnavailable.contains(s.axRole) { out.append(State.unavailable.displayString) }
        return out
    }

    // MARK: Reading

    /// The reading of an element, or nil when the deadline has already gone. Runs on the lookup queue. `countsGroups`
    /// is the "moves by groups" setting, read on main by the caller.
    package static func read(_ e: AXUIElement, deadline: Date, countsGroups: Bool = true) -> PointerReading? {
        guard Date() < deadline else { return nil }
        AXUIElementSetMessagingTimeout(e, messagingTimeout)
        var s = snapshot(e)
        if countsGroups, Date() < deadline, isGroup(e, s) {
            s.isGroup = true
            // The children, in one question: not the keyboard's walk of every item, which a pointer sweep cannot wait on.
            var count: CFIndex = 0
            if AXUIElementGetAttributeValueCount(e, kAXChildrenAttribute as CFString, &count) == .success, Date() < deadline { s.groupItemCount = count }
        }
        return PointerReading(element: e, text: compose(s))
    }

    private static func snapshot(_ e: AXUIElement) -> PointerSnapshot {
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
                     kAXHelpAttribute, kAXRoleDescriptionAttribute, kAXEnabledAttribute, kAXSelectedAttribute, kAXExpandedAttribute]
        let a = e.attrs(names)
        func text(_ k: String) -> String { (a[k] as? String) ?? "" }
        var s = PointerSnapshot()
        s.axRole = text(kAXRoleAttribute).isEmpty ? "?" : text(kAXRoleAttribute)
        s.subrole = text(kAXSubroleAttribute)
        s.title = text(kAXTitleAttribute)
        s.description = text(kAXDescriptionAttribute)
        s.help = text(kAXHelpAttribute)
        s.roleDescription = text(kAXRoleDescriptionAttribute)
        if let v = a[kAXValueAttribute] {
            if let str = v as? String { s.value = String(str.prefix(longestValue)) }
            else if let n = v as? NSNumber {
                s.number = n.intValue
                if !numberStates.contains(s.axRole), s.subrole != "AXSwitch", s.subrole != "AXToggle" { s.value = n.stringValue }
            }
        }
        s.enabled = (a[kAXEnabledAttribute] as? Bool) ?? true
        s.selected = (a[kAXSelectedAttribute] as? Bool) ?? false
        s.expanded = a[kAXExpandedAttribute] as? Bool
        return s
    }

    /// A group the way the keyboard path has it, from what is already read: a listed container, or a named layout one
    /// holding two or more items. A table, list, outline or web page is said as itself.
    private static func isGroup(_ e: AXUIElement, _ s: PointerSnapshot) -> Bool {
        if groupRoles.contains(s.axRole) { return true }
        guard ObjectNavigator.layoutRoles.contains(s.axRole), !s.title.isEmpty || !s.description.isEmpty else { return false }
        var count: CFIndex = 0
        return AXUIElementGetAttributeValueCount(e, kAXChildrenAttribute as CFString, &count) == .success && count >= 2
    }
}
