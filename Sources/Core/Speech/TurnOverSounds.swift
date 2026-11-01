// SPDX-License-Identifier: GPL-3.0-or-later
// TurnOver's own sound set (17 Oct 2026: "a more interesting sound set for TurnOver, something fresher"):
// files made by make-sounds.py (plucked, glassy and wooden notes, glides, a small room), in Resources/Sounds. Played
// when the sounds setting is TurnOver's (Experimental), and where VoiceOver has no sound of its own. The old
// synthesised tones (Tones.beep, playBell) stay as the fallback when a file is missing.
import Foundation
import AVFoundation

@MainActor
public enum TurnOverSounds {
    static var folder: URL? { Bundle.main.resourceURL?.appendingPathComponent("Sounds") }
    private static var players: [String: AVAudioPlayer] = [:]
    /// The names in the bundle, read once (the keyboard thread may ask whether one exists).
    nonisolated static let names: Set<String> = {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Sounds"),
              let list = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return Set(list.filter { $0.hasSuffix(".wav") }.map { String($0.dropLast(4)) })
    }()

    /// Plays one of TurnOver's sounds by name ("link"); false if there is no such file.
    @discardableResult
    public static func play(_ name: String, volume: Float = 0.8) -> Bool {
        guard names.contains(name), let folder else { return false }
        if players[name] == nil {
            guard let p = try? AVAudioPlayer(contentsOf: folder.appendingPathComponent(name + ".wav")) else { return false }
            p.prepareToPlay()
            players[name] = p
        }
        guard let p = players[name] else { return false }
        p.volume = volume * min(1.5, max(0.2, Float(config.speech.volume) / 100))   // with TurnOver's own volume
        p.currentTime = 0
        p.play()
        return true
    }
}
