// SPDX-License-Identifier: GPL-3.0-or-later
// Help improve this app (7 Nov 2026, Oliver: "a really easy flow from within TurnOver itself for people to contribute
// whilst I keep control of core functionality and gatekeep security"). The TurnOver menu's This app section offers
// four ways in, for the app in front:
// - Tell us what's wrong: TurnOver's problem form, filled in with the app, the build and a report of how the app is
//   built, for anyone, no technical knowledge needed.
// - Build it with my AI: a folder describing the app, and Claude Code, Codex or Gemini CLI opened in it with the
//   request typed in, following AI-CONTRIBUTOR.md. The AI writes the app's module and opens a pull request; the
//   module fence (.github/workflows/module-fence.yml) keeps it to that app.
// - Build it myself: the same folder, and MODULE-GUIDE.md.
// - Ask for a building block: the building-block form, filled in the same way.
// The report that goes to GitHub is AppRequest's: kinds of item and counts, never names, values or text. The fuller
// snapshot (names shown in the window, the menus) stays in the folder on this Mac, for the person's own AI.
import Foundation
import AppKit

public enum HelpImprove {
    nonisolated static let repo = "https://github.com/TurnOver-For-Mac/turnover"
    static var guideURL: URL { URL(string: repo + "/blob/main/MODULE-GUIDE.md")! }
    static var briefURL: String { repo + "/blob/main/AI-CONTRIBUTOR.md" }

    /// The This app section's submenu.
    public static func menuItems(pid: pid_t, name: String) -> [MenuItem] {
        var items = [
            MenuItem("Tell us what's wrong in \(name)", .action { report(pid: pid, name: name, form: .problem) },
                     hint: "Opens TurnOver's problem form in your browser, filled in with \(name) and how it is built, never what is in it. You add what goes wrong. You need a GitHub account"),
        ]
        for ai in PluginAI.allCases where PluginAI.agentPath(ai) != nil || ai == .claude {
            items.append(MenuItem("Build it with \(ai.agentName)", .action { build(pid: pid, name: name, ai: ai) },
                                  hint: "For people with \(ai.agentName) and Xcode installed and a GitHub account; Tell us what's wrong needs none of that. \(ai.agentName) opens with a description of \(name) and TurnOver's brief, and helps you make \(name)'s module and send it to the project. It asks you before anything is posted. For three hours it may also try keys in \(name)"))
        }
        items.append(MenuItem("Build it myself", .action { build(pid: pid, name: name, ai: nil) },
                              hint: "For people with Xcode and a GitHub account. A folder describing \(name), opened in Finder, and the guide to writing a module in your browser"))
        items.append(MenuItem("Ask for a building block", .action { report(pid: pid, name: name, form: .buildingBlock) },
                              hint: "When \(name) needs something TurnOver's core doesn't have yet. Opens the request form in your browser, filled in with \(name) and how it is built"))
        return items
    }

    // MARK: The report and the forms

    nonisolated package enum Form: Sendable { case problem, buildingBlock }

    /// The report written off the main thread (a big window takes a moment), a soft tick meanwhile; then the form.
    static func report(pid: pid_t, name: String, form: Form) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        Speech.speakMessage(String(localized: "Looking at \(name)", comment: "Making a plugin: TurnOver gathers what the app shows"))
        gather(app) { report in
            open(form, name: name, report: report)
        }
    }

    static func gather(_ app: NSRunningApplication, then: @escaping @MainActor (String) -> Void) {
        let leads = config.applications.leadBundles.contains(app.bundleIdentifier ?? "") ? "TurnOver" : "VoiceOver"
        let edition = Edition.fullName
        let done = Locked(false)
        func tick() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if !done.value { Tones.beep(880, 30, volume: 0.1); tick() } }
        }
        tick()
        DispatchQueue.global(qos: .userInitiated).async {
            let kind = app.bundleURL.map { AppKind.detect(bundle: $0) } ?? AppKind.apple
            let report = AppRequest.describeCounting(app, pid: app.processIdentifier, leads: leads, edition: edition, kind: kind).0
            DispatchQueue.main.async { done.value = true; then(report) }
        }
    }

    /// The build, macOS and keyboard style, as the problem form asks.
    static var versions: String {
        let style = KeyboardStyle(rawValue: config.general.keyboardStyle).map { "\($0)" } ?? config.general.keyboardStyle
        return "\(Edition.fullName), macOS \(ProcessInfo.processInfo.operatingSystemVersionString), keyboard style \(style)"
    }

    /// The filled-in form's address. Only the app's name, the versions and the report go in it: no content.
    nonisolated package static func formURL(_ form: Form, name: String, report: String, versions: String) -> URL? {
        var c = URLComponents(string: repo + "/issues/new")!
        let shape = "How \(name) is built for accessibility (kinds of item and counts; no content, names or text):\n" + String(report.prefix(1500))
        switch form {
        case .problem:
            c.queryItems = [URLQueryItem(name: "template", value: "problem.yml"), URLQueryItem(name: "title", value: "\(name): "),
                            URLQueryItem(name: "app", value: name), URLQueryItem(name: "versions", value: versions),
                            URLQueryItem(name: "report", value: shape)]
        case .buildingBlock:
            c.queryItems = [URLQueryItem(name: "template", value: "building-block.yml"), URLQueryItem(name: "title", value: "Building block for \(name): "),
                            URLQueryItem(name: "app", value: name), URLQueryItem(name: "tried", value: "\n\n---\n" + shape)]
        }
        return c.url
    }

    static func open(_ form: Form, name: String, report: String) {
        guard let url = formURL(form, name: name, report: report, versions: versions) else { return }
        Log.info("help improve: \(form == .problem ? "problem" : "building block") form for \(name)")
        NSWorkspace.shared.open(url)
        Speech.speakMessage(form == .problem
            ? String(localized: "The problem form is open in your browser, filled in for \(name). Say what you did and what you heard, then submit it. You need a GitHub account.", comment: "Help improve this app: the problem form opened; %@ is the app")
            : String(localized: "The building block form is open in your browser, filled in for \(name). Say what the app needs, then submit it. You need a GitHub account.", comment: "Help improve this app: the building block form opened; %@ is the app"))
    }

    // MARK: Building it

    /// Where the folders for building are kept: the person's own, on this Mac.
    static var folder: URL { AppPaths.file("contribute") }

    /// A folder describing the app (the public report, the fuller snapshot and the menus, and what to do), then the
    /// AI opened in it, or the folder and the guide for someone building by hand.
    static func build(pid: pid_t, name: String, ai: PluginAI?) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        let bundle = app.bundleIdentifier ?? ""
        if ai != nil { PluginTry.grant(bundle: bundle) }   // choosing this is the consent for the AI to try keys here (3 hours)
        Speech.speakMessage(String(localized: "Looking at \(name)", comment: "Making a plugin: TurnOver gathers what the app shows"))
        let base = folder, versions = versions, brief = briefURL
        gather(app) { report in
            DispatchQueue.global(qos: .userInitiated).async {
                let made = Result { try write(pid: pid, name: name, bundle: bundle, report: report, base: base, versions: versions, brief: brief) }
                DispatchQueue.main.async {
                    switch made {
                    case .failure(let error):
                        Speech.speakMessage(String(localized: "Could not make the folder: \(error.localizedDescription)", comment: "Help improve this app: the folder could not be written"))
                    case .success(let dir):
                        if let ai { launch(ai, folder: dir, name: name) } else { byHand(folder: dir, name: name) }
                    }
                }
            }
        }
    }

    /// Off the main thread: the snapshot walks the window. Everything from the main actor comes in as arguments.
    nonisolated package static func write(pid: pid_t, name: String, bundle: String, report: String, base: URL, versions: String, brief: String) throws -> URL {
        let stamp: String = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmm"; return f.string(from: Date()) }()
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let dir = base.appendingPathComponent("\(safe) \(stamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        # Improving TurnOver for \(name)

        Bundle id: \(bundle)
        \(versions)

        Follow TurnOver's brief for AI contributors, \(brief), to make or improve \(name)'s
        module, with the person who opened this folder. Ask them first what goes wrong in \(name), and what they
        hear.

        Before you write any code, in TurnOver's repository:

        - Read AGENTS.md (the rules every contributor follows) and MODULE-GUIDE.md (how modules work).
        - Change only \(name)'s folder under Sources/Apps, its register line and its tests. Anything else is
          TurnOver's core: ask for a building block instead (docs/BUILDING-BLOCKS.md).
        - Before the pull request: ./build.sh must finish with every test passed, and
          python3 Tools/check-module-fence.py origin/main --outside must say it's inside the fence. GitHub checks
          both again on the pull request.

        Before anything is installed, tell the person, plainly:

        - They need Xcode (free from the App Store, but a very large download), a GitHub account, and you.
        - Trying their module means installing the TurnOver they build in place of the one they have. It's signed
          differently, so macOS may ask them to allow Accessibility and Input Monitoring again, and it doesn't
          update itself.
        - To go back afterwards: download TurnOver again from https://turnoverformac.com, replace the one in
          Applications, and allow the permissions again if asked. Updates then come back.
        - If that's more than they want, Tell us what's wrong (in TurnOver's menu, beside this) sends what they
          know, and someone else can build it.

        These files describe the app as TurnOver sees it:

        - report.txt: how \(name) is built (kinds of item and counts). It has no content, so it may be quoted in a
          public issue or pull request.
        - snapshot.txt: the app's windows, with the names they show. It can hold the person's own content (names of
          messages, documents, people), so use it to understand the app, and never paste it anywhere public.
        - menus.txt: the app's menus.

        The person chose this from TurnOver's menu, which lets you try keys in \(name) for three hours with
        `/Applications/TurnOver.app/Contents/MacOS/turnover-plugin try "\(name)" <keys>`.

        """.write(to: dir.appendingPathComponent("START.md"), atomically: true, encoding: .utf8)
        try report.write(to: dir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        try PluginBrief.snapshot(pid: pid, frontWindowOnly: true).text.write(to: dir.appendingPathComponent("snapshot.txt"), atomically: true, encoding: .utf8)
        try PluginBrief.menus(pid: pid).write(to: dir.appendingPathComponent("menus.txt"), atomically: true, encoding: .utf8)
        return dir
    }

    /// Claude Code through the Claude app; Codex or Gemini CLI in Terminal (as PluginAI opens them for plugins).
    static func launch(_ ai: PluginAI, folder dir: URL, name: String) {
        let request = "Read START.md in this folder and follow it to help me make TurnOver work better with \(name)."
        if ai == .claude {
            var c = URLComponents(string: "claude://code/new")!
            c.queryItems = [URLQueryItem(name: "folder", value: dir.path), URLQueryItem(name: "q", value: request)]
            guard let url = c.url, NSWorkspace.shared.open(url) else {
                Speech.speakMessage(String(localized: "Could not open the Claude app", comment: "Spoken message")); return
            }
            Log.info("help improve: Claude Code opened for \(name)")
            Speech.speakMessage(String(localized: "Opening Claude Code in a folder about \(name). The request is typed in: send it, and Claude will ask you what goes wrong.", comment: "Help improve this app: Claude Code opened; %@ is the app"))
            return
        }
        guard let agent = PluginAI.agentPath(ai) else { return }
        let script = dir.appendingPathComponent("start \(ai.agentName).command")
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let body = "#!/bin/zsh -l\ncd \(q(dir.path))\nexec \(q(agent)) \(ai == .gemini ? "-i " : "")\(q(request))\n"
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch {
            Speech.speakMessage(String(localized: "Could not start \(ai.agentName): \(error.localizedDescription)", comment: "An AI tool could not start: its name, then why")); return
        }
        NSWorkspace.shared.open(script)
        Log.info("help improve: \(ai.agentName) opened for \(name)")
        Speech.speakMessage(String(localized: "Opening \(ai.agentName) in Terminal, in a folder about \(name). It will ask you what goes wrong.", comment: "Help improve this app: an AI tool opened; the tool, then the app"))
    }

    static func byHand(folder dir: URL, name: String) {
        NSWorkspace.shared.activateFileViewerSelecting([dir.appendingPathComponent("START.md")])
        NSWorkspace.shared.open(guideURL)
        Log.info("help improve: by hand for \(name), folder \(dir.lastPathComponent)")
        Speech.speakMessage(String(localized: "A folder describing \(name) is open in Finder, and the guide to writing a module is open in your browser.", comment: "Help improve this app: by hand; %@ is the app"))
    }
}
