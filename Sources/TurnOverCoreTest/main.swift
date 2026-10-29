// SPDX-License-Identifier: GPL-3.0-or-later
// turnover-coretest — exercises TurnOverCore's text layer, object properties and
// script resolution against a running application, without speaking and
// without touching the keyboard. Read-only except where --move is given.
//
//   turnover-coretest [--bundle com.microsoft.Word] [--move]
import Foundation
import AppKit
import ApplicationServices
import TurnOverCore
import TurnOverSpeech
import AXFixtures

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
func opt(_ name: String) -> String? { args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
let bundle = opt("--bundle") ?? "com.microsoft.Word"
let allowMoves = args.contains("--move")

Log.level = .debug
do { try Core.start() } catch { print("core failed: \(error)"); exit(1) }
BuiltInModules.register()   // the same app modules as TurnOver (they live in TurnOverCore since 8 Oct 2026)
Speech.mode = .off
Speech.sink = { print("   SPEECH: \($0)") }

if args.contains("--record") {
    // A window's accessibility tree to a JSON fixture for turnover-tests: --record <bundle id> <out.json> [--limit N]
    // [--focus]: the focused window (else the main one), or with --focus the focused element's window.
    let i = args.firstIndex(of: "--record")!
    guard args.indices.contains(i + 2) else { print("usage: --record <bundle id> <out.json> [--limit N]"); exit(2) }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: args[i + 1]).first else { print("not running"); exit(1) }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    guard let window = ax.element(kAXFocusedWindowAttribute) ?? ax.element(kAXMainWindowAttribute) ?? ax.elements(kAXWindowsAttribute).first else { print("no window"); exit(1) }
    let limit = opt("--limit").flatMap(Int.init) ?? 4000
    let t = timed { AXRecorder.record(root: window, app: app, limit: limit) }
    // --mask: the user's content masked (AXRecorder.masked), for apps holding it.
    let fixture = args.contains("--mask") ? AXRecorder.masked(t.value) : t.value
    do { try fixture.save(to: URL(fileURLWithPath: args[i + 2])) } catch { print("could not save: \(error)"); exit(1) }
    // Masked: the window's title is the user's too (a Ulysses sheet's first line, 10 Oct 2026), so it is not printed.
    let shownTitle = args.contains("--mask") ? "title masked" : (window.string(kAXTitleAttribute) ?? "untitled")
    print("recorded \(t.value.nodes.count) elements of \(app.localizedName ?? "") (\(shownTitle)) in \(Int(t.ms)) ms")
    exit(0)
}
if args.contains("--redact") {
    let i = args.firstIndex(of: "--redact")!
    let text = (try? String(contentsOfFile: args[i + 1], encoding: .utf8)) ?? ""
    print(Feedback.redact(text))
    exit(0)
}
if args.contains("--appstore") {
    // The App Store's page as TurnOver reads it (no keys, no clicks).
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.AppStore").first else { print("not running"); exit(1) }
    let v = AppStoreView(pid: app.processIdentifier)
    v.buildPage()
    if args.contains("--all") { v.toEnd(true) }
    print("page: \(v.pageTitle), shelves: \(v.shelves.count) \(v.shelves)")
    var shelf = -1
    for e in v.page {
        if e.shelf != shelf { shelf = e.shelf; print("== \(v.shelves[shelf])") }
        print("   [\(e.kind)] \(e.label.prefix(150))")
    }
    exit(0)
}
if args.contains("--media") {
    // A media app's page as TurnOver reads it; with --all, scrolled to the end as End does (no keys, no clicks).
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: opt("--media") ?? "").first else { print("not running"); exit(1) }
    let v = MediaView(pid: app.processIdentifier)
    var done = false
    v.refresh { if args.contains("--all") { v.toEnd(true); v.onEnd = { done = true } } else { done = true } }
    let until = Date().addingTimeInterval(args.contains("--all") ? 90 : 5)
    while !done, Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
    print("page: \(v.pageTitle), \(v.shelves.count) shelves")
    for s in v.shelves { print("== \(s.title) (\(s.items.count))"); for it in s.items.prefix(args.contains("--full") ? 99 : 3) { print("   \(it.play != nil ? "[play] " : "")\(it.label.prefix(100))") } }
    exit(0)
}
if args.contains("--sidebar") {
    // Finder's sidebar: the cursor onto it, into it, and whether the keyboard followed (clicks the selected row).
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { exit(1) }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    guard let w = ax.element(kAXFocusedWindowAttribute) else { print("no window"); exit(1) }
    func find(_ e: AXUIElement, _ d: Int) -> AXUIElement? {
        if e.role == "AXOutline", e.string(kAXDescriptionAttribute) == "sidebar" { return e }
        guard d < 10 else { return nil }
        for c in e.elements(kAXChildrenAttribute) { if let f = find(c, d + 1) { return f } }
        return nil
    }
    guard let sb = find(w, 0) else { print("no sidebar"); exit(1) }
    ObjectNavigator.shared.focusMoved(to: sb, pid: app.processIdentifier)
    ObjectNavigator.shared.interact()
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    print("holding:", ObjectNavigator.shared.isHolding)
    ObjectNavigator.shared.heldMove(1); ObjectNavigator.shared.heldMove(1); ObjectNavigator.shared.heldEdge(last: true); ObjectNavigator.shared.heldDisclose(open: false)
    exit(0)
}
if args.contains("--brailletables") {
    let t = Date()
    let langs = TOBrailleTranslatorTables.otherLanguages()
    print("\(langs.count) languages in \(String(format: "%.2f", Date().timeIntervalSince(t))) s")
    for l in langs where ["Slovenian", "Italian", "Spanish", "Arabic"].contains(l.language) { print(l.language, l.tables.map(\.name)) }
    exit(0)
}
if args.contains("--chat") {
    // A chat app's parts as TurnOver finds them: counts only, as the words are private.
    let bundle = opt("--chat") ?? ""
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { print("not running"); exit(1) }
    let specs: [String: ChatView.Spec] = [
        "com.apple.MobileSMS": ChatView.Spec(conversationsID: "ConversationList", transcriptID: "TranscriptCollectionView", composerID: "messageBodyField", titleID: "ConversationTitle", isMessage: { _ in true }, isConversation: { $0.role == "AXStaticText" }),
        "net.whatsapp.WhatsApp": ChatView.Spec(conversationsID: "ChatListView_TableView", transcriptID: "ChatMessagesTableView", composerID: "ChatBar_ComposerTextView", titleID: "NavigationBar_HeaderViewButton", isMessage: { ["AXStaticText", "AXHeading"].contains($0.role) }, isConversation: { $0.role == "AXButton" && ($0.string(kAXIdentifierAttribute) ?? "").isEmpty }),
    ]
    print(ChatView(pid: app.processIdentifier, spec: specs[bundle]!).debugCounts())
    exit(0)
}
if args.contains("--config") {
    print("blockQuotes", config.documentFormatting.blockQuotes, "coords", config.documentFormatting.tableCellCoordinates, "style", config.general.keyboardStyle, "leads", config.applications.leadBundles.count)
    exit(0)
}
if args.contains("--sentences") {
    for l in NewToTry.sentences(opt("--sentences") ?? "") { print("- \(l)") }
    exit(0)
}
if args.contains("--groups") {
    // What the VoiceOver keys step through in an app's front window, two levels deep.
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: opt("--groups") ?? "").first else { print("not running"); exit(1) }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    guard let w = ax.element(kAXFocusedWindowAttribute) ?? ax.elements(kAXWindowsAttribute).first else { print("no window"); exit(1) }
    func show(_ e: AXUIElement, _ depth: Int) {
        for it in ObjectNavigator.groupItems(e).prefix(30) {
            let o = ObjectFactory.make(it)
            let g = ObjectNavigator.isGroup(it)
            let f = TurnOverObject.debugFrame(it)
            print(String(repeating: "    ", count: depth) + "\(g ? "[group] " : "")\(Speech.objectPropertiesSpeech(o, reason: .query).joined(separator: ", ").prefix(70))  \(f)")
            if g, depth < 1, !["AXTable", "AXOutline", "AXWebArea", "AXList"].contains(it.role) { show(it, depth + 1) }
        }
    }
    show(w, 0)
    exit(0)
}
if args.contains("--chooser") {
    for e in ApplicationChooser.gather() { print("\(e.name): \(e.windows.count) windows") }
    exit(0)
}
if args.contains("--layout") {
    // Reading order for saved recognition lines (JSON: frame, lines of t, r, w). --mask hides the words.
    let d = try! Data(contentsOf: URL(fileURLWithPath: opt("--layout")!))
    let j = try! JSONSerialization.jsonObject(with: d) as! [String: Any]
    func rect(_ a: Any?) -> CGRect { let v = (a as! [Double]); return CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) }
    let lines: [ScreenRecognition.Line] = (j["lines"] as! [[String: Any]]).map { l in
        (l["t"] as! String, rect(l["r"]), (l["w"] as! [[String: Any]]).map { ($0["t"] as! String, rect($0["r"])) })
    }
    let r = ScreenRecognition.layout(lines, title: "", pid: 0, window: rect(j["frame"]))
    let mask = args.contains("--mask")
    for row in r.rows {
        var t = r.text.substring(with: row.range)
        if mask { t = row.items.map { r.text.substring(with: $0.range).split(separator: " ").first.map { String($0.prefix(3)) + "…(\($0.count))" } ?? "" }.joined(separator: " | ") }
        print("b\(row.block)  \(t)")
    }
    exit(0)
}
if args.contains("--ocr") {
    // Screen recognition of an app's window, printed by row (no keys, no clicks).
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: opt("--ocr") ?? "").first else { print("not running"); exit(1) }
    print("screen recording allowed: \(CGPreflightScreenCaptureAccess())")
    guard let t = ScreenRecognition.target(pid: app.processIdentifier) else { print("no window"); exit(1) }
    print("window \(t.title) \(t.frame)")
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        let start = Date()
        switch await ScreenRecognition.run(t) {
        case .failure(let m): print("failed: \(m)")
        case .success(let r):
            print("\(r.rows.count) rows in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
            for row in r.rows.prefix(80) {
                let words = row.items.flatMap { $0.words }.prefix(3).map { "\(r.text.substring(with: $0.range))@\(Int($0.rect.midX)),\(Int($0.rect.midY))" }
                print("  \(r.text.substring(with: row.range))   [\(words.joined(separator: " "))]")
            }
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
}
if args.contains("--apprequest") {
    // What "Request support for" would send, for a running app (no email opened).
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: opt("--apprequest") ?? "").first else { print("not running"); exit(1) }
    print(AppRequest.describeForTest(app))
    exit(0)
}
if args.contains("--queue") {
    // Two utterances queued together (a typed word, then its punctuation): both must play.
    config = Config.load()
    let player = try! SpeechPlayer(voice: config.speech.voice, rate: config.speech.rate)
    player.speak("there", interrupt: false, completion: { (done: Bool) in print("there: \(done ? "played" : "dropped")") })
    player.speak("comma", interrupt: false, completion: { (done: Bool) in print("comma: \(done ? "played" : "dropped")") })
    RunLoop.main.run(until: Date().addingTimeInterval(3))
    exit(0)
}
if args.contains("--sheet") {
    let i = args.firstIndex(of: "--sheet")!
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: args[i + 1]).first else { print("not running"); exit(1) }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    var sheet: AXUIElement?
    for w in ax.elements(kAXWindowsAttribute) { if let s = w.elements(kAXChildrenAttribute).first(where: { $0.role == "AXSheet" }) { sheet = s; break }; if w.string(kAXSubroleAttribute) == "AXDialog" { sheet = w; break } }
    guard let sheet else { print("no sheet or dialog open"); exit(0) }
    let d = ObjectFactory.make(sheet)
    print("class \(type(of: d))")
    if let dlg = d as? Dialog {
        print("text: \(dlg.dialogText)")
        print("choices: \(dlg.choices.map { "\($0.1) [\($0.0.role)]" })")
        dlg.event_gainFocus()
    }
    exit(0)
}
if args.contains("--media") {
    let i = args.firstIndex(of: "--media")!
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: args[i + 1]).first else { print("not running"); exit(1) }
    let v = MediaView(pid: app.processIdentifier)
    let t0 = Date()
    v.rebuild(force: true)
    print("built in \(Int(Date().timeIntervalSince(t0) * 1000)) ms; page \(v.pageTitle)")
    print("SIDEBAR: " + v.sidebar.map { $0.label + ($0.isHeader ? " [heading]" : "") + ($0.selected ? " [selected]" : "") + ($0.press == nil ? " [no press]" : "") }.joined(separator: " | "))
    for s in v.shelves.prefix(12) { print("SHELF \(s.title) (\(s.items.count)): " + s.items.prefix(4).map { $0.label.prefix(70) + ($0.play != nil ? " [play]" : "") }.joined(separator: " | ")) }
    print("PLAYER: " + v.player.map(\.label).joined(separator: " | "))
    if args.contains("--more") {
        v.pane = .page
        for _ in 0..<6 { v.jumpShelf(1) }
        RunLoop.main.run(until: Date().addingTimeInterval(4))
        for _ in 0..<3 { v.jumpShelf(1) }
        RunLoop.main.run(until: Date().addingTimeInterval(4))
    }
    if args.contains("--walk") {
        let t1 = Date()
        v.pane = .page
        for _ in 0..<4 { v.move(1) }
        v.letter("m")
        v.toEnd(true)
        print("moves in \(Int(Date().timeIntervalSince(t1) * 1000)) ms")
    }
    exit(0)
}
if args.contains("--shortcuts") {
    try? Core.start()
    GlobalCommands.openShortcutsList()
    print(TurnOverMenu.shared.debugOutline())
    exit(0)
}
if args.contains("--answer") {
    // An AI's answer as chat apps format it: prose, then two fenced blocks.
    let answer = """
    This plugin names the toolbar buttons and adds Caps+Shift+L to read the library count.

    ```json
    {"id": "libation-profile", "name": "Libation", "version": "0.1", "apps": ["com.libation.app"], "kind": "profile"}
    ```

    ```json
    {"labels": [{"match": {"role": "button", "unnamed": true, "help": "*"}, "nameFrom": "help"}],
     "keys": [{"key": "turnover+shift+l", "description": "Read the count", "action": "read", "target": {"role": "static text", "text": "*books*"}}]}
    ```
    """
    let objs = PluginAI.jsonObjects(in: answer)
    print("found \(objs.count) objects: \(objs.map { $0.keys.sorted().joined(separator: ",") })")
    let bare = PluginAI.jsonObjects(in: "Here you go: {\"labels\": [], \"keys\": []} hope that helps")
    print("bare: \(bare.count)")
    if let i = args.firstIndex(of: "--brief-for"), let app = NSRunningApplication.runningApplications(withBundleIdentifier: args[i + 1]).first,
       let folder = try? PluginBrief.write(pid: app.processIdentifier) {
        let t = PluginBrief.chatBrief(folder: folder, pid: app.processIdentifier)
        print("chat brief for \(app.localizedName ?? ""): \(t.count) characters, \(t.split(separator: "\n").count) lines")
        try? FileManager.default.removeItem(at: folder)
    }
    exit(0)
}
if args.contains("--maker-test") {
    // The plugin maker on a running app: turnover-coretest --maker-test <bundle> (11 Oct 2026).
    let i = args.firstIndex(of: "--maker-test")!
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: args[i + 1]).first else { print("not running"); exit(1) }
    UserDefaults.standard.set(true, forKey: "plugins")
    for l in PluginMaker.selfTest(pid: app.processIdentifier) { print(l) }
    exit(0)
}
if args.contains("--review") {
    // Object navigation from an app's front window, silently: --review <bundle> [steps]
    let i = args.firstIndex(of: "--review")!
    let bundle = args[i + 1]
    let steps = args.count > i + 2 ? Int(args[i + 2]) ?? 30 : 30
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { print("not running"); exit(1) }
    ProfileStore.shared.reload(force: true)
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    guard let win = ax.element(kAXFocusedWindowAttribute) ?? ax.elements(kAXWindowsAttribute).first else { print("no window"); exit(1) }
    ObjectNavigator.shared.focusMoved(to: win, pid: app.processIdentifier)
    let t0 = Date()
    for _ in 0..<steps { ObjectNavigator.shared.next() }
    print("\(steps) steps in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
    print("== back 3"); for _ in 0..<3 { ObjectNavigator.shared.previous() }
    print("== out, in"); ObjectNavigator.shared.parent(); ObjectNavigator.shared.firstChild()
    print(ObjectNavigator.shared.debugCurrent().prefix(400))
    exit(0)
}
if args.contains("--explain") {
    // Which script a key would reach, and who else answered it, for the focus in the frontmost application:
    //   turnover-coretest --explain kb:turnover+m [--bundle com.apple.mail] [--style windows|mac]
    // (The team review, 8 Oct 2026: the precedence of plugins, app module, document, focus, ancestors and the
    // global commands is implicit; this makes it visible in seconds.)
    let i = args.firstIndex(of: "--explain")!
    guard args.indices.contains(i + 1), let g = KeyboardGesture(identifier: args[i + 1]) else { print("usage: --explain kb:turnover+m"); exit(2) }
    if let style = opt("--style") { config.general.keyboardStyle = style }
    let pid = NSRunningApplication.runningApplications(withBundleIdentifier: opt("--bundle") ?? "").first?.processIdentifier
    for l in KeyExplainer.explain(g, pid: pid) { print(l) }
    exit(0)
}
if let dir = opt("--keys-reference") {
    // The key reference for the guides (Guides/09 to 11), one page per keyboard style, from the code itself: every
    // bound key in the global commands, the global plugins and the style's own table, resolved as a key press would be
    // (no focus: no app, no browse mode), then each built-in app module's keys that nothing global takes first.
    config.keyboard.userGestures = [:]   // this Mac's own keys never go into the guide
    config.keyboard.layout = "laptop"
    func cap(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
    func display(_ id: String) -> String {
        guard let g = KeyboardGesture(identifier: id) else { return id }
        var parts: [String] = []
        if g.modifiers.contains(.turnover) { parts.append("TurnOver") }
        if g.modifiers.contains(.control) { parts.append("Control") }
        if g.modifiers.contains(.option) { parts.append("Option") }
        if g.modifiers.contains(.command) { parts.append("Command") }
        if g.modifiers.contains(.shift) { parts.append("Shift") }
        parts.append(cap(KeyNames.spoken(for: g.keyCode, characters: g.characters)))
        return parts.joined(separator: " ")
    }
    func cell(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
    func plain(_ id: String) -> String? {   // the identifier a key press makes: the laptop layout's, never the desktop's
        if id.hasPrefix("kb(laptop):") { return "kb:" + id.dropFirst("kb(laptop):".count) }
        if id.hasPrefix("kb(") { return nil }
        return id
    }
    let order = ["JAWS keys", "Narrator keys", "TurnOver", "Text", "Reading", "Navigation", "VoiceOver keys", "NVDA keys", "Review", "Mouse", "Tables", "Speech", "Braille", "Settings", "Windows", "System", "Plugins", "Add-ons"]
    func rank(_ c: String) -> Int { order.firstIndex(of: c) ?? order.count }
    let pages: [(KeyboardStyle, String, String)] = [
        (.voiceOver, "09-keys-voiceover.md", "VoiceOver keys: every key"),
        (.nvda, "10-keys-nvda.md", "NVDA keys: every key"),
        (.jaws, "11-keys-jaws.md", "JAWS keys: every key"),
    ]
    let intro: [KeyboardStyle: String] = [
        .voiceOver: "The VoiceOver keys style (the Mac style): VoiceOver's own keys, doing what they do in VoiceOver. **TurnOver** in a key means the TurnOver key: Control and Option together (VO), or Caps Lock. Keys VoiceOver has that aren't listed here go to VoiceOver as usual where VoiceOver reads, and do nothing special where TurnOver reads.",
        .nvda: "The NVDA keys style (the Windows style): NVDA's own keys, doing what they do in NVDA. **TurnOver** in a key means the NVDA key: Caps Lock, or Control and Option together. NVDA's Alt is the Mac's Command key, by position.",
        .jaws: "The JAWS keys style: JAWS's laptop layout. **TurnOver** in a key means the JAWS key: Caps Lock, or Control and Option together. Only the keys that differ from NVDA's are JAWS's own; every other key is NVDA's, so the [NVDA keys page](keys-nvda.html) lists the rest.",
    ]
    let df = DateFormatter(); df.dateFormat = "d MMM yyyy"; df.locale = Locale(identifier: "en_GB")
    let modules = AppModuleHandler.shared.registeredBundleIdentifiers.sorted().compactMap { b -> AppModule? in
        guard let t = AppModuleHandler.shared.moduleType(for: b) else { return nil }
        let name = (NSWorkspace.shared.urlForApplication(withBundleIdentifier: b).flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleName") as? String }) ?? b.split(separator: ".").last.map(String.init) ?? b
        return t.init(pid: 0, bundleIdentifier: b, appName: cap(name))
    }
    for (style, file, title) in pages {
        config.general.keyboardStyle = style.rawValue
        KeySettings.refresh()
        var ids = Set<String>()
        for (id, _) in GlobalCommands.shared.allBindings { if let p = plain(id) { ids.insert(p) } }
        for p in GlobalPluginHandler.shared.plugins { for (id, _) in p.allBindings { if let q = plain(id) { ids.insert(q) } } }
        for (id, _) in StyleKeymap.keys(for: style) { ids.insert(id) }
        var sections: [String: [(String, String)]] = [:]
        let own = StyleKeymap.keys(for: style)
        for id in ids {
            guard let g = KeyboardGesture(identifier: id), let s = ScriptHandler.findScript(for: g) else { continue }
            // A key from the style's own table is listed under the style's name, whatever command it reaches.
            let category = own[normalizeGestureIdentifier(id)] != nil ? style.spokenName : s.category == ScriptableObject.defaultCategory ? "TurnOver" : s.category
            sections[category, default: []].append((display(id), s.description))
        }
        var md = "# \(title)\n\n"
        md += "This page is made from TurnOver's own command tables (`turnover-coretest --keys-reference`, \(df.string(from: Date()))), so it matches the build it came with. Don't edit it by hand.\n\n"
        md += intro[style]! + " Keyboard help (the TurnOver menu, Keys) says what any key does without doing it; Command Control Comma, then Slash, lists the keys that work where you are.\n\n"
        md += "Switch styles with Command Control Comma, then K. TurnOver's own commands behind Command Control Comma are the same in every style: see [The TurnOver layer](the-turnover-layer.html).\n"
        for category in sections.keys.sorted(by: { (rank($0), $0) < (rank($1), $1) }) {
            md += "\n## \(category)\n\n| Key | What it does |\n|---|---|\n"
            for (k, d) in sections[category]!.sorted(by: { ($0.0.count(where: { $0 == " " }), $0.0) < ($1.0.count(where: { $0 == " " }), $1.0) }) { md += "| \(cell(k)) | \(cell(d)) |\n" }
        }
        let sayAll = StyleKeymap.sayAllKeys(for: style)
        if !sayAll.isEmpty {
            md += "\n## During say all\n\nThese keys apply only while say all is reading.\n\n| Key | What it does |\n|---|---|\n"
            for (id, name) in sayAll.sorted(by: { $0.key < $1.key }) {
                if let s = ScriptHandler.findScript(named: name) { md += "| \(cell(display(id))) | \(cell(s.description)) |\n" }
            }
        }
        var appRows: [(String, [(String, String)])] = []
        for m in modules {
            var rows: [(String, String)] = []
            // Documentation has no live focus (pid 0). Availability-filtered help omitted every guarded
            // Settings command, so list declared bindings in their registered precedence instead (29 Oct 2026).
            let declared = m.everyBinding.compactMap { id, scripts in scripts.first.map { (id, $0) } }
            for (id, s) in declared {
                guard let p = plain(id), let g = KeyboardGesture(identifier: p) else { continue }
                // Only a key nothing global takes first: in the Mac style a VoiceOver key beats an app's own.
                if StyleKeymap.script(for: g) != nil || GlobalPluginHandler.shared.plugins.contains(where: { $0.script(for: g) != nil }) { continue }
                rows.append((display(p), s.description))
            }
            print("  \(m.appName): \(declared.count) keys bound, \(rows.count) listed")
            if !rows.isEmpty { appRows.append((m.appName, rows.sorted { $0.0 < $1.0 })) }
        }
        if !appRows.isEmpty {
            md += "\n# In the apps\n\nKeys an app's own support adds at the app level, in that app only; the keys above work there too. Some commands apply only in the relevant control or window. Keys that belong to a document inside an app (Word's headings, comments and tables, a web page's quick keys) are in [The apps](the-apps.html) and [Reading and say all](reading-and-say-all.html).\n"
            for (app, rows) in appRows.sorted(by: { $0.0 < $1.0 }) {
                md += "\n## \(app)\n\n| Key | What it does |\n|---|---|\n"
                for (k, d) in rows { md += "| \(cell(k)) | \(cell(d)) |\n" }
            }
        }
        try! md.write(toFile: dir + "/" + file, atomically: true, encoding: .utf8)
        print("\(file): \(sections.values.reduce(0) { $0 + $1.count }) keys, \(appRows.count) apps")
    }
    exit(0)
}
if args.contains("--keys") {
    // Which script each key reaches, in each keyboard style (no focus: global plugins and commands only).
    try? Core.start()
    let ids = ["kb:turnover+m", "kb:turnover+d", "kb:turnover+shift+m", "kb:turnover+p", "kb:turnover+s", "kb:turnover+t", "kb:turnover+z",
               "kb:turnover+f7", "kb:turnover+u", "kb:turnover+q", "kb:turnover+space", "kb:turnover+tab", "kb:turnover+command+h", "kb:turnover+n",
               "kb:option+b", "kb:command+f4", "kb:f10", "kb:shift+f10"]
    for style in ["windows", "mac"] {
        config.general.keyboardStyle = style
        print("== \(style)")
        for id in ids {
            guard let g = KeyboardGesture(identifier: id) else { print("  \(id): bad identifier"); continue }
            print("  \(g.displayName.padding(toLength: 26, withPad: " ", startingAt: 0)) → \(ScriptHandler.findScript(for: g)?.name ?? "(passes to the app)")")
        }
    }
    exit(0)
}
if args.contains("--claude") {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: ClaudeTranscript.bundleID).first,
          let chat = ClaudeTranscript.chat(pid: app.processIdentifier) else { print("no Claude transcript"); exit(1) }
    print("status: \(ClaudeTranscript.status(chat: chat).debugDescription), responding \(ClaudeTranscript.isResponding(chat: chat))")
    let t0 = Date()
    let reply = ClaudeTranscript.latestReply(chat: chat)
    print("latest reply in \(Int(Date().timeIntervalSince(t0) * 1000)) ms, \(reply.count) characters:\n\(reply)")
    exit(0)
}
if args.contains("--status") {
    let t0 = Date()
    let n = StatusMenus.names()
    print("status menus in \(Int(Date().timeIntervalSince(t0) * 1000)) ms: \(n)")
    exit(0)
}
if args.contains("--gestures") {
    // The shortcuts list runs a script from its binding identifier: round-trip a few.
    for id in ["kb:turnover+/", "kb:turnover+shift+upArrow", "kb:turnover+control+downArrow", "kb:turnover+f7", "kb:NVDA+Alt+C", "kb:turnover++"] {
        if let g = KeyboardGesture(identifier: id) { print("\(id) → \(g.identifier)  spoken: \(g.displayName)") } else { print("\(id) → FAILED") }
    }
    exit(0)
}
if args.contains("--menu-outline") {
    // The TurnOver menu as an outline, read only: every title, its value, submenus to three levels (11 Oct 2026).
    UserDefaults.standard.set(true, forKey: "plugins")
    TurnOverMenu.shared.open()
    print(TurnOverMenu.shared.debugOutline(depth: 3, values: true))
    exit(0)
}
if args.contains("--menu") {
    // Walk the TurnOver menu silently: every item of every submenu, cycling values forward and back so settings end unchanged.
    let saved = config
    func key(_ name: String, _ ch: String = "") { TurnOverMenu.shared.handle(KeyboardGesture(keyCode: KeyNames.code(for: name) ?? 0, modifiers: [], characters: ch, timestamp: 0, isRepeat: false, flags: [])) }
    TurnOverMenu.shared.open()
    key("rightArrow")                       // Preferences
    for section in 0..<5 {
        key("rightArrow")                   // open section
        for _ in 0..<14 { key("rightArrow"); key("leftArrow"); key("downArrow") }   // change and restore each item, move on
        key("escape")                       // back to Preferences
        key("downArrow")
        _ = section
    }
    key("escape"); key("escape")
    config = saved; config.save()
    print("menu walk done, settings restored"); exit(0)
}
if args.contains("--music") {
    // Music's content pane as a document: lines and quick navigation by role, silently.
    guard let music = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first else { print("Music not running"); exit(1) }
    let mEl = AXUIElementCreateApplication(music.processIdentifier)
    guard let win = mEl.element(kAXFocusedWindowAttribute), let split = win.elements(kAXChildrenAttribute).first(where: { $0.role == "AXSplitGroup" }) else { print("no window"); exit(1) }
    var root: AXUIElement?
    for host in split.elements(kAXChildrenAttribute) where host.role == "AXGroup" { if let sc = host.elements(kAXChildrenAttribute).first(where: { $0.role == "AXScrollArea" }) { root = sc; break } }
    guard let root else { print("no content pane"); exit(1) }
    let doc = BrowseModeHandler.shared.document(root: root)
    let obj = WebArea(element: root)
    API.setFocusObject(obj, ancestors: [], interceptor: doc)
    print("content: \(root.string(kAXDescriptionAttribute) ?? "") — \(doc.buffer.lines.count) lines, WebKit search: \(doc.hasWebKitSearch)")
    for (i, l) in doc.buffer.lines.prefix(12).enumerated() { print("  \(i): \(doc.buffer.text.substring(with: NSRange(location: l.start, length: l.end - l.start)).prefix(90))") }
    func press(_ name: String, _ mods: Modifiers = []) {
        let g = KeyboardGesture(keyCode: KeyNames.code(for: name) ?? 0, modifiers: mods, characters: name.count == 1 ? name : "", timestamp: 0, isRepeat: false, flags: [])
        guard let s = ScriptHandler.findScript(for: g) else { print("\(g.identifier): no script"); return }
        s.handler(g); print("\(g.identifier) → \(s.name), position \(doc.position)")
    }
    doc.position = 0
    press("downArrow"); press("downArrow"); press("h"); press("h"); press("b"); press("b"); press("h", .shift); press("downArrow")
    print("done"); exit(0)
}
if let i = args.firstIndex(of: "--names"), i + 1 < args.count {
    // The names TurnOver gives an app's controls (pop-ups, switches, sliders), with their roles: names only.
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: args[i + 1]).first else { print("not running"); exit(1) }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    guard let win = ax.element(kAXFocusedWindowAttribute) ?? ax.elements(kAXWindowsAttribute).first else { print("no window"); exit(1) }
    func walk(_ e: AXUIElement, _ d: Int) {
        if ["AXCheckBox", "AXPopUpButton", "AXSlider", "AXButton"].contains(e.role) {
            let o = ObjectFactory.make(e)
            print("\(e.role)/\(e.string(kAXSubroleAttribute) ?? "") \(type(of: o)): name '\(o.name)' titleUI '\(e.element(kAXTitleUIElementAttribute)?.string(kAXValueAttribute) ?? "-")'")
        }
        if d < 14 { for c in e.elements(kAXChildrenAttribute) { walk(c, d + 1) } }
    }
    walk(win, 0)
    if let f = ax.element(kAXFocusedUIElementAttribute) {
        let o = ObjectFactory.make(f)
        print("FOCUSED \(f.role)/\(f.string(kAXSubroleAttribute) ?? "") \(type(of: o)): name '\(o.name)' titleUI '\(f.element(kAXTitleUIElementAttribute)?.string(kAXValueAttribute) ?? "-")' parent \(f.element(kAXParentAttribute)?.role ?? "-") title '\(f.string(kAXTitleAttribute) ?? "-")' desc '\(f.string(kAXDescriptionAttribute) ?? "-")'")
    }
    exit(0)
}
if args.contains("--preview") {
    // Preview's open document (its pages' container) as a browse-mode document, silently. The document's words are
    // never printed: each line is shown as its role, its length and its first three characters (Preview, 17 Oct 2026).
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Preview").first else { print("Preview not running"); exit(1) }
    let pEl = AXUIElementCreateApplication(app.processIdentifier)
    func findContainer(_ e: AXUIElement, _ d: Int) -> AXUIElement? {
        if e.string(kAXSubroleAttribute) == "AXSharedDocumentContainer" { return e }
        if d > 8 { return nil }
        for c in e.elements(kAXChildrenAttribute) { if let f = findContainer(c, d + 1) { return f } }
        return nil
    }
    let wanted = ProcessInfo.processInfo.environment["PREVIEW_WINDOW"]
    guard let win = (wanted.flatMap { w in pEl.elements(kAXWindowsAttribute).first { ($0.string(kAXTitleAttribute) ?? "").contains(w) } }) ?? pEl.element(kAXFocusedWindowAttribute) ?? pEl.elements(kAXWindowsAttribute).first,
          let root = findContainer(win, 0) else { print("no document container"); exit(1) }
    let t0 = Date()
    let doc = BrowseModeHandler.shared.document(root: root)
    let obj = WebArea(element: root)
    API.setFocusObject(obj, ancestors: [], interceptor: doc)
    print("pages: \(root.elements(kAXChildrenAttribute).filter { $0.role == "AXPage" }.count); \(doc.buffer.lines.count) lines, \(doc.buffer.text.length) characters, built in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
    func mask(_ s: String) -> String { s.count <= 3 ? s : String(s.prefix(3)) + "…(\(s.count))" }
    for (i, l) in doc.buffer.lines.prefix(40).enumerated() {
        let text = doc.buffer.text.substring(with: NSRange(location: l.start, length: l.end - l.start))
        let role = doc.buffer.segment(at: l.start)?.element.role ?? "?"
        print("  \(i): \(role) \(mask(text))")
    }
    func press(_ name: String, _ mods: Modifiers = []) {
        let g = KeyboardGesture(keyCode: KeyNames.code(for: name) ?? 0, modifiers: mods, characters: name.count == 1 ? name : "", timestamp: 0, isRepeat: false, flags: [])
        guard let s = ScriptHandler.findScript(for: g) else { print("\(g.identifier): no script"); return }
        s.handler(g); print("\(g.identifier) → \(s.name), position \(doc.position)")
    }
    doc.position = 0
    press("downArrow"); press("downArrow"); press("h"); press("h"); press("h", .shift)
    doc.position = 0
    for _ in 0..<125 { press("downArrow") }   // across page 1's end: "Page 2" should be said before the line
    print("done"); exit(0)
}
if args.contains("--web") {
    // Browse mode against the first Safari window that exposes a web area, silently.
    // --wrap N: lines wrapped at N characters (a long heading over two lines was read twice, 8 Oct 2026).
    if let w = opt("--wrap").flatMap(Int.init) { config.virtualBuffers.maxLineLength = w }
    let bundle = args.firstIndex(of: "--app").map { args[$0 + 1] } ?? "com.apple.Safari"
    guard let safari = args.firstIndex(of: "--pid").flatMap({ NSRunningApplication(processIdentifier: pid_t(args[$0 + 1])!) })
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { print("\(bundle) not running"); exit(1) }
    let sEl = AXUIElementCreateApplication(safari.processIdentifier)
    AXUIElementSetMessagingTimeout(sEl, 3)
    var webEl: AXUIElement?
    let want = args.firstIndex(of: "--url").map { args[$0 + 1] }
    for w in sEl.elements(kAXWindowsAttribute) where webEl == nil {
        // Every web area in the window (Electron apps hold the page beside their shell's own).
        var queue = [w]; var n = 0
        while !queue.isEmpty, n < 4000, webEl == nil {
            let e = queue.removeFirst(); n += 1
            if e.role == "AXWebArea", want.map({ "\(e.attr("AXURL") ?? "" as CFTypeRef)".contains($0) }) ?? true { webEl = e; break }
            queue.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
    }
    guard let webEl else { print("no web area"); exit(1) }
    let web = ObjectFactory.make(webEl)
    print("web area object: \(type(of: web)) \"\(web.name)\" url \(webEl.attr("AXURL") ?? "" as CFTypeRef)")
    guard let doc = BrowseModeHandler.shared.document(for: web, ancestors: []) else { print("browse mode not supported here"); exit(1) }
    API.setFocusObject(web, ancestors: [], interceptor: doc)
    func press(_ name: String, _ mods: Modifiers = []) {
        let g = KeyboardGesture(keyCode: KeyNames.code(for: name) ?? 0, modifiers: mods, characters: name.count == 1 ? name : "", timestamp: 0, isRepeat: false, flags: [])
        guard let s = ScriptHandler.findScript(for: g) else { print("\(g.identifier): no script"); return }
        let t0 = DispatchTime.now().uptimeNanoseconds
        s.handler(g)
        print("\(g.identifier.padding(toLength: 24, withPad: " ", startingAt: 0)) → \(s.name) in \(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)) ms, position \(doc.position)")
    }
    if let keys = opt("--press") {
        // --press h,h,shift+h: press these in order and print what is said (the heading double-read hunt, 8 Oct 2026).
        for k in keys.split(separator: ",") {
            let parts = k.split(separator: "+").map(String.init)
            var mods = Modifiers()
            for m in parts.dropLast() { if let mm = Modifiers.named(m) { mods.insert(mm) } }
            press(parts.last ?? "", mods)
        }
        exit(0)
    }
    if args.contains("--lines") {
        // Every buffer line: offset, the element's role, control fields, and its text (the double-read hunt, 8 Oct 2026).
        for l in doc.buffer.lines {
            let t = doc.buffer.text.substring(with: NSRange(location: l.start, length: max(0, min(l.end, doc.buffer.text.length) - l.start)))
            print("[\(l.start)] \(l.element?.role ?? "-")\(l.isControl ? " control \(l.fields)" : "")\(l.entering.isEmpty ? "" : " entering \(l.entering.map { $0.role })"): \(t.replacingOccurrences(of: "\n", with: "⏎"))")
        }
        exit(0)
    }
    if args.contains("--search") {
        let found = doc.bridge.search(key: "AXHeadingSearchKey", from: webEl, forward: true, limit: 6)
        print("== WebKit heading search from the web area: \(found.count)")
        for f in found {
            var chain: [String] = []; var e: AXUIElement? = f; var n = 0
            while let x = e, n < 30 { if x.role == "AXWebArea" { chain.append("WebArea(\(x.attr("AXURL") ?? "" as CFTypeRef))") }; e = x.element(kAXParentAttribute); n += 1 }
            var pid: pid_t = 0; AXUIElementGetPid(f, &pid)
            var v: AnyObject?; let err = AXUIElementCopyAttributeValue(f, kAXRoleAttribute as CFString, &v)
            var names: CFArray?; let nerr = AXUIElementCopyAttributeNames(f, &names)
            print("  pid \(pid) role error \(err.rawValue) names error \(nerr.rawValue) count \((names as? [String])?.count ?? -1)")
            print("  \(f.role) \"\(f.string(kAXTitleAttribute) ?? f.string(kAXDescriptionAttribute) ?? "")\" buffer offset \(doc.buffer.offset(of: f).map(String.init) ?? "nil") in \(chain)")
        }
        print("buffer: \(doc.buffer.lines.count) lines; first lines:")
        for l in doc.buffer.lines.prefix(8) { print("  [\(l.start)] \(l.element?.role ?? "-")") }
        exit(0)
    }
    if args.contains("--late") {
        // A page whose content arrives late: the arrows on an empty copy, then the page read when it comes.
        print("lines at first: \(doc.buffer.lines.count)")
        press("downArrow")
        RunLoop.main.run(until: Date().addingTimeInterval(12))
        print("lines after 12 s: \(doc.buffer.lines.count)")
        exit(0)
    }
    if args.contains("--braille") {
        // A pretend 20-cell display: prints each write as Unicode braille, then the text it should say.
        final class Fake: BrailleDisplayDriver {
            let name = "pretend display"; let cellCount = 20
            func write(_ cells: [UInt8]) { print("   display: " + String(String.UnicodeScalarView(cells.compactMap { UnicodeScalar(0x2800 + UInt32($0)) }))) }
            func close() {}
        }
        doc.position = 0
        Braille.attach(Fake())
        func settle() { Braille.refreshSoon(); RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        settle()
        press("downArrow"); settle()
        press("downArrow"); settle()
        print("== pan forward, twice"); Braille.handle(.key("d5")); settle(); Braille.handle(.key("d5")); settle()
        print("== pan back"); Braille.handle(.key("d2")); settle()
        print("== routing key 3"); Braille.handle(.routing(3)); settle()
        print("position now \(doc.position)")
        exit(0)
    }
    if args.contains("--lang") {
        // Automatic language switching: each line's language and the voice it would be read with (--aloud: and say it).
        config = Config.load()
        let langPlayer = try! SpeechPlayer(voice: config.speech.voice, rate: config.speech.rate)
        for l in doc.buffer.lines.prefix(12) {
            let info = try! web.makeTextInfo(.bookmark(Bookmark(start: l.start, end: l.endWithBreak)))
            let lang = info.language()
            print("  \(lang ?? "-") → \(Languages.voice(for: lang) ?? "current voice"): \(info.text.prefix(40).replacingOccurrences(of: "\n", with: " "))")
            if args.contains("--aloud") { langPlayer.speak(info.text, interrupt: false, voice: Languages.voice(for: lang)) }
        }
        if args.contains("--aloud") { RunLoop.main.run(until: Date().addingTimeInterval(14)) }
        exit(0)
    }
    if args.contains("--select") {
        doc.position = 0
        press("downArrow"); press("downArrow")
        print("== select"); press("downArrow", .shift); press("downArrow", .shift); press("upArrow", .shift); press("rightArrow", [.shift, .option])
        press("c", .command)
        print("clipboard: [\(NSPasteboard.general.string(forType: .string) ?? "")]")
        press("downArrow")
        print("after a plain move, selection: \(doc.selectedRange.map { "\($0)" } ?? "none")")
        exit(0)
    }
    print("== line diagnostics at the top")
    for pos in [0, 1, 2, 3, 18, 25] {
        let b = doc.bridge
        let el = b.element(at: pos)
        let ch = (try? doc.rootObject.makeTextInfo(.bookmark(Bookmark(start: pos, end: pos + 1))))?.text ?? ""
        let line = b.unitRange("AXLineTextMarkerRangeForTextMarker", at: pos)
        let right = b.unitRange("AXRightLineTextMarkerRangeForTextMarker", at: pos)
        let para = b.unitRange("AXParagraphTextMarkerRangeForTextMarker", at: pos)
        let elRange = el.flatMap { b.range(of: $0) }
        let info = try! doc.rootObject.makeTextInfo(.bookmark(Bookmark(start: pos, end: pos)))
        info.expand(.line)
        print("  pos \(pos) char \(ch.debugDescription) element \(el?.role ?? "-") range \(elRange.map { "\($0)" } ?? "-") | line \(line.map { "\($0)" } ?? "nil") right \(right.map { "\($0)" } ?? "nil") para \(para.map { "\($0)" } ?? "nil") | expand(.line) → [\(info.start),\(info.end)) \(info.text.count) chars")
    }
    print("== lines from the top")
    doc.position = 0
    for _ in 0..<6 { press("downArrow") }
    print("== words and characters")
    for _ in 0..<3 { press("rightArrow", .option) }
    for _ in 0..<3 { press("rightArrow") }
    press("leftArrow")
    print("== quick nav")
    doc.position = 0
    press("h"); press("h"); press("h", .shift); press("k"); press("k"); press("b"); press("l"); press("d"); press("2"); press("e"); press("t")
    print("== say all chunk and current line review")
    if let info = try? doc.rootObject.makeTextInfo(.caret) { let r = info.copy(); r.move(.readingChunk, 1, endPoint: .end); print("   chunk [\(r.start),\(r.end)): \(Speech.textInfoSpeech(r, unit: .readingChunk, reason: .sayAll).prefix(100))") }
    press("l", .turnover)
    print("done"); exit(0)
}

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { print("\(bundle) is not running"); exit(1) }
let appEl = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(appEl, 1.0)

func ms(_ body: () -> Void) -> String {
    let t0 = DispatchTime.now().uptimeNanoseconds; body()
    return String(format: "%.2f ms", Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
}

// 1. The focus as the app reports it, and as an object.
print("== focus")
if let f = appEl.element(kAXFocusedUIElementAttribute) {
    let obj = ObjectFactory.make(f)
    print("AX focus: \(obj.axRole)/\(obj.axSubrole ?? "-") → \(type(of: obj)) role \(obj.role) name \"\(obj.name)\" states \(obj.states.map(\.rawValue).sorted())")
    print("spoken as focus: \(Speech.objectPropertiesSpeech(obj, reason: .focus))")
    let anc = obj.ancestors
    print("ancestors: \(anc.map { "\($0.axRole)\($0.isPresentableFocusAncestor ? "*" : "")" }.joined(separator: " > "))")
}

// 2. A text element: the caret page area in Word, or the focus if it has text.
print("== text")
var textEl: AXUIElement?
if let win = appEl.element(kAXFocusedWindowAttribute) {
    var queue = [win]; var visited = 0
    while !queue.isEmpty && visited < 6000 {
        let e = queue.removeFirst(); visited += 1
        if e.role == "AXTextArea", let sel = cfRange(e.attr(kAXSelectedTextRangeAttribute)), sel.location != Int.max { textEl = e; break }
        queue.append(contentsOf: e.elements(kAXChildrenAttribute))
    }
}
guard let textEl else { print("no text element with a caret found"); exit(0) }
let obj = ObjectFactory.make(textEl)
print("text object: \(type(of: obj)) role \(obj.role) desc \"\(textEl.string(kAXDescriptionAttribute) ?? "")\" navigable \(obj.hasNavigableText)")

guard let caret = try? obj.makeTextInfo(.caret) else { print("no caret TextInfo"); exit(1) }
print("caret at \(caret.start), story length \(caret.storyLength())")
for unit in [TextUnit.character, .word, .line, .sentence, .paragraph] {
    let i = caret.copy()
    var text = ""
    let t = ms { i.expand(unit); text = i.text }
    print("\(unit) [\(i.start),\(i.end)) \(t): \"\(text.prefix(120).replacingOccurrences(of: "\r", with: "⏎").replacingOccurrences(of: "\n", with: "⏎"))\"")
    print("   speech: \(Speech.textInfoSpeech(i, unit: unit, reason: .caret).prefix(140))")
}
print("formatting: \(caret.formatField()?.fullDescription ?? "none")")
print("location: \(caret.locationText ?? "n/a")")

// 3. Moves along the text (on copies: the caret is not touched).
print("== moves")
let w = caret.copy()
var words: [String] = []
for _ in 0..<8 { guard w.move(.word, 1) != 0 else { break }; let x = w.copy(); x.expand(.word); words.append(x.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
print("next 8 words: \(words)")
let wb = caret.copy()
words = []
for _ in 0..<5 { guard wb.move(.word, -1) != 0 else { break }; let x = wb.copy(); x.expand(.word); words.append(x.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
print("previous 5 words: \(words)")
let l = caret.copy()
var lines: [String] = []
for _ in 0..<3 { guard l.move(.line, 1) != 0 else { break }; let x = l.copy(); x.expand(.line); lines.append(String(x.text.prefix(60))) }
print("next 3 lines: \(lines)")
let p = caret.copy()
var paras: [String] = []
for _ in 0..<2 { guard p.move(.paragraph, 1) != 0 else { break }; let x = p.copy(); x.expand(.paragraph); paras.append(String(x.text.prefix(60))) }
print("next 2 paragraphs: \(paras)")
let r = caret.copy(); r.move(.readingChunk, 1, endPoint: .end)
print("say-all first chunk [\(r.start),\(r.end)): \"\(r.text.prefix(80))\"")
// Selection arithmetic (NVDA's speakSelectionChange).
let a = caret.copy(); a.end = a.start + 5
let b = caret.copy(); b.end = b.start + 9
print("compare a/b startToStart \(b.compareEndPoints(a, .startToStart)) endToEnd \(b.compareEndPoints(a, .endToEnd))")
let diff = b.copy(); diff.setEndPoint(a, .startToEnd)
print("selection grew by: \"\(diff.text)\"")

// 4. Script resolution, as the keyboard thread does it.
print("== scripts")
API.setFocusObject(obj, ancestors: obj.ancestors)
func g(_ name: String, _ mods: Modifiers = []) -> KeyboardGesture {
    KeyboardGesture(keyCode: KeyNames.code(for: name) ?? 0, modifiers: mods, characters: name.count == 1 ? name : "", timestamp: 0, isRepeat: false, flags: [])
}
for (gesture, label) in [(g("upArrow"), "upArrow"), (g("rightArrow", .option), "option+rightArrow"), (g("backspace"), "backspace"), (g("t", .turnover), "turnover+t"),
                         (g("l", .turnover), "turnover+l"), (g("a"), "a"), (g("h", .turnover), "turnover+h"), (g("1", .turnover), "turnover+1"), (g("downArrow", [.turnover]), "turnover+downArrow")] {
    var s: Script?
    let t = ms { s = ScriptHandler.findScript(for: gesture) }
    print("\(label.padding(toLength: 20, withPad: " ", startingAt: 0)) \(gesture.identifier.padding(toLength: 26, withPad: " ", startingAt: 0)) → \(s?.name ?? "(pass through)") [\(t)] typed: \(gesture.typedCharacter.map { "'\($0)'" } ?? "-")")
}
print("normalize: \(normalizeGestureIdentifier("kb:NVDA+Control+UpArrow")) \(normalizeGestureIdentifier("kb(laptop):shift+nvda+."))")
print("spoken: \(g("upArrow", [.turnover, .shift]).displayName) | \(g(".", .turnover).displayName)")

if allowMoves {
    print("== moving the caret (--move)")
    let i = caret.copy(); i.move(.word, 1); i.updateCaret()
    usleep(50_000)
    print("caret now \((try? obj.makeTextInfo(.caret))?.start ?? -1) (asked \(i.start))")
    caret.updateCaret()
}
print("done")
