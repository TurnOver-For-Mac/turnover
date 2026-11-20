// SPDX-License-Identifier: GPL-3.0-or-later
// Sound sets of the user's own (a request from the owner, 19 Nov 2026: "a means for people to introduce and choose their
// own sound sets"). A set is a folder in ~/Library/Application Support/TurnOver/Sound Sets/, with one audio file per sound
// event, named by the event's identifier (SoundEvents). Where a set has no file for an event TurnOver's own sound plays;
// an empty file is silence. Chosen in Settings, Sounds, and saved as "set:<folder name>" in the same setting as
// "voiceover" and "turnover".
import Foundation
import AVFoundation
import TurnOverSpeech

/// One thing TurnOver can sound: a stable identifier (the base name of the file in a set), a plain description, and what
/// TurnOver's own set plays for it, for the starter set.
public struct SoundEvent: Sendable {
    public let id: String
    public let summary: String
    /// The file of TurnOver's own set (Resources/Sounds, without ".wav") that plays for this event, if there is one.
    package let ownFile: String?
    /// A plain tone TurnOver's own set plays for it, where it is made in code: hertz, milliseconds, volume.
    package let tone: (hertz: Double, ms: Int, volume: Float)?
    /// Why the starter set has no file for it, when it has none.
    let absent: String
}

public enum SoundEvents {
    private static func e(_ id: String, _ summary: String, own: String? = nil, tone: (Double, Int, Float)? = nil, absent: String = "TurnOver's own set plays nothing for this event.") -> SoundEvent {
        SoundEvent(id: id, summary: summary, ownFile: own, tone: tone.map { (hertz: $0.0, ms: $0.1, volume: $0.2) }, absent: absent)
    }
    /// Every event TurnOver can sound, in the order the read-me lists them.
    public static let all: [SoundEvent] = [
        e("boundary", "The edge of a line, a list or a document was reached.", own: "edge"),
        e("activate", "An item was pressed or followed, including a mouse click.", own: "press"),
        e("focus-tick", "The focus moved to a new control.", own: "tick"),
        e("link", "The reading position is on a link.", own: "link"),
        e("spelling-error", "The reading position is on a misspelled word.", own: "spelling"),
        e("heading-1", "A heading of level 1.", own: "heading1"),
        e("heading-2", "A heading of level 2.", own: "heading2"),
        e("heading-3", "A heading of level 3.", own: "heading3"),
        e("heading-4", "A heading of level 4.", own: "heading4"),
        e("heading-5", "A heading of level 5.", own: "heading5"),
        e("heading-6", "A heading of level 6.", own: "heading6"),
        e("list", "A list.", own: "list"),
        e("landmark", "A landmark on a web page.", own: "landmark"),
        e("table", "A table.", own: "table"),
        e("graphic", "A graphic or image.", own: "graphic"),
        e("block-quote", "A block quote.", own: "blockquote"),
        e("focus-mode", "Typing into a page: focus mode began.", own: "focus_mode"),
        e("browse-mode", "Reading a page again: browse mode began.", own: "browse_mode"),
        e("comment", "Commented text in a document.", own: "comment"),
        e("marked", "A problem was marked, with Mark a problem.", own: "marked"),
        e("installed", "An app finished installing in the App Store window.", tone: (880, 80, 0.25)),
        e("waiting-tick", "Once a second while something is gathered or an AI is asked.", tone: (880, 30, 0.1)),
        e("keystroke-beep", "A key was typed while VoiceOver is off.", tone: (1000, 15, 0.25)),
        e("jump", "The review cursor jumped to another place.", absent: "TurnOver's own set plays a lower or higher tone depending on the jump, which does not fit in one file."),
        e("say-tone", "The tone before a message TurnOver gives to VoiceOver to say.", tone: (880, 50, 0.2)),
        e("progress", "A progress bar's beep.", absent: "TurnOver's own set plays a tone whose pitch rises with the percentage, which does not fit in one file."),
        e("startup", "TurnOver has started.", own: "startup"),
        e("take-over", "TurnOver took over from VoiceOver.", own: "take_over"),
        e("hand-back", "TurnOver handed back to VoiceOver.", own: "hand_back"),
        e("braille-connected", "A braille display was connected.", own: "braille_on"),
        e("braille-disconnected", "A braille display was disconnected.", own: "braille_off"),
        e("search-not-found", "A search found nothing."),
        e("search-wrapped-forward", "A search went on from the end back to the start."),
        e("search-wrapped-back", "A search went on from the start back to the end."),
        e("menu-opened", "A menu opened."),
        e("context-menu-opened", "A context menu or pop-up appeared.", own: "popup"),
        e("page-loaded", "A web page finished loading.", own: "page_loaded"),
        e("rotor-previous", "The rotor moved to its previous setting."),
        e("rotor-next", "The rotor moved to its next setting."),
        e("window-activated", "A window came to the front."),
        e("dialog-appeared", "A dialog or system prompt appeared."),
        e("selection-added", "Text was added to the selection."),
        e("drill-in", "Moved into a group of items.", own: "drill_in"),
        e("drill-out", "Moved out of a group of items.", own: "drill_out"),
        e("quick-nav-on", "Quick Nav was turned on.", own: "quicknav_on"),
        e("quick-nav-off", "Quick Nav was turned off.", own: "quicknav_off"),
        e("tracking-on", "Trackpad commands were turned on.", own: "tracking_on"),
        e("tracking-off", "Trackpad commands were turned off.", own: "tracking_off"),
        e("empty-space", "The finger on the trackpad is over empty space.", own: "empty"),
        e("announcement", "A notification banner appeared.", own: "announcement"),
        e("secure-character", "A character was typed into a secure field.", own: "secure"),
    ]
    public static var ids: [String] { all.map(\.id) }

    /// The event for one of VoiceOver's sound files, as TurnOver asks for it (any ending).
    nonisolated package static func id(forVoiceOverFile asked: String) -> String? {
        voiceOverFiles[(asked as NSString).deletingPathExtension]
    }
    nonisolated private static let voiceOverFiles: [String: String] = [
        "WrapBoundary": "boundary", "LinkBegin": "link", "Misspelled": "spelling-error", "Select": "activate", "SingleClick": "activate",
        "NotFound": "search-not-found", "MenuDown": "menu-opened", "PopupAppeared": "context-menu-opened",
        "WebAreaLoaded": "page-loaded", "WebPageLoaded": "page-loaded", "RotorLeft": "rotor-previous", "RotorRight": "rotor-next",
        "WrapForward": "search-wrapped-forward", "WrapBack": "search-wrapped-back", "WindowActivated": "window-activated",
        "Alert": "dialog-appeared", "DrillIn": "drill-in", "DrillOut": "drill-out",
        "QuickNavOn": "quick-nav-on", "QuickNavSingleKeyOn": "quick-nav-on", "QuickNavArrowKeyOn": "quick-nav-on",
        "QuickNavOff": "quick-nav-off", "QuickNavSingleKeyOff": "quick-nav-off", "QuickNavArrowKeyOff": "quick-nav-off",
        "TrackingOn": "tracking-on", "TrackingOff": "tracking-off", "EmptySpace": "empty-space", "Announcement": "announcement",
        "SecureCharacter": "secure-character", "BrailleDisplayConnected": "braille-connected", "BrailleDisplayDisconnected": "braille-disconnected",
    ]
    /// The event for a name given to `Tones.invented` where that tone has no other logic around it.
    nonisolated package static func id(forInvented name: String) -> String? {
        ["installed": "installed", "waiting_tick": "waiting-tick", "keystroke_beep": "keystroke-beep", "jump": "jump", "say_tone": "say-tone"][name]
    }
}

/// Main actor, like Tones and the settings it reads: the state is touched on the main thread only.
public enum SoundSets {
    /// A test points this at a temporary folder; nothing else sets it.
    package static var rootOverride: URL?
    /// A test sets this to see which event would play, with nothing played.
    package static var playProbe: ((String) -> Void)?
    public static let savedPrefix = "set:"
    package static let extensions = ["wav", "aiff", "aif", "caf", "m4a", "mp3"]
    /// ~/Library/Application Support/TurnOver/Sound Sets (not made until asked for).
    public static var root: URL { rootOverride ?? AppPaths.support.appendingPathComponent("Sound Sets", isDirectory: true) }

    /// The folder name in a saved sounds setting ("set:My sounds"), or nil for any other value.
    public static func setName(fromSaved saved: String) -> String? {
        guard saved.hasPrefix(savedPrefix) else { return nil }
        let name = String(saved.dropFirst(savedPrefix.count))
        return name.isEmpty ? nil : name
    }
    public static func saved(_ name: String) -> String { savedPrefix + name }

    /// Every folder in the sound sets folder, by name, sorted as Finder does.
    public static func names() -> [String] { names(in: root) }
    package static func names(in parent: URL) -> [String] {
        let list = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return list.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// What a set holds for one event.
    package enum Entry: Equatable { case silent, file(URL) }

    /// The files of one folder by event identifier. The base name, in any case, is the identifier; the first ending of
    /// `extensions` found wins. Files that are not events are ignored. A file of no bytes is silence.
    package static func entries(in folder: URL) -> [String: Entry] {
        let list = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        var best: [String: (rank: Int, url: URL)] = [:]
        for url in list {
            let ext = url.pathExtension.lowercased()
            guard let rank = extensions.firstIndex(of: ext) else { continue }
            let id = url.deletingPathExtension().lastPathComponent.lowercased()
            if let have = best[id], have.rank <= rank { continue }
            best[id] = (rank, url)
        }
        var out: [String: Entry] = [:]
        for (id, found) in best {
            let size = (try? found.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            out[id] = size == 0 ? .silent : .file(found.url)
        }
        return out
    }
    /// The file for one event in a folder: nil if there is none; a file of no bytes comes back too (the caller says silence).
    package static func file(for id: String, in folder: URL) -> URL? {
        if case .file(let url)? = entries(in: folder)[id] { return url }
        return nil
    }

    // MARK: Loaded set

    private struct Loaded { let key: String; let entries: [String: Entry]?; let signature: String; let cache: SoundCache }
    private static var loaded: Loaded?
    private static var failedLogged: Set<String> = []

    private static func signature(of folder: URL) -> String {
        let list = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        return list.map { u -> String in
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return "\(u.lastPathComponent)|\(v?.fileSize ?? 0)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }.sorted().joined(separator: "\n")
    }

    /// Reads the chosen folder once and prepares its players in the background; nil entries mean the folder has gone.
    private static func load(_ name: String, key: String) -> Loaded {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        var isDir: ObjCBool = false
        let cache = SoundCache()
        guard !name.contains("/"), FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            return Loaded(key: key, entries: nil, signature: "", cache: cache)
        }
        let found = entries(in: folder)
        for (id, entry) in found { if case .file(let url) = entry { cache.request(id, url: url, levelled: false) } }
        failedLogged = []
        return Loaded(key: key, entries: found, signature: signature(of: folder), cache: cache)
    }

    /// The chosen set, read when first needed after a change of choice or folder; nil with no custom set chosen or with
    /// the chosen folder gone (TurnOver's own set plays then).
    private static func current() -> (name: String, entries: [String: Entry], cache: SoundCache)? {
        guard let name = setName(fromSaved: config.general.sounds) else { return nil }
        let key = root.path + "\n" + name
                if loaded?.key != key { loaded = load(name, key: key) }
        guard let l = loaded, let e = l.entries else { return nil }
        return (name, e, l.cache)
    }

    /// Called when Settings is opened: a set whose files changed on disk is read again next time it is needed.
    public static func reload() {
        guard let name = setName(fromSaved: config.general.sounds) else { return }
                let folder = root.appendingPathComponent(name, isDirectory: true)
        if let l = loaded, l.signature != signature(of: folder) || (l.entries == nil) != !FileManager.default.fileExists(atPath: folder.path) { loaded = nil }
    }
    /// Called at start: the chosen set is read and its files are prepared in the background, so that its first sound
    /// is ready when it is wanted (review, 20 Nov 2026). Nothing is read where no set of the user's own is chosen.
    public static func preload() { _ = current() }
    /// Forgets the loaded set (a test).
    package static func forget() { loaded = nil; failedLogged = [] }
    /// Whether a set has been read (a test).
    package static var isLoaded: Bool { loaded != nil }

    /// Whether a custom set is chosen and the folder is there.
    public static var active: Bool { current() != nil }

    /// Plays the chosen set's sound for the event if it has one (true: handled, even when the file is empty and so
    /// silent); false where no set is chosen, the folder has gone, or the set has no usable file for it, so TurnOver's own
    /// sound plays. From another thread the play is handed to the main thread.
    @discardableResult
    public static func handle(_ id: String, why: String = #function) -> Bool {
        guard setName(fromSaved: config.general.sounds) != nil, let set = current(), let entry = set.entries[id] else { return false }
        guard case .file = entry else { return true }   // empty file: silence
        return playOnMain(id, set: set.name, cache: set.cache, why: why)
    }

    package static func playOnMain(_ id: String, set: String, cache: SoundCache, why: String) -> Bool {
        if let probe = playProbe { probe(id); return true }
        guard let p = cache.player(id) else {
            if cache.hasFailed(id) {
                let first = failedLogged.insert(id).inserted
                if first { Log.io("sound set \(set): the file for \(id) would not load; TurnOver's own sound plays") }
                return false
            }
            // Not prepared yet (the first sound after a set is chosen or read again): TurnOver's own sound plays this
            // once, where the event used to pass in silence (review, 20 Nov 2026).
            Log.io("sound: set \(set) \(id) not ready; TurnOver's own sound plays (why: \(why))")
            return false
        }
        p.volume = 0.8 * min(1.5, max(0.2, Float(config.speech.volume) / 100))   // with TurnOver's own volume, as its own set
        p.currentTime = 0
        SoundLog.played("set \(set): \(id)", why: why)
        if !AudioOutput.muted { p.play() }
        return true
    }

    // MARK: Starter set

    /// A new folder "My sounds" (then "My sounds 2" and so on) with TurnOver's own sounds as wav files under the event
    /// names, and a read-me. `source` is the folder of TurnOver's own wav files. Returns the new folder.
    @discardableResult
    package static func makeStarterSet(in parent: URL? = nil, from source: URL? = TurnOverSounds.folder) throws -> URL {
        let fm = FileManager.default
        let parent = parent ?? root
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        var folder = parent.appendingPathComponent("My sounds", isDirectory: true), n = 1
        while fm.fileExists(atPath: folder.path) { n += 1; folder = parent.appendingPathComponent("My sounds \(n)", isDirectory: true) }
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        var lines: [String] = []
        for event in SoundEvents.all {
            let target = folder.appendingPathComponent(event.id + ".wav")
            var note = ""
            if let own = event.ownFile, let source, fm.fileExists(atPath: source.appendingPathComponent(own + ".wav").path) {
                try fm.copyItem(at: source.appendingPathComponent(own + ".wav"), to: target)
            } else if let t = event.tone {
                try renderTone(hertz: t.hertz, ms: t.ms, volume: t.volume).write(to: target)
            } else {
                note = "  NO FILE YET: \(event.ownFile == nil ? event.absent : "TurnOver's sound for this was not found.") Add a file named \(event.id).wav (or .aiff, .aif, .caf, .m4a, .mp3) to give it a sound."
            }
            lines.append("\(event.id).wav: \(event.summary)\(note)")
        }
        let readMe = """
        Your TurnOver sound set

        A sound set is a folder with one audio file for each thing TurnOver can sound. The file's name, without its ending, says which event it is for. Any of wav, aiff, aif, caf, m4a and mp3 will do.

        - To change a sound, replace its file with your own, keeping the name.
        - To go back to TurnOver's own sound for an event, delete its file.
        - A file with nothing in it (zero bytes) means silence for that event.
        - A file TurnOver cannot play is treated as missing, so TurnOver's own sound plays instead.
        - To share the set, zip the folder and send it. To use a set someone sends you, unzip it into the Sound Sets folder.
        - To use a set: open Settings, Sounds, and choose it in Whose sounds. After you change files, open Settings again, or choose another set and then this one.

        The events and their files:

        \(lines.joined(separator: "\n"))

        """
        try readMe.write(to: folder.appendingPathComponent("Read me.txt"), atomically: true, encoding: .utf8)
        return folder
    }

    /// A short sine tone as a 16-bit mono wav, with a few milliseconds of fade at each end so it does not click.
    package static func renderTone(hertz: Double, ms: Int, volume: Float) -> Data {
        let rate = 44100, count = max(1, rate * ms / 1000), fade = max(1, min(count / 2, rate * 4 / 1000))
        var wav = Data(capacity: 44 + count * 2)
        func tag(_ s: String) { wav.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { wav.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { wav.append(contentsOf: $0) } }
        tag("RIFF"); u32(36 + count * 2); tag("WAVE")
        tag("fmt "); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        tag("data"); u32(count * 2)
        for i in 0..<count {
            let envelope = min(1, Double(i) / Double(fade), Double(count - 1 - i) / Double(fade))
            let v = sin(2 * Double.pi * hertz * Double(i) / Double(rate)) * Double(volume) * envelope
            withUnsafeBytes(of: Int16(max(-32767, min(32767, v * 32767))).littleEndian) { wav.append(contentsOf: $0) }
        }
        return wav
    }

    /// Makes the folder if needed and returns it, for showing in Finder.
    @discardableResult
    public static func ensureRoot() -> URL {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
