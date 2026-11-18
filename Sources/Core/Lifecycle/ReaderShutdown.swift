// SPDX-License-Identifier: GPL-3.0-or-later
// TurnOver is going (a quit, or stopped from outside): from that moment VoiceOver belongs to the quit handler, which
// brings it back so the Mac is never left without speech (18 Nov 2026, Codex's second review). A settling check or a
// hand-over's own waits, scheduled before the quit, could still run while the quit restored VoiceOver: one could see
// an app TurnOver reads in front and turn VoiceOver off again, and its new choice of reader made the quit's own
// fallback stand down, so TurnOver could exit with VoiceOver off. Once begun, no hand-over runs at all, either way:
// turning VoiceOver off would leave no reader, and even one turning it on would count as a new choice and stop the
// quit's fallback. Any thread: the signal handler begins it off the main thread.
import Foundation

nonisolated public final class ReaderShutdown: @unchecked Sendable {
    private let lock = NSLock()
    private var begunFlag = false
    public init() {}

    /// TurnOver is going. Never undone in this process.
    public func begin() {
        lock.lock(); defer { lock.unlock() }
        begunFlag = true
    }

    public var begun: Bool {
        lock.lock(); defer { lock.unlock() }
        return begunFlag
    }

    /// Whether a hand-over (either way) may still post or go on waiting.
    public var allowsHandOver: Bool { !begun }
}
