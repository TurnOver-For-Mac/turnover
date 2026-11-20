// SPDX-License-Identifier: GPL-3.0-or-later
// With Quick Nav off, Left and Right arrows pressed together turn it on (as VoiceOver's do). "Together" is a
// time limit: before 15 Nov 2026 a Left down and a Right down any time apart counted, even minutes apart, and a
// first key whose key-up was lost (the tap disabled, the app changed) stayed waiting, so ordinary arrow use
// switched Quick Nav on by itself. This is the timing decision, pure so it can be tested.
import Foundation

nonisolated public struct QuickNavChord: Sendable {
    /// The most the second arrow may come after the first for the pair to be the chord (15 Nov 2026: 150 ms; a
    /// real two-finger press is well inside it, and no ordinary Left-then-Right typing is).
    public static let window: TimeInterval = 0.150

    public enum Outcome: Equatable, Sendable {
        /// Nothing waiting that this key pairs with: it is now the first arrow, waiting for a second.
        case first
        /// The pair came within the window; `gapMilliseconds` is the time between the two key-downs.
        case chord(gapMilliseconds: Int)
        /// A Left and a Right, but too far apart: not a chord. This key is now the first arrow.
        case tooSlow(gapMilliseconds: Int)
    }

    private var first: Int64?
    private var firstAt = Date.distantPast

    public init() {}

    /// A bare arrow (123 left, 124 right) went down with Quick Nav off.
    public mutating func down(code: Int64, at now: Date = Date()) -> Outcome {
        if let held = first, held != code, Set([held, code]) == Set<Int64>([123, 124]) {
            let gap = Int((now.timeIntervalSince(firstAt) * 1000).rounded())
            if now.timeIntervalSince(firstAt) >= 0 && now.timeIntervalSince(firstAt) <= Self.window {
                first = nil
                return .chord(gapMilliseconds: gap)
            }
            first = code; firstAt = now
            return .tooSlow(gapMilliseconds: gap)
        }
        first = code; firstAt = now
        return .first
    }

    /// An arrow came up: if it is the waiting first one, nothing is waiting any more.
    public mutating func up(code: Int64) { if code == first { first = nil } }

    /// Forget the waiting key: the tap was disabled or re-enabled, or the app in front changed, so its key-up may
    /// never be seen.
    public mutating func clear() { first = nil }
}
