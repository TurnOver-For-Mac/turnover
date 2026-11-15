// SPDX-License-Identifier: GPL-3.0-or-later
// `turnover-plugin convert` and `turnover-plugin store`, as functions the tool calls and the tests share.
// Never writes outside --out and a temporary folder (the store's list and what earlier conversions found are kept in the tool's own
// cache folder). Never installs or approves anything.
import Foundation

nonisolated public struct ConvertRequest {
    public var input: String
    public var out: String?
    public var force = false
    public var reportOnly = false
    public var channel = "stable"
    public var convertedBy: String?
    public init(input: String) { self.input = input }
}

nonisolated public enum ConvertRun {
    /// A bare word that looks like an add-on id is looked up in the store; anything with a slash or ending .nvda-addon is a path.
    static func isStoreID(_ s: String) -> Bool {
        !s.contains("/") && !s.lowercased().hasSuffix(".nvda-addon") && !s.hasPrefix("~") && !s.hasPrefix(".") && s.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }

    /// Does the whole conversion. Returns the text to print and whether a plugin was made. Throws a plain-words failure.
    public static func perform(_ request: ConvertRequest, fetch: ConvertFetch, cache: URL, now: Date = Date()) throws -> (text: [String], madePlugin: Bool, result: ConvertResult) {
        if let p = ConvertParse.problem() { throw ConvertFailure(p) }
        if !request.reportOnly {
            guard let out = request.out, !out.isEmpty else { throw ConvertFailure("Say where the draft goes with --out <folder>, or use --report-only to read the report without writing anything.") }
            var isDir: ObjCBool = false
            let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                if !isDir.boolValue { throw ConvertFailure("\(url.path) is a file, not a folder; nothing was written.") }
                if !request.force { throw ConvertFailure("\(url.path) already exists. Nothing was written. Use a new folder, or --force to replace the files this tool writes there.") }
            }
        }
        let source: AddonSource
        let expanded = (request.input as NSString).expandingTildeInPath
        if isStoreID(request.input) {
            let list = try StoreBrowser.loadList(cache: cache, now: now, fetch: fetch)
            source = try ConvertSource.store(id: request.input, channel: request.channel, list: list, fetch: fetch)
        } else {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) else { throw ConvertFailure("There is no file or folder at \(request.input).") }
            let url = URL(fileURLWithPath: expanded)
            source = isDir.boolValue ? try ConvertSource.folder(url) : try ConvertSource.archive(url, label: "The file", origin: .file(url.path))
        }
        defer { source.cleanUp() }
        let parser = try ConvertParse()
        defer { parser.finish() }
        var result = try AddonConverter.convert(source: source, options: ConvertOptions(convertedBy: request.convertedBy), parser: parser)
        ConvertMemory(cacheDirectory: cache).remember(id: result.id, version: result.version, verdict: result.verdict, reason: result.verdictReason)
        var text = result.report.components(separatedBy: "\n")
        if text.last == "" { text.removeLast() }
        if !request.reportOnly, let out = request.out {
            let folder = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
            // The translation brief and the original, kept as plain text beside the draft (made before the source is cleaned up).
            if let info = result.briefInfo { result.files += ConvertBrief.files(info: info, source: source) }
            try write(result, to: folder, force: request.force)
            text.append("")
            text.append("## Written")
            text.append("The files are in \(folder.path): \(result.files.map(\.name).joined(separator: ", ")).")
            if result.madePlugin {
                text.append("Next: BRIEF.md in that folder is the task for finishing the translation. Give the folder to your AI tool (Claude, ChatGPT or Gemini), or finish it yourself, then run turnover-plugin check and turnover-plugin test on it. Putting the Mac app in apps is the person's choice. Nothing was installed or approved, and the translation is marked not reviewed.")
            }
            else { text.append("No plugin was made.") }
        } else if request.reportOnly {
            text.append("")
            text.append("Nothing was written (--report-only).")
        }
        return (text, result.madePlugin, result)
    }


    /// Writes the files into the folder: a new folder, or with force the folder that is there (only the files this tool writes).
    public static func write(_ result: ConvertResult, to folder: URL, force: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let ours = ["manifest.json", "main.js", "CONVERSION.md", "LICENSE-ORIGINAL.txt", "BRIEF.md", "CLAUDE.md", "AGENTS.md", "GEMINI.md", "PLUGIN-GUIDE.md", "PLUGIN-SCRIPTS.md"]
        if force {
            for n in ours where !result.files.contains(where: { $0.name == n }) { try? fm.removeItem(at: folder.appendingPathComponent(n)) }
            // The kept original is this tool's too: an older copy is replaced whole, never mixed with a new one.
            try? fm.removeItem(at: folder.appendingPathComponent(ConvertBrief.originalFolder))
        }
        for f in result.files {
            let url = folder.appendingPathComponent(f.name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try f.data.write(to: url, options: .atomic)
        }
    }
}

nonisolated public enum StoreRun {
    /// `store list | search <words> | show <id>`. Returns the lines to print (or the JSON text) and whether it worked.
    public static func perform(_ args: [String], fetch: ConvertFetch, cache: URL, now: Date = Date()) throws -> [String] {
        var words = args
        let json = words.contains("--json"), hide = words.contains("--hide-not-mac")
        var channel = "stable"
        if let i = words.firstIndex(of: "--channel"), words.indices.contains(i + 1) { channel = words[i + 1]; words.remove(at: i + 1); words.remove(at: i) }
        words.removeAll { $0 == "--json" || $0 == "--hide-not-mac" }
        guard let sub = words.first else { throw ConvertFailure("usage: turnover-plugin store list | search <words> | show <id>   (--json, --hide-not-mac)") }
        let list = try StoreBrowser.loadList(cache: cache, now: now, fetch: fetch)
        let browser = StoreBrowser(entries: try StoreEntry.parse(list), memory: ConvertMemory(cacheDirectory: cache))
        switch sub {
        case "list", "search":
            let rest = Array(words.dropFirst())
            if sub == "search", rest.isEmpty { throw ConvertFailure("Say what to search for: turnover-plugin store search <words>.") }
            let page = browser.page(sub == "list" ? browser.stable() : browser.search(rest), hideNotMac: hide)
            if json { return [StoreBrowser.jsonText(["addons": page.json, "shown": page.shown, "leftOut": page.leftOut] as [String: Any])] }
            if sub == "search", page.shown == 0, page.leftOut == 0 { return ["No add-on on the stable channel matches \"\(rest.joined(separator: " "))\"."] }
            return page.lines
        case "show":
            guard words.count >= 2 else { throw ConvertFailure("Say which add-on: turnover-plugin store show <id>.") }
            guard let e = StoreEntry.choose(id: words[1], channel: channel, from: browser.entries) else {
                throw ConvertFailure("The store's list has no add-on with the id \"\(words[1])\" on the \(channel) channel. `turnover-plugin store search <words>` finds one by name.")
            }
            return json ? [StoreBrowser.jsonText(browser.showJSON(e))] : browser.show(e)
        default:
            throw ConvertFailure("usage: turnover-plugin store list | search <words> | show <id>   (--json, --hide-not-mac)")
        }
    }
}
