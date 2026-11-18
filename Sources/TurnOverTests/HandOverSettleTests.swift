// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

/// An app switch hands over only once nothing is moving, and then for the app in front (18 Nov 2026). The standings
/// are written by hand from the log of 18 Nov 2026, 07:32; no test touches VoiceOver or the keyboard. Logic evidence only.
func handOverSettleTests() {
    typealias S = HandOverSettle.Standing
    let calm = S(commandHeld: false, handOverUnderWay: false, voiceOverSettled: true, sinceLastHandOver: 30)

    test("hand-over settle: a single switch with nothing moving decides at once, as before") {
        expect(HandOverSettle.decide(calm, waited: 0), .decideNow)
        expect(HandOverSettle.moving(calm), nil)
    }
    test("hand-over settle: each thing still moving makes the check wait") {
        var s = calm; s.commandHeld = true
        expect(HandOverSettle.decide(s, waited: 0), .wait, "Command held: the switcher may be open")
        s = calm; s.handOverUnderWay = true
        expect(HandOverSettle.decide(s, waited: 0), .wait, "a hand-over has not had its answer")
        s = calm; s.voiceOverSettled = false
        expect(HandOverSettle.decide(s, waited: 0), .wait, "VoiceOver still stopping")
        s = calm; s.sinceLastHandOver = 1.0
        expect(HandOverSettle.decide(s, waited: 0), .wait, "the old 1.5 s spacing stays")
    }
    test("hand-over settle: past the limit it decides anyway, unless Command is still held") {
        var s = calm; s.voiceOverSettled = false
        expect(HandOverSettle.decide(s, waited: HandOverSettle.limit), .decideNow, "a VoiceOver flag on with no VoiceOver is the hand-over's to deal with")
        s = calm; s.commandHeld = true
        expect(HandOverSettle.decide(s, waited: HandOverSettle.limit), .giveUp, "the switch on release decides")
    }
    test("hand-over settle: 18 Nov 07:32, Safari after Claude waits for VoiceOver to go, then decides once") {
        // 07:32:16.49 the hand-over to TurnOver for Claude; the flag off at 16.69, VoiceOver's process gone at 19.98.
        // 07:32:17.88 Safari activated. Before, a check 1.6 s later handed over at once; now it waits for the process.
        let timeline: [(at: Double, s: S)] = [
            (17.88, S(commandHeld: false, handOverUnderWay: false, voiceOverSettled: false, sinceLastHandOver: 1.39)),
            (19.48, S(commandHeld: false, handOverUnderWay: false, voiceOverSettled: false, sinceLastHandOver: 2.99)),
            (19.99, S(commandHeld: false, handOverUnderWay: false, voiceOverSettled: true, sinceLastHandOver: 3.50)),
        ]
        let decisions = timeline.map { HandOverSettle.decide($0.s, waited: $0.at - 17.88) }
        expect(decisions, [.wait, .wait, .decideNow])
    }
    test("hand-over settle: 18 Nov 07:32:22.7, Command Tab pressed again while a hand-over runs: nothing until it is let go") {
        // The hand-over for Claude posted at 21.86; Command Tab at 22.70; Safari in front at 23.40, VoiceOver's process
        // still going (the hand-over then gave up: "VoiceOver still changing after 2 s; not toggled", 25.41).
        let held = S(commandHeld: true, handOverUnderWay: false, voiceOverSettled: false, sinceLastHandOver: 0.84)
        let released = S(commandHeld: false, handOverUnderWay: false, voiceOverSettled: false, sinceLastHandOver: 1.54)
        let gone = S(commandHeld: false, handOverUnderWay: false, voiceOverSettled: true, sinceLastHandOver: 3.60)
        expect(HandOverSettle.decide(held, waited: 0), .wait)
        expect(HandOverSettle.decide(released, waited: 0.7), .wait, "no toggle into a VoiceOver still stopping")
        expect(HandOverSettle.decide(gone, waited: 2.8), .decideNow, "decided once, for the app in front then")
    }
}
