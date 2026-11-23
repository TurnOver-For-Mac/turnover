// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import TurnOverCore

/// Both keyboard workers consult one final-delivery owner. A replacement can start before the
/// outgoing worker finishes; a per-worker map would leave that interval unprotected.
nonisolated enum KeypadApplicationDelivery {
    // CGEvents in sleeping routers never leave state.lock; callbacks and teardown use that same lock.
    struct State {
        var output = OutputQueue()
        var closing = false
        var streams = KeypadApplicationStream()
        var retired: Set<Int64> = []
        var sleeping: [ObjectIdentifier: SleepInsertRouter] = [:]
    }
    static let state = Locked(State())

    /// Publish ownership and deliver an explicit down in one operation: another reader's up
    /// must never overtake the original down between registration and posting.
    static func deliverDown(owner: ObjectIdentifier, code: Int64, flags: CGEventFlags, event: CGEvent, pid: Int32? = nil) -> Bool {
        state.lock.lock(); defer { state.lock.unlock() }
        guard !state.unsafeValue.closing else { return false }
        if Keypad.codes.contains(code) {
            state.unsafeValue.streams.recordDown(code: code, flags: flags, delivered: event, pid: pid, owner: owner)
            // If both taps briefly exist, the second must not reinterpret this same delivered event.
            event.setIntegerValueField(.eventSourceUserData, value: KeyboardHandler.marker)
        }
        if let pid {
            event.setIntegerValueField(.eventSourceUserData, value: KeyboardHandler.marker)
            postOrQueue(event, pid: pid)
            return true
        }
        if state.unsafeValue.output.active {
            enqueueSessionLocked(event)
            return true
        }
        return false
    }

    /// Outer nil means no ownership. Inner nil means consumed; a value means ordinary session delivery.
    static func continueEvent(owner: ObjectIdentifier, _ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>?? {
        guard type == .keyDown || type == .keyUp else { return nil }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        state.lock.lock()
        let previousOwner = state.unsafeValue.sleeping.keys.first {
            $0 != owner && state.unsafeValue.sleeping[$0]?.ownedCodes.contains(code) == true
        }
        if let previousOwner,
           var router = state.unsafeValue.sleeping.removeValue(forKey: previousOwner) {
            // Remove before mutation: the pending run buffer must have one owner, not COW on each event.
            replay(router.retire())
            let result = router.route(type, event: event, asleep: false, enabled: false, keypadEnabled: false, pid: 0)
            state.unsafeValue.sleeping[previousOwner] = router
            let passes = result.disposition == .pass
            consumeResult(consume result)
            state.lock.unlock()
            return passes ? nil : .some(nil)
        }
        if state.unsafeValue.retired.contains(code) {
            if type == .keyUp {
                state.unsafeValue.retired.remove(code)
                state.lock.unlock(); return .some(nil)
            }
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                state.lock.unlock(); return .some(nil)
            }
            state.unsafeValue.retired.remove(code)
        }
        guard state.unsafeValue.streams.continuePress(type, event: event) else { state.lock.unlock(); return nil }
        let destination = state.unsafeValue.streams.destination
        event.setIntegerValueField(.eventSourceUserData, value: KeyboardHandler.marker)
        if let destination {
            postOrQueue(event, pid: destination)
            state.lock.unlock()
            return .some(nil)
        }
        if state.unsafeValue.output.active {
            enqueueSessionLocked(event)
            state.lock.unlock()
            return .some(nil)
        }
        state.lock.unlock()
        // A preserved nil means session delivery, never a newly selected redirect destination.
        return .some(Unmanaged.passUnretained(event))
    }

    /// Posting and retirement share the same lock as continuations, so an up cannot overtake a repeat.
    static func finish(owner: ObjectIdentifier) {
        state.lock.lock(); defer { state.lock.unlock() }
        for release in state.unsafeValue.streams.finish(owner: owner) {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(release.code), keyDown: false) else { continue }
            event.flags = release.flags
            event.setIntegerValueField(.eventSourceUserData, value: KeyboardHandler.marker)
            state.unsafeValue.retired.insert(release.physicalCode)
            postOrQueue(event, pid: release.pid)
        }
    }

    /// Only the primary reader recognizes new sleep chords. A replacement may finish existing
    /// streams, but cannot capture new sleeping input or run a wake on the outgoing reader's behalf.
    static func routeSleeping(owner: ObjectIdentifier, type: CGEventType, event: CGEvent,
                              asleep: Bool, enabled: Bool, keypadEnabled: Bool, pid: Int32) -> SleepInsertRouter.Disposition {
        state.lock.lock(); defer { state.lock.unlock() }
        guard !state.unsafeValue.closing else { return .pass }
        var router = state.unsafeValue.sleeping.removeValue(forKey: owner) ?? SleepInsertRouter()
        let result = router.route(type, event: event, asleep: asleep, enabled: enabled, keypadEnabled: keypadEnabled, pid: pid)
        state.unsafeValue.sleeping[owner] = router
        let disposition = result.disposition
        consumeResult(consume result)
        return disposition
    }

    static func retireSleeping(owner: ObjectIdentifier) {
        state.lock.lock(); defer { state.lock.unlock() }
        guard var router = state.unsafeValue.sleeping.removeValue(forKey: owner) else { return }
        let events = router.retire()
        state.unsafeValue.sleeping[owner] = router
        replay(consume events)
    }

    static func finishSleeping(owner: ObjectIdentifier) {
        state.lock.lock(); defer { state.lock.unlock() }
        guard var router = state.unsafeValue.sleeping.removeValue(forKey: owner) else { return }
        let retirement = router.finish()
        consumeRetirement(consume retirement)
    }

}
