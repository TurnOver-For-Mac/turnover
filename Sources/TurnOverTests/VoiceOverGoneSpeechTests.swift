// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

/// VoiceOver gone under a flag that still says on: the four looks that make TurnOver take the keys also let its
/// speech through, the recovery's own words included (Codex's review, 18 Nov 2026). Driven through Speech's real
/// output gate up to the test seam after it; VoiceOver's flag is given, nothing touches the Mac. Logic evidence only.
func voiceOverGoneSpeechTests() {
    test("VoiceOver gone: speech is refused under the flag until the fourth look, then said; VoiceOver back quietens it") {
        let modeBefore = Speech.mode, gateBefore = Speech.voiceOverEnabledForOutput, coexistBefore = Speech.coexistingForOutput
        let enqueueBefore = Speech.enqueueTestDriver, outputBefore = Speech.outputTestDriver, goneBefore = Speech.voiceOverGoneForOutput
        defer {
            Speech.mode = modeBefore; Speech.voiceOverEnabledForOutput = gateBefore; Speech.coexistingForOutput = coexistBefore
            Speech.enqueueTestDriver = enqueueBefore; Speech.outputTestDriver = outputBefore; Speech.voiceOverGoneForOutput = goneBefore
        }
        var said: [String] = []
        Speech.mode = .talk
        Speech.voiceOverEnabledForOutput = { true }   // macOS's flag stays on
        Speech.coexistingForOutput = { false }
        Speech.enqueueTestDriver = nil
        Speech.outputTestDriver = { text, _, completion in said.append(text); completion?(true) }
        Speech.voiceOverGoneForOutput = false
        Speech.testResetFocusTiming()

        let watch = VoiceOverGoneWatch()
        var decided: [Int] = []
        for n in 1...3 {
            if watch.look(flagOn: true, running: false) { decided.append(n) }
            Speech.speakMessage("look \(n)")
        }
        expect(said, [], "VoiceOver may only be starting: TurnOver stays quiet")
        if watch.look(flagOn: true, running: false) { decided.append(4) }
        Speech.speakMessage("VoiceOver stopped. TurnOver is speaking.")
        expect(decided, [4], "decided once, on the fourth look")
        expect(said, ["VoiceOver stopped. TurnOver is speaking."], "the recovery's words are heard")
        watch.look(flagOn: true, running: false)
        Speech.speakMessage("still gone")
        expect(said.last, "still gone")
        watch.look(flagOn: true, running: true)   // VoiceOver running again
        Speech.speakMessage("over VoiceOver")
        expect(said.last, "still gone", "VoiceOver back: TurnOver quiet again")
        expect(watch.looks, 0)
    }
    test("VoiceOver gone: its process seen again stops TurnOver's speech already let through, at once") {
        // Codex's second review (18 Nov 2026): clearing the gate left admitted speech playing over VoiceOver for up to
        // about 4 s. Here the speech is admitted and still playing (never completed) when VoiceOver comes back.
        let goneBefore = Speech.voiceOverGoneForOutput
        defer { Speech.voiceOverGoneForOutput = goneBefore }
        var stops = 0
        let watch = VoiceOverGoneWatch(stopSpeech: { stops += 1 })
        for _ in 1...VoiceOverGoneWatch.looksToDecide { watch.look(flagOn: true, running: false) }
        check(watch.gone, "decided gone: TurnOver speaks")
        watch.voiceOverStarted(flagOn: true)   // macOS: VoiceOver's process launched, between two timer looks
        expect(stops, 1, "TurnOver's speech stopped at once")
        check(!Speech.voiceOverGoneForOutput, "and nothing new is let through under the flag")
        watch.look(flagOn: true, running: true)
        expect(stops, 1, "stopped once, not at every look while VoiceOver runs")
    }
    test("VoiceOver gone: VoiceOver merely starting, or its flag going off, stops nothing") {
        var stops = 0
        let watch = VoiceOverGoneWatch(stopSpeech: { stops += 1 })
        watch.look(flagOn: true, running: false)
        watch.voiceOverStarted(flagOn: true)   // not yet decided gone: TurnOver was quiet anyway
        expect(stops, 0)
        for _ in 1...VoiceOverGoneWatch.looksToDecide { watch.look(flagOn: true, running: false) }
        watch.look(flagOn: false, running: false)   // the flag off: TurnOver is the reader, it keeps speaking
        expect(stops, 0)
    }
}
