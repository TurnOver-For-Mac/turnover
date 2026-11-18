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
}
