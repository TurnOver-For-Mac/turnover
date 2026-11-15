// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

func typingEchoTests() {
    test("typing: the deleted-text pitch keeps its default and survives a save") {
        var c = Config()
        expect(c.speech.deletedPitch, 0, "deleted is said unless a pitch is chosen")
        c.speech.deletedPitch = 30
        let back = try? JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        expect(back?.speech.deletedPitch, 30)
        let old = try? JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        expect(old?.speech.deletedPitch, 0, "a file from before the setting existed")
    }
    test("typing: a deleted capital stays lowered when capitals are raised") {
        expect(Speech.capitalPitch(pending: nil, percent: 20), 1.2, "a typed capital is raised")
        expect(Speech.capitalPitch(pending: 0.7, percent: 20), 0.7, "a deleted capital keeps the lowered pitch")
    }
    test("typing: the log line says lowered, raised or changed to match the pitch") {
        expect(Speech.pitchLogLine(0.7), "say: (pitch lowered to 70 percent)")
        expect(Speech.pitchLogLine(1.2), "say: (pitch raised to 120 percent)")
        expect(Speech.pitchLogLine(1), "say: (pitch changed to 100 percent)")
    }
}
