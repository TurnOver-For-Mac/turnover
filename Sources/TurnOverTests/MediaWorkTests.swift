// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import os
import TurnOverCore
import AXFixtures

nonisolated private final class MediaTestGate: Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    func hold() { entered.signal(); _ = release.wait(timeout: .now() + 3) }
}

nonisolated private final class MediaTestDeliveries: Sendable {
    private let pending = OSAllocatedUnfairLock(initialState: [@MainActor @Sendable () -> Void]())
    func enqueue(_ body: @escaping @MainActor @Sendable () -> Void) { pending.withLock { $0.append(body) } }
    @MainActor func one() -> Bool {
        let body = pending.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        guard let body else { return false }; body(); return true
    }
}

nonisolated private final class MediaTestSource: Sendable {
    struct State: Sendable {
        var result: MediaView.ReadResult?
        var gate: MediaTestGate?
        var sidebars: [[String]] = []
        var onMain: [Bool] = []
        var cancelled = 0
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    func read(_ input: MediaView.ReadInput, current: @escaping @Sendable () -> Bool) -> MediaView.ReadResult? {
        let values = state.withLock { state in
            let values = (state.result, state.gate)
            state.gate = nil
            state.sidebars.append(input.sidebar.map(\.label)); state.onMain.append(Thread.isMainThread)
            return values
        }
        values.1?.hold()
        if !current() { state.withLock { $0.cancelled += 1 } }
        // Deliberately return even after retirement: main must independently reject a held reply.
        return values.0
    }
    func result(_ result: MediaView.ReadResult?) { state.withLock { $0.result = result } }
}

private final class MediaTestDelays {
    private var pending: [(TimeInterval, @MainActor @Sendable () -> Void)] = []
    func enqueue(_ seconds: TimeInterval, _ body: @escaping @MainActor @Sendable () -> Void) { pending.append((seconds, body)) }
    func fire(_ seconds: TimeInterval) -> Bool {
        guard let index = pending.firstIndex(where: { $0.0 == seconds }) else { return false }
        pending.remove(at: index).1(); return true
    }
}

private final class MediaTestRig {
    let source: MediaTestSource
    let deliveries: MediaTestDeliveries
    let worker: DispatchQueue
    let view: MediaView
    let delays: MediaTestDelays
    private let allowed: OSAllocatedUnfairLock<Bool>

    init(liveCollector: Bool = false) {
        let source = MediaTestSource(), deliveries = MediaTestDeliveries()
        let worker = DispatchQueue(label: "turnover.tests.media-work")
        let allowed = OSAllocatedUnfairLock(initialState: true)
        let delays = MediaTestDelays()
        self.source = source; self.deliveries = deliveries; self.worker = worker; self.allowed = allowed
        self.delays = delays
        let collector: MediaView.Collector? = liveCollector ? nil : { source.read($0, current: $1) }
        // All dependencies are init-local checked values; no partially initialized self crosses to the worker.
        view = MediaView(pid: AXReplay.floor, collector: collector,
                         queue: worker, deliver: { deliveries.enqueue($0) },
                         delay: { delays.enqueue($0, $1) },
                         eligible: { allowed.withLock { $0 } })
    }

    func setEligible(_ value: Bool) { allowed.withLock { $0 = value } }
    func settle() { worker.sync {}; while deliveries.one() { worker.sync {} } }
    func gate() -> MediaTestGate {
        let gate = MediaTestGate(); source.state.withLock { $0.gate = gate }; return gate
    }
    func wait(_ gate: MediaTestGate) { check(gate.entered.wait(timeout: .now() + 3) == .success, "media worker reached its held provider") }
    func load(_ name: String = "A", items: [MediaView.Item]? = nil) {
        source.result(Self.result(name, items: items)); view.refresh {}; settle()
    }
    static func result(_ name: String, items: [MediaView.Item]? = nil) -> MediaView.ReadResult {
        let item = MediaView.Item(label: name, element: AXReplay.element(50))
        return .init(built: .init(sidebar: [.init(label: name + " sidebar", element: AXReplay.element(60))],
                                  shelves: [.init(title: "Featured", items: items ?? [item])],
                                  pageTitle: name, pageID: name))
    }
}

private func mediaActionFixture() {
    AXReplay.load(.init(app: "Public media sample", bundle: "test.media", recorded: "", root: 1, application: 0, focus: nil, nodes: [
        .init(id: 0, attrs: ["AXRole": .string("AXApplication"), "AXFocusedWindow": .element(1)]),
        .init(id: 1, attrs: ["AXRole": .string("AXWindow"), "AXChildren": .elements([])]),
        .init(id: 99, attrs: ["AXRole": .string("AXButton"), "AXIdentifier": .string("reused"), "AXDescription": .string("Other")], actions: ["AXPress"]),
        .init(id: 100, attrs: ["AXRole": .string("AXButton"), "AXIdentifier": .string("sample[id=A]"), "AXDescription": .string("A")], actions: ["AXPress"]),
        .init(id: 101, attrs: ["AXRole": .string("AXButton"), "AXIdentifier": .string("sample[id=B]"), "AXDescription": .string("B")], actions: ["AXPress"]),
    ]))
}

private func mediaPlayable(_ name: String, element: Int) -> MediaView.Item {
    var item = MediaView.Item(label: name, element: AXReplay.element(element), ident: "sample[id=\(name)]", desc: name)
    item.play = item.element
    return item
}

func mediaWorkTests() {
    test("media work: serial reads snapshot the latest commit and complete before the next read") {
        let rig = MediaTestRig(); defer { rig.view.stop() }
        var order: [String] = []
        rig.source.result(MediaTestRig.result("A"))
        let gate = rig.gate(); defer { gate.release.signal() }
        rig.view.refresh { order.append(rig.view.pageTitle) }; rig.wait(gate)
        rig.view.refresh { order.append(rig.view.pageTitle) }
        expect(rig.source.state.withLock { $0.sidebars.count }, 1, "second provider has not started in parallel")
        gate.release.signal(); rig.worker.sync {}
        rig.source.result(MediaTestRig.result("B")); rig.settle()
        expect(order, ["A", "B"])
        expect(rig.source.state.withLock { $0.sidebars }, [[], ["A sidebar"]])
        check(rig.source.state.withLock { $0.onMain.allSatisfy { !$0 } }, "both collectors leave main free")
        expect(rig.view.pageTitle, "B")
    }
    test("media work: stopped provider cannot publish, announce or replay its queued key") {
        let rig = MediaTestRig(); defer { rig.view.stop() }
        rig.source.result(MediaTestRig.result("Old"))
        let gate = rig.gate(); defer { gate.release.signal() }
        var completed = 0
        rig.view.refresh { completed += 1 }; rig.wait(gate)
        rig.view.move(1)
        rig.view.stop(); rig.view.beginSession()
        rig.source.result(MediaTestRig.result("New")); rig.view.refresh { completed += 10 }
        gate.release.signal(); rig.settle()
        expect(rig.view.pageTitle, "New"); expect(completed, 10)
        expect(rig.source.state.withLock { $0.cancelled }, 1)
        expect(rig.source.state.withLock { $0.sidebars.count }, 2, "retired initial-key build was discarded")
    }
    test("media work: actual foreground or reader rejection prevents a held main delivery") {
        let rig = MediaTestRig(); defer { rig.view.stop() }
        rig.source.result(MediaTestRig.result("Old"))
        var completed = false
        rig.view.refresh { completed = true }; rig.worker.sync {}
        rig.setEligible(false); rig.settle()
        expect(rig.view.pageTitle, ""); check(!completed, "a late completion cannot reset the pane")
    }
    test("media work: a retired failure cannot finish or clear a newer read") {
        let rig = MediaTestRig(); defer { rig.view.stop() }
        rig.source.result(nil)
        var old = 0, new = 0
        rig.view.refresh { old += 1 }; rig.worker.sync {}
        rig.view.beginSession()
        rig.source.result(MediaTestRig.result("New"))
        let gate = rig.gate(); defer { gate.release.signal() }
        rig.view.refresh { new += 1 }; rig.wait(gate)
        check(rig.deliveries.one(), "old failure was held for delivery")
        expect(old, 0); expect(new, 0); expect(rig.view.pageTitle, "")
        gate.release.signal(); rig.settle()
        expect(new, 1); expect(rig.view.pageTitle, "New")
    }
    test("media work: a search retires earlier refreshes and its delayed page read retires on focus loss") {
        let rig = MediaTestRig(); defer { rig.view.stop() }
        rig.load()
        rig.source.result(MediaTestRig.result("Stale"))
        var old = false
        rig.view.refresh { old = true }; rig.worker.sync {}
        rig.view.afterSearch()
        rig.source.result(MediaTestRig.result("Results"))
        check(rig.delays.fire(0.35), "actual page polling delay was held")
        rig.settle()
        check(!old, "the earlier arrival/refresh callback cannot reset the page")
        expect(rig.view.pageTitle, "Results")
        rig.view.afterSearch(); rig.view.stop()
        let reads = rig.source.state.withLock { $0.sidebars.count }
        check(rig.delays.fire(0.35), "retired delayed poll still reached its guarded callback")
        rig.settle()
        expect(rig.source.state.withLock { $0.sidebars.count }, reads, "no provider work starts after focus loss")
    }
    test("media work: resolved activation keeps the captured item and runs before queued movement") {
        mediaActionFixture(); defer { AXReplay.unload() }
        let rig = MediaTestRig(); defer { rig.view.stop(); rig.worker.sync {} }
        let stale = mediaPlayable("A", element: 99), fresh = mediaPlayable("A", element: 100), other = mediaPlayable("B", element: 101)
        rig.load(items: [stale, other])
        var result = MediaTestRig.result("A", items: [fresh, other]); result.found = fresh
        rig.source.result(result)
        let gate = rig.gate(); defer { gate.release.signal() }
        rig.view.activate(); rig.wait(gate); rig.view.move(1)
        expect(rig.view.currentItem()?.label, "A", "later key waits for the initiating action")
        gate.release.signal(); rig.settle()
        expect(AXReplay.actions.map(\.id), [100], "only the fresh captured app is played")
        expect(rig.view.currentItem()?.label, "B", "queued movement follows the activation")
    }
    test("media work: focus loss during stale-item resolution prevents the provider action") {
        mediaActionFixture(); defer { AXReplay.unload() }
        let rig = MediaTestRig(); defer { rig.view.stop(); rig.worker.sync {} }
        let stale = mediaPlayable("A", element: 99), fresh = mediaPlayable("A", element: 100)
        rig.load(items: [stale])
        var result = MediaTestRig.result("A", items: [fresh]); result.found = fresh
        rig.source.result(result)
        let gate = rig.gate(); defer { gate.release.signal() }
        rig.view.activate(); rig.wait(gate); rig.view.stop()
        gate.release.signal(); rig.settle()
        check(AXReplay.actions.isEmpty && AXReplay.sets.isEmpty, "no stale scroll, playback or focus action")
        expect(rig.source.state.withLock { $0.cancelled }, 1)
    }
    test("media work: a playback confirmation cannot announce after its media session ends") {
        mediaActionFixture(); defer { AXReplay.unload() }
        let rig = MediaTestRig(); defer { rig.view.stop(); rig.worker.sync {} }
        rig.load(items: [mediaPlayable("A", element: 100)])
        let oldSink = Speech.sink
        var spoken: [String] = []
        Speech.sink = { spoken.append($0) }; defer { Speech.sink = oldSink }
        rig.view.activate()
        check(!AXReplay.actions.isEmpty, "the original requested playback happened")
        let before = spoken
        rig.view.stop()
        check(rig.delays.fire(1.5), "the confirmation timer was pending")
        expect(spoken, before, "no late not-playing warning after leaving the reader/app")
    }
    test("media work: a provider cannot substitute another item when resolving activation") {
        mediaActionFixture(); defer { AXReplay.unload() }
        let rig = MediaTestRig(); defer { rig.view.stop(); rig.worker.sync {} }
        rig.load(items: [mediaPlayable("A", element: 99)])
        let other = mediaPlayable("B", element: 101)
        var result = MediaTestRig.result("A", items: [other]); result.found = other
        rig.source.result(result); rig.view.activate(); rig.settle()
        check(AXReplay.actions.isEmpty, "wrong identity was refused instead of pressing the old index")
    }
    test("media work: the real collector publishes a recorded page without changing the app") {
        AXReplay.load(.init(app: "Public Music sample", bundle: "test.media", recorded: "", root: 1, application: 0, focus: nil, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXApplication"), "AXFocusedWindow": .element(1)]),
            .init(id: 1, attrs: ["AXRole": .string("AXWindow"), "AXTitle": .string("Public page"), "AXChildren": .elements([2])]),
            .init(id: 2, attrs: ["AXRole": .string("AXScrollArea"), "AXIdentifier": .string("sample.page"), "AXChildren": .elements([3, 4]), "AXVerticalScrollBar": .element(5)]),
            .init(id: 3, attrs: ["AXRole": .string("AXHeading"), "AXTitle": .string("Featured")]),
            .init(id: 4, attrs: ["AXRole": .string("AXButton"), "AXDescription": .string("Public episode"), "AXIdentifier": .string("sample[id=1]"), "AXParent": .element(2)], actions: ["AXPress"]),
            .init(id: 5, attrs: ["AXRole": .string("AXScrollBar"), "AXValue": .number(0)]),
        ]))
        let rig = MediaTestRig(liveCollector: true)
        defer { rig.view.stop(); rig.worker.sync {}; AXReplay.unload() }
        rig.view.refresh {}; rig.settle()
        expect(rig.view.pageTitle, "Public page")
        expect(rig.view.shelves.flatMap(\.items).map(\.label), ["Public episode"])
        check(AXReplay.actions.isEmpty && AXReplay.sets.isEmpty, "initial reading did not scroll, play, buy or change focus")
    }
    test("media work: an expired request releases the lane without calling its provider") {
        let worker = DispatchQueue(label: "turnover.tests.media-deadline"), delivery = MediaTestDeliveries()
        let called = OSAllocatedUnfairLock(initialState: false)
        let owner = MediaWorkOwner<Int>(queue: worker, deliver: { delivery.enqueue($0) }, eligible: { true })
        defer { owner.stop() }
        var completed = false, next = false
        owner.enqueue {
            owner.perform(duration: 0, { _ in called.withLock { $0 = true }; return 1 }) { result in
                check(result == nil, "expired work is incomplete"); completed = true
                owner.enqueue { next = true }
            }
        }
        worker.sync {}; while delivery.one() { worker.sync {} }
        check(!called.withLock { $0 }, "no query begins after the deadline")
        check(completed && next && !owner.isWorking, "failure completion and the next command finish in order")
    }
}
