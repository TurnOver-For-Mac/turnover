// SPDX-License-Identifier: GPL-3.0-or-later
// What an app was doing when it stopped answering (11 Nov 2026). Safari hung four seconds after a page loaded and
// stayed hung until it was force-quit seven minutes later; macOS wrote no hang report, so where Safari was stuck, and
// whether one of TurnOver's own questions had set it off, could not be told afterwards. With the switch on, the
// moment an app in front stops answering its stacks are written to a file beside the log, with macOS's own `sample`
// tool: Safari's, and those of its newest page processes (a page's own process can be what stopped, while Safari
// itself goes on answering). The files hold function names, never what was on screen.
//
// Off unless a developer turns it on: `defaults write com.turnover.reader sampleOnStall -bool true`.
import Foundation

nonisolated public enum StallSample {
    static var wanted: Bool { UserDefaults.standard.bool(forKey: "sampleOnStall") }
    private static let queue = DispatchQueue(label: "turnover.stall.sample", qos: .utility)
    private static let lock = NSLock()
    // Swift cannot express static NSLock ownership. Every access holds lock.
    nonisolated(unsafe) private static var lastAt: [pid_t: Date] = [:]
    /// The fewest seconds between two samples of one app, and the most files kept.
    static let gap: TimeInterval = 60
    static let kept = 24

    /// Seconds out of macOS ps's elapsed time: "38:35", "02:28:44" or "1-07:54:16" (days first). Nil if it is none
    /// of those. macOS's ps has no field for the seconds themselves (a review, 11 Nov 2026). Pure.
    public nonisolated static func seconds(elapsed: Substring) -> Int? {
        let dayAndClock = elapsed.split(separator: "-", maxSplits: 1)
        guard let clock = dayAndClock.last else { return nil }
        let days = dayAndClock.count == 2 ? Int(dayAndClock[0]) : 0
        let parts = clock.split(separator: ":").map { Int($0) }
        guard let days, (2...3).contains(parts.count), !parts.contains(nil) else { return nil }
        let clockSeconds = parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        return days * 86_400 + clockSeconds
    }

    /// The newest `count` web content processes in `ps -axo pid=,etime=,comm=` output, newest first. Pure. Whose
    /// they are is not known from this: another app's page process can be among them.
    public nonisolated static func newestWebContent(in ps: String, count: Int) -> [pid_t] {
        var found: [(pid: pid_t, age: Int)] = []
        for line in ps.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, fields[2].contains("com.apple.WebKit.WebContent"),
                  let pid = pid_t(fields[0]), let age = seconds(elapsed: fields[1]) else { continue }
            found.append((pid, age))
        }
        return found.sorted { $0.age < $1.age }.prefix(count).map(\.pid)
    }

    /// Whether another sample of an app is due, `gap` seconds after the last. Pure.
    public nonisolated static func due(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= gap
    }

    /// Sample `pid` (and Safari's newest page processes) in the background. Returns at once.
    public nonisolated static func take(pid: pid_t, name: String, bundleID: String?, logPath: String) {
        guard wanted, !logPath.isEmpty else { return }
        lock.lock()
        let isDue = due(last: lastAt[pid], now: Date())
        if isDue { lastAt[pid] = Date() }
        lock.unlock()
        guard isDue else { return }
        let folder = URL(fileURLWithPath: logPath).deletingLastPathComponent().appendingPathComponent("stalls")
        queue.async {
            let files = FileManager.default
            try? files.createDirectory(at: folder, withIntermediateDirectories: true)
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(identifier: "UTC")
            format.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"
            let stamp = format.string(from: Date())
            let label = name.filter { $0.isLetter || $0.isNumber }
            var targets: [(pid: pid_t, label: String)] = [(pid, label.isEmpty ? "app" : label)]
            if bundleID == "com.apple.Safari", let ps = run("/bin/ps", ["-axo", "pid=,etime=,comm="]) {
                targets += newestWebContent(in: ps, count: 3).map { ($0, "WebContent") }
            }
            for target in targets {
                let file = folder.appendingPathComponent("stall-\(stamp)-\(target.label)-\(target.pid).txt")
                _ = run("/usr/bin/sample", [String(target.pid), "2", "-mayDie", "-file", file.path])
            }
            // The oldest go once there are more than `kept`.
            if let all = try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) {
                let dated = all.compactMap { url in (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { (url, $0) } }
                for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(kept) { try? files.removeItem(at: url) }
            }
        }
    }

    /// A tool run to its end, its output as text; nil if it could not be started.
    private nonisolated static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
