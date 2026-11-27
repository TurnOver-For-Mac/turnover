// SPDX-License-Identifier: GPL-3.0-or-later
import TurnOverCore

func longMenuPositionTests() {
    test("long menu: only titled menu items count (separators and other children left out)") {
        let kids: [(element: Int, role: String?, title: String?)] = [
            (0, "AXMenuItem", "Alex"), (1, "AXMenuItem", ""), (2, "AXMenuItem", nil),
            (3, "AXMenuItem", "Samantha"), (4, "AXGroup", "Header"), (5, nil, "No role"), (6, "AXMenuItem", "Zoe"),
        ]
        let items = LongMenuPosition.titledItems(kids)
        expect(items.map { $0.0 }, [0, 3, 6], "the titled items, in order")
        expect(items.map { $0.1 }, ["Alex", "Samantha", "Zoe"], "with their titles")
    }

    test("long menu: the kept list is used only for the same menu, the same count, within a minute") {
        check(LongMenuPosition.keptIsUsable(sameMenu: true, keptCount: 307, count: 307, age: 5), "the same open menu")
        check(!LongMenuPosition.keptIsUsable(sameMenu: false, keptCount: 307, count: 307, age: 5), "another menu")
        check(!LongMenuPosition.keptIsUsable(sameMenu: true, keptCount: 307, count: 308, age: 5), "a voice added")
        check(!LongMenuPosition.keptIsUsable(sameMenu: true, keptCount: 307, count: 307, age: 61), "over a minute old")
        check(!LongMenuPosition.keptIsUsable(sameMenu: true, keptCount: 307, count: 307, age: -1), "a clock that went back")
    }

    test("long menu: at most one read for one focus") {
        var reads = 0
        let menu = ["Alex", "Fred", "Samantha"]
        let exact: (String) -> ([String]) -> Int? = { t in { $0.firstIndex(of: t) } }
        let none: ([String]) -> Int? = { _ in nil }
        // Found in the kept list: no read.
        var found = LongMenuPosition.find(kept: menu, read: { reads += 1; return menu }, exact: exact("Fred"), loose: none)
        expect(found?.index, 1, "found in the kept list"); expect(reads, 0, "nothing read")
        // Nothing kept: one read.
        found = LongMenuPosition.find(kept: nil, read: { reads += 1; return menu }, exact: exact("Samantha"), loose: none)
        expect(found?.index, 2, "found after one read"); expect(reads, 1, "one read")
        // Not in the kept list (the menu opened again): one fresh read, and the fresh list is what counts.
        reads = 0
        let fresh = ["Alex", "Daniel", "Fred", "Samantha"]
        found = LongMenuPosition.find(kept: menu, read: { reads += 1; return fresh }, exact: exact("Daniel"), loose: none)
        expect(found?.index, 1, "found in the fresh list"); expect(found?.items.count, 4, "counted from the fresh list"); expect(reads, 1, "one read")
        // Not found anywhere: still one read, never two.
        reads = 0
        found = LongMenuPosition.find(kept: menu, read: { reads += 1; return menu }, exact: exact("Nobody"), loose: none)
        check(found == nil, "no position"); expect(reads, 1, "one read, not two")
        // An unanswered read: no position.
        found = LongMenuPosition.find(kept: nil, read: { nil }, exact: exact("Fred"), loose: none)
        check(found == nil, "an app that did not answer gives no position")
        // The kept list is never matched loosely: a title match there could be a stale list.
        reads = 0
        found = LongMenuPosition.find(kept: menu, read: { reads += 1; return fresh }, exact: { _ in nil }, loose: { $0.firstIndex(of: "Fred") })
        expect(found?.index, 2, "matched loosely in the fresh list only"); expect(reads, 1, "after one read")
    }

    test("long menu: an item that does not compare equal is found by its title, and by its place where titles repeat") {
        let list = [(t: "Alex", y: 0), (t: "Fred", y: 20), (t: "Fred", y: 40), (t: "Zoe", y: 60)]
        var frames = 0
        expect(LongMenuPosition.pick(list, title: "Zoe", titleOf: { $0.t }, sameFrame: { _ in frames += 1; return false }), 3, "a title only one item has")
        expect(frames, 0, "no place asked for")
        expect(LongMenuPosition.pick(list, title: "Fred", titleOf: { $0.t }, sameFrame: { frames += 1; return $0.y == 40 }), 2, "two Freds: the one in the same place")
        expect(frames, 2, "the place asked only of the two Freds")
        expect(LongMenuPosition.pick(list, title: "Fred", titleOf: { $0.t }, sameFrame: { _ in false }), nil, "two Freds, neither in the same place: no guess")
        expect(LongMenuPosition.pick(list, title: "Nobody", titleOf: { $0.t }, sameFrame: { _ in true }), nil, "a title no item has")
    }
}
