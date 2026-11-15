// SPDX-License-Identifier: GPL-3.0-or-later
// The draft: manifest.json, main.js and CONVERSION.md, and the plain-words report (docs/PLUGIN-PLATFORM-PLAN.md, stage A,
// points 5, 6 and 8). Everything here is built from what the reading found; nothing is added that the original did not need.
import Foundation
import TurnOverCore

nonisolated extension AddonConverter {
    static func licence(in root: URL) -> (name: String?, file: (String, Data)?) {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        for n in names where n.lowercased().hasPrefix("license") || n.lowercased().hasPrefix("licence") || n.lowercased().hasPrefix("copying") {
            guard let data = PluginFormat.readBounded(root.appendingPathComponent(n), limit: 100_000), data.count <= 100_000, let text = String(data: data, encoding: .utf8) else { continue }
            let t = text.lowercased()
            var name: String?
            if t.contains("gnu general public license") { name = t.contains("version 3, 29 june 2007") ? "GPL v3" : t.contains("version 2, june 1991") ? "GPL v2" : "GPL" }
            else if t.contains("mit license") { name = "MIT" } else if t.contains("apache license") { name = "Apache-2.0" }
            return (name, ("LICENSE-ORIGINAL.txt", data))
        }
        return (nil, nil)
    }

    static func pluralise(_ n: Int, _ one: String, _ many: String? = nil) -> String { "\(n) \(n == 1 ? one : (many ?? one + "s"))" }

    public static func convert(source: AddonSource, options: ConvertOptions = ConvertOptions(), parser: ConvertParse) throws -> ConvertResult {
        guard let iniData = PluginFormat.readBounded(source.root.appendingPathComponent("manifest.ini"), limit: 200_000), iniData.count <= 200_000,
              let iniText = String(data: iniData, encoding: .utf8) else { throw ConvertFailure("manifest.ini could not be read, so this is not an NVDA add-on.") }
        let ini = parseIni(iniText)
        guard let addonID = ini["name"], !addonID.isEmpty, let addonVersion = ini["version"], !addonVersion.isEmpty else {
            throw ConvertFailure("manifest.ini has no name or no version, so this is not an NVDA add-on.")
        }
        let entry = source.storeEntry
        let found = read(source, parser: parser)
        let lic = licence(in: source.root)
        let licenceName = entry?.license ?? lic.name
        let creator = plain(ini["author"] ?? entry?.author ?? "", limit: 200)
        let converter = plain(options.convertedBy ?? "", limit: 200)
        let displayName = plain(ini["summary"] ?? entry?.name ?? addonID, limit: 120)

        // Keys: each command's first gesture that is a key TurnOver allows and has not been taken; the others are reported.
        var commands = found.commands
        var usedKeys = Set<String>(), usedIDs = Set<String>()
        for i in commands.indices {
            var base = commands[i].id, n = 2
            while usedIDs.contains(base) { base = commands[i].id + String(n); n += 1 }
            commands[i].id = base; usedIDs.insert(base)
            for g in commands[i].gestures {
                let t = translateGesture(g)
                if let k = t.key {
                    if commands[i].key == nil, !usedKeys.contains(k.lowercased()) { commands[i].key = k; usedKeys.insert(k.lowercased()) }
                    else if commands[i].key == nil { commands[i].unbound.append("\(g) becomes \(k), but another command already has that key") }
                } else if let why = t.why { commands[i].unbound.append(why) }
            }
        }

        var abilities = found.abilities
        // A global plugin works in every app in NVDA, so its draft asks for exactly that, and says so (stage B). An add-on that also has an
        // app module names programs, and keeps its apps for a person to choose.
        let everywhere = found.kinds.contains("global plugin") && !found.kinds.contains("app module")
        var why = found.why
        if everywhere { abilities.insert("everywhere"); why["everywhere"] = ["the original is a global plugin, which works in every app"] }
        if !found.handlers.isEmpty { /* the events' own abilities were added when each was found */ }
        let abilityList = abilities.sorted()
        abilities = Set(abilityList)

        let carried = commands.count + found.handlers.count
        var result = ConvertResult()
        result.id = addonID; result.version = addonVersion
        result.commandsCarried = commands.count
        result.commandsComplete = commands.filter { $0.body.kept == 0 }.count
        result.eventsCarried = found.handlers.count
        result.notCarried = found.notCarried.count + found.labelRules.count
        result.abilities = abilityList
        result.madePlugin = carried > 0

        // MARK: main.js
        var js: [String] = []
        if result.madePlugin {
            js.append("// main.js: a DRAFT made by turnover-plugin convert from the NVDA add-on \"\(comment(displayName))\" (\(comment(addonID)) \(comment(addonVersion))).")
            js.append("// Original author: \(creator.isEmpty ? "not named" : creator). Licence of the original: \(licenceName.map(comment) ?? "not known: find it before sharing this").")
            if let u = source.sourceURL ?? entry?.sourceURL { js.append("// Source of the original: \(comment(u))") }
            js.append("// This is a derived work of that add-on and keeps its author and licence. The store does not review code, and nobody has read this.")
            js.append("// A person must read every line before approving it. Lines under \"A PERSON MUST WRITE THIS\" are the original Python, not translated.")
            js.append("")
            for c in commands {
                js.append("turnover.command(\(jsString(c.id)), async function (context) {")
                js.append("  // From \(comment(c.file)), \(comment(c.owner)).\(comment(c.method)), line \(c.line)\(c.overlay ? ". In NVDA this worked only on one kind of control; here it works in the whole app" : "").")
                for g in c.gestures { js.append("  // NVDA gesture: \(comment(g))") }
                for u in c.unbound { js.append("  // Left unbound: \(comment(u))") }
                for l in c.body.lines { js.append("  " + l) }
                js.append("});")
                js.append("")
            }
            var events: [String: [Handler]] = [:]
            for h in found.handlers { events[h.event, default: []].append(h) }
            for name in events.keys.sorted() {
                let list = events[name]!
                js.append("turnover.on(\(jsString(name)), async function (event) {")
                for h in list {
                    if list.count > 1 { js.append("  {") }
                    let pad = list.count > 1 ? "    " : "  "
                    js.append(pad + "// From event_\(comment(h.nvda)) in \(comment(h.file)), \(comment(h.owner)), line \(h.line)\(h.overlay ? " (on one kind of control in NVDA)" : "").")
                    for l in h.body.lines { js.append(pad + l) }
                    if list.count > 1 { js.append("  }") }
                }
                js.append("});")
                js.append("")
            }
        }
        let mainJS = js.joined(separator: "\n")

        // MARK: manifest.json
        var manifest = PluginManifest(id: "x", name: displayName, version: plain(addonVersion, limit: 40), author: creator.isEmpty ? nil : creator, description: nil, apps: everywhere ? [PluginManifest.everyApp] : [])
        var idBase = addonID.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
        while idBase.contains("--") { idBase = idBase.replacingOccurrences(of: "--", with: "-") }
        idBase = idBase.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        manifest.id = String(("nvda-" + (idBase.isEmpty ? "addon" : idBase)).prefix(64))
        let about = plain(ini["description"] ?? entry?.description ?? "", limit: 400)
        manifest.description = (about.isEmpty ? "" : about + " ") + "A draft converted from the NVDA add-on \(addonID) by turnover-plugin convert. A person must read it before approving it."
        manifest.summary = String("Draft converted from the NVDA add-on \(displayName)".prefix(120))
        manifest.license = licenceName
        manifest.formatVersion = 2
        manifest.abilities = abilityList
        // A first reason for each ability, from what the original used it for: the table's own words, never the add-on's, for a person
        // to correct. Plain text, cut to 150 characters.
        var reasons: [String: String] = [:]
        for a in abilityList where ScriptAbilities.needsReason(ScriptAbility(rawValue: a) ?? .read) || !(why[a] ?? []).isEmpty {
            let uses = (why[a] ?? []).sorted().joined(separator: "; ")
            guard !uses.isEmpty else { continue }
            var text = "In the original add-on: " + uses + "."
            if text.count > ScriptAbilities.reasonCharacters { text = String(text.prefix(ScriptAbilities.reasonCharacters - 1)) + "…" }
            reasons[a] = text
        }
        if !reasons.isEmpty { manifest.reasons = reasons }
        manifest.script = "main.js"
        manifest.commands = commands.map { PluginCommand(id: $0.id, description: $0.description, key: $0.key) }
        manifest.changes = [PluginChange(version: manifest.version, notes: "Converted from the NVDA add-on \(addonID) version \(addonVersion).")]
        var record = PluginConversionRecord(id: addonID, version: addonVersion, sha256: source.sha256, sourceURL: source.sourceURL ?? entry?.sourceURL,
                                            author: creator.isEmpty ? nil : creator, convertedBy: converter.isEmpty ? nil : converter,
                                            abilities: abilityList, apps: everywhere ? [PluginManifest.everyApp] : found.programs)
        record.sha256 = source.sha256
        manifest.convertedFrom = record
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifestData = (try? encoder.encode(manifest)) ?? Data()

        // MARK: the report
        var r: [String] = []
        r.append("# Converting the NVDA add-on \(displayName)")
        r.append("")
        r.append("## Read this first")
        r.append("This is a draft made by turnover-plugin convert. It is not finished, and it is not safe because it came from NVDA's store: the store does not review code, and nothing was run or tried here. A person must read every line before approving it.")
        r.append("")
        r.append("## Where it came from")
        r.append("The add-on is \(addonID), version \(addonVersion). Its creator is \(creator.isEmpty ? "not named in manifest.ini" : creator). It was converted by \(converter.isEmpty ? "nobody named yet: a converted plugin must say who converted it before it can be shared (run the conversion again with --converted-by \"Name\", or add convertedBy to convertedFrom)" : converter).")
        switch source.origin {
        case .store: r.append("It was fetched from NVDA's store and its SHA-256 matched the store's list.")
        case .file(let p): r.append("It was read from the file \(p).")
        case .folder(let p): r.append("It was read from the folder \(p), so there is no SHA-256 to record.")
        }
        if let h = source.sha256 { r.append("SHA-256: \(h).") }
        if let u = source.sourceURL ?? entry?.sourceURL { r.append("Where its source can be read: \(u).") }
        r.append("")
        r.append("## What the add-on is")
        let kinds = found.kinds.sorted()
        r.append(kinds.isEmpty ? "No global plugin, app module or driver was found in it." : "It contains: \(ListFormatter.localizedString(byJoining: kinds)).")
        if !found.programs.isEmpty { r.append("The program\(found.programs.count == 1 ? "" : "s") it names: \(found.programs.joined(separator: ", ")). These are Windows programs.") }
        if found.libraryFiles > 0 { r.append("\(pluralise(found.libraryFiles, "Python file")) in bundled library folders were not read.") }
        if found.otherFiles > 0 { r.append("\(pluralise(found.otherFiles, "other Python file")) outside the plugin folders \(found.otherFiles == 1 ? "was" : "were") not read; they are not carried over (an install task would run when the add-on is installed in NVDA, and nothing like that comes across).") }
        for (f) in found.unreadFiles { r.append("The file \(f.what) was not read: \(f.why).") }
        for note in found.driverNotes.prefix(3) { r.append("It holds a driver, \(note). Voices and displays are TurnOver's own, so a driver never comes across.") }
        if !found.importsDropped.isEmpty {
            r.append("Dropped on purpose: " + found.importsDropped.keys.sorted().map { "\($0) (\(found.importsDropped[$0]!))" }.joined(separator: "; ") + ".")
        }
        r.append("")
        r.append("## What carried over")
        if !result.madePlugin {
            r.append("Nothing. No command and no event handler could be carried over, so no plugin was made. This report is all there is.")
        } else {
            r.append("\(pluralise(commands.count, "command")) and \(pluralise(found.handlers.count, "event handler")) carried over as handlers in main.js. \(pluralise(result.commandsComplete, "command")) \(result.commandsComplete == 1 ? "is" : "are") fully translated.")
            for c in commands {
                var line = "Command \(c.id): \(c.description)."
                line += c.key.map { " Key: \($0)." } ?? " No key."
                if c.body.kept > 0 { line += " \(pluralise(c.body.kept, "statement")) need\(c.body.kept == 1 ? "s" : "") a person." }
                r.append(line)
            }
            for h in found.handlers { r.append("Event handler for \(h.event), from event_\(h.nvda).\(h.body.kept > 0 ? " \(pluralise(h.body.kept, "statement")) need\(h.body.kept == 1 ? "s" : "") a person." : "")") }
        }
        r.append("")
        r.append("## What needs a person")
        var needs = 0
        if result.madePlugin {
            if everywhere {
                r.append("The apps are [\"*\"] and the draft asks for the everywhere ability, because a global plugin works in every app in NVDA. The person is asked to agree to that in plain words, and it is never in password and permission dialogs. The reasons in manifest.json are a first draft from what the original used each ability for: correct them before sharing.")
                needs += 1
            } else {
            r.append("The apps are empty. \(found.programs.isEmpty ? "A global plugin works in every app in NVDA, but a script here must name the apps it works in, so a person chooses them." : "The add-on named a Windows program, not a Mac app.") Find the Mac app's bundle identifier (for an app that is installed, run: osascript -e 'id of app \"Name\"' ; for one that is running, turnover-plugin snapshot <name> shows it), put it in apps in manifest.json, and add it to convertedFrom.apps as well, so the record shows the choice was made on purpose. Until then turnover-plugin check says this converted plugin is not finished.")
            needs += 1
            }
            for c in commands where c.body.kept > 0 { r.append("In command \(c.id), the original Python is kept as comments under a line saying a person must write it. Where it looked at NVDA objects, the Mac's items have to be found with turnover.find from a snapshot of the Mac app; the Windows selectors do not carry over."); needs += 1 }
            for c in commands where c.key == nil { r.append(c.gestures.isEmpty ? "Command \(c.id) had no key in the original." : "Command \(c.id) is left without a key: \(c.unbound.joined(separator: "; "))."); needs += 1 }
            for l in found.labelRules { r.append("\(l) renamed items when they were made. That is a label rule in profile.json, and it needs the Mac item found from a snapshot of the Mac app; no rule was written."); needs += 1 }
        }
        if converter.isEmpty { r.append("Say who converted it: --converted-by \"Name\"."); needs += 1 }
        if licenceName == nil { r.append("The licence is not known. Find it in the add-on's own files before sharing this."); needs += 1 }
        if !found.unlisted.isEmpty { r.append("Calls into NVDA with no equivalent known, not guessed at: \(found.unlisted.sorted().prefix(15).joined(separator: ", "))."); needs += 1 }
        if needs == 0 { r.append("Nothing beyond reading it.") }
        r.append("")
        r.append("## What can never come across, and why")
        if found.notCarried.isEmpty && found.importsNever.isEmpty && found.patched.isEmpty && found.layers == false { r.append("Nothing was found that the sandbox rules out.") }
        for d in found.notCarried { r.append("\(d.what) was not carried over: \(d.why).") }
        for (k, why) in found.importsNever.sorted(by: { $0.key < $1.key }) { r.append("It imports \(k): \(why), which a script can never do.") }
        for p in found.patched.sorted() { r.append("It replaces NVDA's own \(p): patching NVDA is never allowed, so whatever depends on it does not come across.") }
        if found.layers { r.append("It overrides getScript, which is how NVDA makes commands you press one key and then a letter. Commands are single keys here, so the layer was not carried over.") }
        r.append("")
        r.append("## What a later stage would carry")
        r.append(found.later.isEmpty ? "Nothing in this add-on waits on a later piece of the plan." : "Pieces of the plan's stage B would carry: \(found.later.sorted().joined(separator: "; ")).")
        r.append("")
        r.append("## The abilities the draft asks for")
        r.append(abilityList.isEmpty ? "None. The original's calls need no ability the converter knows, so manifest.json asks for none; a script needs at least one, so a person must decide before this passes check." : "\(abilityList.joined(separator: ", ")). They come from the original's own calls and nowhere else, and are recorded in convertedFrom. turnover-plugin check shows, as an error, any ability or app added to manifest.json that the record does not have.")
        r.append("")
        r.append("## Licence")
        r.append("This plugin is a derived work of the NVDA add-on \(displayName) (\(addonID) \(addonVersion)), created by \(creator.isEmpty ? "an author not named in manifest.ini" : creator). The original's licence is \(licenceName ?? "not known")\(lic.file != nil ? "; its licence file is kept as LICENSE-ORIGINAL.txt" : ""). The draft keeps the original author and licence, and nobody may relicense it. Whether that licence fits how TurnOver and its library share plugins is a question for a person to settle before sharing.")
        let reportText = r.joined(separator: "\n") + "\n"
        result.report = reportText

        // MARK: verdict
        if !result.madePlugin {
            result.verdict = .notForMac
            result.verdictReason = found.kinds.contains(where: { $0.contains("driver") }) ? "a driver: voices and displays are TurnOver's own" : "nothing in it can come across"
        } else if result.commandsComplete == commands.count, found.handlers.allSatisfy({ $0.body.kept == 0 }), found.notCarried.isEmpty, found.programs.isEmpty {
            result.verdict = .canConvert
        } else {
            result.verdict = .needsWork
            result.verdictReason = "\(carried) carried, \(result.notCarried) not, a person must finish it"
        }

        if result.madePlugin {
            result.files.append(("manifest.json", manifestData))
            result.files.append(("main.js", Data(mainJS.utf8)))
        }
        result.files.append(("CONVERSION.md", Data(reportText.utf8)))
        if result.madePlugin, let f = lic.file { result.files.append((f.0, f.1)) }
        return result
    }
}
