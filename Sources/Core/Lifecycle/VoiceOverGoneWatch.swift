// SPDX-License-Identifier: GPL-3.0-or-later
// VoiceOver ended without turning itself off (it crashed, or was stopped from outside): macOS still says it is on.
// The app looks every 2 s; four looks in a row with the flag on and no VoiceOver running decide that it has gone
// (VoiceOver starting shows its process within a second or two). The same decision lets TurnOver's speech through:
// TurnOver took the keys on it, but the speech gate still read the flag alone and refused every word, the recovery's
// own "VoiceOver stopped" included, so nobody spoke (Codex's review, 18 Nov 2026; the watch itself is 14 Oct 2026).
// VoiceOver running again, or its flag off, ends it at the next look.
// VoiceOver back under its unchanged flag: TurnOver's speech stops at once, the words already let through included, and
// the app also looks as soon as macOS says VoiceOver's process started, not at the next 2 s look. Clearing the gate
// alone let what was already admitted go on over VoiceOver, two readers for up to about 4 s while the app waited for its
// two looks to hand the keys back (Codex's second review, 18 Nov 2026).
import Foundation

public final class VoiceOverGoneWatch {
    public static let looksToDecide = 4
    private(set) public var looks = 0
    /// Stops TurnOver's speech now, what is playing and what is queued (the app's own; a test gives its own).
    private let stopSpeech: () -> Void
    public init(stopSpeech: @escaping () -> Void = { Speech.cancel() }) { self.stopSpeech = stopSpeech }

    /// Whether VoiceOver is gone under a flag that still says on, as decided by the looks so far.
    public var gone: Bool { looks >= Self.looksToDecide }

    /// One look. True only on the look that decides VoiceOver has gone (the app acts on it once).
    @discardableResult
    public func look(flagOn: Bool, running: Bool) -> Bool {
        guard flagOn, !running else {
            let wasGone = gone
            looks = 0
            Speech.voiceOverGoneForOutput = false
            // VoiceOver is back: it does the talking from now, so TurnOver stops mid-word rather than speak over it.
            if wasGone, running { stopSpeech() }
            return false
        }
        looks += 1
        if gone { Speech.voiceOverGoneForOutput = true }
        return looks == Self.looksToDecide
    }

    /// macOS says VoiceOver's process has started: a look now, with it running, rather than at the next timer.
    public func voiceOverStarted(flagOn: Bool) { look(flagOn: flagOn, running: true) }
}
