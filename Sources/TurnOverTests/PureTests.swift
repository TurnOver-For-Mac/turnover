// SPDX-License-Identifier: GPL-3.0-or-later
// Tests of the pure parts: no application, no speech, no keyboard.
import Foundation
import Darwin
import AppKit
import AVFoundation
import CoreGraphics
import ApplicationServices
import TurnOverCore
import TurnOverSpeech
import AXFixtures

func pureTests() {
    test("readers per app: a fresh file is off, a file with a list or another mode keeps working as it did") {
        let decode: (String) -> Config.Applications = { json in
            try! JSONDecoder().decode(Config.Applications.self, from: json.data(using: .utf8)!)
        }
        expect(Config.Applications().perAppReaders, false, "a fresh install: TurnOver everywhere while it is on")
        expect(decode("{}").perAppReaders, true, "a file from before the modes starts in apps mode, so its lists are kept")
        expect(decode("{\"leadMode\": \"everywhere\", \"voiceOverBundles\": []}").perAppReaders, false, "everywhere with no list: nothing to keep")
        expect(decode("{\"leadMode\": \"everywhere\", \"voiceOverBundles\": [\"com.apple.Safari\"]}").perAppReaders, true, "an app given to VoiceOver is kept")
        expect(decode("{\"leadMode\": \"apps\"}").perAppReaders, true, "TurnOver in its apps is kept")
        expect(decode("{\"perAppReaders\": false, \"leadMode\": \"apps\"}").perAppReaders, false, "a choice made is kept over the lists")
        let off = decode("{\"leadMode\": \"everywhere\"}")
        expect(off.effectiveLeadMode, "everywhere"); expect(off.switchesAsAppsChange, false); expect(off.handsOverAtLaunch, true)
        expect(decode("{}").swapWithVoiceOver, true, "the swap with VoiceOver is on unless turned off")
        expect(decode("{\"swapWithVoiceOver\": false}").swapWithVoiceOver, false, "the choice is kept")
    }
    test("verbosity: the pieces in the list's order, off ones left out; an old file's switches become the list") {
        let pieces: [(String, [String])] = [("name", ["Save"]), ("role", ["button"]), ("state", ["dimmed"]), ("description", ["Saves the file"]), ("position", ["2 of 5"])]
        expect(Speech.arranged(pieces, by: Config.Verbosity()), ["Save", "button", "dimmed", "Saves the file", "2 of 5"], "the standard order")
        var v = Config.Verbosity(order: ["role", "name"], off: ["description"])
        expect(v.order, ["role", "name", "value", "state", "description", "shortcut", "position", "level"], "missing pieces appended in the standard order")
        expect(Speech.arranged(pieces, by: v), ["button", "Save", "dimmed", "2 of 5"], "role first, help text off")
        v.set("position", said: false); v.set("description", said: true)
        expect(Speech.arranged(pieces, by: v), ["button", "Save", "dimmed", "Saves the file"], "position turned off, help text back on")
        let decode: (String) -> Config.Presentation = { json in try! JSONDecoder().decode(Config.Presentation.self, from: json.data(using: .utf8)!) }
        let old = decode("{\"reportObjectDescriptions\": false, \"reportKeyboardShortcuts\": true, \"reportObjectPositionInformation\": false}")
        expect(old.verbosity.off.sorted(), ["description", "level", "position"], "a file from before the list: its switches become off entries (position took the level with it)")
        expect(old.reportObjectDescriptions, false); expect(old.reportKeyboardShortcuts, true)
        let new = decode("{\"verbosity\": {\"order\": [\"value\", \"bogus\", \"name\"], \"off\": [\"role\"]}, \"verbosityByApp\": {\"com.apple.mail\": {\"order\": [\"description\"], \"off\": []}}}")
        expect(new.verbosity.order.prefix(3).map { $0 }, ["value", "name", "role"], "unknown pieces dropped, the rest appended")
        expect(new.verbosity(for: "com.apple.mail").order.first, "description", "the app's own list")
        expect(new.verbosity(for: "com.apple.Safari").order.first, "value", "another app: the everywhere list")
    }
    test("finder: a list row is a folder by its Kind cell or the folder's dashes in Size") {
        expect(FinderRows.isFolderRow(cellTexts: ["Reports", "Today at 10:14", "--", "Folder"]), true)
        expect(FinderRows.isFolderRow(cellTexts: ["Notes.docx", "8 Oct 2026 at 15:57", "244 KB", "Microsoft Word document (.docx)"]), false)
        expect(FinderRows.isFolderRow(cellTexts: ["Reports", "Today at 10:14", "--"]), true, "the Kind column hidden")
        expect(FinderRows.isFolderRow(cellTexts: []), false, "an icon view item has no cells")
    }
    test("typing echo: the field's word once it has taken the key, the letters typed only without one") {
        expect(Speech.wordJustTyped(field: "the", typed: "teh"), "the", "autocorrect: the field's word")
        expect(Speech.wordJustTyped(field: "café", typed: "cafe"), "café", "a dead key's accent")
        expect(Speech.wordJustTyped(field: nil, typed: "word"), "word", "no field word: the letters typed")
        expect(Speech.wordJustTyped(field: "", typed: ""), nil, "nothing")
        // Taken: the space is in, and only the next word's letters after it.
        let a = Speech.fieldWord(endedBy: " ", before: "one two ", notBefore: 4)
        check(a.taken && a.word == "two", "taken: \(a)")
        let b = Speech.fieldWord(endedBy: " ", before: "one two th", notBefore: 4)
        check(b.taken && b.word == "two" && b.next == 8, "typed on into the next word: \(b)")
        // Not yet: the field lags; the only space is the word before's.
        let c = Speech.fieldWord(endedBy: " ", before: "one tw", notBefore: 4)
        check(!c.taken, "lagging field: \(c)")
        let d = Speech.fieldWord(endedBy: ".", before: "かな.", notBefore: 0)
        check(d.taken && d.word == "かな", "kana: \(d)")
        let e = Speech.fieldWord(endedBy: "\r", before: "line\n", notBefore: 0)
        check(e.taken && e.word == "line", "Return against the field's line break: \(e)")
        // The end of a sentence typed fast: the full stop is in, with a space and the next word after it.
        let f = Speech.fieldWord(endedBy: ".", before: "one the. Ne", notBefore: 4)
        check(f.taken && f.word == "the" && f.next == 9, "a full stop, then a space and the next word: \(f)")
        let g = Speech.fieldWord(endedBy: ",", before: "one two, ", notBefore: 4)
        check(g.taken && g.word == "two", "a comma and a space: \(g)")
        // A closing double quote the field made curly.
        let h = Speech.fieldWord(endedBy: "\"", before: "say “hi” ", notBefore: 5)
        check(h.taken && h.word == "hi", "a closing smart quote: \(h)")
        // After a Backspace the start isn't known: the space must be the field's last character, or the word before
        // the one being typed was read out (27 Oct 2026).
        let i = Speech.fieldWord(endedBy: " ", before: "for entrusting", notBefore: nil)
        check(!i.taken, "start unknown, field lagging: not the word before: \(i)")
        let j = Speech.fieldWord(endedBy: " ", before: "for entrusting ", notBefore: nil)
        check(j.taken && j.word == "entrusting", "start unknown, space in: \(j)")
    }
    test("applications: hidden links to visible apps appear once, hidden apps stay out") {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("turnover-app-list-test-\(UUID().uuidString)")
        let root = dir.appendingPathComponent("Applications")
        let targets = dir.appendingPathComponent("Targets")
        try fm.createDirectory(at: root.appendingPathComponent("Utilities"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        func app(_ name: String, id: String, in directory: URL) throws -> URL {
            let url = directory.appendingPathComponent(name + ".app")
            try fm.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            let plist = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: url.appendingPathComponent("Contents/Info.plist"))
            return url
        }
        let browser = try app("Browser", id: "org.example.browser", in: targets)
        let link = root.appendingPathComponent("Browser.app")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../Targets/Browser.app")
        check(lchflags(link.path, UInt32(UF_HIDDEN)) == 0, "hide the link without hiding its target")
        let nestedLink = root.appendingPathComponent("Utilities/Browser.app")
        try fm.createSymbolicLink(at: nestedLink, withDestinationURL: browser)
        check(lchflags(nestedLink.path, UInt32(UF_HIDDEN)) == 0, "hide the duplicate link in Utilities")
        _ = try app("Visible", id: "org.example.visible", in: root)
        _ = try app("Tool", id: "org.example.tool", in: root.appendingPathComponent("Utilities"))
        let hidden = try app("Hidden", id: "org.example.hidden", in: root)
        check(lchflags(hidden.path, UInt32(UF_HIDDEN)) == 0, "hide the ordinary app")
        let hiddenLink = root.appendingPathComponent("Hidden link.app")
        try fm.createSymbolicLink(at: hiddenLink, withDestinationURL: hidden)
        check(lchflags(hiddenLink.path, UInt32(UF_HIDDEN)) == 0, "hide the link to the hidden app")
        try fm.createSymbolicLink(at: root.appendingPathComponent("Missing.app"), withDestinationURL: targets.appendingPathComponent("Missing.app"))
        let apps = TurnOverMenu.installedApps(in: [root])
        expect(apps.map(\.0).sorted(), ["org.example.browser", "org.example.tool", "org.example.visible"])
        expect(apps.first { $0.0 == "org.example.browser" }?.1, "Browser")
    }
    test("keyboard help: the description in a few words") {
        func brief(_ d: String) -> String { Script.brief(d) }
        expect(brief("Moves to the next heading"), "Moves to the next heading")
        expect(brief("In text, the start of the text; elsewhere the first item in the group (VO-Home)"), "In text, the start of the text")
        expect(brief("Arrow-key Quick Nav on or off: Left and Right move the VoiceOver cursor (VO-Shift-Q)"), "Arrow-key Quick Nav on or off")
        expect(brief("Reports the cell's note; twice, shows it (NVDA+Alt+C)"), "Reports the cell's note")
    }
    test("silent failures: essential keys stay the user's; a zero-width line is nothing to say") {
        for id in ["kb:escape", "kb:turnover+space", "kb:command+control+,", "kb:command+control+."] {
            check(UserGestures.isProtected(KeyboardGesture(identifier: id)!), "\(id) is protected")
        }
        check(!UserGestures.isProtected(KeyboardGesture(identifier: "kb:turnover+t")!), "an ordinary key isn't")
        check(Speech.cleaned("\u{200B}\u{200C}\u{200E}").isEmpty, "zero-width marks clean to nothing")
    }
    test("privacy: braille input and spoken text are redacted in a report") {
        let r = Feedback.redact("[  1.0] IO braille input: dots 123\n[  1.1] IO say: hunter2 is the word\n[  1.2] IO braille shows (line): secret line")
        check(!r.contains("dots 123") && r.contains("braille input: […]"), "braille input: \(r)")
        check(!r.contains("hunter2") && r.contains("[spoken, "), "say: \(r)")
        check(!r.contains("secret line"), "braille shows")
    }
    test("privacy: a page's saved place is keyed by a hash without its query, and logged as host and path") {
        let a = BrowseModeHandler.key(for: "https://en.wikipedia.org/wiki/Cat?x=1&wprov=srpw1#History")
        let b = BrowseModeHandler.key(for: "https://en.wikipedia.org/wiki/Cat")
        let c = BrowseModeHandler.key(for: "https://en.wikipedia.org/wiki/Dog")
        expect(a, b, "query and fragment don't count"); check(a != c, "another page, another key")
        check(a.count == 24 && !a.contains("wikipedia"), "a hash, not the address: \(a)")
        expect(BrowseModeHandler.shortURL("https://example.com/a/b?q=secret%20term"), "example.com/a/b")
    }
    test("languages: one Arabic letter goes to the Arabic voice, not the English voice's letter name") {
        let english = AVSpeechSynthesisVoice.speechVoices().first { $0.language.hasPrefix("en") }
        guard let english else { return }   // no English voice on this Mac: nothing to compare with
        let before = config.speech.voice, beforeAuto = config.speech.autoLanguageSwitching
        defer { config.speech.voice = before; config.speech.autoLanguageSwitching = beforeAuto }
        config.speech.voice = english.identifier; config.speech.autoLanguageSwitching = true
        expect(Languages.detectUnmarked("ا"), "ar", "a lone Arabic letter")
        expect(Languages.detectUnmarked("مع"), "ar", "two Arabic letters")
        expect(Languages.detectUnmarked("a"), nil, "a Latin letter stays with the main voice")
        expect(Languages.detectUnmarked("."), nil, "punctuation stays with the main voice")
    }
    test("reading modes: each mode's own list, for showing and for moving") {
        var a = Config.Applications()
        a.perAppReaders = true   // the lists only count with readers per app on (22 Oct 2026)
        a.leadBundles = ["com.apple.mail"]; a.voiceOverBundles = ["com.apple.Safari"]
        a.leadMode = "apps"
        expect(a.listedForTurnOver("com.apple.mail"), true); expect(a.listedForTurnOver("com.apple.Safari"), false)
        a.leadMode = "everywhere"
        expect(a.listedForTurnOver("com.apple.mail"), true); expect(a.listedForTurnOver("com.apple.Safari"), false)
        expect(a.listedForTurnOver("com.apple.TextEdit"), true, "everywhere: any app not given to VoiceOver")
        a.give("com.apple.TextEdit", toTurnOver: false)
        expect(a.voiceOverBundles.contains("com.apple.TextEdit"), true); expect(a.leadBundles, ["com.apple.mail"], "apps list untouched")
        a.give("com.apple.Safari", toTurnOver: true)
        expect(a.voiceOverBundles.contains("com.apple.Safari"), false)
        a.leadMode = "voiceover"
        expect(a.listedForTurnOver("com.apple.mail"), false)
        let before = a; a.give("com.apple.mail", toTurnOver: true)
        expect(a.leadBundles, before.leadBundles, "VoiceOver everywhere: nothing moves"); expect(a.voiceOverBundles, before.voiceOverBundles)
    }
    test("plugin format: comments, trailing commas, lines, unknown fields, choices, versions") {
        let text = """
        {
          // a comment
          "labels": [
            { "match": { "role": "AXButton", "identifier": "home" }, "nmae": "Home", },   /* trailing comma */
            { "match": { "role": "AXImage" }, "nameFrom": "nextTxt" },
          ],
        }
        """
        let cleaned = PluginFormat.clean(text)
        expect(cleaned.components(separatedBy: "\n").count, text.components(separatedBy: "\n").count)
        expect((try? JSONSerialization.jsonObject(with: Data(cleaned.utf8))) != nil, true)
        expect(PluginFormat.line(of: ["labels", "1", "nameFrom"], in: cleaned), 5)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-format-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let m = dir.appendingPathComponent("manifest.json"), p = dir.appendingPathComponent("profile.json")
        try? #"{ "id": "t", "name": "T", "version": "1", "apps": ["x"], "formatVersion": 9, }"#.write(to: m, atomically: true, encoding: .utf8)
        try? text.write(to: p, atomically: true, encoding: .utf8)
        let problems = PluginFormat.check(manifest: m, profile: p).map(\.description)
        expect(problems.contains { $0.hasPrefix("profile.json, line 4") && $0.contains("did you mean \"name\"") }, true)
        expect(problems.contains { $0.hasPrefix("profile.json, line 5") && $0.contains("nameFrom must be one of") }, true)
        expect(problems.contains { $0.hasPrefix("manifest.json, line 1") && $0.contains("format 9") }, true)
        let loaded = ProfileStore.load(folder: dir)
        expect(loaded.error?.contains("format 9") ?? false, true)
        try? #"{ "id": "t", "name": "T", "version": "1", "apps": ["x"] }"#.write(to: m, atomically: true, encoding: .utf8)
        try? "{\n \"labels\": [\n { \"match\": { \"role\": 3 } }\n ]\n}".write(to: p, atomically: true, encoding: .utf8)
        let bad = ProfileStore.load(folder: dir)
        expect(bad.error?.hasPrefix("profile.json, line 3") ?? false, true)
        try? FileManager.default.removeItem(at: dir)
    }
    test("Excel: column letters from the grid's index") {
        expect(ExcelAddress.columnLetters(1), "A"); expect(ExcelAddress.columnLetters(26), "Z"); expect(ExcelAddress.columnLetters(27), "AA"); expect(ExcelAddress.columnLetters(703), "AAA")
    }
    test("names: icon-font glyphs dropped; list markers are text") {
        expect(Speech.withoutIconGlyphs("\u{F02DC}"), ""); expect(Speech.withoutIconGlyphs("Send \u{E001}"), "Send")
        expect(Role.from(axRole: "AXListMarker", subrole: nil), .staticText)
    }
    test("roles: Preview's pages and tool groups are named; a disabled container is not said to be unavailable") {
        expect(Role.from(axRole: "AXPage", subrole: nil), .page)
        expect(Role.from(axRole: "AXRadioGroup", subrole: nil), .groupBox)
        expect(Role.neverUnavailable.contains(.list), true)
        expect(Role.neverUnavailable.contains(.button), false)
    }
    test("roles: a switch says on or off; a Mac tab says it is selected") {
        expect(Role.from(axRole: "AXCheckBox", subrole: "AXSwitch"), .switchControl)
        expect(Role.switchControl.displayString, "switch")
        expect(statesSpeech(role: .switchControl, states: [], reason: .focus), ["off"])
        expect(statesSpeech(role: .switchControl, states: [.on], reason: .focus), ["on"])
        expect(statesSpeech(role: .tab, states: [.selected], reason: .focus), ["selected"], "focus does not select a tab on the Mac")
        expect(statesSpeech(role: .listItem, states: [.selected], reason: .focus), [], "a list item's selection is still not news")
    }
    test("user keys: a key given to a command, a key taken away, a right Option key of its own") {
        let was = config.keyboard.userGestures; defer { config.keyboard.userGestures = was }
        config.keyboard.userGestures = ["kb:turnover+f14": "script:dateTime", "kb:turnover+t": "none"]
        let f14 = KeyboardGesture(identifier: "kb:turnover+f14")!
        expect(ScriptHandler.findScript(for: f14)?.name, "dateTime", "given")
        check(ScriptHandler.findScript(for: KeyboardGesture(identifier: "kb:turnover+t")!) == nil, "taken away")
        config.keyboard.userGestures = [:]
        check(ScriptHandler.findScript(for: KeyboardGesture(identifier: "kb:turnover+t")!) != nil, "back to TurnOver's own")
        // Right Option S: option with the right-hand device bit (0x40) has an identifier of its own; left Option S does not.
        let right = KeyboardGesture(keyCode: 1, modifiers: .option, characters: "ß", timestamp: 0, isRepeat: false, flags: CGEventFlags(rawValue: 0x80040))
        let left = KeyboardGesture(keyCode: 1, modifiers: .option, characters: "ß", timestamp: 0, isRepeat: false, flags: CGEventFlags(rawValue: 0x80020))
        expect(UserGestures.storedIdentifier(of: right), "kb:rightoption+s")
        check(UserGestures.storedIdentifier(of: left) != "kb:rightoption+s", "left Option is not")
        expect(UserGestures.spoken("kb:rightoption+s"), "right option s")
        expect(UserGestures.storedIdentifier(of: KeyboardGesture(identifier: "kb:turnover+shift+0")!), "kb:turnover+shift+0", "the plain form, not the layout's")
    }
    test("speech: a capital said alone is marked for a raised pitch only when the setting is on") {
        let was = config.speech.capitalPitch; defer { config.speech.capitalPitch = was }
        config.speech.capitalPitch = 0
        check(!Symbols.name(of: "A").hasPrefix(Speech.capitalMark), "off: no mark")
        config.speech.capitalPitch = 30
        check(Symbols.name(of: "A").hasPrefix(Speech.capitalMark), "on: marked")
        check(!Symbols.name(of: "a").hasPrefix(Speech.capitalMark), "a small letter is not")
        check(!Speech.cleaned(Symbols.name(of: "A")).contains(Speech.capitalMark), "the mark never reaches braille or the log")
    }
    test("images: file names made readable, numbers and hashes dropped") {
        expect(ImageNames.readable("sunset-beach_2x"), "sunset beach")
        expect(ImageNames.readable("Team%20Photo@2x"), "Team Photo")
        expect(ImageNames.readable("IMG_2041"), "")
        expect(ImageNames.readable("a3f9c2e1b7d04e55"), "")
        expect(ImageNames.readable("logo"), "logo")
        expect(ImageNames.readable("12345678"), "")
    }
    test("speech output: the device list has names and UIDs, and the config keeps the choice") {
        let devices = SpeechPlayer.outputDevices()
        // A build machine (GitHub's Macs) may have no audio device at all: nothing to check there.
        guard !devices.isEmpty else { print("     (no output device on this machine, skipped)"); return }
        check(devices.allSatisfy { !$0.uid.isEmpty && !$0.name.isEmpty }, "every device named: \(devices)")
        var speech = Config.Speech(); speech.outputDevice = devices[0].uid
        let data = try JSONEncoder().encode(speech)
        expect(try JSONDecoder().decode(Config.Speech.self, from: data).outputDevice, devices[0].uid, "round trip")
        expect(try JSONDecoder().decode(Config.Speech.self, from: Data("{}".utf8)).outputDevice, "", "older config: the default output")
    }
    test("force quit: the front application is marked") {
        expect(ForceQuit.labels([(name: "Safari", isFront: false), (name: "Mail", isFront: true)]), ["Safari", "Mail, in front"])
    }
    test("symbols: levels") {
        expect(Symbols.process("a, b", level: .none), "a, b")
        expect(Symbols.process("a, b", level: .some), "a, b")
        expect(Symbols.process("a, b", level: .all), "a comma b")
        expect(Symbols.process("Markdown • 61 words • 356 characters", level: .some), "Markdown, 61 words, 356 characters")
        expect(Symbols.process("• first item", level: .some).hasPrefix("bullet"), true)
        expect(Symbols.process("50% off", level: .some), "50 percent off")
        expect(Symbols.process("(x)", level: .most), "left paren x right paren")
    }
    test("symbols: an apostrophe inside a word is named only at all") {
        expect(Symbols.process("don't", level: .most), "don't")
        expect(Symbols.process("don't", level: .all), "don apostrophe t")
        expect(Symbols.process("'quoted'", level: .most), "apostrophe quoted apostrophe")
    }
    test("symbols: names and spelling") {
        expect(Symbols.name(of: " "), "space")
        expect(Symbols.name(of: "\n"), "new line")
        expect(Symbols.name(of: "\t"), "tab")
        expect(Symbols.name(of: "é"), "é")
        expect(Symbols.spelled("a.b"), "a, period, b")
        check(Symbols.isAllSymbols(" *** "), "stars are all symbols")
        check(!Symbols.isAllSymbols("a*"), "a letter is not")
        check(!Symbols.isAllSymbols("  "), "blank is not")
    }

    test("gestures: identifiers normalise to TurnOver's names") {
        expect(normalizeGestureIdentifier("kb:NVDA+Control+UpArrow"), "kb:turnover+control+upArrow")
        expect(normalizeGestureIdentifier("kb:caps+shift+h"), "kb:turnover+shift+h")
        expect(normalizeGestureIdentifier("kb(laptop):TurnOver+Space"), "kb(laptop):turnover+space")
        expect(normalizeGestureIdentifier("br(baum):d1"), "br(baum):d1")
    }
    test("gestures: a gesture from an identifier and back") {
        guard let g = KeyboardGesture(identifier: "kb:turnover+shift+upArrow") else { return Harness.fail("no gesture") }
        expect(g.identifier, "kb:turnover+shift+upArrow")
        expect(g.keyName, "upArrow")
        check(g.isTurnOverModifier, "turnover modifier")
        check(!g.shouldReportAsCommand, "a chord is not reported as a command key")
        expect(g.typedCharacter, nil, "a chord types nothing")
        check(KeyboardGesture(identifier: "kb:nosuchkey") == nil, "an unknown key makes no gesture")
    }
    test("gestures: typing and command keys") {
        let a = KeyboardGesture(keyCode: 0, modifiers: [], characters: "a", timestamp: 0, isRepeat: false, flags: [])
        expect(a.typedCharacter, "a")
        check(!a.shouldReportAsCommand, "a letter is typing")
        let A = KeyboardGesture(keyCode: 0, modifiers: .shift, characters: "A", timestamp: 0, isRepeat: false, flags: [])
        expect(A.typedCharacter, "A")
        check(!A.shouldReportAsCommand, "shift with a letter is typing")
        let cmdA = KeyboardGesture(keyCode: 0, modifiers: .command, characters: "a", timestamp: 0, isRepeat: false, flags: [])
        expect(cmdA.typedCharacter, nil, "command a types nothing")
        check(cmdA.shouldReportAsCommand, "command a is a command key")
        let bs = KeyboardGesture(keyCode: 51, modifiers: [], characters: "\u{7f}", timestamp: 0, isRepeat: false, flags: [])
        expect(bs.typedCharacter, "\u{8}", "backspace types a backspace for the word buffer")
    }

    test("scripts: the latest declared wins, unless unavailable") {
        let o = ScriptableObject()
        o.script("first", "", gestures: ["kb:turnover+f19"]) { _ in }
        o.script("second", "", gestures: ["kb:turnover+f19"]) { _ in }
        let g = KeyboardGesture(identifier: "kb:turnover+f19")!
        expect(o.script(for: g)?.name, "second")
        o.script(named: "second")?.isAvailable = { false }
        expect(o.script(for: g)?.name, "first")
        o.script(named: "first")?.isAvailable = { false }
        expect(o.script(for: g)?.name, nil)
        expect(o.script(named: "first")?.name, "first")
    }
    test("kokoro: audio frames split anywhere by the pipe come out whole") {
        let r = KokoroVoice.selfTest()
        check(r.samples == 440 && r.ended, "got \(r.samples) samples, ended \(r.ended)")
    }
    test("languages: an Arabic cell after English words goes to its own voice; English alone isn't split ()") {
        let saved = config.speech.voice
        defer { config.speech.voice = saved }
        config.speech.voice = "com.apple.voice.compact.en-GB.Daniel"
        let pieces = Languages.splitByLanguage("row 2, column 3, الترجمة الشفهية والتتابعية")
        check(pieces.count == 2 && pieces[0].language == nil && pieces[1].language?.hasPrefix("ar") == true,
              "got \(pieces.map { "\($0.language ?? "main"): \($0.text.count) chars" })")
        let plain = Languages.splitByLanguage("Send, button, 3 of 12")
        check(plain.count == 1 && plain[0].language == nil, "plain English split into \(plain.count)")
    }
    test("spelling: by character, said entering a misspelled word and leaving it, not on each letter ()") {
        final class Spelt: TextInfo {
            static let text = "Hello qzxwv there" as NSString
            override func storyLength() -> Int { Self.text.length }
            override func textRange(_ s: Int, _ e: Int) -> String { Self.text.substring(with: NSRange(location: s, length: max(0, e - s))) }
            override func formatField(at offset: Int) -> FormatField? { var f = FormatField(); f.fontName = "Helvetica"; f.misspelled = (6..<11).contains(offset); return f }
        }
        let saved = config.documentFormatting.spellingErrors
        defer { config.documentFormatting.spellingErrors = saved }
        config.documentFormatting.spellingErrors = .speech
        let obj = ObjectFactory.make(AXUIElementCreateApplication(getpid()))
        let said = (5...12).map { i in Speech.textInfoSpeech(Spelt(obj: obj, start: i, end: i + 1), unit: .character, reason: .caret) }
        let marks = said.map { $0.hasPrefix("out of spelling error") ? "out" : $0.hasPrefix("spelling error") ? "in" : "-" }
        check(marks == ["-", "in", "-", "-", "-", "-", "out", "-"], "got \(marks) for \(said)")
    }
    test("plugin listing: a full listing passes; missing fields, undeclared abilities and essential keys don't") {
        let folder = URL(fileURLWithPath: "/tmp/listing-test")
        let profile = try! JSONDecoder().decode(Profile.self, from: Data(#"{"keys":[{"key":"turnover+shift+p","description":"Prepare","action":"menu","menu":["File","Prepare"]}],"labels":[{"match":{"role":"button","unnamed":true,"inside":{"role":"toolbar"}},"name":"Home"}]}"#.utf8))
        var m = PluginManifest(id: "demo", name: "Demo", version: "1.0", author: "TurnOver", description: "Labels and a key.", apps: ["com.example.demo"])
        m.summary = "Names a button and adds a key."; m.contact = "a@b.c"; m.privacy = "Reads Demo only; nothing leaves your Mac."
        m.license = "MIT"; m.changes = [PluginChange(version: "1.0", notes: "First.")]; m.abilities = ["read", "menu"]
        let good = PluginListing.check(LoadedPlugin(folder: folder, manifest: m, profile: profile, error: nil, modified: Date()), others: [])
        check(good.problems == 0, "a full listing: \(good.lines)")
        var bare = m; bare.summary = nil; bare.license = "GPL-3.0"; bare.abilities = ["read"]; bare.changes = nil
        let bad = PluginListing.check(LoadedPlugin(folder: folder, manifest: bare, profile: profile, error: nil, modified: Date()), others: [])
        check(bad.problems == 4, "summary, licence, the menu ability and changes: \(bad.problems) problems: \(bad.lines)")
        let grab = try! JSONDecoder().decode(Profile.self, from: Data(#"{"keys":[{"key":"command+control+.","description":"Mine","action":"say","say":"hi"}]}"#.utf8))
        var m2 = m; m2.abilities = ["say"]
        let r = PluginListing.check(LoadedPlugin(folder: folder, manifest: m2, profile: grab, error: nil, modified: Date()), others: [])
        check(r.lines.contains { $0.contains("essential keys") }, "Command Control Period refused: \(r.lines)")
        let clash = PluginListing.check(LoadedPlugin(folder: folder, manifest: m, profile: profile, error: nil, modified: Date()), others: [(normalizeGestureIdentifier("kb:turnover+shift+p"), "TurnOver's test")])
        check(clash.problems == 0 && clash.notes == 1, "a clash is a note: \(clash.lines)")
    }
    test("plugin ids: plain names only; never a path (the code review's '..')") {
        for ok in ["bambustudio-profile", "a", "my-com-apple-TextEdit"] { check(PluginManifest.isValidID(ok), "\(ok) refused") }
        for bad in ["..", ".", "", "-x", "a/b", "../settings", "a b", String(repeating: "a", count: 65)] { check(!PluginManifest.isValidID(bad), "\(bad) allowed") }
    }
    test("plugin policy: ways out of the app refused anywhere; the library's rules for community plugins") {
        func plugin(_ apps: [String], _ profile: String) -> LoadedPlugin {
            LoadedPlugin(folder: URL(fileURLWithPath: "/tmp/p"), manifest: PluginManifest(id: "t", name: "T", version: "1", apps: apps),
                         profile: try! JSONDecoder().decode(Profile.self, from: Data(profile.utf8)), error: nil, modified: Date())
        }
        let out = PluginPolicy.check(plugin(["com.example.a"], #"{"keys":[{"key":"turnover+a","description":"x","action":"menu","menu":["Apple","System Settings…"]},{"key":"turnover+b","description":"x","action":"keys","keys":"command+tab"},{"key":"turnover+c","description":"x","action":"keys","keys":"command+v"},{"key":"turnover+d","description":"x","action":"menu","menu":["App","Services","Run"]}]}"#))
        check(out.refused.count == 4, "Apple menu, Command Tab, Paste, Services: \(out.refused)")
        let lib = PluginPolicy.check(plugin(["com.1password.1password"], #"{"silence":[{"role":"button"}],"labels":[{"match":{"title":"Save"},"name":"Delete"}],"keys":[{"key":"turnover+s","description":"x","action":"say","say":"TurnOver: call 0800 123 4567"}]}"#))
        check(lib.refused.isEmpty && lib.libraryOnly.count >= 4, "closed app, catch-all silence, renaming, impersonation: \(lib.libraryOnly)")
        let fine = PluginPolicy.check(plugin(["com.example.a"], #"{"labels":[{"match":{"role":"button","unnamed":true,"identifier":"home"},"name":"Home"}],"keys":[{"key":"turnover+h","description":"Home","action":"say","say":"Home page"}]}"#))
        check(fine.refused.isEmpty && fine.libraryOnly.isEmpty, "an ordinary plugin: \(fine.refused + fine.libraryOnly)")
    }
    test("languages: a single Arabic letter has its language by its script (typing echo)") {
        let saved = config.speech.voice
        defer { config.speech.voice = saved }
        config.speech.voice = "com.apple.voice.compact.en-GB.Daniel"
        check(Languages.forCharacter("ب", marked: nil)?.hasPrefix("ar") == true, "ب: \(Languages.forCharacter("ب", marked: nil) ?? "none")")
        check(Languages.forCharacter("b", marked: nil) == nil, "a Latin letter keeps the main voice")
    }
    test("keypad: every entry of VoiceOver's and NVDA's tables reaches a command") {
        let bad = Keypad.unresolved()
        check(bad.isEmpty, "unresolved: \(bad.joined(separator: "; "))")
    }
    test("keys: the keyboard thread's question is answered on the main thread, and a late answer is kept") {
        let ran = Locked(false)
        let s = GlobalCommands.shared.script("test_mainkey", "", gestures: ["kb:control+option+shift+f16"]) { _ in ran.value = true }
        defer { s.isAvailable = { false } }
        let g = KeyboardGesture(identifier: "kb:control+option+shift+f16")!
        // 1. The main thread is free: the key thread gets its answer within the limit, and the script runs.
        let answer = Locked<ScriptHandler.KeyDecision?>(nil)
        let t0 = Date()
        Thread { answer.value = ScriptHandler.askMain(g) }.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        expect(answer.value, .taken, "answered while the main thread was free")
        check(Date().timeIntervalSince(t0) < 1, "quick")
        check(ran.value, "the script ran")
        // 2. The main thread is busy for longer than the limit: the key is swallowed (deferred), and when the main
        // thread gets to it the script still runs, rather than the key being lost or let through.
        ran.value = false; answer.value = nil
        Thread { answer.value = ScriptHandler.askMain(g) }.start()
        Thread.sleep(forTimeInterval: 0.4)   // busy: no run loop, no answer
        expect(answer.value, .deferred, "swallowed while the main thread was busy")
        check(!ran.value, "nothing ran while the main thread was busy")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        check(ran.value, "the late answer ran the script")
        // 3. An unbound key: passed.
        answer.value = nil
        Thread { answer.value = ScriptHandler.askMain(KeyboardGesture(identifier: "kb:control+option+shift+f15")!) }.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        expect(answer.value, .passed, "an unbound key goes to the application")
        if case .found(let found) = ScriptHandler.lookup(g) { expect(found.name, "test_mainkey") } else { Harness.fail("the main thread's own lookup") }
    }

    test("settings: an old file keeps its values and gets the defaults for the rest") {
        let json = """
        {"general": {"keyboardStyle": "windows", "windowsKeys": true}, "speech": {"rate": 0.5, "voice": "x"},
         "applications": {"leadBundles": ["com.apple.Safari"]}, "newSectionNobodyKnows": {"a": 1}}
        """.data(using: .utf8)!
        guard let c = try? JSONDecoder().decode(Config.self, from: json) else { return Harness.fail("did not decode") }
        check(c.general.windowsKeys, "windows style kept")
        expect(c.general.turnOverKey, "both", "a missing field gets its default")
        expect(c.speech.rate, 0.5)
        expect(c.speech.voice, "x")
        expect(c.applications.leadBundles, ["com.apple.Safari"])
        expect(c.keyboard.speakTypedCharacters, Config().keyboard.speakTypedCharacters, "a missing section is the default")
    }
    test("settings: a field of the wrong type does not lose the others") {
        let json = """
        {"general": {"keyboardStyle": 7, "bosunKey": "caps"}, "speech": {"rate": "fast", "volume": 40}}
        """.data(using: .utf8)!
        guard let c = try? JSONDecoder().decode(Config.self, from: json) else { return Harness.fail("did not decode") }
        expect(c.general.keyboardStyle, "mac", "a wrong type falls back")
        expect(c.general.turnOverKey, "caps", "the field beside it survives")
        expect(c.speech.volume, 40)
        expect(c.speech.rate, Config().speech.rate)
    }
    test("right Option T: the time and date, unless the user gives it something else") {
        let rt = KeyboardGesture(keyCode: 17, modifiers: .option, characters: "t", timestamp: 0, isRepeat: false, flags: CGEventFlags(rawValue: 0x80000 | 0x40))
        let lt = KeyboardGesture(keyCode: 17, modifiers: .option, characters: "t", timestamp: 0, isRepeat: false, flags: CGEventFlags(rawValue: 0x80000 | 0x20))
        expect(UserGestures.target(for: rt), .script("dateTime"), "right Option T")
        expect(UserGestures.target(for: lt) == nil, true, "left Option T still types")
        let saved = config.keyboard.userGestures
        config.keyboard.userGestures["kb:rightoption+t"] = "none"
        expect(UserGestures.target(for: rt), .removed, "the user's own choice wins")
        config.keyboard.userGestures = saved
    }
    test("the code name: settings and plugins from before the rename still work") {
        let json = """
        {"general": {"bosunKey": "controlOption"}, "keyboard": {"userGestures": {"kb:bosun+shift+0": "script:bosunMenu"}}}
        """.data(using: .utf8)!
        guard let c = try? JSONDecoder().decode(Config.self, from: json) else { return Harness.fail("did not decode") }
        expect(c.general.turnOverKey, "controlOption", "the TurnOver key setting keeps its stored name")
        expect(c.keyboard.userGestures["kb:turnover+shift+0"], "script:turnOverMenu", "an old saved key is carried over")
        expect(normalizeGestureIdentifier("kb:bosun+shift+p"), "kb:turnover+shift+p", "an old plugin's key")
        let out = String(data: try JSONEncoder().encode(Config()), encoding: .utf8) ?? ""
        expect(out.contains("\"bosunKey\""), true, "saved under the name older builds read")
    }
    test("settings: a round trip keeps every field") {
        var c = Config()
        c.general.keyboardStyle = "windows"; c.speech.rate = 0.42; c.applications.leadBundles = ["a", "b"]
        c.documentFormatting.roleOrder = "after"; c.presentation.reportNotifications = false
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(Config.self, from: data)
        expect(back.general.keyboardStyle, "windows")
        expect(back.speech.rate, 0.42)
        expect(back.applications.leadBundles, ["a", "b"])
        expect(back.documentFormatting.roleOrder, "after")
        expect(back.presentation.reportNotifications, false)
    }
    test("settings: the keyboard thread's snapshot follows the configuration") {
        let saved = config
        defer { config = saved; KeySettings.refresh() }
        config.general.keyboardStyle = "windows"; config.general.turnOverKey = "caps"
        KeySettings.refresh()
        check(KeySettings.current.windowsKeys, "windows keys")
        check(KeySettings.current.capsIsTurnOver, "caps is the TurnOver key")
        check(!KeySettings.current.controlOptionIsTurnOver, "control option is not")
    }

    test("feedback: the log is redacted") {
        let log = """
        [1.0] IO say: the secret text
        [1.1] IO say [fr]: bonjour
        [1.2] IO braille shows (line): private line
        [1.3] IO event gainFocus: AXTextArea "My Document"
        [1.4] IO input kb:a
        [1.5] IO input kb:shift+b
        [1.6] IO input kb:turnover+t → vo_title
        [1.7] IO browse mode: page https://example.com/private/path?q=1 — resuming
        [1.8] typed word: hello
        [1.9] IO notification banner: Mail: from someone
        """
        let r = Feedback.redact(log)
        check(!r.contains("secret"), "spoken text gone")
        check(!r.contains("bonjour"), "spoken text in another language gone")
        check(!r.contains("private line"), "braille line gone")
        check(!r.contains("My Document"), "quoted names gone")
        check(r.contains("input kb:[a key]"), "typed keys gone: \(r)")
        check(r.contains("kb:turnover+t → vo_title"), "scripts kept")
        check(!r.contains("private/path") && !r.contains("q=1"), "web paths gone")
        check(!r.contains("hello"), "typed words gone")
        check(!r.contains("from someone"), "banners gone")
        check(r.contains("event gainFocus: AXTextArea"), "events kept")
    }

    test("braille: short forms") {
        expect(Braille.brailleText(["Save", "button"]), "Save btn")
        expect(Braille.brailleText(["Wrap", "check box", "checked"]), "Wrap chk (x)")
        expect(Braille.brailleText(["News", "heading level 2"]), "News h2")
        expect(Braille.brailleText(["Folder", "level 3", "collapsed"]), "Folder lv 3 +")
        expect(Braille.brailleText(["Hello", "text"]), "Hello")
        expect(Braille.brailleText(["a", "b"], separator: ", "), "a, b")
    }

    test("braille: line breaks and placeholders are blank cells, offsets kept") {
        expect(Braille.displayed("one\ntwo"), "one two")
        expect(Braille.displayed("end\r\n"), "end  ")
        expect(Braille.displayed("a\u{2028}b\u{2029}c\u{FFFC}d\te"), "a b c d e")
        expect(Braille.displayed("šumniki čćž"), "šumniki čćž")
        let s = "x\u{2029}y"
        expect((Braille.displayed(s) as NSString).length, (s as NSString).length)
    }

    test("media: labels are tidied") {
        expect(MediaView.tidy("Show · Example Podcast"), "Show, Example Podcast")
    }
    test("media: a newer read merges into the shelves") {
        func item(_ label: String, _ ident: String = "") -> MediaView.Item { MediaView.Item(label: label, element: AXReplay.element(1), ident: ident) }
        let old = [MediaView.Shelf(title: "Top", items: [item("a"), item("b")]), MediaView.Shelf(title: "Next", items: [item("c")])]
        let new = [MediaView.Shelf(title: "Next", items: [item("c"), item("d")]), MediaView.Shelf(title: "Later", items: [item("e")])]
        let m = MediaView.merge(old, new)
        expect(m.map(\.title), ["Top", "Next", "Later"])
        expect(m[1].items.map(\.label), ["c", "d"], "the known shelf takes the new items")
    }

    test("languages: a character's script picks the voice") {
        let saved = config
        defer { config = saved }
        config.speech.autoLanguageSwitching = true; config.speech.voice = "com.apple.eloquence.en-GB.Reed"
        expect(Languages.forCharacter("م", marked: nil), "ar")
        expect(Languages.forCharacter("б", marked: nil), "ru")
        expect(Languages.forCharacter("a", marked: nil), nil, "a Latin letter keeps the main voice")
        expect(Languages.forCharacter("3", marked: nil), nil, "a digit keeps the main voice")
        expect(Languages.forCharacter("م", marked: "fa"), "fa", "the text's own marking wins for the same script")
        expect(Languages.forCharacter("م", marked: "en"), "ar", "a Latin marking on an Arabic letter is wrong")
        config.speech.autoLanguageSwitching = false
        expect(Languages.forCharacter("م", marked: nil), nil, "off means off")
    }
    test("languages: unmarked text in another script is recognised") {
        let saved = config
        defer { config = saved }
        config.speech.autoLanguageSwitching = true; config.speech.voice = "com.apple.eloquence.en-GB.Reed"
        expect(Languages.detectUnmarked("مرحبا بكم في هذا البرنامج الجديد"), "ar")
        expect(Languages.detectUnmarked("Hello there, this is English text"), nil)
    }
    test("formatting: colours in words") {
        func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
        expect(FormatField.name(ofColour: c(0, 0, 0)), "black")
        expect(FormatField.name(ofColour: c(1, 1, 1)), "white")
        expect(FormatField.name(ofColour: c(1, 0, 0)), "red")
        expect(FormatField.name(ofColour: c(0.4, 0, 0)), "dark red")
        expect(FormatField.name(ofColour: c(0, 0, 1)), "blue")
        expect(FormatField.name(ofColour: c(0.5, 0.5, 0.5)), "light grey")
    }
    test("VoiceOver export: the default voice, rate, volume, verbosity and typing echo are read; activities are ignored") {
        let plist: [String: Any] = ["ArchiveType": 1, "ArchiveVersionVO": 4, "export": [
            "allProfiles": [["profileInfo": ["profileName": "Safari"], "VoiceOverDefaultVoiceSelections": ["en", ["voiceId": "wrong.voice", "rate": 0.9]]]],
            "default": ["VoiceOverDefaultVoiceSelections": ["en", ["_type": "Speech.VoiceSelection", "voiceId": "com.apple.speech.synthesis.voice.Alex", "rate": 0.65, "pitch": 0.5, "volume": 1.0]],
                        "SCRVerbosity_SCRVerbosityLevel": "SCRVerbosityLow", "SCRTypingEchoFeedback": "SCRTypingEchoWords"]]]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(getpid()).voprefs")
        try? (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))?.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let c = try? VoiceOverSettings.read(url) else { return Harness.fail("export not read") }
        expect(c.voiceId, "com.apple.speech.synthesis.voice.Alex"); expect(c.rate, 0.65); expect(c.volume, 1); expect(c.pitch, 0.5)
        expect(c.verbosity, "SCRVerbosityLow"); expect(c.typingEcho, "SCRTypingEchoWords"); expect(c.archiveVersion, 4)
        expect((try? VoiceOverSettings.read(FileManager.default.temporaryDirectory.appendingPathComponent("missing.voprefs"))) == nil, true)
    }
    test("recipes: the built-in recipes load and describe the apps as the code did") {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        Recipes.load(builtIn: repo.appendingPathComponent("Resources/recipes"), plugins: [])
        expect(Recipes.problems.count, 0, "problems: \(Recipes.problems)")
        expect(Recipes.bundles(kind: "chat"), ["com.apple.MobileSMS", "com.hnc.Discord", "net.whatsapp.WhatsApp"])
        expect(Recipes.bundles(kind: "media"), ["com.apple.Music", "com.apple.TV", "com.apple.podcasts"])
        guard let w = Recipes.recipe(for: "net.whatsapp.WhatsApp")?.view.chat, let m = Recipes.recipe(for: "com.apple.MobileSMS")?.view.chat else { return Harness.fail("recipes missing") }
        let spec = ChatView.Spec(w)
        expect(spec.composerID, "ChatBar_ComposerTextView"); expect(spec.saysSent, true); expect(spec.resultsPrefix, "ChatListSearchView_")
        // Messages and WhatsApp find their parts by identifier, as before; only Discord's recipe matches by label.
        expect(spec.partMatch.isEmpty, true); expect(ChatView.Spec(m).partMatch.isEmpty, true)
        if let d = Recipes.recipe(for: "com.hnc.Discord")?.view.chat {
            expect(Set(ChatView.Spec(d).partMatch.keys), ["discord.channels", "discord.messages", "discord.box", "discord.title"])
        } else { Harness.fail("Discord's recipe missing") }
        var f = AXFixture(app: "T", bundle: "t", recorded: "", root: 0, application: nil, focus: nil, nodes: [])
        f.nodes = [
            .init(id: 0, attrs: ["AXRole": .string("AXButton")]),                                                        // a WhatsApp chat row
            .init(id: 1, attrs: ["AXRole": .string("AXButton"), "AXIdentifier": .string("Something")]),                 // a button with a name: not a chat
            .init(id: 2, attrs: ["AXRole": .string("AXGroup"), "AXIdentifier": .string("ChatListSearchView_ContactResult")]),
            .init(id: 3, attrs: ["AXRole": .string("AXStaticText")]),                                                    // a Messages conversation, a WhatsApp message
            .init(id: 4, attrs: ["AXRole": .string("AXHeading")]),
            .init(id: 5, attrs: ["AXRole": .string("AXImage")]),
        ]
        AXReplay.load(f); defer { AXReplay.unload() }
        check(spec.isConversation(AXReplay.element(0)), "a nameless button is a WhatsApp chat")
        check(!spec.isConversation(AXReplay.element(1)), "a named button is not")
        check(spec.isConversation(AXReplay.element(2)), "a search result is")
        check(spec.isMessage(AXReplay.element(3)) && spec.isMessage(AXReplay.element(4)) && !spec.isMessage(AXReplay.element(5)), "WhatsApp messages: text and headings")
        let ms = ChatView.Spec(m)
        check(ms.isConversation(AXReplay.element(3)) && !ms.isConversation(AXReplay.element(0)), "Messages conversations are static texts")
        check(ms.isMessage(AXReplay.element(5)), "Messages: anything in the transcript is a message")
    }
    test("recipes: a broken built-in file is reported by name, the rest load") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("turnover-recipe-test-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "{\"bundle\": \"x.one\", \"name\": \"One\", \"view\": {\"kind\": \"chat\", \"chat\": {\"conversations\": \"a\", \"transcript\": \"b\", \"composer\": \"c\", \"title\": \"d\", \"message\": {}, \"conversation\": {}}}}".write(to: dir.appendingPathComponent("x.one.json"), atomically: true, encoding: .utf8)
        try "{\"bundle\": \"x.two\", \"name\": \"Two\", \"view\": {\"kind\": \"chat\"}}".write(to: dir.appendingPathComponent("x.two.json"), atomically: true, encoding: .utf8)
        try "{\"bundle\": \"x.three\", \"name\": \"Three\", \"view\": {\"kind\": \"spreadsheet\"}}".write(to: dir.appendingPathComponent("x.three.json"), atomically: true, encoding: .utf8)
        try "not json".write(to: dir.appendingPathComponent("x.four.json"), atomically: true, encoding: .utf8)
        Recipes.load(builtIn: dir, plugins: [])
        expect(Recipes.bundles(kind: "chat"), ["x.one"])
        expect(Recipes.problems.map(\.file).sorted(), ["x.four.json", "x.three.json", "x.two.json"])
        check(Recipes.problems.contains { $0.file == "x.two.json" && $0.reason.contains("chat") }, "the missing section is named: \(Recipes.problems)")
        check(Recipes.problems.contains { $0.file == "x.three.json" && $0.reason.contains("spreadsheet") }, "the unknown kind is named: \(Recipes.problems)")
    }
    test("recipes: a plugin's view takes over the app, and its warnings are in words") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("turnover-plugins-test-\(getpid())")
        let plugin = dir.appendingPathComponent("my-chat")
        try? FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "{\"id\": \"my-chat\", \"name\": \"My chat\", \"version\": \"0.1\", \"apps\": [\"net.whatsapp.WhatsApp\"]}".write(to: plugin.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "{\"keys\": [{\"key\": \"turnover+shift+q\", \"description\": \"Quit\", \"action\": \"keys\", \"keys\": \"command+q\"}, {\"key\": \"turnover+shift+r\", \"description\": \"Read\", \"action\": \"read\", \"target\": {\"role\": \"button\"}}], \"view\": {\"kind\": \"chat\", \"chat\": {\"conversations\": \"a\", \"transcript\": \"b\", \"composer\": \"c\", \"title\": \"d\", \"message\": {}, \"conversation\": {}}}}".write(to: plugin.appendingPathComponent("profile.json"), atomically: true, encoding: .utf8)
        let loaded = ProfileStore.load(folder: plugin)
        expect(loaded.error, nil); expect(loaded.recipes.map(\.bundle), ["net.whatsapp.WhatsApp"])
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        Recipes.load(builtIn: repo.appendingPathComponent("Resources/recipes"), plugins: [loaded])
        expect(Recipes.recipe(for: "net.whatsapp.WhatsApp")?.name, "My chat", "the plugin's view wins over the built-in recipe")
        expect(Recipes.recipe(for: "com.apple.MobileSMS")?.name, "Messages", "the others stay")
        let w = PluginChecker.warnings(for: loaded)
        expect(w.lines.count, 2, "the apps it claims, then the key that sends keys: \(w.lines)")
        check(w.lines.first?.hasPrefix("it works in") == true, "the apps first: \(w.lines)")
        check(w.lines.last?.contains("command q") == true, "in words: \(w.lines)")
        check(w.needsConfirmation, "quitting needs a confirmation")
        // A view of a shape TurnOver has no view for is refused, by name.
        try "{\"view\": {\"kind\": \"spreadsheet\"}}".write(to: plugin.appendingPathComponent("profile.json"), atomically: true, encoding: .utf8)
        check(ProfileStore.load(folder: plugin).error?.contains("spreadsheet") == true, "refused: \(ProfileStore.load(folder: plugin).error ?? "no error")")
        Recipes.load(builtIn: repo.appendingPathComponent("Resources/recipes"), plugins: [])
    }
    test("recipes: the panes shape validates and loads (Notes)") {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        Recipes.load(builtIn: repo.appendingPathComponent("Resources/recipes"), plugins: [])
        expect(Recipes.bundles(kind: "panes"), ["com.apple.Notes"])
        expect(Recipes.recipe(for: "com.apple.Notes")?.view.panes?.parts.map(\.name), ["Folders", "Notes list", "Note"])
        var v = RecipeView(kind: "panes", chat: nil, panes: RecipeView.Panes(parts: []))
        check((try? v.validate()) == nil, "no parts is refused")
        v.panes = RecipeView.Panes(parts: [.init(name: "A", match: ElementMatch(), hint: nil)])
        check((try? v.validate()) != nil, "one part is enough")
        // A panes view against a made-up window: the parts are found by their matches.
        var f = AXFixture(app: "T", bundle: "t", recorded: "", root: 0, application: 9, focus: 2, nodes: [])
        f.nodes = [
            .init(id: 0, attrs: ["AXRole": .string("AXWindow"), "AXChildren": .elements([1, 2, 3]), "AXParent": .element(9)]),
            .init(id: 1, attrs: ["AXRole": .string("AXOutline"), "AXDescription": .string("Folders"), "AXParent": .element(0), "AXRows": .elements([])]),
            .init(id: 2, attrs: ["AXRole": .string("AXTable"), "AXIdentifier": .string("ICMNoteListTableView_asList[x]"), "AXParent": .element(0)]),
            .init(id: 3, attrs: ["AXRole": .string("AXTextArea"), "AXIdentifier": .string("Note[id=1]"), "AXParent": .element(0), "AXValue": .string("hi")]),
            .init(id: 9, attrs: ["AXRole": .string("AXApplication"), "AXWindows": .elements([0]), "AXFocusedWindow": .element(0), "AXFocusedUIElement": .element(2)]),
        ]
        AXReplay.load(f); defer { AXReplay.unload() }
        let view = PanesView(pid: 900_009, panes: Recipes.recipe(for: "com.apple.Notes")!.view.panes!)
        // A part is never looked for inside a list's rows (Notes' 800 rows held the main thread for seconds).
        f.nodes[2].attrs["AXChildren"] = .elements([10])
        f.nodes.append(.init(id: 10, attrs: ["AXRole": .string("AXRow"), "AXParent": .element(2), "AXChildren": .elements([11])]))
        f.nodes.append(.init(id: 11, attrs: ["AXRole": .string("AXTextArea"), "AXIdentifier": .string("Note[inside a row]"), "AXParent": .element(10)]))
        AXReplay.load(f)
        expect(view.element(of: 0).flatMap(AXReplay.id(of:)), 1, "Folders found")
        expect(view.element(of: 1).flatMap(AXReplay.id(of:)), 2, "the notes list found")
        expect(view.element(of: 2).flatMap(AXReplay.id(of:)), 3, "the note found, not the one inside a row")
        API.setFocusObject(ObjectFactory.make(AXReplay.element(2)), ancestors: [])
        expect(view.currentIndex(), 1, "the focus is in the notes list")
        API.setFocusObject(nil, ancestors: [])
    }
    test("web buffer: lines wrap at spaces, never past the length, and cover the text") {
        let t = "TurnOver - The Mac screenreader for when voiceover isn't quite up to it... Call for closed beta" as NSString
        let pieces = WebBuffer.wrapPieces(t, maxLen: 24)
        expect(pieces.first?.0, 0); expect(pieces.last?.1, t.length)
        for (i, p) in pieces.enumerated() {
            check(p.1 - p.0 <= 24 && p.1 > p.0, "piece \(i) is \(p.1 - p.0) long")
            if i > 0 { expect(pieces[i - 1].1, p.0, "pieces are contiguous") }
            if p.1 < t.length { expect(t.character(at: p.1 - 1), 32, "a piece that is not the last ends at a space: \(t.substring(with: NSRange(location: p.0, length: p.1 - p.0)))") }
        }
        expect(t.substring(with: NSRange(location: pieces[0].0, length: pieces[0].1 - pieces[0].0)), "TurnOver - The Mac ")
        expect(WebBuffer.wrapPieces("short", maxLen: 24).count, 1)
        expect(WebBuffer.wrapPieces("", maxLen: 24).count, 0)
        // A word longer than the length is cut hard rather than lost.
        let long = String(repeating: "a", count: 50) as NSString
        expect(WebBuffer.wrapPieces(long, maxLen: 20).map { $0.1 - $0.0 }, [20, 20, 10])
    }
    test("web buffer: a wrapped line's later pieces continue their element, a new element does not") {
        let h = AXReplay.element(1), t = AXReplay.element(2)
        let lines = [
            WebBuffer.Line(start: 0, end: 24, element: h, entering: [h], isControl: false, fields: [], hasBreak: false),
            WebBuffer.Line(start: 24, end: 40, element: h, entering: [], isControl: false, fields: [], hasBreak: true),
            WebBuffer.Line(start: 40, end: 60, element: t, entering: [], isControl: false, fields: [], hasBreak: true),
            WebBuffer.Line(start: 60, end: 70, element: h, entering: [h], isControl: false, fields: [], hasBreak: true),   // the heading again, entered afresh
        ]
        check(!WebBuffer.continues(lines, 0), "the first line starts its element")
        check(WebBuffer.continues(lines, 1), "the second piece continues the heading")
        check(!WebBuffer.continues(lines, 2), "a different element is not a continuation")
        check(!WebBuffer.continues(lines, 3), "entering the element again is a new one")
    }
    test("spelling: the word at the caret's edge is found, and the Mac's checker finds every word") {
        // "Thiss is a toste of spelling ": Safari's comment box, 14 Oct 2026.
        let words = [NSRange(location: 0, length: 5), NSRange(location: 11, length: 5)]
        expect(EditableText.misspellingTarget(words, caret: 0, forward: true, placedHere: false)?.location, 0, "forward from the start finds the first word")
        expect(EditableText.misspellingTarget(words, caret: 0, forward: true, placedHere: true)?.location, 11, "and moves on once there")
        expect(EditableText.misspellingTarget(words, caret: 5, forward: false, placedHere: false)?.location, 0, "back from the end of the word just typed")
        expect(EditableText.misspellingTarget(words, caret: 29, forward: false, placedHere: false)?.location, 11, "back from the end of the text")
        check(EditableText.misspellingTarget(words, caret: 11, forward: true, placedHere: true) == nil, "none after the last")
        check(EditableText.misspellingTarget(words, caret: 0, forward: false, placedHere: false) == nil, "none before the first")
        let text = "Thiss is a toste of spelling "
        let found = NSSpellChecker.shared.check(text, range: NSRange(location: 0, length: (text as NSString).length),
            types: NSTextCheckingResult.CheckingType.spelling.rawValue, options: nil, inSpellDocumentWithTag: 0, orthography: nil, wordCount: nil)
        expect(found.map(\.range.location), [0, 11], "both words, not only the first")
    }
    test("spelling: ordinary apps supplement partial marks without duplicating them") {
        let text = NSMutableAttributedString(string: "Thiss is a toste of spelling ")
        text.addAttribute(NSAttributedString.Key("AXMarkedMisspelled"), value: true, range: NSRange(location: 0, length: 6))
        text.addAttribute(NSAttributedString.Key("AXMisspelled"), value: true, range: NSRange(location: 0, length: 5))
        let module = AppModule(pid: 0, bundleIdentifier: "test.editor", appName: "Editor")
        let words = EditableText.misspellingRanges(in: text, appModule: module)
        expect(words, [NSRange(location: 0, length: 5), NSRange(location: 11, length: 5)], "trimmed app mark and the additional system result")
        expect(EditableText.misspellingTarget(words, caret: 0, forward: true, placedHere: true)?.location, 11, "navigation reaches the unmarked error")
    }
    test("spelling: Word keeps its dictionary's marks in shared editing controls") {
        BuiltInModules.register()
        guard let type = AppModuleHandler.shared.moduleType(for: "com.microsoft.Word") else { return Harness.fail("Word's module is registered") }
        let module = type.init(pid: 0, bundleIdentifier: "com.microsoft.Word", appName: "Word")
        // These ranges go through EditableText's shared path, also used by dialog fields without a Word overlay.
        for key in ["AXMarkedMisspelled", "AXMisspelled"] {
            let text = NSMutableAttributedString(string: "Thiss is a toste of spelling ")
            text.addAttribute(NSAttributedString.Key(key), value: true, range: NSRange(location: 0, length: 5))
            let words = EditableText.misspellingRanges(in: text, appModule: module)
            expect(words, [NSRange(location: 0, length: 5)], "\(key): the system checker must not add a word Word accepted")
            expect(EditableText.misspellingTarget(words, caret: 0, forward: true, placedHere: true), nil, "no additional error after Word's mark")
        }
    }
    test("spelling: Word falls back to the system checker without usable marks") {
        BuiltInModules.register()
        guard let type = AppModuleHandler.shared.moduleType(for: "com.microsoft.Word") else { return Harness.fail("Word's module is registered") }
        let module = type.init(pid: 0, bundleIdentifier: "com.microsoft.Word", appName: "Word")
        let text = NSMutableAttributedString(string: "Thiss is a toste of spelling ")
        let expected = [NSRange(location: 0, length: 5), NSRange(location: 11, length: 5)]
        expect(EditableText.misspellingRanges(in: text, appModule: module), expected, "no marks")
        text.addAttribute(NSAttributedString.Key("AXMarkedMisspelled"), value: true, range: NSRange(location: 5, length: 1))
        expect(EditableText.misspellingRanges(in: text, appModule: module), expected, "a whitespace-only mark still needs the fallback")
    }
    test("spelling: the module's preference controls supplementation") {
        final class OwnDictionaryModule: AppModule {
            override var supplementsSpellingMarks: Bool { false }
        }
        let text = NSMutableAttributedString(string: "Thiss is a toste of spelling ")
        text.addAttribute(NSAttributedString.Key("AXMisspelled"), value: true, range: NSRange(location: 0, length: 5))
        let ownDictionary = OwnDictionaryModule(pid: 0, bundleIdentifier: "test.dictionary", appName: "Dictionary")
        expect(EditableText.misspellingRanges(in: text, appModule: ownDictionary), [NSRange(location: 0, length: 5)], "a module can trust its own dictionary")
        let base = AppModule(pid: 0, bundleIdentifier: "com.microsoft.Word", appName: "Word")
        expect(EditableText.misspellingRanges(in: text, appModule: base), [NSRange(location: 0, length: 5), NSRange(location: 11, length: 5)], "the bundle identifier alone does not select the preference")
    }
    test("slow drip: slow answers add up to a rest; a quiet spell starts the count again") {
        let ms: UInt64 = 1_000_000
        var state: AXHealth.DripCount? = nil
        var rested = false
        // A game answering every 60 ms: twenty answers (1.2 s) are fine, the next one rests it.
        for i in 0..<21 { let r = AXHealth.dripStep(state, now: UInt64(i) * 60 * ms, took: 60 * ms); state = r.state; rested = r.rest }
        check(rested, "60 ms answers, 21 in a row: rested")
        check(state == nil, "the count starts again after a rest")
        var s2: AXHealth.DripCount? = nil
        var r2 = false
        for i in 0..<20 { let r = AXHealth.dripStep(s2, now: UInt64(i) * 60 * ms, took: 60 * ms); s2 = r.state; r2 = r.rest }
        check(!r2, "twenty slow answers (1.2 s): not yet")
        let later = AXHealth.dripStep(s2, now: 5_000 * ms, took: 60 * ms)
        check(!later.rest && later.state?.ns == 60 * ms, "a slow answer 5 s later counts on its own")
    }
    test("Numbers: a cell's address") {
        expect(CellAddress.of(row: 0, col: 0), "A1", "the first cell")
        expect(CellAddress.of(row: 2, col: 1), "B3", "column B, row 3")
        expect(CellAddress.of(row: 11, col: 27), "AB12", "past Z")
    }
    test("own keys: right Option with Shift is its own key") {
        let rightOptionShift = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskShift.rawValue | 0x40 | 0x4)
        let g = KeyboardGesture(keyCode: 45, modifiers: [.option, .shift], characters: "", timestamp: 0, isRepeat: false, flags: rightOptionShift)
        expect(UserGestures.storedIdentifier(of: g), "kb:rightoption+shift+n", "right Option Shift N, not Option Shift N")
        let left = KeyboardGesture(keyCode: 45, modifiers: [.option, .shift], characters: "", timestamp: 0, isRepeat: false, flags: [.maskAlternate, .maskShift])
        check(UserGestures.storedIdentifier(of: left) != "kb:rightoption+shift+n", "left Option Shift N stays the plain key")
        expect(UserGestures.spoken("kb:rightoption+shift+n"), "right option shift n", "said as pressed")
    }
    test("direct apps: known by bundle, or by name when a program has none") {
        expect(InputManager.directKey(bundle: "com.example.game", name: "Game"), "com.example.game", "a bundle identifier")
        expect(InputManager.directKey(bundle: nil, name: "godot"), "process:godot", "a Godot game run from Terminal")
    }
    test("speech port: a trusted app speaks and stops only while it is in front") {
        expect(Games.bridgeAction("S hello there", speakerInFront: true), .speak("hello there"), "in front: said")
        expect(Games.bridgeAction("S hello there", speakerInFront: false), .dropped, "in the background: not said")
        expect(Games.bridgeAction("X", speakerInFront: true), .stop, "in front: stops")
        expect(Games.bridgeAction("X", speakerInFront: false), .dropped, "in the background: doesn't stop TurnOver")
        expect(Games.bridgeAction("nonsense", speakerInFront: true), .ignored, "anything else: ignored")
    }
    test("spelling corrections: the word at the caret, or the one just typed before it") {
        let t = "Dinner with mastacation crew" as NSString
        expect(SpellingCorrections.wordRange(in: t, at: 14).map { t.substring(with: $0) }, "mastacation", "the caret inside the word")
        expect(SpellingCorrections.wordRange(in: t, at: 23).map { t.substring(with: $0) }, "mastacation", "the caret just after it")
        expect(SpellingCorrections.wordRange(in: t, at: 12).map { t.substring(with: $0) }, "mastacation", "the caret at its start")
        let q = "say 'hello' don\u{2019}t" as NSString
        expect(SpellingCorrections.wordRange(in: q, at: 6).map { q.substring(with: $0) }, "hello", "not its quote marks")
        expect(SpellingCorrections.wordRange(in: q, at: 14).map { q.substring(with: $0) }, "don\u{2019}t", "an apostrophe inside it kept")
        check(SpellingCorrections.wordRange(in: "a  b" as NSString, at: 2) == nil, "between words, after a space: none")
    }
    test("Steam speech plugin: only the library's official one switches it on; the feature must exist") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gs-\(UUID().uuidString)")
        let plugin = dir.appendingPathComponent("steam-speech")
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifest = #"{"id": "steam-speech", "name": "Steam speech", "version": "1.0", "apps": ["com.valvesoftware.steam"], "provides": "games"}"#
        try manifest.write(to: plugin.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: plugin.appendingPathComponent("profile.json"), atomically: true, encoding: .utf8)
        let loaded = ProfileStore.load(folder: plugin)
        check(loaded.error == nil, "it loads: \(loaded.error ?? "")")
        check(!Games.providesGames([loaded]), "copied in by hand: does nothing")
        let receipt = { (level: String, id: String) in
            try? #"{"id": "\#(id)", "version": "1.0", "sha256": "x", "level": "\#(level)", "installed": "2026-10-14T00:00:00Z"}"#
                .write(to: plugin.appendingPathComponent(".library.json"), atomically: true, encoding: .utf8)
        }
        receipt("Community", "steam-speech")
        check(!Games.providesGames([loaded]), "from the library at Community: does nothing")
        receipt("Official", "other-plugin")
        check(!Games.providesGames([loaded]), "a receipt for another plugin: does nothing")
        receipt("Official", "steam-speech")
        check(Games.providesGames([loaded]), "the library's official one: on")
        check(!PluginPolicy.check(loaded, level: .community).libraryOnly.filter { $0.contains("provides") }.isEmpty, "listing at Community: refused")
        check(PluginPolicy.check(loaded, level: .official).libraryOnly.isEmpty && PluginPolicy.check(loaded, level: .official).refused.isEmpty, "listing at Official: fine")
        try manifest.replacingOccurrences(of: "\"games\"", with: "\"rootkit\"").write(to: plugin.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        check(!PluginPolicy.check(ProfileStore.load(folder: plugin), level: .official).refused.isEmpty, "a feature TurnOver doesn't have: refused")
        check(PluginChecker.warnings(for: loaded).lines.contains { $0.contains("debugging port") }, "the install warning names the debugging port")
    }
    test("app kinds: what an app is built with decides whether TurnOver has the parts") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kinds-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        func bundle(_ name: String, _ paths: [String]) throws -> URL {
            let b = dir.appendingPathComponent("\(name).app")
            for p in paths { try FileManager.default.createDirectory(at: b.appendingPathComponent("Contents/\(p)"), withIntermediateDirectories: true) }
            try FileManager.default.createDirectory(at: b.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            return b
        }
        expect(AppKind.detect(bundle: try bundle("E", ["Frameworks/Electron Framework.framework"])).name, "Electron")
        expect(AppKind.detect(bundle: try bundle("Q", ["Frameworks/QtCore.framework"])).partsReady, false)
        expect(AppKind.detect(bundle: try bundle("F", ["Frameworks/FlutterMacOS.framework"])).name, "Flutter")
        expect(AppKind.detect(bundle: try bundle("J", ["Java"])).name, "Java")
        expect(AppKind.detect(bundle: try bundle("A", [])), AppKind.apple)
        // Real apps, where this Mac has them (measured 14 Oct 2026).
        for (path, name) in [("/Applications/Claude.app", "Electron"), ("/Applications/BambuStudio.app", "wxWidgets"), ("/System/Applications/Calculator.app", AppKind.apple.name)]
        where FileManager.default.fileExists(atPath: path) {
            expect(AppKind.detect(bundle: URL(fileURLWithPath: path)).name, name, path)
        }
    }
    test("plugin try: consent per app and in time; no keys that quit, close, delete or leave the app") {
        let now = Date()
        let consents = ["com.apple.dt.Xcode": now.addingTimeInterval(3600), "com.tinyspeck.slackmacgap": now.addingTimeInterval(-1)]
        check(PluginTry.refusal(bundle: "com.apple.dt.Xcode", steps: ["downArrow", "wait 1", "turnover+control+shift+s", "command+2"], consents: consents, now: now) == nil, "allowed in Xcode")
        check(PluginTry.refusal(bundle: "com.tinyspeck.slackmacgap", steps: ["downArrow"], consents: consents, now: now) != nil, "consent ran out")
        check(PluginTry.refusal(bundle: "com.apple.calculator", steps: ["downArrow"], consents: consents, now: now) != nil, "never asked for")
        check(PluginTry.refusal(bundle: "com.apple.Terminal", steps: ["downArrow"], consents: ["com.apple.Terminal": now.addingTimeInterval(60)], now: now) != nil, "closed apps never")
        for bad in ["command+q", "command+w", "command+backspace", "command+tab", "command+v", "command+control+.", "command+f5", "control+rightArrow", "wait 99", "notakey"] {
            check(PluginTry.refusal(bad) != nil, "refused: \(bad)")
        }
        for ok in ["return", "escape", "tab", "space", "command+2", "turnover+f5", "shift+tab", "wait 0.5"] {
            check(PluginTry.refusal(ok) == nil, "allowed: \(ok): \(PluginTry.refusal(ok) ?? "")")
        }
        check(PluginTry.refusal(bundle: "com.apple.dt.Xcode", steps: Array(repeating: "downArrow", count: 31), consents: consents, now: now) != nil, "at most 30 keys")
    }
    test("text tables: entering, moving and leaving a table say what NVDA says") {
        let t = NSRange(location: 18, length: 16)
        let a = TextTables.Place(table: t, rows: 2, columns: 2, row: 0, column: 0)
        expect(TextTables.news(from: nil, to: a), "table with 2 rows and 2 columns, row 1, column 1")
        expect(TextTables.news(from: a, to: TextTables.Place(table: t, rows: 2, columns: 2, row: 0, column: 1)), "column 2")
        expect(TextTables.news(from: a, to: TextTables.Place(table: t, rows: 2, columns: 2, row: 1, column: 0)), "row 2")
        expect(TextTables.news(from: a, to: TextTables.Place(table: t, rows: 2, columns: 2, row: 1, column: 1)), "row 2, column 2")
        check(TextTables.news(from: a, to: a) == nil, "the same cell says nothing")
        expect(TextTables.news(from: a, to: nil), "out of table")
        check(TextTables.news(from: nil, to: nil) == nil, "plain text says nothing")
        let other = TextTables.Place(table: NSRange(location: 60, length: 9), rows: 1, columns: 3, row: 0, column: 2)
        expect(TextTables.news(from: a, to: other), "table with 1 row and 3 columns, row 1, column 3")
        // The tone setting: the sound on entering and leaving; the cell still said.
        check(TextTables.newsWithTone(from: nil, to: a) == (true, "row 1, column 1"), "entering: sound and cell")
        check(TextTables.newsWithTone(from: a, to: TextTables.Place(table: t, rows: 2, columns: 2, row: 1, column: 0)) == (false, "row 2"), "moving: words only")
        check(TextTables.newsWithTone(from: a, to: nil) == (true, nil), "leaving: the sound only")
    }
    test("plugin read: a group's texts as separate phrases (parts request #3)") {
        expect(ElementMatcher.joinItems(["Example Game", "Last played", "27 days ago", "Progress", "24%"]), "Example Game, Last played, 27 days ago, Progress, 24%")
        expect(ElementMatcher.joinItems(["Done.", "Next one"]), "Done. Next one")
        expect(ElementMatcher.joinItems(["Only"]), "Only")
        expect(ElementMatcher.joinItems([]), "")
    }
    test("Libation's parts (#4 to #6): class names aren't names; the hold rule and the new nameFrom values are part of the format") {
        check(TurnOverObject.isClassName("Avalonia.Controls.Grid"), "a class name")
        check(!TurnOverObject.isClassName("Book download pending"), "words")
        check(!TurnOverObject.isClassName("www.example.com"), "an address")
        check(!TurnOverObject.isClassName("v1.2.3"), "a version")
        check(PluginFormat.choices["nameFrom"]?.contains("ancestorHelp") == true && PluginFormat.choices["nameFrom"]?.contains("rowText") == true, "new nameFrom values")
        let p = try JSONDecoder().decode(Profile.self, from: Data(#"{"hold": [{"focus": {"identifier": "productsGrid"}, "items": {"identifier": "PART_RowsPresenter"}}]}"#.utf8))
        expect(p.hold?.first?.items.identifier, "PART_RowsPresenter")
    }
    test("locked: reads and writes") {
        let l = Locked(1)
        l.value = 2
        expect(l.value, 2)
    }
}

/// Browse mode's P and N on a made-up page: a link bar, a heading, a paragraph, more links, a closing paragraph.
func browseTextNavTests() {
    test("speech parity: VoiceOver's reported value is read") {
        expect(SpeechParity.parsePercent("75%"), 75, "a bare percentage")
        expect(SpeechParity.parsePercent("Rate 100 %"), 100, "with words and a space")
        expect(SpeechParity.parsePercent("Arrow-key Quick Nav on"), nil, "no number: nothing")
    }
    test("keyboard styles: four, in two families, stored as before") {
        expect(KeyboardStyle(rawValue: "mac"), .voiceOver, "mac is VoiceOver keys")
        expect(KeyboardStyle(rawValue: "windows"), .nvda, "windows is NVDA keys")
        expect(KeyboardStyle.jaws.family == .windows, true, "JAWS keys are the Windows family")
        expect(KeyboardStyle.narrator.family == .windows, true, "Narrator keys are the Windows family")
        expect(KeyboardStyle.voiceOver.family == .mac, true, "VoiceOver keys are the Mac family")
        var c = Config()
        c.general.keyboardStyle = "jaws"
        expect(c.general.windowsKeys, true, "JAWS keys answer windowsKeys")
        expect(c.general.macKeys, false, "and not macKeys")
        let saved = try? JSONEncoder().encode(c)
        let back = saved.flatMap { try? JSONDecoder().decode(Config.self, from: $0) }
        expect(back?.general.keyboardStyle, "jaws", "a JAWS style survives a save")
        let odd = try? JSONDecoder().decode(Config.self, from: Data(#"{"general": {"keyboardStyle": "orca"}}"#.utf8))
        expect(odd?.general.keyboardStyle, "mac", "an unknown style falls back to VoiceOver keys")
    }
    test("keyboard styles: the pieces of an announcement, commas in the Mac family, spaces in the Windows family") {
        let saved = config
        defer { config = saved }
        config.general.keyboardStyle = "mac"
        expect(Speech.joined(["Settings", "submenu", "", "3 of 9"]), "Settings, submenu, 3 of 9", "VoiceOver keys: commas, empties left out")
        config.general.keyboardStyle = "windows"
        expect(Speech.joined(["Settings", "submenu", "", "3 of 9"]), "Settings submenu 3 of 9", "NVDA keys: spaces, no pause at each piece")
        config.general.keyboardStyle = "jaws"
        expect(Speech.joined(["OK", "button"]), "OK button", "JAWS keys: the Windows family's way")
    }
    test("JAWS keys: every key names a real command or another key, and plain keys only during say all") {
        let jaws = StyleKeymap.keys(for: .jaws)
        check(jaws.count >= 50, "the JAWS table has its keys (\(jaws.count))")
        let vo = VoiceOverKeysPlugin()
        for (key, value) in jaws {
            check(key.contains("turnover+"), "\(key): a JAWS key holds the JAWS key (Caps Lock), so it never takes typing")
            if value.hasPrefix("=") {
                check(KeyboardGesture(identifier: String(value.dropFirst())) != nil, "\(key) → \(value): the other key is a real key")
            } else {
                check(GlobalCommands.shared.script(named: value) != nil || vo.script(named: value) != nil, "\(key) → \(value): a command TurnOver has")
            }
        }
        // Caps Lock H is JAWS's Say Sentence. It pointed at "=kb:turnover+control+s", and NVDA+Control+S opens the
        // Speech settings in the Windows family since 12 Oct 2026 (NVDA-PARITY.md, decision 6), so Caps Lock H
        // opened them too (Guides/11-keys-jaws.md, 21 Oct 2026: "TurnOver H | Opens TurnOver's Speech").
        expect(jaws[normalizeGestureIdentifier("kb:turnover+h")], "reportCurrentSentence", "Caps Lock H reads the sentence, as JAWS's Say Sentence")
        let sayAll = StyleKeymap.sayAllKeys(for: .jaws)
        expect(sayAll[normalizeGestureIdentifier("kb:leftArrow")], "jaws_sayAllBack", "Left during say all goes back")
        expect(sayAll[normalizeGestureIdentifier("kb:pageUp")], "jaws_sayAllFaster", "Page Up during say all is faster")
        for (_, value) in sayAll { check(GlobalCommands.shared.script(named: value) != nil, "\(value): a command TurnOver has") }
        expect(StyleKeymap.keys(for: .narrator).isEmpty, true, "Narrator's table is still empty")
    }
    test("Steam's Big Picture choice survives a save: written and read under the same name") {
        var g = Config.Games(); g.readBigPicture = true
        let data = try JSONEncoder().encode(g)
        expect(String(decoding: data, as: UTF8.self).contains("readBigPictureChosen"), true, "saved under the new name")
        expect(try JSONDecoder().decode(Config.Games.self, from: data).readBigPicture, true, "read back on")
        let old = try JSONDecoder().decode(Config.Games.self, from: Data(#"{"readBigPicture": true}"#.utf8))
        expect(old.readBigPicture, false, "an 'on' saved before it was a choice doesn't count")
    }
    test("keyboard styles: a style's table is read and normalised") {
        let t = StyleKeymap.parse(Data(#"{"style": "jaws", "keys": {"kb:NVDA+F6": "elementsList", "kb:turnover+downArrow": "sayAll", "kb:x": ""}}"#.utf8))
        expect(t[normalizeGestureIdentifier("kb:turnover+f6")], "elementsList", "NVDA+ written keys become the TurnOver key")
        expect(t[normalizeGestureIdentifier("kb:turnover+downArrow")], "sayAll", "a plain entry")
        expect(t.count, 2, "an empty command name is left out")
        expect(StyleKeymap.parse(Data("not json".utf8)).isEmpty, true, "bad JSON gives nothing")
        expect(StyleKeymap.keys(for: .voiceOver).isEmpty, true, "VoiceOver keys have no table: the built-in keys")
    }
    test("new in this build: every item gets its own heading") {
        expect(NewToTry.heading("Command Control Period turns TurnOver off and on.").0, "Command Control Period turns TurnOver off and on", "a short item is its own heading")
        expect(NewToTry.heading("VO-F8 opens VoiceOver Utility again. More words follow here.").0, "VO-F8 opens VoiceOver Utility again", "the first short sentence")
        expect(NewToTry.heading("Spelling corrections in any edit box: on a misspelled word (or just after one), VO Shift M lists the suggestions; Return puts one in place.").0, "Spelling corrections in any edit box", "before the colon")
        expect(NewToTry.heading("Direct (Command Control Comma, then D): for a game or app that speaks for itself, every key goes straight to it.").0, "Direct", "before the bracket")
        expect(NewToTry.heading("CoExist, much simpler: VoiceOver keeps running and is silenced at the sound level wherever TurnOver reads, and heard the instant.").0, "CoExist", "before the comma")
    }
    test("browse mode: NVDA's comma keys parse") {
        check(KeyboardGesture(identifier: "kb:,") != nil, "comma")
        check(KeyboardGesture(identifier: "kb:shift+,") != nil, "shift comma")
        check(BrowseModeDocument.quickNav.map(\.key).sorted() == ["1","2","3","4","5","6","7","8","9","a","b","c","d","e","f","g","h","i","k","l","m","n","o","p","q","r","s","t","u","v","w","x"], "every NVDA quick key has a letter")
        // VoiceOver's own single-key Quick Nav (its defaults on the Mac), letter by letter.
        let vo = Dictionary(uniqueKeysWithValues: BrowseModeDocument.voiceOverQuickNav.map { ($0.key, $0.name) })
        expect(vo["l"], "Link"); expect(vo["x"], "List"); expect(vo["c"], "CheckBox"); expect(vo["d"], "DifferentItem")
        expect(vo["f"], "TextField"); expect(vo["j"], "Control"); expect(vo["m"], "SameLevelHeading"); expect(vo["n"], "Landmark")
        expect(vo["r"], "RadioGroup"); expect(vo["h"], "Heading"); expect(vo["k"], nil, "K isn't VoiceOver's")
    }
    let t = "Home News Sport\nThe big story\nA lot happened today, and here it is.\nMore Next Previous\nThat was the news.\n" as NSString
    func r(_ s: String) -> NSRange { t.range(of: s) }
    let nav = AXReplay.element(11), h = AXReplay.element(12), p1 = AXReplay.element(13), more = AXReplay.element(14), p2 = AXReplay.element(15)
    func line(_ s: String, _ e: AXUIElement) -> WebBuffer.Line { WebBuffer.Line(start: r(s).location, end: r(s).location + r(s).length + 1, element: e, entering: [e], isControl: false, fields: [], hasBreak: true) }
    let lines = [line("Home News Sport", nav), line("The big story", h), line("A lot happened today, and here it is.", p1),
                 line("More Next Previous", more), line("That was the news.", p2)]
    let segs = ["Home", "News", "Sport", "More", "Next", "Previous"].map { w in WebBuffer.Segment(start: r(w).location, end: r(w).location + r(w).length, element: AXReplay.element(20), isLink: true) }
    func find(_ from: Int, _ fwd: Bool, _ k: WebBuffer.TextKind) -> Int? { WebBuffer.findText(lines: lines, segments: segs, text: t, from: from, forward: fwd, kind: k)?.offset }
    test("browse mode P: the next paragraph skips links and short headings") {
        expect(find(0, true, .paragraph), r("A lot happened").location)
        expect(find(r("A lot happened").location, true, .paragraph), r("That was the news.").location)
        expect(find(r("That was").location, false, .paragraph), r("A lot happened").location)
        expect(find(r("That was").location, true, .paragraph), nil, "none after the last")
    }
    test("browse mode N: the text after a block of links") {
        expect(find(0, true, .afterLinks), r("The big story").location, "from the link bar")
        expect(find(r("A lot happened").location, true, .afterLinks), r("That was the news.").location, "over the next links")
        expect(find(r("That was").location, false, .afterLinks), r("The big story").location, "back: the text before, after links")
    }
}
