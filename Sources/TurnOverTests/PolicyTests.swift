// SPDX-License-Identifier: GPL-3.0-or-later
// The decisions that can leave a blind user with no reader, as tables: who leads, what the speech queue drops; and
// every recorded window read once (code review, 16 Oct 2026).
import Foundation
import AppKit
import ApplicationServices
import TurnOverCore
import TurnOverControl
import AXFixtures

func policyTests() {

    test("spoken lists: refreshing status items preserves the open list and cannot replace a newer list") {
        let menu = TurnOverMenu.shared
        let show = MenuItem(verbatim: "Show hidden items", .select {})
        let hidden = MenuItem(verbatim: "Revealed item", .action {})
        menu.openList(verbatim: "Status menus", items: [show])
        let generation = menu.listGeneration
        menu.refreshList(generation: generation, items: [show, hidden]) { _ in 1 }
        expect(menu.debugPosition?.title, "Revealed item", "announces the newly revealed item")
        expect(menu.debugPosition?.index, 1, "cursor moved to the revealed item")
        expect(menu.debugPosition?.count, 2, "both items are reachable")
        let other = MenuItem(verbatim: "Other item", .action {})
        menu.openList(verbatim: "Another list", items: [other])
        menu.refreshList(generation: generation, items: [show, hidden]) { _ in 1 }
        expect(menu.debugPosition?.title, "Other item", "stale refresh did not reopen the old list")
        expect(menu.debugPosition?.count, 1, "stale refresh did not replace the newer items")
        menu.close()
        menu.refreshList(generation: generation, items: [show, hidden]) { _ in 1 }
        expect(menu.isOpen, false, "an asynchronous refresh cannot reopen a closed list")
    }

    test("mode speech: complete readiness matrix selects only an exclusive ready reader") {
        for coexisting in [false, true] {
            for active in [false, true] {
                for enabled in [false, true] {
                    for running in [false, true] {
                        for known in [false, true] {
                            for silent in [false, true] {
                                func ready(_ reader: ModeSpeechPolicy.Reader, generation: Int = 7) -> Bool {
                                    ModeSpeechPolicy.canAnnounce(reader: reader, generation: generation, currentGeneration: 7,
                                                                coexisting: coexisting, turnOverActive: active,
                                                                voiceOverEnabled: enabled, voiceOverSilent: silent,
                                                                voiceOverRunning: running, voiceOverMuteKnown: known)
                                }
                                let expectedTurnOver = active && (coexisting || (!enabled && !running)) && (!running || (known && silent))
                                let expectedVoiceOver = enabled && running && !active && known && !silent
                                expect(ready(.turnOver), expectedTurnOver, "TurnOver requires activation and confirmed exclusive output")
                                expect(ready(.voiceOver), expectedVoiceOver, "VoiceOver requires running enabled unmuted output")
                                check(!(ready(.turnOver) && ready(.voiceOver)), "a mode never goes to both readers")
                                check(!ready(.turnOver, generation: 6), "an old TurnOver choice is discarded")
                                check(!ready(.voiceOver, generation: 6), "an old VoiceOver choice is discarded")
                            }
                        }
                    }
                }
            }
        }
    }
    test("mode delivery: foreground owner and readiness are checked again after settling") {
        var time = 0.0
        var queued: [(Double, @MainActor () -> Void)] = []
        var reader: ModeSpeechPolicy.Reader? = .voiceOver
        var current = true
        var output: [ModeSpeechPolicy.Reader] = []
        let delivery = ModeSpeechDelivery()
        delivery.announce("mode", now: { time }, schedule: { queued.append((time + $0, $1)) },
                          current: { current }, readyReader: { reader }, output: { _, r in output.append(r) })
        @MainActor func advance() {
            guard !queued.isEmpty else { Harness.fail("production delivery scheduled its continuation"); return }
            let next = queued.removeFirst()
            time = next.0
            next.1()
        }
        reader = nil
        advance()
        check(output.isEmpty, "readiness disappearing during the delay does not speak")
        reader = .turnOver
        advance()
        advance()
        check(output == [.turnOver], "the new foreground owner receives the pending words once")
        delivery.announce("old", now: { time }, schedule: { queued.append((time + $0, $1)) },
                          current: { current }, readyReader: { reader }, output: { _, r in output.append(r) })
        current = false
        advance()
        check(output.count == 1, "a newer choice retires delayed words")
        current = true
        reader = nil
        delivery.announce("timeout", now: { time }, schedule: { queued.append((time + $0, $1)) },
                          current: { current }, readyReader: { reader }, output: { _, r in output.append(r) })
        while !queued.isEmpty { advance() }
        check(output.count == 1, "unknown readiness expires without speaking")
    }
    test("mode delivery: TurnOver delivery reaches the real speech output gate") {
        let oldMode = Speech.mode
        let oldVoiceOver = Speech.voiceOverEnabledForOutput
        let oldOutput = Speech.outputTestDriver
        let oldEnqueue = Speech.enqueueTestDriver
        Speech.enqueueTestDriver = nil
        defer {
            Speech.mode = oldMode
            Speech.voiceOverEnabledForOutput = oldVoiceOver
            Speech.outputTestDriver = oldOutput
            Speech.enqueueTestDriver = oldEnqueue
        }
        Speech.mode = .talk
        Speech.voiceOverEnabledForOutput = { false }
        var spoken: [String] = []
        Speech.outputTestDriver = { text, _, completion in spoken.append(text); completion?(true) }
        var queued: [@MainActor () -> Void] = []
        let delivery = ModeSpeechDelivery()
        @MainActor func request(_ text: String) {
            delivery.announce(text, now: { 0 }, schedule: { _, action in queued.append(action) },
                              current: { true }, readyReader: { .turnOver },
                              output: { text, _ in Speech.speakMessage(text) })
            guard !queued.isEmpty else { Harness.fail("production delivery scheduled output"); return }
            queued.removeFirst()()
        }
        request("mode ready")
        check(spoken == ["mode ready"], "the shared delivery loop reaches output after the actual speech gates")
        Speech.mode = .off
        request("mode blocked")
        check(spoken == ["mode ready"], "speech off still blocks coordinator output")
    }
    test("mode speech: requested silence and a stale VoiceOver flag are not readiness") {
        check(!ModeSpeechPolicy.canAnnounce(reader: .voiceOver, generation: 1, currentGeneration: 1,
                                           coexisting: true, turnOverActive: false, voiceOverEnabled: true,
                                           voiceOverSilent: false, voiceOverRunning: false, voiceOverMuteKnown: true), "VoiceOver must be running")
        check(!ModeSpeechPolicy.canAnnounce(reader: .turnOver, generation: 1, currentGeneration: 1,
                                           coexisting: true, turnOverActive: true, voiceOverEnabled: true,
                                           voiceOverSilent: true, voiceOverRunning: true, voiceOverMuteKnown: false), "a request is not a mute acknowledgement")
    }
    test("mode speech: helper confirmation handles pipe cuts pid changes expiry and failures") {
        var confirmation = VoiceOverMuteConfirmation()
        confirmation.expect("a")
        _ = confirmation.consume(Data("status 123 o".utf8), now: 1)
        check(confirmation.value(pid: 123, wanted: true, now: 1) == nil, "a partial reply proves nothing")
        _ = confirmation.consume(Data("n a\nstatus 123 on a\n".utf8), now: 1)
        check(confirmation.value(pid: 123, wanted: true, now: 1) == true, "split and coalesced replies are parsed")
        check(confirmation.value(pid: 124, wanted: true, now: 1) == nil, "a restarted VoiceOver has no confirmation")
        check(confirmation.value(pid: 123, wanted: false, now: 1) == nil, "changed requests invalidate old replies")
        check(confirmation.value(pid: 123, wanted: true, now: 2) == nil, "old replies expire")
        _ = confirmation.consume(Data("off\n".utf8), now: 1)
        check(confirmation.value(pid: 123, wanted: true, now: 1) == nil, "lease expiry invalidates silence")
        _ = confirmation.consume(Data("status 123 off a\n".utf8), now: 2)
        check(confirmation.value(pid: 123, wanted: false, now: 2) == false, "unmuting also needs confirmation")
        confirmation.expect("b")
        _ = confirmation.consume(Data("status 123 on a\n".utf8), now: 2)
        check(confirmation.value(pid: 123, wanted: true, now: 2) == nil, "an older request cannot confirm a newer probe")
        confirmation.reset()
        check(confirmation.value(pid: 123, wanted: false, now: 2) == nil, "helper exit invalidates confirmation")
    }
    test("mode speech: executable wiring retains delayed delivery activation and layer cue") {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ file: String) -> String {
            let text = (try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)) ?? ""
            return text.components(separatedBy: "\n").map { line in
                String(line.components(separatedBy: "//").first ?? "")
            }.joined(separator: "\n")
        }
        let lead = source("Sources/TurnOver/LeadWatcher.swift")
        let output = source("Sources/TurnOver/LeadWatcherModeSpeech.swift")
        let app = source("Sources/TurnOver/TurnOverApp.swift")
        let menu = source("Sources/TurnOver/MenuAnywhere.swift")
        check(output.contains("modeDelivery.announce(text"), "production calls the tested delivery loop")
        check(output.contains("self?.readyModeReader(generation: generation)"), "production supplies live foreground readiness")
        check(lead.contains("let reader: ModeSpeechPolicy.Reader = shouldLead(front)"), "foreground app selects the receiving reader")
        check(lead.contains("self.sayModeWhenReady(voiceOverWords, generation: generation)"), "settled handback schedules the mode words")
        check(app.contains("MenuAnywhere.shared.cycleLeadMode =") && app.contains("self?.lead.cycleMode()"), "the actual layer callback reaches the mode change")
        check(menu.contains("cycleLeadMode?(); return"), "the claimed layer A key invokes its callback")
        check(app.contains("lead.announceTakeoverMode(words)"), "activation delivers the pending mode name")
        expect(menu.components(separatedBy: "announceClaimedLayer()").count - 1, 3,
               "both normal and Coexist layer paths call the cue owner")
        check(menu.contains("NSSound.beep()"), "the claimed layer retains its audible cue")
    }
    test("one app: the full reader, CoExist off unless turned on, plugins on unless turned off") {
        check(Edition.editionName == "TurnOver", "named TurnOver")
        check(Edition.includesPlugins == ((UserDefaults.standard.object(forKey: "plugins") as? Bool) ?? true), "plugins on unless the default turns them off")
        check(Coexist.wouldBeOn == ((UserDefaults.standard.object(forKey: "coexist") as? Bool) ?? false), "CoExist off unless turned on (experimental, 28 Oct 2026)")
        for app in Edition.supportedApps { check(app.bundle.contains("."), "\(app.name) has a bundle id") }
    }
    test("lead policy: the three modes, the hand switch and games, as a table") {
        typealias I = LeadPolicy.Inputs
        func i(game: Bool = false, pin: Bool? = nil, mode: String = "apps", supported: Bool = true, vo: Bool = false, listed: Bool = false) -> I {
            I(gameLeads: game, pin: pin, leadMode: mode, supported: supported, inVoiceOverList: vo, inLeadList: listed)
        }
        let table: [(String, I, Bool)] = [
            ("apps mode, a supported app in the list", i(listed: true), true),
            ("apps mode, a supported app not in the list", i(), false),
            ("apps mode, an unsupported app", i(supported: false, listed: true), false),
            ("apps mode, an unsupported app switched on by hand", i(pin: true, supported: false), true),
            ("a listed app switched off by hand", i(pin: false, listed: true), false),
            ("everywhere: an unsupported app", i(mode: "everywhere", supported: false), true),
            ("everywhere: an app given to VoiceOver", i(mode: "everywhere", vo: true), false),
            ("everywhere: given to VoiceOver but switched on by hand", i(pin: true, mode: "everywhere", vo: true), true),
            ("VoiceOver everywhere: even a listed app", i(mode: "voiceover", listed: true), false),
            ("VoiceOver everywhere: even a game", i(game: true, mode: "voiceover"), false),
            ("a game in apps mode", i(game: true, supported: false), true),
            ("a game switched off by hand", i(game: true, pin: false), false),
        ]
        for (what, inputs, want) in table { expect(LeadPolicy.leads(inputs), want, what) }
    }
    test("Dock: Option alone in the Dock takes the focus back out, and that is no sign of the shortcut being off") {
        // A second Option in the Dock (6 Nov 2026): Control F3 took the focus back to the application, half a second
        // on no Dock item was selected, and TurnOver said to turn on Move focus to the Dock, which was on.
        let table: [(String, Bool, Bool, Bool)] = [
            ("from an application, and the Dock took the focus", false, true, false),
            ("from an application, and the Dock never took it: the shortcut is off", false, false, true),
            ("from the Dock, and the focus went back to the application", true, false, false),
            ("from the Dock, and the Dock kept it", true, true, false),
        ]
        for (what, fromDock, selectedNow, want) in table {
            expect(GlobalCommands.dockShortcutSeemsOff(fromDock: fromDock, selectedNow: selectedNow), want, what)
        }
    }
    test("speech: a capital's pitch is used up by the next utterance even when nothing is said") {
        Speech.mode = .off
        Speech.speakMessage(Speech.capitalMark + "A")
        check(!Speech.testPitchPending, "the raised pitch was taken, not left for the next utterance")
    }
    test("speech: a focus within 0.4 s of another drops only once the new focus has words") {
        Speech.testResetFocusTiming()
        Speech.focusMoving()
        check(!Speech.testDropForFocusPending, "the first focus drops nothing")
        Speech.focusMoving()
        check(Speech.testDropForFocusPending, "the second, at once, waits to drop")
        Speech.speakMessage("not a focus")
        check(Speech.testDropForFocusPending, "a message is not the focus's words; still waiting")
    }
    test("TurnOver Key: a TurnOver started and quit between two looks lets its quit go, so the key quits the next one") {
        // TurnOver Key looks once a second. Between two looks, Command Control Period starts TurnOver 101 and quits it:
        // no look ever has 101 (the maintainer, 28 Oct 2026).
        var watch = ReaderWatch(seen: [])
        watch.quit(101)
        expect(watch.look([]), .init(quit: true), "101 gone, never seen: its quit")
        check(!watch.isQuitting(102), "the next TurnOver, 102, is not taken for one going: Command Control Period quits it")
        expect(watch.look([102]), .init(), "102 started")
        expect(watch.look([]), .init(stopped: true), "102 gone with no quit: a crash, so the restart's check runs")
        // The same with TurnOver's own notice as it quits (the menu, Command Q), which names no process.
        watch = ReaderWatch(seen: [])
        watch.quitAnnounced(running: [103])
        expect(watch.look([]), .init(quit: true), "103 gone, never seen: its quit")
        check(!watch.isQuitting(104), "the next TurnOver, 104, is not taken for one going")
    }
    test("TurnOver Key: an end is seen even when the next TurnOver starts within the same second") {
        var watch = ReaderWatch(seen: [101])
        watch.quit(101)
        expect(watch.look([102]), .init(quit: true), "101 quit, and 102 started before the next look")
        check(!watch.isQuitting(102), "102 is not going")
        expect(watch.look([103]), .init(stopped: true), "102 crashed, and 103 started before the next look")
    }
    test("fixtures: every recorded window's focus reads as something, within a call budget") {
        let dir = fixtureURL("textedit-guide").deletingLastPathComponent()
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        check(files.count >= 15, "\(files.count) fixtures found")
        for url in files {
            guard let f = try? AXFixture.load(url) else { Harness.fail("\(url.lastPathComponent) would not load"); continue }
            AXReplay.load(f)
            defer { AXReplay.unload() }
            guard let focus = AXReplay.focus ?? AXReplay.root else { Harness.fail("\(url.lastPathComponent): nothing recorded as focused"); continue }
            let before = AXStats.calls
            let obj = ObjectFactory.make(focus)
            let parts = Speech.objectPropertiesSpeech(obj, reason: .focus).filter { !$0.isEmpty }
            let calls = AXStats.calls - before
            // A nameless group is silent by design (it would only cut what was being said); anything else speaks.
            let silentGroup = obj.axRole == "AXGroup" && obj.name.isEmpty
            check(!parts.isEmpty || silentGroup, "\(url.lastPathComponent): the focus says something (role \(obj.axRole))")
            check(calls < 400, "\(url.lastPathComponent): reading the focus took \(calls) accessibility calls")
        }
    }
    test("menu bar: with no owner, no app's bar is taken, not even the focus's (Siri AI's hidden menu took the keyboard, 31 Oct 2026)") {
        let owner = MenuBarOwner.current
        let saved = (API.focusObject, API.focusAncestors, API.focusTreeInterceptor)
        defer { MenuBarOwner.current = owner; API.setFocusObject(saved.0, ancestors: saved.1, interceptor: saved.2) }
        API.setFocusObject(ObjectFactory.make(AXUIElementCreateApplication(getpid())), ancestors: [])
        MenuBarOwner.current = { nil }
        expect(MenuBarOwner.pid, nil, "no owner, with TurnOver's focus in an app")
        MenuBarOwner.current = { 1352 }
        expect(MenuBarOwner.pid, 1352, "the owner's bar")
    }
    test("menu bar: leaving the held bar says the focus it was taken from, the Dock's too (a review, 6 Nov 2026)") {
        // (what, the focus's pid, named, the focus the bar was taken from, the bar's pid, the window named, said)
        let table: [(String, pid_t?, Bool, Bool, pid_t, Bool, MenuBarOwner.Leaving)] = [
            ("the Dock: its list has no name, and the bar is the front app's", 600, false, true, 1352, true, .focus),
            ("another app's named focus, the bar the front app's", 700, true, true, 1352, true, .focus),
            ("the front app's named focus", 1352, true, true, 1352, true, .focus),
            ("the front app's nameless focus: the window's name", 1352, false, true, 1352, true, .window),
            ("the focus went to another app while the bar was held: the window's name", 600, false, false, 1352, true, .window),
            ("no focus, and a nameless window: the app is asked", nil, false, false, 1352, false, .app),
        ]
        for (what, pid, named, cameFrom, bar, window, want) in table {
            expect(MenuBarOwner.leaving(focusPid: pid, focusNamed: named, focusIsWhereItCameFrom: cameFrom, barPid: bar, windowNamed: window), want, what)
        }
    }
    test("menu bar: leaving the held bar in browse mode on the focus's app says the browse cursor, not the focus (issue 353)") {
        let browse = MenuBarOwner.leaving(focusPid: 1352, focusNamed: true, focusIsWhereItCameFrom: true, barPid: 1352, windowNamed: true, browseCursorInFocusApp: true)
        expect(browse, .browse, "Prompt has the focus, the browse cursor is on a heading")
        let focusMode = MenuBarOwner.leaving(focusPid: 1352, focusNamed: true, focusIsWhereItCameFrom: true, barPid: 1352, windowNamed: true, browseCursorInFocusApp: false)
        expect(focusMode, .focus, "focus mode or no document: the focus, as before")
        let noFocus = MenuBarOwner.leaving(focusPid: nil, focusNamed: false, focusIsWhereItCameFrom: false, barPid: 1352, windowNamed: true, browseCursorInFocusApp: true)
        expect(noFocus, .window, "no focus to be in the app of: as before")
    }
    test("menu bar: a real move of the focus lets go of the held bar, holding it and quiet events do not (issue 353)") {
        // (what, the event, it is where the bar was taken from, lets go)
        let table: [(String, EventKind, Bool, Bool)] = [
            ("an app came to the front", .foreground, false, true),
            ("a new foreground window of the same app", .foreground, true, true),
            ("the focus landed on another element", .gainFocus, false, true),
            ("the app said its focus again: the element the bar came from", .gainFocus, true, false),
            ("the focus left something", .loseFocus, false, false),
            ("a value changed", .valueChange, false, false),
            ("a caret moved", .caret, false, false),
            ("a menu opened", .menuStart, false, false),
        ]
        for (what, kind, same, want) in table {
            expect(MenuBarOwner.letsGoOfBar(kind, isWhereItCameFrom: same), want, what)
        }
    }
    test("menu bar: after Escape closes a status menu the front app's focus is read, not the menu owner's (16 Nov 2026)") {
        // (what, the menu's pid, the front app's pid, the key, whose focus is asked)
        let table: [(String, pid_t, pid_t, String, pid_t)] = [
            ("Escape in another process's status menu: the front app", 673, 1352, "escape", 1352),
            ("Escape in the front app's own menu: that app, as before", 1352, 1352, "escape", 1352),
            ("Return chose a status menu item: its effect speaks, the menu's app as before", 673, 1352, "enter", 673),
            ("Space chose a status menu item: the menu's app as before", 673, 1352, "space", 673),
            ("Escape with no front app known: the menu's app", 673, 0, "escape", 673),
        ]
        for (what, menu, front, key, want) in table {
            expect(MenuBarOwner.focusOwnerAfterMenu(menuPid: menu, frontPid: front, key: key), want, what)
        }
    }
}

func activityTests() {
    test("VoiceOver Activity: the archive gains TurnOver's profile, a person's own profile for the same app gets the setting, and removal undoes both") {
        let export: [String: Any] = ["ArchiveVersion": "993", "export": [
            "default": ["SCRVerbosity_SCRVerbosityLevel": "SCRVerbosityMedium", "VoiceOverDefaultVoiceSelections": ["en", ["voiceId": "Alex", "volume": 1.0]]],
            "allProfiles": [["profileInfo": ["profileApps": ["com.apple.Safari"], "profileKey": "profile-ABC", "profileMask": 16392, "profileName": "Web Browsing"],
                             "profileValues": ["SCRVerbosity_SCRVerbosityLevel": "SCRVerbosityLow"]]],
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: export, format: .xml, options: 0)
        let on = try VoiceOverActivity.archive(data, apps: ["com.apple.Safari", "com.apple.mail"], touched: [])
        expect(VoiceOverActivity.installedApps(in: on.data) ?? [], ["com.apple.Safari", "com.apple.mail"], "the TurnOver profile lists the apps")
        expect(on.touched, ["Web Browsing"], "the person's Safari profile was given the setting (by name: keys change on import)")
        let top = try PropertyListSerialization.propertyList(from: on.data, format: nil) as! [String: Any]
        let profiles = ((top["export"] as! [String: Any])["allProfiles"] as! [[String: Any]])
        let web = profiles.first { (($0["profileInfo"] as! [String: Any])["profileName"] as! String) == "Web Browsing" }!
        expect(((web["profileValues"] as! [String: Any])["SCRCategories_SCRCategorySystemWide_SCRSpeechComponentSettings_SCRDisableSpeech"] as? Bool), true)
        expect((((web["profileInfo"] as! [String: Any])["profileMask"] as? NSNumber)?.intValue), 32767, "every category applied to the person's own Activity (speech off, tracking off; its own mask kept for the undo)")
        let turnOver = profiles.first { (($0["profileInfo"] as! [String: Any])["profileName"] as! String) == "TurnOver" }!
        expect(((turnOver["profileValues"] as! [String: Any])["SCRVerbosity_SCRVerbosityLevel"] as? String), "SCRVerbosityMedium", "the defaults are the profile's values")
        let off = try VoiceOverActivity.archive(on.data, apps: nil, touched: on.touched, masks: on.masks)
        check(VoiceOverActivity.installedApps(in: off.data) == nil, "removed")
        let top2 = try PropertyListSerialization.propertyList(from: off.data, format: nil) as! [String: Any]
        let web2 = ((top2["export"] as! [String: Any])["allProfiles"] as! [[String: Any]]).first { (($0["profileInfo"] as! [String: Any])["profileName"] as! String) == "Web Browsing" }!
        expect(((web2["profileValues"] as! [String: Any])["SCRCategories_SCRCategorySystemWide_SCRSpeechComponentSettings_SCRDisableSpeech"] as? Bool), false, "the person's profile put back")
        expect((((web2["profileInfo"] as! [String: Any])["profileMask"] as? NSNumber)?.intValue), 16392)
        expect(off.touched, [], "nothing touched on removal")
    }
}

func activityRealExportTest() {
    test("VoiceOver Activity: on a real export, the person's own profiles covering the apps are touched and put back") {
        // Only when asked (TURNOVER_VOPREFS=path): reading Downloads unasked made macOS ask for permission on others' Macs.
        guard let path = ProcessInfo.processInfo.environment["TURNOVER_VOPREFS"] else { print("     (TURNOVER_VOPREFS not set, skipped)"); return }
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else { print("     (no export in Downloads, skipped)"); return }
        let on = try VoiceOverActivity.archive(data, apps: ["com.apple.Safari", "com.anthropic.claudefordesktop", "com.valvesoftware.steam"], touched: [])
        check(on.touched.count >= 1, "profiles touched: \(on.touched.count)")
        let off = try VoiceOverActivity.archive(on.data, apps: nil, touched: on.touched, masks: on.masks)
        let top = try PropertyListSerialization.propertyList(from: off.data, format: nil) as! [String: Any]
        let profiles = ((top["export"] as! [String: Any])["allProfiles"] as! [[String: Any]])
        for p in profiles where on.touched.contains(((p["profileInfo"] as! [String: Any])["profileName"] as? String) ?? "") {
            let v = (p["profileValues"] as! [String: Any])["SCRCategories_SCRCategorySystemWide_SCRSpeechComponentSettings_SCRDisableSpeech"] as? Bool
            check(v != true, "\((p["profileInfo"] as! [String: Any])["profileName"] ?? ""): speech off undone")
        }
    }
}
