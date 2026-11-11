// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

func mouseTrackingTests() {
    test("mouse tracking: a pointer that has hardly moved is not looked at again") {
        var t = PointerTracker<String>()
        expect(t.worthLooking(at: CGPoint(x: 100, y: 100)), true, "the first place is always looked at")
        t.looked(at: CGPoint(x: 100, y: 100))
        expect(t.worthLooking(at: CGPoint(x: 102, y: 103)), false, "5 points is a tremor")
        expect(t.worthLooking(at: CGPoint(x: 106, y: 100)), true, "6 points is a move")
        expect(t.worthLooking(at: CGPoint(x: 100, y: 94)), true, "up as well as across")
    }

    test("mouse tracking: an item is said once, however many looks find it") {
        var t = PointerTracker<String>()
        expect(t.answer("Save"), .say)
        expect(t.answer("Save"), .nothing, "still over the same button")
        expect(t.answer("Cancel"), .say, "a new one")
        expect(t.answer("Save"), .say, "back to the first is a change")
    }

    test("mouse tracking: a blank place is the empty sound once, and coming back to the item says it again") {
        var t = PointerTracker<String>()
        expect(t.answer(nil), .nothing, "blank from the start has nothing to leave")
        expect(t.answer("Save"), .say)
        expect(t.answer(nil), .blank, "leaving the item for blank space")
        expect(t.answer(nil), .nothing, "still blank: the sound is not repeated")
        expect(t.answer("Save"), .say, "the same button after a gap is heard again, as VoiceOver does")
    }

    test("mouse tracking: a look given up on leaves its place to be looked at again, and what was said stays said") {
        var t = PointerTracker<String>()
        t.looked(at: CGPoint(x: 5, y: 5))
        _ = t.answer("Save")
        t.forgetLook()
        expect(t.worthLooking(at: CGPoint(x: 5, y: 5)), true, "the pointer resting where the lost look was")
        expect(t.answer("Save"), .nothing, "the same item is not said twice")
        expect(t.answer("Cancel"), .say)
    }

    test("mouse tracking: a reset forgets where the pointer was and what was said") {
        var t = PointerTracker<String>()
        t.looked(at: CGPoint(x: 5, y: 5))
        _ = t.answer("Save")
        t.reset()
        expect(t.worthLooking(at: CGPoint(x: 5, y: 5)), true)
        expect(t.answer("Save"), .say, "turned on again, the item under the pointer is said")
    }

    test("mouse tracking: off unless asked for, and kept in the file once set") {
        expect(Config().presentation.mouseTracking, false)
        var c = Config()
        c.presentation.mouseTracking = true
        let back = try? JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        expect(back?.presentation.mouseTracking, true)
        let old = try? JSONDecoder().decode(Config.self, from: Data("{\"presentation\":{\"verbosity\":\"medium\"}}".utf8))
        expect(old?.presentation.mouseTracking, false, "a file from before the setting existed")
        expect(Config().presentation.mouseMovesCursor, true, "the cursor follows unless that is turned off")
        c.presentation.mouseMovesCursor = false
        let kept = try? JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        expect(kept?.presentation.mouseMovesCursor, false)
        expect(old?.presentation.mouseMovesCursor, true, "a file from before the setting existed")
    }

    test("mouse tracking: interrupting other speech is off unless asked for, and kept in the file once set") {
        expect(Config().presentation.mouseInterruptsSpeech, false)
        var c = Config()
        c.presentation.mouseInterruptsSpeech = true
        let kept = try? JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        expect(kept?.presentation.mouseInterruptsSpeech, true)
        let old = try? JSONDecoder().decode(Config.self, from: Data("{\"presentation\":{\"mouseTracking\":true}}".utf8))
        expect(old?.presentation.mouseInterruptsSpeech, false, "a file from before the setting existed")
    }

    test("mouse tracking: a file with the removed blank-sound and watchdog settings still loads") {
        let old = try? JSONDecoder().decode(Config.self, from: Data("{\"presentation\":{\"mouseTracking\":true,\"mouseEmptySound\":false,\"mouseWatchdog\":false}}".utf8))
        expect(old?.presentation.mouseTracking, true)
    }

    test("mouse tracking: a watchdog for an earlier look does nothing once a later one is out") {
        var s = LookState()
        let first = s.begin()
        _ = s.arrived(generation: first.generation)
        let second = s.begin()
        expect(s.giveUp(onLookOf: first.id), false)
        expect(s.inFlight, true, "the later look is still out")
        expect(s.accepts(generation: second.generation), true)
    }

    test("mouse tracking: a look that arrives after it was given up on is dropped") {
        var s = LookState()
        let look = s.begin()
        expect(s.giveUp(onLookOf: look.id), true)
        expect(s.inFlight, false)
        expect(s.arrived(generation: look.generation), false)
    }

    test("mouse tracking: stopping drops a look still out") {
        var s = LookState()
        let look = s.begin()
        s.stop()
        expect(s.inFlight, false)
        expect(s.arrived(generation: look.generation), false)
    }

    test("mouse tracking: a look that arrives in time leaves the watchdog nothing to give up on") {
        var s = LookState()
        let look = s.begin()
        expect(s.arrived(generation: look.generation), true)
        expect(s.inFlight, false)
        expect(s.giveUp(onLookOf: look.id), false)
        expect(s.accepts(generation: look.generation), true, "nothing was dropped")
    }
}
