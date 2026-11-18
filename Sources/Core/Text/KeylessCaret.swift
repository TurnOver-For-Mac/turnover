// SPDX-License-Identifier: GPL-3.0-or-later
// A text field read without its keys (18 Nov 2026). While an app holds the Mac's secure input, no key reaches TurnOver,
// but the field still tells it that its text or its caret changed. Oliver, after a reset-password page in Safari:
// "voiceover shouldn't be coming on, turnover should be able to cope with this, make it more robust". So the field's own
// news is read as the key would have been: a character typed, a character deleted, the caret moved by a character, a
// word or a line. A password field is not read here: SecureEcho says only that it grew or shrank.
import Foundation
import ApplicationServices
import TurnOverAX

/// What a text field's change says, worked out from its text and caret before and after (UTF-16 offsets, as
/// the field gives them). Pure: no field, no speech; the decisions are unit-tested.
public struct KeylessCaret: Equatable {
    public enum Reading: Equatable {
        case nothing
        case typed(String)
        case deleted(String)
        case moved(TextUnit)
    }

    public private(set) var text: [UInt16]
    public private(set) var caret: Int
    /// Where a text change put the caret: the field's own caret news for it, which may come a moment later, is not a
    /// move of its own (one letter typed would otherwise be said twice, as a letter and as a move).
    private var expectedCaret: Int?

    public init(text: String, caret: Int) {
        self.text = Array(text.utf16)
        self.caret = caret
    }

    /// The field's text and caret now: what changed, as the key that made it would have been read.
    public mutating func next(text newString: String, caret newCaret: Int) -> Reading {
        let new = Array(newString.utf16)
        let old = text
        let oldCaret = caret
        text = new
        caret = newCaret
        if new != old {
            let edit = Self.edit(from: old, to: new, caret: oldCaret)
            expectedCaret = edit.caretAfter
            if !edit.inserted.isEmpty { return .typed(Self.string(edit.inserted)) }
            if !edit.removed.isEmpty { return .deleted(Self.string(edit.removed)) }
            return .nothing
        }
        guard newCaret != oldCaret else { return .nothing }
        let expected = expectedCaret
        expectedCaret = nil
        if newCaret == expected { return .nothing }
        if Self.line(at: oldCaret, in: new) != Self.line(at: newCaret, in: new) { return .moved(.line) }
        return .moved(abs(newCaret - oldCaret) == 1 ? .character : .word)
    }

    /// One edit: what went, what came, and where the caret is after it. Tried first at the caret (a key types or
    /// deletes there), so a letter typed beside the same letter is placed right; any other change by its common ends.
    package static func edit(from old: [UInt16], to new: [UInt16], caret: Int) -> (removed: [UInt16], inserted: [UInt16], caretAfter: Int) {
        let c = min(max(caret, 0), old.count)
        let grew = new.count - old.count
        // Typed or pasted at the caret.
        if grew > 0,
           c + grew <= new.count,
           Array(new[..<c]) == Array(old[..<c]),
           Array(new[(c + grew)...]) == Array(old[c...]) {
            return ([], Array(new[c..<(c + grew)]), c + grew)
        }
        let shrank = -grew
        // Backspace: what was just before the caret is gone.
        if shrank > 0,
           c - shrank >= 0,
           Array(new[..<(c - shrank)]) == Array(old[..<(c - shrank)]),
           Array(new[(c - shrank)...]) == Array(old[c...]) {
            return (Array(old[(c - shrank)..<c]), [], c - shrank)
        }
        // Forward delete: what was just after the caret is gone.
        if shrank > 0,
           c + shrank <= old.count,
           Array(new[..<c]) == Array(old[..<c]),
           Array(new[c...]) == Array(old[(c + shrank)...]) {
            return (Array(old[c..<(c + shrank)]), [], c)
        }
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let inserted = Array(new[prefix..<(new.count - suffix)])
        return (Array(old[prefix..<(old.count - suffix)]), inserted, prefix + inserted.count)
    }

    /// Which line an offset is on: the line breaks before it.
    package static func line(at offset: Int, in text: [UInt16]) -> Int {
        let end = min(max(offset, 0), text.count)
        return text[..<end].reduce(0) { $0 + ($1 == 0x0A || $1 == 0x0D || $1 == 0x2028 ? 1 : 0) }
    }

    package static func string(_ units: [UInt16]) -> String { String(decoding: units, as: UTF16.self) }
}

/// The one field being read without keys, and when it was first seen (18 Nov 2026). The first look at a field only
/// notes where it stands: a field that takes the focus puts its caret somewhere of its own accord, and that is no key.
@MainActor
public enum KeylessField {
    private static var element: AXUIElement?
    private static var state: KeylessCaret?
    private static var seenAt = Date.distantPast
    /// A field's own caret placement after it takes the focus is not read as a move.
    static let settle: TimeInterval = 0.25
    /// A field with more text than this is not copied at every change (a long document); it is not read without keys.
    static let largest = 20_000

    /// Forget the field: the focus moved, or secure input went off.
    public static func forget() { element = nil; state = nil }

    /// The field's text and caret now, as a reading. Nil: the first look, a field too long to compare, a selection
    /// (the selection's own reading says it), or nothing readable.
    static func reading(of e: AXUIElement, now: Date = Date()) -> KeylessCaret.Reading? {
        if let n = e.int(kAXNumberOfCharactersAttribute),
           n > largest { forget(); return nil }
        guard let text = e.string(kAXValueAttribute),
              text.utf16.count <= largest,
              let range = cfRange(e.attr(kAXSelectedTextRangeAttribute)) else { return nil }
        let caret = range.location
        guard let known = element,
              known.isSame(e),
              var s = state,
              now.timeIntervalSince(seenAt) >= settle else {
            if element.map({ !$0.isSame(e) }) ?? true { seenAt = now }
            element = e; state = KeylessCaret(text: text, caret: caret)
            return nil
        }
        let r = s.next(text: text, caret: caret)
        state = s
        // A selection made or changed: read by the selection's own reading, which follows.
        if range.length > 0,
           case .moved = r { return nil }
        return r
    }
}
