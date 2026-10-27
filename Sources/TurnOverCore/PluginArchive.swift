// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// The library's ZIP checks and extraction. Called off main by PluginLibrary.download.
nonisolated package enum PluginArchive {
    // The signed list limits the download, not its expansion. These limits leave room for profiles and fixtures
    // without letting one library plugin fill the disk or create thousands of files (audit follow-up, 27 Oct 2026).
    package static let maxEntries = 256
    package static let maxExpandedBytes = 16 * 1024 * 1024

    private static func failure(_ message: String) -> Error {
        NSError(domain: "TurnOver", code: 10, userInfo: [NSLocalizedDescriptionKey: message + "; nothing was installed"])
    }

    /// Returns the plugin and its temporary folder. Every failed check removes the temporary folder.
    package static func unpack(_ data: Data, temporaryDirectory: URL = FileManager.default.temporaryDirectory) throws -> (folder: URL, tmp: URL) {
        let fm = FileManager.default
        let tmp = temporaryDirectory.appendingPathComponent("turnover-plugin-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        do {
            let zip = tmp.appendingPathComponent("p.zip"), out = tmp.appendingPathComponent("unpacked")
            try data.write(to: zip)
            let names = try run("zipinfo", ["-1", zip.path], limit: 1024 * 1024, capture: true)
            let entries = String(decoding: names, as: UTF8.self).split(separator: "\n")
            guard !entries.isEmpty else { throw failure("it isn't a valid plugin archive") }
            guard entries.count <= maxEntries else { throw failure("it holds more than 256 archive entries") }
            for name in entries where name.hasPrefix("/") || name.hasPrefix("..") || name.split(separator: "/").contains("..") {
                throw failure("it holds a path outside its folder")
            }
            let listing = try run("zipinfo", ["-l", zip.path], limit: 1024 * 1024, capture: true)
            for line in String(decoding: listing, as: UTF8.self).split(separator: "\n") where line.hasPrefix("l") {
                throw failure("it holds a link")
            }
            // Count actual decompressed bytes before writing files. On macOS 27.0.1, ZIPs with understated size
            // fields passed both zipinfo and unzip -t, and ditto wrote the larger payload (27 Oct 2026).
            // -p also verifies CRCs; its output is counted and discarded a chunk at a time.
            _ = try run("unzip", ["-p", "-P", "", zip.path], limit: maxExpandedBytes, capture: false)
            // Use the same reader for validation and extraction: ditto extracted local entries missing from
            // the central directory that zipinfo and unzip inspected (27 Oct 2026, macOS 27.0.1).
            // -^ preserves names as ditto did; silently stripping controls can merge distinct fixture paths.
            // AppleDouble metadata stays in sidecar files; plugins read ordinary files, not resource forks.
            _ = try run("unzip", ["-q", "-o", "-^", "-P", "", zip.path, "-d", out.path], limit: 0, capture: false)

            let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
            var enumerationError: Error?
            guard let files = fm.enumerator(at: out, includingPropertiesForKeys: keys, errorHandler: { _, error in
                enumerationError = error
                return false
            }) else {
                throw failure("it couldn't be unpacked")
            }
            var total = 0
            for case let url as URL in files {
                let value = try url.resourceValues(forKeys: Set(keys))
                guard value.isSymbolicLink != true, value.isRegularFile == true || value.isDirectory == true else {
                    throw failure("it holds something other than plain files")
                }
                if value.isRegularFile == true {
                    guard let size = value.fileSize, size >= 0, size <= maxExpandedBytes - total else {
                        throw failure("it expands beyond 16 MiB")
                    }
                    total += size
                }
            }
            if let enumerationError { throw enumerationError }
            // The library's index tool omits the enclosing folder; a ZIP made by hand may include it.
            func hasManifest(_ url: URL) -> Bool { fm.fileExists(atPath: url.appendingPathComponent("manifest.json").path) }
            guard let folder = hasManifest(out) ? out
                    : (try fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)).first(where: hasManifest) else {
                throw failure("it couldn't be unpacked")
            }
            return (folder, tmp)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// Bound the system tool's output and lifetime. Only ZIP listings are retained in memory.
    package static func run(_ tool: String, _ arguments: [String], limit: Int, capture: Bool,
                            timeout: DispatchTimeInterval = .seconds(30)) throws -> Data {
        let process = Process(), output = Pipe(), finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/\(tool)")
        process.arguments = arguments
        // Inherited ZIPINFO/UNZIP options can change the listing format or enable a pager/password prompt.
        process.environment = ["LC_ALL": "C", "LANG": "C", "PATH": "/usr/bin:/bin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        defer {
            try? output.fileHandleForReading.close()
            if process.isRunning {
                process.terminate()
                if finished.wait(timeout: .now() + .seconds(1)) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
            process.waitUntilExit()
        }
        let fd = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw failure("it couldn't be inspected") }
        let deadline = DispatchTime.now() + timeout
        var result = Data(), count = 0, chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            guard DispatchTime.now() < deadline else { throw failure("checking or unpacking the archive took too long") }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, 100)
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            guard ready > 0 else { throw failure("it couldn't be inspected") }
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n == 0 { break }
            if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard n > 0 else { throw failure("it couldn't be inspected") }
            guard n <= limit - count else {
                throw failure(capture ? "its archive listing is too large" : limit == 0 ? "it couldn't be unpacked" : "it expands beyond 16 MiB")
            }
            count += n
            if capture { result.append(contentsOf: chunk.prefix(n)) }
        }
        guard finished.wait(timeout: deadline) == .success else { throw failure("checking or unpacking the archive took too long") }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw failure("it isn't a valid plugin archive")
        }
        return result
    }
}
