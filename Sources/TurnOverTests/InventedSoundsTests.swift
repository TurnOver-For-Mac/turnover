// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

// (press is not here: with VoiceOver's sounds it plays VoiceOver's Select file, see voiceOverFileTests.)
// 19 Nov 2026, SHORTCOMINGS rule 10: with VoiceOver's sounds chosen, TurnOver's invented tones are silent.
@MainActor func inventedSoundsTests() {
    let all: [(String, () -> Void)] = [
        ("heading", { Tones.heading(level: 2) }), ("list", { Tones.list() }), ("landmark", { Tones.landmark() }),
        ("table", { Tones.table() }), ("graphic", { Tones.graphic() }), ("blockquote", { Tones.blockQuote() }),
        ("focus_mode", { Tones.focusMode() }), ("browse_mode", { Tones.browseMode() }), ("comment", { Tones.comment() }),
        ("focus_tick", { Tones.focusTick() }),
        ("keystroke_beep", { _ = Tones.invented("keystroke_beep") }), ("jump", { _ = Tones.invented("jump") }),
        ("say_tone", { _ = Tones.invented("say_tone") }), ("waiting_tick", { _ = Tones.invented("waiting_tick") }),
    ]
    test("sounds: with VoiceOver's sounds chosen every invented tone is silent, and with TurnOver's each plays") {
        let saved = config.general.sounds, savedNav = config.general.navigationSounds
        defer { config.general.sounds = saved; config.general.navigationSounds = savedNav; Tones.inventedProbe = nil }
        config.general.navigationSounds = true
        var heard: [String] = []
        Tones.inventedProbe = { heard.append($0) }
        config.general.sounds = "voiceover"
        for (_, play) in all { play() }
        expect(heard, [], "VoiceOver has no sound for these, so none plays")
        config.general.sounds = "turnover"
        for (name, play) in all {
            heard = []; play()
            expect(heard.contains(name), true, "\(name) plays with TurnOver's sounds")
        }
    }
}
