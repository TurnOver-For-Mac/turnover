// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import os
import TurnOverAX
import TurnOverCore
import AXFixtures

nonisolated private final class ShelfReadGate: Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    func hold() { entered.signal(); _ = release.wait(timeout: .now() + 3) }
}

nonisolated private final class ShelfReadSource: Sendable {
    struct State: Sendable {
        var result: MediaView.ReadResult?
        var gate: ShelfReadGate?
        var scrollValues: [Double?] = []
        var expireNextRead = false
        var expiredReads = 0
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    func read(_ input: MediaView.ReadInput, current: @escaping @Sendable () -> Bool) -> MediaView.ReadResult? {
        let scrollValue = (AXReplay.element(11).attributeResult(kAXValueAttribute).value as? NSNumber)?.doubleValue
        let snapshot = state.withLock { state in
            state.scrollValues.append(scrollValue)
            let snapshot = (state.result, state.gate, state.expireNextRead)
            state.gate = nil; state.expireNextRead = false
            return snapshot
        }
        snapshot.1?.hold()
        if snapshot.2 {
            // Exercise the real owner's short work deadline. The one-second backstop prevents a missing
            // early budget from stalling the harness for the normal twelve-second read allowance.
            let backstop = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
            while current(), DispatchTime.now().uptimeNanoseconds < backstop { Thread.sleep(forTimeInterval: 0.001) }
            if !current() { state.withLock { $0.expiredReads += 1 } }
        }
        return snapshot.0 // deliberately return held replies after cancellation; the actual owner must reject them
    }
    func result(_ result: MediaView.ReadResult?) { state.withLock { $0.result = result } }
}

nonisolated private final class ShelfReadDeliveries: Sendable {
    private let pending = OSAllocatedUnfairLock(initialState: [@MainActor @Sendable () -> Void]())
    func enqueue(_ body: @escaping @MainActor @Sendable () -> Void) { pending.withLock { $0.append(body) } }
    @MainActor func one() -> Bool {
        guard let body = pending.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else { return false }
        body(); return true
    }
}

private final class ShelfReadDelays {
    private var pending: [(TimeInterval, @MainActor @Sendable () -> Void)] = []
    func enqueue(_ seconds: TimeInterval, _ body: @escaping @MainActor @Sendable () -> Void) { pending.append((seconds, body)) }
    func fire(_ seconds: TimeInterval) -> Bool {
        guard let index = pending.firstIndex(where: { $0.0 == seconds }) else { return false }
        pending.remove(at: index).1(); return true
    }
}

private final class ShelfReadRig {
    let source: ShelfReadSource
    let deliveries: ShelfReadDeliveries
    let delays: ShelfReadDelays
    let worker: DispatchQueue
    let focus: OSAllocatedUnfairLock<Int>, keys: OSAllocatedUnfairLock<Int>
    let view: MediaView

    init(policy: MediaView.ShelfLoading = .tvEarly) {
        let source = ShelfReadSource(), deliveries = ShelfReadDeliveries(), delays = ShelfReadDelays()
        let worker = DispatchQueue(label: "turnover.tests.shelf-readiness")
        let focus = OSAllocatedUnfairLock(initialState: 1), keys = OSAllocatedUnfairLock(initialState: 0)
        self.source = source; self.deliveries = deliveries; self.delays = delays; self.worker = worker
        self.focus = focus; self.keys = keys
        view = MediaView(pid: AXReplay.floor, collector: { source.read($0, current: $1) }, queue: worker,
                         shelfLoading: policy, windowQuery: { _ in AXReplay.element(focus.withLock { $0 }) },
                         keys: { keys.withLock { $0 } }, deliver: { deliveries.enqueue($0) },
                         delay: { delays.enqueue($0, $1) }, eligible: { true })
        source.result(Self.result([["A"]]))
        view.refresh {}; settle()
    }

    var readCount: Int { source.state.withLock { $0.scrollValues.count } }
    func settle() { worker.sync {}; while deliveries.one() { worker.sync {} } }
    func stop() { view.stop(); worker.sync {}; while deliveries.one() {} }
    func gateNextRead() -> ShelfReadGate {
        let gate = ShelfReadGate(); source.state.withLock { $0.gate = gate }; return gate
    }
    func wait(_ gate: ShelfReadGate) { check(gate.entered.wait(timeout: .now() + 3) == .success, "shelf read entered its held provider") }
    func refresh(_ shelves: [[String]], page: String = "Public page") {
        source.result(Self.result(shelves, page: page)); view.refresh {}; settle()
    }
    static func result(_ shelves: [[String]], page: String = "Public page") -> MediaView.ReadResult {
        let shelves = shelves.enumerated().map { index, names in
            MediaView.Shelf(title: "Public shelf \(index)", items: names.map { name in
                MediaView.Item(label: name, element: AXReplay.element(100 + Int(name.utf8.first ?? 65)), ident: "public[id=\(name)]")
            })
        }
        return .init(built: .init(sidebar: [.init(label: "Public sidebar", element: AXReplay.element(30))],
                                  shelves: shelves, pageTitle: page, pageScroll: AXReplay.element(10), pageID: page))
    }
}

private func shelfReadFixture() {
    AXReplay.load(.init(app: "Public TV shelf sample", bundle: "test.tv", recorded: "synthetic", root: 1, application: 0, focus: nil, nodes: [
        .init(id: 0, attrs: ["AXRole": .string("AXApplication"), "AXFocusedWindow": .element(1)]),
        .init(id: 1, attrs: ["AXRole": .string("AXWindow"), "AXTitle": .string("Public page")]),
        .init(id: 2, attrs: ["AXRole": .string("AXWindow"), "AXTitle": .string("Public page")]),
        .init(id: 10, attrs: ["AXRole": .string("AXScrollArea"), "AXIdentifier": .string("public.tv.page"), "AXVerticalScrollBar": .element(11)]),
        .init(id: 11, attrs: ["AXRole": .string("AXScrollBar"), "AXValue": .number(0)]),
        .init(id: 30, attrs: ["AXRole": .string("AXButton")]),
    ]))
}

func mediaShelfReadinessTests() {
    test("TV shelf readiness: actual owner moves on an early current snapshot and retires its delayed read") {
        shelfReadFixture(); defer { AXReplay.unload() }
        let rig = ShelfReadRig(); defer { rig.stop() }
        rig.view.move(1)
        expect(AXReplay.sets.count, 1)
        rig.source.result(ShelfReadRig.result([["A", "B"]]))
        check(rig.delays.fire(0.15), "TV requested its optional early read"); rig.settle()
        expect(rig.view.currentItem()?.label, "B")
        expect(rig.readCount, 2)
        check(rig.delays.fire(0.5), "old settling timer still exists but is retired"); rig.settle()
        expect(rig.readCount, 2, "one completion did not collect again at 500 ms")
        expect(AXReplay.sets.count, 1)
    }
    test("TV shelf readiness: unchanged nil and empty early results wait at the same position until 500 ms") {
        for early in [nil, ShelfReadRig.result([]), ShelfReadRig.result([["A"]])] {
            shelfReadFixture()
            let rig = ShelfReadRig()
            rig.view.move(1)
            rig.source.result(early)
            check(rig.delays.fire(0.15), "early read is scheduled"); rig.settle()
            expect(rig.view.currentItem()?.label, "A")
            expect(AXReplay.sets.count, 1, "an unchanged early read cannot scroll past a slow shelf")
            rig.source.result(ShelfReadRig.result([["A", "B"]]))
            check(rig.delays.fire(0.5), "legacy settling point remains scheduled"); rig.settle()
            expect(rig.view.currentItem()?.label, "B")
            expect(AXReplay.sets.count, 1, "settled readiness was read at the same scroll position")
            rig.stop(); AXReplay.unload()
        }
    }
    test("TV shelf readiness: only the settled unchanged result allows the existing further-scroll fallback") {
        shelfReadFixture(); defer { AXReplay.unload() }
        let rig = ShelfReadRig(); defer { rig.stop() }
        rig.view.move(1)
        check(rig.delays.fire(0.15), "early read is scheduled"); rig.settle()
        expect(AXReplay.sets.count, 1)
        check(rig.delays.fire(0.5), "settled read is scheduled"); rig.settle()
        expect(AXReplay.sets.count, 2, "existing retry scroll follows the 500 ms check")
        rig.source.result(ShelfReadRig.result([["A", "B"]]))
        check(rig.delays.fire(0.15), "retry owns a new early read"); rig.settle()
        expect(rig.view.currentItem()?.label, "B")
    }
    test("TV shelf readiness: expired optional early work cannot publish and retains the normal settled read") {
        shelfReadFixture(); defer { AXReplay.unload() }
        let rig = ShelfReadRig(); defer { rig.stop() }
        rig.view.move(1)
        rig.source.result(ShelfReadRig.result([["A", "B"]]))
        rig.source.state.withLock { $0.expireNextRead = true }
        check(rig.delays.fire(0.15), "early read is scheduled"); rig.settle()
        expect(rig.source.state.withLock { $0.expiredReads }, 1, "optional work used the short cooperative allowance")
        expect(rig.view.currentItem()?.label, "A", "late early data was rejected by the actual work owner")
        expect(AXReplay.sets.count, 1, "expiry did not mean another scroll or end of content")
        check(rig.delays.fire(0.5), "full settled allowance remains scheduled"); rig.settle()
        expect(rig.view.currentItem()?.label, "B")
        expect(AXReplay.sets.count, 1)
    }
    test("TV shelf readiness: an overlapping committed refresh completes once and retires both timers") {
        shelfReadFixture(); defer { AXReplay.unload() }
        let rig = ShelfReadRig(); defer { rig.stop() }
        rig.view.move(1)
        rig.refresh([["A", "B"]])
        expect(rig.view.currentItem()?.label, "B")
        let reads = rig.readCount
        check(rig.delays.fire(0.15), "retired early timer can still be delivered")
        check(rig.delays.fire(0.5), "retired settled timer can still be delivered"); rig.settle()
        expect(rig.readCount, reads)
        expect(AXReplay.sets.count, 1)
        expect(rig.view.currentItem()?.label, "B", "no duplicate move from either timer")
    }
    test("TV shelf readiness: overlap fulfillment retires an early read already queued behind it") {
        shelfReadFixture(); defer { AXReplay.unload() }
        let rig = ShelfReadRig(); defer { rig.stop() }
        rig.source.result(ShelfReadRig.result([["A", "B"]]))
        let gate = rig.gateNextRead(); defer { gate.release.signal() }
        rig.view.refresh {}; rig.wait(gate)
        rig.view.move(1)
        check(rig.delays.fire(0.15), "early read queues behind the held refresh")
        gate.release.signal(); rig.settle()
        expect(rig.view.currentItem()?.label, "B")
        expect(rig.readCount, 2, "fulfilled queued early work was not sent to the provider")
        check(rig.delays.fire(0.5), "retired settling timer can still be delivered"); rig.settle()
        expect(rig.readCount, 2)
    }
    test("TV shelf readiness: an early read crossing 500 ms coalesces a fresh settled read before another scroll") {
        shelfReadFixture(); defer { AXReplay.unload() }
        let rig = ShelfReadRig(); defer { rig.stop() }
        rig.view.move(1)
        let gate = rig.gateNextRead(); defer { gate.release.signal() }
        check(rig.delays.fire(0.15), "early read is scheduled"); rig.wait(gate)
        check(rig.delays.fire(0.5), "500 ms arrived while the early read was held")
        expect(rig.readCount, 2, "the settling timer did not start a concurrent provider read")
        expect(AXReplay.sets.count, 1)
        gate.release.signal(); rig.settle()
        let positions = rig.source.state.withLock { $0.scrollValues }
        expect(positions.count, 3)
        expect(positions[1], positions[2], "early and settled reads used the same scroll position")
        expect(AXReplay.sets.count, 2, "only the fresh settled read permitted the retry scroll")
    }
    test("TV shelf readiness: a stopped session retires both timers and a held early response") {
        shelfReadFixture(); defer { AXReplay.unload() }
        let rig = ShelfReadRig(); defer { rig.stop() }
        rig.view.move(1)
        rig.source.result(ShelfReadRig.result([["A", "B"]]))
        let gate = rig.gateNextRead(); defer { gate.release.signal() }
        check(rig.delays.fire(0.15), "early read is scheduled"); rig.wait(gate)
        rig.view.stop()
        gate.release.signal(); rig.settle()
        check(rig.delays.fire(0.5), "old settling timer can still be delivered"); rig.settle()
        expect(rig.view.currentItem()?.label, "A", "a retired read cannot publish or move the cursor")
        expect(rig.readCount, 2)
        expect(AXReplay.sets.count, 1)
    }
    test("TV shelf readiness: a same-title native window change retires the old scroll before another read") {
        shelfReadFixture(); defer { AXReplay.unload() }
        let rig = ShelfReadRig(); defer { rig.stop() }
        rig.view.move(1)
        rig.focus.withLock { $0 = 2 }
        check(rig.delays.fire(0.15), "early timer checks its actual captured window"); rig.settle()
        check(rig.delays.fire(0.5), "old settled timer is harmless"); rig.settle()
        check(rig.view.shelves.isEmpty, "old-window content was retired")
        expect(rig.readCount, 1)
        expect(AXReplay.sets.count, 1)
    }
    test("TV shelf readiness: an early reply for another page is not published under the captured load") {
        shelfReadFixture(); defer { AXReplay.unload() }
        let rig = ShelfReadRig(); defer { rig.stop() }
        rig.view.move(1)
        rig.source.result(ShelfReadRig.result([["Other", "New"]], page: "Another public page"))
        check(rig.delays.fire(0.15), "early read is scheduled"); rig.settle()
        expect(rig.view.pageTitle, "Public page")
        expect(rig.view.currentItem()?.label, "A")
        check(rig.delays.fire(0.5), "rejected page retires the old delayed work"); rig.settle()
        expect(rig.readCount, 2)
        expect(AXReplay.sets.count, 1)
    }
    test("TV shelf readiness: later queued shelf and item keys retain their original order") {
        shelfReadFixture(); defer { AXReplay.unload() }
        let rig = ShelfReadRig(); defer { rig.stop() }
        rig.view.move(1) // A -> B, once B exists.
        rig.keys.withLock { $0 += 2 }
        rig.view.jumpShelf(1) // B -> C.
        rig.view.move(1) // C -> D.
        rig.source.result(ShelfReadRig.result([["A", "B"], ["C", "D"]]))
        check(rig.delays.fire(0.15), "early read is scheduled"); rig.settle()
        expect(rig.view.currentItem()?.label, "D")
        expect(rig.view.pane, .page)
        expect(AXReplay.sets.count, 1)
    }
    test("TV shelf readiness: immediate newer Tab owns its pane and receives no delayed original move") {
        shelfReadFixture(); defer { AXReplay.unload() }
        let rig = ShelfReadRig(); defer { rig.stop() }
        rig.view.move(1)
        rig.keys.withLock { $0 += 1 }; rig.view.switchPane(1)
        expect(rig.view.pane, .sidebar)
        let sink = Speech.sink; var said: [String] = []; Speech.sink = { said.append($0) }
        defer { Speech.sink = sink }
        rig.source.result(ShelfReadRig.result([["A", "B"]]))
        check(rig.delays.fire(0.15), "early read is scheduled"); rig.settle()
        expect(rig.view.pane, .sidebar)
        expect(rig.view.currentItem()?.label, "Public sidebar")
        expect(said, [], "no late navigation speech over the newer pane")
    }
    test("TV shelf readiness: immediate newer Home owns its page cursor") {
        shelfReadFixture(); defer { AXReplay.unload() }
        let rig = ShelfReadRig(); defer { rig.stop() }
        rig.refresh([["A", "B"]]); rig.view.move(1); rig.view.move(1)
        rig.keys.withLock { $0 += 1 }; rig.view.toEnd(false)
        rig.source.result(ShelfReadRig.result([["A", "B", "C"]]))
        check(rig.delays.fire(0.15), "early read is scheduled"); rig.settle()
        expect(rig.view.currentItem()?.label, "A", "old Down did not undo newer Home")
    }
    test("TV shelf readiness: newer Tab away and back owns even the same final pane and item") {
        shelfReadFixture(); defer { AXReplay.unload() }
        let rig = ShelfReadRig(); defer { rig.stop() }
        rig.view.move(1)
        rig.keys.withLock { $0 += 2 }
        rig.view.switchPane(1); rig.view.switchPane(-1)
        expect(rig.view.pane, .page)
        expect(rig.view.currentItem()?.label, "A")
        rig.source.result(ShelfReadRig.result([["A", "B"]]))
        check(rig.delays.fire(0.15), "early read is scheduled"); rig.settle()
        expect(rig.view.pane, .page)
        expect(rig.view.currentItem()?.label, "A", "original Down did not run after a newer round-trip intent")
    }
    test("media shelf readiness: default policy retains its single 500 ms read") {
        shelfReadFixture(); defer { AXReplay.unload() }
        let rig = ShelfReadRig(policy: .standard); defer { rig.stop() }
        rig.view.move(1)
        check(!rig.delays.fire(0.15), "other media apps have no early timer")
        rig.source.result(ShelfReadRig.result([["A", "B"]]))
        check(rig.delays.fire(0.5), "legacy settling timer is unchanged"); rig.settle()
        expect(rig.view.currentItem()?.label, "B")
        expect(rig.readCount, 2)
        expect(AXReplay.sets.count, 1)
    }
}
