// SPDX-License-Identifier: GPL-3.0-or-later
// turnover-plugin: the plugin maker's tool (the plugin design notes, PLUGIN-GUIDE.md). Made for AIs as much as people:
// every command prints plain text and exits non-zero when something needs fixing.
//
//   turnover-plugin brief <app>              write a brief folder for a running app (~/TurnOver Plugins/…)
//   turnover-plugin snapshot <app>           print the app's structure now
//   turnover-plugin menus <app>              print the app's menu paths
//   turnover-plugin check <folder> [--read]  check a plugin against the running app; --read shows web content as TurnOver reads it
//   turnover-plugin install <folder>         copy a checked plugin into TurnOver's plugins folder
//   turnover-plugin list                     the installed plugins
//   turnover-plugin listen                   what TurnOver says, live, as you try the app (Control C stops)
//   turnover-plugin parts                    the parts this TurnOver has that plugin makers asked for, and its build
//   turnover-plugin try <app> <key>…         TurnOver presses the keys in the app and prints what it said ("wait 1"
//                                            between keys waits); only for an app the person chose Make a plugin for
//   turnover-plugin explain <key> [app]      which command a key reaches there, and who else would answer it
//   turnover-plugin record <app> <folder>    each new screen of the app, as you move through it, into <folder>/tests (masked)
//   turnover-plugin test <folder>            the plugin's own tests (tests/expect.json), against its recorded screens
//
// <app> is a bundle identifier or the app's name, and the app must be running.
import Foundation
import AppKit
import ApplicationServices
import TurnOverCore
import TurnOverControl
import AXFixtures
import PluginTestKit

let args = Array(CommandLine.arguments.dropFirst())
Speech.mode = .off   // a tool: it never speaks
func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }
func usage() -> Never {
    fail("""
    usage:
      turnover-plugin brief <app>
      turnover-plugin snapshot <app>
      turnover-plugin menus <app>
      turnover-plugin check <plugin folder> [--read] [--listing] [--level Community|Verified|Official]
      turnover-plugin install <plugin folder>
      turnover-plugin list
      turnover-plugin listen
      turnover-plugin explain <key> [app] [--style windows|mac]
      turnover-plugin record <app> <plugin folder> [--no-mask]
      turnover-plugin test <plugin folder>
      turnover-plugin parts
      turnover-plugin try <app> <key> [<key>…]   (keys as turnover+shift+p, command+2, downArrow; "wait 1" waits)
    <key> as TurnOver writes it: turnover+shift+p, control+option+1, f6.
    <app> is a bundle identifier or the app's name; it must be running.
    """)
}
guard let command = args.first else { usage() }
// The plugin tests replay recorded screens through a library dyld must load at launch: start again with it, once.
if command == "test", !AXReplay.isAvailable, ProcessInfo.processInfo.environment["TURNOVER_PLUGIN_RELAUNCHED"] == nil {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    let shim = AXReplay.shimPath(besides: exe)
    if FileManager.default.fileExists(atPath: shim) {
        setenv("DYLD_INSERT_LIBRARIES", shim, 1); setenv("TURNOVER_PLUGIN_RELAUNCHED", "1", 1)
        let argv = CommandLine.arguments.map { strdup($0) } + [nil]
        execv(exe, argv)
    }
}
if !AXIsProcessTrusted() { fail("This tool needs Accessibility permission for the app it runs in (System Settings, Privacy & Security, Accessibility).") }

func runningApp(_ s: String) -> NSRunningApplication {
    let all = NSWorkspace.shared.runningApplications
    if let a = all.first(where: { $0.bundleIdentifier == s }) ?? all.first(where: { ($0.localizedName ?? "").lowercased() == s.lowercased() }) { return a }
    fail("\(s) is not running. Open it first.")
}

func loadPlugin(_ path: String) -> LoadedPlugin {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    let p = ProfileStore.load(folder: url)
    if let e = p.error { fail("The plugin does not load: \(e)") }
    return p
}


switch command {
case "brief":
    guard args.count >= 2 else { usage() }
    let app = runningApp(args[1])
    do { print(try PluginBrief.write(pid: app.processIdentifier).path) } catch { fail("\(error.localizedDescription)") }

case "snapshot":
    guard args.count >= 2 else { usage() }
    let s = PluginBrief.snapshot(pid: runningApp(args[1]).processIdentifier)
    print(s.text)
    print("\n\(s.elements) elements, \(s.unnamed) unnamed controls")

case "menus":
    guard args.count >= 2 else { usage() }
    print(PluginBrief.menus(pid: runningApp(args[1]).processIdentifier))

case "check":
    guard args.count >= 2 else { usage() }
    let checked = loadPlugin(args[1])
    for w in checked.warnings { print("warning: \(w)") }
    // The listing and keys first: they need no running app (the GitHub check runs this with --listing only).
    BuiltInModules.register()   // the official modules' keys count in the clash check
    // The level the library gives it (the library's index tool passes it from levels.json): Verified may rename, Official more.
    let level = args.firstIndex(of: "--level").flatMap { i in args.indices.contains(i + 1) ? PluginPolicy.Level(rawValue: args[i + 1]) : nil } ?? .community
    let listing = PluginListing.check(checked, level: level)
    print(listing.lines.joined(separator: "\n"))
    if args.contains("--listing") { exit(listing.problems == 0 ? 0 : 1) }
    let report = PluginChecker.check(checked, read: args.contains("--read"))
    print(report.lines.joined(separator: "\n"))
    // Not yet ready for the library is not a failure for a private plugin (the brief tells an AI to fix every problem,
    // and it would invent a licence and privacy text): those count only with --listing.
    if listing.problems > 0 { print("(\(listing.problems) to fix before it can go in the library: only needed to share it there)") }
    exit(report.problems == 0 ? 0 : 1)

case "install":
    guard args.count >= 2 else { usage() }
    let plugin = loadPlugin(args[1])
    let warnings = PluginChecker.warnings(for: plugin)
    for w in warnings.lines { print(w) }
    // Not yet listable is fine on your own Mac; an essential key is not.
    let listing = PluginListing.check(plugin)
    if listing.problems > 0 { print("Not ready for the library yet (\(listing.problems) to fix: turnover-plugin check); installing for this Mac.") }
    if warnings.needsConfirmation, !args.contains("--confirm") { fail("This plugin acts in its app: it sends keys or chooses menu items (see above). Install with --confirm if that is what you want.") }
    do {
        let dest = try PluginChecker.install(plugin)
        let appName = plugin.manifest!.apps.compactMap { b in NSRunningApplication.runningApplications(withBundleIdentifier: b).first?.localizedName }.first ?? plugin.manifest!.apps.first ?? "the app"
        print("Installed \(plugin.manifest!.name) in \(dest.path). TurnOver applies it the next time \(appName) comes to the front.")
    } catch { fail("Could not install: \(error.localizedDescription)") }

case "list":
    for m in PluginListing.officialListings { print("Official: \(m.name), for \(m.apps.joined(separator: ", ")): \(m.summary ?? "")") }
    ProfileStore.shared.reload(force: true)
    let all = ProfileStore.shared.plugins
    if all.isEmpty { print("No plugins installed (\(ProfileStore.folder.path)).") }
    for p in all {
        if let m = p.manifest { print("\(m.name) \(m.version), for \(m.apps.joined(separator: ", ")): \(p.folder.lastPathComponent)") }
        else { print("\(p.folder.lastPathComponent): does not load: \(p.error ?? "?")") }
    }

case "listen":
    // TurnOver's own log, followed: each thing it says, as it says it; a new log (TurnOver restarted) is followed too.
    let logs = AppPaths.file("logs")
    func newest() -> URL? {
        ((try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "log" }
            .max { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
    }
    guard var file = newest() else { fail("No TurnOver log yet: is TurnOver running?") }
    var offset = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? UInt64) ?? 0
    print("Listening to TurnOver (Control C stops).")
    setvbuf(stdout, nil, _IOLBF, 0)
    while true {
        if let n = newest(), n != file { file = n; offset = 0; print("(TurnOver restarted)") }
        if let h = try? FileHandle(forReadingFrom: file) {
            try? h.seek(toOffset: offset)
            let data = h.readDataToEndOfFile(); try? h.close()
            offset += UInt64(data.count)
            for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
                if let r = line.range(of: #"IO say( \[[^\]]*\])?: "#, options: .regularExpression) { print("says: " + line[r.upperBound...]) }
                else if line.contains("] plugin ") { print(line.split(separator: "]", maxSplits: 1).last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "") }
                else if let r = line.range(of: #"IO input (kb:\S+)"#, options: .regularExpression) { print("key: " + line[r].dropFirst(9)) }
            }
        }
        Thread.sleep(forTimeInterval: 0.3)
    }

case "parts":
    let info = Bundle.main.infoDictionary ?? [:]
    print("TurnOver \(info["CFBundleShortVersionString"] ?? "?") build \(info["CFBundleVersion"] ?? "?")")
    for p in TurnOverParts.all { print("\(p.name): \(p.what)\(p.request.map { " (parts request #\($0))" } ?? "")") }

case "try":
    // TurnOver presses the keys (it has the Mac's permission; this tool doesn't) and writes back what it said.
    guard args.count >= 3 else { usage() }
    let app = runningApp(args[1])
    guard let bundle = app.bundleIdentifier else { fail("\(args[1]) has no bundle identifier, so TurnOver can't be asked to try keys there.") }
    var steps: [String] = []
    var i = 2
    while i < args.count {   // "wait 1.5" may come as two words
        if args[i] == "wait", i + 1 < args.count, Double(args[i + 1]) != nil { steps.append("wait \(args[i + 1])"); i += 2 } else { steps.append(args[i]); i += 1 }
    }
    let consents = PluginTry.currentConsents()
    if let why = PluginTry.refusal(bundle: bundle, steps: steps, consents: consents) { fail("Not tried: \(why).") }
    // Either copy: the published TurnOver, or TurnOver Developer beside it (issue 248).
    guard NSWorkspace.shared.runningApplications.contains(where: { [ActiveReader.published, ActiveReader.developer].contains($0.bundleIdentifier ?? "") }) else { fail("TurnOver isn't running.") }
    let id = UUID().uuidString
    let result = PluginTry.resultsFolder.appendingPathComponent("\(id).json")
    // Through TurnOver's control channel, which takes only programs signed by TurnOver's developer.
    guard ControlClient.send(["op": "try", "id": id, "bundle": bundle, "keys": steps.joined(separator: "\n")]).sent else { fail("TurnOver isn't listening.") }
    let waits = steps.compactMap { $0.hasPrefix("wait") ? Double($0.dropFirst(4).trimmingCharacters(in: .whitespaces)) : nil }.reduce(0, +)
    let deadline = Date().addingTimeInterval(8 + Double(steps.count) * 0.8 + waits)
    while Date() < deadline, !FileManager.default.fileExists(atPath: result.path) { Thread.sleep(forTimeInterval: 0.2) }
    guard let data = try? Data(contentsOf: result), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        fail("TurnOver didn't answer. Is this TurnOver build 19 or newer?")
    }
    try? FileManager.default.removeItem(at: result)
    let said = o["said"] as? [String] ?? []
    if said.isEmpty { print("TurnOver said nothing.") }
    for line in said { print("says: \(line)") }
    if let e = o["error"] as? String { fail("Not finished: \(e).") }

case "explain":
    guard args.count >= 2 else { usage() }
    let id = args[1].hasPrefix("kb:") ? args[1] : "kb:" + args[1]
    guard let g = KeyboardGesture(identifier: id) else { fail("\(args[1]) is not a key TurnOver knows. Write it as turnover+shift+p, control+option+1, f6.") }
    do { try Core.start() } catch { fail("TurnOver's core did not start: \(error)") }
    BuiltInModules.register()
    Speech.mode = .off
    if let i = args.firstIndex(of: "--style"), args.indices.contains(i + 1) { config.general.keyboardStyle = args[i + 1] }
    let rest = args.dropFirst(2).filter { !$0.hasPrefix("--") && $0 != "windows" && $0 != "mac" }
    let pid = rest.first.map { runningApp($0).processIdentifier }
    for l in KeyExplainer.explain(g, pid: pid) { print(l) }

case "record":
    // Each new window, sheet, tab or pane of the app, while the user moves through it (Control C stops).
    guard args.count >= 3 else { usage() }
    let app = runningApp(args[1])
    let dir = URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath, isDirectory: true).appendingPathComponent("tests")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let mask = !args.contains("--no-mask")
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(ax, 2)
    var seen = Set<String>()
    var n = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("screen-") }.count
    print("Recording \(app.localizedName ?? "") into \(dir.path)\(mask ? " (text masked; --no-mask keeps it)" : ""). Move through the app; Control C stops.")
    setvbuf(stdout, nil, _IOLBF, 0)
    // A screen is told apart by its window's kind and size, any sheet, the selected tab, and the roles at its top.
    func fingerprint(_ w: AXUIElement) -> String {
        var parts = [w.role, w.string(kAXSubroleAttribute) ?? "", w.string(kAXIdentifierAttribute) ?? ""]
        for k in w.elements(kAXChildrenAttribute).prefix(40) {
            parts.append(k.role + (k.string(kAXIdentifierAttribute) ?? ""))
            if k.role == "AXSheet" { parts.append("sheet") }
            if k.role == "AXTabGroup" || k.role == "AXToolbar" {
                for t in k.elements(kAXChildrenAttribute) where (t.attr(kAXValueAttribute) as? NSNumber)?.intValue == 1 { parts.append("tab:" + (t.string(kAXTitleAttribute) ?? t.string(kAXDescriptionAttribute) ?? "")) }
            }
        }
        return parts.joined(separator: "|")
    }
    while true {
        if let w = ax.element(kAXFocusedWindowAttribute) {
            let f = fingerprint(w)
            if !seen.contains(f) {
                seen.insert(f); n += 1
                let fixture = AXRecorder.record(root: w, app: app, limit: 4000)
                let file = dir.appendingPathComponent("screen-\(n).json")
                do {
                    try (mask ? AXRecorder.masked(fixture) : fixture).save(to: file)
                    print("screen \(n): \(Role.from(axRole: w.role, subrole: w.string(kAXSubroleAttribute)).displayString), \(fixture.nodes.count) elements")
                } catch { print("could not save screen \(n): \(error.localizedDescription)") }
            }
        }
        Thread.sleep(forTimeInterval: 0.7)
    }

case "test":
    guard args.count >= 2 else { usage() }
    guard AXReplay.isAvailable else { fail("The tests need TurnOver's replay library (libAXReplayShim.dylib) beside this tool; run the tool from a TurnOver developer build.") }
    Speech.mode = .off
    let r = PluginTestRunner.run(folder: URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath, isDirectory: true))
    for l in r.lines { print(l) }
    print("\(r.passed) passed, \(r.failed) failed")
    exit(r.failed == 0 ? 0 : 1)

default:
    usage()
}
