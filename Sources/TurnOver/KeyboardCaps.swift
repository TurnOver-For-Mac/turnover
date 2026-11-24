// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import TurnOverCore

extension KeyboardHandler {
    nonisolated func capsAllowed(_ settings: KeySettings) -> Bool {
        settings.capsIsTurnOver || capsPress.retainedFallback(settings: settings)
    }
    nonisolated func capsFlags(_ event: CGEvent, _ settings: KeySettings) -> Bool {
        let owned = capsPress.capturesFlags(at: event.timestamp, settings: settings)
        if !owned { realCapsOn = event.flags.contains(.maskAlphaShift) }
        return owned
    }
    nonisolated func capsChanged(pressed: Bool, timestamp: UInt64) {
        let owned = capsPress.update(down: pressed, timestamp: timestamp, settings: KeySettings.current)
        capsDown = pressed && owned
        Self.capsHeld.value = capsPress
        guard owned else { lastCapsUp = 0; chordFired = false; return }
        setLock(realCapsOn)
        if pressed { chordFired = false }
        else {
            let sinceLastUp = Double(timestamp &- lastCapsUp) / 1_000_000
            let hadPrevious = lastCapsUp != 0
            lastCapsUp = timestamp
            if !chordFired && hadPrevious && sinceLastUp < 350 {
                realCapsOn.toggle()
                setLock(realCapsOn)
                let on = realCapsOn
                let toggled = onCapsLockToggled
                onMain { toggled?(on) }
            }
        }
    }
}
