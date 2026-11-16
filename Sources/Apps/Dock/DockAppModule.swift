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
import AppKit
import ApplicationServices

package final class DockAppModule: AppModule {
    /// The Dock's own list of apps (Control F3, or Option alone in the Windows style): Left and Right move, Up opens
    /// the item's menu, Return opens, Escape leaves. TurnOver's list keys (Up and Down walking rows, 6 Oct 2026) do
    /// not belong here: they reselected an item after Escape and kept the Dock half open, so the arrows go to the Dock.
    static func isDockList(_ element: AXUIElement) -> Bool {
        element.role == "AXList" && element.elements(kAXChildrenAttribute).contains { $0.role == "AXDockItem" }
    }

    package override func objectClass(for element: AXUIElement, role: Role, subrole: String?) -> TurnOverObject.Type? {
        if Self.isDockList(element) { return DockList.self }
        if element.role == "AXList", subrole == "AXProcessSwitcherList" { return AppSwitcherList.self }
        if element.role == "AXButton", element.element(kAXParentAttribute)?.string(kAXSubroleAttribute) == "AXProcessSwitcherList" { return AppSwitcherItem.self }
        return nil
    }

    package override func hint(for object: TurnOverObject) -> String? {
        guard object is DockList else { return nil }
        return Self.listHint(orientation: object.element.string(kAXOrientationAttribute))
    }

    /// The keys that move through the Dock run the way it does: Left and Right at the bottom of the screen, Up and
    /// Down on the left or right side. No orientation reported is taken as the bottom, the Dock's default. The item's
    /// menu is left out: tried by ear on 9 Nov 2026 (build 24, macOS 27.2), Up at the bottom said "nothing selected".
    package static func listHint(orientation: String?) -> String {
        if orientation == (kAXVerticalOrientationValue as String) {
            return String(localized: "Up and Down move through the items; Return opens one.", comment: "A hint in the Dock on the side of the screen")
        }
        return String(localized: "Left and Right move through the items; Return opens one.", comment: "A hint in the Dock at the bottom of the screen")
    }

    /// An item reached in the Dock's own list is said by its name alone: "Safari", not "Safari, dock item, selected"
    /// (Oliver, 15 Nov 2026). Nothing for an item with no name, which keeps the general wording. Object navigation does
    /// not come through here, so it still says what the item is.
    package static func itemWords(name: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? nil : n
    }

    package override func handleEvent(_ event: Event, next: () -> Void) {
        if event.kind == .selection || event.kind == .gainFocus, event.obj.element.role == "AXDockItem",
           let words = Self.itemWords(name: event.obj.name) {
            // The same item reported by both the selection and the focus is said once.
            if let (e, t) = TurnOverObject.lastSelectionSpoken, Date().timeIntervalSince(t) < 0.6, e.isSame(event.obj.element) { return }
            TurnOverObject.noteSelectionSpoken(event.obj.element)
            Speech.speakOnly(words)
            return
        }
        if event.kind == .gainFocus, event.obj is AppSwitcherList {
            AppSwitcherList.openedOver = AXHandler.shared.activePid   // the app the switcher came up over (focus rules)
            // As VoiceOver does: just the highlighted application's name, not "application switcher, list" first.
            // (The first highlighted item is marked before the list reports focus.)
            AppSwitcherDiagnostics.lastAnnounced = nil
            if let item = event.obj.element.elements(kAXChildrenAttribute).first(where: { ($0.attr(kAXFocusedAttribute) as? Bool) == true }) {
                let object = ObjectFactory.make(item)
                AppSwitcherDiagnostics.lastAnnounced = object.name
                Speech.speakObject(object, reason: .focus)
            }
            return
        }
        // The next item's name, for the switcher's log line (16 Nov 2026); it is read as any focus is. The Dock sends a
        // selection for every Tab, not a focus, so the selection updates it too, or the name went stale after one Tab
        // (review, 16 Nov 2026).
        let isSwitcherItem = event.obj is AppSwitcherItem
        let isFocusOrSelection = event.kind == .gainFocus || event.kind == .selection
        if isSwitcherItem, isFocusOrSelection {
            AppSwitcherDiagnostics.lastAnnounced = event.obj.name
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
package final class DockList: TurnOverObject {
    package override var role: Role { .list }
}

final class AppSwitcherList: TurnOverObject {
    /// The app that was active when the switcher came up: its own focus news is set aside while the switcher is up.
    static var openedOver: pid_t?
    override var role: Role { .list }
    override var name: String { "application switcher" }
}

final class AppSwitcherItem: TurnOverObject {
    override var role: Role { .listItem }
    /// Just the name, as VoiceOver says it: no "2 of 8".
    override var positionInfo: PositionInfo? { nil }
}

/// Log lines only (16 Nov 2026). On 15 Nov 2026 (16:20:57 UTC) the switcher opened and TurnOver said one app's name,
/// and Command-Q half a second later reached a different app; nothing in the log could say whether the switcher's
/// selection had moved or the name was stale (the named app had stopped answering). Each key pressed while the
/// switcher is open now logs the item the switcher reports as selected at that moment, its process found from the
/// running applications (by the item's URL, or else its name), beside the name TurnOver last announced. Only the
/// Dock, which owns the switcher and is already being asked, is asked; never the application itself (31bd95f).
package enum AppSwitcherDiagnostics {
    /// The switcher item TurnOver last announced (its name), since the switcher opened.
    package static var lastAnnounced: String?

    package struct RunningApp {
        let name: String?
        let pid: pid_t
        let bundleURL: URL?
        package init(name: String?, pid: pid_t, bundleURL: URL?) {
            self.name = name
            self.pid = pid
            self.bundleURL = bundleURL
        }
    }

    /// The process for a switcher item: by its URL when it has one, else by its name; nil unless exactly one matches.
    package static func process(name: String, url: URL?, among apps: [RunningApp]) -> String? {
        if let url {
            let matching = apps.filter { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }
            guard matching.count == 1 else { return nil }
            return "pid \(matching[0].pid) by its URL"
        }
        let matching = apps.filter { $0.name == name }
        guard matching.count == 1 else { return nil }
        return "pid \(matching[0].pid) by its name"
    }

    package static func line(key: String, selectedName: String?, process: String?, lastAnnounced: String?) -> String {
        let selected = selectedName.map { "\"\($0)\"" } ?? "unknown"
        let announced = lastAnnounced.map { "\"\($0)\"" } ?? "nothing"
        return "switcher key \(key): selected \(selected), \(process ?? "pid unknown"); last announced \(announced)"
    }

    /// From the main thread as each key is decided (InputManager.handleKeyDown), before the key reaches the Dock.
    /// Whether a key pressed while the switcher is open gets the line: not Tab or Shift-Tab, which only move the
    /// selection and are the keys pressed most. The line is for Q, H and anything unexpected; it asks the Dock about
    /// every item on the main thread while the keyboard thread waits (review, 16 Nov 2026).
    package static func logsLine(for gesture: KeyboardGesture) -> Bool {
        let isTab = gesture.keyName == "tab"
        let onlySwitcherModifiers = gesture.modifiers.subtracting([.command, .shift]).isEmpty
        let movesSelection = isTab && onlySwitcherModifiers
        return !movesSelection
    }

    package static func keyDown(_ gesture: KeyboardGesture) {
        guard let list = API.focusObject as? AppSwitcherList else { return }
        guard logsLine(for: gesture) else { return }
        // Bounded, as a diagnostic must be: the switcher holds one item per running app.
        let selected = list.element.elements(kAXChildrenAttribute).prefix(64).first { ($0.attr(kAXFocusedAttribute) as? Bool) == true }
        let name = selected?.string(kAXTitleAttribute)
        let url = selected?.attr(kAXURLAttribute) as? URL
        var process: String?
        if let name {
            let apps = NSWorkspace.shared.runningApplications.map {
                RunningApp(name: $0.localizedName, pid: $0.processIdentifier, bundleURL: $0.bundleURL)
            }
            process = Self.process(name: name, url: url, among: apps)
        }
        Log.io(line(key: gesture.logDescription(), selectedName: name, process: process, lastAnnounced: lastAnnounced))
    }
}
