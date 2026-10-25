// SPDX-License-Identifier: GPL-3.0-or-later
// The app's coordinator: when the reader is on, the Mac-specific pieces, and the hand-over between TurnOver and
// VoiceOver.
//
// TurnOver is active exactly when VoiceOver is off (option C, 30 Sep 2026): VoiceOver's own toggle is the hand-over in
// both directions. (CoExist, VoiceOver running alongside and silenced by an audio tap, was removed on 24 Oct 2026:
// Oliver, "it just confuses things"; one reader at a time, as on every other platform.)
import Foundation
import AppKit
import IOKit.hid
import Carbon
import TurnOverCore
import TurnOverControl

final class TurnOverApp {
    private let keyboard = KeyboardHandler()
    private let lead = LeadWatcher()
    private let status = StatusItem()
    private var voiceOverObservation: NSKeyValueObservation?
    private var active = false
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
                    Watchdog.sayOutside("TurnOver cannot start: it stops at \(Core.startStep) every time. VoiceOver reads every app once TurnOver's Activity is removed: open VoiceOver Utility, Activities, and delete TurnOver.")
                    Thread.sleep(forTimeInterval: 12)
                    exit(4)
                }
                Watchdog.sayOutside("TurnOver is not starting; trying again.")
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
        GlobalCommands.shared.script("handOverToVoiceOver", "Hand this app to VoiceOver; turns VoiceOver on and TurnOver off, and leaves this application to VoiceOver (Command Control Comma, then T)", gestures: [], category: "System") { [weak self] _ in
            guard let self else { return }
            Speech.speakMessage("VoiceOver")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.lead.pinCurrentToVoiceOver() }   // the KVO observation deactivates TurnOver
        }
        TurnOverMenu.shared.onGeneralChanged = { [weak self] in self?.status.apply() }
        TurnOverMenu.shared.onScreenCurtainChanged = { [weak self] in if self?.active == true { ScreenCurtain.apply() } }
        status.apply()
        keyboard.onCapsLockToggled = { on in Speech.speakMessage(on ? "caps lock on" : "caps lock off") }
        // The app's own items in the menu (docs/MENU-PLAN.md): the hand-over sits in "Hand over or quit"; updates and
        // uninstalling in "About and updates".
        TurnOverMenu.shared.handOverItem = MenuItem("Hand over to VoiceOver", .action { [weak self] in guard let self else { return }
            Speech.speakMessage("VoiceOver")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.lead.pinCurrentToVoiceOver() }
        }, hint: "For this app, until TurnOver quits. Command Control Comma, then T, does the same and remembers it")
        TurnOverMenu.shared.aboutItems = [MenuItem("Read the guide", .action { TurnOverGuide.open() }, hint: "What TurnOver is and its keys"),
                                          MenuItem("The apps TurnOver reads", .action {
                                              Speech.speakMessage("Experimental mode: the apps on your list under Apps, \(config.applications.leadBundles.count) of them. Everywhere else VoiceOver reads.")
                                          }),
                                          MenuItem("Undo the VoiceOver settings copy", .action { Speech.speakMessage(VoiceOverSettings.undo()) }, hint: "Puts back the voice, rate, pitch, volume, verbosity and typing echo from before the first copy"),
                                          MenuItem("Updates", .submenu { Updater.shared.menuItems() }),
                                          MenuItem("Previous builds", .action {
                                              NSWorkspace.shared.open(URL(string: Edition.releasesURL)!)
                                              Speech.speakMessage("TurnOver's releases page is open in your browser")
                                          }, hint: "Every build on GitHub, newest first, to go back to one if the newest breaks something: download it, replace the app, and skip the newer one in Updates"),
            MenuItem("Uninstall TurnOver", .submenu { Uninstaller.menuItems() })]
        TurnOverMenu.shared.readsApp = { [weak self] b in self?.lead.shouldLead(b) ?? false }
        TurnOverMenu.shared.switchReader = { [weak self] in let to = MenuAnywhere.shared.voiceOverWasReading; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.lead.switchCurrent(toTurnOver: to) } }
        // Each style its own reader's key (the parity audit, 13 Oct 2026): NVDA+Control+Escape in the Windows style,
        // VoiceOver's VO-Shift-Minus (VO-Shift-Fn-Underscore) in the Mac style. VO-Shift-Minus in the Windows style was
        // NVDA 2026's "zoom out", and VO-Shift-Escape is VoiceOver's "top level", so neither is the curtain's there.
        GlobalCommands.shared.script("screenCurtain", "Screen Curtain on or off: the screen goes black while TurnOver reads as normal (NVDA+Control+Escape)", gestures: ["kb:turnover+control+escape"]) { _ in
            ScreenCurtain.toggle()
        }.isAvailable = { config.general.windowsKeys }
        GlobalCommands.shared.script("vo_screenCurtain", "Screen Curtain on or off: the screen goes black while TurnOver reads as normal (VO-Shift-Fn-Underscore)", gestures: ["kb:turnover+shift+-"]) { _ in
            ScreenCurtain.toggle()
        }.isAvailable = { config.general.macKeys }
    }


    func start() {
        lead.turnOverActive = { [weak self] in self?.active ?? false }
        // An Activity left by a build before 18 Oct 2026 (the first CoExist) comes out, once: it keeps VoiceOver's speech
        // off in the apps it lists.
        removeOldActivity()
        // The CoExist default of earlier builds, gone with it (24 Oct 2026).
        UserDefaults.standard.removeObject(forKey: "coexist")
        TurnOverMenu.shared.quit = { [weak self] in self?.quitRestoringVoiceOver() ?? NSApp.terminate(nil) }
        MenuAnywhere.shared.turnOverActive = { [weak self] in self?.active ?? false }
        Speech.player?.onQueueStuck = { seconds in Watchdog.shared.speechStuck(for: seconds) }
        MenuAnywhere.shared.handOver = { [weak self] on in self?.lead.handOver(voiceOverOn: on) }
        MenuAnywhere.shared.shouldLead = { [weak self] b in self?.lead.shouldLead(b) ?? false }
        MenuAnywhere.shared.switchLead = { [weak self] to in self?.lead.switchCurrent(toTurnOver: to) }
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
            guard config.applications.perAppReaders else { Speech.speakMessage("Readers per app are off: TurnOver reads everywhere while it is on. Settings, Screen reader behaviour, turns them on."); return }
            self?.lead.cycleMode()
        }
        TurnOverMenu.shared.leadModeChanged = { [weak self] in self?.lead.refreshAfterModeChange() }
        Core.lendToVoiceOver = { [weak self] s in self?.lead.lend(seconds: s) }
        MenuAnywhere.shared.register()
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
        // The front application at launch may already be one of TurnOver's.
        // The launch hand-over turns VoiceOver off: only with the swap on, else neither changes the other.
        let launchMayTurnVoiceOverOff = config.applications.swapWithVoiceOver
        if let front = NSWorkspace.shared.frontmostApplication, let b = front.bundleIdentifier, config.applications.handsOverAtLaunch, launchMayTurnVoiceOverOff,
           lead.shouldLead(b), NSWorkspace.shared.isVoiceOverEnabled {
            Log.info("start: \(b) is TurnOver's and VoiceOver is on; handing over in a second")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                Log.info("start: the hand-over step runs (self \(self == nil ? "gone" : "here"))")
                self?.lead.handOver(voiceOverOn: false)
            }
        } else if !config.applications.swapWithVoiceOver, !lead.suspended {
            // Neither reader changes the other: TurnOver comes on as it starts, VoiceOver stays as it is (22 Oct 2026).
            Log.info("start: TurnOver on without a hand-over (the swap is off)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.activate() }
        } else {
            Log.info("start: no hand-over at launch (front \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"), VoiceOver \(NSWorkspace.shared.isVoiceOverEnabled ? "on" : "off"))")
        }
    }

    /// Until Input Monitoring is granted, VoiceOver keeps every application. Look every two seconds; when the user
    /// turns it on in System Settings, say so and take over where TurnOver should, with no restart (a tester's
    /// Mac, 5 Oct 2026: granted later, TurnOver went on leaving everything to VoiceOver).
    private var inputTimer: Timer?
    private func watchForInputMonitoring() {
        guard !InputAccess.granted else { return }
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
            Speech.speakMessage("Input Monitoring is on. TurnOver is ready.")
            self.keyboard.reopenKeyboardWatch()   // the keyboard watch opens again, now allowed
            self.lead.inputMonitoringGranted()
        } }
    }

    static func explainInputMonitoring() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "One more permission: Input Monitoring"
        alert.informativeText = "TurnOver needs Input Monitoring to hear the TurnOver key and to take over from VoiceOver. Choose Open Settings, find TurnOver in the Input Monitoring list, and turn it on. TurnOver notices by itself and says when it is ready."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
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
    private func watchForVoiceOverGone() {
        voiceOverGoneTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The other way round: VoiceOver on and running while TurnOver still leads. macOS's change notice never
                // came for a tester (15 Oct 2026: he turned VoiceOver on by hand, TurnOver kept the keys, and
                // only Activity Monitor could stop it). Two looks, 2 s apart, so a hand-over in progress isn't mistaken.
                if NSWorkspace.shared.isVoiceOverEnabled, HandOver.voiceOverRunning, self.active {
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
                guard !self.active else { return }
                Log.warning("VoiceOver: macOS says it's on but it isn't running (crashed or stopped); TurnOver speaks")
                self.activate()
                Speech.speakMessage("VoiceOver stopped. TurnOver is speaking.")
            }
        }
    }

    /// The first report of VoiceOver's state is TurnOver starting, not a change by hand: the swap setting does not apply to it.
    private var sawVoiceOverState = false
    private func voiceOverChanged(_ on: Bool) {
        HandOver.newChoice()   // VoiceOver turned on or off, by hand too: a recovery's late fallback stands down
        Log.info("VoiceOver is \(on ? "on" : "off")")
        let starting = !sawVoiceOverState
        sawVoiceOverState = true
        defer { refreshWindowsLayer() }
        lead.voiceOverChanged(on: on)
        // Screen reader behaviour (22 Oct 2026): the swap is a setting. Off, VoiceOver's key changes nothing of TurnOver's.
        // VoiceOver going off ends any yielding, whatever the swap setting says.
        if !on { lead.yieldedToVoiceOverByHand = false }
        guard config.applications.swapWithVoiceOver || starting else {
            Log.info("VoiceOver \(on ? "on" : "off"); TurnOver stays as it is (the swap is off)")
            return
        }
        // Only a change made by hand counts as yielding: a hand-over TurnOver posted itself (the lock screen) does not.
        if on, !starting, !lead.isOurChange { lead.yieldedToVoiceOverByHand = true }
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
        if config.general.windowsKeys, config.general.keysWhereVoiceOverReads, !active, !lead.suspended, InputAccess.granted, NSWorkspace.shared.isVoiceOverEnabled {
            WindowsKeyLayer.shared.start()
        } else {
            WindowsKeyLayer.shared.stop()
        }
    }

    private func activate() {
        guard !active else { return }
        active = true
        WindowsKeyLayer.shared.stop()
        Watchdog.shared.active = true
        KeyboardHandler.bypass = false
        Core.activate()
        if !InputAccess.granted, InputAccess.askOnce() {
            Speech.speakMessage("TurnOver needs Input Monitoring for its keys. Opening System Settings, where VoiceOver will read: turn TurnOver on in the list.")
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") { NSWorkspace.shared.open(url) }
        }
        keyboard.start()
        SecureInputWatch.start()
        ScreenCurtain.apply()
        // Started by Command+Control+T: TurnOver Key has just said "TurnOver on"; the first take-over is not said again.
        // At launch TurnOver names itself ("TurnOver on"); later take-overs say the usual "TurnOver on" or play the chime.
        let atLaunch = Date().timeIntervalSince(launchedAt) < 10
        if let words = LeadWatcher.nextTakeoverWords { LeadWatcher.nextTakeoverWords = nil; Speech.speakMessage(words) }   // a mode's name, once
        else if config.general.handOverNothing { if atLaunch { announcedAtLaunch = false } }   // nothing, by choice
        else if announcedAtLaunch, atLaunch { announcedAtLaunch = false; Speech.speakMessage(Edition.editionName) }
        else if atLaunch { Speech.speakMessage("\(Edition.editionName) on") }
        else if config.general.handOverChimes { Tones.takeOver() } else { Speech.speakMessage("TurnOver on") }
    }

    /// An Activity left by a build before 18 Oct 2026 comes out, once: it kept VoiceOver's speech off in TurnOver's apps,
    /// password fields included.
    private func removeOldActivity() {
        guard ActivityFlow.shared.marker.installed else { return }
        Log.info("start: an Activity from an earlier build; taking it out")
        // Said first: VoiceOver Utility comes forward for about ten seconds and drives itself (an update from build
        // 19 or earlier; it was silent, and looked like something going wrong).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            Speech.speakMessage("Tidying up VoiceOver's settings from an earlier TurnOver. VoiceOver Utility opens and closes by itself; a moment.")
            ActivityFlow.shared.set(apps: nil) { text in Log.info("activity removed: \(text)"); Speech.speakMessage("Done.") }
        }
    }
    /// Quit from the menu: TurnOver steps back first, then goes.
    func quitRestoringVoiceOver() {
        lead.suspended = true
        deactivate()
        NSApp.terminate(nil)
    }

    /// Quitting: the tap and the watchdog go first, before VoiceOver is turned on. The tap stayed up through the
    /// hand-over and swallowed keys for up to 4 s at a menu quit (code review, 16 Oct 2026).
    func shutDown() {
        Watchdog.shared.active = false
        keyboard.stop()
        Log.info("quit: the keyboard tap stopped")
    }

    private func deactivate() {
        SecureInputWatch.stop()
        Watchdog.shared.active = false
        if active {
            active = false
            // The falling chime as VoiceOver takes over (words would collide with VoiceOver's own "VoiceOver on").
            if config.general.handOverChimes, !config.general.handOverNothing { Tones.handBack() }
            // Nothing of TurnOver's may keep the keys once VoiceOver leads: its menu, if open, closes.
            if TurnOverMenu.shared.isOpen { TurnOverMenu.shared.close() }
            keyboard.stop()
            Core.deactivate()
            refreshWindowsLayer()
            ScreenCurtain.off()   // VoiceOver's own takes over (its setting stays as the user left it)
        }
    }
}
