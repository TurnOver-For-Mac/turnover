// SPDX-License-Identifier: GPL-3.0-or-later
// Getting an add-on to read: a folder, a `.nvda-addon` file (a zip), or a download from NVDA's store (docs/PLUGIN-PLATFORM-PLAN.md,
// stage A, points 1 and 2). Unpacking refuses any entry whose path leaves the folder, any link, more than 2,000 entries or
// 50 MB unpacked. Downloads are capped at 50 MB, only over https, and only from the address the store's list gives.
// Nothing here runs anything from the add-on.
import Foundation
import CryptoKit
import Darwin

nonisolated public struct ConvertFailure: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

nonisolated public enum ConvertLimits {
    public static let entries = 2000
    public static let unpackedBytes = 50 * 1024 * 1024
    public static let downloadBytes = 50 * 1024 * 1024
}

/// Fetches an https address, at most `limit` bytes. The default asks the internet; the tests supply their own.
public typealias ConvertFetch = @Sendable (URL, Int) throws -> Data

nonisolated public struct AddonSource {
    public enum Origin: Equatable { case store(String), file(String), folder(String) }
    /// The folder with manifest.ini in it.
    public var root: URL
    public var origin: Origin
    public var sha256: String?
    public var sourceURL: String?
    public var storeEntry: StoreEntry?
    /// A temporary folder to remove when finished.
    public var temporary: URL?
    public func cleanUp() { if let t = temporary { try? FileManager.default.removeItem(at: t) } }
}

nonisolated public enum ConvertSource {
    public static func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// The folder that holds manifest.ini: the folder itself, or the one folder inside it.
    static func findRoot(_ folder: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.appendingPathComponent("manifest.ini").path) { return folder }
        let kids = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []).filter { $0.lastPathComponent != "__MACOSX" }
        if kids.count == 1, fm.fileExists(atPath: kids[0].appendingPathComponent("manifest.ini").path) { return kids[0] }
        return nil
    }

    /// Checks a tree for links, too many entries and too many bytes. Nothing is opened.
    static func checkTree(_ folder: URL) throws {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        var failure: ConvertFailure?
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in failure = ConvertFailure("a file in it could not be read"); return false }) else {
            throw ConvertFailure("the folder could not be read")
        }
        var count = 0, total = 0
        let base = folder.resolvingSymlinksInPath().path
        for case let url as URL in walker {
            count += 1
            if count > ConvertLimits.entries { throw ConvertFailure("It holds more than \(ConvertLimits.entries) files, which is more than an add-on needs; nothing was read.") }
            let v = try url.resourceValues(forKeys: Set(keys))
            if v.isSymbolicLink == true { throw ConvertFailure("It holds a link (\(url.lastPathComponent)); links are never followed, and nothing was read.") }
            guard v.isRegularFile == true || v.isDirectory == true else { throw ConvertFailure("It holds something other than plain files; nothing was read.") }
            if !url.resolvingSymlinksInPath().path.hasPrefix(base + "/") { throw ConvertFailure("A path in it leaves its folder; nothing was read.") }
            if v.isRegularFile == true {
                total += v.fileSize ?? 0
                if total > ConvertLimits.unpackedBytes { throw ConvertFailure("It holds more than 50 MB; nothing was read.") }
            }
        }
        if let failure { throw failure }
    }

    /// A folder the person already has.
    public static func folder(_ url: URL) throws -> AddonSource {
        try checkTree(url)
        guard let root = findRoot(url) else { throw ConvertFailure("There is no manifest.ini in \(url.path), so this is not an NVDA add-on.") }
        return AddonSource(root: root, origin: .folder(url.path), sha256: nil, sourceURL: nil, storeEntry: nil, temporary: nil)
    }

    /// A `.nvda-addon` file the person already has, or one just downloaded (`data`).
    public static func archive(_ file: URL, label: String, origin: AddonSource.Origin, expectedSHA256: String? = nil) throws -> AddonSource {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > 0, size <= ConvertLimits.downloadBytes else { throw ConvertFailure("\(label) is empty or larger than 50 MB; nothing was read.") }
        guard let data = try? Data(contentsOf: file) else { throw ConvertFailure("\(label) could not be read.") }
        let digest = sha256Hex(data)
        if let expected = expectedSHA256, expected.lowercased() != digest {
            throw ConvertFailure("The file's SHA-256 does not match the store's list, so it is not what the store published, and nothing was read. The list says \(expected.lowercased()); the file is \(digest).")
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("turnover-convert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        do {
            let out = tmp.appendingPathComponent("unpacked")
            try unpack(file, into: out)
            try checkTree(out)
            guard let root = findRoot(out) else { throw ConvertFailure("There is no manifest.ini in \(label), so this is not an NVDA add-on.") }
            return AddonSource(root: root, origin: origin, sha256: digest, sourceURL: nil, storeEntry: nil, temporary: tmp)
        } catch { try? FileManager.default.removeItem(at: tmp); throw error }
    }

    static func unpack(_ zip: URL, into out: URL) throws {
        let names = try runTool("zipinfo", ["-1", zip.path], limit: 1024 * 1024, capture: true, message: "its list of files is too large")
        let entries = String(decoding: names, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        guard !entries.isEmpty else { throw ConvertFailure("It is not a valid add-on archive: it holds nothing.") }
        guard entries.count <= ConvertLimits.entries else { throw ConvertFailure("It holds more than \(ConvertLimits.entries) entries, which is more than an add-on needs; nothing was unpacked.") }
        for name in entries {
            let parts = name.split(whereSeparator: { $0 == "/" || $0 == "\\" })
            if name.hasPrefix("/") || name.hasPrefix("\\") || parts.contains("..") || name.contains("\0") || (name.count > 1 && name.dropFirst().first == ":") {
                throw ConvertFailure("It holds a path that leaves its own folder (\(name)); nothing was unpacked.")
            }
        }
        let listing = try runTool("zipinfo", ["-l-h-t", zip.path], limit: 1024 * 1024, capture: true, message: "its list of files is too large")
        let rows = String(decoding: listing, as: UTF8.self).split(separator: "\n")
        guard rows.count == entries.count else { throw ConvertFailure("It could not be inspected, so nothing was unpacked.") }
        for line in rows {
            let fields = line.split(maxSplits: 5, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 6, fields[4].count == 2, let type = fields[4].first, "btBT".contains(type) else { throw ConvertFailure("It could not be inspected, so nothing was unpacked.") }
            if type == "B" || type == "T" { throw ConvertFailure("It holds encrypted content; nothing was unpacked.") }
            if line.hasPrefix("l") { throw ConvertFailure("It holds a link; links are never followed, and nothing was unpacked.") }
        }
        // Count the real bytes before writing anything: the sizes an archive states can be wrong.
        _ = try runTool("unzip", ["-p", "-P", "", zip.path], limit: ConvertLimits.unpackedBytes, capture: false, message: "it unpacks to more than 50 MB")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        _ = try runTool("unzip", ["-q", "-o", "-^", "-P", "", zip.path, "-d", out.path], limit: 0, capture: false, message: "it could not be unpacked")
    }

    /// Runs one of the system's zip tools with a time limit and a cap on what it may print.
    static func runTool(_ tool: String, _ arguments: [String], limit: Int, capture: Bool, message: String, timeout: TimeInterval = 60) throws -> Data {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/\(tool)")
        process.arguments = arguments
        process.environment = ["LC_ALL": "C", "LANG": "C", "PATH": "/usr/bin:/bin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? output.fileHandleForReading.close()
            if process.isRunning { process.terminate(); usleep(200_000); if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            process.waitUntilExit()
        }
        let fd = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw ConvertFailure("It could not be inspected.") }
        let deadline = Date().addingTimeInterval(timeout)
        var result = Data(), count = 0, chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            guard Date() < deadline else { throw ConvertFailure("Checking or unpacking it took too long; nothing was read.") }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, 100)
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            guard ready > 0 else { throw ConvertFailure("It could not be inspected.") }
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n == 0 { break }
            if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard n > 0 else { throw ConvertFailure("It could not be inspected.") }
            guard n <= limit - count else { throw ConvertFailure("It is refused: \(message); nothing was read.") }
            count += n
            if capture { result.append(contentsOf: chunk.prefix(n)) }
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw ConvertFailure("It is not a valid add-on archive; nothing was read.") }
        return result
    }

    // MARK: The store

    public static let listAddress = "https://addonStore.nvaccess.org/en/all/latest.json"

    /// An https address with a host, or nil.
    static func httpsURL(_ s: String?) -> URL? {
        guard let s, let u = URL(string: s), u.scheme?.lowercased() == "https", let h = u.host, !h.isEmpty else { return nil }
        return u
    }

    /// From the store: find the id in the list, download the file from the address the list gives (https only), and refuse it
    /// unless its SHA-256 matches the list.
    public static func store(id: String, channel: String, list: Data, fetch: ConvertFetch) throws -> AddonSource {
        let entries = try StoreEntry.parse(list)
        guard let entry = StoreEntry.choose(id: id, channel: channel, from: entries) else {
            let others = entries.filter { $0.id.lowercased() == id.lowercased() }.map(\.channel)
            if !others.isEmpty { throw ConvertFailure("The store has \"\(id)\" only on the \(Set(others).sorted().joined(separator: " and ")) channel, not on \(channel). Ask for it with --channel \(others[0]).") }
            throw ConvertFailure("The store's list has no add-on with the id \"\(id)\". `turnover-plugin store search <words>` finds one by name.")
        }
        guard let url = httpsURL(entry.downloadURL) else { throw ConvertFailure("The store's address for \"\(id)\" is not an https address, so it was not fetched.") }
        guard let expected = entry.sha256, expected.count == 64 else { throw ConvertFailure("The store's list gives no SHA-256 for \"\(id)\", so it was not fetched.") }
        let data: Data
        do { data = try fetch(url, ConvertLimits.downloadBytes) } catch { throw ConvertFailure("The download failed: \(error).") }
        guard data.count <= ConvertLimits.downloadBytes else { throw ConvertFailure("The download is larger than 50 MB; nothing was read.") }
        if sha256Hex(data) != expected.lowercased() {
            throw ConvertFailure("The download's SHA-256 does not match the store's list, so it is not what the store published, and nothing was read.")
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("turnover-convert-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("addon.nvda-addon")
        try data.write(to: file)
        var source = try archive(file, label: "The download", origin: .store(id), expectedSHA256: expected)
        source.sourceURL = entry.sourceURL
        source.storeEntry = entry
        return source
    }
}

/// The real internet, for the tool. https only, redirects only to https, a cap on the size, no cookies, nothing about this Mac
/// or its user: a plain GET with a generic client name.
nonisolated public final class ConvertNetwork: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private var data = Data()
    private var failure: String?
    private let done = DispatchSemaphore(value: 0)

    private init(limit: Int) { self.limit = limit }

    public static let fetch: ConvertFetch = { url, limit in
        guard url.scheme?.lowercased() == "https" else { throw ConvertFailure("only https addresses are fetched") }
        let me = ConvertNetwork(limit: limit)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 180
        config.httpAdditionalHeaders = ["User-Agent": "turnover-plugin"]
        let session = URLSession(configuration: config, delegate: me, delegateQueue: nil)
        let task = session.dataTask(with: URLRequest(url: url))
        task.resume()
        me.done.wait()
        session.finishTasksAndInvalidate()
        if let f = me.failure { throw ConvertFailure(f) }
        return me.data
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { failure = "the server answered \(http.statusCode)"; completionHandler(.cancel); return }
        if response.expectedContentLength > Int64(limit) { failure = "it is larger than \(limit / 1024 / 1024) MB"; completionHandler(.cancel); return }
        completionHandler(.allow)
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive d: Data) {
        data.append(d)
        if data.count > limit { failure = "it is larger than \(limit / 1024 / 1024) MB"; dataTask.cancel() }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if request.url?.scheme?.lowercased() == "https" { completionHandler(request) } else { failure = "it was redirected away from https"; completionHandler(nil) }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, failure == nil { failure = error.localizedDescription }
        done.signal()
    }
}
