// SPDX-License-Identifier: GPL-3.0-or-later
// What TurnOver and the keeper (the sandboxed XPC service that keeps plugin script approvals) say to each other
// (docs/PLUGIN-SCRIPTS-PLAN.md, "The keeper", 15 Nov 2026). The keeper does not understand receipts: it keeps bytes.
import Foundation

/// Three calls, each answered once through its reply block. A reason is a short sentence in English, for the log; the
/// person is told in TurnOver's own words (ScriptTrustStore).
@objc public protocol TrustKeeperProtocol {
    /// The stored bytes, or nil with no reason when nothing is stored yet. With a reason, the keeper refused or failed.
    func load(reply: @escaping @Sendable (Data?, String?) -> Void)
    /// Keep these bytes whole in place of what was kept (at most `TrustKeeperStore.maximumBytes`). The reply is nil on
    /// success, otherwise the reason.
    func store(_ data: Data, reply: @escaping @Sendable (String?) -> Void)
    /// Write, read and remove a probe file that is not the real one. "ok", or the reason it failed.
    func check(reply: @escaping @Sendable (String) -> Void)
}

/// Why the keeper could not be used: a short sentence, for the log.
public struct TrustKeeperFailure: Error, CustomStringConvertible, Sendable, Equatable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public var description: String { reason }
}
