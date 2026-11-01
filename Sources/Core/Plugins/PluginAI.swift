// SPDX-License-Identifier: GPL-3.0-or-later
// Sending a plugin brief to an AI, and taking the answer back (the plugin design notes, "Making one").
//
// Claude: the Claude app opens a Claude Code session in the brief folder with the request typed
// in (claude://code/new?folder=…&q=…); it can run turnover-plugin itself, check its work, install.
// ChatGPT and Gemini: their command-line agents (OpenAI's Codex, Google's Gemini CLI) open in Terminal in the
// brief folder, as Claude Code does, and can check, try and install likewise (14 Oct 2026). Without them, their
// websites can't run anything on the Mac, so the brief goes on the clipboard as one self-contained message; the
// user pastes it, copies the answer back, and "Install a plugin from the clipboard" checks and installs it.
import Foundation
import AppKit

public enum PluginAI: String, CaseIterable {
    case claude = "Claude", chatGPT = "ChatGPT", gemini = "Gemini"

    /// The command-line agent for ChatGPT (Codex) or Gemini (Gemini CLI), if installed. A program file, never a
    /// shell function of the same name.
    var agentName: String { self == .chatGPT ? "Codex" : self == .gemini ? "Gemini CLI" : "Claude Code" }
    static func agentPath(_ ai: PluginAI) -> String? {
        let name = ai == .chatGPT ? "codex" : ai == .gemini ? "gemini" : "claude"
        let home = NSHomeDirectory()
        let places = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.npm-global/bin", home + "/bin", home + "/.bun/bin"]
        return places.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The last brief written, so an answer pasted back knows which app and folder it belongs to.
    public static var lastBrief: (folder: URL, app: String, bundle: String)?

    /// Write the brief for the app and hand it to the chosen AI.
    public static func start(_ ai: PluginAI, pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        let name = app.localizedName ?? "this app"
        Speech.speakMessage(String(localized: "Looking at \(name)", comment: "Making a plugin: TurnOver gathers what the app shows"))
        let bundle = app.bundleIdentifier ?? ""
        PluginTry.grant(bundle: bundle)   // choosing this is the consent for the AI to try keys here (3 hours)
        let agent = ai == .claude ? nil : agentPath(ai)
        // The chat brief walks the app too: made in the background with the folder (on main it stalled TurnOver
        // again for a big app; the code review, 13 Oct 2026).
        brief(pid: pid, failure: "Could not make the brief", chat: ai != .claude && agent == nil) { folder, chatText in
            lastBrief = (folder, name, bundle)
            switch ai {
            case .claude:
                let request = "Read BRIEF.md in this folder and follow it to make a TurnOver plugin for \(name). What is wrong: "
                var c = URLComponents(string: "claude://code/new")!
                c.queryItems = [URLQueryItem(name: "folder", value: folder.path), URLQueryItem(name: "q", value: request)]
                guard let url = c.url, NSWorkspace.shared.open(url) else { Speech.speakMessage(String(localized: "Could not open the Claude app", comment: "Spoken message")); return }
                Log.info("plugin brief sent to Claude Code: \(url.absoluteString.prefix(200))")
                Speech.speakMessage(String(localized: "Opening Claude Code in the brief's folder. The request is typed in: finish the sentence with what is wrong in \(name), and send. Claude can check and install the plugin itself.", comment: "Making a plugin with Claude Code: %@ is the app"))
            case .chatGPT where agent != nil, .gemini where agent != nil:
                let request = "Read BRIEF.md in this folder and follow it to make a TurnOver plugin for \(name). Ask me what is wrong first."
                let script = folder.appendingPathComponent("start \(ai == .chatGPT ? "Codex" : "Gemini").command")
                let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
                let body = "#!/bin/zsh -l\ncd \(q(folder.path))\nexec \(q(agent!)) \(ai == .gemini ? "-i " : "")\(q(request))\n"
                do {
                    try body.write(to: script, atomically: true, encoding: .utf8)
                    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
                } catch { Speech.speakMessage(String(localized: "Could not start \(ai.agentName): \(error.localizedDescription)", comment: "An AI tool could not start: its name, then why")); return }
                NSWorkspace.shared.open(script)
                Log.info("plugin brief opened in \(ai.agentName) (\(agent!))")
                Speech.speakMessage(String(localized: "Opening \(ai.agentName) in Terminal, in the brief's folder. It will ask what is wrong in \(name); it can check, try and install the plugin itself.", comment: "Making a plugin with an AI tool: the tool, then the app"))
            case .chatGPT, .gemini:
                let text = chatText ?? ""
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                let site = ai == .chatGPT ? "https://chatgpt.com/" : "https://gemini.google.com/app"
                NSWorkspace.shared.open(URL(string: site)!)
                Log.info("plugin brief for \(ai.rawValue): \(text.count) characters on the clipboard")
                Speech.speakMessage(String(localized: "The brief is copied, and \(ai.rawValue) is opening. Paste it, add what is wrong in \(name), and send. When it answers, copy the whole answer, then choose Install a plugin from the clipboard, in TurnOver's Plugins menu. The brief includes the names shown in \(name).", comment: "Making a plugin with a chat AI: the AI, then the app (twice)"))
            }
        }
    }

    /// The brief written off the main thread (a big app takes seconds to walk), a soft tick every second meanwhile so
    /// the wait isn't silence; then `then` on the main thread with the folder.
    private static func brief(pid: pid_t, failure: String, chat: Bool = false, then: @escaping @MainActor (URL, String?) -> Void) {
        let done = Locked(false)
        func tick() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if !done.value { Tones.beep(880, 30, volume: 0.1); tick() } }
        }
        tick()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try PluginBrief.write(pid: pid) }
            let chatText: String? = chat ? (try? result.get()).map { PluginBrief.chatBrief(folder: $0, pid: pid) } : nil
            DispatchQueue.main.async {
                done.value = true
                switch result {
                case .success(let folder): then(folder, chatText)
                case .failure(let error): Speech.speakMessage("\(failure): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Take an AI's answer from the clipboard: find manifest.json and profile.json in it, check and install.
    /// Write a plugin yourself (8 Oct 2026: "certain devs will enjoy that"): the same starter folder the AI
    /// gets (manifest, an empty profile, the app's snapshot and menus, the guide), opened in Finder, no AI.
    public static func startByHand(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        let name = app.localizedName ?? "this app"
        Speech.speakMessage(String(localized: "Looking at \(name)", comment: "Making a plugin: TurnOver gathers what the app shows"))
        let bundle = app.bundleIdentifier ?? ""
        PluginTry.grant(bundle: bundle)
        brief(pid: pid, failure: "Could not make the starter folder") { folder, _ in
            lastBrief = (folder, name, bundle)
            let plugin = folder.appendingPathComponent("plugin")
            NSWorkspace.shared.activateFileViewerSelecting([plugin])
            Speech.speakMessage(String(localized: "A starter plugin for \(name) is in \(folder.path), opened in Finder. Edit plugin, profile.json, with the guide, snapshot and menus beside it; then choose Install the plugin you are writing.", comment: "A starter plugin made: the app, then the folder"))
            Log.info("plugin starter for \(name) at \(folder.path)")
        }
    }

    /// Install the starter folder's plugin (after Write yourself or an AI brief), checked and with its warnings.
    public static func installStarter() {
        // The starter from this session, or the newest on disk (TurnOver restarted since it was made, 8 Oct 2026).
        let folder = lastBrief?.folder ?? newestStarterFolder()
        guard let folder else { Speech.speakMessage(String(localized: "No starter folder found. Choose Write a plugin yourself, or Make a plugin, first.", comment: "Spoken message")); return }
        Speech.speakMessage(String(localized: "Installing the plugin in \(folder.lastPathComponent)", comment: "A plugin being installed from its folder"))
        install(folder: folder.appendingPathComponent("plugin"))
    }

    /// The newest brief folder that holds a plugin (plugin/manifest.json), if any.
    static func newestStarterFolder() -> URL? {
        let fm = FileManager.default
        let folders = ((try? fm.contentsOfDirectory(at: PluginBrief.briefsFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("plugin/manifest.json").path) }
        return folders.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return da < db
        }
    }

    /// Open the plugin guide in the app for text files.
    public static func openGuide() {
        guard let g = PluginBrief.guideURL else { Speech.speakMessage(String(localized: "The plugin guide is not in this copy of TurnOver", comment: "Spoken message")); return }
        NSWorkspace.shared.open(g)
    }

    private static var pendingInstall: (String, Date)?
    public static func installFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { Speech.speakMessage(String(localized: "The clipboard has no text", comment: "Spoken message")); return }
        let objects = jsonObjects(in: text)
        var manifest: [String: Any]? = objects.first { $0["apps"] != nil && $0["id"] != nil }
        guard let profile = objects.first(where: { ["labels", "keys", "watch", "silence", "view"].contains(where: $0.keys.contains) }) else {
            Speech.speakMessage(String(localized: "No plugin found on the clipboard. Copy the AI's whole answer, with its profile.json.", comment: "Spoken message"))
            return
        }
        // No manifest in the answer: make one for the app the brief was about.
        if manifest == nil, let b = lastBrief {
            let id = (b.bundle.split(separator: ".").last.map(String.init)?.lowercased() ?? "app") + "-profile"
            manifest = ["id": id, "name": b.app, "version": "0.1", "apps": [b.bundle], "kind": "profile"]
        }
        guard let manifest else { Speech.speakMessage(String(localized: "The answer has no manifest.json, and no brief was made this session to say which app it is for.", comment: "Spoken message")); return }
        let folder = (lastBrief?.folder ?? PluginBrief.briefsFolder).appendingPathComponent("plugin-from-clipboard", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("manifest.json"))
            try JSONSerialization.data(withJSONObject: profile, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("profile.json"))
        } catch { Speech.speakMessage(String(localized: "Could not save the plugin: \(error.localizedDescription)", comment: "A plugin not saved: %@ is why")); return }
        install(folder: folder)
    }

    /// Load, warn, check and install the plugin in a folder; a plugin that can quit, delete or send needs the same
    /// Install chosen again within 20 seconds (8 Oct 2026).
    static func install(folder: URL) {
        let plugin = ProfileStore.load(folder: folder)
        if let e = plugin.error { Speech.speakMessage(String(localized: "The plugin does not load: \(String(describing: e))", comment: "A plugin's problem: %@ is the problem (in English)")); return }
        // What it can do to the app, said before it is installed; one that sends keys or chooses menu items (or works
        // in a closed app) needs a second choice of the same Install within 20 seconds (8 Oct 2026; the Self
        // Check, 13 Oct: by what it does, not by English words).
        let warnings = PluginChecker.warnings(for: plugin)
        if warnings.needsConfirmation {
            if let (id, at) = pendingInstall, id == plugin.manifest?.id, Date().timeIntervalSince(at) < 20 {
                pendingInstall = nil
            } else {
                pendingInstall = (plugin.manifest?.id ?? "", Date())
                Speech.speakMessage(String(localized: "This plugin can act on \(plugin.manifest?.name ?? String(localized: "the app", comment: "An app with no name")): \(warnings.lines.joined(separator: "; ")). To install it anyway, choose the same Install again within 20 seconds.", comment: "A plugin's warnings: the app, then the warnings (in English)"))
                return
            }
        } else if !warnings.lines.isEmpty {
            Speech.speakMessage(warnings.lines.joined(separator: "; ") + ".")
        }
        let report = PluginChecker.check(plugin)
        try? report.lines.joined(separator: "\n").write(to: folder.appendingPathComponent("check.txt"), atomically: true, encoding: .utf8)
        do { try PluginChecker.install(plugin) } catch { Speech.speakMessage(String(localized: "Could not install: \(error.localizedDescription)", comment: "A plugin not installed: %@ is why")); return }
        ProfileStore.shared.reload(force: true)
        let name = plugin.manifest?.name ?? "the plugin"
        var said = "Installed \(name): \(report.summary)."
        let real = report.problems - report.unmatched
        if real > 0 { said += " \(real) problem\(real == 1 ? "" : "s"): the check is in check.txt beside the brief; give it to the AI." }
        if report.unmatched > 0 { said += " \(report.unmatched) rule\(report.unmatched == 1 ? "" : "s") matched nothing on the screen showing now." }
        Log.info("plugin from the clipboard: \(said)")
        Speech.speakMessage(said)
    }

    /// Every JSON object in a text: fenced code blocks first, then bare braces.
    public static func jsonObjects(in text: String) -> [[String: Any]] {
        var candidates: [String] = []
        let fence = try! NSRegularExpression(pattern: "```(?:json)?\\s*\\n(.*?)```", options: [.dotMatchesLineSeparators])
        for m in fence.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let r = Range(m.range(at: 1), in: text) { candidates.append(String(text[r])) }
        }
        if candidates.isEmpty {
            // Balanced top-level braces.
            var depth = 0, start: String.Index?
            var inString = false, escape = false
            for i in text.indices {
                let c = text[i]
                if inString { if escape { escape = false } else if c == "\\" { escape = true } else if c == "\"" { inString = false }; continue }
                if c == "\"" { inString = true } else if c == "{" { if depth == 0 { start = i }; depth += 1 }
                else if c == "}", depth > 0 { depth -= 1; if depth == 0, let s = start { candidates.append(String(text[s...i])) } }
            }
        }
        return candidates.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }
}
