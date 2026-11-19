// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

// 19 Nov 2026: each event VoiceOver plays a file for (its configuration maps event to file) asks for that file with
// VoiceOver's sounds chosen; with TurnOver's chosen nothing of VoiceOver's is asked for beyond what played before.
// Logic evidence only: the probe records the request, nothing is played.
@MainActor func voiceOverFileTests() {
    let events: [(String, String, () -> Void)] = [
        ("a search that finds nothing", "NotFound.aiff", { Tones.searchNotFound() }),
        ("a menu opening", "MenuDown.aiff", { Tones.menuOpened() }),
        ("a page finishing loading", "WebPageLoaded.aiff", { Tones.pageLoaded() }),
    ]
    test("sounds: with VoiceOver's chosen, each wired event asks for VoiceOver's own file") {
        let saved = config.general.sounds
        defer { config.general.sounds = saved; VoiceOverSounds.requestProbe = nil }
        var asked: [String] = []
        VoiceOverSounds.requestProbe = { name, _ in asked.append(name) }
        config.general.sounds = "voiceover"
        for (what, file, play) in events {
            asked = []; play()
            expect(asked, [file], "\(what) plays \(file)")
        }
        asked = []; Tones.contextMenuOpened()
        expect(asked, [], "a context menu is a menu: only MenuDown, not PopupAppeared, with VoiceOver's sounds")
    }
    test("sounds: with TurnOver's chosen, a context menu keeps its popup sound and the new events add none of their own") {
        let saved = config.general.sounds
        defer { config.general.sounds = saved; VoiceOverSounds.requestProbe = nil }
        config.general.sounds = "turnover"
        var asked: [String] = []
        VoiceOverSounds.requestProbe = { name, sounds in asked.append(name + "/" + sounds) }
        Tones.contextMenuOpened()
        expect(asked, ["PopupAppeared.aiff/turnover"], "a context menu sounds as before")
        VoiceOverSounds.requestProbe = nil
        expect(VoiceOverSounds.ownTone(for: "NotFound.aiff"), false, "TurnOver's set has no sound for a failed search")
        expect(VoiceOverSounds.ownTone(for: "MenuDown.aiff"), false, "TurnOver's set has no sound for a menu opening")
    }
}
