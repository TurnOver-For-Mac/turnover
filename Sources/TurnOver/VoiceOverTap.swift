// SPDX-License-Identifier: GPL-3.0-or-later
// VoiceOver silenced at the system's audio level (18 Oct 2026: "voiceover must have some output stream
// somewhere that goes to the soundcard, can't we just intercept that and have a discrete signal to turn it on and
// off?"). The silencing itself is the open helper voiceover-quiet (Helpers/voiceover-quiet, MIT): a Core Audio
// process tap on VoiceOver, set to mute, that records and sends nothing. It is a separate program so anyone can read
// all of it (18 Oct 2026: publish "the little bit that kills VoiceOver audio"). TurnOver starts it once and
// says "on" or "off" down a pipe; TurnOver going, for any reason, closes the pipe, the helper ends, and VoiceOver is
// heard. Tested by ear: switching between TurnOver's apps and VoiceOver's "absolutely seamless".
import AppKit
import TurnOverCore

@MainActor
enum VoiceOverTap {
    static var on: Bool {
        guard #available(macOS 14.2, *) else { return false }
        return (UserDefaults.standard.object(forKey: "voMuteTap") as? Bool ?? true) && helperURL != nil
    }
    /// What TurnOver last asked for.
    static var wantedSilent = false
    private static var said: Bool?
    /// The helper's errors in a row ("VoiceOver isn't running", "no sound yet"): asked again a few times, not forever.
    private static var errorsInARow = 0
    private static var toldCantSilence = false
    private static var waitingForVoiceOver = false
    /// "still" every second while VoiceOver is silent: the helper lets VoiceOver be heard if it stops coming (TurnOver
    /// frozen, which the watchdog's 4 s and its thread don't always catch: a code review on 18 Oct 2026).
    private static var stillTimer: Timer?
    /// The helper answered the last "off". If it doesn't within a second (held up, as by macOS's audio-permission
    /// question on 21 Oct 2026), it's ended, so VoiceOver is heard whatever it's waiting on.
    private static var offAnswered = true
    private static var process: Process?
    private static var input: FileHandle?
    /// The helper's pid, for the watchdog's thread.
    nonisolated(unsafe) private static var helperPid: pid_t = 0

    private static var helperURL: URL? {
        let u = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/voiceover-quiet")
        return FileManager.default.isExecutableFile(atPath: u.path) ? u : nil
    }

    /// VoiceOver silent (true) or heard (false). Asked twice the same way, the second does nothing.
    static func set(_ silent: Bool, why: String) {
        guard on else { return }
        wantedSilent = silent
        guard said != silent || process?.isRunning != true else { return }
        guard let input = ensureHelper() else { return }
        said = silent
        errorsInARow = 0
        send(silent ? "on" : "off", to: input)
        if why == "VoiceOver back", waitingForVoiceOver {} else { Log.io("VoiceOver quiet: \(silent ? "on" : "off") (\(why))") }
        if silent, stillTimer == nil {
            stillTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated {
                guard wantedSilent, let helper = VoiceOverTap.input, process?.isRunning == true else { return }
                send("still", to: helper)
            } }
        } else if !silent {
            stillTimer?.invalidate(); stillTimer = nil
            offAnswered = false
            let helper = process
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated {
                guard !offAnswered, !wantedSilent, let helper, helper === process, helper.isRunning else { return }
                Log.warning("VoiceOver quiet: the helper didn't answer off; ended so VoiceOver is heard")
                helper.terminate()
            } }
        }
    }

    /// A line to the helper: never the raising write, which ends TurnOver if the helper has just gone.
    private static func send(_ word: String, to handle: FileHandle) {
        do { try handle.write(contentsOf: Data((word + "\n").utf8)) }
        catch { Log.warning("VoiceOver quiet: the helper didn't take \(word) (\(error.localizedDescription))"); process = nil; input = nil; said = nil }
    }

    /// The helper, started on first need; a fresh one if the last ended.
    private static func ensureHelper() -> FileHandle? {
        if let p = process, p.isRunning, let input { return input }
        guard let url = helperURL else { Log.warning("VoiceOver quiet: the helper is missing"); return nil }
        let p = Process()
        p.executableURL = url
        let toHelper = Pipe(), fromHelper = Pipe()
        p.standardInput = toHelper
        p.standardOutput = fromHelper
        p.standardError = FileHandle.nullDevice
        fromHelper.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            // The helper gone: nothing more to read (left set, the handler was called again and again on the end).
            guard !data.isEmpty else { h.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.split(separator: "\n").contains("off") { DispatchQueue.main.async { MainActor.assumeIsolated { offAnswered = true } } }
            if text == "on" {
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    if waitingForVoiceOver { waitingForVoiceOver = false; Log.io("VoiceOver quiet: on (VoiceOver back)") }
                } }
            } else if text.contains("isn't running") {
                // No VoiceOver to quiet (quit, or not started yet): asked again every 2 s while TurnOver wants it
                // quiet, not counted towards giving up; it was, and the five misses spoke the audio-permission message
                // for a VoiceOver that simply wasn't there (19 Oct 2026). Logged once.
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    if !waitingForVoiceOver { waitingForVoiceOver = true; Log.info("VoiceOver quiet: VoiceOver isn't running; asking again every 2 s") }
                } }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated {
                    guard wantedSilent else { return }
                    let tries = errorsInARow
                    said = nil; set(true, why: "VoiceOver back")
                    errorsInARow = tries
                } }
            } else if text.contains("error") {
                Log.warning("VoiceOver quiet: helper said \(text)")
                // VoiceOver not running or not sounding yet (just started): asked again in a moment, up to five times.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated {
                    guard wantedSilent else { return }
                    errorsInARow += 1
                    guard errorsInARow <= 5 else {
                        if errorsInARow == 6 {
                            Log.warning("VoiceOver quiet: giving up until TurnOver next takes an app")
                            // Said, once a run: two voices with no reason given is the worst first impression (a tester
                            // who said no to macOS's audio question, or a macOS that changed the tap; 19 Oct 2026).
                            if !toldCantSilence {
                                toldCantSilence = true
                                Speech.speakMessage("TurnOver can't keep VoiceOver quiet, so you may hear both. In System Settings, Privacy and Security, Screen and System Audio Recording, turn TurnOver on; or turn CoExist off in TurnOver's Settings, Experimental.")
                            }
                        }
                        return
                    }
                    let tries = errorsInARow
                    said = nil; set(true, why: "again after: \(text)")
                    errorsInARow = tries
                } }
            }
        }
        // Only if it's still the current helper: one ended by the watchdog can report after its successor started.
        p.terminationHandler = { ended in DispatchQueue.main.async { MainActor.assumeIsolated {
            guard process == nil || process === ended else { return }
            process = nil; input = nil; said = nil; helperPid = 0
        } } }
        do { try p.run() } catch { Log.warning("VoiceOver quiet: couldn't start the helper: \(error.localizedDescription)"); return nil }
        process = p; input = toHelper.fileHandleForWriting; helperPid = p.processIdentifier; said = nil
        return input
    }

    /// After the watchdog let VoiceOver be heard: silent again if TurnOver had it silent (a fresh helper).
    static func resume() {
        guard wantedSilent else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated {
            guard wantedSilent else { return }
            said = nil
            set(true, why: "back after the watchdog")
        } }
    }

    /// From the watchdog's thread while TurnOver's main thread is stuck: the helper ended, so VoiceOver is heard.
    nonisolated static func emergencyOff() {
        let pid = helperPid
        guard pid != 0 else { return }
        kill(pid, SIGTERM)
        Log.error("VoiceOver quiet: helper ended by the watchdog (TurnOver stuck); VoiceOver heard")
    }
}
