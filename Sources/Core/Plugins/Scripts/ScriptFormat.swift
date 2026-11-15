// SPDX-License-Identifier: GPL-3.0-or-later
// Format 2: the checks for a plugin that carries a script (docs/PLUGIN-SCRIPTS-PLAN.md, "The format"; 15 Nov 2026).
// Each problem names its file and line in words, as the format's other errors do. The rules for a command's key and
// letter are not here: they are the rules for a key in profile.json, and live in PluginPolicy.triggerRefusals (at
// load) and PluginListing.check (form, letter and clashes), which look at the commands as well as the keys.
import Foundation

nonisolated extension PluginFormat {
    /// Letters and digits only: what a command's id may be, because the script names it in code.
    static func isValidCommandID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9]+$"#, options: .regularExpression) != nil
    }

    /// The problems in a manifest's `script` and `commands`, and in main.js beside it. `text` is the manifest with its
    /// comments blanked (PluginFormat.clean), so lines match the file. Nothing if the manifest does not decode:
    /// the decoder's own error says so, and says it first.
    static func checkScript(folder: URL?, text: String, scriptData: Data? = nil) -> [Problem] {
        guard let m = try? JSONDecoder().decode(PluginManifest.self, from: Data(text.utf8)) else { return [] }
        var out: [Problem] = []
        /// At the line where `path` is, or where its first existing parent is.
        func manifestProblem(_ path: [String], _ message: String) {
            var p = path
            while !p.isEmpty, line(of: p, in: text) == nil { p.removeLast() }
            out.append(Problem(file: "manifest.json", line: line(of: p, in: text) ?? 1, message: message, isError: true))
        }
        if let script = m.script {
            if script != scriptName { manifestProblem(["script"], "script must be \"\(scriptName)\": a plugin has one script, and it has that name") }
            if (m.formatVersion ?? 1) < 2 { manifestProblem(["script"], "script needs \"formatVersion\": 2 (scripts are a format 2 feature)") }
            let abilityNames = ScriptAbility.allCases.map(\.rawValue)
            if (m.abilities ?? []).isEmpty {
                manifestProblem(["script"], "script needs abilities: list what the script may do (\(abilityNames.joined(separator: ", "))); the person is asked to agree to them")
            }
            for (i, a) in (m.abilities ?? []).enumerated() where !abilityNames.contains(a) {
                manifestProblem(["abilities", String(i)], "ability \"\(a)\" is not one a script can have (\(abilityNames.joined(separator: ", ")))")
            }
            if m.apps.isEmpty { manifestProblem(["apps"], "a script needs apps: name the applications it works in, by bundle identifier") }
            for (i, app) in m.apps.enumerated() where app.contains("*") || app.contains("?") {
                manifestProblem(["apps", String(i)], "a script works only in apps it names, so \"\(app)\" cannot be a pattern: give the bundle identifier")
            }
            out += checkScriptFile(in: folder, data: scriptData)
        } else if m.commands != nil {
            manifestProblem(["commands"], "commands need a script: add \"script\": \"\(scriptName)\" (and \"formatVersion\": 2), or take the commands out")
        }
        var seen = Set<String>()
        for (i, c) in (m.commands ?? []).enumerated() {
            if c.id.isEmpty || !isValidCommandID(c.id) {
                manifestProblem(["commands", String(i), "id"], "command \(i + 1): the id \"\(c.id)\" must be letters and digits only (no spaces, hyphens or punctuation): the script names it in code")
            } else if !seen.insert(c.id).inserted {
                manifestProblem(["commands", String(i), "id"], "command \(i + 1): the id \"\(c.id)\" is used twice")
            }
            if c.description.trimmingCharacters(in: .whitespaces).isEmpty {
                manifestProblem(["commands", String(i), "description"], "command \(i + 1) (\(c.id)) needs a description: it is what input help reads")
            }
        }
        return out
    }

    /// main.js itself: there, UTF-8 text, and small enough.
    static func checkScriptFile(in folder: URL?, data given: Data? = nil) -> [Problem] {
        func problem(_ message: String) -> [Problem] { [Problem(file: scriptName, line: nil, message: message, isError: true)] }
        guard let data = given ?? folder.flatMap({ try? Data(contentsOf: $0.appendingPathComponent(scriptName)) }) else {
            return problem("is missing or cannot be read: the manifest says this plugin has a script")
        }
        guard String(data: data, encoding: .utf8) != nil else { return problem("is not text in UTF-8") }
        guard data.count <= scriptBytes else { return problem("is \(data.count / 1024) KB; a script may be at most \(scriptBytes / 1024) KB") }
        return []
    }
}
