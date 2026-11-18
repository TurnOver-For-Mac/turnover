// SPDX-License-Identifier: GPL-3.0-or-later
// Whose change of VoiceOver it was: the person's own toggle (Option-quote on Oliver's Mac) or TurnOver's (a hand-over
// it posted, or its own start of VoiceOver). The person's always wins (Codex's second review, 18 Nov 2026):
// - Within 3 s of an automatic hand-over every change counted as TurnOver's, so Oliver turning VoiceOver straight back
//   off got no pin, and the hand-over's own check after it could turn VoiceOver on again over his choice. A change
//   the other way from the one the hand-over asked for is now his; only a hand-over that posted a second toggle (the
//   first may land late, 8 Oct 2026) can bring the other way itself.
// - TurnOver's own start of VoiceOver (OwnVoiceOverStart) claimed the first "on" within 20 s, even one made by his key.
//   The key tap sees his toggle shortcut go by (it is let through untouched): a press heard just before the change
//   makes it his. Where the tap was not listening long enough to know, the change cannot be told apart, and it is
//   taken as his: TurnOver never overrides the person on a guess.
import Foundation

/// The person's own presses of VoiceOver's toggle shortcut, as the key tap heard them. Any thread: the tap runs on its own.
nonisolated public final class PersonVoiceOverToggle: @unchecked Sendable {
    /// How long after a press the change of VoiceOver is the press's: the shortcut flips the flag in about 100 ms
    /// (HandOver, 27 Oct 2026); a second late (25 Oct 2026) is the worst seen, so twice that.
    public static let window: TimeInterval = 2

    public enum Verdict: Equatable {
        case person      // the toggle was pressed just before the change
        case notPerson   // the tap was listening all through the window and heard no press
        case unheard     // the tap was not listening long enough to know
    }

    private let lock = NSLock()
    private var pressedAt: TimeInterval?
    private var listeningSince: TimeInterval?
    public init() {}

    /// The tap is up and hearing keys (`true`), or gone (`false`). Up again after being switched off by macOS, it
    /// starts afresh: keys in between were not heard.
    public func listening(_ up: Bool, now: TimeInterval = Date().timeIntervalSince1970) {
        lock.lock(); defer { lock.unlock() }
        listeningSince = up ? now : nil
    }

    /// The person pressed VoiceOver's toggle shortcut (not one TurnOver posted).
    public func pressed(now: TimeInterval = Date().timeIntervalSince1970) {
        lock.lock(); defer { lock.unlock() }
        pressedAt = now
    }

    /// A change of VoiceOver came at `now`: was it the person's press? A press answers for one change only.
    public func take(now: TimeInterval = Date().timeIntervalSince1970) -> Verdict {
        lock.lock(); defer { lock.unlock() }
        let press = pressedAt
        pressedAt = nil
        if let press, now - press >= 0, now - press < Self.window { return .person }
        guard let since = listeningSince else { return .unheard }
        let heardAllWindow = now - since >= Self.window
        return heardAllWindow ? .notPerson : .unheard
    }
}

nonisolated public enum HandOverOwnership {
    /// Whether a change of VoiceOver to `on` is the hand-over's own: within its window (`windowOpen`), the way it asked
    /// for (`wanted`), or either way once it posted a second toggle (`secondToggle`). Never when the person's press
    /// was heard (`byPerson`).
    public static func isHandOvers(on: Bool, wanted: Bool?, windowOpen: Bool, secondToggle: Bool, byPerson: Bool) -> Bool {
        if byPerson { return false }
        if !windowOpen { return false }
        guard let wanted else { return false }
        if on == wanted { return true }
        return secondToggle
    }
}

extension OwnVoiceOverStart {
    /// Whether an "on" is TurnOver's own start: the record says so (`verdict`) and the key tap heard no press of the
    /// person's (`person`). A press heard, or a tap not listening long enough to know, leaves it the person's.
    public static func isOwnStart(_ verdict: Verdict, person: PersonVoiceOverToggle.Verdict) -> Bool {
        guard verdict == .ours else { return false }
        return person == .notPerson
    }
}
