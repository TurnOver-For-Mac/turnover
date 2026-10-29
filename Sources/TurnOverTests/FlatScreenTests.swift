// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore

nonisolated private final class FlatReadGate: Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let timedOut = Locked(false)
    func hold() {
        entered.signal()
        if release.wait(timeout: .now() + 2) == .timedOut { timedOut.value = true }
    }
}

nonisolated private final class HeldFlatDeliveries: Sendable {
    private let pending = Locked<[@MainActor @Sendable () -> Void]>([])
    func enqueue(_ body: @escaping @MainActor @Sendable () -> Void) {
        pending.lock.lock(); pending.unsafeValue.append(body); pending.lock.unlock()
    }
    @MainActor func drainOne() -> Bool {
        pending.lock.lock()
        let body = pending.unsafeValue.isEmpty ? nil : pending.unsafeValue.removeFirst()
        pending.lock.unlock()
        guard let body else { return false }
        body()
        return true
    }
    @MainActor func drain() { while drainOne() {} }
}

nonisolated private final class FlatTestAdapter: FlatAdapter, Sendable {
    let unexpectedReads = Locked(0)
    let settleTimes: [Double] = []
    func areaRoot() -> AXUIElement? { unexpectedReads.value += 1; return nil }
    func isItem(_ e: AXUIElement) -> Bool { false }
    func name(for e: AXUIElement) -> String? { nil }
    func label(for e: AXUIElement, name: String) -> String { name }
    func clickPoint(for e: AXUIElement) -> CGPoint? { nil }
    func unsafeHit(_ e: AXUIElement) -> Bool { true }
    func scrollBar() -> AXUIElement? { unexpectedReads.value += 1; return nil }
    func screenArea() -> CGRect? { unexpectedReads.value += 1; return nil }
}

nonisolated private final class FlatTestSource: FlatScreenSource, Sendable {
    nonisolated struct Replies: Sendable {
        var first: [FlatScreen.Tile] = []
        var additions: [FlatScreen.Tile] = []
        var firstGate: FlatReadGate?
        var nextGate: FlatReadGate?
        var pointGate: FlatReadGate?
        var noPoint = false
        var known: [[String]] = []
        var resolved: [String] = []
        var cancelledReplies = 0
    }
    let replies = Locked(Replies())
    func firstScreen(current: @Sendable () -> Bool) -> [FlatScreen.Tile] {
        replies.lock.lock()
        let tiles = replies.unsafeValue.first, gate = replies.unsafeValue.firstGate
        replies.unsafeValue.firstGate = nil
        replies.lock.unlock()
        gate?.hold()
        noteCancellation(current)
        return tiles   // deliberately return even after cancellation: the owner must reject it
    }
    func nextScreen(known: [FlatScreen.Tile], current: @Sendable () -> Bool) -> (tiles: [FlatScreen.Tile], ended: Bool) {
        replies.lock.lock()
        replies.unsafeValue.known.append(known.map(\.name))
        let next = replies.unsafeValue.additions.first { tile in !known.contains { $0.name == tile.name } }
        let gate = replies.unsafeValue.nextGate
        replies.unsafeValue.nextGate = nil
        replies.lock.unlock()
        gate?.hold()
        noteCancellation(current)
        return (next.map { [$0] } ?? [], next == nil)
    }
    func point(for tile: FlatScreen.Tile, current: @Sendable () -> Bool) -> CGPoint? {
        replies.lock.lock()
        replies.unsafeValue.resolved.append(tile.name)
        let gate = replies.unsafeValue.pointGate, noPoint = replies.unsafeValue.noPoint
        replies.unsafeValue.pointGate = nil
        replies.lock.unlock()
        gate?.hold()
        noteCancellation(current)
        return noPoint ? nil : tile.point
    }
    private func noteCancellation(_ current: @Sendable () -> Bool) {
        if !current() {
            replies.lock.lock(); replies.unsafeValue.cancelledReplies += 1; replies.lock.unlock()
        }
    }
}

private final class FlatTestRig {
    let adapter = FlatTestAdapter()
    let source = FlatTestSource()
    let worker = DispatchQueue(label: "turnover.tests.flat-screen")
    let deliveries = HeldFlatDeliveries()
    let view: FlatScreen
    init() {
        let delivery = deliveries
        view = FlatScreen(name: "test", adapter: adapter, source: source, queue: worker,
                          deliver: { delivery.enqueue($0) })
    }
    func tiles(_ names: [String]) -> [FlatScreen.Tile] {
        names.enumerated().map { FlatScreen.Tile(name: $0.element, label: $0.element, point: CGPoint(x: $0.offset + 10, y: 20), bar: 0) }
    }
    func load(_ names: [String]) {
        source.replies.lock.lock(); source.replies.unsafeValue.first = tiles(names); source.replies.lock.unlock()
        view.begin(); worker.sync {}; deliveries.drain()
    }
    func wait(_ gate: FlatReadGate) {
        check(gate.entered.wait(timeout: .now() + 2) == .success, "worker reached the controlled read gate")
    }
}

func flatScreenTests() {
    test("flat screen: a delayed scan reply cannot replace a later page") {
        let rig = FlatTestRig(), gate = FlatReadGate()
        defer { gate.release.signal(); rig.view.end() }
        rig.source.replies.value = .init(first: rig.tiles(["Old page"]), firstGate: gate)
        var published: [[String]] = []
        rig.view.onChange = { if !$0.isEmpty { published.append($0.compactMap(\.name)) } }
        rig.view.begin(); rig.wait(gate)
        rig.view.end()
        rig.source.replies.lock.lock(); rig.source.replies.unsafeValue.first = rig.tiles(["New page"]); rig.source.replies.lock.unlock()
        rig.view.begin(); gate.release.signal(); rig.worker.sync {}; rig.deliveries.drain()
        expect(rig.view.items.compactMap(\.name), ["New page"])
        expect(published, [["New page"]], "only the active page reaches speech/list observers")
        expect(rig.source.replies.value.cancelledReplies, 1)
        check(!gate.timedOut.value, "the test released the read explicitly")
    }
    test("flat screen: a publication queued on main rechecks page identity at delivery") {
        let rig = FlatTestRig()
        defer { rig.view.end() }
        rig.source.replies.value = .init(first: rig.tiles(["Old page"]))
        rig.view.begin(); rig.worker.sync {}   // old publication is held before main sees it
        rig.view.end()
        rig.source.replies.value = .init(first: rig.tiles(["New page"]))
        rig.view.begin(); rig.worker.sync {}
        check(rig.deliveries.drainOne(), "old publication was queued")
        check(rig.view.items.isEmpty, "old list is rejected even though its read completed before end")
        rig.deliveries.drain()
        expect(rig.view.items.compactMap(\.name), ["New page"])
    }
    test("flat screen: older publications cannot overwrite a newer snapshot on the same page") {
        let rig = FlatTestRig()
        defer { rig.view.end() }
        rig.source.replies.value = .init(first: rig.tiles(["First"]), additions: rig.tiles(["Second"]))
        rig.view.begin(); rig.worker.sync {}
        var count = 0
        rig.view.extend { count = $0 }; rig.worker.sync {}
        check(rig.deliveries.drainOne(), "first snapshot was queued")
        check(rig.view.items.isEmpty, "a superseded revision is not briefly republished")
        rig.deliveries.drain()
        expect(rig.view.items.compactMap(\.name), ["First", "Second"])
        expect(count, 2)
    }
    test("flat screen: extension replies and queued completions cannot move a later page") {
        let rig = FlatTestRig(), gate = FlatReadGate()
        defer { gate.release.signal(); rig.view.end() }
        rig.load(["First"])
        rig.source.replies.lock.lock()
        rig.source.replies.unsafeValue.additions = rig.tiles(["Old extension"])
        rig.source.replies.unsafeValue.nextGate = gate
        rig.source.replies.lock.unlock()
        var calls = 0
        rig.view.extend { _ in calls += 1 }; rig.wait(gate)
        rig.view.end()
        rig.source.replies.lock.lock(); rig.source.replies.unsafeValue.first = rig.tiles(["Later page"]); rig.source.replies.lock.unlock()
        rig.view.begin(); gate.release.signal(); rig.worker.sync {}; rig.deliveries.drain()
        expect(calls, 0)
        expect(rig.view.items.compactMap(\.name), ["Later page"])
        rig.view.extend { _ in calls += 1 }; rig.worker.sync {}   // completion is now held on main
        rig.view.end(); rig.deliveries.drain()
        expect(calls, 0, "delivery after end is also cancelled")
        expect(rig.adapter.unexpectedReads.value, 0, "no live accessibility reads in this fixture")
    }
    test("flat screen: queued extensions read the list when their serial worker starts") {
        let rig = FlatTestRig(), gate = FlatReadGate()
        defer { gate.release.signal(); rig.view.end() }
        rig.load(["First"])
        rig.source.replies.lock.lock()
        rig.source.replies.unsafeValue.additions = rig.tiles(["Second", "Third"])
        rig.source.replies.unsafeValue.nextGate = gate
        rig.source.replies.lock.unlock()
        var counts: [Int] = []
        rig.view.extend { count in
            counts.append(count)
            check(rig.view.items.count >= count, "first cursor callback sees its completed rows")
        }
        rig.wait(gate)
        rig.view.extend { count in
            counts.append(count)
            check(rig.view.items.count >= count, "second cursor callback sees its completed rows")
        }
        gate.release.signal(); rig.worker.sync {}; rig.deliveries.drain()
        expect(rig.source.replies.value.known, [["First"], ["First", "Second"]])
        expect(rig.view.items.compactMap(\.name), ["First", "Second", "Third"])
        expect(counts, [2, 3])
    }
    test("flat screen: an old item never resolves a new row at the same position") {
        let rig = FlatTestRig()
        defer { rig.view.end() }
        rig.load(["Old app"])
        let old = rig.view.items[0]
        rig.load(["New app"])
        var calls = 0
        rig.view.resolve(old) { _ in calls += 1 }; rig.worker.sync {}; rig.deliveries.drain()
        expect(calls, 0)
        check(rig.source.replies.value.resolved.isEmpty, "a retired page identity is rejected before provider reads")
        var wrongName = rig.view.items[0]
        wrongName.name = "Old app"
        rig.view.resolve(wrongName) { point in calls += 1; check(point == nil, "mismatched captured name is refused") }
        expect(calls, 1)
        check(rig.source.replies.value.resolved.isEmpty, "the current position alone cannot authorize the new app")
    }
    test("flat screen: a delayed resolve reply is cancelled by a new page") {
        let rig = FlatTestRig(), gate = FlatReadGate()
        defer { gate.release.signal(); rig.view.end() }
        rig.load(["Old app"])
        rig.source.replies.lock.lock(); rig.source.replies.unsafeValue.pointGate = gate; rig.source.replies.lock.unlock()
        var calls = 0
        rig.view.resolve(rig.view.items[0]) { _ in calls += 1 }; rig.wait(gate)
        rig.view.end()
        rig.source.replies.lock.lock(); rig.source.replies.unsafeValue.first = rig.tiles(["New app"]); rig.source.replies.lock.unlock()
        rig.view.begin(); gate.release.signal(); rig.worker.sync {}; rig.deliveries.drain()
        expect(calls, 0, "old click target never reaches the main callback")
        expect(rig.view.items.compactMap(\.name), ["New app"])
        expect(rig.source.replies.value.cancelledReplies, 1)
    }
    test("flat screen: resolved points recheck the page and newest request when delivered") {
        let rig = FlatTestRig()
        defer { rig.view.end() }
        rig.load(["First", "Second"])
        var opened: [String] = []
        rig.view.resolve(rig.view.items[0]) { _ in opened.append("First") }; rig.worker.sync {}
        rig.view.resolve(rig.view.items[1]) { _ in opened.append("Second") }; rig.worker.sync {}
        rig.deliveries.drain()
        expect(opened, ["Second"], "the newer open request retires a queued older point")
        rig.view.resolve(rig.view.items[0]) { _ in opened.append("Retired page") }; rig.worker.sync {}
        rig.view.end(); rig.load(["Later"]); rig.deliveries.drain()
        expect(opened, ["Second"], "a queued successful point cannot open a later page")
    }
    test("flat screen: navigation can cancel an in-flight resolve on the same page") {
        let rig = FlatTestRig(), gate = FlatReadGate()
        defer { gate.release.signal(); rig.view.end() }
        rig.load(["App"])
        rig.source.replies.lock.lock(); rig.source.replies.unsafeValue.pointGate = gate; rig.source.replies.lock.unlock()
        var calls = 0
        rig.view.resolve(rig.view.items[0]) { _ in calls += 1 }; rig.wait(gate)
        rig.view.cancelResolution()
        gate.release.signal(); rig.worker.sync {}; rig.deliveries.drain()
        expect(calls, 0)
        expect(rig.source.replies.value.cancelledReplies, 1, "the worker observes navigation cancellation")
        expect(rig.view.items.compactMap(\.name), ["App"], "cancelling an action preserves the reading list")
    }
    test("flat screen: a missing point from a source does not fall through to live hit testing") {
        let rig = FlatTestRig()
        defer { rig.view.end() }
        rig.load(["App"])
        rig.source.replies.lock.lock(); rig.source.replies.unsafeValue.noPoint = true; rig.source.replies.lock.unlock()
        var refused = false
        rig.view.resolve(rig.view.items[0]) { refused = $0 == nil }; rig.worker.sync {}; rig.deliveries.drain()
        check(refused, "a current unresolved item reports no point")
        expect(rig.adapter.unexpectedReads.value, 0)
        rig.view.end()
        let calls = rig.source.replies.value.known.count
        rig.view.extend { _ in Harness.fail("inactive extension completed") }
        rig.worker.sync {}; rig.deliveries.drain()
        expect(rig.source.replies.value.known.count, calls, "end prevents new background work")
    }
}
