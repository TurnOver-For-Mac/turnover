// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One budget shared by discovery, retained-reference reads and fresh-reference reads. Limits count admitted
/// queries, including client-deferred queries; a partial pass never receives a fresh allowance (issue 166).
public struct AXProbeBudget: Sendable {
    public enum Stop: String, Sendable { case queryLimit, nodeLimit, deadline, timeoutConfiguration, providerCannotComplete, accessibilityDenied, clientBackoff, clientStopped }
    public let maximumQueries: Int
    public let maximumNodes: Int
    public let maximumDepth: Int
    public let maximumChildren: Int
    public let durationNanoseconds: UInt64
    public let startedNanoseconds: UInt64
    public private(set) var queries = 0
    public private(set) var nodes = 0
    public private(set) var depthClipped = false
    public private(set) var arraysClipped = false
    public private(set) var stopped: Stop?

    public init(maximumQueries: Int = 96, maximumNodes: Int = 12, maximumDepth: Int = 6,
                maximumChildren: Int = 8, durationNanoseconds: UInt64 = 1_500_000_000,
                startedNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        self.maximumQueries = min(128, max(0, maximumQueries))
        self.maximumNodes = min(16, max(0, maximumNodes))
        self.maximumDepth = min(6, max(0, maximumDepth))
        self.maximumChildren = min(8, max(1, maximumChildren))
        self.durationNanoseconds = min(2_000_000_000, durationNanoseconds)
        self.startedNanoseconds = startedNanoseconds
    }

    public mutating func canContinue(now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Bool {
        guard stopped == nil else { return false }
        guard now >= startedNanoseconds, now - startedNanoseconds < durationNanoseconds else {
            stopped = .deadline; return false
        }
        return true
    }

    public mutating func beginQuery(now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Bool {
        guard canContinue(now: now) else { return false }
        guard queries < maximumQueries else { stopped = .queryLimit; return false }
        queries += 1
        return true
    }

    public mutating func beginNode(depth: Int, now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Bool {
        guard canContinue(now: now) else { return false }
        guard depth >= 0, depth <= maximumDepth else { depthClipped = true; return false }
        guard nodes < maximumNodes else { stopped = .nodeLimit; return false }
        nodes += 1
        return true
    }

    public mutating func noteArray(total: Int?, received: Int) {
        if let total, total > received { arraysClipped = true }
    }

    public mutating func stop(_ reason: Stop) {
        if stopped == nil { stopped = reason }
    }
}
