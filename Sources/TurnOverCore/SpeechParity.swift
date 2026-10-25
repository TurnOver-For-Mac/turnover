// SPDX-License-Identifier: GPL-3.0-or-later
// PARKED (20 Oct 2026): off (`on` below is false). Following VoiceOver's rate, volume and pitch was not reliable; the
// code is kept for a better attempt, and nothing calls it while `on` is false. docs/DECISIONS.md lists what is parked.
// One setting, two readers (reference/keyboard-styles/settings-parity.md; 19 Oct 2026: "that lack of parity I
// want to avoid"). Rate, volume and pitch are changed in VoiceOver first, with its own commands through AppleScript,
// and TurnOver takes the value VoiceOver reports, so the two never drift apart, whichever style's key was pressed and
// whichever reader has the app in front. VoiceOver keeps the value; TurnOver follows it.
//
// Measured on 19 Oct 2026 (probe): `perform command "increase rate"` moved VoiceOver's rate 70% → 75%
// and `last phrase` said "75%"; volume 95% → 100%, pitch 50% → 55%. TurnOver's own scales are the same numbers (rate
// 0.7 = 70%, pitch 0.5 = 50%, step 0.05), so VoiceOver's percentage is TurnOver's value. It needs VoiceOver Utility's
// "Allow VoiceOver to be controlled with AppleScript"; without it TurnOver changes its own and says so, once.
import Foundation
import AppKit

public enum SpeechParity {
    static let paired: Set<String> = ["rate", "volume", "pitch"]
    private static let queue = DispatchQueue(label: "turnover.speechparity")
    /// AppleScript refused this session (VoiceOver's option off): TurnOver changes its own alone.
    nonisolated(unsafe) private static var refused = false   // main thread
    nonisolated(unsafe) private static var toldRefused = false   // main thread

    /// Whether this setting goes through VoiceOver now. Off since 20 Oct 2026 (Oliver: "get rid of that bonding of
    /// VoiceOver and TurnOver voices, it's not working correctly"): the keys change TurnOver's own voice only, and
    /// TurnOver no longer reads VoiceOver's rate as it takes over. The code stays for a better attempt.
    public static let on = false
    public static func applies(_ setting: String) -> Bool {
        on && paired.contains(setting) && !refused
            && !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.VoiceOver").isEmpty
    }

    /// Step VoiceOver's setting `steps` times (negative: down), read back what it now has, and hand the percentage to
    /// `apply` on the main thread; nil when VoiceOver couldn't be changed or read.
    public static func step(_ setting: String, by steps: Int, apply: @escaping @MainActor @Sendable (Int?) -> Void) {
        let command = (steps > 0 ? "increase " : "decrease ") + setting
        let count = abs(steps)
        queue.async {
            var ok = true
            for _ in 0..<max(1, count) where ok { ok = run("tell application \"VoiceOver\" to tell commander to perform command \"\(command)\"") != nil }
            guard ok else {
                DispatchQueue.main.async { MainActor.assumeIsolated { refuse(setting); apply(nil) } }
                return
            }
            // VoiceOver says the new value most of a second later ("75%"); its words are read back.
            var percent: Int?
            let end = Date().addingTimeInterval(1.5)
            while percent == nil, Date() < end {
                usleep(150_000)
                if let words = run("tell application \"VoiceOver\" to get content of last phrase") { percent = parsePercent(words) }
            }
            Log.io("speech parity: VoiceOver \(command) ×\(max(1, count)) → \(percent.map { "\($0)%" } ?? "not read back")")
            let p = percent
            DispatchQueue.main.async { MainActor.assumeIsolated { apply(p) } }
        }
    }

    /// The other way round: VoiceOver's rate, volume and pitch read and copied into TurnOver, when TurnOver takes an
    /// app (19 Oct 2026: "speeding up voiceover isn't speeding up turnover"). VoiceOver has no AppleScript
    /// getter for them, so each is stepped down one and up one, and the value it reports after the step up is its
    /// value (unchanged by the pair). Down first, so a setting at its top (volume 100%) comes back right; only one at
    /// 0% would read 5%. TurnOver has VoiceOver silenced in its own apps, so nobody hears the two steps. Not more
    /// than once in 5 s.
    nonisolated(unsafe) private static var lastFollow = Date.distantPast   // main thread
    public static func followVoiceOver() {
        guard applies("rate"), Date().timeIntervalSince(lastFollow) > 5 else { return }
        lastFollow = Date()
        // After VoiceOver's sound is silenced (the tap takes a moment), so its two steps aren't heard.
        queue.asyncAfter(deadline: .now() + 0.6) {
            var found: [String: Int] = [:]
            for setting in ["rate", "volume", "pitch"] {
                guard run("tell application \"VoiceOver\" to tell commander to perform command \"decrease \(setting)\"") != nil else { return }
                usleep(250_000)
                guard run("tell application \"VoiceOver\" to tell commander to perform command \"increase \(setting)\"") != nil else { return }
                let end = Date().addingTimeInterval(1.2)
                while found[setting] == nil, Date() < end {
                    usleep(150_000)
                    if let words = run("tell application \"VoiceOver\" to get content of last phrase") { found[setting] = parsePercent(words) }
                }
            }
            let values = found
            DispatchQueue.main.async { MainActor.assumeIsolated {
                var changed: [String] = []
                if let r = values["rate"], abs(Float(r) / 100 - config.speech.rate) > 0.001 {
                    config.speech.rate = min(1.0, max(0.1, Float(r) / 100)); Speech.player.rate = config.speech.rate; changed.append("rate \(r)")
                }
                if let v = values["volume"], v != config.speech.volume, config.speech.volume <= 100 || v < 100 {
                    config.speech.volume = min(200, max(10, v)); Speech.player.volume = Float(config.speech.volume) / 100; changed.append("volume \(v)")
                }
                if let p = values["pitch"], abs(Float(p) / 100 - config.speech.pitch) > 0.001 {
                    config.speech.pitch = min(1.0, max(0.0, Float(p) / 100)); Speech.player.pitch = config.speech.pitchMultiplier; changed.append("pitch \(p)")
                }
                Log.io("speech parity: VoiceOver has \(values.map { "\($0.key) \($0.value)%" }.sorted().joined(separator: ", "))\(changed.isEmpty ? "; TurnOver already the same" : "; TurnOver follows: " + changed.joined(separator: ", "))")
                if !changed.isEmpty { config.save() }
            } }
        }
    }

    /// "75%" or "Rate 75%" to 75.
    nonisolated public static func parsePercent(_ words: String) -> Int? {
        guard let r = words.range(of: #"(\d{1,3})\s*%"#, options: .regularExpression) else { return nil }
        return Int(words[r].filter(\.isNumber))
    }

    private static func refuse(_ setting: String) {
        refused = true
        Log.warning("speech parity: VoiceOver refused AppleScript; TurnOver changes its own settings alone this session")
        guard !toldRefused else { return }
        toldRefused = true
        Speech.speakMessage("VoiceOver's \(setting) wasn't changed: to keep the two in step, turn on Allow VoiceOver to be controlled with AppleScript, in VoiceOver Utility, General.")
    }

    /// osascript's answer, nil on an error (VoiceOver's AppleScript off is error 4).
    nonisolated private static func run(_ script: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
