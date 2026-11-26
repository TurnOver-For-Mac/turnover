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

/// The keys that went to the application as another key (a system prompt's Return as Space, 26 Nov 2026), kept on the
/// keyboard thread from the press to the release: the application saw the other key go down, so it must see that key
/// come up, whatever the tap is doing by then (the keypad's commands, a main thread that has stopped, a tap that was
/// off). Asked before anything else about every real key event (a review, 26 Nov 2026: the release was looked for
/// only after the keypad had had it, and Shift with numpad Enter left Space held down in the application).
nonisolated public struct KeysSentAsOthers {
    public enum Step: Equatable {
        /// Not one of these keys: the event goes the usual way.
        case asItIs
        /// A repeat of a key that is down as another key: it goes nowhere. One press presses one button.
        case dropped
        /// The key's release: it goes as the release of the key it went down as.
        case releasedAs(Int64)
        /// A fresh press of the key, whose earlier release was never seen (secure input hid it, or the tap was off):
        /// the key it went down as is owed its release, and this press is its own.
        case pressedAgain(owed: Int64)
    }
    private var down: [Int64: Int64] = [:]
    public init() {}
    public var isEmpty: Bool { down.isEmpty }

    /// `code` went down as `other`.
    public mutating func wentDown(_ code: Int64, as other: Int64) { down[code] = other }

    /// A real key event, down or up.
    public mutating func step(code: Int64, down isDown: Bool, isRepeat: Bool) -> Step {
        guard let other = down[code] else { return .asItIs }
        if isDown, isRepeat { return .dropped }
        down[code] = nil
        return isDown ? .pressedAgain(owed: other) : .releasedAs(other)
    }

    /// Forgets the keys `isGone` names (those no longer held, after the tap was off) and returns the keys they went
    /// down as: each is owed its release.
    public mutating func forget(where isGone: (Int64) -> Bool) -> [Int64] {
        let gone = down.filter { isGone($0.key) }
        for code in gone.keys { down[code] = nil }
        return gone.values.sorted()
    }
}
