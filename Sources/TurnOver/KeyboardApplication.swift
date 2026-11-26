// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreGraphics
import TurnOverCore

// Final application delivery and held-key continuation belong to the keyboard worker.
extension KeyboardHandler {
    /// The toggle's key code, read once (with the shortcut from macOS's defaults) before the tap is created, never on
    /// the first key.
    nonisolated static let toggleKeyCode = Int64(voiceOverToggle.keyCode)

    nonisolated static func characters(of event: CGEvent) -> String {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &chars)
        return String(utf16CodeUnits: chars, count: length)
    }

    /// A key down that is VoiceOver's toggle shortcut, pressed by the person: not one TurnOver posted (its own toggle
    /// and its re-posted keys carry a marker), and not a key repeat.
    /// The key code alone is read first, against one already read at the tap's start (`toggleKeyCode`); only the toggle's
    /// own key reads anything more (Codex's third review, 18 Nov 2026: as little as possible on the tap's thread).
    nonisolated static func notePersonToggle(_ event: CGEvent) {
        guard event.getIntegerValueField(.keyboardEventKeycode) == toggleKeyCode else { return }
        let source = event.getIntegerValueField(.eventSourceUserData)
        guard source != marker else { return }
        guard source != orderedMarker else { return }
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
        guard isVoiceOverToggle(code: toggleKeyCode, flags: event.flags) else { return }
        HandOver.personToggle.pressed()
    }

    nonisolated func passOrRedirect(_ event: CGEvent, to owner: Int32? = nil,
                                    recording code: Int64? = nil, flags: CGEventFlags = []) -> Unmanaged<CGEvent>? {
        // Resolve once: ownership and posting must agree even if the foreground changes meanwhile.
        let destination = owner ?? Self.redirectPid ?? Self.arrowTarget(code: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags)
        if let code {
            let queued = KeypadApplicationDelivery.deliverDown(owner: ObjectIdentifier(self), code: code, flags: flags, event: event, pid: destination)
            keypadRouter.passedToApplication(code: code)
            return queued ? nil : Unmanaged.passUnretained(event)
        }
        guard let destination else { return Unmanaged.passUnretained(event) }
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        KeypadApplicationDelivery.state.lock.lock()
        KeypadApplicationDelivery.postOrQueue(event, pid: destination)
        KeypadApplicationDelivery.state.lock.unlock()
        return nil
    }

    nonisolated func tapEvent(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        // Preserve upstream's observation before retirement, bypass and continuation routing.
        if type == .keyDown { Self.notePersonToggle(event) }
        // Ordered script output joins preceding replay before acknowledgement releases later
        // script work. It is application output, not a new physical Insert/keypad press.
        if event.getIntegerValueField(.eventSourceUserData) == Self.orderedMarker {
            if type == .keyDown,
               event.getIntegerValueField(.keyboardEventKeycode) == 48,
               event.flags.contains(.maskCommand) {
                clearLeftoverModifiers(before: "Command Tab")
            }
            let result = passOrRedirect(event)
            let queued = result.map { KeypadApplicationDelivery.deferSession($0.takeUnretainedValue()) } ?? false
            if type == .keyDown { ScriptHandler.orderedKeySeen() }
            return queued ? nil : result
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return Unmanaged.passUnretained(event) }
        if InsertModifier.continueEvent(type, event: event) {
            cancelLoneModifiers()
            return nil
        }
        if let continuation = KeypadApplicationDelivery.continueEvent(owner: ObjectIdentifier(self), type, event) {
            cancelLoneModifiers()
            return continuation
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode), flags = event.flags
        let result = dispatchEvent(type, event)
        if type == .keyDown, let delivered = result?.takeUnretainedValue() {
            let queued = KeypadApplicationDelivery.deliverDown(owner: ObjectIdentifier(self), code: code, flags: flags, event: delivered)
            keypadRouter.passedToApplication(code: code)
            if queued { return nil }
        }
        if let delivered = result?.takeUnretainedValue(),
           KeypadApplicationDelivery.deferSession(delivered) { return nil }
        return result
    }
    // Keep upstream's deferred remapping with application delivery, so the keyboard handler stays focused.
    nonisolated static func switcherPreparation(settings: KeySettings, modifiers: Modifiers)
        -> (@MainActor @Sendable (KeyboardGesture) -> KeyboardGesture)? {
        guard settings.windowsKeys,
              !modifiers.contains(.turnover),
              !modifiers.contains(.command),
              SwitcherCloseWatcher.isWatching.value || ScriptHandler.hasDeferredInput.value else { return nil }
        return { gesture in
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            guard ScriptHandler.findScript(for: gesture) == nil,
                  let key = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(gesture.keyCode), keyDown: true) else { return gesture }
            key.flags = gesture.flags
            guard WindowsRemap.apply(.keyDown, key, frontApp: front) else { return gesture }
            return Self.remappedGesture(gesture, event: key)
        }
    }

    nonisolated static func remappedGesture(_ gesture: KeyboardGesture, event: CGEvent) -> KeyboardGesture {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        var modifiers = Modifiers()
        if event.flags.contains(.maskShift) { modifiers.insert(.shift) }
        if event.flags.contains(.maskControl) { modifiers.insert(.control) }
        if event.flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if event.flags.contains(.maskCommand) { modifiers.insert(.command) }
        return KeyboardGesture(keyCode: code, modifiers: modifiers, characters: characters(of: event),
                               timestamp: gesture.timestamp, isRepeat: gesture.isRepeat, flags: event.flags)
    }


}
