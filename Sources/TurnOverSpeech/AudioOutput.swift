// SPDX-License-Identifier: GPL-3.0-or-later
// One switch for every place TurnOver starts audio (19 Nov 2026): the test binary sets it first thing, so no sound file,
// tone, bell, system alert or spoken warning ever reaches the speakers while tests run (they were heard at random while
// helpers built). Each playback point skips only the playing: the same result is returned and the same line is logged,
// so tests of sound decisions still work. The app never sets it.
import Foundation

package enum AudioOutput {
    /// True only in the test binary (Sources/TurnOverTests/main.swift).
    nonisolated(unsafe) package static var muted = false
}
