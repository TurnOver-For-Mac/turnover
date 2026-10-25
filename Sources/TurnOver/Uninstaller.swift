// SPDX-License-Identifier: GPL-3.0-or-later
// TurnOver menu, Uninstall TurnOver (6 Oct 2026): a clean removal, so a tester with a muddle of copies,
// login items and half-granted permissions can start again, rather than dragging the app to the Bin and leaving
// the TurnOver Key login item, the settings and the permissions behind.
//
// In order: the login items go and TurnOver Key quits; TurnOver's folders and preferences go to the Bin (the Bin,
// not deleted: anything wanted back can be fished out); VoiceOver comes back on while TurnOver still has the
// permission to turn it on; then the Accessibility, Input Monitoring and Automation permissions are reset for both
// TurnOver and TurnOver Key; the app itself goes to the Bin, and TurnOver quits.
import AppKit
import ServiceManagement
import TurnOverCore

enum Uninstaller {
    /// While true, nothing turns VoiceOver off again (the lead watcher would, with Mail in front).
    static private(set) var running = false

    nonisolated static let bundleIDs = ["com.turnover.reader", "com.turnover.key"]

    static func menuItems() -> [MenuItem] {
        [
            MenuItem("Uninstall completely: removes TurnOver, its settings, logs, login items and permissions; VoiceOver has every app", .action { confirm(keepSettings: false) }),
            // Settings and permissions belong to TurnOver's bundle identifier and signature, not to where the app was,
            // so a copy installed again anywhere (Downloads, Applications) picks them up; its login item is
            // registered again from wherever it is opened ().
            MenuItem("Remove the app only: keeps your settings and permissions, for installing again later", .action { confirm(keepSettings: true) }),
        ]
    }

    /// One keypress removed everything (a code review, 14 Oct 2026): a second list first, as the library's install.
    static func confirm(keepSettings: Bool) {
        DispatchQueue.main.async {
            TurnOverMenu.shared.openList(keepSettings ? "Remove the app only?" : "Uninstall TurnOver completely? Settings, plugins and permissions go too", items: [
                MenuItem("Cancel", .action { Speech.speakMessage("Not removed") }),
                MenuItem(keepSettings ? "Remove the app" : "Uninstall everything", .action { DispatchQueue.main.async { run(keepSettings: keepSettings) } }),
            ])
        }
    }

    static func run(keepSettings: Bool) {
        guard !running else { return }
        running = true
        Log.info("uninstall: starting (\(keepSettings ? "app only; settings and permissions kept" : "everything"))")
        // An Activity left by an earlier build (CoExist's first form) first, while TurnOver still has its files and its
        // permissions, or VoiceOver stays silent in TurnOver's apps for good (a code review on 17 Oct 2026). Then the rest.
        if ActivityFlow.shared.marker.installed {
            Speech.speakMessage("Uninstalling TurnOver. First VoiceOver's settings: VoiceOver Utility opens and closes by itself, about ten seconds.")
            ActivityFlow.shared.set(apps: nil) { text in
                Log.info("uninstall: the Activity: \(text)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { removeEverything(keepSettings: keepSettings) }
            }
            return
        }
        removeEverything(keepSettings: keepSettings)
    }

    private static func removeEverything(keepSettings: Bool) {
        ScreenCurtain.off()
        Speech.speakMessage(keepSettings ? "Removing TurnOver, keeping your settings. VoiceOver will come back on in a moment." : "Uninstalling TurnOver. VoiceOver will come back on in a moment.")
        DispatchQueue.global(qos: .userInitiated).async {
            removeLoginItems()
            removeSteamSwitchFiles()
            let left = keepSettings ? [] : trashFiles()
            let appTrashed = trashApp()
            // TurnOver's own last words: while VoiceOver is on, TurnOver is silent.
            let summary: String
            switch (keepSettings, appTrashed) {
            case (true, true): summary = "TurnOver is in the Bin. Your settings and permissions are kept for when you install it again."
            case (true, false): summary = "The app could not be moved to the Bin; drag it there yourself. Your settings are kept."
            case (false, true): summary = "TurnOver is uninstalled and in the Bin."
            case (false, false): summary = "TurnOver's settings and permissions are removed; the app itself could not be moved to the Bin, so drag it there yourself."
            }
            DispatchQueue.main.async { Speech.speakMessage(summary + (left.isEmpty ? "" : " Some files could not be moved.")) }
            Log.info("uninstall: \(summary) Left behind: \(left)")
            sleep(4)
            DispatchQueue.main.async {
                Watchdog.shared.active = false   // the wait for VoiceOver would trip it, and a second toggle undo the first
                HandOver.turnVoiceOverOn()
                // Last: once reset, TurnOver can no longer turn VoiceOver on.
                if !keepSettings { resetPermissions() }
                NSApp.terminate(nil)
            }
        }
    }

    /// Steam's debugging switch, if Big Picture reading ever put it there: Steam must not keep opening its port
    /// after TurnOver is gone (a code review on 20 Oct 2026). The Steam helper knows where every copy of Steam is.
    nonisolated private static func removeSteamSwitchFiles() {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/steam-speech")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { return }
        let p = Process(); p.executableURL = helper; p.arguments = ["--remove-switch-files"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil { p.waitUntilExit() }
    }

    nonisolated private static func removeLoginItems() {
        for service in [SMAppService.mainApp, SMAppService.loginItem(identifier: "com.turnover.key")]
        where service.status == .enabled || service.status == .requiresApproval {
            do { try service.unregister() } catch { Log.warning("uninstall: login item: \(error)") }
        }
        for helper in NSRunningApplication.runningApplications(withBundleIdentifier: "com.turnover.key") { helper.terminate() }
    }

    /// Settings, reading positions, logs, caches and preferences, to the Bin. Returns what could not be moved.
    nonisolated private static func trashFiles() -> [String] {
        let fm = FileManager.default
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        for id in bundleIDs {
            UserDefaults.standard.removePersistentDomain(forName: id)
        }
        UserDefaults.standard.synchronize()
        var items = [AppPaths.support, AppPaths.pluginBriefs]
        for id in bundleIDs {
            items += [
                library.appendingPathComponent("Caches/\(id)"),
                library.appendingPathComponent("HTTPStorages/\(id)"),
                library.appendingPathComponent("HTTPStorages/\(id).binarycookies"),
                library.appendingPathComponent("Saved Application State/\(id).savedState"),
                library.appendingPathComponent("WebKit/\(id)"),
                library.appendingPathComponent("Preferences/\(id).plist"),
            ]
        }
        var left: [String] = []
        for url in items where fm.fileExists(atPath: url.path) {
            do { try fm.trashItem(at: url, resultingItemURL: nil) } catch { left.append(url.lastPathComponent) }
        }
        return left
    }

    nonisolated private static func trashApp() -> Bool {
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app" else { return false }
        do { try FileManager.default.trashItem(at: app, resultingItemURL: nil); return true }
        catch { Log.warning("uninstall: app: \(error)"); return false }
    }

    /// The entries under Privacy & Security for TurnOver and TurnOver Key. tccutil resets an app's own entries
    /// without an administrator's password.
    nonisolated private static func resetPermissions() {
        for id in bundleIDs {
            for service in ["Accessibility", "ListenEvent", "PostEvent", "AppleEvents"] {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                p.arguments = ["reset", service, id]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try? p.run()
                p.waitUntilExit()
            }
        }
    }
}
