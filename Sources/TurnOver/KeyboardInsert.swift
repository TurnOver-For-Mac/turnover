// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import TurnOverCore

extension KeyboardHandler {
    nonisolated func handleSleepingInsert(_ type: CGEventType, _ event: CGEvent, _ settings: KeySettings, allowCapture: Bool = true) -> Bool {
        let front = WindowsRemap.frontApp
        let asleep = allowCapture && InputManager.isAsleep(bundle: front.bundle) && !InputManager.isCapturing && !TurnOverMenu.anyOpen.value
        if asleep { insertKey.update(enabled: false, keypadEnabled: settings.keypadCommands); Self.insertHeld.value = false; Self.separateInsertHeld.value = false }
        let disposition = KeypadApplicationDelivery.routeSleeping(owner: ObjectIdentifier(self), type: type, event: event, asleep: asleep,
                                                                   enabled: allowCapture && settings.insertIsTurnOver && !InputManager.passNextKey,
                                                                   keypadEnabled: settings.keypadCommands, pid: front.pid)
        switch disposition {
        case .pass: return false
        case .consume: return true
        case .wake:
            let g = KeyboardGesture(keyCode: 6, modifiers: [.turnover, .shift], characters: "z", timestamp: 0, isRepeat: false, flags: .maskShift)
            _ = ScriptHandler.askMain(g)
            return true
        }
    }

    /// Runs only on the keyboard thread, using the same snapshot as the rest of this event.
    nonisolated func handleInsert(_ type: CGEventType, _ event: CGEvent, _ settings: KeySettings) -> Bool {
        insertKey.update(enabled: settings.insertIsTurnOver && !InputManager.passNextKey && !InputManager.isAsleep(bundle: WindowsRemap.front),
                         keypadEnabled: settings.keypadCommands)
        let repeatKey = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let taken = insertKey.handle(type, code: event.getIntegerValueField(.keyboardEventKeycode), isRepeat: repeatKey)
        Self.insertHeld.value = insertKey.isHeld
        Self.separateInsertHeld.value = insertKey.separateInsertIsHeld
        if taken, type == .keyDown, !repeatKey, InputManager.isInputHelpActive {
            onMain { Speech.speakMessage(String(localized: "insert, the TurnOver key", comment: "Keyboard help: Insert or number-pad zero as the reader modifier")) }
        }
        return taken
    }
}
