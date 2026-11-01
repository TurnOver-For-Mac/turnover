// SPDX-License-Identifier: GPL-3.0-or-later
// Where TurnOver keeps its files. The app had an older name until 3 Oct 2026 (see `oldName`): the first time
// TurnOver runs, the old folders (settings, reading positions, logs, plugins) are moved to TurnOver's names.
import Foundation

nonisolated public enum AppPaths {
    public static let name = "TurnOver"
    /// The app's name before 3 Oct 2026, spelled out so no renaming of the source can turn it into `name` again (it
    /// did once: the folder was then "migrated" into itself and its logs deleted at every start).
    static let oldName = String(["B", "o", "s", "u", "n"])

    /// ~/Library/Application Support/TurnOver
    public static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let new = base.appendingPathComponent(name, isDirectory: true)
        migrate(from: base.appendingPathComponent(oldName, isDirectory: true), to: new)
        try? FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        return new
    }()

    /// ~/TurnOver Plugins (the briefs made for AIs).
    public static let pluginBriefs: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let new = home.appendingPathComponent("\(name) Plugins", isDirectory: true)
        migrate(from: home.appendingPathComponent("\(oldName) Plugins", isDirectory: true), to: new)
        return new
    }()

    public static func file(_ relative: String) -> URL { support.appendingPathComponent(relative) }

    /// Move the old folder's contents into the new one, item by item (the new folder may already exist: an
    /// installer's restart flag made it before TurnOver first ran, 3 Oct 2026). What is already there stays.
    private static func migrate(from old: URL, to new: URL) {
        let fm = FileManager.default
        guard old.standardizedFileURL.path != new.standardizedFileURL.path, fm.fileExists(atPath: old.path) else { return }
        if !fm.fileExists(atPath: new.path) { try? fm.moveItem(at: old, to: new); return }
        for item in (try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil)) ?? [] {
            let dest = new.appendingPathComponent(item.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) { try? fm.moveItem(at: item, to: dest) }
            else if item.hasDirectoryPath, item.lastPathComponent == "logs" {
                for f in (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? [] {
                    try? fm.moveItem(at: f, to: dest.appendingPathComponent(f.lastPathComponent))
                }
            }
        }
        try? fm.removeItem(at: old.appendingPathComponent("logs"))
        if ((try? fm.contentsOfDirectory(atPath: old.path)) ?? []).isEmpty { try? fm.removeItem(at: old) }
    }
}
