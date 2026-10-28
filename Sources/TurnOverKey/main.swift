// SPDX-License-Identifier: GPL-3.0-or-later
// TurnOver Key: the one shortcut that starts and quits TurnOver, Command+Control+Period (NVDA's Control+Alt+N, in
// spirit; Command Control T until 12 Oct 2026, when Finder, Mail, Terminal, Preview, WhatsApp and Xcode were found to
// use it). A tiny helper inside TurnOver.app, registered as a login item, so it is listening even when TurnOver is
// not running. It needs no permissions: the shortcut is registered with macOS (a Carbon hot key), and it does
// nothing else. Pressed: TurnOver starts if it isn't running; if it is, it turns itself off or on (CoExist), or an
// older TurnOver that doesn't answer is quit. It also starts TurnOver again after a crash (the safety net, below).
import AppKit
import AVFoundation
import Carbon.HIToolbox
import TurnOverControl
import TurnOverObjC

// The reader this helper belongs to: TOReaderID in its Info.plist (build.sh writes it), else TurnOver's bundle id.
let readerID = (Bundle.main.object(forInfoDictionaryKey: "TOReaderID") as? String) ?? "com.turnover.reader"

// One copy only.
if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.turnover.key").count > 1 { exit(0) }

/// TurnOver.app: this helper lives in TurnOver.app/Contents/Library/LoginItems/TurnOver Key.app.
/// TurnOver itself: the copy this helper is inside, if it still exists; else wherever macOS knows TurnOver to be.
/// A tester ran TurnOver from Downloads, moved it to Applications and deleted the first copy; the helper, started
/// from the first copy, went on looking there and said TurnOver couldn't be found (5 Oct 2026).
func readerApp() -> URL {
    let inside = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    if inside.pathExtension == "app", FileManager.default.fileExists(atPath: inside.appendingPathComponent("Contents/MacOS").path) { return inside }
    if let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: readerID) { return found }
    return URL(fileURLWithPath: "/Applications/TurnOver.app")
}

/// A soft two-note bell, as TurnOver's own: rising as it starts, falling as it goes (VoiceOver may be talking).
final class Bell {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try? engine.start()
        if engine.isRunning { _ = TOCatch({ node.play() }, nil) }   // play() raises if the device has gone, and the helper ended (as TurnOver did, 18 Oct 2026)
    }
    func play(_ notes: [Double]) {
        let sr = format.sampleRate, spacing = Int(sr * 0.07), ring = Int(sr * 0.15)
        let total = spacing * (notes.count - 1) + ring
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)), let d = buf.floatChannelData?[0] else { return }
        buf.frameLength = AVAudioFrameCount(total)
        for i in 0..<total { d[i] = 0 }
        let tau = Double(ring) / 4.5, attack = Int(sr * 0.004)
        for (n, f) in notes.enumerated() {
            for j in 0..<ring where n * spacing + j < total {
                var env = exp(-Double(j) / tau)
                if j < attack { env *= Double(j) / Double(attack) }
                let t = Double(j) / sr
                d[n * spacing + j] += Float(env * (sin(2 * .pi * f * t) + 0.25 * sin(4 * .pi * f * t) * exp(-Double(j) / (tau / 2))) / 1.25) * 0.12
            }
        }
        if !engine.isRunning { try? engine.start(); if engine.isRunning { _ = TOCatch({ node.play() }, nil) } }
        guard engine.isRunning else { return }   // no sound device (asleep, locked): no bell
        node.scheduleBuffer(buf, completionHandler: nil)
    }
}

/// "TurnOver on" / "TurnOver off", in the voice and at the rate set for TurnOver (its settings.json).
final class Voice {
    private let synth = AVSpeechSynthesizer()
    func say(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        let settings = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TurnOver/settings.json")
        if let data = try? Data(contentsOf: settings),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let speech = json["speech"] as? [String: Any] {
            if let id = speech["voice"] as? String, let v = AVSpeechSynthesisVoice(identifier: id) { u.voice = v }
            if let r = speech["rate"] as? Double { u.rate = Float(r) }
        }
        synth.stopSpeaking(at: .immediate)
        synth.speak(u)
    }
}

final class Key {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    let bell = Bell()
    let voice = Voice()

    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let me = Unmanaged<Key>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { me.pressed() } }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        registerHotKey(tries: 15)
        // Whether TurnOver is running, looked at every second. (macOS's "application terminated" notice is not sent for
        // a menu-bar app like TurnOver: the first crash test went unnoticed, 4 Oct 2026.)
        wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: readerID).isEmpty
        listenForQuits()   // a quit TurnOver announces is on purpose: no restart (16 Oct 2026)
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated {
            guard let self else { return }
            let now = !NSRunningApplication.runningApplications(withBundleIdentifier: readerID).isEmpty
            if self.wasRunning && !now { self.readerEnded() }
            self.wasRunning = now
        } }
        note("started; TurnOver \(wasRunning ? "running" : "not running")")
    }

    /// Command+Control+Period. A helper starting while another still holds the key (a restart, two started at
    /// once) is refused it, and the one left running then answered nothing: Command Control Period did nothing
    /// (18 Oct 2026). Tried again every two seconds until it's ours, and written in the helper's log.
    private func registerHotKey(tries: Int) {
        let id = EventHotKeyID(signature: OSType(0x544F4B59), id: 1)   // "TOKY"
        let r = RegisterEventHotKey(UInt32(kVK_ANSI_Period), UInt32(cmdKey | controlKey), id, GetApplicationEventTarget(), 0, &ref)
        if r == noErr { note("Command+Control+Period registered"); return }
        note("Command+Control+Period not registered (\(r))\(tries > 1 ? "; trying again" : "; giving up")")
        guard tries > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { self.registerHotKey(tries: tries - 1) } }
    }

    // MARK: The safety net (E11, 4 Oct 2026)
    // TurnOver turns VoiceOver on as it quits, and the watchdog covers it hanging; but a crash leaves VoiceOver off in
    // the app TurnOver was reading, with no speech at all. This helper outlives it: if TurnOver has gone, VoiceOver is
    // not on, and TurnOver is not coming back by itself (a restart), start it again. If it crashes again within a
    // minute, do not loop: say how to turn VoiceOver on. (The helper has no permissions, so it cannot press
    // VoiceOver's key itself.)
    private var quitting = false
    private var wasRunning = false

    /// A line in the helper's own log, ~/Library/Logs/TurnOver Key.log. (Not TurnOver's folder: writing into another
    /// app's data asks macOS's privacy permission, and stalled the helper, 4 Oct 2026.)
    func note(_ text: String) {
        let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/TurnOver Key.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
        if let h = try? FileHandle(forWritingTo: url) { _ = try? h.seekToEnd(); try? h.write(contentsOf: Data(line.utf8)); try? h.close() }   // never the raising write: a full disk ended TurnOver (12 Oct 2026)
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }
    private var lastRescue = Date.distantPast

    private func readerEnded() {
        if quitting { quitting = false; note("TurnOver quit on purpose (the menu, Command Q, or Command+Control+Period)"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { [self] in
            let back = !NSRunningApplication.runningApplications(withBundleIdentifier: readerID).isEmpty
            // An Activity left by a build before 18 Oct: VoiceOver is silent in TurnOver's apps until it's out, so a
            // TurnOver that stopped comes back whatever VoiceOver says.
            let activityIn = oldActivityInstalled()
            // Coexisting (experimental, off unless turned on): VoiceOver is on all the time and silenced in TurnOver's
            // apps, so a TurnOver that stopped comes back whatever VoiceOver says.
            let coexist = (CFPreferencesCopyAppValue("coexist" as CFString, readerID as CFString) as? Bool) ?? false
            // VoiceOver talking is its flag and its process: the flag alone stays on after VoiceOver was quit by script
            // or crashed (a code review, 25 Oct 2026).
            let voiceOverTalking = NSWorkspace.shared.isVoiceOverEnabled && !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.VoiceOver").isEmpty
            guard !back, !voiceOverTalking || coexist || activityIn else {   // restarted, or VoiceOver is talking
                note("TurnOver ended; \(back ? "it is back (a restart)" : "VoiceOver is on"): nothing to do"); return
            }
            // The Mac asleep or locked (the lid closed): no sound device and nobody listening, and a start now stalled on
            // the audio engine (19 Oct 2026). Started instead when the Mac wakes or is unlocked, quietly, after a pause.
            if asleepOrLocked {
                note("TurnOver stopped while the Mac is asleep or locked; starting it again when it wakes")
                gaveUp = true
                return
            }
            if Date().timeIntervalSince(lastRescue) > 60 {
                lastRescue = Date()
                note("TurnOver stopped with VoiceOver off; starting it again")
                bell.play([784, 1175])
                voice.say("TurnOver stopped unexpectedly. Restarting it.")
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = false
                cfg.arguments = ["--announced"]
                NSWorkspace.shared.openApplication(at: readerApp(), configuration: cfg) { _, _ in }
            } else {
                note("TurnOver stopped again within a minute; not restarting now; tried again when the Mac is next woken or unlocked")
                gaveUp = true
                voice.say("TurnOver has stopped again. Press Command Control Period to start it; if VoiceOver is silent in an app, press it again.")
            }
        } }
    }


    private var quitNoteObserver: NSObjectProtocol?
    func listenForQuits() {
        quitNoteObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.turnover.quitting"), object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.quitting = true } }
        // Given up on (two stops in a minute): tried once more when the Mac wakes or is unlocked. On 18 Oct 2026 the Mac
        // locked and slept, TurnOver ended as the sound went (fixed), the restart stalled with no sound device, and
        // TurnOver stayed off until it was noticed ("turnover was off, I don't think I turned it off").
        let again: @Sendable (Notification) -> Void = { [weak self] n in
            let woke = n.name == NSWorkspace.screensDidWakeNotification
            MainActor.assumeIsolated {
                if woke { self?.displayAsleep = false } else { self?.locked = false }
                self?.tryAgainAfterGivingUp()
            }
        }
        wakeObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.displayAsleep = true } })
        wakeObservers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.locked = true } })
        wakeObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: again))
        wakeObservers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main, using: again))
    }
    private var gaveUp = false
    private var wakeObservers: [NSObjectProtocol] = []
    /// The display asleep or the screen locked, as macOS last said.
    private var displayAsleep = false
    private var locked = false
    private var asleepOrLocked: Bool { displayAsleep || locked }
    private func tryAgainAfterGivingUp() {
        guard gaveUp, !asleepOrLocked, NSRunningApplication.runningApplications(withBundleIdentifier: readerID).isEmpty else { return }
        gaveUp = false
        lastRescue = Date()
        note("the Mac woke or was unlocked after TurnOver stopped twice; starting it again")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated {   // the sound device back first
            guard NSRunningApplication.runningApplications(withBundleIdentifier: readerID).isEmpty else { return }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            NSWorkspace.shared.openApplication(at: readerApp(), configuration: cfg) { _, _ in }
        } }
    }
    func pressed() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: readerID)
        if let app = running.first {
            // Coexisting (experimental, 16 Oct 2026): TurnOver stays running and turns itself off and on. Asked through
            // its control channel (TurnOverControl), off the main thread; it answers at once. One that doesn't (stuck,
            // or older) is quit.
            let coexist = (CFPreferencesCopyAppValue("coexist" as CFString, readerID as CFString) as? Bool) ?? false
            if coexist {
                DispatchQueue.global(qos: .userInitiated).async {
                    let answered = ControlClient.send(["op": "toggle"], folder: "TurnOver", waitFor: 1.0).answer?["op"] as? String == "ack"
                    DispatchQueue.main.async { MainActor.assumeIsolated {
                        if answered { self.note("TurnOver toggled by Command+Control+Period (still running)"); return }
                        self.quitReader(app)
                    } }
                }
                return
            }
            // Quit, as before CoExist: TurnOver no longer stays running while off (CoExist removed, 24 Oct 2026). Once
            // the hand is off the keys: the hot key fires as the key goes down, and TurnOver's hand-back, posting
            // VoiceOver's shortcut while Command and Control were still held, sent Command Control plus that shortcut,
            // so VoiceOver never came on (the maintainer's Mac, 25 Oct 2026). Up to a second and a half, then anyway.
            quitWhenKeysAreUp(app)
            return
        }
        start()
    }
    /// TurnOver's record of the Activity it put into VoiceOver's settings in builds before 18 Oct 2026, still there.
    private func oldActivityInstalled() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/TurnOver/voiceover-activity.json")
        return (try? String(contentsOf: url, encoding: .utf8))?.contains("\"installed\":true") ?? false
    }
    private var quitPending = false
    private func quitWhenKeysAreUp(_ app: NSRunningApplication) {
        guard !quitPending, !quitting else { return }   // a second press while the first waits, or while TurnOver goes
        quitPending = true
        waitThenQuit(app, until: Date().addingTimeInterval(1.5))
    }
    private func waitThenQuit(_ app: NSRunningApplication, until end: Date) {
        // The TurnOver that was pressed for, still running: it may have stopped meanwhile, and a quit of a stopped one
        // would mark its crash as on purpose and skip the restart (a code review, 25 Oct 2026).
        guard !app.isTerminated else { quitPending = false; return }
        let held = NSEvent.modifierFlags.intersection([.command, .control, .option, .shift])
        if !held.isEmpty, Date() < end {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { self.waitThenQuit(app, until: end) } }
            return
        }
        quitPending = false
        // Still held: quitting now would leave VoiceOver's shortcut spoiled again, so TurnOver stays (the same review).
        if !held.isEmpty {
            note("Command+Control+Period: modifiers still held after 1.5 s; not quitting")
            voice.say("Let go of the keys, then press Command Control Period again.")
            return
        }
        quitReader(app)
    }
    private func quitReader(_ app: NSRunningApplication) {
        // Quit. SIGTERM, which TurnOver answers off its main thread (VoiceOver on, then gone) even if it is stuck;
        // if it is still there after three seconds, it is stopped outright.
        bell.play([1175, 784])
        voice.say("TurnOver off")
        quitting = true
        kill(app.processIdentifier, SIGTERM)
        let pid = app.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if NSRunningApplication(processIdentifier: pid) != nil { kill(pid, SIGKILL) }
        }
    }
    private func start() {
        bell.play([784, 1175])
        voice.say("TurnOver on")
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.arguments = ["--announced"]   // TurnOver does not say "TurnOver on" again as it takes over
        NSWorkspace.shared.openApplication(at: readerApp(), configuration: cfg) { _, error in
            if let error { NSLog("TurnOver Key: could not start TurnOver: %@", error.localizedDescription) }
        }
    }
}

// One helper only. macOS starts it as a login item while TurnOver may also start it; two answered the shortcut
// together and would both restart TurnOver (a tester account, 5 Oct 2026). The later one leaves.
let me = ProcessInfo.processInfo.processIdentifier
let others = NSRunningApplication.runningApplications(withBundleIdentifier: "com.turnover.key").filter { $0.processIdentifier != me }
if let other = others.first, (other.launchDate ?? .distantPast) <= Date() {
    exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let key = Key()
app.run()
