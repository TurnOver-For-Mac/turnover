// SPDX-License-Identifier: GPL-3.0-or-later
// Waiting for an application, in one place (8 Oct 2026, from the team review).
//
// Two kinds of wait. `pumping` is the short, synchronous one a script uses on the main thread while it waits for
// the caret or a menu to move: it keeps TurnOver's own events flowing and is always bounded. `until` is for the
// long ones (a page scrolling into place, a sidebar opening): it looks on a background queue and comes back to
// the main thread, so speech and the watchdog's heartbeat never wait with it.
import Foundation

public enum Poll {
    /// Main thread. Looks every `every` seconds, pumping TurnOver's events between looks, until `condition` is true
    /// or `limit` has passed. Returns whether the condition came true.
    @discardableResult
    public static func pumping(every: TimeInterval = 0.005, limit: TimeInterval, _ condition: () -> Bool) -> Bool {
        let start = Date()
        while true {
            EventHandler.pumpPendingEvents()
            if condition() { return true }
            if Date().timeIntervalSince(start) >= limit { return false }
            usleep(useconds_t(every * 1_000_000))
        }
    }

    /// Any thread. Looks on a background queue every `every` seconds until `condition` is true or `limit` has
    /// passed, then calls `then` on the main thread with whether it came true. `afterWait`, if given, is called on
    /// the main thread once if the wait goes past `waitNotice` seconds ("please wait").
    public static func until(every: TimeInterval = 0.15, limit: TimeInterval, waitNotice: TimeInterval = 0.6, afterWait: (@MainActor () -> Void)? = nil,
                             _ condition: @escaping @Sendable () -> Bool, then: @escaping @MainActor (Bool) -> Void) {
        let start = Date()
        let noticed = Locked(false)
        @Sendable nonisolated func look() {
            if condition() { DispatchQueue.main.async { then(true) }; return }
            let waited = Date().timeIntervalSince(start)
            if waited >= limit { DispatchQueue.main.async { then(false) }; return }
            if !noticed.value, waited >= waitNotice, let afterWait { noticed.value = true; DispatchQueue.main.async { afterWait() } }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + every, execute: look)
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: look)
    }

    /// Background work with its result on the main thread, and "please wait" said if it takes longer than
    /// `waitNotice` seconds: for a view's build, a document map, anything that asks an application hundreds of
    /// questions.
    public static func background<T: Sendable>(waitNotice: TimeInterval = 0.6, notice: String = "please wait", _ work: @escaping @Sendable () -> T, then: @escaping @MainActor (T) -> Void) {
        let done = Locked(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + waitNotice) { if !done.value { Speech.speakMessage(notice, remember: false) } }
        DispatchQueue.global(qos: .userInitiated).async {
            let r = work()
            DispatchQueue.main.async { done.value = true; then(r) }
        }
    }
}
