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
                menuOpened(menu)
                watchForClose(menu, until: Date().addingTimeInterval(600))
                return
            }
            guard triesLeft > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { look(triesLeft - 1) } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { look(15) } }
    }

    /// A menu no notice will close: when it has no size or is gone, it ends as a reported one does.
    @MainActor func watchForClose(_ menu: AXUIElement, until limit: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The process's own menu-closed notice may have ended it already: one ending, not two.
                guard self.openMenus.contains(where: { $0.isSame(menu) }) else { return }
                if Self.hasSize(menu) {
                    if Date() < limit { self.watchForClose(menu, until: limit) }
                    return
                }
                let pid = menu.pid
                self.openMenus.removeAll { $0.isSame(menu) }
                EventHandler.queue(Event(.menuEnd, ObjectFactory.make(menu)))
                if self.openMenus.isEmpty { self.lastMenuClosed = (pid, Date()) }
                Log.io("context menu: closed (seen by looking)")
            }
        }
    }

    /// A menu came up: kept as open and announced once. From the process's own notice, or from looking.
    func menuOpened(_ element: AXUIElement) {
        openMenus.removeAll { $0.isSame(element) }
        openMenus.append(element)
        menuOpenedAt = Date()
        logMenu(element)
        // Word opens its context menu and every submenu at once: one announcement.
        if Date().timeIntervalSince(lastMenuStart) > 0.5 { EventHandler.queue(Event(.menuStart, ObjectFactory.make(element))); Tones.menuOpened() }
        lastMenuStart = Date()
    }
}
