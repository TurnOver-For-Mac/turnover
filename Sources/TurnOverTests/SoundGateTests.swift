// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

// 19 Nov 2026: the gate sits at the lowest level (Tones.beep, the bell, TurnOverSounds.play), and a sound is never
// prepared on the thread that asks for it. Logic evidence only: probes record what would play, nothing is played.
@MainActor func soundGateTests() {
    let named: [(String, () -> Void)] = [
        ("the waiting beep (HelpImprove, NVDAStoreMenu, PluginAI)", { Tones.waitingTick() }),
        ("the marked sound (GlobalCommands)", { Tones.marked() }),
        ("the installed beep (AppStoreView)", { Tones.installed() }),
        ("a plain beep", { Tones.beep(880, 30) }),
        ("a plain bell", { Tones.bell(frequencies: [880], spacingMs: 0, ringMs: 10) }),
        ("a file of TurnOver's set", { _ = TurnOverSounds.play("marked") }),
    ]
    let exceptions: [(String, () -> Void)] = [
        ("startup", { Tones.startup() }), ("take-over", { Tones.takeOver() }), ("hand-back", { Tones.handBack() }),
        ("the progress beep", { Tones.progress(50) }),
    ]
    test("sounds: with VoiceOver's chosen, the three named callers and every ungated primitive request nothing") {
        let saved = config.general.sounds
        defer { config.general.sounds = saved; Tones.outputProbe = nil }
        var heard: [String] = []
        Tones.outputProbe = { heard.append($0) }
        config.general.sounds = "voiceover"
        for (what, play) in named { heard = []; play(); expect(heard, [], "\(what) is silent") }
    }
    test("sounds: the four exceptions and the stand-in fallbacks play in both sets") {
        let saved = config.general.sounds
        defer { config.general.sounds = saved; Tones.outputProbe = nil }
        var heard: [String] = []
        Tones.outputProbe = { heard.append($0) }
        for set in ["voiceover", "turnover"] {
            config.general.sounds = set
            for (what, play) in exceptions { heard = []; play(); expect(heard.isEmpty, false, "\(what) plays with \(set)") }
            heard = []; Tones.beep(880, 30, exempt: true); expect(heard.isEmpty, false, "an exempt beep plays with \(set)")
            heard = []; Tones.bell(frequencies: [880], spacingMs: 0, ringMs: 10, exempt: true); expect(heard.isEmpty, false, "an exempt bell plays with \(set)")
            heard = []; _ = TurnOverSounds.play("marked", exempt: true); expect(heard.isEmpty, false, "an exempt file plays with \(set)")
        }
    }
    test("sounds: with TurnOver's chosen, the gated sounds play as before") {
        let saved = config.general.sounds
        defer { config.general.sounds = saved; Tones.outputProbe = nil }
        var heard: [String] = []
        Tones.outputProbe = { heard.append($0) }
        config.general.sounds = "turnover"
        for (what, play) in named { heard = []; play(); expect(heard.isEmpty, false, "\(what) plays") }
    }
    test("sounds: a first request for an unprepared file returns without preparing on the calling thread") {
        let saved = config.general.sounds
        defer { config.general.sounds = saved; VoiceOverSounds.cache.setHold(nil) }
        config.general.sounds = "voiceover"
        let hold = DispatchSemaphore(value: 0)
        VoiceOverSounds.cache.setHold(hold)   // preparation waits here, so the request must return first
        let name = "NotFound.aiff"
        expect(VoiceOverSounds.cache.player(name) == nil, true, "not prepared before the request")
        expect(VoiceOverSounds.play(name), true, "the request returns at once")
        expect(VoiceOverSounds.cache.player(name) == nil, true, "nothing was prepared on this thread")
        hold.signal()
        let until = Date().addingTimeInterval(5)
        while VoiceOverSounds.cache.player(name) == nil, !VoiceOverSounds.cache.hasFailed(name), Date() < until { Thread.sleep(forTimeInterval: 0.01) }
        expect(VoiceOverSounds.cache.player(name) != nil || VoiceOverSounds.cache.hasFailed(name), true, "it was prepared in the background")
    }
}
