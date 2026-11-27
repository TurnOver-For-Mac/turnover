// SPDX-License-Identifier: GPL-3.0-or-later
import TurnOverCore

func menuWrapTests() {
    test("menu wrap: Down lands on the first item that can be stopped on, Up on the last") {
        // Options, a separator, Open, Force Quit (as the Dock's menu).
        let flags = [true, false, true, true]
        expect(MenuWrap.target(enabledShowing: flags, down: true), 0, "Down wraps to the first")
        expect(MenuWrap.target(enabledShowing: flags, down: false), 3, "Up wraps to the last")
        expect(MenuWrap.target(enabledShowing: [false, true, true, false], down: true), 1, "a dimmed first item is skipped")
        expect(MenuWrap.target(enabledShowing: [false, true, true, false], down: false), 2, "a filtered-out last item is skipped")
        expect(MenuWrap.target(enabledShowing: [false, false], down: true), nil, "nothing to stop on")
        expect(MenuWrap.target(enabledShowing: [], down: false), nil, "an empty menu")
    }

    test("menu wrap: only a plain, single press with somewhere to go wraps") {
        check(MenuWrap.shouldWrap(isRepeat: false, hasBefore: true, inMenuBar: false, stoppableCount: 2), "an ordinary menu")
        check(!MenuWrap.shouldWrap(isRepeat: true, hasBefore: true, inMenuBar: false, stoppableCount: 5), "a held key stops at the end")
        check(!MenuWrap.shouldWrap(isRepeat: false, hasBefore: false, inMenuBar: false, stoppableCount: 5), "no item known")
        check(!MenuWrap.shouldWrap(isRepeat: false, hasBefore: true, inMenuBar: true, stoppableCount: 5), "the menu bar")
        check(!MenuWrap.shouldWrap(isRepeat: false, hasBefore: true, inMenuBar: false, stoppableCount: 1), "one item only")
        check(!MenuWrap.shouldWrap(isRepeat: false, hasBefore: true, inMenuBar: false, stoppableCount: 0), "none")
    }

    test("menu wrap: the item at the end the key runs into is known") {
        let flags = [true, false, true, true]
        check(MenuWrap.isEnd(enabledShowing: flags, index: 3, down: true), "last, going down")
        check(!MenuWrap.isEnd(enabledShowing: flags, index: 2, down: true), "not last, going down")
        check(MenuWrap.isEnd(enabledShowing: flags, index: 0, down: false), "first, going up")
        check(!MenuWrap.isEnd(enabledShowing: flags, index: 1, down: false), "a separator is never the end")
        check(MenuWrap.isEnd(enabledShowing: [true, true, false], index: 1, down: true), "a dimmed last item does not count")
        check(!MenuWrap.isEnd(enabledShowing: [false], index: 0, down: true), "nothing to stop on")
    }

    test("menu wrap: submenus found by looking after the highlighted menu close, deepest first") {
        // root (looked, not a submenu), submenu, deeper submenu.
        expect(MenuWrap.submenusToClose(looked: [false, true, true], highlightedIn: 0), [2, 1], "the root has the highlight")
        expect(MenuWrap.submenusToClose(looked: [false, true, true], highlightedIn: 1), [2], "the first submenu has it")
        expect(MenuWrap.submenusToClose(looked: [false, true, true], highlightedIn: 2), [], "the deepest has it")
        expect(MenuWrap.submenusToClose(looked: [false, true, false], highlightedIn: 0), [1], "a reported menu is not closed")
        expect(MenuWrap.submenusToClose(looked: [false, false], highlightedIn: 0), [], "ordinary menus: none")
        expect(MenuWrap.submenusToClose(looked: [true], highlightedIn: -1), [], "highlight not in an open menu")
    }

    test("menus: a page's own menu does not hold the page's focus back (27 Nov 2026)") {
        typealias A = AXHandler
        expect(A.focusPastWebMenu(targetIsWeb: true, webMenuOpen: true, otherMenuOpen: false, targetInWebMenu: false), .followAndForgetMenu,
               "Tab on past a search box's suggestions: followed, the list no longer counted open")
        expect(A.focusPastWebMenu(targetIsWeb: true, webMenuOpen: true, otherMenuOpen: false, targetInWebMenu: true), .follow,
               "a link inside the page's menu: followed, the menu kept")
        expect(A.focusPastWebMenu(targetIsWeb: false, webMenuOpen: true, otherMenuOpen: false, targetInWebMenu: false), .hold,
               "a focus outside the page (the toolbar) while the page's menu is open: held as before")
        expect(A.focusPastWebMenu(targetIsWeb: true, webMenuOpen: false, otherMenuOpen: true, targetInWebMenu: false), .hold,
               "an application's own menu (Word handing the document the focus under it): held as before")
        expect(A.focusPastWebMenu(targetIsWeb: true, webMenuOpen: true, otherMenuOpen: true, targetInWebMenu: false), .hold,
               "the application's own menu open as well: held")
    }
}
