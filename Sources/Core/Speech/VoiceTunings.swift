// SPDX-License-Identifier: GPL-3.0-or-later
// Changing voice, from Settings' Voice list or the speech settings ring: each voice keeps its own rate, volume and EQ
// (Config.Speech.voiceTunings), a natural voice as a Mac one (Oliver, 2 Nov 2026: "it should be all the same settings
// wherever the voice comes from"; "rate, volume, and the eq should be specific to each voice").
import Foundation

enum VoiceTunings {
    /// `id`: a Mac voice's identifier, or "external:" and a natural voice.
    static func switchTo(_ id: String) {
        config.speech.switchTuning(from: KokoroVoice.speechVoiceID, to: id)
        KokoroVoice.choose(id)
        Speech.player.rate = config.speech.rate
        Speech.player.volume = Float(config.speech.volume) / 100
        Speech.player.eq = config.speech.eq
        config.save()
    }
}
