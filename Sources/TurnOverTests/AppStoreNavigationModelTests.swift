// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import TurnOverAX
import AXFixtures
import os

func appStoreNavigationModelTests() {
    let nav = AXNavigationChildren.navigationAttribute
    func fixture(cycle: Bool = false) -> AXFixture {
        var nodes: [AXFixture.Node] = [
            .init(id: 0, attrs: ["AXRole": .string("AXApplication"), "AXFocusedWindow": .element(1)]),
            .init(id: 1, attrs: ["AXRole": .string("AXWindow"), "AXChildren": .elements([]), nav: .elements([2])]),
            .init(id: 2, attrs: ["AXRole": .string("AXSplitGroup"), "AXChildren": .elements([]), nav: .elements([3])]),
            .init(id: 3, attrs: ["AXRole": .string("AXScrollArea"), "AXChildren": .elements([]), nav: .elements([4])]),
            .init(id: 4, attrs: ["AXRole": .string("AXList"), "AXSubrole": .string("AXCollectionList"), "AXIdentifier": .string("AppStore.discover"), "AXDescription": .string("Discover"), "AXChildren": .elements([]), nav: .elements([5])]),
            .init(id: 5, attrs: ["AXRole": .string("AXGroup"), "AXSubrole": .string("AXSectionList"), "AXDescription": .string("Public items, Section 1"), "AXChildren": .elements([]), nav: .elements(cycle ? [8] : [7, 6, 6])]),
            .init(id: 6, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("First"), nav: .elements([])]),
            .init(id: 7, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("Second"), nav: .elements([])]),
        ]
        if cycle {
            nodes.append(.init(id: 8, attrs: ["AXRole": .string("AXGroup"), nav: .elements([9])]))
            nodes.append(.init(id: 9, attrs: ["AXRole": .string("AXGroup"), nav: .elements([8])]))
        }
        return .init(app: "Public sample Store", bundle: "test.store.navigation", recorded: "", root: 1, application: 0, focus: nil, nodes: nodes)
    }
    func drain(_ deliveries: Locked<[@MainActor @Sendable () -> Void]>) {
        deliveries.lock.lock(); let jobs = deliveries.unsafeValue; deliveries.unsafeValue = []; deliveries.lock.unlock()
        for job in jobs { job() }
    }

    test("App Store navigation model: semantic-only public children reach the default committed page") {
        AXReplay.load(fixture()); defer { AXReplay.unload() }
        let worker = DispatchQueue(label: "turnover.tests.store-navigation"), deliveries = Locked<[@MainActor @Sendable () -> Void]>([])
        let owner = AppStoreModelOwner(pid: AXReplay.floor, queue: worker, deliver: { callback in
            deliveries.lock.lock(); deliveries.unsafeValue.append(callback); deliveries.lock.unlock()
        })
        defer { owner.stop(); worker.sync {} }
        check(AXReplay.root!.elements(kAXChildrenAttribute).isEmpty, "ordinary window children expose no content")
        owner.read(.page(skipFlatResults: false)); worker.sync {}; drain(deliveries)
        expect(owner.model.title, "Discover")
        expect(owner.model.page.map(\.label), ["Second", "First"], "default model uses semantic order and removes duplicate references")
        expect(owner.model.shelves, ["", "Public items"])
        check(AXReplay.actions.isEmpty && AXReplay.sets.isEmpty, "model reading never pressed, scrolled or purchased")
    }
    test("App Store navigation model: a cyclic section cannot replace a useful committed page") {
        AXReplay.load(fixture()); defer { AXReplay.unload() }
        let worker = DispatchQueue(label: "turnover.tests.store-navigation-cycle"), deliveries = Locked<[@MainActor @Sendable () -> Void]>([])
        let owner = AppStoreModelOwner(pid: AXReplay.floor, queue: worker, deliver: { callback in
            deliveries.lock.lock(); deliveries.unsafeValue.append(callback); deliveries.lock.unlock()
        })
        defer { owner.stop(); worker.sync {} }
        owner.read(.page(skipFlatResults: false)); worker.sync {}; drain(deliveries)
        let before = owner.model.page.map(\.label)
        AXReplay.load(fixture(cycle: true))
        var refused = false
        owner.read(.page(skipFlatResults: false)) { refused = $0 == nil }; worker.sync {}; drain(deliveries)
        check(refused, "cycle in the builder's own traversal refuses partial/empty publication")
        expect(owner.model.page.map(\.label), before)
    }
    test("App Store navigation model: failure in final same-key metadata cannot publish partial data") {
        AXReplay.load(fixture()); defer { AXReplay.unload() }
        nonisolated struct State: Sendable { var count = 0; var failAt: Int? }
        let state = OSAllocatedUnfairLock(initialState: State())
        let root = AXReplay.root!
        let source = AppStoreAXModelSource(pid: AXReplay.floor, makeNavigation: { limits, current in
            var reads = 0
            let failAt = state.withLock { $0.failAt }
            var provider = AXNavigationChildren.Source()
            provider.count = { element, attribute in
                if attribute == nav, CFEqual(element, root) {
                    reads += 1
                    state.withLock { $0.count = reads }
                    if reads == failAt { return .init(value: nil, status: .returned(.cannotComplete), elapsedNanoseconds: 0, wasAttempted: true) }
                }
                return element.attributeValueCountResult(attribute)
            }
            return AXNavigationChildren(limits: limits, current: current, source: provider)
        })
        let worker = DispatchQueue(label: "turnover.tests.store-navigation-final"), deliveries = Locked<[@MainActor @Sendable () -> Void]>([])
        let owner = AppStoreModelOwner(pid: AXReplay.floor, source: source, queue: worker, deliver: { callback in
            deliveries.lock.lock(); deliveries.unsafeValue.append(callback); deliveries.lock.unlock()
        })
        defer { owner.stop(); worker.sync {} }
        owner.read(.page(skipFlatResults: false)); worker.sync {}; drain(deliveries)
        let before = owner.model.page.map(\.label)
        let lastMetadataRead = state.withLock { $0.count }
        check(lastMetadataRead > 1, "recorded provider exercised before/build/final metadata")
        state.withLock { $0.failAt = lastMetadataRead }
        var refused = false
        owner.read(.page(skipFlatResults: false)) { refused = $0 == nil }; worker.sync {}; drain(deliveries)
        check(refused, "same page key is insufficient after final metadata stopped")
        expect(owner.model.page.map(\.label), before, "failure preserves the previous atomic snapshot")
    }
}
