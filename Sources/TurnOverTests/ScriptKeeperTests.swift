// SPDX-License-Identifier: GPL-3.0-or-later
// The keeper and the two faults found when stage 2 was reviewed (docs/PLUGIN-SCRIPTS-PLAN.md, "The keeper"; stage 4,
// 15 Nov 2026). Nothing here uses XPC, the real keeper, the Keychain, the real support folder, the real plugins folder or
// the home folder: folders are temporary and the holders are in memory.
import Foundation
import CryptoKit
import TurnOverCore
import TurnOverPluginWire

/// A holder that keeps its bytes in memory and, if told, fails: what a keeper that cannot be reached looks like.
private final class MemoryHolder: ScriptTrustHolder {
    var kind = "memory (a test)"
    var bytes: Data?
    var failure: String?
    var loads = 0, stores = 0
    func load() throws -> Data? {
        loads += 1
        if let failure { throw ScriptTrustStore.WriteFailure(description: failure) }
        return bytes
    }
    func store(_ data: Data) throws {
        stores += 1
        if let failure { throw ScriptTrustStore.WriteFailure(description: failure) }
        bytes = data
    }
}

func scriptKeeperTests() {
    let fm = FileManager.default
    var cleanup: [URL] = []
    func temp() -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("turnover-keeper-test-\(UUID().uuidString)")
        cleanup.append(url)
        return url   // not made: the keeper makes its own folder
    }
    func made() -> URL { let url = temp(); try? fm.createDirectory(at: url, withIntermediateDirectories: true); return url }
    defer { cleanup.forEach { try? fm.removeItem(at: $0) } }
    /// What the keeper holds; nil for nothing stored (a failure to load is a failed check of its own).
    func loaded(_ keeper: TrustKeeperStore) -> Data? {
        do { return try keeper.load() } catch { check(false, "load failed: \(error)"); return nil }
    }
    func mode(_ url: URL) -> Int? { (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int }

    // MARK: The keeper's file

    test("script keeper: what is stored is loaded again, byte for byte, and the folder is made if missing") {
        let folder = temp()
        let keeper = TrustKeeperStore(folder: folder)
        expect(loaded(keeper), nil, "nothing stored yet")
        let bytes = Data("{\"format\":1}".utf8) + Data([0, 255, 10])
        do { try keeper.store(bytes) } catch { check(false, "store: \(error)") }
        check(fm.fileExists(atPath: folder.path), "the missing folder was made")
        expect(loaded(keeper), bytes, "the same bytes")
        expect(try? Data(contentsOf: folder.appendingPathComponent("plugin-trust.json")), bytes, "in plugin-trust.json")
        do { try keeper.store(Data("second".utf8)) } catch { check(false, "store again: \(error)") }
        expect(loaded(keeper), Data("second".utf8), "a later store replaces it whole")
    }
    test("script keeper: more than 1 MB is refused and the old file is kept") {
        let keeper = TrustKeeperStore(folder: made())
        try? keeper.store(Data("old".utf8))
        expect(TrustKeeperStore.maximumBytes, 1_048_576, "the limit is 1 MB")
        do { try keeper.store(Data(count: 1_048_577)); check(false, "a byte over was accepted") } catch { check(error is TrustKeeperFailure, "a reason is given: \(error)") }
        expect(loaded(keeper), Data("old".utf8), "the old file is kept")
        do { try keeper.store(Data(count: 1_048_576)) } catch { check(false, "exactly 1 MB is allowed: \(error)") }
        expect(loaded(keeper)?.count, 1_048_576, "and kept")
    }
    test("script keeper: the check leaves the real file alone and leaves no probe behind") {
        let folder = made()
        let keeper = TrustKeeperStore(folder: folder)
        expect(keeper.check(), "ok", "a good folder")
        expect((try? fm.contentsOfDirectory(atPath: folder.path)) ?? ["?"], [], "no real file made and no probe left")
        try? keeper.store(Data("real".utf8))
        expect(keeper.check(), "ok", "with a real file there")
        expect(try? Data(contentsOf: folder.appendingPathComponent("plugin-trust.json")), Data("real".utf8), "the real file is untouched")
        expect((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [], ["plugin-trust.json"], "nothing else is left")
        let blocked = made().appendingPathComponent("a-file-where-the-folder-should-be")
        try? Data("x".utf8).write(to: blocked)
        check(TrustKeeperStore(folder: blocked).check() != "ok", "a folder that cannot be used says why instead of ok")
        do { try TrustKeeperStore(folder: blocked).store(Data("x".utf8)); check(false, "stored into a file") } catch { check(error is TrustKeeperFailure, "store says why") }
    }
    test("script keeper: it is sandboxed only inside a container with the container's name set") {
        let home = "/Users/someone/Library/Containers/com.turnover.reader.trust-keeper/Data"
        check(TrustKeeperStore.isSandboxed(home: home, environment: ["APP_SANDBOX_CONTAINER_ID": "com.turnover.reader.trust-keeper"]), "a container and its name")
        check(!TrustKeeperStore.isSandboxed(home: home, environment: [:]), "no container name")
        check(!TrustKeeperStore.isSandboxed(home: home, environment: ["APP_SANDBOX_CONTAINER_ID": ""]), "an empty container name")
        check(!TrustKeeperStore.isSandboxed(home: "/Users/someone", environment: ["APP_SANDBOX_CONTAINER_ID": "x"]), "a home outside any container")
    }

    // MARK: Who the keeper answers

    test("script keeper: the requirement text is made for a good identifier and team, and refused for any other") {
        expect(CodeIdentity.requirement(identifier: "com.turnover.reader.trust-keeper", team: "AV65T28PQ7"),
               "anchor apple generic and identifier \"com.turnover.reader.trust-keeper\" and certificate leaf[subject.OU] = \"AV65T28PQ7\"", "the text")
        for bad in ["", "a\"b", "a b", "a;b", "a\nb", "é.app", "com.x\" or true or identifier \"y", "a/b", "a)b"] {
            expect(CodeIdentity.requirement(identifier: bad, team: "AV65T28PQ7"), nil, "identifier \(bad.debugDescription)")
        }
        for bad in ["", "av65t28pq7", "AV65T28PQ", "AV65T28PQ77", "AV65T28PQ\"", "AV65 28PQ7", "AV65T28PQé", "AV65T28PQ7\" or true"] {
            expect(CodeIdentity.requirement(identifier: "com.turnover.reader", team: bad), nil, "team \(bad.debugDescription)")
        }
    }
    test("script keeper: a program with no team of its own does not connect, and says why") {
        let client = TrustKeeperClient(bundleIdentifier: "com.turnover.reader", team: nil)
        for result in [client.check()] {
            if case .failure(let why) = result { check(!why.reason.isEmpty, "a reason is given") } else { check(false, "it connected with no team") }
        }
        if case .success = client.load() { check(false, "load answered with no team") }
        if case .success = client.store(Data("x".utf8)) { check(false, "store answered with no team") }
        if case .success = TrustKeeperClient(bundleIdentifier: nil, team: "AV65T28PQ7").check() { check(false, "it connected with no bundle identifier") }
        if case .success = TrustKeeperClient(bundleIdentifier: "bad\"id", team: "AV65T28PQ7").check() { check(false, "it connected with an identifier that cannot be put in a requirement") }
    }

    // MARK: The store over a holder

    test("script keeper: a holder that cannot be used leaves the store empty, and approving, revoking and developer mode throw") {
        let holder = MemoryHolder()
        holder.failure = "the keeper did not answer within two seconds"
        let trust = ScriptTrustStore(holder: holder)
        expect(trust.receipts.count, 0, "empty")
        expect(trust.developerMode, false, "developer mode off")
        check(trust.unavailable != nil, "the store knows it is unavailable")
        do { try trust.approve(id: "a", hash: "h", apps: ["x"], abilities: [.say], origin: .file); check(false, "approve went through") }
        catch { check(!"\(error)".isEmpty, "approve throws with words: \(error)") }
        expect(trust.receipts.count, 0, "nothing was approved")
        do { try trust.revoke(id: "a"); check(false, "revoke went through") } catch { }
        do { try trust.setDeveloperMode(true); check(false, "developer mode went through") } catch { }
        expect(trust.developerMode, false, "developer mode stayed off")
        expect(holder.stores, 0, "nothing was written to a holder that could not be read (it would have replaced what it holds)")
        expect(trust.decision(id: "a", hash: "h", apps: ["x"], abilities: [.say]), .refused(.neverApproved), "no script is allowed")
        trust.reload()
        expect(holder.loads, 2, "a reload asks again")
        holder.failure = nil
        trust.reload()
        check(trust.unavailable == nil, "usable again once the holder answers")
        do { try trust.approve(id: "a", hash: "h", apps: ["x"], abilities: [.say], origin: .file) } catch { check(false, "approve after: \(error)") }
        expect(trust.receipts.count, 1, "and then it works")
    }
    test("script keeper: a holder that answers keeps the same JSON with no seal, and a new store reads it back") {
        let holder = MemoryHolder()
        let trust = ScriptTrustStore(holder: holder)
        try? trust.approve(id: "a", hash: "abc", apps: ["x"], abilities: [.read], origin: .library, signer: "1234")
        try? trust.setDeveloperMode(true)
        let text = String(decoding: holder.bytes ?? Data(), as: UTF8.self)
        check(text.contains("\"receipts\"") && text.contains("\"developerMode\":true") && text.contains("\"abc\""), "the receipts and the switch: \(text)")
        check(!text.contains("seal"), "no seal: the keeper is what keeps it safe")
        let again = ScriptTrustStore(holder: holder)
        expect(again.receipts.map(\.id), ["a"], "read back")
        expect(again.developerMode, true, "with the switch")
        holder.bytes = Data("not json".utf8)
        expect(ScriptTrustStore(holder: holder).receipts.count, 0, "bytes that are not the format read as empty")
        holder.bytes = Data("{\"format\":2,\"developerMode\":false,\"receipts\":[]}".utf8)
        expect(ScriptTrustStore(holder: holder).receipts.count, 0, "another format reads as empty")
    }

    // MARK: Stage 2's faults

    test("script keeper: a loaded plugin's hash is of exactly the bytes it was parsed from, even if the files change during the load") {
        let folder = made()
        let manifest = Data(scriptManifestText(["id": "\"parsed-id\""]).utf8), profile = Data("{}".utf8), script = Data(scriptTestSource.utf8)
        func write(_ name: String, _ data: Data) { try? data.write(to: folder.appendingPathComponent(name)) }
        write("manifest.json", manifest); write("profile.json", profile); write("main.js", script)
        var reads: [String: Int] = [:]
        let plugin = ProfileStore.load(folder: folder, read: { url in
            let name = url.lastPathComponent
            reads[name, default: 0] += 1
            let data = try? Data(contentsOf: url)
            // The moment after each read, an attacker swaps the file for another.
            write(name, Data("changed after it was read: \(name)\n".utf8))
            return data
        })
        expect(plugin.error, nil, "it loads from the bytes it read")
        expect(plugin.manifest?.id, "parsed-id", "parsed from what was read")
        expect(plugin.script, scriptTestSource, "the script text is what was read")
        expect(reads, ["manifest.json": 1, "profile.json": 1, "main.js": 1], "each counted file is read once")
        let expected = ScriptTrust.hex(ScriptTrust.digest(files: [("manifest.json", manifest), ("profile.json", profile), ("main.js", script)]))
        expect(plugin.scriptHash, expected, "the hash is of the bytes parsed")
        check(ScriptTrust.hash(folder: folder) != expected, "and not of what is on disk now")
    }
    test("script keeper: a plugin read through the seam with no profile is hashed without one") {
        let folder = made()
        let manifest = Data(scriptManifestText().utf8), script = Data(scriptTestSource.utf8)
        try? manifest.write(to: folder.appendingPathComponent("manifest.json")); try? script.write(to: folder.appendingPathComponent("main.js"))
        let plugin = ProfileStore.load(folder: folder)
        expect(plugin.error, nil, "loads")
        expect(plugin.scriptHash, ScriptTrust.hex(ScriptTrust.digest(files: [("manifest.json", manifest), ("main.js", script)])), "the hash counts only what is there")
        expect(plugin.scriptHash, ScriptTrust.hash(folder: folder), "as it always did")
    }
    test("script keeper: the author's key and the sealing key are made readable by the owner alone, whatever the umask") {
        let old = umask(0)   // the widest the umask can be: the file must be 0600 anyway
        defer { umask(old) }
        let folder = made()
        let keyURL = folder.appendingPathComponent("keys/author.key")
        do { _ = try ScriptAuthorKey.generate(at: keyURL) } catch { check(false, "generate: \(error)") }
        expect(mode(keyURL), 0o600, "the author's key")
        expect(mode(keyURL.deletingLastPathComponent()), 0o700, "its folder")
        do { _ = try ScriptAuthorKey.generate(at: keyURL); check(false, "a key was replaced without --force") } catch { }
        do { _ = try ScriptAuthorKey.generate(at: keyURL, force: true) } catch { check(false, "force: \(error)") }
        expect(mode(keyURL), 0o600, "a forced new key")
        check((try? ScriptAuthorKey.load(from: keyURL)) != nil, "and it can be read back")
        let sealURL = folder.appendingPathComponent("plugin-trust.key")
        let seal = FileSealKey(url: sealURL)
        check(seal.existingKey() == nil, "no key yet")
        check(seal.makeKey() != nil, "a sealing key is made")
        expect(mode(sealURL), 0o600, "the sealing key's file")
        check(seal.existingKey() != nil, "and read back")
        // A file or link already there is never followed.
        let target = folder.appendingPathComponent("target"), link = folder.appendingPathComponent("link.key")
        try? Data("keep".utf8).write(to: target)
        try? fm.createSymbolicLink(at: link, withDestinationURL: target)
        _ = FileSealKey(url: link).makeKey()
        expect(try? Data(contentsOf: target), Data("keep".utf8), "a link in the key's place was not written through")
    }

    // MARK: The fix pass after the independent review (16 Nov 2026)

    test("script keeper: a revocation that cannot be kept lets go of every approval for the run, and so does turning developer mode off") {
        let holder = MemoryHolder()
        let trust = ScriptTrustStore(holder: holder)
        try? trust.approve(id: "a", hash: "h", apps: ["x"], abilities: [.say], origin: .file)
        try? trust.approve(id: "b", hash: "h2", apps: ["x"], abilities: [.say], origin: .file)
        holder.failure = "the keeper did not answer"
        do { try trust.revoke(id: "a"); check(false, "revoke went through") } catch { }
        expect(trust.receipts.count, 0, "no approval at all is believed after a revocation that could not be kept")
        check(trust.unavailable != nil, "the store is unavailable for the run")
        expect(trust.decision(id: "b", hash: "h2", apps: ["x"], abilities: [.say]), .refused(.neverApproved), "so the other plugin's script is not allowed either")
        do { try trust.approve(id: "c", hash: "h", apps: [], abilities: [], origin: .file); check(false, "approve went through") } catch { }
        // Developer mode: turning it on that cannot be kept just stays off; turning it off that cannot be kept lets go of everything.
        let second = MemoryHolder()
        let dev = ScriptTrustStore(holder: second)
        try? dev.setDeveloperMode(true)
        try? dev.approve(id: "a", hash: "h", apps: ["x"], abilities: [.say], origin: .draft)
        second.failure = "gone"
        do { try dev.setDeveloperMode(false); check(false, "went through") } catch { }
        expect(dev.developerMode, false, "developer mode is off")
        expect(dev.receipts.count, 0, "and nothing approved is believed")
        let failing = MemoryHolder()
        let fresh = ScriptTrustStore(holder: failing)
        failing.failure = "gone"
        do { try fresh.setDeveloperMode(true); check(false, "went through") } catch { }
        expect(fresh.developerMode, false, "turning it on that could not be kept leaves it off")
    }

    test("script keeper: the attacker's client connects to the keeper without a team or a requirement; an ordinary client without a team does not connect") {
        let stranger = TrustKeeperClient(strangerOf: "com.example.app")
        check(stranger.connects, "the stranger connects")
        check(!stranger.requiresKeeperSignature, "and asks nothing of the keeper's own signature")
        let honestNoTeam = TrustKeeperClient(bundleIdentifier: "com.example.app", team: nil)
        check(!honestNoTeam.connects, "an ordinary client with no team of its own refuses itself before asking the keeper anything")
        expect({ if case .failure(let why) = honestNoTeam.check() { return "\(why)".contains("no signing team") } else { return false } }(), true, "saying so, without XPC")
        let honest = TrustKeeperClient(bundleIdentifier: "com.example.app", team: "ABCDE12345")
        check(honest.connects && honest.requiresKeeperSignature, "an ordinary client with a team connects and puts a requirement on the keeper")
        check(!TrustKeeperClient(strangerOf: nil).connects, "the stranger needs an identifier to know whom to ask")
        check(!TrustKeeperClient(strangerOf: "a\" or true").connects, "and a name that could carry text into a requirement is not one")
    }

    test("script keeper: a file read for hashing or a signature is read only up to one byte past its limit") {
        let folder = made()
        let big = folder.appendingPathComponent("big")
        try? Data(repeating: 0x41, count: 5_000_000).write(to: big)
        expect(PluginFormat.readBounded(big, limit: 1000)?.count, 1001, "one byte past the limit and no more")
        expect(PluginFormat.readBounded(folder.appendingPathComponent("missing"), limit: 10), nil, "a missing file is nil")
        try? Data("hi".utf8).write(to: folder.appendingPathComponent("small"))
        expect(PluginFormat.readBounded(folder.appendingPathComponent("small"), limit: 10), Data("hi".utf8), "a small file whole")
        try? Data().write(to: folder.appendingPathComponent("empty"))
        expect(PluginFormat.readBounded(folder.appendingPathComponent("empty"), limit: 10), Data(), "an empty file is empty, not missing")
        // A plugin whose main.js is far past the limit has no hash and does not load, and neither read the file whole.
        try? Data(scriptManifestText().utf8).write(to: folder.appendingPathComponent("manifest.json"))
        try? Data(repeating: 0x20, count: 5_000_000).write(to: folder.appendingPathComponent("main.js"))
        expect(ScriptTrust.hash(folder: folder), nil, "no hash for a script past the limit")
        let loaded = ProfileStore.load(folder: folder)
        check(loaded.error?.contains("larger than 256 KB") == true && loaded.script == nil, "it does not load: \(loaded.error ?? "loaded")")
    }
}
