// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

/// Secure input's two log lines, and a swallowed release left behind by it (18 Nov 2026). Times and keys are given by
/// hand; nothing touches the Mac's secure input. Logic evidence only.
func secureInputEpisodeTests() {
    let t0 = Date(timeIntervalSince1970: 1000)
    test("secure input episode: one line as it comes on, one as it goes off, nothing while it stays on") {
        var ep = SecureInputEpisode()
        let on = ep.look(on: true, now: t0, inPasswordField: false, hidKeysSeen: false)
        check(on?.hasPrefix("secure input: on, the focus not in a password field") == true, "the start is logged")
        expect(ep.look(on: true, now: t0 + 1, inPasswordField: false, hidKeysSeen: true), nil)
        expect(ep.since, t0)
        expect(ep.look(on: false, now: t0 + 4.2, inPasswordField: false, hidKeysSeen: true),
               "secure input: off after 4.2 s, the keyboard watch saw keys: yes")
        expect(ep.look(on: false, now: t0 + 5, inPasswordField: false, hidKeysSeen: true), nil)
        expect(ep.since, nil)
    }
    test("secure input episode: a password field had the focus, so nothing about the keyboard watch is logged") {
        var ep = SecureInputEpisode()
        _ = ep.look(on: true, now: t0, inPasswordField: false, hidKeysSeen: false)
        _ = ep.look(on: true, now: t0 + 0.25, inPasswordField: true, hidKeysSeen: true)
        expect(ep.look(on: true, now: t0 + 0.5, inPasswordField: false, hidKeysSeen: true), nil)
        expect(ep.look(on: false, now: t0 + 3, inPasswordField: false, hidKeysSeen: true), "secure input: off after 3.0 s")
        // The next stretch starts afresh: no password field in it, the answer is logged.
        _ = ep.look(on: true, now: t0 + 10, inPasswordField: false, hidKeysSeen: false)
        expect(ep.look(on: false, now: t0 + 11, inPasswordField: false, hidKeysSeen: false),
               "secure input: off after 1.0 s, the keyboard watch saw keys: no")
    }
    test("secure input episode: on in a password field from the first look; no watch, no answer; stood aside, said so") {
        var ep = SecureInputEpisode()
        _ = ep.look(on: true, now: t0, inPasswordField: true, hidKeysSeen: true)
        expect(ep.look(on: false, now: t0 + 2, inPasswordField: false, hidKeysSeen: true), "secure input: off after 2.0 s")
        _ = ep.look(on: true, now: t0 + 5, inPasswordField: false, hidKeysSeen: nil)
        expect(ep.look(on: true, now: t0 + 7, inPasswordField: false, hidKeysSeen: nil, watched: false),
               "secure input: no longer watched after 2.0 s (TurnOver stood aside)")
        expect(ep.look(on: false, now: t0 + 8, inPasswordField: false, hidKeysSeen: nil, watched: false), nil)
    }
    test("swallowed releases: a new press of a key whose release was lost drops only that key's entry") {
        var awaited: Set<Int64> = [48, 123]                      // Tab and Left taken; Tab's release hidden by secure input
        expect(SwallowedReleases.dropsStale(&awaited, code: 48, isRepeat: false), true)
        expect(awaited, [123])                                    // Left's release is still swallowed when it comes
        expect(SwallowedReleases.dropsStale(&awaited, code: 123, isRepeat: true), false)   // a repeat is the same press
        expect(awaited, [123])
        expect(SwallowedReleases.dropsStale(&awaited, code: 0, isRepeat: false), false)    // nothing awaited for A
    }
}
