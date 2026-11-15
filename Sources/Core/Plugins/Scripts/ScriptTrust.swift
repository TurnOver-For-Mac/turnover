// SPDX-License-Identifier: GPL-3.0-or-later
// What makes a plugin's script allowed to run on this Mac (docs/PLUGIN-SCRIPTS-PLAN.md, "Approval", "Signing, the
// library and review", "The format"; 15 Nov 2026):
//
// - the hash of a plugin's files, which an approval and a signature are both for;
// - receipts, kept as one JSON object (the receipts and the developer-mode switch) by a holder. For every build that is
//   not a developer build the holder is the keeper: a sandboxed XPC service inside TurnOver.app that no other program can
//   write through (docs/PLUGIN-SCRIPTS-PLAN.md, "The keeper"). A developer build, whose signature may be ad hoc and so cannot
//   use the keeper, keeps plugin-trust.json in TurnOver's support folder, sealed with an HMAC-SHA256 whose key is in a file
//   beside it with permissions 0600, and says so in the log: weaker, and only on a developer's own Mac. Another program can
//   delete the sealed file (every script then needs approving again) but cannot write a receipt TurnOver will believe
//   without the key, which anything running as the person can read. The Keychain is no longer used (15 Nov 2026);
// - the question the next stage asks: may this plugin's script run?
// - the author's signature (signature.json) over the same hash, and the signing key's fingerprint.
//
// The sealed file (a developer build and the tests). One JSON object: "format", "developerMode", "receipts" and "seal". The seal is the base64 HMAC of the
// object without "seal", written compactly with its keys sorted; the check parses the file, takes "seal" out and writes
// that object the same way, so what is compared is never the file's spacing. A missing file, an unreadable one or a seal
// that does not match is read as empty, and the log says which.
//
// The signature. signature.json is {"format":1,"key":"<base64 public key>","signature":"<base64>"}: an Ed25519
// signature over the 32 raw bytes of the SHA-256 digest (not its hex), so a tool in another language need only hash the
// files and verify.
import Foundation
import CryptoKit
import TurnOverPluginWire

// MARK: - The hash, signatures and the author's key

nonisolated public enum ScriptTrust {
    /// The files that count toward the hash, in this order; `profile.json` only if present. `signature.json` and `tests/` do not.
    public static let countedFiles = ["manifest.json", "profile.json", PluginFormat.scriptName]

    /// The 32-byte SHA-256 of the text `TurnOver plugin 1`, a newline, then for each file its name, a zero byte, its length
    /// in bytes as decimal digits, a zero byte and its bytes.
    public static func digest(files: [(name: String, data: Data)]) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data("TurnOver plugin 1\n".utf8))
        for file in files {
            hasher.update(data: Data(file.name.utf8)); hasher.update(data: Data([0]))
            hasher.update(data: Data(String(file.data.count).utf8)); hasher.update(data: Data([0]))
            hasher.update(data: file.data)
        }
        return Data(hasher.finalize())
    }

    public static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// The counted files of a plugin folder as they are on disk. Nil if manifest.json or main.js cannot be read.
    /// `scriptData` is main.js as the caller already read it (so the hash is of what it loaded).
    static func countedData(in folder: URL, scriptData: Data? = nil) -> [(name: String, data: Data)]? {
        var files: [(name: String, data: Data)] = []
        for name in countedFiles {
            if name == PluginFormat.scriptName, let scriptData { files.append((name, scriptData)); continue }
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else {
                if name == "profile.json" { continue }
                return nil
            }
            files.append((name, data))
        }
        return files
    }

    public static func digest(folder: URL, scriptData: Data? = nil) -> Data? { countedData(in: folder, scriptData: scriptData).map { digest(files: $0) } }
    /// The hash as 64 lowercase hex digits: what a receipt holds and a reviewer records.
    public static func hash(folder: URL, scriptData: Data? = nil) -> String? { digest(folder: folder, scriptData: scriptData).map(hex) }

    // MARK: Signatures

    public struct Signature: Codable, Equatable, Sendable {
        public var format: Int = 1
        /// The author's public key, base64.
        public var key: String
        /// Ed25519 over the digest, base64.
        public var signature: String
        public init(key: String, signature: String) { self.key = key; self.signature = signature }
    }

    public enum SignatureStatus: Equatable, Sendable {
        /// No signature.json.
        case none
        /// Signed, and the signature is good for these files. The key's fingerprint.
        case valid(fingerprint: String)
        /// signature.json is there but is not a good signature for these files.
        case invalid(String)
    }

    /// The first 16 hex digits of the SHA-256 of the public key, in groups of four: what a person can compare by eye
    /// and a receipt keeps.
    public static func fingerprint(ofPublicKey key: Data) -> String {
        let digits = Array(hex(Data(SHA256.hash(data: key))).prefix(16))
        return stride(from: 0, to: 16, by: 4).map { String(digits[$0..<$0 + 4]) }.joined(separator: " ")
    }

    public static func sign(digest: Data, with key: Curve25519.Signing.PrivateKey) throws -> Signature {
        Signature(key: key.publicKey.rawRepresentation.base64EncodedString(), signature: try key.signature(for: digest).base64EncodedString())
    }

    public static func verify(_ signature: Signature, digest: Data) -> SignatureStatus {
        guard let keyData = Data(base64Encoded: signature.key), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let bytes = Data(base64Encoded: signature.signature) else {
            return .invalid(String(localized: "signature.json is not a signature TurnOver can read.", comment: "Said about a plugin's signature file that is damaged"))
        }
        guard key.isValidSignature(bytes, for: digest) else {
            return .invalid(String(localized: "The signature does not match the plugin's files: they changed after it was signed, or it was made with another key.", comment: "Said when a plugin's signature does not fit its files"))
        }
        return .valid(fingerprint: fingerprint(ofPublicKey: keyData))
    }

    public static func readSignature(in folder: URL) -> Signature? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("signature.json")) else { return nil }
        return try? JSONDecoder().decode(Signature.self, from: data)
    }

    /// The status of a folder's signature against its files as they are now.
    public static func signatureStatus(in folder: URL) -> SignatureStatus {
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("signature.json").path) else { return .none }
        guard let signature = readSignature(in: folder) else {
            return .invalid(String(localized: "signature.json is not a signature TurnOver can read.", comment: "Said about a plugin's signature file that is damaged"))
        }
        guard let digest = digest(folder: folder) else {
            return .invalid(String(localized: "The plugin's files cannot be read to check the signature.", comment: "Said when a signature cannot be checked"))
        }
        return verify(signature, digest: digest)
    }

    public static func writeSignature(_ signature: Signature, to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (encoder.encode(signature) + Data("\n".utf8)).write(to: folder.appendingPathComponent("signature.json"), options: .atomic)
    }
}

/// Make a new file that nobody else can ever read: created by open(2) with O_CREAT | O_EXCL and mode 0600 (the umask can only
/// narrow it), so there is no moment when it exists with wider permissions, and a file or link already there is never
/// followed. False, with nothing left behind, if the file exists or cannot be made or written. (Stage 2's review, 15 Nov 2026:
/// the files were created and then narrowed.)
nonisolated func createPrivateFile(at url: URL, contents: Data) -> Bool {
    let descriptor = open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { return false }
    var written = 0
    let ok = contents.withUnsafeBytes { bytes -> Bool in
        while written < bytes.count {
            let n = write(descriptor, bytes.baseAddress! + written, bytes.count - written)
            if n < 0 { if errno == EINTR { continue }; return false }
            written += n
        }
        return true
    }
    let closed = close(descriptor) == 0
    if !(ok && closed) { unlink(url.path); return false }
    return true
}

/// The author's own signing key: a file only they can read (~/.turnover-plugin/author.key), base64 of the private key.
nonisolated public enum ScriptAuthorKey {
    public enum Failure: Error, CustomStringConvertible {
        case exists(String), missing(String), unreadable(String), tooOpen(String)
        public var description: String {
            switch self {
            case .exists(let p): return "\(p) already exists; it is your key, and replacing it would lose it. Use --force to make a new one anyway."
            case .missing(let p): return "There is no key at \(p). Make one with: turnover-plugin keygen"
            case .unreadable(let p): return "The key at \(p) is not a key this tool can read."
            case .tooOpen(let p): return "The key at \(p) can be read by other people on this Mac. Run: chmod 600 \(p)"
            }
        }
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".turnover-plugin/author.key")
    }

    /// Make a key at `url` with permissions 0600 (its folder 0700). Never over an existing key unless `force`.
    public static func generate(at url: URL = defaultURL, force: Bool = false) throws -> Curve25519.Signing.PrivateKey {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            guard force else { throw Failure.exists(url.path) }
            try fm.removeItem(at: url)   // so the new file is made with the right permissions, not the old file's
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let key = Curve25519.Signing.PrivateKey()
        let text = key.rawRepresentation.base64EncodedString() + "\n"
        guard createPrivateFile(at: url, contents: Data(text.utf8)) else { throw Failure.unreadable(url.path) }
        return key
    }

    public static func load(from url: URL = defaultURL) throws -> Curve25519.Signing.PrivateKey {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { throw Failure.missing(url.path) }
        if let mode = attributes[.posixPermissions] as? Int, mode & 0o077 != 0 { throw Failure.tooOpen(url.path) }
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else { throw Failure.unreadable(url.path) }
        return key
    }
}

// MARK: - Receipts

/// Where a script came from when the person approved it. Only a draft may be changed under a developer-mode approval.
nonisolated public enum ScriptOrigin: String, Codable, Sendable, Equatable {
    /// The author's own folder, being worked on.
    case draft
    /// The plugin library (a named person has reviewed this version).
    case library
    /// A folder or file someone else gave this Mac.
    case file
}

nonisolated public struct ScriptReceipt: Codable, Equatable, Sendable {
    public var id: String
    /// The hash of the plugin's files (ScriptTrust.hash), 64 hex digits.
    public var hash: String
    /// The apps and abilities that were agreed to, sorted.
    public var apps: [String]
    public var abilities: [String]
    public var approved: Date
    public var origin: ScriptOrigin
    /// The signing key's fingerprint, if the plugin was signed.
    public var signer: String?
}

nonisolated public enum ScriptTrustReason: Equatable, Sendable {
    case neverApproved, filesChanged, abilitiesGrew, appsGrew

    public var words: String {
        switch self {
        case .neverApproved: return String(localized: "This script has not been approved on this Mac.", comment: "Why a plugin's script does not run")
        case .filesChanged: return String(localized: "The plugin's files changed since you approved its script.", comment: "Why a plugin's script does not run")
        case .abilitiesGrew: return String(localized: "The plugin now asks for more than you approved.", comment: "Why a plugin's script does not run: it wants more abilities than were agreed to")
        case .appsGrew: return String(localized: "The plugin now works in more apps than you approved.", comment: "Why a plugin's script does not run: it names more apps than were agreed to")
        }
    }
}

nonisolated public enum ScriptTrustDecision: Equatable, Sendable {
    case allowed
    case refused(ScriptTrustReason)
    public var isAllowed: Bool { self == .allowed }
}

// MARK: - Where the receipts are kept

/// What keeps the receipts' bytes. Two kinds: the sealed file with its key (a developer build, and the tests), and the keeper
/// (every other build). The store above it keeps the JSON; the holder only keeps bytes safe. Failures are `WriteFailure`s whose
/// words can be told to a person.
package protocol ScriptTrustHolder: AnyObject {
    /// What the log says about where the receipts are kept.
    var kind: String { get }
    /// The kept bytes. Nil when there are none, or when what is there cannot be believed: both mean no script is approved.
    /// Throws when the holder cannot be asked or refuses: the store is then unusable for this run.
    func load() throws -> Data?
    /// Keep these bytes whole in place of the others.
    func store(_ data: Data) throws
}

/// The keeper, through its client: the same JSON, without a seal. Never falls back to a file.
final class KeeperHolder: ScriptTrustHolder {
    let kind = "the keeper"
    private let client: TrustKeeperClient
    init(client: TrustKeeperClient = TrustKeeperClient()) { self.client = client }

    private func failure(_ why: TrustKeeperFailure) -> ScriptTrustStore.WriteFailure {
        ScriptTrustStore.WriteFailure(description: String(localized: "TurnOver's keeper of approvals cannot be used, so no script can be approved or taken back in this run. The rest of TurnOver works as usual. (\(why.reason))",
                                                          comment: "Said when the part of TurnOver that keeps plugin script approvals cannot be reached; the reason in brackets is technical"))
    }
    func load() throws -> Data? {
        switch client.load() { case .success(let data): return data; case .failure(let why): throw failure(why) }
    }
    func store(_ data: Data) throws {
        if case .failure(let why) = client.store(data) { throw failure(why) }
    }
}

/// `turnover --check-trust-keeper` and build.sh: the keeper's own check, without starting anything else of TurnOver.
public enum ScriptTrustKeeperCheck {
    /// Nil if the keeper said ok, otherwise why not.
    public static func run() -> String? {
        if case .failure(let why) = TrustKeeperClient().check() { return why.reason }
        return nil
    }
}

/// The sealing key of a sealed file. Two kinds below; the holder asks for an existing key to check a file, and makes one only
/// when it first has something to write.
package protocol ScriptSealKeyStore: AnyObject {
    /// What the log says about where the key is kept.
    var kind: String { get }
    func existingKey() -> SymmetricKey?
    func makeKey() -> SymmetricKey?
}

/// A file beside the trust file, permissions 0600: for a developer build, whose signature may be ad hoc and changes with
/// each build. Weaker (anything running as the person can read it), and logged.
package final class FileSealKey: ScriptSealKeyStore {
    package let kind = "a file beside it (a developer build: weaker than the keeper)"
    private let url: URL
    package init(url: URL) { self.url = url }
    package func existingKey() -> SymmetricKey? {
        guard let data = try? Data(contentsOf: url), data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }
    package func makeKey() -> SymmetricKey? {
        let key = SymmetricKey(size: .bits256)
        try? FileManager.default.removeItem(at: url)
        guard createPrivateFile(at: url, contents: key.withUnsafeBytes { Data($0) }) else { return nil }
        Log.warning("plugin trust: the sealing key is kept in a file, not the keeper (a developer build); this is weaker and only for a developer's own Mac")
        return key
    }
}

/// For tests: never touches a file.
final class MemorySealKey: ScriptSealKeyStore {
    let kind = "memory (a test)"
    private var key: SymmetricKey?
    init(key: SymmetricKey? = nil) { self.key = key }
    func existingKey() -> SymmetricKey? { key }
    func makeKey() -> SymmetricKey? { key = SymmetricKey(size: .bits256); return key }
}

/// The sealed file: the JSON with an HMAC-SHA256 seal added, in `file`. Anything wrong with it reads as nothing kept, and the
/// log says which.
final class SealedFileHolder: ScriptTrustHolder {
    private let file: URL
    private let keys: ScriptSealKeyStore
    var kind: String { "the sealed file \(ScriptTrustStore.fileName)" }
    init(file: URL, keys: ScriptSealKeyStore) { self.file = file; self.keys = keys }

    /// The bytes the seal covers: the file's object without its seal, compact, keys sorted.
    private static func canonical(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    func load() throws -> Data? {
        let name = ScriptTrustStore.fileName
        guard FileManager.default.fileExists(atPath: file.path) else { Log.info("plugin trust: no \(name) yet; no script is approved"); return nil }
        func distrust(_ why: String) -> Data? { Log.warning("plugin trust: \(name) \(why); it is read as empty, so every script needs approving again"); return nil }
        guard let data = try? Data(contentsOf: file) else { return distrust("cannot be read") }
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let seal = object.removeValue(forKey: "seal") as? String,
              let sealBytes = Data(base64Encoded: seal), let body = Self.canonical(object) else { return distrust("is not a sealed file") }
        guard let key = keys.existingKey() else { return distrust("has no sealing key to check it against (kept in \(keys.kind))") }
        guard HMAC<SHA256>.isValidAuthenticationCode(sealBytes, authenticating: body, using: key) else { return distrust("does not match its seal (edited, or made by another copy of TurnOver)") }
        return body
    }

    func store(_ data: Data) throws {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let body = Self.canonical(object) else {
            throw ScriptTrustStore.WriteFailure(description: "the receipts could not be written")
        }
        guard let key = keys.existingKey() ?? keys.makeKey() else { throw ScriptTrustStore.WriteFailure(description: "the sealing key in \(keys.kind) could not be made or read") }
        object["seal"] = Data(HMAC<SHA256>.authenticationCode(for: body, using: key)).base64EncodedString()
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]).write(to: file, options: .atomic)
        } catch { throw ScriptTrustStore.WriteFailure(description: error.localizedDescription) }
    }
}

// MARK: - The receipts and the questions about them

/// The receipts and the developer-mode switch, read from and written to a holder. Main thread only, as the menu and the
/// plugins that ask it are. If the holder cannot be used, the store is empty for this run and says so when asked to change.
public final class ScriptTrustStore {
    public static let fileName = "plugin-trust.json"
    /// The one TurnOver uses: the keeper, or in a developer build the support folder's sealed file with a key file beside it.
    public static let shared: ScriptTrustStore = {
        let holder: ScriptTrustHolder = Edition.isDevBuild
            ? SealedFileHolder(file: AppPaths.file(fileName), keys: FileSealKey(url: AppPaths.file("plugin-trust.key")))
            : KeeperHolder()
        return ScriptTrustStore(holder: holder)
    }()

    private let holder: ScriptTrustHolder
    public private(set) var receipts: [ScriptReceipt] = []
    public private(set) var developerMode = false
    /// Words for a person, if the holder could not be used when the store last read it. Then nothing can be changed.
    public private(set) var unavailable: String?
    private var saidUnavailable = false

    package init(holder: ScriptTrustHolder) {
        self.holder = holder
        reload()
    }

    /// For tests: a sealed file that keeps its key in memory.
    public convenience init(file: URL, inMemoryKey: Data? = nil) {
        self.init(holder: SealedFileHolder(file: file, keys: MemorySealKey(key: inMemoryKey.map { SymmetricKey(data: $0) })))
    }

    private struct Payload: Codable {
        var format = 1
        var developerMode: Bool
        var receipts: [ScriptReceipt]
    }

    private static func coding() -> (JSONEncoder, JSONDecoder) {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601; decoder.dateDecodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return (encoder, decoder)
    }

    /// Read again. Anything wrong leaves the store empty, and the log says what (once, for a holder that cannot be used).
    public func reload() {
        receipts = []; developerMode = false; unavailable = nil
        let data: Data?
        do { data = try holder.load() } catch {
            unavailable = (error as? WriteFailure)?.description ?? error.localizedDescription
            if !saidUnavailable { saidUnavailable = true; Log.warning("plugin trust: \(holder.kind) cannot be used (\(unavailable ?? "")); no script is approved in this run and none can be") }
            return
        }
        guard let data else { return }
        guard let payload = try? Self.coding().1.decode(Payload.self, from: data), payload.format == 1 else {
            return Log.warning("plugin trust: what \(holder.kind) holds is in a format this TurnOver does not know; it is read as empty, so every script needs approving again")
        }
        receipts = payload.receipts; developerMode = payload.developerMode
    }

    public struct WriteFailure: Error, CustomStringConvertible {
        public let description: String
        package init(description: String) { self.description = description }
    }

    private func save() throws {
        if let unavailable { throw WriteFailure(description: unavailable) }   // never write over what could not be read
        let (encoder, _) = Self.coding()
        guard let data = try? encoder.encode(Payload(developerMode: developerMode, receipts: receipts)) else {
            throw WriteFailure(description: "the receipts could not be written")
        }
        try holder.store(data)
    }

    // MARK: Asking

    public func receipt(for id: String) -> ScriptReceipt? { receipts.first { $0.id == id } }

    /// May this plugin's script run? Yes when a receipt matches the hash; or, with developer mode on and a receipt that
    /// came from a draft, when the apps and abilities are both within the receipt's. Otherwise no, and why.
    public func decision(id: String, hash: String, apps: [String], abilities: Set<ScriptAbility>) -> ScriptTrustDecision {
        guard let receipt = receipt(for: id) else { return .refused(.neverApproved) }
        if receipt.hash == hash { return .allowed }
        guard developerMode, receipt.origin == .draft else { return .refused(.filesChanged) }
        if !Set(abilities.map(\.rawValue)).isSubset(of: Set(receipt.abilities)) { return .refused(.abilitiesGrew) }
        if !Set(apps).isSubset(of: Set(receipt.apps)) { return .refused(.appsGrew) }
        return .allowed
    }

    /// The same question for a loaded plugin: its hash, its apps and the abilities it really has.
    public func decision(for plugin: LoadedPlugin) -> ScriptTrustDecision {
        guard let manifest = plugin.manifest, plugin.script != nil, let hash = plugin.scriptHash else { return .refused(.neverApproved) }
        return decision(id: manifest.id, hash: hash, apps: manifest.apps, abilities: ScriptAbilities.effective(for: plugin))
    }

    // MARK: Changing

    /// Record that the person approved this script. Replaces an earlier receipt for the same plugin.
    public func approve(id: String, hash: String, apps: [String], abilities: Set<ScriptAbility>, origin: ScriptOrigin, signer: String? = nil, at date: Date = Date()) throws {
        let receipt = ScriptReceipt(id: id, hash: hash, apps: apps.sorted(), abilities: abilities.map(\.rawValue).sorted(),
                                    approved: Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)), origin: origin, signer: signer)
        let before = receipts
        receipts.removeAll { $0.id == id }; receipts.append(receipt)
        do { try save() } catch { receipts = before; throw error }
    }

    public func approve(_ plugin: LoadedPlugin, origin: ScriptOrigin, signer: String? = nil, at date: Date = Date()) throws {
        guard let manifest = plugin.manifest, let hash = plugin.scriptHash else { throw WriteFailure(description: "the plugin has no script to approve") }
        try approve(id: manifest.id, hash: hash, apps: manifest.apps, abilities: ScriptAbilities.effective(for: plugin), origin: origin, signer: signer, at: date)
    }

    /// Take a plugin's approval away (the person says so, or the library withdrew it).
    public func revoke(id: String) throws {
        if let unavailable { throw WriteFailure(description: unavailable) }
        let before = receipts
        receipts.removeAll { $0.id == id }
        guard receipts != before else { return }
        do { try save() } catch { receipts = before; throw error }
    }

    public func setDeveloperMode(_ on: Bool) throws {
        let before = developerMode
        developerMode = on
        do { try save() } catch { developerMode = before; throw error }
    }
}
