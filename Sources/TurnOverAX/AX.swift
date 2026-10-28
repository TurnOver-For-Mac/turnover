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
/// to it fail at once instead of waiting. Then it is asked again.
public enum AXHealth {
    private static let lock = NSLock()
    private struct Rest { let until: UInt64; let reason: AXBackoff.Reason }
    // Swift cannot express static NSLock ownership. Every access, including setup, expiry and cleanup, holds lock.
    nonisolated(unsafe) private static var quietUntil: [pid_t: Rest] = [:]
    /// Called (on whatever thread asked) when an application is found not answering; once per stall.
    nonisolated(unsafe) public static var onUnresponsive: (@Sendable (pid_t) -> Void)?   // set once at start
    static let restNs: UInt64 = 3_000_000_000

    static func isResting(_ pid: pid_t) -> Bool {
        backoff(for: pid) != nil
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
    static func note(_ error: AXError, pid: pid_t, ns: UInt64) {
        guard error == .cannotComplete, ns > 900_000_000, pid > 0 else { return }
        lock.lock()
        let fresh = quietUntil[pid] == nil
        quietUntil[pid] = Rest(until: DispatchTime.now().uptimeNanoseconds + restNs, reason: .timeout)
        lock.unlock()
        if fresh { onUnresponsive?(pid) }
    }

    /// Ask, unless the application is resting; note a timeout, or a slow drip.
    @inline(__always) static func ask(_ element: AXUIElement, _ body: () -> AXError) -> AXError {
        query(element, policy: .respectBackoff, body).legacyError
    }

    static func query(_ element: AXUIElement, policy: AXQueryPolicy, _ body: () -> AXError) -> AXQueryExecution {
        var p: pid_t = 0
        AXUIElementGetPid(element, &p)
        return query(pid: p, policy: policy, body)
    }

    /// The clock/provider seam is package-only: tests exercise the same admission/accounting without sleeping
    /// or delaying a real app. Calls and callbacks still run outside the health lock (28 Oct 2026, #166).
    package static func query(pid p: pid_t, policy: AXQueryPolicy = .respectBackoff,
                              clock: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
                              _ body: () -> AXError) -> AXQueryExecution {
        if policy == .respectBackoff, let rest = backoff(for: p) {
            return AXQueryExecution(status: .deferred(rest), elapsedNanoseconds: 0, wasAttempted: false)
        }
        let t0 = clock()
        let e = body()
        let took = clock() &- t0
        AXStats.note(took)
        if e == .cannotComplete { note(e, pid: p, ns: took) }
        if took > dripCallNs { noteDrip(pid: p, ns: took) }
        return AXQueryExecution(status: .returned(e), elapsedNanoseconds: took, wasAttempted: true)
    }

    package static func forget(pid: pid_t) {
        lock.lock(); quietUntil[pid] = nil; drip[pid] = nil; lock.unlock()
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
        var v: CFTypeRef?
        return AXHealth.ask(self) { AXUIElementCopyAttributeValue(self, name as CFString, &v) } == .success ? v : nil
    }
    func attrError(_ name: String) -> (CFTypeRef?, AXError) {
        var v: CFTypeRef?
        let e = AXHealth.ask(self) { AXUIElementCopyAttributeValue(self, name as CFString, &v) }
        return (v, e)
    }
    func string(_ name: String) -> String? { attr(name) as? String }
    /// Several attributes in one question to the app (SwiftUI apps answer each question in about 4 ms: Contacts,
    /// 10 Oct 2026; one question for five is three times faster). Missing or failed ones are absent.
    func attrs(_ names: [String]) -> [String: AnyObject] {
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
public struct ElementKey: Hashable {
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
