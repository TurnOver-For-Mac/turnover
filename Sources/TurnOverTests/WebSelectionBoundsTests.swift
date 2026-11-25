// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

/// WebKit's selection can arrive as NSNotFound (Int.max), negative, past the end or reversed, and the page can be
/// empty. None of it may trap (24 Nov 2026: `selection + 25` overflowed in browse mode after a web dialog opened).
func webSelectionBoundsTests() {
    test("web selection: NSNotFound and negative ends are rejected") {
        check(WebSelectionBounds.validated(start: NSNotFound, end: NSNotFound, length: 100) == nil, "both NSNotFound")
        check(WebSelectionBounds.validated(start: 5, end: NSNotFound, length: 100) == nil, "end NSNotFound")
        check(WebSelectionBounds.validated(start: NSNotFound, end: 5, length: 100) == nil, "start NSNotFound")
        check(WebSelectionBounds.validated(start: -1, end: 5, length: 100) == nil, "negative start")
        check(WebSelectionBounds.validated(start: 5, end: Int.min, length: 100) == nil, "Int.min end")
    }
    test("web selection: past the end is cut and reversed is put in order") {
        let cut = WebSelectionBounds.validated(start: 10, end: 5000, length: 100)
        expect(cut?.0, 10, "start kept"); expect(cut?.1, 100, "end cut to the length")
        let reversed = WebSelectionBounds.validated(start: 40, end: 20, length: 100)
        expect(reversed?.0, 20, "reversed start"); expect(reversed?.1, 40, "reversed end")
        let beyond = WebSelectionBounds.validated(start: 300, end: 400, length: 100)
        expect(beyond?.0, 100, "both past the end, start"); expect(beyond?.1, 100, "both past the end, end")
    }
    test("web selection: a zero or negative document length gives an empty selection at 0") {
        let zero = WebSelectionBounds.validated(start: 7, end: 9, length: 0)
        expect(zero?.0, 0, "zero length start"); expect(zero?.1, 0, "zero length end")
        let negative = WebSelectionBounds.validated(start: 7, end: 9, length: -4)
        expect(negative?.1, 0, "negative length end")
    }
    test("web selection: moving an index never overflows") {
        expect(WebSelectionBounds.moved(Int.max, by: 25, length: 100), 100, "Int.max plus 25")
        expect(WebSelectionBounds.moved(Int.min, by: -15, length: 100), 0, "Int.min minus 15")
        expect(WebSelectionBounds.moved(NSNotFound, by: 25, length: 100), 100, "NSNotFound plus 25")
        expect(WebSelectionBounds.moved(5, by: -15, length: 100), 0, "before the start")
        expect(WebSelectionBounds.moved(95, by: 25, length: 100), 100, "after the end")
        expect(WebSelectionBounds.moved(50, by: 25, length: 100), 75, "inside")
        expect(WebSelectionBounds.moved(3, by: 25, length: 0), 0, "zero document length")
    }
    test("web selection: the proportional guess survives empty and absurd input") {
        expect(WebSelectionBounds.proportionalGuess(position: 50, total: 100, bufferLength: 200), 100, "half way")
        expect(WebSelectionBounds.proportionalGuess(position: Int.max, total: 1, bufferLength: Int.max), Int.max, "huge values stay in range")
        expect(WebSelectionBounds.proportionalGuess(position: 5, total: 0, bufferLength: 200), 0, "zero document length")
        expect(WebSelectionBounds.proportionalGuess(position: 5, total: 100, bufferLength: 0), 0, "empty buffer")
        expect(WebSelectionBounds.proportionalGuess(position: -5, total: 100, bufferLength: 200), 0, "negative position")
        expect(WebSelectionBounds.proportionalGuess(position: 500, total: 100, bufferLength: 200), 200, "position past the end")
    }
}
