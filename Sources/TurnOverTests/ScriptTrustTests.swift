// SPDX-License-Identifier: GPL-3.0-or-later
// The hash, receipts, the sealed trust file and signatures (docs/PLUGIN-SCRIPTS-PLAN.md, stage 2, 15 Nov 2026). Every
// store here keeps its key in memory and its file in the temporary folder: nothing touches the real Keychain or the real
// support folder.
import Foundation
import CryptoKit
import TurnOverCore

func scriptTrustTests() {
    let fm = FileManager.default
    let sealKey = Data(repeating: 7, count: 32)
    func temp() -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("turnover-trust-test-\(UUID().uuidString)")
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func plugin(in folder: URL, script: String = scriptTestSource, abilities: String = "[\"read\", \"say\"]", apps: String = "[\"com.example.app\"]", profile: String? = "{}") {
        try? scriptManifestText(["abilities": abilities, "apps": apps]).write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try? script.write(to: folder.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
        if let profile { try? profile.write(to: folder.appendingPathComponent("profile.json"), atomically: true, encoding: .utf8) }
    }
    func store(_ file: URL, key: Data? = nil) -> ScriptTrustStore { ScriptTrustStore(file: file, inMemoryKey: key ?? sealKey) }
    /// An independent construction of the plan's hash, for the known-answer check.
    func expectedHash(_ files: [(String, Data)]) -> String {
        var bytes = Data("TurnOver plugin 1\n".utf8)
        for (name, data) in files { bytes += Data(name.utf8) + Data([0]) + Data("\(data.count)".utf8) + Data([0]) + data }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    test("script trust: the hash is the plan's, in the plan's order, with profile.json only if present") {
        let folder = temp(); defer { try? fm.removeItem(at: folder) }
        let m = Data("{\"id\":\"x\"}".utf8), p = Data("{}".utf8), j = Data("turnover.say('é');\0".utf8)
        try? m.write(to: folder.appendingPathComponent("manifest.json")); try? p.write(to: folder.appendingPathComponent("profile.json")); try? j.write(to: folder.appendingPathComponent("main.js"))
        expect(ScriptTrust.hash(folder: folder), expectedHash([("manifest.json", m), ("profile.json", p), ("main.js", j)]), "all three files")
        try? fm.removeItem(at: folder.appendingPathComponent("profile.json"))
        expect(ScriptTrust.hash(folder: folder), expectedHash([("manifest.json", m), ("main.js", j)]), "without a profile")
        try? fm.removeItem(at: folder.appendingPathComponent("main.js"))
        expect(ScriptTrust.hash(folder: folder), nil, "no main.js, no hash")
    }
    test("script trust: the hash is stable and changes with any byte of any counted file") {
        let folder = temp(); defer { try? fm.removeItem(at: folder) }
        let originals: [String: Data] = ["manifest.json": Data("{\"id\":\"x\"}".utf8), "profile.json": Data("{}".utf8), "main.js": Data("say(1);".utf8)]
        func write(_ files: [String: Data]) { for (name, data) in files { try? data.write(to: folder.appendingPathComponent(name)) } }
        write(originals)
        let base = ScriptTrust.hash(folder: folder)
        check(base != nil && base == ScriptTrust.hash(folder: folder), "stable")
        var seen: Set<String> = [base!]
        for (name, data) in originals {
            for i in 0..<data.count {
                var changed = data; changed[i] ^= 0x01
                write([name: changed])
                let h = ScriptTrust.hash(folder: folder)!
                check(seen.insert(h).inserted, "byte \(i) of \(name) changes the hash")
            }
            write([name: data + Data([0x20])])
            check(seen.insert(ScriptTrust.hash(folder: folder)!).inserted, "an added byte in \(name) changes the hash")
            write(originals)
        }
        expect(ScriptTrust.hash(folder: folder), base, "back to the originals, back to the hash")
        // Moving a byte between files must not go unnoticed: the names and lengths are in the hash.
        write(["manifest.json": Data("{\"id\":\"x\"}s".utf8), "main.js": Data("ay(1);".utf8)])
        check(ScriptTrust.hash(folder: folder) != base, "the same bytes split another way")
        write(originals)
        // signature.json and tests/ do not count.
        try? "{\"anything\":1}".write(to: folder.appendingPathComponent("signature.json"), atomically: true, encoding: .utf8)
        try? fm.createDirectory(at: folder.appendingPathComponent("tests/script"), withIntermediateDirectories: true)
        try? "{}".write(to: folder.appendingPathComponent("tests/script/a.json"), atomically: true, encoding: .utf8)
        expect(ScriptTrust.hash(folder: folder), base, "signature.json and tests/ are not counted")
    }
    test("script trust: a loaded plugin's hash is the folder's") {
        let folder = temp(); defer { try? fm.removeItem(at: folder) }
        plugin(in: folder)
        let loaded = ProfileStore.load(folder: folder)
        expect(loaded.error, nil, "loads")
        expect(loaded.scriptHash, ScriptTrust.hash(folder: folder), "the hash taken at load")
    }
    test("script trust: a receipt allows its script, still after a restart, and a changed file refuses") {
        let folder = temp(), dir = temp(); defer { try? fm.removeItem(at: folder); try? fm.removeItem(at: dir) }
        plugin(in: folder)
        let file = dir.appendingPathComponent("plugin-trust.json")
        let trust = store(file)
        let loaded = ProfileStore.load(folder: folder)
        expect(trust.decision(for: loaded), .refused(.neverApproved), "before approval")
        try? trust.approve(loaded, origin: .file, signer: "1234 5678 9abc def0")
        expect(trust.decision(for: loaded), .allowed, "after approval")
        let receipt = trust.receipt(for: "script-test")
        expect(receipt?.hash, loaded.scriptHash, "the receipt holds the hash")
        expect(receipt?.apps, ["com.example.app"], "its apps")
        expect(receipt?.abilities, ["read", "say"], "its abilities")
        expect(receipt?.origin, .file, "where it came from")
        expect(receipt?.signer, "1234 5678 9abc def0", "the signing key")
        check(receipt.map { abs($0.approved.timeIntervalSinceNow) < 60 } ?? false, "when it was approved")
        expect(store(file).decision(for: loaded), .allowed, "a new run of TurnOver, the same file and key")
        plugin(in: folder, script: scriptTestSource + "// changed\n")
        expect(trust.decision(for: ProfileStore.load(folder: folder)), .refused(.filesChanged), "a changed script")
        plugin(in: folder)
        plugin(in: folder, abilities: "[\"read\", \"say\", \"press\"]")
        expect(trust.decision(for: ProfileStore.load(folder: folder)), .refused(.filesChanged), "a manifest that asks for more is a changed file")
        expect(trust.decision(id: "another", hash: loaded.scriptHash!, apps: [], abilities: []), .refused(.neverApproved), "another plugin")
    }
    test("script trust: approving again replaces the receipt") {
        let dir = temp(); defer { try? fm.removeItem(at: dir) }
        let trust = store(dir.appendingPathComponent("t.json"))
        try? trust.approve(id: "a", hash: "1", apps: ["x"], abilities: [.say], origin: .file)
        try? trust.approve(id: "a", hash: "2", apps: ["x"], abilities: [.say], origin: .file)
        expect(trust.receipts.count, 1, "one receipt")
        expect(trust.decision(id: "a", hash: "2", apps: ["x"], abilities: [.say]), .allowed, "the new hash")
        expect(trust.decision(id: "a", hash: "1", apps: ["x"], abilities: [.say]), .refused(.filesChanged), "not the old")
    }
    test("script trust: a missing, forged, edited or foreign trust file is treated as empty") {
        let dir = temp(); defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("plugin-trust.json")
        expect(store(file).receipts.count, 0, "a missing file is empty")
        let trust = store(file)
        try? trust.approve(id: "a", hash: "abc", apps: ["x"], abilities: [.say], origin: .file)
        expect(store(file).receipts.count, 1, "the real file is read")
        let good = try! Data(contentsOf: file)
        // Edited: another hash, the seal as it was.
        try? Data(String(decoding: good, as: UTF8.self).replacingOccurrences(of: "abc", with: "abd").utf8).write(to: file)
        expect(store(file).receipts.count, 0, "an edited receipt")
        // Edited: developer mode switched on by hand.
        try? Data(String(decoding: good, as: UTF8.self).replacingOccurrences(of: "\"developerMode\" : false", with: "\"developerMode\" : true").utf8).write(to: file)
        let flipped = store(file)
        expect(flipped.receipts.count, 0, "a flipped switch voids the file")
        expect(flipped.developerMode, false, "and developer mode is off")
        // Forged: a whole file sealed with some other key.
        try? fm.removeItem(at: file)
        let forger = ScriptTrustStore(file: file, inMemoryKey: Data(repeating: 9, count: 32))
        try? forger.approve(id: "evil", hash: "f", apps: ["x"], abilities: [.keys], origin: .library)
        expect(store(file).receipts.count, 0, "a file sealed with another key")
        expect(store(file).decision(id: "evil", hash: "f", apps: ["x"], abilities: [.keys]), .refused(.neverApproved), "so nothing it holds allows a script")
        // Garbage, empty, and a seal that is not a seal.
        for junk in ["", "not json", "[]", "{\"receipts\":[],\"seal\":5}", "{\"seal\":\"AAAA\"}"] {
            try? junk.write(to: file, atomically: true, encoding: .utf8)
            expect(store(file).receipts.count, 0, "junk \(junk)")
        }
        // No key at all (the Keychain item is gone): nothing can be checked.
        try? fm.removeItem(at: file)
        try? store(file).approve(id: "a", hash: "abc", apps: [], abilities: [], origin: .file)
        expect(ScriptTrustStore(file: file, inMemoryKey: nil).receipts.count, 0, "no key to check against")
        // Deleting the file voids every approval but forges none.
        try? fm.removeItem(at: file)
        expect(store(file).receipts.count, 0, "a deleted file")
    }
    test("script trust: developer mode lets a changed draft run while its apps and abilities have not grown") {
        let dir = temp(); defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("t.json")
        let trust = store(file)
        try? trust.approve(id: "d", hash: "one", apps: ["a", "b"], abilities: [.read, .say], origin: .draft)
        expect(trust.developerMode, false, "off to begin with")
        expect(trust.decision(id: "d", hash: "two", apps: ["a", "b"], abilities: [.read, .say]), .refused(.filesChanged), "off: a changed draft is refused")
        try? trust.setDeveloperMode(true)
        expect(trust.decision(id: "d", hash: "two", apps: ["a", "b"], abilities: [.read, .say]), .allowed, "on: the same apps and abilities")
        expect(trust.decision(id: "d", hash: "two", apps: ["a"], abilities: [.say]), .allowed, "on: fewer is within")
        expect(trust.decision(id: "d", hash: "two", apps: ["a", "b"], abilities: [.read, .say, .press]), .refused(.abilitiesGrew), "on: an ability grew")
        expect(trust.decision(id: "d", hash: "two", apps: ["a", "b", "c"], abilities: [.read, .say]), .refused(.appsGrew), "on: an app grew")
        expect(trust.decision(id: "never", hash: "two", apps: ["a"], abilities: [.say]), .refused(.neverApproved), "on: never approved is still refused")
        try? trust.approve(id: "f", hash: "one", apps: ["a"], abilities: [.say], origin: .file)
        expect(trust.decision(id: "f", hash: "two", apps: ["a"], abilities: [.say]), .refused(.filesChanged), "on: a script that did not come from a draft is not forgiven")
        try? trust.approve(id: "l", hash: "one", apps: ["a"], abilities: [.say], origin: .library)
        expect(trust.decision(id: "l", hash: "two", apps: ["a"], abilities: [.say]), .refused(.filesChanged), "on: nor one from the library")
        expect(store(file).developerMode, true, "the switch is kept in the sealed file")
        try? trust.setDeveloperMode(false)
        expect(store(file).developerMode, false, "and switched off")
        expect(trust.decision(id: "d", hash: "two", apps: ["a", "b"], abilities: [.read, .say]), .refused(.filesChanged), "off again")
    }
    test("script trust: revoking takes the approval away, and keeps it away") {
        let dir = temp(); defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("t.json")
        let trust = store(file)
        try? trust.approve(id: "a", hash: "h", apps: ["x"], abilities: [.say], origin: .file)
        try? trust.approve(id: "b", hash: "h", apps: ["x"], abilities: [.say], origin: .file)
        try? trust.revoke(id: "a")
        expect(trust.decision(id: "a", hash: "h", apps: ["x"], abilities: [.say]), .refused(.neverApproved), "revoked")
        expect(trust.decision(id: "b", hash: "h", apps: ["x"], abilities: [.say]), .allowed, "the other stays")
        expect(store(file).receipts.map(\.id), ["b"], "revoked in the file too")
        try? trust.revoke(id: "nothing")
        expect(trust.receipts.count, 1, "revoking what is not there changes nothing")
    }
    test("script trust: a store whose file cannot be written says so and keeps what it had") {
        let dir = temp(); defer { try? fm.removeItem(at: dir) }
        let blocker = dir.appendingPathComponent("blocker")
        try? "x".write(to: blocker, atomically: true, encoding: .utf8)
        let trust = store(blocker.appendingPathComponent("t.json"))   // a folder that is a file
        var failed = false
        do { try trust.approve(id: "a", hash: "h", apps: [], abilities: [], origin: .file) } catch { failed = true }
        check(failed, "approve throws")
        expect(trust.receipts.count, 0, "and nothing is remembered that was not kept")
    }
    test("script trust: a good signature verifies with its key's fingerprint") {
        let folder = temp(); defer { try? fm.removeItem(at: folder) }
        plugin(in: folder)
        let key = Curve25519.Signing.PrivateKey()
        let digest = ScriptTrust.digest(folder: folder)!
        let signature = try! ScriptTrust.sign(digest: digest, with: key)
        try? ScriptTrust.writeSignature(signature, to: folder)
        let expected = SHA256.hash(data: key.publicKey.rawRepresentation).map { String(format: "%02x", $0) }.joined().prefix(16)
        let grouped = stride(from: 0, to: 16, by: 4).map { i -> String in let a = expected.index(expected.startIndex, offsetBy: i); return String(expected[a..<expected.index(a, offsetBy: 4)]) }.joined(separator: " ")
        expect(ScriptTrust.signatureStatus(in: folder), .valid(fingerprint: grouped), "valid, with the fingerprint")
        check(grouped.range(of: #"^[0-9a-f]{4}( [0-9a-f]{4}){3}$"#, options: .regularExpression) != nil, "groups of four: \(grouped)")
        expect(ScriptTrust.readSignature(in: folder), signature, "signature.json reads back")
        expect(ScriptTrust.hash(folder: folder), ScriptTrust.hex(digest), "writing the signature did not change the hash")
        // Approving keeps the fingerprint of a valid signature in the receipt.
        let dir = temp(); defer { try? fm.removeItem(at: dir) }
        let trust = store(dir.appendingPathComponent("t.json"))
        let loaded = ProfileStore.load(folder: folder)
        if case .valid(let fingerprint) = ScriptTrust.signatureStatus(in: folder) { try? trust.approve(loaded, origin: .file, signer: fingerprint) }
        expect(trust.receipt(for: "script-test")?.signer, grouped, "the receipt knows who signed")
    }
    test("script trust: a changed file, a wrong key or a damaged signature does not verify") {
        let folder = temp(); defer { try? fm.removeItem(at: folder) }
        plugin(in: folder)
        let key = Curve25519.Signing.PrivateKey()
        expect(ScriptTrust.signatureStatus(in: folder), .none, "not signed")
        try? ScriptTrust.writeSignature(try! ScriptTrust.sign(digest: ScriptTrust.digest(folder: folder)!, with: key), to: folder)
        plugin(in: folder, script: scriptTestSource + " ")
        if case .invalid(let why) = ScriptTrust.signatureStatus(in: folder) { check(why.contains("changed after it was signed"), why) } else { check(false, "a changed file verified") }
        plugin(in: folder)
        expect(ScriptTrust.signatureStatus(in: folder).isValid, true, "put back, it verifies again")
        // Signed by one key, claiming another's: the public key in the file is not the signer's.
        let other = Curve25519.Signing.PrivateKey()
        var forged = try! ScriptTrust.sign(digest: ScriptTrust.digest(folder: folder)!, with: key)
        forged.key = other.publicKey.rawRepresentation.base64EncodedString()
        try? ScriptTrust.writeSignature(forged, to: folder)
        expect(ScriptTrust.signatureStatus(in: folder).isValid, false, "a wrong key")
        // Signed over something else.
        let elsewhere = try! ScriptTrust.sign(digest: Data(repeating: 1, count: 32), with: key)
        try? ScriptTrust.writeSignature(elsewhere, to: folder)
        expect(ScriptTrust.signatureStatus(in: folder).isValid, false, "a signature for other files")
        // Damaged.
        try? "{ not a signature".write(to: folder.appendingPathComponent("signature.json"), atomically: true, encoding: .utf8)
        expect(ScriptTrust.signatureStatus(in: folder).isValid, false, "damaged")
        try? ScriptTrust.writeSignature(ScriptTrust.Signature(key: "!!", signature: "!!"), to: folder)
        expect(ScriptTrust.signatureStatus(in: folder).isValid, false, "not base64")
    }
    test("script trust: a signature is checked against the hash of the files that were loaded, not the folder as it is now") {
        let folder = temp(); defer { try? fm.removeItem(at: folder) }
        plugin(in: folder)
        let first = Curve25519.Signing.PrivateKey(), second = Curve25519.Signing.PrivateKey()
        try? ScriptTrust.writeSignature(try! ScriptTrust.sign(digest: ScriptTrust.digest(folder: folder)!, with: first), to: folder)
        let loaded = ProfileStore.load(folder: folder)
        let firstPrint = ScriptTrust.fingerprint(ofPublicKey: first.publicKey.rawRepresentation)
        expect(ScriptTrust.signatureStatus(in: folder, loadedHash: loaded.scriptHash), .valid(fingerprint: firstPrint), "as loaded, it is signed by the first key")
        // Another version, signed by another key, is put in the folder after the load.
        plugin(in: folder, script: scriptTestSource + "// another\n")
        try? ScriptTrust.writeSignature(try! ScriptTrust.sign(digest: ScriptTrust.digest(folder: folder)!, with: second), to: folder)
        expect(ScriptTrust.signatureStatus(in: folder).isValid, true, "the folder as it is now is validly signed (by the second key)")
        expect(ScriptTrust.signatureStatus(in: folder, loadedHash: loaded.scriptHash).isValid, false, "but the files that were loaded are not signed by it")
        expect(ScriptTrust.signatureStatus(in: folder, loadedHash: nil).isValid, false, "no hash, no signer")
        expect(ScriptTrust.signatureStatus(in: folder, loadedHash: "not hex").isValid, false, "nor a hash that is not one")
        try? fm.removeItem(at: folder.appendingPathComponent("signature.json"))
        expect(ScriptTrust.signatureStatus(in: folder, loadedHash: loaded.scriptHash), .none, "and no signature is none")
    }
    test("script trust: the author's key is made once, readable only by its author") {
        let dir = temp(); defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent(".turnover-plugin/author.key")
        let first = try! ScriptAuthorKey.generate(at: url)
        let mode = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0
        expect(mode & 0o777, 0o600, "the key's permissions")
        let folderMode = (try? fm.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int) ?? 0
        expect(folderMode & 0o077, 0, "its folder is closed to others")
        expect((try? ScriptAuthorKey.load(from: url))?.publicKey.rawRepresentation, first.publicKey.rawRepresentation, "it reads back")
        var refused = false
        do { _ = try ScriptAuthorKey.generate(at: url) } catch { refused = true }
        check(refused, "a second keygen refuses")
        expect((try? ScriptAuthorKey.load(from: url))?.publicKey.rawRepresentation, first.publicKey.rawRepresentation, "and the key is still the first")
        let second = try! ScriptAuthorKey.generate(at: url, force: true)
        check(second.publicKey.rawRepresentation != first.publicKey.rawRepresentation, "--force makes a new one")
        expect((try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int ?? 0)! & 0o777, 0o600, "still 0600")
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        var open = false
        do { _ = try ScriptAuthorKey.load(from: url) } catch { open = true }
        check(open, "a key others can read is not used")
        var missing = false
        do { _ = try ScriptAuthorKey.load(from: dir.appendingPathComponent("none")) } catch { missing = true }
        check(missing, "a missing key is an error in words")
    }
}

extension ScriptTrust.SignatureStatus {
    var isValid: Bool { if case .valid = self { return true }; return false }
}
