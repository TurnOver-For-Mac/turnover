// SPDX-License-Identifier: GPL-3.0-or-later
// Locking this program in a sandbox (docs/PLUGIN-SCRIPTS-PLAN.md, "Where a script runs"). It happens before a byte
// is read from TurnOver. sandbox_init is public but long deprecated (browsers still use it); the profile below was
// proved on macOS 27.2 on 14 Nov 2026: a sandboxed copy could not open a file in the home folder, write to /tmp,
// connect to 127.0.0.1 or start /usr/bin/true, and JavaScriptCore still ran (dates, number formatting). If it cannot
// be applied the host exits with status 3 and TurnOver runs no scripts.
import Foundation

@_silgen_name("sandbox_init")
private func c_sandbox_init(_ profile: UnsafePointer<CChar>, _ flags: UInt64,
                            _ errorbuf: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
@_silgen_name("sandbox_free_error")
private func c_sandbox_free_error(_ errorbuf: UnsafeMutablePointer<CChar>)

enum Sandbox {
    /// Everything is denied except reading the system's own libraries and data (JavaScriptCore needs them), and the
    /// metadata of any path (a path that does not exist must still say so).
    static let profile = """
    (version 1)
    (deny default)
    (allow sysctl-read)
    (allow file-read* (subpath "/System") (subpath "/usr/lib") (subpath "/usr/share") (subpath "/private/var/db/timezone") (subpath "/Library/Apple"))
    (allow file-read-metadata)
    """

    /// Nil when the sandbox is on; otherwise the reason it could not be applied.
    static func apply() -> String? {
        var error: UnsafeMutablePointer<CChar>? = nil
        let result = profile.withCString { c_sandbox_init($0, 0, &error) }
        guard result != 0 else { return nil }
        defer { if let error { c_sandbox_free_error(error) } }
        return error.map { String(cString: $0) } ?? "sandbox_init returned \(result)"
    }
}
