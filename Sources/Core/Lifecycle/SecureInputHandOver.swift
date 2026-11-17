// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Carbon   // IsSecureEventInputEnabled

/// Secure input left on by an app outside a password field (17 Nov 2026): TurnOver's key tap hears no keys at all, and
/// only the app that turned it on can turn it off. Safari kept it on for the life of Steam's sign-in page after Tab left
/// the password field (Oliver's log, 17 Nov 2026, 09:44 and 09:50). Oliver's decision: a bug to fix, not a warning to
/// give. VoiceOver, privileged, still hears the keys, so it is given them for the episode and TurnOver takes them back
/// once secure input is off. The plan: TODO-log-review-2026-11-17b-plan-secure-input.md.
///
/// This decides when; the lead watcher does the hand-over. Secure input is read through `secureInputOn` and time through
/// `now`, both injected, so the tests never touch the Mac's own secure input.
/// - Handed over: secure input on for `settle` seconds running, the focus outside a password field all along (a real
///   password field is SecureEcho's, and TurnOver keeps it).
/// - Handed back: secure input off for `settle` seconds running. Never by the focus: once handed over, the focus is not
///   asked again, so Shift Tab back into the password field stays with VoiceOver and readers never flip per field.
/// - Not handed back when anything else changed the reader meanwhile (the caller says so): the episode just ends.
/// - After a hand-back, the next hand-over waits `rest` seconds (flicker).
/// - Ended without a hand-back (VoiceOver not coming, the reader changed): TurnOver reads as before, and no new
///   hand-over until secure input has gone off.
package final class SecureInputHandOver {
    package static let settle: TimeInterval = 1
    package static let rest: TimeInterval = 5
    /// The longest a hand-over can take (VoiceOver.app's fallback start waits 12 s after the shortcut's 1.2 s).
    package static let handOverLimit: TimeInterval = 15

    package enum Phase: Equatable { case reading, handingOver, handedOver, spent }
    package enum StandDown: Equatable { case readerChanged, voiceOverOff, frontIsVoiceOvers, voiceOverNeverCame }
    package enum Decision: Equatable { case wait, handOver, handBack, standDown(StandDown) }

    /// What the lead watcher sees while the keys are with VoiceOver for secure input.
    package struct Standing {
        /// Nothing else changed the reader since the hand-over: no other hand-over, no choice by hand, no lock, TurnOver
        /// not turned off by its key, the watchdog did not act.
        package let readerUnchanged: Bool
        package let voiceOverOn: Bool
        /// The app in front is the one secure input was handed over in, or one TurnOver leads.
        package let frontIsTurnOvers: Bool
        package init(readerUnchanged: Bool, voiceOverOn: Bool, frontIsTurnOvers: Bool) {
            self.readerUnchanged = readerUnchanged
            self.voiceOverOn = voiceOverOn
            self.frontIsTurnOvers = frontIsTurnOvers
        }
    }

    private let secureInputOn: () -> Bool
    private let now: () -> TimeInterval
    package private(set) var phase: Phase = .reading
    private var onOutsideSince: TimeInterval?
    private var offSince: TimeInterval?
    private var handOverAt: TimeInterval = 0
    private var restUntil: TimeInterval = -.infinity

    package init(secureInputOn: @escaping () -> Bool = { IsSecureEventInputEnabled() },
                 now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.secureInputOn = secureInputOn
        self.now = now
    }

    /// The keys are with VoiceOver for secure input, or on their way there: the lead watcher keeps looking.
    package var underWay: Bool { phase == .handingOver || phase == .handedOver }

    /// A look while TurnOver reads (SecureInputWatch, four a second). `mayHandOver`: TurnOver leads and nothing else owns
    /// the reader (not locked, no wake restoration, not off by its key, not coexisting).
    package func lookWhileReading(inPasswordField: Bool, mayHandOver: Bool) -> Decision {
        let t = now()
        let on = secureInputOn()
        if phase == .spent {
            // The episode ended without a hand-back (VoiceOver did not come, or the reader changed meanwhile): no new
            // hand-over until secure input has gone off, so a choice by hand is never fought.
            guard !on else { return .wait }
            phase = .reading
            restUntil = t + Self.rest
        }
        guard phase == .reading else { return .wait }
        guard on else { onOutsideSince = nil; return .wait }
        guard !inPasswordField else { onOutsideSince = nil; return .wait }
        guard mayHandOver else { onOutsideSince = nil; return .wait }
        guard t >= restUntil else { onOutsideSince = nil; return .wait }
        let since = onOutsideSince ?? t
        onOutsideSince = since
        guard t - since >= Self.settle else { return .wait }
        phase = .handingOver
        handOverAt = t
        onOutsideSince = nil
        offSince = nil
        return .handOver
    }

    /// The hand-over's answer: `true` when VoiceOver's flag was seen on.
    package func handOverFinished(voiceOverCame: Bool) {
        guard phase == .handingOver else { return }
        phase = voiceOverCame ? .handedOver : .spent
    }

    /// A look while the keys are with VoiceOver (the lead watcher's own timer, four a second). The focus is not asked.
    package func lookWhileHandedOver(_ standing: Standing) -> Decision {
        let t = now()
        switch phase {
        case .reading, .spent:
            return .wait
        case .handingOver:
            guard standing.readerUnchanged else { return end(.readerChanged) }
            guard t - handOverAt >= Self.handOverLimit else { return .wait }
            // The hand-over never answered: whatever VoiceOver's flag says now stands.
            guard standing.voiceOverOn else { return end(.voiceOverNeverCame) }
            phase = .handedOver
            return .wait
        case .handedOver:
            guard standing.readerUnchanged else { return end(.readerChanged) }
            guard standing.voiceOverOn else { return end(.voiceOverOff) }
            guard !secureInputOn() else { offSince = nil; return .wait }
            let since = offSince ?? t
            offSince = since
            guard t - since >= Self.settle else { return .wait }
            guard standing.frontIsTurnOvers else { return end(.frontIsVoiceOvers) }
            phase = .reading
            offSince = nil
            restUntil = t + Self.rest
            return .handBack
        }
    }

    private func end(_ why: StandDown) -> Decision {
        phase = .spent
        offSince = nil
        onOutsideSince = nil
        return .standDown(why)
    }
}
