// SPDX-License-Identifier: GPL-3.0-or-later
// TurnOver's own sound set (17 Oct 2026: "a more interesting sound set for TurnOver, something fresher"):
// files made by make-sounds.py (plucked, glassy and wooden notes, glides, a small room), in Resources/Sounds. Played
// where TurnOver's own may play (Tones.own). The old synthesised tones (Tones.beep, playBell) stay as the fallback when
// a file is missing.
import Foundation
import AVFoundation
import TurnOverSpeech

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

    private static var lastPlayed: [String: Date] = [:]
    /// A sound asked for again within a tenth of a second of the last time: logged, at most once a second.
    private static var repeatLoggedAt = Date.distantPast
    private static func noteRepeat(_ name: String) {
        let now = Date()
        if let last = lastPlayed[name], now.timeIntervalSince(last) < 0.1, now.timeIntervalSince(repeatLoggedAt) > 1 {
            repeatLoggedAt = now
            Log.io("sound: \(name) played again \(Int(now.timeIntervalSince(last) * 1000)) ms after the last")
        }
        lastPlayed[name] = now
    }

    /// Plays one of TurnOver's sounds by name ("link"); false if there is no such file.
    @discardableResult
    public static func play(_ name: String, volume: Float = 0.8, why: String = #function) -> Bool {
        guard names.contains(name), let folder else { return false }
        if players[name] == nil {
            guard let p = try? AVAudioPlayer(contentsOf: folder.appendingPathComponent(name + ".wav")) else { return false }
            p.prepareToPlay()
            players[name] = p
        }
        guard let p = players[name] else { return false }
        p.volume = volume * min(1.5, max(0.2, Float(config.speech.volume) / 100))   // with TurnOver's own volume
        p.currentTime = 0
        let started = Date()
        SoundLog.played(name, why: why)
        if !AudioOutput.muted { p.play() }   // tests are silent (AudioOutput)
        // Oliver, 14 Nov 2026: on MacRumors "the link sound hangs". Sounds were not logged, so the log could not say
        // how. One that is slow to start, or played again before it ended, is logged now.
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if ms >= 50 { Log.io("sound: \(name) took \(ms) ms to start") }
        noteRepeat(name)
        return true
    }
}

/// One log line for every sound actually played, so a sound Oliver cannot account for can be found (19 Nov 2026):
/// "sound: <name> (why: <caller>)". A play can be asked for on the keyboard tap thread (Tones.beep): the line is then
/// handed to the main thread, never written there.
public enum SoundLog {
    nonisolated package static func line(_ name: String, why: String) -> String { "sound: \(name) (why: \(why))" }
    nonisolated public static func played(_ name: String, why: String) {
        let line = line(name, why: why)
        if Thread.isMainThread { Log.io(line) } else { DispatchQueue.main.async { Log.io(line) } }
    }
}
