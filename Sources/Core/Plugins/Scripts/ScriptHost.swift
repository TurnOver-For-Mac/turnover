// SPDX-License-Identifier: GPL-3.0-or-later
// One plugin's script, running in its own sandboxed host program (docs/PLUGIN-SCRIPTS-PLAN.md, "Where a script
// runs", "Misbehaviour", "The wire"; 15 Nov 2026). TurnOver starts `turnover-plugin-host` with DisclaimedSpawn, sends
// it the script, and talks to it in JSON lines. This type is the only door: it checks every request against the
// plugin's abilities and the rates before the broker sees it, and watches the host program so a script that is slow,
// greedy or stuck is stopped and TurnOver carries on.
//
// Threads. The timed question blocks the calling (main) thread for at most the event deadline, so nothing it waits
// for may need main: the host's output is read on the pipe's own dispatch queue, which answers the question
// and applies the gates; only the broker's work is handed to main. Writes to the host go through a serial queue of
// their own, so a host that stops reading can never block the main thread; the watchdog kills it instead.
import Foundation
import Darwin
import TurnOverPluginWire

nonisolated public struct ScriptPluginInfo: Sendable, Equatable {
    public var id: String, name: String, version: String
    public init(id: String, name: String, version: String) { self.id = id; self.name = name; self.version = version }
}

nonisolated public enum ScriptHostState: Equatable, Sendable {
    case starting
    /// The script loaded: the events and commands it registered.
    case ready(events: [String], commands: [String])
    case paused
    /// The script did not load, or the host was killed or crashed. The message is in words for the author.
    case failed(String)
    case ended
}

/// What a script did wrong, for the strike count (a later stage counts them).
nonisolated public enum ScriptStrike: Equatable, Sendable {
    case killed(String)
    case crashed(String)
    case lateAnswer
}

/// The script's answer to a focus or value event.
nonisolated public enum ScriptAnswer: Equatable, Sendable {
    /// Neither said nor silenced (or no script is running to ask): TurnOver reads as usual.
    case unhandled
    /// Say these words in place of TurnOver's own; empty means say nothing.
    case say(String)
    /// Not answered within the deadline, or the host is still busy with an earlier question.
    case late
}

nonisolated public enum ScriptCommandResult: Equatable, Sendable {
    case done
    case failed(String)
}

/// Marked unchecked-Sendable because the compiler cannot see the discipline, which is: every stored property that
/// changes after `init` is read and written only with `lock` held (the main thread, the pipe's reading queue, the
/// exit-waiting thread and the watchdog queue all come here), the callbacks are called with the lock released,
/// and the writing queue touches only its own parameters.
nonisolated public final class ScriptHost: @unchecked Sendable {
    private final class Question: @unchecked Sendable {   // fields guarded by the host's `lock`
        let semaphore = DispatchSemaphore(value: 0)
        var answer: ScriptAnswer?
        var abandoned = false
    }
    private enum Work {
        case question(Question)
        case oneWayEvent
        case command(@MainActor (ScriptCommandResult) -> Void)
    }

    public let plugin: ScriptPluginInfo
    public let abilities: Set<ScriptAbility>
    public let limits: ScriptLimits
    private let declaredCommands: [String]
    private let source: String
    private let language: String
    private let hostPath: String
    private let broker: any ScriptBroker
    private let sounds: [String]

    private let lock = NSLock()
    private var _state = ScriptHostState.starting
    private var _events: [String] = []
    private var _commands: [String] = []
    private var _onStrike: (@MainActor (ScriptStrike) -> Void)?
    private var _onStateChange: (@MainActor (ScriptHostState) -> Void)?
    private var child: DisclaimedSpawn.Child?
    private var launched = false
    private var running = false
    private var stopRequested = false
    private var killedReason: String?
    private var startedAt: TimeInterval = 0
    private var pauseRequested = false
    private var nextID = 1
    private var open: [Int: (since: TimeInterval, work: Work)] = [:]
    private var lateQuestion: Int?
    private var outputFramer: LineFramer
    private var requestTimes: [TimeInterval] = []
    private var sayTimes: [TimeInterval] = []
    private var mainSpans: [(at: TimeInterval, took: TimeInterval)] = []
    private var cpuSamples: [(at: TimeInterval, cpu: TimeInterval)] = []
    private var queuedBytes = 0
    private var lineTimes: [TimeInterval] = []        // when each line from the host came, for the second just gone
    private var floodDrops: [TimeInterval] = []       // when a line was thrown away for coming too fast
    private var mainQueued = 0                        // requests accepted and not yet taken up by main
    private var lastLogged: [String: (at: TimeInterval, held: Int)] = [:]
    private var inputClosed = false                   // touched only on `writer`
    private var lastErrorText = ""
    private var watchdog: DispatchSourceTimer?
    private let writer: DispatchQueue

    public init(plugin: ScriptPluginInfo, abilities: Set<ScriptAbility>, commands: [String], source: String, language: String = "en",
                hostPath: String, broker: any ScriptBroker, limits: ScriptLimits = .standard, sounds: [String] = []) {
        self.plugin = plugin; self.abilities = abilities; self.declaredCommands = commands; self.source = source
        self.language = language; self.hostPath = hostPath; self.broker = broker; self.limits = limits; self.sounds = sounds
        outputFramer = LineFramer(maxBytes: limits.messageBytes)
        writer = DispatchQueue(label: "turnover.script-host.write.\(plugin.id)")
    }

    // MARK: Observing

    public var state: ScriptHostState { lock.lock(); defer { lock.unlock() }; return _state }
    /// The events the script registered (empty until it is ready).
    public var events: [String] { lock.lock(); defer { lock.unlock() }; return _events }
    /// The commands the script registered (empty until it is ready).
    public var commands: [String] { lock.lock(); defer { lock.unlock() }; return _commands }
    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    public var processID: pid_t? { lock.lock(); defer { lock.unlock() }; return child?.pid }
    /// Called on main for each kill, crash or late answer.
    public var onStrike: (@MainActor (ScriptStrike) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onStrike }
        set { lock.lock(); _onStrike = newValue; lock.unlock() }
    }
    /// Called on main when the state changes.
    public var onStateChange: (@MainActor (ScriptHostState) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onStateChange }
        set { lock.lock(); _onStateChange = newValue; lock.unlock() }
    }

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Starting and stopping

    /// Start the host program and send it the script. The state is `.starting` until it answers `ready` or `failed`.
    public func start() {
        lock.lock()
        guard !launched else { lock.unlock(); return }
        launched = true
        lock.unlock()
        guard source.utf8.count <= limits.scriptBytes else {
            return finish(failed: String(localized: "main.js is larger than \(limits.scriptBytes / 1024) KB, which is the most a script may be.", comment: "Said to a plugin author when a script is too large; the number is kilobytes"))
        }
        guard FileManager.default.isExecutableFile(atPath: hostPath) else {
            Log.warning("script host \(plugin.id): the host program is missing at \(hostPath)")
            return finish(failed: String(localized: "TurnOver's script program is missing, so scripts cannot run.", comment: "Said when the helper that runs plugin scripts is not in the app"))
        }
        // No environment: the host needs none, and TurnOver's own would hand it whatever the person's shell holds. Held, so the
        // end of the host is not heard until the host is known here (see `release` below).
        let spawned = DisclaimedSpawn.run(hostPath, arguments: [], directory: "/", environment: [], hold: true) { [self] status in processExited(status) }
        guard let (child, disclaimed) = spawned else {
            return finish(failed: String(localized: "TurnOver could not start its script program.", comment: "Said when starting the helper that runs plugin scripts fails"))
        }
        _ = fcntl(child.stdin.fileDescriptor, F_SETNOSIGPIPE, 1)   // a dead host is an error from write, not a signal that ends TurnOver
        lock.lock()
        self.child = child; running = true; startedAt = Self.now()
        lock.unlock()
        if !disclaimed { Log.warning("script host \(plugin.id): WARNING: the host may have TurnOver's permissions") }
        child.stdout.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            received(data)
        }
        child.stderr.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            lock.lock(); lastErrorText = String(text.prefix(300)); lock.unlock()
            logLimited("errors", "script host \(plugin.id) (errors): \(Log.words(String(text.prefix(300))))")
        }
        startWatchdog()
        child.releaseExit?()   // published and watched: an end from here on finds everything in place
        let hello: [String: Any] = [
            "t": PluginWire.ToHost.hello, "api": PluginWire.apiVersion,
            "plugin": ["id": plugin.id, "name": plugin.name, "version": plugin.version],
            "language": language, "abilities": abilities.map(\.rawValue).sorted(), "commands": declaredCommands,
            "limits": ["timers": limits.timers, "minimumTimerMilliseconds": limits.minimumTimerMilliseconds],
            "sounds": sounds,
            "source": source,
        ]
        guard let line = PluginWire.line(for: hello), line.count <= PluginWire.Limits.helloBytes else {
            return kill("the script could not be sent to its program", state: String(localized: "The script is too large to send to its program.", comment: "Said to a plugin author"))
        }
        write(line)
        Log.info("script host \(plugin.id): started (pid \(child.pid)\(disclaimed ? "" : ", WARNING not disclaimed"))")
    }

    /// Ask the host to end, and make sure it does: it is killed a second later if it is still there.
    public func stop() {
        lock.lock()
        guard !stopRequested else { lock.unlock(); return }
        stopRequested = true
        let pid = child?.pid
        let stillRunning = running
        lock.unlock()
        guard stillRunning, let pid else { return setState(.ended) }
        write(PluginWire.line(for: ["t": PluginWire.ToHost.bye])!, thenClose: true)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
            // Under the lock that also ends `running`: while it is true the host has not been reaped, so the id is still its own.
            lock.lock(); if running { Darwin.kill(pid, SIGKILL) }; lock.unlock()
        }
    }

    public func pause() {
        lock.lock()
        pauseRequested = true
        var changed = false
        if case .ready = _state { _state = .paused; changed = true }
        lock.unlock()
        write(PluginWire.line(for: ["t": PluginWire.ToHost.pause])!)
        if changed { notifyState(.paused) }
    }

    public func resume() {
        lock.lock()
        pauseRequested = false
        var restored: ScriptHostState?
        if case .paused = _state { restored = .ready(events: _events, commands: _commands); _state = restored! }
        lock.unlock()
        write(PluginWire.line(for: ["t": PluginWire.ToHost.resume])!)
        if let restored { notifyState(restored) }
    }

    // MARK: Questions, events and commands

    /// A focus or value event, answered by the script or not at all. Blocks the calling thread (main) for at most the
    /// event deadline. While an earlier question is still unanswered no new one is sent: `.late` comes back at once.
    public func ask(_ event: String, item: ScriptValue? = nil) -> ScriptAnswer {
        lock.lock()
        guard case .ready = _state, !stopRequested else { lock.unlock(); return .unhandled }
        if lateQuestion != nil { lock.unlock(); return .late }
        let id = nextID; nextID += 1
        let question = Question()
        open[id] = (Self.now(), .question(question))
        lock.unlock()
        guard sendEvent(id: id, name: event, item: item) else {
            lock.lock(); open[id] = nil; lock.unlock()
            return .unhandled
        }
        _ = question.semaphore.wait(timeout: .now() + limits.eventDeadline)
        lock.lock()
        if let answer = question.answer { lock.unlock(); return answer }
        question.abandoned = true
        lateQuestion = id
        lock.unlock()
        strike(.lateAnswer)
        return .late
    }

    /// An event that needs no answer (appFocus, appBlur, windowChange). Dropped while the host is busy or paused.
    public func tell(_ event: String, item: ScriptValue? = nil) {
        lock.lock()
        guard case .ready = _state, !stopRequested, lateQuestion == nil else { lock.unlock(); return }
        let id = nextID; nextID += 1
        open[id] = (Self.now(), .oneWayEvent)
        lock.unlock()
        if !sendEvent(id: id, name: event, item: item) { lock.lock(); open[id] = nil; lock.unlock() }
    }

    /// Run one of the script's commands; `completion` is called on main when it finishes, fails or the host goes.
    public func run(command: String, item: ScriptValue? = nil, completion: @escaping @MainActor (ScriptCommandResult) -> Void) {
        lock.lock()
        guard case .ready = _state, !stopRequested else {
            lock.unlock()
            return onMain { completion(.failed(String(localized: "The script is not running.", comment: "A plugin command could not run because its script is off"))) }
        }
        let id = nextID; nextID += 1
        open[id] = (Self.now(), .command(completion))
        lock.unlock()
        var message: [String: Any] = ["t": PluginWire.ToHost.command, "id": id, "command": command]
        if let item { message["item"] = item.json }
        if !send(message) { resolve(id: id, with: .failed(String(localized: "That command's message was too large to send.", comment: "A plugin command could not be sent to its script"))) }
    }

    private func sendEvent(id: Int, name: String, item: ScriptValue?) -> Bool {
        var message: [String: Any] = ["t": PluginWire.ToHost.event, "id": id, "name": name]
        if let item { message["item"] = item.json }
        return send(message)
    }

    /// Finish the open work `id` with a command result (or an unhandled answer for a question).
    private func resolve(id: Int, with result: ScriptCommandResult) {
        lock.lock()
        // Only a command is finished by a command's answer: a question or event left open by a forged `commandDone` would keep
        // its kill deadline away and go unanswered.
        guard case .command(let completion)? = open[id]?.work else { lock.unlock(); return }
        open.removeValue(forKey: id)
        lock.unlock()
        onMain { completion(result) }
    }

    // MARK: Writing

    private func send(_ message: [String: Any]) -> Bool {
        guard let line = PluginWire.line(for: message), line.count <= limits.messageBytes else { return false }
        write(line)
        return true
    }

    private func write(_ line: Data, thenClose: Bool = false) {
        lock.lock()
        guard let input = child?.stdin, running else { lock.unlock(); return }
        queuedBytes += line.count
        let tooMuch = queuedBytes > 8 * limits.messageBytes
        lock.unlock()
        if tooMuch { return kill("it stopped reading what TurnOver sent", state: String(localized: "The script's program stopped listening and was stopped.", comment: "Said to a plugin author")) }
        writer.async { [self] in
            var offset = 0
            while offset < line.count, !inputClosed {
                let n = line.withUnsafeBytes { Darwin.write(input.fileDescriptor, $0.baseAddress! + offset, line.count - offset) }
                if n < 0 { if errno == EINTR { continue }; break }
                offset += n
            }
            lock.lock(); queuedBytes -= line.count; lock.unlock()
            if thenClose, !inputClosed { inputClosed = true; try? input.close() }
        }
    }

    // MARK: Reading

    private func received(_ data: Data) {
        lock.lock()
        let pieces = outputFramer.add(data)
        lock.unlock()
        for piece in pieces {
            switch piece {
            case .tooLong: logLimited("toolong", "script host \(plugin.id): a message from the script was too long and was dropped")
            case .line(let line):
                guard !line.isEmpty, admitLine() else { continue }
                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      let type = object["t"] as? String else { continue }
                handle(type: type, object)
            }
        }
    }

    /// Whether this line may be looked at: at most `messagesPerSecond` a second are, and the rest are thrown away unread. A host
    /// that keeps it up (`floodDropsAllowed` thrown away within `floodWindow`) is stopped: it is not a script that is slow, it
    /// is one that is trying to use TurnOver's time.
    private func admitLine() -> Bool {
        let now = Self.now()
        lock.lock()
        lineTimes.removeAll { $0 <= now - 1 }
        if lineTimes.count < limits.messagesPerSecond { lineTimes.append(now); lock.unlock(); return true }
        floodDrops.removeAll { $0 <= now - limits.floodWindow }
        floodDrops.append(now)
        let abusive = floodDrops.count > limits.floodDropsAllowed
        lock.unlock()
        if abusive { kill("it sent far more messages than a script may", state: String(localized: "The script's program sent far more messages than it may and was stopped.", comment: "Said to a plugin author when the program running its script floods TurnOver with messages")) }
        else { logLimited("flood", "script host \(plugin.id): messages came faster than \(limits.messagesPerSecond) a second and were thrown away") }
        return false
    }

    /// Say something to the log at most once in `logInterval` for each kind, with how many were held back since: a host that
    /// repeats one complaint or refusal cannot fill the log or spend TurnOver's time on writing it.
    private func logLimited(_ kind: String, _ text: String) {
        let now = Self.now()
        lock.lock()
        let last = lastLogged[kind]
        if let last, now - last.at < limits.logInterval { lastLogged[kind] = (last.at, last.held + 1); lock.unlock(); return }
        lastLogged[kind] = (now, 0)
        lock.unlock()
        Log.info(text + ((last?.held ?? 0) > 0 ? " (and \(last!.held) more like it)" : ""))
    }

    private func handle(type: String, _ object: [String: Any]) {
        switch type {
        case PluginWire.FromHost.ready:
            // Only what exists: an event TurnOver sends and a command the manifest declared, once each.
            let events = ((object["events"] as? [Any])?.compactMap { $0 as? String } ?? []).filter { PluginWire.eventNames.contains($0) }
            let commands = ((object["commands"] as? [Any])?.compactMap { $0 as? String } ?? []).filter { declaredCommands.contains($0) }
            lock.lock()
            guard case .starting = _state else { lock.unlock(); return }
            _events = events; _commands = commands
            _state = pauseRequested ? .paused : .ready(events: events, commands: commands)
            let now = _state
            lock.unlock()
            notifyState(now)
        case PluginWire.FromHost.failed:
            let message = object["error"] as? String ?? String(localized: "The script failed to load.", comment: "Said to a plugin author")
            kill("the script did not load", state: message, strike: false)
        case PluginWire.FromHost.eventDone:
            guard let id = object["id"] as? Int else { return }
            let now = Self.now()
            lock.lock()
            // Only a question or an event is finished by this answer; a command left open stays open (a forged answer to the
            // wrong kind of work changes nothing, so nothing loses its deadline).
            guard let entry = open[id] else { lock.unlock(); return }
            if case .command = entry.work { lock.unlock(); return }
            open.removeValue(forKey: id)
            if lateQuestion == id { lateQuestion = nil }
            // Words in place of TurnOver's own are speech like any other: they need the `say` ability, are cut to the character
            // limit and count toward the rate. Silence (empty words) needs the ability but is not speech, so it is not counted.
            var answer = ScriptAnswer.unhandled
            if (object["handled"] as? Bool) == true, abilities.contains(.say), let said = object["say"] as? String {
                let words = String(said.prefix(limits.sayCharacters))
                sayTimes.removeAll { $0 <= now - limits.sayWindow }
                if words.isEmpty { answer = .say("") }
                else if sayTimes.count < limits.saysPerWindow { sayTimes.append(now); answer = .say(words) }
            }
            if case .question(let question) = entry.work, !question.abandoned {
                question.answer = answer
                question.semaphore.signal()
            }
            lock.unlock()
        case PluginWire.FromHost.commandDone:
            guard let id = object["id"] as? Int else { return }
            let error = object["error"] as? String
            resolve(id: id, with: error.map { .failed($0) } ?? .done)
        case PluginWire.FromHost.request, PluginWire.FromHost.notify:
            gate(isRequest: type == PluginWire.FromHost.request, object)
        default: break
        }
    }

    // MARK: Checking a request

    /// Everything that can be decided without main: the rates, the operation, the plugin's abilities. Refusals are
    /// answered here; what passes is handed to main for the broker.
    private func gate(isRequest: Bool, _ object: [String: Any]) {
        let id = object["id"] as? Int
        func refuse(_ message: String) {
            guard isRequest, let id else { return logLimited("refused", "script host \(plugin.id): dropped a one-way message: \(message)") }
            reply(id: id, result: .failure(ScriptBrokerError.refused(message)))
        }
        // Every message counts toward the rate, whatever it asks for or whether it is allowed (it used to be only the ones that
        // got through, so a flood of refused ones cost TurnOver an answer each and counted for nothing).
        let now = Self.now()
        lock.lock()
        requestTimes.removeAll { $0 <= now - 1 }
        let tooManyRequests = requestTimes.count >= limits.requestsPerSecond
        if !tooManyRequests { requestTimes.append(now) }
        let paused = pauseRequested
        lock.unlock()
        if tooManyRequests {
            return refuse(String(localized: "That is more than \(limits.requestsPerSecond) requests in a second, which is the most a script may make.", comment: "Said to a plugin author"))
        }
        guard let name = object["op"] as? String, let operation = ScriptOperation(rawValue: name) else {
            return refuse(String(localized: "TurnOver does not know that operation.", comment: "Said to a plugin author when a script asks for something that does not exist"))
        }
        guard operation.isNotification != isRequest else {
            return refuse(String(localized: "That message was sent the wrong way.", comment: "Said to a plugin author"))
        }
        let missing = ScriptAbilities.missing(for: operation, granted: abilities)
        if !missing.isEmpty {
            let names = missing.map(\.rawValue).joined(separator: ", ")
            return refuse(String(localized: "This needs the \(names) ability. Add \"\(names)\" to abilities in manifest.json, and the person has to agree to it.", comment: "Said to a plugin author when a script asks for something its manifest did not ask for; the placeholder is the ability's name"))
        }
        // While the plugin's app is not in front the script is paused: what it asks for then (a timer's search, a clipboard
        // write, a spoken word) is refused here, on TurnOver's side, whatever the host does with its pause. Only what reaches
        // nothing outside the plugin (its log and its own stored data) goes on.
        if paused, !ScriptAbilities.required(for: operation).isEmpty {
            return refuse(String(localized: "The plugin's app is not in front, so the script is paused and cannot do that now.", comment: "Said to a plugin author when a script asks for something while it is paused"))
        }
        var args = ScriptValue(json: object["args"])
        var tooManySays = false
        if operation == .say || operation == .sound || operation == .itemRead {   // everything that speaks or sounds shares one budget
            lock.lock()
            sayTimes.removeAll { $0 <= now - limits.sayWindow }
            tooManySays = sayTimes.count >= limits.saysPerWindow
            if !tooManySays { sayTimes.append(now) }
            lock.unlock()
        }
        if tooManySays {
            return refuse(String(localized: "That is more than \(limits.saysPerWindow) things said in \(Int(limits.sayWindow)) seconds, which is the most a script may say.", comment: "Said to a plugin author"))
        }
        if operation == .say, case .object(var fields) = args, let text = fields["text"]?.stringValue, text.count > limits.sayCharacters {
            fields["text"] = .string(String(text.prefix(limits.sayCharacters)))
            args = .object(fields)
        }
        if operation == .storageSet, let value = args["value"],
           let data = try? JSONSerialization.data(withJSONObject: value.json, options: [.fragmentsAllowed]), data.count > limits.storageBytes {
            return refuse(String(localized: "That value is larger than \(limits.storageBytes / 1024) KB, which is the most a plugin may store.", comment: "Said to a plugin author"))
        }
        lock.lock()
        let full = mainQueued >= limits.mainQueueLimit
        if !full { mainQueued += 1 }
        lock.unlock()
        if full {
            return refuse(String(localized: "TurnOver has not yet dealt with the script's earlier requests. Ask for less, or less often.", comment: "Said to a plugin author when too many of its requests are waiting"))
        }
        let handed = args
        onMain { [self] in perform(operation, handed, id: isRequest ? id : nil) }
    }

    /// On main: the broker's work, within its share of the main thread's time. The time counts from when each call ended and
    /// by its whole length, so a call that ran for longer than the window still counts against the next ones.
    @MainActor private func perform(_ operation: ScriptOperation, _ args: ScriptValue, id: Int?) {
        let start = Self.now()
        lock.lock()
        mainQueued -= 1
        mainSpans.removeAll { $0.at <= start - 1 }
        let overBudget = mainSpans.reduce(0) { $0 + $1.took } >= limits.mainThreadSecondsPerSecond
        let stopped = stopRequested || !running
        lock.unlock()
        if stopped { return }
        if overBudget {
            if let id { reply(id: id, result: .failure(ScriptBrokerError.refused(String(localized: "The script's requests are taking too much of TurnOver's time just now. Ask for less, or less often.", comment: "Said to a plugin author")))) }
            return
        }
        let result = Result { try broker.perform(operation, args) }
        let end = Self.now()
        lock.lock(); mainSpans.append((end, end - start)); lock.unlock()
        if let id { reply(id: id, result: result) }
    }

    private func reply(id: Int, result: Result<ScriptValue, any Error>) {
        var message: [String: Any] = ["t": PluginWire.ToHost.reply, "id": id]
        switch result {
        case .success(let value): message["ok"] = true; message["value"] = value.json
        case .failure(let error):
            message["ok"] = false
            message["error"] = (error as? ScriptBrokerError)?.message ?? String(localized: "TurnOver could not do that.", comment: "Said to a plugin author when a request fails for no stated reason")
        }
        if !send(message) {
            _ = send(["t": PluginWire.ToHost.reply, "id": id, "ok": false, "error": String(localized: "The answer was larger than \(limits.messageBytes / 1024) KB, which is the most a message may be.", comment: "Said to a plugin author")])
        }
    }

    // MARK: Watching

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + limits.watchdogInterval, repeating: limits.watchdogInterval)
        timer.setEventHandler { [self] in checkOnHost() }
        lock.lock(); watchdog = timer; lock.unlock()
        timer.resume()
    }

    private func checkOnHost() {
        let now = Self.now()
        lock.lock()
        guard running, let pid = child?.pid, killedReason == nil, !stopRequested else { lock.unlock(); return }
        var reason: String?
        if case .starting = _state, now - startedAt > limits.startLimit {
            reason = "it did not start within \(limits.startLimit) seconds"
        } else if open.values.contains(where: { now - $0.since > limits.killLimit }) {
            reason = "it did not answer within \(limits.killLimit) seconds"
        }
        lock.unlock()
        if reason == nil, let usage = Self.usage(of: pid) {
            lock.lock()
            if usage.footprint > limits.memoryBytes {
                reason = "it used more than \(limits.memoryBytes / 1_048_576) MB of memory"
            } else {
                cpuSamples.append((now, usage.cpu))
                while cpuSamples.count > 2, cpuSamples[1].at <= now - limits.cpuWindow { cpuSamples.removeFirst() }
                if let first = cpuSamples.first, let last = cpuSamples.last, last.at - first.at >= limits.cpuWindow,
                   (last.cpu - first.cpu) / (last.at - first.at) > limits.cpuShare {
                    reason = "it used more than \(Int(limits.cpuShare * 100)) percent of a processor for \(Int(limits.cpuWindow)) seconds"
                }
            }
            lock.unlock()
        }
        if let reason {
            kill(reason, state: String(localized: "The script was stopped because it was too slow or too greedy.", comment: "Said to a plugin author; the script took too long, or too much memory or processor time"))
        }
    }

    private static func usage(of pid: pid_t) -> (footprint: UInt64, cpu: TimeInterval)? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)
        let ticks = Double(info.ri_user_time + info.ri_system_time)
        return (info.ri_phys_footprint, ticks * Double(timebase.numer) / Double(timebase.denom) / 1e9)
    }

    /// Kill the host and say why. `state` is the message the author sees. A strike is reported unless `strike` is false.
    private func kill(_ reason: String, state message: String, strike shouldStrike: Bool = true) {
        lock.lock()
        guard killedReason == nil, running, let pid = child?.pid else { lock.unlock(); return }
        killedReason = reason
        let wasStopping = stopRequested
        Darwin.kill(pid, SIGKILL)   // under the lock that ends `running`: until then the host is not reaped and the id is its own
        lock.unlock()
        Log.warning("script host \(plugin.id): stopped it, because \(reason)")
        setState(.failed(message))
        failOpenWork()
        if shouldStrike && !wasStopping { strike(.killed(reason)) }
    }

    private func processExited(_ status: Int32) {
        lock.lock()
        running = false
        let reason = killedReason, stopping = stopRequested
        let exitCode = (status & 0x7f) == 0 ? Int((status >> 8) & 0xff) : -Int(status & 0x7f)
        let wasStarting: Bool
        if case .starting = _state { wasStarting = true } else { wasStarting = false }
        let errorText = lastErrorText
        watchdog?.cancel(); watchdog = nil
        let input = child?.stdin
        lock.unlock()
        failOpenWork()
        writer.async { try? input?.close() }
        if reason != nil { return }
        if stopping { return setState(.ended) }
        if exitCode == 3 && wasStarting {
            Log.warning("script host \(plugin.id): the sandbox could not be applied: \(Log.words(errorText))")
            return setState(.failed(String(localized: "TurnOver could not lock the script's program in its sandbox, so scripts do not run.", comment: "Said when the safety sandbox for plugin scripts could not be turned on")))
        }
        let description = exitCode >= 0 ? "exit status \(exitCode)" : "signal \(-exitCode)"
        Log.warning("script host \(plugin.id): ended on its own (\(description))")
        setState(.failed(String(localized: "The script's program stopped unexpectedly.", comment: "Said to a plugin author when the helper that runs a script crashed")))
        strike(.crashed(description))
    }

    /// Everything waiting on the host gets its answer now: questions go unhandled, commands fail.
    private func failOpenWork() {
        lock.lock()
        let all = open
        open = [:]
        lateQuestion = nil
        for entry in all.values {
            if case .question(let question) = entry.work, !question.abandoned { question.answer = .unhandled; question.semaphore.signal() }
        }
        lock.unlock()
        for entry in all.values {
            if case .command(let completion) = entry.work {
                onMain { completion(.failed(String(localized: "The script stopped before the command finished.", comment: "A plugin command did not finish because its script was stopped"))) }
            }
        }
    }

    /// A failure before the host ever started.
    private func finish(failed message: String) {
        setState(.failed(message))
    }

    private func setState(_ new: ScriptHostState) {
        lock.lock()
        if case .failed = _state, case .ended = new { lock.unlock(); return }
        let changed = _state != new
        _state = new
        lock.unlock()
        if changed { notifyState(new) }
    }

    private func notifyState(_ new: ScriptHostState) {
        lock.lock(); let callback = _onStateChange; lock.unlock()
        if let callback { onMain { callback(new) } }
    }

    private func strike(_ strike: ScriptStrike) {
        lock.lock(); let callback = _onStrike; lock.unlock()
        Log.warning("script host \(plugin.id): strike: \(strike)")
        if let callback { onMain { callback(strike) } }
    }
}
