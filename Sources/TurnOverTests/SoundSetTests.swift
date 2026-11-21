// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

// Sound sets of the user's own (SoundSets). Everything here uses a temporary folder and a probe: nothing is played, and
// the real Application Support folder is not touched.
@MainActor func soundSetTests() {
    func temporaryRoot() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("turnover-soundset-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func write(_ bytes: Int, _ name: String, in folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data(repeating: 1, count: bytes))
    }
    test("sound sets: event identifiers are unique, plain and lowercase, and each has a description") {
        let ids = SoundEvents.ids
        expect(Set(ids).count, ids.count, "no identifier twice")
        for event in SoundEvents.all {
            check(event.id == event.id.lowercased() && !event.id.isEmpty && event.id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }, "\(event.id) is plain and lowercase")
            check(!event.summary.isEmpty, "\(event.id) has a description")
        }
        for id in ["boundary", "activate", "menu-opened", "page-loaded", "window-activated"] { check(ids.contains(id), "\(id) is an event") }
    }
    test("sound sets: a file is found by identifier and any accepted ending, in any case") {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Mine")
        for (i, ext) in SoundSets.extensions.enumerated() { write(10, "event\(i).\(ext)", in: folder) }
        write(10, "Boundary.AIFF", in: folder); write(10, "notes.txt", in: folder)
        for i in 0..<SoundSets.extensions.count { check(SoundSets.file(for: "event\(i)", in: folder) != nil, "ending .\(SoundSets.extensions[i]) is accepted") }
        check(SoundSets.file(for: "boundary", in: folder)?.lastPathComponent == "Boundary.AIFF", "the base name is matched in any case")
        check(SoundSets.file(for: "notes", in: folder) == nil, "other endings are not sounds")
        check(SoundSets.file(for: "activate", in: folder) == nil, "no file for an event is nil")
    }
    test("sound sets: a folder is listed by name, and a missing file falls back, an empty file is silence, a gone set falls back") {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root); SoundSets.rootOverride = nil; SoundSets.playProbe = nil; SoundSets.forget() }
        SoundSets.rootOverride = root
        write(10, "boundary.wav", in: root.appendingPathComponent("Mine")); write(0, "link.wav", in: root.appendingPathComponent("Mine"))
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("Other"), withIntermediateDirectories: true)
        write(1, "stray.txt", in: root)
        expect(SoundSets.names(), ["Mine", "Other"], "folders only, by name")
        let saved = config.general.sounds; defer { config.general.sounds = saved }
        var played: [String] = []
        SoundSets.playProbe = { played.append($0) }
        config.general.sounds = "turnover"
        expect(SoundSets.handle("boundary"), false, "with TurnOver's own set chosen, a set is not asked")
        config.general.sounds = SoundSets.saved("Mine"); SoundSets.forget()
        expect(SoundSets.handle("boundary"), true, "the set's file answers")
        expect(played, ["boundary"], "and is the one played")
        expect(SoundSets.handle("link"), true, "an empty file answers")
        expect(played, ["boundary"], "with silence")
        expect(SoundSets.handle("activate"), false, "no file: TurnOver's own set answers")
        check(config.general.effectiveSounds.hasPrefix("set:"), "the custom set is the one chosen")
        try? FileManager.default.removeItem(at: root.appendingPathComponent("Mine")); SoundSets.forget()
        expect(SoundSets.handle("boundary"), false, "a set that has gone falls back")
        check(!SoundSets.active, "and no set is active, so TurnOver's own set plays")
        config.general.sounds = SoundSets.saved("Never was"); SoundSets.forget()
        expect(SoundSets.handle("boundary"), false, "a set that never existed falls back too")
    }
    test("sound sets: the saved choice reads back, and the old values still read") {
        expect(SoundSets.setName(fromSaved: "set:My sounds"), "My sounds")
        expect(SoundSets.setName(fromSaved: "set:"), nil)
        expect(SoundSets.setName(fromSaved: "voiceover"), nil)
        expect(SoundSets.setName(fromSaved: "turnover"), nil)
        for v in ["voiceover", "turnover", "set:Mine"] {
            let data = try! JSONSerialization.data(withJSONObject: ["sounds": v])
            let general = try! JSONDecoder().decode(Config.General.self, from: data)
            expect(general.sounds, v, "\(v) is kept")
        }
        let data = try! JSONSerialization.data(withJSONObject: ["sounds": "something else"])
        expect(try! JSONDecoder().decode(Config.General.self, from: data).sounds, "", "an unknown value is still dropped")
    }
    test("sound sets: the starter set has a file or a read-me line for every event, and the next is numbered") {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        for event in SoundEvents.all { if let own = event.ownFile { write(100, own + ".wav", in: source) } }
        let sets = root.appendingPathComponent("Sound Sets")
        let first = try! SoundSets.makeStarterSet(in: sets, from: source)
        let second = try! SoundSets.makeStarterSet(in: sets, from: source)
        expect(first.lastPathComponent, "My sounds"); expect(second.lastPathComponent, "My sounds 2")
        let readMe = (try? String(contentsOf: first.appendingPathComponent("Read me.txt"), encoding: .utf8)) ?? ""
        for event in SoundEvents.all {
            check(readMe.contains("\(event.id).wav: \(event.summary)"), "the read-me lists \(event.id) with its description")
            let there = FileManager.default.fileExists(atPath: first.appendingPathComponent(event.id + ".wav").path)
            check(there || readMe.contains("\(event.id).wav: \(event.summary)  NO FILE YET"), "\(event.id) has a file or says why not")
            if event.ownFile != nil || event.tone != nil { check(there, "\(event.id) was written") }
        }
        for phrase in ["replace its file", "delete its file", "zero bytes", "zip the folder"] { check(readMe.contains(phrase), "the read-me says \(phrase)") }
        expect(SoundSets.names(in: sets), ["My sounds", "My sounds 2"], "both are listed")
        let tone = SoundSets.renderTone(hertz: 880, ms: 80, volume: 0.25)
        expect(String(decoding: tone.prefix(4), as: UTF8.self), "RIFF", "a rendered tone is a wav")
        expect(tone.count, 44 + 3528 * 2, "of the right length")
    }
    test("sound sets: VoiceOver's files map to events, and every mapped event exists") {
        for name in ["LinkBegin.aiff", "WrapBoundary.aiff", "QuickNavOn.wav", "MenuDown.aiff", "WebPageLoaded.aiff", "WindowActivated.aiff"] {
            check(SoundEvents.id(forVoiceOverFile: name).map { SoundEvents.ids.contains($0) } == true, "\(name) maps to an event")
        }
    }
    // 20 Nov 2026 (review): a set's file that is not prepared yet must not pass in silence; TurnOver's own sound plays.
    test("sound sets: a file not prepared yet answers false, so TurnOver's own sound plays; preload reads the chosen set") {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root); SoundSets.rootOverride = nil; SoundSets.playProbe = nil; SoundSets.forget() }
        SoundSets.rootOverride = root
        SoundSets.playProbe = nil
        write(10, "boundary.wav", in: root.appendingPathComponent("Mine"))
        // A cache that nothing was requested of: the file is neither ready nor failed. (No player is made, so nothing plays.)
        let cache = SoundCache()
        check(cache.player("boundary") == nil && !cache.hasFailed("boundary"), "the file is not prepared")
        expect(SoundSets.playOnMain("boundary", set: "Mine", cache: cache, why: "test"), false, "not ready: TurnOver's own sound answers")
        let saved = config.general.sounds; defer { config.general.sounds = saved }
        config.general.sounds = SoundSets.saved("Mine"); SoundSets.forget()
        check(!SoundSets.isLoaded, "no set is read yet")
        SoundSets.preload()
        check(SoundSets.isLoaded, "preload reads the chosen set")
        config.general.sounds = "turnover"; SoundSets.forget()
        SoundSets.preload()
        check(!SoundSets.isLoaded, "with TurnOver's own set chosen, preload reads nothing")
    }
}
