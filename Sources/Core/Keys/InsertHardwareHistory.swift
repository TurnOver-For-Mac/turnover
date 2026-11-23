// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Observed physical transitions, separate from which reader consumed a Quartz down.
nonisolated public struct InsertHardwareHistory: Sendable {
    private struct Transition: Sendable {
        let timestamp: UInt64
        let down: Bool
    }
    private var devices: [UInt64: [Int64: [Transition]]] = [:]
    public init() {}

    public mutating func connect(_ connection: UInt64) { devices[connection] = [:] }
    /// Removal is a resynchronization boundary, not a fabricated physical key-up timestamp.
    public mutating func disconnect(_ connection: UInt64) { devices.removeValue(forKey: connection) }

    public mutating func record(connection: UInt64, code: Int64, down: Bool, timestamp: UInt64) {
        guard var device = devices[connection] else { return }
        var transitions = device[code] ?? []
        guard transitions.last?.down != down else { return }
        if let last = transitions.last,
           timestamp < last.timestamp { return }
        transitions.append(Transition(timestamp: timestamp, down: down))
        // A very old queued event has explicitly unknown history instead of invented certainty.
        if transitions.count > 256 { transitions.removeFirst(transitions.count - 256) }
        device[code] = transitions
        devices[connection] = device
    }

    /// nil means incomplete evidence. Current HID state must agree with the observed latest state.
    /// A later observed release can then distinguish a queued chord from a genuinely lost release.
    public func observedDown(code: Int64, at timestamp: UInt64, currentDown: Bool, after capturedAt: UInt64 = 0) -> Bool? {
        let histories = devices.values.compactMap { $0[code] }
        guard !histories.isEmpty else { return nil }
        // Matching old up-state does not prove a newer Quartz press has reached the observer.
        let capturedPressObserved = histories.contains { history in
            history.contains { transition in
                let inCapturedInterval = transition.timestamp >= capturedAt
                    && transition.timestamp <= timestamp
                return transition.down && inCapturedInterval
            }
        }
        guard capturedPressObserved else { return nil }
        let currentlyObservedDown = histories.contains { $0.last?.down == true }
        guard currentlyObservedDown == currentDown else { return nil }
        var unknown = false
        for history in histories {
            guard let preceding = history.last(where: { $0.timestamp <= timestamp }) else {
                unknown = true
                continue
            }
            if preceding.down { return true }
        }
        return unknown ? nil : false
    }
    /// Only positive multi-device evidence groups a new same-code down with an owned episode.
    /// Missing evidence must not make stale ownership permanent after a genuinely lost release.
    public func overlapsDown(code: Int64, at timestamp: UInt64) -> Bool {
        let downDevices = devices.values.filter {
            $0[code]?.last(where: { $0.timestamp <= timestamp })?.down == true
        }
        return downDevices.count > 1
    }

}
