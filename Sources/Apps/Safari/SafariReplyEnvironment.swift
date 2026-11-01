// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import AppKit

/// Safari's delayed replies stay main-owned. The package-only environment lets tests hold actual script
/// callbacks and change the reader/app context without launching Safari, driving keys or starting a reader.
package struct SafariReplyEnvironment {
    package let isCurrent: @MainActor (pid_t) -> Bool
    package let keyCount: @Sendable () -> Int
    package let after: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void
    package let poll: @MainActor (@escaping @Sendable () -> Bool, @escaping @MainActor (Bool) -> Void) -> Void

    package init(isCurrent: @escaping @MainActor (pid_t) -> Bool = { pid in
        Core.active && API.focusPid == pid && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            && !AXHandler.shared.isMenuOpen && !TurnOverMenu.shared.isOpen
            && InputManager.directPid != pid && !InputManager.isAsleep(pid)
    }, keyCount: @escaping @Sendable () -> Int = { ScriptHandler.keysArrivedCount },
    after: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, reply in
        onMain(after: delay, reply)
    }, poll: @escaping @MainActor (@escaping @Sendable () -> Bool, @escaping @MainActor (Bool) -> Void) -> Void = { condition, reply in
        Poll.until(every: 0.05, limit: 1.0, waitNotice: 5, condition, then: reply)
    }) {
        self.isCurrent = isCurrent; self.keyCount = keyCount; self.after = after; self.poll = poll
    }
}
