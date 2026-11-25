// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

/// WebKit's selection can arrive as NSNotFound (Int.max), negative, past the end or reversed, and the page can be
/// empty. None of it may trap (24 Nov 2026: `selection + 25` overflowed in browse mode after a web dialog opened).
func webSelectionBoundsTests() {
    test("web selection: NSNotFound and negative ends are rejected") {
        check(WebSelectionBounds.validated(start: NSNotFound, end: NSNotFound) == nil, "both NSNotFound")
        check(WebSelectionBounds.validated(start: 5, end: NSNotFound) == nil, "end NSNotFound")
        check(WebSelectionBounds.validated(start: NSNotFound, end: 5) == nil, "start NSNotFound")
        check(WebSelectionBounds.validated(start: -1, end: 5) == nil, "negative start")
        check(WebSelectionBounds.validated(start: 5, end: Int.min) == nil, "Int.min end")
    }
    test("web selection: a usable selection is returned unchanged, past the end or reversed too") {
        let past = WebSelectionBounds.validated(start: 10, end: 5000)
        expect(past?.0, 10, "past the end, start"); expect(past?.1, 5000, "past the end, end")
        let reversed = WebSelectionBounds.validated(start: 40, end: 20)
        expect(reversed?.0, 40, "reversed start"); expect(reversed?.1, 20, "reversed end")
        let empty = WebSelectionBounds.validated(start: 0, end: 0)
        expect(empty?.1, 0, "empty selection at 0")
    }
    test("web selection: moving an index never overflows") {
        expect(WebSelectionBounds.moved(Int.max, by: 25, length: 100), 100, "Int.max plus 25, length known")
        expect(WebSelectionBounds.moved(Int.max, by: 25, length: 0), Int.max, "Int.max plus 25, length unknown")
        expect(WebSelectionBounds.moved(Int.min, by: -15, length: 100), 0, "Int.min minus 15")
        expect(WebSelectionBounds.moved(NSNotFound, by: 25, length: 100), 100, "NSNotFound plus 25")
        expect(WebSelectionBounds.moved(5, by: -15, length: 100), 0, "before the start")
        expect(WebSelectionBounds.moved(95, by: 25, length: 100), 100, "after the end")
        expect(WebSelectionBounds.moved(50, by: 25, length: 100), 75, "inside")
    }
    test("web selection: a failed length lookup (0) leaves ordinary values as they were") {
        expect(WebSelectionBounds.moved(3, by: 25, length: 0), 28, "length 0, forward")
        expect(WebSelectionBounds.moved(40, by: 25, length: -1), 65, "negative length, forward")
        expect(WebSelectionBounds.moved(5, by: -15, length: 0), 0, "length 0, never below 0")
    }
    test("web selection: the proportional guess survives empty and absurd input") {
        expect(WebSelectionBounds.proportionalGuess(position: 50, total: 100, bufferLength: 200), 100, "half way")
        expect(WebSelectionBounds.proportionalGuess(position: Int.max, total: 1, bufferLength: Int.max), Int.max, "huge values stay in range")
        expect(WebSelectionBounds.proportionalGuess(position: 5, total: 0, bufferLength: 200), 200, "unknown document length counts as 1")
        expect(WebSelectionBounds.proportionalGuess(position: 5, total: 100, bufferLength: 0), 0, "empty buffer")
        expect(WebSelectionBounds.proportionalGuess(position: -5, total: 100, bufferLength: 200), 0, "negative position")
        expect(WebSelectionBounds.proportionalGuess(position: 500, total: 100, bufferLength: 200), 200, "position past the end")
    }
}
