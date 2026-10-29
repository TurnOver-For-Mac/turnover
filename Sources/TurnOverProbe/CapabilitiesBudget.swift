// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverAX

/// Fixed profiles for this executable's metadata sample. The directed Settings mode needs a deeper container
/// path than App Store diagnostics; it does not relax AXProbeBudget's shared hard caps or accept numeric limits.
struct CapabilitiesBudget {
    let maximumQueries: Int, maximumNodes: Int, maximumDepth: Int
    let maximumChildren = 8
    private let started = DispatchTime.now().uptimeNanoseconds
    private(set) var queries = 0, nodes = 0
    private(set) var depthClipped = false, arraysClipped = false
    private(set) var stopped: AXProbeBudget.Stop?

    init(settingsShape: Bool) {
        maximumQueries = settingsShape ? 256 : 128
        maximumNodes = settingsShape ? 32 : 16
        maximumDepth = settingsShape ? 9 : 6
    }
    mutating func canContinue(now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Bool {
        guard stopped == nil else { return false }
        guard now >= started, now - started < 2_000_000_000 else { stopped = .deadline; return false }
        return true
    }
    mutating func beginQuery() -> Bool {
        guard canContinue() else { return false }
        guard queries < maximumQueries else { stopped = .queryLimit; return false }
        queries += 1
        return true
    }
    mutating func beginNode(depth: Int) -> Bool {
        guard canContinue() else { return false }
        guard depth >= 0, depth <= maximumDepth else { depthClipped = true; return false }
        guard nodes < maximumNodes else { stopped = .nodeLimit; return false }
        nodes += 1
        return true
    }
    mutating func noteArray(total: Int?, received: Int) {
        if let total, total > received { arraysClipped = true }
    }
    mutating func stop(_ reason: AXProbeBudget.Stop) {
        if stopped == nil { stopped = reason }
    }
}
