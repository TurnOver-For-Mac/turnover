// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// HID establishes press ownership; availability changes apply to the next press.
/// Timestamped ownership also covers Quartz flags delivered after a later HID press.
nonisolated public struct CapsPressState: Sendable {
    private struct Press: Sendable {
        var timestamp: UInt64
        var releasedAt: UInt64?
        var owned: Bool
        var fallback: Bool
    }
    private var presses: [Press] = []
    public private(set) var down = false
    public init() {}
    public mutating func update(down pressed: Bool, timestamp: UInt64, settings: KeySettings) -> Bool {
        if pressed && !down {
            presses.append(Press(timestamp: timestamp, owned: settings.capsIsTurnOver,
                                 fallback: settings.insertIsTurnOver && settings.capsIsTurnOver))
            if presses.count > 64 { presses.removeFirst() }
        }
        if !pressed, down, !presses.isEmpty { presses[presses.count - 1].releasedAt = timestamp }
        down = pressed
        return owns(presses.last, settings: settings)
    }
    public func modifierHeld(settings: KeySettings) -> Bool {
        down && owns(presses.last, settings: settings)
    }
    public func retainedFallback(settings: KeySettings) -> Bool {
        down && presses.last?.owned == true && presses.last?.fallback == true && settings.insertIsTurnOver
    }
    public func capturesFlags(at timestamp: UInt64, settings: KeySettings) -> Bool {
        let episode = presses.last { press in
            press.timestamp <= timestamp && (press.releasedAt.map { timestamp <= $0 } ?? true)
        }
        guard let press = episode else { return settings.capsIsTurnOver }
        return owns(press, settings: settings)
    }
    private func owns(_ press: Press?, settings: KeySettings) -> Bool {
        guard let press else { return false }
        return press.owned && (settings.capsIsTurnOver || (press.fallback && settings.insertIsTurnOver))
    }
}
