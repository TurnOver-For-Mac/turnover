// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

/// VoiceOver started by TurnOver's own watchdog or quit is no pin by hand, even in the TurnOver after a restart
/// (18 Nov 2026). Times are plain numbers: no test touches VoiceOver or the file. Logic evidence only.
func ownVoiceOverStartTests() {
    test("own VoiceOver start: 17 Nov 10:16, the watchdog's VoiceOver arriving 9.8 s later in the restarted TurnOver is ours") {
        let watchdogAsked = 36_980.331      // 10:16:20.331, the old process
        let quitAsked = 36_984.415          // 10:16:24.415, the same process quitting: the file holds the later one
        let voiceOverOn = 36_990.146        // 10:16:30.146, 4.1 s into the new process
        check(OwnVoiceOverStart.isOurs(askedAt: quitAsked, now: voiceOverOn), "the quit's request, 5.7 s before")
        check(OwnVoiceOverStart.isOurs(askedAt: watchdogAsked, now: voiceOverOn), "the watchdog's request, 9.8 s before")
    }
    test("own VoiceOver start: a toggle by hand long after, or with nothing asked, is the person's") {
        check(!OwnVoiceOverStart.isOurs(askedAt: nil, now: 1000), "nothing asked")
        check(!OwnVoiceOverStart.isOurs(askedAt: 1000, now: 1000 + OwnVoiceOverStart.window), "at the window's end")
        check(!OwnVoiceOverStart.isOurs(askedAt: 1000, now: 1000 + 3600), "an hour later")
        check(!OwnVoiceOverStart.isOurs(askedAt: 1000, now: 990), "a request after the change cannot have caused it")
        check(OwnVoiceOverStart.isOurs(askedAt: 1000, now: 999.5), "half a second of clock leeway")
    }
    test("own VoiceOver start: the file's text round-trips, and junk reads as nothing") {
        expect(OwnVoiceOverStart.decode(OwnVoiceOverStart.encode(1_763_374_580.331)), 1_763_374_580.331)
        expect(OwnVoiceOverStart.decode("12.5\n"), 12.5)
        expect(OwnVoiceOverStart.decode(""), nil)
        expect(OwnVoiceOverStart.decode("yesterday"), nil)
    }
}
