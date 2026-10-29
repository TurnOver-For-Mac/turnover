// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os

/// One replacement attempt, shared by its builder, main's installation and the watchdog's deadline.
/// The candidate and outcome move together under one lock; a late builder can never install after expiry
/// (speech recovery review, issue 155, 28 Oct 2026). Generic so tests need no live audio engine.
package final class SpeechRecoveryAttempt<Candidate: Sendable>: Sendable {
    private enum Outcome: Sendable { case pending, installed, expired }
    private struct State: Sendable {
        let deadline: ContinuousClock.Instant
        var outcome = Outcome.pending
        var candidate: Candidate?
    }
    private let state: OSAllocatedUnfairLock<State>

    package convenience init(timeout: Duration = .seconds(3)) {
        self.init(deadline: ContinuousClock.now.advanced(by: timeout))
    }

    package init(deadline: ContinuousClock.Instant) {
        state = OSAllocatedUnfairLock(initialState: State(deadline: deadline))
    }

    /// Called by the builder. A refused candidate stays on that thread for disposal.
    package func offer(_ candidate: Candidate) -> Bool { offer(candidate, at: .now) }
    package func offer(_ candidate: Candidate, at now: ContinuousClock.Instant) -> Bool {
        state.withLock {
            guard $0.outcome == .pending, now < $0.deadline, $0.candidate == nil else { return false }
            $0.candidate = candidate
            return true
        }
    }

    /// Called on main only after checking the original player, stall and wake grace again.
    package func takeForInstallation() -> Candidate? { takeForInstallation(at: .now) }
    package func takeForInstallation(at now: ContinuousClock.Instant) -> Candidate? {
        state.withLock {
            guard $0.outcome == .pending, now < $0.deadline, let candidate = $0.candidate else { return nil }
            $0.outcome = .installed
            $0.candidate = nil
            return candidate
        }
    }

    package var installed: Bool { state.withLock { $0.outcome == .installed } }

    /// Expiry is also cancellation when the player recovers or the Mac sleeps again. Keep disposal off main.
    package func expire() {
        state.withLock { if $0.outcome == .pending { $0.outcome = .expired } }
    }

    /// Transfer any unused candidate to the caller. Production calls this only on its disposal thread.
    package func discard() -> Candidate? {
        state.withLock {
            let candidate = $0.candidate
            $0.candidate = nil
            return candidate
        }
    }

    /// Audio-engine teardown may hang too. Keep it off main and off the watcher that must retry after grace;
    /// the closure retains this owner until the candidate is taken on the disposal thread (#155, 28 Oct 2026).
    package func discardOffThread() {
        let disposer = Thread { _ = self.discard() }
        disposer.name = "turnover.speech.discard"
        disposer.start()
    }
}
