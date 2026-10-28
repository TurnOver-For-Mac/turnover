// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os

nonisolated package enum AXWalkStop: String, Sendable { case cancelled, deadline, visits, queries, depth, cycle }

/// Cancellation never waits for an in-flight accessibility call. Its result is checked again before publication.
nonisolated package final class AXWalkRequest: Sendable {
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    package let startedAt: UInt64
    package init(startedAt: UInt64 = DispatchTime.now().uptimeNanoseconds) { self.startedAt = startedAt }
    package var isCancelled: Bool { cancelled.withLock { $0 } }
    package func cancel() { cancelled.withLock { $0 = true } }
}

/// A cooperative budget: a system call cannot be preempted, so check both before and after every provider query.
/// Query limits count navigation-provider operations, not every AX IPC hidden inside a provider's item rules.
nonisolated package struct AXWalkBudget {
    private let request: AXWalkRequest
    private let deadline: UInt64
    private let now: @Sendable () -> UInt64
    private let maxVisits: Int
    private let maxQueries: Int
    private let maxDepth: Int
    package private(set) var visits = 0
    package private(set) var queries = 0
    package private(set) var stopped: AXWalkStop?

    package init(request: AXWalkRequest, duration: UInt64 = 2_000_000_000, maxVisits: Int = 5000,
                 maxQueries: Int = 20_000, maxDepth: Int = 200,
                 now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.request = request
        deadline = request.startedAt.addingReportingOverflow(duration).overflow ? UInt64.max : request.startedAt + duration
        self.maxVisits = maxVisits
        self.maxQueries = maxQueries
        self.maxDepth = maxDepth
        self.now = now
    }

    package mutating func check() -> Bool {
        guard stopped == nil else { return false }
        if request.isCancelled { stopped = .cancelled }
        else if now() >= deadline { stopped = .deadline }
        return stopped == nil
    }

    package mutating func visit() -> Bool {
        guard check() else { return false }
        guard visits < maxVisits else { stopped = .visits; return false }
        visits += 1
        return true
    }

    package mutating func depth(_ depth: Int) -> Bool {
        guard check() else { return false }
        guard depth <= maxDepth else { stopped = .depth; return false }
        return true
    }

    package mutating func halt(_ reason: AXWalkStop) { if stopped == nil { stopped = reason } }

    package mutating func query<Value>(_ body: () -> Value) -> Value? {
        guard check() else { return nil }
        guard queries < maxQueries else { stopped = .queries; return nil }
        queries += 1
        let answer = body()
        return check() ? answer : nil
    }
}

/// One executing job and one replaceable pending job. Repeated keys cannot launch parallel AX walks or leave
/// hundreds of obsolete walks queued behind a slow system call (issue 119, 28 Oct 2026).
nonisolated package final class AXWalkRunner<Result: Sendable>: Sendable {
    private struct Job: Sendable {
        let request: AXWalkRequest
        let collect: @Sendable (AXWalkRequest) -> Result
        let publish: @MainActor @Sendable (Result) -> Void
    }
    private struct State: Sendable {
        var current: AXWalkRequest?
        var pending: Job?
        var running = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "turnover.ax-window-search", qos: .userInitiated)

    package init() {}

    package func submit(collect: @escaping @Sendable (AXWalkRequest) -> Result,
                        publish: @escaping @MainActor @Sendable (Result) -> Void) {
        let request = AXWalkRequest()
        let start = state.withLock { state in
            state.current?.cancel()
            state.current = request
            state.pending = Job(request: request, collect: collect, publish: publish)
            guard !state.running else { return false }
            state.running = true
            return true
        }
        if start { queue.async { [self] in drain() } }
    }

    package func cancel() {
        state.withLock {
            $0.current?.cancel()
            $0.current = nil
            $0.pending = nil
        }
    }

    private func drain() {
        while let job = state.withLock({ state -> Job? in
            guard let job = state.pending else { state.running = false; return nil }
            state.pending = nil
            return job
        }) {
            guard !job.request.isCancelled else { continue }
            let result = job.collect(job.request)
            onMain { [self] in
                // Keep this check at delivery: a completed result may wait on main while focus or keys move on.
                guard !job.request.isCancelled, state.withLock({ $0.current === job.request }) else { return }
                job.publish(result)
                state.withLock { if $0.current === job.request { $0.current = nil } }
            }
        }
    }
}
