// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import AXFixtures

nonisolated private final class StoreModelGate: Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    func hold() { entered.signal(); _ = release.wait(timeout: .now() + 3) }
}
nonisolated private final class StoreModelDeliveries: Sendable {
    let pending = Locked<[@MainActor @Sendable () -> Void]>([])
    func enqueue(_ body: @escaping @MainActor @Sendable () -> Void) {
        pending.lock.lock(); pending.unsafeValue.append(body); pending.lock.unlock()
    }
    @MainActor func one() -> Bool {
        pending.lock.lock()
        let body = pending.unsafeValue.isEmpty ? nil : pending.unsafeValue.removeFirst()
        pending.lock.unlock()
        guard let body else { return false }; body(); return true
    }
    @MainActor func drain() { while one() {} }
}
nonisolated private final class StoreModelSource: AppStoreModelSource, Sendable {
    nonisolated struct Settings: Sendable {
        var key = "A", names = ["App A"], addition = "App B"
        var gate: StoreModelGate?
        var fail = false
        var wrongResolvedName: String?
        var alternateShelf = false
        var kind = AppStoreView.Kind.app
        var bases: [[String]] = []
        var onMain: [Bool] = []
        var cancelled = 0
    }
    let settings = Locked(Settings())
    static func entry(_ name: String, shelf: Int = 1, id: Int = 100, kind: AppStoreView.Kind = .app) -> AppStoreView.Entry {
        .init(label: name, element: AXReplay.element(id), kind: kind, shelf: shelf, check: name)
    }
    func read(_ request: AppStoreModelRequest, current: @escaping @Sendable () -> Bool) -> AppStoreModelResult? {
        settings.lock.lock()
        let values = settings.unsafeValue
        settings.unsafeValue.gate = nil; settings.unsafeValue.fail = false
        settings.unsafeValue.bases.append(request.model.page.map(\.label))
        settings.unsafeValue.onMain.append(Thread.isMainThread)
        settings.lock.unlock()
        var model = request.model
        var resolved: AppStoreView.Entry?
        switch request.operation {
        case .page:
            model.key = values.key; model.title = "Page \(values.key)"
            model.shelves = ["", "Featured"]
            if values.alternateShelf { model.shelves.append("Another shelf") }
            model.page = values.names.enumerated().map {
                Self.entry($0.element, shelf: values.alternateShelf && $0.offset == values.names.count - 1 ? 2 : 1, id: $0.offset + 100, kind: values.kind)
            }
        case .more, .end, .carousel:
            model.shelves.append("More")
            model.page.append(Self.entry(values.addition, shelf: model.shelves.count - 1, id: 200))
        case .sidebar:
            model.sidebar = [Self.entry("Search", shelf: 0)]
        case .metadata: break
        case .resolve(let captured, let index):
            var found = captured; found.element = AXReplay.element(888)
            if let wrong = values.wrongResolvedName { found = Self.entry(wrong, shelf: captured.shelf, id: 888) }
            resolved = found
            if model.page.indices.contains(index) { model.page[index] = found }
        }
        values.gate?.hold()
        if !current() { settings.lock.lock(); settings.unsafeValue.cancelled += 1; settings.lock.unlock() }
        if values.fail { return nil }
        if case .metadata = request.operation { return .init(metadata: .init(key: values.key)) }
        return .init(model: model, metadata: .init(key: model.key), resolved: resolved, more: true)
    }
}
private final class StoreModelRig {
    let source = StoreModelSource(), deliveries = StoreModelDeliveries()
    let worker = DispatchQueue(label: "turnover.tests.appstore-model")
    let owner: AppStoreModelOwner
    init(source: AppStoreModelSource? = nil) {
        let delivery = deliveries
        owner = AppStoreModelOwner(pid: AXReplay.floor, source: source ?? self.source, queue: worker,
                                   deliver: { delivery.enqueue($0) })
    }
    func settle() { worker.sync {}; deliveries.drain() }
    func load(_ names: [String] = ["App A"], key: String = "A") {
        source.settings.lock.lock(); source.settings.unsafeValue.names = names; source.settings.unsafeValue.key = key; source.settings.lock.unlock()
        owner.read(.page(skipFlatResults: false)); settle()
    }
    func gate() -> StoreModelGate {
        let gate = StoreModelGate()
        source.settings.lock.lock(); source.settings.unsafeValue.gate = gate; source.settings.lock.unlock()
        return gate
    }
    func wait(_ gate: StoreModelGate) {
        check(gate.entered.wait(timeout: .now() + 3) == .success, "worker reached its controlled gate")
    }
}

func appStoreModelTests() {
    test("app store model: a retired load cannot append rows or replay commands on a new page") {
        let rig = StoreModelRig(); rig.load()
        let gate = rig.gate(); defer { gate.release.signal(); rig.owner.stop() }
        var oldCompletion = 0, oldCommand = 0
        rig.owner.read(.more) { _ in oldCompletion += 1 }; rig.wait(gate)
        rig.owner.enqueue { oldCommand += 1 }
        rig.owner.invalidate()
        rig.source.settings.lock.lock(); rig.source.settings.unsafeValue.names = ["New app"]; rig.source.settings.unsafeValue.key = "B"; rig.source.settings.lock.unlock()
        rig.owner.read(.page(skipFlatResults: false))
        gate.release.signal(); rig.settle()
        expect(rig.owner.model.page.map(\.label), ["New app"])
        expect(rig.owner.model.key, "B")
        expect(oldCompletion, 0); expect(oldCommand, 0)
        expect(rig.source.settings.value.cancelled, 1)
    }
    test("app store model: stale failure does not clear a newer load or drain its queued keys") {
        let rig = StoreModelRig(); rig.load(); defer { rig.owner.stop() }
        rig.source.settings.lock.lock(); rig.source.settings.unsafeValue.fail = true; rig.source.settings.lock.unlock()
        rig.owner.read(.more); rig.worker.sync {}   // failure held before main delivery
        rig.owner.invalidate()
        let gate = rig.gate(); defer { gate.release.signal() }
        rig.owner.read(.page(skipFlatResults: false)); rig.wait(gate)
        var keys = 0; rig.owner.enqueue { keys += 1 }
        check(rig.deliveries.one(), "old failure was queued")
        check(rig.owner.isLoading, "new read remains in flight")
        expect(keys, 0)
        gate.release.signal(); rig.settle()
        check(!rig.owner.isLoading, "only the new completion ends loading")
        expect(keys, 1)
    }
    test("app store model: atomic commit and initiating completion precede queued key replay") {
        let rig = StoreModelRig(); rig.load(); defer { rig.owner.stop() }
        var order: [String] = []
        rig.owner.onApply = { _, model in
            check(Thread.isMainThread, "model publication belongs to main")
            check(model.page.allSatisfy { model.shelves.indices.contains($0.shelf) }, "rows and shelf state commit together")
            order.append("apply")
            rig.owner.enqueue { order.append("observer key") }
        }
        rig.owner.read(.more) { _ in
            expect(rig.owner.model.page.count, 2)
            order.append("finish original Down")
        }
        rig.owner.enqueue { order.append("later key") }
        rig.settle()
        expect(order, ["apply", "finish original Down", "later key", "observer key"])
        check(rig.source.settings.value.onMain.allSatisfy { !$0 }, "all source reads left main")
    }
    test("app store model: queued operations capture the previously committed snapshot") {
        let rig = StoreModelRig(); rig.load(); defer { rig.owner.stop() }
        let gate = rig.gate(); defer { gate.release.signal() }
        rig.owner.read(.carousel(1)); rig.wait(gate)
        rig.source.settings.lock.lock(); rig.source.settings.unsafeValue.addition = "App C"; rig.source.settings.lock.unlock()
        rig.owner.read(.more)
        gate.release.signal(); rig.settle(); rig.settle()
        expect(rig.source.settings.value.bases.suffix(2).map { $0 }, [["App A"], ["App A", "App B"]])
        expect(rig.owner.model.page.map(\.label), ["App A", "App B", "App C"])
    }
    test("app store model: a replayed command finishes before nested commands enter the queue") {
        let rig = StoreModelRig(); rig.load(); defer { rig.owner.stop() }
        var order: [String] = []
        rig.owner.read(.metadata)
        rig.owner.enqueue {
            order.append("A start")
            rig.owner.enqueue { order.append("B") }
            order.append("A end")
        }
        rig.owner.enqueue { order.append("C") }
        rig.settle()
        expect(order, ["A start", "A end", "C", "B"])
    }
    test("app store model: confirmation patches captured identity rather than an old index") {
        let rig = StoreModelRig(); rig.load(); defer { rig.owner.stop() }
        let captured = rig.owner.model.page[0]
        rig.source.settings.lock.lock(); rig.source.settings.unsafeValue.alternateShelf = true; rig.source.settings.lock.unlock()
        rig.load(["App B", "App A"])
        var resolved: AppStoreView.Entry?
        rig.owner.read(.resolve(captured, index: 0)) { resolved = $0?.resolved }; rig.settle()
        expect(resolved?.label, "App A")
        expect(resolved?.shelf, 2, "a captured old row cannot overwrite its current shelf metadata")
        expect(rig.owner.model.page.map(\.label), ["App B", "App A"])
        expect(AXReplay.id(of: rig.owner.model.page[0].element), 100, "new row at old index remains untouched")
        expect(AXReplay.id(of: rig.owner.model.page[1].element), 888, "live element applied only to captured app")
        expect(rig.owner.model.page[1].shelf, 2)
        rig.source.settings.lock.lock(); rig.source.settings.unsafeValue.wrongResolvedName = "Wrong app"; rig.source.settings.lock.unlock()
        rig.owner.read(.resolve(captured, index: 1)) { resolved = $0?.resolved }; rig.settle()
        check(resolved == nil, "a worker reply with a different identity cannot authorize an action")
        expect(rig.owner.model.page.map(\.label), ["App B", "App A"])
    }
    test("app store model: foreground loss retires an in-flight action and later commands") {
        let rig = StoreModelRig(); rig.load()
        let gate = rig.gate(); defer { gate.release.signal(); rig.owner.stop() }
        var actions = 0, keys = 0
        rig.owner.read(.resolve(rig.owner.model.page[0], index: 0)) { _ in actions += 1 }; rig.wait(gate)
        rig.owner.enqueue { keys += 1 }
        rig.owner.stop(); gate.release.signal(); rig.settle()
        expect(actions, 0); expect(keys, 0)
        check(!rig.owner.isLoading, "stop does not await the provider")
        expect(rig.source.settings.value.cancelled, 1)
    }
    test("app store model: ambiguous app and card names stay refused without an index fallback") {
        for kind: AppStoreView.Kind in [.app, .card] {
            let rig = StoreModelRig(); defer { rig.owner.stop() }
            rig.source.settings.lock.lock(); rig.source.settings.unsafeValue.kind = kind; rig.source.settings.lock.unlock()
            rig.load(["Same name, first developer", "Same name, second developer"])
            let captured = rig.owner.model.page[0]
            var resolved: AppStoreView.Entry?
            rig.owner.read(.resolve(captured, index: 0)) { resolved = $0?.resolved }; rig.settle()
            check(resolved == nil, "a matching position is not a unique product identity")
            expect(rig.owner.model.page.compactMap { AXReplay.id(of: $0.element) }, [100, 101])
        }
    }
    test("app store model: an observer starting a newer read owns loading and command replay") {
        let rig = StoreModelRig(); rig.load(); defer { rig.owner.stop() }
        var oldContinuation = 0, newContinuation = 0, keys = 0
        rig.owner.onApply = { _, _ in
            rig.owner.onApply = nil
            rig.owner.read(.metadata) { _ in newContinuation += 1 }
        }
        rig.owner.read(.more) { _ in oldContinuation += 1 }
        rig.owner.enqueue { keys += 1 }
        rig.settle(); rig.settle()
        expect(oldContinuation, 0, "superseded continuation cannot act after an observer starts newer work")
        expect(newContinuation, 1); expect(keys, 1)
    }
    test("app store action boundary: repeat and pre-prompt queued presses cannot confirm a price") {
        let rig = StoreModelRig(); rig.load(); defer { rig.owner.stop() }
        let gate = rig.gate(); defer { gate.release.signal() }
        let captured = rig.owner.model.page[0]
        let context = AppStorePurchaseConfirmation.Context(page: rig.owner.session, itemIdentity: captured.label,
                                                            offerTitle: "£2.99", button: AXReplay.element(801))
        var confirmation = AppStorePurchaseConfirmation()
        var decisions: [String] = []
        let start = Date(timeIntervalSince1970: 1000)
        func gesture(_ tick: UInt64, repeatKey: Bool = false, code: Int64 = 49) -> KeyboardGesture {
            .init(keyCode: code, modifiers: [], characters: "", timestamp: tick, isRepeat: repeatKey, flags: [])
        }
        // This is the same dispatch seam used by AppStoreAppModule's Enter and Space bindings.
        AppStoreActionPress.dispatch(gesture(10)) { press in
            rig.owner.read(.resolve(captured, index: 0)) { _ in
                decisions.append(String(describing: confirmation.decide(context, press: press, at: start, armTick: 100)))
            }
        }
        rig.wait(gate)
        AppStoreActionPress.dispatch(gesture(20)) { press in
            rig.owner.read(.resolve(captured, index: 0)) { _ in
                decisions.append(String(describing: confirmation.decide(context, press: press, at: start.addingTimeInterval(1), armTick: 200)))
            }
        }
        gate.release.signal(); rig.settle(); rig.settle()
        expect(decisions, ["prompt", "ignore"], "replay cannot turn an earlier physical press into confirmation")
        let reads = rig.source.settings.value.bases.count
        for code: Int64 in [49, 36] {
            AppStoreActionPress.dispatch(gesture(250, repeatKey: true, code: code)) { _ in
                Harness.fail("autorepeated Enter/Space reached the paid-capable module action")
            }
        }
        rig.settle()
        expect(rig.source.settings.value.bases.count, reads, "repeat did not schedule another resolve")
        AppStoreActionPress.dispatch(gesture(220)) { press in
            rig.owner.read(.resolve(captured, index: 0)) { _ in
                decisions.append(String(describing: confirmation.decide(context, press: press, at: start.addingTimeInterval(2), armTick: 300)))
            }
        }
        rig.settle()
        expect(decisions, ["prompt", "ignore", "confirm"], "a distinct physical press after the prompt still confirms")
    }
    test("app store action boundary: a script dispatched after the prompt retains its earlier physical timestamp") {
        let rig = StoreModelRig(); rig.load(); defer { rig.owner.stop() }
        let captured = rig.owner.model.page[0]
        let context = AppStorePurchaseConfirmation.Context(page: rig.owner.session, itemIdentity: captured.label,
                                                            offerTitle: "£2.99", button: AXReplay.element(801))
        var confirmation = AppStorePurchaseConfirmation()
        let start = Date(timeIntervalSince1970: 1000)
        let first = KeyboardGesture(keyCode: 36, modifiers: [], characters: "", timestamp: 10, isRepeat: false, flags: [])
        // The second event exists before the prompt, but its script is held until afterwards.
        let heldScript = KeyboardGesture(keyCode: 36, modifiers: [], characters: "", timestamp: 20, isRepeat: false, flags: [])
        var decisions: [String] = []
        AppStoreActionPress.dispatch(first) { press in
            rig.owner.read(.resolve(captured, index: 0)) { _ in
                decisions.append(String(describing: confirmation.decide(context, press: press, at: start, armTick: 100)))
            }
        }
        rig.settle()
        AppStoreActionPress.dispatch(heldScript) { press in
            expect(press.originTick, 20, "module receipt must not replace the physical event's tick")
            rig.owner.read(.resolve(captured, index: 0)) { _ in
                decisions.append(String(describing: confirmation.decide(context, press: press, at: start.addingTimeInterval(1), armTick: 200)))
            }
        }
        rig.settle()
        expect(decisions, ["prompt", "ignore"])
    }
    test("app store builder: recorded shelf and carousel state is built off main without actions") {
        var nodes: [AXFixture.Node] = [
            .init(id: 0, attrs: ["AXRole": .string("AXApplication"), "AXFocusedWindow": .element(1)]),
            .init(id: 1, attrs: ["AXRole": .string("AXWindow"), "AXChildren": .elements([2])]),
            .init(id: 2, attrs: ["AXRole": .string("AXSplitGroup"), "AXChildren": .elements([3])]),
            .init(id: 3, attrs: ["AXRole": .string("AXScrollArea"), "AXChildren": .elements([4])]),
            .init(id: 4, attrs: ["AXRole": .string("AXList"), "AXSubrole": .string("AXCollectionList"), "AXIdentifier": .string("AppStore.discover"), "AXDescription": .string("Discover"), "AXChildren": .elements([5])]),
            .init(id: 5, attrs: ["AXRole": .string("AXGroup"), "AXSubrole": .string("AXSectionList"), "AXDescription": .string("Featured, Section 1"), "AXChildren": .elements([6, 7, 8])]),
        ]
        for i in 0..<13 {
            var attrs: [String: AXFixture.Value] = ["AXRole": .string("AXGroup"), "AXIdentifier": .string("AppStore.shelfItem.SmallLockupCollectionViewCell"), "AXDescription": .string("Sample app \(i + 1)"), "AXChildren": .elements([])]
            if i > 0 { attrs["AXPreviousContentSibling"] = .element(i + 5) }
            if i < 12 { attrs["AXNextContentSibling"] = .element(i + 7) }
            nodes.append(.init(id: i + 6, attrs: attrs))
        }
        AXReplay.load(.init(app: "Public sample Store", bundle: "test.store", recorded: "", root: 1, application: 0, focus: nil, nodes: nodes))
        let delivery = StoreModelDeliveries(), worker = DispatchQueue(label: "turnover.tests.store-builder")
        let owner = AppStoreModelOwner(pid: AXReplay.floor, queue: worker, deliver: { delivery.enqueue($0) })
        defer { owner.stop(); worker.sync {}; AXReplay.unload() }
        owner.read(.page(skipFlatResults: false)); worker.sync {}; delivery.drain()
        expect(owner.model.page.count, 12)
        expect(owner.model.shelves, ["", "Featured"])
        expect(owner.model.title, "Discover")
        var more = false
        owner.read(.carousel(1)) { more = $0?.more == true }; worker.sync {}; delivery.drain()
        check(more, "the captured carousel tail survives snapshot transfer")
        expect(owner.model.page.count, 13)
        expect(owner.model.page.last?.label, "Sample app 13")
        check(AXReplay.actions.isEmpty && AXReplay.sets.isEmpty, "reading did not press, scroll, buy or download anything")
    }
    test("app store builder: repeated shelf buttons resolve only their original element and section") {
        var fixture = AXFixture(app: "Public sample Store", bundle: "test.store", recorded: "", root: 1, application: 0, focus: nil, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXApplication"), "AXFocusedWindow": .element(1)]),
            .init(id: 1, attrs: ["AXRole": .string("AXWindow"), "AXChildren": .elements([2]), "AXParent": .element(0)]),
            .init(id: 2, attrs: ["AXRole": .string("AXSplitGroup"), "AXChildren": .elements([3]), "AXParent": .element(1)]),
            .init(id: 3, attrs: ["AXRole": .string("AXScrollArea"), "AXChildren": .elements([4]), "AXParent": .element(2)]),
            .init(id: 4, attrs: ["AXRole": .string("AXList"), "AXSubrole": .string("AXCollectionList"), "AXIdentifier": .string("AppStore.discover"), "AXChildren": .elements([5, 6]), "AXParent": .element(3)]),
            .init(id: 5, attrs: ["AXRole": .string("AXGroup"), "AXSubrole": .string("AXSectionList"), "AXDescription": .string("First, Section 1"), "AXChildren": .elements([7]), "AXNextContentSibling": .element(6), "AXParent": .element(4)], actions: ["AXScrollToVisible"]),
            .init(id: 6, attrs: ["AXRole": .string("AXGroup"), "AXSubrole": .string("AXSectionList"), "AXDescription": .string("Second, Section 2"), "AXChildren": .elements([8]), "AXPreviousContentSibling": .element(5), "AXParent": .element(4)], actions: ["AXScrollToVisible"]),
            .init(id: 7, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("See All"), "AXParent": .element(5)], actions: ["AXScrollToVisible"]),
            .init(id: 8, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("See All"), "AXParent": .element(6)], actions: ["AXScrollToVisible"]),
        ])
        AXReplay.load(fixture)
        let delivery = StoreModelDeliveries(), worker = DispatchQueue(label: "turnover.tests.store-controls")
        let owner = AppStoreModelOwner(pid: AXReplay.floor, queue: worker, deliver: { delivery.enqueue($0) })
        defer { owner.stop(); worker.sync {}; AXReplay.unload() }
        owner.read(.page(skipFlatResults: false)); worker.sync {}; delivery.drain()
        expect(owner.model.page.map(\.label), ["See all, First", "See all, Second"])
        guard owner.model.page.count == 2 else { return }
        let captured = owner.model.page[1]
        var resolved: AppStoreView.Entry?
        owner.read(.resolve(captured, index: 0)) { resolved = $0?.resolved }; worker.sync {}; delivery.drain()
        expect(AXReplay.id(of: resolved?.element), 8, "wrong index hint cannot select the other See All")
        expect(resolved?.shelf, 2)
        check(AXReplay.actions.allSatisfy { $0.action == "AXScrollToVisible" && [6, 8].contains($0.id) }, "only the captured shelf/control was revealed; no press")
        check(AXReplay.sets.isEmpty, "no focus, purchase or download was changed")
        fixture.nodes[8].attrs["AXParent"] = .element(5)   // the same control is now under another shelf
        AXReplay.load(fixture)
        resolved = nil
        owner.read(.resolve(captured, index: 1)) { resolved = $0?.resolved }; worker.sync {}; delivery.drain()
        check(resolved == nil, "a recycled control outside the captured section is not accepted")
        check(AXReplay.actions.isEmpty, "section mismatch was refused before any reveal/action")
    }
    test("app store applied selection: same-worded controls retain their element and section across commits") {
        let first = AppStoreView.Entry(label: "See All", element: AXReplay.element(101), kind: .button, shelf: 1,
                                       section: AXReplay.element(11), check: "See All")
        let second = AppStoreView.Entry(label: "See All", element: AXReplay.element(102), kind: .button, shelf: 2,
                                        section: AXReplay.element(12), check: "See All")
        var old = AppStoreModel(); old.key = "same page"; old.page = [first, second]; old.shelves = ["", "First", "Second"]
        var new = old
        // This is the production selection-application seam called by AppStoreView.applied.
        var selection = new.retainingPageSelection(from: old, index: 1)
        expect(selection.index, 1, "a commit cannot jump from the second See All to the first")
        check(selection.retained, "the exact captured control remains selected")
        new.page = [second, first]
        selection = new.retainingPageSelection(from: old, index: 1)
        expect(selection.index, 0, "a reordered control is followed by identity rather than old index")
        check(new.containsSelection(second, at: 0) && !new.containsSelection(second, at: 1), "delayed status uses that same selection identity")
        let replacement = AppStoreView.Entry(label: "See All", element: AXReplay.element(103), kind: .button, shelf: 2,
                                             section: AXReplay.element(12), check: "See All")
        new.page = [first, replacement]
        selection = new.retainingPageSelection(from: old, index: 1)
        check(!selection.retained && !new.containsSelection(second, at: 1), "a same-label replacement cannot retain or speak for the captured control")
    }
    test("app store builder: a recycled same-name row cannot reuse a different full provider identity") {
        var fixture = AXFixture(app: "Public sample Store", bundle: "test.store", recorded: "", root: 1, application: 0, focus: nil, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXApplication"), "AXFocusedWindow": .element(1)]),
            .init(id: 1, attrs: ["AXRole": .string("AXWindow"), "AXChildren": .elements([2]), "AXPosition": .point(0, 0), "AXSize": .size(600, 500)]),
            .init(id: 2, attrs: ["AXRole": .string("AXSplitGroup"), "AXChildren": .elements([3])]),
            .init(id: 3, attrs: ["AXRole": .string("AXScrollArea"), "AXChildren": .elements([4]), "AXPosition": .point(0, 0), "AXSize": .size(600, 500)]),
            .init(id: 4, attrs: ["AXRole": .string("AXList"), "AXSubrole": .string("AXCollectionList"), "AXIdentifier": .string("AppStore.discover"), "AXChildren": .elements([5])]),
            .init(id: 5, attrs: ["AXRole": .string("AXGroup"), "AXSubrole": .string("AXSectionList"), "AXDescription": .string("Featured, Section 1"), "AXChildren": .elements([6])]),
            .init(id: 6, attrs: ["AXRole": .string("AXGroup"), "AXIdentifier": .string("AppStore.shelfItem.SmallLockupCollectionViewCell"),
                               "AXDescription": .string("Same app, First developer"), "AXChildren": .elements([]),
                               "AXPosition": .point(20, 20), "AXSize": .size(300, 60)]),
        ])
        AXReplay.load(fixture)
        let delivery = StoreModelDeliveries(), worker = DispatchQueue(label: "turnover.tests.store-full-identity")
        let owner = AppStoreModelOwner(pid: AXReplay.floor, queue: worker, deliver: { delivery.enqueue($0) })
        defer { owner.stop(); worker.sync {}; AXReplay.unload() }
        owner.read(.page(skipFlatResults: false)); worker.sync {}; delivery.drain()
        guard let captured = owner.model.page.first else { return Harness.fail("fixture row was not built") }
        fixture.nodes[6].attrs["AXDescription"] = .string("Same app, Second developer")
        AXReplay.load(fixture)
        var result: AppStoreModelResult?
        owner.read(.resolve(captured, index: 0)) { result = $0 }; worker.sync {}; delivery.drain()
        check(result?.resolved == nil, "the first-comma name is not proof of the record that was read")
        check(result?.needsRefresh == true, "changed live identity requests a new model without retrying the action")
        expect(owner.model.page.first?.label, "Same app, First developer", "refused reply cannot silently relabel/authorize the old action")
        check(AXReplay.actions.isEmpty && AXReplay.sets.isEmpty, "no control was pressed, purchased or changed")
    }
}
