// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import TurnOverAX
import AXFixtures

func pageWatchTests() {
    for reply in ["unchanged focus", "empty focus", "failed focus"] {
        test("page watch integration: Tab with \(reply) updates the production warning state") {
            var app: [String: AXFixture.Value] = ["AXRole": .string("AXApplication")]
            if reply == "unchanged focus" { app["AXFocusedUIElement"] = .element(0) }
            // AXReplay answers a missing attribute on an empty application node with invalidUIElement.
            if reply == "failed focus" { app = [:] }
            AXReplay.load(.init(app: "Public sample", bundle: "test.page-watch", recorded: "synthetic",
                                root: 0, application: 1, focus: nil, nodes: [
                .init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXParent": .element(1),
                                     "AXURL": .url("https://example.com/page-watch"), "AXChildren": .elements([])]),
                .init(id: 1, attrs: app),
            ]))
            let savedWaiting = PageWatch.waiting
            let savedPoster = KeyboardGesture.poster
            let savedSink = Speech.sink
            let savedReads = AXReplay.reads
            let root = AXReplay.element(0)
            let page = BrowseModeDocument(webArea: root)
            waitForBuffer(page.buffer)
            API.setFocusObject(ObjectFactory.make(root), ancestors: [], interceptor: page)
            let sent = Locked<[String]>([])
            KeyboardGesture.poster = { sent.value.append($0.identifier) }
            Speech.sink = { _ in }
            PageWatch.waiting = .init()
            AXReplay.reads = []
            defer {
                API.setFocusObject(nil, ancestors: [])
                // Drain the real 1.2-second warning callbacks before restoring shared state.
                RunLoop.current.run(until: Date().addingTimeInterval(1.3))
                PageWatch.waiting = savedWaiting
                KeyboardGesture.poster = savedPoster
                Speech.sink = savedSink
                AXReplay.reads = savedReads
                AXReplay.unload()
            }
            let tab = KeyboardGesture(identifier: "kb:tab")!
            page.script(named: "tabFromCaret")?.handler(tab)
            page.script(named: "tabFromCaret")?.handler(tab)
            expect(sent.value, ["kb:tab", "kb:tab"], "the actual Tab script posts both keys through the intercepted poster")
            var snapshot = PageWatch.waiting
            let generation = snapshot.keySent(to: root.pid, at: Date(), lastNews: .distantPast)
            expect(PageWatch.waiting.unansweredKeys(for: root.pid, generation: generation, lastNews: .distantPast), 2,
                   "both production key calls are waiting before the focus timer fires")
            // Exercise askFocusIfNoNews's real 0.35-second callback, rather than calling its helper.
            let askLimit = Date().addingTimeInterval(10)
            while AXReplay.reads?.contains(where: { $0.attribute == "AXFocusedUIElement" }) != true, Date() < askLimit {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))   // the reply is taken in after the question
            check(AXReplay.reads?.contains { $0.attribute == "AXFocusedUIElement" } == true,
                  "the production focus timer actually queried the replayed application")
            let pending = PageWatch.waiting.unansweredKeys(for: root.pid, generation: generation, lastNews: .distantPast)
            if reply == "failed focus" {
                expect(pending, 2, "a failed production focus query retains the two-key warning eligibility")
            } else {
                check(pending == nil, "the production focus reply retires the pending warning even without a notification")
            }
        }
    }
    // 18 Nov 2026: Tab with no focus news from the page answered after a fixed 0.35 s (seven Tabs of 361 to 368 ms in a
    // row in Safari). The page is now asked every 25 ms; and a focus read this way counts as news for PageWatch.
    for moves in [true, false] {
        test("page watch: Tab with no focus news \(moves ? "is answered as soon as the focus has moved" : "keeps asking until the ceiling when it has not")") {
            AXReplay.load(.init(app: "Public sample", bundle: "test.page-watch-poll", recorded: "synthetic",
                                root: 0, application: 1, focus: nil, nodes: [
                .init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXParent": .element(1),
                                     "AXURL": .url("https://example.com/page-watch-poll"), "AXChildren": .elements([2])]),
                .init(id: 1, attrs: ["AXRole": .string("AXApplication"), "AXFocusedUIElement": .element(moves ? 2 : 0)]),
                .init(id: 2, attrs: ["AXRole": .string("AXLink"), "AXParent": .element(0), "AXChildren": .elements([])]),
            ]))
            let savedWaiting = PageWatch.waiting
            let savedPoster = KeyboardGesture.poster
            let savedSink = Speech.sink
            let savedReads = AXReplay.reads
            let root = AXReplay.element(0)
            let page = BrowseModeDocument(webArea: root)
            waitForBuffer(page.buffer)
            API.setFocusObject(ObjectFactory.make(root), ancestors: [], interceptor: page)
            KeyboardGesture.poster = { _ in }
            Speech.sink = { _ in }
            PageWatch.waiting = .init()
            AXReplay.reads = []
            let savedCeiling = BrowseModeDocument.focusPollCeiling
            if !moves { BrowseModeDocument.focusPollCeiling = 1.0 }
            defer {
                BrowseModeDocument.focusPollCeiling = savedCeiling
                API.setFocusObject(nil, ancestors: [])
                RunLoop.current.run(until: Date().addingTimeInterval(1.3))
                PageWatch.waiting = savedWaiting
                KeyboardGesture.poster = savedPoster
                Speech.sink = savedSink
                AXReplay.reads = savedReads
                AXReplay.unload()
            }
            func queries() -> Int { AXReplay.reads?.filter { $0.attribute == "AXFocusedUIElement" }.count ?? 0 }
            let sent = Date()
            page.script(named: "tabFromCaret")?.handler(KeyboardGesture(identifier: "kb:tab")!)
            if moves {
                while queries() == 0, Date().timeIntervalSince(sent) < 10 {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.005))
                }
                let took = Date().timeIntervalSince(sent)
                check(queries() > 0 && took < 0.2, "the focus is asked for well before the old fixed 0.35 s (took \(Int(took * 1000)) ms)")
                check((AXHandler.shared.lastNewsAt[root.pid] ?? .distantPast) >= sent,
                      "a focus TurnOver read itself counts as news from the page, so no false \"please wait\"")
            } else {
                // The ceiling is lengthened to outlast a slow machine (0.35 s there is only a few polls); the asking must
                // then stop of its own accord: no new question for half a second, within ten seconds.
                var last = -1, quietSince = Date()
                let end = Date().addingTimeInterval(10)
                while Date() < end {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                    if queries() != last { last = queries(); quietSince = Date() }
                    else if last >= 3, Date().timeIntervalSince(quietSince) > 0.5 { break }
                }
                check(queries() >= 3, "an unmoved focus is asked for again, not once (asked \(queries()) times)")
                check(queries() <= 60, "and the asking stops at the ceiling (asked \(queries()) times)")
            }
        }
    }
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
