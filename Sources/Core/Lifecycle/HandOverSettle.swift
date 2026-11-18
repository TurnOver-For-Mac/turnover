// SPDX-License-Identifier: GPL-3.0-or-later
// When an app change may hand the Mac to the other reader (18 Nov 2026). On 18 Nov 2026 at 07:32, Command Tab between
// Claude and Safari (pinned to VoiceOver) switched readers seven times in 40 s: each activation that came during a
// hand-over set its own check 1.6 s later, each check handed over for whatever was in front then, one of them for an
// app already left, and one gave up ("VoiceOver still changing after 2 s; not toggled") and left Safari with the wrong
// reader until the next switch. Now one check at a time decides for the app in front once nothing is moving: Command
// let go (the switcher closed), no hand-over under way, VoiceOver wholly on or wholly off, and the old 1.5 s since the
// last hand-over. Activations meanwhile only make sure a check is waiting: the reader settles on the last app alone.
//
// Codex's review (18 Nov 2026): the check is never dropped. It waits for Command however long it is held (Escape out
// of the switcher brings no activation, only Command let go), and for a hand-over under way to have its answer (its
// fallback start of VoiceOver can take 12 s; deciding before it ends would leave that start to arrive over the final
// app). Only VoiceOver never settling (its flag on with no VoiceOver) is decided anyway after `limit`.
import Foundation

nonisolated public enum HandOverSettle {
    nonisolated public struct Standing: Equatable, Sendable {
        public var commandHeld: Bool            // Command is down: the switcher can still be open
        public var handOverUnderWay: Bool       // a hand-over has posted and not yet had its answer
        public var voiceOverSettled: Bool       // VoiceOver's flag and its process agree (not starting or stopping)
        public var sinceLastHandOver: TimeInterval
        public init(commandHeld: Bool, handOverUnderWay: Bool, voiceOverSettled: Bool, sinceLastHandOver: TimeInterval) {
            self.commandHeld = commandHeld; self.handOverUnderWay = handOverUnderWay
            self.voiceOverSettled = voiceOverSettled; self.sinceLastHandOver = sinceLastHandOver
        }
    }

    public enum Decision: Equatable {
        case decideNow
        /// Past `limit` with VoiceOver still not settled: decided as before the gate; the hand-over's own checks follow.
        case decideUnsettled
        case wait
    }

    /// The old spacing between hand-overs (a toggle while VoiceOver is still starting or stopping is swallowed).
    public static let spacing: TimeInterval = 1.5
    /// How long a check waits for VoiceOver itself to settle (the hand-over's own longest wait for it).
    public static let limit: TimeInterval = 6
    /// How often a waiting check looks; once past `limit` (Command held long), less often.
    public static let interval: TimeInterval = 0.15
    public static let slowInterval: TimeInterval = 0.5

    /// What is still moving, for the log; nil once the reader may be decided.
    public static func moving(_ s: Standing) -> String? {
        if s.commandHeld { return "Command is held" }
        if s.handOverUnderWay { return "a hand-over is under way" }
        if !s.voiceOverSettled { return "VoiceOver is still starting or stopping" }
        if s.sinceLastHandOver < spacing { return "the last hand-over was just now" }
        return nil
    }

    /// A check that has waited `waited` seconds.
    public static func decide(_ s: Standing, waited: TimeInterval) -> Decision {
        if moving(s) == nil { return .decideNow }
        if s.commandHeld || s.handOverUnderWay { return .wait }   // never dropped: a release or an answer ends these
        return waited < limit ? .wait : .decideUnsettled
    }
}

/// The one waiting check, driven by the lead watcher; the clock and the scheduling are given, so a test can drive it.
public final class HandOverSettler {
    public var standing: @MainActor () -> HandOverSettle.Standing
    public var now: @MainActor () -> TimeInterval
    public var schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void
    /// Decide the reader for the app in front now; `unsettled`: past the limit, VoiceOver still not settled.
    public var decide: @MainActor (_ unsettled: Bool) -> Void
    public var log: @MainActor (String) -> Void
    public private(set) var waiting = false
    private var startedAt: TimeInterval = 0

    public init(standing: @escaping @MainActor () -> HandOverSettle.Standing, now: @escaping @MainActor () -> TimeInterval,
                schedule: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void,
                decide: @escaping @MainActor (Bool) -> Void, log: @escaping @MainActor (String) -> Void) {
        self.standing = standing; self.now = now; self.schedule = schedule; self.decide = decide; self.log = log
    }

    /// Something may need a hand-over: make sure one check is waiting. Later requests find it waiting.
    public func request(_ why: String) {
        guard !waiting else { log("lead watcher: \(why); the waiting check decides"); return }
        waiting = true
        startedAt = now()
        log("lead watcher: \(why); deciding once it settles, for the app in front then")
        schedule(HandOverSettle.interval) { [weak self] in self?.check() }
    }

    private func check() {
        let s = standing()
        let waited = now() - startedAt
        switch HandOverSettle.decide(s, waited: waited) {
        case .wait:
            schedule(waited < HandOverSettle.limit ? HandOverSettle.interval : HandOverSettle.slowInterval) { [weak self] in self?.check() }
        case .decideNow:
            waiting = false
            log("lead watcher: settled after \(Int(waited * 1000)) ms; the app in front decides")
            decide(false)
        case .decideUnsettled:
            waiting = false
            log("lead watcher: \(HandOverSettle.moving(s) ?? "unsettled") after \(Int(waited)) s; deciding anyway")
            decide(true)
        }
    }
}
