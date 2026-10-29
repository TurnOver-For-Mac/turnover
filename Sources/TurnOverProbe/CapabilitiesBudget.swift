// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverAX

enum CapabilitiesProfile: String { case standard, systemSettings, extended }

/// Fixed profiles for this executable's metadata sample. Explicit Settings/content passes can reach deeper
/// containers without relaxing AXProbeBudget's shared hard caps or accepting numeric limits from arguments.
struct CapabilitiesBudget {
    let maximumQueries: Int, maximumNodes: Int, maximumDepth: Int
    let maximumChildren = 8
    private let started = DispatchTime.now().uptimeNanoseconds
    private(set) var queries = 0, nodes = 0
    private(set) var depthClipped = false, arraysClipped = false
    private(set) var stopped: AXProbeBudget.Stop?

    init(profile: CapabilitiesProfile) {
        switch profile {
        case .standard: maximumQueries = 128; maximumNodes = 16; maximumDepth = 6
        case .systemSettings: maximumQueries = 256; maximumNodes = 32; maximumDepth = 9
        case .extended: maximumQueries = 512; maximumNodes = 64; maximumDepth = 12
        }
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
