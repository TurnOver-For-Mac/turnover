// SPDX-License-Identifier: GPL-3.0-or-later
// The keeper of plugin script approvals (docs/PLUGIN-SCRIPTS-PLAN.md, "The keeper", 15 Nov 2026).
//
// With no arguments it is an XPC service inside TurnOver.app, sandboxed, keeping one file in its own container. It
// answers only a program signed by the same team as itself, with the identifier of the app it sits in; it has no
// entitlement but the App Sandbox, and it refuses to touch a file unless it really is sandboxed.
//
// With `--client check` it is the other end: it asks the keeper in the app it is running inside to run its check, prints
// one line and exits (0 ok; 3 refused or unreachable; 1 anything else). build.sh's keeper check runs it as the host of a
// throwaway app, to prove that the keeper answers its own app.
// With `--client check-as-stranger` it is the attacker: the same call, made by a client that does not first refuse itself
// for having no team and does not put a requirement on the keeper, so a refusal is the keeper's own. The check runs it in the
// copies that must be refused.
import Foundation
import TurnOverPluginWire

/// The object each accepted connection talks to. With no store (not sandboxed) every call gives the reason and touches no file.
final class TrustKeeperService: NSObject, TrustKeeperProtocol {
    private let store: TrustKeeperStore?
    init(store: TrustKeeperStore?) { self.store = store }
    private static let notSandboxed = "not sandboxed"

    func load(reply: @escaping @Sendable (Data?, String?) -> Void) {
        guard let store else { return reply(nil, Self.notSandboxed) }
        do { reply(try store.load(), nil) } catch { reply(nil, "\(error)") }
    }

    func store(_ data: Data, reply: @escaping @Sendable (String?) -> Void) {
        guard let store else { return reply(Self.notSandboxed) }
        do { try store.store(data); reply(nil) } catch { reply("\(error)") }
    }

    func check(reply: @escaping @Sendable (String) -> Void) {
        guard let store else { return reply(Self.notSandboxed) }
        reply(store.check())
    }
}

final class TrustKeeperDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Only the app this service sits in, signed by the same team as this service: its identifier is the app's followed
        // by ".trust-keeper". No team (an ad hoc build) or another shape of identifier: nobody. Observed 15 Nov 2026
        // (macOS 27.2): an ad hoc copy of the app with the same bundle identifier was refused on every call.
        guard let team = CodeIdentity.ownTeam(), let own = Bundle.main.bundleIdentifier, own.hasSuffix(TrustKeeperClient.serviceSuffix),
              let requirement = CodeIdentity.requirement(identifier: String(own.dropLast(TrustKeeperClient.serviceSuffix.count)), team: team) else { return false }
        connection.setCodeSigningRequirement(requirement)
        // The file lives in Application Support inside the container, and only if the container is really there.
        let sandboxed = TrustKeeperStore.isSandboxed(home: NSHomeDirectory(), environment: ProcessInfo.processInfo.environment)
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        connection.exportedInterface = NSXPCInterface(with: TrustKeeperProtocol.self)
        connection.exportedObject = TrustKeeperService(store: sandboxed ? folder.map { TrustKeeperStore(folder: $0) } : nil)
        connection.resume()
        return true
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty {
    let delegate = TrustKeeperDelegate()
    let listener = NSXPCListener.service()
    listener.delegate = delegate
    listener.resume()   // does not return
} else if arguments == ["--client", "check"] {
    switch TrustKeeperClient().check() {
    case .success: print("trust keeper: ok"); exit(0)
    case .failure(let why): print("trust keeper: \(why)"); exit(3)
    }
} else if arguments == ["--client", "check-as-stranger"] {
    switch TrustKeeperClient(strangerOf: Bundle.main.bundleIdentifier).check() {
    case .success: print("trust keeper: ok"); exit(0)
    case .failure(let why): print("trust keeper: \(why)"); exit(3)
    }
} else {
    print("usage: turnover-trust-keeper [--client check | --client check-as-stranger]"); exit(1)
}
