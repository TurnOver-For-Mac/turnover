// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Synchronous, thread-confined admission for a client's accessibility work. Nested helpers inherit the guard,
/// including profile/label queries which would otherwise continue after their caller's deadline. The closures
/// and their mutable walk state stay on this thread, never cross await, and are removed/restored by defer.
public enum AXReadScope {
    private final class Scope {
        let parent: Scope?
        let shouldContinue: () -> Bool
        let onQuery: () -> Bool
        let onResult: (AXQueryStatus) -> Void

        init(parent: Scope?, shouldContinue: @escaping () -> Bool, onQuery: @escaping () -> Bool,
             onResult: @escaping (AXQueryStatus) -> Void) {
            self.parent = parent; self.shouldContinue = shouldContinue; self.onQuery = onQuery; self.onResult = onResult
        }

        func permitsWork() -> Bool { (parent?.permitsWork() ?? true) && shouldContinue() }
        func admitsQuery() -> Bool { (parent?.admitsQuery() ?? true) && onQuery() }
        func report(_ status: AXQueryStatus) { parent?.report(status); onResult(status) }
    }
    private static let key = "com.turnover.ax.read-scope"
    private static var current: Scope? { Thread.current.threadDictionary[key] as? Scope }

    /// `onQuery` is called only after client backoff admission, immediately before an AX API is attempted. It can
    /// reserve a query budget independently of higher-level traversal operations. No messaging timeout is changed.
    /// `onResult` inspects status on this same thread; it must not issue further AX queries.
    public static func with<Value>(while shouldContinue: @escaping () -> Bool,
                                   onQuery: @escaping () -> Bool = { true },
                                   onResult: @escaping (AXQueryStatus) -> Void = { _ in },
                                   _ body: () throws -> Value) rethrows -> Value {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[key]
        dictionary[key] = Scope(parent: current, shouldContinue: shouldContinue, onQuery: onQuery, onResult: onResult)
        defer {
            if let previous { dictionary[key] = previous }
            else { dictionary.removeObject(forKey: key) }
        }
        return try body()
    }

    static var shouldContinue: Bool { current?.permitsWork() ?? true }
    static func admitQuery() -> Bool {
        guard let current else { return true }
        return current.permitsWork() && current.admitsQuery()
    }
    static func report(_ status: AXQueryStatus) { current?.report(status) }
}
