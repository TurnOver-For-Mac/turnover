// SPDX-License-Identifier: GPL-3.0-or-later
// The decisions that can leave a blind user with no reader, as tables: who leads, what the speech queue drops; and
// every recorded window read once (code review, 16 Oct 2026).
import Foundation
import AppKit
import TurnOverCore
import AXFixtures

func policyTests() {
    test("one app: the full reader, plugins on unless turned off") {
        check(Edition.editionName == "TurnOver", "named TurnOver")
        check(Edition.includesPlugins == ((UserDefaults.standard.object(forKey: "plugins") as? Bool) ?? true), "plugins on unless the default turns them off")
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
