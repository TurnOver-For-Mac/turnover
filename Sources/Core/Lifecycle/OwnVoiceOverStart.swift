// SPDX-License-Identifier: GPL-3.0-or-later
// VoiceOver started by TurnOver itself, outside a hand-over: the watchdog, the quit, speech or the keyboard failing.
// Its arrival is not the person's choice, and must never pin the app in front to VoiceOver "by hand". It can arrive
// seconds later, in the next TurnOver: on 17 Nov 2026 the watchdog opened VoiceOver at 10:16:20, the restarted
// TurnOver started at 10:16:26 with VoiceOver still off, and VoiceOver came at 10:16:30, past the new process's
// three seconds of grace, so Mail was "pinned to VoiceOver by hand" (18 Nov 2026). The time of the request is kept
// in a file, so every TurnOver process knows it; this decides from that time alone.
import Foundation

nonisolated public enum OwnVoiceOverStart {
    /// How long after TurnOver asked for VoiceOver its coming on is still TurnOver's doing: 9.8 s was measured on
    /// 17 Nov 2026 (the watchdog's request to VoiceOver reading, across a restart); twice that, rounded.
    public static let window: TimeInterval = 20

    /// VoiceOver came on at `now`, both in seconds since 1970: is it the arrival of TurnOver's own request, made at
    /// `askedAt` by this TurnOver or the one before it? A second's leeway the other way, for the clock.
    public static func isOurs(askedAt: TimeInterval?, now: TimeInterval) -> Bool {
        guard let askedAt else { return false }
        let age = now - askedAt
        return age > -1 && age < window
    }

    /// The file's contents for a request at `time`, and back.
    public static func encode(_ time: TimeInterval) -> String { String(format: "%.3f", time) }
    public static func decode(_ text: String) -> TimeInterval? {
        Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
