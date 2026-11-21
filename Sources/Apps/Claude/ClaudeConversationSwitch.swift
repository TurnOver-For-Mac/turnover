// SPDX-License-Identifier: GPL-3.0-or-later
// What Command and a number, or Command N, says in the Claude app (17 Nov 2026).
//
// The principle: a title is said only when the conversation the key chose has arrived. The key chose row N of the
// sidebar's Recents as it stood when the key was pressed, so the row is read fresh from the app after the key, never
// from the page's last published copy, which can be seconds old while Claude reorders Recents (a message sent, a reply
// finished). Arrival means the page's own title, not Claude's generic one, is that row's name. Nothing is guessed
// before that; at the ceiling the row's own name is said once. Command N has no row, so its new page's title is said.
import Foundation

package struct ClaudeConversationSwitch {
    package enum Answer: Equatable {
        case wait
        case say(String)
        case noConversation(Int)
        /// The key chose the conversation already open.
        case alreadyHere(String)
        /// Done, with nothing to say.
        case silent
    }

    /// The shortcut's number, or nil for Command N.
    package let number: Int?
    /// Row N in each fresh read of Recents since the key, oldest first. A reorder can race the key, so any of them counts.
    package private(set) var targets: [String] = []
    /// The rows in the latest fresh read, or nil while no read has found them.
    package private(set) var rows: [String]?
    /// The title of the conversation being left: the page's title at the key, else the first answer at the old address.
    package private(set) var leftTitle: String?
    package private(set) var addressChanged = false
    package private(set) var announced = false
    private var unchangedAnswers = 0

    package init(number: Int?, titleAtKey: String) {
        self.number = number
        self.titleAtKey = titleAtKey
    }
    private let titleAtKey: String

    /// Claude's own name for a page that has not yet taken its conversation's title.
    package static func isGeneric(_ title: String) -> Bool {
        ["", "Claude", "Claude Code"].contains(title)
    }

    /// A fresh read of Recents: the rows' names in order, or nil when the section could not be read whole.
    package mutating func recents(_ fresh: [String]?) {
        guard let fresh else { return }
        rows = fresh
        guard let number, number <= fresh.count else { return }
        targets.append(fresh[number - 1])
    }

    /// The conversation the key chose is already open: its row is the page's own title, and no other row has it.
    private var targetIsCurrent: Bool {
        guard let leftTitle,
              !Self.isGeneric(leftTitle),
              let rows,
              !targets.isEmpty else { return false }
        let unique = rows.filter { $0 == leftTitle }.count == 1
        return unique && targets.allSatisfy { $0 == leftTitle }
    }

    /// One answer from the app. `loaded`: the new address's copy is complete. `settled`: the shortest wait has passed.
    package mutating func answer(title: String, busy: Bool, changed: Bool, loaded: Bool, settled: Bool) -> Answer {
        guard !announced else { return .wait }
        if changed { addressChanged = true }
        let stillHere = !addressChanged
        if leftTitle == nil,
           !titleAtKey.isEmpty { leftTitle = titleAtKey }
        if stillHere,
           leftTitle == nil,
           !busy,
           !title.isEmpty { leftTitle = title }
        if stillHere,
           let number,
           let rows,
           number > rows.count {
            announced = true
            return .noConversation(number)
        }
        if stillHere,
           targetIsCurrent,
           !busy,
           title == leftTitle {
            unchangedAnswers += 1
            guard unchangedAnswers >= 3 else { return .wait }
            guard settled else { return .wait }
            announced = true
            return .alreadyHere(title)
        }
        unchangedAnswers = 0
        guard !busy,
              arrived(title, loaded: loaded) else { return .wait }
        announced = true
        return .say(title)
    }

    private func arrived(_ title: String, loaded: Bool) -> Bool {
        let named = number == nil ? !title.isEmpty : !Self.isGeneric(title)
        guard named else { return false }
        let moved = (leftTitle != nil && title != leftTitle) || loaded
        guard number != nil, !targets.isEmpty else { return moved }
        return targets.contains(title) && moved
    }

    /// The ceiling: one last answer, read after it.
    package mutating func ceiling(title: String, changed: Bool) -> Answer {
        guard !announced else { return .silent }
        announced = true
        if changed { addressChanged = true }
        let moved = addressChanged || (leftTitle != nil && !title.isEmpty && title != leftTitle)
        guard let number else { return title.isEmpty || !moved ? .silent : .say(title) }
        if !moved {
            if rows == nil || number > (rows?.count ?? 0) { return .noConversation(number) }
            return targetIsCurrent && title == leftTitle ? .alreadyHere(title) : .silent
        }
        if targets.contains(title) { return .say(title) }
        if let row = targets.last { return .say(row) }
        return Self.isGeneric(title) ? .silent : .say(title)
    }
}
