// SPDX-License-Identifier: GPL-3.0-or-later
// An AI making a plugin tries keys in the app and hears what TurnOver says (14 Oct 2026: people should
// make plugins with Claude Code, Codex or Gemini the way we do: look, try, listen, tune).
//
// The AI never presses keys itself: `turnover-plugin try <app> <keys…>` asks TurnOver, which has the Mac's
// permission to. TurnOver does it only:
//  - for an app the person chose "Make a plugin" for, in the last three hours (the consent; "Stop AIs trying keys"
//    in the Plugins menu ends it at once);
//  - never in an app closed to plugins (passwords, security, settings, terminals, browsers);
//  - never with a key that quits, closes, deletes, reaches outside the app, or belongs to TurnOver's own layer;
//  - at most 30 keys a time, saying aloud that an AI is trying keys, then going back to the window it came from.
// What TurnOver said meanwhile goes back in a file only this user can read (tries/<id>.json), not in the
// notification (other programs can hear those).
import Foundation
import TurnOverControl
import AppKit
import ApplicationServices

public enum PluginTry {
    /// Said as an AI starts trying keys, and left out of what it hears back.
    static func tryingWords(_ app: String) -> String { String(localized: "An AI is trying keys in \(app).", comment: "An AI is pressing keys in an app to test a plugin") }
    nonisolated static let consentKey = "pluginTryConsent"
    nonisolated public static let maxKeys = 30
    /// TurnOver's own settings domain, read and written directly: the plugin tool lives inside TurnOver.app and
    /// shares its bundle identifier, and the Mac refuses a suite named after your own bundle (tried 14 Oct 2026).
    nonisolated static let domainName = "com.turnover.reader"
    nonisolated public static func currentConsents() -> [String: Date] {
        CFPreferencesAppSynchronize(domainName as CFString)
        return (CFPreferencesCopyAppValue(consentKey as CFString, domainName as CFString) as? [String: Date]) ?? [:]
    }
    nonisolated static func store(_ c: [String: Date]?) {
        CFPreferencesSetAppValue(consentKey as CFString, c.map { $0 as CFDictionary }, domainName as CFString)
        CFPreferencesAppSynchronize(domainName as CFString)
    }
    nonisolated public static var resultsFolder: URL { AppPaths.file("tries") }

    // MARK: Consent

    /// The person chose to make a plugin for this app with an AI (or by hand): keys may be tried there for 3 hours.
    /// The consents TurnOver itself granted, in memory: the stored copy is for the plugin tool's own pre-check, and
    /// any process running as the user could write it (code review, 16 Oct 2026). TurnOver acts on this one.
    nonisolated(unsafe) private static var granted: [String: Date] = [:]
    public static func grant(bundle: String, hours: Double = 3) {
        guard !bundle.isEmpty else { return }
        var c = currentConsents().filter { $0.value > Date() }
        c[bundle] = Date().addingTimeInterval(hours * 3600)
        granted = c
        store(c)
        Log.info("plugin try: keys may be tried in \(bundle) for \(Int(hours)) hours")
    }

    public static func revokeAll() {
        granted = [:]
        store(nil)
        Log.info("plugin try: consent withdrawn")
        Speech.speakMessage(String(localized: "AIs can no longer try keys in any app.", comment: "Spoken message"))
    }

    nonisolated public static func consented(_ bundle: String, now: Date = Date()) -> Bool {
        consented(bundle, in: currentConsents(), now: now)
    }
    nonisolated public static func consented(_ bundle: String, in consents: [String: Date], now: Date) -> Bool {
        (consents[bundle].map { $0 > now }) ?? false
    }
    public static var anyConsent: Bool {
        granted.values.contains { $0 > Date() }
    }

    // MARK: What may be tried (pure)

    /// Keys that quit, close or delete: refused whatever the app.
    nonisolated static let destructive = ["command+q", "command+w", "command+option+w", "command+shift+w", "command+delete",
        "command+backspace", "command+shift+delete", "command+shift+backspace", "command+option+delete",
        "command+option+backspace", "command+option+shift+delete", "command+option+shift+backspace", "command+option+escape"]

    /// Why this step can't be tried, or nil. A step is a key as TurnOver writes it ("downArrow",
    /// "turnover+control+shift+s", "command+2") or "wait 1.5".
    nonisolated public static func refusal(_ step: String) -> String? {
        let s = step.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("wait") {
            let n = Double(s.dropFirst(4).trimmingCharacters(in: .whitespaces)) ?? -1
            return (0.1...10).contains(n) ? nil : "\(s): wait takes 0.1 to 10 seconds"
        }
        let id = normalizeGestureIdentifier("kb:" + s)
        guard let g = KeyboardGesture(identifier: id) else { return "\(s) is not a key TurnOver knows (write keys as turnover+shift+p, command+2, downArrow)" }
        if destructive.map({ normalizeGestureIdentifier("kb:" + $0) }).contains(id) { return "\(s) quits, closes or deletes" }
        if PluginPolicy.refusedSentKeys.map({ normalizeGestureIdentifier("kb:" + $0) }).contains(id) { return "\(s) reaches outside the app or uses the clipboard" }
        let m = g.modifiers, k = g.keyName.lowercased()
        if m.contains(.command) && m.contains(.control) { return "\(s): Command Control keys are TurnOver's own and the Mac's" }
        if m.contains(.command) && m.contains(.option) && m.contains(.shift) { return "\(s) reaches the whole Mac" }
        if k.hasPrefix("f"), Int(k.dropFirst()) != nil, !m.isEmpty, !m.contains(.turnover) { return "\(s): function keys with modifiers reach the Mac" }
        // Control Option arrows are VoiceOver's keys, not the Spaces ones.
        if m.contains(.control), !m.contains(.turnover), !m.contains(.option), ["1", "2", "3", "4", "5", "6", "7", "8", "9", "uparrow", "downarrow", "leftarrow", "rightarrow"].contains(k) {
            return "\(s) moves between Spaces"
        }
        return nil
    }

    /// Why this request can't be done, or nil. Pure, given the consents.
    public static func refusal(bundle: String, steps: [String], consents: [String: Date], now: Date = Date()) -> String? {
        if let name = PluginPolicy.closedApps[bundle] { return "\(name) is closed to plugins, so keys aren't tried there" }
        guard consented(bundle, in: consents, now: now) else {
            return "TurnOver hasn't been asked to let an AI try keys in this app. In TurnOver's menu, Plugins, choose Make a plugin with the app in front; that allows it for three hours"
        }
        if steps.isEmpty { return "no keys given" }
        if steps.filter({ !$0.hasPrefix("wait") }).count > maxKeys { return "at most \(maxKeys) keys at a time" }
        return steps.lazy.compactMap { refusal($0) }.first
    }

    // MARK: Doing it (TurnOver itself)

    private static var busy = false

    /// The request comes through TurnOver's control channel: only the plugin tool (signed by TurnOver's developer) can
    /// ask TurnOver to press keys (any program could, by distributed notification, until a code review on 18 Oct 2026).
    public static func start() {
        guard Edition.includesPlugins else { return }   // Standard has no plugins, so no one tries keys through it
        ControlServer.shared.handlers["try"] = { message, _ in
            let id = message["id"] as? String ?? "", bundle = message["bundle"] as? String ?? ""
            let steps = (message["keys"] as? String ?? "").split(separator: "\n").map(String.init)
            handle(id: id, bundle: bundle, steps: steps)
        }
    }

    private static func finish(_ id: String, said: [String], error: String?) {
        guard UUID(uuidString: id) != nil else { return }   // the id names the file: never a path
        try? FileManager.default.createDirectory(at: resultsFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = resultsFolder.appendingPathComponent("\(id).json")
        var object: [String: Any] = ["said": said]
        if let error { object["error"] = error }
        if let data = try? JSONSerialization.data(withJSONObject: object) {
            FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }

    static func handle(id: String, bundle: String, steps: [String]) {
        guard UUID(uuidString: id) != nil else { Log.warning("plugin try: a request without a proper id; ignored"); return }
        let consents = granted   // never the stored copy: see `granted`
        if let why = refusal(bundle: bundle, steps: steps, consents: consents) {
            Log.info("plugin try: refused for \(bundle): \(why)")
            finish(id, said: [], error: why); return
        }
        guard !busy else { finish(id, said: [], error: "TurnOver is already trying keys; ask again in a moment"); return }
        // TurnOver's own menu or a question to the person is open (installing a plugin asks whether TurnOver should
        // read its app): keys would answer it for them (an AI's Escape dismissed that question, 14 Oct 2026).
        if TurnOverMenu.shared.isOpen || FindPrompt.shared.isOpen {
            finish(id, said: [], error: "TurnOver is showing the person a menu or a question; ask them to answer or close it, then try again"); return
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
            finish(id, said: [], error: "\(bundle) isn't running: ask the person to open it"); return
        }
        busy = true
        let name = app.localizedName ?? bundle
        let previous = NSWorkspace.shared.frontmostApplication
        Log.info("plugin try: \(steps.count) steps in \(name)")
        Speech.speakMessage(Self.tryingWords(name))
        // To the front the way TurnOver's own app switches go (a background app may not simply activate another).
        _ = AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        app.activate()
        let started = Date()
        func step(_ i: Int) {
            guard i < steps.count else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { done() }
                return
            }
            let s = steps[i].trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("wait") {
                let n = Double(s.dropFirst(4).trimmingCharacters(in: .whitespaces)) ?? 1
                DispatchQueue.main.asyncAfter(deadline: .now() + n) { step(i + 1) }
                return
            }
            // Only into the app it was asked for: if the person switched away, it stops.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                Log.info("plugin try: \(name) is no longer in front; stopped after \(i) steps")
                done(stopped: "stopped after \(i) of \(steps.count) steps: \(name) is no longer in front"); return
            }
            if let g = KeyboardGesture(identifier: normalizeGestureIdentifier("kb:" + s)) { KeyboardGesture.typedPoster?(g) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { step(i + 1) }
        }
        func done(stopped: String? = nil) {
            let said = Speech.history.value.filter { $0.at >= started }.map(\.text)
                .filter { $0 != Self.tryingWords(name) }
            if let previous, previous.processIdentifier != app.processIdentifier, !previous.isTerminated {
                _ = AXUIElementSetAttributeValue(AXUIElementCreateApplication(previous.processIdentifier), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                previous.activate()
            }
            busy = false
            Log.info("plugin try: done in \(name), \(said.count) things said")
            finish(id, said: said, error: stopped)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                busy = false
                finish(id, said: [], error: "\(name) didn't come to the front"); return
            }
            step(0)
        }
    }
}
