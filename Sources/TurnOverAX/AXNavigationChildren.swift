// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices

/// Request-local access to the public linear-navigation representation. AppKit's public navigation-children
/// protocol is available from macOS 10.13; successful empty is authoritative, not unsupported.
/// This reader owns mutable limits on one synchronous worker; it is deliberately not Sendable.
public final class AXNavigationChildren {
    public static let navigationAttribute = "AXChildrenInNavigationOrder"

    public struct Limits: Sendable {
        public var durationNanoseconds: UInt64
        public var queries: Int
        public var nodes: Int
        public var children: Int
        public var depth: Int
        public init(durationNanoseconds: UInt64 = 2_000_000_000, queries: Int = 2048, nodes: Int = 6000,
                    children: Int = 512, depth: Int = 24) {
            self.durationNanoseconds = durationNanoseconds; self.queries = queries
            self.nodes = nodes; self.children = children; self.depth = depth
        }
    }

    public enum Stop: Equatable, Sendable {
        case cancelled, deadline, queryLimit, nodeLimit, childLimit, depthLimit, cycle, malformed
        case query(AXQueryStatus)
    }

    public struct Evidence: Sendable {
        public enum Method: String, Sendable { case empty, prefix, attributeValue, unavailable, failed }
        public let attribute: String
        public let countStatus: AXQueryStatus
        public let valueStatus: AXQueryStatus?
        public let method: Method
        public let rawCount: Int?
    }

    public private(set) var stopped: Stop?
    public private(set) var queryCount = 0
    public private(set) var nodeCount = 0
    public private(set) var navigationReadCount = 0
    public private(set) var ordinaryReadCount = 0
    public private(set) var lastNavigationRead: Evidence?
    public private(set) var lastOrdinaryRead: Evidence?
    private let limits: Limits
    private let current: @Sendable () -> Bool
    private let clock: @Sendable () -> UInt64
    private let startedAt: UInt64
    package struct Source {
        package var count: (AXUIElement, String) -> AXQueryResult<Int> = { $0.attributeValueCountResult($1) }
        package var values: (AXUIElement, String, Int) -> AXQueryResult<CFArray> = { $0.attributeValuesResult($1, index: 0, maxValues: $2) }
        package var value: (AXUIElement, String) -> AXQueryResult<CFTypeRef> = { $0.attributeResult($1) }
        package init() {}
    }
    private let source: Source

    public convenience init(limits: Limits = Limits(), current: @escaping @Sendable () -> Bool = { true },
                clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.init(limits: limits, current: current, clock: clock, source: Source())
    }

    package init(limits: Limits = Limits(), current: @escaping @Sendable () -> Bool = { true },
                 clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }, source: Source) {
        self.limits = limits; self.current = current; self.clock = clock; self.source = source; startedAt = clock()
    }

    @discardableResult
    public func check() -> Bool {
        guard stopped == nil else { return false }
        if !current() { stopped = .cancelled }
        else if clock() &- startedAt >= limits.durationNanoseconds { stopped = .deadline }
        return stopped == nil
    }

    /// A caller traversing children itself can reject a cyclic or over-depth path without publishing partial data.
    public func stop(_ reason: Stop) { if stopped == nil { stopped = reason } }

    /// Both count and bounded prefix reads spend the same query allowance. A provider failure never authorizes
    /// a second representation; only absent/unsupported navigation children permit ordinary-child fallback.
    public func children(of element: AXUIElement) -> [AXUIElement] {
        lastNavigationRead = nil; lastOrdinaryRead = nil
        guard admitNode() else { return [] }
        let navigation = read(element, attribute: Self.navigationAttribute)
        guard check() else { return [] }
        switch navigation {
        case .children(let children): return children
        case .unavailable:
            switch read(element, attribute: kAXChildrenAttribute) {
            case .children(let children): return children
            case .unavailable: return []   // leaves need not implement either optional child attribute
            case .stopped: return []
            }
        case .stopped: return []
        }
    }

    /// Depth-first in the provider's navigation order. Per-path identities detect actual cycles; a shared node
    /// reached through two branches is visited once. Test the root first, as AppStoreView.first has always done.
    public func first(in root: AXUIElement, depth: Int, where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        struct Pending { let element: AXUIElement; let level: Int; let ancestors: Set<ElementKey> }
        var stack = [Pending(element: root, level: 0, ancestors: [])]
        var seen = Set<ElementKey>()
        while let item = stack.popLast(), check() {
            let key = ElementKey(item.element)
            guard !item.ancestors.contains(key) else { stopped = .cycle; return nil }
            guard seen.insert(key).inserted else { continue }
            guard seen.count <= limits.nodes else { stopped = .nodeLimit; return nil }
            guard item.level <= limits.depth else { stopped = .depthLimit; return nil }
            if matches(item.element) { return check() ? item.element : nil }
            guard check() else { return nil }
            if item.level < depth {
                let ancestors = item.ancestors.union([key])
                let children = children(of: item.element)
                guard stack.count + children.count <= limits.nodes else { stopped = .nodeLimit; return nil }
                stack.append(contentsOf: children.reversed().map {
                    Pending(element: $0, level: item.level + 1, ancestors: ancestors)
                })
            }
        }
        return nil
    }

    private enum Read { case children([AXUIElement]), unavailable, stopped }

    private func admitNode() -> Bool {
        guard check() else { return false }
        guard nodeCount < limits.nodes else { stopped = .nodeLimit; return false }
        nodeCount += 1
        return true
    }

    /// Other structural queries in a preview can spend this same allowance. Legacy label helpers outside this
    /// seam are not counted; callers must check cooperatively around them and must not claim a total IPC cap.
    public func query<Value>(_ body: () -> AXQueryResult<Value>) -> AXQueryResult<Value>? {
        guard check() else { return nil }
        guard queryCount < limits.queries else { stopped = .queryLimit; return nil }
        queryCount += 1
        let result = body()
        guard check() else { return nil }
        switch result.status {
        case .returned(.success), .returned(.attributeUnsupported), .returned(.noValue), .returned(.notImplemented): break
        default: stopped = .query(result.status)   // includes backoff, malformed/client-stop and future client statuses
        }
        return result   // preserve the actual failed status for evidence; later queries remain stopped
    }

    private func isUnavailable(_ status: AXQueryStatus) -> Bool {
        if case .returned(let error) = status {
            return error == .attributeUnsupported || error == .noValue || error == .notImplemented
        }
        return false
    }

    private func read(_ element: AXUIElement, attribute: String) -> Read {
        guard let count = query({ source.count(element, attribute) }) else { return .stopped }
        if isUnavailable(count.status) {
            // Some providers expose a public attribute value without implementing count/slice for it. Check that
            // actual value before declaring the representation unavailable; decode only within the same cap.
            return fullValue(element, attribute: attribute, countStatus: count.status)
        }
        guard count.status == .returned(.success) else {
            evidence(attribute, count: count.status, value: nil, method: .failed, size: nil)
            stopped = .query(count.status); return .stopped
        }
        guard let size = count.value, size >= 0 else { stopped = .malformed; return .stopped }
        guard size <= limits.children else {
            evidence(attribute, count: count.status, value: nil, method: .failed, size: size)
            stopped = .childLimit; return .stopped
        }
        if size == 0 {
            evidence(attribute, count: count.status, value: nil, method: .empty, size: 0)
            completed(attribute); return .children([])
        }
        guard let result = query({ source.values(element, attribute, size) }) else { return .stopped }
        if isUnavailable(result.status) { return fullValue(element, attribute: attribute, countStatus: count.status, expected: size) }
        evidence(attribute, count: count.status, value: result.status, method: .prefix, size: size)
        guard result.status == .returned(.success) else { stopped = .query(result.status); return .stopped }
        guard let values = result.value else { stopped = .malformed; return .stopped }
        return decode(values, element: element, expected: size, attribute: attribute)
    }

    private func fullValue(_ element: AXUIElement, attribute: String, countStatus: AXQueryStatus, expected: Int? = nil) -> Read {
        guard let value = query({ source.value(element, attribute) }) else { return .stopped }
        if isUnavailable(value.status) {
            evidence(attribute, count: countStatus, value: value.status, method: .unavailable, size: nil)
            return .unavailable
        }
        guard value.status == .returned(.success) else {
            evidence(attribute, count: countStatus, value: value.status, method: .failed, size: nil)
            stopped = .query(value.status); return .stopped
        }
        guard let raw = value.value, CFGetTypeID(raw) == CFArrayGetTypeID() else {
            evidence(attribute, count: countStatus, value: value.status, method: .failed, size: nil)
            stopped = .malformed; return .stopped
        }
        let values = raw as! CFArray   // type checked; no whole-reply Swift array bridge
        evidence(attribute, count: countStatus, value: value.status, method: .attributeValue, size: CFArrayGetCount(values))
        return decode(values, element: element, expected: expected, attribute: attribute)
    }

    private func evidence(_ attribute: String, count: AXQueryStatus, value: AXQueryStatus?, method: Evidence.Method, size: Int?) {
        let value = Evidence(attribute: attribute, countStatus: count, valueStatus: value, method: method, rawCount: size)
        if attribute == Self.navigationAttribute { lastNavigationRead = value }
        else { lastOrdinaryRead = value }
    }

    private func completed(_ attribute: String) {
        if attribute == Self.navigationAttribute { navigationReadCount += 1 }
        else { ordinaryReadCount += 1 }
    }

    private func decode(_ values: CFArray, element: AXUIElement, expected: Int?, attribute: String) -> Read {
        guard CFGetTypeID(values) == CFArrayGetTypeID() else { stopped = .malformed; return .stopped }
        let size = CFArrayGetCount(values)
        guard expected == nil || expected == size else { stopped = .malformed; return .stopped }
        guard size <= limits.children else { stopped = .childLimit; return .stopped }
        var out: [AXUIElement] = []
        var seen = Set<ElementKey>()
        return withExtendedLifetime(values) {
            for index in 0..<size {
                guard check() else { return .stopped }
                guard let pointer = CFArrayGetValueAtIndex(values, index) else { stopped = .malformed; return .stopped }
                let raw = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
                guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { stopped = .malformed; return .stopped }
                let child = raw as! AXUIElement   // checked above; the array stays alive during the borrow
                let key = ElementKey(child)
                guard !CFEqual(child, element) else { stopped = .cycle; return .stopped }
                if seen.insert(key).inserted { out.append(child) }
            }
            completed(attribute); return .children(out)
        }
    }
}
