// SPDX-License-Identifier: GPL-3.0-or-later
// Switching between the published TurnOver and your own developer build (issue 248, 7 Nov 2026, Oliver: "an option in
// TurnOver to switch between developer mode and ... the regular flavour"). A contributor's build installs beside the
// published one as TurnOver Developer (build.sh); each has its own permissions, granted once, and both read the same
// settings folder. The TurnOver menu offers the other copy when it is installed.
//
// Never two readers at once: this copy says where it is going, records the other as the one in use (so Command
// Control Period follows it, ActiveReader), leaves a small launcher to start the other a moment later, and quits the
// ordinary way, VoiceOver covering the moment between, as when TurnOver is turned off.
import Foundation
import AppKit
import TurnOverControl

public enum DeveloperSwitch {
    /// This copy's identifier, and the other copy's location when it is installed.
    static var other: (id: String, url: URL)? {
        guard let me = Bundle.main.bundleIdentifier, [ActiveReader.published, ActiveReader.developer].contains(me) else { return nil }
        let id = ActiveReader.other(than: me)
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return (id, url)
    }

    /// The TurnOver menu's item, when there is another copy to switch to.
    public static var menuItem: MenuItem? {
        guard let other else { return nil }
        let toDeveloper = other.id == ActiveReader.developer
        return MenuItem(toDeveloper ? "Switch to your developer build" : "Switch to the published TurnOver",
                        .action { switchTo(other.id, at: other.url) },
                        hint: toDeveloper ? "TurnOver Developer, the copy you built, takes over. Switch back the same way at any time"
                                          : "The TurnOver everyone has takes over, with its updates. Your developer build stays installed")
    }

    static func switchTo(_ id: String, at url: URL) {
        let toDeveloper = id == ActiveReader.developer
        Speech.speakMessage(toDeveloper
            ? String(localized: "Switching to your developer build.", comment: "TurnOver is handing over to the contributor's own build")
            : String(localized: "Switching to the published TurnOver.", comment: "TurnOver Developer is handing over to the published TurnOver"))
        Log.info("switch: to \(id) at \(url.path)")
        // The launcher outlives this copy: it waits for it to go, then opens the other. (A child process is left
        // running when its parent quits.)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 2; /usr/bin/open -g \"$1\"", "switch", url.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            Log.error("switch: could not start the launcher: \(error.localizedDescription)")
            Speech.speakMessage(String(localized: "Could not switch: \(error.localizedDescription)", comment: "Switching between TurnOver copies failed"))
            return
        }
        ActiveReader.record(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { (TurnOverMenu.shared.quit ?? { NSApp.terminate(nil) })() }
    }
}
