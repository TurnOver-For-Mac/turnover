// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverAX
import AXFixtures
import os

func axNavigationChildrenTests() {
    let nav = AXNavigationChildren.navigationAttribute
    func load(_ children: [Int], navigation: [Int]?) -> AXUIElement {
        var attrs: [String: AXFixture.Value] = ["AXRole": .string("AXWindow"), "AXChildren": .elements(children)]
        if let navigation { attrs[nav] = .elements(navigation) }
        AXReplay.load(.init(app: "Public sample", bundle: "test.navigation", recorded: "", root: 0, application: nil, focus: nil, nodes: [
            .init(id: 0, attrs: attrs), .init(id: 1, attrs: ["AXRole": .string("AXButton")]),
            .init(id: 2, attrs: ["AXRole": .string("AXGroup")]), .init(id: 3, attrs: ["AXRole": .string("AXStaticText")]),
        ]))
        return AXReplay.root!
    }
    func ids(_ values: [AXUIElement]) -> [Int] { values.compactMap { AXReplay.id(of: $0) } }
    func count(_ status: AXQueryStatus, value: Int? = nil) -> AXQueryResult<Int> {
        .init(value: value, status: status, elapsedNanoseconds: 0, wasAttempted: true)
    }

    test("AX navigation children: semantic order replaces ordinary wrappers and deduplicates identity") {
        let root = load([1], navigation: [3, 2, 3]); defer { AXReplay.unload() }
        let reader = AXNavigationChildren()
        expect(ids(root.elements(kAXChildrenAttribute)), [1], "ordinary representation differs")
        expect(ids(reader.children(of: root)), [3, 2], "navigation representation preserves provider order and first occurrence")
        check(reader.stopped == nil, "the bounded read completed")
        expect(reader.navigationReadCount, 1); expect(reader.ordinaryReadCount, 0)
        expect(reader.lastNavigationRead?.method, .prefix)
        expect(reader.queryCount, 2, "count and prefix both spend the allowance")
    }
    test("AX navigation children: successful empty is authoritative") {
        let root = load([1], navigation: []); defer { AXReplay.unload() }
        let reader = AXNavigationChildren()
        check(reader.children(of: root).isEmpty, "do not replace the provider's navigation leaf with ordinary children")
        expect(reader.navigationReadCount, 1); expect(reader.ordinaryReadCount, 0)
        check(reader.lastOrdinaryRead == nil, "ordinary representation was not queried")
        expect(reader.queryCount, 1)
    }
    test("AX navigation children: genuine unavailable navigation children falls back to ordinary children") {
        let root = load([1], navigation: nil); defer { AXReplay.unload() }
        let reader = AXNavigationChildren()
        expect(ids(reader.children(of: root)), [1])
        expect(reader.lastNavigationRead?.method, .unavailable)
        expect(reader.ordinaryReadCount, 1); expect(reader.navigationReadCount, 0)
        check(reader.stopped == nil, "missing optional attribute is not transport failure")
    }
    test("AX navigation children: count or slice unsupported still tries the public attribute value") {
        let root = load([], navigation: [2, 3]); defer { AXReplay.unload() }
        for unsupportedCount in [true, false] {
            var source = AXNavigationChildren.Source()
            if unsupportedCount {
                source.count = { element, attribute in
                    attribute == nav ? count(.returned(.attributeUnsupported)) : element.attributeValueCountResult(attribute)
                }
            } else {
                source.values = { _, _, _ in .init(value: nil, status: .returned(.notImplemented), elapsedNanoseconds: 0, wasAttempted: true) }
            }
            let reader = AXNavigationChildren(source: source)
            expect(ids(reader.children(of: root)), [2, 3], "actual value remains usable even without array enumeration APIs")
            expect(reader.lastNavigationRead?.method, .attributeValue)
            expect(reader.lastNavigationRead?.valueStatus, .returned(.success))
            expect(reader.navigationReadCount, 1); expect(reader.ordinaryReadCount, 0)
        }
    }
    test("AX navigation children: transport backoff and client errors never authorize fallback") {
        let root = load([1], navigation: [2]); defer { AXReplay.unload() }
        let statuses: [AXQueryStatus] = [.returned(.cannotComplete), .returned(.apiDisabled), .returned(.invalidUIElement), .returned(.failure),
                                       .deferred(.init(reason: .timeout, remainingNanoseconds: 1_000_000)), .invalidResponse, .batchNull]
        for status in statuses {
            var source = AXNavigationChildren.Source()
            var reads: [String] = []
            source.count = { _, attribute in reads.append(attribute); return count(status) }
            let reader = AXNavigationChildren(source: source)
            check(reader.children(of: root).isEmpty, "failed read has no children to publish")
            expect(reader.stopped, .query(status))
            expect(reads, [nav], "no ordinary or second provider query follows failure")
            expect(reader.ordinaryReadCount, 0)
        }
    }
    test("AX navigation children: malformed and oversized values stop without complete empty publication") {
        let root = load([1], navigation: [2, 3]); defer { AXReplay.unload() }
        var malformed = AXNavigationChildren.Source()
        malformed.count = { _, _ in count(.returned(.attributeUnsupported)) }
        malformed.value = { _, _ in .init(value: "not an array" as CFString, status: .returned(.success), elapsedNanoseconds: 0, wasAttempted: true) }
        let bad = AXNavigationChildren(source: malformed)
        check(bad.children(of: root).isEmpty, "malformed values cannot become records")
        expect(bad.stopped, .malformed)
        let capped = AXNavigationChildren(limits: .init(children: 1))
        check(capped.children(of: root).isEmpty, "an over-cap array is not published as a complete prefix")
        expect(capped.stopped, .childLimit)
        expect(capped.queryCount, 1, "known oversized reply is not copied")
    }
    test("AX navigation children: cancellation deadline and query limits cover count and prefix") {
        let root = load([1], navigation: [2, 3]); defer { AXReplay.unload() }
        let current = OSAllocatedUnfairLock(initialState: true)
        var source = AXNavigationChildren.Source()
        source.count = { _, _ in current.withLock { $0 = false }; return count(.returned(.success), value: 2) }
        let cancelled = AXNavigationChildren(current: { current.withLock { $0 } }, source: source)
        check(cancelled.children(of: root).isEmpty, "a late count cannot authorize prefix work")
        expect(cancelled.stopped, .cancelled); expect(cancelled.queryCount, 1)
        let clock = OSAllocatedUnfairLock<UInt64>(initialState: 0)
        source.count = { _, _ in clock.withLock { $0 = 3_000_000_000 }; return count(.returned(.success), value: 2) }
        let late = AXNavigationChildren(clock: { clock.withLock { $0 } }, source: source)
        check(late.children(of: root).isEmpty, "deadline is checked after an in-flight query returns")
        expect(late.stopped, .deadline); expect(late.queryCount, 1)
        let bounded = AXNavigationChildren(limits: .init(queries: 1))
        check(bounded.children(of: root).isEmpty, "count must leave enough budget for the prefix")
        expect(bounded.stopped, .queryLimit); expect(bounded.queryCount, 1)
    }
    test("AX navigation children: actual traversal tests roots navigation order cycles and depth") {
        let root = load([1], navigation: [2, 3]); defer { AXReplay.unload() }
        let rootMatch = AXNavigationChildren()
        expect(rootMatch.first(in: root, depth: 0, where: { CFEqual($0, root) }).flatMap { AXReplay.id(of: $0) }, 0)
        expect(rootMatch.queryCount, 0, "an already-matching root needs no children lookup")
        let ordered = AXNavigationChildren()
        expect(ordered.first(in: root, depth: 2, where: { AXReplay.id(of: $0) == 2 || AXReplay.id(of: $0) == 3 }).flatMap { AXReplay.id(of: $0) }, 2)
        let shallow = AXNavigationChildren(limits: .init(depth: 0))
        check(shallow.first(in: root, depth: 2, where: { _ in false }) == nil, "depth exhausted")
        expect(shallow.stopped, .depthLimit)
        let cycleRoot = load([], navigation: [0])
        let cyclic = AXNavigationChildren()
        check(cyclic.children(of: cycleRoot).isEmpty, "self-reference is not a valid navigation child")
        expect(cyclic.stopped, .cycle)
    }
}
