// SPDX-License-Identifier: GPL-3.0-or-later
// Every plugin TurnOver carries is tested in its build (docs/PLUGIN-TOOLKIT-PLAN.md, item 5): a change to TurnOver that
// breaks one is caught before it ships. Tests/Plugins/* (and Resources/plugins/* when there are built-in ones).
import Foundation
import TurnOverCore
import PluginTestKit
import CryptoKit

func pluginTests() {
    test("plugin match: the role word \"text\" means static text, as an item's role says") {
        check(ElementMatcher.roleMatches("text", "AXStaticText"), "text matches a static text")
        check(ElementMatcher.roleMatches("staticText", "AXStaticText"), "staticText matches it")
        check(!ElementMatcher.roleMatches("text", "AXTextField"), "text does not match a text field")
        check(ElementMatcher.roleMatches("textField", "AXTextField"), "textField still matches a text field")
        check(!ElementMatcher.roleMatches("text", "AXButton"), "or a button")
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    for dir in ["Tests/Plugins", "Resources/plugins"] {
        for folder in PluginTestRunner.folders(under: root.appendingPathComponent(dir)) {
            test("plugin \(folder.lastPathComponent): its own tests") {
                let r = PluginTestRunner.run(folder: folder)
                for l in r.lines where l.hasPrefix("FAIL") { print("   " + l) }
                expect(r.failed, 0)
                expect(r.passed > 0, true)
            }
        }
    }
}

/// The plugin library's list (stage 2): only a signed, current, not-older list is taken.
func pluginLibraryTests() {
    let key = Curve25519.Signing.PrivateKey()
    let pub = key.publicKey.rawRepresentation.base64EncodedString()
    let iso = ISO8601DateFormatter()
    func list(_ seq: Int, expires: Date = Date().addingTimeInterval(86400)) -> Data {
        Data("""
        {"format":1,"sequence":\(seq),"expires":"\(iso.string(from: expires))","withdrawn":["bad-one"],
         "plugins":[{"id":"x","version":"1.0","file":"x-1.0.zip","sha256":"00","size":1,"level":"Community","name":"X"}]}
        """.utf8)
    }
    func sig(_ d: Data) -> Data { Data(try! key.signature(for: d).base64EncodedString().utf8) }
    UserDefaults.standard.removeObject(forKey: PluginLibrary.sequenceKey)
    defer { UserDefaults.standard.removeObject(forKey: PluginLibrary.sequenceKey) }

    test("library: a signed, current list is taken") {
        let d = list(5)
        guard case .success(let i) = PluginLibrary.verify(d, signature: sig(d), key: pub) else { return Harness.fail("refused") }
        expect(i.plugins.first?.id, "x"); expect(i.withdrawn, ["bad-one"])
        expect(UserDefaults.standard.integer(forKey: PluginLibrary.sequenceKey), 5, "sequence recorded")
    }
    test("library: an altered list is refused") {
        let d = list(6), altered = Data(String(decoding: d, as: UTF8.self).replacingOccurrences(of: "Community", with: "Official").utf8)
        if case .success = PluginLibrary.verify(altered, signature: sig(d), key: pub) { Harness.fail("taken") }
    }
    test("library: another key's signature is refused") {
        let d = list(6), other = Curve25519.Signing.PrivateKey()
        if case .success = PluginLibrary.verify(d, signature: Data(try! other.signature(for: d).base64EncodedString().utf8), key: pub) { Harness.fail("taken") }
        if case .success = PluginLibrary.verify(d, signature: nil, key: pub) { Harness.fail("taken with no signature") }
    }
    test("library: an older list is refused") {
        let d = list(4)
        if case .success = PluginLibrary.verify(d, signature: sig(d), key: pub) { Harness.fail("taken") }
    }
    test("library: an expired list is refused") {
        let d = list(7, expires: Date().addingTimeInterval(-60))
        if case .success = PluginLibrary.verify(d, signature: sig(d), key: pub) { Harness.fail("taken") }
    }
    test("library: the built-in key is TurnOver's library key") {
        expect(PluginLibrary.publicKey, "glpzeHM7UV1IAwoisZ0SbNLDV5oPWRgJDogDgIZs74w=")
    }
}

/// The code review's refusals (13 Oct): menus and keys that reach outside the app, checked at load; levels; the
/// one-file signed list.
func pluginPolicyTests() {
    let fm = FileManager.default
    func plugin(keys: String, labels: String = "[]") -> LoadedPlugin {
        let dir = fm.temporaryDirectory.appendingPathComponent("turnover-policy-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try? #"{"id":"policy-test","name":"Policy test","version":"1","apps":["com.example.app"],"kind":"profile","formatVersion":1}"#
            .write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try? "{\"keys\": \(keys), \"labels\": \(labels)}".write(to: dir.appendingPathComponent("profile.json"), atomically: true, encoding: .utf8)
        return ProfileStore.load(folder: dir)
    }
    func menu(_ path: String) -> String { #"[{"key":"turnover+shift+m","description":"x","action":"menu","menu":\#(path)}]"# }
    func sends(_ k: String) -> String { #"[{"key":"turnover+shift+k","description":"x","action":"keys","keys":"\#(k)"}]"# }
    func refused(_ p: LoadedPlugin) -> Bool { p.manifest == nil && (p.error ?? "").hasPrefix("refused") }

    test("policy: menus that reach the Mac are refused at load") {
        check(refused(plugin(keys: menu(#"["*", "Lock Screen"]"#))), "a pattern for the first menu")
        check(refused(plugin(keys: menu(#"["Edit", "Paste"]"#))), "Paste by menu")
        check(refused(plugin(keys: menu(#"["Edit", "*aste"]"#))), "Paste by pattern")
        check(refused(plugin(keys: menu(#"["File", "Log Out Example User…"]"#))), "Log Out with a name")
        check(refused(plugin(keys: menu(#"["Apple", "Restart…"]"#))), "the Apple menu")
        check(!refused(plugin(keys: menu(#"["Controls", "Sleep Timer"]"#))), "Sleep Timer is the app's own")
        check(!refused(plugin(keys: menu(#"["File", "Save"]"#))), "File, Save is fine")
    }
    test("policy: keys that reach the Mac are refused by shape") {
        for k in ["command+f5", "command+option+shift+q", "control+3", "control+leftArrow", "command+control+f", "command+shift+4", "f11", "command+v"] {
            check(refused(plugin(keys: sends(k))), "\(k) should be refused")
        }
        for k in ["command+s", "command+shift+n", "f5", "option+downArrow"] {
            check(!refused(plugin(keys: sends(k))), "\(k) should be allowed")
        }
    }
    test("policy: TurnOver's essential keys are refused at load") {
        check(refused(plugin(keys: #"[{"key":"command+control+,","description":"x","action":"say","say":"hi"}]"#)), "the layer key")
    }
    test("policy: Verified may rename; Community may not") {
        let p = plugin(keys: "[]", labels: #"[{"match":{"role":"AXButton","identifier":"save"},"name":"Save"}]"#)
        check(PluginPolicy.check(p).libraryOnly.contains { $0.contains("rename") }, "Community")
        check(!PluginPolicy.check(p, level: .verified).libraryOnly.contains { $0.contains("rename") }, "Verified")
    }
    test("library: the one-file signed list") {
        UserDefaults.standard.removeObject(forKey: PluginLibrary.sequenceKey)
        defer { UserDefaults.standard.removeObject(forKey: PluginLibrary.sequenceKey) }
        let key = Curve25519.Signing.PrivateKey(), pub = key.publicKey.rawRepresentation.base64EncodedString()
        let exp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let payload = Data(#"{"format":1,"sequence":3,"expires":"\#(exp)","plugins":[],"withdrawn":[]}"#.utf8)
        func envelope(_ p: Data, _ sig: Data) -> Data {
            try! JSONSerialization.data(withJSONObject: ["payload": p.base64EncodedString(), "signature": sig.base64EncodedString()])
        }
        let sig = try! key.signature(for: payload)
        if case .failure(let e) = PluginLibrary.verifySigned(envelope(payload, sig), key: pub) { Harness.fail("refused: \(e)") }
        let other = Data(#"{"format":1,"sequence":9,"expires":"\#(exp)","plugins":[],"withdrawn":[]}"#.utf8)
        if case .success = PluginLibrary.verifySigned(envelope(other, sig), key: pub) { Harness.fail("a list with another's signature was taken") }
        let newer = Data(#"{"format":2,"sequence":9,"expires":"\#(exp)","plugins":[],"withdrawn":[]}"#.utf8)
        if case .success = PluginLibrary.verifySigned(envelope(newer, try! key.signature(for: newer)), key: pub) { Harness.fail("format 2 taken") }
    }
}
