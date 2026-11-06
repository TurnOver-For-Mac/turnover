// SPDX-License-Identifier: GPL-3.0-or-later
// VoiceOver's sound files at the loudness of TurnOver's own set (3 Nov 2026).
import Foundation
import AVFoundation
import TurnOverCore

func soundsTests() {
    test("VoiceOver's sounds: each file to -20 dBFS RMS, or as near as keeps its peaks under -1 dBFS") {
        expect(VoiceOverSounds.gain(rms: 0.2, peak: 0.9), 0.5, "a loud file comes down to -20 dBFS")
        expect((VoiceOverSounds.gain(rms: 0.04, peak: 0.5) * 100).rounded(), 178, "a quiet one comes up, as far as peaks of -1 dBFS")
        let url = VoiceOverSounds.folder.appendingPathComponent("LinkBegin.aiff")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = VoiceOverSounds.levelled(url), let player = try? AVAudioPlayer(data: data) else { return Harness.fail("LinkBegin.aiff: no WAV a player reads") }
        expect(Int((player.duration * 1000).rounded()), 52, "the file's length, 52 ms, kept")
        expect(player.numberOfChannels, 2, "its two channels kept")
    }
}
