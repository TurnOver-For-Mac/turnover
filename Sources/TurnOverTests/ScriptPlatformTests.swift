// SPDX-License-Identifier: GPL-3.0-or-later
// Stage B of docs/PLUGIN-PLATFORM-PLAN.md (16 Nov 2026): everywhere, options, lists and prompts, tones, text and caret, hearing
// speech, reading the clipboard, support and reasons, the level of review, the approval sentences, the Plugins menu's two new
// items, and the checks of the independent review's open findings. The real sandboxed host program runs the scripts; everything
// the scripts reach is a stand-in for the Mac. Nothing uses XPC, the Keychain, the network, the real support folder, the real
// plugins folder, the real clipboard or the home folder, and no tone or word is played.
import Foundation
import ApplicationServices
import TurnOverCore
import AXFixtures
import TurnOverPluginWire
import PluginTestKit

private let hostPath: String = {
    let runner = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    return runner.deletingLastPathComponent().appendingPathComponent("turnover-plugin-host").path
}()

private func waitFor(_ seconds: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let until = Date().addingTimeInterval(seconds)
    while !condition(), Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    return condition()
}
private func settle(_ seconds: TimeInterval) { _ = waitFor(seconds) { false } }

// MARK: A small recorded screen

private let longText = String(repeating: "x", count: 12_000)
private let notesText = "First line\nSecond line\nThird line"

/// A window with a button, a notes field (a caret in its second line), a password field in a group, a long field and some text.
private func platformScreen() -> AXFixture {
    typealias V = AXFixture.Value
    func node(_ id: Int, _ attrs: [String: V], actions: [String] = []) -> AXFixture.Node { AXFixture.Node(id: id, attrs: attrs, params: [], actions: actions) }
    let inWindow: [String: V] = [kAXParentAttribute: .element(0), kAXWindowAttribute: .element(0)]
    func child(_ role: String, _ more: [String: V]) -> [String: V] { inWindow.merging([kAXRoleAttribute: .string(role)].merging(more) { a, _ in a }) { a, _ in a } }
    return AXFixture(app: "Example", bundle: "com.example.app", recorded: "2026-11-16", root: 0, application: 7, focus: 2, nodes: [
        node(0, [kAXRoleAttribute: .string("AXWindow"), kAXTitleAttribute: .string("Main"), kAXChildrenAttribute: .elements([1, 2, 6, 4, 5, 8]), kAXParentAttribute: .element(7)]),
        node(1, child("AXButton", [kAXTitleAttribute: .string("Save"), kAXEnabledAttribute: .bool(true)]), actions: ["AXPress"]),
        node(2, child("AXTextArea", [kAXTitleAttribute: .string("Notes"), kAXValueAttribute: .string(notesText), kAXSelectedTextRangeAttribute: .range(11, 11)])),
        node(3, [kAXRoleAttribute: .string("AXTextField"), kAXSubroleAttribute: .string("AXSecureTextField"), kAXTitleAttribute: .string("Password"),
                 kAXValueAttribute: .string("hunter2"), kAXSelectedTextRangeAttribute: .range(0, 7), kAXParentAttribute: .element(6), kAXWindowAttribute: .element(0)]),
        node(4, child("AXTextArea", [kAXTitleAttribute: .string("Long"), kAXValueAttribute: .string(longText), kAXSelectedTextRangeAttribute: .range(0, 12_000)])),
        node(5, child("AXStaticText", [kAXValueAttribute: .string("Total 12")])),
        node(6, child("AXGroup", [kAXTitleAttribute: .string("Login"), kAXChildrenAttribute: .elements([3])])),
        node(8, child("AXTextField", [kAXTitleAttribute: .string("Name"), kAXValueAttribute: .string("Ann")])),
        node(7, [kAXRoleAttribute: .string("AXApplication"), kAXChildrenAttribute: .elements([0])]),
    ])
}

private let button = 1, notes = 2, password = 3, longField = 4, totalText = 5
private func el(_ id: Int) -> AXUIElement { AXReplay.element(id) }

// MARK: A stand-in for the Mac

nonisolated(unsafe) private var storages: [URL] = []

private final class PMac {
    var front: pid_t? = AXReplay.floor + 1
    var macFront: pid_t? = AXReplay.floor + 1
    var secureInput = false
    var bundles: (pid_t) -> String = { $0 >= AXReplay.floor ? "com.example.app" : "com.other.app" }
    var focus: AXUIElement? = el(notes)
    var scriptSaid: [String] = [], spoken: [String] = []
    var tones: [(Double, Int)] = []
    var copied: [String] = []
    var clipboard: String? = "On the clipboard"
    var running: Set<String> = ["com.example.app"]
    var plugins: [LoadedPlugin] = []
    var limits = ScriptLimits()
    var questions: [(title: String, items: [MenuItem], closed: () -> Void)] = []
    var prompts: [(words: String, done: (String?) -> Void)] = []
    var dismissed = 0
    var echoSpeech = false      // what TurnOver says is also given to Speech, as the real one does
    let profiles = ProfileStore()
    let options = ScriptOptionsStore()
    let storage = FileManager.default.temporaryDirectory.appendingPathComponent("turnover-platform-storage-\(UUID().uuidString)")

    func environment() -> ScriptEnvironment {
        var env = ScriptEnvironment.live()
        env.plugins = { self.plugins }
        env.frontPid = { self.front }
        env.macFrontPid = { self.macFront }
        env.secureInput = { self.secureInput }
        env.bundle = { self.bundles($0) }
        env.runningPid = { self.running.contains($0) ? AXReplay.floor + 1 : nil }
        env.isRunning = { self.running.contains($0) }
        env.focusedElement = { _ in self.focus }
        env.profiles = profiles
        env.soundNames = { ["link"] }
        env.say = { text, _ in self.scriptSaid.append(text) }
        env.sound = { _ in true }
        env.copy = { self.copied.append($0) }
        env.sendKeys = { _ in true }
        env.chooseMenu = { _, _ in true }
        env.refocus = { _ in }
        env.speak = { text in self.spoken.append(text); if self.echoSpeech { Speech.speakOnly(text) } }
        env.present = { title, items, closed in self.questions.append((title, items, closed)) }
        env.readClipboard = { self.clipboard }
        env.tone = { hertz, milliseconds in self.tones.append((hertz, milliseconds)) }
        env.askText = { words, done in self.prompts.append((words, done)) }
        env.dismissQuestion = { self.dismissed += 1 }
        env.options = options
        env.hostPath = hostPath
        env.afterHang = false
        env.storageFolder = { self.storage }
        env.limits = limits
        return env
    }
    /// What a plugin stored, read from its file.
    func stored(_ id: String = "script-test") -> [String: Any] {
        guard let data = try? Data(contentsOf: storage.appendingPathComponent(id + ".json")) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    init() { storages.append(storage) }
}

private final class NullBroker: ScriptBroker {
    func perform(_ operation: ScriptOperation, _ arguments: ScriptValue) throws -> ScriptValue { .null }
}

private let sealKey = Data(repeating: 7, count: 32)
private let commandStub = "turnover.command('readResult', function (c) {});\n"

/// Run a throwing call that must be refused; the words of the refusal, or nil if it went through (or failed another way).
private func refusal(_ body: () throws -> Void) -> String? {
    do { try body(); return nil } catch let error as ScriptBrokerError { if case .refused(let m) = error { return m }; return nil } catch { return nil }
}
private func invalid(_ body: () throws -> Void) -> String? {
    do { try body(); return nil } catch let error as ScriptBrokerError { if case .invalid(let m) = error { return m }; return nil } catch { return nil }
}

func scriptPlatformTests() {
    let fm = FileManager.default
    var cleanup: [URL] = []
    func temp() -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("turnover-platform-test-\(UUID().uuidString)")
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        cleanup.append(url)
        return url
    }
    /// A plugin made of a manifest (each field overridable, as scriptManifestText does) and a script.
    func load(_ overrides: [String: String?], script: String = commandStub) -> LoadedPlugin {
        let folder = scriptTempPlugin(["manifest.json": scriptManifestText(overrides), "profile.json": "{}", "main.js": script])
        cleanup.append(folder)
        return ProfileStore.load(folder: folder)
    }
    func everywhere(_ more: [String: String?] = [:], script: String = commandStub) -> LoadedPlugin {
        var overrides: [String: String?] = ["apps": "[\"*\"]", "abilities": "[\"everywhere\", \"read\", \"say\"]"]
        for (k, v) in more { overrides[k] = v }
        return load(overrides, script: script)
    }
    func store() -> ScriptTrustStore { ScriptTrustStore(file: temp().appendingPathComponent("plugin-trust.json"), inMemoryKey: sealKey) }
    func ready(_ entry: ScriptPlugins.Entry?) -> Bool { if case .ready? = entry?.host?.state { return true } else { return false } }
    func paused(_ entry: ScriptPlugins.Entry?) -> Bool { if case .paused? = entry?.host?.state { return true } else { return false } }

    /// A running ScriptPlugins over a Mac with one approved plugin.
    func start(_ mac: PMac, _ plugin: LoadedPlugin, approved: Bool = true) -> (ScriptPlugins, ScriptPlugins.Entry, ScriptTrustStore)? {
        let trust = store()
        if approved { try? trust.approve(plugin, origin: .file) }
        mac.plugins = [plugin]
        let plugins = ScriptPlugins(trust: trust, environment: mac.environment())
        guard let id = plugin.manifest?.id, let entry = plugins.entries[id] else { check(false, "the plugin has an entry"); return nil }
        return (plugins, entry, trust)
    }
    @discardableResult func fire(_ plugins: ScriptPlugins, _ kind: EventKind, _ element: AXUIElement) -> Int {
        var called = 0
        plugins.handleEvent(Event(kind, ObjectFactory.make(element)), next: { called += 1 })
        return called
    }
    func broker(_ mac: PMac, everywhere wide: Bool = false, apps: [String]? = nil, open: @escaping () -> Bool = { false }) -> AXScriptBroker {
        AXScriptBroker(pluginID: "script-test", apps: apps ?? (wide ? ["*"] : ["com.example.app"]), everywhere: wide, pluginName: "Script test", environment: mac.environment(), questionOpen: open)
    }

    guard fm.isExecutableFile(atPath: hostPath) else {
        test("script platform: the host program is built beside the test runner") { check(false, "no \(hostPath): build --product turnover-plugin-host into the same folder") }
        return
    }
    AXReplay.load(platformScreen())
    ElementMatcher.searchRoots = { pid in pid >= AXReplay.floor ? [AXReplay.root].compactMap { $0 } : nil }
    let savedDriver = Speech.enqueueTestDriver
    Speech.enqueueTestDriver = { _, _, _ in }   // nothing is spoken aloud
    defer {
        Speech.enqueueTestDriver = savedDriver; Speech.observer = nil
        ElementMatcher.searchRoots = nil; AXReplay.unload(); (cleanup + storages).forEach { try? fm.removeItem(at: $0) }
    }

    // MARK: 1. everywhere

    test("script platform: everywhere is [\"*\"] and the everywhere ability, the one never without the other") {
        let good = everywhere()
        expect(good.error, nil, "an everywhere script loads")
        expect(good.manifest?.worksEverywhere, true, "and works everywhere")
        let patterns: [(apps: String, abilities: String, words: [String])] = [
            ("[\"*\"]", "[\"read\", \"say\"]", ["every app", "everywhere"]),
            ("[\"com.example.app\"]", "[\"everywhere\", \"read\"]", ["exactly [\"*\"]"]),
            ("[\"*\", \"com.example.app\"]", "[\"everywhere\", \"read\"]", ["exactly [\"*\"]"]),
            ("[\"com.example.*\"]", "[\"read\"]", ["cannot be a pattern"]),
            ("[\"*\", \"*\"]", "[\"everywhere\", \"read\"]", ["exactly [\"*\"]"]),
        ]
        for pattern in patterns {
            let p = load(["apps": pattern.apps, "abilities": pattern.abilities])
            check(p.error != nil && pattern.words.allSatisfy { p.error!.contains($0) }, "apps \(pattern.apps) with \(pattern.abilities) is refused, saying \(pattern.words): \(p.error ?? "it loaded")")
        }
        // A data plugin is not touched: "*" there did and does nothing.
        let data = load(["apps": "[\"*\"]", "script": nil, "commands": nil, "formatVersion": nil, "abilities": "[\"read\"]"], script: "")
        expect(data.error, nil, "a plugin with no script loads as it always did")
        expect(data.manifest?.worksEverywhere, false, "and does not work everywhere")
        // A plugin that names a closed app and asks for what no closed app allows is refused, whether it acts or hears.
        for ability in ["keys", "hearSpeech", "clipboardRead"] {
            let p = load(["apps": "[\"com.apple.Terminal\"]", "abilities": "[\"read\", \"\(ability)\"]"])
            check(p.error?.contains("only read and speak") == true && p.error?.contains(ability) == true, "Terminal with \(ability) is refused: \(p.error ?? "loaded")")
        }
        expect(load(["apps": "[\"com.apple.Terminal\"]", "abilities": "[\"read\", \"say\"]"]).error, nil, "reading and speaking in Terminal is still allowed")
        // An everywhere script's commands keep the key rules.
        let plain = everywhere(["commands": "[{ \"id\": \"readResult\", \"description\": \"Read\", \"key\": \"command+control+,\" }]"])
        check(plain.error != nil, "an essential key is refused for an everywhere command too: \(plain.error ?? "")")
    }

    test("script platform: an everywhere script starts as TurnOver starts reading, is never paused, and hears no forbidden app") {
        let mac = PMac()
        mac.front = AXReplay.floor - 1; mac.macFront = AXReplay.floor - 1   // some other app is in front: none the plugin names
        let script = commandStub + """
        turnover.on("focus", function (e) { turnover.storage.set("last", e.item.name); });
        turnover.on("appFocus", async function () { const a = (await turnover.storage.get("apps")) || []; a.push(1); await turnover.storage.set("apps", a); });
        """
        guard let (plugins, entry, _) = start(mac, everywhere(script: script)) else { return }
        defer { plugins.terminate() }
        check(waitFor { ready(entry) }, "the host starts without any app coming to the front")
        settle(0.3)
        check(ready(entry), "and is not paused although no app of its own is in front")
        @MainActor func apps() -> Int { (mac.stored()["apps"] as? [Any])?.count ?? 0 }
        let baseline = apps()
        mac.bundles = { _ in "com.other.app" }
        fire(plugins, .gainFocus, el(button))
        check(waitFor { mac.stored()["last"] as? String == "Save" }, "an item in another app is told to it")
        settle(0.3)
        expect(apps(), baseline + 1, "and a new app in front is told once")
        fire(plugins, .gainFocus, el(notes)); settle(0.3)
        expect(apps(), baseline + 1, "the same app again is told nothing more")
        mac.bundles = { _ in "com.apple.SecurityAgent" }
        let before = mac.stored()["last"] as? String
        fire(plugins, .gainFocus, el(notes)); settle(0.3)
        expect(mac.stored()["last"] as? String, before, "nothing from a password dialog reaches it")
        expect(apps(), baseline + 1, "not even that it is in front")
        check(ready(entry), "it is still not paused")
        mac.bundles = { _ in "com.example.app" }
        fire(plugins, .gainFocus, el(notes)); settle(0.3)
        expect(apps(), baseline + 2, "back in an app it is told again")
        expect(mac.stored()["last"] as? String, "Notes", "and hears the focus")
    }

    test("script platform: every request of an everywhere script is judged against the app really in front") {
        let mac = PMac()
        let b = broker(mac, everywhere: true)
        guard let handle = b.item(for: el(button))?["handle"]?.stringValue else { return check(false, "an item in any app") }
        mac.focus = el(notes)
        // In an ordinary app: it reads, speaks and acts.
        expect((try? b.perform(.focused, .object([:])))?["role"]?.stringValue, "textArea", "reads the focus in any app")
        _ = try? b.perform(.say, .object(["text": .string("hello")]))
        expect(mac.scriptSaid, ["hello"], "speaks")
        check(refusal { _ = try b.perform(.itemPress, .object(["handle": .string(handle)])) } == nil, "and presses in an ordinary app")
        // In a forbidden app: nothing, not even an item.
        mac.bundles = { _ in "com.apple.SecurityAgent" }
        expect((try? b.perform(.focused, .object([:])))?["role"], nil, "no focus is given in a password dialog")
        check(b.item(for: el(button)) == nil, "no item is made in a password dialog")
        mac.scriptSaid = []
        _ = try? b.perform(.say, .object(["text": .string("hello")]))
        expect(mac.scriptSaid, [], "nothing it says is heard there")
        for operation in [ScriptOperation.itemPress, .itemRefresh, .itemRead] {
            check((try? b.perform(operation, .object(["handle": .string(handle)]))) == nil, "\(operation) is refused in a password dialog")
        }
        for command in [ScriptOperation.keys, .clipboard] {
            check(refusal { _ = try b.perform(command, .object(["keys": .string("command+k")])) } != nil, "\(command) is refused in a password dialog")
        }
        // In a closed app: it reads and speaks only.
        mac.bundles = { _ in "com.apple.Terminal" }
        guard let closedHandle = b.item(for: el(button))?["handle"]?.stringValue else { return check(false, "an item in a closed app") }
        expect(mac.scriptSaid.count, 0, "nothing said yet")
        _ = try? b.perform(.say, .object(["text": .string("in terminal")]))
        expect(mac.scriptSaid, ["in terminal"], "speaks in a closed app")
        check(refusal { _ = try b.perform(.itemPress, .object(["handle": .string(closedHandle)])) } != nil, "pressing is refused in a closed app")
        check(refusal { _ = try b.perform(.keys, .object(["keys": .string("command+k")])) } != nil, "keys are refused in a closed app")
        // A named plugin is never given another app's items, an everywhere plugin any non-forbidden app's.
        mac.bundles = { _ in "com.other.app" }
        let named = broker(mac)
        check(named.item(for: el(button)) == nil, "a named plugin has no item in an app it did not name")
        check(b.item(for: el(button)) != nil, "an everywhere plugin has")
    }

    test("script platform: an everywhere script's commands are offered in every app but a forbidden one, and a named one's only in its own") {
        let mac = PMac()
        guard let (plugins, _, _) = start(mac, everywhere()) else { return }
        defer { plugins.terminate() }
        expect(plugins.commandList(for: "com.example.app").map { $0.title }, ["Read the result"], "in an app")
        expect(plugins.commandList(for: "com.somewhere.else").map { $0.title }, ["Read the result"], "in any other")
        expect(plugins.commandList(for: "com.apple.SecurityAgent").count, 0, "not in a password dialog")
        expect(plugins.commandList(for: "com.turnover.reader").count, 0, "not in TurnOver itself")
        let other = PMac()
        guard let (named, _, _) = start(other, load([:])) else { return }
        defer { named.terminate() }
        expect(named.commandList(for: "com.example.app").count, 1, "a named plugin's, in its app")
        expect(named.commandList(for: "com.somewhere.else").count, 0, "and nowhere else")
    }

    test("script platform: an everywhere script's key clashes are checked like any other's") {
        let plugin = load(["apps": "[\"*\"]", "abilities": "[\"everywhere\", \"read\", \"say\"]", "commands": "[{ \"id\": \"readResult\", \"description\": \"Read the result\", \"key\": \"command+control+shift+q\" }]"])
        expect(plugin.error, nil, "loads")
        let listing = PluginListing.check(plugin, others: [(normalizeGestureIdentifier("kb:command+control+shift+q"), "Mail's own quit")])
        check(listing.lines.contains { $0.contains("NOTE") && $0.contains("is also Mail's own quit") }, "a clash with another command is said: \(listing.lines)")
        let twice = load(["apps": "[\"*\"]", "abilities": "[\"everywhere\", \"read\", \"say\"]", "commands": "[{ \"id\": \"one\", \"description\": \"One\", \"key\": \"command+control+shift+q\" }, { \"id\": \"two\", \"description\": \"Two\", \"key\": \"command+control+shift+q\" }]"], script: "turnover.command('one', function () {}); turnover.command('two', function () {});")
        check(PluginListing.check(twice, others: []).lines.contains { $0.contains("used twice") }, "the same key twice in one plugin is a problem")
    }

    // MARK: 2. Options

    test("script platform: options are declared with an id, a label, a kind and a default, and the manifest says what is wrong") {
        let ok = load(["options": """
        [ { "id": "loud", "label": "Say it loudly", "kind": "switch", "default": true },
          { "id": "mode", "label": "Mode", "kind": "choice", "choices": ["quiet", "loud"], "default": "quiet" },
          { "id": "name", "label": "What to call it", "kind": "text", "default": "thing" },
          { "id": "level", "label": "Level", "kind": "number", "min": 1, "max": 9, "default": 3 } ]
        """])
        expect(ok.error, nil, "four options load: \(ok.error ?? "")")
        expect(ok.manifest?.options?.count, 4, "all four")
        expect(ok.manifest?.options?[0].defaultValue, .bool(true), "a switch's default is a boolean, not a number")
        expect(ok.manifest?.options?[3].defaultValue, .number(3), "a number's default is a number")
        let long = String(repeating: "a", count: 81)
        let bad: [(String, String)] = [
            ("{ \"id\": \"a b\", \"label\": \"L\", \"kind\": \"switch\", \"default\": true }", "letters and digits"),
            ("{ \"id\": \"a\", \"label\": \"\", \"kind\": \"switch\", \"default\": true }", "needs a label"),
            ("{ \"id\": \"a\", \"label\": \"\(long)\", \"kind\": \"switch\", \"default\": true }", "at most 80"),
            ("{ \"id\": \"a\", \"label\": \"Two\\nlines\", \"kind\": \"switch\", \"default\": true }", "plain text"),
            ("{ \"id\": \"a\", \"label\": \"L\", \"kind\": \"dial\", \"default\": true }", "not one TurnOver has"),
            ("{ \"id\": \"a\", \"label\": \"L\", \"kind\": \"switch\", \"default\": 1 }", "true or false"),
            ("{ \"id\": \"a\", \"label\": \"L\", \"kind\": \"choice\", \"choices\": [\"x\"], \"default\": \"y\" }", "one of the choices"),
            ("{ \"id\": \"a\", \"label\": \"L\", \"kind\": \"choice\", \"choices\": [\"x\", \"x\"], \"default\": \"x\" }", "two choices are the same"),
            ("{ \"id\": \"a\", \"label\": \"L\", \"kind\": \"choice\", \"default\": \"x\" }", "1 to 50 choices"),
            ("{ \"id\": \"a\", \"label\": \"L\", \"kind\": \"number\", \"min\": 5, \"max\": 1, \"default\": 3 }", "min is larger than max"),
            ("{ \"id\": \"a\", \"label\": \"L\", \"kind\": \"number\", \"min\": 1, \"max\": 5, \"default\": 9 }", "from 1.0 to 5.0"),
            ("{ \"id\": \"a\", \"label\": \"L\", \"kind\": \"number\", \"default\": 3 }", "min and a max"),
            ("{ \"id\": \"a\", \"label\": \"L\", \"kind\": \"switch\" }", "default"),
        ]
        for (option, words) in bad {
            let p = load(["options": "[\(option)]"])
            check(p.error?.contains(words) == true, "\(option) is refused, saying \"\(words)\": \(p.error ?? "it loaded")")
        }
        let twice = load(["options": "[{ \"id\": \"a\", \"label\": \"A\", \"kind\": \"switch\", \"default\": true }, { \"id\": \"a\", \"label\": \"B\", \"kind\": \"switch\", \"default\": true }]"])
        check(twice.error?.contains("used twice") == true, "an id used twice: \(twice.error ?? "")")
        let many = (0..<21).map { "{ \"id\": \"o\($0)\", \"label\": \"O\", \"kind\": \"switch\", \"default\": true }" }.joined(separator: ",")
        check(load(["options": "[\(many)]"]).error?.contains("at most 20") == true, "21 options are too many")
        let noScript = load(["script": nil, "commands": nil, "abilities": "[\"read\"]", "options": "[{ \"id\": \"a\", \"label\": \"A\", \"kind\": \"switch\", \"default\": true }]"], script: "")
        check(noScript.error?.contains("options need a script") == true, "options belong to a script: \(noScript.error ?? "")")
    }

    test("script platform: an option keeps only a value it allows, and a saved value it does not allow is the default again") {
        let level = PluginOption(id: "level", label: "Level", kind: "number", min: 1, max: 9, defaultValue: .number(3))
        let mode = PluginOption(id: "mode", label: "Mode", kind: "choice", choices: ["quiet", "loud"], defaultValue: .string("quiet"))
        let name = PluginOption(id: "name", label: "Name", kind: "text", defaultValue: .string("thing"))
        let loud = PluginOption(id: "loud", label: "Loud", kind: "switch", defaultValue: .bool(false))
        var saved: [[String: [String: Any]]] = []
        let kept = ScriptOptionsStore(save: { saved.append($0) })
        expect(kept.value(of: level, plugin: "p"), .number(3), "the default until it is changed")
        expect(kept.set(.number(5), of: level, plugin: "p"), .number(5), "a number in range is kept")
        expect(kept.set(.number(10), of: level, plugin: "p"), nil, "one out of range is not")
        expect(kept.set(.number(.nan), of: level, plugin: "p"), nil, "nor one that is not a number")
        expect(kept.set(.string("5"), of: level, plugin: "p"), nil, "nor text for a number")
        expect(kept.set(.string("loud"), of: mode, plugin: "p"), .string("loud"), "a choice among the choices is kept")
        expect(kept.set(.string("silent"), of: mode, plugin: "p"), nil, "another is not")
        expect(kept.set(.bool(true), of: loud, plugin: "p"), .bool(true), "a switch")
        expect(kept.set(.string(String(repeating: "a", count: 201)), of: name, plugin: "p"), nil, "text longer than 200 characters is not")
        expect(kept.set(.string("two\nlines"), of: name, plugin: "p"), nil, "nor text with a line break")
        expect(kept.value(of: level, plugin: "p"), .number(5), "what is kept is still there")
        expect(kept.value(of: level, plugin: "q"), .number(3), "and is the plugin's own")
        expect(saved.count, 3, "each kept change was saved, no other")
        // What was saved comes back, but only what the option still allows.
        let again = ScriptOptionsStore(load: ["p": ["level": 5.0, "mode": "loud", "loud": true], "q": ["level": 99.0, "mode": 7]])
        expect(again.value(of: level, plugin: "p"), .number(5), "a saved number")
        expect(again.value(of: mode, plugin: "p"), .string("loud"), "a saved choice")
        expect(again.value(of: loud, plugin: "p"), .bool(true), "a saved switch (a boolean is not a number)")
        expect(again.value(of: level, plugin: "q"), .number(3), "a saved number out of range is the default")
        expect(again.value(of: mode, plugin: "q"), .string("quiet"), "a saved choice of the wrong kind is the default")
        expect(PluginOptionValue(any: NSNumber(value: true)), .bool(true), "a stored true is a boolean")
        expect(PluginOptionValue(any: NSNumber(value: 1)), .number(1), "a stored 1 is a number")
    }

    test("script platform: the script reads its options, is told when one changes, and the menu shows them in the author's words") {
        let mac = PMac()
        let script = commandStub + """
        turnover.command('readResult', async function () {
          await turnover.storage.set('seen', [turnover.options.get('loud'), turnover.options.get('level'), turnover.options.get('mode'), turnover.options.get('name'), turnover.options.get('nothing')]);
        });
        turnover.on('optionsChange', function (e) { turnover.storage.set('changed', [e.id, e.value]); });
        """
        let options = """
        [ { "id": "loud", "label": "Say it loudly", "kind": "switch", "default": false },
          { "id": "mode", "label": "Mode of speaking", "kind": "choice", "choices": ["quiet", "loud"], "default": "quiet" },
          { "id": "name", "label": "What to call it", "kind": "text", "default": "thing" },
          { "id": "level", "label": "Level", "kind": "number", "min": 1, "max": 9, "default": 3 } ]
        """
        guard let (plugins, entry, _) = start(mac, load(["options": options, "abilities": "[\"read\", \"say\"]"], script: script)) else { return }
        defer { plugins.terminate() }
        fire(plugins, .gainFocus, el(button))
        check(waitFor { ready(entry) }, "the script loads")
        plugins.run("readResult", of: entry)
        check(waitFor { mac.stored()["seen"] != nil }, "the command ran")
        let seen = mac.stored()["seen"] as? [Any]
        expect(seen?[0] as? Bool, false, "a switch starts at its default")
        expect(seen?[1] as? Double, 3, "a number")
        expect(seen?[2] as? String, "quiet", "a choice")
        expect(seen?[3] as? String, "thing", "text")
        check(seen?[4] is NSNull, "an option that is not declared is null")
        // The person changes one in the menu.
        let items = plugins.optionItems(forPlugin: "script-test")
        expect(items.map(\.title), ["Say it loudly", "Mode of speaking", "What to call it", "Level"], "the labels, as the author wrote them, in the order given")
        expect(items.compactMap(\.hint), Array(repeating: "An option of Script test", count: 4), "each says whose option it is")
        if case .toggle(let get, let set) = items[0].kind { expect(get(), false, "off"); set(true); expect(get(), true, "on") } else { check(false, "a switch is a toggle") }
        check(waitFor { (mac.stored()["changed"] as? [Any])?.first as? String == "loud" }, "the script is told which option changed")
        expect((mac.stored()["changed"] as? [Any])?[1] as? Bool, true, "and to what")
        if case .cycle(let choices, let get, let set) = items[1].kind { expect(choices, ["quiet", "loud"], "the choices"); set(1); expect(get(), 1, "the second") } else { check(false, "a choice is a cycle") }
        if case .number(let get, let set, _, let lo, let hi, _) = items[3].kind { expect([lo, hi], [1, 9], "its range"); set(7); expect(get(), 7, "set"); set(70); expect(get(), 7, "out of range is not kept") } else { check(false, "a number") }
        plugins.run("readResult", of: entry)
        check(waitFor { (mac.stored()["seen"] as? [Any])?[0] as? Bool == true }, "the script reads the new value at once")
        let again = mac.stored()["seen"] as? [Any]
        expect(again?[1] as? Double, 7, "the number")
        expect(again?[2] as? String, "loud", "the choice")
        if case .action(let run) = items[2].kind {
            run()
            check(waitFor { !mac.prompts.isEmpty }, "text is asked for with TurnOver's own prompt")
            mac.prompts[0].done("renamed")
            plugins.run("readResult", of: entry)
            check(waitFor { (mac.stored()["seen"] as? [Any])?[3] as? String == "renamed" }, "and the script reads it")
        } else { check(false, "a text option asks") }
    }

    test("script platform: options reach a script that was paused, and the author's labels cannot carry markup into the menu") {
        let mac = PMac()
        let script = commandStub + "turnover.command('readResult', async function () { await turnover.storage.set('level', turnover.options.get('level')); });\n"
        let options = "[{ \"id\": \"level\", \"label\": \"Level\", \"kind\": \"number\", \"min\": 1, \"max\": 9, \"default\": 3 }]"
        guard let (plugins, entry, _) = start(mac, load(["options": options], script: script)) else { return }
        defer { plugins.terminate() }
        fire(plugins, .gainFocus, el(button))
        check(waitFor { ready(entry) }, "starts")
        mac.front = AXReplay.floor - 1; mac.bundles = { _ in "com.other.app" }
        fire(plugins, .gainFocus, el(button))   // its app is no longer in front: it pauses
        check(waitFor { paused(entry) }, "paused while its app is behind")
        if let option = entry.plugin.manifest?.options?.first { plugins.setOption(.number(8), option, ofPlugin: "script-test") }
        mac.front = AXReplay.floor + 1; mac.bundles = { $0 >= AXReplay.floor ? "com.example.app" : "com.other.app" }
        fire(plugins, .gainFocus, el(button))
        check(waitFor { ready(entry) }, "resumed")
        plugins.run("readResult", of: entry)
        check(waitFor { mac.stored()["level"] as? Double == 8 }, "it reads the value set while it was paused")
        let wide = load(["options": "[{ \"id\": \"a\", \"label\": \"Say \\u001b[31m red\", \"kind\": \"switch\", \"default\": true }]"])
        check(wide.error?.contains("plain text") == true, "a control character in a label is refused: \(wide.error ?? "")")
        let marked = load(["options": "[{ \"id\": \"a\", \"label\": \"Say \\uF8F0 link\", \"kind\": \"switch\", \"default\": true }]"])
        check(marked.error?.contains("plain text") == true, "so is one of TurnOver's own private marks: \(marked.error ?? "")")
    }

    // MARK: 3. choose and ask

    test("script platform: choose puts up TurnOver's own list and answers with the item or null") {
        let mac = PMac()
        let b = broker(mac)
        var answers: [Result<ScriptValue, any Error>] = []
        b.perform(deferred: .choose, .object(["title": .string("Which one?"), "items": .array([.string("Save"), .string("Cancel\nnow")])])) { answers.append($0) }
        expect(mac.questions.count, 1, "a list is put up")
        expect(mac.questions[0].title, "Script test: Which one?", "it says whose question it is, then the title")
        expect(mac.questions[0].items.map(\.title), ["Save", "Cancel now"], "the items, made plain")
        expect(answers.count, 0, "nothing is answered until the person answers")
        mac.questions[0].closed()   // TurnOver's list closes first, then the chosen item's action runs
        if case .action(let run) = mac.questions[0].items[1].kind { run() }
        check(waitFor { !answers.isEmpty }, "the answer comes")
        expect((try? answers[0].get())?.stringValue, "Cancel now", "the item chosen")
        // Dismissed.
        answers = []; mac.questions = []
        b.perform(deferred: .choose, .object(["title": .string("Again"), "items": .array([.string("One")])])) { answers.append($0) }
        mac.questions[0].closed()
        check(waitFor { !answers.isEmpty }, "answered")
        expect((try? answers[0].get()) ?? .bool(false), .null, "dismissed is null")
    }

    test("script platform: ask puts up TurnOver's own prompt and answers with the text or null") {
        let mac = PMac()
        let b = broker(mac)
        var answers: [Result<ScriptValue, any Error>] = []
        b.perform(deferred: .ask, .object(["prompt": .string("What name?")])) { answers.append($0) }
        expect(mac.prompts.map(\.words), ["Script test asks: What name?"], "the prompt says whose it is")
        mac.prompts[0].done("Ann")
        check(waitFor { !answers.isEmpty }, "the answer comes")
        expect((try? answers[0].get())?.stringValue, "Ann", "the text typed")
        answers = []
        b.perform(deferred: .ask, .object(["prompt": .string("Again?")])) { answers.append($0) }
        mac.prompts[1].done(nil)
        check(waitFor { !answers.isEmpty }, "answered")
        expect((try? answers[0].get()) ?? .bool(false), .null, "Escape is null")
        answers = []
        b.perform(deferred: .ask, .object(["prompt": .string("Long?")])) { answers.append($0) }
        mac.prompts[2].done(String(repeating: "z", count: 5000))
        check(waitFor { !answers.isEmpty }, "answered")
        expect((try? answers[0].get())?.stringValue?.count, PluginWire.Limits.answerCharacters, "what comes back is cut to \(PluginWire.Limits.answerCharacters)")
    }

    test("script platform: a question is refused while another is open, when the app is not in front, over a password, and with bad arguments") {
        @MainActor func ask(_ b: AXScriptBroker, _ operation: ScriptOperation, _ args: [String: ScriptValue]) -> Result<ScriptValue, any Error>? {
            var out: Result<ScriptValue, any Error>?
            b.perform(deferred: operation, .object(args)) { out = $0 }
            return out
        }
        @MainActor func refused(_ r: Result<ScriptValue, any Error>?) -> String? { if case .failure(let e as ScriptBrokerError)? = r, case .refused(let m) = e { return m }; return nil }
        @MainActor func rejected(_ r: Result<ScriptValue, any Error>?) -> String? { if case .failure(let e as ScriptBrokerError)? = r, case .invalid(let m) = e { return m }; return nil }
        let list: [String: ScriptValue] = ["title": .string("T"), "items": .array([.string("a")])]
        let mac = PMac()
        let b = broker(mac)
        _ = ask(b, .choose, list)
        expect(mac.questions.count, 1, "the first is put up")
        check(refused(ask(b, .choose, list))?.contains("Another question is open") == true, "a second from the same plugin is refused")
        check(refused(ask(b, .ask, ["prompt": .string("P")]))?.contains("Another question is open") == true, "so is a prompt")
        expect(mac.questions.count, 1, "and no second list appeared")
        expect(mac.prompts.count, 0, "or prompt")
        // Another plugin's, or an approval's, open question refuses this plugin's, through the shared slot.
        let slotMac = PMac()
        let shut = AXScriptBroker(pluginID: "script-test", apps: ["com.example.app"], pluginName: "Script test", environment: slotMac.environment(), questionOpen: { true }, beginQuestion: { false })
        check(refused(ask(shut, .choose, list))?.contains("Another question is open") == true, "another plugin's question is respected")
        expect(slotMac.questions.count, 0, "and nothing is put up")
        // Not in front.
        let behind = PMac(); behind.front = AXReplay.floor - 1
        check(refused(ask(broker(behind), .choose, list)) != nil, "refused while the plugin's app is not in front")
        let macBehind = PMac(); macBehind.macFront = AXReplay.floor - 1
        check(refused(ask(broker(macBehind), .ask, ["prompt": .string("P")])) != nil, "and while the Mac says another app is")
        // Over a password, under secure keyboard entry, or when TurnOver cannot tell what has the focus.
        let secret = PMac(); secret.focus = el(password)
        check(refused(ask(broker(secret), .choose, list))?.contains("password") == true, "refused while a password field has the focus")
        let secure = PMac(); secure.secureInput = true
        check(refused(ask(broker(secure), .ask, ["prompt": .string("P")]))?.contains("hiding what is typed") == true, "refused under secure keyboard entry")
        let blind = PMac(); blind.focus = nil
        check(refused(ask(broker(blind), .choose, list)) != nil, "refused when the focus cannot be found")
        expect(secret.questions.count + secure.prompts.count + blind.questions.count, 0, "none of them put anything up")
        // In a closed app a prompt (typed words) is refused, a list is not.
        let closed = PMac(); closed.bundles = { _ in "com.apple.Terminal" }
        check(refused(ask(broker(closed, apps: ["com.apple.Terminal"]), .ask, ["prompt": .string("P")]))?.contains("read and speak") == true, "no prompt in a closed app")
        _ = ask(broker(closed, apps: ["com.apple.Terminal"]), .choose, list)
        expect(closed.questions.count, 1, "a list is only speaking, and goes up")
        // A forbidden app: nothing, for an everywhere plugin too.
        let forbidden = PMac(); forbidden.bundles = { _ in "com.apple.SecurityAgent" }
        check(refused(ask(broker(forbidden, everywhere: true), .choose, list)) != nil, "nothing in a password dialog")
        // Arguments.
        let good = PMac()
        @MainActor func bad(_ args: [String: ScriptValue], _ op: ScriptOperation = .choose) -> String? { rejected(ask(broker(good), op, args)) }
        check(bad(["title": .string("T"), "items": .array([])]) != nil, "no items")
        check(bad(["title": .string("T"), "items": .array((0..<201).map { _ in .string("a") })]) != nil, "201 items")
        check(bad(["title": .string("T"), "items": .array([.string(String(repeating: "a", count: 201))])]) != nil, "an item of 201 characters")
        check(bad(["title": .string("T"), "items": .array([.number(1)])]) != nil, "an item that is not text")
        check(bad(["title": .string("T"), "items": .array([.string("\u{1B}\u{F8F0}")])]) != nil, "an item with nothing left once control characters and marks are taken out")
        check(bad(["title": .string(String(repeating: "t", count: 201)), "items": .array([.string("a")])]) != nil, "a title of 201 characters")
        check(bad(["items": .array([.string("a")])]) != nil, "no title")
        check(bad(["prompt": .string(String(repeating: "p", count: 201))], .ask) != nil, "a prompt of 201 characters")
        check(bad([:], .ask) != nil, "no prompt")
        expect(good.questions.count + good.prompts.count, 0, "none put anything up")
        _ = ask(broker(good), .choose, ["title": .string("T"), "items": .array((0..<200).map { _ in .string(String(repeating: "a", count: 200)) })])
        expect(good.questions.count, 1, "200 items of 200 characters go up")
    }

    test("script platform: a script that waits for a question is not killed for waiting, and a question open when the script goes is closed") {
        let mac = PMac()
        mac.limits.killLimit = 0.4
        let script = commandStub + """
        turnover.command('readResult', async function () {
          const first = turnover.choose('Pick', ['One', 'Two']);
          let second = 'none';
          try { await turnover.choose('Again', ['A']); } catch (e) { second = String(e.message); }
          await turnover.storage.set('second', second);
          const answer = await first;
          await turnover.storage.set('answer', answer);
        });
        """
        guard let (plugins, entry, _) = start(mac, load(["abilities": "[\"read\", \"say\"]"], script: script)) else { return }
        defer { plugins.terminate() }
        fire(plugins, .gainFocus, el(button))
        check(waitFor { ready(entry) }, "the script loads")
        plugins.run("readResult", of: entry)
        check(waitFor { mac.questions.count == 1 }, "the list is put up")
        expect(plugins.questionIsOpen, true, "TurnOver knows a question is open")
        settle(1.0)   // two and a half times the limit for a command to finish
        check(ready(entry), "the script was not stopped for the person's time")
        mac.questions[0].closed()
        if case .action(let run) = mac.questions[0].items[1].kind { run() }
        check(waitFor { mac.stored()["answer"] as? String == "Two" }, "the answer reaches the script after the wait")
        check((mac.stored()["second"] as? String)?.contains("Another question is open") == true, "a second list asked for while the first was open was refused: \(mac.stored()["second"] ?? "")")
        expect(plugins.questionIsOpen, false, "no question is open any more")
        // A second command with a list open, then the plugin turned off: the list is closed.
        mac.questions = []
        let slow = PMac()
        let onlyAsk = commandStub + "turnover.command('readResult', async function () { await turnover.choose('Wait', ['One']); });\n"
        guard let (second, secondEntry, _) = start(slow, load(["abilities": "[\"read\", \"say\"]"], script: onlyAsk)) else { return }
        defer { second.terminate() }
        fire(second, .gainFocus, el(button))
        check(waitFor { ready(secondEntry) }, "the second script loads")
        second.run("readResult", of: secondEntry)
        check(waitFor { slow.questions.count == 1 }, "its list is up")
        second.turnEverythingOff()
        expect(slow.dismissed, 1, "turning the plugin off closes its list")
    }

    test("script platform: a question and a tone each need the say ability, and a plugin without it is told which to add") {
        for operation in [ScriptOperation.choose, .ask, .tone] {
            expect(ScriptAbilities.required(for: operation), [.say], "\(operation) needs say")
            expect(ScriptAbilities.missing(for: operation, granted: [.read]), [.say], "and a plugin with only read is missing it")
        }
        expect(PluginWire.Operation.choose.isDeferred && PluginWire.Operation.ask.isDeferred, true, "both are answered later")
        expect(PluginWire.Operation.tone.isNotification, true, "a tone is one way")
        let mac = PMac()
        let script = commandStub + "turnover.command('readResult', async function () { let e = 'none'; try { await turnover.choose('T', ['a']); } catch (x) { e = String(x.message); } await turnover.storage.set('error', e); });\n"
        guard let (plugins, entry, _) = start(mac, load(["abilities": "[\"read\"]"], script: script)) else { return }
        defer { plugins.terminate() }
        fire(plugins, .gainFocus, el(button))
        check(waitFor { ready(entry) }, "loads")
        plugins.run("readResult", of: entry)
        check(waitFor { mac.stored()["error"] != nil }, "the command ran")
        check((mac.stored()["error"] as? String)?.contains("\"say\"") == true, "the error names the ability: \(mac.stored()["error"] ?? "")")
        expect(mac.questions.count, 0, "and no list went up")
    }

    // MARK: 4. tone

    test("script platform: a tone is 100 to 4000 hertz and 10 to 500 milliseconds, and is heard only while the plugin's app is in front") {
        let mac = PMac()
        let b = broker(mac)
        _ = try? b.perform(.tone, .object(["hertz": .number(440), "milliseconds": .number(120)]))
        expect(mac.tones.count, 1, "a tone plays")
        expect(mac.tones[0].0, 440, "at its pitch"); expect(mac.tones[0].1, 120, "for its length")
        for (hertz, ms) in [(99.0, 100.0), (4001.0, 100.0), (440.0, 9.0), (440.0, 501.0), (Double.nan, 100.0), (440.0, Double.infinity)] {
            check(invalid { _ = try b.perform(.tone, .object(["hertz": .number(hertz), "milliseconds": .number(ms)])) } != nil, "\(hertz) hertz for \(ms) milliseconds is refused")
        }
        check(invalid { _ = try b.perform(.tone, .object(["hertz": .string("high")])) } != nil, "text is refused")
        for edge in [(100.0, 10.0), (4000.0, 500.0)] { _ = try? b.perform(.tone, .object(["hertz": .number(edge.0), "milliseconds": .number(edge.1)])) }
        expect(mac.tones.count, 3, "the edges are inside the limits")
        let behind = PMac(); behind.front = AXReplay.floor - 1
        _ = try? broker(behind).perform(.tone, .object(["hertz": .number(440), "milliseconds": .number(50)]))
        expect(behind.tones.count, 0, "nothing plays while the app is behind")
        let asking = PMac()
        _ = try? broker(asking, open: { true }).perform(.tone, .object(["hertz": .number(440), "milliseconds": .number(50)]))
        expect(asking.tones.count, 0, "nor while a question is open")
    }

    test("script platform: tones count toward the same limit as what a script says") {
        let mac = PMac()
        mac.limits.saysPerWindow = 3
        let script = commandStub + "turnover.command('readResult', function () { for (let i = 0; i < 6; i++) turnover.tone(440, 50); turnover.say('late'); });\n"
        guard let (plugins, entry, _) = start(mac, load([:], script: script)) else { return }
        defer { plugins.terminate() }
        fire(plugins, .gainFocus, el(button))
        check(waitFor { ready(entry) }, "loads")
        plugins.run("readResult", of: entry)
        check(waitFor { mac.tones.count >= 3 }, "tones play")
        settle(0.5)
        expect(mac.tones.count, 3, "no more than the limit")
        expect(mac.scriptSaid, [], "and the budget was used up, so the words that came after were refused too")
        let out = load([:], script: commandStub + "turnover.command('readResult', function () { turnover.tone(50, 10); });\n")
        expect(out.error, nil, "a script with a bad tone still loads")
    }

    // MARK: 5. text and caret

    test("script platform: item.text gives the selection, the line or all of it, and a password field gives nothing") {
        let mac = PMac()
        let b = broker(mac)
        @MainActor func text(_ id: Int, _ unit: String) -> String? {
            guard let handle = b.item(for: el(id))?["handle"]?.stringValue else { return nil }
            return (try? b.perform(.itemText, .object(["handle": .string(handle), "unit": .string(unit)])))?.stringValue
        }
        expect(text(notes, "selection"), "Second line", "the selected text")
        expect(text(notes, "all"), notesText, "all of it")
        check(text(notes, "line")?.hasPrefix("Second line") == true, "the line the caret is on: \(text(notes, "line") ?? "nil")")
        expect(text(longField, "all")?.count, 10_000, "at most 10,000 characters")
        expect(text(longField, "selection")?.count, 10_000, "a long selection is cut too")
        expect(text(password, "selection"), "", "a password field gives nothing, however it is asked")
        expect(text(password, "line"), "", "nothing")
        expect(text(password, "all"), "", "nothing at all")
        expect(text(button, "all"), "", "an item with no text gives an empty string")
        let passwordHandle = b.item(for: el(password))?["handle"]?.stringValue ?? ""
        check(!String(describing: (try? b.perform(.itemText, .object(["handle": .string(passwordHandle), "unit": .string("all")])))?.json).contains("hunter2"), "the password is nowhere in what comes back")
        check(invalid { _ = try b.perform(.itemText, .object(["handle": .string(passwordHandle), "unit": .string("page")])) } == nil, "a password field is never even told that the unit is wrong")
        let notesHandle = b.item(for: el(notes))?["handle"]?.stringValue ?? ""
        check(invalid { _ = try b.perform(.itemText, .object(["handle": .string(notesHandle), "unit": .string("page")])) } != nil, "an unknown unit is refused")
        expect(ScriptAbilities.required(for: .itemText), [.read], "reading text needs read")
        // The item is not the plugin's: no text.
        mac.bundles = { _ in "com.other.app" }
        check(refusal { _ = try b.perform(.itemText, .object(["handle": .string(notesHandle), "unit": .string("all")])) } != nil, "an item in another app is refused")
    }

    test("script platform: setCaret and select move in the text under edit, with every rule edit has") {
        let mac = PMac()
        let b = broker(mac)
        let n = b.item(for: el(notes))?["handle"]?.stringValue ?? "", p = b.item(for: el(password))?["handle"]?.stringValue ?? ""
        expect(ScriptAbilities.required(for: .itemSetCaret), [.edit], "setCaret needs edit")
        expect(ScriptAbilities.required(for: .itemSelect), [.edit], "select needs edit")
        let before = AXReplay.sets.count
        _ = try? b.perform(.itemSetCaret, .object(["handle": .string(n), "offset": .number(3)]))
        expect(AXReplay.sets.last?.attribute, kAXSelectedTextRangeAttribute, "the caret is set through the selected range")
        expect(AXReplay.sets.last?.value, .range(3, 0), "to a place with no length")
        _ = try? b.perform(.itemSelect, .object(["handle": .string(n), "start": .number(2), "end": .number(9)]))
        expect(AXReplay.sets.last?.value, .range(2, 7), "a selection from 2 to 9")
        expect(AXReplay.sets.count, before + 2, "two writes")
        let after = AXReplay.sets.count
        for (name, args) in [("a place past the end", ["handle": ScriptValue.string(n), "offset": .number(100)]), ("a negative place", ["handle": .string(n), "offset": .number(-1)]),
                             ("a fraction", ["handle": .string(n), "offset": .number(1.5)]), ("not a number", ["handle": .string(n), "offset": .string("1")]),
                             ("infinity", ["handle": .string(n), "offset": .number(.infinity)])] {
            check(invalid { _ = try b.perform(.itemSetCaret, .object(args)) } != nil, "setCaret: \(name) is invalid")
        }
        check(invalid { _ = try b.perform(.itemSelect, .object(["handle": .string(n), "start": .number(9), "end": .number(2)])) } != nil, "select: the end before the start is invalid")
        check(invalid { _ = try b.perform(.itemSelect, .object(["handle": .string(n), "start": .number(0), "end": .number(100)])) } != nil, "select: past the end is invalid")
        // The rules edit has.
        check(refusal { _ = try b.perform(.itemSetCaret, .object(["handle": .string(p), "offset": .number(1)])) }?.contains("password") == true, "a password field is never changed")
        check(refusal { _ = try b.perform(.itemSelect, .object(["handle": .string(p), "start": .number(0), "end": .number(1)])) }?.contains("password") == true, "nor selected in")
        mac.focus = el(password)
        check(refusal { _ = try b.perform(.itemSetCaret, .object(["handle": .string(n), "offset": .number(1)])) }?.contains("password") == true, "refused while a password field has the focus")
        mac.focus = nil
        check(refusal { _ = try b.perform(.itemSetCaret, .object(["handle": .string(n), "offset": .number(1)])) }?.contains("cannot tell") == true, "refused when the focus cannot be found")
        mac.focus = el(notes); mac.secureInput = true
        check(refusal { _ = try b.perform(.itemSelect, .object(["handle": .string(n), "start": .number(0), "end": .number(1)])) }?.contains("hiding what is typed") == true, "refused under secure keyboard entry")
        mac.secureInput = false; mac.front = AXReplay.floor - 1
        check(refusal { _ = try b.perform(.itemSetCaret, .object(["handle": .string(n), "offset": .number(1)])) } != nil, "refused while the app is not in front")
        mac.front = AXReplay.floor + 1; mac.macFront = AXReplay.floor - 1
        check(refusal { _ = try b.perform(.itemSetCaret, .object(["handle": .string(n), "offset": .number(1)])) } != nil, "and when the Mac says another app is")
        mac.macFront = AXReplay.floor + 1; mac.bundles = { _ in "com.apple.Terminal" }
        let inTerminal = broker(mac, apps: ["com.apple.Terminal"])
        let tn = inTerminal.item(for: el(notes))?["handle"]?.stringValue ?? ""
        check(refusal { _ = try inTerminal.perform(.itemSetCaret, .object(["handle": .string(tn), "offset": .number(1)])) }?.contains("read and speak") == true, "refused in a closed app")
        expect(AXReplay.sets.count, after, "none of those wrote anything")
    }

    // MARK: 6. hearSpeech

    /// A named plugin that may hear speech, started, in front, with its script storing what it hears.
    func hearing(_ mac: PMac, abilities: String = "[\"read\", \"say\", \"hearSpeech\"]", wide: Bool = false, script: String? = nil) -> (ScriptPlugins, ScriptPlugins.Entry)? {
        let body = script ?? "turnover.on('speech', function (e) { turnover.storage.set('heard', e.text); });\n"
        let plugin = wide ? everywhere(["abilities": "[\"everywhere\", \"read\", \"say\", \"hearSpeech\"]"], script: commandStub + body) : load(["abilities": abilities], script: commandStub + body)
        guard let (plugins, entry, _) = start(mac, plugin) else { return nil }
        plugins.installSpeechHearing()
        fire(plugins, .gainFocus, el(button))
        guard waitFor(5, { ready(entry) }) else { check(false, "the hearing script loads"); return nil }
        return (plugins, entry)
    }

    test("script platform: a script with hearSpeech is told what TurnOver says in its app, and speech is neither changed nor stopped") {
        let mac = PMac()
        guard let (plugins, entry) = hearing(mac) else { return }
        defer { plugins.terminate() }
        var sink: [String] = []
        let before = Speech.sink
        Speech.sink = { sink.append($0) }
        Speech.speakOnly("Hello there")
        Speech.sink = before
        check(waitFor { mac.stored()["heard"] as? String == "Hello there" }, "the words arrive as TurnOver says them")
        expect(sink, ["Hello there"], "TurnOver said them as usual, untouched")
        expect(ScriptAbility.hearSpeech.rawValue, "hearSpeech", "the ability's name")
        check(entry.hearsSpeech, "the entry hears")
        check(Speech.observer != nil, "speech is observed while a script may hear")
        plugins.terminate()
        check(Speech.observer == nil, "and no longer once scripts end")
    }

    test("script platform: what TurnOver says is not heard in a password field, under secure typing, in the wrong app, or while a question is open") {
        let mac = PMac()
        guard let (plugins, _) = hearing(mac) else { return }
        defer { plugins.terminate() }
        @MainActor func said(_ words: String, _ why: String) {
            Speech.speakOnly(words); settle(0.25)
            check(mac.stored()["heard"] as? String != words, "\(why): \(words) was not heard")
        }
        mac.focus = el(password);          said("one", "a password field has the focus")
        mac.focus = nil;                   said("two", "the focus cannot be found")
        mac.focus = el(notes); mac.secureInput = true; said("three", "the Mac hides what is typed")
        mac.secureInput = false
        mac.front = AXReplay.floor - 1;    said("four", "TurnOver's focus is in another app")
        mac.front = AXReplay.floor + 1; mac.macFront = AXReplay.floor - 1; said("five", "the Mac's frontmost app is another")
        mac.macFront = AXReplay.floor + 1
        mac.bundles = { _ in "com.other.app" }; said("six", "the app is not the plugin's")
        mac.bundles = { _ in "com.apple.SecurityAgent" }; said("seven", "a password dialog")
        mac.bundles = { _ in "com.apple.Terminal" }; said("eight", "a closed app")
        mac.bundles = { $0 >= AXReplay.floor ? "com.example.app" : "com.other.app" }
        // While a question is open (an approval, or another plugin's list or prompt): what is typed there is not another's to hear.
        plugins.askApproval("script-test")
        said("nine", "an approval question is open")
        mac.questions[0].closed()
        settle(0.2)
        Speech.speakOnly("ten"); check(waitFor { mac.stored()["heard"] as? String == "ten" }, "it is heard again when the question has closed, and everything above was safe to say")
        // What a plugin said itself is never passed on.
        Speech.attributedToPlugin { Speech.speakOnly("mine") }
        settle(0.25)
        check(mac.stored()["heard"] as? String != "mine", "what a plugin said is not heard")
    }

    test("script platform: a plugin without hearSpeech, or with it only in another app, hears nothing, and a notice about a plugin is not heard") {
        let mac = PMac()
        guard let (plugins, _) = hearing(mac, abilities: "[\"read\", \"say\"]") else { return }
        defer { plugins.terminate() }
        Speech.speakOnly("secret words"); settle(0.3)
        expect(mac.stored()["heard"] as? String, nil, "without the ability nothing is sent, even if its script asks to hear")
        check(Speech.observer != nil, "(observing is on, but no plugin may listen)")
        // A command that fails makes TurnOver say something with the plugin's own error in it: that is not heard by a plugin that hears.
        let noisy = PMac()
        noisy.echoSpeech = true
        let script = "turnover.on('speech', function (e) { turnover.storage.set('heard', e.text); });\nturnover.command('readResult', function () { throw new Error('the author says so'); });\n"
        guard let (second, secondEntry) = hearing(noisy, script: script) else { return }
        defer { second.terminate() }
        second.run("readResult", of: secondEntry)
        check(waitFor { noisy.spoken.contains { $0.contains("could not do that") } }, "TurnOver says the command failed")
        settle(0.3)
        expect(noisy.stored()["heard"] as? String, nil, "and the plugin does not hear that, nor the author's own error text")
    }

    test("script platform: at most 20 things a second reach a script that hears, each cut to 1,000 characters") {
        let mac = PMac()
        let script = "let n = 0; let longest = 0;\nturnover.on('speech', function (e) { n += 1; longest = Math.max(longest, e.text.length); turnover.storage.set('n', [n, longest]); });\n"
        guard let (plugins, _) = hearing(mac, script: script) else { return }
        defer { plugins.terminate() }
        for i in 0..<40 { Speech.speakOnly("line \(i)") }
        Speech.speakOnly(String(repeating: "q", count: 3000))
        settle(0.8)
        let n = (mac.stored()["n"] as? [Any])?.first as? Double ?? 0
        check(n <= 20 && n >= 15, "no more than twenty in a second reach it: \(n)")
        let t = PMac()
        guard let (second, _) = hearing(t, script: script) else { return }
        defer { second.terminate() }
        Speech.speakOnly(String(repeating: "q", count: 3000)); settle(0.5)
        expect((t.stored()["n"] as? [Any])?.last as? Double, 1000, "a long thing is cut to 1,000 characters")
        let limits = ScriptLimits()
        expect(limits.heardPerSecond, 20, "the number is in ScriptLimits"); expect(limits.heardCharacters, 1000, "and the length")
    }

    test("script platform: an everywhere script hears speech in any app but a forbidden or closed one") {
        let mac = PMac()
        mac.bundles = { _ in "com.other.app" }
        guard let (plugins, _) = hearing(mac, wide: true) else { return }
        defer { plugins.terminate() }
        Speech.speakOnly("anywhere"); check(waitFor { mac.stored()["heard"] as? String == "anywhere" }, "heard in an app it never named")
        mac.bundles = { _ in "com.apple.loginwindow" }
        Speech.speakOnly("login"); settle(0.25)
        check(mac.stored()["heard"] as? String != "login", "not at the login window")
    }

    // MARK: 7. clipboardRead

    test("script platform: clipboard gives the clipboard's text only in front, never under secure typing or in a closed app") {
        expect(ScriptAbilities.required(for: .clipboard), [.clipboardRead], "it needs clipboardRead")
        expect(ScriptAbilities.missing(for: .clipboard, granted: [.clipboard]), [.clipboardRead], "writing the clipboard is not reading it")
        let mac = PMac()
        let b = broker(mac)
        expect((try? b.perform(.clipboard, .object([:])))?.stringValue, "On the clipboard", "the text, in front")
        mac.clipboard = nil
        expect((try? b.perform(.clipboard, .object([:])))?.stringValue, "", "an empty string when there is none")
        mac.clipboard = String(repeating: "c", count: 12_000)
        expect((try? b.perform(.clipboard, .object([:])))?.stringValue?.count, 10_000, "at most 10,000 characters")
        mac.clipboard = "x"
        mac.front = AXReplay.floor - 1
        check(refusal { _ = try b.perform(.clipboard, .object([:])) } != nil, "refused while the plugin's app is not in front")
        mac.front = AXReplay.floor + 1; mac.macFront = AXReplay.floor - 1
        check(refusal { _ = try b.perform(.clipboard, .object([:])) } != nil, "and when the Mac says another app is")
        mac.macFront = AXReplay.floor + 1; mac.secureInput = true
        check(refusal { _ = try b.perform(.clipboard, .object([:])) }?.contains("hiding what is typed") == true, "refused under secure keyboard entry")
        mac.secureInput = false; mac.bundles = { _ in "com.apple.Terminal" }
        check(refusal { _ = try broker(mac, apps: ["com.apple.Terminal"]).perform(.clipboard, .object([:])) }?.contains("read and speak") == true, "refused in a closed app")
        let wide = broker(mac, everywhere: true)
        mac.bundles = { _ in "com.other.app" }
        expect((try? wide.perform(.clipboard, .object([:])))?.stringValue, "x", "an everywhere plugin reads it in any ordinary app")
        mac.bundles = { _ in "com.apple.SecurityAgent" }
        check(refusal { _ = try wide.perform(.clipboard, .object([:])) } != nil, "but not in a password dialog")
        let named = broker(mac)
        mac.bundles = { _ in "com.other.app" }
        check(refusal { _ = try named.perform(.clipboard, .object([:])) } != nil, "a named plugin not in its app does not")
    }

    // MARK: 8. support and reasons

    test("script platform: a reason follows TurnOver's own sentence, marked as the author's, and says nothing for an ability not held") {
        let plugin = load(["abilities": "[\"read\", \"say\", \"keys\"]", "reasons": "{ \"keys\": \"Sends Command-T to jump to today.\", \"press\": \"Presses it.\" }"])
        expect(plugin.error, nil, "loads: \(plugin.error ?? "")")
        let lines = ScriptAbilities.approvalLines(for: plugin, appName: { _ in nil })
        guard let at = lines.firstIndex(where: { $0.kind == .ability && $0.text.hasPrefix("It can press keys") }) else { return check(false, "the keys sentence is there") }
        expect(lines[at + 1].kind, .reason, "the reason comes straight after")
        expect(lines[at + 1].text, "The author says it uses this to: Sends Command-T to jump to today.", "marked as the author's")
        expect(lines.filter { $0.kind == .reason }.count, 1, "only for an ability the plugin has")
        check(!lines.contains { $0.text.contains("Presses it.") }, "a reason for press, which it does not ask for, is not said")
        check(lines[at].text == ScriptAbilities.sentence(for: .keys), "TurnOver's own sentence is unchanged")
        let long = load(["abilities": "[\"read\", \"keys\"]", "reasons": "{ \"keys\": \"\(String(repeating: "a", count: 151))\" }"])
        check(long.error?.contains("at most 150") == true, "151 characters is refused: \(long.error ?? "")")
        let exact = load(["abilities": "[\"read\", \"keys\"]", "reasons": "{ \"keys\": \"\(String(repeating: "a", count: 150))\" }"])
        expect(exact.error, nil, "150 is allowed")
        let control = load(["abilities": "[\"read\", \"keys\"]", "reasons": "{ \"keys\": \"Two\\nlines\" }"])
        check(control.error?.contains("plain text") == true, "a line break is refused: \(control.error ?? "")")
        let unknown = load(["abilities": "[\"read\", \"keys\"]", "reasons": "{ \"flying\": \"Because.\" }"])
        check(unknown.error?.contains("not an ability") == true, "a reason for something that is not an ability is refused: \(unknown.error ?? "")")
        // A reason that got past the loader (a plugin built in memory) is still held to the rule when said.
        expect(ScriptAbilities.reasonText(String(repeating: "a", count: 151)), nil, "too long is not said")
        expect(ScriptAbilities.reasonText("two\nlines"), nil, "nor with a break")
        expect(ScriptAbilities.reasonText("  Fine.  "), "Fine.", "trimmed")
    }

    test("script platform: the library wants a reason for every ability above read and say, and a support address") {
        @MainActor func listed(_ overrides: [String: String?]) -> ScriptListingResult {
            var all: [String: String?] = ["summary": "\"Does a thing\"", "description": "\"Does a thing for you.\"", "author": "\"Ann\"", "contact": "\"https://example.com/c\"",
                                           "privacy": "\"Nothing leaves your Mac.\"", "license": "\"MIT\"", "changes": "[{ \"version\": \"1\", \"notes\": \"First.\" }]",
                                           "support": "\"https://example.com/help\"", "abilities": "[\"read\", \"say\"]"]
            for (k, v) in overrides { all[k] = v }
            return ScriptListingResult(PluginListing.check(load(all), others: []))
        }
        expect(listed([:]).problems, 0, "reading and speaking need no reason: \(listed([:]).lines)")
        let missing = listed(["abilities": "[\"read\", \"keys\", \"hearSpeech\"]"])
        check(missing.lines.contains { $0.contains("reasons has nothing for \"keys\"") }, "a reason for keys is wanted: \(missing.lines)")
        check(missing.lines.contains { $0.contains("reasons has nothing for \"hearSpeech\"") }, "and for hearSpeech")
        let given = listed(["abilities": "[\"read\", \"keys\"]", "reasons": "{ \"keys\": \"Sends Command-T.\" }"])
        expect(given.problems, 0, "with it, the plugin is ready: \(given.lines)")
        let extra = listed(["abilities": "[\"read\", \"keys\"]", "reasons": "{ \"keys\": \"Sends Command-T.\", \"edit\": \"Changes a field.\" }"])
        check(extra.lines.contains { $0.contains("gives a reason for \"edit\", which the plugin does not ask for") }, "a reason for an ability it does not ask for is flagged: \(extra.lines)")
        let blank = listed(["abilities": "[\"read\", \"keys\"]", "reasons": "{ \"keys\": \"   \" }"])
        check(blank.lines.contains { $0.contains("reasons has nothing for \"keys\"") }, "a blank reason is no reason")
        check(listed(["support": nil]).lines.contains { $0.contains("support is missing") }, "a support address is wanted")
        check(listed(["support": "\"not an address\""]).lines.contains { $0.contains("is not a web address") }, "and it must be an address")
        expect(listed(["support": "\"help@example.com\""]).problems, 0, "an email address is one")
        check(listed(["support": "\"http://example.com\""]).lines.contains { $0.contains("is not a web address") }, "a plain http address is not")
        // A plugin with no script keeps what it had: contact, no reasons.
        let data = load(["script": nil, "commands": nil, "formatVersion": nil, "abilities": "[\"read\", \"keys\"]", "summary": "\"x\"", "description": "\"x\"", "author": "\"x\"", "contact": "\"https://example.com\"",
                         "privacy": "\"x\"", "license": "\"MIT\"", "changes": "[{ \"version\": \"1\", \"notes\": \"x\" }]"], script: "")
        check(!PluginListing.check(data, others: []).lines.contains { $0.contains("reasons") || $0.contains("support") }, "a data plugin is asked for neither")
    }

    test("script platform: Report a problem says who looks after the plugin and copies the address with its name, version and the build") {
        var manifest = PluginManifest(id: "calc", name: "Calc helper", version: "2.1", author: "Ann Author", apps: ["com.apple.calculator"])
        manifest.support = "https://example.com/help"
        let (spoken, copied) = PluginSupport.report(for: manifest, build: "TurnOver 2.0 (build 33)")
        expect(spoken, "Calc helper is looked after by Ann Author. To report a problem, write to https://example.com/help. The address, the plugin's name and version and TurnOver's build are on the clipboard.", "what is said")
        check(copied.contains("Calc helper 2.1 (calc)") && copied.contains("TurnOver 2.0 (build 33)") && copied.contains("https://example.com/help") && copied.contains("Ann Author"), "what is copied: \(copied)")
        manifest.support = nil; manifest.contact = "ann@example.com"
        expect(PluginSupport.address(for: manifest), "ann@example.com", "the older contact stands in")
        manifest.contact = nil; manifest.author = nil
        let none = PluginSupport.report(for: manifest, build: "b")
        check(none.spoken.contains("The author of Calc helper is not named.") && none.spoken.contains("gives no address"), "no author and no address are said plainly: \(none.spoken)")
        expect(PluginSupport.isValidAddress("https://example.com/x"), true, "https"); expect(PluginSupport.isValidAddress("a@b.co"), true, "email")
        expect(PluginSupport.isValidAddress("javascript:alert(1)"), false, "not a script address"); expect(PluginSupport.isValidAddress("http://example.com"), false, "not plain http")
        expect(PluginSupport.isValidAddress("https://example.com/a b"), false, "no spaces"); expect(PluginSupport.isValidAddress("a@b"), false, "a host needs a dot")
        check(!PluginSupport.report(for: manifest, build: "b").copied.contains("\u{0}"), "no odd characters")
    }

    test("script platform: the menu has one item that turns every plugin, rules and scripts, off until TurnOver starts again") {
        let mac = PMac()
        let dataFolder = scriptTempPlugin(["manifest.json": "{ \"id\": \"data-one\", \"name\": \"Data one\", \"version\": \"1\", \"apps\": [\"com.example.app\"] }", "profile.json": "{ \"labels\": [{ \"match\": { \"role\": \"button\", \"unnamed\": true }, \"name\": \"Go\" }] }"])
        cleanup.append(dataFolder)
        let data = ProfileStore.load(folder: dataFolder)
        expect(data.error, nil, "the data plugin loads: \(data.error ?? "")")
        mac.profiles.addTesting(data)
        let scripted = load([:])
        mac.profiles.addTesting(scripted)
        guard let (plugins, entry, _) = start(mac, scripted) else { return }
        defer { plugins.terminate() }
        fire(plugins, .gainFocus, el(button))
        check(waitFor { ready(entry) }, "the script runs")
        expect(mac.profiles.livePlugins.map { $0.manifest?.id ?? "" }.sorted(), ["data-one", "script-test"], "both plugins are live")
        guard let item = plugins.items().first(where: { $0.title == "Turn off every plugin until TurnOver starts again" }) else { return check(false, "the menu has the item") }
        if case .action(let run) = item.kind { run() } else { check(false, "it is an action") }
        expect(mac.profiles.pluginsOff, true, "every plugin is off")
        expect(mac.profiles.livePlugins.count, 0, "no rule, label or view is live")
        expect(mac.profiles.profiles(for: "com.example.app").count, 0, "no profile applies to an app")
        check(entry.host == nil, "the script's host has stopped")
        check(mac.spoken.last?.contains("until TurnOver starts again") == true, "and TurnOver says so")
        fire(plugins, .gainFocus, el(button)); settle(0.3)
        check(entry.host == nil, "it does not start again when its app comes to the front")
        plugins.run("readResult", of: entry)
        check(mac.spoken.last?.contains("off until TurnOver starts again") == true, "a command says the scripts are off")
        check(plugins.items().first?.title.contains("off until TurnOver starts again") == true, "and the menu shows it")
        // A new run of TurnOver (a new store) has them back.
        let fresh = ProfileStore()
        fresh.addTesting(data)
        expect(fresh.livePlugins.count, 1, "the switch is only in memory: a store that has just started has its plugins")
    }

    // MARK: 9 and 10. The level, and the sentences

    test("script platform: the level of review is one function of the abilities, with the reason in a sentence") {
        @MainActor func level(_ abilities: [ScriptAbility]) -> ScriptReview.Level { ScriptReview.level(for: Set(abilities)) }
        expect(level([]).number, 1, "nothing: low")
        expect(level([.read, .say]).number, 1, "reading and speaking: low")
        for ability in [ScriptAbility.press, .focus, .edit, .menu, .keys, .clipboard, .everywhere] {
            expect(level([.read, .say, ability]).number, 2, "\(ability) is higher")
        }
        for ability in [ScriptAbility.hearSpeech, .clipboardRead] { expect(level([.read, ability]).number, 3, "\(ability) is highest") }
        expect(level([.keys, .hearSpeech, .everywhere]).number, 3, "the highest of any decides")
        expect(level([.read]).reason, "It only reads and speaks in the apps it names, so it has no reviewer: the automatic checks run, and your own approval is the safeguard.", "the low reason")
        check(level([.everywhere, .keys]).reason.contains("work in every app") && level([.everywhere, .keys]).reason.contains("press keys"), "the higher reason names what decided it: \(level([.everywhere, .keys]).reason)")
        check(level([.hearSpeech, .clipboardRead]).reason.contains("hear what TurnOver says to you and read what you copy"), "the highest reason: \(level([.hearSpeech, .clipboardRead]).reason)")
        check(level([.hearSpeech]).summary.hasPrefix("Review level 3. "), "the summary starts with the level")
        // The abilities the plugin really has decide, profile rules included.
        let plugin = load(["abilities": "[\"read\", \"clipboardRead\"]"])
        expect(ScriptReview.level(for: ScriptAbilities.effective(for: plugin)).number, 3, "from a loaded plugin")
    }

    test("script platform: each new ability has its own approval sentence, exact about what is agreed to") {
        let wide = everywhere(["abilities": "[\"everywhere\", \"read\", \"say\", \"hearSpeech\", \"clipboardRead\"]"])
        expect(wide.error, nil, "loads")
        let lines = ScriptAbilities.approvalLines(for: wide, appName: { _ in nil }).map(\.text)
        check(lines.first?.contains("works in every app you use") == true && lines.first?.contains("except in password and permission dialogs and the login window") == true, "everywhere is said first and plainly: \(lines.first ?? "")")
        check(lines.contains("It works in every app except passwords and permission dialogs, its keys work in every app, and, because it can also read, it can read what is on the screen wherever you are."), "everywhere with read: \(lines)")
        check(lines.contains("It hears what TurnOver says to you in those apps, as TurnOver says it, except in password fields. It cannot change it or stop it."), "hearSpeech: \(lines)")
        check(lines.contains("It can read what you copy: the text on the clipboard, while you are in those apps."), "clipboardRead: \(lines)")
        check(lines.contains("It can never use the internet, read or change your files, see the keys you press, or see a password."), "the fixed sentence has no \"any other app\" for an everywhere plugin: \(lines)")
        check(lines.contains { $0.hasPrefix("In passwords, settings, terminals and browsers it can only read and speak.") }, "and says what it can do in the sensitive apps: \(lines)")
        let withoutRead = everywhere(["abilities": "[\"everywhere\", \"say\"]"])
        let plainer = ScriptAbilities.approvalLines(for: withoutRead, appName: { _ in nil }).map(\.text)
        check(plainer.contains("It works in every app except passwords and permission dialogs, and its keys work in every app."), "without read it does not say it can read the screen: \(plainer)")
        check(!plainer.contains { $0.contains("read what is on the screen wherever") }, "nothing about reading")
        let named = load(["abilities": "[\"read\", \"clipboardRead\"]"])
        let namedLines = ScriptAbilities.approvalLines(for: named, appName: { _ in nil }).map(\.text)
        check(namedLines.contains("It can never use the internet, read or change your files, see the keys you press, see a password, or reach any other app."), "a named plugin keeps its sentence")
        check(!namedLines.contains { $0.contains("every app you use") }, "and does not say it works everywhere")
        for ability in ScriptAbility.allCases { check(!ScriptAbilities.sentence(for: ability).isEmpty, "\(ability) has a sentence") }
        expect(Set(ScriptAbility.allCases.map { ScriptAbilities.sentence(for: $0) }).count, ScriptAbility.allCases.count, "and no two are alike")
    }

    // MARK: 12. The independent review's open findings

    test("script platform: review: a search can never learn what a password field holds, however the match is built") {
        let mac = PMac()
        let b = broker(mac)
        @MainActor func find(_ match: [String: ScriptValue]) -> [String] {
            let found = (try? b.perform(.find, .object(["match": .object(match)])))
            if case .array(let list)? = found { return list.compactMap { let name = $0["name"]?.stringValue ?? ""; return name.isEmpty ? $0["value"]?.stringValue : name } }
            return ["error"]
        }
        // The control: the same searches find an ordinary field by its value.
        expect(find(["value": .string("An*")]), ["Name"], "an ordinary field is found by its value")
        expect(find(["value": .string("Total*")]), ["Total 12"], "static text too")
        expect(find(["role": .string("textField"), "value": .string("A*")]), ["Name"], "with a role")
        // The password field is found by what is not secret, and never by its value, direct or nested.
        expect(find(["title": .string("Password")]), ["Password"], "by its title it can be found: a title is not a secret")
        let guesses: [[String: ScriptValue]] = [
            ["value": .string("hunter2")], ["value": .string("hunter*")], ["value": .string("h*")], ["value": .string("*")],
            ["role": .string("textField"), "value": .string("hunter*")],
            ["any": .array([.object(["value": .string("hunter*")])])],
            ["any": .array([.object(["title": .string("Nothing")]), .object(["value": .string("hunter2")])])],
            ["value": .string("hunter*"), "nth": .number(1)],
            ["value": .string("hunter*"), "nth": .number(-1)],
            ["value": .string("hunter*"), "inside": .object(["role": .string("group")])],
            ["value": .string("hunter*"), "parent": .object(["title": .string("Login")])],
            ["value": .string("hunter*"), "parent": .object(["any": .array([.object(["role": .string("group")])])])],
            ["title": .string("Password"), "value": .string("hunter*")],
        ]
        for guess in guesses {
            let hit = find(guess)
            check(!hit.contains("Password"), "\(guess) did not find the password field: \(hit)")
        }
        expect(find(["value": .string("*")]).contains("Password"), false, "even \"has a value\" does not say the password field has one")
        // The same through the matcher a script uses, directly, with and without the guard (so the test would notice it removed).
        var secret = ElementMatch(); secret.value = "hunter*"
        check(ElementMatcher.matches(el(password), secret), "an ordinary search does match the field's value (so the guard is what protects it)")
        check(!ElementMatcher.matches(el(password), secret, context: ElementMatcher.SearchContext(hideSecure: true)), "a script's search does not")
        check(ElementMatcher.find(secret, pid: AXReplay.floor + 1, hideSecure: true).isEmpty, "a search with hideSecure finds nothing by that value")
        check(!ElementMatcher.find(secret, pid: AXReplay.floor + 1, hideSecure: false).isEmpty, "and one without would (the review's finding, closed by the flag)")
        // The text of an item is the static text inside it, so a password field's value is not in it either.
        check(!ElementMatcher.text(of: el(6)).contains("hunter2"), "the text inside the group holds no password")
    }

    test("script platform: review: a write that comes after the host has ended finds its input closed and does nothing") {
        let host = ScriptHost(plugin: ScriptPluginInfo(id: "race", name: "Race", version: "1"), abilities: [.say], commands: [], source: "turnover.say('x');\n", hostPath: hostPath, broker: NullBroker())
        host.start()
        check(waitFor { if case .ready = host.state { return true } else { return false } }, "the host starts")
        check(!host.inputIsClosed, "its input is open while it runs")
        guard let pid = host.processID else { return check(false, "a process") }
        Darwin.kill(pid, SIGKILL)   // it ends on its own, as a crash does: not through stop()
        check(waitFor { if case .failed = host.state { return true } else { return false } }, "its end is noticed")
        check(waitFor { host.inputIsClosed }, "and its input is closed for every later write, not only after stop()")
        for _ in 0..<500 { host.pause(); host.resume(); host.tell("appFocus") }
        host.setOptions(["a": .bool(true)])
        check(!host.isRunning, "late writes did nothing and did not crash")
    }

    test("script platform: review: the keeper's sandbox check is a string check, and what it does and does not prove is pinned") {
        let home = "/Users/x/Library/Containers/com.turnover.reader.trust-keeper/Data"
        check(TrustKeeperStore.isSandboxed(home: home, environment: ["APP_SANDBOX_CONTAINER_ID": "id"]), "a container home and a name pass")
        check(TrustKeeperStore.isSandboxed(home: "/tmp/Library/Containers/anything", environment: ["APP_SANDBOX_CONTAINER_ID": "spoof"]), "and so does anyone who writes both: the check is a guard against a mistake, not proof of confinement")
        // What stops a program that spoofs both is not this check: the keeper answers only a connection from the signed app (checked
        // with the keeper's own tests), and a copy cannot be started as the service launchd runs. Whether macOS confines the real
        // service can only be shown on the signed build (`turnover --check-trust-keeper`), which a test cannot run.
        check(!Edition.isDevBuild, "the test runner is not a developer build (it has no TODevBuild in its Info.plist), so the shared store would be the keeper's")
        expect(Bundle.main.object(forInfoDictionaryKey: "TODevBuild") as? Bool, nil, "which is where that choice is read from")
    }

    // MARK: Tools: the scenario runner, the scaffold and the samples

    test("script platform: the scenario runner gives a script its options, plays lists, prompts, tones, text and speech") {
        let folder = scriptTempPlugin([
            "manifest.json": scriptManifestText([
                "abilities": "[\"read\", \"say\", \"edit\", \"clipboardRead\", \"hearSpeech\"]",
                "options": "[{ \"id\": \"level\", \"label\": \"Level\", \"kind\": \"number\", \"min\": 1, \"max\": 9, \"default\": 3 }, { \"id\": \"loud\", \"label\": \"Loud\", \"kind\": \"switch\", \"default\": false }]",
            ]),
            "main.js": """
            turnover.on('speech', function (e) { turnover.say('heard ' + e.text); });
            turnover.on('optionsChange', function (e) { turnover.say(e.id + '=' + e.value); });
            turnover.command('readResult', async function (context) {
              turnover.say('level ' + turnover.options.get('level') + (turnover.options.get('loud') ? ' loud' : ''));
              const pick = await turnover.choose('Pick', ['A', 'B']);
              const typed = await turnover.ask('Name?');
              turnover.tone(440, 100);
              const item = (await turnover.find({ role: 'textArea' }))[0];
              turnover.say([pick, typed, await item.text({ unit: 'line' }), await turnover.clipboard()].join('|'));
              await item.setCaret(2); await item.select(1, 3);
            });
            """,
            "tests/script/all.json": """
            [ { "name": "options at their defaults, a list, a prompt, a tone, text and the clipboard",
                "steps": [ { "command": "readResult",
                    "answers": { "choose": "B", "ask": "Ann", "find": [ { "role": "textArea", "name": "Notes" } ], "item.text": "Second line", "clipboard": "copied", "item.setCaret": true, "item.select": true },
                    "expect": { "said": ["level 3", "B|Ann|Second line|copied"], "tones": [[440, 100]],
                                "asked": [ { "choose": "Pick", "items": ["A", "B"] }, { "ask": "Name?" } ] } } ] },
              { "name": "a scenario's own options, and a change while it runs",
                "options": { "level": 8, "loud": true },
                "steps": [ { "event": "optionsChange", "id": "level", "value": 2, "expect": {} },
                           { "command": "readResult", "answers": { "choose": null, "ask": null, "find": [ { "role": "textArea" } ], "item.text": "", "clipboard": "", "item.setCaret": true, "item.select": true },
                             "expect": { "said": ["level 2 loud", "|||"] } } ] },
              { "name": "speech is heard",
                "steps": [ { "event": "speech", "text": "Saved", "expect": { "said": ["heard Saved"] } },
                           { "event": "optionsChange", "id": "loud", "value": true, "expect": { "said": ["loud=true"] } } ] } ]
            """,
        ])
        cleanup.append(folder)
        let outcome = ScriptScenarioRunner.run(folder: folder, hostPath: hostPath)
        expect(outcome.failed, 0, "the scenarios pass: \(outcome.lines)")
        expect(outcome.passed, 3, "all three")
        // The runner tells an author what is wrong with a test.
        let wrong = scriptTempPlugin([
            "manifest.json": scriptManifestText(["abilities": "[\"read\", \"say\"]", "options": "[{ \"id\": \"level\", \"label\": \"Level\", \"kind\": \"number\", \"min\": 1, \"max\": 9, \"default\": 3 }]"]),
            "main.js": commandStub + "turnover.command('readResult', async function () { await turnover.choose('P', ['A']); });\n",
            "tests/script/wrong.json": """
            [ { "name": "no answer for the list", "steps": [ { "command": "readResult" } ] },
              { "name": "an answer that is not an item", "steps": [ { "command": "readResult", "answers": { "choose": "Z" } } ] },
              { "name": "an option the manifest does not have", "options": { "nothing": 1 }, "steps": [ { "command": "readResult", "answers": { "choose": null } } ] },
              { "name": "a value the option does not allow", "steps": [ { "event": "optionsChange", "id": "level", "value": 99 } ] },
              { "name": "speech for a plugin that cannot hear", "steps": [ { "event": "speech", "text": "x" } ] } ]
            """,
        ])
        cleanup.append(wrong)
        let bad = ScriptScenarioRunner.run(folder: wrong, hostPath: hostPath)
        let report = bad.lines.joined(separator: "\n")
        expect(bad.failed, 4, "four of those fail: \(report)")
        check(report.contains("has no answer for it: add \"choose\""), "the missing answer is named")
        check(report.contains("which is not one of the items"), "a choice that is not an item is said")
        check(report.contains("which manifest.json does not declare"), "an option that is not declared is said")
        check(report.contains("does not allow that value"), "a value the option refuses is said")
    }

    test("script platform: turnover-plugin new --everywhere makes a plugin that loads, checks, lists its level and passes its own test") {
        let folder = temp().appendingPathComponent("every-thing")
        let written = (try? PluginScaffold.make(folder: folder, app: "*", script: true, everywhere: true)) ?? []
        check(written.contains("manifest.json") && written.contains("main.js") && written.contains("tests/script/first.json"), "the files: \(written)")
        let plugin = ProfileStore.load(folder: folder)
        expect(plugin.error, nil, "it loads: \(plugin.error ?? "")")
        expect(plugin.manifest?.worksEverywhere, true, "it works everywhere")
        expect(plugin.manifest?.apps, ["*"], "with apps [\"*\"]")
        expect(ScriptReview.level(for: ScriptAbilities.effective(for: plugin)).number, 2, "at level 2")
        let outcome = ScriptScenarioRunner.run(folder: folder, hostPath: hostPath)
        expect(outcome.failed, 0, "its first test passes: \(outcome.lines)")
        check(PluginListing.check(plugin, others: []).lines.contains { $0.contains("reasons has nothing") } == false, "its reason for everywhere is there")
        let report = ScriptChecker.check(plugin, hostPath: hostPath)
        expect(report.problems, [], "the checker finds nothing wrong")
        check((try? PluginScaffold.make(folder: temp().appendingPathComponent("a"), app: "com.example.app", script: true, everywhere: true)) == nil, "everywhere with a named app is refused")
        check((try? PluginScaffold.make(folder: temp().appendingPathComponent("b"), app: "*", script: true)) == nil, "\"*\" without everywhere is refused")
        check((try? PluginScaffold.make(folder: temp().appendingPathComponent("c"), app: "*", script: false, everywhere: true)) == nil, "everywhere needs a script")
        let named = temp().appendingPathComponent("named")
        _ = try? PluginScaffold.make(folder: named, app: "com.apple.calculator", script: true)
        expect(ProfileStore.load(folder: named).manifest?.worksEverywhere, false, "the ordinary scaffold is unchanged")
    }

    test("script platform: the chooser sample is an every-app plugin at level 2 that lists, passes its tests and has a reason for each ability") {
        let sample = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("plugins/examples/sample-script-chooser")
        let plugin = ProfileStore.load(folder: sample)
        expect(plugin.error, nil, "it loads: \(plugin.error ?? "")")
        expect(plugin.warnings, [], "with no warnings")
        expect(plugin.manifest?.worksEverywhere, true, "it works in every app")
        expect(plugin.manifest?.options?.count, 3, "it has options")
        expect(Set(plugin.manifest?.reasons?.keys.map { $0 } ?? []), ["everywhere", "press"], "and a reason for each ability above read and say")
        let listing = PluginListing.check(plugin, others: [])
        expect(listing.problems, 0, "it is ready to list: \(listing.lines)")
        expect(ScriptReview.level(for: ScriptAbilities.effective(for: plugin)).number, 2, "level 2")
        let outcome = ScriptScenarioRunner.run(folder: sample, hostPath: hostPath)
        expect(outcome.failed, 0, "its tests pass: \(outcome.lines)")
        expect(outcome.passed, 5, "five tests")
        let report = ScriptChecker.check(plugin, hostPath: hostPath)
        expect(report.problems, [], "the checker finds nothing: \(report.problems)")
        expect(report.warnings, [], "and no warnings")
        expect(report.commands, ["chooseButton"], "it handles its command")
        let lines = ScriptAbilities.approvalLines(for: plugin, appName: { _ in nil }).map(\.text)
        check(lines.contains { $0.hasPrefix("The author says it uses this to: Presses the one button") }, "the author's reason is said at approval: \(lines)")
    }

    test("script platform: the checker warns when a script uses what its abilities do not allow") {
        let source = "turnover.choose('a', ['b']); turnover.ask('c'); turnover.tone(440, 10); turnover.clipboard(); item.text({ unit: 'all' }); item.setCaret(1); item.select(1, 2);"
        let warnings = ScriptChecker.abilityWarnings(source: source, granted: [.read])
        let text = warnings.joined(separator: "\n")
        for member in ["turnover.choose", "turnover.ask", "turnover.tone", "turnover.clipboard", "setCaret", "select"] {
            check(text.contains("\(member)(…)"), "\(member) is noticed: \(text)")
        }
        expect(ScriptChecker.abilityWarnings(source: source, granted: [.say, .read, .edit, .clipboardRead]), [], "with the abilities there are none")
    }
}

/// The listing's lines and problem count, kept together so a test reads them without the type's name.
private struct ScriptListingResult {
    let lines: [String]
    let problems: Int
    init(_ result: PluginListing.Result) { lines = result.lines; problems = result.problems }
}
