// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

/// Secure input left on outside a password field hands the keys to VoiceOver (17 Nov 2026). The clock and the "secure
/// input on" reader are injected: no test touches the Mac's own secure input. Logic evidence only.
func secureInputHandOverTests() {
    final class Rig {
        var t: TimeInterval = 100
        var secure = false
        var handOvers = 0
        var handBacks = 0
        var standDowns: [SecureInputHandOver.StandDown] = []
        lazy var machine = SecureInputHandOver(secureInputOn: { [unowned self] in self.secure }, now: { [unowned self] in self.t })

        /// Looks four a second while TurnOver reads, for `seconds`; a hand-over is answered at once with `voiceOverCame`.
        func reading(_ seconds: TimeInterval, inPassword: Bool = false, may: Bool = true, voiceOverCame: Bool = true) {
            for _ in 0..<Int(seconds * 4) {
                t += 0.25
                if machine.lookWhileReading(inPasswordField: inPassword, mayHandOver: may) == .handOver {
                    handOvers += 1
                    machine.handOverFinished(voiceOverCame: voiceOverCame)
                }
            }
        }
        /// Looks four a second while the keys are with VoiceOver, for `seconds`.
        func handedOver(_ seconds: TimeInterval, unchanged: Bool = true, voiceOverOn: Bool = true, front: Bool = true) {
            for _ in 0..<Int(seconds * 4) {
                t += 0.25
                let standing = SecureInputHandOver.Standing(readerUnchanged: unchanged, voiceOverOn: voiceOverOn, frontIsTurnOvers: front)
                switch machine.lookWhileHandedOver(standing) {
                case .handBack: handBacks += 1
                case .standDown(let why): standDowns.append(why)
                case .wait, .handOver: break
                }
            }
        }
    }

    test("secure input: Safari's sign-in timeline hands over a second after Tab leaves the field, back a second after it goes off") {
        let rig = Rig()
        rig.secure = true
        rig.reading(30, inPassword: true)   // typing the password: SecureEcho's, TurnOver keeps it
        expect(rig.handOvers, 0, "a real password field is never handed over")
        rig.reading(0.75)
        expect(rig.handOvers, 0, "under a second outside the field: not yet")
        rig.reading(0.5)
        expect(rig.handOvers, 1, "a second outside the field: handed over")
        expect(rig.machine.phase, .handedOver)
        rig.handedOver(60)   // Shift Tab back into the field and out again: the focus is not asked
        expect(rig.handBacks, 0, "no hand-back while secure input is on, wherever the focus goes")
        rig.secure = false
        rig.handedOver(0.75)
        expect(rig.handBacks, 0, "under a second off: not yet")
        rig.handedOver(0.5)
        expect(rig.handBacks, 1, "a second off: handed back once")
        expect(rig.machine.phase, .reading)
        rig.handedOver(10)
        expect(rig.handBacks, 1, "handed back only once")
    }

    test("secure input: a real password field is never handed over, for any length of time") {
        let rig = Rig()
        rig.secure = true
        rig.reading(600, inPassword: true)
        expect(rig.handOvers, 0)
        rig.reading(0.5)
        rig.reading(0.5, inPassword: true)   // back into the field before the second was up
        rig.reading(0.75)
        expect(rig.handOvers, 0, "the second outside the field starts again each time the focus is in one")
    }

    test("secure input: flicker hands nothing over, and a hand-back rests five seconds") {
        let rig = Rig()
        for _ in 0..<33 {   // on and off every 300 ms for ten seconds (looks every 250 ms)
            rig.secure.toggle()
            rig.t += 0.3
            _ = rig.machine.lookWhileReading(inPasswordField: false, mayHandOver: true)
        }
        rig.secure = false
        rig.reading(10)
        expect(rig.handOvers, 0, "never a second on running")
        rig.secure = true
        rig.reading(1.25)
        expect(rig.handOvers, 1)
        rig.secure = false
        rig.handedOver(0.5)
        rig.secure = true
        rig.handedOver(10)
        expect(rig.handBacks, 0, "off for half a second is not a second off")
        rig.secure = false
        rig.handedOver(1.25)
        expect(rig.handBacks, 1)
        rig.secure = true
        rig.reading(5)
        expect(rig.handOvers, 1, "within five seconds of a hand-back, no hand-over")
        rig.reading(1.5)
        expect(rig.handOvers, 2, "after the rest, a second on hands over again")
    }

    test("secure input: Terminal's Secure Keyboard Entry left on for hours hands over once and back once") {
        let rig = Rig()
        rig.secure = true
        rig.reading(2)
        rig.handedOver(4 * 3600)
        expect(rig.handOvers, 1)
        expect(rig.handBacks, 0)
        expect(rig.standDowns, [])
        rig.secure = false
        rig.handedOver(2)
        expect(rig.handBacks, 1)
    }

    test("secure input: quitting, the watchdog or another reader change ends it with no hand-back, and a restart starts afresh") {
        let rig = Rig()
        rig.secure = true
        rig.reading(1.25)
        rig.handedOver(5)
        rig.handedOver(0.25, unchanged: false)   // the watchdog acted, another hand-over, a choice by hand, the lock
        expect(rig.standDowns, [.readerChanged])
        rig.secure = false
        rig.handedOver(5)
        expect(rig.handBacks, 0, "no hand-back after someone else changed the reader")
        rig.secure = true
        rig.reading(30)
        expect(rig.handOvers, 1, "secure input not yet gone off since: no new hand-over, so a choice by hand is not fought")
        // TurnOver quit, or the watchdog restarted it, while handed over: the new process knows nothing of it. VoiceOver
        // stays on (what TurnOver leaves at a quit); if TurnOver takes the keys back while secure input is on, a second
        // later they go to VoiceOver again.
        let restarted = Rig()
        restarted.secure = true
        restarted.reading(1.25)
        expect(restarted.handOvers, 1)
        restarted.reading(0.25, may: false)
        expect(restarted.handOvers, 1)
    }

    test("secure input: VoiceOver failing to start leaves TurnOver reading, with no retry until secure input goes off") {
        let rig = Rig()
        rig.secure = true
        rig.reading(1.25, voiceOverCame: false)
        expect(rig.handOvers, 1)
        expect(rig.machine.phase, .spent)
        check(!rig.machine.underWay, "the lead watcher stops looking: TurnOver still reads by focus")
        rig.reading(120)
        expect(rig.handOvers, 1, "no toggling VoiceOver again and again")
        rig.secure = false
        rig.reading(1)
        rig.secure = true
        rig.reading(5)
        expect(rig.handOvers, 1, "a new episode waits the rest")
        rig.reading(1.5)
        expect(rig.handOvers, 2, "then tries again")

        let silent = Rig()   // the hand-over never answered at all
        silent.secure = true
        var asked = 0
        for _ in 0..<5 {   // looked at, but the answer is never given
            silent.t += 0.25
            if silent.machine.lookWhileReading(inPasswordField: false, mayHandOver: true) == .handOver { asked += 1 }
        }
        expect(asked, 1)
        expect(silent.machine.phase, .handingOver)
        silent.handedOver(14, voiceOverOn: false)
        expect(silent.standDowns, [], "the hand-over may still answer")
        silent.handedOver(1.5, voiceOverOn: false)
        expect(silent.standDowns, [.voiceOverNeverCame], "after 15 s with VoiceOver off, TurnOver goes on reading")
        expect(silent.handBacks, 0)
    }

    test("secure input: no hand-over while something else owns the reader; no hand-back to an app VoiceOver leads") {
        let rig = Rig()
        rig.secure = true
        rig.reading(60, may: false)   // locked, waking, off by its key, coexisting, TurnOver not reading
        expect(rig.handOvers, 0)
        rig.reading(1.25)
        expect(rig.handOvers, 1, "the second counts from when it may")
        rig.secure = false
        rig.handedOver(1.25, front: false)
        expect(rig.standDowns, [.frontIsVoiceOvers])
        expect(rig.handBacks, 0)

        let byHand = Rig()
        byHand.secure = true
        byHand.reading(1.25)
        byHand.handedOver(3, voiceOverOn: false)   // VoiceOver turned off by hand
        expect(byHand.standDowns, [.voiceOverOff])
        expect(byHand.handBacks, 0)
    }
}
