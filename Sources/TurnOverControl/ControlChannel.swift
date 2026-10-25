// SPDX-License-Identifier: GPL-3.0-or-later
// TurnOver's control channel (18 Oct 2026, the code review: "any program on the Mac can change TurnOver's settings or
// make it speak"). TurnOver Settings' changes, TurnOver Key's on/off, the plugin tool's key tries and Windy's words
// went to TurnOver as distributed notifications, which any program can post and any program can hear (TurnOver
// answered every settings request with the whole of its settings, to anyone listening).
//
// Now they come down a local socket in TurnOver's own folder, and each program that connects is checked before a
// word of it is read: it must be signed by the same developer as TurnOver itself (the Team ID in its code signature,
// checked by macOS's own code-signing service against the connecting process, not anything it says about itself).
// Anything else is turned away and logged. Answers go only to the program that asked.
//
// The messages are JSON objects, one a line: {"op": "patch", "json": "..."} and so on; each op is handled by TurnOver
// (ControlServer.handle). A program's connection can stay open to hear TurnOver's answers as they come (Settings).
import Foundation
import Security

/// Where the channel is: in TurnOver's own support folder.
public enum ControlChannel {
    public static func socketPath(folder: String = "TurnOver") -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(folder, isDirectory: true).appendingPathComponent("control.sock").path
    }

    /// A Unix socket address for the path (nil if the path is too long for one).
    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    /// One line of JSON.
    static func encode(_ message: [String: Any]) -> Data? {
        guard var d = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        d.append(0x0A)
        return d
    }

    // MARK: Who is on the other end

    /// This program's own Team ID (nil when it isn't signed by a developer: a build on a Mac without one).
    public static let ownTeam: String? = {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    /// The process on the other end of a connected socket is signed by our developer: macOS's code-signing service
    /// checks the running process (by its audit token, which it can't fake) against "signed through Apple, this
    /// Team ID". An unsigned TurnOver (a build without a developer certificate, as anyone building from source makes)
    /// accepts only programs inside its own app bundle (TurnOver Key, TurnOver Settings), found from the audit
    /// token's process: "same user" let any program make it speak or change its settings (a code review on
    /// 20 Oct 2026).
    public static func peerIsTrusted(_ fd: Int32) -> (Bool, String) {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return (false, "no audit token") }
        guard let team = ownTeam else {
            let pid = pid_t(bitPattern: token.val.5)
            guard let mine = outermostApp(of: Bundle.main.executablePath ?? ""), let theirs = outermostApp(of: executablePath(of: pid)) else {
                return (false, "TurnOver unsigned: the caller isn't inside an app")
            }
            return mine == theirs ? (true, "TurnOver unsigned: a program inside TurnOver") : (false, "TurnOver unsigned: a program outside TurnOver")
        }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &code) == errSecSuccess, let code else {
            return (false, "not identified")
        }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return (false, "no requirement") }
        let ok = SecCodeCheckValidity(code, [], requirement) == errSecSuccess
        return (ok, ok ? "signed by this developer" : "not signed by this developer")
    }

    /// A process's executable, by its pid ("" if it can't be read).
    static func executablePath(of pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "" }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The outermost app bundle a path is inside: ".../TurnOver.app" for TurnOver, TurnOver Key and TurnOver Settings.
    static func outermostApp(of path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return (String(path[..<r.lowerBound]) + ".app" as NSString).resolvingSymlinksInPath
    }
}

// MARK: - The server (TurnOver)

/// TurnOver's end: accepts, checks, reads lines, hands each message to `handle` on the main thread.
public final class ControlServer: @unchecked Sendable {
    public static let shared = ControlServer()
    /// One message: its fields, and a way to answer the program that sent it.
    public typealias Handler = @MainActor (_ message: [String: Any], _ reply: @escaping @Sendable ([String: Any]) -> Void) -> Void
    /// Set by TurnOver: the ops it answers ("patch", "ask", "say", "try"…). Main thread only.
    nonisolated(unsafe) public var handlers: [String: Handler] = [:]
    /// Lines for TurnOver's log (set by TurnOver; the channel has no logging of its own). Main thread only.
    nonisolated(unsafe) public var log: @MainActor (String) -> Void = { _ in }

    private let queue = DispatchQueue(label: "turnover.control")
    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [Int32: (source: DispatchSourceRead, buffer: Data)] = [:]
    /// Connections that asked to hear the settings as they change (Settings).
    private var subscribers = Set<Int32>()

    /// Listening at `path`. False if the socket couldn't be made (logged).
    @MainActor @discardableResult
    public func start(path: String) -> Bool {
        guard listener < 0 else { return true }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var addr = ControlChannel.address(path) else { log("control: no socket"); return false }
        unlink(path)   // one left by a TurnOver that crashed
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0 else { log("control: couldn't bind (\(errno))"); close(fd); return false }
        chmod(path, 0o600)   // this user only
        guard listen(fd, 8) == 0 else { log("control: couldn't listen (\(errno))"); close(fd); return false }
        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.resume()
        acceptSource = source
        log("control: listening\(ControlChannel.ownTeam == nil ? " (TurnOver unsigned: only programs inside TurnOver)" : "")")
        return true
    }

    private func acceptOne() {
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { return }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let (trusted, why) = ControlChannel.peerIsTrusted(fd)
        guard trusted else {
            close(fd)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.log("control: a program turned away (\(why))") } }
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.read(fd) }
        source.setCancelHandler { close(fd) }
        clients[fd] = (source, Data())
        source.resume()
    }

    private func read(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = Darwin.read(fd, &chunk, chunk.count)
        guard n > 0 else { drop(fd); return }
        guard var entry = clients[fd] else { return }
        entry.buffer.append(contentsOf: chunk[0..<n])
        // A program that sends a megabyte without a line end is not one of ours.
        if entry.buffer.count > 1_000_000 { drop(fd); return }
        while let end = entry.buffer.firstIndex(of: 0x0A) {
            let line = entry.buffer[entry.buffer.startIndex..<end]
            entry.buffer.removeSubrange(entry.buffer.startIndex...end)
            guard let message = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any], let op = message["op"] as? String else { continue }
            if op == "subscribe" { subscribers.insert(fd) }
            let reply: @Sendable ([String: Any]) -> Void = { [weak self] answer in self?.send(answer, to: fd) }
            nonisolated(unsafe) let m = message
            DispatchQueue.main.async { MainActor.assumeIsolated {
                if let h = self.handlers[op] { h(m, reply) } else if op != "subscribe" { self.log("control: unknown op \(op)") }
            } }
        }
        clients[fd] = entry
    }

    private func drop(_ fd: Int32) {
        subscribers.remove(fd)
        clients.removeValue(forKey: fd)?.source.cancel()
    }

    private func send(_ message: [String: Any], to fd: Int32) {
        guard let data = ControlChannel.encode(message) else { return }
        queue.async { [weak self] in
            guard self?.clients[fd] != nil else { return }
            data.withUnsafeBytes { _ = write(fd, $0.baseAddress, data.count) }
        }
    }

    /// To every program that asked to hear (Settings): the settings as they now are.
    public func broadcast(_ message: [String: Any]) {
        guard let data = ControlChannel.encode(message) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            for fd in self.subscribers { data.withUnsafeBytes { _ = write(fd, $0.baseAddress, data.count) } }
        }
    }
}

// MARK: - The clients (TurnOver Settings, TurnOver Key, the plugin tool, Windy)

public enum ControlClient {
    /// Connected to TurnOver's channel; nil if TurnOver isn't listening.
    public static func connect(folder: String = "TurnOver") -> Int32? {
        let path = ControlChannel.socketPath(folder: folder)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var addr = ControlChannel.address(path) else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0 else { close(fd); return nil }
        return fd
    }

    /// One message; with `waitFor`, the first answer within that many seconds (nil if none). False-y: TurnOver not there.
    public static func send(_ message: [String: Any], folder: String = "TurnOver", waitFor seconds: Double? = nil) -> (sent: Bool, answer: [String: Any]?) {
        guard let fd = connect(folder: folder) else { return (false, nil) }
        defer { close(fd) }
        guard let data = ControlChannel.encode(message), write(fd, (data as NSData).bytes, data.count) == data.count else { return (false, nil) }
        guard let seconds else {
            // Stay connected until TurnOver has read it (it closes its end): closed at once, TurnOver could no longer
            // ask the system who had sent it ("no audit token") and turned every message away; the plugin tool's
            // try went unanswered (the untuned-apps survey, 19 Oct 2026). At most a second.
            shutdown(fd, SHUT_WR)
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&p, 1, 1000) > 0 { var b = [UInt8](repeating: 0, count: 256); _ = read(fd, &b, b.count) }
            return (true, nil)
        }
        var buffer = Data()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, Int32(max(1, deadline.timeIntervalSinceNow * 1000))) > 0 else { break }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { break }
            buffer.append(contentsOf: chunk[0..<n])
            if let end = buffer.firstIndex(of: 0x0A) {
                return (true, (try? JSONSerialization.jsonObject(with: buffer[buffer.startIndex..<end])) as? [String: Any])
            }
        }
        return (true, nil)
    }

    /// A connection kept open (Settings): messages sent on it, every line TurnOver sends back handed to `received` on
    /// the main thread, `ended` when TurnOver goes.
    public final class Connection: @unchecked Sendable {
        private let fd: Int32
        private let source: DispatchSourceRead
        private var buffer = Data()

        public init?(folder: String = "TurnOver", received: @escaping @MainActor ([String: Any]) -> Void, ended: @escaping @MainActor () -> Void) {
            guard let fd = ControlClient.connect(folder: folder) else { return nil }
            self.fd = fd
            source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "turnover.control.client"))
            source.setEventHandler { [weak self] in
                guard let self else { return }
                var chunk = [UInt8](repeating: 0, count: 65536)
                let n = read(self.fd, &chunk, chunk.count)
                guard n > 0 else { self.source.cancel(); DispatchQueue.main.async { MainActor.assumeIsolated { ended() } }; return }
                self.buffer.append(contentsOf: chunk[0..<n])
                while let end = self.buffer.firstIndex(of: 0x0A) {
                    let line = self.buffer[self.buffer.startIndex..<end]
                    self.buffer.removeSubrange(self.buffer.startIndex...end)
                    guard let message = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
                    nonisolated(unsafe) let m = message
                    DispatchQueue.main.async { MainActor.assumeIsolated { received(m) } }
                }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
        }

        @discardableResult
        public func send(_ message: [String: Any]) -> Bool {
            guard let data = ControlChannel.encode(message) else { return false }
            return write(fd, (data as NSData).bytes, data.count) == data.count
        }

        deinit { source.cancel() }
    }
}
