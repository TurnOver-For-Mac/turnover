// SPDX-License-Identifier: GPL-3.0-or-later
// The real ScriptBroker (docs/PLUGIN-SCRIPTS-PLAN.md, "How it joins TurnOver"; stage 3, 15 Nov 2026): what a plugin's
// script asks of TurnOver, done with Accessibility, speech, the menus and the clipboard. ScriptHost has already checked
// the plugin's abilities, the rates and the sizes; every rule here is about the screen:
// - the item or app a request concerns must belong to one of the plugin's own apps at that moment (the bundle of the
//   process that really owns it, not what the manifest says), and never to a forbidden app;
// - press, focus, edit, menu and keys work only while one of the plugin's apps is in front, by TurnOver's own idea of the
//   focus and by the Mac's frontmost app both (15 Nov 2026), and never in a closed app (PluginPolicy.closedApps), where a
//   script may read and speak and nothing more (16 Nov 2026);
// - press never reaches a menu element: menus are chosen with `menu`, which is checked against the policy;
// - menu and keys are checked against PluginPolicy when asked; keys and edit are refused while the Mac reports secure
//   keyboard entry, while a secure field has the focus, and when TurnOver cannot find what has the focus; edit is never
//   done to a password field;
// - say and sound are dropped (not an error) while none of the plugin's apps is in front or an approval question is open.
// Everything that touches the Mac goes through `ScriptEnvironment`, so a test can stand in for each part.
import Foundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import TurnOverAX

/// What the broker and ScriptPlugins reach out to. `live()` is the real Mac; a test replaces what it exercises.
package struct ScriptEnvironment {
    package var plugins: () -> [LoadedPlugin]
    /// The store whose profiles wait for a script's approval, and the names of TurnOver's own sounds.
    package var profiles: ProfileStore
    package var soundNames: () -> [String]
    /// The process the focus is in (the key availability check's own question), and the bundle a process belongs to.
    package var frontPid: () -> pid_t?
    /// The process of the app the Mac itself says is frontmost (NSWorkspace), which can differ from TurnOver's idea of the focus.
    package var macFrontPid: () -> pid_t?
    /// Whether macOS reports secure keyboard entry (a password field or a program has asked that no one else see the keys).
    package var secureInput: () -> Bool
    package var bundle: (pid_t) -> String
    package var runningPid: (String) -> pid_t?
    package var isRunning: (String) -> Bool
    package var focusedElement: (pid_t) -> AXUIElement?
    package var say: (String, Bool) -> Void
    package var sound: (String) -> Bool
    package var copy: (String) -> Void
    package var sendKeys: (String) -> Bool
    package var chooseMenu: ([String], pid_t) -> Bool
    package var refocus: (pid_t) -> Void
    /// Said by TurnOver itself (notices, the start-up words), and a question put to the person (its words, its answers,
    /// and what to run when it closes however it closes).
    package var speak: (String) -> Void
    package var present: (String, [MenuItem], @escaping () -> Void) -> Void
    package var hostPath: String
    package var afterHang: Bool
    /// Where the plugins' stored data goes (one file per plugin); asked only when something is stored.
    package var storageFolder: () -> URL
    package var limits: ScriptLimits

    @MainActor package static func live() -> ScriptEnvironment {
        ScriptEnvironment(
            plugins: { ProfileStore.shared.plugins },
            profiles: .shared,
            soundNames: { TurnOverSounds.names.sorted() },
            frontPid: { API.focusPid },
            macFrontPid: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            secureInput: { IsSecureEventInputEnabled() },
            bundle: { ProfileStore.shared.bundle(of: $0) },
            runningPid: { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.processIdentifier },
            isRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty },
            focusedElement: { AXUIElementCreateApplication($0).element(kAXFocusedUIElementAttribute) ?? API.focusObject?.element },
            say: { text, interrupt in
                if interrupt { Speech.cancel() }
                Speech.speakMessage(text)
            },
            sound: { TurnOverSounds.play($0) },
            copy: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            sendKeys: { keys in
                guard let gesture = KeyboardGesture(identifier: "kb:" + keys) else { return false }
                gesture.send()
                return true
            },
            chooseMenu: { path, pid in
                // Paste is refused by its shortcut as well as its title, so another language's name for it is refused too.
                guard let item = MenuPath.find(path, pid: pid),
                      !PluginPolicy.isPasteShortcut(character: item.string(kAXMenuItemCmdCharAttribute), modifiers: item.attr(kAXMenuItemCmdModifiersAttribute) as? Int)
                else { return false }
                return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
            },
            refocus: { AXHandler.shared.refocus(pid: $0) },
            speak: { Speech.speakMessage($0) },
            present: { title, items, closed in
                TurnOverMenu.shared.openList(verbatim: title, items: items)
                let before = TurnOverMenu.shared.onClose   // one hook, run once on closing: kept, then ours
                TurnOverMenu.shared.onClose = { before?(); closed() }
            },
            hostPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/turnover-plugin-host").path,
            afterHang: CommandLine.arguments.contains("--after-hang"),
            storageFolder: { AppPaths.file("plugin-data") },
            limits: .standard)
    }
}

package final class AXScriptBroker: ScriptBroker {
    package let pluginID: String
    package let apps: [String]
    private let env: ScriptEnvironment
    private let questionOpen: () -> Bool
    package let handles: ScriptHandleTable
    private var stored: [String: ScriptValue]?

    package init(pluginID: String, apps: [String], environment: ScriptEnvironment, questionOpen: @escaping () -> Bool, handleCapacity: Int = ScriptHandleTable.capacity) {
        self.pluginID = pluginID; self.apps = apps; env = environment; self.questionOpen = questionOpen
        handles = ScriptHandleTable(capacity: handleCapacity)
    }

    // MARK: Whose it is

    /// The apps no script may reach, whatever its manifest says (docs/PLUGIN-SCRIPTS-PLAN.md, "Details settled"):
    /// compared without regard to case, against the bundle identifier of the app that really owns the item.
    nonisolated package static func isForbiddenApp(_ bundle: String) -> Bool {
        let b = bundle.lowercased()
        return b == "com.turnover" || b.hasPrefix("com.turnover.") || PluginPolicy.scriptForbiddenApps.keys.contains { $0.lowercased() == b }
    }

    /// Whether this plugin may deal with the process: one of its named apps, decided as ProfilesPlugin decides which
    /// plugins apply to an app (the manifest's list holds the bundle exactly), and not a forbidden one.
    package func owns(_ pid: pid_t) -> Bool {
        let bundle = env.bundle(pid)
        return !bundle.isEmpty && apps.contains(bundle) && !Self.isForbiddenApp(bundle)
    }

    private var frontOwns: Bool { env.frontPid().map(owns) ?? false }

    /// Acting needs both TurnOver's focus and the Mac's own frontmost app to be the plugin's: either alone can be stale or
    /// wrong, and a request must never reach an app the person is not looking at.
    private var macFrontOwns: Bool { env.macFrontPid().map(owns) ?? false }
    private func requireFront() throws {
        guard frontOwns, macFrontOwns else {
            throw ScriptBrokerError.refused(String(localized: "This works only while one of the plugin's apps is in front.", comment: "Said to a plugin author when a script asks to act while its app is not in front"))
        }
    }

    /// Acting (press, focus, edit, menu, keys) needs the app in front, and is never done in a closed app: there a script reads and
    /// speaks. Decided here against the app really in front (and the item's own app), whatever the manifest and the load said.
    private func requireMayAct(_ element: AXUIElement? = nil) throws {
        try requireFront()
        let pids = [env.frontPid(), env.macFrontPid(), element?.pid].compactMap { $0 }
        if pids.contains(where: { PluginPolicy.isClosedApp(env.bundle($0)) }) {
            throw ScriptBrokerError.refused(String(localized: "In this app a plugin can only read and speak. It can never press, type or choose anything there.", comment: "Said to a plugin author when a script asks to act in a closed app such as Terminal"))
        }
    }

    private static let menuRoles: Set<String> = ["AXMenu", "AXMenuBar", "AXMenuBarItem", "AXMenuItem"]
    /// Whether the element is a menu or part of one: they are chosen with `menu`, through the policy's refusals, never pressed.
    private func isInMenu(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        var hops = 0
        while let x = current, hops < 8 {
            if Self.menuRoles.contains(x.role) { return true }
            current = x.element(kAXParentAttribute); hops += 1
        }
        return false
    }

    private func element(_ args: ScriptValue) throws -> AXUIElement {
        guard let handle = args["handle"]?.stringValue, let element = handles.element(for: handle) else {
            throw ScriptBrokerError.gone(String(localized: "TurnOver does not have that item: it was not given to this plugin, or it was given long ago and has been let go.", comment: "Said to a plugin author when a script uses an item handle TurnOver does not hold"))
        }
        guard owns(element.pid) else {
            throw ScriptBrokerError.refused(String(localized: "That item is not in one of this plugin's apps.", comment: "Said to a plugin author when a script asks about an item in another app"))
        }
        return element
    }

    static func isSecure(_ element: AXUIElement) -> Bool {
        ScriptItem.isSecure(subrole: element.string(kAXSubroleAttribute), role: element.string(kAXRoleAttribute))
    }

    /// Typing for a script (`keys`, `edit`) is refused while the Mac reports secure keyboard entry, while a password field
    /// has the focus, and when what has the focus cannot be found at all: not knowing is not a reason to go ahead. The three
    /// sentences are for each of those, said in the request's own words.
    private func requireNoSecret(secureInput: String, secureFocus: String, unknownFocus: String) throws {
        if env.secureInput() { throw ScriptBrokerError.refused(secureInput) }
        guard let pid = env.frontPid(), let focused = env.focusedElement(pid) else { throw ScriptBrokerError.refused(unknownFocus) }
        if Self.isSecure(focused) { throw ScriptBrokerError.refused(secureFocus) }
    }

    /// The item for a script, with a handle: nil if the element is not in one of the plugin's apps now.
    package func item(for element: AXUIElement) -> ScriptValue? {
        guard owns(element.pid) else { return nil }
        return ScriptItem.read(element).value(handle: handles.handle(for: element))
    }

    // MARK: Requests

    package func perform(_ operation: ScriptOperation, _ args: ScriptValue) throws -> ScriptValue {
        switch operation {
        case .log: return log(args)
        case .say: return say(args)
        case .sound: return sound(args)
        case .focused:
            guard let pid = env.frontPid(), owns(pid), let focus = env.focusedElement(pid) else { return .null }
            return item(for: focus) ?? .null
        case .find: return try find(args)
        case .itemRefresh:
            let e = try element(args)
            let (value, error) = e.attrError(kAXRoleAttribute)
            if value == nil, error == .invalidUIElement || error == .noValue { return .null }
            if value == nil { throw ScriptBrokerError.failed(String(localized: "The app did not answer.", comment: "Said to a plugin author when an app does not answer a question")) }
            return item(for: e) ?? .null
        case .itemParent:
            guard let parent = try element(args).element(kAXParentAttribute) else { return .null }
            return item(for: parent) ?? .null
        case .itemChildren:
            return .array(try element(args).elements(kAXChildrenAttribute).prefix(200).compactMap { item(for: $0) })
        case .itemRead: return try read(args)
        case .itemPress:
            let e = try element(args)
            try requireMayAct(e)
            if isInMenu(e) {
                throw ScriptBrokerError.refused(String(localized: "A menu item cannot be pressed like a button. Choose it with menu, which checks it first.", comment: "Said to a plugin author when a script presses an item that is part of a menu"))
            }
            guard AXUIElementPerformAction(e, kAXPressAction as CFString) == .success else {
                throw ScriptBrokerError.failed(String(localized: "That item could not be pressed.", comment: "Said to a plugin author"))
            }
            return .bool(true)
        case .itemFocus:
            let e = try element(args)
            try requireMayAct(e)
            guard e.set(kAXFocusedAttribute, kCFBooleanTrue) == .success else {
                throw ScriptBrokerError.failed(String(localized: "The focus could not be moved to that item.", comment: "Said to a plugin author"))
            }
            env.refocus(e.pid)
            return .bool(true)
        case .itemSetValue: return try edit(args)
        case .menu: return try menu(args)
        case .keys: return try keys(args)
        case .copy:
            guard let text = args["text"]?.stringValue else { throw ScriptBrokerError.invalid(String(localized: "copy needs the text to put on the clipboard.", comment: "Said to a plugin author")) }
            try requireFront()   // the clipboard is the person's: written only while the plugin's app is the one they are in
            env.copy(text)
            return .null
        case .storageGet, .storageSet, .storageRemove: return try storage(operation, args)
        }
    }

    private func log(_ args: ScriptValue) -> ScriptValue {
        let text = args["text"]?.stringValue ?? ""
        let line = "script \(pluginID): \(Log.words(text))"
        switch args["level"]?.stringValue {
        case "error": Log.error(line)
        case "warning": Log.warning(line)
        default: Log.info(line)
        }
        return .null
    }

    /// Speech and sounds are heard only while the plugin's app is in front and no approval question is open.
    private var mayBeHeard: Bool { frontOwns && macFrontOwns && !questionOpen() }

    private func say(_ args: ScriptValue) -> ScriptValue {
        guard let text = args["text"]?.stringValue, !text.isEmpty else { return .null }
        guard mayBeHeard else { Log.info("script \(pluginID): something it said was dropped (its app is not in front, or a question is open)"); return .null }
        env.say(text, args["interrupt"]?.boolValue ?? false)
        return .null
    }

    private func sound(_ args: ScriptValue) -> ScriptValue {
        guard let name = args["name"]?.stringValue else { return .null }
        guard mayBeHeard else { Log.info("script \(pluginID): a sound it played was dropped (its app is not in front, or a question is open)"); return .null }
        if !env.sound(name) { Log.info("script \(pluginID): TurnOver has no sound called \(Log.words(name))") }
        return .null
    }

    /// Read an item aloud the way a profile key's `read` does (ProfilesPlugin.readingText). Never a password field.
    private func read(_ args: ScriptValue) throws -> ScriptValue {
        let e = try element(args)
        if Self.isSecure(e) { throw ScriptBrokerError.refused(String(localized: "A password field is never read to a plugin.", comment: "Said to a plugin author")) }
        guard mayBeHeard else { Log.info("script \(pluginID): a reading it asked for was dropped (its app is not in front, or a question is open)"); return .null }
        env.say(String(ProfilesPlugin.readingText(of: e).prefix(env.limits.sayCharacters)), false)   // as much as anything else a script says
        return .null
    }

    private func find(_ args: ScriptValue) throws -> ScriptValue {
        var match = ElementMatch()
        if let given = args["match"], given != .null {
            guard JSONSerialization.isValidJSONObject(given.json), let data = try? JSONSerialization.data(withJSONObject: given.json),
                  let decoded = try? JSONDecoder().decode(ElementMatch.self, from: data) else {
                throw ScriptBrokerError.invalid(String(localized: "That is not a match TurnOver understands. Use the fields of a match in profile.json: role, title, identifier and so on.", comment: "Said to a plugin author"))
            }
            match = decoded
        }
        var searched = env.frontPid().flatMap { owns($0) ? $0 : nil }   // the app in front, else a running one of the plugin's
        if searched == nil { searched = apps.lazy.compactMap { self.env.runningPid($0) }.first { self.owns($0) } }
        guard let pid = searched else { return .array([]) }
        // The number is clamped as the number it came as: turning 1e100 into an Int first stops the program. And "the nth" is a
        // place: not zero, and not past what a search can visit.
        var limit = env.limits.findLimit
        if let asked = args["limit"]?.numberValue {
            guard asked.isFinite else { throw ScriptBrokerError.invalid(String(localized: "limit must be a number.", comment: "Said to a plugin author")) }
            limit = Int(max(1, min(Double(env.limits.findLimit), asked)))
        }
        if let nth = match.nth, !ElementMatcher.validNth(nth) {
            throw ScriptBrokerError.invalid(String(localized: "nth counts from 1 (the first) or from -1 (the last); it cannot be 0.", comment: "Said to a plugin author when a match's nth is zero or out of reach"))
        }
        // A script's search never matches on what is in a password field (hideSecure), in this match or any inside it.
        let found: [AXUIElement]
        if match.nth != nil { found = ElementMatcher.findOne(match, pid: pid, budget: env.limits.findBudget, hideSecure: true).map { [$0] } ?? [] }
        else { found = ElementMatcher.find(match, pid: pid, limit: limit, budget: env.limits.findBudget, hideSecure: true) }
        return .array(found.compactMap { item(for: $0) })
    }

    private func edit(_ args: ScriptValue) throws -> ScriptValue {
        let e = try element(args)
        try requireMayAct(e)
        if Self.isSecure(e) { throw ScriptBrokerError.refused(String(localized: "A password field is never changed by a plugin.", comment: "Said to a plugin author")) }
        try requireNoSecret(
            secureInput: String(localized: "The Mac is hiding what is typed, as it does for a password, so a plugin cannot change anything now.", comment: "Said to a plugin author when a script asks to edit while the Mac reports secure keyboard entry"),
            secureFocus: String(localized: "A password field has the focus, so a plugin cannot change anything now.", comment: "Said to a plugin author"),
            unknownFocus: String(localized: "TurnOver cannot tell what has the focus, so a plugin cannot change anything now.", comment: "Said to a plugin author when a script asks to edit and the focused item cannot be found"))
        let value: CFTypeRef
        switch args["value"] {
        case .string(let s)?: value = s as CFString
        case .number(let n)?: value = NSNumber(value: n)
        default: throw ScriptBrokerError.invalid(String(localized: "setValue needs a string or a number.", comment: "Said to a plugin author"))
        }
        guard e.set(kAXValueAttribute, value) == .success else {
            throw ScriptBrokerError.failed(String(localized: "That item's value could not be changed.", comment: "Said to a plugin author"))
        }
        return .bool(true)
    }

    private func menu(_ args: ScriptValue) throws -> ScriptValue {
        try requireMayAct()
        var path: [String] = []
        if case .array(let steps)? = args["path"], steps.count <= 8 { path = steps.compactMap(\.stringValue); if path.count != steps.count { path = [] } }
        guard !path.isEmpty, !path.contains(where: { $0.isEmpty || $0.count > 200 }) else {
            throw ScriptBrokerError.invalid(String(localized: "menu needs a path of menu names, such as [\"Edit\", \"Copy\"].", comment: "Said to a plugin author"))
        }
        if let why = PluginPolicy.menuRefusals(path).first {
            throw ScriptBrokerError.refused(String(localized: "A plugin may not choose that: \(why).", comment: "Said to a plugin author when a script's menu path is refused; the placeholder is the reason"))
        }
        guard let pid = env.frontPid(), env.chooseMenu(path, pid) else {
            throw ScriptBrokerError.failed(String(localized: "That menu item was not found.", comment: "Said to a plugin author"))
        }
        return .bool(true)
    }

    private func keys(_ args: ScriptValue) throws -> ScriptValue {
        try requireMayAct()
        let target = env.frontPid()
        guard let keys = args["keys"]?.stringValue, !keys.isEmpty else {
            throw ScriptBrokerError.invalid(String(localized: "keys needs a key, such as \"command+k\".", comment: "Said to a plugin author"))
        }
        try requireNoSecret(
            secureInput: String(localized: "The Mac is hiding what is typed, as it does for a password, so a plugin cannot press keys now.", comment: "Said to a plugin author when a script asks to press keys while the Mac reports secure keyboard entry"),
            secureFocus: String(localized: "A password field has the focus, so a plugin cannot press keys now.", comment: "Said to a plugin author"),
            unknownFocus: String(localized: "TurnOver cannot tell what has the focus, so a plugin cannot press keys now.", comment: "Said to a plugin author when a script asks to press keys and the focused item cannot be found"))
        if let why = PluginPolicy.refusedKey(keys) {
            throw ScriptBrokerError.refused(String(localized: "A plugin may not send \(keys): \(why).", comment: "Said to a plugin author when a script's key is refused; the placeholders are the key and the reason"))
        }
        // The questions above ask the app, which can be slow: look again, at the same app, just before the keys go.
        try requireMayAct()
        guard env.frontPid() == target else {
            throw ScriptBrokerError.refused(String(localized: "The app in front changed, so the keys were not sent.", comment: "Said to a plugin author when the app in front changed while a script's keys were being checked"))
        }
        guard env.sendKeys(keys) else {
            throw ScriptBrokerError.invalid(String(localized: "\(keys) is not a key combination TurnOver knows.", comment: "Said to a plugin author; the placeholder is the key"))
        }
        return .null
    }

    // MARK: Storage

    private var storageURL: URL? {
        // The id names the file, so it must be only letters, digits and hyphens: anything else is refused, never made into a path.
        PluginManifest.isValidID(pluginID) ? env.storageFolder().appendingPathComponent(pluginID + ".json") : nil
    }

    private func loadStorage(_ url: URL) -> [String: ScriptValue] {
        if let stored { return stored }
        var loaded: [String: ScriptValue] = [:]
        if let data = try? Data(contentsOf: url), data.count <= env.limits.storageBytes,
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            loaded = object.mapValues { ScriptValue(json: $0) }
        }
        stored = loaded
        return loaded
    }

    private func storage(_ operation: ScriptOperation, _ args: ScriptValue) throws -> ScriptValue {
        guard let url = storageURL else {
            throw ScriptBrokerError.refused(String(localized: "This plugin's id cannot be used to keep data.", comment: "Said to a plugin author"))
        }
        guard let key = args["key"]?.stringValue, !key.isEmpty, key.count <= 200 else {
            throw ScriptBrokerError.invalid(String(localized: "storage needs a key: a short word.", comment: "Said to a plugin author"))
        }
        var all = loadStorage(url)
        if operation == .storageGet { return all[key] ?? .null }
        if operation == .storageSet { all[key] = args["value"] ?? .null } else { all.removeValue(forKey: key) }
        guard let data = try? JSONSerialization.data(withJSONObject: ScriptValue.object(all).json, options: [.sortedKeys]) else {
            throw ScriptBrokerError.invalid(String(localized: "That value cannot be kept.", comment: "Said to a plugin author"))
        }
        guard data.count <= env.limits.storageBytes else {
            throw ScriptBrokerError.refused(String(localized: "A plugin may keep at most \(env.limits.storageBytes / 1024) KB in all, and that would be more.", comment: "Said to a plugin author; the placeholder is a number of kilobytes"))
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw ScriptBrokerError.failed(String(localized: "TurnOver could not keep that.", comment: "Said to a plugin author when the stored data could not be written"))
        }
        stored = all
        return .null
    }
}
