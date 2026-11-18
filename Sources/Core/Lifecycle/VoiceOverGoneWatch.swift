// SPDX-License-Identifier: GPL-3.0-or-later
// VoiceOver ended without turning itself off (it crashed, or was stopped from outside): macOS still says it is on.
// The app looks every 2 s; four looks in a row with the flag on and no VoiceOver running decide that it has gone
// (VoiceOver starting shows its process within a second or two). The same decision lets TurnOver's speech through:
// TurnOver took the keys on it, but the speech gate still read the flag alone and refused every word, the recovery's
// own "VoiceOver stopped" included, so nobody spoke (Codex's review, 18 Nov 2026; the watch itself is 14 Oct 2026).
// VoiceOver running again, or its flag off, ends it at the next look.
import Foundation

public final class VoiceOverGoneWatch {
    public static let looksToDecide = 4
    private(set) public var looks = 0
    public init() {}

    /// Whether VoiceOver is gone under a flag that still says on, as decided by the looks so far.
    public var gone: Bool { looks >= Self.looksToDecide }

    /// One look. True only on the look that decides VoiceOver has gone (the app acts on it once).
    @discardableResult
    public func look(flagOn: Bool, running: Bool) -> Bool {
        guard flagOn, !running else {
            looks = 0
            Speech.voiceOverGoneForOutput = false
            return false
        }
        looks += 1
        if gone { Speech.voiceOverGoneForOutput = true }
        return looks == Self.looksToDecide
    }
}
