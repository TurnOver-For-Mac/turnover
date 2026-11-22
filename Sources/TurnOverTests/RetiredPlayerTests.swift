// SPDX-License-Identifier: GPL-3.0-or-later
// A speech player the watchdog has replaced is retired (22 Nov 2026): kept alive, shut down, and inert afterwards.
// Tests run with AudioOutput.muted, so nothing is played; a real player is made only to hold the queue and flags.
import Foundation
import os
import TurnOverSpeech

private func makePlayer() -> SpeechPlayer? {
    guard let p = try? SpeechPlayer(voice: "com.apple.voice.compact.en-GB.Daniel") else {
        print("     (skipped: no audio output to start a player on)"); return nil
    }
    return p
}

/// Waits until the player's speech queue has run everything queued so far (a condition, not a fixed sleep).
private func drain(_ p: SpeechPlayer, timeout: TimeInterval = 5) -> Bool {
    let done = DispatchSemaphore(value: 0)
    p.afterQueueForTesting { done.signal() }
    return done.wait(timeout: .now() + timeout) == .success
}

func retiredPlayerTests() {
    test("retired player: stays alive after its last outside reference goes") {
        weak var weakPlayer: SpeechPlayer?
        do {
            guard let p = makePlayer() else { return }
            weakPlayer = p
            p.retire()
            check(drain(p), "the shut-down block ran")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check(weakPlayer != nil, "a retired player is never freed")
        check(weakPlayer?.isRetiredPlayer == true, "and says it is retired")
    }

    test("retired player: speech and cancels complete false and start no audio") {
        guard let p = makePlayer() else { return }
        let results = OSAllocatedUnfairLock<[String: Bool]>(initialState: [:])
        func speak(_ name: String, interrupt: Bool = true) {
            p.speak(name, interrupt: interrupt, completion: { @Sendable f in results.withLock { $0[name] = f } })
        }
        // One queued before the retirement, behind a blocked queue; it runs after the retirement.
        let release = DispatchSemaphore(value: 0)
        p.blockQueueForTesting(until: release)
        speak("before")
        p.retire()
        let calls = p.audioCalls.withLock { $0 }
        release.signal()
        check(drain(p), "the queue drained")
        speak("after"); speak("after2", interrupt: false)
        p.cancel(); p.cancel(source: "x"); p.playTone(frequency: 440, durationMs: 10); p.playBell(frequencies: [440], spacingMs: 10, ringMs: 10)
        p.pause(); p.resume(); p.outputDeviceUID = nil
        check(drain(p), "the queue drained again")
        let got = results.withLock { $0 }
        expect(got["before"], false, "queued before retirement: completed false")
        expect(got["after"], false, "after retirement: completed false")
        expect(got["after2"], false, "waiting after retirement: completed false")
        expect(p.audioCalls.withLock { $0 }, calls, "no play, engine start or synthesizer write after retirement")
    }

    test("retired player: retire is idempotent and returns at once while the queue is blocked") {
        guard let p = makePlayer() else { return }
        let release = DispatchSemaphore(value: 0)
        p.blockQueueForTesting(until: release)
        let logged = OSAllocatedUnfairLock<Int>(initialState: 0)
        p.onOutputChange = { @Sendable line in if line.contains("retired") { logged.withLock { $0 += 1 } } }
        let began = Date()
        p.retire(); p.retire()
        check(Date().timeIntervalSince(began) < 1, "retire did not wait for the blocked queue")
        check(p.isRetiredPlayer, "flag is readable without the queue")
        expect(logged.withLock { $0 }, 1, "one log line, however often it is called")
        release.signal()
        check(drain(p), "shut-down ran once the queue was free")
        p.retire()
        expect(logged.withLock { $0 }, 1, "still one line")
    }

    test("retired player: no stuck, silent, unavailable or first-audio callbacks") {
        guard let p = makePlayer() else { return }
        let fired = OSAllocatedUnfairLock<[String]>(initialState: [])
        p.onFirstAudio = { _ in fired.withLock { $0.append("firstAudio") } }
        p.onVoiceSilent = { _ in fired.withLock { $0.append("voiceSilent") } }
        p.onOutputUnavailable = { @Sendable _, _ in fired.withLock { $0.append("unavailable") } }
        p.onQueueStuck = { @Sendable _ in fired.withLock { $0.append("stuck") }; return true }
        p.monitorRequiredOutput(true)
        p.retire()
        for i in 0..<3 { p.speak("word \(i)", interrupt: true); p.cancel() }
        check(drain(p), "the queue drained")
        expect(fired.withLock { $0 }, [], "nothing reported by a retired player")
    }
}
