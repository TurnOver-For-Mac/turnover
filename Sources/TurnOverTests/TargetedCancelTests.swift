// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
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
}
