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
        public init(attributes: [String: AXSnapshotValue], actions: [String] = [], settable: [String: Bool] = [:]) {
            self.attributes = attributes; self.actions = actions; self.settable = settable
        }
    }
    public let nodes: [ElementKey: Node]
    public init(nodes: [ElementKey: Node]) { self.nodes = nodes }
    /// This snapshot with another's elements added (a page read on: the rest of it, collected later); where both have
    /// an element, the later one's.
    public func merging(_ later: AXSnapshot) -> AXSnapshot { AXSnapshot(nodes: nodes.merging(later.nodes) { _, new in new }) }

    /// Synchronous, thread-local interpretation, never held across await. Absent attributes stay absent: a
    /// presentation rule cannot accidentally make a live provider call while the keyboard is waiting on main.
    ///
    /// `liveForMissing`: an element the snapshot holds is answered from it, and one it does not hold is asked of the
    /// app. Only for reading on past the end of what was collected (a page longer than one collection, issue 227),
    /// which reads the rest on main as build 24 did; never for a page's first reading.
    public func with<Value>(liveForMissing: Bool = false, _ body: () throws -> Value) rethrows -> Value {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[Self.key]
        dictionary[Self.key] = Scope(self, liveForMissing: liveForMissing)
        defer { if let previous { dictionary[Self.key] = previous } else { dictionary.removeObject(forKey: Self.key) } }
        return liveForMissing ? try body() : try AXReadScope.with(while: { false }, body)
    }

    private final class Scope {
        let snapshot: AXSnapshot
        let liveForMissing: Bool
        init(_ snapshot: AXSnapshot, liveForMissing: Bool) { self.snapshot = snapshot; self.liveForMissing = liveForMissing }
    }
    private static let key = "com.turnover.ax.snapshot"
    static var current: AXSnapshot? { (Thread.current.threadDictionary[key] as? Scope)?.snapshot }
    /// The snapshot that answers for `element` here: the scope's, unless it lets missing elements be asked live and
    /// this is one.
    static func serving(_ element: AXUIElement) -> AXSnapshot? {
        guard let scope = Thread.current.threadDictionary[key] as? Scope else { return nil }
        if scope.liveForMissing, scope.snapshot.nodes[ElementKey(element)] == nil { return nil }
        return scope.snapshot
    }
    /// Inside a strict scope (`with()`), whether `element` was collected: an element that was not reads as empty.
    public static func holds(_ element: AXUIElement) -> Bool {
        guard let scope = Thread.current.threadDictionary[key] as? Scope else { return true }
        return scope.liveForMissing || scope.snapshot.nodes[ElementKey(element)] != nil
    }
    func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? { nodes[ElementKey(element)]?.attributes[name]?.value }
}
