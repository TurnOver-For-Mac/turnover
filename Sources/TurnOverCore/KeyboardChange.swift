// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One Change action, including the old and new keys' layout overrides. Restore puts back exactly what this
/// action changed; a later edit to any of those entries makes the record ineligible until that edit is undone.
public struct KeyboardChange: Codable, Equatable {
    public let id: String
    public let oldKey: String
    public let newKey: String
    public let entries: [Entry]

    public struct Entry: Codable, Equatable {
        public let key: String
        public let before: String?
        public let after: String?
    }

    public init?(oldKey: String, newKey: String, before: [String: String], after: [String: String]) {
        guard oldKey != newKey else { return nil }
        self.id = UUID().uuidString
        self.oldKey = oldKey; self.newKey = newKey
        entries = Set(before.keys).union(after.keys).sorted().compactMap { key in
            before[key] == after[key] ? nil : Entry(key: key, before: before[key], after: after[key])
        }
        guard isCurrent(in: after) else { return nil }
    }

    public func isCurrent(in overrides: [String: String]) -> Bool {
        // A malformed saved record must not turn Restore into an edit of unrelated keys.
        guard oldKey != newKey, oldKey.hasPrefix("kb:"), newKey.hasPrefix("kb:"),
              !KeyboardMap.isEssential(oldKey), !KeyboardMap.isEssential(newKey), !entries.isEmpty else { return false }
        var allowed = Set([oldKey, newKey])
        for key in [oldKey, newKey] {
            for layout in ["laptop", "desktop"] { allowed.insert("kb(\(layout)):" + key.dropFirst(3)) }
        }
        let affected = Set(entries.map(\.key))
        return affected.count == entries.count && affected.isSubset(of: allowed) &&
            entries.allSatisfy { $0.before != $0.after && overrides[$0.key] == $0.after }
    }

    public func restoring(in overrides: [String: String]) -> [String: String]? {
        guard isCurrent(in: overrides) else { return nil }
        var restored = overrides
        for entry in entries { restored[entry.key] = entry.before }
        return restored
    }
}
