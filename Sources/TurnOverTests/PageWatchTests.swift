// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import TurnOverAX

func pageWatchTests() {
    let firstKey = Date(timeIntervalSinceReferenceDate: 100)
    let secondKey = firstKey.addingTimeInterval(0.5)
    let noNews = Date.distantPast
    let pid: Int32 = 123

    test("page watch: an answered empty focus query prevents a false warning") {
        let answered: [AXQueryStatus] = [
            .returned(.success),
            .returned(.noValue),
            .returned(.attributeUnsupported),
            .returned(.notImplemented),
        ]
        for status in answered {
            var waiting = PageWatch.WaitingKeys()
            _ = waiting.keySent(to: pid, at: firstKey, lastNews: noNews)
            let timer = waiting.keySent(to: pid, at: secondKey, lastNews: noNews)
            let answer = AXQueryResult<CFTypeRef>(value: nil, status: status,
                                                elapsedNanoseconds: 1, wasAttempted: true)
            check(answer.value == nil, "the answer contains no focused element")
            waiting.focusQueryReturned(answer.status, by: pid)
            check(waiting.unansweredKeys(for: pid, generation: timer, lastNews: noNews) == nil,
                  "an explicit empty answer retires the warning: \(status)")
        }
    }

    test("page watch: an unsuccessful focus query does not suppress a genuine warning") {
        let unanswered: [AXQueryStatus] = [
            .returned(.cannotComplete),
            .returned(.failure),
            .returned(.apiDisabled),
            .returned(.invalidUIElement),
            .deferred(AXBackoff(reason: .timeout, remainingNanoseconds: 1)),
            .clientWorkStopped,
            .batchNull,
            .invalidResponse,
        ]
        for status in unanswered {
            var waiting = PageWatch.WaitingKeys()
            _ = waiting.keySent(to: pid, at: firstKey, lastNews: noNews)
            let timer = waiting.keySent(to: pid, at: secondKey, lastNews: noNews)
            let wasAttempted: Bool
            if case .returned = status { wasAttempted = true }
            else { wasAttempted = false }
            let answer = AXQueryResult<CFTypeRef>(value: nil, status: status,
                                                elapsedNanoseconds: 1, wasAttempted: wasAttempted)
            waiting.focusQueryReturned(answer.status, by: pid)
            check(waiting.unansweredKeys(for: pid, generation: timer, lastNews: noNews) == 2,
                  "an unanswered query preserves the warning: \(status)")
        }
    }

    test("page watch: unchanged focus reply prevents a false wait warning") {
        var waiting = PageWatch.WaitingKeys()
        let firstTimer = waiting.keySent(to: pid, at: firstKey, lastNews: noNews)
        waiting.focusAnswered(by: pid)
        let secondTimer = waiting.keySent(to: pid, at: secondKey, lastNews: noNews)
        waiting.focusAnswered(by: pid)
        check(waiting.unansweredKeys(for: pid, generation: firstTimer, lastNews: noNews) == nil,
              "the first pending timer is retired by a focus reply")
        check(waiting.unansweredKeys(for: pid, generation: secondTimer, lastNews: noNews) == nil,
              "a real unchanged-focus answer is news even with no AX notification")
    }

    test("page watch: no notification and no focus answer still warns after two keys") {
        var waiting = PageWatch.WaitingKeys()
        let timer = waiting.keySent(to: pid, at: firstKey, lastNews: noNews)
        check(waiting.unansweredKeys(for: pid, generation: timer, lastNews: noNews) == nil,
              "one unanswered key does not warn")
        let secondTimer = waiting.keySent(to: pid, at: secondKey, lastNews: noNews)
        check(waiting.unansweredKeys(for: pid, generation: secondTimer, lastNews: noNews) == 2,
              "two unanswered keys still reach the warning path")
    }

    test("page watch: reply retires old timers before a new silent run") {
        var waiting = PageWatch.WaitingKeys()
        let oldTimer = waiting.keySent(to: pid, at: firstKey, lastNews: noNews)
        waiting.focusAnswered(by: pid)
        _ = waiting.keySent(to: pid, at: secondKey, lastNews: noNews)
        let newTimer = waiting.keySent(to: pid, at: secondKey.addingTimeInterval(0.1), lastNews: noNews)
        check(waiting.unansweredKeys(for: pid, generation: oldTimer, lastNews: noNews) == nil,
              "a timer from before the reply cannot warn about newer keys")
        check(waiting.unansweredKeys(for: pid, generation: newTimer, lastNews: noNews) == 2,
              "a new silent run retains its own warning")
    }

    test("page watch: AX notification also prevents a wait warning") {
        var waiting = PageWatch.WaitingKeys()
        let timer = waiting.keySent(to: pid, at: firstKey, lastNews: noNews)
        _ = waiting.keySent(to: pid, at: secondKey, lastNews: noNews)
        check(waiting.unansweredKeys(for: pid, generation: timer, lastNews: secondKey) == nil,
              "notification after the key proves responsiveness")
        let newTimer = waiting.keySent(to: pid, at: secondKey.addingTimeInterval(0.1), lastNews: secondKey)
        check(waiting.unansweredKeys(for: pid, generation: newTimer, lastNews: secondKey) == nil,
              "the first key after news starts a fresh run")
    }

    test("page watch: another process cannot answer pending keys") {
        var waiting = PageWatch.WaitingKeys()
        _ = waiting.keySent(to: pid, at: firstKey, lastNews: noNews)
        let timer = waiting.keySent(to: pid, at: secondKey, lastNews: noNews)
        waiting.focusAnswered(by: pid + 1)
        check(waiting.unansweredKeys(for: pid, generation: timer, lastNews: noNews) == 2,
              "an unrelated process reply cannot suppress a real warning")
        let otherTimer = waiting.keySent(to: pid + 1, at: secondKey, lastNews: noNews)
        check(waiting.unansweredKeys(for: pid, generation: timer, lastNews: noNews) == nil,
              "an old process timer cannot warn for the new process")
        check(waiting.unansweredKeys(for: pid + 1, generation: otherTimer, lastNews: noNews) == nil,
              "the other process starts with only one unanswered key")
    }
}
