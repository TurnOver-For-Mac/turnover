// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore
import TurnOverSpeech

/// The test binary never sends audio to the speakers (19 Nov 2026): the switch every playback point honours is on.
func audioMuteTests() {
    test("audio: the test binary is muted, so no sound, tone, bell or spoken warning reaches the speakers") {
        check(AudioOutput.muted, "AudioOutput.muted is set first thing in main.swift")
        // A sound decision still returns what it would have: only the playing is skipped.
        check(RecoveryWarning().say(""), "the spoken warning reports it started, without starting the system voice")
    }
}
