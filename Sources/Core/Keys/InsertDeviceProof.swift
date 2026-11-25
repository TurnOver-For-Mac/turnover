// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Persist physical capability, never connection or held-key state. Descriptors alone
/// and vendor/product/location IDs cannot prove that a particular keyboard has Insert.
nonisolated public struct InsertDeviceProof: Sendable {
    private var devices: [String: Set<Int64>]
    public init(data: Data? = nil) {
        devices = data.flatMap { try? JSONDecoder().decode([String: Set<Int64>].self, from: $0) } ?? [:]
    }
    public var data: Data? { try? JSONEncoder().encode(devices) }
    public static func identity(serial: String?, vendor: Int?, product: Int?, transport: String?, uniqueID: String? = nil) -> String? {
        func usable(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, !value.allSatisfy({ $0 == "0" }) else { return nil }
            return value
        }
        let identity = usable(uniqueID).map { "physical:\($0)" } ?? usable(serial).map { "serial:\($0)" }
        guard let identity, let vendor, let product, let transport, !transport.isEmpty else { return nil }
        // Length-prefix the device identity so embedded separators cannot alias another.
        return "\(vendor):\(product):\(identity.utf8.count):\(identity):\(transport)"
    }
    public func keys(for identity: String?) -> Set<Int64> {
        guard let identity else { return [] }
        return (devices[identity] ?? []).intersection([82, 114])
    }
    @discardableResult public mutating func observe(_ code: Int64, identity: String?) -> Bool {
        guard let identity, code == 82 || code == 114 else { return false }
        return devices[identity, default: []].insert(code).inserted
    }
}
