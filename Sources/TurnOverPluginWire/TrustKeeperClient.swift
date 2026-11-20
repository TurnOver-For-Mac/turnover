// SPDX-License-Identifier: GPL-3.0-or-later
// What TurnOver uses to reach the keeper (docs/PLUGIN-SCRIPTS-PLAN.md, "The keeper", 15 Nov 2026): the XPC service
// `<this app's bundle identifier>.trust-keeper` inside the app. TurnOver puts a code-signing requirement on its own end
// (that identifier, signed by this program's own team), so a keeper swapped inside the app is not believed. With no team of
// its own, this program does not connect at all. Every call waits at most two seconds for the reply and then gives up.
import Foundation

/// One answer, delivered once from whichever thread the reply or the error arrives on; the first to arrive wins.
private final class PendingAnswer<Value: Sendable>: @unchecked Sendable {
    // Safe because: `value` is read and written only under `lock`, and the semaphore is signalled only after the first write.
    private let lock = NSLock(), done = DispatchSemaphore(value: 0)
    private var value: Result<Value, TrustKeeperFailure>?

    func fulfill(_ result: Result<Value, TrustKeeperFailure>) {
        lock.lock(); defer { lock.unlock() }
        guard value == nil else { return }
        value = result; done.signal()
    }

    func wait(seconds: Double) -> Result<Value, TrustKeeperFailure>? {
        guard done.wait(timeout: .now() + seconds) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

public final class TrustKeeperClient: @unchecked Sendable {
    /// The longest any call waits.
    public static let timeoutSeconds = 2.0
    public static let serviceSuffix = ".trust-keeper"

    /// Who to connect to and the requirement on them (nil for `stranger`: none), or why this client will not connect at all.
    private let target: Result<(service: String, requirement: String?), TrustKeeperFailure>
    // Safe because: `connection` is read and written only under `lock`; NSXPCConnection itself is thread-safe to message.
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    public init(bundleIdentifier: String? = Bundle.main.bundleIdentifier, team: String? = CodeIdentity.ownTeam()) {
        guard let team else {
            target = .failure(TrustKeeperFailure("this copy of TurnOver has no signing team of its own, so the keeper would not trust it"))
            return
        }
        guard let bundleIdentifier, let requirement = CodeIdentity.requirement(identifier: bundleIdentifier + Self.serviceSuffix, team: team) else {
            target = .failure(TrustKeeperFailure("this program has no usable bundle identifier to name the keeper by"))
            return
        }
        target = .success((bundleIdentifier + Self.serviceSuffix, requirement))
    }

    /// The attacker's client, for the keeper check only (`turnover-trust-keeper --client check-as-stranger`): it connects to the
    /// keeper of the app it runs in without the checks an honest client makes, a signing team of its own and a requirement on the
    /// keeper, so that if a stranger is refused it is the keeper's own check that refused it. An ordinary client never gets this far:
    /// with no team it will not connect at all, which proves nothing about the keeper.
    public init(strangerOf bundleIdentifier: String?) {
        guard let bundleIdentifier, CodeIdentity.isValidIdentifier(bundleIdentifier) else {
            target = .failure(TrustKeeperFailure("this program has no usable bundle identifier to name the keeper by"))
            return
        }
        target = .success((bundleIdentifier + Self.serviceSuffix, nil))
    }

    /// Whether this client would open a connection, and whether it would ask nothing of the keeper's own signature first.
    public var connects: Bool { if case .success = target { return true } else { return false } }
    public var requiresKeeperSignature: Bool { if case .success(let found) = target { return found.requirement != nil } else { return false } }

    /// The stored bytes, nil if nothing is stored yet.
    public func load() -> Result<Data?, TrustKeeperFailure> {
        call { keeper, answer in
            keeper.load { data, reason in answer(reason.map { .failure(TrustKeeperFailure($0)) } ?? .success(data)) }
        }
    }

    public func store(_ data: Data) -> Result<Void, TrustKeeperFailure> {
        call { keeper, answer in
            keeper.store(data) { reason in answer(reason.map { .failure(TrustKeeperFailure($0)) } ?? .success(())) }
        }
    }

    /// The keeper's own check: success if it said "ok", otherwise the reason it gave or why it could not be asked.
    public func check() -> Result<Void, TrustKeeperFailure> {
        call { keeper, answer in
            keeper.check { text in answer(text == "ok" ? .success(()) : .failure(TrustKeeperFailure(text))) }
        }
    }

    private func call<Value: Sendable>(_ ask: (TrustKeeperProtocol, @escaping @Sendable (Result<Value, TrustKeeperFailure>) -> Void) -> Void) -> Result<Value, TrustKeeperFailure> {
        let service: (service: String, requirement: String?)
        switch target { case .failure(let why): return .failure(why); case .success(let found): service = found }
        let pending = PendingAnswer<Value>()
        let connection = currentConnection(service)
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            pending.fulfill(.failure(TrustKeeperFailure("the keeper could not be reached, or it refused this copy of TurnOver")))
        }
        guard let keeper = proxy as? TrustKeeperProtocol else { return .failure(TrustKeeperFailure("the keeper's connection did not give its interface")) }
        ask(keeper) { pending.fulfill($0) }
        let result = pending.wait(seconds: Self.timeoutSeconds) ?? .failure(TrustKeeperFailure("the keeper did not answer within two seconds"))
        // After any failure the next call starts a new connection, in case this one is dead.
        if case .failure = result { drop(connection) }
        return result
    }

    private func currentConnection(_ service: (service: String, requirement: String?)) -> NSXPCConnection {
        lock.lock(); defer { lock.unlock() }
        if let connection { return connection }
        let made = NSXPCConnection(serviceName: service.service)
        made.remoteObjectInterface = NSXPCInterface(with: TrustKeeperProtocol.self)
        if let requirement = service.requirement { made.setCodeSigningRequirement(requirement) }
        made.resume()
        connection = made
        return made
    }

    private func drop(_ dead: NSXPCConnection) {
        lock.lock(); defer { lock.unlock() }
        if connection === dead { connection = nil }
        dead.invalidate()
    }
}
