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
        ("an item activated", "Select.aiff", { Tones.press() }),
        ("a mouse click", "SingleClick.aiff", { Tones.mouseClick() }),
        ("the rotor to its previous setting", "RotorLeft.aiff", { Tones.rotorMoved(forward: false) }),
        ("the rotor to its next setting", "RotorRight.aiff", { Tones.rotorMoved(forward: true) }),
        ("a search wrapping forward", "WrapForward.aiff", { Tones.searchWrapped(forward: true) }),
        ("a window coming to the front", "WindowActivated.aiff", { Tones.windowActivated() }),
        ("a dialog appearing", "Alert.aiff", { Tones.dialogAppeared() }),
        ("a search wrapping backward", "WrapBack.aiff", { Tones.searchWrapped(forward: false) }),
    ]
    test("sounds: with VoiceOver's chosen, each wired event asks for VoiceOver's own file") {
        let saved = config.general.sounds, savedNav = config.general.navigationSounds
        defer { config.general.sounds = saved; config.general.navigationSounds = savedNav; VoiceOverSounds.requestProbe = nil }
        config.general.navigationSounds = true
        var asked: [String] = []
        VoiceOverSounds.requestProbe = { name, _ in asked.append(name) }
        config.general.sounds = "voiceover"
        for (what, file, play) in events {
            asked = []; play()
            expect(asked, [file], "\(what) plays \(file)")
        }
        asked = []; Tones.contextMenuOpened()
        expect(asked, [], "a context menu is a menu: only MenuDown, not PopupAppeared, with VoiceOver's sounds")
        asked = []; Tones.selectionAdded()
        expect(asked, [], "text added to a selection asks for none of VoiceOver's files: DragShort was wrong by ear")
    }
    test("sounds: with TurnOver's chosen, a context menu keeps its popup sound and the new events add none of their own") {
        let saved = config.general.sounds
        defer { config.general.sounds = saved; VoiceOverSounds.requestProbe = nil }
        config.general.sounds = "turnover"
        var asked: [String] = []
        VoiceOverSounds.requestProbe = { name, sounds in asked.append(name + "/" + sounds) }
        Tones.contextMenuOpened()
        expect(asked, ["PopupAppeared.aiff/turnover"], "a context menu sounds as before")
        asked = []
        Tones.rotorMoved(forward: true); Tones.rotorMoved(forward: false); Tones.mouseClick(); Tones.searchWrapped(forward: true); Tones.windowActivated(); Tones.dialogAppeared(); Tones.selectionAdded()
        expect(asked.filter { $0.hasPrefix("Rotor") || $0.hasPrefix("SingleClick") || $0.hasPrefix("WrapForward") || $0.hasPrefix("Window") || $0.hasPrefix("Alert") || $0.hasPrefix("DragShort") }, [], "TurnOver's set asks for none of VoiceOver's rotor, click or wrap files")
        var heard: [String] = []
        Tones.inventedProbe = { heard.append($0) }
        defer { Tones.inventedProbe = nil }
        let savedNav = config.general.navigationSounds
        config.general.navigationSounds = true
        asked = []; Tones.press()
        config.general.navigationSounds = savedNav
        expect(heard, ["press"], "TurnOver's own press click plays as before")
        expect(asked, [], "and asks for no Select file")
        VoiceOverSounds.requestProbe = nil
        expect(VoiceOverSounds.ownTone(for: "NotFound.aiff"), false, "TurnOver's set has no sound for a failed search")
        expect(VoiceOverSounds.ownTone(for: "MenuDown.aiff"), false, "TurnOver's set has no sound for a menu opening")
    }
}
