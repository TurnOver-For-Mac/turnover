// SPDX-License-Identifier: GPL-3.0-or-later
// The decisions that can leave a blind user with no reader, as tables: who leads, what the speech queue drops; and
// every recorded window read once (code review, 16 Oct 2026).
import Foundation
import AppKit
import TurnOverCore
import AXFixtures

func policyTests() {
    test("one app: the full reader, CoExist on unless turned off, plugins on unless turned off") {
        check(Edition.editionName == "TurnOver", "named TurnOver")
        check(Edition.includesPlugins == ((UserDefaults.standard.object(forKey: "plugins") as? Bool) ?? true), "plugins on unless the default turns them off")
        check(Coexist.wouldBeOn == ((UserDefaults.standard.object(forKey: "coexist") as? Bool) ?? true), "CoExist on unless turned off")
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
    test("reader selection: startup chooses the configured reader with automatic hand-over on or off") {
        let states: [(coexist: Bool, voiceOver: Bool, running: Bool, turnOver: Bool, chooseTurnOver: Bool?, chooseVoiceOver: Bool?, pendingIfTurnOverLeads: Bool)] = [
            (false, false, false, false, nil, false, false),
            (false, false, false, true, nil, false, false),
            (false, true, true, false, true, nil, false),
            (false, true, true, true, true, nil, false),
            (true, false, false, false, true, false, true),
            (true, false, false, true, nil, false, true),
            (true, false, true, false, true, false, true),
            (true, false, true, true, nil, false, true),
            (true, true, false, false, true, nil, true),
            (true, true, false, true, nil, false, true),
            (true, true, true, false, true, nil, false),
            (true, true, true, true, nil, false, false),
        ]
        for state in states {
            for automatic in [false, true] {
                for shouldLead in [false, true] {
                    var selection = ReaderSelection()
                    let context = "CoExist \(state.coexist), VoiceOver \(state.voiceOver), running \(state.running), TurnOver \(state.turnOver), automatic \(automatic), TurnOver owns app \(shouldLead)"
                    let choice = selection.select(shouldLead: shouldLead, automaticHandOver: automatic,
                                                  coexist: state.coexist, voiceOverEnabled: state.voiceOver,
                                                  voiceOverRunning: state.running, turnOverActive: state.turnOver)
                    expect(choice, shouldLead ? state.chooseTurnOver : state.chooseVoiceOver, context)
                    expect(selection.needsInitialSelection, shouldLead ? state.pendingIfTurnOverLeads : false,
                           "\(context): only the temporary CoExist fallback leaves startup pending")
                }
            }
        }
    }
    test("reader selection: automatic hand-over controls app switches after startup") {
        for coexist in [false, true] {
            for automatic in [false, true] {
                var selection = ReaderSelection()
                expect(selection.select(shouldLead: true, automaticHandOver: automatic, coexist: coexist,
                                        voiceOverEnabled: true, voiceOverRunning: true, turnOverActive: false), true,
                       "TurnOver takes its app at startup, including when automatic hand-over is off")
                expect(selection.select(shouldLead: false, automaticHandOver: automatic, coexist: coexist,
                                        voiceOverEnabled: coexist, voiceOverRunning: coexist, turnOverActive: true), automatic ? false : nil,
                       "switching to a VoiceOver app only hands back when automatic hand-over is on")
                // VoiceOver was selected automatically above, or explicitly by the user with automatic hand-over off.
                selection.readerChosen()
                expect(selection.select(shouldLead: true, automaticHandOver: automatic, coexist: coexist,
                                        voiceOverEnabled: true, voiceOverRunning: true, turnOverActive: false), automatic ? true : nil,
                       "returning to a TurnOver app only takes over when automatic hand-over is on")
            }
        }
    }
    test("reader selection: an already correct startup reader does not leave a later startup choice pending") {
        for coexist in [false, true] {
            var selection = ReaderSelection()
            expect(selection.select(shouldLead: true, automaticHandOver: false, coexist: coexist,
                                    voiceOverEnabled: coexist, voiceOverRunning: coexist, turnOverActive: true), nil,
                   "TurnOver already has its startup app")
            expect(selection.select(shouldLead: false, automaticHandOver: false, coexist: coexist,
                                    voiceOverEnabled: coexist, voiceOverRunning: coexist, turnOverActive: true), nil,
                   "a later app change cannot masquerade as the startup choice")
            expect(selection.select(shouldLead: false, automaticHandOver: true, coexist: coexist,
                                    voiceOverEnabled: coexist, voiceOverRunning: coexist, turnOverActive: true), false,
                   "enabling automatic hand-over applies the current app's reader")
        }
    }
    test("reader selection: an explicit reader choice supersedes deferred startup") {
        for coexist in [false, true] {
            for manuallyChoseTurnOver in [false, true] {
                var selection = ReaderSelection()
                selection.readerChosen()
                check(!selection.needsInitialSelection, "the explicit choice completes startup selection")
                expect(selection.select(shouldLead: !manuallyChoseTurnOver, automaticHandOver: false,
                                        coexist: coexist, voiceOverEnabled: coexist || !manuallyChoseTurnOver,
                                        voiceOverRunning: coexist || !manuallyChoseTurnOver,
                                        turnOverActive: manuallyChoseTurnOver), nil,
                       "a delayed startup check preserves the user's reader even when the configured owner differs")
            }
        }
    }
    test("reader selection: app changes preserve deliberate silence after startup or suspension") {
        for automatic in [false, true] {
            for suspendDuringFallback in [false, true] {
                var selection = ReaderSelection()
                expect(selection.select(shouldLead: true, automaticHandOver: automatic, coexist: true,
                                        voiceOverEnabled: !suspendDuringFallback, voiceOverRunning: !suspendDuringFallback,
                                        turnOverActive: false), true, "TurnOver starts reading")
                if suspendDuringFallback { selection.readerChosen() }
                check(!selection.needsInitialSelection, "startup has completed or suspension has cancelled its fallback")
                for _ in 0..<2 {
                    expect(selection.select(shouldLead: false, automaticHandOver: automatic, coexist: true,
                                            voiceOverEnabled: false, voiceOverRunning: false, turnOverActive: false), nil,
                           "an app change cannot restart VoiceOver after both readers were silenced")
                }
            }
        }
    }
    test("reader selection: CoExist keeps reading a VoiceOver app until VoiceOver returns at startup") {
        for automatic in [false, true] {
            for voiceOverEnabled in [false, true] {
                var selection = ReaderSelection()
                // The existing lead policy supplies true while VoiceOver is off or its process has quit.
                expect(selection.select(shouldLead: true, automaticHandOver: automatic, coexist: true,
                                        voiceOverEnabled: voiceOverEnabled, voiceOverRunning: false, turnOverActive: false), true,
                       "TurnOver covers the VoiceOver app during startup")
                check(selection.needsInitialSelection, "the fallback awaits VoiceOver")
                expect(selection.select(shouldLead: true, automaticHandOver: automatic, coexist: true,
                                        voiceOverEnabled: voiceOverEnabled, voiceOverRunning: false, turnOverActive: true), nil,
                       "repeated startup checks keep TurnOver reading")
                check(selection.needsInitialSelection, "keeping the fallback reader does not complete startup")
                expect(selection.select(shouldLead: false, automaticHandOver: automatic, coexist: true,
                                        voiceOverEnabled: true, voiceOverRunning: true, turnOverActive: true), false,
                       "the configured VoiceOver app hands back when VoiceOver returns, even with automatic hand-over off")
                check(!selection.needsInitialSelection, "VoiceOver's return completes startup selection")
                expect(selection.select(shouldLead: true, automaticHandOver: automatic, coexist: true,
                                        voiceOverEnabled: true, voiceOverRunning: true, turnOverActive: false), automatic ? true : nil,
                       "later application changes obey automatic hand-over")
            }
        }
    }
    test("reader selection: a manual choice during the CoExist startup fallback is preserved") {
        for manuallyChoseTurnOver in [false, true] {
            var selection = ReaderSelection()
            expect(selection.select(shouldLead: true, automaticHandOver: false, coexist: true,
                                    voiceOverEnabled: false, voiceOverRunning: false, turnOverActive: false), true,
                   "TurnOver starts as the fallback reader")
            check(selection.needsInitialSelection, "the fallback leaves startup pending")
            selection.readerChosen()
            check(!selection.needsInitialSelection, "a manual choice cancels the pending selection")
            expect(selection.select(shouldLead: !manuallyChoseTurnOver, automaticHandOver: false, coexist: true,
                                    voiceOverEnabled: true, voiceOverRunning: true, turnOverActive: manuallyChoseTurnOver), nil,
                   "VoiceOver's return cannot override the explicit reader choice")
        }
    }
    test("reader selection: an already correct fallback reader completes startup without rearming later") {
        for automatic in [false, true] {
            var selection = ReaderSelection()
            expect(selection.select(shouldLead: true, automaticHandOver: automatic, coexist: true,
                                    voiceOverEnabled: false, voiceOverRunning: false, turnOverActive: false), true,
                   "TurnOver starts reading while VoiceOver is unavailable")
            check(selection.needsInitialSelection, "startup remains pending during the fallback")
            expect(selection.select(shouldLead: true, automaticHandOver: automatic, coexist: true,
                                    voiceOverEnabled: true, voiceOverRunning: true, turnOverActive: true), nil,
                   "VoiceOver's return keeps the already active configured TurnOver reader")
            check(!selection.needsInitialSelection, "the correct reader completes startup without a hand-over")
            expect(selection.select(shouldLead: true, automaticHandOver: automatic, coexist: true,
                                    voiceOverEnabled: false, voiceOverRunning: false, turnOverActive: true), nil,
                   "a later VoiceOver disappearance keeps TurnOver reading")
            check(!selection.needsInitialSelection, "a later disappearance cannot rearm startup")
            expect(selection.select(shouldLead: false, automaticHandOver: automatic, coexist: true,
                                    voiceOverEnabled: true, voiceOverRunning: true, turnOverActive: true), automatic ? false : nil,
                   "a subsequent VoiceOver app obeys automatic hand-over")
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
