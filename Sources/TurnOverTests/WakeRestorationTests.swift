// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

func wakeRestorationTests() {
    typealias Recovery = WakeRestoration
    func readiness(locked: Bool = false, secure: Bool = false, foreground: Bool = true,
                   suspended: Bool = false, input: Bool = true, coexist: Bool = false,
                   appSwitching: Bool = false, voiceOverReady: Bool = true) -> Recovery.Readiness {
        .init(locked: locked, secureInput: secure, ordinaryForeground: foreground, suspended: suspended,
              inputGranted: input, coexisting: coexist, automaticAppSwitching: appSwitching, voiceOverReady: voiceOverReady)
    }
    func lockedReader() -> Recovery {
        var state = Recovery()
        state.lock(readerWasActive: true, voiceOverAlreadyOn: false, suspended: false)
        return state
    }

    test("wake restoration: delayed foreground readiness keeps VoiceOver until an ordinary app arrives") {
        var state = lockedReader()
        for now in [1.0, 10.0, 11.0, 30.0, 120.0] {
            check(state.beginAttempt(readiness: readiness(foreground: false), now: now) == nil,
                  "elapsed waiting never makes a missing or nonregular foreground safe")
        }
        check(state.pending, "late foreground does not lose lock-owned intent")
        expect(state.attempts, 0, "waiting consumes no handover attempts")
        check(state.beginAttempt(readiness: readiness(), now: 121) != nil,
              "a later app activation can resume restoration")
    }
    test("wake restoration: secure input and lost permissions keep the existing reader") {
        var state = lockedReader()
        let unsafe = [readiness(locked: true), readiness(secure: true), readiness(input: false),
                      readiness(suspended: true), readiness(coexist: true), readiness(appSwitching: true)]
        for input in unsafe {
            check(!input.canRestore, "the same readiness gate used by deferred handovers refuses unsafe input")
            check(state.beginAttempt(readiness: input, now: 30) == nil, "no off request while readiness is missing")
        }
        expect(state.attempts, 0)
        check(state.beginAttempt(readiness: readiness(), now: 31) != nil, "readiness recovery permits the first attempt")
    }
    test("wake restoration: slow VoiceOver startup does not spend restoration attempts") {
        var state = lockedReader()
        state.observedVoiceOverOn()
        for now in [1.0, 3.0, 8.0, 12.0, 20.0, 35.0] {
            check(state.beginAttempt(readiness: readiness(voiceOverReady: false), now: now) == nil,
                  "an enabled flag without a running VoiceOver process is still startup")
        }
        expect(state.attempts, 0, "slow startup does not exhaust the retry allowance")
        guard let attempt = state.beginAttempt(readiness: readiness(), now: 36) else { return Harness.fail("settled VoiceOver may restore") }
        check(readiness(voiceOverReady: false).canRestore,
              "after the off toggle, loss of the on state must not invalidate observation of success")
        state.finishAttempt(attempt, succeeded: true, now: 37)
        check(!state.pending, "successful restoration completes normally")
    }
    test("wake restoration: failed settling retains intent and retries without overlap") {
        var state = lockedReader()
        guard let first = state.beginAttempt(readiness: readiness(), now: 1) else { return Harness.fail("initial attempt") }
        check(state.pending && state.inFlight, "requesting handover does not count as success")
        check(state.beginAttempt(readiness: readiness(), now: 20) == nil, "no overlap even after a long request")
        state.finishAttempt(first, succeeded: false, now: 20)
        check(state.pending && !state.inFlight, "aborted settling retains ownership")
        check(state.beginAttempt(readiness: readiness(), now: 20.49) == nil, "retry has a quiet interval")
        guard let retry = state.beginAttempt(readiness: readiness(), now: 20.5) else { return Harness.fail("retry admitted") }
        check(state.isCurrent(retry), "retry owns the pending handover")
        check(!state.isCurrent(first), "earlier callback cannot complete the retry")
        state.finishAttempt(first, succeeded: true, now: 21)
        check(state.pending && state.isCurrent(retry), "late success from an earlier attempt cannot erase current work")
        state.finishAttempt(retry, succeeded: true, now: 21)
        check(!state.pending && !state.inFlight, "observed off-state completes restoration")
        check(state.beginAttempt(readiness: readiness(), now: 22) == nil, "success does not toggle the reader again")
    }
    test("wake restoration: persistent failure has a bounded attempt count") {
        var state = lockedReader()
        for index in 0..<3 {
            let now = Double(index * 10)
            guard let attempt = state.beginAttempt(readiness: readiness(), now: now) else { return Harness.fail("attempt \(index + 1)") }
            state.finishAttempt(attempt, succeeded: false, now: now + 2)
        }
        check(state.pending, "failure never claims successful restoration")
        check(state.beginAttempt(readiness: readiness(), now: 1000) == nil, "later activations cannot create an endless retry loop")
        expect(state.attempts, 3)
        state.lock(readerWasActive: false, voiceOverAlreadyOn: true, suspended: false)
        check(state.beginAttempt(readiness: readiness(), now: 1001) != nil, "a new lock cycle has its own bounded allowance")
    }
    test("wake restoration: another lock retires callbacks while preserving owned VoiceOver") {
        var state = lockedReader()
        guard let old = state.beginAttempt(readiness: readiness(), now: 1) else { return Harness.fail("initial attempt") }
        // A second lock happens while VoiceOver is still on and TurnOver is quiet.
        state.lock(readerWasActive: false, voiceOverAlreadyOn: true, suspended: false)
        check(!state.isCurrent(old), "old off request must stop before it posts a toggle")
        check(state.pending, "the next unlock still owns VoiceOver enabled by the first lock")
        state.finishAttempt(old, succeeded: true, now: 2)
        check(state.pending, "stale completion cannot clear the new cycle")
        check(state.beginAttempt(readiness: readiness(locked: true), now: 3) == nil, "still locked")
        check(state.beginAttempt(readiness: readiness(), now: 4) != nil, "next actual unlock may restore")
    }
    test("wake restoration: user-selected VoiceOver and suspended TurnOver never create ownership") {
        var userVoiceOver = Recovery()
        userVoiceOver.lock(readerWasActive: false, voiceOverAlreadyOn: true, suspended: false)
        userVoiceOver.lock(readerWasActive: false, voiceOverAlreadyOn: true, suspended: false)
        check(!userVoiceOver.pending, "duplicate lock notices do not claim the user's reader")
        check(userVoiceOver.beginAttempt(readiness: readiness(), now: 30) == nil, "user VoiceOver remains on")
        var stopped = Recovery()
        stopped.lock(readerWasActive: true, voiceOverAlreadyOn: false, suspended: true)
        check(!stopped.pending, "TurnOver switched off by its key has no restoration claim")
    }
    test("wake restoration: a deliberate reader choice cancels in-flight and queued retry work") {
        var state = lockedReader()
        guard let attempt = state.beginAttempt(readiness: readiness(), now: 1) else { return Harness.fail("initial attempt") }
        state.cancel()
        check(!state.isCurrent(attempt), "deferred toggle checks the retired token")
        state.finishAttempt(attempt, succeeded: false, now: 3)
        check(state.beginAttempt(readiness: readiness(), now: 4) == nil, "late failure cannot resurrect user-cancelled work")
        state.lock(readerWasActive: false, voiceOverAlreadyOn: true, suspended: false)
        check(!state.pending, "the next lock does not acquire already-on user VoiceOver")
    }
    test("wake restoration: a slow lock-screen start remains owned until VoiceOver actually arrives") {
        var state = lockedReader()
        check(state.pending && !state.voiceOverWasObservedOn,
              "an initial off snapshot cannot prove that an asynchronous lock-screen start has finished")
        // macOS may finish opening VoiceOver after the first wake watch has ended.
        state.observedVoiceOverOn()
        check(state.pending && state.voiceOverWasObservedOn, "late owned startup can still be restored")
        guard let attempt = state.beginAttempt(readiness: readiness(), now: 45) else { return Harness.fail("late startup restoration") }
        state.finishAttempt(attempt, succeeded: true, now: 46)
        check(!state.pending && !state.voiceOverWasObservedOn, "observed off completes this startup's ownership")
    }
    test("wake restoration: a new lock with VoiceOver off must observe its fresh start") {
        var state = lockedReader()
        state.observedVoiceOverOn()
        // The first restoration has just posted off, but a fresh lock arrives before its completion.
        guard let old = state.beginAttempt(readiness: readiness(), now: 1) else { return Harness.fail("first cycle") }
        state.lock(readerWasActive: false, voiceOverAlreadyOn: false, suspended: false)
        check(state.pending && !state.voiceOverWasObservedOn,
              "the previous cycle's on state is not evidence that the new asynchronous start completed")
        state.finishAttempt(old, succeeded: true, now: 2)
        check(state.pending, "the first cycle cannot complete the next lock's restoration")
        state.observedVoiceOverOn()
        state.lock(readerWasActive: false, voiceOverAlreadyOn: true, suspended: false)
        check(state.pending && state.voiceOverWasObservedOn, "duplicate notices retain ownership of an actually on reader")
    }
    test("wake restoration: a cancelled lock start cannot claim a later VoiceOver choice") {
        var state = lockedReader()
        state.cancel()
        state.observedVoiceOverOn()
        check(!state.pending && !state.voiceOverWasObservedOn, "a later on notice does not recreate cancelled ownership")
        check(state.beginAttempt(readiness: readiness(), now: 45) == nil, "no wake off-toggle overrides the new choice")
    }
    test("wake restoration: observing VoiceOver off retires all remaining callbacks") {
        var state = lockedReader()
        guard let attempt = state.beginAttempt(readiness: readiness(), now: 1) else { return Harness.fail("initial attempt") }
        state.observedVoiceOverOff()
        check(!state.pending && !state.isCurrent(attempt), "actual off notification ends the lock's ownership")
        state.finishAttempt(attempt, succeeded: false, now: 2)
        check(state.beginAttempt(readiness: readiness(), now: 3) == nil, "a late failure cannot turn a success into another toggle")
    }
}
