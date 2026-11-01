// SPDX-License-Identifier: GPL-3.0-or-later
// VoiceOver's own sound effects, played by TurnOver for the events VoiceOver marks with a sound (17 Oct 2026:
// "TurnOver should be using all the VoiceOver sounds for headings, spelling mistakes, links, based on the archive").
// The files are VoiceOver's (ScreenReader.framework's Sounds); which events get a sound follows the settings copied
// from VoiceOver's export (links: sound or words; misspelled words: a tone at changes). Headings, lists, tables and
// graphics have no sound in VoiceOver: it says them, and so does TurnOver.
import Foundation
import AVFoundation

@MainActor
public enum VoiceOverSounds {
    static let folder = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/ScreenReader.framework/Versions/A/Resources/Sounds")
    private static var players: [String: AVAudioPlayer] = [:]
    public static var available: Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent("LinkBegin.aiff").path) }

    /// Plays one of VoiceOver's sounds by file name ("LinkBegin.aiff"); false if the file isn't there.
    @discardableResult
    public static func play(_ name: String, volume: Float = 0.7) -> Bool {
        // "TurnOver's sounds" chosen (17 Oct 2026): TurnOver's own tone stands in for each of VoiceOver's files.
        if config.general.effectiveSounds == "turnover" { return ownTone(for: name) }
        let url = folder.appendingPathComponent(name)
        if players[name] == nil {
            guard let p = try? AVAudioPlayer(contentsOf: url) else { return false }
            p.prepareToPlay()
            players[name] = p
        }
        guard let p = players[name] else { return false }
        p.volume = volume * min(1.5, max(0.2, Float(config.speech.volume) / 100))   // with TurnOver's own volume
        p.currentTime = 0
        p.play()
        return true
    }

    /// TurnOver's tone for one of VoiceOver's sound names (the sounds setting "TurnOver's"); false where TurnOver
    /// has none, so the caller's own fallback plays.
    static func ownTone(for asked: String) -> Bool {
        // By the sound's name, whatever its file's ending: VoiceOver's Quick Nav sounds are .wav, and asked for as such
        // they matched nothing here, so Quick Nav said its words instead of TurnOver's sound (19 Oct 2026).
        let name = (asked as NSString).deletingPathExtension + ".aiff"
        // TurnOver's own set first (make-sounds.py); the old tones below if a file is missing.
        let fresh: [String: String] = [
            "WrapBoundary.aiff": "edge", "DrillIn.aiff": "drill_in", "DrillOut.aiff": "drill_out",
            "QuickNavOn.aiff": "quicknav_on", "QuickNavArrowKeyOn.aiff": "quicknav_on", "QuickNavOff.aiff": "quicknav_off", "QuickNavArrowKeyOff.aiff": "quicknav_off",
            "TrackingOn.aiff": "tracking_on", "TrackingOff.aiff": "tracking_off", "PopupAppeared.aiff": "popup", "WebPageLoaded.aiff": "page_loaded",
            "EmptySpace.aiff": "empty", "Announcement.aiff": "announcement", "SecureCharacter.aiff": "secure",
            "LinkBegin.aiff": "link", "Misspelled.aiff": "spelling",
        ]
        if let f = fresh[name], TurnOverSounds.play(f) { return true }
        switch name {
        case "WrapBoundary.aiff": Tones.beep(220, 70); return true
        case "DrillIn.aiff": Tones.beep(660, 30); return true
        case "DrillOut.aiff": Tones.beep(440, 30); return true
        case "QuickNavOn.aiff", "QuickNavArrowKeyOn.aiff", "TrackingOn.aiff": Tones.beep(660, 40); DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { Tones.beep(880, 50) }; return true
        case "QuickNavOff.aiff", "QuickNavArrowKeyOff.aiff", "TrackingOff.aiff": Tones.beep(880, 40); DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { Tones.beep(660, 50) }; return true
        case "PopupAppeared.aiff": Tones.beep(520, 40); return true
        case "WebPageLoaded.aiff": Tones.beep(700, 50); return true
        case "EmptySpace.aiff": Tones.beep(300, 40); return true
        case "Announcement.aiff": Tones.beep(800, 40); return true
        case "SecureCharacter.aiff": Tones.beep(1000, 20, volume: 0.15); return true
        default: return false   // LinkBegin, Misspelled: Tones.link and Tones.spellingError have their own
        }
    }
}
