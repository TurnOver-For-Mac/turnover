// SPDX-License-Identifier: GPL-3.0-or-later
// TurnOver Key's watch on TurnOver (Sources/TurnOverKey/main.swift): which of TurnOver's processes its look, once a
// second, saw last, and which are being quit on purpose. Pure, for the tests: TurnOverControl is the one library that
// both TurnOver Key and the tests link.
import Darwin

package struct ReaderWatch {
    /// TurnOver's processes at the last look.
    package private(set) var seen: Set<pid_t>
    /// The TurnOvers being quit on purpose, remembered as each is quit, not found by the look: a TurnOver started and
    /// quit between two looks was never seen to end, so its quit stayed set and Command Control Period did nothing
    /// (the maintainer, 28 Oct 2026). Each is let go once it is no longer running, seen or not.
    package private(set) var quitting: Set<pid_t> = []

    package init(seen: Set<pid_t> = []) { self.seen = seen }

    /// Command Control Period quits this one.
    package mutating func quit(_ pid: pid_t) { quitting.insert(pid) }

    /// TurnOver says it is quitting (the menu, Command Q) but not which one: every TurnOver running now, or at the last
    /// look (one may already be gone from the list before its notice is read).
    package mutating func quitAnnounced(running: Set<pid_t>) { quitting.formUnion(running.union(seen)) }

    package func isQuitting(_ pid: pid_t) -> Bool { quitting.contains(pid) }

    /// What a look found gone.
    package struct Ended: Equatable {
        /// One being quit: on purpose, whether or not a look saw it.
        package var quit = false
        /// One a look saw, not being quit: a crash, or a restart.
        package var stopped = false
        package init(quit: Bool = false, stopped: Bool = false) { self.quit = quit; self.stopped = stopped }
    }

    /// The look, with the processes running now. One gone is an end even if another TurnOver has started since
    /// (Command Control Period pressed again just after a quit, 28 Oct 2026).
    package mutating func look(_ running: Set<pid_t>) -> Ended {
        let quit = quitting.subtracting(running)
        quitting.subtract(quit)
        let stopped = seen.subtracting(running).subtracting(quit)
        seen = running
        return Ended(quit: !quit.isEmpty, stopped: !stopped.isEmpty)
    }
}
