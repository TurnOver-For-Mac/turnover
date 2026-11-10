// SPDX-License-Identifier: GPL-3.0-or-later
// Attributes answered from a snapshot instead of by asking the app again (trial, 10 Nov 2026).
//
// Why: the page buffer's walk asks each element for its role, its subrole, its value, its children and more, one
// question at a time: 0.24 ms an element on real pages (9,716 builds in Oliver's logs, November 2026), where one
// batched question an element costs 0.04 ms in Safari. Rewriting that walk over a snapshot would risk every rule in
// it. Instead the walk stays exactly as it is, and inside `with(_:)` the questions it asks through `attr` are
// answered from a snapshot taken just before: the same code, the same lines, fewer questions.
//
// Thread-confined, like AXReadScope: the snapshot answers only on the thread that opened the scope, only inside it,
// and only for the attributes the snapshot asked for. An element or attribute the snapshot does not hold is asked
// for live, as before. A snapshot is a moment: the scope is opened for one build, straight after the snapshot.
import Foundation
import ApplicationServices

public enum AXAttributeCache {
    private final class Store {
        let snapshot: AXSnapshot
        let names: Set<String>
        var hits = 0, misses = 0
        init(_ snapshot: AXSnapshot) { self.snapshot = snapshot; names = Set(snapshot.names) }
    }
    private static let key = "com.turnover.ax.attribute-cache"
    private static var current: Store? { Thread.current.threadDictionary[key] as? Store }

    /// What the scope answered from the snapshot, and what it had to ask the app for.
    public struct Use: Sendable { public let hits: Int; public let misses: Int }

    public static func with<Value>(_ snapshot: AXSnapshot, _ body: () throws -> Value) rethrows -> (value: Value, use: Use) {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[key]
        let store = Store(snapshot)
        dictionary[key] = store
        defer {
            if let previous { dictionary[key] = previous } else { dictionary.removeObject(forKey: key) }
        }
        let value = try body()
        return (value, Use(hits: store.hits, misses: store.misses))
    }

    /// `.some(value)` when the snapshot holds the answer (`value` nil: the app had none); nil when it must be asked.
    @inline(__always) static func lookup(_ element: AXUIElement, _ name: String) -> CFTypeRef?? {
        guard let store = current else { return nil }
        guard store.names.contains(name), let index = store.snapshot.index(of: element), store.snapshot.nodes[index].isFilled else {
            store.misses += 1
            return nil
        }
        store.hits += 1
        return .some(store.snapshot.nodes[index].raw.values[name])
    }

    // MARK: Counting, for the probes

    private static let tallyKey = "com.turnover.ax.attribute-tally"
    private final class Tally { var counts: [String: Int] = [:] }
    /// Counts the attributes asked for through `attr` on this thread inside `body`, by name: what a walk really asks.
    public static func counting<Value>(_ body: () throws -> Value) rethrows -> (value: Value, counts: [String: Int]) {
        let dictionary = Thread.current.threadDictionary
        let tally = Tally()
        dictionary[tallyKey] = tally
        defer { dictionary.removeObject(forKey: tallyKey) }
        let value = try body()
        return (value, tally.counts)
    }
    @inline(__always) static func count(_ name: String) {
        if let tally = Thread.current.threadDictionary[tallyKey] as? Tally { tally.counts[name, default: 0] += 1 }
    }
}
