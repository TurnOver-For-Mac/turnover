// SPDX-License-Identifier: GPL-3.0-or-later
// What `turnover-plugin check` says about a plugin converted from an NVDA add-on (docs/PLUGIN-PLATFORM-PLAN.md, stage A,
// point 7). The record in manifest.json (`convertedFrom`) says what the original needed. Nothing is added to a converted
// plugin that the original did not need, so anything the manifest has and the record does not was put there later, by a
// hand or an AI, and is shown as an error. The credit names (author, convertedBy) never widen what a plugin may do.
import Foundation

nonisolated public enum PluginConversion {
    public struct Findings: Equatable {
        /// Stop the plugin being used or shared as it is.
        public var problems: [String] = []
        /// To fix before sharing; an error with --listing.
        public var warnings: [String] = []
    }

    /// Said when a converted plugin has no app yet (also where the loader refuses a script with no apps).
    public static let notFinished = "this converted plugin is not finished: apps is empty. The add-on named a Windows program, not a Mac app. Find the Mac app's bundle identifier (for an app that is installed: osascript -e 'id of app \"Name\"'), then put it in apps and in convertedFrom.apps"

    public static func findings(for m: PluginManifest) -> Findings {
        var f = Findings()
        guard let record = m.convertedFrom else { return f }
        let abilities = Set(record.abilities ?? []), apps = Set(record.apps ?? [])
        for a in (m.abilities ?? []) where !abilities.contains(a) {
            f.problems.append("the ability \"\(a)\" is in manifest.json but not in convertedFrom: the original add-on did not need it, so it was added after the conversion. Take it out; if it is wanted on purpose, a person adds it to convertedFrom.abilities too, knowing that is a decision to reach further than the original did")
        }
        for app in m.apps where !apps.contains(app) {
            f.problems.append("the app \"\(app)\" is in manifest.json but not in convertedFrom.apps. Choosing the Mac app is the person's job: when you have chosen it, add its identifier to convertedFrom.apps as well as to apps, so the record shows the choice was made on purpose")
        }
        if m.apps.isEmpty {
            f.problems.append(notFinished)
        }
        if (record.convertedBy ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            f.warnings.append("a converted plugin must say who converted it before it can be shared: add convertedBy to convertedFrom (turnover-plugin convert --converted-by \"Name\" does it)")
        }
        if (record.translation ?? "").lowercased() == PluginConversionRecord.notReviewed {
            f.warnings.append("converted, translation not reviewed: a person has not yet read main.js against the original add-on. When they have, they change translation to \"reviewed\" in convertedFrom. This is not approval: approving the script is the person's, in TurnOver")
        }
        return f
    }

    /// Lines for `check`: what is wrong, in words. `listing` makes the warning an error, as it is for sharing.
    public static func lines(for m: PluginManifest, listing: Bool) -> (lines: [String], problems: Int) {
        guard m.convertedFrom != nil else { return ([], 0) }
        let f = findings(for: m)
        var lines = ["Converted from an NVDA add-on:"]
        for p in f.problems { lines.append("  PROBLEM: " + p) }
        for w in f.warnings { lines.append((listing ? "  PROBLEM: " : "  WARNING: ") + w) }
        if f.problems.isEmpty && f.warnings.isEmpty { lines.append("  the abilities and apps match the record of the conversion, both names are given, and the translation has been reviewed") }
        return (lines, f.problems.count + (listing ? f.warnings.count : 0))
    }
}
