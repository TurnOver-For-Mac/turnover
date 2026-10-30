// SPDX-License-Identifier: GPL-3.0-or-later
// Request this app (6 Oct 2026): a tester asks for TurnOver to support the application in front. The
// request says which app it is and how its window is built for accessibility (what kinds of item, how many have
// no label), never what is in it, and goes in an email to the developers for the tester to add a line and send.
// Counting the requests shows which apps matter most; the shape shows how much work each would be.
import Foundation
import AppKit
import ApplicationServices
import TurnOverAX

public enum AppRequest {
    /// The application TurnOver would be asked to support: the one in front, never TurnOver itself.
    public static var frontApp: NSRunningApplication? {
        let app = API.focusPid.flatMap { NSRunningApplication(processIdentifier: $0) } ?? NSWorkspace.shared.frontmostApplication
        return app?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : app
    }

    /// Plugins come from the community; TurnOver supplies the parts (14 Oct 2026: "we're creating the parts for
    /// people to build with"). So the request first finds what the app is built with. If TurnOver has the parts for
    /// that kind of app, anyone can make its plugin: make one, or post it as wanted for plugin makers. If not (Java,
    /// Qt, Flutter, an app that tells the Mac almost nothing), what's missing is parts: ask TurnOver for them.
    public static func request() {
        guard let app = frontApp else { Speech.speakMessage(String(localized: "Switch to the application you'd like help with, then choose this again.", comment: "Spoken message")); return }
        let name = app.localizedName ?? app.bundleIdentifier ?? String(localized: "this app", comment: "An application with no name")
        Speech.speakMessage(String(localized: "Looking at \(name)", comment: "Making a plugin: TurnOver gathers what the app shows"))
        let pid = app.processIdentifier
        let leads = config.applications.leadBundles.contains(app.bundleIdentifier ?? "") ? "TurnOver" : "VoiceOver", edition = Edition.fullName
        DispatchQueue.global(qos: .userInitiated).async {
            let kind = app.bundleURL.map { AppKind.detect(bundle: $0) } ?? AppKind.apple
            let (report, items) = describeCounting(app, pid: pid, leads: leads, edition: edition, kind: kind)
            DispatchQueue.main.async { offer(name: name, bundle: app.bundleIdentifier ?? "", pid: pid, kind: kind, nearlyEmpty: items < 4, report: report) }
        }
    }

    static func offer(name: String, bundle: String, pid: pid_t, kind: AppKind, nearlyEmpty: Bool, report: String) {
        Log.info("app request: \(name) (\(bundle)), built with \(kind.name), parts \(kind.partsReady && !nearlyEmpty ? "ready" : "missing")")
        if kind.partsReady && !nearlyEmpty {
            var items = [MenuItem("Make a plugin for \(name) yourself", .action { PluginAI.startByHand(pid: pid) }, hint: "A starter folder with the guide, a snapshot of the app and its menus")]
            for ai in PluginAI.allCases { items.append(MenuItem("Make one with \(ai.rawValue)", .action { PluginAI.start(ai, pid: pid) })) }
            items.append(MenuItem("Post \(name) as wanted, for plugin makers", .action { send(name: name, bundle: bundle, kind: "plugin wanted: " + kind.name, report: report) },
                                  hint: "Opens a public request on GitHub, filled in with how the app is built, never what is in it. You need a GitHub account"))
            TurnOverMenu.shared.openList("\(name) is built with \(kind.name). TurnOver has the parts for it, so anyone can make its plugin", items: items)
        } else {
            let why = nearlyEmpty ? String(localized: "\(name) tells the Mac almost nothing about its window", comment: "Why an app can't be tuned yet: %@ is the app")
                : String(localized: "TurnOver hasn't got the parts for apps built with \(kind.name) yet", comment: "Why an app can't be tuned yet: %@ is what it is built with")
            TurnOverMenu.shared.openList(verbatim: why, items: [
                MenuItem("Ask TurnOver for the parts", .action { send(name: name, bundle: bundle, kind: nearlyEmpty ? "an app that draws its own window" : kind.name, report: report) },
                         hint: "A public request on GitHub, filled in with how the app is built, never what is in it. You need a GitHub account"),
            ])
        }
    }

    /// The app, its version, and the shape of its front window: counts of each kind of item, unlabelled controls,
    /// the focused item's kind. No names, values or text.
    nonisolated static func describe(_ app: NSRunningApplication, pid: pid_t, leads: String, edition: String) -> String {
        describeCounting(app, pid: pid, leads: leads, edition: edition, kind: app.bundleURL.map { AppKind.detect(bundle: $0) } ?? .apple).0
    }

    /// The report, and how many items the front window has (a window of three or fewer tells the Mac almost nothing).
    nonisolated static func describeCounting(_ app: NSRunningApplication, pid: pid_t, leads: String, edition: String, kind: AppKind) -> (String, Int) {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 1.0)
        let bundle = app.bundleIdentifier ?? "?"
        let version = app.bundleURL.flatMap { Bundle(url: $0) }.flatMap { b in
            [b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, (b.object(forInfoDictionaryKey: "CFBundleVersion") as? String).map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        } ?? "?"
        var roles: [String: Int] = [:]
        var unlabelled = 0, visited = 0
        let controls: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXSlider", "AXLink"]   // what a user presses; images and fields in lists carry their meaning elsewhere
        if let w = el.element(kAXFocusedWindowAttribute) ?? el.elements(kAXWindowsAttribute).first {
            var queue = [w]
            while !queue.isEmpty, visited < 3000 {
                let e = queue.removeFirst(); visited += 1
                let role = e.role
                let sub = e.string(kAXSubroleAttribute).map { "/\($0)" } ?? ""
                roles[role + sub, default: 0] += 1
                if controls.contains(role) {
                    let label = [kAXTitleAttribute, kAXDescriptionAttribute, "AXLabel", kAXHelpAttribute].compactMap { e.string($0) }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    if label == nil, e.element("AXTitleUIElement") == nil { unlabelled += 1 }
                }
                queue.append(contentsOf: e.elements(kAXChildrenAttribute))
            }
        }
        let focus = el.element(kAXFocusedUIElementAttribute)
        let focusKind = focus.map { [$0.role, $0.string(kAXSubroleAttribute)].compactMap { $0 }.joined(separator: "/") } ?? "none"
        let top = roles.sorted { $0.value > $1.value }.prefix(25).map { "  \($0.key): \($0.value)" }.joined(separator: "\n")
        return ("""
        App: \(app.localizedName ?? "?")
        Bundle: \(bundle)
        Version: \(version)
        Built with: \(kind.name)
        Led by: \(leads)
        From the Mac App Store: \(app.bundleURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/_MASReceipt").path) } ?? false)
        Front window: \(visited) items\(visited >= 3000 ? " (stopped counting)" : ""); controls with no label: \(unlabelled)
        Focus: \(focusKind)
        Kinds of item:
        \(top)
        \(edition); macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        """, visited)
    }

    public static func describeForTest(_ app: NSRunningApplication) -> String { describe(app, pid: app.processIdentifier, leads: config.applications.leadBundles.contains(app.bundleIdentifier ?? "") ? "TurnOver" : "VoiceOver", edition: Edition.fullName) }

    /// A request on TurnOver's issue form (the idea form), filled in: the app's name, version and how it is built
    /// (kinds of item and counts, never what is in it), so it can be public. The person adds what they use it for.
    static func send(name: String, bundle: String, kind: String, report: String) {
        Log.info("app request: \(name) (\(bundle))")
        let tuning = kind.hasPrefix("tuning: ")
        let appVersion = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.bundleURL
            .flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String } ?? ""
        let idea = """
        \(tuning ? "Please tune TurnOver for \(name)" : kind.hasPrefix("plugin wanted: ") ? "A plugin wanted for \(name), built with \(kind.dropFirst(15))" : "TurnOver hasn't got the parts for \(name), built with \(kind)")\(appVersion.isEmpty ? "" : " (version \(appVersion))").

        What I use it for, and where VoiceOver lets me down in it:


        ---
        How \(name) is built for accessibility (kinds of item and counts; no content, names or text):
        \(report.prefix(1500))
        """
        let title = tuning ? "Tune this app: \(name)" : kind.hasPrefix("plugin wanted: ") ? "Plugin wanted: \(name)" : "Parts for \(kind): \(name)"
        var c = URLComponents(string: Edition.issuesURL + "/new")!
        c.queryItems = [URLQueryItem(name: "template", value: "idea.yml"), URLQueryItem(name: "title", value: title),
                        URLQueryItem(name: "idea", value: idea)]
        guard let url = c.url else { return }
        NSWorkspace.shared.open(url)
        Speech.speakMessage(String(localized: "TurnOver's request form is open in your browser, filled in for \(name). Add what you use it for, then submit it. You need a GitHub account.", comment: "A request for an app opened in the browser: %@ is the app"))
    }
}

/// What an app is built with, found from its bundle: the "flavour" that decides which of TurnOver's parts it needs.
/// partsReady: TurnOver's core handles this kind (checked on the app days, 10 to 12 Oct 2026), so a plugin can do
/// the rest. Not ready: no app of the kind has been worked through yet.
nonisolated public struct AppKind: Equatable, Sendable {
    public let name: String
    public let partsReady: Bool
    public static let apple = AppKind(name: "Apple's own kits (AppKit or SwiftUI)", partsReady: true)

    public static func detect(bundle: URL) -> AppKind {
        let fm = FileManager.default
        let contents = bundle.appendingPathComponent("Contents")
        func has(_ path: String) -> Bool { fm.fileExists(atPath: contents.appendingPathComponent(path).path) }
        let frameworks = (try? fm.contentsOfDirectory(atPath: contents.appendingPathComponent("Frameworks").path)) ?? []
        func framework(_ prefix: String) -> Bool { frameworks.contains { $0.hasPrefix(prefix) } }
        let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")) as? [String: Any] ?? [:]
        if bundle.path.contains("/Wrapper/") {   // an iPhone or iPad app installed on the Mac lives in a wrapper
            return AppKind(name: "iPhone and iPad apps", partsReady: true)
        }
        if framework("Electron Framework") { return AppKind(name: "Electron", partsReady: true) }
        if framework("Chromium Embedded Framework") { return AppKind(name: "Chromium (CEF)", partsReady: true) }
        if framework("FlutterMacOS") { return AppKind(name: "Flutter", partsReady: false) }
        if framework("Qt") { return AppKind(name: "Qt", partsReady: false) }
        if framework("UnityPlayer") || has("Frameworks/UnityPlayer.dylib") { return AppKind(name: "Unity", partsReady: false) }
        if has("Java") || has("runtime/Contents/Home") || has("PlugIns/jdk") || has("PlugIns/jre") || has("MacOS/libjli.dylib") { return AppKind(name: "Java", partsReady: false) }
        if has("MonoBundle") || has("MacOS/libcoreclr.dylib") || has("MacOS/libAvaloniaNative.dylib") || has("Frameworks/libcoreclr.dylib") {
            return AppKind(name: ".NET (Avalonia, MAUI or Mono)", partsReady: false)
        }
        // Catalyst apps carry UIKit's device family (Messages 2, WhatsApp and Podcasts 6); SwiftUI apps such as
        // Calculator have a scene manifest too, so that is no sign (measured 14 Oct 2026).
        if info["UIDeviceFamily"] != nil { return AppKind(name: "Mac Catalyst (iPad apps made for the Mac)", partsReady: true) }
        if frameworks.contains(where: { $0.hasPrefix("libwx") }) { return AppKind(name: "wxWidgets", partsReady: true) }
        // wxWidgets linked into the app itself (Bambu Studio): its name is in the program. Read in pieces, at most 300 MB.
        if let exe = (info["CFBundleExecutable"] as? String).map({ contents.appendingPathComponent("MacOS/\($0)") }),
           let h = try? FileHandle(forReadingFrom: exe) {
            defer { try? h.close() }
            let needle = Data("wxWidgets".utf8)
            var tail = Data(), read = 0
            while read < 300_000_000, let chunk = try? h.read(upToCount: 4_000_000), !chunk.isEmpty {
                read += chunk.count
                let window = tail + chunk
                if window.range(of: needle) != nil { return AppKind(name: "wxWidgets", partsReady: true) }
                tail = window.suffix(needle.count)
            }
        }
        return apple
    }
}
