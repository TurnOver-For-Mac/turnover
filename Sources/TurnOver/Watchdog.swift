// SPDX-License-Identifier: GPL-3.0-or-later
// The way out if TurnOver hangs (a beta tester must never be left without a reader).
//
// The main thread beats twice a second. A separate thread watches: if TurnOver is active (VoiceOver off)
// and the main thread has not beaten for 4 seconds, it lets every key through untouched (the keyboard
// tap stops taking TurnOver's chords, which would otherwise queue for a main thread that never runs them),
// and turns VoiceOver back on with the system's own shortcut. If the main thread is still stuck 20
// seconds after that, TurnOver relaunches itself. (1 Oct 2026: a deadlock silenced TurnOver in Safari while
// the keyboard thread kept taking keys.)
import Foundation
import AppKit
import TurnOverCore
import TurnOverSpeech

final class Watchdog: @unchecked Sendable {   // its state is under `lock`
    nonisolated static let shared = Watchdog()
    nonisolated private init() {}
    private let lock = NSLock()
    // All under `lock`: written by the main thread's beat, read on the watch thread.
    nonisolated(unsafe) private var lastBeat = Date()
    nonisolated(unsafe) private var _active = false
    nonisolated(unsafe) private var trippedAt: Date?
    nonisolated(unsafe) private var _lastTrip: Date?

    /// When the watchdog last turned VoiceOver on: that change is not the user's (the lead watcher took it as Mail
    /// "pinned to VoiceOver by hand", 3 Oct 2026). VoiceOver then keeps the app until the user next switches apps.
    /// How long since the main thread last beat (any thread).
    nonisolated var secondsSinceBeat: TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(lastBeat) }

    nonisolated var lastTrip: Date? { lock.lock(); defer { lock.unlock() }; return _lastTrip }

    /// TurnOver is reading (VoiceOver off): set by the app, read by the watch.
    /// No fresh player and no relaunch while the Mac is asleep or locked, nor for 30 s after it wakes: the audio
    /// system is away then, speech sticks for a while by rights, and a relaunch at the lock screen made copy after copy
    /// of TurnOver (a tester, 20 Oct 2026: "many instances", speech as an echo, VoiceOver unstartable).
    nonisolated(unsafe) private var graceUntil = Date.distantPast
    nonisolated func noteAsleepOrLocked() { lock.lock(); graceUntil = .distantFuture; lock.unlock() }
    nonisolated func noteAwake() { lock.lock(); graceUntil = Date().addingTimeInterval(30); lock.unlock() }
    nonisolated private var inGrace: Bool { lock.lock(); defer { lock.unlock() }; return Date() < graceUntil }

    nonisolated var active: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _active }
        set { lock.lock(); _active = newValue; lock.unlock() }
    }

    func start() {
        // In the common modes: a menu being tracked (TurnOver's own status menu) runs the main thread in another
        // mode, and a default-mode heartbeat stopped while main was perfectly well (E6 audit, 4 Oct 2026).
        let beat = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            lock.lock(); lastBeat = Date(); let wasTripped = trippedAt != nil; trippedAt = nil; lock.unlock()
            if wasTripped {
                Log.error("watchdog: the main thread is back")
                KeyboardHandler.bypass = false
                // VoiceOver silenced again where TurnOver reads: it stayed heard after a 4-second stall on Word opening
                // a long book, speaking over TurnOver until another app came forward (18 Oct 2026).
                MainActor.assumeIsolated { VoiceOverTap.resume() }
            }
        }
        RunLoop.main.add(beat, forMode: .common)
        let t = Thread { [weak self] in
            while true {
                Thread.sleep(forTimeInterval: 1)
                self?.check()
            }
        }
        t.name = "turnover.watchdog"
        t.qualityOfService = .userInteractive
        t.start()
    }

    nonisolated private func check() {
        lock.lock()
        let stuck = Date().timeIntervalSince(lastBeat)
        let tripped = trippedAt
        let isActive = _active
        lock.unlock()
        if let tripped {
            if Date().timeIntervalSince(tripped) > 20 {
                if inGrace { Log.error("watchdog: still stuck, but the Mac is asleep, locked or just awake; no relaunch yet") } else { relaunch(stuckFor: stuck) }
            }
            return
        }
        // Coexisting, a hang matters whether or not TurnOver is active: VoiceOver is kept quiet in TurnOver's apps, so
        // a TurnOver that hangs in Finder is found out only in Mail, where nobody speaks (a code review on 17 Oct
        // 2026). Watched always there.
        guard isActive || Coexist.on, stuck > 4 else { return }
        lock.lock(); trippedAt = Date(); _lastTrip = trippedAt; lock.unlock()
        // The Mac asleep, locked or just awake: the beat stopped because the Mac did, not TurnOver. Keys through and
        // VoiceOver heard as below, in case; but not announced. Each wake said "TurnOver is not responding" in the
        // system's voice, several copies over each other (Oliver, 22 Oct 2026), while TurnOver was simply waking.
        let sleeping = inGrace
        Log.error("watchdog: the main thread has not run for \(Int(stuck)) s\(sleeping ? " (the Mac asleep, locked or just awake)" : ""); letting keys through and turning VoiceOver back on")
        KeyboardHandler.bypass = true
        // VoiceOver's sound back first: the tap silencing it would otherwise outlive a hang (18 Oct 2026).
        VoiceOverTap.emergencyOff()
        if !NSWorkspace.shared.isVoiceOverEnabled, !Coexist.on { HandOver.postToggle() }   // (coexisting, VoiceOver is already on)
        // Said with the system's own voice, which needs neither TurnOver's main thread nor its engine, nor VoiceOver's
        // speech (silent in TurnOver's apps): the only voice left.
        if Coexist.on, !sleeping { Self.sayOutside("TurnOver is not responding. If it doesn't recover, it restarts in twenty seconds.") }
    }

    /// The system's `say`, from any thread: the voice of last resort while the main thread is stuck. One at a time:
    /// a second warning while the first is still being said waits for it (they spoke over each other, 22 Oct 2026).
    nonisolated(unsafe) private static var saying: Process?
    nonisolated private static let sayLock = NSLock()
    nonisolated static func sayOutside(_ text: String) {
        sayLock.lock(); defer { sayLock.unlock() }
        if let s = saying, s.isRunning { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = [text]
        try? p.run()
        saying = p
    }
    nonisolated static func waitForSaying() {
        sayLock.lock(); let s = saying; sayLock.unlock()
        s?.waitUntilExit()
    }

    /// The speech queue stuck (SpeechPlayer.onQueueStuck): told with the system's voice, which needs nothing of
    /// TurnOver's, and TurnOver started afresh, as quitting and starting it did for a tester ().
    nonisolated func speechStuck(for seconds: TimeInterval) {
        // First a fresh speech player, in place of the stuck one: TurnOver keeps running and speaks again within a
        // second (19 Oct 2026). Only if that can't be done (the main thread stuck too, or no audio engine) is TurnOver
        // restarted, as before.
        // Built on a thread of its own: starting an audio engine is the kind of call that was stuck, and built on main
        // it stuck main too (98 s on 20 Oct 2026), so keys and the VoiceOver hand-back stopped with it. If the build
        // hangs, its thread is abandoned and TurnOver restarts; main stays free for the watchdog's other duties.
        if inGrace { Log.error("speech: the speech queue has not run for \(Int(seconds)) s, with the Mac asleep, locked or just awake: left to come back"); return }
        let rebuilt = Flag()
        guard let old = SpeechPlayer.current else { relaunch(stuckFor: seconds); return }
        let builder = Thread {
            do {
                let fresh = try old.freshCopy()
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    Speech.player = fresh
                    rebuilt.set()
                    Log.error("speech: the speech queue was stuck for \(Int(seconds)) s; a fresh speech player in its place")
                } }
            } catch { Log.error("speech: no fresh speech player (\(error)); restarting TurnOver") }
        }
        builder.name = "turnover.speech.rebuild"
        builder.start()
        Thread.sleep(forTimeInterval: 3)
        if rebuilt.isSet { return }
        Log.error("speech: the speech queue has not run for \(Int(seconds)) s; restarting TurnOver")
        Self.sayOutside("TurnOver's voice stopped. Restarting TurnOver.")
        Self.waitForSaying()   // said before the restart cuts it
        try? FileManager.default.createDirectory(at: AppPaths.file("restarting").deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: AppPaths.file("restarting").path, contents: nil)
        relaunch(stuckFor: seconds)
    }

    nonisolated private func relaunch(stuckFor: TimeInterval) {
        Log.error("watchdog: still stuck after \(Int(stuckFor)) s; relaunching TurnOver")
        // The new TurnOver is told which process it replaces, and ends it if it's still here; this one leaves with
        // _exit, which runs no exit handlers (an audio call in one hung, and the old TurnOver lived on beside the new:
        // a tester's echo of copies, 20 Oct 2026).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", Bundle.main.bundlePath, "--args", "--after-hang", "\(getpid())"]
        try? p.run()
        Thread.sleep(forTimeInterval: 0.5)
        _exit(3)
    }

    /// For testing the watchdog only: freezes the main thread, and only while the test file exists.
    func installTestHook() {
        let flag = AppPaths.file("allow-watchdog-test")
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.turnover.test.freeze"), object: nil, queue: .main) { _ in
            guard FileManager.default.fileExists(atPath: flag.path) else { return }
            Log.error("watchdog test: freezing the main thread for 8 s")
            Thread.sleep(forTimeInterval: 8)
        }
    }
}

/// A yes/no set on one thread and read on another.
nonisolated final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
