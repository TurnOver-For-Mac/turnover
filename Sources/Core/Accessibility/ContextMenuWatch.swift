// SPDX-License-Identifier: GPL-3.0-or-later
// A context menu asked for on an item of another process (the Dock, Control Centre, a menu bar extra) is not
// always announced by that process: the Dock answered AXShowMenu with success and never sent the menu-opened
// notice, so TurnOver said "nothing selected" as the list's selection emptied, and the arrows reached the Dock.
// After a successful request TurnOver looks for the menu itself, and when it finds one that no notice reported, it
// treats it exactly as a reported one (the same menuOpened path) and watches for it to go.
import Foundation
import ApplicationServices
import TurnOverAX

extension AXHandler {
    /// Whether a context menu has just been asked for, or one is open: the selection or focus news that comes with
    /// the menu opening is the menu's side effect, not a thing to say.
    nonisolated public static func menuJustAsked(requestedAt: Date, now: Date, menuOpen: Bool) -> Bool {
        menuOpen || now.timeIntervalSince(requestedAt) < 2
    }

    /// Where the menu of an item may be: a child of the item, then of its application, then the menu the
    /// application's focus is in.
    @MainActor static func contextMenuCandidates(of element: AXUIElement) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(element.pid)
        // Never a long wait on main for a menu (AGENTS.md): a busy process is asked again on the next look.
        AXUIElementSetMessagingTimeout(app, 0.3)
        AXUIElementSetMessagingTimeout(element, 0.3)
        defer { AXUIElementSetMessagingTimeout(element, 0) }
        var found = element.elements(kAXChildrenAttribute).filter { $0.role == "AXMenu" }
        found += app.elements(kAXChildrenAttribute).filter { $0.role == "AXMenu" }
        if found.isEmpty, var f = app.element(kAXFocusedUIElementAttribute) {
            for _ in 0..<4 {
                if f.role == "AXMenu" { found.append(f); break }
                guard let up = f.element(kAXParentAttribute) else { break }
                f = up
            }
        }
        return found.filter { hasSize($0) }
    }

    /// After the context-menu command succeeded on `element`: if no menu-opened notice comes, look for the menu.
    @MainActor public func watchForContextMenu(of element: AXUIElement) {
        let startedWith = lastMenuStart
        func look(_ triesLeft: Int) {
            if lastMenuStart != startedWith { return }   // the process announced it: the usual path has it
            if let menu = Self.contextMenuCandidates(of: element).first {
                Log.io("context menu: found \(menu.role) by looking; the process sent no notice")
                registerLookedMenu(menu, submenu: false, announce: true)
                return
            }
            guard triesLeft > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { look(triesLeft - 1) } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { look(15) } }
    }

    /// A menu (or submenu) that no notice reported, found by looking: it joins the open menus as a reported one does,
    /// is remembered as found by looking, and is watched until it goes.
    @MainActor func registerLookedMenu(_ menu: AXUIElement, submenu: Bool, announce: Bool) {
        lookedMenus.removeAll { $0.menu.isSame(menu) }
        lookedMenus.append((menu, submenu))
        if announce { menuOpened(menu, force: submenu) }
        else {
            openMenus.removeAll { $0.isSame(menu) }
            openMenus.append(menu)
            menuOpenedAt = Date()
            lastMenuStart = Date()
        }
        Log.io("menu: \(submenu ? "submenu" : "menu") registered by looking; \(openMenus.count) open, \(lookedMenus.count) found by looking")
        watchForClose(menu, until: Date().addingTimeInterval(600))
    }

    /// Whether any open menu was found by looking (forgets the ones that have closed meanwhile).
    var hasLookedMenus: Bool {
        if lookedMenus.isEmpty { return false }
        let open = openMenus
        lookedMenus.removeAll { l in !open.contains { $0.isSame(l.menu) } }
        return !lookedMenus.isEmpty
    }

    func isLookedMenu(_ menu: AXUIElement) -> Bool { lookedMenus.contains { $0.menu.isSame(menu) } }

    /// Which menu a submenu found by looking sits in: its position among the open menus, nil when it is not open.
    func openIndex(of menu: AXUIElement) -> Int? { openMenus.firstIndex { $0.isSame(menu) } }

    /// A submenu found by looking has gone: no size, nothing in it, or no menu before it for it to belong to. (A
    /// closed AXMenu may go on existing, so the element being there says nothing.)
    @MainActor func lookedSubmenuIsGone(_ menu: AXUIElement) -> Bool {
        if !Self.hasSize(menu) || menu.elements(kAXChildrenAttribute).isEmpty { return true }
        return (openIndex(of: menu) ?? 0) == 0
    }

    /// The one end path for a menu found by looking: leaves the open menus, queues its end, as a reported one does.
    @MainActor func endLookedMenu(_ menu: AXUIElement, why: String) {
        guard openMenus.contains(where: { $0.isSame(menu) }) else { lookedMenus.removeAll { $0.menu.isSame(menu) }; return }
        let pid = menu.pid
        openMenus.removeAll { $0.isSame(menu) }
        lookedMenus.removeAll { $0.menu.isSame(menu) }
        EventHandler.queue(Event(.menuEnd, ObjectFactory.make(menu)))
        if openMenus.isEmpty { lastMenuClosed = (pid, Date()) }
        Log.io("context menu: closed (\(why)); \(openMenus.count) open, \(lookedMenus.count) found by looking")
    }

    /// After a key found the highlight in `menu`: the submenus found by looking that sit after it are closed, deepest first.
    @MainActor func closeLookedSubmenus(after menu: AXUIElement) {
        guard hasLookedMenus, let idx = openIndex(of: menu) else { return }
        let flags = openMenus.map { m in lookedMenus.contains { $0.sub && $0.menu.isSame(m) } }
        for i in MenuWrap.submenusToClose(looked: flags, highlightedIn: idx) where i < openMenus.count {
            endLookedMenu(openMenus[i], why: "its parent menu has the highlight")
        }
    }

    /// A menu no notice will close: when it has no size or is gone, it ends as a reported one does. A root menu that is
    /// gone takes every submenu found by looking in its process with it.
    @MainActor func watchForClose(_ menu: AXUIElement, until limit: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The process's own menu-closed notice may have ended it already: one ending, not two.
                guard self.openMenus.contains(where: { $0.isSame(menu) }) else { return }
                let isSub = self.lookedMenus.first { $0.menu.isSame(menu) }?.sub ?? false
                let gone = isSub ? self.lookedSubmenuIsGone(menu) : !Self.hasSize(menu)
                if !gone {
                    if Date() < limit { self.watchForClose(menu, until: limit) }
                    return
                }
                if !isSub {
                    let pid = menu.pid
                    let subs = self.lookedMenus.filter { $0.sub && $0.menu.pid == pid }.map { $0.menu }
                    for s in self.openMenus.reversed() where subs.contains(where: { $0.isSame(s) }) {
                        self.endLookedMenu(s, why: "its root menu is gone")
                    }
                }
                self.endLookedMenu(menu, why: "seen by looking")
            }
        }
    }

    /// A menu came up: kept as open and announced once. From the process's own notice, or from looking.
    /// `force`: a submenu found by looking is announced even within half a second of the menu it hangs from.
    func menuOpened(_ element: AXUIElement, force: Bool = false) {
        openMenus.removeAll { $0.isSame(element) }
        openMenus.append(element)
        menuOpenedAt = Date()
        logMenu(element)
        // Word opens its context menu and every submenu at once: one announcement.
        if force || Date().timeIntervalSince(lastMenuStart) > 0.5 { EventHandler.queue(Event(.menuStart, ObjectFactory.make(element))); Tones.menuOpened() }
        lastMenuStart = Date()
    }
}

/// The wrap-round decisions for a menu, kept pure.
public enum MenuWrap {
    /// The index to land on: the first (Down wraps) or last (Up wraps) item that is enabled and showing.
    public static func target(enabledShowing: [Bool], down: Bool) -> Int? {
        down ? enabledShowing.firstIndex(of: true) : enabledShowing.lastIndex(of: true)
    }
    /// Whether the key may wrap: not held down, an item known, not the menu bar, and at least two items to stop on.
    public static func shouldWrap(isRepeat: Bool, hasBefore: Bool, inMenuBar: Bool, stoppableCount: Int) -> Bool {
        !isRepeat && hasBefore && !inMenuBar && stoppableCount >= 2
    }
    /// Whether `index` is already the end the key runs into (the last stoppable item for Down, the first for Up).
    public static func isEnd(enabledShowing: [Bool], index: Int, down: Bool) -> Bool {
        guard let end = down ? enabledShowing.lastIndex(of: true) : enabledShowing.firstIndex(of: true) else { return false }
        return end == index
    }
    /// Of the open menus (outermost first), flagged by whether each was found by looking as a submenu: the positions
    /// after the one holding the highlight that are such submenus, deepest first.
    public static func submenusToClose(looked: [Bool], highlightedIn: Int) -> [Int] {
        guard highlightedIn >= 0 else { return [] }
        return looked.indices.reversed().filter { $0 > highlightedIn && looked[$0] }
    }
}
