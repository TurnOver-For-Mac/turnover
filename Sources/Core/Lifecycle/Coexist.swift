// SPDX-License-Identifier: GPL-3.0-or-later
// CoExist (16 to 18 Oct 2026): VoiceOver stays running alongside TurnOver. TurnOver takes the keys and speaks in its
// own apps and steps back in every other; VoiceOver, silenced by the audio tap (VoiceOverTap, the voiceover-quiet
// helper) wherever TurnOver reads, is heard everywhere else, and in password fields and macOS's own prompts, which are
// VoiceOver's. On unless turned off: the `coexist` default (TurnOver's Settings, CoExist).
import Foundation

public enum Coexist {
    /// Read once at start (the keyboard thread asks on every key); a change restarts TurnOver. The Key helper applies
    /// the same rule.
    nonisolated public static let on: Bool = wouldBeOn
    /// The setting as it stands now: off unless turned on (experimental since 28 Oct 2026).
    /// macOS 14.2 at least: VoiceOver is kept quiet by an audio process tap, which earlier macOS hasn't; there, two
    /// voices would speak at once, so TurnOver works the old way (VoiceOver off where TurnOver reads).
    nonisolated public static var wouldBeOn: Bool {
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0)) else { return false }
        return (UserDefaults.standard.object(forKey: "coexist") as? Bool) ?? false
    }
}
