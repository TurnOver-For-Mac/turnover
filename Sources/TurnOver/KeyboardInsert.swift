// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import TurnOverCore

extension KeyboardHandler {
    nonisolated func handleSleepingInsert(_ type: CGEventType, _ event: CGEvent, _ settings: KeySettings, allowCapture: Bool = true) -> Bool {
        let front = WindowsRemap.frontApp
        let asleep = allowCapture && InputManager.isAsleep(bundle: front.bundle) && !InputManager.isCapturing && !TurnOverMenu.anyOpen.value
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
        let enabled = settings.insertIsTurnOver
            && !InputManager.passNextKey
            && !InputManager.isAsleep(bundle: WindowsRemap.front)
        let repeatKey = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let decision = InsertModifier.handle(type, event: event, enabled: enabled, settings: settings)
        insertForEvent = decision.held
        let taken = decision.consumed
        if taken, type == .keyDown, !repeatKey, InputManager.isInputHelpActive {
            onMain { Speech.speakMessage(String(localized: "insert, the TurnOver key", comment: "Keyboard help: Insert or number-pad zero as the reader modifier")) }
        }
        return taken
    }
}
