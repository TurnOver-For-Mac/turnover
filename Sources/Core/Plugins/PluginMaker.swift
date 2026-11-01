// SPDX-License-Identifier: GPL-3.0-or-later
// Making a plugin by hand, in the app, with nothing to write (docs/PLUGIN-TOOLKIT-PLAN.md, item 1; 11 Oct 2026).
//
// TurnOver Shift Slash (VoiceOver's VO Shift Slash labels an item; NVDA needs Python for any of this) opens a short
// list for the item TurnOver is on (the review cursor if it is in the app in front, else the focus):
//   What is this?            role, name, identifier, where it sits, and the match TurnOver would use; copied too
//   Label this item          type a name; it is called that from now on
//   Give this item a key     press a key: it presses, focuses or reads the item
//   Read this when it changes
//   Don't announce this
//   Undo the last change
//   My changes for <app>     each change; Return removes one
//   Share my changes         the plugin as a .zip on the Desktop, to send or submit
// Every change goes into a plugin of the user's own for that app ("My changes for Bambu Studio", folder my-<bundle>)
// in TurnOver's plugins folder, and applies at once. The match is chosen and checked by TurnOver: the identifier
// first; else the title, description or tooltip; else "unnamed, inside" the nearest named part, with its place
// among the matches (nth) when there are several.
import Foundation
import AppKit
import ApplicationServices

public enum PluginMaker {

    // MARK: The item and its app

    static func target() -> (element: AXUIElement, pid: pid_t)? {
        guard let pid = API.focusPid else { return nil }
        if let r = ObjectNavigator.shared.reviewElement, r.pid == pid { return (r, pid) }
        if let f = API.focusObject?.element { return (f, pid) }
        return nil
    }

    static func app(_ pid: pid_t) -> (bundle: String, name: String)? {
        guard let a = NSRunningApplication(processIdentifier: pid), let b = a.bundleIdentifier else { return nil }
        return (b, a.localizedName ?? b)
    }

    // MARK: The match

    /// An identifier an app generated (AppKit's "_NS:123") changes between launches: not one to match by.
    static func steady(_ id: String) -> Bool { !id.isEmpty && !id.hasPrefix("_NS:") && !id.hasPrefix("NS") }

    /// The match TurnOver would use for an element, checked against the app: it finds this element (with nth when
    /// more than one matches). Also how it was chosen, in words.
    public static func match(for e: AXUIElement, pid: pid_t) -> (match: ElementMatch, how: String) {
        var m = ElementMatch()
        m.role = e.role
        var how: String
        let id = e.string(kAXIdentifierAttribute) ?? ""
        let title = (e.string(kAXTitleAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let desc = (e.string(kAXDescriptionAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let help = (e.string(kAXHelpAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if steady(id) { m.identifier = id; how = "by its identifier, \(id)" }
        else if !title.isEmpty { m.title = title; how = "by its title" }
        else if !desc.isEmpty { m.description = desc; how = "by its description" }
        else if !help.isEmpty { m.help = help; how = "by its tooltip" }
        else {
            m.unnamed = true
            var acts: CFArray?; AXUIElementCopyActionNames(e, &acts)
            if ((acts as? [String]) ?? []).contains("AXPress") { m.pressable = true }
            how = "as an unnamed \(Role.from(axRole: e.role, subrole: e.string(kAXSubroleAttribute)).displayString)"
            if let (anc, words) = namedAncestor(of: e) { m.inside = Box(anc); how += " inside \(words)" }
        }
        // Checked: which matches come first, and where this one is among them.
        let found = ElementMatcher.find(m, pid: pid, limit: 50, budget: 1.0)
        if let i = found.firstIndex(where: { $0.isSame(e) }), found.count > 1 { m.nth = i + 1; how += ", number \(i + 1) of \(found.count)" }
        else if !found.contains(where: { $0.isSame(e) }) { how += " (TurnOver could not find it again by this; it may move)" }
        return (m, how)
    }

    /// The nearest ancestor with something steady to match by (an identifier, a title, a description).
    static func namedAncestor(of e: AXUIElement) -> (ElementMatch, String)? {
        var p = e.element(kAXParentAttribute); var hops = 0
        while let x = p, hops < 8, x.role != "AXWindow", x.role != "AXApplication" {
            var m = ElementMatch(); m.role = x.role
            let id = x.string(kAXIdentifierAttribute) ?? "", t = x.string(kAXTitleAttribute) ?? "", d = x.string(kAXDescriptionAttribute) ?? ""
            let kind = Role.from(axRole: x.role, subrole: x.string(kAXSubroleAttribute)).displayString
            if steady(id) { m.identifier = id; return (m, "the \(kind) \(id)") }
            if !t.isEmpty { m.title = t; return (m, "the \(kind) \(t)") }
            if !d.isEmpty { m.description = d; return (m, "the \(kind) \(d)") }
            p = x.element(kAXParentAttribute); hops += 1
        }
        return nil
    }

    // MARK: The user's own plugin for the app

    static func folder(for bundle: String) -> URL {
        let safe = bundle.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return ProfileStore.folder.appendingPathComponent("my-" + String(safe), isDirectory: true)
    }

    static func load(bundle: String, appName: String) -> (PluginManifest, Profile) {
        let dir = folder(for: bundle)
        let loaded = ProfileStore.load(folder: dir)
        if let m = loaded.manifest, let p = loaded.profile { return (m, p) }
        let safe = String(bundle.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        var m = PluginManifest(id: "my-" + safe, name: "My changes for \(appName)", version: "1", author: NSFullUserName(),
                               description: "Made in TurnOver with TurnOver Shift Slash.", apps: [bundle])
        m.kind = "profile"; m.formatVersion = PluginFormat.currentVersion
        return (m, Profile(labels: nil, keys: nil, watch: nil, silence: nil, view: nil))
    }

    static func save(_ m: PluginManifest, _ p: Profile, bundle: String) -> Bool {
        let dir = folder(for: bundle)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try enc.encode(m).write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
            try enc.encode(p).write(to: dir.appendingPathComponent("profile.json"), options: .atomic)
        } catch { Log.error("plugin maker: could not save: \(error)"); Speech.speakMessage(String(localized: "Could not save the change", comment: "Spoken message")); return false }
        ProfileStore.shared.reload(force: true, quiet: true)
        return true
    }

    /// The changes made this session, newest last, for Undo: the app and the change as it was written.
    static var history: [(bundle: String, appName: String, kind: String, json: Data)] = []

    static func encode<T: Encodable>(_ v: T) -> Data { let e = JSONEncoder(); e.outputFormatting = .sortedKeys; return (try? e.encode(v)) ?? Data() }

    static func add(_ kind: String, bundle: String, appName: String, change: (inout Profile) -> Data) -> Bool {
        let (m, p0) = load(bundle: bundle, appName: appName)
        var p = p0
        let json = change(&p)
        guard save(m, p, bundle: bundle) else { return false }
        history.append((bundle, appName, kind, json))
        Log.io("plugin maker: \(kind) added to My changes for \(appName)")
        return true
    }

    /// Remove a change (the last one equal to `json` of that kind).
    static func remove(kind: String, json: Data, bundle: String, appName: String) -> Bool {
        let (m, p0) = load(bundle: bundle, appName: appName)
        var p = p0
        func drop<T: Encodable>(_ list: inout [T]?) -> Bool {
            guard var l = list, let i = l.lastIndex(where: { encode($0) == json }) else { return false }
            l.remove(at: i); list = l.isEmpty ? nil : l; return true
        }
        let done: Bool
        switch kind {
        case "label": done = drop(&p.labels)
        case "key": done = drop(&p.keys)
        case "watch": done = drop(&p.watch)
        default: done = drop(&p.silence)
        }
        return done && save(m, p, bundle: bundle)
    }

    // MARK: The list (TurnOver Shift Slash)

    public static func open() {
        guard Edition.includesPlugins else { Speech.speakMessage(String(localized: "Plugins are not on in this version", comment: "Spoken message")); return }
        guard let (e, pid) = target(), let (bundle, appName) = app(pid) else { Speech.speakMessage(String(localized: "No item to change here", comment: "Spoken message")); return }
        guard bundle != Bundle.main.bundleIdentifier else { Speech.speakMessage(String(localized: "TurnOver's own windows cannot be changed", comment: "Spoken message")); return }
        let obj = ObjectFactory.make(e)
        let itemName = obj.name.isEmpty ? obj.role.displayString : "\(obj.name), \(obj.role.displayString)"
        let items: [MenuItem] = [
            MenuItem("What is this?", .action { whatIsThis(e, pid: pid) }),
            MenuItem("Label this item", .action { label(e, pid: pid, bundle: bundle, appName: appName) }),
            MenuItem("Give this item a key", .action { giveKey(e, pid: pid, bundle: bundle, appName: appName) }),
            MenuItem("Read this when it changes", .action { watch(e, pid: pid, bundle: bundle, appName: appName) }),
            MenuItem("Don't announce this", .action { silence(e, pid: pid, bundle: bundle, appName: appName) }),
            MenuItem("Undo the last change", .action { undo() }),
            MenuItem("My changes for \(appName)", .action { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { listChanges(bundle: bundle, appName: appName) } }),
            MenuItem("Share my changes for \(appName)", .action { share(bundle: bundle, appName: appName) }),
        ]
        TurnOverMenu.shared.openList(verbatim: String(localized: "Change \(itemName)", comment: "The plugin maker's list for an item: %@ is the item"), items: items)
    }

    static func whatIsThis(_ e: AXUIElement, pid: pid_t) {
        let obj = ObjectFactory.make(e)
        let (m, how) = match(for: e, pid: pid)
        var facts = ["\(obj.role.displayString) (\(e.role)\(e.string(kAXSubroleAttribute).map { ", \($0)" } ?? ""))"]
        facts.append(obj.name.isEmpty ? "no name" : "named \(obj.name)")
        if let id = e.string(kAXIdentifierAttribute), !id.isEmpty { facts.append("identifier \(id)") }
        var acts: CFArray?; AXUIElementCopyActionNames(e, &acts)
        let actions = ((acts as? [String]) ?? []).filter { $0.hasPrefix("AX") }.map { $0.dropFirst(2).lowercased() }
        if !actions.isEmpty { facts.append("can \(actions.joined(separator: ", "))") }
        facts.append("TurnOver would match it \(how)")
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = String(data: (try? enc.encode(m)) ?? Data(), encoding: .utf8) ?? ""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(facts.joined(separator: "; ") + "\n\"match\": " + json, forType: .string)
        Speech.speakMessage(facts.joined(separator: ". ") + ". " + String(localized: "Copied", comment: "Copied to the clipboard"))
    }

    static func label(_ e: AXUIElement, pid: pid_t, bundle: String, appName: String) {
        let obj = ObjectFactory.make(e)
        LineInput.ask(String(localized: "Name for this \(obj.role.displayString)", comment: "Labelling an item: %@ is its role"), initial: "") { text in
            guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            let (m, _) = match(for: e, pid: pid)
            var acts: CFArray?; AXUIElementCopyActionNames(e, &acts)
            let pressable = ((acts as? [String]) ?? []).contains("AXPress")
            // A picture or group that can be pressed is said as a button (Bambu Studio's home page icons).
            let role: String? = pressable && ["AXImage", "AXGroup", "AXStaticText"].contains(e.role) ? "button" : nil
            let rule = LabelRule(match: m, name: text.trimmingCharacters(in: .whitespaces), nameFrom: nil, role: role)
            if add("label", bundle: bundle, appName: appName, change: { p in p.labels = (p.labels ?? []) + [rule]; return encode(rule) }) {
                Speech.speakMessage(String(localized: "Labelled \(rule.name ?? ""). Saved in My changes for \(appName)", comment: "An item labelled: %1$@ is the label, %2$@ the app"))
            }
        }
    }

    static func giveKey(_ e: AXUIElement, pid: pid_t, bundle: String, appName: String) {
        let obj = ObjectFactory.make(e)
        let name = obj.name.isEmpty ? obj.role.displayString : obj.name
        TurnOverMenu.captureKey(prompt: "Press the key for \(name). Use the TurnOver key, Command, Control or Option with it") { g in
            // A plain letter, digit or the like would type in the app: it needs a modifier, or to be a function key.
            let fkey = g.keyName.hasPrefix("f") && Int(g.keyName.dropFirst()) != nil
            guard !g.modifiers.isEmpty || fkey else { Speech.speakMessage(String(localized: "\(g.displayName) on its own types in \(appName). Not given; try again with a modifier", comment: "A key that types can't be given: %1$@ is the key, %2$@ the app")); return }
            if let s = ScriptHandler.findScript(for: g), !s.name.hasPrefix("plugin_") {
                Speech.speakMessage(String(localized: "\(g.displayName) already does: \(s.description). Not given; choose another key", comment: "A key already taken: %1$@ is the key, %2$@ its command")); return
            }
            var acts: CFArray?; AXUIElementCopyActionNames(e, &acts)
            let canPress = ((acts as? [String]) ?? []).contains("AXPress")
            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(e, kAXFocusedAttribute as CFString, &settable)
            let action = canPress ? "press" : settable.boolValue ? "focus" : "read"
            let words = action == "press" ? "Presses" : action == "focus" ? "Moves to" : "Reads"
            let (m, _) = match(for: e, pid: pid)
            let id = g.identifier.hasPrefix("kb:") ? String(g.identifier.dropFirst(3)) : g.identifier
            let rule = KeyRule(key: id, description: "\(words) \(name)", action: action, target: m, menu: nil, keys: nil, say: nil)
            if add("key", bundle: bundle, appName: appName, change: { p in p.keys = (p.keys ?? []) + [rule]; return encode(rule) }) {
                let key = g.displayName
                Speech.speakMessage(action == "press" ? String(localized: "\(key) presses \(name) in \(appName). Saved", comment: "A key given to an item: the key, the item, the app")
                    : action == "focus" ? String(localized: "\(key) moves to \(name) in \(appName). Saved", comment: "A key given to an item: the key, the item, the app")
                    : String(localized: "\(key) reads \(name) in \(appName). Saved", comment: "A key given to an item: the key, the item, the app"))
            }
        }
    }

    static func watch(_ e: AXUIElement, pid: pid_t, bundle: String, appName: String) {
        let obj = ObjectFactory.make(e)
        let (m, _) = match(for: e, pid: pid)
        let hasValue = e.attr(kAXValueAttribute) != nil
        let rule = WatchRule(match: m, prefix: obj.name.isEmpty ? nil : obj.name, read: hasValue ? "value" : "text")
        if add("watch", bundle: bundle, appName: appName, change: { p in p.watch = (p.watch ?? []) + [rule]; return encode(rule) }) {
            Speech.speakMessage(obj.name.isEmpty ? String(localized: "TurnOver will read this when it changes. Saved", comment: "An item watched for changes")
                : String(localized: "TurnOver will read \(obj.name) when it changes. Saved", comment: "An item watched for changes: %@ is its name"))
        }
    }

    static func silence(_ e: AXUIElement, pid: pid_t, bundle: String, appName: String) {
        let obj = ObjectFactory.make(e)
        let (m, _) = match(for: e, pid: pid)
        if add("silence", bundle: bundle, appName: appName, change: { p in p.silence = (p.silence ?? []) + [m]; return encode(m) }) {
            Speech.speakMessage(obj.name.isEmpty ? String(localized: "This will not be announced. Saved", comment: "An item silenced")
                : String(localized: "\(obj.name) will not be announced. Saved", comment: "An item silenced: %@ is its name"))
        }
    }

    static func undo() {
        guard let last = history.popLast() else { Speech.speakMessage(String(localized: "Nothing to undo", comment: "Spoken message")); return }
        Speech.speakMessage(remove(kind: last.kind, json: last.json, bundle: last.bundle, appName: last.appName) ? String(localized: "Undone: the \(last.kind) taken out", comment: "A plugin change undone: %@ is its kind (label, key)")
            : String(localized: "Could not undo; it was already removed", comment: "Spoken message"))
    }

    static func listChanges(bundle: String, appName: String) {
        let (_, p) = load(bundle: bundle, appName: appName)
        func words(_ m: ElementMatch) -> String {
            let what = Role.from(axRole: m.role ?? "", subrole: nil).displayString
            let by = m.identifier ?? m.title ?? m.description ?? m.help ?? "unnamed"
            return "\(what) \(by)\(m.nth.map { ", number \($0)" } ?? "")"
        }
        var items: [MenuItem] = []
        func item(_ title: String, kind: String, json: Data) {
            items.append(MenuItem(verbatim: title, .action { Speech.speakMessage(remove(kind: kind, json: json, bundle: bundle, appName: appName) ? String(localized: "Removed", comment: "Spoken message") : String(localized: "Could not remove it", comment: "Spoken message")) }))
        }
        for r in p.labels ?? [] { item("Label: \(words(r.match)) is called \(r.name ?? r.nameFrom ?? "")", kind: "label", json: encode(r)) }
        for r in p.keys ?? [] { item("Key: \(KeyboardGesture(identifier: "kb:" + r.key)?.displayName ?? r.key), \(r.description)", kind: "key", json: encode(r)) }
        for r in p.watch ?? [] { item("Read when it changes: \(words(r.match))", kind: "watch", json: encode(r)) }
        for m in p.silence ?? [] { item("Not announced: \(words(m))", kind: "silence", json: encode(m)) }
        TurnOverMenu.shared.openList(verbatim: String(localized: "My changes for \(appName). Return removes one", comment: "A list of your plugin changes: %@ is the app"), items: items)
    }

    static func share(bundle: String, appName: String) {
        let dir = folder(for: bundle)
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("profile.json").path) else { Speech.speakMessage(String(localized: "No changes for \(appName) yet", comment: "Spoken message: %@ is the app")); return }
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let zip = desktop.appendingPathComponent("My changes for \(appName).zip")
        try? FileManager.default.removeItem(at: zip)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", dir.path, zip.path]
        do { try p.run(); p.waitUntilExit() } catch { Speech.speakMessage(String(localized: "Could not make the file", comment: "Spoken message")); return }
        Speech.speakMessage(p.terminationStatus == 0 ? String(localized: "Saved My changes for \(appName).zip on the Desktop", comment: "Your plugin changes shared as a file: %@ is the app")
            : String(localized: "Could not make the file", comment: "Spoken message"))
    }
}

extension PluginMaker {
    /// For turnover-coretest --maker-test: on the first unnamed pressable element of the app, the match, a label saved,
    /// read back through TurnOver, then removed. Prints nothing of the app's content but roles and the label.
    public static func selfTest(pid: pid_t) -> [String] {
        var out: [String] = []
        guard let (bundle, appName) = app(pid) else { return ["no app"] }
        var m = ElementMatch(); m.unnamed = true; m.pressable = true
        guard let e = ElementMatcher.find(m, pid: pid, limit: 5, budget: 2).first(where: { $0.role != "AXButton" || ($0.string(kAXSubroleAttribute) ?? "").isEmpty }) else { return ["no unnamed pressable element"] }
        out.append("item: \(e.role), name before: \"\(ObjectFactory.make(e).name)\"")
        let (match, how) = match(for: e, pid: pid)
        out.append("matched \(how)")
        let rule = LabelRule(match: match, name: "Maker test label", nameFrom: nil, role: "button")
        guard add("label", bundle: bundle, appName: appName, change: { p in p.labels = (p.labels ?? []) + [rule]; return encode(rule) }) else { return out + ["could not save"] }
        let after = ObjectFactory.make(e)
        out.append("name after: \"\(after.name)\", role \"\(after.roleText ?? after.role.displayString)\"")
        var plain = match; plain.nth = nil
        let others = ElementMatcher.find(plain, pid: pid, limit: 20).filter { !$0.isSame(e) }
        out.append("other unnamed items still unnamed: \(others.allSatisfy { ObjectFactory.make($0).name != "Maker test label" } ? "yes" : "NO") (\(others.count) checked)")
        let check = ProfileStore.load(folder: folder(for: bundle))
        out.append("plugin loads: \(check.error == nil ? "yes" : "no, \(check.error!)"); warnings: \(check.warnings.count)")
        _ = undoLast()
        out.append("after undo: \"\(ObjectFactory.make(e).name)\"")
        return out
    }

    static func undoLast() -> Bool {
        guard let last = history.popLast() else { return false }
        return remove(kind: last.kind, json: last.json, bundle: last.bundle, appName: last.appName)
    }
}

/// A line typed into TurnOver itself, with no dialog: each character echoed, Backspace deletes, Return finishes,
/// Escape cancels (the keyboard commands editor's capture, one key at a time).
public enum LineInput {
    public static func ask(_ prompt: String, initial: String = "", done: @escaping (String?) -> Void) {
        var text = initial
        func next() {
            InputManager.captureNext = { g in
                guard let g else { Speech.speakMessage(String(localized: "cancelled", comment: "Spoken message")); done(nil); return }
                switch g.keyName {
                case "enter", "numpadEnter": done(text); return
                case "backspace":
                    if let c = text.popLast() { Speech.speakMessage(Symbols.name(of: c)) } else { Tones.edge() }
                default:
                    if let ch = g.typedCharacter, g.modifiers.subtracting(.shift).isEmpty { text.append(ch); Speech.speakMessage(Symbols.name(of: ch)) }
                    else if !g.modifiers.contains(.turnover), !g.modifiers.subtracting(.shift).isEmpty { g.send() }   // Control Space: the keyboard language
                    else { Tones.edge() }
                }
                next()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            Speech.speakMessage(String(localized: "\(prompt). Type it, then Return. Escape cancels", comment: "Waiting for typed words: %@ says what for"))
            next()
        }
    }
}
