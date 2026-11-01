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
