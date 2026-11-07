// SPDX-License-Identifier: GPL-3.0-or-later
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
}
