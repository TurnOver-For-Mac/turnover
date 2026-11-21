// SPDX-License-Identifier: GPL-3.0-or-later
// The level of review a plugin needs, from its abilities alone (docs/PLUGIN-PLATFORM-PLAN.md, "Review by risk"; 16 Nov 2026), so a tool
// can decide which applies and say why. One function; `turnover-plugin check` and `consent` print it.
//
//   1  Low: reads and speaks in named apps. No reviewer; the automatic checks run and the person's own approval is the safeguard.
//   2  Higher: acts in an app (press, focus, edit, menu, keys), puts text on the clipboard, or works everywhere. One review of the first
//      version and of the author by a person who is not the author; later versions that ask for nothing new, signed by the same key,
//      need none.
//   3  Highest: can read private things, which can then be sent out (hearSpeech, clipboardRead; and read together with the internet or
//      files, when those exist). A person who is not the author reads every version.
//
// The plan lists the acting abilities and `everywhere` for level 2. Writing to the clipboard is not named there; it overwrites what the
// person copied, so it counts as acting here (decided while building stage B, to fail closed).
import Foundation

nonisolated public enum ScriptReview {
    public struct Level: Equatable, Sendable {
        public let number: Int
        /// One sentence: which abilities decided it, and what that means for review.
        public let reason: String
        public var summary: String { String(localized: "Review level \(number). \(reason)", comment: "Printed by turnover-plugin check and consent: the level of review a plugin needs, then why") }
    }

    /// Level 3 abilities, then level 2, in the words of the reason.
    private static let highest: [(ScriptAbility, String)] = [
        (.hearSpeech, String(localized: "hear what TurnOver says to you", comment: "Part of the reason a plugin needs the highest review")),
        (.clipboardRead, String(localized: "read what you copy", comment: "Part of the reason a plugin needs the highest review")),
    ]
    private static let higher: [(ScriptAbility, String)] = [
        (.press, String(localized: "press things", comment: "Part of the reason a plugin needs a higher review")),
        (.focus, String(localized: "move the focus", comment: "Part of the reason a plugin needs a higher review")),
        (.menu, String(localized: "choose menu items", comment: "Part of the reason a plugin needs a higher review")),
        (.keys, String(localized: "press keys", comment: "Part of the reason a plugin needs a higher review")),
        (.edit, String(localized: "change text", comment: "Part of the reason a plugin needs a higher review")),
        (.clipboard, String(localized: "change your clipboard", comment: "Part of the reason a plugin needs a higher review")),
        (.everywhere, String(localized: "work in every app", comment: "Part of the reason a plugin needs a higher review")),
    ]

    public static func level(for abilities: Set<ScriptAbility>) -> Level {
        let top = highest.filter { abilities.contains($0.0) }.map(\.1)
        if !top.isEmpty {
            let list = ListFormatter.localizedString(byJoining: top)
            return Level(number: 3, reason: String(localized: "It can \(list), which is private, and could send it out another way, so a person who is not its author reads every version.", comment: "Why a plugin is at the highest level of review; the placeholder lists what it can do"))
        }
        let mid = higher.filter { abilities.contains($0.0) }.map(\.1)
        if !mid.isEmpty {
            let list = ListFormatter.localizedString(byJoining: mid)
            return Level(number: 2, reason: String(localized: "It can \(list), so one person who is not its author reviews its first version and its author; later versions that ask for nothing new and are signed by the same key need none.", comment: "Why a plugin is at the higher level of review; the placeholder lists what it can do"))
        }
        return Level(number: 1, reason: String(localized: "It only reads and speaks in the apps it names, so it has no reviewer: the automatic checks run, and your own approval is the safeguard.", comment: "Why a plugin is at the lowest level of review"))
    }
}
