// SPDX-License-Identifier: GPL-3.0-or-later
// Mail's message list: the next message is read the moment the arrow is pressed, not when Mail says its selection
// has moved (trial, 10 Nov 2026).
//
// Why: of the 76 ms between an arrow and the first sound in this list, 45 were Mail moving its selection and loading
// the message before it told anyone; TurnOver's own reading of the row took 2 (60 presses in Oliver's logs, 10 Nov
// 2026; Finder's lists, which only move a selection, answered in 40 ms in all). The row the arrow will land on is
// known before Mail gets there: it is the row after the selected one. So it is read at once, by the same path a
// selection is read by, and Mail's own news a moment later is checked against it: the same row is not read twice,
// and any other row is read as the correction it is.
//
// This file is the bookkeeping, apart from Mail so the tests can drive it; MailAppModule asks it what to do.
import Foundation
import ApplicationServices

nonisolated package struct MailReadAhead {
    /// The row read ahead, and when (seconds, any steady clock).
    package private(set) var row: AXUIElement?
    private var at = 0.0
    /// The reading TurnOver itself queued for `row` has not come through the event path yet.
    private var ownReadingPending = false
    /// Counts the rows read ahead: the check a moment later is only for the latest.
    package private(set) var serial = 0

    /// A second arrow inside this long steps from the row just read ahead, not from Mail's selection, which may not
    /// have caught up: holding Down reads each next row, not the same one twice.
    static let chainWindow = 0.5
    /// Mail's news of the row read ahead is expected within this long. Later than that, it is read as news.
    static let confirmWindow = 3.0

    package init() {}

    /// The row the next arrow steps from.
    package func base(selected: AXUIElement?, now: Double) -> AXUIElement? {
        if let row, now - at < Self.chainWindow, !(selected.map { CFEqual($0, row) } ?? false) { return row }
        return selected
    }

    /// `next` is being read ahead now.
    @discardableResult
    package mutating func readingAhead(_ next: AXUIElement, now: Double) -> Int {
        row = next; at = now; ownReadingPending = true; serial += 1
        return serial
    }

    /// A selection event for `eventRow` has arrived: whether it is to be read. TurnOver's own queued reading passes
    /// once; Mail then confirming the same row is not read again; any other row is, and ends the expectation.
    package mutating func admits(_ eventRow: AXUIElement, now: Double) -> Bool {
        guard let row, now - at < Self.confirmWindow else { return true }
        guard CFEqual(row, eventRow) else { clear(); return true }
        if ownReadingPending { ownReadingPending = false; return true }
        return false
    }

    package mutating func clear() { row = nil; ownReadingPending = false }
}
