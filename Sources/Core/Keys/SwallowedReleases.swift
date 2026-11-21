// SPDX-License-Identifier: GPL-3.0-or-later
// The keys whose press TurnOver took and whose release it will swallow to match (KeyboardHandler's `quarantined`).
// A release hidden by secure input left its entry behind, and the next release of that key, after a press the app did
// see, would be swallowed: the app would think the key still held (read from the code, 18 Nov 2026; not seen live).
import Foundation

nonisolated public enum SwallowedReleases {
    /// A press of `code`: if its release is still awaited from an earlier press, drop that entry and say so. A key's
    /// own repeats are not a new press. Physical keys cannot be pressed twice without a release between.
    public static func dropsStale(_ awaited: inout Set<Int64>, code: Int64, isRepeat: Bool) -> Bool {
        guard !isRepeat else { return false }
        return awaited.remove(code) != nil
    }
}

/// A key going down, in the keyboard thread's order (18 Nov 2026, a review): first the echo guard, then the stale
/// release. An echo copy is dropped before anything else is touched, so a swallowed press keeps its release swallowed
/// however many copies come; only a press that gets past the guard can drop a stale entry.
nonisolated public struct KeyDownGate {
    public enum Outcome: Equatable {
        /// An echo copy: the same key a third time or more within 8 ms. `first` for the first one dropped (it is logged).
        case echo(first: Bool)
        /// Past the guard; `droppedStale` when an awaited release of this key was forgotten.
        case accepted(droppedStale: Bool)
    }
    private var echoCode: Int64 = -1
    private var echoAt: UInt64 = 0
    private var echoCount = 0
    public init() {}

    public mutating func press(code: Int64, isRepeat: Bool, nowNs: UInt64, awaited: inout Set<Int64>) -> Outcome {
        if code == echoCode,
           nowNs &- echoAt < 8_000_000 { echoCount += 1 } else { echoCount = 0 }
        echoCode = code; echoAt = nowNs
        if echoCount >= 2 { return .echo(first: echoCount == 2) }
        return .accepted(droppedStale: SwallowedReleases.dropsStale(&awaited, code: code, isRepeat: isRepeat))
    }
}
