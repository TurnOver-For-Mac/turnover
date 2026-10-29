// SPDX-License-Identifier: GPL-3.0-or-later
// A stalled queue is acknowledged only once recovery accepts it. Sleep/wake grace may defer the request;
// the next watch poll must then try again, unless a heartbeat or replacement made it obsolete (#155, 28 Oct 2026).
import Foundation
import os

package final class SpeechQueueWatch: Sendable {
    package struct Stall: Sendable, Equatable {
        fileprivate let generation: UInt64
        fileprivate let claim: UInt64
        package let seconds: TimeInterval
        package let doing: String
    }

    private struct State: Sendable {
        var at: Date
        var generation: UInt64 = 0
        var nextClaim: UInt64 = 0
        var pending: UInt64?
        var acknowledged = false
        var retired = false
        var doing = "nothing yet (stuck before its first heartbeat)"
    }

    private let state: OSAllocatedUnfairLock<State>

    package init(now: Date = Date()) {
        state = OSAllocatedUnfairLock(initialState: State(at: now))
    }

    package func heartbeat(at now: Date = Date()) {
        state.withLock {
            guard !$0.retired else { return }
            $0.at = now
            $0.generation &+= 1
            $0.pending = nil
            $0.acknowledged = false
            $0.doing = "idle"
        }
    }

    package func noteDoing(_ operation: String) {
        state.withLock { $0.doing = operation }
    }

    package func claim(at now: Date = Date()) -> Stall? {
        state.withLock {
            let seconds = now.timeIntervalSince($0.at)
            guard !$0.retired, !$0.acknowledged, $0.pending == nil, seconds > 4 else { return nil }
            $0.nextClaim &+= 1
            $0.pending = $0.nextClaim
            return Stall(generation: $0.generation, claim: $0.nextClaim, seconds: seconds, doing: $0.doing)
        }
    }

    package func isCurrent(_ stall: Stall) -> Bool {
        state.withLock { !$0.retired && $0.generation == stall.generation && $0.pending == stall.claim }
    }

    package func complete(_ stall: Stall, accepted: Bool) {
        state.withLock {
            guard !$0.retired, $0.generation == stall.generation, $0.pending == stall.claim else { return }
            $0.pending = nil
            $0.acknowledged = accepted
        }
    }

    package func retire() {
        state.withLock {
            $0.retired = true
            $0.pending = nil
        }
    }

    package var isRetired: Bool { state.withLock { $0.retired } }
}
