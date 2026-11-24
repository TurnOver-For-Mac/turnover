// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

/// A made-up page for the hidden-control search (24 Nov 2026): elements and markers are small numbers, so the search
/// runs without any accessibility. Marker n is the n-th piece of text; `pieces[n]` is the element the piece belongs to.
private struct MadeUpPage: HiddenControlPage {
    var pieces: [Int] = []
    var parents: [Int: Int] = [:]
    var focusable: Set<Int> = []
    var ancestors: [Int: Int] = [:]
    var focused: Set<Int> = []
    var styled: [Int] = []
    var grid: [Int: Int] = [:]      // point number (x) to the element under it
    var plainGroups: Set<Int> = []
    var wrongEnd = true
    func isSame(_ a: Int, _ b: Int) -> Bool { a == b }
    func isSameMarker(_ a: Int, _ b: Int) -> Bool { a == b }
    func textRange(of element: Int) -> (start: Int, end: Int)? {
        guard let first = pieces.firstIndex(of: element), let last = pieces.lastIndex(of: element) else { return nil }
        // The container's own range is wrong at its end, as WebKit's was (fact 5).
        return (first, element == 0 && wrongEnd ? max(0, first - 1) : last)
    }
    func element(at marker: Int) -> Int? { pieces.indices.contains(marker) ? pieces[marker] : nil }
    func parent(of element: Int) -> Int? { parents[element] }
    func next(after marker: Int) -> Int? { marker + 1 < pieces.count ? marker + 1 : nil }
    func styledElements(from start: Int, to end: Int) -> [Int] { styled }
    func canTakeFocus(_ element: Int) -> Bool { focusable.contains(element) }
    func focusableAncestor(of element: Int) -> Int? { ancestors[element] }
    func isFocused(_ element: Int) -> Bool? { focused.contains(element) }
    func isPlainGroup(_ element: Int) -> Bool { plainGroups.contains(element) }
    func gridPoints(over element: Int) -> [CGPoint] { grid.keys.sorted().map { CGPoint(x: $0, y: 0) } }
    func element(atPoint point: CGPoint) -> Int? { grid[Int(point.x)] }
}

/// Element 0 is the row. 1 and 2 are links inside it (their text pieces are 11 and 12); 3 is a button that only the
/// styled text names; 4 is an image link only the grid reaches; 9 is the link after the row.
private func row() -> MadeUpPage {
    var p = MadeUpPage()
    p.pieces = [0, 11, 12, 9]
    p.parents = [11: 0, 12: 0, 1: 0, 2: 0, 3: 0, 4: 0, 9: 99]
    p.focusable = [1, 2, 3, 4]
    p.ancestors = [11: 1, 12: 2]
    p.styled = [3]
    p.grid = [10: 4]
    return p
}

func hiddenFocusTests() {
    typealias D = HiddenFocusDecision
    test("hidden focus: after a Tab with the row still reported, a control that still has the keyboard means not moved yet") {
        expect(D.afterTabStillReported(hasRecord: true, recordedControlFocused: true, containerFocused: false), .pollOn)
    }
    test("hidden focus: the keyboard back on the row speaks the row") {
        expect(D.afterTabStillReported(hasRecord: true, recordedControlFocused: false, containerFocused: true), .backOnContainer)
    }
    test("hidden focus: moved to another hidden control searches") {
        expect(D.afterTabStillReported(hasRecord: true, recordedControlFocused: false, containerFocused: false), .search)
        expect(D.afterTabStillReported(hasRecord: true, recordedControlFocused: nil, containerFocused: false), .search)
    }
    test("hidden focus: with nothing recorded only a row that says it has no keyboard starts a search") {
        expect(D.afterTabStillReported(hasRecord: false, recordedControlFocused: nil, containerFocused: false), .search)
        expect(D.afterTabStillReported(hasRecord: false, recordedControlFocused: nil, containerFocused: true), .pollOn)
        expect(D.afterTabStillReported(hasRecord: false, recordedControlFocused: nil, containerFocused: nil), .pollOn)
    }
    test("hidden focus: a found control that has the keyboard is spoken, with or without evidence") {
        expect(D.afterSearch(foundFocusedControl: true, hasRecord: false, focusedBeforeTab: nil, containerFocusedNow: false), .moved)
    }
    test("hidden focus: nothing found with evidence gives the fallback; without, silence") {
        expect(D.afterSearch(foundFocusedControl: false, hasRecord: true, focusedBeforeTab: nil, containerFocusedNow: false), .fallback)
        expect(D.afterSearch(foundFocusedControl: false, hasRecord: false, focusedBeforeTab: true, containerFocusedNow: false), .fallback)
        expect(D.afterSearch(foundFocusedControl: false, hasRecord: false, focusedBeforeTab: nil, containerFocusedNow: false), .silent)
        expect(D.afterSearch(foundFocusedControl: false, hasRecord: false, focusedBeforeTab: false, containerFocusedNow: false), .silent)
    }
    test("hidden focus: a list that names its option by aria-activedescendant never gets the fallback") {
        // It may answer not focused, but it was not focused before the Tab either, and nothing hidden is recorded.
        for before in [false, nil] as [Bool?] {
            expect(D.afterSearch(foundFocusedControl: false, hasRecord: false, focusedBeforeTab: before, containerFocusedNow: false), .silent)
        }
        // A list that still says focused after the Tab is not evidence either.
        expect(D.afterSearch(foundFocusedControl: false, hasRecord: false, focusedBeforeTab: true, containerFocusedNow: true), .silent)
    }
    test("hidden search: text pieces find the links, and the one that says focused is chosen") {
        var p = row()
        p.focused = [2]
        let r = HiddenControlSearch.search(in: 0, page: p, known: [], includeGrid: false, timeIsUp: { false })
        expect(r.focused, 2)
        expect(r.stage, .text)
        expect(r.controls, [1, 2])
        expect(r.hops, 3, "the row, two links, then the walk stops at the piece outside")
    }
    test("hidden search: the control after the row is never taken, though the row's own range ends early") {
        var p = row()
        p.parents[9] = 0   // even a piece that claims the row as its parent only counts if it takes the keyboard
        p.focused = [9]
        let r = HiddenControlSearch.search(in: 0, page: p, known: [], includeGrid: false, timeIsUp: { false })
        expect(r.focused, nil)
    }
    test("hidden search: the styled text adds a button the pieces do not reach") {
        var p = row()
        p.focused = [3]
        let r = HiddenControlSearch.search(in: 0, page: p, known: [], includeGrid: false, timeIsUp: { false })
        expect(r.focused, 3)
        expect(r.stage, .styled)
    }
    test("hidden search: the grid runs only when asked, and finds a control with no text") {
        var p = row()
        p.focused = [4]
        let without = HiddenControlSearch.search(in: 0, page: p, known: [], includeGrid: false, timeIsUp: { false })
        expect(without.focused, nil)
        expect(without.points, 0)
        let with = HiddenControlSearch.search(in: 0, page: p, known: [], includeGrid: true, timeIsUp: { false })
        expect(with.focused, 4)
        expect(with.stage, .grid)
    }
    test("hidden search: controls already known are asked first") {
        var p = row()
        p.focused = [1]
        let r = HiddenControlSearch.search(in: 0, page: p, known: [1, 2], includeGrid: true, timeIsUp: { false })
        expect(r.focused, 1)
        expect(r.stage, .remembered)
        expect(r.hops, 0)
    }
    test("hidden search: nothing found gives no control and no focused one") {
        let r = HiddenControlSearch.search(in: 0, page: row(), known: [], includeGrid: true, timeIsUp: { false })
        expect(r.focused, nil)
        expect(r.controls, [1, 2, 3, 4])
    }
    test("hidden search: of two that say focused, the one with a real role is chosen over a nameless group") {
        var p = row()
        p.focusable.insert(5); p.parents[5] = 0; p.plainGroups = [5]
        p.pieces = [0, 5, 11, 12, 9]
        p.ancestors[5] = 5
        p.focused = [5, 2]
        let r = HiddenControlSearch.search(in: 0, page: p, known: [], includeGrid: false, timeIsUp: { false })
        expect(r.focused, 2)
    }
    test("hidden search: out of time stops it and says so") {
        var asked = 0
        let r = HiddenControlSearch.search(in: 0, page: row(), known: [], includeGrid: true, timeIsUp: { asked += 1; return asked > 2 })
        check(r.cutShort, "cut short")
    }
    test("hidden search: a page with no end to its text is cut at the cap") {
        var p = MadeUpPage()
        p.pieces = [0] + (100..<500).map { $0 }
        for e in 100..<500 { p.parents[e] = 0 }
        let r = HiddenControlSearch.search(in: 0, page: p, known: [], includeGrid: false, timeIsUp: { false })
        expect(r.hops, HiddenControlSearch.hopCap)
        check(r.cutShort, "cut short at the cap")
    }
    test("hidden focus: the repeat rule lets another element through when it is reached by Tab, and keeps the same element twice") {
        check(!Speech.focusRepeated(words: "Remove, button", last: "Remove, button", after: 0.1, anotherRow: false, anotherByTab: true), "two Remove buttons by quick Tabs")
        check(Speech.focusRepeated(words: "Remove, button", last: "Remove, button", after: 0.1, anotherRow: false, anotherByTab: false), "the same element twice")
        check(Speech.focusRepeated(words: "12, A1", last: "12, A1", after: 0.1, anotherRow: false), "the old call still means the old rule")
    }
    test("hidden search: time running out in the styled step stops it before the grid") {
        var p = row()
        p.focused = [4]
        var asked = 0
        // The known list and the pieces ask a few times; the styled loop must ask too, and stop.
        let r = HiddenControlSearch.search(in: 0, page: p, known: [], includeGrid: true, timeIsUp: { asked += 1; return asked > 6 })
        check(r.cutShort, "cut short")
        expect(r.focused, nil, "the grid never ran")
    }
}
