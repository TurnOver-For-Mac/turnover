// SPDX-License-Identifier: GPL-3.0-or-later
// The user's own keys (NVDA's Input Gestures dialog; VoiceOver's Keyboard Commander and NumPad Commander). Any key
// can be given to a TurnOver command or to opening an application, and any of TurnOver's keys can be taken away.
// Right Option keys are their own ("right option S", VoiceOver's Keyboard Commander), as are numpad keys.
// (a tester asked for an editor, a tester for his right Option app keys and numpad, 9 Oct 2026. VoiceOver's own
// Commander settings sit in a container macOS does not let other apps read, so they cannot be copied across.)
import Foundation
import AppKit

public enum UserGestures {
    /// What a key does: a command by script name, an application by bundle identifier, or nothing (taken away).
    public enum Target: Equatable {
        case script(String), app(String), removed
        /// From VoiceOver's customisations (17 Oct 2026): a Shortcut by identifier, an AppleScript file, a VoiceOver
        /// command TurnOver has no answer for yet (said so when pressed).
        case shortcut(String), file(String), voiceOver(String)
        init?(_ s: String) {
            if s == "none" { self = .removed }
            else if s.hasPrefix("script:") { self = .script(String(s.dropFirst(7))) }
            else if s.hasPrefix("app:") { self = .app(String(s.dropFirst(4))) }
            else if s.hasPrefix("shortcut:") { self = .shortcut(String(s.dropFirst(9))) }
            else if s.hasPrefix("file:") { self = .file(String(s.dropFirst(5))) }
            else if s.hasPrefix("vo:") { self = .voiceOver(String(s.dropFirst(3))) }
            else { return nil }
        }
        var stored: String {
            switch self {
            case .script(let n): return "script:" + n; case .app(let b): return "app:" + b; case .removed: return "none"
            case .shortcut(let i): return "shortcut:" + i; case .file(let p): return "file:" + p; case .voiceOver(let c): return "vo:" + c
            }
        }
    }

    /// The key's identifiers, most particular first: right Option keys have their own ("kb:rightoption+s").
    public static func identifiers(of g: KeyboardGesture) -> [String] {
        var ids: [String] = []
        // With Shift too: right Option Shift N is its own key, not Option Shift N (a tester, 19 Oct 2026: it was
        // stored without "right", so any Option Shift N ran it).
        if g.flags.rawValue & 0x40 != 0, g.modifiers == [.option] || g.modifiers == [.option, .shift] {
            ids.append("kb:rightoption+" + (g.modifiers.contains(.shift) ? "shift+" : "") + g.keyName)
        }
        return ids + g.identifiers
    }

    /// The identifier a captured key is stored under.
    /// The plain form ("kb:…"), or the right Option form: not the keyboard layout's ("kb(laptop):…"), which was
    /// stored at first and would not survive a change of layout (found live, 10 Oct 2026).
    public static func storedIdentifier(of g: KeyboardGesture) -> String {
        let ids = identifiers(of: g)
        return normal(ids.first { $0.hasPrefix("kb:rightoption+") } ?? ids.first { $0.hasPrefix("kb:") } ?? ids.first ?? "")
    }
    /// TurnOver's normal form, keeping "rightoption", which the general normaliser does not know (it dropped it).
    static func normal(_ id: String) -> String { id.hasPrefix("kb:rightoption+") ? id : normalizeGestureIdentifier(id) }

    /// TurnOver's own right Option keys, used unless the user gives the key something else (or takes it away):
    /// right Option T, the time and, pressed twice, the date (12 Oct 2026; TurnOver Shift T does the same).
    public static let defaults: [String: String] = ["kb:rightoption+t": "script:dateTime"]

    public static func target(for g: KeyboardGesture) -> Target? {
        for id in identifiers(of: g) {
            // VoiceOver's Option Commander off (VO-Shift-K) turns off the right Option keys TurnOver gives by default, not
            // ones the user set: those were skipped too, the key typed its character, and Right Option / said
            // "division" (a tester, 19 Oct 2026, with the Commander off).
            if id.hasPrefix("kb:rightoption+"), !config.keyboard.optionCommander, config.keyboard.userGestures[normal(id)] == nil { continue }
            if let s = config.keyboard.userGestures[normal(id)] ?? defaults[normal(id)], let t = Target(s) { return t }
        }
        return nil
    }

    /// The script a user key runs here, nil when it has none of the user's (then TurnOver's own keys apply).
    /// `removed` comes back as `.removed`: the key goes to the application.
    public enum Found { case script(Script), removed }
    /// Keys no reassignment touches: the way out of focus mode and of input help, the mode key, TurnOver's way in
    /// and its way out (a code review, 14 Oct 2026: Escape set to nothing left a page stuck in focus mode).
    nonisolated public static let protected: Set<String> = Set(["kb:escape", "kb:turnover+space", "kb:command+control+,", "kb:command+control+."].map(normalizeGestureIdentifier))
    public static func isProtected(_ g: KeyboardGesture) -> Bool { !protected.isDisjoint(with: identifiers(of: g).map(normalizeGestureIdentifier)) }

    public static func lookup(_ g: KeyboardGesture) -> Found? {
        if isProtected(g) { return nil }
        guard let t = target(for: g) else { return nil }
        switch t {
        case .removed: return .removed
        case .script(let name):
            // A command that only answers somewhere else (Word's, in Mail): the key falls back to TurnOver's own.
            return ScriptHandler.findScript(named: name).map { .script($0) }
        case .app(let bundle):
            return .script(Script(name: "user_openApp", description: String(localized: "Opens \(appName(bundle))", comment: "Your own key: %@ is the app it opens"), category: "Your keys", owner: nil) { _ in openApp(bundle) })
        case .shortcut(let id):
            return .script(Script(name: "user_shortcut", description: String(localized: "Runs a Shortcut", comment: "Your own key: it runs a Shortcut"), category: "Your keys", owner: nil) { _ in VoiceOverCommands.runShortcut(id) })
        case .file(let path):
            return .script(Script(name: "user_scriptFile", description: String(localized: "Runs \((path as NSString).lastPathComponent)", comment: "Your own key: %@ is the script it runs"), category: "Your keys", owner: nil) { _ in VoiceOverCommands.runScriptFile(path) })
        case .voiceOver(let command):
            let name = VoiceOverCommands.englishName(of: command)
            return .script(Script(name: "user_voiceOverCommand", description: String(localized: "VoiceOver's \(name)", comment: "Your own key: %@ is a VoiceOver command's English name"), category: "Your keys", owner: nil) { _ in Speech.speakMessage(String(localized: "VoiceOver's \(name) isn't in TurnOver yet", comment: "A VoiceOver command TurnOver lacks: %@ is its English name")) })
        }
    }

    public static func set(_ g: KeyboardGesture, to t: Target) {
        if isProtected(g) { Log.info("keys: \(g.identifier) is essential; not reassigned"); Speech.speakMessage(String(localized: "\(g.displayName) is one of TurnOver's essential keys and can't be changed", comment: "Spoken message: %@ is the command")); return }
        config.keyboard.userGestures[storedIdentifier(of: g)] = t.stored
        config.save()
        Log.info("user keys: \(storedIdentifier(of: g)) → \(t.stored)")
    }
    public static func clear(_ id: String) { config.keyboard.userGestures[id] = nil; config.save() }

    /// "right option S", "numpad 8", "caps shift L".
    public static func spoken(_ id: String) -> String {
        let body = id.components(separatedBy: ":").last ?? id
        return body.split(separator: "+").map { part -> String in
            switch part {
            case "rightoption": return "right option"
            case "turnover", "bosun": return config.general.turnOverKeyName
            default:
                if let code = KeyNames.code(for: String(part)) { return KeyNames.spoken(for: code, characters: "") }
                return String(part)
            }
        }.joined(separator: " ")
    }

    public static func describe(_ t: Target) -> String {
        switch t {
        case .removed: return String(localized: "does nothing in TurnOver (goes to the application)", comment: "What your own key does")
        case .app(let b): return String(localized: "opens \(appName(b))", comment: "What your own key does: %@ is the app")
        case .script(let n): return ScriptHandler.findScript(named: n)?.description ?? n
        case .shortcut: return String(localized: "runs a Shortcut", comment: "What your own key does")
        case .file(let p): return String(localized: "runs the script \((p as NSString).lastPathComponent)", comment: "What your own key does: %@ is the script")
        case .voiceOver(let c): return String(localized: "VoiceOver's \(VoiceOverCommands.englishName(of: c)), not in TurnOver yet", comment: "What your own key does: %@ is a VoiceOver command's English name")
        }
    }

    static func appName(_ bundle: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundle
    }
    static func openApp(_ bundle: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { Speech.speakMessage(String(localized: "\(appName(bundle)) is not installed", comment: "An app is not installed: %@ is the app")); return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { onMain { Speech.speakMessage(String(localized: "could not open \(appName(bundle)): \(error.localizedDescription)", comment: "An app could not open: the app, then why")) } }
        }
    }

    /// Every command that answers where the user is now, for the editor's list: TurnOver's global commands, the
    /// application's, the page's and the focus's, each once.
    public static func availableCommands() -> [Script] {
        var out: [Script] = []
        // Only commands that exist in this style and edition: the Windows style's Screen Curtain key was listed in
        // the Mac style, and pressing it did nothing (a tester, 16 Oct 2026).
        // The app's and the focus's commands only where they answer now; TurnOver's own and the plugins' always, whatever
        // the keyboard style: a key the user gives a command runs it by name, in either style. Filtered by the style,
        // VoiceOver's paragraph and table moves vanished from the list in the Windows style (a tester, 19 Oct 2026).
        func add(_ list: [Script], checked: Bool) { for s in list where !s.description.isEmpty && !s.name.hasPrefix("test_") && (!checked || (s.isAvailable?() ?? true)) && !out.contains(where: { $0.name == s.name }) { out.append(s) } }
        if let pid = API.focusPid { add(AppModuleHandler.shared.appModule(for: pid).allScripts, checked: true) }
        if let d = API.focusTreeInterceptor { add(d.allScripts, checked: true) }
        if let f = API.focusObject { add(f.allScripts, checked: true) }
        for p in GlobalPluginHandler.shared.plugins { add(p.allScripts, checked: false) }
        add(GlobalCommands.shared.allScripts, checked: false)
        return out.sorted { ($0.category, $0.description) < ($1.category, $1.description) }
    }
}
