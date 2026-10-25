// SPDX-License-Identifier: GPL-3.0-or-later
// VoiceOver's own settings (voice, rate, pitch, volume, verbosity), for TurnOver to take on as its own, so the two
// readers sound the same and TurnOver needs fewer settings of its own (15 Oct 2026). VoiceOver keeps them in
// its group container, which macOS guards from other apps: whether TurnOver may read it is the first question.
//
// The probe: run once when the "probeVoiceOverSettings" default is set (then cleared). It logs which files it found
// and which setting names in them look like speech settings, with their kinds, never their values.
import Foundation
import AVFoundation

public enum VoiceOverSettings {
    static let container = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.VoiceOver/Library/Preferences")

    /// Whether VoiceOver is muted for `bundle`, read from its own settings: the mute is kept per Activity
    /// (`SCRCUserDefaultsMuteVoiceOver`, 1 muted), the app's Activity if one lists it, else the default (probe, 18 Oct
    /// 2026: one app in an Activity, another in a second Activity, the rest on the default). nil where TurnOver can't
    /// read them (no Full Disk Access).
    /// The Activity whose mute applies to `bundle` (its profile id, or "default"); nil where the settings can't be read.
    nonisolated public static func activity(for bundle: String) -> String? {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.VoiceOver/Library/Preferences/com.apple.VoiceOver4")
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("master.plist")),
              let master = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        for (id, info) in (master["allProfiles"] as? [String: Any]) ?? [:] {
            let d = info as? [String: Any] ?? [:]
            let pi = d["profileInfo"] as? [String: Any] ?? d
            if ((pi["profileApps"] as? [String]) ?? []).contains(bundle) { return id }
        }
        return "default"
    }

    /// VoiceOver's arrow-key Quick Nav in its default profile; nil where it can't be read.
    public static func arrowQuickNav() -> Bool? {
        let url = container.appendingPathComponent("com.apple.VoiceOver4/default.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        return (plist["SCRCUserDefaultsArrowKeyQuickNavEnabled"] as? NSNumber)?.boolValue
    }

    public static func probeIfAsked() {
        let d = UserDefaults.standard
        guard d.bool(forKey: "probeVoiceOverSettings") else { return }
        d.removeObject(forKey: "probeVoiceOverSettings")
        DispatchQueue.main.async { probe() }   // the developer's probe, asked for by hand: main-actor state
    }

    static func probe() {
        Log.info("VoiceOver settings probe: looking in \(container.path)")
        let files: [String]
        do { files = try FileManager.default.contentsOfDirectory(atPath: container.path) }
        catch { Log.info("VoiceOver settings probe: can't list the folder: \(error.localizedDescription)"); return }
        Log.info("VoiceOver settings probe: \(files.count) files: \(files.joined(separator: ", "))")
        let words = ["voice", "rate", "pitch", "volume", "verbos", "punct", "hint", "echo", "speech", "sound", "language", "mute"]
        // The plists here, and in the folders here (com.apple.VoiceOver4/default.plist).
        var plists: [String] = []
        for f in files {
            if f.hasSuffix(".plist") { plists.append(f); continue }
            for g in (try? FileManager.default.contentsOfDirectory(atPath: container.appendingPathComponent(f).path)) ?? [] where g.hasSuffix(".plist") {
                plists.append(f + "/" + g)
            }
        }
        for f in plists {
            let url = container.appendingPathComponent(f)
            guard let data = try? Data(contentsOf: url) else { Log.info("VoiceOver settings probe: \(f): can't read"); continue }
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                Log.info("VoiceOver settings probe: \(f): not a dictionary (\(data.count) bytes)"); continue
            }
            Log.info("VoiceOver settings probe: \(f): \(plist.count) settings")
            // Settings, not personal data: the active profile and the voice selections in full.
            if f.hasSuffix("master.plist") || f.hasSuffix(".local.plist") {
                for (k, v) in plist.sorted(by: { $0.key < $1.key }) { Log.info("VoiceOver settings probe:   \(k) = \(String(describing: v).prefix(300))") }
            }
            for key in ["VoiceOverDefaultVoiceSelections", "VoiceOverVoiceRotors", "VoiceOverCurrentRotorVoiceIdentifier", "SCRVerbosity_SCRVerbosityLevel",
                        "SCRCategories_SCRCategorySystemWide_SCRPunctuationRepeatMode", "SCRTypingEchoFeedback"] {
                if let v = plist[key] { Log.info("VoiceOver settings probe:   \(key) = \(String(describing: v).replacingOccurrences(of: "\n", with: " ").prefix(700))") }
            }
            if let m = plist["SCRCUserDefaultsMuteVoiceOver"] { Log.info("VoiceOver settings probe:   \(f) mute = \(m)") }
            if f.hasSuffix("master.plist"), let all = plist["allProfiles"] as? [String: Any] {
                for (id, info) in all {
                    let d = info as? [String: Any] ?? [:]
                    let pi = d["profileInfo"] as? [String: Any] ?? d
                    Log.info("VoiceOver settings probe:   profile \(id): name \(pi["profileName"] ?? "?"), apps \((pi["profileApps"] as? [Any])?.count ?? 0): \(String(describing: pi["profileApps"] ?? "").replacingOccurrences(of: "\n", with: " ").prefix(200))")
                }
            }
            for (k, v) in plist.sorted(by: { $0.key < $1.key }) where words.contains(where: { k.lowercased().contains($0) }) {
                Log.info("VoiceOver settings probe:   \(k): \(kind(v))")
            }
        }
    }

    /// What a value is, without what it says.
    static func kind(_ v: Any) -> String {
        switch v {
        case let n as NSNumber: return "number"
            + (CFGetTypeID(n) == CFBooleanGetTypeID() ? " (yes/no)" : "")
        case is String: return "text"
        case let a as [Any]: return "list of \(a.count)"
        case let d as [String: Any]: return "group of \(d.count): \(d.keys.sorted().prefix(12).joined(separator: ", "))"
        case is Data: return "data"
        default: return "\(type(of: v))"
        }
    }
}

// MARK: - Copying VoiceOver's settings from its export (no permission needed)
//
// VoiceOver Utility's File > Export Preferences… writes "VoiceOver Archive.voprefs", a plain plist: `export` holds
// `default` (the main settings) and `allProfiles` (activities). TurnOver reads the default voice, rate, volume,
// verbosity and typing echo and takes them as its own, so the two readers sound the same (15 Oct 2026).
// The guided flow: open VoiceOver Utility (VoiceOver leads there), press its Export item, wait for the file in
// Downloads, copy, and say what was done, with the key to do it again.
import AppKit

extension VoiceOverSettings {
    public struct Copied {
        public var voiceId = "", rate: Float = 0.5, pitch: Float = 0.5, volume: Float = 1, verbosity = "", typingEcho = ""
        public var links = "", misspelled = "", textAttributes = "", punctuation = ""
        /// VoiceOver's customisations: the Keyboard Commander's letters and their commands; the custom key bindings
        /// (a VO key with modifiers → a command, or removed); the Commanders' on/off states.
        public var commanderKeys: [(letter: String, command: String)] = []
        public var keyBindings: [(key: String, shift: Bool, command: Bool, fn: Bool, target: String, removed: Bool)] = []
        public var keyboardCommander: Bool?, numpadCommander: Bool?
        public var archiveVersion = 0
    }

    public static let key = "the TurnOver menu, Settings, Copy VoiceOver settings, Copy"

    /// The newest export in Downloads or on the Desktop, modified after `since` (nil: any).
    public static func newestExport(since: Date?) -> URL? {
        let fm = FileManager.default
        var best: (URL, Date)?
        for dir in ["Downloads", "Desktop"] {
            let d = fm.homeDirectoryForCurrentUser.appendingPathComponent(dir)
            for f in (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where f.pathExtension == "voprefs" {
                guard let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
                if let since, m <= since { continue }
                if best == nil || m > best!.1 { best = (f, m) }
            }
        }
        return best?.0
    }

    public enum ReadError: Error { case notAnExport, noDefaults, noVoice }

    /// The settings in an export. Pure apart from the file read.
    public static func read(_ url: URL) throws -> Copied {
        let data = try Data(contentsOf: url)
        guard let top = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let export = top["export"] as? [String: Any] else { throw ReadError.notAnExport }
        guard let d = export["default"] as? [String: Any] else { throw ReadError.noDefaults }
        var c = Copied()
        c.archiveVersion = (top["ArchiveVersionVO"] as? NSNumber)?.intValue ?? 0
        // [language, {voiceId, rate, pitch, volume}, language, {…}]: the first selection is the main voice.
        if let sel = d["VoiceOverDefaultVoiceSelections"] as? [Any],
           let voice = sel.first(where: { $0 is [String: Any] }) as? [String: Any],
           let id = voice["voiceId"] as? String, !id.isEmpty {
            c.voiceId = id
            c.rate = (voice["rate"] as? NSNumber)?.floatValue ?? 0.5
            c.volume = (voice["volume"] as? NSNumber)?.floatValue ?? 1
            c.pitch = (voice["pitch"] as? NSNumber)?.floatValue ?? 0.5
        } else {
            // Some exports retain flattened speech fields rather than VoiceSelection objects. Only the default
            // voice is copied: category voices and Activities must not replace it. Percentages need converting.
            let system = "SCRCategories_SCRCategorySystemWide_SCRSpeechComponentSettings_"
            let language = "SCRCategories_SCRCategorySystemWide_SCRSpeechLanguages_default_SCRSpeechComponentSettings_"
            let customised = d[language + "SCRVoiceUseCustomizedVoiceSettings"] as? Bool == true
            func field(_ name: String) -> Any? {
                if customised, let value = d[language + name] { return value }
                return d[system + name]
            }
            guard let id = field("SCRVoiceIdentifier") as? String, !id.isEmpty else { throw ReadError.noVoice }
            func fraction(_ name: String, default fallback: Float) -> Float {
                guard let value = field(name) as? NSNumber else { return fallback }
                let fraction = value.floatValue / 100
                return fraction.isFinite ? min(1, max(0, fraction)) : fallback
            }
            c.voiceId = id
            c.rate = fraction("SCRRateAsPercent", default: 0.5)
            c.pitch = fraction("SCRPitchAsPercent", default: 0.5)
            c.volume = fraction("SCRVolumeAsPercent", default: 1)
        }
        c.verbosity = d["SCRVerbosity_SCRVerbosityLevel"] as? String ?? ""
        c.typingEcho = d["SCRTypingEchoFeedback"] as? String ?? ""
        c.links = d["SCRCategories_SCRCategorySystemWide_SCRLinkAttributeDescriptionLevel"] as? String ?? ""
        c.misspelled = d["SCRCategories_SCRCategorySystemWide_SCRMisspelledWordsDescriptionLevel"] as? String ?? ""
        c.textAttributes = d["SCRCategories_SCRCategorySystemWide_SCRTextAttributesDescriptionLevel"] as? String ?? ""
        c.punctuation = (d["SCRCategories_SCRCategorySystemWide_SCRPunctuationVerbosenessLevel"] ?? d["SCRCUserDefaultsCategorySystemWide_PunctuationVerbosenessLevel"]).map { "\($0)" } ?? ""
        c.keyboardCommander = d["SCRCKeyboardCommanderEnabled"] as? Bool
        c.numpadCommander = d["SCRNumPadCommanderEnabled"] as? Bool
        for (k, v) in d {
            if k.hasPrefix("custom.keyboard-commander.SCRKeyboardCommander_"), let command = v as? String,
               let code = UInt32(k.components(separatedBy: "_").last ?? "", radix: 16), let scalar = Unicode.Scalar(code) {
                c.commanderKeys.append((String(Character(scalar)).lowercased(), command))
            }
            if k.hasPrefix("custom.custom-keybindings."), let b = v as? [String: Any], let key = b["key"] as? [String: Any], let chars = key["characters"] as? String, !chars.isEmpty {
                c.keyBindings.append((chars.lowercased(), key["shifted"] as? Bool ?? false, key["commanded"] as? Bool ?? false, key["fned"] as? Bool ?? false, b["command"] as? String ?? "", b["remove"] as? Bool ?? false))
            }
        }
        return c
    }

    /// The settings as they were before the last copy, for Undo (15 Oct 2026: "a restore just in case").
    static let beforeURL = AppPaths.file("settings-before-voiceover-copy.json")
    static func keepBefore(at url: URL) {
        // Only until an undo: a second copy must not overwrite the values from before the first (the code review, 17 Oct 2026).
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        if let data = try? JSONEncoder().encode(config) { try? data.write(to: url, options: .atomic) }
    }
    /// Undo: the fields the copy changes go back to the kept values; everything else stays as it is now.
    public static func undo() -> String {
        guard let data = try? Data(contentsOf: beforeURL), let before = try? JSONDecoder().decode(Config.self, from: data) else {
            return String(localized: "There's nothing to put back: VoiceOver's settings haven't been copied on this Mac.", comment: "Reverting the VoiceOver settings copy")
        }
        config.speech.voice = before.speech.voice; config.speech.rate = before.speech.rate
        config.speech.pitch = before.speech.pitch; config.speech.volume = before.speech.volume
        config.presentation.speakHints = before.presentation.speakHints
        config.presentation.reportObjectDescriptions = before.presentation.reportObjectDescriptions
        config.keyboard.speakTypedCharacters = before.keyboard.speakTypedCharacters
        config.keyboard.speakTypedWords = before.keyboard.speakTypedWords
        Speech.player.rate = config.speech.rate; Speech.player.pitch = config.speech.pitchMultiplier
        Speech.player.volume = Float(config.speech.volume) / 100
        config.save()
        try? FileManager.default.removeItem(at: beforeURL)
        let voice = AVSpeechSynthesisVoice(identifier: config.speech.voice)?.name ?? String(localized: "its voice", comment: "TurnOver's voice, when it has no name")
        Log.info("VoiceOver settings copy undone: back to \(voice), rate \(Int((config.speech.rate * 100).rounded()))")
        return String(localized: "Put back: \(voice), \(Phrases.rate(Int((config.speech.rate * 100).rounded()))), and the verbosity and typing echo from before the copy.", comment: "The VoiceOver settings copy reverted: the voice, then the rate")
    }

    /// Applies what TurnOver can, saves, and returns what to say. A voice TurnOver can't use (a Siri voice) keeps
    /// the current one and says so.
    /// Tools and tests may supply a separate Undo snapshot URL rather than use the app's live backup.
    public static func apply(_ c: Copied, undoSnapshot: URL? = nil) -> String {
        keepBefore(at: undoSnapshot ?? beforeURL)
        var said: [String] = []
        var voiceNote = ""
        if let v = AVSpeechSynthesisVoice(identifier: c.voiceId), !c.voiceId.contains("gryphon") {
            config.speech.voice = c.voiceId
            Speech.player?.voiceIdentifier = c.voiceId   // (the setting changed but the player kept the old voice: "it says Alex but it is using Eddy", 16 Oct 2026)
            Languages.forget()
            said.append(v.name)
        } else {
            // Said at the end, apart from the list, or the copy sounded like a failure ("it fails because it can't
            // find a voice", a reader on AppleVis with a Siri voice, 26 Oct 2026). The Siri voices are Apple's own:
            // only Siri and VoiceOver may speak with them, and no other program is given them.
            let current = AVSpeechSynthesisVoice(identifier: config.speech.voice)?.name ?? String(localized: "its voice", comment: "TurnOver's voice, when it has no name")
            let siri = c.voiceId.contains("gryphon") || c.voiceId.lowercased().contains("siri")
            voiceNote = siri
                ? String(localized: "VoiceOver's voice is a Siri voice, which Apple gives to Siri and VoiceOver alone, so TurnOver keeps \(current); choose a voice in Settings, Speech.", comment: "Copying VoiceOver's settings: %@ is TurnOver's voice")
                : String(localized: "VoiceOver's voice isn't one TurnOver can use, so TurnOver keeps \(current); choose a voice in Settings, Speech.", comment: "Copying VoiceOver's settings: %@ is TurnOver's voice")
            Log.info("VoiceOver settings: voice \(c.voiceId) not usable; keeping \(config.speech.voice)")
        }
        config.speech.rate = min(1.0, max(0.1, c.rate))
        Speech.player?.rate = config.speech.rate
        said.append(Phrases.rate(Int((config.speech.rate * 100).rounded())))
        config.speech.pitch = min(1, max(0, c.pitch))
        Speech.player?.pitch = config.speech.pitchMultiplier
        if abs(c.pitch - 0.5) > 0.01 { said.append(String(localized: "pitch \(String(Int((config.speech.pitch * 100).rounded())))", comment: "The speech pitch, out of 100")) }
        config.speech.volume = Int((min(1, max(0.1, c.volume)) * 100).rounded())
        Speech.player?.volume = Float(config.speech.volume) / 100
        switch c.verbosity {   // VoiceOver's low, medium and high: hints and descriptions
        case "SCRVerbosityLow": config.presentation.speakHints = false; config.presentation.reportObjectDescriptions = false; said.append(String(localized: "low verbosity", comment: "Copying VoiceOver's settings"))
        case "SCRVerbosityMedium": config.presentation.speakHints = false; config.presentation.reportObjectDescriptions = true; said.append(String(localized: "medium verbosity", comment: "Copying VoiceOver's settings"))
        case "SCRVerbosityHigh": config.presentation.speakHints = true; config.presentation.reportObjectDescriptions = true; said.append(String(localized: "high verbosity", comment: "Copying VoiceOver's settings"))
        default: break
        }
        // Links, misspelled words and text attributes as VoiceOver marks them: a sound (VoiceOver's own file), words,
        // or nothing (17 Oct 2026: "based on the VoiceOver archive and how that is set up").
        func level(_ v: String) -> ElementReport? { v.isEmpty ? nil : v.contains("Sound") || v.contains("Tone") ? .tone : v.contains("DoNothing") || v.contains("None") ? .off : .speech }
        if let l = level(c.links) { config.documentFormatting.links = l
            said.append(l == .tone ? String(localized: "links by sound", comment: "Copying VoiceOver's settings") : l == .off ? String(localized: "links not marked", comment: "Copying VoiceOver's settings") : String(localized: "links said", comment: "Copying VoiceOver's settings")) }
        if let m = level(c.misspelled) { config.documentFormatting.spellingErrors = m
            said.append(m == .tone ? String(localized: "misspellings by sound", comment: "Copying VoiceOver's settings") : m == .off ? String(localized: "misspellings not marked", comment: "Copying VoiceOver's settings") : String(localized: "misspellings said", comment: "Copying VoiceOver's settings")) }
        if !c.textAttributes.isEmpty { let on = !c.textAttributes.contains("None"); config.documentFormatting.reportFontAttributes = on; if on { said.append(String(localized: "text attributes said", comment: "Copying VoiceOver's settings")) } }
        // Punctuation: VoiceOver's none, some, most, all (the key's value, whatever its spelling, by its word or number).
        if !c.punctuation.isEmpty {
            let v = c.punctuation.lowercased()
            let level: SymbolLevel? = v.contains("none") || v == "0" ? SymbolLevel.none : v.contains("some") || v == "1" ? .some : v.contains("most") || v == "2" ? .most : v.contains("all") || v == "3" ? .all : nil
            if let level { config.speech.symbolLevel = level; said.append(String(localized: "punctuation \(level.name)", comment: "Copying VoiceOver's settings: %@ is the punctuation level")) }
        }
        // The Commanders and the custom bindings, cloned into TurnOver's own keys (17 Oct 2026).
        if let on = c.keyboardCommander { config.keyboard.optionCommander = on }
        if let on = c.numpadCommander { config.keyboard.numpadCommander = on }
        var letters: [String] = []
        for (letter, command) in c.commanderKeys {
            config.keyboard.userGestures["kb:rightoption+" + letter] = VoiceOverCommands.target(for: command).stored
            letters.append(letter.uppercased())
        }
        if !letters.isEmpty { said.append(String(localized: "Keyboard Commander keys \(letters.sorted().joined(separator: ", "))", comment: "Copying VoiceOver's settings: the letters given")) }
        var bound = 0
        for b in c.keyBindings {
            let name = KeyNames.code(for: b.key).map { KeyNames.name(for: $0) } ?? b.key
            let id = "kb:turnover+" + (b.command ? "command+" : "") + (b.shift ? "shift+" : "") + name
            config.keyboard.userGestures[id] = b.removed ? UserGestures.Target.removed.stored : VoiceOverCommands.target(for: b.target).stored
            bound += 1
        }
        if bound > 0 { said.append(bound == 1 ? String(localized: "1 custom key binding", comment: "Copying VoiceOver's settings") : String(localized: "\(String(bound)) custom key bindings", comment: "Copying VoiceOver's settings")) }
        if !c.typingEcho.isEmpty {
            let chars = c.typingEcho.contains("Characters"), words = c.typingEcho.contains("Words")
            config.keyboard.speakTypedCharacters = chars ? .editControls : .off
            config.keyboard.speakTypedWords = words ? .editControls : .off
            said.append(chars && words ? String(localized: "typing echo characters and words", comment: "Copying VoiceOver's settings") : chars ? String(localized: "typing echo characters", comment: "Copying VoiceOver's settings")
                        : words ? String(localized: "typing echo words", comment: "Copying VoiceOver's settings") : String(localized: "typing echo off", comment: "Copying VoiceOver's settings"))
        }
        config.save()
        Log.info("VoiceOver settings copied (archive version \(c.archiveVersion)): \(said.joined(separator: ", "))")
        let copied = String(localized: "VoiceOver settings copied: \(said.joined(separator: ", ")).", comment: "The VoiceOver settings copy done: %@ lists what was copied")
        let again = String(localized: "Run it again whenever you change VoiceOver's settings: the TurnOver menu, or the speech settings' last stop, sync with VoiceOver.", comment: "The VoiceOver settings copy done")
        return [copied, voiceNote, again].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Said by whichever reader is talking (VoiceOver leads in VoiceOver Utility).
    static func sayByEitherReader(_ text: String) { VoiceOverSpeak.say(text) }

    private static var flowRunning = false
    private static let utilityBundle = "com.apple.VoiceOverUtility"

    /// The guided copy: VoiceOver Utility opens with VoiceOver, TurnOver presses Export, the person presses Return to
    /// save to Downloads, and the new file is read as soon as it appears (up to four minutes).
    /// Installed by the app: the export done by accessibility, nobody pressing anything (ActivityFlow, 16 Oct 2026).
    nonisolated(unsafe) public static var automaticExport: ((@escaping (URL?) -> Void) -> Void)?

    public static func startFlow() {
        guard !flowRunning else { return }
        if let auto = automaticExport {
            flowRunning = true
            Speech.speakMessage(String(localized: "Copying VoiceOver's settings; a moment.", comment: "Spoken message"))
            auto { file in
                DispatchQueue.main.async {
                    if let file { finish(with: file) } else { flowRunning = false; Speech.speakMessage(String(localized: "VoiceOver's settings couldn't be read this time.", comment: "Spoken message")) }
                }
            }
            return
        }
        flowRunning = true
        let since = Date()
        sayByEitherReader(String(localized: "VoiceOver Utility is opening, with VoiceOver. When the save sheet appears, press Return to save to Downloads; TurnOver copies the settings when the file appears.", comment: "Spoken message"))
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: utilityBundle) else {
            Speech.speakMessage(String(localized: "VoiceOver Utility wasn't found.", comment: "Spoken message")); flowRunning = false; return
        }
        // The save sheet opens on Downloads: the Utility's save panel remembers its last folder in its own defaults
        // (15 Oct 2026: "set the destination it falls on").
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
        CFPreferencesSetAppValue("NSNavLastRootDirectory" as CFString, downloads as CFString, utilityBundle as CFString)
        CFPreferencesAppSynchronize(utilityBundle as CFString)
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        var presses = 0
        func pressExport() {
            DispatchQueue.main.asyncAfter(deadline: .now() + (presses == 0 ? 3.0 : 1.0)) {
                presses += 1
                if pressExportItem() { Log.info("VoiceOver settings: pressed Export Preferences in VoiceOver Utility"); return }
                if presses < 8 { pressExport() } else { Log.info("VoiceOver settings: couldn't press Export; the person chooses File, Export Preferences") }
            }
        }
        pressExport()
        var looks = 0
        func look() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                looks += 1
                if let f = newestExport(since: since) {
                    // Written in full a moment later.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { finish(with: f) }
                    return
                }
                if looks < 240 { look() } else {
                    flowRunning = false
                    sayByEitherReader(String(localized: "No VoiceOver settings file appeared; nothing was changed.", comment: "Spoken message"))
                }
            }
        }
        look()
    }

    private static func finish(with file: URL) {
        flowRunning = false
        let text: String
        do { text = apply(try read(file)) }
        catch { text = "The VoiceOver settings file couldn't be read (\(error)); nothing was changed."; Log.warning("VoiceOver settings: \(error)") }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: utilityBundle) { app.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { sayByEitherReader(text) }
    }

    /// File > Export Preferences… in VoiceOver Utility, by accessibility. False if it isn't there or is disabled.
    private static func pressExportItem() -> Bool { pressFileMenuItem(prefix: "Export Preferences") }
    /// A File menu item of VoiceOver Utility by title prefix, by accessibility. False if it isn't there or is disabled.
    public static func pressFileMenuItem(prefix: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: utilityBundle).first else { return false }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        guard let bar = ax.element(kAXMenuBarAttribute),
              let file = bar.elements(kAXChildrenAttribute).first(where: { $0.string(kAXTitleAttribute) == "File" }),
              let menu = file.elements(kAXChildrenAttribute).first else { return false }
        for item in menu.elements(kAXChildrenAttribute) where (item.string(kAXTitleAttribute) ?? "").hasPrefix(prefix) {
            guard (item.attr(kAXEnabledAttribute) as? Bool) != false else { return false }
            return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
        }
        return false
    }
    /// The Utility's front window's sheet (a save or open panel, or an alert), if one is up.
    public static func utilitySheet() -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: utilityBundle).first else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        // The save and open panels come as the focused window with the role AXSheet (seen 16 Oct 2026); an alert
        // hangs off the main window's AXSheets.
        if let f = ax.element(kAXFocusedWindowAttribute), f.role == "AXSheet" { return f }
        for w in ax.elements(kAXWindowsAttribute) {
            if w.role == "AXSheet" { return w }
            if let s = w.elements("AXSheets").first { return s }
        }
        return nil
    }
    /// The text of the sheet up now, joined (to recognise "Are you sure you want to import preferences?").
    public static func utilitySheetText() -> String {
        guard let s = utilitySheet() else { return "" }
        var out: [String] = []; var queue = [s]; var visited = 0
        while !queue.isEmpty, visited < 3000 {
            let e = queue.removeFirst(); visited += 1
            if e.role == "AXStaticText", let v = e.string(kAXValueAttribute) { out.append(v) }
            queue.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
        return out.joined(separator: " ")
    }
    /// Presses the sheet's button with this title (OK on the import alert).
    public static func pressSheetButton(_ title: String) -> Bool {
        guard let s = utilitySheet() else { return false }
        // A panel's buttons are its own children (Save, Cancel, Open, OK); the file browser inside it has thousands
        // of nodes, so the shallow levels are looked at first (the walk never reached Save, 16 Oct 2026).
        func find(_ root: AXUIElement, depth: Int) -> AXUIElement? {
            let kids = root.elements(kAXChildrenAttribute)
            if let b = kids.first(where: { $0.role == "AXButton" && $0.string(kAXTitleAttribute) == title }) { return b }
            guard depth > 0 else { return nil }
            for k in kids { if let b = find(k, depth: depth - 1) { return b } }
            return nil
        }
        guard let b = find(s, depth: 3) else { Log.io("VoiceOver Utility: no \(title) button within three levels of the sheet"); return false }
        return AXUIElementPerformAction(b, kAXPressAction as CFString) == .success
    }
    /// In the open panel: the list row whose name is `name` (without the extension), opened (AXOpen), which chooses it.
    public static func openSheetRow(named name: String) -> Bool {
        guard let s = utilitySheet() else { return false }
        var queue = [s]; var visited = 0
        while !queue.isEmpty, visited < 3000 {
            let e = queue.removeFirst(); visited += 1
            if e.role == "AXTextField", let v = e.string(kAXValueAttribute), v == name || v == name + ".voprefs" {   // ours shows its extension; the Utility's own export hides it (16 Oct 2026)
                // The cell holding the name opens the file.
                // The open action, on the cell or its row; the answer code isn't trusted (16 Oct 2026), the sheet
                // changing is.
                var p: AXUIElement? = e
                for _ in 0..<3 {
                    guard let x = p else { break }
                    var names: CFArray?
                    if AXUIElementCopyActionNames(x, &names) == .success, ((names as? [String]) ?? []).contains("AXOpen") { _ = AXUIElementPerformAction(x, "AXOpen" as CFString); return true }
                    p = x.element(kAXParentAttribute)
                }
                return false
            }
            queue.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
        return false
    }
    public static var utilityBundleID: String { utilityBundle }
    /// The Utility is up with a window (its menu is usable only then).
    public static func utilityHasWindow() -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: utilityBundle).first, !app.isTerminated else { return false }
        return !AXUIElementCreateApplication(app.processIdentifier).elements(kAXWindowsAttribute).isEmpty
    }
    public static func quitUtility() {
        // With a sheet up the polite quit is refused: the sheet is cancelled first, and the quit forced after a second.
        _ = pressSheetButton("Cancel")
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: utilityBundle) {
            app.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { if !app.isTerminated { app.forceTerminate() } }
        }
    }
    /// Where the Utility's save sheet opens: its own default, which the flows point at a folder of TurnOver's.
    public static func pointSaveSheet(at folder: URL) {
        CFPreferencesSetAppValue("NSNavLastRootDirectory" as CFString, folder.path as CFString, utilityBundle as CFString)
        CFPreferencesAppSynchronize(utilityBundle as CFString)
    }
    /// The newest export in a folder, modified after `since`.
    public static func newestExport(in folder: URL, since: Date) -> URL? {
        let fm = FileManager.default
        var best: (URL, Date)?
        for f in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where f.pathExtension == "voprefs" {
            guard let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, m > since else { continue }
            if best == nil || m > best!.1 { best = (f, m) }
        }
        return best?.0
    }
}

// MARK: - Speaking through VoiceOver

/// Words for the person while VoiceOver leads: VoiceOver says them itself (its AppleScript `output`, which works
/// when "Allow VoiceOver to be controlled with AppleScript" is on), else an accessibility announcement, which
/// VoiceOver may or may not read (it didn't, for the layer, 15 Oct 2026). A tone first, so there's always something.
public enum VoiceOverSpeak {
    public static func say(_ text: String, tone: Bool = false) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { Speech.speakMessage(text); return }
        // Coexisting, VoiceOver is silent wherever TurnOver reads: TurnOver says it there (the code review, 17 Oct 2026).
        if Coexist.on, Core.active { Speech.speakMessage(text); return }
        if tone { Tones.beep(880, 50, volume: 0.2) }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "tell application id \"com.apple.VoiceOver\" to output \"\(escaped)\""]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
            if p.terminationStatus != 0 { Log.info("VoiceOver didn't take the words to say (status \(p.terminationStatus)): \(Log.words(String(text.prefix(40))))") }
        }
    }
}
