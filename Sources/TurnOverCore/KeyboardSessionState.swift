// SPDX-License-Identifier: GPL-3.0-or-later
// The keyboard's request and worker are separate: stopping during setup must cancel that request, and starting
// again must wait for the old worker's teardown (review of #52, 28 Oct 2026). The keyboard owner locks each transition.
nonisolated public struct KeyboardSessionState: Sendable {
    public typealias Generation = UInt64
    private var generation: Generation = 0
    public private(set) var requested: Generation?
    public private(set) var worker: Generation?
    private var ready = false

    public init() {}

    public mutating func requestStart() -> Generation {
        if let requested { return requested }
        generation &+= 1
        requested = generation
        ready = false
        return generation
    }

    public mutating func requestStop() {
        requested = nil
        ready = false
    }

    /// Reserve exactly one worker. A newer request waits until the old one has actually finished teardown.
    public mutating func beginWorker() -> Generation? {
        guard worker == nil, let requested else { return nil }
        worker = requested
        return requested
    }

    public func isRequested(_ candidate: Generation) -> Bool {
        requested == candidate && worker == candidate
    }

    public func isReady(_ candidate: Generation) -> Bool {
        isRequested(candidate) && ready
    }

    /// A failed setup or failed re-enable retires the request; recovery requires an explicit new activation.
    @discardableResult
    public mutating func report(_ candidate: Generation, ready: Bool) -> Bool {
        guard isRequested(candidate) else { return false }
        self.ready = ready
        if !ready { requested = nil }
        return true
    }

    @discardableResult
    public mutating func finished(_ candidate: Generation) -> Bool {
        guard worker == candidate else { return false }
        worker = nil
        if requested == candidate { requested = nil }
        ready = false
        return true
    }
}
