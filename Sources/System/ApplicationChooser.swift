// SPDX-License-Identifier: GPL-3.0-or-later
// The application chooser (VoiceOver's VO-F1-F1; in the Windows style, Option Tab, as Windows+Tab is Task View):
// every application with a window on screen, its windows under it, to switch to. Command Tab leaves out the ones
// that matter most when something is stuck: system prompts with no Dock icon (Screen Recording's "allow" alert,
// a password prompt, a security agent). Screen Recording's alert could not be reached, 6 Oct 2026.
import Foundation
import AppKit
import ApplicationServices

public enum ApplicationChooser {
    public struct Entry { public let pid: pid_t; public let name: String; public let windows: [(title: String, element: AXUIElement?)] }

    /// Apps with windows on screen (any kind of process), then the regular apps with none, in front-to-back order.
    public static func gather() -> [Entry] {
        let own = ProcessInfo.processInfo.processIdentifier
        let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var order: [pid_t] = []
        for w in info {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  let bounds = w[kCGWindowBounds as String] as? [String: CGFloat], (bounds["Width"] ?? 0) > 40, (bounds["Height"] ?? 0) > 40,
                  (w[kCGWindowAlpha as String] as? CGFloat ?? 1) > 0 else { continue }
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            // The menu bar, the Dock and wallpaper are above or below the ordinary layers; alerts sit at 0 to a few hundred.
            guard layer >= 0, layer < 1000, !order.contains(pid) else { continue }
            if let app = NSRunningApplication(processIdentifier: pid), ["com.apple.dock", "com.apple.WindowManager", "com.apple.controlcenter", "com.apple.Spotlight", "com.apple.campo", "com.apple.notificationcenterui"].contains(app.bundleIdentifier ?? "") { continue }
            order.append(pid)
        }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !order.contains(app.processIdentifier) && app.processIdentifier != own {
            order.append(app.processIdentifier)
        }
        // The system prompts TurnOver knows are open come first, whatever their window layer: the keychain's
        // password prompt was not in the list at build 18's publish (14 Oct 2026).
        let prompts = SystemPrompts.shared.waiting
        order.removeAll { pid in prompts.contains { $0.pid == pid } }
        let promptEntries = prompts.map { p in Entry(pid: p.pid, name: String(localized: "system dialog", comment: "A role: a macOS system dialog"), windows: [(p.text, p.window)]) }
        return promptEntries + order.compactMap { pid in
            guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
            let name = app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)"
            let ax = AXUIElementCreateApplication(pid)
            let windows = ax.elements(kAXWindowsAttribute).map { w -> (String, AXUIElement?) in
                let t = (w.string(kAXTitleAttribute) ?? "").trimmingCharacters(in: .whitespaces)
                let dialog = w.string(kAXSubroleAttribute) == "AXDialog" || w.string(kAXSubroleAttribute) == "AXSystemDialog"
                return (t.isEmpty ? (dialog ? String(localized: "untitled dialog", comment: "A dialog with no title") : String(localized: "untitled window", comment: "A window with no title")) : t, w)
            }
            return Entry(pid: pid, name: name, windows: windows)
        }
    }

    public static func open() {
        let entries = gather()
        let items: [MenuItem] = entries.map { e in
            let count = e.windows.count
            let label = "\(e.name), \(count == 0 ? String(localized: "no windows", comment: "An app with no windows") : count == 1 ? e.windows[0].title : String(localized: "\(String(count)) windows", comment: "How many windows an app has"))"
            if count > 1 {
                return MenuItem(verbatim: label, .submenu {
                    e.windows.map { w in MenuItem(verbatim: w.title, .action { switchTo(e, window: w.element) }) }
                })
            }
            return MenuItem(verbatim: label, .action { switchTo(e, window: e.windows.first?.element) })
        }
        Log.io("application chooser: \(entries.count) applications")
        TurnOverMenu.shared.openList("Application Chooser", items: items)   // named as VoiceOver names it (15 Oct 2026)
    }

    /// Bring the app and the window forward and give it the keyboard. A process with no Dock icon (a system alert)
    /// is not "activated" by AppKit; it is made frontmost through accessibility, and its window raised and focused.
    static func switchTo(_ e: Entry, window: AXUIElement?) {
        Log.io("application chooser: to \(e.name)")
        let app = NSRunningApplication(processIdentifier: e.pid)
        app?.activate(options: [.activateAllWindows])
        let ax = AXUIElementCreateApplication(e.pid)
        _ = ax.set(kAXFrontmostAttribute, kCFBooleanTrue)
        if let w = window {
            _ = AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            _ = w.set(kAXMainAttribute, kCFBooleanTrue)
            _ = w.set(kAXFocusedAttribute, kCFBooleanTrue)
        }
        AXHandler.shared.observe(e.pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if let w = window, let focus = w.element(kAXFocusedUIElementAttribute) ?? ax.element(kAXFocusedUIElementAttribute) {
                AXHandler.shared.focusChanged(focus, pid: e.pid)
            } else if let w = window {
                AXHandler.shared.focusChanged(w, pid: e.pid)
            } else {
                AXHandler.shared.refocus(pid: e.pid)
            }
        }
    }
}
