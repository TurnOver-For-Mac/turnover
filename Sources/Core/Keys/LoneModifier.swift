// SPDX-License-Identifier: GPL-3.0-or-later
// A modifier key pressed and let go on its own is a command of its own: in the Windows style Shift pauses speech,
// Command opens the menu bar and Option the Dock or the shortcut menu. The keyboard thread keeps one of these a key:
// KeyboardHandler, and WindowsKeyLayer for Command and Option where VoiceOver reads.
//
// While secure input is on the key tap gets the modifiers but never a key (LeadWatcher, 10 Oct 2026), so a modifier
// let go after a shortcut looked pressed on its own: while Chrome held secure input after a sign-in, Command Tab and
// Command A opened the menu bar, six times of six (macOS 27.2, JAWS keys, 31 Oct 2026). A modifier is on its own only
// with secure input off both as it goes down and as it comes up. Control, which stops speech (pauses it in the Mac
// style), keeps its own flag in KeyboardHandler and no such rule: it is all there is to quiet speech then (1 Nov 2026).
import Foundation

nonisolated public struct LoneModifier: Sendable {
    private var alone = false
    private var downAt = Date.distantPast

    public init() {}

    /// It went down. `alone`: nothing is held with it that rules a press on its own out (each key has its own rule).
    public mutating func down(alone: Bool, secureInput: Bool, at now: Date = Date()) {
        self.alone = alone && !secureInput
        downAt = now
    }

    /// Another key or modifier came while it was held.
    public mutating func cancel() { alone = false }

    /// It came up: whether it was pressed on its own, and let go within 0.6 s.
    public mutating func up(secureInput: Bool, at now: Date = Date()) -> Bool {
        defer { alone = false }
        return alone && !secureInput && now.timeIntervalSince(downAt) < 0.6
    }
}
