// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

/// VoiceOver started by TurnOver's own watchdog or quit is no pin by hand, even in the TurnOver after a restart; the
/// record answers for one start only (18 Nov 2026, with Codex's review). The record is driven through a real file in
/// a temporary folder, with the clock given; nothing touches VoiceOver. Logic evidence only.
func ownVoiceOverStartTests() {
    func freshRecord() -> OwnVoiceOverStart.Record {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("turnover-own-start-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return OwnVoiceOverStart.Record(url: folder.appendingPathComponent("voiceover-asked-by-turnover"))
    }

    test("own VoiceOver start: 17 Nov 10:16, the quit's request taken by the restarted TurnOver's first VoiceOver on") {
        // Two processes share the file: the old one writes (watchdog 10:16:20.3, then the quit 10:16:24.4), the new one,
        // started 10:16:26, reads it when VoiceOver comes on at 10:16:30.1.
        let old = freshRecord()
        old.note(now: 36_980.331)
        old.note(now: 36_984.415)
        let new = OwnVoiceOverStart.Record(url: old.url)
        expect(new.take(now: 36_990.146), .ours)
        check(!new.isPending, "the record is used up by the start it describes")
    }
    test("own VoiceOver start: after the recovery's start is taken, Oliver's own Option-quote within 20 s is his") {
        let r = freshRecord()
        r.note(now: 1000)
        expect(r.take(now: 1004), .ours, "the watchdog's VoiceOver")
        // A hand-over turns VoiceOver off (cancel, as LeadWatcher.handOver does), then he turns it on at 1010.
        r.cancel()
        expect(r.take(now: 1010), .none, "his toggle, inside the old window")
    }
    test("own VoiceOver start: a hand-over or VoiceOver going off before the start arrives cancels it") {
        let r = freshRecord()
        r.note(now: 1000)
        r.cancel()   // VoiceOver off, or a hand-over posted
        check(!r.isPending, "cancelled")
        expect(r.take(now: 1003), .none)
    }
    test("own VoiceOver start: a stale record, or one dated after the clock (it went back), is no evidence and is deleted") {
        let r = freshRecord()
        r.note(now: 1000)
        expect(r.take(now: 1000 + OwnVoiceOverStart.window), .stale)
        check(!r.isPending, "deleted when stale")
        r.note(now: 1000)
        expect(r.take(now: 999.5), .stale, "the clock went back")
        check(!r.isPending, "deleted when ahead of the clock")
        expect(r.take(now: 2000), .none, "nothing asked")
    }
    test("own VoiceOver start: junk in the file reads as nothing and is deleted") {
        let r = freshRecord()
        try? "yesterday".write(to: r.url, atomically: true, encoding: .utf8)
        expect(r.take(now: 1000), .none)
        check(!r.isPending, "deleted")
        expect(OwnVoiceOverStart.decode(OwnVoiceOverStart.encode(1_763_374_580.331)), 1_763_374_580.331)
    }
}
