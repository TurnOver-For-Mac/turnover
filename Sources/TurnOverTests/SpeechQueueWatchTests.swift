// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os
import TurnOverSpeech

func speechQueueWatchTests() {
    let start = Date(timeIntervalSince1970: 1_000)

    test("speech recovery: a deferred stall retries after grace and stops once accepted") {
        let watch = SpeechQueueWatch(now: start)
        check(watch.claim(at: start.addingTimeInterval(4)) == nil, "four seconds is not yet a stall")
        var attempts = 0
        for second in [6.0, 8.0, 10.0] {
            guard let stall = watch.claim(at: start.addingTimeInterval(second)) else { return Harness.fail("deferred stall was lost") }
            attempts += 1
            check(watch.isCurrent(stall), "the current request can be used for recovery")
            expect(stall.seconds, second)
            // The same decision the app returns during sleep/wake grace: leave the claim available to retry.
            watch.complete(stall, accepted: second == 10)
        }
        expect(attempts, 3)
        check(watch.claim(at: start.addingTimeInterval(12)) == nil, "accepted recovery is not repeated")
    }

    test("speech recovery: a claimed stall cannot start overlapping recovery") {
        let watch = SpeechQueueWatch(now: start)
        guard let stall = watch.claim(at: start.addingTimeInterval(6)) else { return Harness.fail("no initial stall") }
        check(watch.claim(at: start.addingTimeInterval(8)) == nil, "only one recovery can own a heartbeat generation")
        watch.complete(stall, accepted: false)
        check(watch.claim(at: start.addingTimeInterval(10)) != nil, "deferring releases the claim")
    }

    test("speech recovery: resumed speech invalidates the outstanding recovery request") {
        let watch = SpeechQueueWatch(now: start)
        guard let old = watch.claim(at: start.addingTimeInterval(6)) else { return Harness.fail("no initial stall") }
        watch.heartbeat(at: start.addingTimeInterval(7))
        check(!watch.isCurrent(old), "a resumed queue rejects the old replacement")
        watch.complete(old, accepted: true)
        check(watch.claim(at: start.addingTimeInterval(10)) == nil, "a recent heartbeat is healthy")
        guard let next = watch.claim(at: start.addingTimeInterval(13)) else { return Harness.fail("a later stall was suppressed by the old completion") }
        check(watch.isCurrent(next), "a new stall can recover independently")
        expect(next.seconds, 6)
    }

    test("speech recovery: an obsolete completion cannot acknowledge a newer retry") {
        let watch = SpeechQueueWatch(now: start)
        guard let old = watch.claim(at: start.addingTimeInterval(6)) else { return Harness.fail("no initial stall") }
        watch.complete(old, accepted: false)
        guard let next = watch.claim(at: start.addingTimeInterval(8)) else { return Harness.fail("no retry") }
        check(!watch.isCurrent(old), "a deferred claim expires even without a heartbeat")
        watch.complete(old, accepted: true)
        check(watch.isCurrent(next), "the newer request still owns recovery")
        watch.complete(next, accepted: false)
        check(watch.claim(at: start.addingTimeInterval(10)) != nil, "the obsolete acknowledgement did not consume the stall")
    }

    test("speech recovery: a replaced player cannot retry or accept a late replacement") {
        let watch = SpeechQueueWatch(now: start)
        guard let stall = watch.claim(at: start.addingTimeInterval(6)) else { return Harness.fail("no initial stall") }
        watch.retire()
        check(watch.isRetired, "replacement retires the old watcher")
        check(!watch.isCurrent(stall), "late results from the old player are obsolete")
        watch.complete(stall, accepted: false)
        watch.heartbeat(at: start.addingTimeInterval(7))
        check(watch.claim(at: start.addingTimeInterval(20)) == nil, "neither completion nor an old queued heartbeat rearms a retired player")
    }

    test("speech recovery: a fresh heartbeat rearms recovery after an accepted stall") {
        let watch = SpeechQueueWatch(now: start)
        guard let first = watch.claim(at: start.addingTimeInterval(6)) else { return Harness.fail("no initial stall") }
        watch.complete(first, accepted: true)
        watch.heartbeat(at: start.addingTimeInterval(9))
        guard let next = watch.claim(at: start.addingTimeInterval(15)) else { return Harness.fail("a different stall was lost") }
        watch.complete(first, accepted: false)
        check(watch.isCurrent(next), "the first stall cannot release the second claim")
    }

    test("speech recovery: a stalled request keeps a consistent operation snapshot") {
        let watch = SpeechQueueWatch(now: start)
        watch.noteDoing("engine start")
        guard let stall = watch.claim(at: start.addingTimeInterval(6)) else { return Harness.fail("no initial stall") }
        watch.noteDoing("node play")
        expect(stall.doing, "engine start", "the diagnostic belongs to the operation observed at the claim")
        watch.complete(stall, accepted: false)
        expect(watch.claim(at: start.addingTimeInterval(8))?.doing, "node play")
    }

    test("speech recovery: concurrent polls give only one caller the recovery claim") {
        let watch = SpeechQueueWatch(now: start)
        let claimed = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            if watch.claim(at: start.addingTimeInterval(6)) != nil { claimed.withLock { $0 += 1 } }
        }
        expect(claimed.withLock { $0 }, 1)
    }
}
