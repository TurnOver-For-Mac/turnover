// SPDX-License-Identifier: GPL-3.0-or-later
// Shortcuts (18 Oct 2026, the Apple apps sweep). The window opens with the keyboard in "Describe a shortcut" (a text
// area: Tab types a tab there), and Control-Tab goes only round the toolbar: the sidebar's folders and the grid of
// shortcuts ("library.grid", each a run button) are never reached from the keyboard (driver). TurnOver reads the
// window's panes as a document: typing in the describe box stays typing (focus mode); Escape goes to reading, where
// Down goes through the folders and every shortcut, H and Tab as on a page, Return runs the shortcut it's on (as its
// button does).
import Foundation
import ApplicationServices

final class ShortcutsAppModule: AppModule {
    static let bundleID = "com.apple.shortcuts"

    required init(pid: pid_t, bundleIdentifier: String, appName: String) {
        super.init(pid: pid, bundleIdentifier: bundleIdentifier, appName: appName)
        WebBuffer.decorativeImageApps.insert(Self.bundleID)
        // Escape from the describe box: reading from the top (the folders, then the shortcuts), not from the box, the
        // page's last line, where every Down said "bottom" (driver, 18 Oct 2026).
        script("shortcuts_read", String(localized: "From the describe box to reading the folders and shortcuts, from the top", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:escape"], category: "Shortcuts") { [weak self] g in
            guard let self, let doc = API.focusTreeInterceptor, doc.webArea.pid == self.pid, doc.passThrough else { g.send(); return }
            doc.setPassThrough(false, announce: true)
            doc.position = 0
            doc.speakUnit(.line)
        }.isAvailable = { [weak self] in
            guard let self, let doc = API.focusTreeInterceptor else { return false }
            return doc.webArea.pid == self.pid && doc.passThrough && API.focusObject?.axRole == "AXTextArea"
        }
    }

    override func browseRoot(for element: AXUIElement, ancestors: [TurnOverObject]) -> AXUIElement? {
        // The window's split group: the sidebar, the grid, the describe box.
        if element.role == "AXSplitGroup", element.element(kAXParentAttribute)?.role == "AXWindow" { return element }
        return ancestors.first { $0.element.role == "AXSplitGroup" && $0.element.element(kAXParentAttribute)?.role == "AXWindow" }?.element
    }
}
