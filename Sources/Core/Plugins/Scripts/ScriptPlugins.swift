// SPDX-License-Identifier: GPL-3.0-or-later
// Plugin scripts joining TurnOver (docs/PLUGIN-SCRIPTS-PLAN.md, "How it joins TurnOver"; stage 3, 15 Nov 2026). A
// GlobalPlugin, registered in Core.start beside ProfilesPlugin only when `Edition.includesPluginScripts` is on. It
// - finds the loaded plugins that have scripts, and asks ScriptTrust whether each may run (no receipt, no script);
// - starts a plugin's host (ScriptHost, a sandboxed program) when one of its apps first comes to the front, pauses it
//   when none is in front, resumes it when one is, and stops it when its apps quit, the plugin goes or changes, or its
//   receipt is taken away;
// - carries each plugin's commands as scripts, as ProfilesPlugin carries a profile's keys;
// - passes on focus, value-change, app and window events, and nothing else: never a typed character or a caret move;
// - counts strikes, and turns a script off for this run after three in ten minutes.
// With the switch off none of this exists. With it on and no script for the app in front, an event costs one lookup.
import Foundation
import AppKit
import ApplicationServices

/// The words a script gave for the focus now being reported. Held only while the event runs on down the chain, for the
/// element they were given for; `TurnOverObject.reportFocus` asks, and says them in place of its own announcement.
package enum ScriptFocusWords {
    nonisolated(unsafe) package static var current: (element: AXUIElement, words: String)?   // main thread only, set and cleared around one event

    package static func held(for element: AXUIElement) -> String? {
        guard let held = current, held.element.isSame(element) else { return nil }
        return held.words
    }
}

package final class ScriptPlugins: GlobalPlugin {
    /// The running one (for the menu and the plugin layer's list); nil when scripts are off.
    nonisolated(unsafe) package static weak var current: ScriptPlugins?   // main thread only

    /// What TurnOver knows about one plugin that has a script.
    package final class Entry {
        package let id: String
        package var plugin: LoadedPlugin
        package var host: ScriptHost?
        var broker: AXScriptBroker?
        /// Bumped at each start and stop, so a late message from an older host is ignored.
        var generation = 0
        package var strikes: [Date] = []
        /// Off for this run of TurnOver, after three strikes (the menu can turn it on again).
        package var turnedOff = false
        var saidOff = false
        var everReady = false
        /// The files that failed to load: not started again until they change.
        package var failedHash: String?
        var saidFailureFor: String?
        var announceReload = false
        package var inFront = false
        init(_ plugin: LoadedPlugin) { id = plugin.manifest?.id ?? ""; self.plugin = plugin }
        var name: String { plugin.manifest?.name ?? id }
        var apps: [String] { plugin.manifest?.apps ?? [] }
        /// A focus or value event carries the item, so only a plugin that has `read` is sent one (15 Nov 2026).
        var mayRead: Bool { ScriptAbilities.effective(for: plugin).contains(.read) }
    }

    private let trust: ScriptTrustStore
    private let env: ScriptEnvironment
    package private(set) var entries: [String: Entry] = [:]
    private var byBundle: [String: [Entry]] = [:]
    private var ordered: [Entry] = []   // by id
    private var commandNames: [String] = []
    private var waitingNoticed = Set<String>()
    package private(set) var waitingNotices = 0
    private var approvalOpen = false
    private var heldSpeech: [String] = []   // what a host asked to be said while a question was open
    private var startupPending = true
    private var terminationObserver: NSObjectProtocol?
    /// After a hang no script runs for this run of TurnOver.
    package let blocked: Bool

    /// Whether an approval question is open: no script is heard meanwhile.
    package var questionIsOpen: Bool { approvalOpen }

    /// For TurnOver: the real Mac, the real trust file, and a hook on the plugins' reloads.
    package required init() {
        trust = .shared; env = .live(); blocked = env.afterHang
        super.init()
        ScriptPlugins.current = self
        Self.chainReload(onto: ProfileStore.shared) { [weak self] in DispatchQueue.main.async { self?.reloaded() } }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkQuit() }
        }
        reloaded()
    }

    /// ProfilesPlugin (registered first) keeps its own reload hook: `handler` runs after it, on each reload.
    package static func chainReload(onto store: ProfileStore, _ handler: @escaping () -> Void) {
        let previous = store.onReload
        store.onReload = { previous?(); handler() }
    }

    /// For a test: its own trust store (in memory) and its own picture of the Mac.
    package init(trust: ScriptTrustStore, environment: ScriptEnvironment) {
        self.trust = trust; env = environment; blocked = environment.afterHang
        super.init()
        reloaded()
    }

    override package func terminate() {
        entries.values.forEach(stop)
        if env.profiles.setScriptLive([:]) { env.profiles.livenessChanged() }   // nothing is approved once this is gone
        if let terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver) }
        terminationObserver = nil
        if ScriptPlugins.current === self { ScriptPlugins.current = nil }
    }

    // MARK: The plugins

    /// The loaded plugins changed (or this is the first look): who has a script now, and what changed.
    package func reloaded() {
        var seen = Set<String>()
        for plugin in env.plugins() where plugin.error == nil && plugin.script != nil {
            guard let manifest = plugin.manifest, manifest.script != nil else { continue }
            seen.insert(manifest.id)
            if let entry = entries[manifest.id] {
                let changed = entry.plugin.scriptHash != plugin.scriptHash
                entry.plugin = plugin
                if changed { scriptChanged(entry) }
            } else {
                entries[manifest.id] = Entry(plugin)
            }
        }
        for (id, entry) in entries where !seen.contains(id) { stop(entry); entries[id] = nil }   // the plugin was removed
        ordered = entries.values.sorted { $0.id < $1.id }
        byBundle = [:]
        for entry in ordered { for app in entry.apps { byBundle[app, default: []].append(entry) } }
        rebuildCommands()
        reconcileTrust()
    }

    /// A plugin's files changed: the old host goes. In developer mode a draft that may still run starts again at once
    /// and "reloaded", or its first error with the line, is said.
    private func scriptChanged(_ entry: Entry) {
        stop(entry)
        entry.strikes = []; entry.turnedOff = false; entry.saidOff = false; entry.everReady = false; entry.failedHash = nil
        guard trust.developerMode, trust.decision(for: entry.plugin).isAllowed, !blocked else { return }
        // Started even while its app is behind (the author is in an editor): it loads, says reloaded or its first error,
        // and waits paused until its app is in front.
        entry.inFront = isFront(entry)
        entry.announceReload = true
        start(entry)
    }

    /// Hosts whose receipt no longer holds go (taken away, developer mode off, a changed file).
    package func reconcileTrust() {
        for entry in entries.values where entry.host != nil && !trust.decision(for: entry.plugin).isAllowed { stop(entry) }
        // A plugin with a script is one thing: its profile is live only while its script may run (ProfileStore.livePlugins).
        var live: [String: String] = [:]
        for entry in entries.values where trust.decision(for: entry.plugin).isAllowed { live[entry.id] = entry.plugin.scriptHash }
        if env.profiles.setScriptLive(live) { env.profiles.livenessChanged() }
        for entry in entries.values where entry.host == nil && entry.inFront { arrived(entry) }
    }

    /// Hosts whose apps have all quit end.
    package func checkQuit() {
        for entry in entries.values where entry.host != nil && !entry.apps.contains(where: env.isRunning) { stop(entry); entry.inFront = false }
    }

    private func stop(_ entry: Entry) {
        entry.generation += 1
        entry.host?.stop()
        entry.host = nil; entry.broker = nil
    }

    private func isFront(_ entry: Entry) -> Bool {
        guard let pid = env.frontPid() else { return false }
        let bundle = env.bundle(pid)
        return !bundle.isEmpty && entry.apps.contains(bundle) && !AXScriptBroker.isForbiddenApp(bundle)
    }

    // MARK: Starting, pausing and the host's news

    private func start(_ entry: Entry) {
        guard entry.host == nil, !blocked, !entry.turnedOff, entry.failedHash == nil || entry.failedHash != entry.plugin.scriptHash,
              trust.decision(for: entry.plugin).isAllowed, let manifest = entry.plugin.manifest, let source = entry.plugin.script else { return }
        let broker = AXScriptBroker(pluginID: manifest.id, apps: manifest.apps, environment: env, questionOpen: { [weak self] in self?.approvalOpen ?? false })
        let host = ScriptHost(plugin: ScriptPluginInfo(id: manifest.id, name: manifest.name, version: manifest.version),
                              abilities: ScriptAbilities.effective(for: entry.plugin), commands: (manifest.commands ?? []).map(\.id), source: source,
                              language: Locale.current.language.languageCode?.identifier ?? "en", hostPath: env.hostPath, broker: broker, limits: env.limits,
                              sounds: env.soundNames())
        entry.generation += 1
        let generation = entry.generation
        entry.host = host; entry.broker = broker; entry.everReady = false
        host.onStateChange = { [weak self, weak entry] state in
            guard let self, let entry, entry.generation == generation else { return }
            self.hostChanged(entry, state)
        }
        host.onStrike = { [weak self, weak entry] strike in
            guard let self, let entry, entry.generation == generation else { return }
            self.struck(entry, strike)
        }
        host.start()
    }

    private func hostChanged(_ entry: Entry, _ state: ScriptHostState) {
        switch state {
        case .ready:
            entry.everReady = true
            if entry.announceReload { entry.announceReload = false; speakHost(entry, String(localized: "\(entry.name) script reloaded.", comment: "Said in developer mode when a plugin's script was saved and started again; the placeholder is the plugin's name")) }
            if entry.inFront { tell(entry, "appFocus") } else { entry.host?.pause() }
        case .failed(let message):
            entry.host = nil; entry.broker = nil
            guard !entry.everReady else { return }   // it ran and was stopped later: the strike says what comes next
            entry.failedHash = entry.plugin.scriptHash
            entry.announceReload = false
            if entry.saidFailureFor != entry.plugin.scriptHash {
                entry.saidFailureFor = entry.plugin.scriptHash
                speakHost(entry, String(localized: "The script of \(entry.name) did not load. \(String(message.prefix(200)))", comment: "Said once when a plugin's script fails to start; the placeholders are the plugin's name and the first error, with its line, in English"))
            }
        case .ended:
            entry.host = nil; entry.broker = nil
        case .starting, .paused: break
        }
    }

    /// Said because of something a host did (its first error, a failed command, a reload): never while an approval question is
    /// open (it is held until the question closes, a few at most), never longer than a sentence or two, and only while the
    /// plugin's app is in front, or, in developer mode, while its author works on it elsewhere.
    private func speakHost(_ entry: Entry, _ text: String) {
        let capped = String(text.prefix(300))
        if approvalOpen { if heldSpeech.count < 5 { heldSpeech.append(capped) }; return }
        guard entry.inFront || trust.developerMode else { return Log.info("script \(entry.id): not said, its app is not in front: \(Log.words(capped))") }
        env.speak(capped)
    }

    /// The question is over, however it ended: what was held for it is said now.
    private func closeApproval() {
        approvalOpen = false
        let held = heldSpeech
        heldSpeech = []
        held.forEach { env.speak($0) }
    }

    private func struck(_ entry: Entry, _ strike: ScriptStrike) {
        let now = Date()
        entry.strikes = (entry.strikes + [now]).filter { now.timeIntervalSince($0) < env.limits.strikeWindow }
        if entry.strikes.count >= env.limits.strikesAllowed { return turnOff(entry) }
        // A killed or crashed host is gone; the script still has strikes to spare, so it starts again if its app is in front.
        if case .lateAnswer = strike { return }
        DispatchQueue.main.async { [weak self, weak entry] in
            guard let self, let entry, entry.host == nil, entry.inFront else { return }
            self.start(entry)
        }
    }

    /// Three strikes in ten minutes: off for this run of TurnOver, and said once, by the plugin's name.
    package func turnOff(_ entry: Entry) {
        stop(entry)
        entry.turnedOff = true
        guard !entry.saidOff else { return }
        entry.saidOff = true
        env.speak(String(localized: "The script of \(entry.name) kept going wrong, so it is turned off until TurnOver starts again. You can turn it on again in the Plugins menu.", comment: "Said once when a plugin's script is turned off after three problems in ten minutes; the placeholder is the plugin's name"))
    }

    /// One of the plugin's apps came to the front.
    private func arrived(_ entry: Entry) {
        guard !blocked, !entry.turnedOff else { return }
        guard trust.decision(for: entry.plugin).isAllowed else { return noticeWaiting(entry) }
        if let host = entry.host { host.resume(); tell(entry, "appFocus") } else { start(entry) }
    }

    /// None of the plugin's apps is in front now.
    private func left(_ entry: Entry) {
        guard let host = entry.host else { return }
        tell(entry, "appBlur")
        host.pause()
    }

    private func tell(_ entry: Entry, _ event: String) {
        guard let host = entry.host, host.events.contains(event) else { return }
        host.tell(event)
    }

    /// The script is waiting for approval, said when its app comes to the front: once for a plugin, three notices at most
    /// in a run, in TurnOver's own words with the plugin's name inside. The plugin's own description is heard only inside the question.
    private func noticeWaiting(_ entry: Entry) {
        guard !waitingNoticed.contains(entry.id), waitingNotices < 3 else { return }
        waitingNoticed.insert(entry.id); waitingNotices += 1
        env.speak(String(localized: "\(entry.name) has a script waiting for approval. It will not run until you approve it in the Plugins menu.", comment: "Said once when an app comes to the front that has a plugin whose script is not approved; the placeholder is the plugin's name"))
    }

    // MARK: Events

    override package func handleEvent(_ event: Event, next: () -> Void) {
        switch event.kind {
        case .gainFocus, .valueChange, .foreground: break
        default: return next()   // a typed character, a caret move and everything else never reach a script
        }
        if startupPending { startupPending = false; scheduleStartupWords() }
        guard !entries.isEmpty else { return next() }
        let pid = event.obj.pid
        let bundle = env.bundle(pid)
        if event.kind != .valueChange { frontChanged(bundle: bundle, windowEvent: event.kind == .foreground) }
        guard !bundle.isEmpty, !approvalOpen, let list = byBundle[bundle], !AXScriptBroker.isForbiddenApp(bundle) else { return next() }
        switch event.kind {
        case .gainFocus:
            let name = "focus"
            for entry in list {
                guard entry.mayRead, let host = entry.host, host.events.contains(name), let item = entry.broker?.item(for: event.obj.element) else { continue }
                if case .say(let words) = host.ask(name, item: item) {
                    // The first plugin to give words wins. They are held for this element while the event goes on down the
                    // chain (the object does more than speak when it takes the focus), then let go.
                    ScriptFocusWords.current = (event.obj.element, words)
                    next()
                    ScriptFocusWords.current = nil
                    return
                }
            }
            next()
        case .valueChange:
            let name = "valueChange"
            if AXScriptBroker.isSecure(event.obj.element) { return next() }   // what is typed in a password field is never sent to any script
            for entry in list {
                guard entry.mayRead, let host = entry.host, host.events.contains(name), let item = entry.broker?.item(for: event.obj.element) else { continue }
                if case .say(let words) = host.ask(name, item: item) {
                    if !words.isEmpty { env.speak(words) }
                    return   // handled: the chain stops here, as a watch rule's does
                }
            }
            next()
        default:
            next()
        }
    }

    /// Which plugins have an app in front now: tell each what changed (an app arriving or leaving, or a new window).
    private func frontChanged(bundle: String, windowEvent: Bool) {
        for entry in ordered {
            let now = !bundle.isEmpty && entry.apps.contains(bundle) && !AXScriptBroker.isForbiddenApp(bundle)
            if now, !entry.inFront { entry.inFront = true; arrived(entry) }
            else if !now, entry.inFront { entry.inFront = false; left(entry) }
            else if now, windowEvent, !approvalOpen { tell(entry, "windowChange") }
        }
    }

    // MARK: At start

    /// What TurnOver says once, as it starts reading, so that an approval the person never gave is heard: how many
    /// scripts are on, and that developer mode is on. Nothing when no script may run and developer mode is off.
    package func startupWords() -> [String] {
        if blocked { return [String(localized: "TurnOver started again after it stopped responding, so plugin scripts are off until it starts again.", comment: "Said once when TurnOver restarts after a hang and plugin scripts are switched on")] }
        var out: [String] = []
        let on = entries.values.filter { trust.decision(for: $0.plugin).isAllowed }.count
        if on == 1 { out.append(String(localized: "1 plugin script is on.", comment: "Said once as TurnOver starts: one plugin script may run")) }
        else if on > 1 { out.append(String(localized: "\(String(on)) plugin scripts are on.", comment: "Said once as TurnOver starts: how many plugin scripts may run")) }
        if trust.developerMode { out.append(String(localized: "Developer mode for scripts is on.", comment: "Said once as TurnOver starts when developer mode for plugin scripts is on")) }
        return out
    }

    /// Queued (never interrupting) a moment after the first event: events only flow while TurnOver is reading, and
    /// its own start-up words are already waiting by then.
    private func scheduleStartupWords() {
        onMain(after: 2) { [weak self] in
            guard let self else { return }
            for words in self.startupWords() { self.env.speak(words) }
        }
    }

    // MARK: Commands

    private func rebuildCommands() {
        commandNames.forEach { removeScript($0) }
        commandNames.removeAll()
        for entry in ordered {
            guard let manifest = entry.plugin.manifest else { continue }
            let apps = Set(manifest.apps)
            for command in manifest.commands ?? [] {
                guard let key = command.key else { continue }
                let name = "plugin_\(manifest.id)_script_\(command.id)"
                let id = key.hasPrefix("kb") ? key : "kb:" + key
                script(name, command.description, gestures: [id], category: manifest.name) { [weak self, weak entry] _ in
                    if let self, let entry { self.run(command.id, of: entry) }
                }.isAvailable = { API.focusPid.map { apps.contains(ProfileStore.shared.bundle(of: $0)) } ?? false }
                commandNames.append(name)
            }
        }
    }

    /// The commands of the scripts working in an app, for the plugin layer (PluginCommands.forApp).
    package static func commands(for bundle: String) -> [(letter: String?, title: String, key: String, run: @MainActor () -> Void)] {
        current?.commandList(for: bundle) ?? []
    }

    package func commandList(for bundle: String) -> [(letter: String?, title: String, key: String, run: @MainActor () -> Void)] {
        var out: [(letter: String?, title: String, key: String, run: @MainActor () -> Void)] = []
        for entry in byBundle[bundle] ?? [] {
            for command in entry.plugin.manifest?.commands ?? [] {
                let key = command.key.map { GlobalCommands.spoken(normalizeGestureIdentifier($0.hasPrefix("kb:") ? $0 : "kb:" + $0)) } ?? ""
                out.append((command.letter?.lowercased(), command.description, key, { [weak self, weak entry] in
                    if let self, let entry { self.run(command.id, of: entry) }
                }))
            }
        }
        return out
    }

    /// A command was chosen (its key, or its letter in the plugin layer). If the host is not ready, say so in a few words.
    package func run(_ commandID: String, of entry: Entry) {
        func say(_ words: String) { env.speak(words) }
        if blocked { return say(String(localized: "Plugin scripts are off until TurnOver starts again.", comment: "Said when a script's command is chosen after a hang")) }
        if !trust.decision(for: entry.plugin).isAllowed {
            return say(String(localized: "\(entry.name) is waiting for approval in the Plugins menu.", comment: "Said when a command of a plugin whose script is not approved is chosen; the placeholder is the plugin's name"))
        }
        if entry.turnedOff { return say(String(localized: "The script of \(entry.name) is off after problems.", comment: "Said when a command of a script that was turned off is chosen; the placeholder is the plugin's name")) }
        guard let host = entry.host, case .ready = host.state, let broker = entry.broker else {
            if entry.host == nil, isFront(entry) { start(entry) }
            return say(String(localized: "The script of \(entry.name) is not ready yet.", comment: "Said when a command is chosen while its script is still starting; the placeholder is the plugin's name"))
        }
        var context: ScriptValue?
        if ScriptAbilities.effective(for: entry.plugin).contains(.read), let pid = env.frontPid(), let focus = env.focusedElement(pid) { context = broker.item(for: focus) }
        host.run(command: commandID, item: context) { [weak self] result in
            guard case .failed(let message) = result, let self else { return }
            Log.info("script \(entry.id): the command \(commandID) failed: \(Log.words(message))")
            self.speakHost(entry, self.trust.developerMode
                ? String(localized: "\(entry.name): \(message)", comment: "Said in developer mode when a script's command fails; the placeholders are the plugin's name and the script's own error")
                : String(localized: "\(entry.name) could not do that.", comment: "Said when a script's command fails; the placeholder is the plugin's name"))
        }
    }

    // MARK: Approval and the menu

    /// The question: what the script is and can do (TurnOver's own words, the author's marked as theirs), then the
    /// answers. No script is heard while it is open. Not now is first, so a quick Return never approves.
    package func askApproval(_ id: String) {
        guard let entry = entries[id] else { return }
        let plugin = entry.plugin
        // The signer is of the files this question is about (the ones loaded and to be hashed into the receipt), not of the folder as
        // it is now.
        let signature = ScriptTrust.signatureStatus(in: plugin.folder, loadedHash: plugin.scriptHash)
        let lines = ScriptAbilities.approvalLines(for: plugin, origin: .file, signature: signature).map(\.text)
        let title = (lines + [String(localized: "Approve it?", comment: "The question after what a plugin's script can do")]).joined(separator: " ")
        approvalOpen = true
        env.present(title, [
            MenuItem("Not now", .action { [weak self] in self?.closeApproval() }),
            MenuItem("Approve", .action { [weak self] in self?.approve(plugin, signature: signature) }),
        ]) { [weak self] in self?.closeApproval() }
    }

    /// Approve what was heard. The receipt's origin is a draft only if developer mode is on now.
    package func approve(_ plugin: LoadedPlugin, signature: ScriptTrust.SignatureStatus) {
        closeApproval()
        var signer: String?
        if case .valid(let fingerprint) = signature { signer = fingerprint }
        do { try trust.approve(plugin, origin: trust.developerMode ? .draft : .file, signer: signer) }
        catch {
            Log.warning("script approval for \(plugin.manifest?.id ?? "?") was not saved: \(error)")
            return env.speak(String(localized: "The approval could not be saved, so the script stays off.", comment: "Said when a plugin script's approval could not be written"))
        }
        env.speak(String(localized: "\(plugin.manifest?.name ?? "") script is on.", comment: "Said when a plugin's script is approved; the placeholder is the plugin's name"))
        reconcileTrust()
    }

    package func turnOffByMenu(_ entry: Entry) {
        // The script stops whether or not the revocation could be kept: a script the person turned off must not go on running. If it
        // could not be kept the store has let go of every approval for this run (ScriptTrustStore.latch), so every host stops.
        stop(entry)
        do { try trust.revoke(id: entry.id) } catch {
            reconcileTrust()
            return env.speak(String(localized: "The approval could not be taken away, so no script will run until TurnOver starts again.", comment: "Said when a plugin script's approval could not be removed: every script is stopped for this run"))
        }
        reconcileTrust()   // its profile goes dark with it
        env.speak(String(localized: "\(entry.name) script is off. It needs your approval to run again.", comment: "Said when a plugin's script is turned off from the menu; the placeholder is the plugin's name"))
    }

    package func turnOnAgain(_ entry: Entry) {
        entry.turnedOff = false; entry.saidOff = false; entry.strikes = []; entry.failedHash = nil
        env.speak(String(localized: "\(entry.name) script is on again.", comment: "Said when a plugin's script that was turned off after problems is started again; the placeholder is the plugin's name"))
        if isFront(entry) { entry.inFront = true; arrived(entry) }
    }

    package func setDeveloperMode(_ on: Bool) {
        do { try trust.setDeveloperMode(on) } catch {
            reconcileTrust()   // turning it off that could not be kept lets go of every approval for this run
            return env.speak(String(localized: "Developer mode for scripts could not be changed.", comment: "Said when the developer mode switch could not be saved"))
        }
        if on {
            env.speak(String(localized: "Developer mode for scripts is on. A script you approve now keeps running when you save changes to it, as long as it asks for no more apps or abilities. TurnOver says so each time it starts.", comment: "Said when developer mode for plugin scripts is turned on"))
        }
        reconcileTrust()
    }

    /// The Plugins menu's items for scripts.
    package static func menuItems() -> [MenuItem] { current?.items() ?? [] }

    package func items() -> [MenuItem] {
        var out: [MenuItem] = []
        for entry in entries.values.sorted(by: { $0.id < $1.id }) {
            let name = entry.name
            if blocked {
                out.append(MenuItem(verbatim: String(localized: "\(name), script off until TurnOver starts again", comment: "A plugin's script in the Plugins menu after a hang; the placeholder is the plugin's name"), .action { [weak self] in
                    self?.env.speak(String(localized: "Plugin scripts are off until TurnOver starts again.", comment: "Said when a script's menu item is chosen after a hang")) }))
            } else if entry.turnedOff {
                out.append(MenuItem(verbatim: String(localized: "\(name), script turned off after problems", comment: "A plugin's script in the Plugins menu, turned off after problems; the placeholder is the plugin's name"),
                                    .action { [weak self, weak entry] in if let self, let entry { self.turnOnAgain(entry) } },
                                    hint: String(localized: "Choose it to start the script again", comment: "A hint for a plugin's script that was turned off after problems")))
            } else if trust.decision(for: entry.plugin).isAllowed {
                out.append(MenuItem(verbatim: String(localized: "\(name), script on", comment: "A plugin's script in the Plugins menu, running; the placeholder is the plugin's name"),
                                    .action { [weak self, weak entry] in if let self, let entry { self.turnOffByMenu(entry) } },
                                    hint: String(localized: "Choose it to turn the script off and take your approval away", comment: "A hint for a plugin's script that is on")))
            } else {
                let id = entry.id
                out.append(MenuItem(verbatim: String(localized: "\(name), script waiting for approval", comment: "A plugin's script in the Plugins menu that has not been approved; the placeholder is the plugin's name"),
                                    .action { [weak self] in DispatchQueue.main.async { self?.askApproval(id) } },
                                    hint: String(localized: "Choose it to hear what the script can do, and approve it", comment: "A hint for a plugin's script waiting for approval")))
            }
        }
        out.append(MenuItem("Developer mode for scripts", .toggle(get: { [weak self] in self?.trust.developerMode ?? false }, set: { [weak self] in self?.setDeveloperMode($0) }),
                            hint: "A script you approve in developer mode starts again by itself when you save it, as long as it asks for no more"))
        return out
    }
}
