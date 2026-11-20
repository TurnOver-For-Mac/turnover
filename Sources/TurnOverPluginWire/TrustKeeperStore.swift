// SPDX-License-Identifier: GPL-3.0-or-later
// The keeper's file logic alone, given a folder, so it is tested without XPC (docs/PLUGIN-SCRIPTS-PLAN.md, "The
// keeper", 15 Nov 2026). It keeps one file, plugin-trust.json, whole.
import Foundation

public struct TrustKeeperStore: Sendable {
    public static let fileName = "plugin-trust.json"
    /// The most the keeper will keep: far more than any number of receipts needs.
    public static let maximumBytes = 1_048_576

    public let folder: URL
    public init(folder: URL) { self.folder = folder }

    private var file: URL { folder.appendingPathComponent(Self.fileName) }

    /// Whether this program is in an App Sandbox: its home is inside a container and macOS set the container's name.
    /// Observed on macOS 27.2, 15 Nov 2026: a sandboxed service's home is ~/Library/Containers/<identifier>/Data and
    /// APP_SANDBOX_CONTAINER_ID is set; a program run by hand has neither.
    public static func isSandboxed(home: String, environment: [String: String]) -> Bool {
        home.contains("/Library/Containers/") && !(environment["APP_SANDBOX_CONTAINER_ID"] ?? "").isEmpty
    }

    /// The stored bytes; nil if nothing is stored yet.
    public func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do { return try Data(contentsOf: file) } catch { throw TrustKeeperFailure("the file cannot be read: \(error.localizedDescription)") }
    }

    /// Keep these bytes in place of any before, written whole (a failed write leaves the old file), the folder made if
    /// it is missing. More than `maximumBytes` is refused and the old file stays.
    public func store(_ data: Data) throws {
        guard data.count <= Self.maximumBytes else { throw TrustKeeperFailure("more than \(Self.maximumBytes) bytes: refused") }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch { throw TrustKeeperFailure("the file cannot be written: \(error.localizedDescription)") }
    }

    /// Write, read back and remove a probe file beside the real one. "ok", or the reason it failed. The real file is
    /// never touched.
    public func check() -> String {
        let probe = folder.appendingPathComponent("\(Self.fileName).check-\(UUID().uuidString)")
        let bytes = Data("TurnOver keeper check".utf8)
        defer { try? FileManager.default.removeItem(at: probe) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try bytes.write(to: probe, options: .atomic)
            guard try Data(contentsOf: probe) == bytes else { return "the probe file read back differently" }
            try FileManager.default.removeItem(at: probe)
        } catch { return "the check failed: \(error.localizedDescription)" }
        return "ok"
    }
}
