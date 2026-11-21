// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics

/// A log line to settle why a TurnOver key went missing (16 Nov 2026). On 15 Nov 2026 (19:31 to 19:32 UTC), with the
/// Command-Tab switcher open, VoiceOver's previous-heading key was named `kb:command+shift+h`, without the TurnOver
/// key, and at 20:33 `control+command+shift+h` had Control but not Option. TurnOver names a key's modifiers from that
/// key event's own flags (KeyboardHandler); it keeps no record of Control or Option that could be dropped. So either
/// the event arrived without them or the hand did not hold them. The line puts the event's flags beside what the
/// keyboard holds at that moment, only when the switcher is open or the keyboard holds both Control and Option while
/// the key was not named a TurnOver key. Typed keys stay masked (logDescription).
public enum KeyboardModifierDiagnostics {
    nonisolated public static func line(for gesture: KeyboardGesture, keyboardFlags: CGEventFlags,
                                        controlOptionIsTurnOver: Bool, switcherOpen: Bool) -> String? {
        let keyboardHoldsControlOption = keyboardFlags.contains(.maskControl) && keyboardFlags.contains(.maskAlternate)
        let namedTurnOver = gesture.modifiers.contains(.turnover)
        let turnOverKeyLost = controlOptionIsTurnOver && keyboardHoldsControlOption && !namedTurnOver
        guard switcherOpen || turnOverKeyLost else { return nil }
        let eventFlags = String(gesture.flags.rawValue & 0xFFFF0000, radix: 16)
        let held = String(keyboardFlags.rawValue & 0xFFFF0000, radix: 16)
        var line = "key modifiers: \(gesture.logDescription()) from event flags 0x\(eventFlags); the keyboard holds 0x\(held)"
        if switcherOpen { line += "; application switcher open" }
        if turnOverKeyLost { line += "; Control and Option held but not named the TurnOver key" }
        return line
    }

    /// From the main thread, as each key is decided (InputManager.handleKeyDown).
    public static func record(_ gesture: KeyboardGesture) {
        let switcherOpen = API.focusObject is AppSwitcherList
        let keyboardFlags = CGEventSource.flagsState(.hidSystemState)
        let controlOptionIsTurnOver = KeySettings.current.controlOptionIsTurnOver
        if let line = line(for: gesture, keyboardFlags: keyboardFlags, controlOptionIsTurnOver: controlOptionIsTurnOver,
                           switcherOpen: switcherOpen) {
            Log.io(line)
        }
    }
}
