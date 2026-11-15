// SPDX-License-Identifier: GPL-3.0-or-later
// The converter (docs/PLUGIN-PLATFORM-PLAN.md, stage A, points 3 to 8): read an add-on, work out what it is and uses, write a
// draft plugin and CONVERSION.md. The add-on's code is only read as text and parsed; nothing of it is run. Nothing is
// invented: the abilities come from the original's own calls and from nowhere else.
import Foundation
import TurnOverCore

nonisolated public struct ConvertOptions {
    public var convertedBy: String?
    public init(convertedBy: String? = nil) { self.convertedBy = convertedBy }
}

nonisolated public struct ConvertResult {
    public var id = ""
    public var version = ""
    public var madePlugin = false
    /// Files for the draft, in the order they are written. Without a plugin there is only CONVERSION.md.
    public var files: [(name: String, data: Data)] = []
    /// The report in plain words; CONVERSION.md carries it too.
    public var report = ""
    public var commandsCarried = 0, commandsComplete = 0, eventsCarried = 0, notCarried = 0
    public var abilities: [String] = []
    public var verdict: StoreVerdict = .needsWork
    public var verdictReason: String?
    /// What the translation brief says about the add-on (written beside the draft by `convert`, never with --report-only).
    public var briefInfo: ConvertBrief.Info?
}

nonisolated public enum AddonConverter {
    // MARK: manifest.ini

    struct Ini { var values: [String: String] = [:]; subscript(_ k: String) -> String? { values[k.lowercased()] } }

    static func parseIni(_ text: String) -> Ini {
        var ini = Ini()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") || line.hasPrefix("[") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, let l = value.last, (f == "\"" && l == "\"") || (f == "'" && l == "'") { value = String(value.dropFirst().dropLast()) }
            if ini.values[key] == nil { ini.values[key] = value }
        }
        return ini
    }

    // MARK: Small helpers

    /// One line of text safe inside a // comment: control characters and every kind of line break become spaces, so original text can
    /// never end the comment and start code.
    static func comment(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { u in
            (u.value < 0x20 && u.value != 9) || (0x7F...0x9F).contains(u.value) || u.value == 0x2028 || u.value == 0x2029 ? " " : u
        }))
    }

    static func plain(_ s: String, limit: Int = 300) -> String {
        let flat = comment(s).components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        var t = String(decoding: data, as: UTF8.self)
        t = String(t.dropFirst().dropLast())
        return t.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    static func identifier(_ method: String) -> String {
        var name = method
        if name.hasPrefix("script_") { name = String(name.dropFirst(7)) }
        var out = "", up = false
        for ch in name {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { out += up ? String(ch).uppercased() : String(ch); up = false } else { up = !out.isEmpty }
        }
        if out.isEmpty || out.first!.isNumber { out = "command" + out }
        return String(out.prefix(60))
    }

    static func humanise(_ method: String) -> String {
        var name = method
        if name.hasPrefix("script_") { name = String(name.dropFirst(7)) }
        var out = ""
        for ch in name { if ch == "_" { out += " " } else if ch.isUppercase, !out.isEmpty, out.last != " " { out += " " + ch.lowercased() } else { out.append(ch) } }
        return out.prefix(1).uppercased() + out.dropFirst()
    }

    // MARK: Gestures

    /// An NVDA gesture as a TurnOver key, or why it cannot be one. `kb:NVDA+x` becomes `turnover+x`.
    static func translateGesture(_ gesture: String) -> (key: String?, why: String?) {
        var g = gesture
        guard let colon = g.firstIndex(of: ":") else { return (nil, "\(gesture) is not a keyboard gesture") }
        let kind = g[..<colon].lowercased()
        guard kind == "kb" || kind.hasPrefix("kb(") else { return (nil, "\(gesture) is not a keyboard gesture (braille and touch gestures have no equivalent)") }
        g = String(g[g.index(after: colon)...])
        let map = ["nvda": "turnover", "control": "control", "ctrl": "control", "shift": "shift", "alt": "option", "windows": "command", "win": "command"]
        let tokens = g.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let last = tokens.last, !last.isEmpty else { return (nil, "\(gesture) names no key") }
        var out: [String] = []
        for t in tokens.dropLast() {
            guard let m = map[t.lowercased()] else { return (nil, "\(gesture) uses the key \(t), which has no TurnOver equivalent") }
            out.append(m)
        }
        out.append(map[last.lowercased()] ?? last)
        let key = out.joined(separator: "+")
        guard KeyboardGesture(identifier: "kb:" + key) != nil else { return (nil, "\(gesture) becomes \(key), which is not a key TurnOver knows") }
        // The refusals PluginPolicy gives any command key: asked of a probe manifest that holds this one command.
        var probe = PluginManifest(id: "probe", name: "probe", version: "1", apps: [])
        probe.script = "main.js"
        probe.commands = [PluginCommand(id: "probe", description: "probe", key: key)]
        if let refusal = PluginPolicy.scriptRefusals(probe).first { return (nil, "\(gesture) becomes \(key), which TurnOver refuses a plugin: \(refusal.replacingOccurrences(of: "command probe: ", with: ""))") }
        return (key, nil)
    }

    // MARK: What was found

    struct Body { var lines: [String] = []; var translated = 0; var kept = 0 }

    struct Command {
        var id: String; var description: String; var key: String?; var gestures: [String]; var unbound: [String]
        var file: String; var owner: String; var method: String; var line: Int; var overlay: Bool; var body: Body
    }
    struct Handler {
        var nvda: String; var event: String; var file: String; var owner: String; var line: Int; var overlay: Bool; var body: Body
    }
    struct Dropped { var what: String; var why: String }

    struct Found {
        var commands: [Command] = []
        var handlers: [Handler] = []
        var notCarried: [Dropped] = []
        var abilities = Set<String>()
        /// For each ability, what the original used it for, in the converter's own words (the table's), for the first draft of `reasons`.
        var why: [String: Set<String>] = [:]
        var later = Set<String>()
        var unlisted = Set<String>()
        var programs: [String] = []
        var kinds = Set<String>()
        var driverNotes: [String] = []
        var unreadFiles: [Dropped] = []
        var libraryFiles = 0, otherFiles = 0
        var importsDropped: [String: String] = [:]
        var importsNever: [String: String] = [:]
        var labelRules: [String] = []
        var layers = false
        var patched = Set<String>()
    }

    // MARK: Reading

    static let skipDirectories: Set<String> = ["lib", "libs", "site-packages", "dist-packages", "vendor", "vendored", "third_party", "thirdparty", "extern", "__pycache__", "locale"]

    static func read(_ source: AddonSource, parser: ConvertParse) -> Found {
        var found = Found()
        let fm = FileManager.default
        let root = source.root.resolvingSymlinksInPath()
        var relatives: [String] = []
        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in walker where url.pathExtension == "py" {
                let p = url.resolvingSymlinksInPath().path
                if p.hasPrefix(root.path + "/") { relatives.append(String(p.dropFirst(root.path.count + 1))) }
            }
        }
        relatives.sort()
        var analysed = 0
        for rel in relatives {
            let comps = rel.split(separator: "/").map(String.init)
            if comps.dropLast().contains(where: { skipDirectories.contains($0) }) { found.libraryFiles += 1; continue }
            switch comps[0] {
            case "appModules", "globalPlugins":
                if comps.count == 2, comps[1] == "__init__.py" { continue }
                let isApp = comps[0] == "appModules"
                found.kinds.insert(isApp ? "app module" : "global plugin")
                if isApp {
                    let program = comps.count == 2 ? String(comps[1].dropLast(3)) : comps[1]
                    let named = program.lowercased().hasSuffix(".exe") ? program : program + ".exe"
                    if !found.programs.contains(named) { found.programs.append(named) }
                }
                guard analysed < 200 else { found.unreadFiles.append(Dropped(what: rel, why: "more than 200 Python files; the rest were not read")); continue }
                analysed += 1
                let analysis = parser.analyse(root.appendingPathComponent(rel))
                if !analysis.ok { found.unreadFiles.append(Dropped(what: rel, why: analysis.error ?? "it could not be read")); continue }
                collect(analysis, file: rel, into: &found)
            case "synthDrivers":
                found.kinds.insert("speech synthesizer driver"); found.driverNotes.append(rel)
            case "brailleDisplayDrivers":
                found.kinds.insert("braille display driver"); found.driverNotes.append(rel)
            case "visionEnhancementProviders":
                found.kinds.insert("vision enhancement provider"); found.driverNotes.append(rel)
            default:
                found.otherFiles += 1
            }
        }
        return found
    }

    static func isPluginClass(_ c: ConvertClass) -> Bool { c.bases.contains { $0.hasSuffix("GlobalPlugin") || $0.hasSuffix("AppModule") } }

    /// Why a function cannot come across, or nil.
    static func blockReason(_ m: ConvertMethod, fileReason: String?) -> String? {
        if let fileReason { return fileReason }
        if let p = m.patches.first { return "it replaces NVDA's own \(p), and patching NVDA is never allowed" }
        for name in Set(m.calls.keys).union(m.refs.keys).sorted() {
            if let row = ConvertMapping.row(for: name) {
                if row.fit == .never { return "\(name): \(row.why)" }
                continue
            }
            let root = String(name.split(separator: ".").first ?? "")
            if let why = ConvertMapping.neverModules[root] { return "\(name): \(why)" }
        }
        return nil
    }

    static func collect(_ a: ConvertFileAnalysis, file: String, into found: inout Found) {
        var fileReason: String?
        for imp in a.imports ?? [] {
            let root = String(imp.split(separator: ".").first ?? "")
            if let why = ConvertMapping.droppedModules[root] { found.importsDropped[root] = why }
            if let why = ConvertMapping.neverModules[root] {
                found.importsNever[root] = why
                if ConvertMapping.serviceModules.contains(root), fileReason == nil { fileReason = "the whole file is built on \(root): \(why)" }
            }
        }
        for patch in a.patches ?? [] { found.patched.insert(patch) }
        for c in a.classes ?? [] {
            let plugin = isPluginClass(c)
            let owner = c.name
            for m in c.methods {
                if m.name == "getScript" { found.layers = true }
                let isScript = m.name.hasPrefix("script_") || m.decorators.contains { $0.name == "scriptHandler.script" || $0.name == "script" }
                let isEvent = m.name.hasPrefix("event_")
                guard isScript || isEvent else { continue }
                let label = "\(file), \(owner).\(m.name), line \(m.line)"
                if let why = blockReason(m, fileReason: fileReason) { found.notCarried.append(Dropped(what: label, why: why)); continue }
                for name in m.calls.keys.sorted() {
                    if let row = ConvertMapping.row(for: name) {
                        if let ab = row.ability { found.abilities.insert(ab); found.why[ab, default: []].insert(row.why) }
                        if let l = row.later { found.later.insert(l) }
                    } else if let root = name.split(separator: ".").first.map(String.init), ConvertMapping.nvdaModules.contains(root), name != "scriptHandler.script", !name.hasPrefix("globalPluginHandler."), !name.hasPrefix("appModuleHandler.") {
                        found.unlisted.insert(name)
                    }
                }
                for name in m.refs.keys.sorted() { if let row = ConvertMapping.row(forReference: name), let l = row.later { found.later.insert(l) } }
                if isEvent {
                    let nvda = String(m.name.dropFirst(6))
                    guard let row = ConvertMapping.eventRow(for: nvda) else {
                        found.notCarried.append(Dropped(what: label, why: "the event \(nvda) is not in the table of events, so it was not guessed at")); continue
                    }
                    if nvda == "NVDAObject_init" { found.labelRules.append(label); continue }
                    guard let target = row.script else {
                        found.notCarried.append(Dropped(what: label, why: row.why + (row.later.map { " (a later stage: \($0))" } ?? ""))); if let l = row.later { found.later.insert(l) }; continue
                    }
                    if let ab = row.ability { found.abilities.insert(ab); found.why[ab, default: []].insert(row.why) }
                    found.handlers.append(Handler(nvda: nvda, event: target, file: file, owner: owner, line: m.line, overlay: !plugin, body: body(m)))
                } else {
                    let desc = m.decorators.compactMap(\.description).first(where: { !$0.isEmpty }) ?? (m.doc?.components(separatedBy: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })).map { $0.trimmingCharacters(in: .whitespaces) }
                    let bare = m.name.hasPrefix("script_") ? String(m.name.dropFirst(7)) : m.name
                    var gestures = m.decorators.compactMap(\.gesture) + m.decorators.flatMap { $0.gestures ?? [] }
                    for (g, target) in c.gestures where target == bare || target == m.name { gestures.append(g) }
                    var seen = Set<String>(); gestures = gestures.filter { seen.insert($0).inserted }
                    found.commands.append(Command(id: identifier(m.name), description: plain(desc ?? humanise(m.name), limit: 200), key: nil, gestures: gestures, unbound: [],
                                                  file: file, owner: owner, method: m.name, line: m.line, overlay: !plugin, body: body(m)))
                }
            }
        }
    }

    // MARK: Bodies

    static func literal(_ a: ConvertArg) -> String? {
        switch a.k {
        case "s": return a.v.map(jsString)
        case "b": return a.v
        case "n": if let v = a.v, v.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil { return v }; return nil
        default: return nil
        }
    }

    /// The mechanical translation where the mapping is exact and every argument is a plain literal; otherwise the original Python
    /// as comments under a line that says a person must write it.
    static func body(_ m: ConvertMethod) -> Body {
        var b = Body()
        var pending: [String] = []
        func flush() {
            guard !pending.isEmpty else { return }
            b.lines.append("// A PERSON MUST WRITE THIS: the original Python follows, not translated.")
            for l in pending { b.lines.append("//   " + comment(l)) }
            pending = []
        }
        for s in m.body {
            if let call = s.call, let name = call.name, let row = ConvertMapping.row(for: name) {
                if row.fit == .dropped {
                    flush(); b.translated += 1
                    b.lines.append("// Dropped (\(comment(row.why))): " + comment(s.source.first ?? ""))
                    continue
                }
                if row.fit == .exact, let template = row.template, call.args.count == row.argc, call.kwargs.isEmpty {
                    let lits = call.args.compactMap(literal)
                    if lits.count == call.args.count {
                        flush(); b.translated += 1
                        var js = template
                        for (i, l) in lits.enumerated() { js = js.replacingOccurrences(of: "{\(i)}", with: l) }
                        b.lines.append(js + ";")
                        continue
                    }
                }
            }
            b.kept += 1
            pending += s.source
        }
        flush()
        if m.bodyTruncated { b.lines.append("// A PERSON MUST WRITE THIS: the original has more than 200 statements; only the first 200 are shown above.") ; b.kept += 1 }
        if b.lines.isEmpty { b.lines.append("// The original has no statements to translate.") }
        return b
    }
}
