// SPDX-License-Identifier: GPL-3.0-or-later
// The rising tide: TurnOver leads in the applications on its list, VoiceOver in
// the rest, and the hand-over happens by itself as the front application
// changes (NVDA's sleep mode, the other way round). Always awake, even while
// VoiceOver is on: it needs only the application-switch notifications.
//
// Caps+V pins the current application to VoiceOver; turning VoiceOver off by
// hand while in an application pins it to TurnOver. Pins last until TurnOver quits.
// Every hand-over is timed in the log, because VoiceOver's own start-up is the
// cost of this design and the owner should know what it is.
import Foundation
import AppKit
import IOKit.hid
import Carbon.HIToolbox   // IsSecureEventInputEnabled
import TurnOverCore

final class LeadWatcher {
    private var token: NSObjectProtocol?
    private var pins: [String: Bool] = [:]
    private var warnedNoInput = false          // bundle → true means TurnOver leads
    private var ourChangeUntil = Date.distantPast
    /// Whether a VoiceOver change arriving now is TurnOver's own (a hand-over it posted, within its window), not the hand's.
    var isOurChange: Bool { Date() < ourChangeUntil }
    private var lastHandOverAt = Date.distantPast
    private var postedAt: Date?
    private var wantedOn: Bool?

    func start() {
        token = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.appActivated(app) }
        }
        // The app in front as TurnOver starts: started over Claude with VoiceOver off (after a crash), it left VoiceOver
        // off, as it only acted on a switch (4 Oct 2026). Look once, when the start-up has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in
            if let front = NSWorkspace.shared.frontmostApplication { self?.appActivated(front) }
        }
        Log.info("lead watcher: TurnOver leads in \(config.applications.leadBundles.joined(separator: ", "))\(config.applications.leadEverywhereElse ? " (and everywhere else)" : "")")
        watchSleepAndLock()
    }

    // MARK: Sleep and the lock screen
    // TurnOver cannot read the login window: if the Mac sleeps or locks while TurnOver leads, VoiceOver is off and
    // the password prompt has no speech at all (6 Oct 2026). VoiceOver comes on first; once unlocked, the app
    // in front decides again.

    private(set) var locked = false
    private var sleepTokens: [NSObjectProtocol] = []

    private func watchSleepAndLock() {
        let ws = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()
        sleepTokens.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.goingAway("sleep") } })
        sleepTokens.append(ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.goingAway("display sleep") } })
        sleepTokens.append(ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.goingAway("user switch") } })
        sleepTokens.append(dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.goingAway("lock") } })
        sleepTokens.append(dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.back("unlocked") } })
        sleepTokens.append(ws.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.back("session active") } })
        // The display waking without a lock (no unlock will come): back at once, unless the lock screen is up.
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            sleepTokens.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if !Self.screenIsLocked { self?.back("woke, not locked") } }
            })
        }
    }

    static var screenIsLocked: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Bool) ?? (d["CGSSessionScreenIsLocked"] as? Int).map { $0 != 0 } ?? false
    }

    private func goingAway(_ why: String) {
        locked = true
        Watchdog.shared.noteAsleepOrLocked()
        guard !NSWorkspace.shared.isVoiceOverEnabled else { Log.info("lead watcher: \(why); VoiceOver already on"); return }
        Log.info("lead watcher: \(why); VoiceOver on for the lock screen")
        handOver(voiceOverOn: true)
    }

    private func back(_ why: String) {
        Watchdog.shared.noteAwake()
        guard locked else { return }
        locked = false
        initialTakeOverPending = true   // the lock gave VoiceOver the Mac; the app in front is taken again once (22 Oct 2026)
        Log.info("lead watcher: \(why); the app in front decides again once secure input is off")
        // The lock screen's password field turns on secure input, and it stays on for a few seconds after the unlock.
        // While it is on, TurnOver's key tap gets only the modifiers, never a key: handed over at once, TurnOver said
        // "Claude" and then heard none of the user's keys for six seconds (10 Oct 2026). VoiceOver, privileged, still
        // hears them, so it keeps the Mac until secure input is off (up to 15 s), then the app in front decides.
        let started = Date()
        func decideWhenFree() {
            let secure = IsSecureEventInputEnabled()
            if secure, Date().timeIntervalSince(started) < 15 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { decideWhenFree() }
                return
            }
            Log.info("lead watcher: secure input \(secure ? "still on after 15 s" : "off") \(Int(Date().timeIntervalSince(started) * 1000)) ms after \(why)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                if let front = NSWorkspace.shared.frontmostApplication { self?.appActivated(front) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { decideWhenFree() }
    }

    /// Input Monitoring has just been granted: look at the application in front again.
    func inputMonitoringGranted() {
        warnedNoInput = false
        initialTakeOverPending = true   // the take-over that waited for the permission
        if let front = NSWorkspace.shared.frontmostApplication { appActivated(front) }
    }

    /// Does TurnOver lead in this application?
    /// TurnOver quitting from its menu (quitRestoringVoiceOver): it takes no app back on the way out.
    var suspended = false
    /// VoiceOver turned on by hand while TurnOver read: TurnOver stepped back by the swap setting and
    /// does not take the next app by itself. Cleared when VoiceOver goes off or TurnOver is turned on by its key.
    var yieldedToVoiceOverByHand = false
    /// Without readers per app, TurnOver takes the app in front once: at launch, and again once Input Monitoring is
    /// granted. After that an app change changes nothing; a hand-over to VoiceOver by its command stands.
    var initialTakeOverPending = true
    func shouldLead(_ bundle: String) -> Bool {
        if suspended { return false }
        // A direct app: TurnOver's key tap sends its keys, so TurnOver leads (and says nothing there).
        if config.applications.directApps.contains(bundle) { return InputAccess.granted }
        if bundle == Bundle.main.bundleIdentifier { return false }
        // TurnOver's own Settings window is always TurnOver's to read (18 Oct 2026).
        if bundle == "com.turnover.settings" { return !suspended }
        // VoiceOver Utility is VoiceOver's own: TurnOver taking it muted VoiceOver for every app sharing its mute
        // (18 Oct 2026).
        if bundle == "com.apple.VoiceOverUtility" { return false }
        // Without Input Monitoring TurnOver cannot take its keys: leading would leave a reader that cannot be driven.
        // VoiceOver keeps every application until it is granted (E11, 4 Oct 2026).
        guard InputAccess.granted else {
            if !warnedNoInput { warnedNoInput = true; Log.error("lead watcher: no Input Monitoring; VoiceOver keeps every application") }
            return false
        }
        // TurnOver leads only where it is supported; VoiceOver has the rest (Edition).
        // A game (Steam, a Windows game in a CrossOver bottle) is TurnOver's while game speech is on (Games.swift).
        // VoiceOver everywhere: TurnOver steps back from every app (Command Control Comma, A).
        // The rules themselves are LeadPolicy.leads (pure, with a table test); this gathers what they need.
        return LeadPolicy.leads(.init(gameLeads: Games.leads(bundle), pin: pins[bundle],
                                      leadMode: config.applications.effectiveLeadMode, supported: Edition.supports(bundle),
                                      inVoiceOverList: config.applications.effectiveVoiceOverBundles.contains(bundle), inLeadList: config.applications.leadBundles.contains(bundle)))
    }

    func look(at app: NSRunningApplication) { appActivated(app) }
    private func appActivated(_ app: NSRunningApplication) {
        // TurnOver's own windows (the update window, alerts) are VoiceOver's: TurnOver does not read itself. A menu-bar
        // app is not a regular one, so it is let through here by name; it went unread (5 Oct 2026, the update window).
        let own = app.bundleIdentifier == Bundle.main.bundleIdentifier
        // A direct app (Command Control Comma, D): its keys straight to it, TurnOver quiet; TurnOver must lead there, as
        // its key tap is what sends them. Any other app clears it.
        let directKey = InputManager.directKey(bundle: app.bundleIdentifier, name: app.localizedName)
        let direct = app.activationPolicy == .regular && config.applications.directApps.contains(directKey)
        InputManager.directPid = direct && !suspended ? app.processIdentifier : nil
        if direct { Log.info("lead watcher: \(app.localizedName ?? directKey) is direct: its keys go straight to it") }
        // A Wine program has no bundle at all (CrossOver runs it through a bare loader stub); game speech gives it a key.
        // A direct program without one (a Godot game run from Terminal) is known by its name.
        // Without readers per app TurnOver reads everywhere, so the first take-over (at launch, or once Input Monitoring
        // is granted) still happens; after it, apps changing hands is only with the switch on (a second reviewer, 22 Oct 2026).
        // Not after VoiceOver was turned on by hand (the swap gave it the Mac): that choice stands until VoiceOver goes
        // off again or TurnOver is turned on by its own key (a second reviewer, 22 Oct 2026).
        // And never by turning VoiceOver off when the swap is off: then TurnOver's own key is the only way it comes on.
        let mayTurnVoiceOverOff = config.applications.swapWithVoiceOver
        // And never while TurnOver is off by its own key (suspended): an app change then changes nothing.
        let firstTakeOver = !config.applications.perAppReaders && initialTakeOverPending && !suspended && !turnOverActive() && !yieldedToVoiceOverByHand && mayTurnVoiceOverOff
        guard config.applications.switchesAsAppsChange || firstTakeOver, app.activationPolicy == .regular || own,
              let bundle = app.bundleIdentifier ?? Games.leadKey(for: app) ?? (direct ? directKey : nil), bundle != "com.apple.VoiceOver" else { return }
        // TurnOver in front with no window of its own showing: a moment's activation macOS reports as a window
        // changes hands (Finder's Command Up and Command Down), not the user moving. Handing over on it put
        // VoiceOver on for a few seconds, which felt like a crash (a tester, 8 Oct 2026).
        if own, !NSApp.windows.contains(where: { $0.isVisible }) { Log.io("lead watcher: TurnOver in front with no window; ignored"); return }
        // TurnOver's own switch to wake an app's accessibility (AppWake): not the user moving, no hand-over.
        guard Date() > AppWake.nudgingUntil else { return }
        // Locked or asleep: VoiceOver keeps the screen until it is unlocked.
        guard !locked else { return }
        let lead = shouldLead(bundle)
        let reading = !NSWorkspace.shared.isVoiceOverEnabled
        guard lead != reading else { return }   // already the right reader
        guard Date().timeIntervalSince(lastHandOverAt) > 1.5 else {
            // Not now, but not never: once the hand-over settles, look at whatever is in front then. Left alone for
            // good, VoiceOver stayed off in Claude (which TurnOver does not read) until the next switch (4 Oct 2026).
            Log.io("lead watcher: \(app.localizedName ?? bundle) activated during a hand-over; checking again when it settles")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self, let front = NSWorkspace.shared.frontmostApplication else { return }
                self.appActivated(front)
            }
            return
        }
        Log.info("lead watcher: \(app.localizedName ?? bundle) is \(lead ? "TurnOver's" : "VoiceOver's"); turning VoiceOver \(lead ? "off" : "on")")
        if lead { initialTakeOverPending = false }
        handOver(voiceOverOn: !lead)
    }

    /// Post the toggle and time it: the flag flip, and VoiceOver's process appearing or going. Nothing here waits on
    /// the main thread: each wait is a short check repeated by timer (it used to hold the main thread for up to 2 s
    /// of sleeping and 8 s of nested run loop, events and scripts running inside it: E6 audit, 4 Oct 2026). A newer
    /// hand-over cancels the waits of an older one.
    /// TurnOver's own active state, from the app.
    var turnOverActive: () -> Bool = { false }
    func handOver(voiceOverOn: Bool) {
        Log.info("hand-over: asked for VoiceOver \(voiceOverOn ? "on" : "off")")
        if Uninstaller.running && !voiceOverOn { return }   // uninstalling: VoiceOver stays on
        if !voiceOverOn { ScreenCurtain.noteVoiceOverCurtain() }   // before VoiceOver goes, and its curtain with it
        lastHandOverAt = Date()
        ourChangeUntil = Date().addingTimeInterval(3)
        postedAt = Date()
        wantedOn = voiceOverOn
        handOverGeneration += 1
        HandOver.newChoice()   // a recovery's late fallback stands down
        let generation = handOverGeneration
        let t0 = Date()
        let isOn = { NSWorkspace.shared.isVoiceOverEnabled }
        let running = { HandOver.voiceOverRunning }
        // VoiceOver wanted, its flag on and no VoiceOver (crashed, or quit by script): opened, since there is nothing to
        // wait for and the toggle would turn the flag off (a code review, 25 Oct 2026).
        if voiceOverOn, isOn(), !running() {
            Log.info("hand-over: VoiceOver's flag is on but it isn't running; opening it")
            HandOver.openVoiceOver("hand-over")
            return
        }
        // 1. VoiceOver wholly on or wholly off before the toggle (toggling mid-change could leave it off).
        poll(generation, every: 0.05, upTo: 2, until: { isOn() == running() }) { [weak self] settled in
            guard let self else { return }
            if isOn() == voiceOverOn { Log.info("hand-over: VoiceOver already \(voiceOverOn ? "on" : "off")"); return }
            // Toggled mid-change, VoiceOver can end up off for good: left for the next activation to try again.
            guard settled else { Log.warning("hand-over: VoiceOver still changing after 2 s; not toggled (next activation tries again)"); return }
            self.ourChangeUntil = Date().addingTimeInterval(3)   // the change about to come is ours, not a pin by hand
            // On by opening VoiceOver.app, which works when its shortcut doesn't (25 Oct 2026); off by the shortcut.
            if voiceOverOn { HandOver.openVoiceOver("hand-over") } else { HandOver.postToggle() }
            // 2. The flag flips.
            self.poll(generation, every: 0.05, upTo: 2, until: { isOn() == voiceOverOn }) { [weak self] flipped in
                guard let self else { return }
                let flagMs = Int(Date().timeIntervalSince(t0) * 1000)
                if !flipped {
                    // Ignored: VoiceOver was still shutting down (or starting) from the last switch, and a toggle then
                    // is swallowed; VoiceOver stayed off in Claude for 6 s (4 Oct 2026). Let it finish, then once more.
                    Log.info("hand-over: VoiceOver did not go \(voiceOverOn ? "on" : "off"); waiting for it to settle, then again")
                    self.poll(generation, every: 0.1, upTo: 6, until: { isOn() == running() }) { settled in
                        guard isOn() != voiceOverOn else { return }
                        guard settled else { Log.warning("hand-over: VoiceOver still changing after 6 s more; not toggled again"); return }
                        self.ourChangeUntil = Date().addingTimeInterval(3)   // (a late second toggle was read as the user's choice and pinned the app, 8 Oct 2026)
                        if voiceOverOn { HandOver.openVoiceOver("hand-over, again") } else { HandOver.postToggle() }
                        self.poll(generation, every: 0.05, upTo: 2, until: { isOn() == voiceOverOn }) { again in
                            Log.info("hand-over: second toggle \(again ? "worked" : "did not work either"): VoiceOver \(isOn() ? "on" : "off")")
                        }
                    }
                    return
                }
                // 3. VoiceOver's process appears or goes (timing only).
                self.poll(generation, every: 0.05, upTo: 6, until: { running() == voiceOverOn }) { seen in
                    let processMs = Int(Date().timeIntervalSince(t0) * 1000)
                    Log.info("hand-over timing: VoiceOver \(voiceOverOn ? "on" : "off"): flag \(flipped ? "flipped" : "did not flip") in \(flagMs) ms, process \(seen ? "\(processMs) ms" : "not observed within 6 s")")
                }
            }
        }
    }
    private var handOverGeneration = 0

    /// Check `condition` every `interval` on the main queue, up to `limit` seconds, then call `done` with whether it
    /// came true; nothing if a newer hand-over has started meanwhile.
    private func poll(_ generation: Int, every interval: Double, upTo limit: Double, until condition: @escaping () -> Bool, then done: @escaping (Bool) -> Void) {
        let end = Date().addingTimeInterval(limit)
        func check() {
            guard generation == handOverGeneration else { return }
            if condition() { done(true); return }
            if Date() >= end { done(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + interval) { check() }
        }
        check()
    }

    /// Each change of reader by hand (a mode, Switch reader): a hand-over or word queued for later is dropped when a
    /// newer change has come since (code review, 13 Oct: A pressed twice, or Command Tab within the second, turned
    /// VoiceOver on over TurnOver).
    private var choiceGeneration = 0

    /// Said by whichever reader is talking: TurnOver's speech is muted while VoiceOver is on, so then it goes through
    /// VoiceOver as an accessibility announcement (the new mode was silent when VoiceOver kept reading).
    private func say(_ text: String) { VoiceOverSpeak.say(text) }   // VoiceOver says it itself where it leads (15 Oct 2026)

    /// Says `text` once TurnOver is up (it can't speak until VoiceOver has gone), unless a newer choice came since.
    private func sayWhenTurnOverIsUp(_ text: String, generation: Int) {
        let end = Date().addingTimeInterval(4)
        func check() {
            guard generation == choiceGeneration else { return }
            if !NSWorkspace.shared.isVoiceOverEnabled {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    if generation == self?.choiceGeneration { Speech.speakMessage(text) }
                }
                return
            }
            if Date() < end { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { check() } }
        }
        check()
    }

    /// After `delay`, gives the app in front then (not the one in front now) to its reader, if no newer choice came.
    private func settleReader(after delay: Double, generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.choiceGeneration else { return }
            // The menu still open: wait for it (VoiceOver coming on mid-menu silenced it).
            if TurnOverMenu.shared.isOpen { self.settleReader(after: 0.3, generation: generation); return }
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            let turnOver = self.shouldLead(front)
            let turnOverReading = !NSWorkspace.shared.isVoiceOverEnabled
            if turnOver != turnOverReading { self.handOver(voiceOverOn: !turnOver) }
        }
    }

    /// Command Control Comma, A: the next of the three modes, said, saved, and the app in front given to its reader.
    /// Words for TurnOver's next take-over instead of "TurnOver on" (a mode change): consumed by the app.
    static var nextTakeoverWords: String?

    func cycleMode() {
        let modes = Config.Applications.leadModes
        let next = modes[((modes.firstIndex(of: config.applications.leadMode) ?? 0) + 1) % modes.count]
        config.applications.leadMode = next
        pins.removeAll()   // the hand choices of the moment belong to the mode that was
        config.save()
        Log.info("lead mode: \(next)")
        choiceGeneration += 1
        let generation = choiceGeneration
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if shouldLead(front) {
            // TurnOver takes over for the new mode: the mode's name in place of "TurnOver on", then the app as usual.
            // Said after it, the name ran into "TurnOver on" and the app ("a bit of a mouthful", 15 Oct 2026).
            if NSWorkspace.shared.isVoiceOverEnabled { Self.nextTakeoverWords = Config.Applications.leadModeName(next) }
            handOver(voiceOverOn: false)
            if !NSWorkspace.shared.isVoiceOverEnabled { sayWhenTurnOverIsUp(Config.Applications.leadModeName(next), generation: generation) }
        } else {
            say(Config.Applications.leadModeName(next))
            settleReader(after: 1.2, generation: generation)
        }
    }

    /// The mode changed in the menu: the hand choices go, and the app in front gets its reader once the menu closes.
    func refreshAfterModeChange() {
        pins.removeAll()
        choiceGeneration += 1
        settleReader(after: 1.0, generation: choiceGeneration)
    }

    /// Command Control Shift T: the app in front goes to the other reader, and stays there (saved, as the Applications
    /// menu does). 10 Oct 2026: "rather than having to dig through menus". Works while either reader leads.
    /// `toTurnOver`: who should read from now on, when the caller knows who reads now (the layer key: VoiceOver was
    /// talking, so TurnOver; TurnOver was, so VoiceOver). Without it, the saved list decides, which is wrong when
    /// automatic switching is off: Safari was TurnOver's in the list but VoiceOver was reading it, and T handed it
    /// "back" to VoiceOver (a tester, 12 Oct 2026).
    /// Command Control Comma, D: the app in front direct, or not. Saved, so it stays direct next time.
    func toggleDirect() {
        guard let app = NSWorkspace.shared.frontmostApplication, app.activationPolicy == .regular, app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            Log.info("direct: nothing in front to make direct"); Tones.edge(); return
        }
        let key = InputManager.directKey(bundle: app.bundleIdentifier, name: app.localizedName)
        let name = app.localizedName ?? key
        let on = !config.applications.directApps.contains(key)
        config.applications.directApps.removeAll { $0 == key }
        if on { config.applications.directApps.append(key) }
        config.save()
        Log.info("direct: \(name) \(on ? "on" : "off")")
        InputManager.directPid = on ? app.processIdentifier : nil
        appActivated(app)   // TurnOver takes the app if it wasn't reading it (its tap sends the keys)
        // Said by TurnOver, which leads here now (VoiceOver is kept quiet), once the take-over has been said.
        let words = on ? "Direct. Keys go straight to \(name), and TurnOver stays quiet here. Command Control Comma, then D, to leave."
                       : "Direct off. TurnOver reads \(name) again."
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            if self?.turnOverActive() == true { Speech.speakMessage(words) } else { self?.say(words) }
        }
    }

    func switchCurrent(toTurnOver wanted: Bool? = nil) {
        // Without readers per app there is nothing to give an app to: TurnOver is on or off (22 Oct 2026).
        guard config.applications.perAppReaders else {
            Log.info("switch reader: readers per app are off; nothing to switch")
            Speech.speakMessage("Readers per app are off: TurnOver reads everywhere while it is on. Command Control Period turns it off and on; Settings, Experimental, turns readers per app on.")
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication, app.activationPolicy == .regular,
              let bundle = app.bundleIdentifier ?? Games.leadKey(for: app), bundle != Bundle.main.bundleIdentifier else {
            Log.info("switch reader: nothing to switch in front"); Tones.edge(); return
        }
        let name = app.localizedName ?? bundle
        guard !locked else { return }
        guard InputAccess.granted else { Log.info("switch reader: no Input Monitoring"); Tones.edge(); return }
        let toTurnOver = wanted ?? !shouldLead(bundle)
        // Saved in the mode's own list: TurnOver's apps, or (everywhere) the apps VoiceOver keeps.
        if config.applications.leadMode == "voiceover" {
            say("VoiceOver reads everywhere. Command Control Comma, then A, to change that.")
            return
        }
        if config.applications.leadMode == "everywhere" {
            config.applications.voiceOverBundles.removeAll { $0 == bundle }
            if !toTurnOver { config.applications.voiceOverBundles.append(bundle) }
        } else {
            config.applications.leadBundles.removeAll { $0 == bundle }
            if toTurnOver { config.applications.leadBundles.append(bundle) }
        }
        pins[bundle] = nil
        if shouldLead(bundle) != toTurnOver { pins[bundle] = toTurnOver }   // a game, or a rule the list does not decide
        config.save()
        Log.info("switch reader: \(name) is now \(toTurnOver ? "TurnOver's" : "VoiceOver's") (saved)")
        choiceGeneration += 1
        if toTurnOver {
            handOver(voiceOverOn: false)
            sayWhenTurnOverIsUp("TurnOver leads in \(name)", generation: choiceGeneration)
        } else {
            Speech.speakMessage("VoiceOver leads in \(name)")
            settleReader(after: 0.8, generation: choiceGeneration)
        }
    }

    /// The app in front to VoiceOver for some seconds, then back to TurnOver if it is still in front and still TurnOver's
    /// (Core.lendToVoiceOver: Excel builds its grid only for VoiceOver).
    func lend(seconds: TimeInterval) {
        guard let app = NSWorkspace.shared.frontmostApplication, let b = app.bundleIdentifier, shouldLead(b) else { return }
        Log.info("lead watcher: lending \(app.localizedName ?? b) to VoiceOver for \(seconds) s")
        handOver(voiceOverOn: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 2) { [weak self] in
            guard let self, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier, self.shouldLead(b) else { return }
            Log.info("lead watcher: \(app.localizedName ?? b) back to TurnOver after the loan")
            self.handOver(voiceOverOn: false)
        }
    }

    /// The user pressed Caps+V: VoiceOver leads in this application from now on.
    func pinCurrentToVoiceOver() {
        if let b = NSWorkspace.shared.frontmostApplication?.bundleIdentifier { pins[b] = false; Log.info("lead watcher: \(b) pinned to VoiceOver") }
        handOver(voiceOverOn: true)
    }

    /// VoiceOver's state changed (from the app's observation). A change we did not post is the user's choice: pin it.
    /// VoiceOver's state as TurnOver starts is not a choice the user made: after a quit or a watchdog restart
    /// VoiceOver is on (TurnOver turns it on as it goes), and reading that as "pinned to VoiceOver by hand" left Mail
    /// with VoiceOver (3 Oct 2026). Only changes after the first few seconds count.
    private let startedAt = Date()

    func voiceOverChanged(on: Bool) {
        guard Date().timeIntervalSince(startedAt) > 3 else { return }
        if let t = Watchdog.shared.lastTrip, Date().timeIntervalSince(t) < 30 { return }
        guard Date() > ourChangeUntil, config.applications.switchesAsAppsChange else { return }
        guard let app = NSWorkspace.shared.frontmostApplication, app.activationPolicy == .regular, let b = app.bundleIdentifier, b != Bundle.main.bundleIdentifier else { return }
        if shouldLead(b) == on {   // the user went against the list for this app
            pins[b] = !on
            Log.info("lead watcher: \(app.localizedName ?? b) pinned to \(on ? "VoiceOver" : "TurnOver") by hand")
        }
    }
}
