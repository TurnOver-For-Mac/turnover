// SPDX-License-Identifier: GPL-3.0-or-later
// NVDA's add-on store, from TurnOver's Plugins menu (docs/PLUGIN-PLATFORM-PLAN.md, stage A; 16 Nov 2026).
//
// The screen reader itself does no networking and no parsing of what comes back. Everything goes through the bundled
// `turnover-plugin` tool, run as a separate program with a time limit and a cap on what it may print:
//   turnover-plugin store list|search <words> --json     the add-ons, with TurnOver's verdict where it is known
//   turnover-plugin store show <id> --json               one add-on in full
//   turnover-plugin convert <id> --out <folder> --converted-by "<name>"
// The tool fetches only over https from the address NVDA's store gives, refuses a file whose SHA-256 differs from the
// list, and only reads the add-on's Python as text. This file builds the questions, reads the answers (fixture JSON in the
// tests, never the network) and says failures in plain sentences. The menu part is NVDAStoreMenu.swift.
import Foundation

nonisolated public enum NVDAStore {

    // MARK: What the tool says

    public enum Verdict: String, Equatable, Sendable {
        case canConvert = "can be converted", needsWork = "needs work", notForMac = "not for the Mac", notLookedAt = "not looked at yet"
        init(words: String?) { self = Verdict(rawValue: words ?? "") ?? .notLookedAt }
    }

    public struct Item: Equatable, Sendable {
        public var id: String, name: String, version: String, author: String, description: String
        public var verdict: Verdict, reason: String?
        public init(id: String, name: String, version: String, author: String, description: String, verdict: Verdict, reason: String?) {
            self.id = id; self.name = name; self.version = version; self.author = author; self.description = description; self.verdict = verdict; self.reason = reason
        }
    }

    public struct Detail: Equatable, Sendable {
        public var item: Item
        public var license: String?, sourceURL: String?, homepage: String?, minNVDA: String?
    }

    /// A failure, already in the plain sentence the person hears.
    public struct Failure: Error, Equatable, Sendable {
        public let words: String
        public init(_ words: String) { self.words = words }
        public static let notConnected = Failure(String(localized: "TurnOver has not been told it may ask NVDA's store, so nothing was asked.", comment: "Said when the NVDA add-on store is used without the person having agreed"))
    }

    /// What running the tool gave. `out` is capped by the runner.
    public struct ToolResult: Sendable {
        public var status: Int32
        public var out: Data
        public var err: String
        public var timedOut = false
        public var couldNotStart = false
        public init(status: Int32, out: Data, err: String = "", timedOut: Bool = false, couldNotStart: Bool = false) {
            self.status = status; self.out = out; self.err = err; self.timedOut = timedOut; self.couldNotStart = couldNotStart
        }
    }

    /// Runs the tool with these arguments and gives up after the time. The real one is `ToolProcess.run`; the tests pass their own.
    public typealias Runner = (_ arguments: [String], _ timeout: TimeInterval) -> ToolResult

    // MARK: Text from outside

    /// One plain line: no control characters, runs of space made one, cut at a limit. Everything from the store passes through this
    /// before it is spoken or shown.
    static func plain(_ s: String, limit: Int) -> String {
        let flat = String(String.UnicodeScalarView(s.unicodeScalars.map { u in
            u.value < 0x20 || (0x7F...0x9F).contains(u.value) || u.value == 0x2028 || u.value == 0x2029 ? " " : u
        })).split(whereSeparator: { $0 == " " }).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }

    /// An add-on id the tool may be given: letters, digits, dot, underscore, hyphen, starting with a letter or digit. Anything else
    /// is never put on a command line.
    public static func isSafeID(_ id: String) -> Bool { id.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$"#, options: .regularExpression) != nil }

    /// A name to credit: plain, at most 120 characters, nothing that could be read as a flag.
    public static func creditName(_ s: String) -> String { plain(s, limit: 120).trimmingCharacters(in: CharacterSet(charactersIn: "- ")) }

    // MARK: Questions

    public static let listArguments = ["store", "list", "--json"]

    /// The words typed, as separate words with any leading hyphens taken off (so a word can never be read as one of the tool's
    /// flags); nil when nothing is left to search for.
    public static func searchArguments(_ text: String) -> [String]? {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map { String($0.drop(while: { $0 == "-" })) }.filter { !$0.isEmpty }.map { plain($0, limit: 60) }
        return words.isEmpty ? nil : ["store", "search"] + words.prefix(8) + ["--json"]
    }

    public static func showArguments(_ id: String) -> [String]? { isSafeID(id) ? ["store", "show", id, "--json"] : nil }

    public static func convertArguments(id: String, folder: URL, convertedBy: String) -> [String]? {
        guard isSafeID(id) else { return nil }
        var a = ["convert", id, "--out", folder.path, "--channel", "stable"]
        let name = creditName(convertedBy)
        if !name.isEmpty { a += ["--converted-by", name] }
        return a
    }

    /// A new folder for a conversion in `base` (the plugin makers' folder, ~/TurnOver Plugins): named for the add-on and the time,
    /// never an existing one.
    public static func conversionFolder(name: String, id: String, base: URL, now: Date = Date(), exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmm"; f.locale = Locale(identifier: "en_US_POSIX")
        let safe = String((name.isEmpty ? id : name).map { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" ? $0 : " " })
        let label = plain(safe, limit: 50).trimmingCharacters(in: .whitespaces)
        let stem = "NVDA add-on \(label.isEmpty ? id : label) \(f.string(from: now))"
        var url = base.appendingPathComponent(stem, isDirectory: true), n = 2
        while exists(url) { url = base.appendingPathComponent("\(stem) \(n)", isDirectory: true); n += 1 }
        return url
    }

    // MARK: Answers

    /// What a failed run says, in a plain sentence.
    public static func failure(_ r: ToolResult, what: String) -> Failure {
        if r.couldNotStart { return Failure(String(localized: "TurnOver's plugin tool could not be started, so \(what) did not happen.", comment: "A store step could not start: %@ names the step")) }
        if r.timedOut { return Failure(String(localized: "NVDA's store did not answer in time, so \(what) did not happen. Nothing was changed. Try again later.", comment: "A store step took too long: %@ names the step")) }
        let first = plain(r.err.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? "", limit: 240)
            .reversed().drop(while: { $0 == "." || $0 == " " }).reversed().map(String.init).joined()
        if first.isEmpty { return Failure(String(localized: "\(what) did not work, and the tool did not say why. Nothing was changed.", comment: "A store step failed with no reason: %@ names the step")) }
        return Failure(String(localized: "\(what) did not work: \(first). Nothing was changed.", comment: "A store step failed: %1$@ names the step, %2$@ is the tool's own reason"))
    }

    /// A download that failed, said in one plain sentence for the add-on's name: nil when the tool's words are not about a
    /// download. The tool says "The download failed: <reason>." (or the SHA-256 or size refusals); the reason decides what is said.
    public static func downloadFailure(_ err: String, name: String) -> Failure? {
        let first = plain(err.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? "", limit: 300)
        let lower = first.lowercased()
        let who = name.isEmpty ? String(localized: "The add-on", comment: "Stands for an add-on's name in a failure sentence") : name
        if lower.contains("sha-256 does not match") {
            return Failure(String(localized: "\(who) was not used: its file is not the one NVDA's store listed, so nothing was read. That is at the store's or its author's end, not yours. Nothing was changed.", comment: "A download's checksum did not match; the placeholder is the add-on's name"))
        }
        if lower.contains("larger than 50 mb") {
            return Failure(String(localized: "\(who) could not be fetched: its download is larger than TurnOver will read, 50 megabytes. Nothing was changed.", comment: "A download was too big; the placeholder is the add-on's name"))
        }
        guard lower.hasPrefix("the download failed") else { return nil }
        let why: String
        if let m = lower.range(of: #"answered (\d{3})"#, options: .regularExpression), let code = Int(lower[m].suffix(3)) {
            switch code {
            case 404, 410: why = String(localized: "its download address no longer exists. That is at its author's end, not yours", comment: "A download address gave 404 or 410")
            case 401, 403: why = String(localized: "its download server refused the request (\(code)). That is at its author's end, not yours", comment: "A download gave 401 or 403: the placeholder is the number")
            case 500...599: why = String(localized: "its download server had a problem (\(code)). Try again later", comment: "A download gave a server error: the placeholder is the number")
            default: why = String(localized: "its download server answered \(code), not the file. Try again later", comment: "A download gave another status: the placeholder is the number")
            }
        } else if lower.contains("timed out") {
            why = String(localized: "the download took too long. Try again later", comment: "A download timed out")
        } else if ["offline", "internet connection", "network connection was lost", "could not connect", "cannot connect", "not connected"].contains(where: lower.contains) {
            why = String(localized: "TurnOver could not reach the internet. Check the connection and try again", comment: "A download had no network")
        } else if lower.contains("hostname") || lower.contains("cannot find host") || lower.contains("could not be found") {
            why = String(localized: "its download server could not be found. That may be no internet connection, or an address that no longer exists", comment: "A download's host did not resolve")
        } else if lower.contains("https") {
            why = String(localized: "it would not be fetched safely, because its address is not a secure one", comment: "A download was not over https")
        } else {
            let reason = first.dropFirst("The download failed:".count).trimmingCharacters(in: CharacterSet(charactersIn: ". ")).trimmingCharacters(in: .whitespaces)
            why = reason.isEmpty ? String(localized: "the download did not work", comment: "A download failed with no reason") : reason
        }
        return Failure(String(localized: "\(who) could not be fetched: \(why). Nothing was changed.", comment: "A download failed: the placeholders are the add-on's name and the reason, which has no full stop"))
    }

    /// What is said of an author: no addresses in angle brackets and no bare email addresses (the full string stays in the files
    /// the converter writes). "Ann <a@x.org>, Bob <b@y.org>" is "Ann, Bob".
    public static func speakableAuthor(_ s: String) -> String {
        var t = s
        for pattern in [#"<[^<>]*>"#, #"<[^<>]*$"#, #"[^\s<>(),;]+@[^\s<>(),;]+"#, #"\(\s*\)"#, #"\[\s*\]"#] {
            t = t.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        let names = t.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.split(whereSeparator: { $0 == " " }).joined(separator: " ") }.filter { !$0.isEmpty }
        return names.joined(separator: ", ")
    }

    static func item(_ d: [String: Any]) -> Item? {
        guard let id = d["id"] as? String, isSafeID(id) else { return nil }
        let name = plain((d["name"] as? String) ?? id, limit: 120)
        return Item(id: id, name: name.isEmpty ? id : name, version: plain((d["version"] as? String) ?? "", limit: 40), author: plain((d["author"] as? String) ?? "", limit: 100),
                    description: plain((d["description"] as? String) ?? "", limit: 300), verdict: Verdict(words: d["verdict"] as? String),
                    reason: (d["reason"] as? String).map { plain($0, limit: 160) })
    }

    /// The answer to `store list|search --json`. An entry with no safe id is left out, never guessed at.
    public static func parseList(_ data: Data) -> Result<[Item], Failure> {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let list = o["addons"] as? [[String: Any]] else {
            return .failure(Failure(String(localized: "NVDA's store gave an answer TurnOver could not read. Nothing was changed.", comment: "The store's answer did not parse")))
        }
        return .success(list.compactMap(item))
    }

    /// The answer to `store show <id> --json`.
    public static func parseDetail(_ data: Data) -> Result<Detail, Failure> {
        guard let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let i = item(d) else {
            return .failure(Failure(String(localized: "NVDA's store gave an answer TurnOver could not read. Nothing was changed.", comment: "The store's answer did not parse")))
        }
        func s(_ k: String, _ limit: Int = 200) -> String? { (d[k] as? String).map { plain($0, limit: limit) }.flatMap { $0.isEmpty ? nil : $0 } }
        return .success(Detail(item: i, license: s("license", 80), sourceURL: s("sourceURL"), homepage: s("homepage"), minNVDA: s("minNVDA", 40)))
    }

    // MARK: The steps. Each refuses to ask anything unless the person has said yes.

    /// All the add-ons, or those matching words. Never runs the tool unless `connected`.
    public static func fetchList(search: String?, connected: Bool, run: Runner) -> Result<[Item], Failure> {
        guard connected else { return .failure(.notConnected) }
        let args: [String]
        if let search { guard let a = searchArguments(search) else { return .failure(Failure(String(localized: "There was nothing to search for.", comment: "An empty search of NVDA's add-on store"))) }; args = a }
        else { args = listArguments }
        let r = run(args, 60)
        guard r.status == 0, !r.timedOut, !r.couldNotStart else { return .failure(failure(r, what: String(localized: "asking NVDA's store", comment: "A step: asking the store for its list"))) }
        return parseList(r.out)
    }

    public static func fetchDetail(id: String, connected: Bool, run: Runner) -> Result<Detail, Failure> {
        guard connected else { return .failure(.notConnected) }
        guard let args = showArguments(id) else { return .failure(Failure(String(localized: "That add-on's id is not one TurnOver will use.", comment: "An add-on id with odd characters"))) }
        let r = run(args, 60)
        guard r.status == 0, !r.timedOut, !r.couldNotStart else { return .failure(failure(r, what: String(localized: "asking NVDA's store", comment: "A step: asking the store for its list"))) }
        return parseDetail(r.out)
    }

    public enum ConvertOutcome: Equatable, Sendable {
        /// A draft plugin and its brief are in the folder.
        case made(folder: URL)
        /// The add-on was read, and nothing in it comes across: the report is in the folder, and there is no plugin.
        case nothingToConvert(folder: URL)
        case failed(Failure)
    }

    /// Converts an add-on into a new folder under `base`. Never runs the tool unless `connected`.
    public static func convert(_ item: Item, convertedBy: String, base: URL, connected: Bool, now: Date = Date(), run: Runner) -> ConvertOutcome {
        guard connected else { return .failed(.notConnected) }
        let folder = conversionFolder(name: item.name, id: item.id, base: base, now: now)
        guard let args = convertArguments(id: item.id, folder: folder, convertedBy: convertedBy) else { return .failed(Failure(String(localized: "That add-on's id is not one TurnOver will use.", comment: "An add-on id with odd characters"))) }
        let r = run(args, 240)
        guard r.status == 0, !r.timedOut, !r.couldNotStart else {
            if !r.timedOut, !r.couldNotStart, let f = downloadFailure(r.err, name: item.name) { return .failed(f) }
            return .failed(failure(r, what: String(localized: "converting the add-on", comment: "A step: converting an add-on")))
        }
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) { return .made(folder: folder) }
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("CONVERSION.md").path) { return .nothingToConvert(folder: folder) }
        return .failed(Failure(String(localized: "The conversion finished but wrote nothing. Nothing was changed.", comment: "A conversion wrote no files")))
    }

    // MARK: Spoken forms

    /// An add-on in a list: name, author, short description, and the verdict where it is known.
    public static func title(_ i: Item) -> String {
        var s = i.name
        let author = speakableAuthor(i.author)
        if !author.isEmpty { s += String(localized: ", by \(author)", comment: "An NVDA add-on in a list: its author, after its name") }
        switch i.verdict {
        case .notForMac: s += String(localized: ". Not for the Mac\(i.reason.map { ": \($0)" } ?? "").", comment: "An NVDA add-on that cannot come across; the placeholder is the reason, with its colon, or empty")
        case .needsWork: s += String(localized: ". Looked at before: needs work.", comment: "An NVDA add-on an earlier conversion found needs a person's work")
        case .canConvert: s += String(localized: ". Looked at before: can be converted.", comment: "An NVDA add-on an earlier conversion found can be converted")
        case .notLookedAt: break
        }
        return s
    }

    /// What a result says after a pause (only with hints on): its description, which About reads out in full either way.
    public static func hint(_ i: Item) -> String? { i.description.isEmpty ? nil : i.description }

    /// Everything the list says about one add-on, as one spoken passage.
    public static func facts(_ d: Detail) -> String {
        var parts = [d.item.name + (d.item.version.isEmpty ? "" : String(localized: ", version \(d.item.version)", comment: "An add-on's version after its name"))]
        let author = speakableAuthor(d.item.author)
        if !author.isEmpty { parts.append(String(localized: "By \(author).", comment: "An add-on's author")) }
        if !d.item.description.isEmpty { parts.append(d.item.description) }
        parts.append(String(localized: "Licence: \(d.license ?? String(localized: "not given", comment: "A licence the store does not give")).", comment: "An add-on's licence"))
        if let s = d.sourceURL { parts.append(String(localized: "Source: \(s).", comment: "Where an add-on's source can be read")) }
        parts.append(String(localized: "TurnOver's view: \(d.item.verdict.rawValue)\(d.item.reason.map { ", \($0)" } ?? "").", comment: "Whether an add-on can come across to TurnOver; the placeholder holds the verdict and any reason"))
        return parts.joined(separator: " ")
    }
}

// MARK: Running the tool

/// Runs the bundled `turnover-plugin` as its own program: a time limit, a cap on what it may print, no shell, the arguments as given.
nonisolated public enum ToolProcess {
    public static let outputLimit = 12 * 1024 * 1024

    /// Beside TurnOver (Contents/MacOS), or beside whatever program is running (a developer build), or in the installed app.
    public static var toolURL: URL? {
        let fm = FileManager.default
        let candidates = [Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/turnover-plugin"),
                          Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("turnover-plugin"),
                          URL(fileURLWithPath: "/Applications/TurnOver.app/Contents/MacOS/turnover-plugin")].compactMap { $0 }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    public static func run(_ arguments: [String], timeout: TimeInterval, tool: URL? = toolURL, limit: Int = outputLimit) -> NVDAStore.ToolResult {
        guard let tool else { return NVDAStore.ToolResult(status: -1, out: Data(), couldNotStart: true) }
        let p = Process(), out = Pipe(), err = Pipe()
        p.executableURL = tool; p.arguments = arguments
        p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
        let outData = Locked(Data()), errData = Locked(Data()), over = Locked(false)
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            outData.value.append(d)
            if outData.value.count > limit { over.value = true; p.terminate() }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            if errData.value.count < 20_000 { errData.value.append(d) }
        }
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return NVDAStore.ToolResult(status: -1, out: Data(), couldNotStart: true) }
        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if done.wait(timeout: .now() + 3) == .timedOut { kill(p.processIdentifier, SIGKILL); _ = done.wait(timeout: .now() + 3) }
        }
        out.fileHandleForReading.readabilityHandler = nil; err.fileHandleForReading.readabilityHandler = nil
        // Whatever was still in the pipes when it ended.
        outData.value.append((try? out.fileHandleForReading.readToEnd()) ?? Data())
        if over.value { return NVDAStore.ToolResult(status: 1, out: Data(), err: "the answer was larger than TurnOver will read") }
        return NVDAStore.ToolResult(status: p.terminationStatus, out: outData.value, err: String(decoding: errData.value, as: UTF8.self), timedOut: timedOut)
    }
}
