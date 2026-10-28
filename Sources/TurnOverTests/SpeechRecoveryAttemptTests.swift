// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os
import TurnOverSpeech

nonisolated private final class RecoveryCandidate: Sendable {
    let onDiscard: @Sendable (Bool, String?) -> Void
    init(onDiscard: @escaping @Sendable (Bool, String?) -> Void) { self.onDiscard = onDiscard }
    deinit { onDiscard(Thread.isMainThread, Thread.current.name) }
}

func speechRecoveryAttemptTests() {
    test("speech recovery: a timely replacement installs exactly once") {
        let now = ContinuousClock.now
        let attempt = SpeechRecoveryAttempt<Int>(deadline: now.advanced(by: .seconds(3)))
        check(attempt.offer(1, at: now), "builder supplied its replacement")
        expect(attempt.takeForInstallation(at: now.advanced(by: .seconds(1))), 1)
        expect(attempt.takeForInstallation(at: now.advanced(by: .seconds(2))), nil)
        attempt.expire()
        check(attempt.installed, "deadline cannot undo an installation")
        expect(attempt.discard(), nil, "the installed candidate belongs to main")
    }

    test("speech recovery: a late builder cannot replace a player during restart") {
        let now = ContinuousClock.now
        let attempt = SpeechRecoveryAttempt<Int>(deadline: now.advanced(by: .seconds(3)))
        attempt.expire()
        check(!attempt.offer(1, at: now.advanced(by: .seconds(1))), "expired attempt rejects even an early result")
        expect(attempt.takeForInstallation(at: now.advanced(by: .seconds(1))), nil)
        check(!attempt.installed, "fallback keeps ownership")
    }

    test("speech recovery: deadline rejects an installation even before watchdog checks it") {
        let now = ContinuousClock.now
        let deadline = now.advanced(by: .seconds(3))
        let attempt = SpeechRecoveryAttempt<Int>(deadline: deadline)
        check(attempt.offer(1, at: now), "replacement is waiting for main")
        expect(attempt.takeForInstallation(at: deadline), nil, "the deadline itself is expired")
        check(!attempt.installed, "late main callback did not install")
        attempt.expire()
        expect(attempt.discard(), 1, "watchdog can dispose of the unused replacement off main")
        expect(attempt.discard(), nil, "disposal transfers ownership only once")
    }

    test("speech recovery: recovery or renewed sleep cancels a queued replacement") {
        let now = ContinuousClock.now
        let attempt = SpeechRecoveryAttempt<Int>(deadline: now.advanced(by: .seconds(3)))
        check(attempt.offer(1, at: now), "replacement was built")
        attempt.expire()
        expect(attempt.takeForInstallation(at: now.advanced(by: .seconds(1))), nil)
        expect(attempt.discard(), 1, "cancelled candidate stays with the watchdog")
    }

    test("speech recovery: unused candidates are disposed away from main and the recovery watcher") {
        let attempt = SpeechRecoveryAttempt<RecoveryCandidate>()
        let finished = DispatchSemaphore(value: 0)
        let observed = OSAllocatedUnfairLock<(Bool, String?)?>(initialState: nil)
        check(attempt.offer(RecoveryCandidate { onMain, name in
            observed.withLock { $0 = (onMain, name) }
            finished.signal()
        }), "candidate is owned only by the attempt")
        attempt.expire()
        attempt.discardOffThread()
        check(finished.wait(timeout: .now() + 3) == .success, "disposal completes without running the main loop")
        expect(observed.withLock { $0?.0 }, false)
        expect(observed.withLock { $0?.1 }, "turnover.speech.discard")
    }

    test("speech recovery: competing installation and expiry keep a single candidate owner") {
        for _ in 0..<32 {
            let now = ContinuousClock.now
            let attempt = SpeechRecoveryAttempt<Int>(deadline: now.advanced(by: .seconds(30)))
            check(attempt.offer(1, at: now), "candidate offered")
            let installed = OSAllocatedUnfairLock(initialState: 0)
            DispatchQueue.concurrentPerform(iterations: 8) { index in
                if index % 2 == 0 { attempt.expire() }
                else if attempt.takeForInstallation(at: now) != nil { installed.withLock { $0 += 1 } }
            }
            let count = installed.withLock { $0 }
            check(count <= 1, "only one callback can install")
            expect(attempt.installed, count == 1)
            expect(attempt.discard(), count == 1 ? nil : 1, "exactly one thread owns final disposal")
        }
    }
}
