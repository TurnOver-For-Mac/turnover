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
    // 14 Nov 2026: a mute request is not confirmation. A short-lived helper status is
    // tied to VoiceOver's actual pid; a restart, pipe loss or changed request invalidates it.
    private static var confirmation = VoiceOverMuteConfirmation()
    private static var lastProbe = -Double.infinity
    private static var probeSequence = 0
    // Only the isolated executable-source harness installs this boundary driver. The
    // actual getter and final confirmation read remain under test, without a helper.
    private static var announcementTestDriver: (() -> Void)?
    static var announcementConfirmation: Bool? {
        guard announcementTestDriver != nil || on else {
            if process?.isRunning == true { return nil }
            return wantedSilent ? nil : false
        }
        let now = announcementTestDriver == nil ? ProcessInfo.processInfo.systemUptime : 1
        let pid = announcementTestDriver == nil ? NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.VoiceOver").first?.processIdentifier ?? 0 : 123
        if let announcementTestDriver { announcementTestDriver() }
        else if let input = ensureHelper() {
            // Reuse an unexpired acknowledgement while the helper remains alive. Probing
            // every readiness check would revoke it again before the settling delay ends.
            if now - lastProbe >= 0.1, confirmation.value(pid: pid, wanted: wantedSilent, now: now) == nil {
                lastProbe = now
                probeSequence += 1
                let token = String(probeSequence)
                confirmation.expect(token)
                send("status " + token, to: input)
            }
        }
        // Restarting, requesting status, or a failed pipe write can invalidate the old reply.
        return confirmation.value(pid: pid, wanted: wantedSilent, now: now)
    }
    /// Exercises this getter after each operation that can revoke a previously good reply.
    static func testAnnouncementInvalidation() -> Bool {
        let saved = confirmation
        let savedWanted = wantedSilent
        defer { confirmation = saved; wantedSilent = savedWanted; announcementTestDriver = nil }
        wantedSilent = true
        func seed() {
            confirmation.reset()
            confirmation.expect("a")
            _ = confirmation.consume(Data("status 123 on a\n".utf8), now: 1)
        }
        seed()
        announcementTestDriver = {}
        guard announcementConfirmation == true else { return false }
        // Helper restart, new status probe, and a failed pipe write all revoke the reply.
        let invalidations: [() -> Void] = [
            { confirmation.reset() },
            { confirmation.expect("b") },
            {
                // A read-only descriptor produces a real failed write without SIGPIPE,
                // launching a helper, or changing the Mac's VoiceOver state.
                let handle = FileHandle(forReadingAtPath: "/dev/null")!
                defer { try? handle.close() }
                send("status b", to: handle)
            }
        ]
        for invalidate in invalidations {
            seed()
            announcementTestDriver = invalidate
            guard announcementConfirmation == nil else { return false }
        }
        return true
    }
    private static var said: Bool?
    /// The helper's errors in a row ("VoiceOver isn't running", "no sound yet"): asked again a few times, not forever.
    private static var errorsInARow = 0
    private static var toldCantSilence = false
    private static var waitingForVoiceOver = false
    /// "still" every second while VoiceOver is silent: the helper lets VoiceOver be heard if it stops coming (TurnOver
    /// frozen, which the watchdog's 4 s and its thread don't always catch: a code review on 18 Oct 2026).
    private static var stillTimer: Timer?
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
        if wantedSilent != silent { confirmation.reset() }
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
        } else if !silent { stillTimer?.invalidate(); stillTimer = nil }
    }

    /// A line to the helper: never the raising write, which ends TurnOver if the helper has just gone.
    private static func send(_ word: String, to handle: FileHandle) {
        do { try handle.write(contentsOf: Data((word + "\n").utf8)) }
        catch { Log.warning("VoiceOver quiet: the helper didn't take \(word) (\(error.localizedDescription))"); process = nil; input = nil; said = nil; confirmation.reset() }
    }

    /// The helper, started on first need; a fresh one if the last ended.
    private static func ensureHelper() -> FileHandle? {
        if let p = process, p.isRunning, let input { return input }
        confirmation.reset()
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
            guard !data.isEmpty else {
                h.readabilityHandler = nil
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    guard process === p else { return }
                    confirmation.reset()
                } }
                return
            }
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard process === p else { return }
                for text in confirmation.consume(data, now: ProcessInfo.processInfo.systemUptime) {
                    handleReply(text, helper: p)
                }
            } }
        }
        // Only if it's still the current helper: a terminated predecessor cannot confirm its successor.
        p.terminationHandler = { ended in DispatchQueue.main.async { MainActor.assumeIsolated {
            guard process == nil || process === ended else { return }
            process = nil; input = nil; said = nil; helperPid = 0; confirmation.reset()
        } } }
        do { try p.run() } catch { Log.warning("VoiceOver quiet: couldn't start the helper: \(error.localizedDescription)"); return nil }
        confirmation.reset()
        process = p; input = toHelper.fileHandleForWriting; helperPid = p.processIdentifier; said = nil
        return input
    }

    private static func handleReply(_ text: String, helper: Process) {
        if text == "on" {
            if waitingForVoiceOver { waitingForVoiceOver = false; Log.io("VoiceOver quiet: on (VoiceOver back)") }
        } else if text.contains("isn't running") {
            // No VoiceOver to quiet (quit, or not started yet): asked again every 2 s while TurnOver wants it
            // quiet, not counted towards giving up; it was, and the five misses spoke the audio-permission message
            // for a VoiceOver that simply wasn't there (19 Oct 2026). Logged once.
            if !waitingForVoiceOver { waitingForVoiceOver = true; Log.info("VoiceOver quiet: VoiceOver isn't running; asking again every 2 s") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated {
                guard process === helper, wantedSilent else { return }
                let tries = errorsInARow
                said = nil; set(true, why: "VoiceOver back")
                errorsInARow = tries
            } }
        } else if text.contains("error") {
            Log.warning("VoiceOver quiet: helper said \(text)")
            // VoiceOver not running or not sounding yet (just started): asked again in a moment, up to five times.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated {
                guard process === helper, wantedSilent else { return }
                errorsInARow += 1
                guard errorsInARow <= 5 else {
                    if errorsInARow == 6 {
                        Log.warning("VoiceOver quiet: giving up until TurnOver next takes an app")
                        // Said, once a run: two voices with no reason given is the worst first impression (a tester
                        // who said no to macOS's audio question, or a macOS that changed the tap; 19 Oct 2026).
                        if !toldCantSilence {
                            toldCantSilence = true
                            Speech.speakMessage(String(localized: "TurnOver can't keep VoiceOver quiet, so you may hear both. In System Settings, Privacy and Security, Screen and System Audio Recording, turn TurnOver on; or turn CoExist off in TurnOver's Settings, Experimental.", comment: "Spoken message"))
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
