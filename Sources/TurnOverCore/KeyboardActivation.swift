// SPDX-License-Identifier: GPL-3.0-or-later
// Main-actor admission for a keyboard worker's asynchronous acknowledgement. A reader choice can cancel
// activation before input setup returns; an enabled old tap must never revive that choice (28 Oct 2026, #52).
import Foundation

public final class KeyboardActivation {
    public private(set) var generation: UInt64?
    public private(set) var isActive = false
    public var isRequested: Bool { generation != nil }
    private var automaticRestore: (readerChoice: Int, expires: Date)?

    public init() {}

    public func begin(_ generation: UInt64) {
        readerSelected()
        self.generation = generation
        isActive = false
    }

    @discardableResult
    public func confirm(_ generation: UInt64, inputReady: Bool) -> Bool {
        guard self.generation == generation, !isActive, inputReady else { return false }
        isActive = true
        return true
    }

    public func cancel() {
        generation = nil
        isActive = false
    }

    /// Permission recovery starts VoiceOver before cancelling input. Its one matching on-notification is ours,
    /// so it must not be saved as a manual reader pin which prevents permission-grant retry. Cancellation keeps
    /// this acknowledgement alive; an off notice, a new choice, expiry or the first on notice consumes it.
    public func expectAutomaticVoiceOverRestore(readerChoice: Int, now: Date = Date()) {
        automaticRestore = (readerChoice, now.addingTimeInterval(5))
    }

    public func takeAutomaticVoiceOverRestore(on: Bool, readerChoice: Int, now: Date = Date()) -> Bool {
        guard let expected = automaticRestore else { return false }
        automaticRestore = nil
        return on && expected.readerChoice == readerChoice && now < expected.expires
    }

    /// Called when a user selects a reader, before any delayed menu action posts its handover.
    public func readerSelected() { automaticRestore = nil }

    /// With the swap off, VoiceOver taking the Mac suspends both pending and active TurnOver. The caller
    /// remembers the hold and stops the keyboard, so VoiceOver going off can request a fresh activation.
    @discardableResult
    public func yieldToVoiceOver() -> Bool {
        guard isRequested else { return false }
        cancel()
        return true
    }
}
