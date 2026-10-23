// SPDX-License-Identifier: GPL-3.0-or-later
// The accessibility API handler (NVDA: IAccessibleHandler / UIAHandler for
// Windows; here the one macOS API). It watches applications through
// AXObservers, keeps the focus and the foreground up to date, and turns each
// notification into an event for an object. Nothing here speaks; the objects
// and modules decide that.
//
// Measured on Word (30 Sep 2026): AXSelectedTextChanged on every caret move,
// AXFocusedUIElementChanged when the caret crosses a page, AXValueChanged noise
// from AutoSave labels and scroll bars with every move. The focus object is
// the only one whose value changes are spoken, so the noise costs an object
// construction and nothing else.
import Foundation
import AppKit
import ApplicationServices
import TurnOverAX

// Banners from Notification Centre, read as they appear (Presentation, Report notifications).
extension AXHandler {
    // MARK: Notifications from other apps


    func announceNotificationsSoon() {
        guard config.presentation.reportNotifications else { return }
        notificationCheck?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.announceNotifications() }
        notificationCheck = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    /// Banners already up when TurnOver starts are not news: remember them without reading them.
    func seedNotifications() { announceNotifications(speak: false) }

    func announceNotifications(speak wanted: Bool = true) {
        guard !wanted || activePid != notificationCentrePid else { return }   // the user is in Notification Centre itself
        // The open panel lists the history as the same alert groups: remembered, not read as news (23 Oct 2026).
        let speak = wanted && !NotificationCentrePanel.isOpen
        let app = AXUIElementCreateApplication(notificationCentrePid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var alerts: [AXUIElement] = []
        for w in app.elements(kAXWindowsAttribute) {
            var stack = [w], n = 0
            while let e = stack.popLast(), n < 300 {
                n += 1
                if e.string(kAXSubroleAttribute) == "AXNotificationCenterAlert" { alerts.append(e); continue }
                stack.append(contentsOf: e.elements(kAXChildrenAttribute))
            }
        }
        for a in alerts {
            let id = a.string(kAXIdentifierAttribute) ?? (a.string(kAXDescriptionAttribute) ?? "")
            guard !id.isEmpty, !seenNotifications.contains(id) else { continue }
            seenNotifications.append(id)
            if seenNotifications.count > 100 { seenNotifications.removeFirst(50) }
            var parts: [String] = []
            for k in a.elements(kAXChildrenAttribute) where k.role == "AXStaticText" {
                if let v = k.string(kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { parts.append(v) }
            }
            guard speak else { continue }
            let text = parts.isEmpty ? (a.string(kAXDescriptionAttribute) ?? "") : parts.joined(separator: ", ")
            guard !text.isEmpty else { continue }
            Log.io("notification banner: \(text.count) characters")   // never its words: two-factor codes come this way
            NotificationHistory.add(text)
            VoiceOverSounds.play("Announcement.aiff")
            Speech.asPrivate { Speech.speakNews("notification, " + text) }
        }
    }
}
