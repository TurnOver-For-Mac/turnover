// SPDX-License-Identifier: GPL-3.0-or-later
// Thin helpers over the HIServices C API for the probes. The reader proper will
// put this boundary in C/Objective-C on dedicated threads; the probes just need
// to make calls and time them.
import Foundation
import ApplicationServices
import AppKit

public struct Timed<T> {
    public let value: T
    public let ms: Double
}

public func timed<T>(_ body: () -> T) -> Timed<T> {
    let t0 = DispatchTime.now().uptimeNanoseconds
    let v = body()
    let t1 = DispatchTime.now().uptimeNanoseconds
    return Timed(value: v, ms: Double(t1 - t0) / 1_000_000)
}

/// An application that has stopped answering (E12). A frozen Safari page makes every question wait for the
/// messaging timeout (2 s), and reading a page asks hundreds: TurnOver stalled for as long as the page did, and the
/// watchdog had to step in. After one timed-out question the application is left alone for a few seconds: questions
/// to it fail at once instead of waiting. Then it is asked again, in the background (below), never by a key.
public enum AXHealth {
    private static let lock = NSLock()
    private struct Rest { let until: UInt64; let reason: AXBackoff.Reason }
    // Swift cannot express static NSLock ownership. Every access, including setup, expiry and cleanup, holds lock.
    nonisolated(unsafe) private static var quietUntil: [pid_t: Rest] = [:]
    /// Called (on whatever thread asked) when an application is found not answering; once per stall.
    nonisolated(unsafe) public static var onUnresponsive: (@Sendable (pid_t) -> Void)?   // set once at start
    static let restNs: UInt64 = 3_000_000_000
    /// A cannot-complete that took longer than this is a question that was not answered in time.
    static let timeoutNs: UInt64 = 900_000_000

    static func isResting(_ pid: pid_t) -> Bool {
        backoff(for: pid) != nil
    }

    /// Whether a question got no answer: it was not answered in time, or it was not asked, because the app or the
    /// element is being left alone or the caller's own work had stopped. Nothing is known then. That is not "no
    /// value": Safari not answering for its page's address was read as an empty address, so as a new page, and the
    /// page already read was thrown away (11 Nov 2026).
    public static func isNoAnswer(_ status: AXQueryStatus, elapsedNanoseconds ns: UInt64) -> Bool {
        switch status {
        case .deferred, .clientWorkStopped: return true
        case .returned(let error): return error == .cannotComplete && ns > timeoutNs
        case .batchNull, .invalidResponse: return false
        }
    }

    /// This process's current client backoff. A successful standalone probe says nothing about reader-process state.
    public static func backoff(for pid: pid_t) -> AXBackoff? {
        lock.lock(); defer { lock.unlock() }
        guard let rest = quietUntil[pid] else { return nil }
        let now = DispatchTime.now().uptimeNanoseconds
        if now < rest.until { return AXBackoff(reason: rest.reason, remainingNanoseconds: rest.until - now) }
        quietUntil[pid] = nil
        return nil
    }

    /// A question to `pid` came back `error` after `ns`: a cannot-complete that took most of a second is a timeout.
    /// The app rests, the element asked (when it is known) is marked silent, and the background check begins.
    static func note(_ error: AXError, pid: pid_t, ns: UInt64, element: AXUIElement? = nil) {
        guard error == .cannotComplete, ns > timeoutNs, pid > 0 else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let begins = silence[pid] == nil
        let fresh = quietUntil[pid] == nil && begins
        // A longer rest already standing (the app itself is silent, and is looked at again later) is not cut short.
        let rest = Rest(until: now + restNs, reason: .timeout)
        if (quietUntil[pid]?.until ?? 0) < rest.until { quietUntil[pid] = rest }
        var stall: Silence
        if let standing = silence[pid] {
            stall = standing
        } else {
            lastSilenceID += 1
            stall = Silence(id: lastSilenceID, since: now &- ns, elements: [], attempt: 0, unanswered: 0, heardLookAt: 0,
                            nextLookAt: now + checkGapNs(attempt: 0))
        }
        stall.unanswered += 1
        if let element {
            let key = ElementKey(element)
            let known = stall.elements.contains(key)
            let room = stall.elements.count < silentElementLimit
            if !known, room { stall.elements.append(key) }
        }
        silence[pid] = stall
        lock.unlock()
        if fresh { onUnresponsive?(pid) }
        if begins { scheduleCheck(pid: pid, attempt: 0, stallID: stall.id) }
    }

    /// Ask, unless the application is resting; note a timeout, or a slow drip.
    @inline(__always) static func ask(_ element: AXUIElement, _ body: () -> AXError) -> AXError {
        query(element, policy: .respectBackoff, body).legacyError
    }

    static func query(_ element: AXUIElement, policy: AXQueryPolicy, _ body: () -> AXError) -> AXQueryExecution {
        var p: pid_t = 0
        AXUIElementGetPid(element, &p)
        return query(pid: p, policy: policy, element: element, body)
    }

    /// The clock/provider seam is package-only: tests exercise the same admission/accounting without sleeping
    /// or delaying a real app. Calls and callbacks still run outside the health lock (28 Oct 2026, #166).
    package static func query(pid p: pid_t, policy: AXQueryPolicy = .respectBackoff, element: AXUIElement? = nil,
                              clock: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
                              _ body: () -> AXError) -> AXQueryExecution {
        guard AXReadScope.shouldContinue else {
            AXReadScope.report(.clientWorkStopped)
            return AXQueryExecution(status: .clientWorkStopped, elapsedNanoseconds: 0, wasAttempted: false)
        }
        if policy == .respectBackoff, let rest = backoff(for: p) ?? silentBackoff(element, pid: p) {
            AXReadScope.report(.deferred(rest))
            return AXQueryExecution(status: .deferred(rest), elapsedNanoseconds: 0, wasAttempted: false)
        }
        guard AXReadScope.admitQuery() else {
            AXReadScope.report(.clientWorkStopped)
            return AXQueryExecution(status: .clientWorkStopped, elapsedNanoseconds: 0, wasAttempted: false)
        }
        let t0 = clock()
        let e = body()
        let took = clock() &- t0
        AXStats.note(took)
        if e == .cannotComplete { note(e, pid: p, ns: took, element: element) }
        if took > dripCallNs { noteDrip(pid: p, ns: took) }
        AXReadScope.report(.returned(e))
        return AXQueryExecution(status: .returned(e), elapsedNanoseconds: took, wasAttempted: true)
    }

    package static func forget(pid: pid_t) {
        lock.lock(); quietUntil[pid] = nil; drip[pid] = nil; silence[pid] = nil; lock.unlock()
    }

    // MARK: Asked again in the background
    // Until 11 Nov 2026 a rest simply ran out, and the next question went to the app again, whoever asked it. When
    // that was a key, the main thread waited the whole timeout once more: Safari hung for good that day, and every
    // three seconds another key froze for two (three times in twelve seconds, 22 keys pressed with nothing read).
    // Now the element that went unanswered stays silent (questions to it fail at once), and a look off the main
    // thread asks again at growing gaps: the app itself first, then the elements, two a look, each in its turn.
    // - The app does not answer: the whole app stays resting until it does.
    // - The app answers and an element does not: only the element stays silent. A web page whose own process had
    //   stopped left its app answering at once for its windows, while the page's questions each took 1.5 s and
    //   failed (measured with a test web view, macOS 27.2, 11 Nov 2026): Safari's toolbar must stay readable then.
    // An element's silence does not cover what is inside it (a page's headings): browse mode reads a silent page
    // from its copy alone for that (BrowseModeDocument.pageSilent).
    // Nothing is held against an app for more than ten minutes, and if no look ever runs, a rest still runs out.
    private struct Silence {
        /// Which stall this is: a look begun for an earlier one changes nothing.
        let id: UInt64
        var since: UInt64
        var elements: [ElementKey]
        var attempt: Int
        /// The questions that have gone unanswered so far: an answer heard by a look that began before the latest
        /// of them proves nothing about it.
        var unanswered: Int
        var heardLookAt: UInt64
        /// When the next regular look is due: a look in between that finds the app itself silent rests it until then.
        var nextLookAt: UInt64
    }
    nonisolated(unsafe) private static var silence: [pid_t: Silence] = [:]   // under `lock`
    nonisolated(unsafe) private static var lastSilenceID: UInt64 = 0         // under `lock`
    static let silentElementLimit = 8
    static let asksPerLook = 2
    static let silenceLimitNs: UInt64 = 600_000_000_000
    static let heardLookGapNs: UInt64 = 3_000_000_000
    private static let checkQueue = DispatchQueue(label: "turnover.ax.health.check", qos: .utility)
    /// Called from the check's queue while an app (`appAnswers` false) or something in it is still silent, with the
    /// seconds since it stopped answering.
    nonisolated(unsafe) public static var onStillSilent: (@Sendable (pid_t, Double, Bool) -> Void)?   // set once at start
    /// Called from the check's queue when everything that was silent in an app answers again.
    nonisolated(unsafe) public static var onAnsweringAgain: (@Sendable (pid_t, Double) -> Void)?   // set once at start
    /// Seams for the tests: whether the app (nil) or an element answers now, whether the process is there, and
    /// whether looks are put on the queue at all.
    nonisolated(unsafe) package static var answers: @Sendable (pid_t, AXUIElement?) -> Bool = { liveAnswer($0, $1) }
    nonisolated(unsafe) package static var processExists: @Sendable (pid_t) -> Bool = { kill($0, 0) == 0 || errno == EPERM }
    nonisolated(unsafe) package static var schedulesChecks = true

    /// Whether this element went unanswered and has not answered since.
    public static func isSilent(_ element: AXUIElement) -> Bool {
        var p: pid_t = 0
        AXUIElementGetPid(element, &p)
        return silentBackoff(element, pid: p) != nil
    }

    static func silentBackoff(_ element: AXUIElement?, pid: pid_t) -> AXBackoff? {
        guard let element else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let stall = silence[pid] else { return nil }
        guard stall.elements.contains(ElementKey(element)) else { return nil }
        return AXBackoff(reason: .timeout, remainingNanoseconds: checkGapNs(attempt: stall.attempt))
    }

    /// The wait before look number `attempt` (from 0): 3, 6, 12, 24, then 30 seconds. Pure.
    public static func checkGapNs(attempt: Int) -> UInt64 {
        let steps: [UInt64] = [3, 6, 12, 24]
        let seconds = attempt < steps.count ? steps[max(0, attempt)] : 30
        return seconds * 1_000_000_000
    }

    /// The silent elements in the order they are asked at look number `attempt`: each comes first in its turn, so
    /// one that never answers again cannot keep the others from being asked. Pure.
    package static func inTurn<Item>(_ items: [Item], attempt: Int) -> [Item] {
        guard !items.isEmpty else { return [] }
        let first = max(0, attempt) % items.count
        return Array(items[first...]) + Array(items[..<first])
    }

    /// A look is queued for one stall: by the time it runs that stall may be over and another begun, with looks of
    /// its own, and this one must not join them (a review, 11 Nov 2026).
    static func scheduleCheck(pid: pid_t, attempt: Int, stallID: UInt64) {
        guard schedulesChecks else { return }
        checkQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(checkGapNs(attempt: attempt)))) { check(pid: pid, stallID: stallID) }
    }

    /// A notice came from the app: a sign of life. What is silent in it is looked at now and not at the end of the
    /// present wait: a new page can load in a web area whose last page had stopped, and the old copy would be read
    /// for up to half a minute. At most one such look in three seconds, so a hung page beside a busy toolbar is not
    /// asked at every notice.
    public static func heardFrom(pid: pid_t) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        var due: UInt64?
        if var stall = silence[pid], now &- stall.heardLookAt >= heardLookGapNs {
            stall.heardLookAt = now
            silence[pid] = stall
            due = stall.id
        }
        lock.unlock()
        guard let stallID = due, schedulesChecks else { return }
        checkQueue.asyncAfter(deadline: .now() + .milliseconds(300)) { check(pid: pid, continues: false, stallID: stallID) }
    }

    /// Questions asked directly and not counted: were they answered? A quick refusal (an element that has gone) is
    /// an answer; only a wait past the timeout is not. A web area is asked for its address too: that is the
    /// question browse mode asks of it, and a role alone answered proved nothing about it (a review, 11 Nov 2026).
    static func liveAnswer(_ pid: pid_t, _ element: AXUIElement?) -> Bool {
        let asked = element ?? AXUIElementCreateApplication(pid)
        if element == nil { AXUIElementSetMessagingTimeout(asked, 1.5) }
        func answer(_ name: String) -> (answered: Bool, value: CFTypeRef?) {
            var value: CFTypeRef?
            let t0 = DispatchTime.now().uptimeNanoseconds
            let error = AXUIElementCopyAttributeValue(asked, name as CFString, &value)
            let took = DispatchTime.now().uptimeNanoseconds &- t0
            let timedOut = error == .cannotComplete && took > timeoutNs
            return (!timedOut, value)
        }
        let role = answer(kAXRoleAttribute)
        guard role.answered else { return false }
        let isWebArea = element != nil && (role.value as? String) == "AXWebArea"
        return isWebArea ? answer("AXURL").answered : true
    }

    /// One look at an app in which something stopped answering. True when another look is due. `continues` false:
    /// a look between the regular ones (a notice arrived), which leaves their count and timing alone.
    @discardableResult
    package static func check(pid: pid_t, continues: Bool = true, stallID: UInt64? = nil,
                              now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) -> Bool {
        let began = now()
        lock.lock()
        guard let before = silence[pid] else { lock.unlock(); return false }
        // Queued for a stall that has ended: the one there now has its own looks.
        if let stallID, before.id != stallID { lock.unlock(); return false }
        // While the app itself is being asked, nobody else asks it: a key pressed in that moment would otherwise
        // wait out the timeout alongside this look.
        if (quietUntil[pid]?.until ?? 0) < began + restNs { quietUntil[pid] = Rest(until: began + restNs, reason: .timeout) }
        lock.unlock()
        guard processExists(pid) else { forget(pid: pid); return false }
        // Ten minutes on, nothing more is held against it: it is asked as any app is, and may be found silent again.
        guard began &- before.since < silenceLimitNs else { forget(pid: pid); return false }

        let appAnswers = answers(pid, nil)
        if appAnswers {
            // The app is there: its rest ends now, before any element is asked, so the rest of the app (Safari's
            // toolbar, beside a page that has stopped) is not kept waiting on the element's answer.
            lock.lock()
            let sameStall = silence[pid]?.id == before.id
            let noNewTimeoutSinceLookBegan = silence[pid]?.unanswered == before.unanswered
            if sameStall, noNewTimeoutSinceLookBegan, quietUntil[pid]?.reason == .timeout { quietUntil[pid] = nil }
            lock.unlock()
        }
        var answered: [ElementKey] = []
        if appAnswers {
            for key in inTurn(before.elements, attempt: before.attempt).prefix(asksPerLook) {
                if answers(pid, key.element) { answered.append(key) }
            }
        }

        let t = now()
        lock.lock()
        guard var stall = silence[pid], stall.id == before.id else { lock.unlock(); return false }   // forgotten, or another stall
        let seconds = Double(t &- stall.since) / 1_000_000_000
        // A question that went unanswered while this look ran is newer than anything the look heard.
        let noNewTimeoutSinceLookBegan = stall.unanswered == before.unanswered
        if appAnswers, noNewTimeoutSinceLookBegan {
            stall.elements.removeAll { answered.contains($0) }
        }
        if continues {
            stall.attempt = before.attempt + 1
            stall.nextLookAt = t + checkGapNs(attempt: stall.attempt)
        }
        if !appAnswers {
            // The whole app rests on, past the next regular look and that look's own wait for an answer; found by a
            // look in between as much as by a regular one (an app whose page was silent can stop altogether).
            let rest = Rest(until: stall.nextLookAt + restNs, reason: .timeout)
            if (quietUntil[pid]?.until ?? 0) < rest.until { quietUntil[pid] = rest }
        }
        let done = appAnswers && noNewTimeoutSinceLookBegan && stall.elements.isEmpty
        if done { silence[pid] = nil } else { silence[pid] = stall }
        lock.unlock()
        if done { onAnsweringAgain?(pid, seconds); return false }
        if continues {
            onStillSilent?(pid, seconds, appAnswers)
            scheduleCheck(pid: pid, attempt: stall.attempt, stallID: stall.id)
        }
        return true
    }

    // MARK: The slow drip
    // An app that answers every question, but each slowly: a Godot game in front answers once a frame, 50 to 130 ms a
    // question (measured, 18 Oct 2026). No single question times out, but a window coming forward asks dozens, and
    // TurnOver froze for 6 to 10 seconds while the watchdog stepped in. Slow
    // questions to one app are added up; past 1.2 s of them within 2 s, the app rests for 1.5 s (its questions fail at
    // once), as a timed-out app does. Apps with their own module (Word, Excel…) are exempt: they are slow by nature
    // and TurnOver is built round it.
    static let dripCallNs: UInt64 = 30_000_000
    static let dripWindowNs: UInt64 = 2_000_000_000
    static let dripLimitNs: UInt64 = 1_200_000_000
    static let dripRestNs: UInt64 = 1_500_000_000
    /// An app's slow time so far, and when the count began.
    public struct DripCount: Equatable, Sendable { public var start: UInt64; public var ns: UInt64 }
    nonisolated(unsafe) private static var drip: [pid_t: DripCount] = [:]   // under `lock`
    /// Called when a slow drip rests an app (the core logs it; nothing is said: the app is slow, not stuck, and "please
    /// wait" every few seconds in a game was noise: 18 Oct 2026).
    nonisolated(unsafe) public static var onSlowRest: (@Sendable (pid_t) -> Void)?   // set once at start
    /// Set by the core: true for an app TurnOver has a module of its own for (exempt from the drip rest).
    nonisolated(unsafe) public static var dripExempt: (@Sendable (pid_t) -> Bool)?   // set once at start

    /// One slow question added to an app's running total: the new total (nil once it trips) and whether it tripped.
    /// Pure, for the tests.
    public static func dripStep(_ state: DripCount?, now: UInt64, took: UInt64) -> (state: DripCount?, rest: Bool) {
        var d = state ?? DripCount(start: now, ns: 0)
        if now &- d.start > dripWindowNs { d = DripCount(start: now, ns: 0) }
        d.ns &+= took
        if d.ns > dripLimitNs { return (nil, true) }
        return (d, false)
    }

    static func noteDrip(pid: pid_t, ns: UInt64) {
        guard pid > 0, !(dripExempt?(pid) ?? false) else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let step = dripStep(drip[pid], now: now, took: ns)
        drip[pid] = step.state
        var tripped = false
        if step.rest {
            let current = quietUntil[pid].flatMap { $0.until > now ? $0 : nil }
            tripped = current == nil
            let candidate = Rest(until: now + dripRestNs, reason: .slowResponses)
            // The same timed-out call can trip the drip counter. Do not shorten its longer timeout rest or
            // misreport that provider failure as mere slow responses (diagnostic review, 28 Oct 2026, #166).
            if let current, current.until >= candidate.until { quietUntil[pid] = current }
            else { quietUntil[pid] = candidate }
        }
        lock.unlock()
        if tripped { onSlowRest?(pid) }
    }
}

/// How much is asked of applications: a count and the time spent, read by the script handler to log the
/// expensive scripts (8 Oct 2026, from the team review: measured, not guessed). Direct C calls elsewhere are
/// not counted; the bulk goes through here.
public enum AXStats {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _calls = 0        // under `lock`
    nonisolated(unsafe) private static var _ns: UInt64 = 0
    public static var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    public static var ms: Double { lock.lock(); defer { lock.unlock() }; return Double(_ns) / 1e6 }
    @inline(__always) static func note(_ ns: UInt64) { lock.lock(); _calls += 1; _ns &+= ns; lock.unlock() }
}

// An AXUIElement is a reference the accessibility client API answers from any thread (TurnOver's walks and polls
// run off the main thread by design): Swift 6 is told so here, once.
extension AXUIElement: @unchecked @retroactive Sendable {}
extension AXValue: @unchecked @retroactive Sendable {}

public extension AXUIElement {
    func attr(_ name: String) -> CFTypeRef? {
        if let snapshot = AXSnapshot.current { return snapshot.attribute(name, of: self) }
        var v: CFTypeRef?
        return AXHealth.ask(self) { AXUIElementCopyAttributeValue(self, name as CFString, &v) } == .success ? v : nil
    }
    func attrError(_ name: String) -> (CFTypeRef?, AXError) {
        if let snapshot = AXSnapshot.current { let v = snapshot.attribute(name, of: self); return (v, v == nil ? .noValue : .success) }
        var v: CFTypeRef?
        let e = AXHealth.ask(self) { AXUIElementCopyAttributeValue(self, name as CFString, &v) }
        return (v, e)
    }
    func string(_ name: String) -> String? { attr(name) as? String }
    /// Several attributes in one question to the app (SwiftUI apps answer each question in about 4 ms: Contacts,
    /// 10 Oct 2026; one question for five is three times faster). Missing or failed ones are absent.
    func attrs(_ names: [String]) -> [String: AnyObject] {
        if let snapshot = AXSnapshot.current { return Dictionary(uniqueKeysWithValues: names.compactMap { n in snapshot.attribute(n, of: self).map { (n, $0) } }) }
        var out: CFArray?
        guard AXHealth.ask(self, { AXUIElementCopyMultipleAttributeValues(self, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &out) }) == .success,
              let values = out as? [AnyObject], values.count == names.count else { return [:] }
        var d: [String: AnyObject] = [:]
        for (n, v) in zip(names, values) {
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { continue }
            d[n] = v
        }
        return d
    }
    func int(_ name: String) -> Int? { (attr(name) as? NSNumber)?.intValue }
    func element(_ name: String) -> AXUIElement? {
        guard let v = attr(name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    func elements(_ name: String) -> [AXUIElement] {
        let all = (attr(name) as? [AXUIElement]) ?? []
        guard name == kAXChildrenAttribute, ForeignChildren.contains(pid), string(kAXRoleAttribute) == "AXWindow" else { return all }
        return ForeignChildren.own(all, of: self)
    }
    var role: String { string(kAXRoleAttribute) ?? "?" }

    func param(_ name: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXHealth.ask(self) { AXUIElementCopyParameterizedAttributeValue(self, name as CFString, parameter, &v) } == .success ? v : nil
    }
    func paramError(_ name: String, _ parameter: CFTypeRef) -> (CFTypeRef?, AXError) {
        var v: CFTypeRef?
        let e = AXHealth.ask(self) { AXUIElementCopyParameterizedAttributeValue(self, name as CFString, parameter, &v) }
        return (v, e)
    }
    func set(_ name: String, _ value: CFTypeRef) -> AXError {
        AXHealth.ask(self) { AXUIElementSetAttributeValue(self, name as CFString, value) }
    }

    var pid: pid_t {
        var p: pid_t = 0
        AXUIElementGetPid(self, &p)
        return p
    }

    /// Breadth-first search for the first descendant with a role, bounded.
    func firstDescendant(role wanted: String, maxVisited: Int = 5000) -> AXUIElement? {
        var queue: [AXUIElement] = [self]
        var visited = 0
        while !queue.isEmpty && visited < maxVisited {
            let e = queue.removeFirst()
            visited += 1
            if e.role == wanted { return e }
            queue.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
        return nil
    }
}

/// An element as a dictionary key or set member: equal when the accessibility API says the two refer to the same
/// thing (CFEqual), which two `AXUIElement` objects for one control do.
public struct ElementKey: Hashable, Sendable {
    public let element: AXUIElement
    public init(_ e: AXUIElement) { element = e }
    public static func == (a: ElementKey, b: ElementKey) -> Bool { CFEqual(a.element, b.element) }
    public func hash(into h: inout Hasher) { h.combine(CFHash(element)) }
}

/// A point, size, rect or range out of an accessibility value, only if it is one, of that type: an app handing back
/// another kind of object (accessibility trees are not always what they say) is refused here rather than reaching
/// AXValueGetValue, which isn't safe with it (a code review on 18 Oct 2026, from an outside review).
/// Unread (false), `out` keeps what it had: callers that start from zero carry on with zero.
@discardableResult
public func axValue<T: BitwiseCopyable>(_ v: CFTypeRef?, _ type: AXValueType, _ out: inout T) -> Bool {
    guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return false }
    let value = v as! AXValue   // checked: an AXValue
    guard AXValueGetType(value) == type else { return false }
    return withUnsafeMutablePointer(to: &out) { AXValueGetValue(value, type, $0) }
}

/// An accessibility element, only if the object is one.
public func axElement(_ v: CFTypeRef?) -> AXUIElement? {
    guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)   // checked: an AXUIElement
}

public func cfRange(_ v: CFTypeRef?) -> CFRange? {
    guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var r = CFRange()
    return axValue(v, .cfRange, &r) ? r : nil
}

public func axRangeValue(_ location: Int, _ length: Int) -> AXValue {
    var r = CFRange(location: location, length: length)
    return AXValueCreate(.cfRange, &r)!
}

public func describeError(_ e: AXError) -> String {
    switch e {
    case .success: return "success"
    case .cannotComplete: return "cannotComplete(-25204)"
    case .attributeUnsupported: return "attributeUnsupported(-25205)"
    case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported(-25213)"
    case .noValue: return "noValue(-25212)"
    case .notImplemented: return "notImplemented(-25208)"
    case .invalidUIElement: return "invalidUIElement(-25202)"
    case .apiDisabled: return "apiDisabled(-25211)"
    default: return "error(\(e.rawValue))"
    }
}

/// Applications whose windows each list every window's elements as children (Qt Quick's, built on MuseScore's
/// framework: Audacity 4's plugin question held the main window's buttons and slider too, so Tab went from "Skip this
/// time" to "Playback volume", and two copies of each of its buttons kept VO-Right on "Skip this time"; parts sweep,
/// 14 Oct 2026). Each element's own AXParent is right: such an app's window children are cut to those whose parent is
/// the window, without exact copies. Found per app as its windows appear (`check`); other apps pay nothing.
public enum ForeignChildren {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pids = Set<pid_t>()   // under `lock`
    public static func contains(_ pid: pid_t) -> Bool { lock.lock(); defer { lock.unlock() }; return pids.contains(pid) }

    nonisolated(unsafe) private static var notQt = Set<pid_t>()   // under `lock`: apps with no Qt framework, never checked again

    /// Looks at the app's windows (two or more): one listing an element whose parent is another window marks the app.
    /// Only Qt apps are looked at (a Qt framework in the bundle, read once per app): every other app pays one folder
    /// listing, once, and never an accessibility question (15 Oct 2026, after the Dock regression: no new cost in the
    /// paths every app goes through).
    public static func check(pid: pid_t) {
        guard !contains(pid) else { return }
        lock.lock(); let skip = notQt.contains(pid); lock.unlock()
        if skip { return }
        let frameworks = NSRunningApplication(processIdentifier: pid)?.bundleURL
            .flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.appendingPathComponent("Contents/Frameworks").path) } ?? []
        guard frameworks.contains(where: { $0.hasPrefix("Qt") }) else { lock.lock(); notQt.insert(pid); lock.unlock(); return }
        let windows = AXUIElementCreateApplication(pid).elements(kAXWindowsAttribute)
        guard windows.count >= 2 else { return }
        for w in windows.prefix(4) {
            for c in ((w.attr(kAXChildrenAttribute) as? [AXUIElement]) ?? []).prefix(40) {
                if let p = c.element(kAXParentAttribute), p.string(kAXRoleAttribute) == "AXWindow", !CFEqual(p, w) {
                    lock.lock(); pids.insert(pid); lock.unlock()
                    return
                }
            }
        }
    }

    public static func forget(_ pid: pid_t) { lock.lock(); pids.remove(pid); notQt.remove(pid); lock.unlock() }

    /// The window's own children, each once.
    static func own(_ all: [AXUIElement], of window: AXUIElement) -> [AXUIElement] {
        var seen = Set<String>()
        var out: [AXUIElement] = []
        for c in all {
            let a = c.attrs([kAXParentAttribute, kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXPositionAttribute, kAXSizeAttribute])
            if let p = a[kAXParentAttribute], CFGetTypeID(p) == AXUIElementGetTypeID(), !CFEqual(p as! AXUIElement, window) { continue }
            func text(_ v: AnyObject?) -> String {
                guard let v else { return "" }
                if CFGetTypeID(v) == AXValueGetTypeID() {
                    var p = CGPoint.zero, z = CGSize.zero
                    if axValue(v, .cgPoint, &p) { return "\(p.x),\(p.y)" }
                    if axValue(v, .cgSize, &z) { return "\(z.width)x\(z.height)" }
                }
                return "\(v)"
            }
            let key = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXPositionAttribute, kAXSizeAttribute].map { text(a[$0]) }.joined(separator: "|")
            if !seen.insert(key).inserted { continue }
            out.append(c)
        }
        return out
    }
}
