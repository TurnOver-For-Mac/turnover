// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Ownership of VoiceOver enabled for TurnOver's lock screen, separate from a user's reader choice.
/// The caller supplies monotonic time; this state never sleeps, posts keys or changes a reader (#204).
package struct WakeRestoration {
    package struct Attempt: Equatable {
        package let generation: Int
        package let number: Int
    }

    package struct Readiness {
        package let locked: Bool
        package let secureInput: Bool
        package let ordinaryForeground: Bool
        package let suspended: Bool
        package let inputGranted: Bool
        package let coexisting: Bool
        package let automaticAppSwitching: Bool
        package let voiceOverReady: Bool

        package init(locked: Bool, secureInput: Bool, ordinaryForeground: Bool, suspended: Bool,
                    inputGranted: Bool, coexisting: Bool, automaticAppSwitching: Bool, voiceOverReady: Bool) {
            self.locked = locked; self.secureInput = secureInput; self.ordinaryForeground = ordinaryForeground
            self.suspended = suspended; self.inputGranted = inputGranted; self.coexisting = coexisting
            self.automaticAppSwitching = automaticAppSwitching; self.voiceOverReady = voiceOverReady
        }

        /// Safety throughout the handover; VoiceOver no longer reading is its desired outcome, not cancellation.
        package var canRestore: Bool {
            !locked && !secureInput && ordinaryForeground && !suspended && inputGranted
                && !coexisting && !automaticAppSwitching
        }
    }

    package private(set) var pending = false
    package private(set) var generation = 0
    package private(set) var attempts = 0
    package private(set) var inFlight = false
    package private(set) var voiceOverWasObservedOn = false
    private var retryAt: TimeInterval = 0
    package init() {}

    /// Sleep, display sleep and lock can arrive together. Retire callbacks from the previous cycle without
    /// losing ownership of the VoiceOver we already started. Pre-existing user VoiceOver never creates intent.
    package mutating func lock(readerWasActive: Bool, voiceOverAlreadyOn: Bool, suspended: Bool) {
        let owned = pending || (readerWasActive && !voiceOverAlreadyOn && !suspended)
        generation &+= 1
        pending = owned && !suspended
        voiceOverWasObservedOn = pending && voiceOverAlreadyOn
        attempts = 0; inFlight = false; retryAt = 0
    }

    package mutating func cancel() {
        generation &+= 1
        pending = false; attempts = 0; inFlight = false; retryAt = 0
        voiceOverWasObservedOn = false
    }

    package mutating func beginAttempt(readiness: Readiness, now: TimeInterval) -> Attempt? {
        // Startup settling must not spend the retry allowance before there is a running reader to hand over.
        guard pending, !inFlight, attempts < 3, readiness.canRestore, readiness.voiceOverReady,
              now.isFinite, now >= retryAt else { return nil }
        attempts += 1; inFlight = true
        return Attempt(generation: generation, number: attempts)
    }

    package func isCurrent(_ attempt: Attempt) -> Bool {
        pending && inFlight && attempt.generation == generation && attempt.number == attempts
    }

    /// Success means the caller observed VoiceOver off, never merely accepted an off request.
    package mutating func finishAttempt(_ attempt: Attempt, succeeded: Bool, now: TimeInterval) {
        guard isCurrent(attempt) else { return }
        if succeeded { cancel(); return }
        inFlight = false
        retryAt = now.isFinite ? now + 0.5 : .infinity
    }

    /// A false snapshot before the owned start finishes is not an on-to-off transition.
    package mutating func observedVoiceOverOn() {
        if pending { voiceOverWasObservedOn = true }
    }

    package mutating func observedVoiceOverOff() { cancel() }
}

/// The lock screen's one request for VoiceOver. Sleep comes as notices in a burst: "sleep", then "display sleep" 86 ms
/// later, then "lock". Each found VoiceOver's flag still off while the first request was under way, and each toggled
/// it, so VoiceOver went on and straight off again behind the lock, and the Mac had no reader after the unlock until
/// TurnOver was restarted (the owner's log, 13 Nov 2026, 20:24:43; posted twice at 19:29:11 and 20:26:09 as well). A notice
/// that comes while the request is under way stands down. It is under way until it is answered, or for at most
/// `window` seconds, so a request whose answer never comes cannot hold back the next lock.
/// The caller supplies monotonic time.
package struct LockVoiceOverRequest {
    package static let window: TimeInterval = 3
    private var startedAt: TimeInterval?

    package init() {}

    /// A request is under way at `now`: a lock notice now leaves it to finish.
    package func isUnderWay(now: TimeInterval) -> Bool {
        guard let startedAt else { return false }
        return now - startedAt < Self.window
    }

    /// The request is made at `now`.
    package mutating func start(now: TimeInterval) { startedAt = now }

    /// The request was answered: VoiceOver's flag was seen as asked, or the request was given up.
    package mutating func answered() { startedAt = nil }
}
