// SPDX-License-Identifier: GPL-3.0-or-later
// The library listing check (the plugin design notes, plugin decisions 3, 4 and 6; 13 Oct 2026): what a plugin must say about
// itself to be listed, whether the abilities it uses are the ones it declares, and whether its keys clash. Needs no
// running app, so the same check runs on a person's Mac (turnover-plugin check), at install, and on GitHub before a
// plugin is accepted. Plain lines, as PluginChecker's.
import Foundation

public enum PluginListing {
    /// The official modules' listings (Resources/official): built in, closed, listed like plugins (decision 7).
    public static var officialListings: [PluginManifest] {
        // Built into the program (make-embedded.py); a folder only where there are none (a test's checkout).
        if !EmbeddedResources.official.isEmpty {
            return EmbeddedResources.official.compactMap { EmbeddedResources.unpack($0.packed) }
                .compactMap { try? JSONDecoder().decode(PluginManifest.self, from: $0) }
        }
        let dir = Bundle.main.resourceURL?.appendingPathComponent("official")
            ?? URL(fileURLWithPath: "Resources/official")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
            .compactMap { try? JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: $0)) }
    }

    /// The fixed words for what a profile can do. Capability plugins add "helper", "voice", "network:<site>" (later).
    public static let abilities: [String: String] = [
        "read": "read its app's window",
        "press": "press buttons in its app",
        "focus": "move the focus in its app",
        "menu": "choose menu items in its app",
        "keys": "send key combinations to its app",
        "say": "say set words",
    ]
    /// Open licences the library accepts, by SPDX name. MIT is the library's own (13 Oct 2026).
    public static let openLicences = ["MIT", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "ISC", "MPL-2.0", "CC0-1.0", "Unlicense"]
    /// Keys no plugin may take: TurnOver's way in and its way out (the layer key; start or quit).
    nonisolated public static let essentialKeys = ["command+control+,", "command+control+."]

    /// What the profile actually does, in ability words.
    public static func abilitiesUsed(by p: Profile) -> Set<String> {
        var used = Set<String>()
        if !(p.labels ?? []).isEmpty || !(p.watch ?? []).isEmpty || !(p.silence ?? []).isEmpty || p.view != nil { used.insert("read") }
        if !(p.hold ?? []).isEmpty { used.insert("read"); used.insert("press") }
        for k in p.keys ?? [] {
            switch k.action {
            case "press": used.insert("press"); used.insert("read")
            case "focus": used.insert("focus"); used.insert("read")
            case "read": used.insert("read")
            case "menu": used.insert("menu")
            case "keys": used.insert("keys")
            case "say": used.insert("say")
            default: break
            }
            if k.say != nil { used.insert("say") }
        }
        return used
    }

    public struct Result {
        public var lines: [String] = []
        /// What stops a plugin being listed (or, for an essential key, installed at all).
        public var problems = 0
        /// Worth knowing, not stopping: a key that replaces one of TurnOver's in its app.
        public var notes = 0
    }

    /// The listing and key checks. `others`: keys of TurnOver's own and of other plugins, as (normalized identifier,
    /// what it is); passed in so the tests and the GitHub check can supply their own.
    public static func check(_ plugin: LoadedPlugin, others: [(String, String)]? = nil, level: PluginPolicy.Level = .community) -> Result {
        var r = Result()
        func problem(_ s: String) { r.lines.append("  PROBLEM: " + s); r.problems += 1 }
        func note(_ s: String) { r.lines.append("  NOTE: " + s); r.notes += 1 }
        guard let m = plugin.manifest else { problem("no manifest"); return r }
        r.lines.append("Listing:")
        func required(_ v: String?, _ field: String, _ what: String) {
            if (v ?? "").trimmingCharacters(in: .whitespaces).isEmpty { problem("\(field) is missing: \(what)") }
        }
        required(m.summary, "summary", "one line, spoken at install and in the library")
        if let s = m.summary, s.count > 120 { problem("summary is \(s.count) characters; keep it to one line (120 at most)") }
        required(m.description, "description", "a few sentences on what it does and why")
        required(m.author, "author", "who made it")
        required(m.contact, "contact", "an email address or web page for problems")
        required(m.privacy, "privacy", "what it reads and where anything goes (\"nothing leaves your Mac\")")
        if let l = m.license, !l.isEmpty {
            if !openLicences.contains(l) { problem("license \"\(l)\" is not an open licence the library accepts (\(openLicences.joined(separator: ", ")))") }
        } else { problem("license is missing: an open licence such as \"MIT\"") }
        if !(m.changes ?? []).contains(where: { $0.version == m.version }) { problem("changes has nothing for version \(m.version): say what this version changed") }

        // Abilities: declared in the fixed words, and the same as what it does.
        let declared = Set(m.abilities ?? [])
        for a in declared.subtracting(abilities.keys) { problem("ability \"\(a)\" is not one TurnOver knows (\(abilities.keys.sorted().joined(separator: ", ")))") }
        if let p = plugin.profile {
            let used = abilitiesUsed(by: p)
            for a in used.subtracting(declared).sorted() { problem("it can \(abilities[a] ?? a), but abilities doesn't say so: add \"\(a)\"") }
            for a in declared.intersection(abilities.keys).subtracting(used).sorted() { note("abilities says \"\(a)\" but nothing uses it: leave it out") }
        }

        // Keys: in the fixed form; never an essential key; clashes said.
        let essential = Set(essentialKeys.map { normalizeGestureIdentifier("kb:" + $0) })
        let known = others ?? defaultOthers(apps: m.apps)
        var seen: [String: String] = [:]
        var letters: [String: String] = [:]
        for k in plugin.profile?.keys ?? [] {
            guard let l = k.letter?.lowercased() else { continue }
            if l.count != 1 || !(l.first!.isLetter || l.first!.isNumber) { problem("letter \"\(k.letter!)\" for \(k.description): one letter or digit") }
            else if let other = letters[l] { problem("letter \(l) is used twice (\(other); \(k.description))") }
            letters[l] = k.description
        }
        for k in plugin.profile?.keys ?? [] {
            let id = normalizeGestureIdentifier(k.key.hasPrefix("kb:") ? k.key : "kb:" + k.key)
            guard let g = KeyboardGesture(identifier: id) else { problem("key \"\(k.key)\" is not in the fixed form (see PLUGIN-GUIDE.md, keys)"); continue }
            if k.description.trimmingCharacters(in: .whitespaces).isEmpty { problem("key \(g.displayName) has no description") }
            if essential.contains(id) { problem("\(g.displayName) is one of TurnOver's essential keys; no plugin can take it"); continue }
            if let first = seen[id] { problem("\(g.displayName) is used twice in this plugin (\(first); \(k.description))") }
            seen[id] = k.description
            for (other, what) in known where other == id {
                note("\(g.displayName) is also \(what); in \(m.name) this plugin's comes first")
            }
        }
        // What plugins may do (PluginPolicy): refusals anywhere, the library's own rules.
        let policy = PluginPolicy.check(plugin, level: level)
        for s in policy.refused { problem("refused: " + s) }
        for s in policy.libraryOnly { problem("not for the library: " + s) }
        r.lines.append(r.problems == 0 ? "  ready to list\(r.notes > 0 ? " (\(r.notes) note\(r.notes == 1 ? "" : "s"))" : "")" : "  \(r.problems) to fix before it can be listed")
        return r
    }

    /// A command's description cut at a word, for a line of the report.
    static func short(_ d: String) -> String {
        let plain = d.components(separatedBy: " (").first ?? d
        guard plain.count > 60 else { return plain.lowercased() }
        let cut = plain.prefix(60)
        return String(cut[..<(cut.lastIndex(of: " ") ?? cut.endIndex)]).lowercased() + "…"
    }

    /// TurnOver's own keys (both styles, VoiceOver's and NVDA's parity keys among them) and the installed plugins'.
    static func defaultOthers(apps: [String] = []) -> [(String, String)] {
        var out: [(String, String)] = []
        // The official module for the plugin's app (Word's keys for a Word plugin).
        for b in apps {
            guard let type = AppModuleHandler.shared.moduleType(for: b) else { continue }
            let module = type.init(pid: 0, bundleIdentifier: b, appName: b)
            for (id, scripts) in module.everyBinding {
                for s in scripts { out.append((normalizeGestureIdentifier(id), "the official module's \(short(s.description))")) }
            }
        }
        for (id, scripts) in GlobalCommands.shared.everyBinding {
            for s in scripts { out.append((normalizeGestureIdentifier(id), "TurnOver's \(short(s.description))")) }
        }
        let vo = VoiceOverKeysPlugin()
        for (id, scripts) in vo.everyBinding {
            for s in scripts { out.append((normalizeGestureIdentifier(id), "VoiceOver's \(short(s.description))")) }
        }
        for p in ProfileStore.shared.plugins {
            for k in p.profile?.keys ?? [] {
                out.append((normalizeGestureIdentifier(k.key.hasPrefix("kb:") ? k.key : "kb:" + k.key), "\(p.manifest?.name ?? "another plugin")'s \(k.description)"))
            }
        }
        return out
    }
}
