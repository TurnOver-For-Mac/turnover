// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore
import TurnOverAX
import ApplicationServices
import AXFixtures
import os

nonisolated private struct SearchNode: Sendable {
    var parent: Int?
    var children: [Int] = []
    var matches = false
}

nonisolated private func searchQueries(_ tree: [Int: SearchNode],
                           query: @escaping @Sendable (String, Int) -> Void = { _, _ in },
                           row: @escaping @Sendable (Int, Int, Int) -> Int? = { _, _, _ in nil }) -> WindowKindQueries<Int, Int> {
    WindowKindQueries(
        identity: { $0 },
        window: { query("window", $0); return 0 },
        children: { query("children", $0); return tree[$0]?.children ?? [] },
        parent: { query("parent", $0); return tree[$0]?.parent },
        descends: { query("descends", $0); return !(tree[$0]?.children.isEmpty ?? true) },
        matches: { query("matches", $0); return tree[$0]?.matches ?? false },
        neighbourRow: row
    )
}

nonisolated private func searchFound(_ result: WindowKindSearchResult<Int>) -> Int? {
    if case .found(let node) = result { return node }
    return nil
}

nonisolated private func searchStop(_ result: WindowKindSearchResult<Int>) -> AXWalkStop? {
    if case .incomplete(let reason) = result { return reason }
    return nil
}

func axWalkTests() {
    let tree: [Int: SearchNode] = [
        0: SearchNode(children: [1, 2, 5]),
        1: SearchNode(parent: 0, matches: true),
        2: SearchNode(parent: 0, children: [3, 4]),
        3: SearchNode(parent: 2, matches: true),
        4: SearchNode(parent: 2),
        5: SearchNode(parent: 0, matches: true),
    ]
    test("AX window search: forward backward and window edges preserve reading order") {
        func run(_ from: Int, forward: Bool) -> WindowKindSearchResult<Int> {
            var walk = WindowKindSearch(queries: searchQueries(tree), budget: AXWalkBudget(request: AXWalkRequest()))
            return walk.find(from: from, forward: forward)
        }
        expect(searchFound(run(1, forward: true)), 3, "skip the current match and enter the next layout group")
        expect(searchFound(run(5, forward: false)), 3, "previous search checks the previous sibling's last descendants first")
        expect(searchFound(run(0, forward: true)), 1, "window search begins on its first child")
        if case .end = run(0, forward: false) {} else { check(false, "there is no previous item before the window") }
        if case .end = run(5, forward: true) {} else { check(false, "only actual exhaustion reports no next item") }
    }
    test("AX window search: row neighbours avoid fetching every table row") {
        let rows: [Int: SearchNode] = [
            0: SearchNode(children: [10]), 10: SearchNode(parent: 0, children: [20, 21, 22]),
            20: SearchNode(parent: 10, matches: true), 21: SearchNode(parent: 10), 22: SearchNode(parent: 10, matches: true),
        ]
        let bulkReads = OSAllocatedUnfairLock(initialState: 0)
        let queries = searchQueries(rows, query: { operation, node in
            if operation == "children", node == 10 { bulkReads.withLock { $0 += 1 } }
        }, row: { node, parent, offset in parent == 10 && (20...22).contains(node + offset) ? node + offset : nil })
        var forward = WindowKindSearch(queries: queries, budget: AXWalkBudget(request: AXWalkRequest()))
        var backward = WindowKindSearch(queries: queries, budget: AXWalkBudget(request: AXWalkRequest()))
        expect(searchFound(forward.find(from: 21, forward: true)), 22)
        expect(searchFound(backward.find(from: 21, forward: false)), 20)
        expect(bulkReads.withLock { $0 }, 0, "indexed rows retain the existing navigation fast path")
    }
    test("AX window search: a delayed matching reply cannot escape its deadline") {
        let clock = OSAllocatedUnfairLock<UInt64>(initialState: 0)
        let queries = searchQueries(tree, query: { operation, node in
            if operation == "matches", node == 3 { clock.withLock { $0 = 3_000_000_000 } }
        })
        var walk = WindowKindSearch(queries: queries, budget: AXWalkBudget(request: AXWalkRequest(startedAt: 0), now: { clock.withLock { $0 } }))
        let result = walk.find(from: 1, forward: true)
        expect(searchStop(result), .deadline, "late matching result is incomplete, not a valid navigation target or no-match")
        check(searchFound(result) == nil, "expired query cannot move the cursor")
    }
    test("AX window search: cancellation during a matching query discards its target") {
        let request = AXWalkRequest()
        let queries = searchQueries(tree, query: { operation, node in
            if operation == "matches", node == 3 { request.cancel() }
        })
        var walk = WindowKindSearch(queries: queries, budget: AXWalkBudget(request: request))
        let result = walk.find(from: 1, forward: true)
        expect(searchStop(result), .cancelled)
        check(searchFound(result) == nil, "cancelled reply is never an action target")
    }
    test("AX window search: cyclic deep and oversized providers stop as incomplete") {
        let cycle: [Int: SearchNode] = [0: SearchNode(children: [1]), 1: SearchNode(parent: 0, children: [1])]
        var cyclic = WindowKindSearch(queries: searchQueries(cycle), budget: AXWalkBudget(request: AXWalkRequest()))
        expect(searchStop(cyclic.find(from: 0, forward: true)), .cycle, "a repeated child cannot loop indefinitely")
        var chain: [Int: SearchNode] = [0: SearchNode(children: [1])]
        for i in 1...10 { chain[i] = SearchNode(parent: i - 1, children: i < 10 ? [i + 1] : []) }
        var deep = WindowKindSearch(queries: searchQueries(chain), budget: AXWalkBudget(request: AXWalkRequest(), maxDepth: 3))
        expect(searchStop(deep.find(from: 0, forward: true)), .depth)
        var large = WindowKindSearch(queries: searchQueries(chain), budget: AXWalkBudget(request: AXWalkRequest(), maxVisits: 2))
        expect(searchStop(large.find(from: 0, forward: true)), .visits)
        var costly = WindowKindSearch(queries: searchQueries(chain), budget: AXWalkBudget(request: AXWalkRequest(), maxQueries: 1))
        expect(searchStop(costly.find(from: 0, forward: true)), .queries)
        expect(costly.budget.queries, 1, "no provider query begins after the budget is exhausted")
    }
    test("AX window search: slow work coalesces pending keys and publishes only the newest target") {
        let runner = AXWalkRunner<WindowKindSearchResult<Int>>()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let collected = OSAllocatedUnfairLock(initialState: [Int]())
        let published = OSAllocatedUnfairLock(initialState: [Int]())
        let ranOnMain = OSAllocatedUnfairLock(initialState: false)
        runner.submit { request in
            collected.withLock { $0.append(0) }
            ranOnMain.withLock { $0 = Thread.isMainThread }
            let queries = WindowKindQueries<Int, Int>(identity: { $0 }, window: { _ in
                entered.signal()
                _ = release.wait(timeout: .now() + 2)
                return 0
            }, children: { tree[$0]?.children ?? [] }, parent: { tree[$0]?.parent },
                descends: { !(tree[$0]?.children.isEmpty ?? true) }, matches: { tree[$0]?.matches ?? false }, neighbourRow: { _, _, _ in nil })
            var walk = WindowKindSearch(queries: queries, budget: AXWalkBudget(request: request))
            return walk.find(from: 1, forward: true)
        } publish: { if let target = searchFound($0) { published.withLock { $0.append(target) } } }
        check(entered.wait(timeout: .now() + 2) == .success, "first fake query is held off main")
        for key in 1...100 {
            runner.submit { request in
                collected.withLock { $0.append(key) }
                var walk = WindowKindSearch(queries: searchQueries(tree), budget: AXWalkBudget(request: request))
                return walk.find(from: 3, forward: true)
            } publish: { if let target = searchFound($0) { published.withLock { $0.append(target) } } }
        }
        release.signal()
        let until = Date().addingTimeInterval(2)
        while published.withLock({ $0.isEmpty }), Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        expect(collected.withLock { $0 }, [0, 100], "one running query and one latest pending walk, without multiplying AX work")
        expect(published.withLock { $0 }, [5], "only the newest requested target may move the cursor")
        check(!ranOnMain.withLock { $0 }, "a slow AX provider never runs on main")
        runner.cancel()
    }
    test("AX window search: cancellation rejects completed work waiting for main") {
        let runner = AXWalkRunner<Int>()
        let finished = DispatchSemaphore(value: 0)
        let publications = OSAllocatedUnfairLock(initialState: [Int]())
        runner.submit { _ in finished.signal(); return 7 } publish: { target in publications.withLock { $0.append(target) } }
        check(finished.wait(timeout: .now() + 2) == .success, "worker has a result before main can deliver it")
        runner.cancel()   // a newer key, focus/cursor change or reader deactivation
        runner.submit { _ in 9 } publish: { target in publications.withLock { $0.append(target) } }
        let until = Date().addingTimeInterval(2)
        while publications.withLock({ $0.isEmpty }), Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        expect(publications.withLock { $0 }, [9], "stale completion cannot navigate or announce over the current reader")
        runner.cancel()
    }
    test("AX read scope: cancelled actual wrappers report client stop without provider work") {
        let fixture = AXFixture(app: "Public sample", bundle: "test.scope", recorded: "", root: 0, application: nil, focus: nil, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("Public button")], actions: [kAXPressAction]),
        ])
        AXReplay.load(fixture); defer { AXReplay.unload() }
        guard let root = AXReplay.root else { return check(false, "fixture root") }
        let request = AXWalkRequest()
        let budget = AXWalkBudget(request: request)
        let before = AXStats.calls
        AXReadScope.with(while: { budget.check() }, onQuery: { budget.admitAXQuery() }) {
            request.cancel()
            let result = root.attributeResult(kAXRoleAttribute, policy: .diagnosticDirect)
            expect(result.status, .clientWorkStopped, "diagnostic bypass cannot bypass caller cancellation")
            check(result.error == nil && result.value == nil && !result.wasAttempted, "client stop is not a provider error")
            expect(result.elapsedNanoseconds, 0)
            expect(result.legacyError, .cannotComplete)
            check(root.attr(kAXRoleAttribute) == nil, "legacy wrapper also stops")
            let batch = root.attributesResult([kAXRoleAttribute, kAXTitleAttribute])
            expect(batch.query.status, .clientWorkStopped)
            expect(batch.attributes[kAXTitleAttribute]?.status, .clientWorkStopped, "batch slots preserve client stop")
            var rule = ElementMatch(); rule.pressable = true
            check(!ElementMatcher.matches(root, rule), "nested profile action query also respects cancellation")
        }
        expect(AXStats.calls, before, "neither typed legacy batch nor nested profile wrappers attempted an AX API")
        expect(budget.axQueries, 0)
    }
    test("AX read scope: nested guards restore their parent and cleanup after throws") {
        enum SampleError: Error { case stop }
        let fixture = AXFixture(app: "Public sample", bundle: "test.scope", recorded: "", root: 0, application: nil, focus: nil, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXButton")]),
        ])
        AXReplay.load(fixture); defer { AXReplay.unload() }
        guard let root = AXReplay.root else { return check(false, "fixture root") }
        AXReadScope.with(while: { false }) {
            AXReadScope.with(while: { true }) {
                expect(root.attributeResult(kAXRoleAttribute).status, .clientWorkStopped, "inner scope cannot loosen the outer guard")
            }
        }
        do {
            try AXReadScope.with(while: { true }) {
                do {
                    try AXReadScope.with(while: { false }) { throw SampleError.stop }
                } catch {}
                expect(root.attributeResult(kAXRoleAttribute).value as? String, "AXButton", "throw restored the outer permitting scope")
                throw SampleError.stop
            }
        } catch {}
        expect(root.attributeResult(kAXRoleAttribute).value as? String, "AXButton", "outer throw leaves no scope on the caller's thread")
    }
    test("AX read scope: worker scopes do not leak onto the main thread") {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let stopped = OSAllocatedUnfairLock(initialState: false)
        let fixture = AXFixture(app: "Public sample", bundle: "test.scope", recorded: "", root: 0, application: nil, focus: nil, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXButton")]),
        ])
        AXReplay.load(fixture); defer { AXReplay.unload() }
        guard let root = AXReplay.root else { return check(false, "fixture root") }
        DispatchQueue.global().async {
            AXReadScope.with(while: { false }) {
                entered.signal()
                _ = release.wait(timeout: .now() + 2)
                stopped.withLock { $0 = root.attributeResult(kAXRoleAttribute).status == .clientWorkStopped }
            }
            done.signal()
        }
        check(entered.wait(timeout: .now() + 2) == .success, "worker owns a live scope")
        expect(root.attributeResult(kAXRoleAttribute).value as? String, "AXButton", "a different thread continues normally")
        release.signal()
        check(done.wait(timeout: .now() + 2) == .success, "worker scope cleaned up")
        check(stopped.withLock { $0 }, "worker's actual wrapper was stopped")
    }
    test("AX read scope: actual AX query budget is distinct from provider operations") {
        let fixture = AXFixture(app: "Public sample", bundle: "test.scope", recorded: "", root: 0, application: nil, focus: nil, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXButton")], actions: [kAXPressAction]),
        ])
        AXReplay.load(fixture); defer { AXReplay.unload() }
        guard let root = AXReplay.root else { return check(false, "fixture root") }
        let budget = AXWalkBudget(request: AXWalkRequest(), maxAXQueries: 1)
        let before = AXStats.calls
        AXReadScope.with(while: { budget.check() }, onQuery: { budget.admitAXQuery() }) {
            expect(root.attributeResult(kAXRoleAttribute).value as? String, "AXButton")
            expect(root.actionNamesResult().status, .clientWorkStopped, "second actual query is not attempted")
        }
        expect(budget.axQueries, 1)
        expect(budget.queries, 0, "no generic provider operation was counted as an AX API query")
        expect(budget.stopped, .axQueries)
        expect(AXStats.calls, before + 1, "exactly the admitted query reached the replay provider")
    }
    test("AX window search: transport failure before the deadline is incomplete rather than no match") {
        let pid = pid_t(Int32.max - 110)
        defer { AXHealth.forget(pid: pid) }
        for error in [AXError.cannotComplete, .apiDisabled, .invalidUIElement, .failure] {
            let budget = AXWalkBudget(request: AXWalkRequest())
            let queries = searchQueries(tree, query: { operation, node in
                if operation == "matches", node == 3 { _ = AXHealth.query(pid: pid) { error } }
            })
            var walk = WindowKindSearch(queries: queries, budget: budget)
            let result = AXReadScope.with(while: { budget.check() }, onQuery: { budget.admitAXQuery() }, onResult: { budget.record($0) }) {
                walk.find(from: 1, forward: true)
            }
            expect(searchStop(result), .providerFailure, "\(error) must not become an exhausted search or action target")
            check(searchFound(result) == nil, "failed provider cannot move the cursor")
        }
        let budget = AXWalkBudget(request: AXWalkRequest())
        let queries = searchQueries(tree, query: { operation, node in
            if operation == "matches", node == 3 { _ = AXHealth.query(pid: pid) { .attributeUnsupported } }
        })
        var optional = WindowKindSearch(queries: queries, budget: budget)
        let result = AXReadScope.with(while: { budget.check() }, onQuery: { budget.admitAXQuery() }, onResult: { budget.record($0) }) {
            optional.find(from: 1, forward: true)
        }
        expect(searchFound(result), 3, "unsupported optional data still permits existing fallback rules")
    }
    test("AX window search: caller backoff remains incomplete without attempting provider work") {
        let pid = pid_t(Int32.max - 111)
        defer { AXHealth.forget(pid: pid) }
        var ticks: [UInt64] = [100, 1_000_000_100]
        _ = AXHealth.query(pid: pid, clock: { ticks.removeFirst() }) { .cannotComplete }
        let attempted = OSAllocatedUnfairLock(initialState: false)
        let queries = searchQueries(tree, query: { operation, node in
            if operation == "matches", node == 3 {
                _ = AXHealth.query(pid: pid) { attempted.withLock { $0 = true }; return .success }
            }
        })
        let budget = AXWalkBudget(request: AXWalkRequest())
        var walk = WindowKindSearch(queries: queries, budget: budget)
        let result = AXReadScope.with(while: { budget.check() }, onQuery: { budget.admitAXQuery() }, onResult: { budget.record($0) }) {
            walk.find(from: 1, forward: true)
        }
        expect(searchStop(result), .backoff)
        check(!attempted.withLock { $0 }, "deferred provider is never called")
        expect(budget.axQueries, 0, "backoff does not consume an actual API admission")
    }
}
