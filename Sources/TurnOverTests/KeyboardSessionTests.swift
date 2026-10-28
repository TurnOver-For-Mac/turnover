// SPDX-License-Identifier: GPL-3.0-or-later
import TurnOverCore
import Foundation

func keyboardSessionTests() {
    test("keyboard permission recovery: automatic VoiceOver restoration permits permission-grant retry") {
        let activation = KeyboardActivation()
        var worker = KeyboardSessionState()
        let denied = worker.requestStart()
        _ = worker.beginWorker()
        activation.begin(denied)
        let now = Date(timeIntervalSince1970: 100)
        // Permission fallback opens VoiceOver, then deactivates. That cancellation must retain ownership of
        // its pending notification, rather than saving the automatic recovery as a manual VoiceOver choice.
        activation.expectAutomaticVoiceOverRestore(readerChoice: 7, now: now)
        activation.cancel()
        worker.requestStop()
        worker.finished(denied)
        let automatic = activation.takeAutomaticVoiceOverRestore(on: true, readerChoice: 7, now: now.addingTimeInterval(1))
        check(automatic, "automatic restore is acknowledged after deactivation")
        var yieldedByHand = false
        if !automatic { yieldedByHand = true }
        check(!yieldedByHand, "permission recovery must not block the lead policy as a manual choice")
        let retry = worker.requestStart()   // the permission watch observes the grant
        activation.begin(retry)
        _ = worker.beginWorker()
        worker.report(retry, ready: true)
        check(activation.confirm(retry, inputReady: worker.isReady(retry)), "grant can complete a fresh activation")
        check(!activation.takeAutomaticVoiceOverRestore(on: true, readerChoice: 7, now: now.addingTimeInterval(2)), "only one on-notification belongs to recovery")
    }
    test("keyboard permission recovery: off and explicit reader selections preserve later manual intent") {
        let activation = KeyboardActivation()
        let now = Date(timeIntervalSince1970: 100)
        activation.expectAutomaticVoiceOverRestore(readerChoice: 7, now: now)
        check(!activation.takeAutomaticVoiceOverRestore(on: false, readerChoice: 7, now: now.addingTimeInterval(1)), "off is never an automatic restore")
        check(!activation.takeAutomaticVoiceOverRestore(on: true, readerChoice: 7, now: now.addingTimeInterval(2)), "on after an intervening off is manual")
        activation.expectAutomaticVoiceOverRestore(readerChoice: 8, now: now)
        activation.readerSelected()   // menu choices clear ownership before their delayed handover runs
        check(!activation.takeAutomaticVoiceOverRestore(on: true, readerChoice: 8, now: now.addingTimeInterval(1)), "a menu selection is not suppressed")
        activation.expectAutomaticVoiceOverRestore(readerChoice: 9, now: now)
        check(!activation.takeAutomaticVoiceOverRestore(on: true, readerChoice: 10, now: now.addingTimeInterval(1)), "a newer reader-choice generation invalidates recovery ownership")
        activation.expectAutomaticVoiceOverRestore(readerChoice: 11, now: now)
        activation.begin(2)
        check(!activation.takeAutomaticVoiceOverRestore(on: true, readerChoice: 11, now: now.addingTimeInterval(1)), "a new activation also clears the old restore")
    }
    test("keyboard permission recovery: notification ownership expires and can be renewed after revocation") {
        let activation = KeyboardActivation()
        let now = Date(timeIntervalSince1970: 100)
        activation.expectAutomaticVoiceOverRestore(readerChoice: 1, now: now)
        check(!activation.takeAutomaticVoiceOverRestore(on: true, readerChoice: 1, now: now.addingTimeInterval(5)), "a late manual on must not be suppressed indefinitely")
        activation.expectAutomaticVoiceOverRestore(readerChoice: 2, now: now.addingTimeInterval(20))
        check(activation.takeAutomaticVoiceOverRestore(on: true, readerChoice: 2, now: now.addingTimeInterval(21)), "revoked permission can establish fresh recovery ownership")
        check(!activation.takeAutomaticVoiceOverRestore(on: true, readerChoice: 2, now: now.addingTimeInterval(22)), "a second on remains a manual choice")
    }
    test("keyboard activation: VoiceOver on with swap off cancels pending takeover and permits a fresh resume") {
        var worker = KeyboardSessionState()
        let activation = KeyboardActivation()
        let old = worker.requestStart()
        _ = worker.beginWorker()
        activation.begin(old)
        check(activation.yieldToVoiceOver(), "VoiceOver can hold a pending activation before it is active")
        worker.requestStop()
        check(!worker.report(old, ready: true), "old setup cannot revive the choice cancelled by VoiceOver")
        check(!activation.confirm(old, inputReady: true), "an enabled old tap cannot activate the main reader")
        worker.finished(old)
        let next = worker.requestStart()   // VoiceOver goes off again while TurnOver was held
        activation.begin(next)
        _ = worker.beginWorker()
        worker.report(next, ready: true)
        check(activation.confirm(next, inputReady: worker.isReady(next)), "fresh resume can take over")
        check(activation.isActive, "only the new reader becomes active")
    }
    test("keyboard activation: tap loss during core setup prevents takeover") {
        var worker = KeyboardSessionState()
        let activation = KeyboardActivation()
        let request = worker.requestStart()
        _ = worker.beginWorker()
        activation.begin(request)
        worker.report(request, ready: true)
        check(worker.isReady(request), "core setup can begin")
        worker.report(request, ready: false)
        check(!activation.confirm(request, inputReady: worker.isReady(request)), "main must not mute VoiceOver after tap loss")
        check(!activation.isActive, "reader has not taken over")
        activation.cancel()
    }
    test("keyboard activation: cancelled callback cannot affect a newer takeover") {
        let activation = KeyboardActivation()
        activation.begin(1)
        activation.cancel()
        activation.begin(2)
        check(!activation.confirm(1, inputReady: true), "late ready callback is rejected")
        check(!activation.confirm(2, inputReady: false), "new setup still needs input")
        check(activation.confirm(2, inputReady: true), "new setup can complete")
        check(!activation.confirm(2, inputReady: true), "duplicate callback does not activate core twice")
        check(activation.yieldToVoiceOver(), "VoiceOver can also cancel an active reader")
        check(!activation.isActive && !activation.isRequested, "both states are retired")
    }
    test("keyboard readiness: successful tap setup is required") {
        var state = KeyboardSessionState()
        let request = state.requestStart()
        check(!state.isReady(request), "requesting input does not establish readiness")
        expect(state.beginWorker(), request)
        check(!state.isReady(request), "a running setup worker is still not ready")
        check(state.report(request, ready: true), "current setup accepted")
        check(state.isReady(request), "successful setup permits takeover")
    }
    test("keyboard readiness: denied setup cannot leave a ready request") {
        var state = KeyboardSessionState()
        let request = state.requestStart()
        _ = state.beginWorker()
        check(state.report(request, ready: false), "failure delivered for the current request")
        check(!state.isReady(request), "failed tap must not mute VoiceOver")
        check(state.requested == nil, "failure retires automatic activation")
        check(!state.report(request, ready: true), "late success cannot revive failed setup")
    }
    test("keyboard readiness: stop before setup completes rejects its late result") {
        var state = KeyboardSessionState()
        let request = state.requestStart()
        _ = state.beginWorker()
        state.requestStop()   // no run loop has been published yet
        check(!state.isRequested(request), "stop works even before the worker has a run loop")
        check(!state.report(request, ready: true), "cancelled setup cannot acknowledge readiness")
        check(state.beginWorker() == nil, "no replacement without a fresh request")
        state.finished(request)
        check(state.worker == nil && state.requested == nil, "cancelled worker tears down once")
    }
    test("keyboard readiness: rapid restart waits for old teardown") {
        var state = KeyboardSessionState()
        let old = state.requestStart()
        _ = state.beginWorker()
        state.requestStop()
        let next = state.requestStart()
        check(next != old, "new activation gets a new identity")
        check(state.beginWorker() == nil, "two taps must not run together")
        check(!state.report(old, ready: true), "old setup cannot take over the new request")
        state.finished(old)
        expect(state.beginWorker(), next, "replacement starts only after teardown")
        check(state.report(next, ready: true) && state.isReady(next), "replacement can become ready")
        check(!state.finished(old), "duplicate old completion cannot tear down replacement")
        check(state.isReady(next), "replacement readiness survives stale completion")
    }
    test("keyboard readiness: failed re-enable withdraws readiness immediately") {
        var state = KeyboardSessionState()
        let request = state.requestStart()
        _ = state.beginWorker()
        state.report(request, ready: true)
        check(state.report(request, ready: false), "current health failure accepted")
        check(!state.isReady(request) && !state.isRequested(request), "keys pass while main handles fallback")
        state.finished(request)
        check(state.beginWorker() == nil, "failed input never automatically restarts")
    }
    test("keyboard readiness: repeated start shares its pending worker") {
        var state = KeyboardSessionState()
        let request = state.requestStart()
        expect(state.beginWorker(), request)
        expect(state.requestStart(), request)
        check(state.beginWorker() == nil, "duplicate start does not create another worker")
        state.report(request, ready: true)
        state.requestStop()
        check(!state.isReady(request), "deactivation rejects an already queued ready callback")
    }
    test("keyboard readiness: unexpected worker exit cannot keep input ready") {
        var state = KeyboardSessionState()
        let request = state.requestStart()
        _ = state.beginWorker()
        state.report(request, ready: true)
        state.finished(request)
        check(!state.isReady(request) && state.requested == nil, "a departed worker cannot authorize takeover")
    }
}
