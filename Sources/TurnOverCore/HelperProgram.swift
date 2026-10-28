// SPDX-License-Identifier: GPL-3.0-or-later
// A helper program (the Steam program, Trackpad gestures), started without TurnOver's permissions and read a
// line at a time. Built into TurnOver.app/Contents/Helpers from the open source in the plugins repository.
// If it ends on its own it is started again, up to three times when it keeps dying at once; it quits by itself
// when TurnOver goes (its input closes).
import Foundation

final class HelperProgram {
    nonisolated(unsafe) private static var live: [pid_t: HelperProgram] = [:]   // main thread only
    let name: String
    private let arguments: [String]
    private let onLine: (String) -> Void
    private var child: DisclaimedSpawn.Child?
    private var lines = HelperLines()
    private var stopping = false
    private var startedAt = Date()
    private var restarts = 0
    var onGiveUp: (() -> Void)?
    var isRunning: Bool { child != nil }

    init(name: String, arguments: [String] = [], onLine: @escaping (String) -> Void) {
        self.name = name; self.arguments = arguments; self.onLine = onLine
    }

    static func path(_ name: String) -> String? {
        let p = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    func start() {
        stopping = false
        guard let path = Self.path(name) else { Log.warning("\(name): the program is missing from TurnOver.app"); return }
        let pidBox = Locked(pid_t(0))
        let ended: @Sendable (Int32) -> Void = { status in
            let pid = pidBox.value
            DispatchQueue.main.async { MainActor.assumeIsolated { HelperProgram.ended(pid: pid, status: status) } }
        }
        guard let (child, disclaimed) = DisclaimedSpawn.run(path, arguments: arguments, directory: nil, exited: ended) else {
            Log.warning("\(name): couldn't start"); return
        }
        self.child = child; startedAt = Date()
        let pid = child.pid
        pidBox.value = pid
        Self.live[pid] = self
        child.stdout.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { HelperProgram.live[pid]?.received(d) } }
        }
        let label = name
        child.stderr.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            let text = String(decoding: d, as: UTF8.self)
            DispatchQueue.main.async { Log.info("\(label) (errors): \(Log.words(String(text.prefix(300))))") }
        }
        Log.info("\(name): started (pid \(pid)\(disclaimed ? ", without TurnOver's permissions" : "; WARNING: it may have TurnOver's permissions"))")
    }

    private static func ended(pid: pid_t, status: Int32) {
        guard let helper = live.removeValue(forKey: pid) else { return }
        helper.child = nil
        guard !helper.stopping else { return }
        Log.warning("\(helper.name): ended (status \(status))")
        if Date().timeIntervalSince(helper.startedAt) > 60 { helper.restarts = 0 }
        guard helper.restarts < 3, status != 2 << 8 else {   // exit 2: it can't work on this Mac (no trackpad, an API gone)
            Log.warning("\(helper.name): left off"); helper.onGiveUp?(); return
        }
        helper.restarts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard !helper.stopping, helper.child == nil else { return }
            helper.start()
        }
    }

    private func received(_ data: Data) {
        for line in lines.add(data) where !line.isEmpty {
            // Helpers can include page text or error details in diagnostics (issue 68, 28 Oct 2026).
            if line.hasPrefix("L ") { Log.info("\(name): \(Log.words(String(line.dropFirst(2).prefix(300))))") } else { onLine(line) }
        }
    }

    func send(_ command: String) {
        guard let child else { return }
        try? child.stdin.write(contentsOf: Data((command + "\n").utf8))
    }

    func stop() {
        stopping = true
        guard let child else { return }
        try? child.stdin.close()
        let pid = child.pid
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if kill(pid, 0) == 0 { kill(pid, SIGTERM) } }
        Log.info("\(name): stopping (pid \(pid))")
    }
}
