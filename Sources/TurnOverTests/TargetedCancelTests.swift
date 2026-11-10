// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os
import TurnOverSpeech

func targetedCancelTests() {
    test("targeted cancel: only the source's waiting speech is dropped, in order") {
        let waiting: [(id: Int, source: String?)] = [(1, "mouse"), (2, nil), (3, "mouse"), (4, "other")]
        let kept = SpeechSourceFilter.keeping(waiting, notFrom: "mouse") { $0.source }
        expect(kept.map(\.id), [2, 4], "untagged and other sources stay, in their order")
    }

    test("targeted cancel: nothing from the source leaves the list alone") {
        let kept = SpeechSourceFilter.keeping([1, 2], notFrom: "mouse") { _ in nil }
        expect(kept, [1, 2])
    }

    test("targeted cancel: the player calls an other source's completion once, never as cut off") {
        guard let player = try? SpeechPlayer(voice: "com.apple.voice.compact.en-GB.Daniel") else {
            print("     (skipped: no audio output to start a player on)"); return
        }
        // An external voice that never delivers audio keeps the first utterance rendering, so the others wait, and
        // no sound is made.
        let said = OSAllocatedUnfairLock<[String]>(initialState: [])
        player.externalRenderer = { @Sendable text, _, _, _ in said.withLock { $0.append(text) }; return {} }
        let calls = OSAllocatedUnfairLock<[String: [Bool]]>(initialState: [:])
        func speak(_ text: String, source: String?) {
            player.speak(text, interrupt: false, voice: "external:test", source: source,
                         completion: { @Sendable finished in calls.withLock { $0[text, default: []].append(finished) } })
        }
        speak("mouse one", source: "mouse")
        speak("other one", source: nil)
        speak("mouse two", source: "mouse")
        speak("other two", source: "typing")
        player.cancel(source: "mouse")
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, calls.withLock({ $0["mouse two"] == nil || $0["mouse one"] == nil }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))   // the rest of the cancel runs after those two calls
        let got = calls.withLock { $0 }
        expect(got["mouse one"], [false], "the source's utterance that was rendering is cut off")
        expect(got["mouse two"], [false], "the source's waiting utterance is dropped")
        check(got["other one"] == nil, "another source's waiting utterance is not told it was cut off")
        check(got["other two"] == nil, "nor the next one")
        expect(said.withLock { $0 }, ["mouse one", "other one"], "the other source's speech goes on, in order")
        player.cancel()
    }
}
