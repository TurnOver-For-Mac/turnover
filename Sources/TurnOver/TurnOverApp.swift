// SPDX-License-Identifier: GPL-3.0-or-later
// The app's coordinator: when the reader is on, the Mac-specific pieces, and the hand-over between TurnOver and
// VoiceOver.
//
// With CoExist (the default since 18 Oct 2026) VoiceOver runs all the time: TurnOver is active in the apps it reads,
// takes the keys there and keeps VoiceOver quiet (VoiceOverTap); everywhere else, in password fields and in macOS's
// own prompts, it steps aside and VoiceOver is heard. Without CoExist, TurnOver is active exactly when VoiceOver is off
// (option C, 30 Sep 2026): VoiceOver's own toggle is the hand-over in both directions.
import Foundation
import AppKit
import IOKit.hid
import Carbon
import TurnOverCore
import TurnOverControl
import TurnOverSpeech

final class TurnOverApp {
    private let keyboard = KeyboardHandler()
    private let lead = LeadWatcher()
    private let status = StatusItem()
    private var voiceOverObservation: NSKeyValueObservation?
    private let inputActivation = KeyboardActivation()
    private var active: Bool { inputActivation.isActive }
    private var activation: UInt64? { inputActivation.generation }
    private var voiceOverGoneTimer: Timer?
    private var testSayObserver: NSObjectProtocol?
    private var voiceOverGoneChecks = 0
    private var announcedAtLaunch = CommandLine.arguments.contains("--announced")
    private let launchedAt = Date()

    init() throws {
        Config.persists = true   // TurnOver itself: the only process that writes the settings
        // A write to a helper that has died (Kokoro, a plugin brief, any pipe) returns an error instead of ending
        // TurnOver silently, which is SIGPIPE's default (code review, 13 Oct).
        signal(SIGPIPE, SIG_IGN)
        // A start that never finishes (17 Oct 2026: five silent hours) ends itself; the Key helper starts TurnOver again.
        let startDeadline = Thread {
            Thread.sleep(forTimeInterval: 20)
            if !Core.started {
                Log.error("start: stalled for 20 s at \(Core.startStep); ending so the Key helper can start TurnOver again")
                // Three stalled starts in five minutes is a fault that will not clear by itself: say so with the
                // system's voice and stop restarting (a code review on 17 Oct 2026: a silent restart loop).
                let url = AppPaths.file("start-stalls.txt")
                var stalls = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { Double($0) }.filter { Date().timeIntervalSince1970 - $0 < 300 }
                stalls.append(Date().timeIntervalSince1970)
                try? stalls.map { String($0) }.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
                if stalls.count >= 3 {
                    Watchdog.sayOutside(String(localized: "TurnOver cannot start: it stops at \(String(describing: Core.startStep)) every time. VoiceOver reads every app once TurnOver's Activity is removed: open VoiceOver Utility, Activities, and delete TurnOver.", comment: "TurnOver failed to start: %@ is where it stopped (in English)"))
                    Thread.sleep(forTimeInterval: 12)
                    exit(4)
                }
                Watchdog.sayOutside(String(localized: "TurnOver is not starting; trying again.", comment: "Spoken message"))
                exit(3)
            }
        }
        startDeadline.name = "turnover.start-deadline"
        startDeadline.start()
        try Core.start()
        BuiltInModules.register()   // the app modules live in TurnOverCore (so the probes see them too, 8 Oct 2026)
        // Apps with a module of their own are slow by nature and TurnOver is built round it: no drip rest for them
        // (AXHealth, the slow drip). Asked off the main thread, only for a slow question.
        let ownModules = Set(AppModuleHandler.shared.registeredBundleIdentifiers)
        AXHealth.dripExempt = { pid in NSRunningApplication(processIdentifier: pid)?.bundleIdentifier.map { ownModules.contains($0) } ?? false }
        GlobalCommands.shared.script("handOverToVoiceOver", String(localized: "Hand this app to VoiceOver; turns VoiceOver on and TurnOver off, and leaves this application to VoiceOver (Command Control Comma, then T)", comment: "A command, as the key list and keyboard help say it"), gestures: [], category: "System") { [weak self] _ in
            guard let self else { return }
            self.inputActivation.readerSelected()
            Speech.speakMessage("VoiceOver")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.lead.pinCurrentToVoiceOver() }   // the KVO observation deactivates TurnOver
        }
        TurnOverMenu.shared.onGeneralChanged = { [weak self] in self?.status.apply() }
        TurnOverMenu.shared.onScreenCurtainChanged = { [weak self] in if self?.active == true { ScreenCurtain.apply() } }
        status.apply()
        keyboard.onCapsLockToggled = { on in Speech.speakMessage(on ? String(localized: "caps lock on", comment: "Spoken message") : String(localized: "caps lock off", comment: "Spoken message")) }
        keyboard.onReadinessChanged = { [weak self] generation, ready in
            guard let self, self.activation == generation else { return }
            if ready { self.finishActivation(generation) }
            else { self.inputUnavailable(generation) }
        }
        // The app's own items in the menu (docs/MENU-PLAN.md): the hand-over sits in "Hand over or quit"; updates and
        // uninstalling in "About and updates".
        TurnOverMenu.shared.handOverItem = MenuItem("Hand over to VoiceOver", .action { [weak self] in guard let self else { return }
            self.inputActivation.readerSelected()
            Speech.speakMessage("VoiceOver")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.lead.pinCurrentToVoiceOver() }
        }, hint: "For this app, until TurnOver quits. Command Control Comma, then T, does the same and remembers it")
        TurnOverMenu.shared.aboutItems = [MenuItem("Read the guide", .action { TurnOverGuide.open() }, hint: "What TurnOver is and its keys"),
                                          MenuItem("The apps TurnOver reads", .action {
                                              Speech.speakMessage(String(localized: "Experimental mode: the apps on your list under Apps, \(String(config.applications.leadBundles.count)) of them. Everywhere else VoiceOver reads.", comment: "Experimental mode: %@ is how many apps"))
                                          }),
                                          MenuItem("Undo the VoiceOver settings copy", .action { Speech.speakMessage(VoiceOverSettings.undo()) }, hint: "Puts back the voice, rate, pitch, volume, verbosity and typing echo from before the first copy"),
                                          MenuItem("Updates", .submenu { Updater.shared.menuItems() }),
                                          MenuItem("Previous builds", .action {
                                              NSWorkspace.shared.open(URL(string: Edition.releasesURL)!)
                                              Speech.speakMessage(String(localized: "TurnOver's releases page is open in your browser", comment: "Spoken message"))
                                          }, hint: "Every build on GitHub, newest first, to go back to one if the newest breaks something: download it, replace the app, and skip the newer one in Updates"),
            MenuItem("Uninstall TurnOver", .submenu { Uninstaller.menuItems() })]
        TurnOverMenu.shared.readsApp = { [weak self] b in self?.lead.shouldLead(b) ?? false }
        TurnOverMenu.shared.switchReader = { [weak self] in
            self?.inputActivation.readerSelected()
            let to = MenuAnywhere.shared.voiceOverWasReading
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.lead.switchCurrent(toTurnOver: to) }
        }
        // Each style its own reader's key (the parity audit, 13 Oct 2026): NVDA+Control+Escape in the Windows style,
        // VoiceOver's VO-Shift-Minus (VO-Shift-Fn-Underscore) in the Mac style. VO-Shift-Minus in the Windows style was
        // NVDA 2026's "zoom out", and VO-Shift-Escape is VoiceOver's "top level", so neither is the curtain's there.
        GlobalCommands.shared.script("screenCurtain", String(localized: "Screen Curtain on or off: the screen goes black while TurnOver reads as normal (NVDA+Control+Escape)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+control+escape"]) { _ in
            ScreenCurtain.toggle()
        }.isAvailable = { config.general.windowsKeys }
        GlobalCommands.shared.script("vo_screenCurtain", String(localized: "Screen Curtain on or off: the screen goes black while TurnOver reads as normal (VO-Shift-Fn-Underscore)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+shift+-"]) { _ in
            ScreenCurtain.toggle()
        }.isAvailable = { config.general.macKeys }
    }


    /// An Activity left by a build before 18 Oct 2026 comes out, once: it kept VoiceOver's speech off in TurnOver's apps,
    /// password fields included.
    private func removeOldActivity() {
        guard ActivityFlow.shared.marker.installed else { return }
        Log.info("start: an Activity from an earlier build; taking it out")
        // Said first: VoiceOver Utility comes forward for about ten seconds and drives itself (an update from build
        // 19 or earlier; it was silent, and looked like something going wrong).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            Speech.speakMessage(String(localized: "Tidying up VoiceOver's settings from an earlier TurnOver. VoiceOver Utility opens and closes by itself; a moment.", comment: "Spoken message"))
            ActivityFlow.shared.set(apps: nil) { text in Log.info("activity removed: \(text)"); Speech.speakMessage(String(localized: "Done.", comment: "Spoken message")) }
        }
    }

    func start() {
        lead.turnOverActive = { [weak self] in self?.activation != nil }
        // An Activity left by a build before 18 Oct 2026 (the first CoExist) comes out whatever the switch says: it
        // keeps VoiceOver's speech off in the apps it lists (a review, 28 Oct 2026).
        removeOldActivity()
        if Coexist.on {
            // CoExist means VoiceOver running: off at start (an update from the old way, which turned it off), it's
            // turned on, after a moment so the two don't start talking over each other (19 Oct 2026). Until it
            // is, TurnOver reads every app.
            if !NSWorkspace.shared.isVoiceOverEnabled {
                Log.info("start: CoExist with VoiceOver off; turning VoiceOver on in 3 s")
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 3) { HandOver.turnVoiceOverOn() }
            } else if !HandOver.voiceOverRunning {
                // The flag on with no VoiceOver (quit by script, or crashed): started now, not after the watchdog's 8 s.
                Log.info("start: CoExist, VoiceOver's flag on but it isn't running; starting it in 3 s")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    guard NSWorkspace.shared.isVoiceOverEnabled, !HandOver.voiceOverRunning else { return }
                    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Library/CoreServices/VoiceOver.app"), configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
                }
            }
            startCoexist()
            // Password fields and macOS's prompts stay with whichever reader is in charge (28 Oct 2026, Oliver: "we can just
            // let whichever screen reader that's in charge take the security"; the first CoExist stepped TurnOver aside
            // there, 18 Oct). TurnOver never echoes a password; it keeps the application chooser, force quit and the
            // prompts, which it handles better.
        }
        TurnOverMenu.shared.quit = { [weak self] in self?.quitRestoringVoiceOver() ?? NSApp.terminate(nil) }
        lead.onCoexistLead = { [weak self] turnOver in if turnOver { self?.activate() } else { self?.deactivate() } }
        MenuAnywhere.shared.turnOverActive = { [weak self] in self?.active ?? false }
        Speech.player?.onQueueStuck = { stall in Watchdog.shared.speechStuck(stall) }
        Speech.player?.onOutputUnavailable = { [weak self] source, failure in
            let choice = HandOver.choice.value
            onMain { [weak self] in self?.speechOutputUnavailable(failure, from: source, readerChoice: choice) }
        }
        QuickNavWatch.shared.turnOverActive = { [weak self] in self?.active ?? false }
        QuickNavWatch.shared.start()
        ArrowQuickNav.startInStep()
        MenuAnywhere.shared.handOver = { [weak self] on in self?.lead.handOver(voiceOverOn: on) }
        MenuAnywhere.shared.shouldLead = { [weak self] b in self?.lead.shouldLead(b) ?? false }
        MenuAnywhere.shared.switchLead = { [weak self] to in self?.inputActivation.readerSelected(); self?.lead.switchCurrent(toTurnOver: to) }
        MenuAnywhere.shared.toggleDirect = { [weak self] in self?.lead.toggleDirect() }
        VoiceOverSettings.automaticExport = { done in ActivityFlow.shared.export(completion: done) }
        // Words from a companion app (Windy: "Windows style"): said by TurnOver where TurnOver reads, since VoiceOver
        // is quiet there; the companion says them through VoiceOver as well, for VoiceOver's apps (17 Oct 2026).
        // Through the control channel, so only a program of TurnOver's own developer can make TurnOver speak (any
        // program could, by distributed notification, until a code review on 18 Oct 2026: a fake prompt, say).
        ControlServer.shared.handlers["say"] = { message, _ in
            guard let text = message["text"] as? String, !text.isEmpty, text.count < 400, Core.active else { return }
            Log.io("say for a companion: \(Log.words(String(text.prefix(60))))"); Speech.speakMessage(text)
        }
        MenuAnywhere.shared.cycleLeadMode = { [weak self] in
            self?.inputActivation.readerSelected()
            guard config.applications.perAppReaders else { Speech.speakMessage(String(localized: "Readers per app are off: TurnOver reads everywhere while it is on. Settings, Screen reader behaviour, turns them on.", comment: "Spoken message")); return }
            self?.lead.cycleMode()
        }
        TurnOverMenu.shared.leadModeChanged = { [weak self] in self?.lead.refreshAfterModeChange() }
        Core.lendToVoiceOver = { [weak self] s in self?.lead.lend(seconds: s) }
        MenuAnywhere.shared.register()
        TurnOverMenu.shared.relaunch = {
            let restart = {
                Log.info("mode changed: restarting")
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = ["-n", Bundle.main.bundlePath]
                try? FileManager.default.createDirectory(at: AppPaths.file("restarting").deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: AppPaths.file("restarting").path, contents: nil)
                try? p.run(); Thread.sleep(forTimeInterval: 0.5); exit(0)
            }
            restart()
        }
        ScreenRecognition.warmUp()
        WindowsRemap.watchFrontApp()
        GlobalCommands.onKeyboardStyleChanged = { [weak self] in
            guard let self else { return }
            self.refreshWindowsLayer()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refreshWindowsLayer() }   // the app in front at start may be VoiceOver's
        Log.info("edition: \(Edition.editionName) (\(Edition.fullName))")
        Watchdog.shared.start()
        // Held and replayed in order while the main thread is busy (an application not answering for a second or two);
        // let through only once the main thread has been gone as long as the watchdog allows. At 1.5 s, a key pressed
        // late in a 1.8 s Safari stall went to Safari ahead of an earlier one still held (10 Oct 2026).
        ScriptHandler.mainStuck = { Watchdog.shared.secondsSinceBeat > 4 }
        Watchdog.shared.installTestHook()
        voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled, options: [.initial, .new]) { [weak self] ws, _ in
            DispatchQueue.main.async { self?.voiceOverChanged(NSWorkspace.shared.isVoiceOverEnabled) }
        }
        watchForVoiceOverGone()
        lead.start()
        Games.startIfWanted()
        PluginTry.start()
        VoiceOverSettings.probeIfAsked()   // a one-off look at VoiceOver's settings, when asked (VoiceOverSettings.swift)
        // For tests and demonstrations only (the "testSpeech" default): a distributed notification makes TurnOver say
        // its object text, so a hand-over can be heard with a count passing between the readers (15 Oct 2026).
        if Edition.devDefault("testSpeech") {
            testSayObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.turnover.test.say"), object: nil, queue: .main) { n in
                guard let text = n.object as? String, !text.isEmpty else { return }
                MainActor.assumeIsolated { Speech.speakMessage(String(text.prefix(200))) }
            }
        }
        Trackpad.startIfWanted()   // the Trackpad gestures plugin, or the "trackpad" default (Trackpad.swift)   // an AI making a plugin may ask TurnOver to try keys in that app (PluginTry.swift)
        // Started while VoiceOver has the Mac (a login, a restart): no words, VoiceOver is talking, but a tone ().
        if NSWorkspace.shared.isVoiceOverEnabled { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { Tones.startup() } }
        watchForInputMonitoring()
        // The swap turned on in Settings while TurnOver waits for VoiceOver (the swap was off): the hand-over it would
        // have made at launch, now (25 Oct 2026).
        SettingsBridge.onSwapChanged = { [weak self] on in
            guard let self, on, self.heldForVoiceOver, !self.active, NSWorkspace.shared.isVoiceOverEnabled else { return }
            Log.info("swap turned on while TurnOver waits for VoiceOver: handing over")
            self.heldForVoiceOver = false
            self.lead.handOver(voiceOverOn: false)
        }
        // The front application at launch may already be one of TurnOver's.
        // Not coexisting, the launch hand-over turns VoiceOver off: only with the swap on, else neither changes the other.
        let launchMayTurnVoiceOverOff = Coexist.on || config.applications.swapWithVoiceOver
        if let front = NSWorkspace.shared.frontmostApplication, let b = front.bundleIdentifier, config.applications.handsOverAtLaunch, launchMayTurnVoiceOverOff,
           lead.shouldLead(b), NSWorkspace.shared.isVoiceOverEnabled || Coexist.on {
            Log.info("start: \(b) is TurnOver's and VoiceOver is on; handing over in a second")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                Log.info("start: the hand-over step runs (self \(self == nil ? "gone" : "here"))")
                self?.lead.handOver(voiceOverOn: false)
            }
        } else if !Coexist.on, !config.applications.swapWithVoiceOver, !lead.suspended {
            // Neither reader changes the other (22 Oct 2026), but one speaks at a time: VoiceOver on and running at the
            // start keeps the Mac, and TurnOver waits for it to go off (both spoke over each other, 25 Oct 2026).
            if NSWorkspace.shared.isVoiceOverEnabled, HandOver.voiceOverRunning {
                Log.info("start: VoiceOver is on and the swap is off; TurnOver waits for it to go off")
                heldForVoiceOver = true
                // The Settings window must reach TurnOver while it waits, or the advice can't be followed (a code review).
                SettingsBridge.start()
                VoiceOverSpeak.say("VoiceOver is on, so TurnOver waits. Turn VoiceOver off and TurnOver speaks; or turn the swap on in Settings, Screen reader behaviour.")
            } else {
                Log.info("start: TurnOver on without a hand-over (the swap is off)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self else { return }
                    // VoiceOver turned on during the second: TurnOver waits instead (a code review, 25 Oct 2026).
                    if NSWorkspace.shared.isVoiceOverEnabled, HandOver.voiceOverRunning { self.heldForVoiceOver = true; return }
                    self.activate()
                }
            }
        } else {
            Log.info("start: no hand-over at launch (front \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"), VoiceOver \(NSWorkspace.shared.isVoiceOverEnabled ? "on" : "off"))")
        }
    }

    /// Until Input Monitoring is granted, VoiceOver keeps every application. Look every two seconds; when the user
    /// turns it on in System Settings, say so and take over where TurnOver should, with no restart (a tester's
    /// Mac, 5 Oct 2026: granted later, TurnOver went on leaving everything to VoiceOver).
    private var inputTimer: Timer?
    private func watchForInputMonitoring() {
        guard inputTimer == nil, !InputAccess.granted else { return }
        // Ask now, straight after Accessibility. It used to be asked only when TurnOver first took over from
        // VoiceOver, and without it TurnOver never takes over: on a fresh install the question never came (a
        // fresh-install test, 6 Oct 2026; a tester's first log shows the same).
        if InputAccess.askOnce() {
            Log.info("Input Monitoring: asked")
            // macOS 27 adds TurnOver to the list without showing a question (6 Oct 2026): if it is still not on a
            // moment later, say so in an alert VoiceOver reads, and open the right page of System Settings.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard self != nil, !InputAccess.granted else { return }
                Self.explainInputMonitoring()
            }
        }
        inputTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated {
            guard let self, InputAccess.granted else { return }
            self.inputTimer?.invalidate(); self.inputTimer = nil
            Log.info("Input Monitoring granted")
            Speech.speakMessage(String(localized: "Input Monitoring is on. TurnOver is ready.", comment: "Spoken message"))
            self.keyboard.reopenKeyboardWatch()   // the keyboard watch opens again, now allowed
            self.lead.inputMonitoringGranted()
        } }
    }

    static func explainInputMonitoring() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "One more permission: Input Monitoring", comment: "Spoken message")
        alert.informativeText = String(localized: "TurnOver needs Input Monitoring to hear the TurnOver key and to take over from VoiceOver. Choose Open Settings, find TurnOver in the Input Monitoring list, and turn it on. TurnOver notices by itself and says when it is ready.", comment: "Spoken message")
        alert.addButton(withTitle: String(localized: "Open Settings", comment: "Spoken message"))
        alert.addButton(withTitle: String(localized: "Later", comment: "Spoken message"))
        Log.info("Input Monitoring: explained")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    /// VoiceOver ended without turning itself off (it crashed, or was stopped from outside): macOS still says it's on,
    /// so TurnOver stayed quiet, and the Mac had no speech at all until VoiceOver was started again (14 Oct 2026, a
    /// test that stopped VoiceOver by its process). Every 2 s: the flag on and no VoiceOver for four looks in a row
    /// (VoiceOver starting shows its process within a second or two), and TurnOver speaks.
    private var voiceOverOnChecks = 0
    private var voiceOverWasReading = HandOver.voiceOverReading
    private func watchForVoiceOverGone() {
        voiceOverGoneTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Coexisting, VoiceOver's process coming or going under a flag that stays on sends no change notice:
                // the app in front is looked at afresh when it does, so TurnOver reads it while VoiceOver isn't there.
                let reading = HandOver.voiceOverReading
                if Coexist.on, reading != self.voiceOverWasReading {
                    self.voiceOverWasReading = reading
                    if let front = NSWorkspace.shared.frontmostApplication { self.lead.look(at: front) }
                }
                // The other way round: VoiceOver on and running while TurnOver still leads. macOS's change notice never
                // came for a tester (15 Oct 2026: he turned VoiceOver on by hand, TurnOver kept the keys, and
                // only Activity Monitor could stop it). Two looks, 2 s apart, so a hand-over in progress isn't mistaken.
                if !Coexist.on, NSWorkspace.shared.isVoiceOverEnabled, HandOver.voiceOverRunning, self.activation != nil {
                    self.voiceOverOnChecks += 1
                    if self.voiceOverOnChecks >= 2 {
                        self.voiceOverOnChecks = 0
                        Log.warning("VoiceOver is on and running while TurnOver leads, and no change notice came: stepping aside")
                        self.voiceOverChanged(true)
                    }
                    return
                }
                self.voiceOverOnChecks = 0
                guard NSWorkspace.shared.isVoiceOverEnabled, !HandOver.voiceOverRunning else { self.voiceOverGoneChecks = 0; return }
                self.voiceOverGoneChecks += 1
                guard self.voiceOverGoneChecks == 4 else { return }
                // Coexisting, VoiceOver is the reader everywhere else: started again (a code review on 17 Oct 2026).
                if Coexist.on {
                    Log.warning("VoiceOver: macOS says it's on but it isn't running; starting it again")
                    Speech.speakMessage(String(localized: "VoiceOver stopped; starting it again.", comment: "Spoken message"))
                    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Library/CoreServices/VoiceOver.app"), configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
                    return
                }
                guard !self.active else { return }
                Log.warning("VoiceOver: macOS says it's on but it isn't running (crashed or stopped); TurnOver speaks")
                self.activate()
                Speech.speakMessage(String(localized: "VoiceOver stopped. TurnOver is speaking.", comment: "Spoken message"))
            }
        }
    }

    /// The first report of VoiceOver's state is TurnOver starting, not a change by hand: the swap setting does not apply to it.
    private var sawVoiceOverState = false
    /// The swap off and VoiceOver on while TurnOver was speaking: TurnOver is quiet until VoiceOver goes off.
    private var heldForVoiceOver = false

    private func voiceOverChanged(_ on: Bool) {
        let byInputRecovery = inputActivation.takeAutomaticVoiceOverRestore(on: on, readerChoice: HandOver.choice.value)
        HandOver.newChoice()   // VoiceOver turned on or off, by hand too: a recovery's late fallback stands down
        Log.info("VoiceOver is \(on ? "on" : "off")")
        let starting = !sawVoiceOverState
        sawVoiceOverState = true
        defer { refreshWindowsLayer() }
        // Coexisting (experimental): VoiceOver off means TurnOver reads every app (LeadWatcher.shouldLead), on again
        // means it goes back to its own; the app in front is looked at afresh either way (19 Oct 2026).
        // The lock's own VoiceOver, noticed late (after the wake, before or after the unlock): no pin, no yielding.
        let byLock = on && lead.takeLockVoiceOverOn()
        if byLock { Log.info("VoiceOver on: the lock screen's own, noticed late") }
        if Coexist.on {
            Log.info("coexist: VoiceOver \(on ? "on" : "off"); TurnOver reads \(on ? "its own apps" : "every app") now")
            if !on { lead.yieldedToVoiceOverByHand = false }
            if let front = NSWorkspace.shared.frontmostApplication { lead.look(at: front) }
            return
        }
        lead.voiceOverChanged(on: on, byLock: byLock, byInputRecovery: byInputRecovery)
        // Screen reader behaviour (22 Oct 2026): the swap is a setting. Off, VoiceOver's key changes nothing of TurnOver's.
        // VoiceOver going off ends any yielding, whatever the swap setting says.
        if !on { lead.yieldedToVoiceOverByHand = false }
        if !config.applications.swapWithVoiceOver, !starting {
            // The swap off: neither reader turns the other on or off, but one speaks at a time (25 Oct 2026: with the
            // swap off, VoiceOver turned on by hand left both talking). VoiceOver on quietens TurnOver; VoiceOver off
            // brings it back only if that is what quietened it, since TurnOver's own key is the way it comes on.
            if on {
                if inputActivation.yieldToVoiceOver() {
                    Log.info("VoiceOver on; TurnOver is quiet until it goes off (the swap is off)")
                    heldForVoiceOver = true
                    deactivate()
                }
            } else if heldForVoiceOver {
                heldForVoiceOver = false
                Log.info("VoiceOver off; TurnOver speaks again (the swap is off)")
                activate()
            }
            return
        }
        // Only a change made by hand counts as yielding: a hand-over TurnOver posted itself (the lock screen) does not.
        // Nor one noticed while the Mac is locked or asleep: the lock's own, its notice held back until the wake, long
        // after the three-second window (26 Oct 2026; the lead watcher clears the flag again on the unlock as well).
        if on, !starting, !lead.isOurChange, !lead.locked, !byLock, !byInputRecovery {
            lead.yieldedToVoiceOverByHand = true
            Log.info("VoiceOver turned on by hand: TurnOver steps back until it goes off or TurnOver's key")
        }
        if on { deactivate() } else { activate() }
    }

    /// "NVDA and JAWS keys where VoiceOver reads too": the small key layer runs while VoiceOver leads (TurnOver's own
    /// layer does the same translations while TurnOver leads).
    private func refreshWindowsLayer() {
        // NVDA keys where VoiceOver reads (docs/KEYBOARD-STYLES-PLAN.md step 2, 19 Oct 2026; shelved since 6 Oct, back with
        // Windy folded in): on in a Windows-family style while TurnOver is running but not the reader of the app in
        // front. Off where TurnOver reads (its own tap has the keys) and when TurnOver is switched off.
        // Its setting turns it off: the layer takes Caps Lock where VoiceOver reads, so VoiceOver's own Caps Lock keys
        // (VO-F7, VO-F8, VO-M) are the NVDA key's there (21 Oct 2026).
        if config.general.windowsKeys, config.general.keysWhereVoiceOverReads, activation == nil, !active, !lead.suspended, InputAccess.granted, NSWorkspace.shared.isVoiceOverEnabled {
            WindowsKeyLayer.shared.start()
        } else {
            WindowsKeyLayer.shared.stop()
        }
    }

    private func speechOutputUnavailable(_ failure: SpeechOutputFailure, from source: SpeechPlayer, readerChoice: Int) {
        // A delivery can wait on main while a key cancels speech, the user picks a reader, or a replacement player
        // starts. Wake grace leaves the incident pending: the responsive speech queue offers it again afterwards.
        let state: SpeechOutputRecovery.ReaderState
        if !active || lead.suspended { state = .inactive }
        else if source.isPaused || (Speech.mode != .talk && Speech.mode != .onDemand) { state = .intentionallyQuiet }
        else if lead.locked || Watchdog.shared.inGrace { state = .waking }
        else { state = .required }
        SpeechOutputRecovery.receive(failure, isCurrent: Speech.player === source && HandOver.choice.value == readerChoice, state: state) {
            Log.error("speech: required output made no \(failure.stage == .rendering ? "rendered frames" : "playback progress") within 4 s; handing back to VoiceOver")
            lead.suspended = true   // no automatic take-back into the failed output path; TurnOver's key retries it
            KeyboardHandler.bypass = true
            // Release first: deactivation closes the braille driver, which may wait on hardware. A speech failure
            // must not keep VoiceOver muted or postpone starting it while that unrelated close finishes.
            if Coexist.on { VoiceOverTap.set(false, why: "TurnOver speech output failed") }
            HandOver.bringVoiceOverBack("speech output failed")
            Watchdog.sayOutside(String(localized: "TurnOver's speech output stopped. Handing back to VoiceOver. Press Command Control Period to try TurnOver again.", comment: "Spoken message"))
            deactivate()
        }
    }

    private func activate() {
        guard activation == nil, !active, !lead.suspended, !lead.locked else { return }
        WindowsKeyLayer.shared.stop()
        KeyboardHandler.bypass = true
        let inputGranted = InputAccess.granted
        if !inputGranted, InputAccess.askOnce() {
            Speech.speakMessage(String(localized: "TurnOver needs Input Monitoring for its keys. Opening System Settings, where VoiceOver will read: turn TurnOver on in the list.", comment: "Spoken message"))
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") { NSWorkspace.shared.open(url) }
        }
        let generation = keyboard.start()
        inputActivation.begin(generation)
        // Caps Lock needs the physical HID watch. The event tap alone can work for Control+Option, but must
        // not swallow Caps Lock while its input permission is absent. A granted permission is accepted even
        // with Karabiner's existing exclusive-open result; that result alone does not prove missing reports.
        if KeySettings.current.capsIsTurnOver, !inputGranted { inputUnavailable(generation, awaitingPermission: true); return }
        // Setup can itself stall. Cancel the request rather than allowing a late tap to silence VoiceOver
        // after the user has already been handed back (review of #52, 28 Oct 2026).
        onMain(after: 3) { [weak self] in
            guard let self, self.activation == generation, !self.active else { return }
            self.inputUnavailable(generation)
        }
    }

    private func inputUnavailable(_ generation: UInt64, awaitingPermission: Bool = false) {
        guard activation == generation else { return }
        Log.error("keyboard: input unavailable for the current activation; VoiceOver keeps the Mac")
        // Missing permission already gates the lead policy; its existing watch can retry once granted.
        // Other failures suspend automatic take-back until the user explicitly turns TurnOver on again.
        if !awaitingPermission { lead.suspended = true }
        KeyboardHandler.bypass = true
        VoiceOverTap.set(false, why: "TurnOver's keyboard is unavailable")
        let needsVoiceOver = !HandOver.voiceOverReading
        HandOver.bringVoiceOverBack("TurnOver's keyboard is unavailable")
        if awaitingPermission {
            if needsVoiceOver { inputActivation.expectAutomaticVoiceOverRestore(readerChoice: HandOver.choice.value) }
            watchForInputMonitoring()   // reinstalls the watch if permission was revoked after a granted launch
        }
        Watchdog.sayOutside(String(localized: "TurnOver's keyboard is unavailable. VoiceOver is taking over. Check TurnOver's Accessibility and Input Monitoring permissions before turning TurnOver on again.", comment: "Spoken message"))
        deactivate()
    }

    private func finishActivation(_ generation: UInt64) {
        guard activation == generation, !active else { return }
        guard !lead.suspended, !lead.locked else { deactivate(); return }
        guard keyboard.isReady(generation) else { return }
        Watchdog.shared.active = true
        Core.activate()
        // Core setup can take time. A failed tap during it must not lead to muting VoiceOver afterwards.
        guard inputActivation.confirm(generation, inputReady: keyboard.isReady(generation)) else { inputUnavailable(generation); return }
        KeyboardHandler.bypass = false
        SecureInputWatch.start()
        if Coexist.on { VoiceOverTap.set(true, why: "TurnOver takes \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "an app")") }
        // VoiceOver's speech settings may have been changed where it read: TurnOver takes them up (SpeechParity).
        if Coexist.on, SpeechParity.on { SpeechParity.followVoiceOver() }
        ScreenCurtain.apply()
        // Started by Command+Control+T: TurnOver Key has just said "TurnOver on"; the first take-over is not said again.
        // At launch TurnOver names itself ("TurnOver on"); later take-overs say the usual "TurnOver on" or play the chime.
        let atLaunch = Date().timeIntervalSince(launchedAt) < 10
        if let words = LeadWatcher.nextTakeoverWords { LeadWatcher.nextTakeoverWords = nil; Speech.speakMessage(words) }   // a mode's name, once
        else if config.general.handOverNothing { if atLaunch { announcedAtLaunch = false } }   // nothing, by choice
        else if announcedAtLaunch, atLaunch { announcedAtLaunch = false; Speech.speakMessage(Edition.editionName) }
        else if atLaunch { Speech.speakMessage("\(Edition.editionName) on") }
        else if config.general.handOverChimes { Tones.takeOver() } else { Speech.speakMessage(String(localized: "TurnOver on", comment: "Spoken message")) }
    }

    // MARK: Coexisting with VoiceOver: on and off while running

    /// The system's keyboard focus is a password field (asked briefly: a busy app is taken as no).
    private static func systemFocusIsPasswordField() -> Bool {
        // The front app's own element, with its own short timeout (the system-wide element's would set every call's).
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let f = app.element(kAXFocusedUIElementAttribute) else { return false }
        return f.string(kAXSubroleAttribute) == "AXSecureTextField"
    }

    private var secureTimer: Timer?
    private func startCoexist() {
        // The Key helper asks, instead of quitting TurnOver: Command Control Period is on and off (16 Oct 2026). Through
        // the control channel: only TurnOver Key (signed by the same developer) can turn TurnOver off.
        ControlServer.shared.handlers["toggle"] = { [weak self] _, reply in
            reply(["op": "ack"])
            self?.toggleCoexist()
        }
        // VoiceOver is silenced by the audio tap (VoiceOverTap), not by an Activity any more (18 Oct 2026). An Activity
        // left by an earlier build comes out, once: it kept VoiceOver's speech off in TurnOver's apps, password fields
        // included, where VoiceOver must be heard.
        if ActivityFlow.shared.marker.installed {
            Log.info("coexist: an Activity from an earlier build; taking it out")
            // Said first: VoiceOver Utility comes forward for about ten seconds and drives itself (an update from build
            // 19 or earlier; it was silent, and looked like something going wrong).
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                Speech.speakMessage(String(localized: "Tidying up VoiceOver's settings from an earlier TurnOver. VoiceOver Utility opens and closes by itself; a moment.", comment: "Spoken message"))
                ActivityFlow.shared.set(apps: nil) { text in Log.info("activity removed: \(text)"); Speech.speakMessage(String(localized: "Done.", comment: "Spoken message")) }
            }
        }
    }
    private func toggleCoexist() {
        inputActivation.readerSelected()
        if lead.suspended {
            lead.suspended = false
            lead.yieldedToVoiceOverByHand = false   // turned on by its own key: it takes the app in front again
            Speech.speakMessage("TurnOver on")
            if !Coexist.on, !config.applications.swapWithVoiceOver {
                activate()   // on by its key, whatever VoiceOver is doing: the swap is off
            } else if let front = NSWorkspace.shared.frontmostApplication {
                lead.look(at: front)
            }
            refreshWindowsLayer()
        } else {
            lead.suspended = true
            // Said before TurnOver steps back, with its own voice: VoiceOver's is silent here (the code review, 17 Oct 2026).
            Speech.speakMessage("TurnOver off")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                // Turned on again within the pause: nothing to hand back (off then on in two seconds left VoiceOver
                // unmuted under TurnOver, the hand-back landing after the take: 18 Oct 2026).
                guard let self, self.lead.suspended else { Log.info("coexist: on again before the hand-back; it's dropped"); return }
                self.deactivate()
                self.refreshWindowsLayer()
            }
        }
    }
    /// Quit from the menu while coexisting: VoiceOver gets its apps back first, then TurnOver goes.
    func quitRestoringVoiceOver() {
        lead.suspended = true
        deactivate()
        NSApp.terminate(nil)   // applicationShouldTerminate removes the Activity first when coexisting (main.swift)
    }

    /// Quitting: the tap and the watchdog go first, before VoiceOver is turned on. The tap stayed up through the
    /// hand-over and swallowed keys for up to 4 s at a menu quit (code review, 16 Oct 2026).
    func shutDown() {
        inputActivation.cancel()
        KeyboardHandler.bypass = true
        Watchdog.shared.active = false
        keyboard.stop()
        if Coexist.on { VoiceOverTap.set(false, why: "quit") }
        Log.info("quit: the keyboard tap stopped")
    }

    private func deactivate() {
        SecureInputWatch.stop()
        Watchdog.shared.active = false
        let wasActive = active
        inputActivation.cancel()
        KeyboardHandler.bypass = true
        keyboard.stop()
        if Coexist.on { VoiceOverTap.set(false, why: "TurnOver hands back") }
        if wasActive {
            // The falling chime as VoiceOver takes over (words would collide with VoiceOver's own "VoiceOver on").
            if config.general.handOverChimes, !config.general.handOverNothing { Tones.handBack() }
        }
        // This also covers a reader choice which cancelled activation before this call.
        if TurnOverMenu.shared.isOpen { TurnOverMenu.shared.close() }
        Core.deactivate()
        refreshWindowsLayer()
        ScreenCurtain.off()   // VoiceOver's own takes over (its setting stays as the user left it)
    }
}
