// SPDX-License-Identifier: GPL-3.0-or-later
// Checking a plugin against the running app (turnover-plugin check, and the TurnOver menu's
// "Install a plugin from the clipboard"): what each rule matches, what TurnOver will say,
// and the problems to fix. Plain lines, so the same report serves an AI and a person.
import Foundation
import AppKit
import ApplicationServices

public enum PluginChecker {
    public struct Report {
        public var lines: [String] = []
        public var problems = 0
        /// Rules that match nothing now (often because their screen is not showing): warnings, not failures.
        public var unmatched = 0
        public var summary: String = ""
    }

    static func describe(_ m: ElementMatch) -> String {
        String(data: (try? JSONEncoder().encode(m)) ?? Data(), encoding: .utf8) ?? "?"
    }

    /// What a plugin can do to the application, in words, for the person installing it: every key that sends keys
    /// or chooses a menu item, and whether any of them is one to think about (quit, delete, send). A plugin cannot
    /// run code, read files or use the network; these are its only teeth (8 Oct 2026).
    /// The checker waits longer than a key does: a slow, deep app (Libation, .NET's Avalonia) ran out of time a few levels
    /// down, and every rule "matched nothing" (parts request #6, 14 Oct 2026). A check isn't in the middle of typing.
    nonisolated static let patience: TimeInterval = 6

    public static func warnings(for plugin: LoadedPlugin) -> (lines: [String], needsConfirmation: Bool) {
        guard let m = plugin.manifest, let p = plugin.profile else { return ([], false) }
        let app = m.apps.compactMap { b in NSRunningApplication.runningApplications(withBundleIdentifier: b).first?.localizedName }.first ?? m.name
        // Which apps it claims, said first: a pasted answer that named Mail beside the app the brief was for went into
        // Mail without a word (a code review, 14 Oct 2026).
        let appNames = m.apps.map { b in NSRunningApplication.runningApplications(withBundleIdentifier: b).first?.localizedName
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: b).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? b }
        var lines: [String] = ["it works in \(appNames.joined(separator: " and "))"]; var risky = false
        let riskyKeys = ["command+q", "delete", "backspace", "command+w", "forwarddelete"]
        let riskyWords = ["quit", "delete", "trash", "send", "remove", "erase", "format"]
        for rule in p.keys ?? [] {
            let key = KeyboardGesture(identifier: "kb:" + rule.key)?.displayName ?? rule.key
            switch rule.action {
            case "keys":
                let sent = rule.keys.flatMap { KeyboardGesture(identifier: "kb:" + $0)?.displayName } ?? (rule.keys ?? "?")
                lines.append("\(key) sends \(sent) to \(app)")
                // Any key it sends acts in the app, whatever the words say (the code review: English risk words missed
                // "Senden", Command Return, Command Shift D): asked twice.
                risky = true
                _ = riskyKeys
            case "menu":
                let path = (rule.menu ?? []).joined(separator: ", ")
                lines.append("\(key) chooses the menu item \(path) in \(app)")
                risky = true
                _ = riskyWords
            default: break
            }
        }
        // A plugin for an app closed to community plugins (passwords, security, settings, terminals, browsers): fine
        // on your own Mac, said plainly before installing, and asked twice. (The library's other rules don't matter
        // on your own Mac; turnover-plugin check --listing has them.)
        // A plugin claiming the games feature (15 Oct 2026: Steam is built into TurnOver, so such a plugin changes
        // nothing; the old warning about the debugging port stays, since that is what Steam support does).
        if m.provides == "games" {
            lines.append("it says it provides game speech: TurnOver works with Steam on its own, so this plugin adds nothing to that")
            lines.append("to read Big Picture, TurnOver puts a file in Steam's folder that turns on Steam's debugging port. While Steam is open, any program on this Mac could control Steam's pages through that port. Remove this plugin to stop it, then restart Steam")
            risky = true
        }
        for b in m.apps { if let name = PluginPolicy.closedApps[b] { lines.append("it works in \(name), which only official plugins may do in the library: be sure you trust it"); risky = true } }
        return (lines, risky)
    }

    public static func check(_ plugin: LoadedPlugin, read: Bool = false) -> Report {
        var r = Report()
        func line(_ s: String) { r.lines.append(s) }
        guard let manifest = plugin.manifest, let profile = plugin.profile else {
            r.problems = 1; r.summary = "does not load: \(plugin.error ?? "?")"; line("The plugin does not load: \(plugin.error ?? "?")"); return r
        }
        line("\(manifest.name) \(manifest.version): loads. For: \(manifest.apps.joined(separator: ", "))")
        if let v = profile.view {
            line("A \(v.kind) view for \(manifest.apps.joined(separator: ", ")).")
            if let c = v.chat, let recipe = plugin.recipes.first {
                line("  message box \(c.composer), messages \(c.transcript), conversations \(c.conversations), title \(c.title)")
                if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == recipe.bundle }) {
                    // Each named part should be in the app's window now.
                    let root = AXUIElementCreateApplication(app.processIdentifier)
                    for (what, id) in [("message box", c.composer), ("messages", c.transcript), ("conversations", c.conversations), ("title", c.title)] {
                        var queue = root.elements(kAXWindowsAttribute); var n = 0; var found = false
                        while let e = queue.first, n < 3000 { queue.removeFirst(); n += 1; if e.string(kAXIdentifierAttribute) == id { found = true; break }; queue += e.elements(kAXChildrenAttribute) }
                        if found { line("  \(what) \(id): found") } else { line("  PROBLEM: \(what) \(id) is not in the window now (open a conversation and check again?)"); r.problems += 1 }
                    }
                } else { line("  \(recipe.name) is not running, so its parts cannot be looked for.") }
            }
        }
        if manifest.id.isEmpty || manifest.id.contains("/") || manifest.id.contains(" ") { line("PROBLEM: id must be a short word without spaces or slashes"); r.problems += 1 }
        let counts = "\(profile.labels?.count ?? 0) labels, \(profile.keys?.count ?? 0) keys, \(profile.watch?.count ?? 0) watched, \(profile.silence?.count ?? 0) silenced"
        guard let app = NSWorkspace.shared.runningApplications.first(where: { manifest.apps.contains($0.bundleIdentifier ?? "") }) else {
            line("None of its apps is running, so the rules cannot be tried. Open \(manifest.apps.first ?? "the app") and check again.")
            r.summary = counts
            return r
        }
        let pid = app.processIdentifier
        ProfileStore.shared.addTesting(plugin)

        for (i, rule) in (profile.labels ?? []).enumerated() {
            let found = ElementMatcher.find(rule.match, pid: pid, limit: 20, budget: Self.patience)
            line("\nlabel \(i + 1): \(describe(rule.match))")
            if found.isEmpty { line("  PROBLEM: matches nothing in \(app.localizedName ?? "the app") as it is now"); r.problems += 1; r.unmatched += 1; continue }
            line("  matches \(found.count)\(found.count == 20 ? " or more" : "")")
            for e in found.prefix(6) {
                let said = Speech.objectPropertiesSpeech(ObjectFactory.make(e), reason: .focus).joined(separator: ", ")
                line("  TurnOver says: \(said.isEmpty ? "(nothing)" : said)")
                if rule.name == nil, rule.nameFrom != nil, ProfileStore.shared.label(for: e, pid: pid)?.0 == nil { line("  PROBLEM: nameFrom \"\(rule.nameFrom!)\" found no text for this one"); r.problems += 1 }
            }
        }
        for (i, rule) in (profile.keys ?? []).enumerated() {
            line("\nkey \(i + 1): \(rule.key), \(rule.action): \(rule.description)")
            let id = rule.key.hasPrefix("kb") ? rule.key : "kb:" + rule.key
            if let g = KeyboardGesture(identifier: id) {
                for (bid, sc) in GlobalCommands.shared.allBindings where normalizeGestureIdentifier(bid) == normalizeGestureIdentifier(id) {
                    line("  NOTE: in this app it replaces TurnOver's own \(g.displayName): \(sc.description). Pick another key unless that is wanted.")
                }
            } else { line("  PROBLEM: \"\(rule.key)\" is not a key TurnOver knows (see PLUGIN-GUIDE.md, Keys)"); r.problems += 1 }
            switch rule.action {
            case "press", "focus", "read":
                guard let t = rule.target else { line("  PROBLEM: \(rule.action) needs a target"); r.problems += 1; break }
                if let e = ElementMatcher.findOne(t, pid: pid, budget: Self.patience) {
                    line("  acts on: \(Speech.objectPropertiesSpeech(ObjectFactory.make(e), reason: .focus).joined(separator: ", "))")
                    if rule.action == "press" {
                        var acts: CFArray?; AXUIElementCopyActionNames(e, &acts)
                        if !((acts as? [String]) ?? []).contains("AXPress") { line("  PROBLEM: that element cannot be pressed"); r.problems += 1 }
                    }
                } else { line("  PROBLEM: target matches nothing now (it may only exist on another screen: check there)"); r.problems += 1; r.unmatched += 1 }
            case "menu":
                guard let path = rule.menu, !path.isEmpty else { line("  PROBLEM: menu needs a path"); r.problems += 1; break }
                if let item = MenuPath.find(path, pid: pid) {
                    line("  menu item: \(item.string(kAXTitleAttribute) ?? "?")\((item.attr(kAXEnabledAttribute) as? Bool) == false ? " (disabled now)" : "")")
                } else { line("  PROBLEM: no menu item \(path.joined(separator: " > ")) (see turnover-plugin menus)"); r.problems += 1 }
            case "keys":
                if rule.keys.flatMap({ KeyboardGesture(identifier: "kb:" + $0) }) == nil { line("  PROBLEM: keys \"\(rule.keys ?? "")\" is not a key combination TurnOver knows"); r.problems += 1 }
            case "say":
                if (rule.say ?? "").isEmpty { line("  PROBLEM: say needs text"); r.problems += 1 }
            default:
                line("  PROBLEM: unknown action \"\(rule.action)\" (press, focus, read, menu, keys, say)"); r.problems += 1
            }
        }
        for (i, rule) in (profile.watch ?? []).enumerated() {
            let found = ElementMatcher.find(rule.match, pid: pid, limit: 5, budget: Self.patience)
            line("\nwatch \(i + 1): \(describe(rule.match))")
            if found.isEmpty { line("  PROBLEM: matches nothing now"); r.problems += 1; r.unmatched += 1 }
            else { line("  matches \(found.count); now: \(rule.read == "text" ? ElementMatcher.text(of: found[0]) : (found[0].attr(kAXValueAttribute).map { "\($0)" } ?? ""))") }
        }
        for (i, m) in (profile.silence ?? []).enumerated() {
            let found = ElementMatcher.find(m, pid: pid, limit: 20, budget: Self.patience)
            line("\nsilence \(i + 1): \(describe(m))")
            if found.isEmpty { line("  PROBLEM: matches nothing now"); r.problems += 1; r.unmatched += 1 } else { line("  matches \(found.count)") }
        }
        if read {
            line("\n== web content as TurnOver reads it, with this plugin")
            let appEl = AXUIElementCreateApplication(pid)
            var queue = appEl.elements(kAXWindowsAttribute); var n = 0
            var areas: [AXUIElement] = []
            while !queue.isEmpty, n < 5000 { let e = queue.removeFirst(); n += 1; if e.role == "AXWebArea" { areas.append(e); continue }; queue.append(contentsOf: e.elements(kAXChildrenAttribute)) }
            if areas.isEmpty { line("(no web content in this app's windows)") }
            for a in areas {
                let b = WebBuffer(webArea: a)
                b.build()
                line("-- \(a.string(kAXDescriptionAttribute) ?? a.string(kAXTitleAttribute) ?? "page"): \(b.lines.count) lines")
                for l in b.lines.prefix(60) { line("  " + b.text.substring(with: NSRange(location: l.start, length: l.end - l.start)) + (l.isControl ? "   [\(l.fields.joined(separator: ", "))]" : "")) }
            }
        }
        line(r.problems == 0 ? "\nNo problems found." : "\n\(r.problems) problem\(r.problems == 1 ? "" : "s") to fix.")
        r.summary = counts
        return r
    }

    /// Install a loaded plugin into TurnOver's plugins folder; returns where.
    @discardableResult
    public static func install(_ plugin: LoadedPlugin) throws -> URL {
        guard let m = plugin.manifest else { throw NSError(domain: "TurnOver", code: 2, userInfo: [NSLocalizedDescriptionKey: plugin.error ?? "does not load"]) }
        // TurnOver's way in and way out stay its own, whoever installs (the plugin design notes, decision 4).
        if let why = PluginPolicy.refusals(plugin.profile).first {
            throw NSError(domain: "TurnOver", code: 5, userInfo: [NSLocalizedDescriptionKey: why])
        }
        let fm = FileManager.default
        guard PluginManifest.isValidID(m.id) else { throw NSError(domain: "TurnOver", code: 4, userInfo: [NSLocalizedDescriptionKey: "its id \"\(m.id)\" is not a plain name"]) }
        let dest = ProfileStore.folder.appendingPathComponent(m.id, isDirectory: true)
        // Never anything outside the plugins folder, whatever the id says.
        guard dest.standardizedFileURL.deletingLastPathComponent().path == ProfileStore.folder.standardizedFileURL.path else {
            throw NSError(domain: "TurnOver", code: 4, userInfo: [NSLocalizedDescriptionKey: "it would install outside the plugins folder"])
        }
        try fm.createDirectory(at: ProfileStore.folder, withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for f in ["manifest.json", "profile.json"] { try fm.copyItem(at: plugin.folder.appendingPathComponent(f), to: dest.appendingPathComponent(f)) }
        return dest
    }
}
