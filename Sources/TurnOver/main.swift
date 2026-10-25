// SPDX-License-Identifier: GPL-3.0-or-later
// TurnOver — the reader. An LSUIElement app: no Dock icon, no window.
//
// Nothing the app needs may hang off a window (Muteny's lesson): everything is
// wired in applicationDidFinishLaunching. Permissions are asked for at launch,
// while VoiceOver can still read the dialogs; TurnOver waits until it is trusted.
import AppKit
import ServiceManagement
import ApplicationServices
import IOKit.hid
import TurnOverCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    fileprivate(set) var app: TurnOverApp?
    private var trustTimer: Timer?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // An Edit menu, though TurnOver shows no menu bar of its own: without one, Command V does nothing in its text
        // fields (7 Oct 2026). Key equivalents reach a field through it.
        let main = NSMenu()
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NewToTry.noteLaunch()   // before the welcome marks this Mac as welcomed
        Log.open()
        endStuckCopy()
        handleTermination()
        startKeyHelper()
        try? FileManager.default.removeItem(at: AppPaths.file("restarting"))   // a restart's flag, used or not
        Log.info("macOS \(ProcessInfo.processInfo.operatingSystemVersionString), bundle \(Bundle.main.bundleIdentifier ?? "none"), VoiceOver \(NSWorkspace.shared.isVoiceOverEnabled ? "on" : "off")")
        // The beta leaves the top row alone: put it back to the Mac's own setting (an earlier TurnOver may have left it
        // switched to F1 to F12).
        // The function keys are the Mac's own, always: TurnOver never changes them (10 Oct 2026). Earlier
        // builds switched the top row with the reader and put it back wrongly (a tester, 9 Oct 2026).
        welcomeOnFirstRun()
        // Opened from Finder or Spotlight, TurnOver comes to the front with no window: VoiceOver said "TurnOver has no
        // windows", and Command Tab was needed to get back (a tester, 10 Oct 2026). A moment after launch, with no
        // window of its own showing (the welcome, the key and permission alerts do show), it steps back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard NSApp.isActive, !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeKey }) else { return }
            Log.info("launch: in front with no window of its own; handing the front back")
            NSApp.hide(nil)
        }
        // Updates start at once, before (and whatever happens with) the permissions: an update may be the fix.
        Updater.shared.start()
        // Ask macOS (its "would like to control this Mac" alert) only when TurnOver is not already allowed.
        let trusted = AXIsProcessTrusted() || AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary)   // the SDK global is mutable state to Swift 6
        Log.info("Accessibility trusted: \(trusted)")
        if !InputAccess.granted { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }   // macOS asks only if it never has
        if trusted { startReader() } else {
            Log.info("waiting for the Accessibility grant")
            trustTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] t in
                if AXIsProcessTrusted() { t.invalidate(); Log.info("Accessibility granted"); MainActor.assumeIsolated { self?.startReader() } }
            }
        }
    }

    /// Started by the watchdog after a hang ("--after-hang <pid>"): the stuck TurnOver is ended here, by its pid and by
    /// any other copy with this bundle identifier, so there is never more than one (20 Oct 2026).
    private func endStuckCopy() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--after-hang") else { return }
        var pids = Set<pid_t>()
        if args.indices.contains(i + 1), let p = pid_t(args[i + 1]) { pids.insert(p) }
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "") { pids.insert(other.processIdentifier) }
        pids.remove(getpid())
        for p in pids where kill(p, 0) == 0 {
            kill(p, SIGKILL)
            Log.error("start: the TurnOver that hung (pid \(p)) ended; this one takes over")
        }
    }

    /// The first time TurnOver runs (or the first time after 1.0): short pages, each with a heading, Next and Back, so
    /// it can be taken in a piece at a time (12 Oct 2026: "one long list"). Ordinary alerts, read by VoiceOver, since
    /// TurnOver starts reading only once they close.
    private func welcomeOnFirstRun() {
        let key = "welcomed-\(Edition.version)"
        let versionWelcomed = UserDefaults.standard.bool(forKey: key)
        // Nothing new: no version welcome due, and this build's pages already seen.
        guard !versionWelcomed || NewToTry.pagesDue else { return }
        // VoiceOver on for the pages, or nobody reads them (a code review, 17 Oct 2026; again on 24 Oct, when CoExist
        // went). TurnOver's own launch hand-over turns it off after, by the swap setting.
        // VoiceOver's flag can stay on with VoiceOver gone (quit by script, or crashed): then it is started, since the
        // toggle would turn the flag off (the test machine, 24 Oct 2026: the welcome open, and nobody speaking).
        if !HandOver.voiceOverReading {
            if NSWorkspace.shared.isVoiceOverEnabled {
                Log.info("welcome: VoiceOver's flag is on but it isn't running; starting it first")
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Library/CoreServices/VoiceOver.app"), configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
            } else {
                Log.info("welcome: VoiceOver is off; turning it on first")
                HandOver.turnVoiceOverOn()
            }
        }
        // macOS 27 renamed Accessibility in Privacy and Security to Device Control and Data Access.
        let accessName = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? "Device Control and Data Access" : "Accessibility"
        let updated = UserDefaults.standard.bool(forKey: "welcomed-1.0") || versionWelcomed
        // One page for the keys when the version changes (it was four, of nineteen: "a bit much").
        let keysPages: [(String, String)] = [
            ("Keys in \(Edition.version)",
             "TurnOver is a full screen reader now: while it is on, it reads everything and VoiceOver is off. Command Control Period starts it and quits it.\n\nThe keys are VoiceOver's, NVDA's or JAWS's: Command Control Comma, then K, changes the style. Command Control M opens the TurnOver menu; Command Control Comma, then S, the Settings window."),
        ]
        let firstRunPages: [(String, String)] = [
            ("Welcome to TurnOver \(Edition.version)",
             "TurnOver is a screen reader for the Mac. It reads every app, with its own voice and the keys you already know. These few pages explain the start. Next and Back move between them."),
            ("TurnOver takes over",
             "While TurnOver is on, it reads everything and VoiceOver is off. TurnOver turns VoiceOver off as it starts and back on as it quits, so you are never without speech. To change that, Settings, Screen reader behaviour."),
            ("Two permissions",
             "Next, TurnOver needs two permissions, \(accessName) and Input Monitoring. macOS asks for the first. For the second, if no question appears, TurnOver shows you where to turn it on. Both are in System Settings, Privacy and Security."),
            ("Keys",
             "Choose the keys you know: VoiceOver's, NVDA's or JAWS's. Command Control Comma, then K, changes the style; the VO keys do what they do in VoiceOver. Command Control M opens the TurnOver menu. Every setting is in the Settings window: Command Control Comma, then S. To bring your VoiceOver voice and speed with you: Command Control Comma, then V."),
            ("Starting, quitting and help",
             "Command Control Period starts TurnOver and quits it, from anywhere. If TurnOver ever stops responding, VoiceOver comes on within a few seconds and TurnOver starts again. Command Control Comma, then H, opens the guides. To report a problem, use Send feedback in the TurnOver menu."),
        ]
        // An update: the version's pages (keys that moved, once per version), then this build's new things and what
        // to test. A first install: the first-run pages, and this build's are marked seen.
        var pages: [(String, String)]
        let build = NewToTry.latest?.build ?? 0
        if !updated {
            pages = firstRunPages
        } else {
            pages = versionWelcomed ? [] : keysPages
            pages += NewToTry.pagesDue || !versionWelcomed ? NewToTry.summaryPages() : []
            pages.insert(("Welcome to TurnOver \(Edition.version), build \(build)",
                          "A few short pages: what's new and what to test. Next and Back move; Skip closes them. The details are in the TurnOver menu (Command Control Comma, then M), under What to test in build \(build)."), at: 0)
        }
        NSApp.activate(ignoringOtherApps: true)
        showPages(pages)
        UserDefaults.standard.set(true, forKey: key)
        NewToTry.markSeen()
    }

    /// Pages as ordinary alerts, so VoiceOver (still running) reads each: a heading and "n of m", then Next (Return),
    /// Back and Skip; the last has Done, Back and Read the guide (12 Oct 2026).
    func showPages(_ pages: [(String, String)]) {
        guard !pages.isEmpty else { return }
        var i = 0
        while true {
            let alert = NSAlert()
            alert.messageText = pages[i].0 + " (\(i + 1) of \(pages.count))"
            alert.informativeText = pages[i].1
            let last = i == pages.count - 1
            alert.addButton(withTitle: last ? "Done" : "Next")
            alert.addButton(withTitle: i > 0 ? "Back" : (last ? "Read the guide" : "Skip"))
            if i > 0 { alert.addButton(withTitle: last ? "Read the guide" : "Skip") }
            let r = alert.runModal()
            if r == .alertFirstButtonReturn { if last { break }; i += 1; continue }
            if r == .alertSecondButtonReturn, i > 0 { i -= 1; continue }
            let pressed = r == .alertSecondButtonReturn ? (i > 0 ? "Back" : (last ? "Read the guide" : "Skip")) : (last ? "Read the guide" : "Skip")
            if pressed == "Read the guide", let guide = Bundle.main.url(forResource: Edition.guideName, withExtension: "txt") { NSWorkspace.shared.open(guide) }
            break
        }
    }

    private func startReader() {
        do {
            let a = try TurnOverApp()
            app = a
            a.start()
        } catch {
            Log.error("could not start: \(error)")
            // Said, not only logged: VoiceOver reads the alert (code review, 16 Oct 2026; before, TurnOver "did nothing").
            let a = NSAlert(); a.messageText = "TurnOver could not start"; a.informativeText = "\(error)\n\nVoiceOver is still on. Check for an update from the TurnOver menu next time, or send feedback."
            a.addButton(withTitle: "Quit"); a.runModal(); NSApp.terminate(nil)
        }
    }

    /// Opened again from Applications or the Dock while running: say so, and open the menu.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Only while TurnOver is reading: opened under VoiceOver, the menu sat open unseen and would have taken every
        // key on the next switch to Mail (4 Oct 2026).
        // Opened again from Applications: say so and offer the menu, whichever reader has the app (the code review, 17 Oct 2026).
        VoiceOverSpeak.say("TurnOver is running")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { MenuAnywhere.shared.layer() }
        return false
    }

    /// A deliberate quit (the menu, the Dock, Command Q) is told to the Key helper, so it doesn't start TurnOver again
    /// as it would after a crash; a logout, restart or shutdown isn't (the next login starts TurnOver as usual).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reason = NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue ?? 0
        let systemReasons: [OSType] = [OSType(kAELogOut), OSType(kAEReallyLogOut), OSType(kAEShowRestartDialog), OSType(kAEShowShutdownDialog), OSType(kAERestart), OSType(kAEShutDown)]
        if !systemReasons.contains(reason), !FileManager.default.fileExists(atPath: AppPaths.file("restarting").path) {
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.turnover.quitting"), object: nil, userInfo: nil, deliverImmediately: true)
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        ScreenCurtain.off()   // macOS would restore the displays anyway; say so in the log
        app?.shutDown()   // the tap first: nothing of TurnOver's takes a key once it is going
        // TurnOver gone: VoiceOver comes back so the user is never left with no speech (the guide promised it;
        // quitting used to leave VoiceOver off, 3 Oct 2026).
        Core.stop()
        Watchdog.shared.active = false   // (or it could post a second toggle while VoiceOver was still starting, 8 Oct 2026)
        Log.info("terminating")
        AppDelegate.voiceOverOnAtQuit.value = config.applications.voiceOverOnAtQuit
        AppDelegate.giveBackToVoiceOver()
    }

    /// VoiceOver on as TurnOver goes, unless this is a restart (an update installing: build.sh leaves a flag) or its
    /// setting is off (Screen reader behaviour).
    /// The setting, copied on main as TurnOver goes: this runs off main on a signal, where main may be stuck. Left
    /// at on when main never answers, so a stuck TurnOver still leaves speech behind.
    nonisolated static let voiceOverOnAtQuit = Locked(true)
    nonisolated static func giveBackToVoiceOver() {
        let flag = AppPaths.file("restarting")
        if FileManager.default.fileExists(atPath: flag.path) { try? FileManager.default.removeItem(at: flag); Log.info("restart: VoiceOver left as it is"); return }
        guard !HandOver.voiceOverReading else { return }
        guard voiceOverOnAtQuit.value else { Log.info("quitting: VoiceOver left off (its setting)"); return }
        // macOS's flag can stay on with VoiceOver gone (quit by script, or crashed): then it is started, not toggled,
        // or the toggle turns the flag off and nobody speaks (a code review, 25 Oct 2026).
        if NSWorkspace.shared.isVoiceOverEnabled { HandOver.bringVoiceOverBack("quitting", waitUpTo: 4); return }
        Log.info("quitting: turning VoiceOver on")
        HandOver.turnVoiceOverOn()
    }

    /// TurnOver Key (Command+Control+T starts and quits TurnOver) runs from login, apart from TurnOver: register it
    /// as a login item, and start it now if it is not running.
    private func startKeyHelper() {
        // A helper from another copy of TurnOver (run from Downloads, then moved and deleted): it looks for
        // TurnOver in the wrong place. Stop it, and register and start this copy's.
        let mine = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/TurnOver Key.app").standardizedFileURL.path
        var reregister = false
        for h in NSRunningApplication.runningApplications(withBundleIdentifier: "com.turnover.key") {
            guard let url = h.bundleURL?.standardizedFileURL.path, url != mine else { continue }
            Log.info("TurnOver Key: one from another copy is running (\(url)); replacing it with this copy's")
            h.terminate()
            reregister = true
        }
        // After an update the old helper went on running from the replaced files: TurnOver's control channel couldn't
        // check its signature and turned it away, and Command Control Period quit TurnOver instead of switching it off
        // (the regression pass of 20.2, 19 Oct 2026; every update since build 20).
        // Once per build (an update, or a new copy dropped in): the helper is started again by launchd from this copy's
        // files. The running one isn't always among NSRunningApplication's (seen 19 Oct 2026, after an update), so
        // launchd is asked by the job's name.
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        if UserDefaults.standard.string(forKey: "keyHelperBuild") != build {
            UserDefaults.standard.set(build, forKey: "keyHelperBuild")
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["kickstart", "-k", "gui/\(getuid())/com.turnover.key"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil { Log.info("TurnOver Key: started again for build \(build) (launchd)") }
        }
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "keyHelperRegisteredFrom") != Bundle.main.bundlePath { reregister = true }
        if reregister {
            let old = SMAppService.loginItem(identifier: "com.turnover.key")
            if old.status == .enabled || old.status == .requiresApproval { try? old.unregister() }
        }
        defaults.set(Bundle.main.bundlePath, forKey: "keyHelperRegisteredFrom")
        let service = SMAppService.loginItem(identifier: "com.turnover.key")
        // Registering again while it waits for approval (or was switched off in Login Items) brings back macOS's
        // "Background Items Added" notice each time TurnOver starts: only when it was never registered.
        Log.info("TurnOver Key: login item status \(service.status.rawValue)")
        if service.status == .notRegistered || service.status == .notFound {
            do { try service.register(); Log.info("TurnOver Key: registered as a login item") }
            catch { Log.error("TurnOver Key: could not register: \(error.localizedDescription)") }
        }
        // macOS starts a newly registered login item itself; start it only if it is still not running a moment later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.turnover.key").isEmpty else { return }
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/TurnOver Key.app")
            let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = false
            NSWorkspace.shared.openApplication(at: helper, configuration: cfg) { _, e in if let e { Log.error("TurnOver Key: \(e.localizedDescription)") } }
        }
    }

    /// Stopped from outside (kill, an installer): the same as quitting.
    private var termSource: DispatchSourceSignal?
    func handleTermination() {
        signal(SIGTERM, SIG_IGN)
        // Not on the main queue: TurnOver Key's Command+Control+T sends this, and it must work even if the main
        // thread is stuck (VoiceOver on, then gone).
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .userInteractive))
        src.setEventHandler { @Sendable in
            Log.info("stopped from outside")
            // The same tidying as a quit from the menu (applicationWillTerminate is skipped on a signal). What is the
            // main actor's (the curtain, the plugins' terminate) by a bounded hop, never a wait on a main thread that
            // may be stuck: that is why this handler isn't on main (a code review, 14 Oct 2026: it ran
            // main-actor code on its global queue).
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { MainActor.assumeIsolated { AppDelegate.voiceOverOnAtQuit.value = config.applications.voiceOverOnAtQuit; ScreenCurtain.off(); delegate.app?.shutDown(); Core.stop() }; done.signal() }
            if done.wait(timeout: .now() + 1.5) == .timedOut {
                CGDisplayRestoreColorSyncSettings()   // the curtain's own undo, without main
                Log.warning("stopped from outside: the main thread didn't answer; the displays restored directly")
            }
            Watchdog.shared.active = false
            // VoiceOver left off on purpose: the Key helper is told this was a quit, or it would start TurnOver
            // again (Codex review, 23 Oct 2026). A restart keeps its flag and the helper's recovery.
            if !AppDelegate.voiceOverOnAtQuit.value, !FileManager.default.fileExists(atPath: AppPaths.file("restarting").path) {
                DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.turnover.quitting"), object: nil, userInfo: nil, deliverImmediately: true)
            }
            AppDelegate.giveBackToVoiceOver()
            exit(0)
        }
        src.resume()
        termSource = src
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
