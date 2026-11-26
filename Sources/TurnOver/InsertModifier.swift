// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import TurnOverCore

/// One owner for both taps: handover changes the reader, not the physical key press.
/// Every state access is under state.lock, including HID reconciliation and settings changes.
nonisolated enum InsertModifier {
    private static let state = Locked(InsertKeyState())

    private static func hardwareIsDown(_ code: Int64) -> Bool {
        CGEventSource.keyState(.hidSystemState, key: CGKeyCode(code))
    }

    static func continueEvent(_ type: CGEventType, event: CGEvent) -> Bool {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard code == 82 || code == 114 else { return false }
        state.lock.lock()
        defer { state.lock.unlock() }
        let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let settings = KeySettings.current
        state.unsafeValue.update(enabled: settings.insertIsTurnOver, keypadEnabled: settings.keypadCommands)
        let timestamp = KeyboardEventTime.quartzNanoseconds(event.timestamp)
        let freshDown = type == .keyDown && !repeated
        let overlappingDown = freshDown && InsertHardware.overlapsDown(code, at: timestamp)
        var stillHeld = false
        if type == .keyUp {
            let current = hardwareIsDown(code)
            stillHeld = InsertHardware.observedDown(code, at: timestamp, currentDown: current, after: state.unsafeValue.capturedAt(code)) ?? current
        }
        return state.unsafeValue.continuePress(type, code: code, isRepeat: repeated, stillHeld: stillHeld, overlappingDown: overlappingDown)
    }

    /// Live gestures use a reconciled copy; they cannot erase history needed by a queued keyboard chord.
    static func snapshot() -> InsertKeyState {
        let settings = KeySettings.current
        state.lock.lock()
        defer { state.lock.unlock() }
        state.unsafeValue.update(enabled: settings.insertIsTurnOver, keypadEnabled: settings.keypadCommands)
        var snapshot = state.unsafeValue
        snapshot.reconcile(isDown: hardwareIsDown)
        return snapshot
    }

    struct Decision {
        let consumed: Bool
        let held: Bool
    }

    static func handle(_ type: CGEventType, event: CGEvent, enabled: Bool, settings: KeySettings) -> Decision {
        state.lock.lock()
        defer { state.lock.unlock() }
        state.unsafeValue.update(enabled: enabled, keypadEnabled: settings.keypadCommands)
        let timestamp = KeyboardEventTime.quartzNanoseconds(event.timestamp)
        let captured = state.unsafeValue
        state.unsafeValue.reconcile { code in
            let current = hardwareIsDown(code)
            // Incomplete history falls back to current HID state to avoid a stuck reader modifier.
            if let observed = InsertHardware.observedDown(code, at: timestamp, currentDown: current, after: captured.capturedAt(code)) { return observed }
            if !current { Log.io("Insert physical history incomplete: reconciling to current released state") }
            return current
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let repeatKey = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let consumed = state.unsafeValue.handle(type, code: code, isRepeat: repeatKey, timestamp: timestamp)
        return Decision(consumed: consumed, held: state.unsafeValue.isHeld)
    }
}
