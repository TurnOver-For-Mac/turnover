// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

/// The person's own VoiceOver toggle wins over TurnOver's hand-over and its own start (Codex's second review, 18 Nov
/// 2026). The rules the app calls are driven with a given clock; the key tap, VoiceOver and the lead watcher's pins are
/// not driven here. Logic evidence only.
func voiceOverChangeOriginTests() {
    test("change origin: Oliver turns VoiceOver off 1 s after an automatic hand-over turned it on: his, so it is pinned") {
        // Before, any change within 3 s was the hand-over's: no pin, and its own check after it turned VoiceOver on again.
        check(!HandOverOwnership.isHandOvers(on: false, wanted: true, windowOpen: true, secondToggle: false, byPerson: false),
              "the other way from the hand-over: the person's")
        check(HandOverOwnership.isHandOvers(on: true, wanted: true, windowOpen: true, secondToggle: false, byPerson: false),
              "the way it asked for, inside its window: the hand-over's own, as before")
    }
    test("change origin: a hand-over's second toggle may bring either change; the person's press heard still wins") {
        check(HandOverOwnership.isHandOvers(on: true, wanted: false, windowOpen: true, secondToggle: true, byPerson: false),
              "a late first toggle and the second (8 Oct 2026): still the hand-over's")
        check(!HandOverOwnership.isHandOvers(on: false, wanted: false, windowOpen: true, secondToggle: false, byPerson: true),
              "his key heard: his, even the way the hand-over asked")
        check(!HandOverOwnership.isHandOvers(on: true, wanted: true, windowOpen: false, secondToggle: false, byPerson: false),
              "after the window: the person's")
        check(!HandOverOwnership.isHandOvers(on: true, wanted: nil, windowOpen: true, secondToggle: false, byPerson: false),
              "nothing asked for: the person's")
    }
    test("change origin: Oliver's Option-quote while TurnOver's own start is outstanding is his, not the record's") {
        let keys = PersonVoiceOverToggle()
        keys.listening(true, now: 100)
        keys.pressed(now: 110.0)
        let person = keys.take(now: 110.15)   // VoiceOver on, 150 ms after his press
        expect(person, .person)
        check(!OwnVoiceOverStart.isOwnStart(.ours, person: person), "the outstanding record does not claim his toggle")
        expect(keys.take(now: 111), .notPerson, "a press answers for one change only")
    }
    test("change origin: the watchdog's start, keys heard all the while and no press: TurnOver's own, no pin") {
        // 17 Nov 2026, 10:16: the restarted TurnOver's tap was up at 0.37 s, VoiceOver came about 4 s after it started.
        let keys = PersonVoiceOverToggle()
        keys.listening(true, now: 0.366)
        let person = keys.take(now: 4.1)
        expect(person, .notPerson)
        check(OwnVoiceOverStart.isOwnStart(.ours, person: person), "TurnOver's own start")
    }
    test("change origin: keys not heard long enough to know: taken as the person's, never overridden on a guess") {
        let keys = PersonVoiceOverToggle()
        expect(keys.take(now: 50), .unheard, "no tap at all")
        keys.listening(true, now: 49.5)
        expect(keys.take(now: 50), .unheard, "up only half a second")
        check(!OwnVoiceOverStart.isOwnStart(.ours, person: .unheard), "so the record does not claim it")
        keys.listening(false, now: 60)
        expect(keys.take(now: 70), .unheard, "the tap gone (TurnOver handed the keys to VoiceOver)")
        keys.pressed(now: 80)
        expect(keys.take(now: 83), .unheard, "a press too long before is no evidence")
    }
    // Codex's third review (18 Nov 2026).
    test("change origin: Oliver's off 1 s after a hand-over, within the watchdog's 30 s grace, is known to be his") {
        check(HandOverOwnership.isKnownPersons(on: false, wanted: true, windowOpen: true, secondToggle: false, byPerson: false),
              "against the hand-over's change: his, so it is pinned even inside the grace")
        check(HandOverOwnership.isKnownPersons(on: true, wanted: nil, windowOpen: false, secondToggle: false, byPerson: true),
              "his key heard: his")
        check(!HandOverOwnership.isKnownPersons(on: true, wanted: false, windowOpen: false, secondToggle: false, byPerson: false),
              "outside any window with no key heard: not known, so the grace still covers the watchdog's own VoiceOver")
        check(!HandOverOwnership.isKnownPersons(on: true, wanted: false, windowOpen: true, secondToggle: true, byPerson: false),
              "a hand-over's second toggle may bring it: not known")
        check(!HandOverOwnership.isKnownPersons(on: true, wanted: true, windowOpen: true, secondToggle: false, byPerson: false),
              "the hand-over's own change: not his")
    }
    test("change origin: a hand-over begun before Oliver's own choice goes no further, so its fallback never opens VoiceOver") {
        check(HandOverOwnership.mayGoOn(shutdownBegun: false, manualChoiceAtStart: 3, manualChoiceNow: 3), "nothing since: it goes on")
        check(!HandOverOwnership.mayGoOn(shutdownBegun: false, manualChoiceAtStart: 3, manualChoiceNow: 4),
              "his choice since it began: its waits stop before the VoiceOver.app fallback")
        check(!HandOverOwnership.mayGoOn(shutdownBegun: true, manualChoiceAtStart: 3, manualChoiceNow: 3), "quitting: it stops")
    }
    test("change origin: presses noted from another thread are taken whole") {
        let keys = PersonVoiceOverToggle()
        keys.listening(true, now: 0)
        DispatchQueue.concurrentPerform(iterations: 200) { i in keys.pressed(now: 100 + Double(i) / 1000) }
        expect(keys.take(now: 100.5), .person)
        expect(keys.take(now: 100.6), .notPerson, "taken once")
    }
    // Codex's fourth review (18 Nov 2026): secure input hides keys, the toggle included.
    test("change origin: Oliver's toggle in a password field after a watchdog restart stays his") {
        let keys = PersonVoiceOverToggle()
        keys.listening(true, now: 0.37)   // the restarted TurnOver's tap, up for seconds
        keys.secureInputSeen(true, now: 3.0)   // a password field: secure input on, his press unheard
        let person = keys.take(now: 4.1)
        expect(person, .unheard, "the tap could not hear: not TurnOver's")
        check(!OwnVoiceOverStart.isOwnStart(.ours, person: person), "the outstanding recovery does not claim it")
    }
    test("change origin: secure input on as the change comes, or within the window before it, is not heard") {
        let keys = PersonVoiceOverToggle()
        keys.listening(true, now: 0)
        expect(keys.take(now: 10, secureInputNow: true), .unheard, "on at the report, between the app's looks")
        keys.secureInputSeen(true, now: 10)
        keys.secureInputSeen(false, now: 10.25)   // off again
        expect(keys.take(now: 11), .unheard, "on for part of the 2 s before")
        expect(keys.take(now: 12.3), .notPerson, "heard for the whole window since")
    }
    // 19 Nov 2026: the app's looks stop when TurnOver stops reading; an "on" they last saw is cleared by the next change.
    test("change origin: secure input last seen on, with no look since, is unheard once and then cleared") {
        let keys = PersonVoiceOverToggle()
        keys.listening(true, now: 0)
        keys.secureInputSeen(true, now: 5)   // the last look before TurnOver stopped reading
        expect(keys.take(now: 60), .unheard, "off now, but when it went off is not known")
        expect(keys.take(now: 61), .unheard, "within the window of that")
        expect(keys.take(now: 63), .notPerson, "heard for the whole window since")
        expect(keys.take(now: 70, secureInputNow: true), .unheard, "on at the report, with no look")
        expect(keys.take(now: 75), .unheard, "on at the last report: when it went off is not known")
        expect(keys.take(now: 78), .notPerson)
    }
    // 19 Nov 2026: the watcher's look is what records secure input; the app's toggle is the one it records into.
    test("change origin: the secure-input look the watcher calls records secure input for the classifier") {
        let keys = PersonVoiceOverToggle()
        keys.listening(true, now: 0)
        SecureInputWatch.noteLook(on: true, toggle: keys, now: 3.0)
        SecureInputWatch.noteLook(on: false, toggle: keys, now: 3.5)   // over before the change is handled
        expect(keys.take(now: 4.1), .unheard, "a toggle in a password field is not TurnOver's own start")
    }
}
