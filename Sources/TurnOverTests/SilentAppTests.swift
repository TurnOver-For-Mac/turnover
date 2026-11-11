// SPDX-License-Identifier: GPL-3.0-or-later
// An app, or a page in it, that stops answering (11 Nov 2026: Safari hung, and TurnOver threw away the page it had
// read and froze a key every three seconds). No process is asked anything here: the questions' answers, the clock
// and the background check's own questions are all supplied.
import Foundation
import ApplicationServices
import TurnOverAX
import TurnOverCore

func silentAppTests() {
    let pid = pid_t(Int32.max - 101)
    /// Stands for an element in the app (a page's web area). Never asked anything.
    let page = AXUIElementCreateApplication(pid)
    let second = 1_000_000_000 as UInt64

    func ask(_ error: AXError, took: UInt64 = 1, of element: AXUIElement?) -> AXQueryExecution {
        var ticks: [UInt64] = [100, 100 + took]
        return AXHealth.query(pid: pid, element: element, clock: { ticks.removeFirst() }) { error }
    }
    /// The check's seams set for a test, and put back after it.
    func withCheck(appAnswers: @escaping @Sendable () -> Bool, elementAnswers: @escaping @Sendable () -> Bool, _ body: () -> Void) {
        let answers = AXHealth.answers, exists = AXHealth.processExists, schedules = AXHealth.schedulesChecks
        let again = AXHealth.onAnsweringAgain, still = AXHealth.onStillSilent, unresponsive = AXHealth.onUnresponsive
        AXHealth.answers = { _, element in element == nil ? appAnswers() : elementAnswers() }
        AXHealth.processExists = { _ in true }
        AXHealth.schedulesChecks = false
        AXHealth.onUnresponsive = nil
        defer {
            AXHealth.answers = answers; AXHealth.processExists = exists; AXHealth.schedulesChecks = schedules
            AXHealth.onAnsweringAgain = again; AXHealth.onStillSilent = still; AXHealth.onUnresponsive = unresponsive
            AXHealth.forget(pid: pid)
        }
        body()
    }

    test("silent app: no answer is told apart from no value") {
        check(AXHealth.isNoAnswer(.returned(.cannotComplete), elapsedNanoseconds: 2 * second), "a question that waited out the timeout")
        check(AXHealth.isNoAnswer(.deferred(AXBackoff(reason: .timeout, remainingNanoseconds: 1)), elapsedNanoseconds: 0), "a question not asked of a resting app")
        check(AXHealth.isNoAnswer(.clientWorkStopped, elapsedNanoseconds: 0), "a question the caller's own limit stopped")
        check(!AXHealth.isNoAnswer(.returned(.cannotComplete), elapsedNanoseconds: 1_000_000), "a quick refusal is an answer: the element has gone")
        check(!AXHealth.isNoAnswer(.returned(.noValue), elapsedNanoseconds: 1), "no value is an answer")
        check(!AXHealth.isNoAnswer(.returned(.invalidUIElement), elapsedNanoseconds: 1), "a dead element is an answer")
        check(!AXHealth.isNoAnswer(.returned(.success), elapsedNanoseconds: 3 * second), "a slow answer is an answer")
        let unanswered = AXQueryResult<String>(value: nil, status: .returned(.cannotComplete), elapsedNanoseconds: 2 * second, wasAttempted: true)
        check(unanswered.isNoAnswer, "the result says so itself")
    }

    test("silent app: the wait worked out for each look is 3, 6, 12, 24, then 30 seconds") {
        expect((0..<7).map { AXHealth.checkGapNs(attempt: $0) / second }, [3, 6, 12, 24, 30, 30, 30])
        expect(AXHealth.checkGapNs(attempt: -1) / second, 3, "never less than the first wait")
    }

    test("silent app: each silent element comes first in its turn") {
        expect(AXHealth.inTurn(["a", "b", "c"], attempt: 0), ["a", "b", "c"])
        expect(AXHealth.inTurn(["a", "b", "c"], attempt: 1), ["b", "c", "a"])
        expect(AXHealth.inTurn(["a", "b", "c"], attempt: 5), ["c", "a", "b"])
        expect(AXHealth.inTurn([String](), attempt: 3), [])
        // With two asked a look, three looks reach every one of five, whichever of them never answers.
        let asked = Set((0..<3).flatMap { AXHealth.inTurn([0, 1, 2, 3, 4], attempt: $0).prefix(2) })
        expect(asked.count >= 4, true, "the elements after one that stays silent still get asked (\(asked.sorted()))")
    }

    test("silent app: a question that goes unanswered during a look is not wiped out by that look's answer") {
        let late = LockedFlag(false)
        withCheck(appAnswers: { true }, elementAnswers: {
            // While the look is asking the page, another question to the app goes unanswered. (One to the page itself
            // could not: a silent element is not asked.)
            if !late.value {
                late.value = true
                var ticks: [UInt64] = [100, 100 + 2_000_000_000]
                _ = AXHealth.query(pid: pid, element: nil, clock: { ticks.removeFirst() }) { .cannotComplete }
            }
            return true
        }) {
            _ = ask(.cannotComplete, took: 2 * second, of: page)
            check(AXHealth.check(pid: pid), "the look heard an answer, but a newer question had none: another look is due")
            check(AXHealth.isSilent(page), "the page is still silent")
            check(AXHealth.backoff(for: pid) != nil, "and the rest the newer timeout began still stands")
            check(!AXHealth.check(pid: pid), "the next look, with nothing new, ends it")
            check(!AXHealth.isSilent(page), "and the page is asked again")
        }
    }

    test("silent app: with looks run by hand, a page that stops answering stays silent while its app is read") {
        let appUp = LockedFlag(true), pageUp = LockedFlag(false)
        withCheck(appAnswers: { appUp.value }, elementAnswers: { pageUp.value }) {
            expect(ask(.cannotComplete, took: 2 * second, of: page).status, .returned(.cannotComplete), "the question that was not answered")
            check(AXHealth.isSilent(page), "the page is silent")
            if case .deferred = ask(.success, of: nil).status {} else { check(false, "the whole app rests at first, as before") }

            let stillAt = LockedList<Bool>()
            AXHealth.onStillSilent = { _, _, appAnswers in stillAt.append(appAnswers) }
            check(AXHealth.check(pid: pid), "another look is due: the page is still silent")
            expect(stillAt.values, [true], "told once that the app answers and something in it does not")
            var asked = false
            expect(AXHealth.query(pid: pid, element: nil) { asked = true; return .success }.status, .returned(.success), "the app itself is asked again")
            check(asked, "its question went to it")
            asked = false
            let ofPage = AXHealth.query(pid: pid, element: page) { asked = true; return .success }
            if case .deferred(let rest) = ofPage.status { expect(rest.reason, .timeout) } else { check(false, "the page is still not asked") }
            check(!asked && !ofPage.wasAttempted, "no question went to the page")

            let again = LockedList<Double>()
            AXHealth.onAnsweringAgain = { _, seconds in again.append(seconds) }
            pageUp.value = true
            check(!AXHealth.check(pid: pid), "the page answers: no more looks")
            expect(again.values.count, 1, "said to be answering again, once")
            check(!AXHealth.isSilent(page), "the page is asked again")
            expect(ask(.success, of: page).status, .returned(.success))
            check(!AXHealth.check(pid: pid), "nothing left to look at")
        }
    }

    test("silent app: with looks run by hand, an app that stops answering rests until a look hears from it") {
        let appUp = LockedFlag(false)
        withCheck(appAnswers: { appUp.value }, elementAnswers: { true }) {
            _ = ask(.cannotComplete, took: 2 * second, of: page)
            let still = LockedList<Bool>()
            AXHealth.onStillSilent = { _, _, appAnswers in still.append(appAnswers) }
            for _ in 0..<3 { check(AXHealth.check(pid: pid), "still silent: another look is due") }
            expect(still.values, [false, false, false], "the app itself, each time")
            guard let rest = AXHealth.backoff(for: pid) else { return check(false, "the app is still resting after three looks") }
            expect(rest.reason, .timeout)
            // Past the fourth look (24 s away) and that look's own wait.
            check(rest.remainingNanoseconds > 24 * second, "it rests on past the next look, so no key is the one to find out (\(rest.remainingNanoseconds / second) s)")
            var asked = false
            _ = AXHealth.query(pid: pid, element: nil) { asked = true; return .success }
            check(!asked, "nothing is asked of it meanwhile")

            appUp.value = true
            check(!AXHealth.check(pid: pid), "it answers: done")
            check(AXHealth.backoff(for: pid) == nil, "its rest ends with its answer")
            expect(ask(.success, of: page).status, .returned(.success), "and its page is asked again")
        }
    }

    test("silent app: a look between the regular ones that finds the app itself silent rests it until the next regular look") {
        let appUp = LockedFlag(true)
        withCheck(appAnswers: { appUp.value }, elementAnswers: { false }) {
            _ = ask(.cannotComplete, took: 2 * second, of: page)
            check(AXHealth.check(pid: pid), "the app answers, its page does not: the next regular look is six seconds away")
            check(AXHealth.backoff(for: pid) == nil, "the app itself is being asked again")
            appUp.value = false
            check(AXHealth.check(pid: pid, continues: false), "a look in between (a notice came) finds the app silent now")
            guard let rest = AXHealth.backoff(for: pid) else { return check(false, "the app rests") }
            check(rest.remainingNanoseconds > 5 * second, "past the next regular look, not just three seconds, so no key finds out first (\(rest.remainingNanoseconds / 1_000_000) ms)")
        }
    }

    test("silent app: a look queued for a stall that has ended does nothing to the next stall") {
        withCheck(appAnswers: { true }, elementAnswers: { true }) {
            _ = ask(.cannotComplete, took: 2 * second, of: page)
            check(!AXHealth.check(pid: pid), "the first stall ends")
            _ = ask(.cannotComplete, took: 2 * second, of: page)
            check(AXHealth.isSilent(page), "a second stall has begun")
            check(!AXHealth.check(pid: pid, stallID: 0), "a look left over from another stall")
            check(AXHealth.isSilent(page), "changed nothing: the second stall's own look decides")
        }
    }

    test("silent app: an app that has quit is forgotten") {
        withCheck(appAnswers: { false }, elementAnswers: { false }) {
            _ = ask(.cannotComplete, took: 2 * second, of: page)
            AXHealth.processExists = { _ in false }
            check(!AXHealth.check(pid: pid), "no more looks")
            check(!AXHealth.isSilent(page) && AXHealth.backoff(for: pid) == nil, "nothing is held against a process that has gone")
        }
    }

    test("browse mode: the rule for saying nothing on this page yet again is two seconds") {
        let said = Date(timeIntervalSinceReferenceDate: 1000)
        check(!BrowseModeDocument.nothingYetDue(last: said, now: said.addingTimeInterval(0.001)), "a key queued behind the first")
        check(!BrowseModeDocument.nothingYetDue(last: said, now: said.addingTimeInterval(1.9)), "nor just under two seconds on")
        check(BrowseModeDocument.nothingYetDue(last: said, now: said.addingTimeInterval(2)), "two seconds on it is said again")
        check(BrowseModeDocument.nothingYetDue(last: .distantPast, now: said), "the first time")
    }

    test("stall sample: ps's elapsed times are read, and the newest page processes picked from its lines") {
        expect(StallSample.seconds(elapsed: "38:35"), 38 * 60 + 35)
        expect(StallSample.seconds(elapsed: "02:28:44"), 2 * 3600 + 28 * 60 + 44)
        expect(StallSample.seconds(elapsed: "01-08:44:09"), 86_400 + 8 * 3600 + 44 * 60 + 9, "days first")
        expect(StallSample.seconds(elapsed: "90210"), nil, "bare seconds are not what macOS's ps prints")
        expect(StallSample.seconds(elapsed: "a:b"), nil)
        // Lines as `ps -axo pid=,etime=,comm=` printed them on macOS 27.2 (11 Nov 2026), the paths shortened.
        let ps = """
         5270 01-08:44:09 /System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent
        47560    00:04 /System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent
        16221 08:08:58 /System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking
        47505    06:06 /System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent
        not a line
        86022 01-08:35:10 /System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari
        """
        expect(StallSample.newestWebContent(in: ps, count: 2), [47560, 47505], "the two that started last, newest first")
        expect(StallSample.newestWebContent(in: ps, count: 9), [47560, 47505, 5270], "never the network process or Safari itself")
        expect(StallSample.newestWebContent(in: "", count: 3), [])
    }

    test("stall sample: the rule for sampling one app again is a minute") {
        let then = Date(timeIntervalSinceReferenceDate: 5000)
        check(StallSample.due(last: nil, now: then), "the first stall of an app")
        check(!StallSample.due(last: then, now: then.addingTimeInterval(59)), "a second stall within the minute")
        check(StallSample.due(last: then, now: then.addingTimeInterval(60)), "a minute on it is sampled again")
    }
}

/// A flag and a list the check's callbacks can touch from its queue (here they run on the test's own thread).
nonisolated private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock(); private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool { get { lock.lock(); defer { lock.unlock() }; return stored } set { lock.lock(); stored = newValue; lock.unlock() } }
}
nonisolated private final class LockedList<Element>: @unchecked Sendable {
    private let lock = NSLock(); private var stored: [Element] = []
    func append(_ element: Element) { lock.lock(); stored.append(element); lock.unlock() }
    var values: [Element] { lock.lock(); defer { lock.unlock() }; return stored }
}
