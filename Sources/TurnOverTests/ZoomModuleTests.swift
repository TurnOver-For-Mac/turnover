// SPDX-License-Identifier: GPL-3.0-or-later
import AXFixtures
import Foundation
import TurnOverCore

func zoomModuleTests() {
    test("zoom: the app module owns Zoom's mute and video keys") {
        BuiltInModules.register()
        check(AppModuleHandler.shared.moduleType(for: "us.zoom.xos") == ZoomAppModule.self, "the Zoom bundle uses the Zoom module")
        let module = ZoomAppModule(pid: 0, bundleIdentifier: "us.zoom.xos", appName: "Zoom")
        expect(module.script(for: KeyboardGesture(identifier: "kb:command+shift+a")!)?.name, "zoom_toggleAudio", "mute")
        expect(module.script(for: KeyboardGesture(identifier: "kb:command+shift+v")!)?.name, "zoom_toggleVideo", "video")
    }

    test("zoom: the menu item names the next action, the state said is the present one") {
        expect(ZoomWords.audio("Unmute audio"), "muted", "the item offers unmute while muted")
        expect(ZoomWords.audio("Mute audio"), "unmuted", "the item offers mute while unmuted")
        expect(ZoomWords.video("Start video"), "video off", "the item offers start while off")
        expect(ZoomWords.video("Stop video"), "video on", "the item offers stop while on")
        check(ZoomWords.audio("Heli sisse") == nil, "words in another language are not guessed")
        check(ZoomWords.video("") == nil, "an empty title is not a state")
    }

    test("zoom: the hand and reaction keys belong to the module, and the feedback window is told by its shape") {
        let module = ZoomAppModule(pid: 0, bundleIdentifier: "us.zoom.xos", appName: "Zoom")
        expect(module.script(for: KeyboardGesture(identifier: "kb:option+y")!)?.name, "zoom_toggleHand", "the hand")
        expect(module.script(for: KeyboardGesture(identifier: "kb:option+command+4")!)?.name, "zoom_react", "the first reaction")
        expect(module.script(for: KeyboardGesture(identifier: "kb:option+command+9")!)?.name, "zoom_react", "the last reaction")
        check(module.script(for: KeyboardGesture(identifier: "kb:option+command+3")!) == nil, "another number is Zoom's")
        expect(ZoomWords.feedbackChild(windowSubrole: "AXUnknown", childRoles: ["AXButton"]), "AXButton", "the lower hand button: the hand is up")
        expect(ZoomWords.feedbackChild(windowSubrole: nil, childRoles: ["AXImage"]), "AXImage", "a reaction's picture")
        check(ZoomWords.feedbackChild(windowSubrole: "AXStandardWindow", childRoles: ["AXButton"]) == nil, "a standard window is not it")
        check(ZoomWords.feedbackChild(windowSubrole: "AXSystemDialog", childRoles: ["AXImage"]) == nil, "a dialog is not it")
        check(ZoomWords.feedbackChild(windowSubrole: "AXUnknown", childRoles: ["AXButton", "AXButton"]) == nil, "a window with more in it is not it")
        check(ZoomWords.feedbackChild(windowSubrole: "AXUnknown", childRoles: ["AXStaticText"]) == nil, "a notice is not it")
    }

    test("zoom: the active speaker is the tile Zoom marks") {
        let module = ZoomAppModule(pid: 0, bundleIdentifier: "us.zoom.xos", appName: "Zoom")
        expect(module.script(for: KeyboardGesture(identifier: "kb:command+shift+2")!)?.name, "zoom_activeSpeaker", "Zoom's key for who is speaking")
        check(module.script(for: KeyboardGesture(identifier: "kb:command+2")!) == nil, "Command 2 stays Zoom's own")
        let tiles = ["Sample One, Computer audio unmuted", "grid view",
                     "Sample Two, Computer audio muted, Video off",
                     "Sample One, Computer audio unmuted, Video on, active speaker"]
        expect(ZoomWords.activeSpeaker(in: tiles), "Sample One", "the name before the states")
        check(ZoomWords.activeSpeaker(in: Array(tiles.prefix(3))) == nil, "no marked tile, no speaker")
        check(ZoomWords.activeSpeaker(in: []) == nil, "no tiles")
    }

    test("zoom: who is speaking sends the key on to Zoom, in the meeting window and outside it") {
        let savedPoster = KeyboardGesture.poster, savedSink = Speech.sink, oldFocus = API.focusObject, oldAncestors = API.focusAncestors, oldDocument = API.focusTreeInterceptor
        let sent = Locked<[String]>([])
        var said: [String] = []
        KeyboardGesture.poster = { sent.value.append($0.identifier) }
        Speech.sink = { said.append($0) }
        API.setFocusObject(nil, ancestors: [])
        defer { KeyboardGesture.poster = savedPoster; Speech.sink = savedSink; API.setFocusObject(oldFocus, ancestors: oldAncestors, interceptor: oldDocument) }
        let key = KeyboardGesture(identifier: "kb:command+shift+2")!

        // Outside a meeting: no window answers. The key goes to Zoom and nothing is said.
        let outside = ZoomAppModule(pid: 0, bundleIdentifier: "us.zoom.xos", appName: "Zoom")
        outside.script(named: "zoom_activeSpeaker")?.handler(key)
        expect(sent.value, [key.identifier], "outside the meeting window the key goes to Zoom once")
        expect(said, [], "nothing is said")

        // In the meeting window, made up here: a tile, and the grid's tiles one level down, one marked as speaking.
        func meeting(speaking: Bool) -> AXFixture {
            AXFixture(app: "Public sample", bundle: "us.zoom.xos", recorded: "", root: 1, application: 0, focus: nil, nodes: [
                .init(id: 0, attrs: ["AXRole": .string("AXApplication"), "AXFocusedWindow": .element(1), "AXWindows": .elements([1])]),
                .init(id: 1, attrs: ["AXRole": .string("AXWindow"), "AXIdentifier": .string("zm.meeting.window.main"), "AXChildren": .elements([2, 3])]),
                .init(id: 2, attrs: ["AXRole": .string("AXTabGroup"), "AXDescription": .string("Sample Two, Computer audio muted, Video off")]),
                .init(id: 3, attrs: ["AXRole": .string("AXTabGroup"), "AXDescription": .string("grid view"), "AXChildren": .elements([4])]),
                .init(id: 4, attrs: ["AXRole": .string("AXTabGroup"), "AXDescription": .string("Sample One, Computer audio unmuted, Video on" + (speaking ? ", active speaker" : ""))]),
            ])
        }
        let inMeeting = ZoomAppModule(pid: AXReplay.floor, bundleIdentifier: "us.zoom.xos", appName: "Zoom")
        defer { AXReplay.unload() }
        for (speaking, words) in [(true, "Sample One is speaking"), (false, "No one is speaking")] {
            AXReplay.load(meeting(speaking: speaking))
            sent.value = []; said = []
            inMeeting.script(named: "zoom_activeSpeaker")?.handler(key)
            expect(sent.value, [key.identifier], "in the meeting window the key goes to Zoom once too")
            expect(said, [words], "and the speaker is said")
        }
    }
}
