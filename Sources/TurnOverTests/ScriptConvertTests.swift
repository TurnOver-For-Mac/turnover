// SPDX-License-Identifier: GPL-3.0-or-later
// turnover-plugin convert and store (docs/PLUGIN-PLATFORM-PLAN.md, stage A). The add-ons here are small made-up folders the tests
// write themselves: never a real add-on's code, never the network. The parsing runs in /usr/bin/python3 -I, as in the tool.
import Foundation
import TurnOverCore
import PluginTestKit

private let fm = FileManager.default

private struct Fixture {
    let root: URL
    init() { root = fm.temporaryDirectory.appendingPathComponent("turnover-convert-test-\(UUID().uuidString)"); try? fm.createDirectory(at: root, withIntermediateDirectories: true) }
    func write(_ text: String, _ path: String) {
        let url = root.appendingPathComponent(path)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
    func remove() { try? fm.removeItem(at: root) }
    func sub(_ name: String) -> URL { root.appendingPathComponent(name) }
}

private let ini = """
[general]
name = hello
summary = "Hello Add-on"
description = "Says hello and copies a greeting."
author = "Ann Author <ann@example.com>"
version = 1.2
minimumNVDAVersion = 2024.1
"""

private let gpl2 = "                    GNU GENERAL PUBLIC LICENSE\n                       Version 2, June 1991\n"

private let helloPlugin = """
import globalPluginHandler, ui, api
from scriptHandler import script

class GlobalPlugin(globalPluginHandler.GlobalPlugin):
    __gestures = {"kb:NVDA+shift+h": "hello"}

    def script_hello(self, gesture):
        \"\"\"Says hello\"\"\"
        ui.message(_("Hello there"))

    @script(description=_("Copies a greeting"), gesture="kb:NVDA+windows+g")
    def script_copyGreeting(self, gesture):
        api.copyToClip("Greetings")
        count = len("abc")

    def event_gainFocus(self, obj, nextHandler):
        ui.message("Focus moved")
        nextHandler()
"""

private func helloAddon(_ f: Fixture) -> URL {
    f.write(ini, "addon/manifest.ini")
    f.write(gpl2, "addon/LICENSE")
    f.write(helloPlugin, "addon/globalPlugins/hello.py")
    return f.sub("addon")
}

private func convertFolder(_ folder: URL, convertedBy: String? = nil, reportOnly: Bool = true, out: URL? = nil, force: Bool = false, cache: URL) throws -> (text: [String], madePlugin: Bool, result: ConvertResult) {
    var request = ConvertRequest(input: folder.path)
    request.reportOnly = reportOnly; request.convertedBy = convertedBy; request.force = force; request.out = out?.path
    return try ConvertRun.perform(request, fetch: { _, _ in throw ConvertFailure("the network is not used in a test") }, cache: cache)
}

private func file(_ result: ConvertResult, _ name: String) -> String {
    result.files.first { $0.name == name }.map { String(decoding: $0.data, as: UTF8.self) } ?? ""
}

/// A zip with the given entries made by Python's own zipfile (so names the zip tool would refuse can be made).
private func makeZip(_ entries: [(String, String)], links: [String] = [], at url: URL) {
    let spec: [String: Any] = ["path": url.path, "entries": entries.map { ["name": $0.0, "data": $0.1, "link": links.contains($0.0)] as [String: Any] }]
    let json = String(decoding: (try? JSONSerialization.data(withJSONObject: spec)) ?? Data(), as: UTF8.self)
    let code = "import sys, json, zipfile\nspec = json.loads(sys.argv[1])\nz = zipfile.ZipFile(spec['path'], 'w')\nfor e in spec['entries']:\n    zi = zipfile.ZipInfo(e['name'])\n    if e['link']:\n        zi.external_attr = 0o120777 << 16\n    z.writestr(zi, e['data'])\nz.close()\n"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); p.arguments = ["-I", "-c", code, json]
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
}

nonisolated private func storeList(id: String, name: String = "Hello Add-on", sha: String, channel: String = "stable", description: String = "Says hello", url: String = "https://example.test/hello.nvda-addon") -> String {
    "{\"addonId\":\"\(id)\",\"displayName\":\"\(name)\",\"description\":\"\(description)\",\"URL\":\"\(url)\",\"sha256\":\"\(sha)\",\"addonVersionName\":\"1.2\",\"channel\":\"\(channel)\",\"publisher\":\"Ann Author\",\"sourceURL\":\"https://example.test/source\",\"license\":\"GPL v2\",\"minNVDAVersion\":{\"major\":2024,\"minor\":1,\"patch\":0}}"
}

func scriptConvertTests() {
    guard ConvertParse.problem() == nil else {
        test("script convert: Python 3 is there") { check(false, "/usr/bin/python3 cannot read: \(ConvertParse.problem() ?? "")") }
        return
    }
    let cache = fm.temporaryDirectory.appendingPathComponent("turnover-convert-test-cache-\(UUID().uuidString)")
    let host = ScriptScenarioRunner.hostPath()

    test("script convert: a global plugin with two scripts and a focus event") {
        let f = Fixture(); defer { f.remove() }
        let done = try convertFolder(helloAddon(f), cache: cache)
        let r = done.result
        check(done.madePlugin, "a plugin is made")
        expect(r.commandsCarried, 2, "two commands"); expect(r.eventsCarried, 1, "one event handler")
        expect(r.abilities, ["clipboard", "everywhere", "read", "say"], "abilities come from the original's calls alone, and a global plugin works everywhere")
        let js = file(r, "main.js")
        check(js.contains("turnover.say(\"Hello there\");"), "ui.message becomes turnover.say: \(js)")
        check(js.contains("await turnover.copy(\"Greetings\");"), "copyToClip becomes turnover.copy")
        check(js.contains("turnover.on(\"focus\""), "a focus handler")
        check(js.contains("turnover.say(\"Focus moved\");"), "the focus handler's message")
        check(js.contains("A PERSON MUST WRITE THIS") && js.contains("//   count = len(\"abc\")"), "the untranslated line is kept as a comment under a line saying so")
        check(js.contains("// Dropped") && !js.contains("\n  nextHandler"), "nextHandler is dropped, not translated: \(js)")
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(file(r, "manifest.json").utf8))
        expect(manifest.commands?.map(\.id) ?? [], ["hello", "copyGreeting"], "command ids")
        expect(manifest.commands?.compactMap(\.key) ?? [], ["turnover+shift+h", "turnover+command+g"], "kb:NVDA+x becomes turnover+x")
        expect(manifest.apps, ["*"], "a global plugin works in every app, so apps is [\"*\"] (stage B)")
        expect(manifest.convertedFrom?.abilities ?? [], ["clipboard", "everywhere", "read", "say"], "recorded")
        expect(manifest.convertedFrom?.apps ?? [], ["*"], "and so is the app")
        expect(manifest.id, "nvda-hello", "the id says where it came from")
        // The script is a real, loadable script.
        if let host {
            let out = f.sub("draft"); try ConvertRun.write(r, to: out, force: false)
            let plugin = ProfileStore.load(folder: out)
            expect(plugin.error, nil, "the draft loads as it was written: it names every app, so there is no app to choose")
            let report = ScriptChecker.check(plugin, hostPath: host)
            expect(report.problems, [], "main.js loads in the sandbox host")
            expect(report.commands.sorted(), ["copyGreeting", "hello"], "both commands handled")
        }
    }

    test("script convert: an app module names a Windows program and leaves apps empty") {
        let f = Fixture(); defer { f.remove() }
        f.write(ini, "addon/manifest.ini")
        f.write("import appModuleHandler, ui\nclass AppModule(appModuleHandler.AppModule):\n    def script_swap(self, gesture):\n        ui.message(\"Swapped\")\n    __gestures = {\"kb:control+f6\": \"swap\"}\n", "addon/appModules/filezilla.py")
        let done = try convertFolder(f.sub("addon"), cache: cache)
        check(done.madePlugin, "a plugin is made")
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(file(done.result, "manifest.json").utf8))
        expect(manifest.apps, [], "apps empty")
        expect(manifest.convertedFrom?.apps ?? [], ["filezilla.exe"], "the Windows program is recorded")
        expect(manifest.commands?.first?.key, "control+f6", "control+f6 stays")
        check(done.text.joined(separator: "\n").contains("id of app"), "the report says how to find the Mac app's identifier")
        let out = f.sub("draft"); try ConvertRun.write(done.result, to: out, force: false)
        let plugin = ProfileStore.load(folder: out)
        check((plugin.error ?? "").contains("not finished"), "check says a converted plugin with no app is not finished: \(plugin.error ?? "loaded")")
        check(PluginConversion.findings(for: manifest).problems.contains { $0.contains("not finished") }, "and so does the record check")
    }

    test("script convert: a driver gets a report and no plugin") {
        let f = Fixture(); defer { f.remove() }
        f.write(ini, "addon/manifest.ini")
        f.write("import synthDriverHandler\nclass SynthDriver(synthDriverHandler.SynthDriver):\n    name = 'x'\n", "addon/synthDrivers/x/__init__.py")
        let out = f.sub("out")
        let done = try convertFolder(f.sub("addon"), reportOnly: false, out: out, cache: cache)
        check(!done.madePlugin, "no plugin")
        expect(done.result.files.map(\.name), ["CONVERSION.md"], "only the report")
        check(!fm.fileExists(atPath: out.appendingPathComponent("manifest.json").path), "no manifest written")
        check(file(done.result, "CONVERSION.md").contains("driver"), "the report says why")
        expect(done.result.verdict, .notForMac, "remembered as not for the Mac")
    }

    test("script convert: a zip with a path that climbs out is refused, and so is a link") {
        let f = Fixture(); defer { f.remove() }
        let evil = f.sub("evil.nvda-addon")
        makeZip([("manifest.ini", ini), ("../escape.py", "x = 1")], at: evil)
        do { _ = try ConvertSource.archive(evil, label: "The file", origin: .file(evil.path)); check(false, "should refuse") }
        catch { check("\(error)".contains("leaves its own folder"), "says why: \(error)") }
        let link = f.sub("link.nvda-addon")
        makeZip([("manifest.ini", ini), ("globalPlugins/a.py", "/etc/passwd")], links: ["globalPlugins/a.py"], at: link)
        do { _ = try ConvertSource.archive(link, label: "The file", origin: .file(link.path)); check(false, "should refuse a link") }
        catch { check("\(error)".contains("link"), "says why: \(error)") }
        check(!fm.fileExists(atPath: f.root.appendingPathComponent("escape.py").path), "nothing was written outside")
        let good = f.sub("good.nvda-addon")
        makeZip([("manifest.ini", ini), ("globalPlugins/hello.py", helloPlugin)], at: good)
        let s = try ConvertSource.archive(good, label: "The file", origin: .file(good.path)); defer { s.cleanUp() }
        check(s.sha256?.count == 64, "a good one unpacks and has its SHA-256")
    }

    test("script convert: a wrong SHA-256 refuses the download, and a right one converts it") {
        let f = Fixture(); defer { f.remove() }
        let zip = f.sub("hello.nvda-addon")
        makeZip([("manifest.ini", ini), ("globalPlugins/hello.py", helloPlugin)], at: zip)
        let data = (try? Data(contentsOf: zip)) ?? Data()
        let right = ConvertSource.sha256Hex(data)
        let wrong = String(repeating: "0", count: 64)
        let fetch: ConvertFetch = { url, _ in url.absoluteString.hasSuffix("latest.json") ? Data(("[" + storeList(id: "hello", sha: wrong) + "]").utf8) : data }
        do { _ = try ConvertSource.store(id: "hello", channel: "stable", list: Data(("[" + storeList(id: "hello", sha: wrong) + "]").utf8), fetch: fetch); check(false, "should refuse") }
        catch { check("\(error)".contains("does not match"), "says it does not match: \(error)") }
        let s = try ConvertSource.store(id: "hello", channel: "stable", list: Data(("[" + storeList(id: "hello", sha: right) + "]").utf8), fetch: fetch); defer { s.cleanUp() }
        expect(s.sha256, right, "the right one is accepted")
        expect(s.sourceURL, "https://example.test/source", "the source address is carried")
        let parser = try ConvertParse(); defer { parser.finish() }
        let r = try AddonConverter.convert(source: s, parser: parser)
        let m = try JSONDecoder().decode(PluginManifest.self, from: Data(file(r, "manifest.json").utf8))
        expect(m.convertedFrom?.sha256, right, "the SHA-256 is in the record"); expect(m.license, "GPL v2", "the store's licence")
        do { _ = try ConvertSource.store(id: "hello", channel: "stable", list: Data(("[" + storeList(id: "hello", sha: right, url: "http://example.test/a.nvda-addon") + "]").utf8), fetch: fetch); check(false, "http refused") }
        catch { check("\(error)".contains("https"), "http is refused: \(error)") }
        do { _ = try ConvertSource.store(id: "hello", channel: "stable", list: Data(("[" + storeList(id: "hello", sha: right, channel: "beta") + "]").utf8), fetch: fetch); check(false, "channel") }
        catch { check("\(error)".contains("--channel beta"), "says which channel to ask for: \(error)") }
    }

    test("script convert: an ability added by hand after conversion is refused by check") {
        let f = Fixture(); defer { f.remove() }
        let done = try convertFolder(helloAddon(f), convertedBy: "Bob Converter", cache: cache)
        var m = try JSONDecoder().decode(PluginManifest.self, from: Data(file(done.result, "manifest.json").utf8))
        m.apps = ["com.example.app"]; m.convertedFrom?.apps = ["com.example.app"]
        expect(PluginConversion.findings(for: m).problems, [], "as converted, with the app chosen on purpose: clean")
        m.abilities = (m.abilities ?? []) + ["keys"]
        let bad = PluginConversion.findings(for: m).problems
        check(bad.count == 1 && bad[0].contains("\"keys\"") && bad[0].contains("not in convertedFrom"), "the added ability is an error: \(bad)")
        m.abilities?.removeLast(); m.apps.append("com.example.other")
        check(PluginConversion.findings(for: m).problems.contains { $0.contains("com.example.other") }, "an app that is not in the record is an error")
        let lines = PluginConversion.lines(for: m, listing: false)
        check(lines.problems >= 1 && lines.lines.joined().contains("PROBLEM"), "check prints it and counts it")
    }

    test("script convert: the licence and author are carried over, and both credit names") {
        let f = Fixture(); defer { f.remove() }
        let done = try convertFolder(helloAddon(f), convertedBy: "Bob Converter", cache: cache)
        let m = try JSONDecoder().decode(PluginManifest.self, from: Data(file(done.result, "manifest.json").utf8))
        expect(m.author, "Ann Author <ann@example.com>", "the manifest's author stays the creator")
        expect(m.license, "GPL v2", "the licence from the add-on's licence file")
        expect(m.convertedFrom?.author, "Ann Author <ann@example.com>", "the record names the creator")
        expect(m.convertedFrom?.convertedBy, "Bob Converter", "and who converted it")
        let md = file(done.result, "CONVERSION.md")
        check(md.contains("Ann Author") && md.contains("Bob Converter") && md.contains("GPL v2") && md.contains("derived work"), "CONVERSION.md carries both names, the licence and the notice")
        check(done.result.files.contains { $0.name == "LICENSE-ORIGINAL.txt" }, "the original's licence text is kept")
        // Without --converted-by: nothing is asked; check warns, and with --listing it is an error.
        let unnamed = try convertFolder(helloAddon(f), cache: cache)
        var m2 = try JSONDecoder().decode(PluginManifest.self, from: Data(file(unnamed.result, "manifest.json").utf8))
        m2.apps = ["x"]; m2.convertedFrom?.apps = ["x"]
        expect(m2.convertedFrom?.convertedBy, nil, "left empty")
        expect(PluginConversion.findings(for: m2).warnings.count, 1, "a warning")
        expect(PluginConversion.lines(for: m2, listing: false).problems, 0, "not an error without --listing")
        expect(PluginConversion.lines(for: m2, listing: true).problems, 1, "an error with --listing")
        // The names change nothing about what it may do.
        expect(unnamed.result.abilities, done.result.abilities, "the same abilities")
        // The approval line.
        let named = m
        let out = f.sub("draft"); try ConvertRun.write(done.result, to: out, force: false)
        try JSONEncoder().encode(named).write(to: out.appendingPathComponent("manifest.json"))
        let plugin = ProfileStore.load(folder: out)
        expect(plugin.error, nil, "loads")
        let lines = ScriptAbilities.approvalLines(for: plugin, appName: { $0 })
        let line = lines.first { $0.kind == .converted }?.text ?? ""
        check(line.contains("converted from the NVDA add-on hello by Ann Author") && line.contains("converted by Bob Converter"), "the approval says so: \(line)")
        var unnamedPlugin = named; unnamedPlugin.convertedFrom?.convertedBy = nil
        try JSONEncoder().encode(unnamedPlugin).write(to: out.appendingPathComponent("manifest.json"))
        let line2 = ScriptAbilities.approvalLines(for: ProfileStore.load(folder: out), appName: { $0 }).first { $0.kind == .converted }?.text ?? ""
        check(line2.contains("is not named"), "and says when the converter is not named: \(line2)")
    }

    test("script convert: a gesture PluginPolicy refuses is left unbound and reported") {
        let f = Fixture(); defer { f.remove() }
        f.write(ini, "addon/manifest.ini")
        f.write("import globalPluginHandler, ui\nclass GlobalPlugin(globalPluginHandler.GlobalPlugin):\n    __gestures = {\"kb:h\": \"plain\", \"kb:NVDA+f1\": \"fine\", \"kb(laptop):NVDA+f1\": \"clash\"}\n    def script_plain(self, gesture):\n        ui.message(\"a\")\n    def script_fine(self, gesture):\n        ui.message(\"b\")\n    def script_clash(self, gesture):\n        ui.message(\"c\")\n", "addon/globalPlugins/g.py")
        let r = try convertFolder(f.sub("addon"), cache: cache).result
        let m = try JSONDecoder().decode(PluginManifest.self, from: Data(file(r, "manifest.json").utf8))
        let keys = Dictionary(uniqueKeysWithValues: (m.commands ?? []).map { ($0.id, $0.key) })
        expect(keys["plain"] ?? "x", nil, "a plain key is left unbound")
        expect(keys["fine"] ?? nil, "turnover+f1", "a good key is kept")
        expect(keys["clash"] ?? "x", nil, "a second command on the same key is left unbound")
        check(file(r, "main.js").contains("Left unbound"), "main.js says so")
        check(file(r, "CONVERSION.md").contains("left without a key"), "and the report")
    }

    test("script convert: a call not in the table is never guessed at, and what the sandbox rules out is not carried") {
        let f = Fixture(); defer { f.remove() }
        f.write(ini, "addon/manifest.ini")
        f.write("import globalPluginHandler, ui, subprocess, speech\nclass GlobalPlugin(globalPluginHandler.GlobalPlugin):\n    def script_list(self, gesture):\n        ui.browseableMessage(\"text\")\n        speech.cancelSpeech()\n    def script_run(self, gesture):\n        subprocess.run([\"x\"])\n    def script_open(self, gesture):\n        open(\"f.txt\")\n", "addon/globalPlugins/g.py")
        let r = try convertFolder(f.sub("addon"), cache: cache).result
        expect(r.commandsCarried, 0, "everything was either ruled out or not a command")
        check(!r.madePlugin, "no plugin when nothing carries over")
        check(r.report.contains("subprocess"), "the reason is given: \(r.report)")
        f.write("import globalPluginHandler, ui, speech\nclass GlobalPlugin(globalPluginHandler.GlobalPlugin):\n    def script_list(self, gesture):\n        ui.browseableMessage(\"text\")\n        speech.cancelSpeech()\n", "addon/globalPlugins/g.py")
        let r2 = try convertFolder(f.sub("addon"), cache: cache).result
        let js = file(r2, "main.js")
        check(js.contains("//   ui.browseableMessage(\"text\")") && js.contains("//   speech.cancelSpeech()"), "kept as the original")
        check(!js.contains("turnover.say"), "not guessed at")
        check(r2.report.contains("speech.cancelSpeech"), "the unlisted call is listed in the report")
    }

    test("script convert: original text can never end a comment and start code") {
        let f = Fixture(); defer { f.remove() }
        f.write(ini, "addon/manifest.ini")
        f.write("import globalPluginHandler\nclass GlobalPlugin(globalPluginHandler.GlobalPlugin):\n    def script_x(self, gesture):\n        y = '\u{2028}turnover.say(1)'  # \u{2029}evil()\n", "addon/globalPlugins/g.py")
        let js = file(try convertFolder(f.sub("addon"), cache: cache).result, "main.js")
        for l in js.components(separatedBy: .newlines) where l.contains("turnover.say(1)") || l.contains("evil()") { check(l.trimmingCharacters(in: .whitespaces).hasPrefix("//"), "inside a comment: \(l)") }
        check(!js.unicodeScalars.contains { $0.value == 0x2028 || $0.value == 0x2029 }, "no line separators")
    }

    test("script convert: --out never overwrites an existing folder without --force, and writes nowhere else") {
        let f = Fixture(); defer { f.remove() }
        let addon = helloAddon(f)
        let out = f.sub("draft")
        let first = try convertFolder(addon, reportOnly: false, out: out, cache: cache)
        check(first.madePlugin && fm.fileExists(atPath: out.appendingPathComponent("main.js").path), "written")
        do { _ = try convertFolder(addon, reportOnly: false, out: out, cache: cache); check(false, "should refuse") }
        catch { check("\(error)".contains("--force"), "says to use --force: \(error)") }
        _ = try convertFolder(addon, reportOnly: false, out: out, force: true, cache: cache)
        let report = f.sub("never")
        _ = try convertFolder(addon, reportOnly: true, out: report, cache: cache)
        check(!fm.fileExists(atPath: report.path), "--report-only writes nothing")
        do { _ = try convertFolder(addon, reportOnly: false, out: nil, cache: cache); check(false, "needs --out") } catch { check("\(error)".contains("--out"), "asks for --out") }
    }

    // MARK: the store

    let storeJSON = "[" + [
        storeList(id: "zoomPlus", name: "Zoom Plus", sha: "a", description: "Reads Zoom meetings aloud."),
        storeList(id: "rhv", name: "RHVoice", sha: "b", description: "A speech synthesizer with many voices."),
        storeList(id: "npp", name: "Notepad++ helper", sha: "c", description: "Better reading in the editor."),
        storeList(id: "clock", name: "Clock", sha: "d", description: "Says the time. A very long description that goes on and on and on past a hundred and ten characters so that it has to be cut at a word."),
        storeList(id: "betaOnly", name: "Beta thing", sha: "e", channel: "beta", description: "Not stable."),
        storeList(id: "alpha", name: "alpha tool", sha: "f", description: "Mentions SAPI 5 voices."),
    ].joined(separator: ",") + "]"

    func browser(_ memory: ConvertMemory? = nil) -> StoreBrowser { StoreBrowser(entries: (try? StoreEntry.parse(Data(storeJSON.utf8))) ?? [], memory: memory) }

    test("script convert: store list is the stable channel sorted by name, one add-on per line") {
        let b = browser()
        let page = b.page(b.stable(), hideNotMac: false)
        expect(page.shown, 5, "five stable add-ons (the beta one is not listed)")
        check(page.lines[0].hasPrefix("alpha tool, id alpha, version 1.2, by Ann Author."), "sorted by name, ignoring case: \(page.lines[0])")
        check(page.lines.dropLast().allSatisfy { !$0.contains("\n") && !$0.contains("  ") && !$0.contains("\t") }, "one line each, no padding")
        check(page.lines.contains { $0.hasPrefix("Clock,") && $0.contains("…") && $0.count < 260 }, "a long description is cut at a word")
        expect(page.lines.last, "5 add-ons.", "the end line")
    }

    test("script convert: store search matches name, id, author and description, ignoring case") {
        let b = browser()
        expect(b.search(["zoom"]).map(\.id), ["zoomPlus"], "name and description")
        expect(b.search(["ZOOMPLUS"]).map(\.id), ["zoomPlus"], "id, any case")
        expect(b.search(["ann", "time"]).map(\.id), ["clock"], "author and description, every word needed")
        expect(b.search(["beta"]).map(\.id), [], "the beta channel is not searched")
        expect(b.search(["nothingmatches"]).count, 0, "no match")
    }

    test("script convert: the verdict comes from a remembered conversion first, then signs in the list, and never says can be converted from the list alone") {
        let dir = fm.temporaryDirectory.appendingPathComponent("turnover-convert-test-memory-\(UUID().uuidString)"); defer { try? fm.removeItem(at: dir) }
        let memory = ConvertMemory(cacheDirectory: dir)
        let b = browser(memory)
        let all = Dictionary(uniqueKeysWithValues: b.entries.map { ($0.id, $0) })
        expect(b.judge(all["clock"]!).verdict, .notLookedAt, "no sign: not looked at yet")
        expect(b.judge(all["rhv"]!).verdict, .notForMac, "a speech synthesizer: not for the Mac")
        check(b.judge(all["rhv"]!).reason?.contains("synthesizer") == true, "with its reason")
        expect(b.judge(all["npp"]!).verdict, .notForMac, "Notepad++ is Windows only")
        expect(b.judge(all["alpha"]!).verdict, .notForMac, "SAPI is Windows only")
        for e in b.entries { check(b.judge(e).verdict != .canConvert, "\(e.id): never can-convert from the list alone") }
        memory.remember(id: "clock", version: "1.2", verdict: .canConvert, reason: nil)
        expect(b.judge(all["clock"]!), StoreJudgement(verdict: .canConvert, reason: nil, source: .remembered), "a remembered result is used")
        memory.remember(id: "rhv", version: "1.2", verdict: .needsWork, reason: "tried")
        expect(b.judge(all["rhv"]!).verdict, .needsWork, "and wins over the signs")
        memory.remember(id: "zoomPlus", version: "9.9", verdict: .canConvert, reason: nil)
        expect(b.judge(all["zoomPlus"]!).verdict, .notLookedAt, "another version is not the same result")
        check(b.line(all["clock"]!).hasSuffix("Verdict: can be converted."), "shown on the line: \(b.line(all["clock"]!))")
        check(b.show(all["rhv"]!).contains { $0.hasPrefix("Verdict: needs work") }, "and in show")
    }

    test("script convert: --hide-not-mac leaves the not-for-the-Mac ones out and says how many") {
        let b = browser()
        let page = b.page(b.stable(), hideNotMac: true)
        expect(page.shown, 2, "zoom and clock stay"); expect(page.leftOut, 3, "three left out")
        expect(page.lines.last, "2 add-ons shown; 3 left out as not for the Mac.", "the end line says so")
        check(!page.lines.contains { $0.contains("RHVoice") }, "RHVoice is gone")
        let searched = b.page(b.search(["a"]), hideNotMac: true)
        check(searched.lines.last?.contains("left out as not for the Mac") == true, "search says it too")
    }

    test("script convert: store show gives everything the list says, and --json gives the same") {
        let b = browser()
        let e = StoreEntry.choose(id: "zoomplus", channel: "stable", from: b.entries)!
        let lines = b.show(e)
        for want in ["Name: Zoom Plus", "Id: zoomPlus", "Version: 1.2", "Author: Ann Author", "Licence: GPL v2", "Source address: https://example.test/source", "SHA-256: a", "Download address: https://example.test/hello.nvda-addon"] {
            check(lines.contains(want), "has \(want): \(lines)")
        }
        check(lines.contains { $0.hasPrefix("Kind:") && $0.contains("does not say") }, "kind is honest when the list does not say")
        check(b.show(StoreEntry.choose(id: "rhv", channel: "stable", from: b.entries)!).contains { $0.hasPrefix("Kind: looks like a speech synthesizer") }, "a driver is recognised from its description")
        let json = StoreBrowser.jsonText(b.showJSON(e))
        let back = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        expect(back?["id"] as? String, "zoomPlus", "json id"); expect(back?["sha256"] as? String, "a", "json sha"); expect(back?["verdict"] as? String, "not looked at yet", "json verdict")
    }

    test("script convert: the store's list is cached for an hour, and only https is fetched") {
        let dir = fm.temporaryDirectory.appendingPathComponent("turnover-convert-test-list-\(UUID().uuidString)"); defer { try? fm.removeItem(at: dir) }
        nonisolated(unsafe) var fetches = 0
        nonisolated(unsafe) var schemes: [String] = []
        let fetch: ConvertFetch = { url, _ in
            schemes.append(url.scheme ?? "")
            fetches += 1
            return Data(storeJSON.utf8)
        }
        defer { check(schemes.allSatisfy { $0 == "https" }, "https only: \(schemes)") }
        let t0 = Date()
        _ = try StoreBrowser.loadList(cache: dir, now: t0, fetch: fetch)
        _ = try StoreBrowser.loadList(cache: dir, now: t0.addingTimeInterval(1800), fetch: fetch)
        expect(fetches, 1, "the second look, half an hour later, uses the copy")
        _ = try StoreBrowser.loadList(cache: dir, now: t0.addingTimeInterval(3 * 3600), fetch: fetch)
        expect(fetches, 2, "three hours later it is fetched again")
        let lines = try StoreRun.perform(["search", "zoom", "--json"], fetch: fetch, cache: dir, now: t0.addingTimeInterval(3 * 3600 + 5))
        check(lines.joined().contains("\"zoomPlus\""), "store search --json: \(lines)")
        let listed = try StoreRun.perform(["list", "--hide-not-mac"], fetch: fetch, cache: dir, now: t0.addingTimeInterval(3 * 3600 + 5))
        expect(listed.last, "2 add-ons shown; 3 left out as not for the Mac.", "the command's own output")
        do { _ = try StoreRun.perform(["show", "nope"], fetch: fetch, cache: dir, now: t0.addingTimeInterval(3 * 3600 + 5)); check(false, "unknown id") } catch { check("\(error)".contains("no add-on"), "says so") }
    }

    test("script convert: a convert remembers its verdict for the store to show") {
        let f = Fixture(); defer { f.remove() }
        let dir = fm.temporaryDirectory.appendingPathComponent("turnover-convert-test-mem-\(UUID().uuidString)"); defer { try? fm.removeItem(at: dir) }
        _ = try convertFolder(helloAddon(f), cache: dir)
        let b = StoreBrowser(entries: (try? StoreEntry.parse(Data(("[" + storeList(id: "hello", sha: "a") + "]").utf8))) ?? [], memory: ConvertMemory(cacheDirectory: dir))
        let j = b.judge(b.entries[0])
        expect(j.source, .remembered, "remembered from the earlier convert")
        check(j.verdict == .needsWork, "the app module's apps, key choices and kept Python make it needs work: \(j.verdict)")
    }

    // MARK: Stage B (16 Nov 2026): what scripts gained is in the table, and each ability gets a first reason

    test("script platform: convert: the table maps tones, lists, prompts, text and caret, the clipboard, settings and speech to what scripts now have") {
        @MainActor func row(_ name: String) -> ConvertMapping.Row? { ConvertMapping.row(for: name) }
        expect(row("tones.beep")?.fit, .exact, "a beep is a tone"); expect(row("tones.beep")?.template, "turnover.tone({0}, {1})", "its translation")
        expect(row("tones.beep")?.ability, "say", "under say")
        expect(row("wx.SingleChoiceDialog")?.fit, .partial, "a list of choices"); expect(row("wx.SingleChoiceDialog")?.ability, "say", "under say")
        expect(row("wx.TextEntryDialog")?.fit, .partial, "a prompt for text"); expect(row("wx.TextEntryDialog")?.ability, "say", "under say")
        expect(row("ui.browseableMessage")?.fit, .partial, "a window of text")
        expect(row("obj.makeTextInfo")?.fit, .partial, "text of an item"); expect(row("obj.makeTextInfo")?.ability, "read", "under read")
        expect(row("textInfos.POSITION_CARET")?.ability, "read", "text by position")
        expect(row("info.updateCaret")?.ability, "edit", "moving the caret is edit"); expect(row("info.updateSelection")?.ability, "edit", "so is selecting")
        expect(row("config.conf")?.fit, .partial, "settings become options"); check(row("config.conf")?.why.contains("options") == true, "and says so")
        expect(row("api.getClipData")?.fit, .partial, "the clipboard can now be read"); expect(row("api.getClipData")?.ability, "clipboardRead", "with its own ability")
        expect(row("speech.extensions.pre_speech.register")?.ability, "hearSpeech", "hearing speech")
        check(ConvertMapping.rows.filter { $0.fit == .nothingYet }.allSatisfy { !($0.later ?? "").contains("turnover.tone") && !($0.later ?? "").contains("options TurnOver shows") }, "no row still waits for a piece that now exists")
        check(ConvertMapping.rows.filter { $0.fit == .never }.allSatisfy { $0.nvda != "api.getClipData" }, "reading the clipboard is no longer \"never\"")
        expect(ConvertMapping.rows.filter { $0.fit == .never }.count, 6, "what is still never: settings of TurnOver, programs, files, web pages")
    }

    test("script platform: convert: a global plugin becomes an everywhere draft with a first reason for each ability from what the original used it for") {
        let f = Fixture(); defer { f.remove() }
        f.write(ini, "addon/manifest.ini")
        f.write("""
        import globalPluginHandler, ui, tones, api, textInfos, config
        class GlobalPlugin(globalPluginHandler.GlobalPlugin):
            def script_beep(self, gesture):
                \"\"\"Beeps\"\"\"
                tones.beep(440, 100)
            def script_paste(self, gesture):
                \"\"\"Reads the clipboard\"\"\"
                text = api.getClipData()
                ui.message("done")
            def script_line(self, gesture):
                \"\"\"Reads a line and moves\"\"\"
                obj = api.getFocusObject()
                info = obj.makeTextInfo(textInfos.POSITION_CARET)
                info.updateCaret()
                loud = config.conf["myAddon"]["loud"]
        """, "addon/globalPlugins/tools.py")
        let done = try convertFolder(f.sub("addon"), convertedBy: "Bob", cache: cache)
        let r = done.result
        check(done.madePlugin, "a plugin is made")
        expect(r.abilities, ["clipboardRead", "edit", "everywhere", "read", "say"], "everything from the original's own calls, and everywhere because it is a global plugin")
        let js = file(r, "main.js")
        check(js.contains("turnover.tone(440, 100);"), "tones.beep becomes turnover.tone: \(js)")
        check(js.contains("A PERSON MUST WRITE THIS") && js.contains("api.getClipData()"), "what is only partly mapped stays as the original Python")
        let m = try JSONDecoder().decode(PluginManifest.self, from: Data(file(r, "manifest.json").utf8))
        expect(m.apps, ["*"], "apps"); expect(m.worksEverywhere, true, "it works everywhere")
        expect(m.convertedFrom?.apps ?? [], ["*"], "the record has it too")
        for ability in ["clipboardRead", "edit", "everywhere", "read", "say"] {
            let reason = m.reasons?[ability] ?? ""
            check(!reason.isEmpty && reason.count <= 150 && PluginText.isPlain(reason), "a first reason for \(ability), plain and at most 150 characters: \(reason)")
        }
        check(m.reasons?["clipboardRead"]?.contains("reads the clipboard's text") == true, "the reason says what the original used it for: \(m.reasons?["clipboardRead"] ?? "")")
        check(m.reasons?["everywhere"]?.contains("global plugin") == true, "and why everywhere: \(m.reasons?["everywhere"] ?? "")")
        check(m.reasons?["edit"]?.contains("moves the caret") == true, "edit: \(m.reasons?["edit"] ?? "")")
        check(m.reasons?["say"]?.contains("plays a tone") == true && m.reasons?["say"]?.contains("speaks a message") == true, "say names both uses: \(m.reasons?["say"] ?? "")")
        check(!(m.reasons ?? [:]).values.contains { $0.contains("getClipData") || $0.contains("textInfos") }, "the add-on's own names are never copied into a reason")
        check(PluginConversion.findings(for: m).problems.isEmpty, "the record matches the manifest")
        let out = f.sub("draft"); try ConvertRun.write(r, to: out, force: false)
        let plugin = ProfileStore.load(folder: out)
        expect(plugin.error, nil, "the draft loads as written: \(plugin.error ?? "")")
        let listing = PluginListing.check(plugin, others: [])
        check(!listing.lines.contains { $0.contains("reasons has nothing") }, "the library's reasons check finds one for every ability above read and say: \(listing.lines)")
        let md = file(r, "CONVERSION.md")
        check(md.contains("[\"*\"]") && md.contains("everywhere") && md.contains("first draft"), "the report says apps is [\"*\"] and that the reasons are a first draft: \(md)")
        let lines = ScriptAbilities.approvalLines(for: plugin, appName: { $0 }).map(\.text)
        check(lines.contains { $0.hasPrefix("The author says it uses this to: In the original add-on: reads the clipboard's text") }, "and the person hears it, marked as the author's: \(lines)")
        expect(ScriptReview.level(for: ScriptAbilities.effective(for: plugin)).number, 3, "a converted plugin that reads the clipboard is at the highest level")
        // An add-on with an app module is not everywhere: its programs are Windows ones, and apps is left to a person.
        let g = Fixture(); defer { g.remove() }
        g.write(ini, "addon/manifest.ini")
        g.write("import appModuleHandler, ui, tones\nclass AppModule(appModuleHandler.AppModule):\n    def script_swap(self, gesture):\n        tones.beep(500, 50)\n", "addon/appModules/filezilla.py")
        let app = try convertFolder(g.sub("addon"), cache: cache).result
        let am = try JSONDecoder().decode(PluginManifest.self, from: Data(file(app, "manifest.json").utf8))
        expect(am.apps, [], "an app module's draft has no apps"); check(!(am.abilities ?? []).contains("everywhere"), "and is not everywhere")
    }
}
