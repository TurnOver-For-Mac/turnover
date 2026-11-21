// SPDX-License-Identifier: GPL-3.0-or-later
// The eight things a plugin script may be allowed to do (docs/PLUGIN-SCRIPTS-PLAN.md, "The clear line"), and which
// of them each operation needs. TurnOver checks the table on every request, so a script cannot do more than its
// manifest asked and the person agreed to. Also here: the abilities a plugin really has, and the sentences TurnOver says
// when the person is asked to approve a script (stage 2, 15 Nov 2026).
import Foundation
import AppKit
import TurnOverPluginWire

nonisolated public enum ScriptAbility: String, CaseIterable, Sendable, Comparable {
    /// The names, roles and values of items in the plugin's apps.
    case read
    /// Speak, and play TurnOver's own sounds.
    case say
    case press
    case focus
    case menu
    case keys
    /// Change an item's text or value.
    case edit
    /// Put text on the clipboard (reading it is `clipboardRead`).
    case clipboard
    /// Stage B (16 Nov 2026). Work in every app, not only the named ones (the manifest's apps is ["*"]), except the forbidden apps.
    case everywhere
    /// Be told what TurnOver itself says while one of the plugin's apps is in front.
    case hearSpeech
    /// Read the clipboard's text while one of the plugin's apps is in front.
    case clipboardRead

    public static func < (a: ScriptAbility, b: ScriptAbility) -> Bool { a.rawValue < b.rawValue }
}

public typealias ScriptOperation = PluginWire.Operation

nonisolated extension PluginManifest {
    /// The one app name that means every app. A manifest with a script may give `apps` as exactly this, and only with the
    /// `everywhere` ability (PluginFormat.checkScript refuses the one without the other).
    public static let everyApp = "*"
    /// A script that works in every app: it has a script, its only app is `["*"]`, and it asks for `everywhere`. All three, or
    /// it is not (a request that is half of it is refused when the plugin loads, so no plugin is ever treated as everywhere
    /// by one of them alone).
    public var worksEverywhere: Bool { script != nil && apps == [Self.everyApp] && (abilities ?? []).contains(ScriptAbility.everywhere.rawValue) }
}

nonisolated public enum ScriptAbilities {
    /// What an operation needs, all of it. Logging, and the plugin's own stored data, need nothing: they reach
    /// nothing outside the plugin.
    public static func required(for operation: ScriptOperation) -> Set<ScriptAbility> {
        switch operation {
        case .say, .sound, .tone, .choose, .ask: return [.say]
        case .itemText: return [.read]
        case .itemSetCaret, .itemSelect: return [.edit]
        case .clipboard: return [.clipboardRead]
        case .log, .storageGet, .storageSet, .storageRemove: return []
        case .focused, .find, .itemRefresh, .itemParent, .itemChildren: return [.read]
        case .itemRead: return [.read, .say]   // it reads the item and speaks it
        case .itemPress: return [.press]
        case .itemFocus: return [.focus]
        case .itemSetValue: return [.edit]
        case .menu: return [.menu]
        case .keys: return [.keys]
        case .copy: return [.clipboard]
        }
    }

    /// The abilities an operation needs that the plugin does not have, in a fixed order.
    public static func missing(for operation: ScriptOperation, granted: Set<ScriptAbility>) -> [ScriptAbility] {
        required(for: operation).subtracting(granted).sorted()
    }
}

/// One line of what TurnOver says at approval. The kind lets a screen show the author's words or a warning differently;
/// the text is the whole sentence, in words for a listener.
nonisolated public struct ScriptApprovalLine: Equatable, Sendable {
    public enum Kind: String, Sendable { case apps, author, converted, ability, reason, cannot, closedAppWarning, signature, unchecked }
    public let kind: Kind
    public let text: String
}

extension ScriptAbilities {
    /// What the plugin really has: the abilities its manifest names, together with those its profile.json rules imply (a
    /// key that presses needs `press`, a label needs `read`, and so on: PluginListing.abilitiesUsed). The profile and
    /// the script share one approval, so a script cannot reach past its abilities by leaving the work to a key in
    /// profile.json (docs/PLUGIN-SCRIPTS-PLAN.md, "Approval").
    public static func effective(for plugin: LoadedPlugin) -> Set<ScriptAbility> {
        var names = Set(plugin.manifest?.abilities ?? [])
        if let profile = plugin.profile {
            names.formUnion(PluginListing.abilitiesUsed(by: profile))
            // What a profile rule says aloud or keeps quiet is speech control, whether or not the listing counts it so: a silence
            // keeps TurnOver from saying something, a watch says what changed, and a key that reads speaks (16 Nov 2026 review).
            if !(profile.silence ?? []).isEmpty || !(profile.watch ?? []).isEmpty || (profile.keys ?? []).contains(where: { $0.action == "read" }) { names.insert("say") }
        }
        return Set(names.compactMap(ScriptAbility.init(rawValue:)))
    }

    /// What a person hears at approval, one sentence at a time: which apps, what it can do, what it can never do, the
    /// author's own words (marked as theirs), a warning for an app where a plugin can do more harm, and whether anyone
    /// has checked it. `appName` turns a bundle identifier into the app's name where the Mac knows it.
    @MainActor public static func approvalLines(for plugin: LoadedPlugin, origin: ScriptOrigin = .file, signature: ScriptTrust.SignatureStatus = .none,
                                                appName: @MainActor (String) -> String? = ScriptAbilities.installedAppName) -> [ScriptApprovalLine] {
        guard let manifest = plugin.manifest else { return [] }
        var lines: [ScriptApprovalLine] = []
        let everywhere = manifest.worksEverywhere
        let names = manifest.apps.map { appName($0) ?? $0 }
        let appList = ListFormatter.localizedString(byJoining: names)
        if everywhere {
            // Said plainly and first: this is the most a script's reach can be (stage B, 16 Nov 2026).
            lines.append(.init(kind: .apps, text: String(localized: "\(manifest.name) has a script. It works in every app you use, not only one, and goes on working whichever app you are in, except in password and permission dialogs and the login window. \"Those apps\" below means every app.", comment: "Said when asking a person to approve a plugin's script that works in every app: the plugin's name")))
        } else {
            lines.append(.init(kind: .apps, text: names.count == 1
                ? String(localized: "\(manifest.name) has a script. It works only in \(appList), and does nothing while you are in another app.", comment: "Said when asking a person to approve a plugin's script: the plugin, then the one app it works in")
                : String(localized: "\(manifest.name) has a script. It works only in these apps: \(appList), and does nothing while you are in another app.", comment: "Said when asking a person to approve a plugin's script: the plugin, then the apps it works in")))
        }
        let described = (manifest.description ?? manifest.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(.init(kind: .author, text: described.isEmpty
            ? String(localized: "The author gave no description of what it is for.", comment: "Said when asking a person to approve a plugin's script")
            : String(localized: "The author's own words about it: \(described)", comment: "Said when asking a person to approve a plugin's script: the plugin's description, written by its author, not by TurnOver")))
        // A plugin converted from an NVDA add-on says whose work it is and who converted it. Credit only: it changes nothing about what the plugin may do.
        if let from = manifest.convertedFrom {
            let creator = (from.author ?? manifest.author ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let converter = (from.convertedBy ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let text: String
            switch (creator.isEmpty, converter.isEmpty) {
            case (false, false): text = String(localized: "This was converted from the NVDA add-on \(from.id) by \(creator), and converted by \(converter).", comment: "Said when asking a person to approve a plugin's script converted from an NVDA add-on: the add-on's id, its creator, and who converted it")
            case (false, true): text = String(localized: "This was converted from the NVDA add-on \(from.id) by \(creator). The person who converted it is not named.", comment: "Said when asking a person to approve a plugin's script converted from an NVDA add-on: the add-on's id and its creator")
            case (true, false): text = String(localized: "This was converted from the NVDA add-on \(from.id), whose creator is not named, and converted by \(converter).", comment: "Said when asking a person to approve a plugin's script converted from an NVDA add-on: the add-on's id and who converted it")
            case (true, true): text = String(localized: "This was converted from the NVDA add-on \(from.id). Neither its creator nor the person who converted it is named.", comment: "Said when asking a person to approve a plugin's script converted from an NVDA add-on: the add-on's id")
            }
            lines.append(.init(kind: .converted, text: text))
        }
        let granted = effective(for: plugin)
        for ability in ScriptAbility.allCases where granted.contains(ability) {
            lines.append(.init(kind: .ability, text: sentence(for: ability, alsoReads: granted.contains(.read))))
            // The author's reason follows TurnOver's own sentence, marked as theirs. It never replaces it, and it only follows an ability
            // the plugin really has (a reason for one it does not have is not said).
            if let reason = reasonText(manifest.reasons?[ability.rawValue]) {
                lines.append(.init(kind: .reason, text: String(localized: "The author says it uses this to: \(reason)", comment: "Said when asking a person to approve a plugin's script, after what an ability allows: the author's own reason for it, in their words, not TurnOver's")))
            }
        }
        if granted.isEmpty {
            lines.append(.init(kind: .ability, text: String(localized: "It asks to do nothing in those apps. It can only think and keep its own notes.", comment: "Said when asking a person to approve a plugin's script that asks for no abilities")))
        }
        lines.append(.init(kind: .cannot, text: everywhere
            ? String(localized: "It can never use the internet, read or change your files, see the keys you press, or see a password.", comment: "Said when asking a person to approve a plugin's script that works in every app: what no script can ever do")
            : String(localized: "It can never use the internet, read or change your files, see the keys you press, see a password, or reach any other app.", comment: "Said when asking a person to approve a plugin's script: what no script can ever do")))
        if everywhere {
            lines.append(.init(kind: .closedAppWarning, text: String(localized: "In passwords, settings, terminals and browsers it can only read and speak. It can never press, type or choose anything there, hear what TurnOver says there or read your clipboard there, whatever else it is allowed to do.", comment: "Said when asking a person to approve a plugin's script that works in every app: what it can do in the sensitive apps")))
        }
        let closed = manifest.apps.compactMap { PluginPolicy.closedApps[$0] }
        if !closed.isEmpty {
            var unique: [String] = []
            for name in closed where !unique.contains(name) { unique.append(name) }   // two names for one app (1Password) are said once
            let list = ListFormatter.localizedString(byJoining: unique)
            lines.append(.init(kind: .closedAppWarning, text: String(localized: "In \(list) it can only read and speak: passwords, settings, terminals and browsers are like this. It can never press, type or choose anything there, whatever else it is allowed to do.", comment: "Said when asking a person to approve a plugin's script that works in a sensitive app, where scripts may only read and speak; the placeholder is the app names")))
        }
        switch signature {
        case .valid(let fingerprint):
            lines.append(.init(kind: .signature, text: String(localized: "It is signed with the key \(fingerprint). That says who made it, not that it is safe.", comment: "Said when asking a person to approve a plugin's script: the signing key's fingerprint, in groups of four")))
        case .invalid:
            lines.append(.init(kind: .signature, text: String(localized: "It has a signature, but the signature does not match its files, so the files were changed after it was signed.", comment: "Said when asking a person to approve a plugin's script")))
        case .none: break
        }
        if origin != .library || signature == .none {
            lines.append(.init(kind: .unchecked, text: String(localized: "Nobody has checked this script. Approve it only if you wrote it or trust the person who did.", comment: "Said when asking a person to approve a plugin's script that is not from the reviewed library")))
        }
        return lines
    }

    /// The author's reason as it may be said: plain text, at most 150 characters, trimmed; nil when there is none or it is not allowed.
    nonisolated package static func reasonText(_ reason: String?) -> String? {
        guard let reason else { return nil }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.count > reasonCharacters || !PluginText.isPlain(trimmed) ? nil : trimmed
    }
    /// The most characters an author's reason may have.
    nonisolated public static let reasonCharacters = 150

    /// Whether the library wants a reason for it: every ability above reading and speaking.
    nonisolated public static func needsReason(_ ability: ScriptAbility) -> Bool { ability != .read && ability != .say }

    /// One sentence for an ability, plain and short. `alsoReads`: the plugin has `read` too, which `everywhere` says.
    package static func sentence(for ability: ScriptAbility, alsoReads: Bool = false) -> String {
        switch ability {
        case .everywhere:
            return alsoReads
                ? String(localized: "It works in every app except passwords and permission dialogs, its keys work in every app, and, because it can also read, it can read what is on the screen wherever you are.", comment: "Said when asking a person to approve a plugin's script: the everywhere ability, for a plugin that can also read")
                : String(localized: "It works in every app except passwords and permission dialogs, and its keys work in every app.", comment: "Said when asking a person to approve a plugin's script: the everywhere ability")
        case .hearSpeech:
            return String(localized: "It hears what TurnOver says to you in those apps, as TurnOver says it, except in password fields. It cannot change it or stop it.", comment: "Said when asking a person to approve a plugin's script: the hearSpeech ability")
        case .clipboardRead:
            return String(localized: "It can read what you copy: the text on the clipboard, while you are in those apps.", comment: "Said when asking a person to approve a plugin's script: the clipboardRead ability")
        case .read: return String(localized: "It can read what is on the screen in those apps, including text you have typed there, the selected text and whole lines, but never a password.", comment: "Said when asking a person to approve a plugin's script: the read ability")
        case .say: return String(localized: "It can speak, change or silence what TurnOver says in those apps, play TurnOver's own sounds and tones, and ask you to choose from a list or type a line.", comment: "Said when asking a person to approve a plugin's script: the say ability")
        case .press: return String(localized: "It can press buttons and other controls in those apps.", comment: "Said when asking a person to approve a plugin's script: the press ability")
        case .focus: return String(localized: "It can move the keyboard focus to an item in those apps.", comment: "Said when asking a person to approve a plugin's script: the focus ability")
        case .menu: return String(localized: "It can choose commands from those apps' menus.", comment: "Said when asking a person to approve a plugin's script: the menu ability")
        case .keys: return String(localized: "It can press keys in those apps for you.", comment: "Said when asking a person to approve a plugin's script: the keys ability")
        case .edit: return String(localized: "It can change the text or value of a field in those apps, and move the cursor or the selection in it.", comment: "Said when asking a person to approve a plugin's script: the edit ability")
        case .clipboard: return String(localized: "It can put text on the clipboard. It cannot read what is on it unless it also has the clipboardRead ability, which is said separately.", comment: "Said when asking a person to approve a plugin's script: the clipboard ability")
        }
    }

    /// The name of an installed or running app, or nil where the Mac does not have it.
    @MainActor public static func installedAppName(_ bundle: String) -> String? {
        if let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.localizedName { return name }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
