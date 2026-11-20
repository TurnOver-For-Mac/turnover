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
            if m.apps.isEmpty {
                manifestProblem(["apps"], m.convertedFrom != nil ? PluginConversion.notFinished : "a script needs apps: name the applications it works in, by bundle identifier")
            }
            // Every app (stage B, 16 Nov 2026): exactly ["*"] and the `everywhere` ability, the one without the other never.
            let asksEverywhere = (m.abilities ?? []).contains(ScriptAbility.everywhere.rawValue)
            let everyApp = m.apps == [PluginManifest.everyApp]
            if asksEverywhere, !everyApp {
                manifestProblem(["abilities"], "the everywhere ability means every app, so apps must be exactly [\"*\"]; to work in named apps, take everywhere out")
            }
            for (i, app) in m.apps.enumerated() where app.contains("*") || app.contains("?") {
                if app == PluginManifest.everyApp {
                    if m.apps.count > 1 { manifestProblem(["apps", String(i)], "\"*\" means every app and must be the only entry in apps") }
                    else if !asksEverywhere { manifestProblem(["apps", String(i)], "\"*\" (every app) needs the everywhere ability: add \"everywhere\" to abilities, and the person is asked to agree to it") }
                } else {
                    manifestProblem(["apps", String(i)], "a script works only in apps it names, so \"\(app)\" cannot be a pattern: give the bundle identifier (or exactly \"*\" with the everywhere ability)")
                }
            }
            out += checkScriptFile(in: folder, data: scriptData)
        } else if m.commands != nil {
            manifestProblem(["commands"], "commands need a script: add \"script\": \"\(scriptName)\" (and \"formatVersion\": 2), or take the commands out")
        } else if m.options != nil {
            manifestProblem(["options"], "options need a script: add \"script\": \"\(scriptName)\" (and \"formatVersion\": 2), or take the options out")
        }
        // Options: what the person can set, shown in TurnOver's menu (the author's words, plain and short).
        if let options = m.options {
            if options.count > PluginOption.maxCount { manifestProblem(["options"], "a plugin may have at most \(PluginOption.maxCount) options") }
            var ids = Set<String>()
            for (i, option) in options.enumerated() {
                for why in option.problems() { manifestProblem(["options", String(i)], "option \(i + 1): " + why) }
                if !ids.insert(option.id).inserted { manifestProblem(["options", String(i), "id"], "option \(i + 1): the id \"\(option.id)\" is used twice") }
            }
        }
        // The author's reasons: for an ability, a sentence in plain text, short. Whether one is wanted is the library's check.
        for (ability, reason) in (m.reasons ?? [:]).sorted(by: { $0.key < $1.key }) {
            if !ScriptAbility.allCases.map(\.rawValue).contains(ability) {
                manifestProblem(["reasons", ability], "reasons names \"\(ability)\", which is not an ability (\(ScriptAbility.allCases.map(\.rawValue).joined(separator: ", ")))")
            }
            if reason.count > ScriptAbilities.reasonCharacters { manifestProblem(["reasons", ability], "the reason for \(ability) is \(reason.count) characters; at most \(ScriptAbilities.reasonCharacters)") }
            else if !PluginText.isPlain(reason) { manifestProblem(["reasons", ability], "the reason for \(ability) must be plain text, with no line breaks or control characters") }
        }
        if let support = m.support, support.count > 300 || !PluginText.isPlain(support) {
            manifestProblem(["support"], "support must be a web address or an email address on one line, at most 300 characters")
        }
        var seen = Set<String>()
        for (i, c) in (m.commands ?? []).enumerated() {
            if c.id.isEmpty || !isValidCommandID(c.id) {
                manifestProblem(["commands", String(i), "id"], "command \(i + 1): the id \"\(c.id)\" must be letters and digits only (no spaces, hyphens or punctuation): the script names it in code")
            } else if !seen.insert(c.id).inserted {
                manifestProblem(["commands", String(i), "id"], "command \(i + 1): the id \"\(c.id)\" is used twice")
            }
            if let letter = c.letter?.lowercased(), PluginCommands.reservedLetters.contains(letter) {
                out.append(Problem(file: "manifest.json", line: line(of: ["commands", String(i), "letter"], in: text) ?? line(of: ["commands", String(i)], in: text) ?? 1,
                                   message: "command \(i + 1) (\(c.id)): the letter \"\(letter)\" is one the TurnOver layer keeps for its own command, so the letter will do nothing; choose another letter (not M, N, S, R, T, D, A, K, J, H, I, C, G, V, E or the slash)", isError: false))
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
        guard let data = given ?? folder.flatMap({ readBounded($0.appendingPathComponent(scriptName), limit: scriptBytes) }) else {
            return problem("is missing or cannot be read: the manifest says this plugin has a script")
        }
        // The size first: nothing is decoded that is larger than a script may be (and a file is read only to one byte past it).
        guard data.count <= scriptBytes else { return problem("is larger than \(scriptBytes / 1024) KB; a script may be at most \(scriptBytes / 1024) KB") }
        guard String(data: data, encoding: .utf8) != nil else { return problem("is not text in UTF-8") }
        return []
    }
}
