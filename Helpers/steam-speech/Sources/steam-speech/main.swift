// SPDX-License-Identifier: GPL-3.0-or-later
// steam-speech: Steam speech's program, for TurnOver (github.com/TurnOver-For-Mac/turnover-plugins). MIT.
//
// What it does, all of it:
//  1. Steam's Big Picture is silent on macOS: Steam draws it in a helper with no accessibility tree. An empty file
//     named .cef-enable-remote-debugging in the Steam client's folder makes Steam open its Chromium debugging port on
//     127.0.0.1:8080. This program puts that file there (a Steam update removes it), attaches to every Big Picture
//     page on that port, installs a small script that watches Valve's own focus class (gpfocus: the gamepad
//     interface never moves the page's real focus) and reports the focused item, and turns the reports into words.
//     It attaches only to a port that lists Steam's own steamloopback.host page: anything else on 8080 is a stranger
//     and never gets the script.
//  2. Steam games built on Electron, started with the launch option --remote-debugging-port=9223, speak what they
//     put in aria-live regions and where focus moves.
//  3. On request, restarts Steam so the port comes up (the Mac client, or the Windows client in a CrossOver bottle).
//
// What it can't do: it is started by TurnOver without TurnOver's permissions, so it can't read or control other
// apps, see the screen or the keyboard. It reaches only 127.0.0.1 (no other network), and writes only the switch file.
//
// Talking to TurnOver, one line each way. It writes to standard output:
//   S <text>   say this          I <text>   stop what is being said, then say this
//              (either may end with a tab and the page it came from, for TurnOver's log)
//   X          stop speaking      L <text>   a line for TurnOver's log
//   T <text>   the answer to "status"
//   R          Steam's menu is showing but nothing in Steam has the keyboard (Steam's own fault; VoiceOver meets
//              it too). TurnOver switches to itself and back to Steam, unseen, which makes Steam give the menu the
//              keys. This program can't do that itself; TurnOver decides, and only while Steam is in front.
// It reads from standard input: "status", "restart-steam". When standard input closes, TurnOver has gone: it quits.
//
//   steam-speech [--no-big-picture] [--web-port 9223]
//   steam-speech --self-test     checks the parts that turn reports into words
import AppKit
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Talking to TurnOver

enum Out {
    static func line(_ kind: String, _ text: String = "") {
        let one = text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        print(one.isEmpty ? kind : "\(kind) \(one)")
    }
    /// `from`: which page it came from, after a tab, for TurnOver's log ("Library\tMainMenu_uid2").
    static func say(_ text: String, interrupting: Bool = false, from: String = "") {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\t", with: " ")
        if !t.isEmpty { line(interrupting ? "I" : "S", from.isEmpty ? t : t + "\t" + from.replacingOccurrences(of: "\t", with: " ")) }
    }
    static func log(_ text: String) { line("L", text) }
}

// Page titles, element text and error descriptions can contain private content. Keep the diagnostic's shape,
// never those words, even when this helper is run on its own (issue 68, 28 Oct 2026).
enum Diagnostic {
    static func text(_ value: String) -> String { "[\(value.count) characters]" }
    static func page(_ title: String) -> String { "page \(text(title))" }
    static func error(_ error: Error) -> String { "error code \((error as NSError).code)" }

    static func skippedFocus(_ object: [String: Any]) -> String {
        ["tag", "cls", "text"].map { "\($0)=\(text(object[$0] as? String ?? ""))" }.joined(separator: " ")
    }

    static func observer(in title: String, result: [String: Any]) -> String {
        let value = (result["result"] as? [String: Any])?["value"] as? String
        // Only the literal acknowledgements returned by our own scripts are safe to keep as words.
        let status = value.map { ["already", "installed", "installed v11"].contains($0) ? $0 : text($0) }
            ?? "no installation acknowledgement"
        return "observer in \(page(title)): \(status)"
    }
}

let steamBundle = "com.valvesoftware.steam"

// MARK: - Big Picture's reports, as words

enum BigPictureEvent: Equatable { case speak(String), focusGone, skipped(String), nothing }

/// What the page's observer reported, as words: the name, a role only where it carries information (a tab is worth
/// knowing about; a button is what most things are), the state, then the blurb after a pause.
func bigPictureEvent(_ payload: String) -> BigPictureEvent {
    guard let data = payload.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .nothing }
    if object["focusGone"] as? Bool == true { return .focusGone }
    if object["skipped"] as? Bool == true {
        return .skipped(Diagnostic.skippedFocus(object))
    }
    var text = (object["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    // The page's script's own words ("top", "on"), not Steam's.
    if object["own"] as? Bool == true { return text.isEmpty ? .nothing : .speak(word(text)) }
    let role = object["role"] as? String ?? ""
    let state = object["state"] as? String ?? ""
    guard !text.isEmpty || !role.isEmpty else { return .nothing }
    if role == "tab" { text += ", " + word("tab") }
    if ["slider", "checkbox", "switch", "radio"].contains(role) { text += ", " + word(role) }
    if !state.isEmpty { text += ", " + state.components(separatedBy: ", ").map(word).joined(separator: ", ") }
    if text.isEmpty { text = role }
    if let blurb = object["blurb"] as? String, !blurb.isEmpty { text += ". \(blurb)" }
    return .speak(text)
}

// MARK: - TurnOver's words

/// TurnOver.app, which this program lives in (Contents/Helpers): its translations are TurnOver's own. Outside the
/// app (the self-test) there is none, and the English stands.
let turnOverApp: Bundle? = {
    let app = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return app.pathExtension == "app" ? Bundle(url: app) : nil
}()

/// A word this program adds to Steam's, in the reader's language (an unknown word, a slider's number, as it is).
func word(_ english: String) -> String {
    switch english {
    case "tab": return String(localized: "tab", bundle: turnOverApp, comment: "A role, spoken after an item's name")
    case "slider": return String(localized: "slider", bundle: turnOverApp, comment: "A role, spoken after an item's name")
    case "switch": return String(localized: "switch", bundle: turnOverApp, comment: "A role, spoken after an item's name")
    case "checkbox": return String(localized: "checkbox", bundle: turnOverApp, comment: "A role in Steam's Big Picture: a check box")
    case "radio": return String(localized: "radio", bundle: turnOverApp, comment: "A role in Steam's Big Picture: a radio button")
    case "selected": return String(localized: "selected", bundle: turnOverApp, comment: "A state, spoken after an item's role")
    case "on": return String(localized: "on", bundle: turnOverApp, comment: "A state, spoken after an item's role")
    case "off": return String(localized: "off", bundle: turnOverApp, comment: "A state, spoken after an item's role")
    case "mixed": return String(localized: "mixed", bundle: turnOverApp, comment: "A state in Steam's Big Picture: half checked")
    case "top": return String(localized: "top", bundle: turnOverApp, comment: "Spoken message")
    case "bottom": return String(localized: "bottom", bundle: turnOverApp, comment: "Spoken message")
    case "nothing to read here": return String(localized: "nothing to read here", bundle: turnOverApp, comment: "Steam's Big Picture page has nothing to read")
    default: return english
    }
}

// MARK: - Chromium pages over a debugging port

struct DevToolsTarget: Decodable {
    let id: String
    let type: String?
    let title: String?
    let url: String?
    let webSocketDebuggerUrl: String?
}

/// Polls a debugging port's target list, attaches a session to every page wanted, drops the ones that have gone,
/// pings the rest (a socket can die while its page stays listed; left alone that was permanent silence).
final class DevToolsReader {
    let port: UInt16
    let name: String
    private let binding: String
    private let script: String
    private let attach: (DevToolsTarget) -> Bool
    /// Whether the list is the program we want at all (Steam's port must list steamloopback.host).
    private let gate: ([DevToolsTarget]) -> Bool
    private let every: TimeInterval
    private let onEvent: (String, DevToolsSession) -> Void
    private var timer: Timer?
    private(set) var sessions: [String: DevToolsSession] = [:]
    private(set) var portIsUp = false
    private(set) var portIsForeign = false
    private var warnedForeign = false
    var onPortDown: (() -> Void)?
    var onReconciled: (() -> Void)?

    init(port: UInt16, name: String, binding: String, script: String, attach: @escaping (DevToolsTarget) -> Bool,
         gate: @escaping ([DevToolsTarget]) -> Bool, every: TimeInterval, onEvent: @escaping (String, DevToolsSession) -> Void) {
        self.port = port; self.name = name; self.binding = binding; self.script = script
        self.attach = attach; self.gate = gate; self.every = every; self.onEvent = onEvent
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: every, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        for s in sessions.values { s.close() }
        sessions.removeAll()
        portIsUp = false
    }

    private func poll() {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json/list") else { return }
        var req = URLRequest(url: url); req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self, self.timer != nil else { return }
                let targets = data.flatMap { try? JSONDecoder().decode([DevToolsTarget].self, from: $0) }
                guard error == nil, let targets, self.gate(targets) else {
                    let somethingAnswered = error == nil && data != nil
                    if somethingAnswered {
                        self.portIsForeign = true
                        if !self.warnedForeign {
                            self.warnedForeign = true
                            Out.log("port \(self.port) answers but it is not what the \(self.name) reader wants; not attaching")
                        }
                    } else {
                        self.portIsForeign = false; self.warnedForeign = false
                    }
                    if self.portIsUp {
                        self.portIsUp = false
                        Out.log("\(self.name): port \(self.port) went away")
                        for s in self.sessions.values { s.close() }
                        self.sessions.removeAll()
                    }
                    self.onPortDown?()
                    return
                }
                if !self.portIsUp { self.portIsUp = true; Out.log("\(self.name): port \(self.port) is up") }
                self.portIsForeign = false; self.warnedForeign = false
                for s in self.sessions.values { s.ping() }
                self.reconcile(targets)
            }
        }.resume()
    }

    private func reconcile(_ targets: [DevToolsTarget]) {
        let wanted = targets.filter { attach($0) && $0.webSocketDebuggerUrl != nil }
        let ids = Set(wanted.map { $0.id })
        for (id, s) in sessions where !ids.contains(id) {
            Out.log("\(name): \(Diagnostic.page(s.title)) closed")
            s.close(); sessions.removeValue(forKey: id)
        }
        for t in wanted where sessions[t.id] == nil {
            // Only the loopback: a target list can name any address, and the script goes nowhere else.
            guard let url = URL(string: t.webSocketDebuggerUrl ?? ""), ["127.0.0.1", "localhost"].contains(url.host ?? "") else { continue }
            let title = t.title ?? t.url ?? t.id
            let id = t.id
            let s = DevToolsSession(title: title, url: url, binding: binding, script: script,
                                    onEvent: { [weak self] payload, session in self?.onEvent(payload, session) },
                                    onDead: { [weak self] in
                                        guard let self, self.sessions[id] != nil else { return }
                                        self.sessions.removeValue(forKey: id)
                                        Out.log("\(self.name): \(Diagnostic.page(title)) connection died; attaching again on the next poll")
                                    })
            sessions[id] = s
            Out.log("\(name): attached to \(Diagnostic.page(title))")
        }
        onReconciled?()
    }
}

/// One DevTools WebSocket: the observer script installed now and on every navigation, a binding the page calls.
final class DevToolsSession {
    let title: String
    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var nextId = 1   // under `lock`
    private var pending: [Int: ([String: Any]) -> Void] = [:]
    private let binding: String
    private let onEvent: (String, DevToolsSession) -> Void
    private let onDead: () -> Void
    private var closed = false

    init(title: String, url: URL, binding: String, script: String, onEvent: @escaping (String, DevToolsSession) -> Void, onDead: @escaping () -> Void) {
        self.title = title; self.binding = binding; self.onEvent = onEvent; self.onDead = onDead
        task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        receive()
        send("Runtime.enable")
        send("Page.enable")
        send("Runtime.addBinding", ["name": binding])
        send("Page.addScriptToEvaluateOnNewDocument", ["source": script])
        send("Runtime.evaluate", ["expression": script, "returnByValue": true]) { result in
            Out.log(Diagnostic.observer(in: title, result: result))
        }
    }

    func close() { closed = true; task.cancel(with: .goingAway, reason: nil) }

    func ping() { task.sendPing { [weak self] error in if error != nil { self?.died() } } }

    func evaluate(_ expression: String) { send("Runtime.evaluate", ["expression": expression]) }
    /// A key pressed in this page, down and up, whatever the Mac's keyboard focus (Input.dispatchKeyEvent).
    func key(_ key: String, vk: Int) {
        send("Input.dispatchKeyEvent", ["type": "rawKeyDown", "key": key, "code": key, "windowsVirtualKeyCode": vk])
        send("Input.dispatchKeyEvent", ["type": "keyUp", "key": key, "code": key, "windowsVirtualKeyCode": vk])
    }

    /// An expression's value (a string), on the main queue.
    func evaluate(_ expression: String, then done: @escaping (String?) -> Void) {
        send("Runtime.evaluate", ["expression": expression, "returnByValue": true]) { result in
            done((result["result"] as? [String: Any])?["value"] as? String)
        }
    }

    private func died() {
        guard !closed else { return }
        closed = true
        task.cancel(with: .goingAway, reason: nil)
        DispatchQueue.main.async { self.onDead() }
    }

    private func send(_ method: String, _ params: [String: Any] = [:], _ done: (([String: Any]) -> Void)? = nil) {
        lock.lock()
        let id = nextId; nextId += 1
        if let done { pending[id] = done }
        lock.unlock()
        guard let data = try? JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params]) else { return }
        task.send(.string(String(decoding: data, as: UTF8.self))) { error in
            if let error { DispatchQueue.main.async { Out.log("send failed: \(Diagnostic.error(error))") } }
        }
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case .failure(let error):
                DispatchQueue.main.async { Out.log("\(Diagnostic.page(self.title)) socket closed: \(Diagnostic.error(error))") }
                self.died()
            case .success(let message):
                var text = ""
                if case .string(let s) = message { text = s }
                if case .data(let d) = message { text = String(decoding: d, as: UTF8.self) }
                if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                    if let id = object["id"] as? Int {
                        self.lock.lock(); let cb = self.pending.removeValue(forKey: id); self.lock.unlock()
                        let r = (object["result"] as? [String: Any]) ?? (object["error"] as? [String: Any]) ?? [:]
                        if let cb { DispatchQueue.main.async { cb(r) } }
                    } else if object["method"] as? String == "Runtime.bindingCalled",
                              let params = object["params"] as? [String: Any],
                              params["name"] as? String == self.binding,
                              let payload = params["payload"] as? String {
                        DispatchQueue.main.async { self.onEvent(payload, self) }
                    }
                }
                self.receive()
            }
        }
    }
}

// MARK: - Steam's Big Picture

final class BigPictureReader {
    private var reader: DevToolsReader?
    private var lastSpoken = ""
    private var lastSpokenAt = Date.distantPast
    private var hadBigPicture = false
    private var portDownSince: Date?
    private var warnedPortDown = false
    private(set) var steamRunningWithoutPort = false

    var status: String {
        guard let r = reader else { return "Not reading Big Picture." }
        if steamRunningWithoutPort { return "Steam is running without its port; restart Steam from the Games menu." }
        if r.portIsForeign { return "Port 8080 is in use by something that is not Steam." }
        if !r.portIsUp { return "Waiting for Steam." }
        if r.sessions.isEmpty { return "Steam is up; waiting for Big Picture." }
        return lastSpoken.isEmpty ? "Reading Big Picture." : "Reading Big Picture. Last: \(lastSpoken.prefix(60))"
    }

    func start() {
        SteamInstall.ensureSwitchFiles()
        let r = DevToolsReader(port: 8080, name: "Big Picture", binding: "__steamSpeak", script: Scripts.bigPicture,
                               attach: { $0.type == "page" && $0.title != "SharedJSContext" },
                               // Steam's own endpoint always lists SharedJSContext at steamloopback.host; anything
                               // else on 8080 is a stranger (a dev server) and must never get our script.
                               gate: { targets in targets.contains { URL(string: $0.url ?? "")?.host == "steamloopback.host" } },
                               every: 2.0) { [weak self] payload, session in self?.heard(payload, from: session) }
        r.onPortDown = { [weak self] in self?.portDown() }
        r.onReconciled = { [weak self] in self?.reconciled() }
        reader = r
        r.start()
        rescueTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in self?.checkKeyboard() }
        Out.log("watching 127.0.0.1:8080 for Big Picture")
    }

    // MARK: Steam's menu opening without the keyboard

    /// Opened a second time, Steam's main menu could appear without the keyboard: no page had it, so the arrows went
    /// nowhere until you switched apps and back (14 Oct 2026; recorded: MainMenu visible, no page focused).
    /// While Big Picture is in front, if the menu is showing and no page has the keyboard, the menu is given it.
    private var rescueTimer: Timer?
    private var lastRescue = Date.distantPast
    private var checking = false
    private var rescuesThisTime = 0   // at most two Tabs while it stays stuck; reset once something has the keyboard

    /// A key for the main menu, from TurnOver ("key ArrowDown 40"): the menu opens without the Mac's keyboard
    /// (Escape in Big Picture), and no switching gives it one; keys put straight into the menu's page move its
    /// highlight and choose (found 15 Oct 2026). Nothing if no menu page is there.
    func forwardKey(_ key: String, vk: Int) {
        guard let reader, let menu = reader.sessions.values.first(where: { $0.title.hasPrefix("MainMenu") }) else {
            Out.log("key \(Diagnostic.text(key)) for the menu, but no menu page"); return
        }
        menu.key(key, vk: vk)
    }

    private func checkKeyboard() {
        guard !checking, let reader, Date().timeIntervalSince(lastRescue) > 1.5,
              let front = NSWorkspace.shared.frontmostApplication, SteamInstall.isSteamProcess(front) else { return }
        let pages = Array(reader.sessions.values)
        guard let menu = pages.first(where: { $0.title.hasPrefix("MainMenu") }) else { return }
        checking = true
        var answers: [String: String] = [:]
        let group = DispatchGroup()
        for page in pages where !page.title.hasPrefix("notificationtoasts") {
            group.enter()
            page.evaluate("document.visibilityState + ' ' + document.hasFocus()") { value in answers[page.title] = value ?? "?"; group.leave() }
        }
        let gaveUp = DispatchWorkItem { [weak self] in self?.checking = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: gaveUp)
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            gaveUp.cancel(); self.checking = false
            let anyFocused = answers.values.contains { $0.hasSuffix(" true") }
            guard !anyFocused, answers[menu.title] == "visible false" else { self.rescuesThisTime = 0; return }
            guard self.rescuesThisTime < 2 else { return }
            self.rescuesThisTime += 1
            self.lastRescue = Date()
            // window.focus() from the page doesn't move the keyboard (tried 14 Oct 2026: "not focused"), nor does a
            // Tab (it lands in the page behind); Steam re-routes the keys when its window becomes active again.
            Out.log("Steam's menu is showing without the keyboard; asking TurnOver to switch away and back (\(self.rescuesThisTime) of 2)")
            Out.line("R")
        }
    }

    /// Steam is running and its port is not there: a Steam update replaced the client directory and the switch
    /// file with it. Put the file back and say so once; TurnOver's Games menu has Restart Steam.
    private func portDown() {
        if reader?.portIsUp == false, hadBigPicture { hadBigPicture = false }
        let steamRunning = NSWorkspace.shared.runningApplications.contains(where: SteamInstall.isSteamProcess)
        guard steamRunning, reader?.portIsForeign == false else {
            portDownSince = nil; warnedPortDown = false; steamRunningWithoutPort = false
            return
        }
        SteamInstall.ensureSwitchFiles()
        if portDownSince == nil { portDownSince = Date() }
        guard let since = portDownSince, Date().timeIntervalSince(since) > 8 else { return }
        steamRunningWithoutPort = true
        guard !warnedPortDown else { return }
        warnedPortDown = true
        Out.log("Steam is running without its debugging port; it needs restarting before Big Picture can be read")
        Out.say(String(localized: "Steam needs restarting before Big Picture can be read. Restart Steam is in the Games menu.", bundle: turnOverApp, comment: "Steam speech"))
    }

    private func reconciled() {
        portDownSince = nil; warnedPortDown = false; steamRunningWithoutPort = false
        let has = reader?.sessions.values.contains { $0.title == "Steam Big Picture Mode" } ?? false
        if has && !hadBigPicture {
            hadBigPicture = true
            Out.log("Big Picture is open; reading")
            Out.say(String(localized: "Reading Big Picture.", bundle: turnOverApp, comment: "Steam speech"))
        } else if !has {
            hadBigPicture = false
        }
    }

    private func heard(_ payload: String, from session: DevToolsSession) {
        switch bigPictureEvent(payload) {
        case .nothing: return
        case .focusGone:
            // An overlay (the Steam menu, Quick Access) lost focus: it is closing. Have the main page say what is
            // under focus now; it is the same element as before and would otherwise stay silent.
            if session.title != "Steam Big Picture Mode" {
                reader?.sessions.values.first { $0.title == "Steam Big Picture Mode" }?
                    .evaluate("window.__steamSpeakReport && window.__steamSpeakReport()")
            }
        case .skipped(let what):
            // A focused element with no name and no role (Steam's settings screens): logged so the gaps can be closed.
            Out.log("skipped a nameless focus in \(Diagnostic.page(session.title)): \(what)")
        case .speak(let text):
            // The same thing twice in quick succession is one event that fired twice.
            let now = Date()
            if text == lastSpoken && now.timeIntervalSince(lastSpokenAt) < 0.6 { return }
            lastSpoken = text; lastSpokenAt = now
            Out.say(text, interrupting: true, from: session.title)
        }
    }
}

/// A Steam client this Mac can read: the native one, and the Windows one in any CrossOver bottle (Wine shares the
/// loopback, so a bottle's Steam puts its DevTools on the same port; only the switch file lives elsewhere, next to
/// steam.exe, and restarting is a different verb).
enum SteamInstall {
    case mac
    case bottle(name: String, steamExe: URL)

    static let crossOverBundle = "com.codeweavers.CrossOver"

    /// Found by bisection on 17 Sep 2026: the file in the client's own directory brings the port up in two seconds.
    static let macSwitchFile = URL(fileURLWithPath: NSHomeDirectory()
        + "/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/.cef-enable-remote-debugging")
    static let bottlesDirectory = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/CrossOver/Bottles", isDirectory: true)

    var switchFile: URL {
        switch self {
        case .mac: return Self.macSwitchFile
        case .bottle(_, let exe): return exe.deletingLastPathComponent().appendingPathComponent(".cef-enable-remote-debugging")
        }
    }

    var name: String {
        switch self {
        case .mac: return "Steam"
        case .bottle(let name, _): return "Steam in the \(name) bottle"
        }
    }

    static var all: [SteamInstall] {
        var found: [SteamInstall] = []
        if FileManager.default.fileExists(atPath: macSwitchFile.deletingLastPathComponent().path) { found.append(.mac) }
        let bottles = (try? FileManager.default.contentsOfDirectory(at: bottlesDirectory, includingPropertiesForKeys: nil)) ?? []
        for bottle in bottles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let exe = bottle.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe")
            if FileManager.default.fileExists(atPath: exe.path) { found.append(.bottle(name: bottle.lastPathComponent, steamExe: exe)) }
        }
        return found
    }

    /// Big Picture reading off (or TurnOver uninstalling): the switch files go, so Steam stops opening its debugging
    /// port at its next start (20 Oct 2026: it was left on for every Mac with Steam).
    static func removeSwitchFiles() {
        for i in all where FileManager.default.fileExists(atPath: i.switchFile.path) {
            let gone = (try? FileManager.default.removeItem(at: i.switchFile)) != nil
            Out.log("\(gone ? "removed" : "could not remove") the debugging switch file for \(Diagnostic.text(i.name))")
        }
    }

    /// A Steam update replaces the client directory and the file with it, so it is put back every time rather than trusted.
    @discardableResult
    static func ensureSwitchFiles() -> Bool {
        let installs = all
        for i in installs where !FileManager.default.fileExists(atPath: i.switchFile.path) {
            let made = FileManager.default.createFile(atPath: i.switchFile.path, contents: Data())
            Out.log("\(made ? "created" : "could not create") the debugging switch file for \(Diagnostic.text(i.name))")
        }
        return !installs.isEmpty
    }

    /// The Mac client's processes, or Wine's steam.exe (macOS lists it as an application named after the executable).
    static func isSteamProcess(_ app: NSRunningApplication) -> Bool {
        let path = (app.executableURL?.path ?? "").lowercased()
        if path.hasSuffix("/steam_osx") || app.bundleIdentifier == steamBundle || app.localizedName == "Steam Helper" { return true }
        return (app.localizedName ?? "").lowercased() == "steam.exe"
    }

    /// Which install a restart acts on: the one running, else the first found.
    static var toRestart: SteamInstall? {
        let installs = all
        let running = NSWorkspace.shared.runningApplications.filter(isSteamProcess)
        if running.contains(where: { ($0.localizedName ?? "").lowercased() == "steam.exe" }),
           let bottle = installs.first(where: { if case .bottle = $0 { return true } else { return false } }) { return bottle }
        if running.contains(where: { $0.bundleIdentifier == steamBundle || ($0.executableURL?.path ?? "").hasSuffix("/steam_osx") }),
           installs.contains(where: { if case .mac = $0 { return true } else { return false } }) { return .mac }
        return installs.first
    }
}

enum SteamRestart {
    /// Quits Steam and starts it again with the port enabled. Says what it is doing.
    static func run() {
        guard let install = SteamInstall.toRestart else { Out.say(String(localized: "Steam does not seem to be installed.", bundle: turnOverApp, comment: "Steam speech")); return }
        SteamInstall.ensureSwitchFiles()
        switch install {
        case .mac: restartMac()
        case .bottle(let name, let exe): restartBottle(named: name, steamExe: exe)
        }
    }

    private static func restartMac() {
        let location = NSWorkspace.shared.urlForApplication(withBundleIdentifier: steamBundle) ?? URL(fileURLWithPath: "/Applications/Steam.app")
        guard FileManager.default.fileExists(atPath: location.path) else { Out.say(String(localized: "Steam does not seem to be installed.", bundle: turnOverApp, comment: "Steam speech")); return }
        let running = NSWorkspace.shared.runningApplications.first { app in
            let path = (app.executableURL?.path ?? "").lowercased()
            return path.hasSuffix("/steam_osx") || app.bundleIdentifier == steamBundle
        }
        running?.terminate()
        Out.log("Steam restart: asked \(running == nil ? "nothing" : "Steam") to quit; relaunching")
        Out.say(running == nil ? String(localized: "Starting Steam.", bundle: turnOverApp, comment: "Steam speech") : String(localized: "Restarting Steam. It takes a few seconds.", bundle: turnOverApp, comment: "Steam speech"))
        // Long enough for Steam to finish shutting down; a second copy on top of a dying one is how you get two.
        DispatchQueue.main.asyncAfter(deadline: .now() + (running == nil ? 0.2 : 6.0)) {
            let c = NSWorkspace.OpenConfiguration(); c.activates = true
            NSWorkspace.shared.openApplication(at: location, configuration: c) { _, error in
                DispatchQueue.main.async {
                    if let error { Out.log("Steam restart failed: \(Diagnostic.error(error))"); Out.say(String(localized: "Could not start Steam: \(error.localizedDescription)", bundle: turnOverApp, comment: "The Steam program's message")) }
                    else { Out.log("Steam is starting") }
                }
            }
        }
    }

    /// The Windows client in a bottle: the quit is forced (it ignores every polite request), and the relaunch goes
    /// through CrossOver's app so the Wine server it gets can reach the network and the screen.
    private static func restartBottle(named name: String, steamExe: URL) {
        guard let crossOver = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SteamInstall.crossOverBundle) else {
            Out.say(String(localized: "CrossOver is not installed, so Steam in the \(name) bottle cannot be started.", bundle: turnOverApp, comment: "Steam speech: %@ is a CrossOver bottle")); return
        }
        let running = NSWorkspace.shared.runningApplications.filter { ($0.localizedName ?? "").lowercased() == "steam.exe" }
        for app in running { app.forceTerminate() }
        // Its web helpers are separate Wine processes that outlive it and keep the port.
        let sweep = Process()
        sweep.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        sweep.arguments = ["-9", "-f", "steamwebhelper.exe"]
        try? sweep.run()
        Out.log("Steam restart (\(Diagnostic.text(name)) bottle): force-quit \(running.count) process(es); relaunching through CrossOver")
        Out.say(running.isEmpty ? String(localized: "Starting Steam in the \(name) bottle.", bundle: turnOverApp, comment: "The Steam program's message") : String(localized: "Restarting Steam in the \(name) bottle. It takes a few seconds.", bundle: turnOverApp, comment: "The Steam program's message"))
        DispatchQueue.main.asyncAfter(deadline: .now() + (running.isEmpty ? 0.2 : 4.0)) {
            let c = NSWorkspace.OpenConfiguration(); c.activates = true
            NSWorkspace.shared.open([steamExe], withApplicationAt: crossOver, configuration: c) { _, error in
                DispatchQueue.main.async {
                    if let error { Out.log("Steam restart (\(Diagnostic.text(name)) bottle) failed: \(Diagnostic.error(error))"); Out.say(String(localized: "Could not start Steam in the \(name) bottle: \(error.localizedDescription)", bundle: turnOverApp, comment: "The Steam program's message")) }
                    else { Out.log("Steam in the \(Diagnostic.text(name)) bottle is starting") }
                }
            }
        }
    }
}

// MARK: - Starting

func selfTest() -> Int32 {
    var failed = 0
    func expect(_ got: BigPictureEvent, _ want: BigPictureEvent, _ line: Int = #line) {
        if got != want { failed += 1; FileHandle.standardError.write(Data("line \(line): got \(got), wanted \(want)\n".utf8)) }
    }
    expect(bigPictureEvent(#"{"name":"Library","role":"tab","state":""}"#), .speak("Library, tab"))
    expect(bigPictureEvent(#"{"name":"Play","role":"button","state":""}"#), .speak("Play"))
    expect(bigPictureEvent(#"{"name":"Volume","role":"slider","state":"80"}"#), .speak("Volume, slider, 80"))
    expect(bigPictureEvent(#"{"name":"Hades II","role":"","state":"selected","blurb":"Defy the god of the dead"}"#),
           .speak("Hades II, selected. Defy the god of the dead"))
    expect(bigPictureEvent(#"{"name":"","role":"checkbox","state":"on"}"#), .speak(", checkbox, on"))
    expect(bigPictureEvent(#"{"focusGone":true}"#), .focusGone)
    expect(bigPictureEvent(#"{"skipped":true,"tag":"DIV","cls":"x","text":""}"#), .skipped("tag=[3 characters] cls=[1 characters] text=[0 characters]"))
    expect(bigPictureEvent(#"{"skipped":true,"tag":"SECRET","cls":"private account","text":"private message"}"#),
           .skipped("tag=[6 characters] cls=[15 characters] text=[15 characters]"))
    expect(bigPictureEvent(#"{"name":"","role":"","state":""}"#), .nothing)
    expect(bigPictureEvent("not json"), .nothing)
    func expectText(_ got: String, _ want: String, _ line: Int = #line) {
        if got != want { failed += 1; FileHandle.standardError.write(Data("line \(line): got \(got), wanted \(want)\n".utf8)) }
    }
    expectText(Diagnostic.page("secret"), "page [6 characters]")
    expectText(Diagnostic.observer(in: "secret", result: ["result": ["value": "installed v11"]]),
               "observer in page [6 characters]: installed v11")
    expectText(Diagnostic.observer(in: "secret", result: ["result": ["value": "private message"]]),
               "observer in page [6 characters]: [15 characters]")
    expectText(Diagnostic.observer(in: "secret", result: ["exceptionDetails": ["text": "private error"]]),
               "observer in page [6 characters]: no installation acknowledgement")
    expectText(Diagnostic.error(NSError(domain: "private domain", code: -1001, userInfo: [NSLocalizedDescriptionKey: "private URL"])),
               "error code -1001")
    print(failed == 0 ? "steam-speech self-test: all passed" : "steam-speech self-test: \(failed) failed")
    return failed == 0 ? 0 : 1
}

let args = CommandLine.arguments
if args.contains("--self-test") { exit(selfTest()) }
if args.contains("--remove-switch-files") { SteamInstall.removeSwitchFiles(); exit(0) }
let webPort = args.firstIndex(of: "--web-port").flatMap { args.indices.contains($0 + 1) ? UInt16(args[$0 + 1]) : nil } ?? 9223

var bigPicture: BigPictureReader?
if !args.contains("--no-big-picture") { bigPicture = BigPictureReader(); bigPicture?.start() } else { SteamInstall.removeSwitchFiles() }
// Electron games load their own files (file://, app://), never http: a browser or an Electron app started with the
// same debugging port would otherwise get the script in every tab, and its pages read aloud (16 Oct 2026).
let web = DevToolsReader(port: webPort, name: "web", binding: "speechBridge", script: Scripts.liveRegions,
                         attach: { $0.type == "page" && !($0.url ?? "").lowercased().hasPrefix("http") }, gate: { _ in true }, every: 2.0) { payload, _ in Out.say(payload) }
web.start()
Out.log("started (Big Picture \(bigPicture == nil ? "off" : "on"), web games on port \(webPort))")

// Commands from TurnOver, a line each; standard input closing means TurnOver has gone.
var pendingInput = Data()
FileHandle.standardInput.readabilityHandler = { h in
    let d = h.availableData
    DispatchQueue.main.async {
        if d.isEmpty { Out.log("TurnOver has gone; stopping"); exit(0) }
        pendingInput.append(d)
        while let nl = pendingInput.firstIndex(of: 0x0A) {
            let line = String(decoding: pendingInput[pendingInput.startIndex..<nl], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            pendingInput.removeSubrange(pendingInput.startIndex...nl)
            switch line {
            case "status": Out.line("T", [bigPicture?.status ?? "Not reading Big Picture.", web.portIsUp ? "A web game is connected on port \(webPort)." : ""].filter { !$0.isEmpty }.joined(separator: " "))
            case "restart-steam": SteamRestart.run()
            case let l where l.hasPrefix("key "):
                let parts = l.split(separator: " ")
                if parts.count == 3, let vk = Int(parts[2]) { bigPicture?.forwardKey(String(parts[1]), vk: vk) }
            case "": break
            default: Out.log("unknown command: \(Diagnostic.text(line))")
            }
        }
    }
}
signal(SIGTERM, SIG_DFL)
RunLoop.main.run()
