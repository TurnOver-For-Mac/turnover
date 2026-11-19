// SPDX-License-Identifier: GPL-3.0-or-later
// What a script is given for an item on the screen (docs/PLUGIN-SCRIPTS-PLAN.md, "The script interface, version 1";
// stage 3, 15 Nov 2026): a copy of what was true when it was made, with a handle to ask more about it, and the table
// that keeps the handles of one plugin. The copy is made from Accessibility's own attributes in one question to the app.
// A secure field's value is never read into it.
import Foundation
import ApplicationServices
import TurnOverAX

/// The copy of an item that a script is given.
nonisolated public struct ScriptItem: Equatable, Sendable {
    /// The role in the words a profile.json match uses: "button", "radioButton", "textField" (the accessibility role
    /// without its "AX", first letter small). `ElementMatcher.roleMatches` accepts it for the role it came from.
    public var role = ""
    public var axRole = ""
    public var subrole = ""
    public var name = ""
    /// Empty for a secure field, always.
    public var value = ""
    public var description = ""
    public var help = ""
    public var identifier = ""
    /// Words: "focused", "selected", "disabled", "expanded", "collapsed", "checked", "mixed".
    public var states: [String] = []
    /// The title of the window it is in.
    public var window = ""
    /// A password field. A plugin sees it as it is, but never what is in it, and cannot type into it.
    public var secure = false

    /// The most characters of a value or a name a script is given: a text area can hold a book.
    public static let valueLimit = 8_000
    public static let textLimit = 1_000

    /// "AXRadioButton" is "radioButton": the accessibility role as a match's `role` is written.
    nonisolated public static func roleWord(_ axRole: String) -> String {
        let bare = axRole.hasPrefix("AX") ? String(axRole.dropFirst(2)) : axRole
        return bare.prefix(1).lowercased() + bare.dropFirst()
    }

    /// Whether this element is a password field, from its subrole (or role, where an app puts it there).
    nonisolated public static func isSecure(subrole: String?, role: String?) -> Bool {
        subrole == "AXSecureTextField" || role == "AXSecureTextField"
    }

    nonisolated static let attributeNames = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute,
                                             kAXHelpAttribute, kAXIdentifierAttribute, kAXEnabledAttribute, kAXFocusedAttribute,
                                             kAXSelectedAttribute, kAXExpandedAttribute]

    /// Read an item: one question for its attributes, one for its window's title.
    public static func read(_ element: AXUIElement) -> ScriptItem {
        let a = element.attrs(attributeNames)
        func text(_ key: String, limit: Int = textLimit) -> String {
            guard let s = a[key] as? String else { return "" }
            return String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
        }
        var item = ScriptItem()
        item.axRole = (a[kAXRoleAttribute] as? String) ?? ""
        item.role = roleWord(item.axRole)
        item.subrole = (a[kAXSubroleAttribute] as? String) ?? ""
        item.secure = isSecure(subrole: item.subrole, role: item.axRole)
        item.name = text(kAXTitleAttribute)
        if item.name.isEmpty { item.name = text(kAXDescriptionAttribute) }
        item.description = text(kAXDescriptionAttribute)
        item.help = text(kAXHelpAttribute)
        item.identifier = text(kAXIdentifierAttribute)
        if !item.secure {
            if let s = a[kAXValueAttribute] as? String { item.value = String(s.prefix(valueLimit)) }
            else if let n = a[kAXValueAttribute] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
                item.value = n.doubleValue == n.doubleValue.rounded() && abs(n.doubleValue) < 1e15 ? String(n.intValue) : String(n.doubleValue)
            }
        }
        var states: [String] = []
        if (a[kAXEnabledAttribute] as? Bool) == false { states.append("disabled") }
        if (a[kAXFocusedAttribute] as? Bool) == true { states.append("focused") }
        if (a[kAXSelectedAttribute] as? Bool) == true { states.append("selected") }
        if let expanded = a[kAXExpandedAttribute] as? Bool { states.append(expanded ? "expanded" : "collapsed") }
        if ["AXCheckBox", "AXRadioButton", "AXMenuItem"].contains(item.axRole), let n = a[kAXValueAttribute] as? NSNumber {
            if n.intValue == 2 { states.append("mixed") } else if n.intValue != 0 { states.append("checked") }
        }
        item.states = states
        if let window = element.element(kAXWindowAttribute) { item.window = String((window.string(kAXTitleAttribute) ?? "").prefix(textLimit)) }
        return item
    }

    /// As the wire carries it, with the handle the script asks more about it by.
    public func value(handle: String) -> ScriptValue {
        .object(["handle": .string(handle), "role": .string(role), "axRole": .string(axRole), "subrole": .string(subrole), "name": .string(name),
                 "value": .string(value), "description": .string(description), "help": .string(help), "identifier": .string(identifier),
                 "states": .array(states.map { .string($0) }), "window": .string(window), "secure": .bool(secure)])
    }
}

/// The handles one plugin has been given: at most `capacity`, the oldest dropped. A handle is a word the plugin
/// cannot make up from another's; it names an element only in this table, so a plugin cannot ask about an item it was
/// not given. Main thread only, as the broker is.
package final class ScriptHandleTable {
    package static let capacity = 512
    private let capacity: Int
    private var byElement: [ElementKey: String] = [:]
    private var byHandle: [String: AXUIElement] = [:]
    private var order: [String] = []
    private var counter = 0

    package init(capacity: Int = ScriptHandleTable.capacity) { self.capacity = capacity }

    package var count: Int { order.count }

    /// The handle for an element: the one it already has (made the newest again), or a new one.
    package func handle(for element: AXUIElement) -> String {
        let key = ElementKey(element)
        if let existing = byElement[key] {
            order.removeAll { $0 == existing }; order.append(existing)
            return existing
        }
        counter += 1
        let handle = "h\(counter)"
        byElement[key] = handle; byHandle[handle] = element; order.append(handle)
        while order.count > capacity {
            let oldest = order.removeFirst()
            if let dropped = byHandle.removeValue(forKey: oldest) { byElement.removeValue(forKey: ElementKey(dropped)) }
        }
        return handle
    }

    package func element(for handle: String) -> AXUIElement? { byHandle[handle] }
}
