// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import TurnOverCore

// Final application delivery and held-key continuation belong to the keyboard worker.
extension KeyboardHandler {
    nonisolated func passOrRedirect(_ event: CGEvent, to owner: Int32? = nil,
                                    recording code: Int64? = nil, flags: CGEventFlags = []) -> Unmanaged<CGEvent>? {
        // Resolve once: ownership and posting must agree even if the foreground changes meanwhile.
        let destination = owner ?? Self.redirectPid ?? Self.arrowTarget(code: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags)
        if let code {
            KeypadApplicationDelivery.deliverDown(owner: ObjectIdentifier(self), code: code, flags: flags, event: event, pid: destination)
            keypadRouter.passedToApplication(code: code)
            return destination == nil ? Unmanaged.passUnretained(event) : nil
        }
        guard let destination else { return Unmanaged.passUnretained(event) }
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        event.postToPid(destination)
        return nil
    }

    nonisolated func tapEvent(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return Unmanaged.passUnretained(event) }
        if let continuation = KeypadApplicationDelivery.continueEvent(owner: ObjectIdentifier(self), type, event) { return continuation }
        let code = event.getIntegerValueField(.keyboardEventKeycode), flags = event.flags
        let result = dispatchEvent(type, event)
        if type == .keyDown, let delivered = result?.takeUnretainedValue() {
            KeypadApplicationDelivery.deliverDown(owner: ObjectIdentifier(self), code: code, flags: flags, event: delivered)
            keypadRouter.passedToApplication(code: code)
        }
        return result
    }

}
