// SPDX-License-Identifier: GPL-3.0-or-later
// The few settings the keyboard thread needs, as a snapshot (8 Oct 2026, from the team review).
//
// `config` is written on the main thread; the keyboard tap used to read it directly from its own thread while
// a setting could be changing under it. The tap reads this value type instead: the main thread refreshes it
// after loading, after every save and after every script, and the tap takes a copy under a lock.
import Foundation

nonisolated public struct KeySettings: Sendable {
    public var capsIsTurnOver = true
    public var controlOptionIsTurnOver = true
    public var windowsKeys = false
    public var speakCommandKeys = true
    public var optionCommander = true
    public var numpadCommander = false
    public var keypadCommands = true
    public var userGestureIdentifiers: Set<String> = []
    public var layout = "laptop"

    public func hasUserGesture(_ gesture: KeyboardGesture) -> Bool {
        let id = gesture.identifier
        return userGestureIdentifiers.contains(id) || userGestureIdentifiers.contains("kb(\(layout)):" + id.dropFirst(3))
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _current = KeySettings()   // under `lock`

    /// A copy for the keyboard thread. Any thread.
    public static var current: KeySettings { lock.lock(); defer { lock.unlock() }; return _current }

    /// Take the values from `config`. Main thread.
    @MainActor public static func refresh() {
        let s = KeySettings(capsIsTurnOver: config.general.capsIsTurnOver, controlOptionIsTurnOver: config.general.controlOptionIsTurnOver,
                            windowsKeys: config.general.windowsKeys, speakCommandKeys: config.keyboard.speakCommandKeys,
                            optionCommander: config.keyboard.optionCommander, numpadCommander: config.keyboard.numpadCommander,
                            keypadCommands: config.keyboard.keypadCommands,
                            userGestureIdentifiers: Set(config.keyboard.userGestures.keys), layout: config.keyboard.layout)
        lock.lock(); _current = s; lock.unlock()
    }
}
