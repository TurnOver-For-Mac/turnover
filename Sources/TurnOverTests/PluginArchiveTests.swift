// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

private let archiveManifest = Data(#"{"id":"archive-test","name":"Archive test","version":"1"}"#.utf8)

private func withArchiveFixture(_ body: (URL, URL) throws -> Void) throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("turnover-archive-test-\(UUID().uuidString)")
    let source = root.appendingPathComponent("source"), work = root.appendingPathComponent("work")
    try fm.createDirectory(at: source, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: work, withIntermediateDirectories: true)
    try body(source, work)
}

private func archiveFile(_ name: String, _ data: Data, in source: URL) throws {
    let path = source.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: path)
}

private func makePluginZIP(_ source: URL, options: [String] = []) throws -> Data {
    let zip = source.deletingLastPathComponent().appendingPathComponent("fixture.zip")
    try? FileManager.default.removeItem(at: zip)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.currentDirectoryURL = source
    process.arguments = ["-q", "-r", "-y"] + options + [zip.path, "."]
    process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain: "ArchiveFixture", code: 1) }
    return try Data(contentsOf: zip)
}

private func refuseArchive(_ data: Data, in work: URL, reason: String) throws {
    do {
        let unpacked = try PluginArchive.unpack(data, temporaryDirectory: work)
        try? FileManager.default.removeItem(at: unpacked.tmp)
        Harness.fail("archive accepted: expected \(reason)")
    } catch {
        check(error.localizedDescription.contains(reason), "expected \(reason), got \(error.localizedDescription)")
    }
    expect(try FileManager.default.contentsOfDirectory(atPath: work.path), [], "failed unpack leaves no temporary files")
}

/// Alter only ZIP header metadata; compressed content and its real checksum stay intact.
private func changeArchiveHeaders(_ data: Data, _ edit: (inout Data, Int, Bool) -> Void) -> Data {
    var changed = data
    for (signature, central) in [(Data([0x50, 0x4B, 0x03, 0x04]), false), (Data([0x50, 0x4B, 0x01, 0x02]), true)] {
        var offset = 0
        while let range = changed.range(of: signature, in: offset..<changed.count) {
            edit(&changed, range.lowerBound, central)
            offset = range.upperBound
        }
    }
    return changed
}

private func zipNumber(_ data: Data, at offset: Int, bytes: Int) -> Int {
    (0..<bytes).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
}

private func setZIPNumber(_ number: Int, in data: inout Data, at offset: Int, bytes: Int) {
    for i in 0..<bytes { data[offset + i] = UInt8(truncatingIfNeeded: number >> (i * 8)) }
}

func pluginArchiveTests() {
    test("archive: oversized inspection output stops the tool") {
        let started = ContinuousClock.now
        do {
            _ = try PluginArchive.run("yes", [], limit: 1024, capture: true)
            Harness.fail("unbounded output accepted")
        } catch {
            check(error.localizedDescription.contains("listing is too large"), "output limit error: \(error)")
        }
        check(started.duration(to: .now) < .seconds(3), "tool is stopped and reaped promptly")
    }
    test("archive: a stalled inspection has a deadline and stops the tool") {
        let started = ContinuousClock.now
        do {
            _ = try PluginArchive.run("tail", ["-f", "/dev/null"], limit: 1024, capture: true, timeout: .milliseconds(30))
            Harness.fail("stalled tool accepted")
        } catch {
            check(error.localizedDescription.contains("took too long"), "deadline error: \(error)")
        }
        check(started.duration(to: .now) < .seconds(3), "timeout cleanup does not hang")
    }
    test("archive: root and enclosing-folder layouts preserve files and names") {
        for prefix in ["", "Example plugin/"] {
            try withArchiveFixture { source, work in
                try archiveFile(prefix + "manifest.json", archiveManifest, in: source)
                let name = "fixtures/a café with spaces\nand a newline.txt"
                let content = Data("Public example text 🌍".utf8)
                try archiveFile(prefix + name, content, in: source)
                let unpacked = try PluginArchive.unpack(makePluginZIP(source), temporaryDirectory: work)
                defer { try? FileManager.default.removeItem(at: unpacked.tmp) }
                expect(try Data(contentsOf: unpacked.folder.appendingPathComponent("manifest.json")), archiveManifest)
                expect(try Data(contentsOf: unpacked.folder.appendingPathComponent(name)), content)
            }
        }
    }
    test("archive: exactly 256 entries are accepted, 257 are refused") {
        try withArchiveFixture { source, work in
            try archiveFile("manifest.json", archiveManifest, in: source)
            for i in 1..<PluginArchive.maxEntries { try archiveFile("file-\(i).txt", Data(), in: source) }
            let unpacked = try PluginArchive.unpack(makePluginZIP(source), temporaryDirectory: work)
            expect(try FileManager.default.contentsOfDirectory(atPath: unpacked.folder.path).count, 256)
            try FileManager.default.removeItem(at: unpacked.tmp)
            try archiveFile("one-too-many.txt", Data(), in: source)
            try refuseArchive(makePluginZIP(source), in: work, reason: "256 archive entries")
        }
    }
    test("archive: directory entries count toward the limit") {
        try withArchiveFixture { source, work in
            try archiveFile("manifest.json", archiveManifest, in: source)
            for i in 0..<PluginArchive.maxEntries {
                try FileManager.default.createDirectory(at: source.appendingPathComponent("directory-\(i)"), withIntermediateDirectories: false)
            }
            try refuseArchive(makePluginZIP(source), in: work, reason: "256 archive entries")
        }
    }
    test("archive: exactly 16 MiB expanded is accepted, one extra byte is refused") {
        try withArchiveFixture { source, work in
            try archiveFile("manifest.json", archiveManifest, in: source)
            var payload = Data(repeating: 65, count: PluginArchive.maxExpandedBytes - archiveManifest.count)
            try archiveFile("payload.txt", payload, in: source)
            let zipped = try makePluginZIP(source)
            check(zipped.count < 100_000, "a small download can expand to the limit")
            let unpacked = try PluginArchive.unpack(zipped, temporaryDirectory: work)
            expect(try Data(contentsOf: unpacked.folder.appendingPathComponent("payload.txt")), payload)
            try FileManager.default.removeItem(at: unpacked.tmp)
            payload.append(65)
            try archiveFile("payload.txt", payload, in: source)
            try refuseArchive(makePluginZIP(source), in: work, reason: "16 MiB")
        }
    }
    test("archive: expanded size is the total across all files") {
        try withArchiveFixture { source, work in
            try archiveFile("manifest.json", archiveManifest, in: source)
            for name in ["first.txt", "second.txt"] {
                try archiveFile(name, Data(repeating: 65, count: PluginArchive.maxExpandedBytes / 2), in: source)
            }
            try refuseArchive(makePluginZIP(source), in: work, reason: "16 MiB")
        }
    }
    test("archive: understated size fields cannot bypass the expansion limit") {
        try withArchiveFixture { source, work in
            try archiveFile("manifest.json", archiveManifest, in: source)
            try archiveFile("payload.txt", Data(repeating: 65, count: PluginArchive.maxExpandedBytes + 1), in: source)
            // Both local and central directory headers claim one byte per file. macOS zipinfo and unzip -t
            // accept this, while unzip -p and ditto still expand the real payload (27 Oct 2026, macOS 27.0.1).
            let understated = changeArchiveHeaders(try makePluginZIP(source)) { data, start, central in
                let size = start + (central ? 24 : 22)
                data.replaceSubrange(size..<(size + 4), with: [1, 0, 0, 0])
            }
            try refuseArchive(understated, in: work, reason: "16 MiB")
        }
    }
    test("archive: missing Unix file-type bits do not bypass limits or reject ordinary files") {
        try withArchiveFixture { source, work in
            try archiveFile("manifest.json", archiveManifest, in: source)
            // Python's ZipFile.writestr can leave the Unix file type unset: zipinfo prints '?' rather than '-'.
            let zipped = changeArchiveHeaders(try makePluginZIP(source)) { data, start, central in
                if central { data[start + 41] &= 0x0F }
            }
            let unpacked = try PluginArchive.unpack(zipped, temporaryDirectory: work)
            defer { try? FileManager.default.removeItem(at: unpacked.tmp) }
            expect(try Data(contentsOf: unpacked.folder.appendingPathComponent("manifest.json")), archiveManifest)
        }
    }
    test("archive: extraction ignores oversized local entries absent from the central directory") {
        try withArchiveFixture { source, work in
            try archiveFile("manifest.json", archiveManifest, in: source)
            try archiveFile("hidden.txt", Data(repeating: 65, count: PluginArchive.maxExpandedBytes + 1), in: source)
            var zipped = try makePluginZIP(source)
            let signature = Data([0x50, 0x4B, 0x01, 0x02])
            var offset = 0, removed = 0
            while let record = zipped.range(of: signature, in: offset..<zipped.count) {
                let start = record.lowerBound
                let nameLength = zipNumber(zipped, at: start + 28, bytes: 2)
                let name = String(decoding: zipped[(start + 46)..<(start + 46 + nameLength)], as: UTF8.self)
                if name == "hidden.txt" {
                    removed = 46 + nameLength + zipNumber(zipped, at: start + 30, bytes: 2) + zipNumber(zipped, at: start + 32, bytes: 2)
                    zipped.removeSubrange(start..<(start + removed))
                    break
                }
                offset = record.upperBound
            }
            guard removed > 0, let end = zipped.range(of: Data([0x50, 0x4B, 0x05, 0x06]))?.lowerBound else {
                return Harness.fail("fixture's directory not found")
            }
            setZIPNumber(1, in: &zipped, at: end + 8, bytes: 2)
            setZIPNumber(1, in: &zipped, at: end + 10, bytes: 2)
            let size = zipNumber(zipped, at: end + 12, bytes: 4)
            setZIPNumber(size - removed, in: &zipped, at: end + 12, bytes: 4)
            let unpacked = try PluginArchive.unpack(zipped, temporaryDirectory: work)
            defer { try? FileManager.default.removeItem(at: unpacked.tmp) }
            expect(try FileManager.default.contentsOfDirectory(atPath: unpacked.folder.path), ["manifest.json"])
            expect(try Data(contentsOf: unpacked.folder.appendingPathComponent("manifest.json")), archiveManifest)
        }
    }
    test("archive: local and central filenames must agree") {
        try withArchiveFixture { source, work in
            try archiveFile("manifest.json", archiveManifest, in: source)
            let mismatched = changeArchiveHeaders(try makePluginZIP(source)) { data, start, central in
                if !central { data[start + 30] = UInt8(ascii: "x") }
            }
            try refuseArchive(mismatched, in: work, reason: "valid plugin archive")
        }
    }
    test("archive: Finder-style ZIPs preserve plugin content and count AppleDouble metadata as files") {
        try withArchiveFixture { source, work in
            try archiveFile("manifest.json", archiveManifest, in: source)
            try archiveFile("fixtures/example.txt", Data("Public fixture".utf8), in: source)
            let fork = Data("Public resource fork".utf8)
            let forkPath = "fixtures/example.txt/..namedfork/rsrc"
            try fork.write(to: source.appendingPathComponent(forkPath))
            let zip = source.deletingLastPathComponent().appendingPathComponent("finder.zip")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, zip.path]
            try process.run(); process.waitUntilExit()
            expect(process.terminationStatus, 0)
            let unpacked = try PluginArchive.unpack(Data(contentsOf: zip), temporaryDirectory: work)
            defer { try? FileManager.default.removeItem(at: unpacked.tmp) }
            expect(try Data(contentsOf: unpacked.folder.appendingPathComponent("manifest.json")), archiveManifest)
            expect(try String(contentsOf: unpacked.folder.appendingPathComponent("fixtures/example.txt"), encoding: .utf8), "Public fixture")
            let metadata = unpacked.tmp.appendingPathComponent("unpacked/__MACOSX/source/fixtures/._example.txt")
            let appleDouble = try Data(contentsOf: metadata)
            check(appleDouble.range(of: fork) != nil, "metadata is decompressed as an ordinary file, included in the byte limit")
        }
    }
    test("archive: invalid, truncated and empty ZIPs are refused and cleaned up") {
        try withArchiveFixture { source, work in
            try archiveFile("manifest.json", archiveManifest, in: source)
            let zipped = try makePluginZIP(source)
            let emptyZIP = Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18))
            for invalid in [Data("not a ZIP".utf8), Data(zipped.prefix(zipped.count / 2)), emptyZIP] {
                try refuseArchive(invalid, in: work, reason: "valid plugin archive")
            }
        }
    }
    test("archive: corrupt checksums stop extraction and clean up") {
        try withArchiveFixture { source, work in
            try archiveFile("manifest.json", archiveManifest, in: source)
            let corrupt = changeArchiveHeaders(try makePluginZIP(source)) { data, start, central in
                data[start + (central ? 16 : 14)] ^= 1
            }
            try refuseArchive(corrupt, in: work, reason: "valid plugin archive")
        }
    }
    test("archive: password-protected files are refused without prompting") {
        try withArchiveFixture { source, work in
            try archiveFile("manifest.json", archiveManifest, in: source)
            try refuseArchive(makePluginZIP(source, options: ["-P", "public-test-password"]), in: work, reason: "valid plugin archive")
        }
    }
    test("archive: links are refused before their targets can be used") {
        try withArchiveFixture { source, work in
            try archiveFile("manifest.json", archiveManifest, in: source)
            try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "manifest.json")
            try refuseArchive(makePluginZIP(source), in: work, reason: "holds a link")
        }
    }
    test("archive: absolute and parent-traversing paths are refused") {
        try withArchiveFixture { source, work in
            try archiveFile("manifest.json", archiveManifest, in: source)
            try archiveFile("ordinary.txt", Data("Example".utf8), in: source)
            let zipped = try makePluginZIP(source)
            for name in ["/outside.txt", "../entry.txt"] {
                var unsafe = zipped
                let original = Data("ordinary.txt".utf8), replacement = Data(name.utf8)
                expect(original.count, replacement.count, "keep ZIP offsets intact")
                while let range = unsafe.range(of: original) { unsafe.replaceSubrange(range, with: replacement) }
                try refuseArchive(unsafe, in: work, reason: "path outside its folder")
            }
        }
    }
    test("archive: a missing manifest is refused and cleaned up after extraction") {
        try withArchiveFixture { source, work in
            try archiveFile("notes.txt", Data("Example".utf8), in: source)
            try refuseArchive(makePluginZIP(source), in: work, reason: "couldn't be unpacked")
        }
    }
}
