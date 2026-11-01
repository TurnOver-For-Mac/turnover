// SPDX-License-Identifier: GPL-3.0-or-later
import TurnOverSpeech

/// Main-actor handback admission. The app supplies its current reader state; tests supply fake reader effects.
/// Deferring during wake must leave the incident claimable, whereas a delivery invalidated by output/cancellation
/// must never release a newer reader's mute lease (28 Oct 2026, issue 71).
public enum SpeechOutputRecovery {
    public enum ReaderState { case inactive, intentionallyQuiet, waking, required }

    @discardableResult
    public static func receive(_ failure: SpeechOutputFailure, isCurrent: Bool, state: ReaderState,
                               handBack: () -> Void) -> Bool {
        guard isCurrent, state == .required, failure.claim() else { return false }
        handBack()
        return true
    }
}
