// SPDX-License-Identifier: GPL-3.0-or-later
// Settings profiles: VoiceOver's Activities (VO-X, Mac style) and NVDA's configuration profiles (NVDA+Control+P,
// Windows style); one feature for both (docs/VOICEOVER-PARITY.md, decision 14; the parity audit, 13 Oct 2026).
//
// A profile is a named set of the settings that shape what is said and shown: speech, typing echo and text, what is
// reported about objects, web pages, document formatting, braille. Keyboard style, the apps TurnOver reads, keys and
// plugins stay the same whatever the profile. A profile can be switched on by hand, or used for chosen apps (NVDA's
// triggers, VoiceOver's "when this app is in front"); a profile chosen by hand stays until it is switched off.
//
// Safety (the settings wipe of 13 Oct): settings.json always keeps the normal settings. While a profile is on, a
// change is saved into the profile's own file (profiles/<name>.json) and settings.json is written with the normal
// sections as they were; switching the profile off puts them back. A profile file that won't read is left alone.
import Foundation
import AppKit

public enum SettingsProfiles {
    /// What a profile holds.
    struct Sections: Codable {
        var speech: Config.Speech
        var editableText: Config.EditableText
        var presentation: Config.Presentation
        var virtualBuffers: Config.VirtualBuffers
        var documentFormatting: Config.DocumentFormatting
        var braille: Config.Braille
        init(of c: Config) {
            speech = c.speech; editableText = c.editableText; presentation = c.presentation
            virtualBuffers = c.virtualBuffers; documentFormatting = c.documentFormatting; braille = c.braille
        }
        func apply(to c: inout Config) {
            c.speech = speech; c.editableText = editableText; c.presentation = presentation
            c.virtualBuffers = virtualBuffers; c.documentFormatting = documentFormatting; c.braille = braille
        }
    }
    struct Profile: Codable { var name: String; var apps: [String]; var settings: Sections }

    nonisolated(unsafe) private static var activeName: String?        // main thread only
    nonisolated(unsafe) private static var activeByApp = false
    /// The normal settings' sections while a profile is on.
    nonisolated(unsafe) private static var normal: Sections?

    static var folder: URL { AppPaths.file("profiles") }
    static func file(_ name: String) -> URL { folder.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-") + ".json") }

    static func all() -> [Profile] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(Profile.self, from: $0) } }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
    static func write(_ p: Profile) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try enc.encode(p).write(to: file(p.name), options: .atomic) }
        catch { Log.warning("profiles: \(p.name) not saved: \(error.localizedDescription)") }
    }

    // MARK: Saving (Config.save calls this)

    /// What settings.json should hold: with a profile on, the normal sections; the live ones go to the profile.
    static func forSaving(_ live: Config) -> Config {
        guard let name = activeName, let normal else { return live }
        if var p = all().first(where: { $0.name == name }) { p.settings = Sections(of: live); write(p) }
        var out = live
        normal.apply(to: &out)
        return out
    }

    // MARK: Switching

    static func activate(_ name: String, byApp: Bool) {
        guard let p = all().first(where: { $0.name == name }) else { return }
        if activeName == nil { normal = Sections(of: config) }
        activeName = name; activeByApp = byApp
        var c = config; p.settings.apply(to: &c); config = c
        applyLive()
        Log.info("profiles: \(name) on\(byApp ? " (its app is in front)" : "")")
    }

    static func deactivate() {
        guard activeName != nil, let normal else { return }
        Log.info("profiles: \(activeName ?? "") off")
        activeName = nil; activeByApp = false
        var c = config; normal.apply(to: &c); config = c
        Self.normal = nil
        applyLive()
    }

    /// The speech player and braille follow the settings just put in place.
    static func applyLive() {
        Speech.player.rate = config.speech.rate
        Speech.player.volume = Float(config.speech.volume) / 100
        Speech.player.pitch = config.speech.pitchMultiplier
        Speech.player.voiceIdentifier = config.speech.voice
        Ducking.apply()
        Braille.refreshSoon()
    }

    // MARK: Apps

    nonisolated(unsafe) private static var observer: NSObjectProtocol?
    public static func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let bundle = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier ?? ""
            MainActor.assumeIsolated { appCameToFront(bundle) }
        }
    }

    static func appCameToFront(_ bundle: String) {
        guard bundle != Bundle.main.bundleIdentifier else { return }   // TurnOver's own menu doesn't change profiles
        if activeName != nil, !activeByApp { return }   // chosen by hand: stays
        if let p = all().first(where: { $0.apps.contains(bundle) }) {
            if activeName != p.name { if activeName != nil { deactivate() }; activate(p.name, byApp: true); Speech.speakMessage(String(localized: "\(p.name) profile", comment: "A settings profile switched on for an app: its name")) }
        } else if activeName != nil {
            deactivate()
        }
    }

    // MARK: The chooser (VO-X; NVDA+Control+P)

    public static func openChooser() {
        let front = NSWorkspace.shared.frontmostApplication
        let frontBundle = front?.bundleIdentifier ?? ""
        let frontName = front?.localizedName ?? String(localized: "this app", comment: "An application with no name")
        var items: [MenuItem] = []
        items.append(MenuItem(activeName == nil ? "Normal settings, active" : "Normal settings", .action { DispatchQueue.main.async { deactivate(); Speech.speakMessage(String(localized: "normal settings", comment: "Spoken message")) } }))
        for p in all() {
            let on = activeName == p.name
            let apps = p.apps.map { b in NSWorkspace.shared.urlForApplication(withBundleIdentifier: b).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? b }
            var title = on ? String(localized: "\(p.name), active", comment: "A settings profile in use") : p.name
            if !apps.isEmpty { title += String(localized: ", for \(apps.joined(separator: Phrases.and))", comment: "The apps a settings profile is for") }
            items.append(MenuItem(verbatim: title, .submenu {
                var sub: [MenuItem] = []
                sub.append(MenuItem(on ? "Switch off" : "Switch on", .action { DispatchQueue.main.async {
                    if on { deactivate(); Speech.speakMessage(String(localized: "normal settings", comment: "Spoken message")) }
                    else { if activeName != nil { deactivate() }; activate(p.name, byApp: false); Speech.speakMessage(String(localized: "\(p.name) profile on", comment: "A settings profile switched on")) }
                } }))
                if !frontBundle.isEmpty, frontBundle != Bundle.main.bundleIdentifier {
                    let uses = p.apps.contains(frontBundle)
                    sub.append(MenuItem(uses ? "Stop using it for \(frontName)" : "Use it whenever \(frontName) is in front", .action { DispatchQueue.main.async {
                        var q = p
                        q.apps.removeAll { $0 == frontBundle }
                        if !uses { q.apps.append(frontBundle) }
                        write(q)
                        Speech.speakMessage(uses ? String(localized: "\(p.name) no longer used for \(frontName)", comment: "A settings profile and an app: the profile, then the app") : String(localized: "\(p.name) used for \(frontName)", comment: "A settings profile and an app: the profile, then the app"))
                    } }))
                }
                sub.append(MenuItem("Remove \(p.name)", .action { DispatchQueue.main.async { remove(p.name) } }, hint: "Kept in the profiles-removed folder, not deleted"))
                return sub
            }))
        }
        items.append(MenuItem("New profile from the settings now", .action { DispatchQueue.main.async { newProfile(for: nil) } }, hint: "Then change what you like while it is on"))
        if !frontBundle.isEmpty, frontBundle != Bundle.main.bundleIdentifier {
            items.append(MenuItem("New profile for \(frontName)", .action { DispatchQueue.main.async { newProfile(for: (frontBundle, frontName)) } }))
        }
        TurnOverMenu.shared.openList("Profiles", items: items)
    }

    static func newProfile(for app: (bundle: String, name: String)?) {
        LineInput.ask(String(localized: "Profile name", comment: "Spoken message"), initial: app?.name ?? "") { typed in
            guard let raw = typed?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return }
            guard !all().contains(where: { $0.name.lowercased() == raw.lowercased() }) else { Speech.speakMessage("There is a profile called \(raw) already"); return }
            write(Profile(name: raw, apps: app.map { [$0.bundle] } ?? [], settings: Sections(of: config)))
            if activeName != nil { deactivate() }
            activate(raw, byApp: app != nil)
            Speech.speakMessage(String(localized: "\(raw) profile made and on. Changes to speech, verbosity, web pages and braille now go into it.", comment: "A settings profile made: its name"))
        }
    }

    static func remove(_ name: String) {
        if activeName == name { deactivate() }
        let fm = FileManager.default
        let aside = AppPaths.file("profiles-removed")
        try? fm.createDirectory(at: aside, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try? fm.moveItem(at: file(name), to: aside.appendingPathComponent("\(name) \(stamp).json"))
        Speech.speakMessage(String(localized: "\(name) removed", comment: "A settings profile removed: its name"))
    }
}
