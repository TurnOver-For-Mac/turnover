// SPDX-License-Identifier: GPL-3.0-or-later
// What this build offers: one TurnOver, the full screen reader, with its newer apps and features marked experimental
// where they sit (experimentalApps, CoExist). The names and numbers a report or the About item needs are here too.
// (A smaller Standard edition lived behind `isRelease` from 15 to 18 Oct 2026; one app since, and its code went
// with the open-source tidy of 20 Oct 2026.)
import Foundation
import AppKit

public enum Edition {
    /// Apps whose support is new and still settling: "experimental" in This app (18 Oct 2026).
    public static let experimentalApps: Set<String> = ["com.apple.Preview", "com.apple.iCal", "com.apple.Pages", "com.apple.Numbers", "com.apple.Keynote", "com.amazon.Lassen", "com.apple.reminders", "com.apple.AddressBook", "com.apple.iBooksX", "com.apple.calculator", "com.apple.Maps", "com.apple.FaceTime", "com.apple.freeform", "com.apple.shortcuts", "com.apple.Photos"]
    /// Said at start ("TurnOver on") and in the log.
    public static var editionName: String { "TurnOver" }
    /// A marker build.sh looks for in each slice of a universal binary, so a slice built from other sources or with
    /// other flags can't ship inside the package unnoticed (code review, 16 Oct 2026).
    public static let marker = "TURNOVER-EDITION-BETA"
    /// The guide in the bundle ("Read the guide", the layer's H).
    public static var guideName: String { "TurnOver Guide" }
    public static let version = "2.0"   // 2.0 with build 17: Swift 6, the three sets of keys (the welcome shows again)
    /// A build made on a developer's own Mac (build.sh marks every build it doesn't strip for release). Only these
    /// honour the developer switches that would hand what TurnOver reads to any program on the Mac (logSpeech,
    /// imageDescribeSaveCapture, kokoro, testSpeech): a code review on 20 Oct 2026. A published build ignores them.
    nonisolated public static let isDevBuild: Bool = Bundle.main.object(forInfoDictionaryKey: "TODevBuild") as? Bool ?? false
    /// A developer switch, honoured only in a developer's build.
    nonisolated public static func devDefault(_ key: String) -> Bool { isDevBuild && UserDefaults.standard.bool(forKey: key) }
    /// Where Support TurnOver goes: straight to the payment pages, nothing in between (20 Oct 2026: "as easy as possible").
    public static let sponsorsURL = "https://github.com/sponsors/TurnOver-For-Mac"
    public static let kofiURL = "https://ko-fi.com/oliverkennett"
    /// Every published build, newest first, each with its notes and its zip: for going back to an earlier one.
    public static let releasesURL = "https://github.com/TurnOver-For-Mac/turnover/releases"
    /// The build number (CFBundleVersion; raised for every published build), so a report says exactly which build.
    public static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }
    /// "TurnOver 1.0", or "TurnOver 1.0 (build 3)" once builds are numbered.
    public static var fullName: String { build == version ? "TurnOver \(version)" : "TurnOver \(version) (build \(build))" }   // (feedback subjects are counted by it)
    /// TurnOver's issues on GitHub: Send feedback and app requests open its forms there, filled in.
    public static let issuesURL = "https://github.com/TurnOver-For-Mac/turnover/issues"

    public static let supportedApps: [(bundle: String, name: String)] = [
        ("com.apple.mail", "Mail"),
        ("com.apple.Safari", "Safari"),
        ("com.apple.Terminal", "Terminal"),
        ("com.microsoft.Word", "Microsoft Word (preview, off until you turn it on)"),
        // Previews, off until turned on (6 Oct 2026).
        ("com.apple.finder", "Finder (preview, off until you turn it on)"),
        ("com.anthropic.claudefordesktop", "Claude (preview, off until you turn it on)"),
        ("com.apple.TextEdit", "TextEdit (preview, off until you turn it on)"),
        ("com.apple.AppStore", "App Store (preview, off until you turn it on)"),
        ("com.apple.Music", "Music (preview, off until you turn it on)"),
        ("com.apple.podcasts", "Podcasts (preview, off until you turn it on)"),
        ("com.apple.TV", "TV (preview, off until you turn it on)"),
        ("com.apple.MobileSMS", "Messages (preview, off until you turn it on)"),
        ("net.whatsapp.WhatsApp", "WhatsApp (preview, off until you turn it on)"),
    ]

    /// Apps added on one Mac only, for trying out before testers get them (TextEdit, 6 Oct 2026): the
    /// "devApps" default, a list of bundle identifiers. Testers' Macs have none.
    public static var devApps: [(bundle: String, name: String)] {
        (UserDefaults.standard.stringArray(forKey: "devApps") ?? []).map { b in
            (b, NSWorkspace.shared.urlForApplication(withBundleIdentifier: b).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? b)
        }
    }

    /// Whether TurnOver may lead in an application: the supported ones, this Mac's own extras, and any unverified
    /// app the user has given to TurnOver in Apps, Other apps on this Mac.
    public static func supports(_ bundle: String) -> Bool {
        isVerified(bundle) || config.applications.leadBundles.contains(bundle)
    }

    /// Checked and supported by TurnOver (or added on this Mac); every other app is "unverified".
    public static func isVerified(_ bundle: String) -> Bool {
        // Steam and Steam Helper (Big Picture's process) are TurnOver's own: the menu offered "make a plugin" for
        // "Steam Helper", and a tester went looking for one (a tester, AppleVis, 16 Oct 2026).
        supportedApps.contains { $0.bundle == bundle } || devApps.contains { $0.bundle == bundle } || Games.leads(bundle)
    }

    /// Plugins are on unless the "plugins" default turns them off (`defaults write com.turnover.reader plugins -bool false`).
    /// Parked 17 Oct 2026 (a way to load other people's rules into a reader with this much access needed more care),
    /// open again from 20 Oct 2026 with TurnOver open source: plugins are data (no code), checked by the plugin checker,
    /// sent as public pull requests to the plugins repository and reviewed before the library's signed list carries
    /// them. "plugins" set to false turns them off.
    public static var includesPlugins: Bool { UserDefaults.standard.object(forKey: "plugins") as? Bool ?? true }
}
