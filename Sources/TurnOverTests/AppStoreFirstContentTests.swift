// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import TurnOverAX
import AXFixtures

private func firstContentFixture(leadingEmpty: Bool = false, middleReady: Bool = false) -> AXFixture {
    let nav = AXNavigationChildren.navigationAttribute
    var nodes: [AXFixture.Node] = [
        .init(id: 0, attrs: ["AXRole": .string("AXApplication"), "AXFocusedWindow": .element(1)]),
        .init(id: 1, attrs: ["AXRole": .string("AXWindow"), nav: .elements([2])]),
        .init(id: 2, attrs: ["AXRole": .string("AXSplitGroup"), nav: .elements([3])]),
        .init(id: 3, attrs: ["AXRole": .string("AXScrollArea"), nav: .elements([4])]),
        .init(id: 4, attrs: ["AXRole": .string("AXList"), "AXSubrole": .string("AXCollectionList"), "AXIdentifier": .string("AppStore.discover"), nav: .elements(leadingEmpty ? [6, 7] : [5, 6, 7])]),
        .init(id: 5, attrs: ["AXRole": .string("AXGroup"), "AXSubrole": .string("AXSectionList"), "AXDescription": .string("A shelf, Section 1"), "AXNextContentSibling": .element(6), nav: .elements([50])]),
        .init(id: 6, attrs: ["AXRole": .string("AXGroup"), "AXSubrole": .string("AXSectionList"), "AXDescription": .string("B shelf, Section 2"), "AXNextContentSibling": .element(7), nav: .elements([100])]),
        .init(id: 7, attrs: ["AXRole": .string("AXGroup"), "AXSubrole": .string("AXSectionList"), "AXDescription": .string("C shelf, Section 3"), nav: .elements([70])]),
        .init(id: 50, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("A"), nav: .elements([])]),
        .init(id: 70, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("C"), nav: .elements([])]),
        .init(id: 80, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("B"), nav: .elements([])]),
    ]
    // Screenshot items are seen by the carousel walker but produce no reading entries. Twelve plus a tail
    // exercise rollback of both seen identities and provisional carousel state when this shelf is deferred.
    for id in 100...112 {
        var attrs: [String: AXFixture.Value] = ["AXRole": .string("AXGroup"), "AXIdentifier": .string("AppStore.shelfItem.ProductMediaItem"), nav: .elements([])]
        if id < 112 { attrs["AXNextContentSibling"] = .element(id + 1) }
        if middleReady, id == 100 {
            attrs["AXIdentifier"] = .string("AppStore.shelfItem.SmallLockupCollectionViewCell")
            attrs["AXDescription"] = .string("B")
            attrs.removeValue(forKey: "AXNextContentSibling")
        }
        if middleReady, id == 112 {
            attrs["AXIdentifier"] = .string("AppStore.shelfItem.SmallLockupCollectionViewCell")
            attrs["AXDescription"] = .string("Unexpected stale tail")
        }
        nodes.append(.init(id: id, attrs: attrs))
    }
    return .init(app: "Public sample Store", bundle: "test.store.first-content", recorded: "", root: 1, application: 0, focus: nil, nodes: nodes)
}

private final class FirstContentRig {
    let worker: DispatchQueue
    let deliveries: Locked<[@MainActor @Sendable () -> Void]>
    let owner: AppStoreModelOwner

    init(materializeOnScroll: Bool = false) {
        let worker = DispatchQueue(label: "turnover.tests.store-first-content")
        let deliveries = Locked<[@MainActor @Sendable () -> Void]>([])
        self.worker = worker
        self.deliveries = deliveries
        let nav = AXNavigationChildren.navigationAttribute
        let source = AppStoreAXModelSource(pid: AXReplay.floor, makeNavigation: { limits, current in
            var provider = AXNavigationChildren.Source()
            provider.count = { element, attribute in
                if materializeOnScroll, attribute == nav, AXReplay.id(of: element) == 6,
                   AXReplay.actions.contains(where: { $0.id == 6 && $0.action == "AXScrollToVisible" }) {
                    return .init(value: 1, status: .returned(.success), elapsedNanoseconds: 0, wasAttempted: true)
                }
                return element.attributeValueCountResult(attribute)
            }
            provider.values = { element, attribute, count in
                if materializeOnScroll, attribute == nav, AXReplay.id(of: element) == 6,
                   AXReplay.actions.contains(where: { $0.id == 6 && $0.action == "AXScrollToVisible" }) {
                    return .init(value: [AXReplay.element(80)] as CFArray, status: .returned(.success), elapsedNanoseconds: 0, wasAttempted: true)
                }
                return element.attributeValuesResult(attribute, index: 0, maxValues: count)
            }
            return AXNavigationChildren(limits: limits, current: current, source: provider)
        })
        owner = AppStoreModelOwner(pid: AXReplay.floor, source: source, queue: worker, deliver: { callback in
            deliveries.lock.lock(); deliveries.unsafeValue.append(callback); deliveries.lock.unlock()
        })
    }

    func read(_ operation: AppStoreModelRequest.Operation) {
        owner.read(operation)
        worker.sync {}
        deliveries.lock.lock(); let jobs = deliveries.unsafeValue; deliveries.unsafeValue = []; deliveries.lock.unlock()
        for job in jobs { job() }
    }
    func stop() { owner.stop(); worker.sync {} }
}

func appStoreFirstContentTests() {
    test("App Store first content: defer empty later shelf and recover it exactly once with more") {
        AXReplay.load(firstContentFixture()); defer { AXReplay.unload() }
        let rig = FirstContentRig(); defer { rig.stop() }
        rig.read(.page(skipFlatResults: false))
        expect(rig.owner.model.page.map(\.label), ["A"], "publish usable prefix without reading later shelves out of order")
        expect(rig.owner.model.shelves, ["", "A shelf"], "provisional empty shelf slot was rolled back")
        check(AXReplay.actions.isEmpty && AXReplay.sets.isEmpty, "initial prefix did not scroll or change UI")
        AXReplay.load(firstContentFixture(middleReady: true))
        rig.read(.more)
        expect(rig.owner.model.page.map(\.label), ["A", "B", "C"], "deferred same-identity item was not poisoned by provisional seen state")
        expect(rig.owner.model.shelves, ["", "A shelf", "B shelf", "C shelf"])
        rig.read(.carousel(2))
        expect(rig.owner.model.page.map(\.label), ["A", "B", "C"], "provisional screenshot tail cannot append recycled stale items")
    }
    test("App Store first content: End resumes the deferred shelf before following content") {
        AXReplay.load(firstContentFixture()); defer { AXReplay.unload() }
        let rig = FirstContentRig(); defer { rig.stop() }
        rig.read(.page(skipFlatResults: false))
        expect(rig.owner.model.page.map(\.label), ["A"])
        AXReplay.load(firstContentFixture(middleReady: true))
        rig.read(.end)
        expect(rig.owner.model.page.map(\.label), ["A", "B", "C"], "End retains order and does not repeat the prefix")
    }
    test("App Store first content: a leading empty shelf retains eager materialization") {
        AXReplay.load(firstContentFixture(leadingEmpty: true)); defer { AXReplay.unload() }
        let rig = FirstContentRig(materializeOnScroll: true); defer { rig.stop() }
        rig.read(.page(skipFlatResults: false))
        expect(rig.owner.model.page.map(\.label), ["B", "C"], "no readable prefix means existing retry behavior is retained")
        check(AXReplay.actions.contains { $0.id == 6 && $0.action == "AXScrollToVisible" }, "leading shelf was actually asked to materialize")
        check(AXReplay.actions.allSatisfy { $0.action == "AXScrollToVisible" }, "no purchase, press or download action")
    }
}
