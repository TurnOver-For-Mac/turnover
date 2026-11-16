// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import TurnOverCore

/// Both keyboard workers consult one final-delivery owner. A replacement can start before the
/// outgoing worker finishes; a per-worker map would leave that interval unprotected.
nonisolated enum KeypadApplicationDelivery {
    // CGEvents in sleeping routers never leave state.lock; callbacks and teardown use that same lock.
    struct State {
        var streams = KeypadApplicationStream()
        var retired: Set<Int64> = []
        var sleeping: [ObjectIdentifier: SleepInsertRouter] = [:]
    }
    static let state = Locked(State())

    /// Publish ownership and deliver an explicit down in one operation: another reader's up
    /// must never overtake the original down between registration and posting.
    static func deliverDown(owner: ObjectIdentifier, code: Int64, flags: CGEventFlags, event: CGEvent, pid: Int32? = nil) {
        state.lock.lock(); defer { state.lock.unlock() }
        if Keypad.codes.contains(code) {
            state.unsafeValue.streams.recordDown(code: code, flags: flags, delivered: event, pid: pid, owner: owner)
            // If both taps briefly exist, the second must not reinterpret this same delivered event.
            event.setIntegerValueField(.eventSourceUserData, value: KeyboardHandler.marker)
        }
        if let pid {
            event.setIntegerValueField(.eventSourceUserData, value: KeyboardHandler.marker)
            event.postToPid(pid)
        }
    }

    /// Outer nil means no ownership. Inner nil means consumed; a value means ordinary session delivery.
    static func continueEvent(owner: ObjectIdentifier, _ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>?? {
        guard type == .keyDown || type == .keyUp else { return nil }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        state.lock.lock()
        if let entry = state.unsafeValue.sleeping.first(where: { $0.key != owner && $0.value.ownedCodes.contains(code) }) {
            // The old tap may disappear immediately after this callback. Resolve its outstanding
            // stream here, under the shared lock, rather than deferring to that tap's lifetime.
            var router = entry.value
            replay(router.retire())
            let result = router.route(type, event: event, asleep: false, enabled: false, keypadEnabled: false, pid: 0)
            state.unsafeValue.sleeping[entry.key] = router
            replay(result.replay)
            state.lock.unlock()
            return .some(nil)
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
            event.postToPid(destination)
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
            event.postToPid(release.pid)
        }
    }

    /// Only the primary reader recognizes new sleep chords. A replacement may finish existing
    /// streams, but cannot capture new sleeping input or run a wake on the outgoing reader's behalf.
    static func routeSleeping(owner: ObjectIdentifier, type: CGEventType, event: CGEvent,
                              asleep: Bool, enabled: Bool, keypadEnabled: Bool, pid: Int32) -> SleepInsertRouter.Disposition {
        state.lock.lock(); defer { state.lock.unlock() }
        var router = state.unsafeValue.sleeping[owner] ?? SleepInsertRouter()
        let result = router.route(type, event: event, asleep: asleep, enabled: enabled, keypadEnabled: keypadEnabled, pid: pid)
        state.unsafeValue.sleeping[owner] = router
        replay(result.replay)
        return result.disposition
    }

    static func retireSleeping(owner: ObjectIdentifier) {
        state.lock.lock(); defer { state.lock.unlock() }
        guard var router = state.unsafeValue.sleeping[owner] else { return }
        let events = router.retire()
        state.unsafeValue.sleeping[owner] = router
        replay(events)
    }

    static func finishSleeping(owner: ObjectIdentifier) {
        state.lock.lock(); defer { state.lock.unlock() }
        guard var router = state.unsafeValue.sleeping.removeValue(forKey: owner) else { return }
        let retirement = router.finish()
        state.unsafeValue.retired.formUnion(retirement.releasedCodes)
        replay(retirement.replay)
    }

    /// Called only while state.lock owns every retained event and its destination.
    private static func replay(_ events: [SleepInsertRouter.Replay]) {
        for item in events {
            item.event.setIntegerValueField(.eventSourceUserData, value: KeyboardHandler.marker)
            for _ in 0..<item.count { item.event.postToPid(item.pid) }
        }
    }
}
