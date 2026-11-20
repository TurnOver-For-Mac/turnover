// SPDX-License-Identifier: GPL-3.0-or-later
// NVDA's store list, and finding an add-on in it without knowing its id (`turnover-plugin store list | search | show`).
// The list is the combined file `convert` uses. A copy is kept for an hour so browsing is quick. Output is plain lines made for a
// screen reader: one add-on per line, no tables. Each add-on has a small verdict (docs/PLUGIN-PLATFORM-PLAN.md, stage A).
import Foundation

nonisolated public struct StoreEntry: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var version: String
    public var downloadURL: String?
    public var sha256: String?
    public var channel: String
    public var author: String
    public var sourceURL: String?
    public var license: String?
    public var licenseURL: String?
    public var homepage: String?
    public var minNVDA: String?
    public var lastTested: String?

    /// The entries of NVDA's combined list. Fields it does not have come back empty; the VirusTotal results are not read.
    public static func parse(_ data: Data) throws -> [StoreEntry] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ConvertFailure("The store's list could not be understood (it is not the list this tool expects).")
        }
        func text(_ d: [String: Any], _ k: String) -> String? { (d[k] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } }
        func api(_ d: [String: Any], _ k: String) -> String? {
            guard let o = d[k] as? [String: Any], let a = o["major"], let b = o["minor"] else { return nil }
            return "\(a).\(b)" + (o["patch"].map { ".\($0)" } ?? "")
        }
        return array.compactMap { d in
            guard let id = text(d, "addonId") else { return nil }
            return StoreEntry(id: id, name: text(d, "displayName") ?? id, description: text(d, "description") ?? "", version: text(d, "addonVersionName") ?? "",
                              downloadURL: text(d, "URL"), sha256: text(d, "sha256"), channel: text(d, "channel") ?? "stable",
                              author: text(d, "publisher") ?? "", sourceURL: text(d, "sourceURL"), license: text(d, "license"), licenseURL: text(d, "licenseURL"),
                              homepage: text(d, "homepage"), minNVDA: api(d, "minNVDAVersion"), lastTested: api(d, "lastTestedVersion"))
        }
    }

    /// The entry for an id on a channel (the newest version the list holds for it).
    public static func choose(id: String, channel: String, from entries: [StoreEntry]) -> StoreEntry? {
        entries.last { $0.id.lowercased() == id.lowercased() && $0.channel.lowercased() == channel.lowercased() }
    }
}

nonisolated public enum StoreVerdict: String, Codable, Sendable {
    case canConvert, needsWork, notForMac, notLookedAt
    public var words: String {
        switch self {
        case .canConvert: return "can be converted"
        case .needsWork: return "needs work"
        case .notForMac: return "not for the Mac"
        case .notLookedAt: return "not looked at yet"
        }
    }
}

nonisolated public struct StoreJudgement: Equatable, Sendable {
    public enum Source: String, Sendable { case remembered, signs, none }
    public var verdict: StoreVerdict
    public var reason: String?
    public var source: Source
    public init(verdict: StoreVerdict, reason: String?, source: Source) { self.verdict = verdict; self.reason = reason; self.source = source }
}

/// What an earlier `convert` found out about an id and version, kept in the tool's own cache folder (never TurnOver's support folder).
nonisolated public struct ConvertMemory {
    public let file: URL
    struct Item: Codable { var verdict: StoreVerdict; var reason: String? }
    public init(cacheDirectory: URL) { file = cacheDirectory.appendingPathComponent("convert-results.json") }

    private func load() -> [String: Item] {
        guard let data = try? Data(contentsOf: file), let d = try? JSONDecoder().decode([String: Item].self, from: data) else { return [:] }
        return d
    }
    static func key(_ id: String, _ version: String) -> String { id.lowercased() + "@" + version }
    public func recall(id: String, version: String) -> (StoreVerdict, String?)? { load()[Self.key(id, version)].map { ($0.verdict, $0.reason) } }
    public func remember(id: String, version: String, verdict: StoreVerdict, reason: String?) {
        var all = load()
        all[Self.key(id, version)] = Item(verdict: verdict, reason: reason)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: file, options: .atomic) }
    }
}

nonisolated public struct StoreBrowser {
    public let entries: [StoreEntry]
    public let memory: ConvertMemory?

    public init(entries: [StoreEntry], memory: ConvertMemory?) { self.entries = entries; self.memory = memory }

    public static var defaultCacheDirectory: URL {
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory).appendingPathComponent("turnover-plugin")
    }

    /// The combined list: the copy kept in `cache` if it is under an hour old, otherwise fetched (over https) and kept.
    public static func loadList(cache: URL, now: Date = Date(), fetch: ConvertFetch) throws -> Data {
        let file = cache.appendingPathComponent("store-list.json")
        if let m = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date, now.timeIntervalSince(m) < 3600, now >= m,
           let data = try? Data(contentsOf: file), !data.isEmpty { return data }
        guard let url = ConvertSource.httpsURL(ConvertSource.listAddress) else { throw ConvertFailure("The store's address is not https.") }
        let data: Data
        do { data = try fetch(url, ConvertLimits.downloadBytes) } catch { throw ConvertFailure("The store's list could not be fetched: \(ConvertFailure.sentenceEnd("\(error)")).") }
        _ = try StoreEntry.parse(data)   // only a list that reads is kept
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return data
    }

    /// The stable channel, sorted by name.
    public func stable() -> [StoreEntry] { sorted(entries.filter { $0.channel.lowercased() == "stable" }) }

    func sorted(_ list: [StoreEntry]) -> [StoreEntry] {
        list.sorted { let c = $0.name.localizedCaseInsensitiveCompare($1.name); return c == .orderedSame ? $0.id < $1.id : c == .orderedAscending }
    }

    /// Matches name, id, author and description; every word must be found; case does not matter.
    public func search(_ words: [String]) -> [StoreEntry] {
        let needles = words.map { $0.lowercased() }.filter { !$0.isEmpty }
        return stable().filter { e in
            let hay = [e.name, e.id, e.author, e.description].joined(separator: "\n").lowercased()
            return needles.allSatisfy { hay.contains($0) }
        }
    }

    /// The verdict: what an earlier convert remembered; else plain signs in the entry; else not looked at yet.
    public func judge(_ e: StoreEntry) -> StoreJudgement {
        if let (v, why) = memory?.recall(id: e.id, version: e.version) { return StoreJudgement(verdict: v, reason: why, source: .remembered) }
        if let why = ConvertSigns.notForMac(name: e.name, id: e.id, description: e.description) { return StoreJudgement(verdict: .notForMac, reason: why, source: .signs) }
        return StoreJudgement(verdict: .notLookedAt, reason: nil, source: .none)
    }

    // MARK: Output

    static func oneLine(_ s: String, limit: Int = 110) -> String {
        let flat = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard flat.count > limit else { return flat }
        let cut = flat.prefix(limit)
        return String(cut[..<(cut.lastIndex(of: " ") ?? cut.endIndex)]) + "…"
    }

    /// One add-on on one line, as it is read aloud.
    public func line(_ e: StoreEntry) -> String {
        let j = judge(e)
        var s = "\(e.name), id \(e.id), version \(e.version)"
        if !e.author.isEmpty { s += ", by \(Self.oneLine(e.author, limit: 60))" }
        if !e.description.isEmpty { s += ". \(Self.oneLine(e.description))" }
        if !s.hasSuffix(".") && !s.hasSuffix("…") { s += "." }
        s += " Verdict: \(j.verdict.words)" + (j.reason.map { " (\($0))" } ?? "") + "."
        return s
    }

    public struct Page { public var lines: [String]; public var shown: Int; public var leftOut: Int; public var json: [[String: Any]] }

    /// The lines for a list or a search, with the end sentence. `hideNotMac` leaves out "not for the Mac" and counts them.
    public func page(_ list: [StoreEntry], hideNotMac: Bool) -> Page {
        var lines: [String] = [], json: [[String: Any]] = [], hidden = 0
        for e in list {
            let j = judge(e)
            if hideNotMac, j.verdict == .notForMac { hidden += 1; continue }
            lines.append(line(e))
            var d: [String: Any] = ["id": e.id, "name": e.name, "version": e.version, "author": e.author, "description": e.description, "verdict": j.verdict.words]
            if let r = j.reason { d["reason"] = r }
            json.append(d)
        }
        let n = json.count
        var end = n == 1 ? "1 add-on." : "\(n) add-ons."
        if hideNotMac { end = (n == 1 ? "1 add-on shown" : "\(n) add-ons shown") + "; \(hidden) left out as not for the Mac." }
        lines.append(end)
        return Page(lines: lines, shown: n, leftOut: hidden, json: json)
    }

    /// Everything the list says about one add-on, one fact per line.
    public func show(_ e: StoreEntry) -> [String] {
        let j = judge(e)
        var l = ["Name: \(e.name)", "Id: \(e.id)", "Version: \(e.version)", "Channel: \(e.channel)"]
        if !e.author.isEmpty { l.append("Author: \(e.author)") }
        if !e.description.isEmpty { l.append("Description: \(e.description.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " "))") }
        l.append("Licence: \(e.license ?? "not given in the list")" + (e.licenseURL.map { ", \($0)" } ?? ""))
        l.append("Source address: \(e.sourceURL ?? "not given in the list")")
        if let h = e.homepage { l.append("Home page: \(h)") }
        l.append("Download address: \(e.downloadURL ?? "not given in the list")")
        l.append("SHA-256: \(e.sha256 ?? "not given in the list")")
        if let m = e.minNVDA { l.append("Needs NVDA: \(m) or later" + (e.lastTested.map { "; last tested with \($0)" } ?? "")) }
        let text = e.name + " " + e.description
        let kind = ConvertSigns.table.first { s in s.words.contains { ConvertSigns.contains(" " + text.lowercased() + " ", $0) } && (s.reason.hasPrefix("a speech") || s.reason.hasPrefix("a braille")) }
        l.append("Kind: " + (kind.map { "looks like \($0.reason.components(separatedBy: ";")[0]), from its description" } ?? "the list does not say whether it is a global plugin, an app module or a driver; convert --report-only finds out"))
        l.append("Verdict: \(j.verdict.words)" + (j.reason.map { " (\($0))" } ?? "") + (j.source == .remembered ? ", from an earlier conversion on this Mac" : j.source == .signs ? ", from signs in the list" : ""))
        return l
    }

    public func showJSON(_ e: StoreEntry) -> [String: Any] {
        let j = judge(e)
        var d: [String: Any] = ["id": e.id, "name": e.name, "version": e.version, "channel": e.channel, "author": e.author, "description": e.description, "verdict": j.verdict.words, "verdictSource": j.source.rawValue]
        for (k, v) in [("license", e.license), ("licenseURL", e.licenseURL), ("sourceURL", e.sourceURL), ("homepage", e.homepage), ("downloadURL", e.downloadURL), ("sha256", e.sha256), ("minNVDA", e.minNVDA), ("lastTested", e.lastTested), ("reason", j.reason)] { if let v { d[k] = v } }
        return d
    }

    public static func jsonText(_ object: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
