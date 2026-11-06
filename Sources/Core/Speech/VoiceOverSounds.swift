// SPDX-License-Identifier: GPL-3.0-or-later
// VoiceOver's own sound effects, played by TurnOver for the events VoiceOver marks with a sound (17 Oct 2026:
// "TurnOver should be using all the VoiceOver sounds for headings, spelling mistakes, links, based on the archive").
// The files are VoiceOver's (ScreenReader.framework's Sounds); which events get a sound follows VoiceOver's own list of
// them, its Sounds Help menu (links: sound or words; misspelled words: a tone at changes). Headings, lists, tables and
// graphics have no sound in VoiceOver: it says them, and so does TurnOver, with its own set's sounds (Tones).
import Foundation
import AVFoundation

@MainActor
public enum VoiceOverSounds {
    nonisolated package static let folder = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/ScreenReader.framework/Versions/A/Resources/Sounds")
    private static var players: [String: AVAudioPlayer] = [:]
    public static var available: Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent("LinkBegin.aiff").path) }

    /// Plays one of VoiceOver's sounds by file name ("LinkBegin.aiff"), or TurnOver's own for it with TurnOver's set
    /// chosen or the file missing; false where there is neither, so the caller's old tone plays.
    @discardableResult
    public static func play(_ name: String, volume: Float = 0.8) -> Bool {
        // "TurnOver's sounds" chosen (17 Oct 2026): TurnOver's own sound stands in for each of VoiceOver's files.
        if config.general.effectiveSounds == "turnover" { return ownTone(for: name) }
        if players[name] == nil, let data = levelled(folder.appendingPathComponent(name)), let p = try? AVAudioPlayer(data: data) {
            p.prepareToPlay()
            players[name] = p
        }
        guard let p = players[name] else { return ownTone(for: name) }
        p.volume = volume * min(1.5, max(0.2, Float(config.speech.volume) / 100))   // with TurnOver's own volume
        p.currentTime = 0
        p.play()
        return true
    }

    /// The file's samples at the loudness of TurnOver's own set, as a 16-bit WAV in memory. VoiceOver's files are
    /// quieter than the set, by 5 to 10 dB and unevenly (LinkBegin -28 dBFS RMS, EmptySpace -32, against the set's
    /// -15 to -24; measured 3 Nov 2026, "they don't sound quite right"), and a player's volume can't go above 1, so
    /// each is brought to about -20 dBFS RMS once, its peaks kept under -1 dBFS.
    nonisolated package static func levelled(_ url: URL) -> Data? {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true), file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let samples = buffer.floatChannelData?[0] else { return nil }
        let channels = Int(file.processingFormat.channelCount), count = Int(buffer.frameLength) * channels
        var peak: Float = 0, sum: Float = 0
        for i in 0..<count { peak = max(peak, abs(samples[i])); sum += samples[i] * samples[i] }
        guard count > 0, peak > 0 else { return nil }
        let g = gain(rms: (sum / Float(count)).squareRoot(), peak: peak)
        let pcm = (0..<count).map { Int16(max(-32768, min(32767, (samples[$0] * g * 32767).rounded()))).littleEndian }
        var wav = Data(capacity: 44 + count * 2)
        func tag(_ s: String) { wav.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { wav.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { wav.append(contentsOf: $0) } }
        let rate = Int(file.processingFormat.sampleRate)
        tag("RIFF"); u32(36 + count * 2); tag("WAVE")
        tag("fmt "); u32(16); u16(1); u16(channels); u32(rate); u32(rate * channels * 2); u16(channels * 2); u16(16)
        tag("data"); u32(count * 2)
        pcm.withUnsafeBytes { wav.append(contentsOf: $0) }
        return wav
    }
    /// The factor that brings a file to -20 dBFS RMS, or as near as keeps its peaks under -1 dBFS.
    nonisolated package static func gain(rms: Float, peak: Float) -> Float { min(0.1 / rms, 0.89 / peak) }

    /// TurnOver's sound for one of VoiceOver's sound names (the sounds setting "TurnOver's", or the file missing); false
    /// where TurnOver has none, so the caller's own fallback plays.
    static func ownTone(for asked: String) -> Bool {
        guard Tones.own else { return false }   // coexisting, VoiceOver's own stand in for a file that is missing
        // By the sound's name, whatever its file's ending: VoiceOver's Quick Nav sounds are .wav, and asked for as such
        // they matched nothing here, so Quick Nav said its words instead of TurnOver's sound (19 Oct 2026).
        let name = (asked as NSString).deletingPathExtension + ".aiff"
        // TurnOver's own set first (make-sounds.py); the old tones below if a file is missing.
        let fresh: [String: String] = [
            "WrapBoundary.aiff": "edge", "DrillIn.aiff": "drill_in", "DrillOut.aiff": "drill_out",
            "QuickNavOn.aiff": "quicknav_on", "QuickNavArrowKeyOn.aiff": "quicknav_on", "QuickNavOff.aiff": "quicknav_off", "QuickNavArrowKeyOff.aiff": "quicknav_off",
            "TrackingOn.aiff": "tracking_on", "TrackingOff.aiff": "tracking_off", "PopupAppeared.aiff": "popup", "WebAreaLoaded.aiff": "page_loaded",
            "EmptySpace.aiff": "empty", "Announcement.aiff": "announcement", "SecureCharacter.aiff": "secure",
            "LinkBegin.aiff": "link", "Misspelled.aiff": "spelling", "BrailleDisplayConnected.aiff": "braille_on", "BrailleDisplayDisconnected.aiff": "braille_off",
        ]
        if let f = fresh[name], TurnOverSounds.play(f) { return true }
        switch name {
        case "WrapBoundary.aiff": Tones.beep(220, 70); return true
        case "DrillIn.aiff": Tones.beep(660, 30); return true
        case "DrillOut.aiff": Tones.beep(440, 30); return true
        case "QuickNavOn.aiff", "QuickNavArrowKeyOn.aiff", "TrackingOn.aiff": Tones.beep(660, 40); DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { Tones.beep(880, 50) }; return true
        case "QuickNavOff.aiff", "QuickNavArrowKeyOff.aiff", "TrackingOff.aiff": Tones.beep(880, 40); DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { Tones.beep(660, 50) }; return true
        case "PopupAppeared.aiff": Tones.beep(520, 40); return true
        case "WebAreaLoaded.aiff": Tones.beep(700, 50); return true
        case "EmptySpace.aiff": Tones.beep(300, 40); return true
        case "Announcement.aiff": Tones.beep(800, 40); return true
        case "SecureCharacter.aiff": Tones.beep(1000, 20, volume: 0.15); return true
        default: return false   // LinkBegin, Misspelled, the braille display: Tones has its own
        }
    }
}
