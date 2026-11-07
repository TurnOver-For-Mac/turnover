// SPDX-License-Identifier: GPL-3.0-or-later
import AXFixtures
import TurnOverCore

func spotifyModuleTests() {
    test("spotify: the app module owns the four playback shortcuts") {
        BuiltInModules.register()
        let type = AppModuleHandler.shared.moduleType(for: "com.spotify.client")
        check(type == SpotifyAppModule.self, "the Spotify bundle uses the Spotify module")
        let module = SpotifyAppModule(pid: 0, bundleIdentifier: "com.spotify.client", appName: "Spotify")
        expect(module.script(for: KeyboardGesture(identifier: "kb:command+upArrow")!)?.name, "spotify_volumeUp", "volume up")
        expect(module.script(for: KeyboardGesture(identifier: "kb:command+downArrow")!)?.name, "spotify_volumeDown", "volume down")
        expect(module.script(for: KeyboardGesture(identifier: "kb:command+leftArrow")!)?.name, "spotify_previousTrack", "previous track")
        expect(module.script(for: KeyboardGesture(identifier: "kb:command+rightArrow")!)?.name, "spotify_nextTrack", "next track")
    }

    test("spotify: the search combo box keeps normal caret commands") {
        guard AXReplay.isAvailable else { return }
        let oldFocus = API.focusObject, oldAncestors = API.focusAncestors, oldDocument = API.focusTreeInterceptor
        AXReplay.load(.init(app: "Spotify", bundle: "com.spotify.client", recorded: "synthetic search combo box", root: 1,
                            application: nil, focus: 1, nodes: [
            .init(id: 1, attrs: ["AXRole": .string("AXComboBox"), "AXValue": .string("Music"),
                                "AXSelectedTextRange": .range(5, 0)]),
        ]))
        defer {
            API.setFocusObject(oldFocus, ancestors: oldAncestors, interceptor: oldDocument)
            AXReplay.unload()
        }
        let field = ObjectFactory.make(AXReplay.element(1))
        check(field is EditableComboBox, "the recorded role and caret create an editable combo box")
        API.setFocusObject(field, ancestors: [])
        let module = SpotifyAppModule(pid: field.pid, bundleIdentifier: "com.spotify.client", appName: "Spotify")
        for arrow in ["leftArrow", "rightArrow", "upArrow", "downArrow"] {
            let key = KeyboardGesture(identifier: "kb:command+\(arrow)")!
            check(module.script(for: key) == nil, "Spotify leaves \(arrow) to the search field")
            let caret = arrow == "leftArrow" || arrow == "rightArrow" ? "caret_moveByCharacter" : "caret_moveByLine"
            expect(field.script(for: key)?.name, caret, "ordinary caret command")
        }
    }

    test("spotify: the keyboard resolves document navigation in browse mode and playback in focus mode") {
        guard AXReplay.isAvailable else { return }
        let oldFocus = API.focusObject, oldAncestors = API.focusAncestors, oldDocument = API.focusTreeInterceptor
        AXReplay.load(.init(app: "Spotify", bundle: "com.spotify.client", recorded: "synthetic playback area", root: 1,
                            application: nil, focus: 2, nodes: [
            .init(id: 1, attrs: ["AXRole": .string("AXWebArea"), "AXChildren": .elements([2])]),
            .init(id: 2, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("Play"), "AXParent": .element(1)]),
        ]))
        let focus = ObjectFactory.make(AXReplay.element(2))
        let document = BrowseModeHandler.shared.document(root: AXReplay.element(1))
        let moduleID = "pid.\(focus.pid)"
        let previousType = AppModuleHandler.shared.moduleType(for: moduleID)
        AppModuleHandler.shared.register(SpotifyAppModule.self, for: moduleID)
        defer {
            if let previousType { AppModuleHandler.shared.register(previousType, for: moduleID) }
            else { AppModuleHandler.shared.unregister(bundleIdentifier: moduleID) }
            API.setFocusObject(oldFocus, ancestors: oldAncestors, interceptor: oldDocument)
            BrowseModeHandler.shared.forget(pid: document.webArea.pid)
            AXReplay.unload()
        }
        API.setFocusObject(focus, ancestors: [], interceptor: document)
        let bindings = [
            ("upArrow", "topOfDocument", "spotify_volumeUp"),
            ("downArrow", "bottomOfDocument", "spotify_volumeDown"),
            ("leftArrow", "startOfLine", "spotify_previousTrack"),
            ("rightArrow", "endOfLine", "spotify_nextTrack"),
        ]
        for (arrow, browse, playback) in bindings {
            let key = KeyboardGesture(identifier: "kb:command+\(arrow)")!
            document.passThrough = false
            expect(ScriptHandler.findScript(for: key, styleTable: false)?.name, browse, "browse mode")
            document.passThrough = true
            expect(ScriptHandler.findScript(for: key, styleTable: false)?.name, playback, "focus mode")
        }
    }

    test("spotify: a resolved shortcut still goes through without an active Spotify reader") {
        let savedPoster = KeyboardGesture.poster, savedSink = Speech.sink
        let sent = Locked<[String]>([])
        var said: [String] = []
        KeyboardGesture.poster = { sent.value.append($0.identifier) }
        Speech.sink = { said.append($0) }
        defer { KeyboardGesture.poster = savedPoster; Speech.sink = savedSink }
        let module = SpotifyAppModule(pid: 0, bundleIdentifier: "com.spotify.client", appName: "Spotify")
        let key = KeyboardGesture(identifier: "kb:command+rightArrow")!
        module.script(named: "spotify_nextTrack")?.handler(key)
        expect(sent.value, [key.identifier], "the original shortcut is sent exactly once")
        expect(said, [], "speech is skipped")
    }
}
