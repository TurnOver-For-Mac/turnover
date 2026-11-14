// SPDX-License-Identifier: GPL-3.0-or-later
// 14 Nov 2026: a mode announcement waits for speech readiness, independently of reader ownership.

nonisolated public enum ModeSpeechPolicy {
    public enum Reader { case turnOver, voiceOver }

    public static func canAnnounce(reader: Reader, generation: Int, currentGeneration: Int,
                                   coexisting: Bool, turnOverActive: Bool,
                                   voiceOverEnabled: Bool, voiceOverSilent: Bool) -> Bool {
        guard generation == currentGeneration else { return false }
        switch reader {
        case .turnOver:
            guard turnOverActive else { return false }
            guard !voiceOverEnabled || coexisting else { return false }
            guard !coexisting || !voiceOverEnabled || voiceOverSilent else { return false }
        case .voiceOver:
            guard voiceOverEnabled else { return false }
            guard !turnOverActive else { return false }
            guard !coexisting || !voiceOverSilent else { return false }
        }
        return true
    }
}
