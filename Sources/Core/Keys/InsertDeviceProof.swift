// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

/// Cache only observed capability. A serial alone can be shared across keyboards.
nonisolated public struct InsertDeviceProof: Sendable {
    private struct Cache: Codable {
        var keys: [String: Set<Int64>] = [:]
        var ambiguous: Set<String> = []
    }
    private var cache: Cache
    private var connected: [UInt64: String] = [:]

    public init(data: Data? = nil) {
        cache = data.flatMap { try? JSONDecoder().decode(Cache.self, from: $0) } ?? Cache()
    }

    public var data: Data? { try? JSONEncoder().encode(cache) }

    public static func identity(physicalID: String?, vendor: Int?, product: Int?, transport: String?) -> String? {
        guard let id = physicalID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty, !id.allSatisfy({ $0 == "0" }),
              let vendor, let product, let transport, !transport.isEmpty else { return nil }
        let material = "\(vendor):\(product):\(id.utf8.count):\(id):\(transport)"
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Return all connections whose remembered proof must be revoked on a new collision.
    public mutating func connect(_ connection: UInt64, identity: String?) -> [UInt64] {
        guard let identity else { return [] }
        connected[connection] = identity
        guard !cache.ambiguous.contains(identity) else { return [] }
        let matches = connected.compactMap { $0.value == identity ? $0.key : nil }
        guard matches.count > 1 else { return [] }
        cache.ambiguous.insert(identity)
        cache.keys.removeValue(forKey: identity)
        return matches
    }

    public mutating func disconnect(_ connection: UInt64) { connected.removeValue(forKey: connection) }

    public func keys(for connection: UInt64) -> Set<Int64> {
        guard let id = connected[connection], !cache.ambiguous.contains(id) else { return [] }
        return (cache.keys[id] ?? []).intersection([82, 114])
    }

    public mutating func observe(_ code: Int64, connection: UInt64) -> Bool {
        guard let id = connected[connection], !cache.ambiguous.contains(id), code == 82 || code == 114 else { return false }
        return cache.keys[id, default: []].insert(code).inserted
    }
}
