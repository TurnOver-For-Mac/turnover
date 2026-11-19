// SPDX-License-Identifier: GPL-3.0-or-later
// Who looks after a plugin, and how to tell them (docs/PLUGIN-PLATFORM-PLAN.md, "Who looks after a plugin"; 16 Nov 2026). Each plugin
// in the Plugins menu gets "Report a problem with this plugin": it says who looks after the plugin and copies the address with the
// plugin's name and version and TurnOver's build, so a report reaches the author with what they need to answer it.
import Foundation
import AppKit

nonisolated public enum PluginSupport {
    /// The address for reporting a problem: `support`, or the older `contact` where a plugin has only that. Nil if neither.
    public static func address(for manifest: PluginManifest) -> String? {
        for candidate in [manifest.support, manifest.contact] {
            if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        }
        return nil
    }

    /// Whether an address is one TurnOver accepts for the library: a web address (https) or an email address, on one line.
    public static func isValidAddress(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 300, PluginText.isPlain(t), !t.contains(" ") else { return false }
        if t.hasPrefix("https://") { return URL(string: t)?.host?.contains(".") == true }
        return t.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil
    }

    /// What is said, and what is copied, for a plugin's "Report a problem" item.
    public static func report(for manifest: PluginManifest, build: String) -> (spoken: String, copied: String) {
        let who = (manifest.author ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let address = address(for: manifest)
        var copied = "Plugin: \(manifest.name) \(manifest.version) (\(manifest.id))\nTurnOver: \(build)"
        copied += "\nWho looks after it: \(who.isEmpty ? "not named" : who)"
        if let address { copied += "\nWhere to report: \(address)" }
        let looksAfter = who.isEmpty
            ? String(localized: "The author of \(manifest.name) is not named.", comment: "Said when a person asks to report a problem with a plugin whose author is not named; the placeholder is the plugin's name")
            : String(localized: "\(manifest.name) is looked after by \(who).", comment: "Said when a person asks to report a problem with a plugin; the placeholders are the plugin's name and its author")
        guard let address else {
            return (String(localized: "\(looksAfter) It gives no address for problems. The plugin's name and version and TurnOver's build are on the clipboard.", comment: "Said after Report a problem with a plugin that has no address: the first sentence says who looks after it"), copied)
        }
        return (String(localized: "\(looksAfter) To report a problem, write to \(address). The address, the plugin's name and version and TurnOver's build are on the clipboard.", comment: "Said after Report a problem with a plugin: the first sentence says who looks after it, then the address"), copied)
    }

    /// The menu item (the live Mac: the clipboard and TurnOver's voice).
    @MainActor public static func reportItem(for manifest: PluginManifest) -> MenuItem {
        MenuItem("Report a problem with this plugin", .action {
            let (spoken, copied) = report(for: manifest, build: Edition.fullName)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copied, forType: .string)
            Speech.speakMessage(spoken)
        }, hint: "Says who looks after it and copies where to write, with its name and version and TurnOver's build")
    }
}
