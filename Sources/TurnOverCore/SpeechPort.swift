// SPDX-License-Identifier: GPL-3.0-or-later
// The speech port (18 Oct 2026: "can we make it so apps can request to use TurnOver as output, and TurnOver
// alerts the user, then it's their choice: do you trust this app?"). Any app on this Mac can ask TurnOver to speak for
// it: a game of its own (SubCities, in Godot), a Windows game through SpeechBridge's stand-in speech files in
// CrossOver. It connects to 127.0.0.1:52134 (this Mac only) and sends lines: "S <text>" to say something, "X" to stop.
//
// Who is asking is found out by TurnOver, not taken from the app: the connection's port is looked up among the Mac's
// processes (the kernel's own record), and the process's code signature (or, unsigned, its file) names it. The first
// time an app asks, while it is the app in front, TurnOver asks the user, by name: allow, don't allow, or not now.
// The answer is kept (speech-apps.json) and can be changed in Settings, Apps that speak through TurnOver.
// TurnOver tells the app where it stands, a line at a time: "unknown" (not asked yet: it may send its words, which
// are not said, and the first one asks), "asking", "allowed" or "not allowed". An app keeps its own voice until it
// hears "allowed" (SubCities does).
//
// An allowed app is heard only while it is the app in front (a game's words while you read Mail are not wanted, and
// a program in the background mustn't speak, or stop TurnOver speaking, unseen). It can do nothing else: no settings,
// no keys. TurnOver's own programs use the control channel instead (TurnOverControl).
import Foundation
import AppKit
import Network
import Security

final class SpeechPort {
    static let shared = SpeechPort()

    /// Who is on the other end of a connection.
    struct Speaker: Sendable {
        let id: String      // "team:<team>/<identifier>" for a signed program, "path:<executable>" otherwise
        let name: String    // what the user is asked about
        let pid: pid_t
        let isWine: Bool
    }

    private var listener: NWListener?
    private var port: UInt16 = 52134
    private var failed = ""
    private(set) var connections = 0
    private(set) var lines = 0
    private var retried = false
    /// The decisions, by the speaker's id.
    private var decisions: [String: (name: String, allowed: Bool)] = [:]
    /// A question being asked, so it is asked once.
    private var asking = Set<String>()
    private var droppedBackground = 0
    /// The open connections, by speaker, to tell of a decision.
    private var open: [String: [NWConnection]] = [:]

    private func standing(of id: String) -> String {
        if asking.contains(id) { return "asking" }
        switch decisions[id]?.allowed { case true?: return "allowed"; case false?: return "not allowed"; case nil: return "unknown" }
    }
    private func tell(_ conn: NWConnection, _ word: String) {
        conn.send(content: Data((word + "\n").utf8), completion: .contentProcessed { _ in })
    }
    private func tellAll(_ id: String) { for c in open[id] ?? [] { tell(c, standing(of: id)) } }

    var status: String {
        if !failed.isEmpty { return "The speech port could not listen: \(failed)." }
        return connections == 0 ? "Listening for apps on port \(port); none connected." : "\(connections) app connection\(connections == 1 ? "" : "s"), \(lines) lines heard."
    }

    // MARK: Listening

    func start(port: Int) {
        guard listener == nil else { return }
        load()
        self.port = UInt16(clamping: port)
        let params = NWParameters.tcp
        guard let p = NWEndpoint.Port(rawValue: self.port) else { return }
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: p)   // this Mac only
        params.allowLocalEndpointReuse = true
        do { listener = try NWListener(using: params) } catch {
            failed = error.localizedDescription
            Log.error("speech port: could not listen on \(self.port): \(error)")
            return
        }
        listener?.newConnectionHandler = { [weak self] c in MainActor.assumeIsolated { self?.serve(c) } }
        listener?.stateUpdateHandler = { [weak self] state in MainActor.assumeIsolated {
            switch state {
            case .ready: Log.info("speech port: listening on 127.0.0.1:\(self?.port ?? 0)")
            case .failed(let e):
                // A restart: the old TurnOver still holds the port for a moment. Once more after 2 s.
                if "\(e)".contains("48"), self?.retried == false {
                    self?.retried = true
                    self?.listener?.cancel(); self?.listener = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.start(port: Int(self?.port ?? 52134)) }
                    return
                }
                self?.failed = "\(e)"
                Log.error("speech port: failed on \(self?.port ?? 0): \(e). Is the old SpeechBridge Listener still running?")
            default: break
            }
        } }
        listener?.start(queue: .main)
    }

    private func serve(_ conn: NWConnection) {
        connections += 1
        let buffer = DataBox()
        let box = SpeakerBox()
        // Who it is, off the main thread (a look through the Mac's processes), before any line is acted on.
        let ourPort = port
        if case .hostPort(_, let remote) = conn.endpoint {
            let remotePort = remote.rawValue
            DispatchQueue.global(qos: .userInitiated).async {
                let speaker = Self.identify(remotePort: remotePort, ourPort: ourPort)
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    box.speaker = speaker
                    if let speaker { self.tell(conn, self.standing(of: speaker.id)); self.open[speaker.id, default: []].append(conn) }
                    Log.info("speech port: \(speaker.map { "\($0.name) (\($0.id)) connected" } ?? "a program connected that couldn't be identified; it won't be heard")")
                    for line in box.held { self.handle(line, box) }
                    box.held.removeAll()
                } }
            }
        }
        conn.start(queue: .main)
        receive(conn, buffer, box)
    }

    nonisolated private func receive(_ conn: NWConnection, _ buffer: DataBox, _ box: SpeakerBox) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in MainActor.assumeIsolated {
            guard let self else { return }
            if let data { buffer.data.append(data) }
            if buffer.data.count > 1_000_000 { buffer.data.removeAll() }   // no line end in a megabyte: not a speaker
            while let nl = buffer.data.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer.data[buffer.data.startIndex..<nl], as: UTF8.self)
                buffer.data.removeSubrange(buffer.data.startIndex...nl)
                if box.speaker == nil { box.held = Array((box.held + [line]).suffix(5)) } else { self.handle(line, box) }
            }
            if done || error != nil {
                self.connections = max(0, self.connections - 1)
                if let id = box.speaker?.id { self.open[id]?.removeAll { $0 === conn } }
                conn.cancel()
            } else {
                self.receive(conn, buffer, box)
            }
        } }
    }

    // MARK: A line

    private func handle(_ line: String, _ box: SpeakerBox) {
        lines += 1
        guard let speaker = box.speaker else { return }
        let front = NSWorkspace.shared.frontmostApplication
        let inFront = front?.processIdentifier == speaker.pid || (speaker.isWine && (front.map { Games.isGame($0) } ?? false))
        switch decisions[speaker.id]?.allowed {
        case false?:
            return
        case nil:
            // Asked only while the app is in front and TurnOver is reading, so the user knows which app it is.
            if inFront, Core.active, case .speak = Games.bridgeCommand(line) { ask(speaker, then: line) }
            return
        case true?:
            switch Games.bridgeAction(line, speakerInFront: inFront && Core.active) {
            case .stop: Speech.cancel()
            case .speak(let text): say(text, from: speaker)
            case .dropped:
                droppedBackground += 1
                if droppedBackground == 1 || droppedBackground % 50 == 0 { Log.io("speech port: \(speaker.name) isn't in front; not said (\(droppedBackground) so far)") }
            case .ignored: if !line.isEmpty { Log.io("speech port: a line that isn't S or X from \(speaker.name)") }
            }
        }
    }

    private func say(_ text: String, from speaker: Speaker) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if Speech.logsWords { Log.io("speech port (\(speaker.name)): \(t.prefix(160))") } else { Log.io("speech port (\(speaker.name)): [\(t.count) characters]") }
        Speech.speakNews(t)
    }

    // MARK: Asking the user

    private func ask(_ found: Speaker, then line: String) {
        guard !asking.contains(found.id), !TurnOverMenu.shared.isOpen else { return }
        // A program's own name can say little ("godot" for every Godot game): its window's title too ("godot,
        // SubCities"), asked briefly.
        let app = AXUIElementCreateApplication(found.pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let title = app.element(kAXFocusedWindowAttribute)?.string(kAXTitleAttribute).map { $0.replacingOccurrences(of: " (DEBUG)", with: "") }
        let speaker = Speaker(id: found.id, name: title.map { $0.isEmpty || $0 == found.name ? found.name : "\(found.name), \($0)" } ?? found.name, pid: found.pid, isWine: found.isWine)
        asking.insert(speaker.id)
        tellAll(speaker.id)
        Log.info("speech port: asking whether \(speaker.name) may speak through TurnOver")
        let decide: (Bool?) -> Void = { [weak self] allowed in
            guard let self else { return }
            self.asking.remove(speaker.id)
            guard let allowed else { self.tellAll(speaker.id); Log.info("speech port: \(speaker.name): not now"); return }
            self.decisions[speaker.id] = (speaker.name, allowed)
            self.save()
            self.tellAll(speaker.id)
            Log.info("speech port: \(speaker.name) \(allowed ? "allowed" : "not allowed")")
            Speech.speakMessage(allowed ? "\(speaker.name) can speak through TurnOver." : "\(speaker.name) won't be heard.")
            if allowed, case .speak(let text) = Games.bridgeCommand(line) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.say(text, from: speaker) }
            }
        }
        TurnOverMenu.shared.onClose = { [weak self] in if self?.asking.contains(speaker.id) == true { self?.asking.remove(speaker.id); self?.tellAll(speaker.id) } }
        TurnOverMenu.shared.openList("\(speaker.name) wants TurnOver to speak for it. Do you trust it?", items: [
            MenuItem("Don't allow", .action { decide(false) }, hint: "\(speaker.name) won't be heard; you can change this in Settings, Apps that speak through TurnOver"),
            MenuItem("Allow", .action { decide(true) }, hint: "\(speaker.name) can make TurnOver say anything while it is the app in front, and nothing else"),
            MenuItem("Not now", .action { decide(nil) }, hint: "Asked again the next time it wants to speak"),
        ])
    }

    // MARK: The decisions, kept

    private var file: URL { AppPaths.file("speech-apps.json") }

    private func load() {
        guard let data = try? Data(contentsOf: file), let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]] else { return }
        for (id, v) in d { if let name = v["name"] as? String, let allowed = v["allowed"] as? Bool { decisions[id] = (name, allowed) } }
    }

    private func save() {
        var d: [String: [String: Any]] = [:]
        for (id, v) in decisions { d[id] = ["name": v.name, "allowed": v.allowed] }
        guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) else { return }
        FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    /// Settings, Apps that speak through TurnOver: each app asked about, allowed or not, Right Arrow to change.
    /// The apps that have asked to speak through TurnOver, for the Settings window: id, name, allowed.
    public var appDecisions: [(id: String, name: String, allowed: Bool)] {
        decisions.sorted { $0.value.name.lowercased() < $1.value.name.lowercased() }.map { ($0.key, $0.value.name, $0.value.allowed) }
    }
    public func setAllowed(_ id: String, _ on: Bool) {
        guard decisions[id] != nil else { return }
        decisions[id]?.allowed = on; save(); tellAll(id)
    }

    func menuItems() -> [MenuItem] {
        guard !decisions.isEmpty else { return [MenuItem("No app has asked yet", .action {})] }
        return decisions.sorted { $0.value.name.lowercased() < $1.value.name.lowercased() }.map { id, v in
            MenuItem(v.name, .toggle(get: { [weak self] in self?.decisions[id]?.allowed ?? false },
                                     set: { [weak self] on in self?.decisions[id]?.allowed = on; self?.save(); self?.tellAll(id) }),
                     hint: "Allowed: it can make TurnOver speak while it is the app in front")
        }
    }

    // MARK: Who it is (off the main thread)

    /// The program at the other end of a connection to this Mac's port: the process holding the other end, found in
    /// the kernel's own list of each process's sockets, then named by its code signature.
    nonisolated static func identify(remotePort: UInt16, ourPort: UInt16) -> Speaker? {
        guard let pid = pid(holdingLocalPort: remotePort, connectedTo: ourPort) else { return nil }
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = length > 0 ? String(decoding: pathBuffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
        let exe = URL(fileURLWithPath: path).lastPathComponent
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? (exe.isEmpty ? "a program" : exe)
        var id = "path:\(path)"
        var code: SecCode?
        if SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary, [], &code) == errSecSuccess, let code {
            var staticCode: SecStaticCode?
            var info: CFDictionary?
            if SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
               SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
               let d = info as? [String: Any], let team = d[kSecCodeInfoTeamIdentifier as String] as? String,
               let identifier = d[kSecCodeInfoIdentifier as String] as? String {
                id = "team:\(team)/\(identifier)"
            }
        }
        return Speaker(id: id, name: name, pid: pid, isWine: Games.isWineProcess(name: name, path: path))
    }

    /// The process with a TCP socket from `localPort` to `ourPort` on this Mac.
    nonisolated static func pid(holdingLocalPort localPort: UInt16, connectedTo ourPort: UInt16) -> pid_t? {
        let me = getpid()
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        for pid in pids.prefix(Int(max(0, got))) where pid > 0 && pid != me {
            let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard bytes > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.size)
            let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bytes)
            guard filled > 0 else { continue }
            for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                var info = socket_fdinfo()
                let size = Int32(MemoryLayout<socket_fdinfo>.size)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size, info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
                let ini = info.psi.soi_proto.pri_tcp.tcpsi_ini
                let l = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport))
                let f = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_fport))
                if l == localPort, f == ourPort { return pid }
            }
        }
        return nil
    }
}

/// A connection's speaker, once known, and the lines that came before it was.
final class SpeakerBox {
    var speaker: SpeechPort.Speaker?
    var held: [String] = []
}
