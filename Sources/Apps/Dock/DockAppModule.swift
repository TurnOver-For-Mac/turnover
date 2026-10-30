// SPDX-License-Identifier: GPL-3.0-or-later
// The Dock: the Cmd+Tab application switcher (NVDA reads the Alt+Tab task
// switcher the same way, as a list whose items gain focus).
//
// Measured 1 Oct 2026: while Command is held, the Dock exposes an AXList with
// subrole AXProcessSwitcherList whose children are AXButtons titled with the
// app names; the highlighted one is AXFocused, not AXSelected. The Dock sends
// AXSelectedChildrenChanged on the list for every Tab, AXCreated and
// AXFocusedUIElementChanged (the list) when it appears, AXUIElementDestroyed
// when it goes. The Dock never activates, so the core observes it always.
import Foundation
import ApplicationServices

final class DockAppModule: AppModule {
    /// The Dock's own list of apps (Control F3, or Option alone in the Windows style): Left and Right move, Up opens
    /// the item's menu, Return opens, Escape leaves. TurnOver's list keys (Up and Down walking rows, 6 Oct 2026) do
    /// not belong here: they reselected an item after Escape and kept the Dock half open, so the arrows go to the Dock.
    static func isDockList(_ element: AXUIElement) -> Bool {
        element.role == "AXList" && element.elements(kAXChildrenAttribute).contains { $0.role == "AXDockItem" }
    }

    override func objectClass(for element: AXUIElement, role: Role, subrole: String?) -> TurnOverObject.Type? {
        if Self.isDockList(element) { return DockList.self }
        if element.role == "AXList", subrole == "AXProcessSwitcherList" { return AppSwitcherList.self }
        if element.role == "AXButton", element.element(kAXParentAttribute)?.string(kAXSubroleAttribute) == "AXProcessSwitcherList" { return AppSwitcherItem.self }
        return nil
    }

    override func handleEvent(_ event: Event, next: () -> Void) {
        if event.kind == .gainFocus, event.obj is AppSwitcherList {
            // As VoiceOver does: just the highlighted application's name, not "application switcher, list" first.
            // (The first highlighted item is marked before the list reports focus.)
            if let item = event.obj.element.elements(kAXChildrenAttribute).first(where: { ($0.attr(kAXFocusedAttribute) as? Bool) == true }) {
                Speech.speakObject(ObjectFactory.make(item), reason: .focus)
            }
            return
        }
        // Escape in the Dock: the keys are back with the application, but the Dock reports its list as focused with
        // nothing selected ("list, 13 items, nothing selected", and the arrows then went back into the Dock). Read the
        // application's own focus instead.
        if event.kind == .gainFocus, event.obj is DockList,
           !event.obj.element.elements(kAXChildrenAttribute).contains(where: { ($0.attr(kAXSelectedAttribute) as? Bool) == true }) {
            Log.io("dock: left with nothing selected; back to the application")
            let pid = AXHandler.shared.activePid
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { AXHandler.shared.refocus(pid: pid) }
            return
        }
        next()
    }
}

/// The Dock's list of apps: a plain list, its keys the Dock's own.
final class DockList: TurnOverObject {
    override var role: Role { .list }
}

final class AppSwitcherList: TurnOverObject {
    override var role: Role { .list }
    override var name: String { "application switcher" }
}

final class AppSwitcherItem: TurnOverObject {
    override var role: Role { .listItem }
    /// Just the name, as VoiceOver says it: no "2 of 8".
    override var positionInfo: PositionInfo? { nil }
}
