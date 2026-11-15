// SPDX-License-Identifier: GPL-3.0-or-later
// App profiles: the first kind of plugin (the plugin design notes, PLUGIN-GUIDE.md).
//
// A profile is data, never code: rules that match an application's elements and
// give them names, bind keys to actions on them, read them when they change, or
// keep them quiet. Profiles load from ~/Library/Application Support/TurnOver/plugins/
// <folder>/ (manifest.json + profile.json) and reload when their files change.
// Every rule applies only to the applications its manifest names.
import Foundation
import AppKit
import ApplicationServices

// MARK: - The format

nonisolated public struct PluginManifest: Codable {
    public var id: String
    public var name: String
    public var version: String
    public var author: String?
    public var description: String?
    /// Bundle identifiers of the applications the plugin works in. Nothing applies anywhere else.
    public var apps: [String]
    /// "profile" for now; "script" later (the plugin design notes, phase 3).
    public var kind: String?
    /// The format the plugin is written in (1 today; PluginFormat.currentVersion). Missing means 1.
    public var formatVersion: Int?
    /// The oldest TurnOver the plugin works with ("2.0").
    public var minimumTurnOver: String?
    // The library listing (the plugin design notes, plugin decision 3, 13 Oct 2026). Optional to load; required to be listed.
    /// One line, spoken at install and in the library.
    public var summary: String?
    /// An email address or web page for problems.
    public var contact: String?
    /// What changed in each version, newest first.
    public var changes: [PluginChange]?
    /// What it asks to do, in the fixed words (PluginAbilities): "read", "press", "focus", "menu", "keys", "say".
    public var abilities: [String]?
    /// What it reads and where anything goes: "Reads Bambu Studio's window; nothing leaves your Mac."
    public var privacy: String?
    /// An open licence, as an SPDX name: "MIT" (the library's own), "Apache-2.0" …
    public var license: String?
    /// A feature built into TurnOver that this plugin switches on: "games" (game speech) today (PluginPolicy.features).
    /// Acted on only for an official plugin installed from the library; anywhere else it does nothing. The code stays
    /// TurnOver's (closed); the plugin is how a tester chooses it (14 Oct 2026).
    public var provides: String?
    /// The plugin's script, always "main.js" (format 2; docs/PLUGIN-SCRIPTS-PLAN.md). Needs `abilities` and named `apps`.
    public var script: String?
    /// The commands the script handles, declared here so TurnOver can list them, check their keys and let the person
    /// rebind them without running anything. Format 2, with `script`.
    public var commands: [PluginCommand]?
    /// Where a plugin converted from an NVDA add-on came from, and what the original needed (PluginConversion). Nothing in
    /// it widens what the plugin may do: `check` reports an ability or app the manifest has and this record does not.
    public var convertedFrom: PluginConversionRecord?

    /// A plugin id: 1 to 64 letters, digits and hyphens, not starting with a hyphen. It names the plugin's folder.
    public static func isValidID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,63}$"#, options: .regularExpression) != nil
    }

    public init(id: String, name: String, version: String, author: String? = nil, description: String? = nil, apps: [String]) {
        self.id = id; self.name = name; self.version = version; self.author = author; self.description = description; self.apps = apps
    }
}

/// The record of a conversion from an NVDA add-on (docs/PLUGIN-PLATFORM-PLAN.md, stage A).
nonisolated public struct PluginConversionRecord: Codable, Equatable {
    /// The add-on's id, and its version.
    public var id: String
    public var version: String
    /// The SHA-256 of the add-on file that was read (none when a folder was converted), and where it came from.
    public var sha256: String?
    public var sourceURL: String?
    /// The creator: the original add-on's author. Credit only.
    public var author: String?
    /// Who converted it. Credit only; empty until the converter is told.
    public var convertedBy: String?
    /// The abilities the original's behaviour needed, and the programs it named (Windows program names, then any app
    /// a person chose for the Mac, written here as well as in `apps`).
    public var abilities: [String]?
    public var apps: [String]?
    public init(id: String, version: String, sha256: String? = nil, sourceURL: String? = nil, author: String? = nil, convertedBy: String? = nil,
                abilities: [String]? = nil, apps: [String]? = nil) {
        self.id = id; self.version = version; self.sha256 = sha256; self.sourceURL = sourceURL; self.author = author
        self.convertedBy = convertedBy; self.abilities = abilities; self.apps = apps
    }
}

/// One command of a plugin's script (manifest.json, format 2). A script never sees the key: it is told its command was chosen.
nonisolated public struct PluginCommand: Codable, Equatable {
    /// Letters and digits only: how the script names it (`turnover.command("readResult", …)`).
    public var id: String
    /// What it does, for input help and the shortcuts list.
    public var description: String
    /// A TurnOver gesture, as a key in profile.json is written.
    public var key: String?
    /// Its letter in the plugin layer, as a key's in profile.json.
    public var letter: String?
    public init(id: String, description: String, key: String? = nil, letter: String? = nil) {
        self.id = id; self.description = description; self.key = key; self.letter = letter
    }
}

nonisolated public struct PluginChange: Codable {
    public var version: String
    public var notes: String
    public init(version: String, notes: String) { self.version = version; self.notes = notes }
}

/// Which elements a rule means. Every field given must match; strings may use * as a wildcard,
/// and match case-insensitively.
nonisolated public struct ElementMatch: Codable {
    public var role: String?          // "AXButton", "AXImage" … ("button" and "image" work too)
    /// Any of these roles (for a view's items: a text or a heading).
    public var roles: [String]?
    public var subrole: String?
    public var identifier: String?    // AXIdentifier: the steadiest thing to match where the app sets it
    public var title: String?
    public var description: String?
    public var help: String?
    public var value: String?
    /// The element's own text (its static text, in order), for groups and rows.
    public var text: String?
    /// Its window's title.
    public var window: String?
    /// An ancestor that must also match (the toolbar, the sidebar …).
    public var inside: Box<ElementMatch>?
    /// The element's immediate parent must match.
    public var parent: Box<ElementMatch>?
    /// Only elements with no name of their own.
    public var unnamed: Bool?
    /// Only elements that can be pressed (AXPress), such as a clickable image.
    public var pressable: Bool?
    /// Of all the elements that match, only this one (1 is the first, -1 the last) — for keys that act on one element.
    public var nth: Int?
    /// Any of these matches (an "or"); the other fields are then ignored.
    public var any: [ElementMatch]?
    nonisolated public init() {}
}

/// A wrapper so a match can hold a match (inside), and JSON can write it plainly.
nonisolated public final class Box<T: Codable>: Codable {
    public let value: T
    public init(_ v: T) { value = v }
    public required init(from decoder: Decoder) throws { value = try T(from: decoder) }
    public func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

nonisolated public struct LabelRule: Codable {
    public var match: ElementMatch
    /// The name to speak.
    public var name: String?
    /// Or where to take it from: "nextText" (the text after the element, as on Bambu Studio's home page),
    /// "previousText", "childText", "help", "description", "parentText".
    public var nameFrom: String?
    /// The role to speak instead of the element's own ("button" for a pressable image).
    public var role: String?
}

nonisolated public struct KeyRule: Codable {
    /// A TurnOver gesture: "turnover+shift+p", "control+option+1", "f6". ("kb:" is optional.)
    public var key: String
    /// What it does, for input help and the shortcuts list.
    public var description: String
    /// "press", "focus", "read", "menu", "keys", "say".
    public var action: String
    /// The element for press, focus and read.
    public var target: ElementMatch?
    /// For "menu": the path, as the menus show it: ["File", "Export", "Export G-code…"].
    public var menu: [String]?
    /// For "keys": what to send the application: "command+shift+e".
    public var keys: String?
    /// For "say", or spoken after any other action.
    public var say: String?
    /// Its letter in the plugin layer: Command Control Comma, P, then this letter (one letter or digit, unique in the
    /// plugin; the plugin design notes 14). Every command is also in that layer's list.
    public var letter: String?
}

nonisolated public struct HoldRule: Codable {
    /// When the focus lands on an element like this (the grid)…
    public var focus: ElementMatch
    /// …TurnOver holds this one, whose children are the rows (inside the focused element, or anywhere in the window).
    public var items: ElementMatch
}

nonisolated public struct WatchRule: Codable {
    public var match: ElementMatch
    /// Spoken before the new value or text ("Progress").
    public var prefix: String?
    /// "value" (default) or "text".
    public var read: String?
}

nonisolated public struct Profile: Codable {
    public var labels: [LabelRule]?
    public var keys: [KeyRule]?
    public var watch: [WatchRule]?
    /// Lists TurnOver walks itself: where an app's list takes the keyboard but reports nothing as the arrows move
    /// (Libation's book grid: no focus, selection or value news), TurnOver holds it and moves its own cursor along
    /// its rows; Return and Space press the row (parts request #4, 14 Oct 2026).
    public var hold: [HoldRule]?
    /// Elements TurnOver should not announce when focus enters or lands on them.
    public var silence: [ElementMatch]?
    /// The app as a whole, as a shape TurnOver drives (a recipe: docs/APP-RECIPES-PLAN.md).
    public var view: RecipeView?
}

/// A loaded plugin, or the reason it could not load.
nonisolated public struct LoadedPlugin {
    public let folder: URL
    public let manifest: PluginManifest?
    public let profile: Profile?
    public let error: String?
    public let modified: Date
    /// Things to fix that do not stop it loading (an unknown field), each with its file and line.
    public let warnings: [String]
    /// The text of main.js, when the manifest names a script. Nothing runs it in this stage; a plugin with a script
    /// still works as a data plugin when scripts are off.
    public let script: String?
    /// ScriptTrust's hash of the plugin's files as they were read together at load (a receipt matches this).
    public let scriptHash: String?
    public init(folder: URL, manifest: PluginManifest?, profile: Profile?, error: String?, modified: Date, warnings: [String] = [],
                script: String? = nil, scriptHash: String? = nil) {
        self.folder = folder; self.manifest = manifest; self.profile = profile; self.error = error; self.modified = modified; self.warnings = warnings
        self.script = script; self.scriptHash = scriptHash
    }
    /// The plugin's view, as a recipe for each app its manifest names (none without a view section).
    public var recipes: [Recipe] {
        guard let m = manifest, let v = profile?.view else { return [] }
        return m.apps.map { Recipe(bundle: $0, name: m.name, view: v) }
    }
}

// MARK: - Matching

nonisolated public enum ElementMatcher {
    private static let timeoutLock = NSLock()
    nonisolated(unsafe) private static var timeoutSet = Set<pid_t>()   // under `timeoutLock`
    static func glob(_ pattern: String, _ s: String) -> Bool {
        if pattern == "*" { return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }   // "has one"
        let p = pattern.lowercased(), t = s.lowercased()
        if !p.contains("*") { return p == t }
        // A pattern or a text beyond the limits matches nothing (ScriptLimits.globPatternCharacters says why).
        let pattern = Array(p.unicodeScalars), text = Array(t.unicodeScalars)
        guard pattern.count <= ScriptLimits.globPatternCharacters, text.count <= ScriptLimits.globTextCharacters else { return false }
        return wildcardMatch(pattern, text)
    }

    /// `*` matches any run of characters except a line end (as `.*` did), everything else only itself. One star is
    /// remembered and widened one character at a time, so the work is at most the pattern's length times the text's: never
    /// the combinatorial work a backtracking regular expression does on "*a*a*a*b" against a long run of a's.
    static func wildcardMatch(_ p: [Unicode.Scalar], _ t: [Unicode.Scalar]) -> Bool {
        func lineEnd(_ c: Unicode.Scalar) -> Bool { c == "\n" || c == "\r" || c == "\u{85}" || c == "\u{2028}" || c == "\u{2029}" }
        var pi = 0, ti = 0, star = -1, starText = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "*" { star = pi; starText = ti; pi += 1 }
            else if pi < p.count, p[pi] == t[ti] { pi += 1; ti += 1 }
            else if star >= 0, !lineEnd(t[starText]) { starText += 1; ti = starText; pi = star + 1 }
            else { return false }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// What one search may spend and must not read: its end time (every step after it fails, so a slow app costs the search,
    /// not the reader), and whether a secure field's value is hidden from the match (a script must not be able to ask
    /// "does the password start with a?").
    public final class SearchContext {
        let end: Date?
        let hideSecure: Bool
        public init(end: Date? = nil, hideSecure: Bool = false) { self.end = end; self.hideSecure = hideSecure }
        var expired: Bool { end.map { Date() >= $0 } ?? false }
    }

    /// "AXRadioButton", "RadioButton", "radio button" and "radioButton" all mean the same role.
    static func roleMatches(_ wanted: String, _ axRole: String) -> Bool {
        if wanted.hasPrefix("AX") { return glob(wanted, axRole) }
        let words = wanted.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return glob("AX" + words.joined(), axRole)
    }

    /// Whether an element satisfies a match (the "nth" field is for searches, not single tests).
    public static func matches(_ e: AXUIElement, _ m: ElementMatch, context: SearchContext? = nil) -> Bool {
        if context?.expired == true { return false }
        if let any = m.any { return any.contains { matches(e, $0, context: context) } }
        if let r = m.role, !roleMatches(r, e.role) { return false }
        if let rs = m.roles { let actual = e.role; if !rs.contains(where: { roleMatches($0, actual) }) { return false } }
        if let s = m.subrole, !glob(s, e.string(kAXSubroleAttribute) ?? "") { return false }
        if let i = m.identifier, !glob(i, e.string(kAXIdentifierAttribute) ?? "") { return false }
        if let t = m.title, !glob(t, e.string(kAXTitleAttribute) ?? "") { return false }
        if let d = m.description, !glob(d, e.string(kAXDescriptionAttribute) ?? "") { return false }
        if let h = m.help, !glob(h, e.string(kAXHelpAttribute) ?? "") { return false }
        if let v = m.value {
            let secret = context?.hideSecure == true && ScriptItem.isSecure(subrole: e.string(kAXSubroleAttribute), role: e.string(kAXRoleAttribute))
            let val = secret ? "" : (e.attr(kAXValueAttribute).map { "\($0)" } ?? "")
            if !glob(v, val) { return false }
        }
        if m.unnamed == true {
            let named = [e.string(kAXTitleAttribute), e.string(kAXDescriptionAttribute)].contains { s in
                let t = (s ?? "").trimmingCharacters(in: .whitespaces); return !t.isEmpty && !TurnOverObject.isClassName(t)
            }
            if named { return false }
        }
        if let p = m.pressable {
            // This can be nested inside a bounded search; action reads now share attribute health/scope admission
            // rather than bypassing cancellation and accounting (28 Oct 2026, issue 119).
            if ((e.actionNamesResult().value as? [String]) ?? []).contains("AXPress") != p { return false }
        }
        if let w = m.window { guard let win = e.element(kAXWindowAttribute), glob(w, win.string(kAXTitleAttribute) ?? "") else { return false } }
        if let t = m.text, !glob(t, text(of: e, context: context)) { return false }
        if let pm = m.parent?.value { guard let p = e.element(kAXParentAttribute), matches(p, pm, context: context) else { return false } }
        if let inside = m.inside?.value {
            var p = e.element(kAXParentAttribute); var depth = 0; var found = false
            while let x = p, depth < 30, context?.expired != true { if matches(x, inside, context: context) { found = true; break }; p = x.element(kAXParentAttribute); depth += 1 }
            if !found { return false }
        }
        return true
    }

    /// A match tested on one element, with "nth" kept: the element must be that one of all the matches. Without it,
    /// a label made for the first of eleven unnamed icons named all eleven (the plugin maker, 11 Oct 2026). The
    /// search behind nth is kept for two seconds per rule and app, so reading a page does not search for every item.
    public static func matchesHere(_ e: AXUIElement, _ m: ElementMatch, pid: pid_t) -> Bool {
        guard matches(e, m) else { return false }
        guard let n = m.nth else { return true }
        guard validNth(n) else { return false }   // 0, or past what a search can visit: nothing is "the nth"
        let key = "\(pid)|" + String(data: (try? JSONEncoder().encode(m)) ?? Data(), encoding: .utf8)!
        nthLock.lock(); let cached = nthCache[key]; nthLock.unlock()
        let chosen: AXUIElement?
        if let c = cached, Date().timeIntervalSince(c.at) < 2 { chosen = c.element }
        else {
            var plain = m; plain.nth = nil
            let all = find(plain, pid: pid, limit: max(50, abs(n)))
            chosen = n < 0 ? (all.count + n >= 0 ? all[all.count + n] : nil) : (n - 1 < all.count ? all[n - 1] : nil)
            nthLock.lock(); nthCache[key] = (chosen, Date()); if nthCache.count > 200 { nthCache.removeAll() }; nthLock.unlock()
        }
        return chosen.map { $0.isSame(e) } ?? false
    }
    /// The most elements a search visits, and so the furthest an `nth` can reach. Zero is not a place.
    static let maxVisits = 6000
    public static func validNth(_ n: Int) -> Bool { n != 0 && n.magnitude <= UInt(maxVisits) }
    private static let nthLock = NSLock()
    nonisolated(unsafe) private static var nthCache: [String: (element: AXUIElement?, at: Date)] = [:]   // under `nthLock`

    /// Where a search starts for a pid that is not a running app (a plugin test's replayed screen); nil: its windows.
    nonisolated(unsafe) public static var searchRoots: ((pid_t) -> [AXUIElement]?)?   // set by the test runner only

    /// Every element in the application's windows that matches, in tree order (bounded).
    public static func find(_ m: ElementMatch, pid: pid_t, limit: Int = 50, budget: TimeInterval = 0.6, hideSecure: Bool = false) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        // The messaging timeout is inherited by the elements copied from the application element: set once per
        // application, not on every search (code review, 8 Oct 2026).
        timeoutLock.lock(); let fresh = !timeoutSet.contains(pid); if fresh { timeoutSet.insert(pid) }; timeoutLock.unlock()
        if fresh { AXUIElementSetMessagingTimeout(app, 1.0) }
        var out: [AXUIElement] = []
        // Breadth first, and never into a copy of the element itself: Outlook's search field holds itself about 40
        // deep, and depth first spent the whole time budget down that chain (22 elements; every rule "matched
        // nothing", even the Sync button: parts request #2, 14 Oct 2026). Toolbars and panes are near the top.
        var queue = searchRoots?(pid) ?? app.elements(kAXWindowsAttribute)
        var head = 0
        let started = Date()
        let context = SearchContext(end: started.addingTimeInterval(budget), hideSecure: hideSecure)
        func sameKind(_ a: AXUIElement, _ b: AXUIElement) -> Bool {
            let keys = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute]
            let x = a.attrs(keys), y = b.attrs(keys)
            guard x[kAXRoleAttribute] as? String != nil else { return false }
            // Only a copy that says what it is: Avalonia (Libation) is layer on layer of nameless groups, and
            // skipping those as "copies" stopped every search a few levels down (14 Oct 2026, the retest of #4).
            guard keys.dropFirst().contains(where: { !((x[$0] as? String) ?? "").isEmpty }) else { return false }
            return keys.allSatisfy { (x[$0] as? String) == (y[$0] as? String) }
        }
        // A time budget as well as a count: 6,000 visits of a slow application is seconds on the main thread.
        // The same end time stops the match and the walk part-way through one element, not only between elements.
        while head < queue.count, head < maxVisits, out.count < limit, !context.expired {
            let e = queue[head]; head += 1
            if matches(e, m, context: context) { out.append(e) }
            for c in e.elements(kAXChildrenAttribute) where !context.expired && !sameKind(c, e) { queue.append(c) }
        }
        return out
    }

    /// The one element a key acts on: "nth" picks among the matches (default the first).
    public static func findOne(_ m: ElementMatch, pid: pid_t, budget: TimeInterval = 0.6, hideSecure: Bool = false) -> AXUIElement? {
        let n = m.nth ?? 1
        guard validNth(n) else { return nil }   // nth 0 once indexed all[-1]; a huge one once overflowed abs()
        let all = find(m, pid: pid, limit: max(50, n), budget: budget, hideSecure: hideSecure)
        guard !all.isEmpty else { return nil }
        if n < 0 { return all.count + n >= 0 ? all[all.count + n] : nil }
        return n - 1 < all.count ? all[n - 1] : nil
    }

    /// Static text inside an element, in order.
    nonisolated public static func text(of e: AXUIElement, context: SearchContext? = nil) -> String {
        if e.role == "AXStaticText" { return (e.string(kAXValueAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        // On a web page, one sentence comes in pieces ("Hello " and "world"): joined as they are. In an app, each text
        // is its own item: joined with a pause, or Asobi's game card read "Example GameLast played27 days ago…"
        // (parts request #3, from an AI making an Asobi plugin, 14 Oct 2026).
        var p = e.element(kAXParentAttribute); var hops = 0
        while let x = p, hops < 30, context?.expired != true { if x.role == "AXWebArea" { return ClaudeTranscript.text(of: e, skipHidden: false) }; p = x.element(kAXParentAttribute); hops += 1 }
        var parts: [String] = []
        var budget = 2000
        func walk(_ x: AXUIElement) {
            guard budget > 0, context?.expired != true else { return }
            budget -= 1
            if x.role == "AXStaticText" {
                if let v = x.string(kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { parts.append(v) }
                return
            }
            for c in x.elements(kAXChildrenAttribute) { walk(c) }
        }
        walk(e)
        return joinItems(parts)
    }

    /// Separate texts as separate phrases: a comma between them, unless one already ends in punctuation. Pure.
    nonisolated public static func joinItems(_ parts: [String]) -> String {
        var out = ""
        for p in parts where !p.isEmpty {
            if out.isEmpty { out = p; continue }
            out += (out.last.map { ".,;:!?".contains($0) } ?? false) ? " " + p : ", " + p
        }
        return out
    }

    /// The first sentence of a tooltip: a name, not a paragraph ("This is the height for each layer").
    public static func firstSentence(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.rangeOfCharacter(from: CharacterSet(charactersIn: "\n\t")) { t = String(t[..<r.lowerBound]) }
        if let r = t.range(of: ". ") { t = String(t[..<r.lowerBound]) }
        if t.hasSuffix(".") { t.removeLast() }
        return t.count > 90 ? String(t.prefix(90)) + "…" : t
    }

    /// A name taken from beside or inside the element.
    public static func name(from source: String, of e: AXUIElement) -> String? { nameAndSource(from: source, of: e)?.0 }

    /// The name, and the sibling it came from (which then need not be read again).
    public static func nameAndSource(from source: String, of e: AXUIElement) -> (String, AXUIElement?)? {
        // The nearest sibling with text, within a few; if there is none at this level, the same one level up, up to
        // six levels: a focused box six deep inside a spinner, its label beside the spinner (parts request #5,
        // Libation, 14 Oct 2026). A sibling holding a whole panel (over 80 characters) isn't a label.
        func siblingText(_ step: Int) -> (String, AXUIElement?)? {
            var me = e
            for _ in 0..<14 {   // Avalonia's number box is eleven levels inside the spinner its label sits beside
                guard let parent = me.element(kAXParentAttribute) else { return nil }
                let kids = parent.elements(kAXChildrenAttribute)
                if var i = kids.firstIndex(where: { $0.isSame(me) }) {
                    for _ in 0..<4 {
                        i += step
                        guard kids.indices.contains(i) else { break }
                        let t = text(of: kids[i])
                        if !t.isEmpty, t.count <= 80 { return (t, kids[i]) }   // a whole panel's text isn't a label: on
                    }
                }
                me = parent
            }
            return nil
        }
        func plain(_ s: String?) -> (String, AXUIElement?)? { s.flatMap { $0.isEmpty ? nil : ($0, nil) } }
        switch source {
        case "nextText": return siblingText(1)
        case "previousText": return siblingText(-1)
        case "childText": return plain(text(of: e))
        case "ancestorHelp":
            // The nearest tooltip above it: Libation's row button says its state only on an ancestor.
            var p = e.element(kAXParentAttribute); var hops = 0
            while let x = p, hops < 6 { if let h = x.string(kAXHelpAttribute), !h.trimmingCharacters(in: .whitespaces).isEmpty { return (h.trimmingCharacters(in: .whitespacesAndNewlines), nil) }; p = x.element(kAXParentAttribute); hops += 1 }
            return nil
        case "rowText":
            // The row it sits in, read as one: a row, or a cell that holds a whole row (Avalonia's grid).
            var p = e.element(kAXParentAttribute); var hops = 0
            while let x = p, hops < 8 {
                if x.role == "AXRow" || x.role == "AXCell" { let t = text(of: x); return t.isEmpty ? nil : (String(t.prefix(200)), nil) }
                p = x.element(kAXParentAttribute); hops += 1
            }
            return nil
        case "parentText": return plain(e.element(kAXParentAttribute).map { text(of: $0) })
        case "help": return plain(e.string(kAXHelpAttribute).map(firstSentence))
        case "description": return plain(e.string(kAXDescriptionAttribute))
        default: return nil
        }
    }
}

// MARK: - The store

public final class ProfileStore {
    nonisolated public static let shared = ProfileStore()
    nonisolated package init() {}
    public static var folder: URL {
        AppPaths.file("plugins")
    }
    /// The accepted fixes inside TurnOver.app (Contents/Resources/fixes), when there are any. Read only.
    public static var shippedFixes: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("fixes", isDirectory: true),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var _plugins: [LoadedPlugin] = []   // under `lock`
    nonisolated public var plugins: [LoadedPlugin] { lock.lock(); defer { lock.unlock() }; return _plugins }
    /// Called after a load, so the scripts that carry the profiles' keys can be rebuilt.
    public var onReload: (() -> Void)?
    /// Whether a change found on reload is said (on once TurnOver is running; not at its first load).
    nonisolated(unsafe) public var announceChanges = false   // main thread only

    /// Load one plugin folder (also used by the tester). Each counted file is read once, through `read`, and both parsed and
    /// hashed from those bytes, so a receipt is for what was parsed even if the file changes during the load (15 Nov 2026).
    /// `read` is a seam for the tests only.
    public static func load(folder: URL, read: (URL) -> Data? = { PluginFormat.readPluginFile($0) }) -> LoadedPlugin {
        let fm = FileManager.default
        let mURL = folder.appendingPathComponent("manifest.json"), pURL = folder.appendingPathComponent("profile.json")
        let jURL = folder.appendingPathComponent(PluginFormat.scriptName)
        let modified = [mURL, pURL, jURL].compactMap { (try? fm.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }.max() ?? .distantPast
        do {
            // Read as hand-written files: comments and trailing commas allowed, errors with their line (PluginFormat).
            let mData = read(mURL)
            let manifest = try PluginFormat.decode(PluginManifest.self, from: mData, file: mURL.lastPathComponent)
            // The id names its folder: never a path (".." would have made install delete TurnOver's own folder, the
            // code review, 13 Oct 2026).
            guard PluginManifest.isValidID(manifest.id) else {
                return LoadedPlugin(folder: folder, manifest: nil, profile: nil, error: "manifest.json: id \"\(manifest.id)\" must be 1 to 64 letters, digits and hyphens, starting with a letter or digit", modified: modified)
            }
            // A plugin with a script may have no profile.json at all (the hash counts it "if present"); a data plugin may not.
            let hasProfile = fm.fileExists(atPath: pURL.path)
            let profile: Profile
            let pData = hasProfile ? read(pURL) : nil
            if manifest.script != nil, !hasProfile { profile = Profile() } else { profile = try PluginFormat.decode(Profile.self, from: pData, file: pURL.lastPathComponent) }
            let jData = manifest.script != nil ? read(jURL) : nil
            let problems = PluginFormat.check(manifest: mData, profile: pData, folder: folder, scriptData: jData)
            if let first = problems.first(where: { $0.isError }) {
                return LoadedPlugin(folder: folder, manifest: nil, profile: nil, error: first.description, modified: modified, warnings: problems.filter { !$0.isError }.map(\.description))
            }
            try profile.view?.validate()   // a view that names a shape TurnOver has no view for fails the plugin
            // What no plugin may do on any Mac fails it here, however it arrived: copied in, or edited in place.
            if let why = (PluginPolicy.refusals(profile) + PluginPolicy.scriptRefusals(manifest)).first {
                return LoadedPlugin(folder: folder, manifest: nil, profile: nil, error: "refused: " + why, modified: modified)
            }
            // The script's text and the hash of the files, from the one read of each, so a receipt is for what was loaded.
            var text: String?, hash: String?
            if manifest.script != nil, let mData, let jData, let loaded = String(data: jData, encoding: .utf8) {
                var files = [(name: "manifest.json", data: mData)]
                if let pData { files.append((name: "profile.json", data: pData)) }
                files.append((name: PluginFormat.scriptName, data: jData))
                text = loaded; hash = ScriptTrust.hex(ScriptTrust.digest(files: files))
            }
            return LoadedPlugin(folder: folder, manifest: manifest, profile: profile, error: nil, modified: modified, warnings: problems.map(\.description),
                                script: text, scriptHash: hash)
        } catch let e as PluginFormatError {
            return LoadedPlugin(folder: folder, manifest: nil, profile: nil, error: e.description, modified: modified)
        } catch let e as RecipeError {
            return LoadedPlugin(folder: folder, manifest: nil, profile: nil, error: "view: " + Recipes.describe(e), modified: modified)
        } catch let e as DecodingError {
            return LoadedPlugin(folder: folder, manifest: nil, profile: nil, error: describe(e), modified: modified)
        } catch {
            return LoadedPlugin(folder: folder, manifest: nil, profile: nil, error: error.localizedDescription, modified: modified)
        }
    }

    /// A decoding error in words an author (or their AI) can act on.
    public static func describe(_ e: DecodingError) -> String {
        func path(_ c: [CodingKey]) -> String { c.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        switch e {
        case .keyNotFound(let k, let c): return "missing \"\(k.stringValue)\" at \(path(c.codingPath).isEmpty ? "the top" : path(c.codingPath))"
        case .typeMismatch(let t, let c): return "wrong type at \(path(c.codingPath)): expected \(t)"
        case .valueNotFound(let t, let c): return "missing value at \(path(c.codingPath)): expected \(t)"
        case .dataCorrupted(let c): return "not valid JSON at \(path(c.codingPath)): \(c.debugDescription)"
        @unknown default: return "\(e)"
        }
    }

    /// Load every plugin folder; only reload when something changed.
    @discardableResult
    public func reload(force: Bool = false, quiet: Bool = false) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        func subfolders(_ dir: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.sorted { $0.path < $1.path }
        }
        // The fixes people shared and the project accepted (Resources/fixes, copied into the app by build.sh; 7 Nov
        // 2026) first, then the person's own, which can add to or undo them.
        let folders = (Self.shippedFixes.map(subfolders) ?? []) + subfolders(Self.folder)
        let current = plugins
        if !force, folders.count == current.count, zip(folders, current).allSatisfy({ f, p in
            f == p.folder && ([f.appendingPathComponent("manifest.json"), f.appendingPathComponent("profile.json"), f.appendingPathComponent(PluginFormat.scriptName)]
                .compactMap { (try? fm.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }.max() ?? .distantPast) == p.modified
        }) { return false }
        let loaded = folders.map { Self.load(folder: $0) }
        lock.lock(); _plugins = loaded; lock.unlock()
        // Saved while TurnOver runs: said, so the author hears the result without looking (docs/PLUGIN-TOOLKIT-PLAN.md,
        // item 3: NVDA's scratchpad, without the reload key).
        if announceChanges, !quiet {
            for p in loaded where !current.contains(where: { $0.folder == p.folder && $0.modified == p.modified }) {
                let name = p.manifest?.name ?? p.folder.lastPathComponent
                let text = p.error.map { String(localized: "Plugin \(p.folder.lastPathComponent) not loaded. \($0)", comment: "A plugin saved but not loaded: its folder, then the problem (in English)") }
                    ?? (p.warnings.isEmpty ? String(localized: "Plugin \(name) reloaded", comment: "A plugin saved and reloaded")
                        : p.warnings.count == 1 ? String(localized: "Plugin \(name) reloaded, with 1 warning. \(p.warnings[0])", comment: "A plugin reloaded: its name, then the warning (in English)")
                        : String(localized: "Plugin \(name) reloaded, with \(String(p.warnings.count)) warnings. \(p.warnings[0])", comment: "A plugin reloaded: its name, how many warnings, then the first (in English)"))
                if Thread.isMainThread { Speech.speakMessage(text) } else { DispatchQueue.main.async { Speech.speakMessage(text) } }
            }
        }
        for p in loaded {
            if let e = p.error { Log.info("plugin \(p.folder.lastPathComponent): not loaded, \(e)") }
            else { Log.info("plugin \(p.manifest!.name) \(p.manifest!.version) for \(p.manifest!.apps.joined(separator: ", "))\(p.profile?.view.map { " (a \($0.kind) view)" } ?? "")") }
            for w in p.warnings { Log.info("plugin \(p.folder.lastPathComponent): \(w)") }
        }
        Recipes.load(plugins: livePlugins)   // the plugins' views, over the built-in recipes
        DispatchQueue.main.async { Games.pluginsChanged(loaded); Trackpad.pluginsChanged(loaded) }   // official plugins switch built-in features on or off
        leadInPluginApps(loaded)
        onReload?()
        return true
    }

    /// A plugin for an application TurnOver was leaving to VoiceOver did nothing at all: its keys and names only
    /// exist while TurnOver leads (the first plugin, for a game, 9 Oct 2026). Installing a plugin for
    /// an app is as clear a request as the Unverified apps menu, so the app is handed to TurnOver, and said.
    /// A plugin for an app TurnOver doesn't read asks, once, whether TurnOver should read it from now on. It no longer
    /// adds the app by itself: that changed the user's settings at install (the plugin design notes decision 15, 13 Oct 2026).
    /// Asked once per plugin and app; "no" leaves the plugin waiting until the app is handed over (Command Control
    /// Comma, T). A plugin update never asks again.
    private func leadInPluginApps(_ loaded: [LoadedPlugin]) {
        guard Config.persists else { return }   // TurnOver itself, not a tool
        var asked = Set(UserDefaults.standard.stringArray(forKey: "pluginLeadAsked") ?? [])
        var questions: [(plugin: String, bundle: String, name: String)] = []
        for p in loaded {
            guard let m = p.manifest, p.error == nil else { continue }
            for b in m.apps where !config.applications.leadBundles.contains(b) && !asked.contains(m.id + " " + b) {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) else { continue }
                let name = NSRunningApplication.runningApplications(withBundleIdentifier: b).first?.localizedName
                    ?? FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                questions.append((m.name, b, name)); asked.insert(m.id + " " + b)
            }
        }
        guard !questions.isEmpty else { return }
        UserDefaults.standard.set(Array(asked), forKey: "pluginLeadAsked")
        DispatchQueue.main.async {
            // One question, whatever the number of apps (two lists at once would cover each other).
            let names = questions.map(\.name).joined(separator: Phrases.and)
            let plugins = Array(Set(questions.map(\.plugin))).sorted().joined(separator: ", ")
            Log.info("plugins \(plugins): asking whether TurnOver should read \(questions.map(\.bundle).joined(separator: ", "))")
            TurnOverMenu.shared.openList(verbatim: questions.count == 1
                ? String(localized: "TurnOver doesn't read \(names) yet. Read it with TurnOver from now on, for \(plugins)?", comment: "A plugin's app TurnOver doesn't read: the app, then the plugin")
                : String(localized: "TurnOver doesn't read \(names) yet. Read them with TurnOver from now on, for \(plugins)?", comment: "A plugin's apps TurnOver doesn't read: the apps, then the plugins"), items: [
                MenuItem("Yes, read \(names) with TurnOver", .action {
                    for q in questions where !config.applications.leadBundles.contains(q.bundle) { config.applications.leadBundles.append(q.bundle) }
                    config.save()
                    Speech.speakMessage(questions.count == 1 ? String(localized: "TurnOver reads \(names) from now on. Switch to it and back once.", comment: "An app given to TurnOver for a plugin")
                        : String(localized: "TurnOver reads \(names) from now on. Switch to them and back once.", comment: "Apps given to TurnOver for a plugin"))
                }),
                MenuItem("No, leave \(names) with VoiceOver", .action {
                    Speech.speakMessage(String(localized: "\(plugins) waits until you hand \(names) to TurnOver: Command Control Comma, then T, in the app.", comment: "A plugin waiting for its app: the plugin, then the app"))
                }),
            ])
        }
    }

    /// A plugin being checked by the tool, applied as if installed (turnover-plugin check).
    public func addTesting(_ p: LoadedPlugin) {
        lock.lock(); _plugins.removeAll { $0.manifest?.id == p.manifest?.id }; _plugins.append(p); lock.unlock()
    }

    // MARK: Which profiles are live

    /// With plugin scripts on, a plugin that has a script is one thing: until ScriptTrust says its script may run, none of its
    /// profile is live either (no labels, keys, watches, silences, holds or view). This maps each such plugin's id to the hash
    /// of the files that may run, set by ScriptPlugins whenever the receipts or the files change; a plugin whose files are
    /// not the ones in the map is not live (so a change is dark until it is decided again). nil: scripts are off, every plugin
    /// is live as a data plugin always was. Plugins without a script are never touched.
    nonisolated(unsafe) private var scriptLive: [String: String]?   // under `lock`
    /// Set the map; true if it changed (then `livenessChanged()` follows, on main).
    nonisolated package func setScriptLive(_ map: [String: String]?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard scriptLive != map else { return false }
        scriptLive = map
        return true
    }
    /// What to do when the live set changed without a reload: the keys are rebuilt (ProfilesPlugin) and the views reloaded.
    nonisolated(unsafe) package var onLiveChange: (() -> Void)?   // main thread only
    package func livenessChanged() {
        if plugins.contains(where: { $0.manifest?.script != nil && $0.profile?.view != nil }) { Recipes.load(plugins: livePlugins) }
        onLiveChange?()
    }
    /// The plugins whose profiles apply now.
    nonisolated public var livePlugins: [LoadedPlugin] {
        lock.lock(); defer { lock.unlock() }
        guard let live = scriptLive else { return _plugins }
        return _plugins.filter { p in
            guard p.manifest?.script != nil else { return true }
            guard let id = p.manifest?.id, let hash = p.scriptHash else { return false }
            return live[id] == hash
        }
    }

    /// The profiles that apply to an application.
    nonisolated public func profiles(for bundle: String) -> [(PluginManifest, Profile)] {
        livePlugins.compactMap { p in
            guard let m = p.manifest, let pr = p.profile, m.apps.contains(bundle) else { return nil }
            return (m, pr)
        }
    }

    nonisolated(unsafe) private var bundleCache: [pid_t: (start: UInt64, bundle: String)] = [:]   // under `lock`
    /// When the process began, to the microsecond: a process id that is used again by another program has another start, so
    /// what was cached for the old one is not believed. Seams for the tests.
    nonisolated(unsafe) package var processStart: (pid_t) -> UInt64? = { pid in
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        return info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
    }
    nonisolated(unsafe) package var lookupBundle: (pid_t) -> String = { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier ?? "" }
    /// The app a replayed screen stands for (a plugin's tests: every element of a replay has a pid of its own).
    nonisolated(unsafe) public var replayBundle: String?   // set and cleared by the test runner, main thread
    nonisolated public func bundle(of pid: pid_t) -> String {
        if pid >= 900_000, let b = replayBundle { return b }
        // The app that really has this process now: what is kept for a process id is kept with the process's start, because the
        // answer decides what a script may reach, and an id passes to another program when the first one quits.
        guard let start = processStart(pid) else { return lookupBundle(pid) }
        lock.lock(); if let c = bundleCache[pid], c.start == start { lock.unlock(); return c.bundle }; lock.unlock()
        let b = lookupBundle(pid)
        lock.lock(); bundleCache[pid] = (start, b); lock.unlock()
        return b
    }

    /// A profile's label for an element: (name, role text), or nil.
    nonisolated public func label(for e: AXUIElement, pid: pid_t) -> (String?, String?)? {
        labelDetail(for: e, pid: pid).map { ($0.name, $0.role) }
    }

    /// The label with the sibling its name came from, if any.
    nonisolated public func labelDetail(for e: AXUIElement, pid: pid_t) -> (name: String?, role: String?, source: AXUIElement?)? {
        let bundle = bundle(of: pid)
        guard !bundle.isEmpty else { return nil }
        for (_, profile) in profiles(for: bundle) {
            for rule in profile.labels ?? [] where ElementMatcher.matchesHere(e, rule.match, pid: pid) {
                if let n = rule.name { return (n, rule.role, nil) }
                let found = rule.nameFrom.flatMap { ElementMatcher.nameAndSource(from: $0, of: e) }
                if found != nil || rule.role != nil { return (found?.0, rule.role, found?.1) }
            }
        }
        return nil
    }

    nonisolated public func isSilenced(_ e: AXUIElement, pid: pid_t) -> Bool {
        let bundle = bundle(of: pid)
        return profiles(for: bundle).contains { $0.1.silence?.contains { ElementMatcher.matchesHere(e, $0, pid: pid) } ?? false }
    }

    public func holdRule(for e: AXUIElement, pid: pid_t) -> HoldRule? {
        let bundle = bundle(of: pid)
        for (_, profile) in profiles(for: bundle) { if let r = profile.hold?.first(where: { ElementMatcher.matchesHere(e, $0.focus, pid: pid) }) { return r } }
        return nil
    }

    public func watchRule(for e: AXUIElement, pid: pid_t) -> WatchRule? {
        let bundle = bundle(of: pid)
        for (_, profile) in profiles(for: bundle) { if let r = profile.watch?.first(where: { ElementMatcher.matchesHere(e, $0.match, pid: pid) }) { return r } }
        return nil
    }
}

// MARK: - The plugin that applies them

/// Carries every profile's keys as scripts (first in line, as the user's own fixes should be), keeps silenced
/// elements quiet, and reads watched elements when they change.
final class ProfilesPlugin: GlobalPlugin {
    private var scriptNames: [String] = []
    private var reloadTimer: Timer?

    required init() {
        super.init()
        // With plugin scripts on, no profile of a plugin that has a script is live until its script is approved: shut before
        // anything loads, opened one plugin at a time by ScriptPlugins.
        if Edition.includesPluginScripts { _ = ProfileStore.shared.setScriptLive([:]) }
        ProfileStore.shared.onLiveChange = { [weak self] in self?.rebuild() }
        ProfileStore.shared.onReload = { [weak self] in DispatchQueue.main.async { self?.rebuild() } }
        ProfileStore.shared.reload(force: true)
        // The plugins folder looked at every second: a file saved is reloaded and said (a few file dates, no reading).
        ProfileStore.shared.announceChanges = true
        reloadTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in MainActor.assumeIsolated { _ = ProfileStore.shared.reload() } }
    }

    private func rebuild() {
        scriptNames.forEach { removeScript($0) }
        scriptNames.removeAll()
        for p in ProfileStore.shared.livePlugins {
            guard let m = p.manifest, let profile = p.profile else { continue }
            for (i, rule) in (profile.keys ?? []).enumerated() {
                let name = "plugin_\(m.id)_\(i)"
                let apps = Set(m.apps)
                let id = rule.key.hasPrefix("kb") ? rule.key : "kb:" + rule.key
                script(name, rule.description, gestures: [id], category: m.name) { g in Self.perform(rule, gesture: g) }
                    .isAvailable = { API.focusPid.map { apps.contains(ProfileStore.shared.bundle(of: $0)) } ?? false }
                scriptNames.append(name)
            }
        }
    }

    /// What a key's `read` says for an element: its text, or its name, role and the rest if it has none. A script's
    /// `item.read` says the same.
    static func readingText(of e: AXUIElement) -> String {
        let t = ElementMatcher.text(of: e)
        return t.isEmpty ? Speech.objectPropertiesSpeech(ObjectFactory.make(e), reason: .query).joined(separator: ", ") : t
    }

    static func perform(_ rule: KeyRule, gesture: KeyboardGesture) {
        guard let pid = API.focusPid else { return }
        func target() -> AXUIElement? {
            guard let t = rule.target else { return nil }
            let e = ElementMatcher.findOne(t, pid: pid)
            if e == nil { Speech.speakMessage(String(localized: "not found", comment: "Spoken message")) }
            return e
        }
        switch rule.action {
        case "press":
            guard let e = target() else { return }
            let r = AXUIElementPerformAction(e, kAXPressAction as CFString)
            Log.io("plugin: press \(e.role) → \(r.rawValue)")
        case "focus":
            guard let e = target() else { return }
            _ = e.set(kAXFocusedAttribute, kCFBooleanTrue)
            AXHandler.shared.refocus(pid: pid)
        case "read":
            guard let e = target() else { return }
            Speech.speakMessage(readingText(of: e))
        case "menu":
            guard let path = rule.menu, !path.isEmpty else { return }
            if !MenuPath.choose(path, pid: pid) { Speech.speakMessage(String(localized: "menu item not found: \(path.joined(separator: ", "))", comment: "A plugin's menu item not found: %@ is its path")) }
        case "keys":
            if let k = rule.keys, let g = KeyboardGesture(identifier: "kb:" + k) { g.send() }
        case "say":
            break
        default:
            Speech.speakMessage(String(localized: "unknown action \(rule.action)", comment: "A plugin key with an action TurnOver doesn't know: %@ is the action"))
        }
        if let s = rule.say { Speech.speakMessage(s) }
    }

    /// The commands of the plugins working in an app, for the plugin layer (Command Control Comma, P): each with its
    /// letter (if it has one), what it does, and how to run it.
    /// Each command's own key too, spoken as the shortcuts list says keys (13 Oct 2026: the list should
    /// say the shortcuts, so they can be learnt).
    static func commands(for bundle: String) -> [(letter: String?, title: String, key: String, run: @MainActor () -> Void)] {
        var out: [(letter: String?, title: String, key: String, run: @MainActor () -> Void)] = []
        for p in ProfileStore.shared.livePlugins {
            guard let m = p.manifest, p.error == nil, m.apps.contains(bundle) else { continue }
            for rule in p.profile?.keys ?? [] {
                let id = normalizeGestureIdentifier(rule.key.hasPrefix("kb:") ? rule.key : "kb:" + rule.key)
                let g = KeyboardGesture(identifier: id)
                out.append((rule.letter?.lowercased(), rule.description, GlobalCommands.spoken(id), { if let g { perform(rule, gesture: g) } }))
            }
        }
        return out
    }

    /// The app the plugins were last said for, so they're said once as an app comes to the front, not per window.
    private var announcedFor = ""
    /// The plugins working in an app, by name.
    static func pluginNames(for bundle: String) -> [String] {
        ProfileStore.shared.plugins.compactMap { p in p.manifest.flatMap { $0.apps.contains(bundle) && p.error == nil ? $0.name : nil } }
    }

    override func handleEvent(_ event: Event, next: () -> Void) {
        // A plugin says it's there as its app comes to the front ("…, with the Bambu Studio plugin"; the plugin design notes 13).
        if event.kind == .foreground {
            next()
            let bundle = ProfileStore.shared.bundle(of: event.obj.pid)
            guard bundle != announcedFor else { return }
            announcedFor = bundle
            let names = Self.pluginNames(for: bundle)
            if config.presentation.announcePlugins, !names.isEmpty {
                Speech.speakMessage(String(localized: "with \(names.map { String(localized: "the \($0) plugin", comment: "A plugin by name") }.joined(separator: Phrases.and))", comment: "An app coming to the front with plugins: %@ names them"))
            }
            return
        }
        switch event.kind {
        case .gainFocus, .focusEntered:
            if ProfileStore.shared.isSilenced(event.obj.element, pid: event.obj.pid) { return }
            if event.kind == .gainFocus, let rule = ProfileStore.shared.holdRule(for: event.obj.element, pid: event.obj.pid) {
                next()
                if let list = ElementMatcher.findOne(rule.items, pid: event.obj.pid, budget: 1.0) {
                    ObjectNavigator.shared.holdForPlugin(list)
                } else {
                    Log.io("plugin hold: the list to hold wasn't found")
                }
                return
            }
        case .valueChange:
            if let rule = ProfileStore.shared.watchRule(for: event.obj.element, pid: event.obj.pid) {
                let v = rule.read == "text" ? ElementMatcher.text(of: event.obj.element) : (event.obj.value ?? "")
                if !v.isEmpty { Speech.speakMessage([rule.prefix, v].compactMap { $0 }.joined(separator: " ")) }
                return
            }
        default: break
        }
        next()
    }
}

/// Choosing a menu item by its path, through accessibility (no menus are opened on screen).
public enum MenuPath {
    /// The menu item at a path; each step may use * ("Open Project*" matches "Open Project...").
    public static func find(_ path: [String], pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        guard let bar = app.element(kAXMenuBarAttribute) else { return nil }
        var level = bar.elements(kAXChildrenAttribute)
        var item: AXUIElement?
        for (i, title) in path.enumerated() {
            guard let found = level.first(where: { ElementMatcher.glob(title, $0.string(kAXTitleAttribute) ?? "") }) else { return nil }
            item = found
            if i < path.count - 1 { level = found.elements(kAXChildrenAttribute).first?.elements(kAXChildrenAttribute) ?? [] }
        }
        return item
    }

    public static func choose(_ path: [String], pid: pid_t) -> Bool {
        guard let item = find(path, pid: pid) else { return false }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }
}

/// The plugins' commands for the plugin layer in the app (Command Control Comma, P).
public enum PluginCommands {
    public static func forApp(_ bundle: String) -> [(letter: String?, title: String, key: String, run: @MainActor () -> Void)] { ProfilesPlugin.commands(for: bundle) + ScriptPlugins.commands(for: bundle) }
}
