// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore
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
}
