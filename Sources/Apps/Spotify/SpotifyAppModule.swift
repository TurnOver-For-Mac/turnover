// SPDX-License-Identifier: GPL-3.0-or-later
// Spotify (#226): announce playback shortcuts in focus mode. Browse mode and text fields keep their keys.
import AppKit
import Foundation

package final class SpotifyAppModule: AppModule {
    package static let bundleID = "com.spotify.client"

    package required init(pid: pid_t, bundleIdentifier: String, appName: String) {
        super.init(pid: pid, bundleIdentifier: bundleIdentifier, appName: appName)
        script("spotify_volumeUp", String(localized: "Sends Spotify's volume up shortcut and says louder", comment: "A command, as the key list and keyboard help say it"),
               gestures: ["kb:command+upArrow"], category: "Spotify") { gesture in
            Self.sendShortcut(gesture, to: pid, cue: String(localized: "louder", comment: "Spotify volume up shortcut"))
        }.isAvailable = Self.playbackShortcutIsAvailable
        script("spotify_volumeDown", String(localized: "Sends Spotify's volume down shortcut and says quieter", comment: "A command, as the key list and keyboard help say it"),
               gestures: ["kb:command+downArrow"], category: "Spotify") { gesture in
            Self.sendShortcut(gesture, to: pid, cue: String(localized: "quieter", comment: "Spotify volume down shortcut"))
        }.isAvailable = Self.playbackShortcutIsAvailable
        script("spotify_previousTrack", String(localized: "Sends Spotify's previous track shortcut and says previous track", comment: "A command, as the key list and keyboard help say it"),
               gestures: ["kb:command+leftArrow"], category: "Spotify") { gesture in
            Self.sendShortcut(gesture, to: pid, cue: String(localized: "previous track", comment: "Spotify previous track shortcut"))
        }.isAvailable = Self.playbackShortcutIsAvailable
        script("spotify_nextTrack", String(localized: "Sends Spotify's next track shortcut and says next track", comment: "A command, as the key list and keyboard help say it"),
               gestures: ["kb:command+rightArrow"], category: "Spotify") { gesture in
            Self.sendShortcut(gesture, to: pid, cue: String(localized: "next track", comment: "Spotify next track shortcut"))
        }.isAvailable = Self.playbackShortcutIsAvailable
    }

    private static func playbackShortcutIsAvailable() -> Bool {
        guard API.focusTreeInterceptor?.passThrough != false else { return false }
        guard let focus = API.focusObject else { return true }
        // Spotify's search is an editable AXComboBox, which can have a caret without the editable state.
        return focus.role != .comboBox && !(focus is EditableText) && !focus.states.contains(.editable)
    }

    private static func sendShortcut(_ gesture: KeyboardGesture, to pid: pid_t, cue: String) {
        gesture.send()
        guard Core.active, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
        Speech.speakMessage(cue)
    }
}
