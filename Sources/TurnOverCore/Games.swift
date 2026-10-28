// SPDX-License-Identifier: GPL-3.0-or-later
// Games: Steam and Windows games speaking through TurnOver.
//
// Moved into TurnOver on 8 Oct 2026 from two separate apps of September 2026, SpeechBridge Listener and Steam
// Speak, which spoke through VoiceOver by Apple event. TurnOver leads in these processes instead (LeadWatcher asks
// Games.isGame), so its own voice speaks: one voice, and it can be cut off. Two sources of words:
//  1. The Steam program, a separate open helper (github.com/TurnOver-For-Mac/turnover-plugins, helpers/steam-speech;
//     built into TurnOver.app/Contents/Helpers): Steam's Big Picture through Steam's debugging port, and Steam
//     games built on Electron. TurnOver starts it without TurnOver's permissions (DisclaimedSpawn) and speaks the
//     lines it writes ("S", "I", "X"); it quits when TurnOver goes (its input closes). Open since 14 Oct 2026 (so
//     people should be able to read what it does).
//  2. The speech port (SpeechPort.swift, 18 Oct 2026; the game bridge before it): games in a CrossOver bottle talk
//     to SpeechBridge's stand-in speech DLLs, which send "S <text>" and "X" lines to 127.0.0.1:52134, as any app may,
//     once the user has said it can.
// Steam is one of TurnOver's own apps (15 Oct 2026): (1) is built in and never named to users as a plugin
// or as "Steam speech"; TurnOver simply works with Steam, as it does with Word.
import Foundation
import AppKit
import Network

extension Config {
    public struct Games: Codable {
        /// The readers run whenever the Mac has the Games menu at all. A switch until 25 Oct 2026, when it went: Steam
        /// itself says when it is asked to open its port, so an off position only hid speech. Read from old files, unused.
        public var enabled = true
        /// Attach to Steam's debugging port and read Big Picture. Off until chosen: it makes Steam open a debugging port
        /// on this Mac that any program here could use (a code review on 20 Oct 2026). Stored under a new name, so a
        /// saved "on" from before, when it was the default, isn't taken as a choice.
        public var readBigPicture = false
        public var bridgePort = 52134
        public var webPort = 9223
        public init() {}
        enum Keys: String, CodingKey { case enabled, readBigPicture = "readBigPictureChosen", bridgePort, webPort }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            let d = Games()
            enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
            readBigPicture = (try? c.decodeIfPresent(Bool.self, forKey: .readBigPicture)) ?? d.readBigPicture
            bridgePort = (try? c.decodeIfPresent(Int.self, forKey: .bridgePort)) ?? d.bridgePort
            webPort = (try? c.decodeIfPresent(Int.self, forKey: .webPort)) ?? d.webPort
        }
        /// Written by hand too: the synthesised encoder ignores `Keys` and wrote the old name, so the choice was read
        /// back as unmade at every start (20 Oct 2026: "will I have to turn Steam reading on each reboot?").
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(enabled, forKey: .enabled)
            try c.encode(readBigPicture, forKey: .readBigPicture)
            try c.encode(bridgePort, forKey: .bridgePort)
            try c.encode(webPort, forKey: .webPort)
        }
    }
}

public enum Games {
    /// the maintainer's Mac: `defaults write com.turnover.reader games -bool true` (everything, the CrossOver bridge too).
    /// Anyone's Mac: Big Picture and Electron games, built in (the bridge needs SpeechBridge's stand-in files,
    /// which testers don't have). 15 Oct 2026: Steam is one of TurnOver's own apps, "a good example of
    /// doing something VoiceOver can't", so no plugin is needed; the old steam-speech plugin is gone from the
    /// library and one copied in by hand does nothing. `ownSetup` (the "games" default) still adds CrossOver games on the maintainer's Mac.
    public static var available: Bool { true }
    static var ownSetup: Bool { UserDefaults.standard.bool(forKey: "games") }
    /// Kept from the last plugin reload: an official plugin with "provides": "games", installed from the library.
    public private(set) static var byPlugin = false

    /// Whether these plugins switch game speech on: "provides": "games" from the library at the Official level, its
    /// receipt naming the same plugin. (Copied in by hand, or Community, it does nothing.)
    public static func providesGames(_ plugins: [LoadedPlugin]) -> Bool {
        plugins.contains { p in
            guard p.manifest?.provides == "games", let r = PluginLibrary.receipt(p.folder) else { return false }
            return r.level == "Official" && r.id == p.manifest?.id
        }
    }

    /// After the plugins reload: logged only; the readers no longer depend on a plugin.
    public static func pluginsChanged(_ plugins: [LoadedPlugin]) {
        let on = providesGames(plugins)
        let ignored = plugins.contains { $0.manifest?.provides != nil } && !on
        if ignored { Log.info("games: a plugin claims to provide game speech; Steam is TurnOver's own, so it's ignored") }
        guard on != byPlugin else { return }
        byPlugin = on
        Log.info("games: a leftover plugin from before Steam was TurnOver's own is \(on ? "installed" : "gone"); nothing changes")
    }
    /// Whether game processes are TurnOver's and the readers should run.
    public static var active: Bool { available }
    public static var running: Bool { started }
    private static var started = false

    private static var steam: SteamHelper?

    public static func startIfWanted() {
        guard available else { return }
        start()
    }

    public static func start() {
        watchFront()
        guard !started else { return }
        started = true
        let g = config.games
        steam = SteamHelper(); steam?.start(bigPicture: g.readBigPicture, webPort: g.webPort)
        Log.info("games: on (Steam: Big Picture \(g.readBigPicture ? "on" : "off"), web games on \(g.webPort))")
    }

    public static func stop() {
        started = false
        steam?.stop(); steam = nil
        Log.info("games: off")
    }

    /// Big Picture on or off: the helper is started again with the new choice.
    static func restartBigPicture() {
        guard running else { return }
        steam?.stop()
        steam = SteamHelper(); steam?.start(bigPicture: config.games.readBigPicture, webPort: config.games.webPort)
    }

    /// Said from the menu: the bridge's state now, the Steam program's when it answers.
    static func sayStatus() {
        guard available else { Speech.speakMessage("Games are not set up on this Mac."); return }
        guard running else { Speech.speakMessage(ownSetup ? "Game speech is off." : "Steam reading is off."); return }
        let bridgeStatus = SpeechPort.shared.status
        guard let steam, steam.isRunning else { Speech.speakMessage([bridgeStatus, "The Steam program is not running."].filter { !$0.isEmpty }.joined(separator: " ")); return }
        steam.askStatus { Speech.speakMessage([bridgeStatus, $0].filter { !$0.isEmpty }.joined(separator: " ")) }
    }

    /// Steam's menu opened from the keyboard shows without the keyboard: no page in it hears the keys (recorded
    /// 14 Oct 2026; VoiceOver meets it too). The menu is drawn inside Big Picture's window, and Steam gives it the
    /// keys only when that window becomes active again: switching away and back fixed it; a Tab only put
    /// the keys in the page behind. So TurnOver makes that switch itself, unseen (AppWake), while Steam is in front.
    /// A symptom fix: the cause is Steam's routing of keys between its own pages.
    /// Big Picture's main menu is open without the Mac's keyboard (the reader's R): TurnOver's arrows, Return,
    /// Escape and Tab go into the menu's page through the reader instead (15 Oct 2026: switching apps and back
    /// never gave the menu the keys; keys sent into the page do). Read on the keyboard thread: a lock.
    /// Steam has the front: its menu's keys are forwarded only then. Another app coming forward ends the claim
    /// (Command-Tab away with the menu open left the arrows going to Steam from every app: code review, 16 Oct 2026).
    /// Steam or its helper (Big Picture's own process is the helper: the menu keys never went in while it was in
    /// front, 16 Oct 2026).
    public static var steamInFront: Bool { let b = NSWorkspace.shared.frontmostApplication?.bundleIdentifier; return b == steamBundle || b == steamHelperBundle }
    private static var frontObserver: NSObjectProtocol?
    static func watchFront() {
        guard frontObserver == nil else { return }
        frontObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let front = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                if front != steamBundle, front != steamHelperBundle, menuNeedsKeys { menuNeedsKeys = false; Log.io("games: Steam's menu keys released; another app has the front") }
            }
        }
    }
    nonisolated(unsafe) private static var _menuNeedsKeys = false
    private static let menuLock = NSLock()
    public static var menuNeedsKeys: Bool {
        get { menuLock.lock(); defer { menuLock.unlock() }; return _menuNeedsKeys }
        set { menuLock.lock(); _menuNeedsKeys = newValue; menuLock.unlock() }
    }
    static let menuKeys: [(gesture: String, key: String, vk: Int)] = [
        ("downArrow", "ArrowDown", 40), ("upArrow", "ArrowUp", 38), ("leftArrow", "ArrowLeft", 37), ("rightArrow", "ArrowRight", 39),
        ("enter", "Enter", 13), ("numpadEnter", "Enter", 13), ("escape", "Escape", 27), ("tab", "Tab", 9),
    ]
    public static func forwardMenuKey(_ key: String, vk: Int) {
        guard let steam, steam.isRunning else { return }
        Log.io("games: \(key) into Steam's menu page")
        steam.send("key \(key) \(vk)")
        if key == "Enter" || key == "Escape" { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { menuNeedsKeys = false } }
    }

    static func menuLostKeyboard() {
        guard active, let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == steamHelperBundle || front.bundleIdentifier == steamBundle else {
            Log.info("games: Steam's menu has no keyboard, but Steam isn't in front; left alone"); return
        }
        if !menuNeedsKeys { Log.info("games: Steam's menu has no keyboard; TurnOver's arrows, Return, Escape and Tab go into it") }
        menuNeedsKeys = true
    }

    static func restartSteam() {
        guard let steam, steam.isRunning else { Speech.speakMessage("Turn Steam reading on first: the Steam program restarts Steam."); return }
        steam.send("restart-steam")
    }

    public static func menuItems() -> [MenuItem] {
        [
            MenuItem("Read Steam's Big Picture", .toggle(get: { config.games.readBigPicture }, set: { config.games.readBigPicture = $0; restartBigPicture() }),
                     hint: "Makes Steam open a debugging port on this Mac while it runs, which other programs here could use too. Off removes it"),
            MenuItem("What the game reader is doing", .action { sayStatus() }),
            MenuItem("Restart Steam so Big Picture can be read", .action { restartSteam() }),
        ]
    }

    // MARK: Which processes are games

    public static let steamBundle = "com.valvesoftware.steam"
    /// Big Picture's window belongs to Steam Helper, a separate app: led and announced like Steam itself (a tester's
    /// Mac, reading "TurnOver in its apps", left VoiceOver on there and every Big Picture line was dropped; 14 Oct 2026).
    public static let steamHelperBundle = "com.valvesoftware.steam.helper"

    /// A key the lead watcher can pin and list: the bundle identifier, or "game:<name>" for a Wine process, which has
    /// no bundle at all (CrossOver runs each program through a bare loader stub named after it).
    public static func leadKey(for app: NSRunningApplication) -> String? {
        guard isGame(app) else { return nil }
        return app.bundleIdentifier ?? "game:\(app.localizedName ?? "wine")"
    }

    public static func leads(_ key: String) -> Bool { active && (key == steamBundle || key == steamHelperBundle || key.hasPrefix("game:") || key.hasPrefix("com.notproton.launcher.")) }

    public static func isGame(_ app: NSRunningApplication) -> Bool {
        guard active else { return false }
        if app.bundleIdentifier == steamBundle || app.bundleIdentifier == steamHelperBundle { return true }
        // NotProton runs each game through a launcher bundle of its own (com.notproton.launcher.<appid>), so the
        // game's process has a bundle identifier after all (8 Oct 2026).
        if let b = app.bundleIdentifier { return b.hasPrefix("com.notproton.launcher.") }   // CrossOver's own app and every ordinary app: no
        return isWineProcess(name: app.localizedName ?? "", path: app.executableURL?.path ?? "")
    }

    /// Pure, for the tests: a Wine program under CrossOver runs from a per-session winetemp folder, or is "wine".
    nonisolated public static func isWineProcess(name: String, path: String) -> Bool {
        let n = name.lowercased()
        return path.contains("/winetemp-") || path.contains("/CrossOver") || path.contains("/notproton/") || n.hasSuffix(".exe") || n == "wine" || n == "wine64-preloader"
    }

    // MARK: Speaking

    private static var droppedWarnedAt = Date.distantPast

    /// Through TurnOver's own voice, shown on the braille display too. While VoiceOver is on (TurnOver not leading,
    /// the game not in front) the line is dropped, and the log says so once a minute.
    static func say(_ text: String, interrupting: Bool, from source: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        // Coexisting, VoiceOver is always on; TurnOver being active for the game is the test (16 Oct 2026).
        if NSWorkspace.shared.isVoiceOverEnabled, !(Coexist.on && Core.active) {
            if Date().timeIntervalSince(droppedWarnedAt) > 60 {
                droppedWarnedAt = Date()
                Log.info("games (\(source)): VoiceOver is on, so game speech is dropped until TurnOver leads: \(Log.words(String(t.prefix(80))))")
            }
            return
        }
        // Never over Apple's apps or a browser: the web games' port takes lines from any program on this Mac, which
        // could otherwise speak in TurnOver's voice over Mail or a sign-in page (a code review on 20 Oct 2026). A
        // game is Steam, a Wine game, or an Electron game (an ordinary app, so only those two kinds are ruled out).
        if let front = NSWorkspace.shared.frontmostApplication, !isGame(front), !Self.mayBeWebGame(front.bundleIdentifier ?? "") {
            Log.io("games (\(source)): a line dropped, no game in front (\(front.bundleIdentifier ?? "?"))")
            return
        }
        if Speech.logsWords { Log.io("games (\(source)): \(t.prefix(160))") } else { Log.io("games (\(source)): [\(t.count) characters]") }   // friends' names and chat (code review, 16 Oct 2026)
        if interrupting { Speech.cancel() }
        Speech.speakNews(t)
    }

    // MARK: Pure parts

    /// An app an Electron game could be: not one of Apple's and not a browser.
    nonisolated public static func mayBeWebGame(_ bundle: String) -> Bool {
        let browsers: Set<String> = ["com.google.chrome", "org.mozilla.firefox", "com.brave.browser", "com.microsoft.edgemac",
                                     "company.thebrowser.browser", "com.operasoftware.opera", "com.vivaldi.vivaldi", "com.kagi.kagimacos"]
        let b = bundle.lowercased()
        return !b.isEmpty && !b.hasPrefix("com.apple.") && !browsers.contains(b)
    }

    public enum BridgeCommand: Equatable { case speak(String), stop, ignored }

    /// The bridge's line protocol: "S <text>" speaks, "X" stops. Anything else is ignored (and logged by the bridge).
    public static func bridgeCommand(_ raw: String) -> BridgeCommand {
        let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        if line == "X" { return .stop }
        if line.hasPrefix("S ") || line == "S" {
            let text = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? .ignored : .speak(text)
        }
        return .ignored
    }

    /// What the speech port does with a line from an app the user trusts, given whether that app is the one in front:
    /// pure, for the tests. Neither speaking nor stopping happens from an app in the background (a stop from one could
    /// cut TurnOver off mid-sentence in Mail: an outside review, 18 Oct 2026).
    public enum BridgeAction: Equatable { case speak(String), stop, dropped, ignored }
    public static func bridgeAction(_ raw: String, speakerInFront: Bool) -> BridgeAction {
        switch bridgeCommand(raw) {
        case .ignored: return .ignored
        case .stop: return speakerInFront ? .stop : .dropped
        case .speak(let text): return speakerInFront ? .speak(text) : .dropped
        }
    }
}

// MARK: - The Steam program (the open helper)

/// Lines from a helper's output, which a pipe delivers in pieces: a line cut across two reads comes out whole, once.
/// A line longer than a megabyte without an end is dropped rather than kept growing.
nonisolated public struct HelperLines {
    private var pending = Data()
    public init() {}
    public mutating func add(_ data: Data) -> [String] {
        pending.append(data)
        var out: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            out.append(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...nl)
        }
        if pending.count > 1_000_000 { pending.removeAll() }
        return out
    }
}

/// The Steam program (helpers/steam-speech in the public repo), started without TurnOver's permissions, read a line at a time.
final class SteamHelper {
    nonisolated(unsafe) private static var live: [pid_t: SteamHelper] = [:]   // main thread only
    private var child: DisclaimedSpawn.Child?
    private var lines = HelperLines()
    private var statusWaiters: [(String) -> Void] = []
    private var stopping = false
    private var startedAt = Date()
    private var restarts = 0
    private var bigPicture = true
    private var webPort = 9223
    var isRunning: Bool { child != nil }

    /// Built from helpers/steam-speech in the public plugins repository and signed with TurnOver (build.sh).
    static var path: String? {
        let p = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/steam-speech").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    func start(bigPicture: Bool, webPort: Int) {
        self.bigPicture = bigPicture; self.webPort = webPort; stopping = false
        guard let path = Self.path else { Log.warning("games: the Steam program is missing from TurnOver.app"); return }
        var args = ["--web-port", String(webPort)]
        if !bigPicture { args.append("--no-big-picture") }
        let pidBox = Locked(pid_t(0))   // set once it has started; the end is matched to this program by it
        let ended: @Sendable (Int32) -> Void = { status in
            let pid = pidBox.value
            DispatchQueue.main.async { MainActor.assumeIsolated { SteamHelper.ended(pid: pid, status: status) } }
        }
        guard let (child, disclaimed) = DisclaimedSpawn.run(path, arguments: args, directory: nil, exited: ended) else {
            Log.warning("games: the Steam program could not start"); return
        }
        self.child = child; startedAt = Date()
        let pid = child.pid
        pidBox.value = pid
        Self.live[pid] = self
        child.stdout.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { SteamHelper.live[pid]?.received(d) } }
        }
        child.stderr.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            let text = String(decoding: d, as: UTF8.self)
            DispatchQueue.main.async { Log.info("steam speech (errors): \(text.prefix(300))") }
        }
        Log.info("games: Steam program started (pid \(pid)\(disclaimed ? ", without TurnOver's permissions" : "; WARNING: it may have TurnOver's permissions"))")
    }

    /// The program ended. Stopped on purpose: nothing. Otherwise started again, unless it keeps dying at once.
    private static func ended(pid: pid_t, status: Int32) {
        guard let helper = live.removeValue(forKey: pid) else { return }
        helper.child = nil
        for w in helper.statusWaiters { w("The Steam program stopped.") }
        helper.statusWaiters.removeAll()
        guard !helper.stopping else { return }
        Log.warning("games: the Steam program ended (status \(status))")
        if Date().timeIntervalSince(helper.startedAt) > 60 { helper.restarts = 0 }
        guard helper.restarts < 3 else { Log.warning("games: the Steam program keeps ending; left off"); return }
        helper.restarts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard !helper.stopping, helper.child == nil else { return }
            helper.start(bigPicture: helper.bigPicture, webPort: helper.webPort)
        }
    }

    private func received(_ data: Data) {
        for line in lines.add(data) {
            let kind = line.prefix(1), rest = line.count > 2 ? String(line.dropFirst(2)) : ""
            // "S Library\tMainMenu_uid2": the words, then the page they came from (for the log only).
            let parts = rest.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            let text = parts.first.map(String.init) ?? "", page = parts.count > 1 ? "Steam, \(parts[1])" : "Steam"
            switch kind {
            case "S", "I":
                // A highlight on a page other than the menu: the menu has gone, or the page has the keys again.
                if !page.contains("MainMenu"), Games.menuNeedsKeys { Games.menuNeedsKeys = false; Log.io("games: Steam's menu closed; keys are Steam's again") }
                Games.say(text, interrupting: kind == "I", from: page)
            case "X": Speech.cancel()
            case "L": Log.info("steam speech: \(text.prefix(300))")
            case "R": Games.menuLostKeyboard()
            case "T":
                let waiting = statusWaiters; statusWaiters.removeAll()
                for w in waiting { w(text) }
            default: if !line.isEmpty { Log.info("steam speech: a line it doesn't know: \(Log.words(String(line.prefix(80))))") }
            }
        }
    }

    func send(_ command: String) {
        guard let child else { return }
        do { try child.stdin.write(contentsOf: Data((command + "\n").utf8)) } catch { Log.warning("games: couldn't reach the Steam program: \(error)") }
    }

    func askStatus(_ answer: @escaping (String) -> Void) {
        statusWaiters.append(answer)
        send("status")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.statusWaiters.isEmpty else { return }
            let waiting = self.statusWaiters; self.statusWaiters.removeAll()
            for w in waiting { w("The Steam program did not answer.") }
        }
    }

    /// Its input closed, it quits by itself; if it hasn't a second later, it is told to.
    func stop() {
        stopping = true
        guard let child else { return }
        try? child.stdin.close()
        let pid = child.pid
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if kill(pid, 0) == 0 { kill(pid, SIGTERM) } }
        Log.info("games: Steam program stopping (pid \(pid))")
    }
}

/// Bytes arriving on a connection, kept across its receive callbacks (all on the main queue).
nonisolated final class DataBox: @unchecked Sendable { var data = Data() }
