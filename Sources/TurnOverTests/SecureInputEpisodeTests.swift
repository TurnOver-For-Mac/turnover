// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

/// Secure input's two log lines, and a swallowed release left behind by it (18 Nov 2026). Times and keys are given by
/// hand; nothing touches the Mac's secure input. Logic evidence only.
func secureInputEpisodeTests() {
    let t0 = Date(timeIntervalSince1970: 1000)
    test("secure input episode: one line as it comes on, one as it goes off, nothing while it stays on") {
        var ep = SecureInputEpisode()
        let on = ep.look(on: true, now: t0, inPasswordField: false)
        check(on?.hasPrefix("secure input: on, the focus not in a password field") == true, "the start is logged")
        expect(ep.look(on: true, now: t0 + 1, inPasswordField: true), nil)
        expect(ep.since, t0)
        expect(ep.look(on: false, now: t0 + 4.2), "secure input: off after 4.2 s")
        expect(ep.look(on: false, now: t0 + 5), nil)
        expect(ep.since, nil)
    }
    test("secure input episode: nothing about the keyboard is ever logged") {
        var ep = SecureInputEpisode()
        let on = ep.look(on: true, now: t0, inPasswordField: true) ?? ""
        let off = ep.look(on: false, now: t0 + 3) ?? ""
        check(!on.contains("keyboard") && !off.contains("keyboard"), "no keyboard watch in either line")
        expect(off, "secure input: off after 3.0 s")
    }
    test("secure input episode: stood aside mid-stretch, said so, and only once") {
        var ep = SecureInputEpisode()
        _ = ep.look(on: true, now: t0, inPasswordField: false)
        expect(ep.look(on: true, now: t0 + 2, watched: false), "secure input: no longer watched after 2.0 s (TurnOver stood aside)")
        expect(ep.look(on: false, now: t0 + 3, watched: false), nil)
    }
    test("swallowed releases: a new press of a key whose release was lost drops only that key's entry") {
        var awaited: Set<Int64> = [48, 123]                      // Tab and Left taken; Tab's release hidden by secure input
        expect(SwallowedReleases.dropsStale(&awaited, code: 48, isRepeat: false), true)
        expect(awaited, [123])
        expect(SwallowedReleases.dropsStale(&awaited, code: 123, isRepeat: true), false)   // a repeat is the same press
        expect(SwallowedReleases.dropsStale(&awaited, code: 0, isRepeat: false), false)
    }

    /// The tap's order for one key, as KeyboardHandler runs it: the gate, then the press taken (its release awaited) or
    /// dropped as an echo; a release swallowed if awaited, else passed to the app.
    struct Tap {
        var gate = KeyDownGate()
        var awaited = Set<Int64>()
        var passedUps = 0
        mutating func down(_ code: Int64, at ms: Double, taken: Bool, isRepeat: Bool = false) -> KeyDownGate.Outcome {
            let o = gate.press(code: code, isRepeat: isRepeat, nowNs: UInt64(ms * 1_000_000), awaited: &awaited)
            if case .accepted = o, taken { awaited.insert(code) }
            return o
        }
        mutating func up(_ code: Int64) { if awaited.remove(code) == nil { passedUps += 1 } }
    }
    test("key down gate: echo copies of a swallowed press keep its release swallowed (the review's case)") {
        var t = Tap()
        expect(t.down(123, at: 1000, taken: true), .accepted(droppedStale: false))
        expect(t.down(123, at: 1002, taken: true), .accepted(droppedStale: true))    // a copy past the guard, taken again
        expect(t.down(123, at: 1004, taken: true), .echo(first: true))               // dropped: the entry is untouched
        expect(t.down(123, at: 1006, taken: true), .echo(first: false))
        check(t.awaited.contains(123), "the release is still awaited")
        t.up(123)
        expect(t.passedUps, 0)
    }
    test("key down gate: a release lost under secure input no longer swallows the next press's release") {
        var t = Tap()
        _ = t.down(48, at: 1000, taken: true)                 // Tab taken; its release hidden by secure input
        expect(t.down(48, at: 9000, taken: false), .accepted(droppedStale: true))    // later Tab passed to the app
        t.up(48)
        expect(t.passedUps, 1)                                // the app gets this press's release
    }
    test("key down gate: key repeat of a taken key and other keys' releases are left alone") {
        var t = Tap()
        _ = t.down(125, at: 1000, taken: true)
        _ = t.down(124, at: 1100, taken: true)
        expect(t.down(125, at: 1200, taken: false, isRepeat: true), .accepted(droppedStale: false))
        t.up(125); t.up(124)
        expect(t.passedUps, 0)
    }
}
