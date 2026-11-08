// SpeechBridge Listener — the Mac end of SpeechBridge.
//
// Listens on 127.0.0.1:52134 for the line protocol the bottle-side DLLs send
// (SAAPI64, SapiBridge, the NVDA and WindowsTTS stand-ins):
//     S <utf-8 text>\n   speak this
//     X\n                stop speaking, drop anything queued
// and speaks each line, in order.
//
// With VoiceOver running, VoiceOver itself speaks: each line goes to
// `tell application "VoiceOver" to output` as a child osascript on a serial
// queue, killed after 3 s so a stuck call can never wedge speech — the route
// Steam Speak settled on after the in-process AppleScript one hung in the field.
// VoiceOver queues what it is given and offers nothing to cancel it, so a stop
// only drops lines not yet handed over. Without VoiceOver (or with --voice) the
// system synthesiser speaks, and a stop cuts it off at once.
//
// Lines that arrive within 60 ms of each other are spoken as one utterance (a control's
// name, state and hint), and a batch that has waited more than 1.5 s is dropped, because
// VoiceOver cannot be cut off and a queue behind the cursor is worse than a gap.
//
// Build and install as an app (so the Automation permission belongs to it):
//     SpeechBridge/listener/build.sh
// Or run it bare:  swiftc -O -o d4bridge d4bridge.swift && ./d4bridge
//     --voice        always the system voice, even with VoiceOver on
//     --port 52134
// Test:   printf 'S Hello from the bridge\n' | nc 127.0.0.1 52134
//
// Every line is logged with a timestamp to stdout and to
// ~/Library/Application Support/SpeechBridge/logs/listener-<date>.log.

import AppKit
import AVFoundation
import Foundation
import Network

let stamp: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

let logFile: FileHandle? = {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SpeechBridge/logs")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd-HHmmss"
    let url = dir.appendingPathComponent("listener-\(day.string(from: Date())).log")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    return try? FileHandle(forWritingTo: url)
}()

func log(_ s: String) {
    let line = "\(stamp.string(from: Date())) \(s)\n"
    print(line, terminator: "")
    fflush(stdout)
    logFile?.write(Data(line.utf8))
}

final class Speaker {
    private let synth = AVSpeechSynthesizer()
    private let forceVoice: Bool
    private let voQueue = DispatchQueue(label: "speechbridge.voiceover.output")
    private var generation = 0          // bumped by stop(); queued lines from before are dropped
    private var warnedDenied = false
    private var lastRoute = ""

    /// Lines that arrived within `batchWindow` of each other go to VoiceOver as one
    /// utterance: a game's reader sends a control's name, its state and its hint as three
    /// lines a few milliseconds apart, and three osascript round trips for that made
    /// speech fall behind the cursor. A batch older than `maxAge` when its turn comes is
    /// dropped — the game has moved on, and VoiceOver cannot be cut off.
    private static let batchWindow: TimeInterval = 0.04
    private static let maxAge: TimeInterval = 1.5
    private var pending: [String] = []
    private var pendingSince = Date()
    private var flushTimer: Timer?

    init(forceVoice: Bool) { self.forceVoice = forceVoice }

    private var useVoiceOver: Bool {
        !forceVoice && NSWorkspace.shared.isVoiceOverEnabled
    }

    func say(_ text: String) {
        if useVoiceOver {
            noteRoute("VoiceOver itself")
            if pending.isEmpty { pendingSince = Date() }
            pending.append(text)
            flushTimer?.invalidate()
            flushTimer = Timer.scheduledTimer(withTimeInterval: Self.batchWindow, repeats: false) { [weak self] _ in self?.flush() }
        } else {
            noteRoute("the system voice")
            speakWithSynth(text)
        }
    }

    private func flush() {
        flushTimer = nil
        guard !pending.isEmpty else { return }
        let batch = pending.joined(separator: "  ")
        let born = pendingSince
        pending.removeAll()
        let gen = generation
        voQueue.async { [self] in
            guard gen == generation else { return }              // a stop came first
            if Date().timeIntervalSince(born) > Self.maxAge {
                DispatchQueue.main.async { log("dropped (stale): \(batch.prefix(60))") }
                return
            }
            if !speakThroughVoiceOver(batch) {
                DispatchQueue.main.async { self.speakWithSynth(batch) }
            }
        }
    }

    func stop() {
        generation += 1
        flushTimer?.invalidate(); flushTimer = nil
        pending.removeAll()
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    private func speakWithSynth(_ text: String) {
        // The synthesiser can be cut off, so the newest line wins — a menu that moves
        // faster than speech should end on the item you are on.
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        synth.speak(AVSpeechUtterance(string: text))
    }

    /// Runs on voQueue. True if VoiceOver took the line.
    ///
    /// The line goes to VoiceOver as a raw Apple event — its `output` command is class
    /// VOAS, id outp, text as the direct object — sent from this process with a 3 s
    /// timeout. A child osascript per line cost ~500 ms each (measured 28 Sep 2026), and
    /// that was the lag the owner heard in Diablo IV; an in-process send is a few ms. The
    /// timeout is what makes it safe: the in-process AppleScript route that hung Steam
    /// Speak in the field had no timeout and ran on the main thread; this has one and runs
    /// on a serial background queue, so a stuck VoiceOver costs one dropped line, not speech.
    private func speakThroughVoiceOver(_ text: String) -> Bool {
        let started = Date()
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.VoiceOver")
        let event = NSAppleEventDescriptor(eventClass: 0x564F4153 /* VOAS */, eventID: 0x6F757470 /* outp */,
                                           targetDescriptor: target,
                                           returnID: Int16(kAutoGenerateReturnID),
                                           transactionID: Int32(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: text), forKeyword: AEKeyword(keyDirectObject))
        do {
            _ = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 3.0)
        } catch {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let err = (error as NSError).code
            if !warnedDenied {
                warnedDenied = true
                if err == -1743 {
                    log("VoiceOver route refused (-1743): allow SpeechBridge Listener under Privacy & Security, Automation, VoiceOver.")
                    DispatchQueue.main.async {
                        self.speakWithSynth("To hear VoiceOver's own voice, allow SpeechBridge Listener to control VoiceOver in Privacy and Security settings, under Automation.")
                    }
                } else {
                    log("VoiceOver route failed (\(err)) after \(ms) ms — \(error.localizedDescription)")
                }
            }
            return false
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if ms > 150 { DispatchQueue.main.async { log("VoiceOver took \(ms) ms to accept a line") } }
        return true
    }

    private func noteRoute(_ route: String) {
        guard route != lastRoute else { return }
        lastRoute = route
        log("speaking through \(route)")
    }
}

// ---- arguments --------------------------------------------------------------

var port: UInt16 = 52134
var forceVoice = false
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--voice": forceVoice = true
    case "--port":
        guard let v = args.next(), let p = UInt16(v) else { fatalError("--port needs a number") }
        port = p
    default: break          // the app may be launched with arguments that are not ours
    }
}

let speaker = Speaker(forceVoice: forceVoice)

// ---- listener, loopback only ------------------------------------------------

let params = NWParameters.tcp
params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
params.allowLocalEndpointReuse = true
let listener = try NWListener(using: params)

func handle(line: String) {
    if line == "X" {
        log("stop")
        speaker.stop()
    } else if line.hasPrefix("S ") {
        let text = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        log("say: \(text)")
        speaker.say(text)
    } else if !line.isEmpty {
        log("ignored: \(line)")
    }
}

func serve(_ conn: NWConnection) {
    var buffer = Data()
    func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
            if let data = data { buffer.append(data) }
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                handle(line: String(decoding: lineData, as: UTF8.self)
                    .trimmingCharacters(in: .init(charactersIn: "\r")))
            }
            if done || error != nil {
                log("game disconnected")
                conn.cancel()
            } else {
                receive()
            }
        }
    }
    conn.stateUpdateHandler = { state in
        if case .ready = state { log("game connected") }
    }
    conn.start(queue: .main)
    receive()
}

listener.newConnectionHandler = serve
listener.stateUpdateHandler = { state in
    switch state {
    case .ready: log("listening on 127.0.0.1:\(port) — \(forceVoice ? "system voice" : "VoiceOver when running, else system voice")")
    case .failed(let e): log("listener failed: \(e)"); exit(1)
    default: break
    }
}

// ---- web reader: pages served over a Chromium debugging port ------------------
//
// Some games are web pages in an Electron shell and speak through nothing at all: they
// write to aria-live regions and expect a screen reader to read them (Periphery Synthetic
// EP, 29 Sep 2026). Under Wine there is no screen reader in the bottle, so this does what
// one would: it attaches to every page on the game's debugging port — the game is launched
// with --remote-debugging-port=9223 — installs a MutationObserver on the live regions and a
// focus listener, and speaks what changes. The same technique Steam Speak uses for Big
// Picture. Nothing is injected into a page unless it is on this port, and the port only
// exists when a game is started with the switch.

final class WebReader {
    private let port: UInt16
    private let speaker: Speaker
    private var sessions: [String: WebSession] = [:]
    private var timer: Timer?
    private var wasUp = false

    init(port: UInt16, speaker: Speaker) { self.port = port; self.speaker = speaker }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    private struct Target: Decodable { let id: String; let type: String?; let title: String?; let url: String?; let webSocketDebuggerUrl: String? }

    private func poll() {
        let url = URL(string: "http://127.0.0.1:\(port)/json/list")!
        var req = URLRequest(url: url); req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard error == nil, let data = data, let targets = try? JSONDecoder().decode([Target].self, from: data) else {
                    if self.wasUp { log("web reader: port \(self.port) went away"); self.wasUp = false }
                    for s in self.sessions.values { s.close() }
                    self.sessions.removeAll()
                    return
                }
                if !self.wasUp { log("web reader: port \(self.port) is up"); self.wasUp = true }
                let live = Set(targets.map { $0.id })
                for (id, s) in self.sessions where !live.contains(id) { s.close(); self.sessions[id] = nil }
                for t in targets where t.type == "page" && self.sessions[t.id] == nil {
                    guard let ws = t.webSocketDebuggerUrl, let wsURL = URL(string: ws) else { continue }
                    let s = WebSession(url: wsURL, title: t.title ?? t.url ?? t.id, speaker: self.speaker)
                    self.sessions[t.id] = s
                    s.open()
                }
            }
        }.resume()
    }
}

final class WebSession {
    private let url: URL
    private let title: String
    private let speaker: Speaker
    private var task: URLSessionWebSocketTask?
    private var nextId = 1

    /// Speaks every change inside an aria-live region (or role alert/status/log) and every
    /// focus move, through a binding the listener installs. Idempotent per page.
    static let observer = """
    (function(){
      if (window.__speechBridge) return 'already';
      window.__speechBridge = true;
      var last = '', lastAt = 0;
      function speak(t){ t = String(t||'').replace(/\\s+/g,' ').trim(); if(!t) return;
        var now = Date.now(); if (t === last && now - lastAt < 800) return; last = t; lastAt = now;
        try { window.speechBridge(t); } catch(e){} }
      function inLive(el){ for (var e = el; e && e.nodeType === 1; e = e.parentElement) {
        var a = e.getAttribute('aria-live'); if (a && a !== 'off') return true;
        var r = e.getAttribute('role'); if (r === 'alert' || r === 'status' || r === 'log') return true; }
        return false; }
      new MutationObserver(function(ms){ for (var i = 0; i < ms.length; i++) { var m = ms[i];
        var target = m.type === 'characterData' ? m.target.parentElement : m.target;
        if (!inLive(target)) continue;
        if (m.type === 'characterData') speak(m.target.data);
        else for (var j = 0; j < m.addedNodes.length; j++) speak(m.addedNodes[j].textContent); } })
        .observe(document.documentElement, {subtree: true, childList: true, characterData: true});
      document.addEventListener('focusin', function(e){ var el = e.target; if (!el || el === document.body) return;
        var name = el.getAttribute('aria-label') || (el.labels && el.labels[0] && el.labels[0].textContent) || el.textContent || el.value || '';
        var role = el.getAttribute('role') || el.tagName.toLowerCase();
        speak(name.trim() + (role ? ', ' + role : '')); }, true);
      return 'installed';
    })()
    """

    init(url: URL, title: String, speaker: Speaker) { self.url = url; self.title = title; self.speaker = speaker }

    func open() {
        let t = URLSession.shared.webSocketTask(with: url)
        task = t
        t.resume()
        send(["method": "Runtime.enable"])
        send(["method": "Runtime.addBinding", "params": ["name": "speechBridge"]])
        send(["method": "Page.enable"])
        send(["method": "Page.addScriptToEvaluateOnNewDocument", "params": ["source": WebSession.observer]])
        send(["method": "Runtime.evaluate", "params": ["expression": WebSession.observer, "returnByValue": true]])
        log("web reader: attached to \(title.isEmpty ? url.lastPathComponent : title)")
        receive()
    }

    func close() { task?.cancel(with: .goingAway, reason: nil); task = nil }

    private func send(_ msg: [String: Any]) {
        var m = msg; m["id"] = nextId; nextId += 1
        guard let data = try? JSONSerialization.data(withJSONObject: m), let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure:
                DispatchQueue.main.async { log("web reader: page connection ended (\(self.title))") }
                return
            case .success(let message):
                if case .string(let text) = message,
                   let data = text.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   obj["method"] as? String == "Runtime.bindingCalled",
                   let params = obj["params"] as? [String: Any],
                   params["name"] as? String == "speechBridge",
                   let payload = params["payload"] as? String {
                    DispatchQueue.main.async { log("web: \(payload)"); self.speaker.say(payload) }
                }
                self.receive()
            }
        }
    }
}

let webReader = WebReader(port: 9223, speaker: speaker)
webReader.start()

listener.start(queue: .main)
RunLoop.main.run()
