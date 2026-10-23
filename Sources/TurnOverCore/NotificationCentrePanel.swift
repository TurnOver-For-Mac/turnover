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

    /// The list of notifications when the panel is open, nil when it is closed.
    public static func list() -> AXUIElement? {
        guard let centre = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { return nil }
        let app = AXUIElementCreateApplication(centre.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.5)
        for window in app.elements(kAXWindowsAttribute) {
            if let found = find(listIdentifier, under: window) { return found }
        }
        return nil
    }

    public static var isOpen: Bool { list() != nil }

    /// Opens the panel and goes in, or closes it if it is open.
    public static func toggle() {
        generation += 1
        if isOpen {
            close()
            return
        }
        let pressed = VoiceOverKeysPlugin.pressMenuExtra("com.apple.menuextra.clock", "Notification Centre")
        guard pressed else { return }
        waitAndEnter(tries: 0, generation: generation)
    }

    /// Closes the panel with the clock, and the review cursor goes back to the keyboard focus.
    static func close() {
        let pressed = VoiceOverKeysPlugin.pressMenuExtra("com.apple.menuextra.clock", "Notification Centre")
        if pressed {
            Log.io("notification centre: closed")
        }
        if ObjectNavigator.shared.reviewElement?.pid == centrePid() {
            ObjectNavigator.shared.toFocus()
        }
    }

    /// Looks for the list every tenth of a second; when it is there, the review cursor lands on the first
    /// notification (or on the empty list), with the panel's name said first.
    private static func waitAndEnter(tries: Int, generation pressGeneration: Int) {
        guard pressGeneration == generation else { return }
        if let list = list() {
            enter(list)
            return
        }
        if tries >= openTries {
            Log.io("notification centre: the panel did not appear within \(openTries) tenths of a second")
            Speech.speakMessage("Notification Centre did not open")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            waitAndEnter(tries: tries + 1, generation: pressGeneration)
        }
    }

    private static func enter(_ list: AXUIElement) {
        let alerts = list.elements(kAXChildrenAttribute).filter { $0.string(kAXSubroleAttribute) == alertSubrole }
        Log.io("notification centre: open, \(alerts.count) notifications")
        Speech.speakMessage(alerts.isEmpty ? "Notification Centre, no notifications" : "Notification Centre")
        ObjectNavigator.shared.moveTo(alerts.first ?? list)
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
