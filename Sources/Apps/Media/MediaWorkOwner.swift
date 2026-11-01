// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os

/// Cancellation is independent of an in-flight AX call. This checked token is the only mutable state the
/// media worker shares with main; the deadline is cooperative and does not change provider timeouts (#182).
nonisolated package final class MediaWorkRequest: Sendable {
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    private let deadline: UInt64
    private let now: @Sendable () -> UInt64

    package init(duration: UInt64, now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.now = now
        let end = now().addingReportingOverflow(duration)
        deadline = end.overflow ? UInt64.max : end.partialValue
    }

    package func cancel() { cancelled.withLock { $0 = true } }
    package func current() -> Bool { !cancelled.withLock { $0 } && now() < deadline }
}

/// One serial worker per media view. Main owns the session, committed model and command ordering; workers get
/// immutable snapshots. Retiring a page or leaving the app also retires its queued work and continuations.
package final class MediaWorkOwner<Result: Sendable> {
    package private(set) var session = UUID()
    package private(set) var isWorking = false
    private var active = true
    private var request: MediaWorkRequest?
    private var finishing = false
    private var draining = false
    private var queued: [@MainActor () -> Void] = []
    private let eligible: @MainActor () -> Bool
    private let queue: DispatchQueue
    private let deliver: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void

    package init(queue: DispatchQueue? = nil,
                 deliver: @escaping @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void = { onMain($0) },
                 eligible: @escaping @MainActor () -> Bool) {
        self.queue = queue ?? DispatchQueue(label: "turnover.media.model", qos: .userInitiated)
        self.deliver = deliver; self.eligible = eligible
    }

    package func isCurrent(_ generation: UUID) -> Bool { active && session == generation && eligible() }

    package func beginSession() { retire(); active = true }
    package func stop() { retire(); active = false }

    private func retire() {
        request?.cancel(); request = nil
        session = UUID(); isWorking = false; finishing = false; queued = []
    }

    /// Preparation stays on main and happens only when earlier work/its initiating continuation have finished.
    /// A queued build therefore snapshots the model that was just committed, rather than an older sidebar.
    package func enqueue(_ command: @escaping @MainActor () -> Void) {
        guard active else { return }
        queued.append(command)
        drain()
    }

    package func perform(duration: UInt64 = 12_000_000_000,
                         _ collect: @escaping @Sendable (@escaping @Sendable () -> Bool) -> Result?,
                         then: @escaping @MainActor @Sendable (Result?) -> Void) {
        guard active, !isWorking else { return }
        guard eligible() else { stop(); return }
        let token = MediaWorkRequest(duration: duration)
        let generation = session
        request = token; isWorking = true
        queue.async { [weak self, deliver] in
            let result = token.current() ? collect { token.current() } : nil
            deliver { [weak self] in
                guard let self, active, session == generation, request === token else { return }
                guard eligible() else { stop(); return }
                request = nil; isWorking = false; finishing = true
                then(token.current() ? result : nil)
                guard session == generation else { return }
                finishing = false
                drain()
            }
        }
    }

    private func drain() {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while active, !isWorking, !finishing, !queued.isEmpty {
            guard eligible() else { stop(); return }
            queued.removeFirst()()
        }
    }
}
