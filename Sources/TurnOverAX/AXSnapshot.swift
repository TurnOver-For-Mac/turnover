// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices

/// Immutable values captured on an AX worker. No untyped Foundation containers cross the worker boundary.
public indirect enum AXSnapshotValue: Sendable {
    case string(String), number(Double), bool(Bool), element(AXUIElement), array([AXSnapshotValue])
    case attributedString(String), url(URL), date(Date), point(CGPoint), size(CGSize), rect(CGRect), range(CFRange)

    public init?(_ value: CFTypeRef) {
        if CFGetTypeID(value) == AXUIElementGetTypeID() { self = .element(value as! AXUIElement) }
        else if CFGetTypeID(value) == CFBooleanGetTypeID() { self = .bool((value as! NSNumber).boolValue) }
        else if let s = value as? String { self = .string(s) }
        else if let n = value as? NSNumber { self = .number(n.doubleValue) }
        else if let s = value as? NSAttributedString { self = .attributedString(s.string) }
        else if let u = value as? URL { self = .url(u) }
        else if let d = value as? Date { self = .date(d) }
        else if let a = value as? [AnyObject] { self = .array(a.compactMap { AXSnapshotValue($0) }) }
        else if CFGetTypeID(value) == AXValueGetTypeID() {
            let v = value as! AXValue
            switch AXValueGetType(v) {
            case .cgPoint: var p = CGPoint.zero; guard AXValueGetValue(v, .cgPoint, &p) else { return nil }; self = .point(p)
            case .cgSize: var s = CGSize.zero; guard AXValueGetValue(v, .cgSize, &s) else { return nil }; self = .size(s)
            case .cgRect: var r = CGRect.zero; guard AXValueGetValue(v, .cgRect, &r) else { return nil }; self = .rect(r)
            case .cfRange: var r = CFRange(); guard AXValueGetValue(v, .cfRange, &r) else { return nil }; self = .range(r)
            default: return nil
            }
        } else { return nil }
    }

    public var value: CFTypeRef {
        switch self {
        case .string(let s): return s as CFString
        case .number(let n): return NSNumber(value: n)
        case .bool(let b): return b ? kCFBooleanTrue : kCFBooleanFalse
        case .element(let e): return e
        case .array(let a): return a.map(\.value) as CFArray
        case .attributedString(let s): return NSAttributedString(string: s)
        case .url(let u): return u as CFURL
        case .date(let d): return d as CFDate
        case .point(var p): return AXValueCreate(.cgPoint, &p)!
        case .size(var s): return AXValueCreate(.cgSize, &s)!
        case .rect(var r): return AXValueCreate(.cgRect, &r)!
        case .range(var r): return AXValueCreate(.cfRange, &r)!
        }
    }
}

public struct AXSnapshot: Sendable {
    public struct Node: Sendable {
        public let attributes: [String: AXSnapshotValue]
        public let actions: [String]
        public let settable: [String: Bool]
        /// Collected with the short list only (`AXSnapshot.plainNames`): a page's plain text or plain group. Anything
        /// else asked of it reads as absent, and is counted (`takeMissed`), so a rule that comes to need more shows.
        public let isPlain: Bool
        public init(attributes: [String: AXSnapshotValue], actions: [String] = [], settable: [String: Bool] = [:], isPlain: Bool = false) {
            self.attributes = attributes; self.actions = actions; self.settable = settable; self.isPlain = isPlain
        }
    }
    public let nodes: [ElementKey: Node]
    public init(nodes: [ElementKey: Node]) { self.nodes = nodes }
    /// This snapshot with another's elements added (a page read on: the rest of it, collected later); where both have
    /// an element, the later one's.
    public func merging(_ later: AXSnapshot) -> AXSnapshot { AXSnapshot(nodes: nodes.merging(later.nodes) { _, new in new }) }

    /// Synchronous, thread-local interpretation, never held across await. Absent attributes stay absent: a
    /// presentation rule cannot accidentally make a live provider call while the keyboard is waiting on main.
    public func with<Value>(_ body: () throws -> Value) rethrows -> Value {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[Self.key]
        dictionary[Self.key] = Scope(self)
        defer { if let previous { dictionary[Self.key] = previous } else { dictionary.removeObject(forKey: Self.key) } }
        return try AXReadScope.with(while: { false }, body)
    }

    private final class Scope {
        let snapshot: AXSnapshot
        init(_ snapshot: AXSnapshot) { self.snapshot = snapshot }
    }
    private static let key = "com.turnover.ax.snapshot"
    static var current: AXSnapshot? { (Thread.current.threadDictionary[key] as? Scope)?.snapshot }
    /// Inside a snapshot scope, whether the element was collected.
    public static func holds(_ element: AXUIElement) -> Bool {
        guard let current else { return true }
        return current.nodes[ElementKey(element)] != nil
    }
    /// What is collected of a page's plain texts and plain groups, which are most of a page: what reading a page asks
    /// of them (role, subrole, children, value, title, role description: turnover-coretest --page-needs on Safari and
    /// Claude pages, 10 Nov 2026) and what other rules might (labels, identifiers, state, place). One batched question,
    /// where every attribute an element has, with its names and its actions, was four questions and five times the
    /// time (0.26 ms against 0.05 in Safari), and took a page of 2,900 elements past the two-second limit.
    public static let plainNames: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXChildrenAttribute, kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
        kAXRoleDescriptionAttribute, kAXParentAttribute, kAXWindowAttribute, kAXTitleUIElementAttribute, kAXHelpAttribute,
        kAXIdentifierAttribute, "AXDOMIdentifier", "AXDOMClassList", "AXARIALive", "AXLanguage", "AXBlockQuoteLevel",
        kAXEnabledAttribute, kAXFocusedAttribute, kAXSelectedAttribute, "AXExpanded", "AXElementBusy", kAXURLAttribute,
        kAXPositionAttribute, kAXSizeAttribute, "AXEditableAncestor", kAXIndexAttribute, "AXRowIndexRange",
        "AXColumnIndexRange", "AXRowSpan", "AXColSpan"]
    private static let plainSet = Set(plainNames)
    /// A page's text, its groups with no subrole, its list items, and a table's rows, columns and cells: read with
    /// `plainNames` alone. Browse mode, its text ranges and its tables ask nothing else of these by name (every
    /// attribute they read is in the list; checked in the source, 10 Nov 2026). Lists, tables, headings, links,
    /// landmarks, pictures and every control are read in full.
    public static func isPlain(role: String, subrole: String?) -> Bool {
        switch role {
        case "AXStaticText", "AXCell", "AXRow", "AXColumn": return true
        case "AXGroup": return (subrole ?? "").isEmpty || subrole == "AXListItem"
        default: return false
        }
    }

    private static let missedLock = NSLock()
    // Swift cannot express static NSLock ownership. Every read and write of `missed` holds `missedLock`.
    nonisolated(unsafe) private static var missed: [String: Int] = [:]
    /// Attributes asked of plain elements that were not collected, by name, since the last call: for the log.
    public static func takeMissed() -> [String: Int] {
        missedLock.lock(); defer { missedLock.unlock() }
        let out = missed; missed = [:]
        return out
    }

    func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        let node = nodes[ElementKey(element)]
        if let node, node.isPlain, !Self.plainSet.contains(name) {
            Self.missedLock.lock(); Self.missed[name, default: 0] += 1; Self.missedLock.unlock()
        }
        if let tally = Thread.current.threadDictionary[Self.tallyKey] as? Tally, let node {
            var role = "?"
            if case .string(let r)? = node.attributes[kAXRoleAttribute] { role = r }
            tally.asked[role, default: [:]][name, default: 0] += 1
        }
        return node?.attributes[name]?.value
    }

    // MARK: Counting, for the probes
    private static let tallyKey = "com.turnover.ax.snapshot-tally"
    private final class Tally { var asked: [String: [String: Int]] = [:] }
    /// What is asked of a snapshot's elements on this thread inside `body`: by the element's role, each attribute
    /// name and how often. For measuring what reading a page really needs of each kind of element.
    public static func counting<Value>(_ body: () throws -> Value) rethrows -> (value: Value, asked: [String: [String: Int]]) {
        let dictionary = Thread.current.threadDictionary
        let tally = Tally()
        dictionary[tallyKey] = tally
        defer { dictionary.removeObject(forKey: tallyKey) }
        let value = try body()
        return (value, tally.asked)
    }
}
