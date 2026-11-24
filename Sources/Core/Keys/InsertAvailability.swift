// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A descriptor may list keys the keyboard does not physically have. Only an observed
/// press proves a key exists; an unproven device leaves the recovery modifier enabled.
nonisolated public struct InsertAvailability: Sendable {
    private var devices: [UInt64: Set<Int64>] = [:]
    public init() {}
    public static let current = Locked(InsertAvailability())

    public mutating func connect(_ connection: UInt64) { devices[connection] = [] }
    public mutating func disconnect(_ connection: UInt64) { devices.removeValue(forKey: connection) }
    public mutating func observePress(connection: UInt64, code: Int64) {
        guard devices[connection] != nil, code == 82 || code == 114 else { return }
        devices[connection]?.insert(code)
    }
    public func isAvailable(keypadCommands: Bool) -> Bool {
        devices.values.contains { $0.contains(114) || (keypadCommands && $0.contains(82)) }
    }
}
