// SPDX-License-Identifier: GPL-3.0-or-later
// Spotify (#226): browse mode can take playback keys. Send each shortcut and announce the command.
import AppKit
import Foundation

package final class SpotifyAppModule: AppModule {
    package static let bundleID = "com.spotify.client"

    package required init(pid: pid_t, bundleIdentifier: String, appName: String) {
        super.init(pid: pid, bundleIdentifier: bundleIdentifier, appName: appName)
        script("spotify_volumeUp", String(localized: "Sends Spotify's volume up shortcut and says louder", comment: "Spotify keyboard help"),
               gestures: ["kb:command+upArrow"], category: "Spotify") { [weak self] gesture in
            self?.sendShortcut(gesture, cue: String(localized: "louder", comment: "Spotify volume up shortcut"))
        }
        script("spotify_volumeDown", String(localized: "Sends Spotify's volume down shortcut and says quieter", comment: "Spotify keyboard help"),
               gestures: ["kb:command+downArrow"], category: "Spotify") { [weak self] gesture in
            self?.sendShortcut(gesture, cue: String(localized: "quieter", comment: "Spotify volume down shortcut"))
        }
        script("spotify_previousTrack", String(localized: "Sends Spotify's previous track shortcut and says previous", comment: "Spotify keyboard help"),
               gestures: ["kb:command+leftArrow"], category: "Spotify") { [weak self] gesture in
            self?.sendShortcut(gesture, cue: String(localized: "previous", comment: "Spotify previous track shortcut"))
        }
        script("spotify_nextTrack", String(localized: "Sends Spotify's next track shortcut and says next", comment: "Spotify keyboard help"),
               gestures: ["kb:command+rightArrow"], category: "Spotify") { [weak self] gesture in
            self?.sendShortcut(gesture, cue: String(localized: "next", comment: "Spotify next track shortcut"))
        }
    }

    private func sendShortcut(_ gesture: KeyboardGesture, cue: String) {
        guard Core.active, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
        gesture.send()
        Speech.speakMessage(cue)
    }
}
