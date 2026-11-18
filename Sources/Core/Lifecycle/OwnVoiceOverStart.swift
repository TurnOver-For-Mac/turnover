// SPDX-License-Identifier: GPL-3.0-or-later
// VoiceOver started by TurnOver itself, outside a hand-over: the watchdog, the quit, speech or the keyboard failing.
// Its arrival is not the person's choice, and must never pin the app in front to VoiceOver "by hand" or count as
// yielding to VoiceOver. It can arrive seconds later, in the next TurnOver: on 17 Nov 2026 the watchdog opened
// VoiceOver at 10:16:20, the restarted TurnOver started at 10:16:26 with VoiceOver still off, and VoiceOver came at
// 10:16:30, past the new process's three seconds of grace, so Mail was "pinned to VoiceOver by hand" (18 Nov 2026).
//
// The request is a record in a file, so every TurnOver process knows it. It answers for one VoiceOver start only:
// the first "VoiceOver is on" after it takes it (and deletes it); VoiceOver going off, or any hand-over TurnOver posts,
// cancels it, so the person's own toggle after either counts as theirs (Codex's review, 18 Nov 2026). A record older
// than the window, or dated ahead of the clock (the clock went back), is no evidence and is deleted.
import Foundation

nonisolated public enum OwnVoiceOverStart {
    /// How long after TurnOver asked for VoiceOver its coming on is still TurnOver's doing: 9.8 s was measured on
    /// 17 Nov 2026 (the watchdog's request to VoiceOver reading, across a restart); twice that, rounded.
    public static let window: TimeInterval = 20

    public enum Verdict: Equatable { case ours, none, stale }

    /// VoiceOver came on at `now`, both in seconds since 1970: is it the arrival of TurnOver's own request, made at
    /// `askedAt` by this TurnOver or the one before it?
    public static func judge(askedAt: TimeInterval?, now: TimeInterval) -> Verdict {
        guard let askedAt else { return .none }
        let age = now - askedAt
        return age >= 0 && age < window ? .ours : .stale
    }

    /// The file's contents for a request at `time`, and back.
    public static func encode(_ time: TimeInterval) -> String { String(format: "%.3f", time) }
    public static func decode(_ text: String) -> TimeInterval? {
        Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The record itself, in `url`. Any thread: the quit writes it from a signal handler, off the main thread.
    nonisolated public final class Record: @unchecked Sendable {
        public let url: URL
        private let lock = NSLock()
        public init(url: URL) { self.url = url }

        /// TurnOver is starting VoiceOver itself now.
        public func note(now: TimeInterval = Date().timeIntervalSince1970) {
            lock.lock(); defer { lock.unlock() }
            try? OwnVoiceOverStart.encode(now).write(to: url, atomically: true, encoding: .utf8)
        }

        /// "VoiceOver is on" came at `now`: true if it is TurnOver's own start. The record is used up either way.
        public func take(now: TimeInterval = Date().timeIntervalSince1970) -> Verdict {
            lock.lock(); defer { lock.unlock() }
            let asked = (try? String(contentsOf: url, encoding: .utf8)).flatMap(OwnVoiceOverStart.decode)
            let verdict = OwnVoiceOverStart.judge(askedAt: asked, now: now)
            if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
            return verdict
        }

        /// VoiceOver went off, or TurnOver posted a hand-over: the start the record was for is no longer what comes next.
        public func cancel() {
            lock.lock(); defer { lock.unlock() }
            if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
        }

        public var isPending: Bool { FileManager.default.fileExists(atPath: url.path) }
    }
}
