// SPDX-License-Identifier: GPL-3.0-or-later
// When an app change may hand the Mac to the other reader (18 Nov 2026). On 18 Nov 2026 at 07:32, Command Tab between
// Claude and Safari (pinned to VoiceOver) switched readers seven times in 40 s: each activation that came during a
// hand-over set its own check 1.6 s later, each check handed over for whatever was in front then, one of them for an
// app already left, and one gave up ("VoiceOver still changing after 2 s; not toggled") and left Safari with the wrong
// reader until the next switch. Now one check at a time decides for the app in front once nothing is moving: Command
// let go (the switcher closed), no hand-over under way, VoiceOver wholly on or wholly off, and the old 1.5 s since the
// last hand-over. Activations meanwhile only make sure a check is waiting: the reader settles on the last app alone.
import Foundation

nonisolated public enum HandOverSettle {
    nonisolated public struct Standing: Equatable {
        public var commandHeld: Bool            // Command is down: the switcher can still be open
        public var handOverUnderWay: Bool       // a hand-over has posted and not yet seen its answer
        public var voiceOverSettled: Bool       // VoiceOver's flag and its process agree (not starting or stopping)
        public var sinceLastHandOver: TimeInterval
        public init(commandHeld: Bool, handOverUnderWay: Bool, voiceOverSettled: Bool, sinceLastHandOver: TimeInterval) {
            self.commandHeld = commandHeld; self.handOverUnderWay = handOverUnderWay
            self.voiceOverSettled = voiceOverSettled; self.sinceLastHandOver = sinceLastHandOver
        }
    }

    public enum Decision: Equatable { case decideNow, wait, giveUp }

    /// The old spacing between hand-overs (a toggle while VoiceOver is still starting or stopping is swallowed).
    public static let spacing: TimeInterval = 1.5
    /// How long a check waits for things to settle (the hand-over's own longest wait for VoiceOver to settle). Past
    /// it the reader is decided anyway, as before, and the hand-over's own checks deal with a VoiceOver that never
    /// settles (its flag on with no VoiceOver running); only Command still held gives up, for the next switch.
    public static let limit: TimeInterval = 6
    /// How often a waiting check looks.
    public static let interval: TimeInterval = 0.15

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
        if waited < limit { return .wait }
        return s.commandHeld ? .giveUp : .decideNow
    }
}
