// SPDX-License-Identifier: GPL-3.0-or-later
// 14 Nov 2026: a mode announcement waits for speech readiness, independently of reader ownership.

nonisolated public enum ModeSpeechPolicy {
    public enum Reader { case turnOver, voiceOver }

    public static func canAnnounce(reader: Reader, generation: Int, currentGeneration: Int,
                                   coexisting: Bool, turnOverActive: Bool,
                                   voiceOverEnabled: Bool, voiceOverSilent: Bool,
                                   voiceOverRunning: Bool, voiceOverMuteKnown: Bool) -> Bool {
        guard generation == currentGeneration else { return false }
        switch reader {
        case .turnOver:
            guard turnOverActive else { return false }
            guard coexisting || (!voiceOverEnabled && !voiceOverRunning) else { return false }
            guard !voiceOverRunning || (voiceOverMuteKnown && voiceOverSilent) else { return false }
        case .voiceOver:
            guard voiceOverEnabled, voiceOverRunning else { return false }
            guard !turnOverActive else { return false }
            guard voiceOverMuteKnown, !voiceOverSilent else { return false }
        }
        return true
    }
}
