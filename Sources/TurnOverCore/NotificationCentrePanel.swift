// SPDX-License-Identifier: GPL-3.0-or-later
// Notification Centre's panel, as VoiceOver's VO-O has it: the clock in the menu bar is pressed, the review cursor
// goes to the first notification, and the key again closes it.
//
// Measured 23 Oct 2026 on macOS 27.2 with a probe: the panel is not a window of its own. Notification Centre keeps one
// full-screen window at all times for its banners; when the panel opens, a scroll area appears in it holding a group
// with the identifier AXNotificationListItems and one AXNotificationCenterAlert group per notification (title and
// body texts; actions such as Show Details and Close). Nothing takes the keyboard focus: the front application and
// its focused element stay as they were, so TurnOver has to move its own cursor in. Escape closes the panel within a
// tenth of a second even with the focus elsewhere, and so does pressing the clock again. The press itself answered
// in six milliseconds.
import Foundation
import AppKit
import ApplicationServices
import TurnOverAX

public enum NotificationCentrePanel {
    static let listIdentifier = "AXNotificationListItems"
    static let alertSubrole = "AXNotificationCenterAlert"
    static let bundle = "com.apple.notificationcenterui"
    /// How long the panel is given to appear after the press, in tenths of a second.
    static let openTries = 20
    /// Counts presses of the key: a landing scheduled for an earlier press is dropped.
    private static var generation = 0
    /// True from the press until the review cursor has landed or the wait gave up: a second press meanwhile is a
    /// close, not a second opening.
    private static var opening = false

    /// The list of notifications: the group is in the tree whether the panel shows or not (measured 23 Oct 2026,
    /// after the first build took its presence for the panel being open and closed it instead).
    public static func list() -> AXUIElement? {
        guard let centre = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { return nil }
        let app = AXUIElementCreateApplication(centre.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.5)
        for window in app.elements(kAXWindowsAttribute) {
            if let found = find(listIdentifier, under: window) { return found }
        }
        return nil
    }

    /// Set by the foreground transitions and nothing else (so a panel already open when TurnOver starts reads as
    /// closed until the first transition; the first press then closes it and says press again): the panel opening
    /// posts a focused-window change from
    /// Notification Centre about 85 ms after the press, and closing it (Escape, the clock, a click elsewhere) brings
    /// the application's window back as the foreground (the log, 23 Oct 2026). The handler's own focus-window field
    /// is not used for this: a focus change in the application beneath the panel rewrites that field while the
    /// panel stays up (a second reviewer, 23 Oct 2026).
    private static var open = false
    /// The Notification Centre process the flag was set for: a relaunched Notification Centre starts closed.
    private static var openPid: pid_t = 0

    public static var isOpen: Bool {
        guard let pid = centrePid() else { return false }
        guard pid == openPid else { return false }
        return open
    }

    /// When the reader stops (deactivation): what happens to the panel meanwhile is not seen, so nothing is assumed.
    public static func reset() {
        open = false
        openPid = 0
        opening = false
        generation += 1
    }

    /// Called from every foreground window change, before anything is said about it.
    static func noteForeground(_ window: AXUIElement) {
        guard let pid = centrePid() else { return }
        let isPanel = window.pid == pid
        if isPanel != open {
            Log.io("notification centre: panel \(isPanel ? "open" : "closed") (foreground window)")
        }
        open = isPanel
        openPid = pid
        if !isPanel, opening {
            // Closed (Escape, a click, the clock) before the cursor got in, or it was open before TurnOver started and
            // the press closed it: said, so the press is not silent; the next press opens.
            Log.io("notification centre: closed before it was entered")
            opening = false
            generation += 1
            Speech.speakMessage(String(localized: "Notification Centre closed", comment: "Spoken message"))
        }
        cursorBackIfStranded()
    }

    /// Opens the panel and goes in, or closes it if it is open.
    public static func toggle() {
        generation += 1
        if opening || isOpen {
            opening = false
            close()
            return
        }
        // Observed again before the press: a relaunched Notification Centre is a new process, and the foreground
        // change that marks the panel open comes through its observer.
        if let pid = centrePid() {
            AXHandler.shared.notificationCentrePid = pid   // the handler's copy is taken once; a relaunch changes it
            AXHandler.shared.observe(pid)
        }
        let pressed = VoiceOverKeysPlugin.pressMenuExtra("com.apple.menuextra.clock", String(localized: "Notification Centre", comment: "The Mac's Notification Centre"))
        guard pressed else { return }
        opening = true
        let activePid = AXHandler.shared.activePid
        waitAndEnter(tries: 0, generation: generation, activePid: activePid)
    }

    /// Closes the panel with the clock, and the review cursor goes back to the keyboard focus.
    static func close() {
        let pressed = VoiceOverKeysPlugin.pressMenuExtra("com.apple.menuextra.clock", String(localized: "Notification Centre", comment: "The Mac's Notification Centre"))
        if pressed {
            Log.io("notification centre: closed by the key")
        }
        if ObjectNavigator.shared.reviewElement?.pid == centrePid() {
            ObjectNavigator.shared.toFocus()
        }
    }

    /// Looks for the list every tenth of a second; when it is there, the review cursor lands on the first
    /// notification (or on the empty list), with the panel's name said first. The wait is dropped when the key was
    /// pressed again meanwhile, or when the user has moved to another application: the panel stays open, but the
    /// cursor is not pulled away from where they went.
    private static func waitAndEnter(tries: Int, generation pressGeneration: Int, activePid: pid_t) {
        guard pressGeneration == generation else { return }
        if AXHandler.shared.activePid != activePid {
            Log.io("notification centre: the focus moved to another application while the panel opened; not entered")
            opening = false
            return
        }
        if isOpen, let list = list() {
            opening = false
            enter(list)
            return
        }
        if tries >= openTries {
            // Either the panel never came, or it was open before TurnOver started (no transition was seen, so the
            // flag said closed) and this press closed it: the next press opens it either way.
            opening = false
            Log.io("notification centre: no foreground change within \(openTries) tenths of a second; press again")
            Speech.speakMessage(String(localized: "Notification Centre did not open; press again", comment: "Spoken message"))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            waitAndEnter(tries: tries + 1, generation: pressGeneration, activePid: activePid)
        }
    }

    private static func enter(_ list: AXUIElement) {
        let alerts = list.elements(kAXChildrenAttribute).filter { $0.string(kAXSubroleAttribute) == alertSubrole }
        Log.io("notification centre: open, \(alerts.count) notifications")
        Speech.speakMessage(alerts.isEmpty ? String(localized: "Notification Centre, no notifications", comment: "Spoken message") : String(localized: "Notification Centre", comment: "Spoken message"))
        ObjectNavigator.shared.moveTo(alerts.first ?? list)
    }

    /// Called when the foreground window changes and on every layout change in Notification Centre, whether or not
    /// banners are read: if Escape (or a click elsewhere) closed the panel while the review cursor was inside, the
    /// cursor goes back to the keyboard focus, as it does when the key closes the panel. The first check is the
    /// cursor's process, so the ordinary banner traffic costs nothing here.
    public static func cursorBackIfStranded() {
        guard let pid = centrePid() else { return }
        guard ObjectNavigator.shared.reviewElement?.pid == pid else { return }
        guard !isOpen else { return }
        Log.io("notification centre: closed from outside; the cursor goes back to the focus")
        ObjectNavigator.shared.toFocus()
    }

    /// Whether this foreground change is the panel opening for the key: the window is read as a dialog otherwise
    /// (all its notifications in one breath), and the key's own landing says the panel and the first notification.
    static func isPanelOpeningForKey(_ window: AXUIElement) -> Bool {
        guard opening else { return false }
        guard let pid = centrePid() else { return false }
        return window.pid == pid
    }

    static func centrePid() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.processIdentifier
    }

    /// Depth first, at most 400 elements and eight levels: the list sits four levels under the window.
    private static func find(_ identifier: String, under root: AXUIElement) -> AXUIElement? {
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while let (element, depth) = stack.popLast() {
            visited += 1
            if visited > 400 { return nil }
            if element.string(kAXIdentifierAttribute) == identifier { return element }
            if depth >= 8 { continue }
            for child in element.elements(kAXChildrenAttribute) {
                stack.append((child, depth + 1))
            }
        }
        return nil
    }
}
