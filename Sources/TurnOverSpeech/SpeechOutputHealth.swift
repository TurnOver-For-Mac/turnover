// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Evidence that required speech failed to progress through the output pipeline, not a measurement of audibility.
public struct SpeechOutputFailure: Sendable {
    public enum Stage: Sendable { case rendering, playback }
    public let stage: Stage
    private let incident: SpeechOutputIncident

    fileprivate init(stage: Stage, incident: SpeechOutputIncident) {
        self.stage = stage
        self.incident = incident
    }

    /// The main-actor owner claims only after checking its current reader choice. Cancellation or recovered output
    /// invalidates an unclaimed delivery, including one already waiting on main.
    public func claim() -> Bool { incident.claim() }
}

/// The incident is passed from the speech queue to main. Swift cannot express NSLock ownership: every read and write
/// of pending, including cancellation, reporting, claim and teardown, holds lock. No audio or owner callback runs held.
public final class SpeechOutputIncident: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = true

    fileprivate init() {}
    fileprivate var isPending: Bool { lock.lock(); defer { lock.unlock() }; return pending }
    fileprivate func invalidate() { lock.lock(); pending = false; lock.unlock() }
    fileprivate func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pending else { return false }
        pending = false
        return true
    }
}

/// Audio-free lifecycle used by SpeechPlayer. Rendering may finish or time out before this independent deadline:
/// that must not discard the failure (28 Oct 2026, issue 71). All mutable state, from setup through cancellation and
/// teardown, is under lock because main must invalidate a queued failure without waiting for audio work. Callbacks
/// and audio operations happen outside the lock; Swift's checked Sendable cannot express this NSLock ownership.
public final class SpeechOutputHealth: @unchecked Sendable {
    private let lock = NSLock()
    private let timeout: TimeInterval
    private var enabled = true
    private var paused = false
    private var incident: SpeechOutputIncident?
    private var deadline: TimeInterval = 0
    private var hasFrames = false
    private var scheduledAtSample: Int64?
    private var lastSample: Int64?

    public init(timeout: TimeInterval = 4) { self.timeout = timeout }

    deinit { lock.lock(); clear(); lock.unlock() }

    public var isWaiting: Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled && !paused && incident?.isPending == true
    }

    public func setEnabled(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        enabled = value
        if !value { clear() }
    }

    public func setPaused(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        paused = value
        if value { clear() }
    }

    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        clear()
    }

    /// Repeated zero-frame render attempts share the first deadline, rather than keeping silence alive indefinitely.
    public func request(hasWords: Bool, now: TimeInterval) -> SpeechOutputIncident? {
        lock.lock(); defer { lock.unlock() }
        guard enabled, !paused, hasWords else { return nil }
        if let incident, incident.isPending { return incident }
        let next = SpeechOutputIncident()
        incident = next
        deadline = now + timeout
        hasFrames = false
        scheduledAtSample = nil
        return next
    }

    public func scheduledFrames(for request: SpeechOutputIncident?, sampleTime: Int64?) {
        lock.lock(); defer { lock.unlock() }
        guard let request, request === incident, request.isPending else { return }
        if !hasFrames { scheduledAtSample = sampleTime }
        hasFrames = true
    }

    public func playbackProgress(for request: SpeechOutputIncident?) {
        lock.lock(); defer { lock.unlock() }
        guard let request, request === incident, hasFrames else { return }
        clear()
    }

    /// A node's advancing sample clock proves pipeline progress even when one long buffer has not completed yet.
    /// Earlier queued speech may still be playing while the new render fails; let it finish before timing silence.
    public func poll(now: TimeInterval, sampleTime: Int64?, hasQueuedAudio: Bool) -> SpeechOutputFailure? {
        lock.lock(); defer { lock.unlock() }
        defer { lastSample = sampleTime }
        guard enabled, !paused, let incident, incident.isPending else { return nil }
        if hasQueuedAudio, let sampleTime, let previous = lastSample, sampleTime > previous {
            if hasFrames, scheduledAtSample.map({ sampleTime > $0 }) ?? true { clear(); return nil }
            deadline = now + timeout
        }
        guard now >= deadline else { return nil }
        return SpeechOutputFailure(stage: hasFrames ? .playback : .rendering, incident: incident)
    }

    private func clear() {
        incident?.invalidate()
        incident = nil
        hasFrames = false
        scheduledAtSample = nil
        lastSample = nil
    }
}
