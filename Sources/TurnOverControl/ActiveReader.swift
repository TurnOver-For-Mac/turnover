// SPDX-License-Identifier: GPL-3.0-or-later
// Which copy of TurnOver is the one in use, when a contributor has their own build beside the published one
// (issue 248, 7 Nov 2026). The published TurnOver is com.turnover.reader; a contributor's build installs beside it as
// TurnOver Developer, com.turnover.reader.developer (build.sh). Only one runs at a time, and Command Control Period
// belongs to one helper (the key can be held by one program only, 18 Oct 2026), so the helper asks this record which
// copy to start and stop. Each copy writes itself here as it starts; switching starts the other.
import Foundation

public enum ActiveReader {
    public static let published = "com.turnover.reader"
    public static let developer = "com.turnover.reader.developer"

    /// ~/Library/Application Support/TurnOver/active-reader: one line, a bundle identifier.
    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TurnOver/active-reader")
    }

    /// The copy in use, if one has been recorded.
    public static func recorded() -> String? {
        guard let s = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let id = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return [published, developer].contains(id) ? id : nil
    }

    /// Recorded as each copy starts. A failed write leaves the last copy recorded, which the helper checks is installed.
    public static func record(_ id: String) {
        guard [published, developer].contains(id), recorded() != id else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (id + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// The other copy's identifier.
    public static func other(than id: String) -> String { id == developer ? published : developer }
}
