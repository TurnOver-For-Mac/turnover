// SPDX-License-Identifier: GPL-3.0-or-later
// Force quit (the Mac's Command Option Escape, Windows' Task Manager on Control Shift Escape), spoken: a chooser of
// the running applications, then a confirmation before anything is killed. The Mac's own Force Quit window belongs
// to loginwindow, which TurnOver does not read, so with VoiceOver off the key opened a silent window (// 9 Oct 2026). Only NSRunningApplication is used here: an application that has stopped answering must not be
// asked anything over accessibility, or TurnOver would stop too.
import Foundation
import AppKit

public enum ForceQuit {
    public static func open() {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier && !$0.isTerminated }
        let rows = labels(apps.map { (name: $0.localizedName ?? $0.bundleIdentifier ?? "application", isFront: $0.processIdentifier == front) })
        let items = zip(apps, rows).sorted { a, b in a.0.processIdentifier == front ? true : b.0.processIdentifier == front ? false : a.1.lowercased() < b.1.lowercased() }
            .map { app, label in MenuItem(verbatim: label, .action { confirm(app) }) }
        TurnOverMenu.shared.openChooser("Force quit", items: items)
    }

    /// Pure: the front application is marked and listed first.
    public static func labels(_ apps: [(name: String, isFront: Bool)]) -> [String] {
        apps.map { $0.isFront ? String(localized: "\($0.name), in front", comment: "The app in front, in the force quit list") : $0.name }
    }

    private static func confirm(_ app: NSRunningApplication) {
        let name = app.localizedName ?? String(localized: "the application", comment: "An application with no name")
        DispatchQueue.main.async {
            TurnOverMenu.shared.openChooser("Force quit \(name)? Unsaved work is lost", items: [
                MenuItem("Force quit \(name)", .action {
                    let ok = app.forceTerminate()
                    Log.info("force quit: \(name) (pid \(app.processIdentifier)) \(ok ? "killed" : "could not be killed")")
                    Speech.speakMessage(ok ? String(localized: "\(name) force quit", comment: "An app force quit: its name") : String(localized: "Could not force quit \(name)", comment: "An app not force quit: its name"))
                }),
                MenuItem("Quit \(name) normally", .action {
                    _ = app.terminate()
                    Speech.speakMessage(String(localized: "Asked \(name) to quit", comment: "An app asked to quit: its name"))
                }),
                MenuItem("Cancel", .action {}),
            ])
        }
    }
}
