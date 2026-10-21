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
            // A password field, anywhere (macOS's secure input on): VoiceOver's entirely, as macOS's own prompts are
            // (18 Oct 2026: "voiceover has to remain on as I want it dealing with all security"). TurnOver
            // steps aside, keys and all, and comes back when secure input goes off. Watched here, not by the
            // reader's own watch, which stops while TurnOver is aside.
            // A password field that doesn't turn secure input on (some apps' own fields) counts the same: TurnOver's
            // focus on one steps it aside, and it comes back once the system's focus has left it (a code review on
            // 18 Oct 2026: the guide promised VoiceOver in every password field).
            secureTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in MainActor.assumeIsolated {
                guard let self else { return }
                let inPasswordField = self.active ? API.focusObject?.role == .passwordEdit
                    : self.secureSteppedAside && Self.systemFocusIsPasswordField()
                let on = IsSecureEventInputEnabled() || inPasswordField
                guard on != self.secureWasOn else { return }
                self.secureWasOn = on
                // Only with VoiceOver on to take over: with it off, TurnOver keeps reading (it never echoes a secret field).
                if on, self.active, NSWorkspace.shared.isVoiceOverEnabled {
                    self.secureSteppedAside = true
                    Log.info("secure input on: VoiceOver's; TurnOver steps aside")
                    self.deactivate()
                } else if !on, self.secureSteppedAside {
                    self.secureSteppedAside = false
                    Log.info("secure input off: TurnOver back if the app in front is its")
                    if let front = NSWorkspace.shared.frontmostApplication { self.lead.look(at: front) }
                }
            } }
        }
        TurnOverMenu.shared.quit = { [weak self] in self?.quitRestoringVoiceOver() ?? NSApp.terminate(nil) }
        // macOS's prompts (passwords, Touch ID, "Allow") to VoiceOver while they're open; TurnOver back after.
        if Coexist.on {
            SystemPrompts.shared.onPromptChange = { [weak self] open in
                guard let self else { return }
                if open {
                    guard self.active, NSWorkspace.shared.isVoiceOverEnabled else { return }
                    self.promptSteppedAside = true
                    Log.info("system prompt: VoiceOver's; TurnOver steps aside")
                    self.deactivate()
                } else if self.promptSteppedAside {
                    self.promptSteppedAside = false
                    Log.info("system prompt closed; TurnOver back if the app in front is its")
                    if let front = NSWorkspace.shared.frontmostApplication { self.lead.look(at: front) }
                }
            }
        }
        lead.onCoexistLead = { [weak self] turnOver in if turnOver { self?.activate() } else { self?.deactivate() } }
        MenuAnywhere.shared.turnOverActive = { [weak self] in self?.active ?? false }
        Speech.player?.onQueueStuck = { seconds in Watchdog.shared.speechStuck(for: seconds) }
        QuickNavWatch.shared.turnOverActive = { [weak self] in self?.active ?? false }
        QuickNavWatch.shared.start()
        ArrowQuickNav.startInStep()
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
        MenuAnywhere.shared.cycleLeadMode = { [weak self] in self?.lead.cycleMode() }
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
        voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled, options: [.new]) { [weak self] ws, _ in
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
        // Ordinary launches get the startup sound with either reader. The Key helper already played its bell
        // for --announced launches; use the original argument because activation consumes announcedAtLaunch.
        if !CommandLine.arguments.contains("--announced") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { Tones.startup() }
        }
        watchForInputMonitoring()
        // Synchronize the existing VoiceOver state without treating it as the user's manual reader choice.
        voiceOverChanged(NSWorkspace.shared.isVoiceOverEnabled, initial: true)
        // Launching TurnOver selects the configured reader even when switching readers between apps is off.
        // The watcher rechecks the app in front, and ignores this if a reader has already been chosen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.lead.selectInitialReader()
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
                if !Coexist.on, NSWorkspace.shared.isVoiceOverEnabled, HandOver.voiceOverRunning, self.active {
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
                    Speech.speakMessage("VoiceOver stopped; starting it again.")
                    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Library/CoreServices/VoiceOver.app"), configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
                    return
                }
                guard !self.active else { return }
                Log.warning("VoiceOver: macOS says it's on but it isn't running (crashed or stopped); TurnOver speaks")
                self.activate()
                Speech.speakMessage("VoiceOver stopped. TurnOver is speaking.")
            }
        }
    }

    private func voiceOverChanged(_ on: Bool, initial: Bool = false) {
        Log.info("VoiceOver is \(on ? "on" : "off")")
        defer { refreshWindowsLayer() }
        // Coexisting: VoiceOver off means TurnOver reads every app (LeadWatcher.shouldLead), on again means it goes back
        // to its own; the app in front is looked at afresh either way. (It stayed as it was, and with VoiceOver off the
        // apps that weren't TurnOver's were silent: 19 Oct 2026.)
        if Coexist.on {
            Log.info("coexist: VoiceOver \(on ? "on" : "off"); TurnOver reads \(on ? "its own apps" : "every app") now")
            if let front = NSWorkspace.shared.frontmostApplication { lead.look(at: front) }
            return
        }
        if !initial { lead.voiceOverChanged(on: on) }
        if on { deactivate() } else { activate() }
    }

    /// "Windows keys everywhere": the small key layer runs while VoiceOver leads (TurnOver's own layer does the same
    /// translations while TurnOver leads).
    private func refreshWindowsLayer() {
        // NVDA keys where VoiceOver reads (docs/KEYBOARD-STYLES-PLAN.md step 2, 19 Oct 2026; shelved since 6 Oct, back with
        // Windy folded in): on in a Windows-family style while TurnOver is running but not the reader of the app in
        // front. Off where TurnOver reads (its own tap has the keys) and when TurnOver is switched off.
        if config.general.windowsKeys, !active, !lead.suspended, InputAccess.granted, NSWorkspace.shared.isVoiceOverEnabled {
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
        else if config.general.handOverChimes { Tones.takeOver() } else { Speech.speakMessage("TurnOver on") }
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

    private var promptSteppedAside = false
    private var secureTimer: Timer?
    private var secureWasOn = false
    private var secureSteppedAside = false
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
                Speech.speakMessage("Tidying up VoiceOver's settings from an earlier TurnOver. VoiceOver Utility opens and closes by itself; a moment.")
                ActivityFlow.shared.set(apps: nil) { text in Log.info("activity removed: \(text)"); Speech.speakMessage("Done.") }
            }
        }
    }
    private func toggleCoexist() {
        if lead.suspended {
            lead.suspended = false
            Speech.speakMessage("TurnOver on")
            if let front = NSWorkspace.shared.frontmostApplication { lead.look(at: front) }
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
        Watchdog.shared.active = false
        keyboard.stop()
        if Coexist.on { VoiceOverTap.set(false, why: "quit") }
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
            if Coexist.on { VoiceOverTap.set(false, why: "TurnOver hands back") }
            Core.deactivate()
            refreshWindowsLayer()
            ScreenCurtain.off()   // VoiceOver's own takes over (its setting stays as the user left it)
        }
    }
}
