// SPDX-License-Identifier: GPL-3.0-or-later
// A window with nothing TurnOver can read: a custom-drawn or OpenGL window whose accessibility tree holds only its
// title-bar buttons and perhaps a toolbar (Parallels' installation assistant, issue 74, 23 Oct 2026; Bambu Studio's
// plate, 26 Oct). TurnOver said "window" and then nothing, and the person had to know that screen recognition exists
// and where it is. Now, a moment after such a window comes to the front, TurnOver says so once and names the key for
// screen recognition in the keyboard style in use (Oliver, 27 Oct 2026: "include the relevant shortcut based on which
// mode they are using"). The look at the window runs off the main thread, every element with a short messaging
// timeout and the whole with a deadline, so a slow app costs nothing on main (AGENTS.md); it is looked at twice, a
// second apart, since a web view or an Electron window fills in late (a code review, 27 Oct 2026).
import Foundation
import AppKit
import ApplicationServices

public enum EmptyWindowNotice {
    /// Roles that are something to read or do. A container (group, scroll area, split group) is not: Parallels' window
    /// was all groups. A static text counts only with words in it; a list, table, web area or outline only with
    /// children; a picture or heading only with a name.
    nonisolated private static let contentRoles: Set<String> = [
        "AXStaticText", "AXTextField", "AXTextArea", "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXSlider", "AXLink", "AXTable", "AXOutline", "AXList", "AXWebArea", "AXTabGroup", "AXComboBox", "AXIncrementor",
        "AXDisclosureTriangle", "AXHeading", "AXImage", "AXBrowser", "AXDockItem", "AXCell", "AXRow", "AXProgressIndicator",
        "AXSearchField", "AXDateField", "AXTimeField", "AXColorWell", "AXLevelIndicator", "AXMenu", "AXMenuItem",
    ]
    nonisolated private static let needChildren: Set<String> = ["AXTable", "AXOutline", "AXList", "AXWebArea", "AXBrowser", "AXTabGroup", "AXMenu"]
    nonisolated private static let needName: Set<String> = ["AXImage", "AXHeading", "AXCell", "AXRow"]
    nonisolated private static let titleBarSubroles: Set<String> = ["AXCloseButton", "AXZoomButton", "AXMinimizeButton", "AXFullScreenButton", "AXToolbarButton"]
    /// Windows already told about, so a window is told about once (the newest 12), and those being looked at.
    private static var told: [AXUIElement] = []
    private static var pending: [AXUIElement] = []

    nonisolated enum Look: Equatable { case readable(String), empty, inconclusive }

    /// Called as a window comes to the front; looks a moment later, and again a second on, and says so if nothing
    /// readable is in it both times.
    public static func check(_ window: AXUIElement, pid: pid_t) {
        guard !told.contains(where: { $0.isSame(window) }), !pending.contains(where: { $0.isSame(window) }) else { return }
        pending.append(window)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.8) {
            let first = look(window)
            Log.io("empty window check: pid \(pid): \(first)")
            guard first == .empty else { DispatchQueue.main.async { MainActor.assumeIsolated { forget(window) } }; return }
            // Looked at again a second on: a window still being built, or a web view loading, fills in by then.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.2) {
                let second = look(window)
                Log.io("empty window check again: pid \(pid): \(second)")
                DispatchQueue.main.async { MainActor.assumeIsolated { if second == .empty { say(for: window, pid: pid) } else { forget(window) } } }
            }
        }
    }

    private static func forget(_ window: AXUIElement) { pending.removeAll { $0.isSame(window) } }

    /// What the window holds beyond its title-bar buttons, toolbar and title: readable (the first readable role),
    /// empty, or inconclusive (the walk ran out of budget or the app didn't answer; nothing is said then).
    /// Bounded: at most 400 elements, 10 levels deep, one second in all, 0.3 s per element.
    nonisolated static func look(_ window: AXUIElement) -> Look {
        let title = (window.string(kAXTitleAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let deadline = Date().addingTimeInterval(1.0)
        var visited = 0
        var inconclusive = false
        func walk(_ e: AXUIElement, _ depth: Int) -> String? {
            if visited >= 400 || depth >= 10 || Date() > deadline { inconclusive = true; return nil }
            visited += 1
            AXUIElementSetMessagingTimeout(e, 0.3)
            let role = e.role
            if role == "?" { inconclusive = true; return nil }   // the app didn't answer
            if role == "AXToolbar" { return nil }
            let subrole = e.string(kAXSubroleAttribute) ?? ""
            if titleBarSubroles.contains(subrole) { return nil }
            let name = ((e.string(kAXTitleAttribute) ?? "") + " " + (e.string(kAXDescriptionAttribute) ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
            if contentRoles.contains(role) {
                if role == "AXStaticText" {
                    let words = ((e.string(kAXValueAttribute) ?? "") + " " + name).trimmingCharacters(in: .whitespacesAndNewlines)
                    // The window's own title is a static text at the top of its tree: not content.
                    if !words.isEmpty, !(depth <= 2 && (words == title || name == title)) { return role }
                } else if needChildren.contains(role) {
                    if !e.elements(kAXChildrenAttribute).isEmpty { return role }
                } else if needName.contains(role) {
                    if !name.isEmpty { return role }
                } else { return role + (subrole.isEmpty ? "" : "/" + subrole) }
            } else if role == "AXGroup", !name.isEmpty, e.elements(kAXChildrenAttribute).isEmpty {
                return "named group"   // a named leaf group reads as an item
            }
            for k in e.elements(kAXChildrenAttribute) {
                if let r = walk(k, depth + 1) { return r }
                if inconclusive { return nil }
            }
            return nil
        }
        if let r = walk(window, 0) { return .readable(r) }
        return inconclusive ? .inconclusive : .empty
    }

    private static func say(for window: AXUIElement, pid: pid_t) {
        forget(window)
        guard !told.contains(where: { $0.isSame(window) }) else { return }
        // Still the window in front of the app in front, no sheet or dialog over it, and not a direct app.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let front = AXUIElementCreateApplication(pid).element(kAXFocusedWindowAttribute), front.isSame(window),
              !AXHandler.modalInFront(pid: pid), InputManager.directPid != pid else { return }
        told.append(window); if told.count > 12 { told.removeFirst() }
        // The key for screen recognition in this style: VO-Shift-L in the VoiceOver style (describeImage recognises
        // the screen when the cursor isn't on a picture), the TurnOver key with R in the NVDA and JAWS styles.
        let key = GlobalCommands.spoken(config.general.style == .voiceOver ? "kb:turnover+shift+l" : "kb:turnover+r")
        Log.info("empty window: nothing readable in the front window of pid \(pid); screen recognition offered (\(key))")
        Speech.speakMessage("Nothing in this window can be read. Press \(key) to recognise the screen.")
    }
}
