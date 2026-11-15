// SPDX-License-Identifier: GPL-3.0-or-later
// Format 2, the plugin format with a script (docs/PLUGIN-SCRIPTS-PLAN.md, stage 2, 15 Nov 2026): each new error and
// warning, a format 1 plugin unchanged, and what PluginPolicy refuses for a script's manifest.
import Foundation
import TurnOverCore

/// A plugin folder in the temporary folder, with the given files (name to text). The caller removes it.
func scriptTempPlugin(_ files: [String: String]) -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("turnover-script-test-\(UUID().uuidString)")
    for (name, text) in files {
        let url = folder.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
    return folder
}

/// A format 2 manifest as text, each field overridable: a value of nil leaves the field out, any other is JSON as written.
func scriptManifestText(_ overrides: [String: String?] = [:]) -> String {
    var fields: [(String, String?)] = [
        ("formatVersion", "2"), ("id", "\"script-test\""), ("name", "\"Script test\""), ("version", "\"1\""),
        ("apps", "[\"com.example.app\"]"), ("abilities", "[\"read\", \"say\"]"), ("script", "\"main.js\""),
        ("commands", "[{ \"id\": \"readResult\", \"description\": \"Read the result\", \"key\": \"turnover+control+shift+r\", \"letter\": \"r\" }]"),
    ]
    for (key, value) in overrides {
        if let i = fields.firstIndex(where: { $0.0 == key }) { fields[i].1 = value } else { fields.append((key, value)) }
    }
    return "{\n" + fields.compactMap { f in f.1.map { "  \"\(f.0)\": \($0)" } }.joined(separator: ",\n") + "\n}\n"
}

let scriptTestSource = "turnover.on('focus', function (e) {});\nturnover.command('readResult', function () {});\n"

func scriptFormatTests() {
    let fm = FileManager.default
    /// Load a plugin made of a manifest and the usual other files, and remove it.
    func load(_ manifest: String, profile: String? = "{}", script: String? = scriptTestSource, extra: [String: String] = [:]) -> LoadedPlugin {
        var files = ["manifest.json": manifest].merging(extra) { a, _ in a }
        if let profile { files["profile.json"] = profile }
        if let script { files["main.js"] = script }
        let folder = scriptTempPlugin(files)
        defer { try? fm.removeItem(at: folder) }
        return ProfileStore.load(folder: folder)
    }
    func fails(_ p: LoadedPlugin, _ line: Int?, _ words: [String]) {
        guard let error = p.error else { return check(false, "it should not load, but did") }
        if let line { check(error.hasPrefix("manifest.json, line \(line):"), "the error should start with the manifest's line \(line): \(error)") }
        for w in words { check(error.contains(w), "the error should say \"\(w)\": \(error)") }
        check(p.manifest == nil, "a plugin with an error is not loaded")
    }

    /// The manifest from `overrides` must fail to load, at the line of `field`, saying all of `words`.
    func failsOn(_ overrides: [String: String?], line field: String, _ words: String..., script: String? = scriptTestSource, extra: [String: String] = [:]) {
        let text = scriptManifestText(overrides)
        let want = text.components(separatedBy: "\n").firstIndex { $0.contains("\"\(field)\":") }.map { $0 + 1 }
        fails(load(text, script: script, extra: extra), want, words)
    }

    func command(_ key: String) -> LoadedPlugin { load(scriptManifestText(["commands": "[{ \"id\": \"a\", \"description\": \"x\", \"key\": \"\(key)\" }]"])) }
    func listing(commands: String, profile: String = "{}") -> [String] {
        PluginListing.check(load(scriptManifestText(["commands": commands]), profile: profile), others: []).lines
    }

    test("script format: a valid format 2 plugin loads with its script, its hash and its commands") {
        let p = load(scriptManifestText())
        expect(p.error, nil, "no error")
        expect(p.script, scriptTestSource, "the script's text")
        check(p.scriptHash?.count == 64, "a 64 digit hash: \(p.scriptHash ?? "nil")")
        expect(p.manifest?.commands, [PluginCommand(id: "readResult", description: "Read the result", key: "turnover+control+shift+r", letter: "r")], "the commands")
        expect(p.warnings, [], "no warnings")
    }
    test("script format: a plugin with a script needs no profile.json, a data plugin does") {
        expect(load(scriptManifestText(), profile: nil).error, nil, "a script plugin without a profile loads")
        let data = load(#"{"id":"d","name":"D","version":"1","apps":["com.example.app"]}"#, profile: nil, script: nil)
        check(data.error?.hasPrefix("profile.json") ?? false, "a data plugin without a profile does not: \(data.error ?? "nil")")
    }
    test("script format: script must be main.js") {
        failsOn(["script": "\"other.js\""], line: "script", "script must be \"main.js\"", extra: ["other.js": ""])
    }
    test("script format: script needs formatVersion 2") {
        failsOn(["formatVersion": nil], line: "script", "formatVersion")
        failsOn(["formatVersion": "1"], line: "script", "formatVersion")
    }
    test("script format: script needs abilities") {
        failsOn(["abilities": nil], line: "script", "needs abilities")
        failsOn(["abilities": "[]"], line: "script", "needs abilities")
        failsOn(["abilities": "[\"read\", \"fly\"]"], line: "abilities", "ability \"fly\"")
    }
    test("script format: abilities edit and clipboard are names a script may have") {
        expect(load(scriptManifestText(["abilities": "[\"edit\", \"clipboard\"]"])).error, nil, "edit and clipboard")
    }
    test("script format: a script needs apps, named exactly") {
        failsOn(["apps": "[]"], line: "apps", "needs apps")
        failsOn(["apps": "[\"com.example.*\"]"], line: "apps", "cannot be a pattern")
        failsOn(["apps": "[\"*\"]"], line: "apps", "cannot be a pattern")
    }
    test("script format: main.js missing, not UTF-8 or over 256 KB") {
        let missing = load(scriptManifestText(), script: nil)
        expect(missing.error?.hasPrefix("main.js: is missing"), true, "missing: \(missing.error ?? "nil")")
        let folder = scriptTempPlugin(["manifest.json": scriptManifestText(), "profile.json": "{}"])
        defer { try? fm.removeItem(at: folder) }
        try? Data([0x66, 0xFF, 0xFE, 0x41]).write(to: folder.appendingPathComponent("main.js"))
        expect(ProfileStore.load(folder: folder).error?.hasPrefix("main.js: is not text in UTF-8"), true, "not UTF-8")
        try? Data(repeating: 0x20, count: 256 * 1024).write(to: folder.appendingPathComponent("main.js"))
        expect(ProfileStore.load(folder: folder).error, nil, "exactly 256 KB is allowed")
        try? Data(repeating: 0x20, count: 256 * 1024 + 1).write(to: folder.appendingPathComponent("main.js"))
        let big = ProfileStore.load(folder: folder).error ?? ""
        check(big.hasPrefix("main.js:") && big.contains("at most 256 KB"), "too large: \(big)")
    }
    test("script format: commands need a script") {
        failsOn(["script": nil, "formatVersion": "1", "abilities": nil], line: "commands", "commands need a script", script: nil)
    }
    test("script format: a command needs an id and a description") {
        let noID = load(scriptManifestText(["commands": "[{ \"description\": \"x\" }]"]))
        check(noID.error?.hasPrefix("manifest.json, line 9:") ?? false, "no id, with its line: \(noID.error ?? "nil")")
        check(noID.error?.contains("needs \"id\"") ?? false, "says what is missing: \(noID.error ?? "nil")")
        let noDescription = load(scriptManifestText(["commands": "[{ \"id\": \"x\" }]"]))
        check(noDescription.error?.contains("needs \"description\"") ?? false, "no description: \(noDescription.error ?? "nil")")
        failsOn(["commands": "[{ \"id\": \"x\", \"description\": \"  \" }]"], line: "commands", "needs a description")
    }
    test("script format: a command id is letters and digits, and not repeated") {
        for bad in ["read-result", "read result", "read_result", ""] {
            failsOn(["commands": "[{ \"id\": \"\(bad)\", \"description\": \"x\" }]"], line: "commands", "letters and digits")
        }
        expect(load(scriptManifestText(["commands": "[{ \"id\": \"read2Result\", \"description\": \"x\" }]"])).error?.contains("read2Result"), nil, "letters and digits are fine")
        failsOn(["commands": "[{ \"id\": \"a\", \"description\": \"x\" }, { \"id\": \"a\", \"description\": \"y\" }]"], line: "commands", "used twice")
    }
    test("script format: a command's key follows PluginPolicy as a key in profile.json does") {
        check(command("command+control+,").error?.hasPrefix("refused:") ?? false, "an essential key")
        check(command("p").error?.hasPrefix("refused:") ?? false, "a plain key would type in the app")
        expect(command("turnover+shift+p").error, nil, "an ordinary command key")
    }
    test("script format: a command's key and letter get the listing's key checks, together with the profile's") {
        let twice = listing(commands: "[{ \"id\": \"a\", \"description\": \"x\", \"letter\": \"r\" }, { \"id\": \"b\", \"description\": \"y\", \"letter\": \"r\" }]")
        check(twice.contains { $0.contains("letter r is used twice") }, "the same letter twice: \(twice)")
        let withProfile = listing(commands: "[{ \"id\": \"a\", \"description\": \"x\", \"key\": \"turnover+shift+p\" }]",
                                  profile: #"{"keys":[{"key":"turnover+shift+p","description":"y","action":"say","say":"hi"}]}"#)
        check(withProfile.contains { $0.contains("is used twice in this plugin") }, "a command and a key on one gesture: \(withProfile)")
        let shape = listing(commands: "[{ \"id\": \"a\", \"description\": \"x\", \"key\": \"nonsense+\", \"letter\": \"ab\" }]")
        check(shape.contains { $0.contains("is not in the fixed form") } && shape.contains { $0.contains("one letter or digit") }, "form and letter: \(shape)")
    }
    test("script format: the unknown-field warnings and 'did you mean' know the new fields") {
        let folder = scriptTempPlugin(["manifest.json": scriptManifestText(["scrpt": "\"x\"", "commands": "[{ \"id\": \"a\", \"descripton\": \"x\", \"description\": \"d\" }]"])])
        defer { try? fm.removeItem(at: folder) }
        let problems = PluginFormat.check(manifest: folder.appendingPathComponent("manifest.json"), profile: nil).map(\.description)
        check(problems.contains { $0.contains("the field \"scrpt\"") && $0.contains("did you mean \"script\"") }, "the manifest: \(problems)")
        check(problems.contains { $0.contains("the field \"descripton\"") && $0.contains("did you mean \"description\"") }, "a command: \(problems)")
        check(!problems.contains { $0.contains("the field \"script\"") }, "script itself is known")
        check(!problems.contains { $0.contains("the field \"commands\"") }, "commands itself is known")
    }
    test("script format: format 1 plugins are unchanged, and format 3 is still refused") {
        let data = load(#"{"id":"d","name":"D","version":"1","apps":["com.example.app"],"kind":"profile","formatVersion":1,"abilities":["read"]}"#,
                        profile: #"{"labels":[{"match":{"role":"AXButton","identifier":"x"},"name":"X"}]}"#, script: nil)
        expect(data.error, nil, "a format 1 plugin loads")
        expect(data.script, nil, "it has no script")
        expect(data.scriptHash, nil, "and no script hash")
        expect(load(#"{"id":"d","name":"D","version":"1","apps":["a"],"formatVersion":2}"#, script: nil).error, nil, "a format 2 plugin without a script is a data plugin")
        check(load(#"{"id":"d","name":"D","version":"1","apps":["a"],"formatVersion":3}"#, script: nil).error?.contains("format 3") ?? false, "format 3 is refused")
        expect(PluginFormat.dataVersion, 1, "the maker still writes format 1")
    }
    test("script format: a script's apps may not name the macOS dialogs, the login window or TurnOver") {
        for app in ["com.apple.SecurityAgent", "com.apple.LocalAuthentication.UIAgent", "com.apple.CoreServicesUIAgent", "com.apple.UserNotificationCenter",
                    "com.apple.loginwindow", "com.turnover.reader", "com.turnover.reader.developer", "com.turnover.settings"] {
            let p = load(scriptManifestText(["apps": "[\"com.example.app\", \"\(app)\"]"]))
            check(p.error?.hasPrefix("refused: a script may not work in") ?? false, "\(app) is refused: \(p.error ?? "it loaded")")
        }
        expect(load(scriptManifestText(["apps": "[\"com.example.turnoverish\"]"])).error, nil, "an unrelated name is fine")
    }
    test("script format: the script refusals do not touch a plugin without a script") {
        let data = load(#"{"id":"d","name":"D","version":"1","apps":["com.apple.loginwindow"]}"#, script: nil)
        expect(data.error, nil, "a data plugin loads as before")
        expect(PluginPolicy.scriptRefusals(data.manifest!), [], "and has no script refusals")
    }
    test("script format: the library's closed-apps rule covers a plugin with a script, and an official one still may not break the refusals") {
        let terminal = load(scriptManifestText(["apps": "[\"com.apple.Terminal\"]"]))
        expect(terminal.error, nil, "it loads on its maker's Mac")
        check(PluginPolicy.check(terminal).libraryOnly.contains { $0.contains("Terminal is open to official plugins only") }, "not for the library")
        check(PluginPolicy.check(terminal, level: .official).libraryOnly.isEmpty, "official plugins may")
        let login = ProfileStore.load(folder: scriptTempPlugin(["manifest.json": scriptManifestText(), "main.js": scriptTestSource]))
        var manifest = login.manifest!
        manifest.apps = ["com.apple.loginwindow"]
        let refused = PluginPolicy.check(LoadedPlugin(folder: login.folder, manifest: manifest, profile: login.profile, error: nil, modified: Date()), level: .official)
        check(!refused.refused.isEmpty, "the login window is refused at every level")
        try? fm.removeItem(at: login.folder)
    }
    test("script format: a plugin's abilities are the manifest's with those its profile.json rules imply") {
        let profile = #"{"keys":[{"key":"turnover+shift+p","description":"d","action":"press","target":{"role":"AXButton","identifier":"play"}},{"key":"turnover+shift+m","description":"m","action":"menu","menu":["File","Save"]}],"labels":[{"match":{"identifier":"x"},"name":"X"}]}"#
        let p = load(scriptManifestText(["abilities": "[\"say\"]"]), profile: profile)
        expect(p.error, nil, "loads")
        expect(ScriptAbilities.effective(for: p), [.say, .read, .press, .menu], "say from the manifest; read, press and menu from the rules")
        let plain = load(scriptManifestText(["abilities": "[\"edit\", \"clipboard\"]"]))
        expect(ScriptAbilities.effective(for: plain), [.edit, .clipboard], "nothing implied by an empty profile")
    }
    test("script format: the approval text says the apps, one sentence per ability, the limits and the author's words") {
        let p = load(scriptManifestText(["abilities": "[\"read\", \"say\", \"clipboard\"]", "description": "\"Reads the result aloud.\""]))
        let lines = ScriptAbilities.approvalLines(for: p, appName: { _ in "Example App" })
        expect(lines.map(\.kind), [.apps, .author, .ability, .ability, .ability, .cannot, .unchecked], "the lines, in order")
        check(lines[0].text.contains("Example App") && lines[0].text.contains("only"), "the app: \(lines[0].text)")
        check(lines[1].text.contains("author's own words") && lines[1].text.contains("Reads the result aloud."), "the author's words are marked: \(lines[1].text)")
        check(lines[2].text.contains("read what is on the screen"), "read: \(lines[2].text)")
        check(lines[3].text.contains("speak"), "say: \(lines[3].text)")
        check(lines[4].text.contains("clipboard") && lines[4].text.contains("cannot read"), "clipboard: \(lines[4].text)")
        for word in ["internet", "files", "type", "password", "other app"] { check(lines[5].text.contains(word), "the fixed sentence says \(word): \(lines[5].text)") }
        check(lines[6].text.contains("Nobody has checked this script"), "unchecked: \(lines[6].text)")
        let all = load(scriptManifestText(["abilities": "[\"read\", \"say\", \"press\", \"focus\", \"menu\", \"keys\", \"edit\", \"clipboard\"]"]))
        expect(ScriptAbilities.approvalLines(for: all, appName: { _ in nil }).filter { $0.kind == .ability }.count, 8, "one sentence for each of the eight")
        expect(ScriptAbilities.approvalLines(for: all, appName: { _ in nil })[0].text.contains("com.example.app"), true, "an unknown app is named by its identifier")
    }
    test("script format: the approval text warns for a closed app, and says who signed it and whether it was reviewed") {
        let terminal = load(scriptManifestText(["apps": "[\"com.apple.Terminal\", \"com.example.app\"]"]))
        let warned = ScriptAbilities.approvalLines(for: terminal, appName: { _ in nil })
        check(warned.contains { $0.kind == .closedAppWarning && $0.text.contains("Terminal") && $0.text.contains("Only the person who wrote it") }, "a warning for Terminal")
        let plain = load(scriptManifestText())
        check(!ScriptAbilities.approvalLines(for: plain, appName: { _ in nil }).contains { $0.kind == .closedAppWarning }, "none for an ordinary app")
        let signed = ScriptAbilities.approvalLines(for: plain, origin: .file, signature: .valid(fingerprint: "1234 5678 9abc def0"), appName: { _ in nil })
        check(signed.contains { $0.kind == .signature && $0.text.contains("1234 5678 9abc def0") }, "the fingerprint")
        check(signed.contains { $0.kind == .unchecked }, "signed but not from the library: still unchecked")
        let library = ScriptAbilities.approvalLines(for: plain, origin: .library, signature: .valid(fingerprint: "1234 5678 9abc def0"), appName: { _ in nil })
        check(!library.contains { $0.kind == .unchecked }, "a signed script from the library is not called unchecked")
        let unsignedLibrary = ScriptAbilities.approvalLines(for: plain, origin: .library, signature: .none, appName: { _ in nil })
        check(unsignedLibrary.contains { $0.kind == .unchecked }, "a library script with no signature is")
        let tampered = ScriptAbilities.approvalLines(for: plain, origin: .library, signature: .invalid("x"), appName: { _ in nil })
        check(tampered.contains { $0.kind == .signature && $0.text.contains("does not match") }, "a bad signature is said")
    }
}
