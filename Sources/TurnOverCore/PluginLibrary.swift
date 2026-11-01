// SPDX-License-Identifier: GPL-3.0-or-later
// The plugin library (the plugin design notes decisions 5 and 6, plugin stage 2; 13 Oct 2026): a signed list of plugins on
// TurnOver's updates site, browsed in the TurnOver menu, each installed after its consent summary is read out.
//
// Trust, in order: the list's signature (the library's own key, not the updates key), carried in
// the same file as the list so a half-updated site can't pair a new list with an old signature; its format; its
// sequence number, never lower than the last one seen (an old list can't be served in place of a newer one); its
// expiry (7 days; a list out of date is refused); each plugin's size (capped while it downloads) and SHA-256; regular
// files only in the zip; then the plugin's own checks (PluginPolicy, PluginChecker) as for any install. The author
// said is the one the list vouches for, never what a plugin claims.
//
// Only plugins installed from the library carry a receipt (.library.json), and only they are updated or withdrawn by
// it: a person's own plugin that happens to share an id is never replaced or moved (code review, 13 Oct). A withdrawn
// plugin is moved aside within a day, dated, never deleted.
//
// The network and the unpacking run off the main thread; what touches TurnOver's state runs on it.
import Foundation
import AppKit
import CryptoKit

public enum PluginLibrary {
    nonisolated public static let publicKey = "glpzeHM7UV1IAwoisZ0SbNLDV5oPWRgJDogDgIZs74w="
    /// The library's folder; the "pluginLibraryURL" default points it elsewhere for testing (a file:// folder works).
    /// Still signature-checked, but it cuts this Mac off from the real withdrawals, so it is logged at start.
    /// Honoured only in a developer's build (Edition.isDevBuild): another program could otherwise point the library at
    /// an old signed list and hold back a withdrawal (a code review on 20 Oct 2026).
    nonisolated static var testingURL: String? { Edition.isDevBuild ? UserDefaults.standard.string(forKey: "pluginLibraryURL") : nil }
    nonisolated static var base: URL {
        testingURL.flatMap { URL(string: $0.hasSuffix("/") ? $0 : $0 + "/") }
            ?? URL(string: "https://doll-eye.github.io/turnover-updates/plugins/")!
    }
    static let receiptName = ".library.json"
    /// The last sequence seen, per library address: a test list under "pluginLibraryURL" with a high number locked
    /// the Mac out of the real library (a code review, 14 Oct 2026).
    nonisolated public static var sequenceKey: String { "pluginIndexSequence:" + base.absoluteString }

    nonisolated public struct Entry: Decodable, Sendable {
        public let id: String, version: String, file: String, sha256: String, size: Int, level: String
        public let name: String, summary: String?, author: String?, privacy: String?, apps: [String]?, sites: [String]?, abilities: [String]?
    }
    nonisolated public struct Index: Decodable, Sendable { public let format: Int, sequence: Int, expires: String, plugins: [Entry], withdrawn: [String] }
    nonisolated struct Signed: Decodable { let payload: String; let signature: String }
    nonisolated struct Receipt: Codable { let id: String; let version: String; let sha256: String; let level: String; let installed: String
        /// The library's author, not the manifest's claim (the installed list said "by" the manifest's author where the library said TurnOver-For-Mac, 14 Oct 2026). Missing in older receipts.
        var author: String? = nil }

    private static var lastFetch = Date.distantPast
    private static var started = false

    nonisolated static func failure(_ s: String) -> Error { NSError(domain: "TurnOver", code: 10, userInfo: [NSLocalizedDescriptionKey: s]) }

    /// One session for the library, with timeouts (a stalled site never holds a fetch open for long).
    nonisolated private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15; c.timeoutIntervalForResource = 60
        return URLSession(configuration: c)
    }()

    // MARK: Checking the list

    /// The list's checks, in order: signature, readable, format, sequence, expiry. Records the sequence when it passes.
    nonisolated public static func verify(_ data: Data, signature sigData: Data?, key: String = publicKey, now: Date = Date()) -> Result<Index, Error> {
        guard let sigText = sigData.flatMap({ String(data: $0, encoding: .utf8) })?.trimmingCharacters(in: .whitespacesAndNewlines),
              let sig = Data(base64Encoded: sigText), let pk = Data(base64Encoded: key),
              let k = try? Curve25519.Signing.PublicKey(rawRepresentation: pk), k.isValidSignature(sig, for: data)
        else { return .failure(failure("the library's list isn't signed by TurnOver; it was refused")) }
        guard let index = try? JSONDecoder().decode(Index.self, from: data) else { return .failure(failure("the library's list can't be read")) }
        guard index.format == 1 else { return .failure(failure("the library's list is a newer kind; update TurnOver to use it")) }
        let lastSeen = UserDefaults.standard.integer(forKey: sequenceKey)
        guard index.sequence >= lastSeen else {
            return .failure(failure("the library's list (number \(index.sequence)) is older than the last one seen (\(lastSeen)); it was refused"))
        }
        guard let exp = ISO8601DateFormatter().date(from: index.expires), exp > now else { return .failure(failure("the library's list is out of date")) }
        UserDefaults.standard.set(index.sequence, forKey: sequenceKey)
        return .success(index)
    }

    /// index.signed.json: the list and its signature together.
    nonisolated public static func verifySigned(_ envelope: Data, key: String = publicKey, now: Date = Date()) -> Result<Index, Error> {
        guard let s = try? JSONDecoder().decode(Signed.self, from: envelope), let payload = Data(base64Encoded: s.payload) else {
            return .failure(failure("the library's list can't be read"))
        }
        return verify(payload, signature: Data(s.signature.utf8), key: key, now: now)
    }

    /// Fetches with a size cap: past `limit` bytes it stops (a plugin's size comes from the signed list). Only a 200
    /// counts: a missing page is "can't be reached", not "isn't signed".
    nonisolated static func fetch(_ url: URL, limit: Int) async throws -> Data {
        if url.isFileURL {
            let d = try Data(contentsOf: url)
            guard d.count <= limit else { throw failure("it is larger than the library's list says") }
            return d
        }
        let (bytes, response) = try await session.bytes(from: url)
        if let h = response as? HTTPURLResponse, h.statusCode != 200 { throw failure("the library answered \(h.statusCode)") }
        var data = Data()
        for try await b in bytes {
            data.append(b)
            if data.count > limit { throw failure("it is larger than the library's list says") }
        }
        return data
    }

    /// The list, fetched and checked; tried twice (a site mid-update, a moment's network).
    nonisolated static func fetchIndex() async -> Result<Index, Error> {
        var last: Error = failure("the library can't be reached")
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            do {
                let envelope = try await fetch(base.appendingPathComponent("index.signed.json"), limit: 2_000_000)
                let checked = verifySigned(envelope)
                if case .failure(let e) = checked { last = e } else { return checked }
            } catch { last = error }
        }
        return .failure(last)
    }

    /// Fetch and check the list; `done` with the entries, or why not.
    public static func refresh(_ done: ((Result<[Entry], Error>) -> Void)? = nil) {
        Task { @MainActor in
            let result = await Task.detached { await fetchIndex() }.value
            switch result {
            case .failure(let e):
                // Tried again in an hour, not a day.
                lastFetch = Date().addingTimeInterval(-19 * 3600)
                Log.warning("plugin library: \(e.localizedDescription)")
                done?(.failure(e))
            case .success(let index):
                lastFetch = Date()
                withdraw(index.withdrawn)
                done?(.success(index.plugins))
            }
        }
    }

    /// Once per run (Core.activate runs on every hand-back from VoiceOver; each used to add a timer): a check a minute
    /// after start, then hourly, fetching at most daily, and only with plugins installed.
    public static func startDailyChecks() {
        guard !started else { return }
        started = true
        if let o = testingURL { Log.warning("plugin library: using \(o) instead of TurnOver's (testing)") }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { _ in MainActor.assumeIsolated { dailyCheck() } }
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in MainActor.assumeIsolated { dailyCheck() } }
    }

    static func dailyCheck() {
        // Parked plugins: no check at all, so the update feed is the only thing TurnOver fetches by itself (the privacy page).
        guard Edition.includesPlugins, !ProfileStore.shared.plugins.isEmpty, Date().timeIntervalSince(lastFetch) > 20 * 3600 else { return }
        refresh(nil)
    }

    // MARK: Receipts and withdrawing

    static func receipt(_ folder: URL) -> Receipt? {
        (try? Data(contentsOf: folder.appendingPathComponent(receiptName))).flatMap { try? JSONDecoder().decode(Receipt.self, from: $0) }
    }

    /// Library plugins on the withdrawn line are switched off: moved aside (dated, never deleted), and said.
    static func withdraw(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let fm = FileManager.default
        let aside = ProfileStore.folder.deletingLastPathComponent().appendingPathComponent("plugins-withdrawn", isDirectory: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        var gone: [String] = []
        for p in ProfileStore.shared.plugins {
            guard let m = p.manifest, ids.contains(m.id), receipt(p.folder)?.id == m.id else { continue }
            try? fm.createDirectory(at: aside, withIntermediateDirectories: true)
            if (try? fm.moveItem(at: p.folder, to: aside.appendingPathComponent("\(m.id) \(stamp)"))) != nil { gone.append(m.name) }
        }
        guard !gone.isEmpty else { return }
        ProfileStore.shared.reload(force: true)
        Log.warning("plugin library: withdrawn and switched off: \(gone.joined(separator: ", "))")
        Speech.speakMessage(String(localized: "Withdrawn from the plugin library and switched off: \(gone.joined(separator: ", ")).", comment: "Plugins withdrawn: %@ lists them"))
    }

    // MARK: The menu

    /// The TurnOver menu's Plugin library: the list, each with its level, then its consent summary and Install.
    public static func open() {
        Speech.speakMessage(String(localized: "Plugin library", comment: "Spoken message"))
        refresh { result in
            switch result {
            case .failure(let e): Speech.speakMessage(String(localized: "The plugin library: \(e.localizedDescription).", comment: "The plugin library failed: %@ is why"))
            case .success(let entries):
                // Last in the list: ask for a plugin for the app in front when the library has none for it (the
                // request is the app's shape, never its contents: AppRequest; 14 Oct 2026).
                var ask: [MenuItem] = []
                if let app = AppRequest.frontApp, let b = app.bundleIdentifier, !entries.contains(where: { ($0.apps ?? []).contains(b) }) {
                    ask = [MenuItem("No plugin for \(app.localizedName ?? String(localized: "this app", comment: "An application with no name")) yet: make one, or ask", .action { AppRequest.request() },
                                    hint: "Finds what the app is built with. If TurnOver has the parts for it, make its plugin or post it as wanted; if not, ask for the parts")]
                }
                if entries.isEmpty { TurnOverMenu.shared.openList("Plugin library", items: ask); return }
                // Plugins for apps on this Mac first, then the rest by name.
                func onMac(_ e: Entry) -> Bool { (e.apps ?? [String]()).contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil } }
                let sorted = entries.sorted { (onMac($0) ? 0 : 1, $0.name.lowercased()) < (onMac($1) ? 0 : 1, $1.name.lowercased()) }
                let items = sorted.map { e -> MenuItem in
                    MenuItem(verbatim: "\(e.name), \(e.level)\(state(of: e)). \(e.summary ?? "")", .action { DispatchQueue.main.async { details(e) } })
                }
                TurnOverMenu.shared.openList("Plugin library", items: items + ask)
            }
        }
    }

    /// ", installed", ", update available", ", you have your own plugin with this name", or nothing.
    static func state(of e: Entry) -> String {
        guard let p = ProfileStore.shared.plugins.first(where: { $0.manifest?.id == e.id }) else { return "" }
        guard let r = receipt(p.folder) else { return ", " + String(localized: "you have your own plugin with this name", comment: "A library plugin's state") }
        return ", " + (PluginFormat.compare(e.version, r.version) == .orderedDescending ? String(localized: "update available", comment: "A library plugin's state") : String(localized: "installed", comment: "A library plugin's state"))
    }

    /// What it is and what it can do, read out, with Install.
    static func details(_ e: Entry) {
        let apps = (e.apps ?? []).map { b in NSWorkspace.shared.urlForApplication(withBundleIdentifier: b).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? b }
        let can = (e.abilities ?? []).compactMap { PluginListing.abilities[$0] }
        var lines = ["\(e.name), version \(e.version). \(e.level), by \(e.author ?? "unknown")"]   // (joined with ". ": a full stop here said "..")
        if !apps.isEmpty { lines.append("Works in \(apps.joined(separator: " and "))") }
        if let sites = e.sites, !sites.isEmpty { lines.append("Works on \(sites.joined(separator: ", "))") }
        if !can.isEmpty { lines.append("It can " + can.joined(separator: ", ")) }
        if let p = e.privacy { lines.append(p) }
        TurnOverMenu.shared.openList(verbatim: lines.joined(separator: ". "), items: [
            MenuItem("Install \(e.name)", .action { DispatchQueue.main.async { install(e) } }),
            MenuItem("Back to the library", .action { DispatchQueue.main.async { open() } }),
        ])
    }

    // MARK: Installing

    /// Off the main thread: the zip fetched (capped at its listed size) and checked, then unpacked into a folder of
    /// its own; plain files only (a link could point the installed rules at a file anyone can change). Returns the
    /// plugin's folder and the temporary folder to remove afterwards.
    nonisolated static func download(_ e: Entry) async throws -> (folder: URL, tmp: URL) {
        let data = try await fetch(base.appendingPathComponent(e.file), limit: e.size)
        guard data.count == e.size, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == e.sha256 else {
            throw failure("it didn't match the library's list; nothing was installed")
        }
        return try PluginArchive.unpack(data)
    }

    /// Download, check, and install through the same checks as any plugin; asks first when it acts in its app or an
    /// update asks for more.
    static func install(_ e: Entry) {
        if let own = ProfileStore.shared.plugins.first(where: { $0.manifest?.id == e.id }), receipt(own.folder) == nil {
            Speech.speakMessage(String(localized: "You have your own plugin with the name \(e.id). The library's can't replace it; nothing was changed.", comment: "A library plugin clashes with yours: %@ is its name"))
            return
        }
        Speech.speakMessage(String(localized: "Getting \(e.name)", comment: "A library plugin being downloaded"))
        Task { @MainActor in
            let got: (folder: URL, tmp: URL)
            do { got = try await Task.detached { try await download(e) }.value }
            catch { Speech.speakMessage("\(e.name): \(error.localizedDescription)."); return }
            let tmp = got.tmp
            let cleanUp = { try? FileManager.default.removeItem(at: tmp); return () }
            let plugin = ProfileStore.load(folder: got.folder)
            guard let m = plugin.manifest, m.id == e.id, m.version == e.version else {
                cleanUp()
                Speech.speakMessage(plugin.error.map { "\(e.name): \($0)" } ?? String(localized: "\(e.name) isn't what the library's list says; nothing was installed.", comment: "A library plugin failed its check"))
                return
            }
            let installed = ProfileStore.shared.plugins.first { $0.manifest?.id == e.id }
            let more = Set(m.abilities ?? []).subtracting(installed?.manifest?.abilities ?? [])
            let warnings = PluginChecker.warnings(for: plugin)
            let asksMore = installed != nil && !more.isEmpty
            guard warnings.needsConfirmation || asksMore else { finish(plugin, e, cleanUp); return }
            // Asked in the same menu, with the download kept: Install anyway or Cancel (code review, 13 Oct: it took
            // reopening the library and choosing Install again within 20 seconds).
            var why = "\(e.name) acts in its app: " + warnings.lines.joined(separator: "; ") + "."
            if asksMore { why += " This version asks for more: \(more.compactMap { PluginListing.abilities[$0] }.joined(separator: ", "))." }
            TurnOverMenu.shared.openList(verbatim: why, items: [
                MenuItem("Install anyway", .action { DispatchQueue.main.async { finish(plugin, e, cleanUp) } }),
                MenuItem("Cancel", .action { cleanUp(); Speech.speakMessage(String(localized: "Not installed", comment: "Spoken message")) }),
            ])
        }
    }

    static func finish(_ plugin: LoadedPlugin, _ e: Entry, _ cleanUp: () -> Void) {
        defer { cleanUp() }
        do {
            let dest = try PluginChecker.install(plugin)
            let r = Receipt(id: e.id, version: e.version, sha256: e.sha256, level: e.level, installed: ISO8601DateFormatter().string(from: Date()), author: e.author)
            try JSONEncoder().encode(r).write(to: dest.appendingPathComponent(receiptName), options: .atomic)
        } catch { Speech.speakMessage(String(localized: "Could not install: \(error.localizedDescription)", comment: "A plugin not installed: %@ is why")); return }
        ProfileStore.shared.reload(force: true)
        Log.info("plugin library: installed \(e.id) \(e.version) (\(e.level))")
        Speech.speakMessage(String(localized: "\(e.name) installed.", comment: "A library plugin installed"))
    }
}
