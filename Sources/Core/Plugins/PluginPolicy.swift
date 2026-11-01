// SPDX-License-Identifier: GPL-3.0-or-later
// What plugins may do, beyond what their listing says (the plugin design notes, decisions 10 and 13 and the code review's
// refusals, 13 Oct 2026). Two kinds of rule:
// - refused everywhere, on anyone's Mac: ways out of the plugin's own app (the Apple and Services menus, system-wide
//   keys, Paste) and TurnOver's essential keys;
// - for the library only (Community level): apps closed to community plugins, labels only on unnamed items, no
//   catch-all rules, no replacing a built-in view, no speech that passes itself off as TurnOver.
// A private plugin that breaks a library rule still installs on its maker's Mac, with a warning.
import Foundation

public enum PluginPolicy {
    /// Apps only official plugins may claim: passwords, security, system settings, terminals, TurnOver, browsers.
    public static let closedApps: [String: String] = [
        "com.apple.Passwords": "Passwords", "com.1password.1password": "1Password", "com.agilebits.onepassword7": "1Password",
        "com.bitwarden.desktop": "Bitwarden", "com.lastpass.LastPass": "LastPass", "com.dashlane.dashlanephonefinal": "Dashlane",
        "com.apple.keychainaccess": "Keychain Access", "com.apple.systempreferences": "System Settings",
        "com.apple.SecurityAgent": "macOS security dialogs", "com.apple.LocalAuthentication.UIAgent": "macOS security dialogs",
        "com.apple.CoreServicesUIAgent": "macOS dialogs", "com.apple.UserNotificationCenter": "macOS dialogs",
        "com.apple.Terminal": "Terminal", "com.googlecode.iterm2": "iTerm", "dev.warp.Warp-Stable": "Warp",
        "net.kovidgoyal.kitty": "kitty", "com.github.wez.wezterm": "WezTerm", "com.mitchellh.ghostty": "Ghostty",
        "com.turnover.reader": "TurnOver",
        "com.apple.Safari": "Safari", "com.google.Chrome": "Chrome", "org.mozilla.firefox": "Firefox",
        "com.microsoft.edgemac": "Edge", "com.brave.Browser": "Brave", "company.thebrowser.Browser": "Arc",
        "com.operasoftware.Opera": "Opera", "com.vivaldi.Vivaldi": "Vivaldi",
    ]
    /// Keys a plugin may never send: they reach outside its app (switching apps, Spotlight, Spaces, screenshots,
    /// Force Quit, locking) or use the clipboard behind the user's back (Paste).
    nonisolated public static let refusedSentKeys: [String] = [
        "command+tab", "command+shift+tab", "command+space", "control+space", "command+option+space",
        "control+leftArrow", "control+rightArrow", "control+upArrow", "control+downArrow",
        "command+shift+3", "command+shift+4", "command+shift+5", "command+option+escape",
        "control+command+q", "command+v", "command+shift+v", "command+option+v", "command+option+shift+v",
        "command+h", "command+option+h", "command+m", "command+option+d",
        "command+shift+q", "command+option+8", "command+option+=", "command+option+-",   // log out; zoom
    ]

    /// Menu items a plugin may never choose, matched against each step of its menu path: the clipboard behind the
    /// user's back, and the Mac's own (log out, restart, lock, settings) wherever an app copies them.
    nonisolated public static let refusedMenuItems = ["Paste", "Paste and Match Style", "Paste Style", "Paste and Retain Formatting",
        "Paste Special", "Log Out", "Lock Screen", "Restart", "Shut Down", "Sleep", "Force Quit", "System Settings",
        "System Preferences", "Services"]

    /// The library's levels (the plugin design notes, decision 6): Community plugins meet every library rule; Verified ones may
    /// rename items the app already names; Official ones (TurnOver's own) may also claim closed apps and give views.
    public enum Level: String, CaseIterable, Sendable { case community = "Community", verified = "Verified", official = "Official" }

    public struct Findings {
        /// Never allowed, on any Mac.
        public var refused: [String] = []
        /// Allowed on the maker's own Mac (Draft), not in the library.
        public var libraryOnly: [String] = []
    }

    /// Why a key a plugin sends would reach outside its app, or nil. By shape as well as by name (code review, 13 Oct:
    /// the list missed Command F5, which turns VoiceOver on or off, logging out, Spaces and more).
    nonisolated static func refusedKey(_ sent: String) -> String? {
        let id = normalizeGestureIdentifier("kb:" + sent)
        if refusedSentKeys.map({ normalizeGestureIdentifier("kb:" + $0) }).contains(id) { return "it reaches outside the app or uses the clipboard" }
        guard let g = KeyboardGesture(identifier: id) else { return nil }   // not a key at all: the listing check says so
        let m = g.modifiers, k = g.keyName.lowercased()
        if m.contains(.turnover) { return "it presses TurnOver's own keys" }
        if m.contains(.command) && m.contains(.control) { return "Command Control keys belong to TurnOver and the Mac" }
        if m.contains(.command) && m.contains(.option) && m.contains(.shift) { return "Command Option Shift keys reach the whole Mac (logging out among them)" }
        if k.hasPrefix("f"), Int(k.dropFirst()) != nil {
            if !m.isEmpty { return "function keys with modifiers reach the Mac (Command F5 turns VoiceOver on or off)" }
            if k == "f11" { return "F11 shows the desktop" }
        }
        if m.contains(.control), ["1", "2", "3", "4", "5", "6", "7", "8", "9", "uparrow", "downarrow", "leftarrow", "rightarrow"].contains(k) {
            return "Control with a number or an arrow moves between Spaces"
        }
        if m.contains(.command) && m.contains(.shift), ["3", "4", "5", "6"].contains(k) { return "it takes screenshots" }
        return nil
    }

    /// What no plugin may do on any Mac, from its profile alone: checked at load as well as install, so a plugin
    /// copied into the folder or edited in place can't get round it (code review, 13 Oct).
    nonisolated public static func refusals(_ p: Profile?) -> [String] {
        var out: [String] = []
        let essential = Set(PluginListing.essentialKeys.map { normalizeGestureIdentifier("kb:" + $0) })
        for k in p?.keys ?? [] {
            if essential.contains(normalizeGestureIdentifier(k.key.hasPrefix("kb:") ? k.key : "kb:" + k.key)) {
                out.append("\(k.key) is one of TurnOver's essential keys (its way in and its way out)")
            }
            // A plain key (a letter, Return, Delete) would type in the app or take a key the app needs: a modifier
            // beyond Shift, or a function key. The maker refused it; a hand-written or pasted file didn't (the full
            // code review, 14 Oct 2026).
            if let g = KeyboardGesture(identifier: normalizeGestureIdentifier(k.key.hasPrefix("kb:") ? k.key : "kb:" + k.key)) {
                let fkey = g.keyName.lowercased().hasPrefix("f") && Int(g.keyName.dropFirst()) != nil
                if g.modifiers.subtracting(.shift).isEmpty, !fkey { out.append("\(k.key) on its own would type in the app: a key needs a modifier (Caps Lock, Command, Control or Option) or a function key") }
            }
            if k.action == "menu", let path = k.menu, let first = path.first {
                if first.lowercased() == "apple" || first == "\u{F8FF}" { out.append("\(k.key): the Apple menu belongs to the Mac, not the app") }
                // A pattern for the first menu could land on the Apple menu, which comes first.
                if first.contains("*") { out.append("\(k.key): the first menu must be named, not a pattern (it could reach the Apple menu)") }
                for step in path {
                    let st = step.lowercased()
                    // "Log Out Example User…", "Restart…": the Mac's items carry more words; "Sleep Timer" doesn't count.
                    let prefixed = ["Log Out", "Restart", "Shut Down", "Force Quit"]
                    if let item = refusedMenuItems.first(where: { ElementMatcher.glob(step, $0) || (prefixed.contains($0) && st.hasPrefix($0.lowercased())) }) {
                        out.append("\(k.key): the menu item \(item) is never a plugin's to choose")
                        break
                    }
                }
            }
            if k.action == "keys", let sent = k.keys, let why = refusedKey(sent) { out.append("\(k.key) sends \(sent): \(why)") }
        }
        return out
    }

    /// The built-in features an official plugin may switch on (PluginManifest.provides).
    public static let features = ["games", "trackpad"]

    public static func check(_ plugin: LoadedPlugin, level: Level = .community) -> Findings {
        var f = Findings()
        guard let m = plugin.manifest else { return f }
        let p = plugin.profile
        f.refused = refusals(p)
        // A built-in feature switched on: official plugins only, and only a feature TurnOver has.
        if let pr = m.provides {
            if !features.contains(pr) { f.refused.append("provides \"\(pr)\": TurnOver has no such feature (\(features.joined(separator: ", ")))") }
            else if level != .official { f.libraryOnly.append("provides \"\(pr)\" switches on a feature built into TurnOver: official plugins only") }
        }
        // The library's rules.
        guard level != .official else { return f }
        for b in m.apps { if let name = closedApps[b] { f.libraryOnly.append("\(name) is open to official plugins only (passwords, security, settings, terminals, browsers)") } }
        for (i, l) in (p?.labels ?? []).enumerated() {
            if l.match.unnamed != true, level == .community { f.libraryOnly.append("label \(i + 1) can rename an item the app already names: add \"unnamed\": true (renaming needs Verified)") }
            if isCatchAll(l.match) { f.libraryOnly.append("label \(i + 1) matches nearly everything: narrow it") }
            if let n = l.name, let why = impersonates(n) { f.libraryOnly.append("label \(i + 1): \(why)") }
        }
        for (i, s) in (p?.silence ?? []).enumerated() where isCatchAll(s) { f.libraryOnly.append("silence \(i + 1) matches nearly everything: it would mute the app") }
        for (i, w) in (p?.watch ?? []).enumerated() {
            if isCatchAll(w.match) { f.libraryOnly.append("watch \(i + 1) matches nearly everything: narrow it") }
            if let pre = w.prefix, let why = impersonates(pre) { f.libraryOnly.append("watch \(i + 1): \(why)") }
        }
        for k in p?.keys ?? [] {
            if let s = k.say, let why = impersonates(s) { f.libraryOnly.append("\(k.key): \(why)") }
            if let t = k.target, isCatchAll(t) { f.libraryOnly.append("\(k.key): its target matches nearly everything") }
        }
        if p?.view != nil, m.apps.contains(where: { AppModuleHandler.shared.moduleType(for: $0) != nil }) {
            f.libraryOnly.append("a view for an app TurnOver already reads with an official module")
        }
        return f
    }

    /// A match that names nothing particular: a role at most.
    static func isCatchAll(_ m: ElementMatch) -> Bool {
        if let any = m.any { return any.contains(where: isCatchAll) }
        let specific: [Any?] = [m.subrole, m.identifier, m.title, m.description, m.help, m.value, m.text, m.window, m.inside, m.parent, m.nth]
        return specific.allSatisfy { $0 == nil }
    }

    /// Words a plugin may not speak: passing itself off as TurnOver or VoiceOver, or sending you somewhere.
    static func impersonates(_ text: String) -> String? {
        let t = text.lowercased()
        if t.contains("turnover") || t.contains("voiceover") || t.contains("voice over") { return "its words mention TurnOver or VoiceOver" }
        if text.range(of: #"\+?\d[\d \-()]{7,}\d"#, options: .regularExpression) != nil { return "its words contain a phone number" }
        if text.range(of: #"(https?://|www\.|\b[a-z0-9-]+\.(com|net|org|co|io|uk)\b)"#, options: [.regularExpression, .caseInsensitive]) != nil { return "its words contain a web address" }
        return nil
    }
}
