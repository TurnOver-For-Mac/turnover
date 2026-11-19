// SPDX-License-Identifier: GPL-3.0-or-later
// The prepared players of one sound set, made off the main thread (19 Nov 2026: reading and levelling a file, building its
// player and prepareToPlay() on main, the first time each file was asked for, held up speech and keys).
import Foundation
import AVFoundation

/// A sound set's prepared players. Preparing runs on one serial background queue; the main thread only looks a player up.
// @unchecked Sendable because AVAudioPlayer is not Sendable. Every field is read and written only with `lock` held. A
// player is made on `queue`, stored under the lock, and from then on used only by the main thread (volume, play), which
// takes it from the dictionary under the lock: it is handed over once and never touched by both at the same time.
nonisolated package final class SoundCache: @unchecked Sendable {
    package init() {}
    private let lock = NSLock()
    private var ready: [String: AVAudioPlayer] = [:]
    private var failed: Set<String> = []
    private var waiting: [String: [@Sendable (Bool) -> Void]] = [:]
    private var hold: DispatchSemaphore?
    private let queue = DispatchQueue(label: "turnover.sounds.prepare", qos: .utility)

    /// The prepared player, or nil if the file is not prepared yet (or cannot be).
    package func player(_ name: String) -> AVAudioPlayer? { lock.lock(); defer { lock.unlock() }; return ready[name] }
    /// The file was tried and cannot be played.
    package func hasFailed(_ name: String) -> Bool { lock.lock(); defer { lock.unlock() }; return failed.contains(name) }
    /// A test holds preparation here, to see a request return before anything is prepared.
    package func setHold(_ s: DispatchSemaphore?) { lock.lock(); hold = s; lock.unlock() }

    /// Prepares the file in the background; `done` (called on the queue) says whether a player is now ready. Returns at
    /// once, never preparing on the calling thread. A file already being prepared is not prepared twice.
    package func request(_ name: String, url: URL, levelled: Bool, done: (@Sendable (Bool) -> Void)? = nil) {
        lock.lock()
        if ready[name] != nil { lock.unlock(); done?(true); return }
        if failed.contains(name) { lock.unlock(); done?(false); return }
        let busy = waiting[name] != nil
        waiting[name, default: []].append(done ?? { _ in })
        lock.unlock()
        if busy { return }
        queue.async { [self] in
            lock.lock(); let h = hold; lock.unlock()
            h?.wait()
            var made: AVAudioPlayer?
            if levelled { if let data = VoiceOverSounds.levelled(url) { made = try? AVAudioPlayer(data: data) } }
            else { made = try? AVAudioPlayer(contentsOf: url) }
            made?.prepareToPlay()
            lock.lock()
            if let made { ready[name] = made } else { failed.insert(name) }
            let calls = waiting.removeValue(forKey: name) ?? []
            lock.unlock()
            for c in calls { c(made != nil) }
        }
    }
}
