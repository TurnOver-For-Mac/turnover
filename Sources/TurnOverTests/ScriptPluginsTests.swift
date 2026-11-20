// SPDX-License-Identifier: GPL-3.0-or-later
// Plugin scripts joining TurnOver (docs/PLUGIN-SCRIPTS-PLAN.md, stage 3, 15 Nov 2026): the real broker over a recorded
// screen, and ScriptPlugins with the real sandboxed host program, against a stand-in for the Mac (what is in front, what
// was said, what was asked). Every store keeps its key in memory and its files in the temporary folder: nothing touches
// the Keychain, the real support folder, the real plugins folder or ~/.turnover-plugin, and no key is sent or sound played.
import Foundation
import CryptoKit
import ApplicationServices
import TurnOverCore
import AXFixtures
import TurnOverPluginWire

private let hostPath: String = {
    let runner = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    return runner.deletingLastPathComponent().appendingPathComponent("turnover-plugin-host").path
}()

private func waitFor(_ seconds: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
    let until = Date().addingTimeInterval(seconds)
    while !condition(), Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    return condition()
}
private func settle(_ seconds: TimeInterval) { _ = waitFor(seconds) { false } }

// MARK: A small recorded screen

/// A window with a button, a text field, a password field and some text, in an app called com.example.app.
private func miniScreen() -> AXFixture {
    typealias V = AXFixture.Value
    func node(_ id: Int, _ attrs: [String: V], actions: [String] = []) -> AXFixture.Node { AXFixture.Node(id: id, attrs: attrs, params: [], actions: actions) }
    let inWindow: [String: V] = [kAXParentAttribute: .element(0), kAXWindowAttribute: .element(0)]
    func child(_ role: String, _ more: [String: V]) -> [String: V] { inWindow.merging([kAXRoleAttribute: .string(role)].merging(more) { a, _ in a }) { a, _ in a } }
    return AXFixture(app: "Example", bundle: "com.example.app", recorded: "2026-11-15", root: 0, application: 5, focus: 1, nodes: [
        node(0, [kAXRoleAttribute: .string("AXWindow"), kAXTitleAttribute: .string("Main"), kAXChildrenAttribute: .elements([1, 2, 3, 4]), kAXParentAttribute: .element(5)]),
        node(1, child("AXButton", [kAXTitleAttribute: .string("Save"), kAXEnabledAttribute: .bool(true)]), actions: ["AXPress"]),
        node(2, child("AXTextField", [kAXTitleAttribute: .string("Name"), kAXValueAttribute: .string("Ann")])),
        node(3, child("AXTextField", [kAXSubroleAttribute: .string("AXSecureTextField"), kAXTitleAttribute: .string("Password"), kAXValueAttribute: .string("hunter2")])),
        node(4, child("AXStaticText", [kAXValueAttribute: .string("Total 12")])),
        node(5, [kAXRoleAttribute: .string("AXApplication"), kAXChildrenAttribute: .elements([0])]),
        // A menu item, held by no window: only for asking whether pressing it is refused.
        // Two buttons with very long names, held by no window: for the wildcard tests.
        node(7, [kAXRoleAttribute: .string("AXButton"), kAXTitleAttribute: .string(String(repeating: "a", count: 5_000)), kAXParentAttribute: .element(5)]),
        node(8, [kAXRoleAttribute: .string("AXButton"), kAXTitleAttribute: .string(String(repeating: "a", count: 20_000)), kAXParentAttribute: .element(5)]),
        node(6, [kAXRoleAttribute: .string("AXMenuItem"), kAXTitleAttribute: .string("Paste"), kAXParentAttribute: .element(5)], actions: ["AXPress"]),
    ])
}

private let button = 1, nameField = 2, passwordField = 3, totalText = 4, menuItem = 6, longName = 7, longerName = 8
private func el(_ id: Int) -> AXUIElement { AXReplay.element(id) }

// MARK: A stand-in for the Mac

/// The folders the stand-ins keep stored data in, removed when the tests end.
nonisolated(unsafe) private var macStorages: [URL] = []

private final class Mac {
    var front: pid_t? = AXReplay.floor + 1       // TurnOver's own idea of the focus
    var macFront: pid_t? = AXReplay.floor + 1    // the Mac's frontmost app
    var secureInput = false
    var bundles: (pid_t) -> String = { $0 >= AXReplay.floor ? "com.example.app" : "com.other.app" }
    var focus: AXUIElement?
    var scriptSaid: [String] = []     // what a script said or read, as TurnOver would speak it
    var spoken: [String] = []         // everything TurnOver itself said (notices, start-up words, results)
    var sounds: [String] = [], keys: [String] = [], menus: [[String]] = [], copied: [String] = []
    var running: Set<String> = ["com.example.app"]
    var plugins: [LoadedPlugin] = []
    var afterHang = false
    var limits = ScriptLimits()
    var questions: [(title: String, items: [MenuItem], closed: () -> Void)] = []
    var onFocusQuery: (() -> Void)?   // run when TurnOver asks the app what has the focus (a slow question, in the Mac's life)
    let profiles = ProfileStore()
    var soundNames = ["link"]
    let storage = FileManager.default.temporaryDirectory.appendingPathComponent("turnover-script-storage-\(UUID().uuidString)")

    func environment() -> ScriptEnvironment {
        var env = ScriptEnvironment.live()
        env.plugins = { self.plugins }
        env.frontPid = { self.front }
        env.macFrontPid = { self.macFront }
        env.secureInput = { self.secureInput }
        env.bundle = { self.bundles($0) }
        env.runningPid = { self.running.contains($0) ? AXReplay.floor + 1 : nil }
        env.isRunning = { self.running.contains($0) }
        env.focusedElement = { _ in self.onFocusQuery?(); return self.focus }
        env.profiles = profiles
        env.soundNames = { self.soundNames }
        env.say = { text, _ in self.scriptSaid.append(text) }
        env.sound = { name in self.sounds.append(name); return name == "link" }
        env.copy = { self.copied.append($0) }
        env.sendKeys = { self.keys.append($0); return true }
        env.chooseMenu = { path, _ in self.menus.append(path); return true }
        env.refocus = { _ in }
        env.speak = { self.spoken.append($0) }
        env.present = { title, items, closed in self.questions.append((title, items, closed)) }
        env.hostPath = hostPath
        env.afterHang = afterHang
        env.storageFolder = { self.storage }
        env.limits = limits
        return env
    }
    init() { macStorages.append(storage) }
}

private let sealKey = Data(repeating: 9, count: 32)
private let commandStub = "turnover.command('readResult', function (c) {});\n"

func scriptPluginsTests() {
    let fm = FileManager.default
    var cleanup: [URL] = []
    func temp() -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("turnover-script-plugins-test-\(UUID().uuidString)")
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        cleanup.append(url)
        return url
    }
    func makePlugin(id: String = "script-test", script: String, abilities: String = "[\"read\", \"say\"]", apps: String = "[\"com.example.app\"]", commands: String? = nil) -> LoadedPlugin {
        var overrides: [String: String?] = ["id": "\"\(id)\"", "abilities": abilities, "apps": apps]
        if let commands { overrides["commands"] = commands }
        let folder = scriptTempPlugin(["manifest.json": scriptManifestText(overrides), "profile.json": "{}", "main.js": commandStub + script])
        cleanup.append(folder)
        let plugin = ProfileStore.load(folder: folder)
        expect(plugin.error, nil, "the test plugin loads")
        return plugin
    }
    func store() -> ScriptTrustStore { ScriptTrustStore(file: temp().appendingPathComponent("plugin-trust.json"), inMemoryKey: sealKey) }
    func ready(_ entry: ScriptPlugins.Entry?) -> Bool { if case .ready? = entry?.host?.state { return true } else { return false } }

    /// A running ScriptPlugins over a Mac, one approved plugin, and its entry once the host has started.
    func start(_ mac: Mac, script: String, approved: Bool = true, developerMode: Bool = false, id: String = "script-test", abilities: String = "[\"read\", \"say\"]") -> (ScriptPlugins, ScriptPlugins.Entry, ScriptTrustStore, LoadedPlugin)? {
        let plugin = makePlugin(id: id, script: script, abilities: abilities)
        let trust = store()
        if developerMode { try? trust.setDeveloperMode(true) }
        if approved { try? trust.approve(plugin, origin: developerMode ? .draft : .file) }
        mac.plugins = [plugin]
        let plugins = ScriptPlugins(trust: trust, environment: mac.environment())
        guard let entry = plugins.entries[id] else { check(false, "the plugin has an entry"); return nil }
        return (plugins, entry, trust, plugin)
    }
    /// An event through the plugin; what the rest of the chain would do is `during`, run while `next` is called.
    @discardableResult func fire(_ plugins: ScriptPlugins, _ kind: EventKind, _ element: AXUIElement, character: Character? = nil, during: () -> Void = {}) -> Int {
        var called = 0
        plugins.handleEvent(Event(kind, ObjectFactory.make(element), character: character), next: { called += 1; during() })
        return called
    }
    /// The first event starts the host; wait until the script has loaded.
    func startHost(_ plugins: ScriptPlugins, _ entry: ScriptPlugins.Entry) -> Bool {
        fire(plugins, .gainFocus, el(button))
        return waitFor { ready(entry) }
    }
    func said(_ capture: inout [String], _ body: () -> Void) {
        var out: [String] = []
        let before = Speech.sink
        Speech.sink = { out.append($0) }
        body()
        Speech.sink = before
        capture = out
    }

    guard fm.isExecutableFile(atPath: hostPath) else {
        test("script plugins: the host program is built beside the test runner") { check(false, "no \(hostPath): build --product turnover-plugin-host into the same folder") }
        return
    }
    AXReplay.load(miniScreen())
    ElementMatcher.searchRoots = { pid in pid >= AXReplay.floor ? [AXReplay.root].compactMap { $0 } : nil }
    defer { ElementMatcher.searchRoots = nil; AXReplay.unload(); (cleanup + macStorages).forEach { try? fm.removeItem(at: $0) } }

    // MARK: The switch

    test("script plugins: the switch is off unless set, and never on when plugins are off") {
        let domain = UserDefaults.argumentDomain
        let saved = UserDefaults.standard.volatileDomain(forName: domain)
        defer { UserDefaults.standard.setVolatileDomain(saved, forName: domain) }
        @MainActor func with(_ values: [String: Any]) -> Bool {
            UserDefaults.standard.setVolatileDomain(values, forName: domain)
            return Edition.includesPluginScripts
        }
        expect(with([:]), false, "off by default")
        expect(with(["pluginScripts": true]), true, "on when set")
        expect(with(["pluginScripts": false]), false, "off when set off")
        expect(with(["pluginScripts": true, "plugins": false]), false, "never on with plugins off")
    }

    test("script plugins: with the switch off nothing is registered and a focus says what it always said") {
        expect(Edition.includesPluginScripts, false, "off in the tests")
        check(!GlobalPluginHandler.shared.plugins.contains { $0 is ScriptPlugins }, "no ScriptPlugins registered")
        check(ScriptPlugins.current == nil, "none running")
        check(ScriptPlugins.commands(for: "com.example.app").isEmpty, "no script commands in the plugin layer")
        expect(ScriptFocusWords.current == nil, true, "no words held")
        let object = ObjectFactory.make(el(button))
        var always: [String] = [], now: [String] = []
        Speech.testResetFocusTiming()
        said(&always) { Speech.speakObject(object, reason: .focus) }   // what a focus always said
        settle(0.55)   // the same words within half a second are not said twice
        said(&now) { object.reportFocus() }
        check(!always.isEmpty, "something is said for a button")
        expect(now, always, "reportFocus says the same")
    }

    test("script plugins: the reload hook is chained, not taken") {
        let saved = ProfileStore.shared.onReload
        defer { ProfileStore.shared.onReload = saved }
        var calls: [String] = []
        ProfileStore.shared.onReload = { calls.append("profiles") }
        ScriptPlugins.chainReload(onto: ProfileStore.shared) { calls.append("scripts") }
        ProfileStore.shared.onReload?()
        expect(calls, ["profiles", "scripts"], "ProfilesPlugin's hook first, then ours")
    }

    // MARK: Items

    test("script plugins: an item is a copy with the role in a match's words, and a password's value is empty") {
        let broker = AXScriptBroker(pluginID: "script-test", apps: ["com.example.app"], environment: Mac().environment(), questionOpen: { false })
        for id in [button, nameField, passwordField, totalText] {
            guard case .object(let item)? = broker.item(for: el(id)) else { check(false, "an item for node \(id)"); continue }
            let ax = item["axRole"]?.stringValue ?? "", role = item["role"]?.stringValue ?? ""
            var match = ElementMatch(); match.role = role
            check(ElementMatcher.matches(el(id), match), "\(role) is the way a match writes \(ax)")
            check(item["handle"]?.stringValue != nil, "it has a handle")
        }
        let save = broker.item(for: el(button)), name = broker.item(for: el(nameField)), password = broker.item(for: el(passwordField))
        expect(save?["role"]?.stringValue, "button", "a button's role")
        expect(save?["name"]?.stringValue, "Save", "its name")
        expect(save?["window"]?.stringValue, "Main", "its window's title")
        expect(name?["value"]?.stringValue, "Ann", "a field's value")
        expect(name?["secure"]?.boolValue, false, "not secure")
        expect(password?["secure"]?.boolValue, true, "a password field is secure")
        expect(password?["value"]?.stringValue, "", "and its value is empty")
        let wire = String(decoding: (try? JSONSerialization.data(withJSONObject: password!.json)) ?? Data(), as: UTF8.self)
        check(!wire.contains("hunter2"), "the password is nowhere in what a script is given")
    }

    test("script plugins: the handle table holds 512, drops the oldest, and keeps one handle for one element") {
        expect(ScriptHandleTable.capacity, 512, "the plan's number")
        let table = ScriptHandleTable(capacity: 3)
        let a = table.handle(for: el(button)), b = table.handle(for: el(nameField)), c = table.handle(for: el(passwordField))
        expect(table.handle(for: el(button)), a, "the same element, the same handle")
        expect(table.count, 3, "three held")
        let d = table.handle(for: el(totalText))
        expect(table.count, 3, "still three")
        expect(table.element(for: b) == nil, true, "the oldest was dropped (the button was made newest again)")
        expect(table.element(for: a) != nil && table.element(for: c) != nil && table.element(for: d) != nil, true, "the others are kept")
        let big = ScriptHandleTable()
        for i in 0..<600 { _ = big.handle(for: AXReplay.element(i)) }
        expect(big.count, 512, "never more than 512")
    }

    // MARK: Whose it is

    test("script plugins: a request about an item in another app, or about a handle never given, is refused") {
        let mac = Mac()
        let broker = AXScriptBroker(pluginID: "script-test", apps: ["com.example.app"], environment: mac.environment(), questionOpen: { false })
        guard let handle = broker.item(for: el(button))?["handle"]?.stringValue else { return check(false, "an item") }
        expect((try? broker.perform(.itemRefresh, .object(["handle": .string(handle)]))) != nil, true, "its own item is answered")
        do { _ = try broker.perform(.itemRefresh, .object(["handle": .string("h999")])); check(false, "a handle never given") }
        catch let error as ScriptBrokerError { check(error == .gone(error.message), "a handle the plugin was not given is gone: \(error)") } catch { check(false, "\(error)") }
        // The same handle, but the item now belongs to another app: refused at that moment, not at the time it was given.
        mac.bundles = { _ in "com.other.app" }
        for operation in [ScriptOperation.itemRefresh, .itemParent, .itemChildren, .itemPress, .itemFocus, .itemRead] {
            do { _ = try broker.perform(operation, .object(["handle": .string(handle)])); check(false, "\(operation) in another app") }
            catch let error as ScriptBrokerError { check(error == .refused(error.message), "\(operation) is refused: \(error)") } catch { check(false, "\(error)") }
        }
        check(broker.item(for: el(button)) == nil, "no item is made for an element in another app")
        expect(mac.scriptSaid, [], "nothing was said")
        expect(AXReplay.actions.count, 0, "nothing was pressed")
    }

    test("script plugins: the apps no script may reach are refused whatever the manifest says, in any case") {
        for bundle in ["com.apple.SecurityAgent", "com.apple.securityagent", "COM.APPLE.LOGINWINDOW", "com.turnover.reader", "com.TurnOver.reader.developer", "com.turnover"] {
            check(AXScriptBroker.isForbiddenApp(bundle), "\(bundle) is forbidden")
            let mac = Mac()
            mac.bundles = { _ in bundle }
            let broker = AXScriptBroker(pluginID: "script-test", apps: [bundle], environment: mac.environment(), questionOpen: { false })
            check(!broker.owns(AXReplay.floor + 1), "\(bundle) is not the plugin's even when its manifest lists it")
            check(broker.item(for: el(button)) == nil, "no item from \(bundle)")
        }
        check(!AXScriptBroker.isForbiddenApp("com.example.app"), "an ordinary app is not")
        check(!AXScriptBroker.isForbiddenApp("com.turnoverish.app"), "nor one that only starts with the same letters")
    }

    test("script plugins: press, focus and edit work only while the plugin's app is in front") {
        let mac = Mac()
        mac.focus = el(nameField)   // an edit needs the focused item to be found (15 Nov 2026)
        let broker = AXScriptBroker(pluginID: "script-test", apps: ["com.example.app"], environment: mac.environment(), questionOpen: { false })
        let b = broker.item(for: el(button))?["handle"]?.stringValue ?? "", n = broker.item(for: el(nameField))?["handle"]?.stringValue ?? ""
        mac.front = AXReplay.floor + 1
        _ = try? broker.perform(.itemPress, .object(["handle": .string(b)]))
        expect(AXReplay.actions.map { $0.action }, ["AXPress"], "pressed in front")
        _ = try? broker.perform(.itemSetValue, .object(["handle": .string(n), "value": .string("Bea")]))
        expect(AXReplay.sets.last?.attribute, kAXValueAttribute, "edited in front")
        mac.front = nil
        for (operation, args) in [(ScriptOperation.itemPress, ["handle": ScriptValue.string(b)]), (.itemFocus, ["handle": .string(b)]), (.itemSetValue, ["handle": .string(n), "value": .string("x")]),
                                  (.menu, ["path": .array([.string("Edit"), .string("Copy")])]), (.keys, ["keys": .string("command+k")])] {
            do { _ = try broker.perform(operation, .object(args)); check(false, "\(operation) with the app not in front") }
            catch let error as ScriptBrokerError { check(error == .refused(error.message), "\(operation) is refused when not in front: \(error)") } catch { check(false, "\(error)") }
        }
        mac.front = AXReplay.floor + 1
        mac.bundles = { $0 == AXReplay.floor + 1 ? "com.other.app" : "com.example.app" }
        do { _ = try broker.perform(.keys, .object(["keys": .string("command+k")])); check(false, "another app in front") } catch { }
        expect(mac.keys, [], "no key was sent")
    }

    // MARK: Policy

    test("script plugins: a refused menu path and a refused key are refused when asked, with the reason") {
        let mac = Mac()
        mac.focus = el(nameField)   // an allowed key needs the focused item to be found (15 Nov 2026)
        let broker = AXScriptBroker(pluginID: "script-test", apps: ["com.example.app"], environment: mac.environment(), questionOpen: { false })
        @MainActor func menu(_ path: [String]) throws -> ScriptValue { try broker.perform(.menu, .object(["path": .array(path.map { .string($0) })])) }
        for (path, reason) in [(["Apple", "About This Mac"], "the Apple menu"), (["*", "Anything"], "not a pattern"), (["Edit", "Paste"], "Paste"), (["File", "Log Out Ann…"], "Log Out")]  {
            do { _ = try menu(path); check(false, "\(path) should be refused") }
            catch let error as ScriptBrokerError { check(error == .refused(error.message) && error.message.contains(reason), "\(path): \(error)") } catch { check(false, "\(error)") }
        }
        expect(mac.menus, [], "nothing was chosen")
        _ = try? menu(["Edit", "Copy"])
        expect(mac.menus, [["Edit", "Copy"]], "a plain menu path is chosen")
        for key in ["command+tab", "command+v", "command+shift+3", "turnover+h", "command+control+q", "command+f5"] {
            do { _ = try broker.perform(.keys, .object(["keys": .string(key)])); check(false, "\(key) should be refused") }
            catch let error as ScriptBrokerError { check(error == .refused(error.message) && error.message.contains(key), "\(key): \(error)") } catch { check(false, "\(error)") }
        }
        expect(mac.keys, [], "no refused key was sent")
        _ = try? broker.perform(.keys, .object(["keys": .string("command+k")]))
        expect(mac.keys, ["command+k"], "an allowed key is sent")
    }

    test("script plugins: the profile's menu refusals read as they did, from the shared check") {
        func refusals(_ menu: [String]) throws -> [String] {
            let list = menu.map { "\"\($0)\"" }.joined(separator: ",")
            let json = #"{"keys":[{"key":"turnover+control+shift+m","description":"x","action":"menu","menu":[\#(list)]}]}"#
            return PluginPolicy.refusals(try JSONDecoder().decode(Profile.self, from: Data(json.utf8)))
        }
        let both = try refusals(["Apple", "Restart…"])
        expect(both.filter { $0.contains("the Apple menu belongs to the Mac, not the app") }.count, 1, "the Apple menu line")
        expect(both.filter { $0.contains("the menu item Restart is never a plugin's to choose") }.count, 1, "the Mac's own item")
        check(both.allSatisfy { $0.hasPrefix("turnover+control+shift+m: ") }, "each line starts with the key, as before")
        let pattern = try refusals(["*", "Open"]), plain = try refusals(["File", "Open"])
        check(pattern.contains { $0.hasSuffix("the first menu must be named, not a pattern (it could reach the Apple menu)") }, "the pattern line")
        check(plain.allSatisfy { !$0.contains("menu") }, "an ordinary path passes")
    }

    // MARK: Secure fields

    test("script plugins: keys and edit are refused while a secure field has the focus, and edit is never done to one") {
        let mac = Mac()
        let broker = AXScriptBroker(pluginID: "script-test", apps: ["com.example.app"], environment: mac.environment(), questionOpen: { false })
        let n = broker.item(for: el(nameField))?["handle"]?.stringValue ?? "", p = broker.item(for: el(passwordField))?["handle"]?.stringValue ?? ""
        let setsBefore = AXReplay.sets.count
        mac.focus = el(nameField)
        do { _ = try broker.perform(.itemSetValue, .object(["handle": .string(p), "value": .string("x")])); check(false, "edit on a password field") }
        catch let error as ScriptBrokerError { check(error == .refused(error.message), "edit on a password field: \(error)") } catch { check(false, "\(error)") }
        do { _ = try broker.perform(.itemRead, .object(["handle": .string(p)])); check(false, "reading a password field") }
        catch let error as ScriptBrokerError { check(error == .refused(error.message), "reading a password field: \(error)") } catch { check(false, "\(error)") }
        _ = try? broker.perform(.keys, .object(["keys": .string("command+k")]))
        expect(mac.keys, ["command+k"], "keys work while the focus is in an ordinary field")
        mac.focus = el(passwordField)
        for (operation, args) in [(ScriptOperation.keys, ["keys": ScriptValue.string("command+k")]), (.itemSetValue, ["handle": .string(n), "value": .string("x")])] {
            do { _ = try broker.perform(operation, .object(args)); check(false, "\(operation) with a password field focused") }
            catch let error as ScriptBrokerError { check(error == .refused(error.message), "\(operation) is refused while a password field has the focus: \(error)") } catch { check(false, "\(error)") }
        }
        expect(mac.keys, ["command+k"], "no more keys were sent")
        expect(AXReplay.sets.count, setsBefore, "nothing was written to any field")
    }

    // MARK: Stage 3's review (15 Nov 2026)

    test("script plugins: a plugin without read is sent no focus or value event, and a password field's value change goes to no script") {
        let script = "turnover.on('focus', function (e) { e.say('focus ' + e.item.name); }); turnover.on('valueChange', function (e) { e.say('value ' + e.item.name); });"
        // Without read: the script runs, but is never asked.
        let blind = Mac()
        blind.limits.eventDeadline = 0.5
        guard let (blindPlugins, blindEntry, _, blindPlugin) = start(blind, script: script, abilities: "[\"say\"]") else { return }
        defer { blindPlugins.terminate() }
        check(!ScriptAbilities.effective(for: blindPlugin).contains(.read), "this plugin has no read")
        expect(startHost(blindPlugins, blindEntry), true, "the script loads and runs")
        var heldDuring = true
        expect(fire(blindPlugins, .gainFocus, el(nameField), during: { heldDuring = ScriptFocusWords.current != nil }), 1, "a focus goes straight on")
        expect(heldDuring, false, "and no words were held for it")
        expect(fire(blindPlugins, .valueChange, el(nameField)), 1, "a value change goes on too")
        expect(blind.spoken.filter { $0.hasPrefix("value") || $0.hasPrefix("focus") }, [], "the script was asked nothing")
        // With read: the same script is asked.
        let seeing = Mac()
        seeing.limits.eventDeadline = 0.5
        guard let (plugins, entry, _, _) = start(seeing, script: script) else { return }
        defer { plugins.terminate() }
        expect(startHost(plugins, entry), true, "the script loads")
        expect(fire(plugins, .valueChange, el(nameField)), 0, "with read, a value change is handled and stops the chain")
        expect(seeing.spoken.contains("value Name"), true, "and the script's words were said")
        // A password field's value change is sent to nobody.
        let before = seeing.spoken.count
        expect(fire(plugins, .valueChange, el(passwordField)), 1, "a value change in a password field passes straight on")
        expect(seeing.spoken.count, before, "and the script said nothing")
    }

    test("script plugins: the approval sentences say exactly what is agreed to") {
        let plugin = makePlugin(script: "", abilities: "[\"read\", \"say\"]")
        let lines = ScriptAbilities.approvalLines(for: plugin, appName: { _ in nil }).map(\.text)
        check(lines.contains("It can speak, change or silence what TurnOver says in those apps, play TurnOver's own sounds and tones, and ask you to choose from a list or type a line."), "say: \(lines)")
        check(lines.contains("It can read what is on the screen in those apps, including text you have typed there, the selected text and whole lines, but never a password."), "read: \(lines)")
        check(lines.contains("It can never use the internet, read or change your files, see the keys you press, see a password, or reach any other app."), "the fixed sentence: \(lines)")
    }

    /// The five acting requests, by name, against a broker; the handles are for the button and the name field.
    func act(_ name: String, _ broker: AXScriptBroker, button b: String, field n: String) throws -> ScriptValue {
        switch name {
        case "press": return try broker.perform(.itemPress, .object(["handle": .string(b)]))
        case "focus": return try broker.perform(.itemFocus, .object(["handle": .string(b)]))
        case "edit": return try broker.perform(.itemSetValue, .object(["handle": .string(n), "value": .string("x")]))
        case "menu": return try broker.perform(.menu, .object(["path": .array([.string("Edit"), .string("Copy")])]))
        default: return try broker.perform(.keys, .object(["keys": .string("command+k")]))
        }
    }
    /// Every request in `names` must be refused (not failed, not invalid), and change nothing.
    func allRefused(_ names: [String], _ why: String, _ broker: AXScriptBroker, _ mac: Mac, button b: String, field n: String) {
        let actions = AXReplay.actions.count, sets = AXReplay.sets.count
        for name in names {
            do { _ = try act(name, broker, button: b, field: n); check(false, "\(name) went through \(why)") }
            catch let error as ScriptBrokerError { check(error == .refused(error.message), "\(name) is refused \(why): \(error)") } catch { check(false, "\(error)") }
        }
        expect(AXReplay.actions.count, actions, "nothing was pressed \(why)"); expect(AXReplay.sets.count, sets, "nothing was set \(why)")
        expect(mac.keys, [], "no key was sent \(why)"); expect(mac.menus, [], "no menu was chosen \(why)")
    }

    test("script plugins: acting needs TurnOver's focus and the Mac's frontmost app both to be the plugin's") {
        let mac = Mac()
        mac.focus = el(nameField)
        let broker = AXScriptBroker(pluginID: "script-test", apps: ["com.example.app"], environment: mac.environment(), questionOpen: { false })
        let b = broker.item(for: el(button))?["handle"]?.stringValue ?? "", n = broker.item(for: el(nameField))?["handle"]?.stringValue ?? ""
        let all = ["press", "focus", "edit", "menu", "keys"]
        mac.front = AXReplay.floor + 1; mac.macFront = AXReplay.floor - 1   // TurnOver thinks the plugin's app, the Mac says another
        allRefused(all, "when the Mac's frontmost app is another", broker, mac, button: b, field: n)
        mac.front = AXReplay.floor - 1; mac.macFront = AXReplay.floor + 1   // the other way round
        allRefused(all, "when TurnOver's focus is in another app", broker, mac, button: b, field: n)
        mac.macFront = nil; mac.front = AXReplay.floor + 1
        allRefused(all, "when the Mac names no frontmost app", broker, mac, button: b, field: n)
        mac.macFront = AXReplay.floor + 1
        for name in all { do { _ = try act(name, broker, button: b, field: n) } catch { check(false, "\(name) with both agreeing: \(error)") } }
        expect(mac.keys, ["command+k"], "with both agreeing a key goes")
    }

    test("script plugins: keys and edit are refused while the Mac reports secure keyboard entry, and when the focused item cannot be found") {
        let mac = Mac()
        let broker = AXScriptBroker(pluginID: "script-test", apps: ["com.example.app"], environment: mac.environment(), questionOpen: { false })
        let b = broker.item(for: el(button))?["handle"]?.stringValue ?? "", n = broker.item(for: el(nameField))?["handle"]?.stringValue ?? ""
        mac.focus = el(nameField); mac.secureInput = true
        allRefused(["keys", "edit"], "while secure keyboard entry is on", broker, mac, button: b, field: n)
        mac.secureInput = false; mac.focus = nil
        allRefused(["keys", "edit"], "when the focus cannot be found", broker, mac, button: b, field: n)
        mac.focus = el(nameField)
        for name in ["keys", "edit"] { do { _ = try act(name, broker, button: b, field: n) } catch { check(false, "\(name) in an ordinary field: \(error)") } }
        expect(mac.keys, ["command+k"], "both go when the focus is an ordinary field and nothing is hidden")
        expect(AXReplay.sets.last?.attribute, kAXValueAttribute, "the edit was made")
    }

    test("script plugins: words a script gave for a focus, said twice within half a second, are said once; silence says nothing and schedules no hint") {
        let object = ObjectFactory.make(el(button))
        let delay = Hints.delay
        Hints.delay = 0.05
        defer { Hints.delay = delay }
        Speech.testResetFocusTiming()
        settle(0.55)   // after any earlier words of the same kind
        var heard: [String] = []
        said(&heard) {
            Speech.speakFocusWords("Save it twice", for: object)
            Speech.speakFocusWords("Save it twice", for: object)
            settle(0.4)
        }
        expect(heard.filter { $0 == "Save it twice" }.count, 1, "the repeat is said once: \(heard)")
        check(heard.contains(Hints.forObject(object)) && !Hints.forObject(object).isEmpty, "and the hint follows the words: \(heard)")
        settle(0.55)
        var silent: [String] = []
        said(&silent) {
            Speech.speakFocusWords("", for: object)
            settle(0.4)
        }
        expect(silent, [], "a silence says nothing and schedules no hint")
    }

    // MARK: Speech

    test("script plugins: what a script says is dropped while its app is not in front, and while an approval question is open") {
        let mac = Mac()
        var question = false
        let broker = AXScriptBroker(pluginID: "script-test", apps: ["com.example.app"], environment: mac.environment(), questionOpen: { question })
        let b = broker.item(for: el(button))?["handle"]?.stringValue ?? ""
        @MainActor func say(_ text: String) { _ = try? broker.perform(.say, .object(["text": .string(text), "interrupt": .bool(false)])) }
        say("in front")
        _ = try? broker.perform(.sound, .object(["name": .string("link")]))
        _ = try? broker.perform(.itemRead, .object(["handle": .string(b)]))
        expect(mac.scriptSaid.count, 2, "said, and read the button, while in front")
        expect(mac.sounds, ["link"], "and the sound played")
        question = true
        say("question open")
        _ = try? broker.perform(.sound, .object(["name": .string("link")]))
        _ = try? broker.perform(.itemRead, .object(["handle": .string(b)]))
        question = false
        mac.front = AXReplay.floor + 1
        mac.bundles = { _ in "com.other.app" }
        say("not in front")
        _ = try? broker.perform(.sound, .object(["name": .string("link")]))
        expect(mac.scriptSaid.count, 2, "nothing more was said")
        expect(mac.sounds, ["link"], "nothing more was played")
        mac.bundles = { _ in "com.example.app" }
        say("in front again")
        expect(mac.scriptSaid.last, "in front again", "heard again when it is back")
        _ = try? broker.perform(.copy, .object(["text": .string("copied")]))
        expect(mac.copied, ["copied"], "copy puts text on the clipboard")
    }

    // MARK: Search and storage

    test("script plugins: find uses a profile's match, and a recorded window's buttons come back as items") {
        let mac = Mac()
        let broker = AXScriptBroker(pluginID: "script-test", apps: ["com.example.app"], environment: mac.environment(), questionOpen: { false })
        @MainActor func find(_ match: ScriptValue, limit: Double? = nil) -> [ScriptValue] {
            var args: [String: ScriptValue] = ["match": match]
            if let limit { args["limit"] = .number(limit) }
            if case .array(let list)? = try? broker.perform(.find, .object(args)) { return list }
            return []
        }
        expect(find(.object(["role": .string("button")])).compactMap { $0["name"]?.stringValue }, ["Save"], "by role, in a match's words")
        expect(find(.object(["role": .string("AXTextField")])).count, 2, "by accessibility role")
        expect(find(.object(["title": .string("Na*")])).compactMap { $0["name"]?.stringValue }, ["Name"], "by title with a wildcard")
        expect(find(.object(["role": .string("textField")]), limit: 1).count, 1, "the script's limit")
        expect(find(.object(["role": .string("textField"), "nth": .number(-1)])).compactMap { $0["name"]?.stringValue }, ["Password"], "nth, as a profile's match has it")
        expect(find(.object(["title": .string("Nothing like this")])).count, 0, "nothing matched is an empty list")
        do { _ = try broker.perform(.find, .object(["match": .object(["role": .number(3)])])); check(false, "a match with the wrong types") }
        catch let error as ScriptBrokerError { check(error == .invalid(error.message), "an unreadable match is invalid: \(error)") } catch { check(false, "\(error)") }
        var limits = ScriptLimits(); limits.findLimit = 2
        mac.limits = limits
        let small = AXScriptBroker(pluginID: "script-test", apps: ["com.example.app"], environment: mac.environment(), questionOpen: { false })
        if case .array(let list)? = try? small.perform(.find, .object(["match": .object([:]), "limit": .number(50)])) { expect(list.count, 2, "no search returns more than the limit") }
    }

    test("script plugins: find on a recorded settings window gives buttons with names") {
        guard let fixture = try? AXFixture.load(fixtureURL("settings-general")) else { return check(false, "the recorded window loads") }
        AXReplay.load(fixture)
        defer { AXReplay.load(miniScreen()) }
        let mac = Mac()
        let broker = AXScriptBroker(pluginID: "script-test", apps: ["com.example.app"], environment: mac.environment(), questionOpen: { false })
        guard case .array(let list)? = try? broker.perform(.find, .object(["match": .object(["role": .string("button")]), "limit": .number(20)])) else { return check(false, "find answers") }
        check(!list.isEmpty, "the recorded window has buttons")
        check(list.allSatisfy { $0["role"]?.stringValue == "button" && $0["handle"]?.stringValue != nil }, "each is a button item with a handle")
    }

    test("script plugins: storage is one file named by the plugin's id, kept, limited, and never built from a bad id") {
        let mac = Mac()
        @MainActor func broker(_ id: String) -> AXScriptBroker { AXScriptBroker(pluginID: id, apps: ["com.example.app"], environment: mac.environment(), questionOpen: { false }) }
        let one = broker("script-test")
        @MainActor func op(_ b: AXScriptBroker, _ o: ScriptOperation, _ key: String, _ value: ScriptValue? = nil) throws -> ScriptValue {
            var args: [String: ScriptValue] = ["key": .string(key)]
            if let value { args["value"] = value }
            return try b.perform(o, .object(args))
        }
        expect(try? op(one, .storageGet, "count"), .some(.null), "nothing yet")
        _ = try? op(one, .storageSet, "count", .number(3))
        _ = try? op(one, .storageSet, "list", .array([.string("a"), .object(["b": .bool(true)])]))
        expect(try? op(one, .storageGet, "count"), .some(.number(3)), "a number comes back")
        expect(try? op(broker("script-test"), .storageGet, "list"), .some(.array([.string("a"), .object(["b": .bool(true)])])), "a new run reads the file")
        check(fm.fileExists(atPath: mac.storage.appendingPathComponent("script-test.json").path), "the file is named by the id")
        expect((try? fm.contentsOfDirectory(atPath: mac.storage.path))?.count, 1, "one file for the plugin")
        _ = try? op(one, .storageRemove, "count")
        expect(try? op(broker("script-test"), .storageGet, "count"), .some(.null), "removed")
        expect(try? op(broker("other-plugin"), .storageGet, "list"), .some(.null), "another plugin has its own")
        do { _ = try op(one, .storageSet, "big", .string(String(repeating: "x", count: 300 * 1024))); check(false, "over 256 KB") }
        catch let error as ScriptBrokerError { check(error == .refused(error.message), "256 KB in all: \(error)") } catch { check(false, "\(error)") }
        expect(try? op(broker("script-test"), .storageGet, "big"), .some(.null), "the refused value was not kept")
        for bad in ["../escape", "a/b", "a b", "", "x.json/../y"] {
            do { _ = try op(broker(bad), .storageSet, "k", .number(1)); check(false, "\(bad) must not name a file") }
            catch let error as ScriptBrokerError { check(error == .refused(error.message), "\(bad) is refused: \(error)") } catch { check(false, "\(error)") }
        }
        expect((try? fm.contentsOfDirectory(atPath: mac.storage.path))?.count, 1, "no other file was made")
    }

    // MARK: Events through ScriptPlugins and the real host

    test("script plugins: words a script gives for a focus are said once, in place of the usual, for that element only") {
        let mac = Mac()
        mac.limits.eventDeadline = 0.5
        guard let (plugins, entry, _, _) = start(mac, script: """
            turnover.on('focus', function (e) {
              if (e.item.name === 'Save') e.say('Save it now');
              else if (e.item.name === 'Name') e.silence();
            });
            """) else { return }
        defer { plugins.terminate() }
        expect(startHost(plugins, entry), true, "the script loads")
        var heard: [String] = []
        var heldForButton: String?, heldForName: String?
        Speech.testResetFocusTiming()
        said(&heard) {
            fire(plugins, .gainFocus, el(button), during: {
                heldForButton = ScriptFocusWords.held(for: el(button)); heldForName = ScriptFocusWords.held(for: el(nameField))
                ObjectFactory.make(el(button)).reportFocus()
            })
        }
        expect(heard, ["Save it now"], "the script's words, once, and not the usual announcement")
        expect(heldForButton, "Save it now", "held for the element they were given for")
        expect(heldForName, nil, "not for another element")
        expect(ScriptFocusWords.current == nil, true, "gone afterwards")
        var after: [String] = []
        settle(0.55)   // (the same words within half a second are not said twice)
        Speech.testResetFocusTiming()
        said(&after) { ObjectFactory.make(el(button)).reportFocus() }
        expect(after.first == "Save it now", false, "afterwards the usual words again")
        expect(after.isEmpty, false, "and something is said")

        var silent: [String] = []
        Speech.testResetFocusTiming()
        said(&silent) { fire(plugins, .gainFocus, el(nameField), during: { ObjectFactory.make(el(nameField)).reportFocus() }) }
        expect(silent, [], "empty words say nothing")
        expect(ScriptFocusWords.current == nil, true, "and are let go")

        var always: [String] = [], usual: [String] = []
        let object = ObjectFactory.make(el(totalText))
        Speech.testResetFocusTiming()
        said(&always) { Speech.speakObject(object, reason: .focus) }
        settle(0.55)
        said(&usual) { fire(plugins, .gainFocus, el(totalText), during: { object.reportFocus() }) }
        expect(usual, always, "no words from the script: the usual announcement")
    }

    test("script plugins: a handled value change stops the chain and an unhandled one passes on") {
        let mac = Mac()
        mac.limits.eventDeadline = 0.5
        guard let (plugins, entry, _, _) = start(mac, script: "turnover.on('valueChange', function (e) { if (e.item.value === 'Ann') e.say('Name is Ann'); });") else { return }
        defer { plugins.terminate() }
        expect(startHost(plugins, entry), true, "the script loads")
        expect(fire(plugins, .valueChange, el(nameField)), 0, "handled: the chain stops")
        expect(mac.spoken.filter { $0 == "Name is Ann" }.count, 1, "and the words were said")
        expect(fire(plugins, .valueChange, el(totalText)), 1, "not handled: the chain goes on")
        expect(mac.spoken.filter { $0 == "Name is Ann" }.count, 1, "nothing more was said")
    }

    test("script plugins: a typed character, a caret move and every other kind of event are never sent to a host") {
        let mac = Mac()
        mac.limits.eventDeadline = 0.5
        guard let (plugins, entry, _, _) = start(mac, script: "turnover.on('focus', function (e) { e.say('focus'); }); turnover.on('valueChange', function (e) { e.say('value'); });") else { return }
        defer { plugins.terminate() }
        expect(startHost(plugins, entry), true, "the script loads")
        for kind in [EventKind.loseFocus, .focusEntered, .focusExited, .nameChange, .stateChange, .descriptionChange, .caret, .selection, .textChange, .alert, .menuStart, .menuEnd,
                     .typedCharacter, .appModuleGainFocus, .appModuleLoseFocus, .liveRegionChange] {
            var heldDuring = true
            let calls = fire(plugins, kind, el(nameField), character: kind == .typedCharacter ? "a" : nil, during: { heldDuring = ScriptFocusWords.current != nil })
            expect(calls, 1, "\(kind) goes straight on")
            expect(heldDuring, false, "\(kind) holds no words for the focus")
        }
        check(!mac.spoken.contains("focus") && !mac.spoken.contains("value"), "no event was answered by the script")
    }

    test("script plugins: a script with no receipt does not start, and the waiting notice is given once") {
        let mac = Mac()
        guard let (plugins, entry, trust, _) = start(mac, script: "turnover.on('focus', function (e) {});", approved: false) else { return }
        defer { plugins.terminate() }
        expect(trust.receipts.count, 0, "no receipt")
        fire(plugins, .gainFocus, el(button))
        expect(entry.host == nil, true, "no host was started")
        var notices = mac.spoken.filter { $0.contains("waiting for approval") }
        expect(notices.count, 1, "the notice was given when its app came to the front")
        check(notices.first?.contains("Script test") == true && notices.first?.contains("Plugins menu") == true, "with the plugin's name, and where to approve: \(notices)")
        check(notices.first?.contains("The author") != true, "and not the plugin's own description")
        fire(plugins, .gainFocus, el(nameField)); fire(plugins, .foreground, el(0))
        mac.front = AXReplay.floor + 1
        notices = mac.spoken.filter { $0.contains("waiting for approval") }
        expect(notices.count, 1, "not given again")
        // It leaves and comes back: still once for the plugin in this run.
        mac.bundles = { _ in "com.other.app" }
        fire(plugins, .gainFocus, el(button))
        mac.bundles = { _ in "com.example.app" }
        fire(plugins, .gainFocus, el(button))
        expect(mac.spoken.filter { $0.contains("waiting for approval") }.count, 1, "not again after leaving and coming back")
    }

    test("script plugins: no more than three waiting notices in a run") {
        let mac = Mac()
        mac.plugins = (1...5).map { makePlugin(id: "waiting-\($0)", script: "turnover.on('focus', function (e) {});") }
        let plugins = ScriptPlugins(trust: store(), environment: mac.environment())
        defer { plugins.terminate() }
        fire(plugins, .gainFocus, el(button))
        expect(mac.spoken.filter { $0.contains("waiting for approval") }.count, 3, "three at most")
        expect(plugins.waitingNotices, 3, "counted")
        check(plugins.entries.values.allSatisfy { $0.host == nil }, "none of them started")
    }

    test("script plugins: two strikes leave a script running and the third turns it off, said once") {
        let mac = Mac()   // the real 25 ms deadline: a handler that takes 1.5 s is late each time, even when a slow machine wakes the waiting thread long after 25 ms (the answer must not already be in by then)
        guard let (plugins, entry, _, _) = start(mac, script: "turnover.on('focus', function (e) { var t = Date.now(); while (Date.now() - t < 1500) {} });") else { return }
        defer { plugins.terminate() }
        expect(startHost(plugins, entry), true, "the script loads")
        for strike in 1...2 {
            fire(plugins, .gainFocus, el(nameField))
            check(waitFor { entry.strikes.count == strike }, "strike \(strike) was counted")
            settle(0.4)   // the host answers late, and is asked again only then
            check(waitFor(15) { !(entry.host?.isAwaitingLateAnswer ?? false) }, "the host has finished its late answer")
        }
        check(entry.host != nil && !entry.turnedOff, "two strikes leave it running")
        expect(mac.spoken.filter { $0.contains("kept going wrong") }.count, 0, "and nothing is said yet")
        fire(plugins, .gainFocus, el(nameField))
        check(waitFor { entry.turnedOff }, "the third strike turns it off")
        expect(entry.host == nil, true, "its host is gone")
        let notice = mac.spoken.filter { $0.contains("kept going wrong") }
        expect(notice.count, 1, "said once")
        check(notice.first?.contains("Script test") == true, "by the plugin's name: \(notice)")
        for _ in 1...3 { fire(plugins, .gainFocus, el(nameField)) }
        settle(0.2)
        expect(mac.spoken.filter { $0.contains("kept going wrong") }.count, 1, "not said again")
        expect(entry.host == nil, true, "and it does not start again in this run")
    }

    test("script plugins: strikes older than ten minutes do not count") {
        let mac = Mac()
        mac.limits.strikeWindow = 0.3
        guard let (plugins, entry, _, _) = start(mac, script: "turnover.on('focus', function (e) { var t = Date.now(); while (Date.now() - t < 1500) {} });") else { return }
        defer { plugins.terminate() }
        expect(startHost(plugins, entry), true, "the script loads")
        for strike in 1...3 {
            let last = entry.strikes.last
            fire(plugins, .gainFocus, el(nameField))
            check(waitFor { entry.strikes.last != last }, "strike \(strike) arrived")
            check(waitFor(15) { !(entry.host?.isAwaitingLateAnswer ?? false) }, "the host has finished its late answer")
            settle(0.5)   // each is past the window by the time the next arrives
        }
        check(!entry.turnedOff, "three spread out over more than the window do not turn it off")
    }

    test("script plugins: a script that fails to load says its first error once, with its line") {
        let mac = Mac()
        guard let (plugins, entry, _, _) = start(mac, script: "var x = 1;\nvar y = ;\n") else { return }
        defer { plugins.terminate() }
        fire(plugins, .gainFocus, el(button))
        check(waitFor { mac.spoken.contains { $0.contains("did not load") } }, "the error is said")
        let said = mac.spoken.filter { $0.contains("did not load") }
        check(said.first?.contains("line") == true && said.first?.contains("Script test") == true, "with the plugin's name and the line: \(said)")
        fire(plugins, .gainFocus, el(nameField)); fire(plugins, .gainFocus, el(button))
        settle(0.3)
        expect(mac.spoken.filter { $0.contains("did not load") }.count, 1, "once")
        expect(entry.host == nil, true, "and it is not started again until its files change")
    }

    test("script plugins: the host pauses when its app leaves the front, resumes when it returns, and stops when its apps quit") {
        let mac = Mac()
        mac.limits.eventDeadline = 0.5
        guard let (plugins, entry, _, _) = start(mac, script: "turnover.on('focus', function (e) { e.say('hello'); });") else { return }
        defer { plugins.terminate() }
        expect(startHost(plugins, entry), true, "started when its app first came to the front")
        let host = entry.host
        mac.bundles = { _ in "com.other.app" }
        fire(plugins, .gainFocus, el(button))
        expect(entry.inFront, false, "left")
        check(waitFor { if case .paused? = entry.host?.state { return true } else { return false } }, "paused")
        mac.bundles = { _ in "com.example.app" }
        fire(plugins, .gainFocus, el(button))
        check(waitFor { ready(entry) }, "resumed, the same host")
        check(entry.host === host, "no new host was made")
        mac.running = []
        plugins.checkQuit()
        expect(entry.host == nil, true, "stopped when all its apps quit")
    }

    test("script plugins: several plugins for one app are asked in order of id, and the first to handle wins") {
        let mac = Mac()
        mac.limits.eventDeadline = 0.5
        let trust = store()
        mac.plugins = [("b-second", "second"), ("a-first", "first")].map { id, word in makePlugin(id: id, script: "turnover.on('focus', function (e) { e.say('\(word)'); });") }
        for p in mac.plugins { try? trust.approve(p, origin: .file) }
        let plugins = ScriptPlugins(trust: trust, environment: mac.environment())
        defer { plugins.terminate() }
        fire(plugins, .gainFocus, el(button))
        check(waitFor { plugins.entries.values.allSatisfy { ready($0) } }, "both start")
        var heard: [String] = []
        Speech.testResetFocusTiming()
        said(&heard) { fire(plugins, .gainFocus, el(nameField), during: { ObjectFactory.make(el(nameField)).reportFocus() }) }
        expect(heard, ["first"], "a-first answers before b-second")
    }

    // MARK: Commands, approval, start-up

    test("script plugins: commands are carried as scripts and listed in the plugin layer, and one chosen too early says so") {
        let mac = Mac()
        mac.limits.eventDeadline = 0.5
        let commands = "[{ \"id\": \"readResult\", \"description\": \"Read the result\", \"key\": \"turnover+command+shift+a\", \"letter\": \"o\" }, { \"id\": \"quiet\", \"description\": \"No key\" }]"
        let plugin = makePlugin(script: "turnover.command('readResult', function (c) { turnover.say('The result is 42'); });", commands: commands)
        let trust = store()
        try? trust.approve(plugin, origin: .file)
        mac.plugins = [plugin]
        let plugins = ScriptPlugins(trust: trust, environment: mac.environment())
        defer { plugins.terminate() }
        let script = plugins.script(named: "plugin_script-test_script_readResult")
        expect(script?.description, "Read the result", "the description is the command's")
        expect(script?.category, "Script test", "the plugin's name is the category")
        expect(plugins.script(named: "plugin_script-test_script_quiet") == nil, true, "a command with no key has no script")
        let list = plugins.commandList(for: "com.example.app")
        expect(list.map { $0.title }, ["Read the result", "No key"], "both are in the plugin layer's list")
        expect(list.first?.letter ?? nil, "o", "with its letter, in small")
        expect(plugins.commandList(for: "com.other.app").count, 0, "only for its own app")
        // The layer: the declared letter runs the command, and the list names it (15 Nov 2026: the letters reached nothing).
        expect(PluginCommands.command(letter: "o", in: list)?.title, "Read the result", "the letter finds the command in its app")
        expect(PluginCommands.command(letter: "O", in: list)?.title, "Read the result", "in either case")
        check(PluginCommands.command(letter: "o", in: plugins.commandList(for: "com.other.app")) == nil, "not in another app")
        check(PluginCommands.command(letter: "x", in: list) == nil, "not for a letter no command has")
        expect(PluginCommands.layerCommands(in: list).map { "\($0.letter) \($0.title)" }, ["o Read the result"], "the layer's list has it, the command with no letter left out")
        list.first?.run()
        expect(mac.spoken.filter { $0.contains("not ready") }.count, 1, "chosen before the host is ready, it says so in a few words")
        fire(plugins, .gainFocus, el(button))
        check(waitFor { ready(plugins.entries["script-test"]) }, "the host starts")
        list.first?.run()
        check(waitFor { mac.scriptSaid == ["The result is 42"] }, "chosen when ready, the script runs and says its words")
    }

    test("script plugins: a letter the layer keeps for itself never reaches a plugin, and the first command with a letter keeps it") {
        let mac = Mac()
        let commands = "[{ \"id\": \"a\", \"description\": \"Take R\", \"letter\": \"r\" }, { \"id\": \"b\", \"description\": \"First B\", \"letter\": \"b\" }, { \"id\": \"c\", \"description\": \"Second B\", \"letter\": \"B\" }]"
        let plugin = makePlugin(script: "turnover.command('a', function () {}); turnover.command('b', function () {}); turnover.command('c', function () {});", commands: commands)
        let trust = store()
        try? trust.approve(plugin, origin: .file)
        mac.plugins = [plugin]
        let plugins = ScriptPlugins(trust: trust, environment: mac.environment())
        defer { plugins.terminate() }
        let list = plugins.commandList(for: "com.example.app")
        expect(list.count, 3, "all three are the plugin's")
        check(PluginCommands.command(letter: "r", in: list) == nil, "R is the layer's screen recognition")
        expect(PluginCommands.command(letter: "b", in: list)?.title, "First B", "the first command with a letter has it")
        expect(PluginCommands.layerCommands(in: list).map(\.letter), ["b"], "the list has B once and no R")
    }

    test("script plugins: the approval question carries the approval lines, answers Not now and Approve, and a script is heard by no one while it is open") {
        let mac = Mac()
        guard let (plugins, entry, trust, plugin) = start(mac, script: "turnover.on('focus', function (e) {});", approved: false) else { return }
        defer { plugins.terminate() }
        plugins.askApproval("script-test")
        guard let question = mac.questions.first else { return check(false, "a question was put") }
        let lines = ScriptAbilities.approvalLines(for: plugin).map(\.text)
        check(lines.allSatisfy { question.title.contains($0) }, "the title is the approval lines, word for word")
        expect(question.items.map { $0.title }, ["Not now", "Approve"], "the answers")
        expect(plugins.questionIsOpen, true, "open")
        let broker = AXScriptBroker(pluginID: "script-test", apps: ["com.example.app"], environment: mac.environment(), questionOpen: { plugins.questionIsOpen })
        _ = try? broker.perform(.say, .object(["text": .string("hush")]))
        expect(mac.scriptSaid, [], "nothing a script says is heard while it is open")
        question.closed()
        expect(plugins.questionIsOpen, false, "closed")
        _ = try? broker.perform(.say, .object(["text": .string("now")]))
        expect(mac.scriptSaid, ["now"], "and heard again after")
        // Approve, with developer mode off: a receipt from a file.
        plugins.askApproval("script-test")
        if case .action(let approve)? = mac.questions.last?.items.last?.kind { approve() } else { check(false, "Approve is an action") }
        expect(trust.receipt(for: "script-test")?.origin, .file, "approved with developer mode off: a file's receipt")
        expect(trust.decision(for: entry.plugin), .allowed, "the script may run")
        expect(plugins.questionIsOpen, false, "no question open")
        // Approve with developer mode on: a draft's.
        try? trust.revoke(id: "script-test")
        try? trust.setDeveloperMode(true)
        plugins.askApproval("script-test")
        if case .action(let approve)? = mac.questions.last?.items.last?.kind { approve() } else { check(false, "Approve is an action") }
        expect(trust.receipt(for: "script-test")?.origin, .draft, "approved with developer mode on: a draft's receipt")
        // Not now writes nothing.
        try? trust.revoke(id: "script-test")
        plugins.askApproval("script-test")
        if case .action(let notNow)? = mac.questions.last?.items.first?.kind { notNow() } else { check(false, "Not now is an action") }
        expect(trust.receipt(for: "script-test") == nil, true, "Not now leaves no receipt")
    }

    test("script plugins: approving starts a script whose app is in front, and taking the receipt away stops it") {
        let mac = Mac()
        guard let (plugins, entry, trust, plugin) = start(mac, script: "turnover.on('focus', function (e) {});", approved: false) else { return }
        defer { plugins.terminate() }
        fire(plugins, .gainFocus, el(button))
        expect(entry.host == nil, true, "waiting")
        plugins.approve(plugin, signature: .none)
        check(waitFor { ready(entry) }, "approved while its app is in front: it starts")
        plugins.turnOffByMenu(entry)
        expect(entry.host == nil, true, "its receipt was taken away: it stops")
        expect(trust.receipt(for: "script-test") == nil, true, "no receipt")
    }

    test("script plugins: the menu offers waiting, on and turned off after problems, and developer mode") {
        let mac = Mac()
        guard let (plugins, entry, trust, _) = start(mac, script: "turnover.on('focus', function (e) {});", approved: false) else { return }
        defer { plugins.terminate() }
        @MainActor func titles() -> [String] { plugins.items().map { $0.title } }
        expect(titles(), ["Script test, script waiting for approval", "Turn off every plugin until TurnOver starts again", "Developer mode for scripts"], "waiting")
        if case .action(let run) = plugins.items()[0].kind { run() }
        check(waitFor { !mac.questions.isEmpty }, "choosing it opens the question")
        try? trust.approve(entry.plugin, origin: .file)
        expect(titles()[0], "Script test, script on", "on")
        plugins.turnOff(entry)
        expect(titles()[0], "Script test, script turned off after problems", "turned off")
        if case .action(let again) = plugins.items()[0].kind { again() }
        expect(entry.turnedOff, false, "choosing it starts it again")
        expect(titles()[0], "Script test, script on", "on again")
        expect(titles().last, "Developer mode for scripts", "developer mode")
        if case .toggle(let get, let set)? = plugins.items().last?.kind {
            expect(get(), false, "off")
            set(true)
            expect(get(), true, "turned on")
            expect(trust.developerMode, true, "kept in the sealed file")
            check(mac.spoken.contains { $0.contains("Developer mode for scripts is on.") && $0.contains("keeps running when you save") }, "a sentence says what it means")
            set(false)
            expect(trust.developerMode, false, "turned off")
        } else { check(false, "developer mode is a switch") }
    }

    test("script plugins: at start it says how many scripts are on, and that developer mode is, and nothing otherwise") {
        let mac = Mac()
        let trust = store()
        mac.plugins = (1...3).map { makePlugin(id: "on-\($0)", script: "turnover.on('focus', function (e) {});") }
        var plugins = ScriptPlugins(trust: trust, environment: mac.environment())
        expect(plugins.startupWords(), [], "no script may run and developer mode is off: nothing")
        plugins.terminate()
        try? trust.approve(mac.plugins[0], origin: .file)
        plugins = ScriptPlugins(trust: trust, environment: mac.environment())
        expect(plugins.startupWords(), ["1 plugin script is on."], "one")
        plugins.terminate()
        for p in mac.plugins { try? trust.approve(p, origin: .file) }
        plugins = ScriptPlugins(trust: trust, environment: mac.environment())
        expect(plugins.startupWords(), ["3 plugin scripts are on."], "three")
        plugins.terminate()
        try? trust.setDeveloperMode(true)
        plugins = ScriptPlugins(trust: trust, environment: mac.environment())
        expect(plugins.startupWords(), ["3 plugin scripts are on.", "Developer mode for scripts is on."], "and developer mode")
        plugins.terminate()
        try? trust.revoke(id: "on-1"); try? trust.revoke(id: "on-2"); try? trust.revoke(id: "on-3")
        plugins = ScriptPlugins(trust: trust, environment: mac.environment())
        expect(plugins.startupWords(), ["Developer mode for scripts is on."], "developer mode alone is still said")
        plugins.terminate()
    }

    test("script plugins: after a hang no script runs, and it is said") {
        let mac = Mac()
        mac.afterHang = true
        guard let (plugins, entry, _, _) = start(mac, script: "turnover.on('focus', function (e) {});") else { return }
        defer { plugins.terminate() }
        expect(plugins.blocked, true, "blocked")
        fire(plugins, .gainFocus, el(button))
        expect(entry.host == nil, true, "no host starts")
        check(plugins.startupWords().first?.contains("stopped responding") == true, "the start-up words say so: \(plugins.startupWords())")
        expect(plugins.startupWords().count, 1, "once, and nothing about scripts being on")
        check(plugins.items().first?.title.contains("off until TurnOver starts again") == true, "the menu says so too")
    }

    test("script plugins: a changed script in developer mode starts again, and says reloaded; otherwise it waits for approval") {
        let mac = Mac()
        mac.limits.eventDeadline = 0.5
        guard let (plugins, entry, trust, plugin) = start(mac, script: "turnover.on('focus', function (e) {});", developerMode: true) else { return }
        defer { plugins.terminate() }
        expect(startHost(plugins, entry), true, "the script loads")
        let first = entry.host
        let edited = plugin.folder.appendingPathComponent("main.js")
        try? (commandStub + "turnover.on('focus', function (e) { e.say('edited'); });").write(to: edited, atomically: true, encoding: .utf8)
        mac.plugins = [ProfileStore.load(folder: plugin.folder)]
        mac.front = nil   // the author is in an editor: the plugin's app is behind
        plugins.reloaded()
        check(waitFor { entry.host != nil && entry.host !== first }, "a changed draft that may still run is started again, even with its app behind")
        check(waitFor { mac.spoken.contains { $0.contains("script reloaded") } }, "and \"reloaded\" is said")
        check(waitFor { if case .paused? = entry.host?.state { return true } else { return false } }, "it waits paused until its app is in front")
        mac.front = AXReplay.floor + 1
        // A script error: its first error, with the line, is said.
        try? (commandStub + "var x = ;\n").write(to: edited, atomically: true, encoding: .utf8)
        mac.plugins = [ProfileStore.load(folder: plugin.folder)]
        plugins.reloaded()
        check(waitFor { mac.spoken.contains { $0.contains("did not load") && $0.contains("line") } }, "a script that no longer loads says its first error")
        // Developer mode off: the changed file needs its approval again.
        try? trust.setDeveloperMode(false)
        try? (commandStub + "turnover.on('focus', function (e) { e.say('again'); });").write(to: edited, atomically: true, encoding: .utf8)
        mac.plugins = [ProfileStore.load(folder: plugin.folder)]
        plugins.reloaded()
        expect(entry.host == nil, true, "a changed file with developer mode off does not run")
        expect(trust.decision(for: entry.plugin), .refused(.filesChanged), "it is waiting for approval")
        // A plugin taken away is stopped and forgotten.
        mac.plugins = []
        plugins.reloaded()
        expect(plugins.entries.isEmpty, true, "removed")
    }

    // MARK: The fix pass after the independent review (16 Nov 2026)

    /// A holder that keeps bytes in memory and can be told to fail its writes: a keeper that stops answering.
    final class FailableHolder: ScriptTrustHolder {
        let kind = "memory (a test)"
        var bytes: Data?
        var failStores = false
        func load() throws -> Data? { bytes }
        func store(_ data: Data) throws {
            if failStores { throw ScriptTrustStore.WriteFailure(description: "the keeper did not answer") }
            bytes = data
        }
    }

    test("script plugins: until a script may run, none of its plugin's profile is live; plugins without a script are untouched") {
        let mac = Mac()
        let manifest = scriptManifestText(["abilities": "[\"read\", \"say\"]", "commands": nil])
        let profile = #"{"labels":[{"match":{"role":"button","title":"Save"},"name":"Keep"}],"silence":[{"title":"Name"}]}"#
        let folder = scriptTempPlugin(["manifest.json": manifest, "profile.json": profile, "main.js": "turnover.on('focus', function (e) {});\n"])
        let dataFolder = scriptTempPlugin(["manifest.json": #"{"id":"data-one","name":"Data","version":"1","apps":["com.example.app"]}"#,
                                           "profile.json": #"{"labels":[{"match":{"role":"textField","title":"Name"},"name":"Who"}]}"#])
        cleanup += [folder, dataFolder]
        let script = ProfileStore.load(folder: folder), data = ProfileStore.load(folder: dataFolder)
        expect(script.error, nil, "the script plugin loads"); expect(data.error, nil, "and the data plugin")
        let profiles = mac.profiles
        profiles.replayBundle = "com.example.app"
        defer { profiles.replayBundle = nil }
        let pid = AXReplay.floor + 1
        profiles.addTesting(script); profiles.addTesting(data)
        expect(profiles.livePlugins.count, 2, "with scripts off (no gate) both are live, as before")
        expect(profiles.label(for: el(button), pid: pid)?.0, "Keep", "the label works")
        mac.plugins = [script]
        let trust = store()
        let plugins = ScriptPlugins(trust: trust, environment: mac.environment())
        defer { plugins.terminate() }
        expect(profiles.livePlugins.compactMap { $0.manifest?.id }, ["data-one"], "an unapproved script's plugin is dark, the data plugin is not")
        expect(profiles.label(for: el(button), pid: pid)?.0, nil, "no label from it")
        expect(profiles.isSilenced(el(nameField), pid: pid), false, "no silence from it")
        expect(profiles.label(for: el(nameField), pid: pid)?.0, "Who", "the data plugin's label still works")
        try? trust.approve(script, origin: .file)
        plugins.reconcileTrust()
        expect(profiles.livePlugins.count, 2, "approved, its profile is live")
        expect(profiles.label(for: el(button), pid: pid)?.0, "Keep", "its label works")
        expect(profiles.isSilenced(el(nameField), pid: pid), true, "and its silence")
        // Its files change: dark again until decided again.
        try? (manifest + "\n").write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let changed = ProfileStore.load(folder: folder)
        mac.plugins = [changed]; profiles.addTesting(changed)
        check(profiles.livePlugins.count == 1, "a plugin with other files than the approved ones is dark at once, before anything reloads")
        plugins.reloaded()
        expect(profiles.livePlugins.compactMap { $0.manifest?.id }, ["data-one"], "and stays dark")
        expect(profiles.isSilenced(el(nameField), pid: pid), false, "no silence")
        // Approved again, then turned off from the menu.
        try? trust.approve(changed, origin: .file)
        plugins.reconcileTrust()
        expect(profiles.livePlugins.count, 2, "approved again, live again")
        if let entry = plugins.entries["script-test"] { plugins.turnOffByMenu(entry) }
        expect(profiles.livePlugins.compactMap { $0.manifest?.id }, ["data-one"], "taking the approval away darkens it")
    }

    test("script plugins: silences, watches and reading keys count as say in a plugin's real abilities; the listing's own count is unchanged") {
        @MainActor func plugin(_ profile: String) -> LoadedPlugin {
            let folder = scriptTempPlugin(["manifest.json": scriptManifestText(["abilities": "[\"read\"]", "commands": nil]), "profile.json": profile, "main.js": "\n"])
            cleanup.append(folder)
            return ProfileStore.load(folder: folder)
        }
        let silence = plugin(#"{"silence":[{"title":"Name"}]}"#), watch = plugin(#"{"watch":[{"match":{"title":"Total"}}]}"#)
        let reading = plugin(#"{"keys":[{"key":"control+option+k","description":"Read","action":"read","target":{"title":"Save"}}]}"#)
        let label = plugin(#"{"labels":[{"match":{"title":"Save"},"name":"Keep"}]}"#)
        for (name, p) in [("a silence", silence), ("a watch", watch), ("a reading key", reading)] {
            expect(p.error, nil, "\(name) loads")
            check(ScriptAbilities.effective(for: p).contains(.say), "\(name) counts as say")
            check(!PluginListing.abilitiesUsed(by: p.profile!).contains("say") || name == "a reading key" && false, "the listing's own count is as it was for \(name)")
        }
        check(!ScriptAbilities.effective(for: label).contains(.say), "a label is not speech control")
        expect(PluginListing.abilitiesUsed(by: silence.profile!), ["read"], "the listing counts a silence as read only, as before")
    }

    test("script plugins: in a closed app a script reads and speaks and never acts, in the broker whatever the manifest said") {
        let mac = Mac()
        mac.bundles = { $0 >= AXReplay.floor ? "com.apple.Terminal" : "com.other.app" }
        mac.focus = el(nameField)
        let broker = AXScriptBroker(pluginID: "script-test", apps: ["com.apple.Terminal"], environment: mac.environment(), questionOpen: { false })
        let b = broker.item(for: el(button))?["handle"]?.stringValue ?? "", n = broker.item(for: el(nameField))?["handle"]?.stringValue ?? ""
        check(!b.isEmpty && !n.isEmpty, "items in the closed app can still be read")
        allRefused(["press", "focus", "edit", "menu", "keys"], "in a closed app", broker, mac, button: b, field: n)
        _ = try? broker.perform(.say, .object(["text": .string("spoken in Terminal")]))
        _ = try? broker.perform(.itemRead, .object(["handle": .string(b)]))
        expect(mac.scriptSaid.count, 2, "speech and reading still work there")
        // The same acts in an ordinary app.
        mac.bundles = { $0 >= AXReplay.floor ? "com.example.app" : "com.other.app" }
        let ok = AXScriptBroker(pluginID: "script-test", apps: ["com.example.app"], environment: mac.environment(), questionOpen: { false })
        let b2 = ok.item(for: el(button))?["handle"]?.stringValue ?? ""
        do { _ = try ok.perform(.itemPress, .object(["handle": .string(b2)])) } catch { check(false, "press in an ordinary app: \(error)") }
        // A script whose own app is ordinary but whose item is in a closed one is refused too.
        mac.bundles = { $0 == AXReplay.floor + 1 ? "com.example.app" : "com.apple.Terminal" }
    }

    test("script plugins: the closed-app notice says read and speak only, and a manifest that names a closed app and asks to act is refused at load") {
        for (app, name) in [("com.apple.Terminal", "Terminal"), ("com.googlecode.iterm2", "iTerm"), ("com.apple.Safari", "Safari"), ("com.apple.Passwords", "Passwords")] {
            for ability in ["press", "focus", "edit", "menu", "keys"] {
                let folder = scriptTempPlugin(["manifest.json": scriptManifestText(["apps": "[\"\(app)\"]", "abilities": "[\"read\", \"say\", \"\(ability)\"]", "commands": nil]), "profile.json": "{}", "main.js": "\n"])
                cleanup.append(folder)
                let loaded = ProfileStore.load(folder: folder)
                check(loaded.error?.contains("only read and speak in \(name)") == true && loaded.error?.contains(ability) == true, "\(app) with \(ability) is refused, saying why: \(loaded.error ?? "loaded")")
            }
            let folder = scriptTempPlugin(["manifest.json": scriptManifestText(["apps": "[\"\(app)\"]", "abilities": "[\"read\", \"say\", \"clipboard\"]", "commands": nil]), "profile.json": "{}", "main.js": "\n"])
            cleanup.append(folder)
            expect(ProfileStore.load(folder: folder).error, nil, "\(app) with read, say and clipboard loads")
        }
        let mixed = scriptTempPlugin(["manifest.json": scriptManifestText(["apps": "[\"com.example.app\", \"com.apple.Terminal\"]", "abilities": "[\"read\", \"keys\"]", "commands": nil]), "profile.json": "{}", "main.js": "\n"])
        cleanup.append(mixed)
        check(ProfileStore.load(folder: mixed).error?.contains("Terminal") == true, "a plugin for an ordinary app and Terminal is refused as a whole")
        let plugin = makePlugin(script: "", abilities: "[\"read\", \"say\"]", apps: "[\"com.apple.Terminal\"]")
        let lines = ScriptAbilities.approvalLines(for: plugin, appName: { _ in nil }).map(\.text)
        check(lines.contains { $0.contains("In Terminal it can only read and speak") && $0.contains("never press, type or choose") }, "the notice: \(lines)")
        check(!lines.contains { $0.contains("Only the person who wrote it") || $0.contains("do more harm") }, "and it promises nothing more")
    }

    test("script plugins: a menu item cannot be pressed like a button, whatever its title or language") {
        let mac = Mac()
        let broker = AXScriptBroker(pluginID: "script-test", apps: ["com.example.app"], environment: mac.environment(), questionOpen: { false })
        guard let handle = broker.item(for: el(menuItem))?["handle"]?.stringValue else { return check(false, "a handle for the menu item") }
        let actions = AXReplay.actions.count
        do { _ = try broker.perform(.itemPress, .object(["handle": .string(handle)])); check(false, "a menu item was pressed") }
        catch let error as ScriptBrokerError { check(error == .refused(error.message) && error.message.contains("menu"), "refused, pointing to menu: \(error)") } catch { check(false, "\(error)") }
        expect(AXReplay.actions.count, actions, "nothing was pressed")
        check(PluginPolicy.isPasteShortcut(character: "v", modifiers: 0), "Command V is Paste in any language")
        check(PluginPolicy.isPasteShortcut(character: "V", modifiers: 1), "so is Command Shift V")
        check(!PluginPolicy.isPasteShortcut(character: "v", modifiers: 8), "a V with no Command is not")
        check(!PluginPolicy.isPasteShortcut(character: "c", modifiers: 0), "nor is Copy")
        check(!PluginPolicy.isPasteShortcut(character: nil, modifiers: nil), "nor an item with no shortcut")
    }

    test("script plugins: find with a huge limit or a zero nth does not stop TurnOver, and is refused or clamped") {
        let mac = Mac()
        let broker = AXScriptBroker(pluginID: "script-test", apps: ["com.example.app"], environment: mac.environment(), questionOpen: { false })
        for limit in [1e100, -1e100, 1e300, 0] {
            let found = (try? broker.perform(.find, .object(["match": .object([:]), "limit": .number(limit)])))
            if case .array(let items)? = found { check(items.count >= 1 && items.count <= mac.limits.findLimit, "a limit of \(limit) is clamped: \(items.count)") } else { check(false, "a limit of \(limit) gave no list") }
        }
        for nth in [0.0, -9223372036854775808.0, 1e19, 6001] {
            do { _ = try broker.perform(.find, .object(["match": .object(["nth": .number(nth)])])); check(false, "nth \(nth) was accepted") }
            catch let error as ScriptBrokerError { check(error == .invalid(error.message), "nth \(nth) is invalid: \(error)") } catch { check(false, "\(error)") }
        }
        var zero = ElementMatch(); zero.nth = 0
        expect(ElementMatcher.findOne(zero, pid: AXReplay.floor + 1) == nil, true, "findOne with nth 0 finds nothing, and does not index before the start")
        check(!ElementMatcher.matchesHere(el(button), zero, pid: AXReplay.floor + 1), "nor does a rule with nth 0 match anything")
        var last = ElementMatch(); last.nth = -1; last.role = "button"
        expect(ElementMatcher.findOne(last, pid: AXReplay.floor + 1) != nil, true, "the last still works")
    }

    test("script plugins: a script's search cannot ask what a password field holds") {
        let mac = Mac()
        let broker = AXScriptBroker(pluginID: "script-test", apps: ["com.example.app"], environment: mac.environment(), questionOpen: { false })
        var plain = ElementMatch(); plain.value = "hunter*"
        expect(ElementMatcher.find(plain, pid: AXReplay.floor + 1).count, 1, "an ordinary search matches on the value (the leak this closes)")
        for value in ["hunter*", "hunter2", "*"] {
            guard case .array(let items)? = try? broker.perform(.find, .object(["match": .object(["value": .string(value), "subrole": .string("AXSecureTextField")])])) else { return check(false, "no list") }
            expect(items.count, 0, "a script asking for a password field by its value (\(value)) gets nothing")
        }
        guard case .array(let nested)? = try? broker.perform(.find, .object(["match": .object(["any": .array([.object(["value": .string("hunter2")]), .object(["value": .string("zzz")])])])])) else { return check(false, "no list") }
        expect(nested.count, 0, "nor through an any")
        guard case .array(let ordinary)? = try? broker.perform(.find, .object(["match": .object(["value": .string("Ann")])])) else { return check(false, "no list") }
        expect(ordinary.count, 1, "an ordinary field is still found by its value")
    }

    test("script plugins: a wildcard cannot run for long, and a pattern or a text beyond the limits matches nothing") {
        var pathological = ElementMatch()
        pathological.title = String(repeating: "*a", count: 25) + "*b"
        let started = Date()
        check(!ElementMatcher.matches(el(longName), pathological), "it does not match")
        check(Date().timeIntervalSince(started) < 1, "and finishes at once, not after exponential work: \(Date().timeIntervalSince(started)) s")
        var ends = ElementMatch(); ends.title = "*a"
        check(ElementMatcher.matches(el(longName), ends), "a star still matches a long run")
        var first = ElementMatch(); first.title = "a*a"
        check(ElementMatcher.matches(el(longName), first), "at either end")
        check(!ElementMatcher.matches(el(longerName), ends), "a name past 10,000 characters is not matched by a pattern with a star")
        var long = ElementMatch(); long.title = "*" + String(repeating: "a", count: 300)
        check(!ElementMatcher.matches(el(longName), long), "a pattern past 200 characters matches nothing")
        var save = ElementMatch(); save.title = "S*e"
        check(ElementMatcher.matches(el(button), save), "S*e is Save")
        save.title = "*AVE"; check(ElementMatcher.matches(el(button), save), "without regard to case")
        save.title = "S*x"; check(!ElementMatcher.matches(el(button), save), "and not what it is not")
        save.title = "Sa?e"; check(!ElementMatcher.matches(el(button), save), "a question mark is only itself")
        save.title = "*"; check(ElementMatcher.matches(el(button), save), "a lone star means has one")
    }

    test("script plugins: speech is heard only while the Mac's own frontmost app is the plugin's, and a reading is cut to the limit") {
        let mac = Mac()
        mac.limits.sayCharacters = 3
        let broker = AXScriptBroker(pluginID: "script-test", apps: ["com.example.app"], environment: mac.environment(), questionOpen: { false })
        let t = broker.item(for: el(totalText))?["handle"]?.stringValue ?? ""
        _ = try? broker.perform(.itemRead, .object(["handle": .string(t)]))
        expect(mac.scriptSaid, ["Tot"], "a reading is cut to the character limit")
        mac.macFront = AXReplay.floor - 1   // TurnOver's focus is still in the plugin's app; the Mac says another
        _ = try? broker.perform(.say, .object(["text": .string("hi")]))
        _ = try? broker.perform(.sound, .object(["name": .string("link")]))
        _ = try? broker.perform(.itemRead, .object(["handle": .string(t)]))
        expect(mac.scriptSaid, ["Tot"], "nothing was said while the Mac's frontmost app is another")
        expect(mac.sounds, [], "and no sound")
    }

    test("script plugins: keys are looked at again after the slow questions, and go to the same app or not at all; copy needs the app in front") {
        let mac = Mac()
        mac.focus = el(nameField)
        let broker = AXScriptBroker(pluginID: "script-test", apps: ["com.example.app"], environment: mac.environment(), questionOpen: { false })
        mac.onFocusQuery = { mac.front = AXReplay.floor - 1; mac.macFront = AXReplay.floor - 1 }   // the person switches apps while TurnOver asks
        do { _ = try broker.perform(.keys, .object(["keys": .string("command+k")])); check(false, "keys went to another app") }
        catch let error as ScriptBrokerError { check(error == .refused(error.message), "refused: \(error)") } catch { check(false, "\(error)") }
        expect(mac.keys, [], "no key was sent")
        mac.onFocusQuery = nil
        mac.front = AXReplay.floor - 1
        do { _ = try broker.perform(.copy, .object(["text": .string("x")])); check(false, "copied while behind") } catch { }
        expect(mac.copied, [], "nothing was put on the clipboard while the app is behind")
        mac.front = AXReplay.floor + 1; mac.macFront = AXReplay.floor + 1
        _ = try? broker.perform(.copy, .object(["text": .string("y")]))
        expect(mac.copied, ["y"], "in front it is")
    }

    test("script plugins: what a host reports is held while an approval question is open, and said when it closes") {
        let mac = Mac()
        guard let (plugins, entry, _, _) = start(mac, script: "var x = ;\n") else { return }
        defer { plugins.terminate() }
        plugins.askApproval(entry.id)
        check(plugins.questionIsOpen && mac.questions.count == 1, "a question is open")
        fire(plugins, .gainFocus, el(button))
        check(waitFor { entry.failedHash != nil }, "the script failed to load")
        settle(0.2)
        check(!mac.spoken.contains { $0.contains("did not load") }, "its words were not said during the question: \(mac.spoken)")
        mac.questions.last?.closed()
        check(mac.spoken.contains { $0.contains("did not load") }, "they are said when it closes: \(mac.spoken)")
    }

    test("script plugins: when taking an approval away cannot be kept, the script stops anyway and no approval holds for the rest of the run") {
        let mac = Mac()
        let plugin = makePlugin(script: "turnover.on('focus', function (e) {});")
        let holder = FailableHolder()
        let trust = ScriptTrustStore(holder: holder)
        try? trust.approve(plugin, origin: .file)
        mac.plugins = [plugin]
        let plugins = ScriptPlugins(trust: trust, environment: mac.environment())
        defer { plugins.terminate() }
        guard let entry = plugins.entries["script-test"] else { return check(false, "an entry") }
        expect(startHost(plugins, entry), true, "the approved script runs")
        holder.failStores = true
        plugins.turnOffByMenu(entry)
        expect(entry.host == nil, true, "the script was stopped though the revocation was not kept")
        expect(trust.receipts.count, 0, "no approval is believed for the rest of this run")
        check(trust.unavailable != nil, "the store says it cannot be used")
        expect(trust.decision(for: plugin).isAllowed, false, "so it would not start again")
        check(mac.spoken.contains { $0.contains("could not be taken away") }, "and the person is told: \(mac.spoken)")
    }

    test("script plugins: the signer in the approval question is the signer of the files that were loaded") {
        let mac = Mac()
        guard let (plugins, entry, _, plugin) = start(mac, script: "turnover.on('focus', function (e) {});", approved: false) else { return }
        defer { plugins.terminate() }
        let first = Curve25519.Signing.PrivateKey(), second = Curve25519.Signing.PrivateKey()
        try? ScriptTrust.writeSignature(try! ScriptTrust.sign(digest: ScriptTrust.digest(folder: plugin.folder)!, with: first), to: plugin.folder)
        // Between loading and the question, another signed version is put in the folder.
        try? (commandStub + "turnover.on('focus', function (e) { e.say('other'); });").write(to: plugin.folder.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
        try? ScriptTrust.writeSignature(try! ScriptTrust.sign(digest: ScriptTrust.digest(folder: plugin.folder)!, with: second), to: plugin.folder)
        let secondPrint = ScriptTrust.fingerprint(ofPublicKey: second.publicKey.rawRepresentation)
        plugins.askApproval(entry.id)
        guard let title = mac.questions.last?.title else { return check(false, "a question") }
        check(!title.contains(secondPrint), "the question does not name the signer of other files: \(title)")
        check(title.contains("does not match its files"), "it says the signature does not fit the files it is about: \(title)")
    }
}
