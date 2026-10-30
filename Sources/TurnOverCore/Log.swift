// SPDX-License-Identifier: GPL-3.0-or-later
// The log is the primary diagnostic (NVDA: logHandler). TurnOver narrates its
// startup, every permission answer, every event it acts on, every gesture and
// the script it resolved to, and everything it says.
import Foundation
import AppKit

nonisolated public enum Log {
    public enum Level: Int, Comparable { case debug = 0, io, info, warning, error
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }
    nonisolated(unsafe) private static var handle: FileHandle?
    private static let started = Date()
    private static let lock = NSLock()
    nonisolated(unsafe) public private(set) static var path = ""
    /// Lines below this level are dropped. `io` logs every gesture and event.
    nonisolated(unsafe) public static var level: Level = .io

    public static func open(name: String = "turnover") {
        let dir = AppPaths.file("logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // TurnOver's own logs older than 30 days go (they record what was said on screen; no need to keep them).
        let old = Date().addingTimeInterval(-30 * 24 * 3600)
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where f.pathExtension == "log" && ((try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()) < old {
            try? FileManager.default.removeItem(at: f)
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let url = dir.appendingPathComponent("\(name)-\(stamp).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        path = url.path
        info("TurnOver pid \(getpid()), log \(url.path)")
    }

    /// Echo to stderr only when it is a terminal: a pipe nobody reads fills, and then every log line (the keyboard
    /// thread's among them) would block (E6 audit, 4 Oct 2026).
    private static let toTerminal = isatty(STDERR_FILENO) != 0

    public static func line(_ text: String, level: Level = .info) {
        guard level >= self.level else { return }
        let t = String(format: "%9.3f", Date().timeIntervalSince(started))
        let tag: String
        switch level { case .debug: tag = "D "; case .io: tag = "IO "; case .info: tag = ""; case .warning: tag = "WARN "; case .error: tag = "ERROR " }
        let out = "[\(t)] \(tag)\(text)\n"
        lock.lock(); defer { lock.unlock() }
        // The throwing write: the old one raises an Objective-C exception when the disk is full, and that ended
        // TurnOver (12 Oct 2026, the Mac's disk filled by a voice model; VoiceOver couldn't start either). A line
        // that can't be written is lost, counted, and noted once writing works again.
        if let handle {
            do {
                if lost > 0 { try handle.write(contentsOf: Data("[\(t)] WARN \(lost) log lines lost (the disk was full)\n".utf8)); lost = 0 }
                try handle.write(contentsOf: Data(out.utf8))
            } catch { lost += 1 }
        }
        if toTerminal { try? FileHandle.standardError.write(contentsOf: Data(out.utf8)) }
    }
    nonisolated(unsafe) private static var lost = 0

    public static func debug(_ t: @autoclosure () -> String) { if level <= .debug { line(t(), level: .debug) } }
    /// Words from the screen (a control's name, a page's address, a title) as the log may keep them: the words on a
    /// developer's Mac (`logSpeech`), their length everywhere else, so a log never holds what someone was reading.
    nonisolated public static func words(_ s: String) -> String {
        if Edition.devDefault("logSpeech") { return s }
        return s.isEmpty ? "" : "(\(s.count) characters)"
    }
    public static func io(_ t: @autoclosure () -> String) { if level <= .io { line(t(), level: .io) } }
    public static func info(_ t: String) { line(t, level: .info) }
    public static func warning(_ t: String) { line(t, level: .warning) }
    public static func error(_ t: String) { line(t, level: .error) }

    /// NVDA+Control+Shift+F1: the first press marks where the log is; the second copies the log from there to the
    /// clipboard (NVDA's "copy part of the log").
    nonisolated(unsafe) private static var markedAt: UInt64?   // main thread only
    @MainActor public static func markOrCopy() {
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
        guard let from = markedAt else {
            markedAt = size
            Speech.speakMessage(String(localized: "log start marked; press again to copy from here", comment: "Spoken message"))
            return
        }
        markedAt = nil
        guard let h = FileHandle(forReadingAtPath: path) else { Speech.speakMessage(String(localized: "the log can't be read", comment: "Spoken message")); return }
        defer { try? h.close() }
        try? h.seek(toOffset: min(from, size))
        let text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Speech.speakMessage(String(localized: "copied \(String(text.split(separator: "\n").count)) lines of the log", comment: "Part of the log copied: how many lines"))
    }
}
