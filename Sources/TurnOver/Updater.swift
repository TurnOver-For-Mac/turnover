// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import ApplicationServices
import TurnOverCore
import Sparkle

/// Updates, through Sparkle 2: once a day TurnOver reads its update feed (SUFeedURL in Info.plist), and when there is
/// a newer build it says so and shows Sparkle's window, an ordinary Mac window in TurnOver's own process, which
/// VoiceOver reads (TurnOver never leads in itself). Install downloads the update, checks its signature against
/// SUPublicEDKey, replaces the app and relaunches it. The same Developer ID signature means macOS keeps the
/// Accessibility and Input Monitoring permissions. Each release is signed, and the feed written, by the maintainer's private release tooling.
final class Updater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = Updater()
    private var controller: SPUStandardUpdaterController?
    private var startError: String?

    func start() {
        guard controller == nil else { return }
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String else {
            Log.info("updates: no feed in \(Bundle.main.bundlePath)/Contents/Info.plist"); return
        }
        let c = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        do {
            try c.updater.start()
            controller = c
            Log.info("updates: \(feed), checking \(c.updater.automaticallyChecksForUpdates ? "daily" : "only when asked"), installing \(c.updater.automaticallyDownloadsUpdates ? "by itself" : "when the user says")")
        } catch {
            startError = error.localizedDescription
            Log.error("updates: Sparkle did not start: \(error)")
        }
    }

    /// TurnOver menu, Updates: check now, the daily check, automatic installing, and an update waiting to install.
    func menuItems() -> [MenuItem] {
        guard let updater = controller?.updater else {
            return [MenuItem("Check for updates", .action { self.checkNow() }), MenuItem("What's new (opens the list of changes in Safari)", .action {
                if let url = URL(string: "https://doll-eye.github.io/turnover-updates/changes.html") { NSWorkspace.shared.open(url) }
            })]
        }
        var items: [MenuItem] = []
        if let install = pendingInstall {
            items.append(MenuItem("Install the downloaded update now (TurnOver restarts)", .action {
                Speech.speakMessage(String(localized: "installing the update; TurnOver will be back in a moment", comment: "Spoken message"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { install() }
            }))
        }
        items.append(MenuItem("Check for updates", .action { self.checkNow() }))
        // For anyone wondering whether their report was dealt with; not pushed at anyone (5 Oct 2026).
        items.append(MenuItem("What's new (opens the list of changes in Safari)", .action {
            if let url = URL(string: "https://doll-eye.github.io/turnover-updates/changes.html") { NSWorkspace.shared.open(url) }
        }))
        items.append(MenuItem("Check for updates every day", .toggle(get: { updater.automaticallyChecksForUpdates }, set: { updater.automaticallyChecksForUpdates = $0 })))
        items.append(MenuItem("Download and install updates automatically", .toggle(get: { updater.automaticallyDownloadsUpdates }, set: {
            updater.automaticallyDownloadsUpdates = $0
            if $0 { updater.automaticallyChecksForUpdates = true }
        })))
        return items
    }

    /// An update downloaded by itself waits for TurnOver to quit; this installs it now.
    private var pendingInstall: (() -> Void)?

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        pendingInstall = immediateInstallHandler
        Log.info("updates: \(item.displayVersionString) (build \(item.versionString)) downloaded; installs on quit")
        Speech.speakMessage(String(localized: "A TurnOver update has downloaded. It installs when TurnOver next quits, or now from the TurnOver menu, About and updates, Updates.", comment: "Spoken message"))
        return true
    }

    /// TurnOver menu, Check for updates.
    /// TurnOver is a menu-bar app: Sparkle's window opens behind the app in front, where nobody finds it ("checking",
    /// then nothing, 5 Oct 2026). Bring TurnOver to the front by accessibility (macOS no longer lets an app activate
    /// itself over another), and its window with it; VoiceOver then has it, as TurnOver never leads in itself.
    static func bringWindowForward() {
        // (An accessibility call into our own process waits on our own main thread: it only timed out, 8 Oct 2026.)
        NSRunningApplication.current.activate()
        for w in NSApp.windows where w.isVisible && w.level == .normal || w.isVisible && w.className.contains("SU") {
            w.orderFrontRegardless(); w.makeKey()
        }
    }

    private var userCheck = false

    func checkNow() {
        userCheck = true
        guard let controller else {
            Speech.speakMessage(startError.map { String(localized: "updates could not start: \(String(describing: $0))", comment: "Updates failed: %@ is why") } ?? String(localized: "updates are not set up in this build", comment: "Spoken message"))
            return
        }
        Speech.speakMessage(String(localized: "checking for updates", comment: "Spoken message"))
        controller.checkForUpdates(nil)
    }

    // TurnOver is a menu-bar app: a scheduled check's window would open behind the front app, unseen. Say it, and
    // bring the window forward.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        Log.info("updates: \(update.displayVersionString) (build \(update.versionString)) available")
        userCheck = false
        Speech.speakMessage(String(localized: "A TurnOver update is available: build \(update.versionString). The update window is open.", comment: "An update found: %@ is its build"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Self.bringWindowForward() }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Log.warning("updates: \(error.localizedDescription)")
        // Asked for from the menu: say the answer ("You're up to date!"), and show Sparkle's note of it.
        if userCheck {
            userCheck = false
            Speech.speakMessage(error.localizedDescription)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Self.bringWindowForward() }
        }
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        Log.info("updates: installed; relaunching")
    }
}
