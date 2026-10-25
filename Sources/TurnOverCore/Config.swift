// SPDX-License-Identifier: GPL-3.0-or-later
// Configuration (NVDA: config.conf). One JSON file; the names follow NVDA's
// sections where there is a counterpart so the User Guide reads across.
// ~/Library/Application Support/TurnOver/settings.json
import Foundation
import AVFoundation

public enum SymbolLevel: Int, Codable, CaseIterable {
    case none = 0, some, most, all
    public var name: String { ["none", "some", "most", "all"][rawValue] }
}

public enum ElementReport: String, Codable, CaseIterable {
    case speech, tone, off
    public var name: String { rawValue }
}

public enum TypingEcho: Int, Codable, CaseIterable {
    case off = 0, editControls, always
    public var name: String { ["off", "in edit controls", "always"][rawValue] }
}

public struct Config: Codable {
    public struct General: Codable {
        /// Registered with the system as a login item (NVDA: "Start NVDA after I sign in").
        public var openAtLogin = false
        public var showInMenuBar = true
        /// Windows habits on Mac keys: Command alone opens the menus (Alt), left Option alone the Dock (the Windows
        /// key), right Option alone the context menu (the Applications key), Command+F4 quits, Control+F4 closes,
        /// Option+B the status menus, Finder's Return opens and F2 renames. Off: plain Mac keys.
        /// "windows" (NVDA's habits on Mac keys) or "mac" (VoiceOver's commands on the TurnOver key).
        /// Parked 3 Oct 2026 and back 6 Oct 2026: Mac style works like VoiceOver, key for key; Windows style
        /// makes the Mac feel like a Windows machine (WINDOWS-MODE.md). Switched in the TurnOver menu or with TurnOver
        /// Shift K. The whole-Mac layer is still to come (ESCALATIONS E16).
        public var keyboardStyle = "mac"
        /// Left over from the two modes of 15 to 18 Oct 2026 ("standard" or "experimental"): nothing sets it now, but
        /// a settings file that says "experimental" still chooses TurnOver's own sounds by default (effectiveSounds),
        /// so it is read and written as before rather than thrown away.
        public var edition = "standard"
        /// The keyboard style as one of four (docs/KEYBOARD-STYLES-PLAN.md, 19 Oct 2026). Stored as before: "mac" is
        /// VoiceOver keys and "windows" NVDA keys, so settings from earlier builds read the same.
        public var style: KeyboardStyle { KeyboardStyle(rawValue: keyboardStyle) ?? .voiceOver }
        /// NVDA, Narrator and JAWS keys share the Windows family's habits (role before the words, the cursor not
        /// moving the focus, flat review); VoiceOver keys are the Mac family.
        public var windowsKeys: Bool { style.family == .windows }
        /// With NVDA or JAWS keys, the same keys where VoiceOver reads too: a small layer turns them into VoiceOver's,
        /// Caps Lock the NVDA key there as well. On by default, so a key keeps its meaning whichever reader has the app
        /// (the maintainer, 21 Oct 2026); off, VoiceOver's own Caps Lock chords work in VoiceOver's apps. (A new key:
        /// the old windowsKeysEverywhere was never read, but every settings file holds it as false.)
        public var keysWhereVoiceOverReads = true
        /// In the Mac style, the VoiceOver keys move as VoiceOver's cursor does: within a group (a toolbar, a list, a
        /// named pane), into it with VO Shift Down and out with VO Shift Up, in screen order (a tester, agreed 7 Oct
        /// 2026). Off: they walk the whole window, as NVDA's object navigation does.
        public var navigateByGroups = true
        /// The Windows style's review keys (TurnOver Left and Right) move by groups too, the VoiceOver way (a tester, 9 Oct
        /// 2026); off, NVDA's flat review.
        public var groupsInWindowsStyle = false
        /// Whether the review keys move by groups in the style in use.
        public var movesByGroups: Bool { navigateByGroups && (!windowsKeys || groupsInWindowsStyle) }
        /// The keyboard focus follows the cursor as it lands on something that can take it: "auto" (VoiceOver's way
        /// in the Mac style; NVDA's review cursor never moves the focus, so off in the Windows style), "on", "off".
        /// (A Windows-style review step onto TextEdit's Bold button took the arrows away from the text, 8 Oct 2026.)
        public var focusFollowsCursor = "auto"
        public var cursorMovesFocus: Bool { focusFollowsCursor == "on" || (focusFollowsCursor == "auto" && macKeys) }
        public var macKeys: Bool { style.family == .mac }
        /// What acts as the TurnOver key: "caps" (Caps Lock), "controlOption" (VoiceOver's VO keys), or "both".
        /// Caps Lock or Control Option by default: VoiceOver users reach for Control Option first (5 Oct 2026).
        public var turnOverKey = "both"
        /// Taking over from VoiceOver and handing back: said in words, or a rising and a falling chime.
        public var handOverChimes = false
        /// Nothing at all as TurnOver takes over or hands back (15 Oct 2026: words, a sound, or nothing).
        public var handOverNothing = false
        /// VoiceOver's sounds: a tick as the focus moves, a click as an item is pressed.
        public var navigationSounds = true
        /// Screen Curtain while TurnOver leads: "follow" VoiceOver's, "on" or "off".
        public var screenCurtain = "follow"
        /// "voiceover" (VoiceOver's sound files for links, misspellings, edges, the rotor, the trackpad) or
        /// "turnover" (TurnOver's own tones and bells); "" means by the old mode: VoiceOver's unless the settings file
        /// says "experimental" (17 Oct 2026: "people seemed to like those").
        public var sounds = ""
        public var effectiveSounds: String { sounds.isEmpty ? (edition != "experimental" ? "voiceover" : "turnover") : sounds }
        public init() {}
        enum Keys: String, CodingKey { case openAtLogin, showInMenuBar, windowsKeys, keyboardStyle, keysWhereVoiceOverReads, navigateByGroups, groupsInWindowsStyle, focusFollowsCursor, turnOverKey = "bosunKey", handOverChimes, navigationSounds, screenCurtain, edition, handOverNothing, sounds }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            openAtLogin = (try? c.decodeIfPresent(Bool.self, forKey: .openAtLogin)) ?? false
            showInMenuBar = (try? c.decodeIfPresent(Bool.self, forKey: .showInMenuBar)) ?? true
            let oldWindows = (try? c.decodeIfPresent(Bool.self, forKey: .windowsKeys)) ?? true
            _ = oldWindows
            keyboardStyle = (try? c.decodeIfPresent(String.self, forKey: .keyboardStyle)).flatMap { KeyboardStyle(rawValue: $0)?.rawValue } ?? "mac"
            edition = (try? c.decodeIfPresent(String.self, forKey: .edition)) == "experimental" ? "experimental" : "standard"
            handOverNothing = (try? c.decodeIfPresent(Bool.self, forKey: .handOverNothing)) ?? false
            keysWhereVoiceOverReads = (try? c.decodeIfPresent(Bool.self, forKey: .keysWhereVoiceOverReads)) ?? true
            navigateByGroups = (try? c.decodeIfPresent(Bool.self, forKey: .navigateByGroups)) ?? true
            groupsInWindowsStyle = (try? c.decodeIfPresent(Bool.self, forKey: .groupsInWindowsStyle)) ?? false
            focusFollowsCursor = (try? c.decodeIfPresent(String.self, forKey: .focusFollowsCursor)).flatMap { ["auto", "on", "off"].contains($0) ? $0 : nil } ?? "auto"
            turnOverKey = (try? c.decodeIfPresent(String.self, forKey: .turnOverKey)) ?? "both"
            handOverChimes = (try? c.decodeIfPresent(Bool.self, forKey: .handOverChimes)) ?? false
            navigationSounds = (try? c.decodeIfPresent(Bool.self, forKey: .navigationSounds)) ?? true
            screenCurtain = (try? c.decodeIfPresent(String.self, forKey: .screenCurtain)) ?? "follow"
            sounds = (try? c.decodeIfPresent(String.self, forKey: .sounds)).flatMap { ["voiceover", "turnover"].contains($0) ? $0 : nil } ?? ""
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(openAtLogin, forKey: .openAtLogin)
            try c.encode(showInMenuBar, forKey: .showInMenuBar)
            try c.encode(keyboardStyle, forKey: .keyboardStyle); try c.encode(edition, forKey: .edition); try c.encode(handOverNothing, forKey: .handOverNothing)
            try c.encode(keysWhereVoiceOverReads, forKey: .keysWhereVoiceOverReads)
            try c.encode(groupsInWindowsStyle, forKey: .groupsInWindowsStyle)
            try c.encode(navigateByGroups, forKey: .navigateByGroups); try c.encode(focusFollowsCursor, forKey: .focusFollowsCursor)
            try c.encode(turnOverKey, forKey: .turnOverKey)
            try c.encode(handOverChimes, forKey: .handOverChimes)
            try c.encode(navigationSounds, forKey: .navigationSounds)
            try c.encode(screenCurtain, forKey: .screenCurtain); try c.encode(sounds, forKey: .sounds)
        }
        /// How the TurnOver key is spoken in help and the shortcuts list.
        public var turnOverKeyName: String { turnOverKey == "controlOption" ? "V O" : "caps" }
        public var capsIsTurnOver: Bool { turnOverKey != "controlOption" }
        public var controlOptionIsTurnOver: Bool { turnOverKey != "caps" }
    }
    public struct Speech: Codable {
        /// Reed for an English Mac; elsewhere the system language's own voice (code review, 16 Oct 2026, item 33).
        public var voice = Speech.defaultVoice
        nonisolated static let defaultVoice: String = {
            if AVSpeechSynthesisVoice.currentLanguageCode().hasPrefix("en") { return "com.apple.eloquence.en-GB.Reed" }
            return AVSpeechSynthesisVoice(language: nil)?.identifier ?? "com.apple.eloquence.en-GB.Reed"
        }()
        public var rate: Float = 0.55
        public var symbolLevel: SymbolLevel = .some
        public var sayCapForCapitals = true
        /// Speech volume in percent, 10 to 200. 100 is the voice as rendered, the level VoiceOver plays it at (the
        /// 3 dB make-up of 5 Oct 2026 rested on a mixer loss that isn't there; measured and removed 15 Oct).
        public var volume = 100
        /// NVDA's automatic language switching: text marked as another language is read with a voice for it.
        public var autoLanguageSwitching = true
        /// The voice chosen for each other language, by language code ("ar": a voice identifier).
        public var languageVoices: [String: String] = [:]
        /// A speech rate for each other language (0.1 to 1, as `rate`), when it should differ (a tester).
        public var languageRates: [String: Float] = [:]
        /// Where speech plays (VoiceOver Utility's Sound, NVDA's output device): a CoreAudio device UID, or empty
        /// for the Mac's default output, followed as it changes. A chosen device that is absent (headphones off)
        /// falls back to the default until it returns.
        public var outputDevice = ""
        /// NVDA's "capital pitch change": a capital letter said on its own (spelling, moving by character, typing) is
        /// raised by this percentage; 0 is off (a tester, 10 Oct 2026). Works with or without "cap".
        public var capitalPitch = 0
        /// The voice's pitch on VoiceOver's scale, 0 to 1 with 0.5 the voice's own (copied from VoiceOver, 15 Oct 2026).
        public var pitch: Float = 0.5
        /// The pitch as the player's multiplier: 0 is half, 0.5 is 1, 1 is double.
        public var pitchMultiplier: Float { 0.5 * pow(4, min(1, max(0, pitch))) }
        /// NVDA's audio ducking: "off", "speech" (while TurnOver speaks) or "always" (Ducking.swift). Off, as in NVDA.
        public var ducking = "off"
        /// The voices the speech rotor (VO-Command-Shift, voice) steps through, by identifier; empty, every voice of the
        /// Mac's languages (18 Oct 2026: "just Alex and Eddy… rather than wading through all the novelty ones").
        public var rotorVoices: [String] = []
        public init() {}
        // Each field falls back to its default, so a setting added later never resets the voice and rate.
        enum Keys: String, CodingKey { case voice, rate, symbolLevel, sayCapForCapitals, volume, autoLanguageSwitching, languageVoices, languageRates, outputDevice, capitalPitch, ducking, pitch, rotorVoices }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            voice = (try? c.decodeIfPresent(String.self, forKey: .voice)) ?? voice
            rate = (try? c.decodeIfPresent(Float.self, forKey: .rate)) ?? rate
            symbolLevel = (try? c.decodeIfPresent(SymbolLevel.self, forKey: .symbolLevel)) ?? symbolLevel
            sayCapForCapitals = (try? c.decodeIfPresent(Bool.self, forKey: .sayCapForCapitals)) ?? sayCapForCapitals
            volume = (try? c.decodeIfPresent(Int.self, forKey: .volume)) ?? volume
            autoLanguageSwitching = (try? c.decodeIfPresent(Bool.self, forKey: .autoLanguageSwitching)) ?? autoLanguageSwitching
            languageVoices = (try? c.decodeIfPresent([String: String].self, forKey: .languageVoices)) ?? languageVoices
            languageRates = (try? c.decodeIfPresent([String: Float].self, forKey: .languageRates)) ?? languageRates
            outputDevice = (try? c.decodeIfPresent(String.self, forKey: .outputDevice)) ?? outputDevice
            capitalPitch = (try? c.decodeIfPresent(Int.self, forKey: .capitalPitch)) ?? capitalPitch
            pitch = (try? c.decodeIfPresent(Float.self, forKey: .pitch)) ?? pitch
            ducking = (try? c.decodeIfPresent(String.self, forKey: .ducking)) ?? ducking
            rotorVoices = (try? c.decodeIfPresent([String].self, forKey: .rotorVoices)) ?? rotorVoices
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(voice, forKey: .voice); try c.encode(rate, forKey: .rate); try c.encode(symbolLevel, forKey: .symbolLevel)
            try c.encode(sayCapForCapitals, forKey: .sayCapForCapitals); try c.encode(volume, forKey: .volume)
            try c.encode(autoLanguageSwitching, forKey: .autoLanguageSwitching); try c.encode(languageVoices, forKey: .languageVoices)
            try c.encode(languageRates, forKey: .languageRates); try c.encode(outputDevice, forKey: .outputDevice)
            try c.encode(capitalPitch, forKey: .capitalPitch); try c.encode(ducking, forKey: .ducking); try c.encode(pitch, forKey: .pitch)
            try c.encode(rotorVoices, forKey: .rotorVoices)
        }
    }
    public struct Keyboard: Codable {
        public var speakTypedCharacters: TypingEcho = .editControls
        public var speakTypedWords: TypingEcho = .off
        public var speakCommandKeys = false
        /// NVDA's multiPressTimeout: the same script again within this window is a repeat.
        public var multiPressTimeoutMs = 500
        /// NVDA's keyboard layout: "desktop" or "laptop". Macs are laptops.
        public var layout = "laptop"
        /// "New line" said on Return in a text field (asked for, 4 Oct 2026; a tester wanted it off).
        public var speakNewLine = true
        /// VoiceOver's Option key Commander: right Option with a letter runs a command (right Option T, the time).
        /// VO-Shift-K turns it off and on (12 Oct 2026).
        public var optionCommander = true
        /// The keypad (Keypad.swift): VoiceOver's NumPad Commander in the Mac style (off, as VoiceOver, until VO-Clear);
        /// NVDA's keypad commands in the Windows style (on, as NVDA with Num Lock off; Clear types numbers instead).
        public var numpadCommander = false
        public var keypadCommands = true
        public init() {}
        /// The user's own keys (UserGestures): key identifier → "script:<name>", "app:<bundle id>" or "none".
        public var userGestures: [String: String] = [:]
        enum Keys: String, CodingKey { case speakTypedCharacters, speakTypedWords, speakCommandKeys, multiPressTimeoutMs, layout, speakNewLine, userGestures, optionCommander, numpadCommander, keypadCommands }
        // Each setting falls back on its own, so adding one never resets the others.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            speakTypedCharacters = (try? c.decodeIfPresent(TypingEcho.self, forKey: .speakTypedCharacters)) ?? .editControls
            speakTypedWords = (try? c.decodeIfPresent(TypingEcho.self, forKey: .speakTypedWords)) ?? .off
            speakCommandKeys = (try? c.decodeIfPresent(Bool.self, forKey: .speakCommandKeys)) ?? false
            multiPressTimeoutMs = (try? c.decodeIfPresent(Int.self, forKey: .multiPressTimeoutMs)) ?? 500
            layout = (try? c.decodeIfPresent(String.self, forKey: .layout)) ?? "laptop"
            speakNewLine = (try? c.decodeIfPresent(Bool.self, forKey: .speakNewLine)) ?? true
            optionCommander = (try? c.decodeIfPresent(Bool.self, forKey: .optionCommander)) ?? true
            numpadCommander = (try? c.decodeIfPresent(Bool.self, forKey: .numpadCommander)) ?? false
            keypadCommands = (try? c.decodeIfPresent(Bool.self, forKey: .keypadCommands)) ?? true
            userGestures = (try? c.decodeIfPresent([String: String].self, forKey: .userGestures)) ?? [:]
            // Saved before the code name went (12 Oct 2026): "kb:bosun+n" is "kb:turnover+n"; "script:bosunMenu" is
            // "script:turnOverMenu".
            userGestures = Dictionary(userGestures.map { k, v in
                (k.replacingOccurrences(of: ":bosun+", with: ":turnover+"), v.replacingOccurrences(of: "bosunMenu", with: "turnOverMenu"))
            }, uniquingKeysWith: { a, _ in a })
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(speakTypedCharacters, forKey: .speakTypedCharacters); try c.encode(speakTypedWords, forKey: .speakTypedWords)
            try c.encode(speakCommandKeys, forKey: .speakCommandKeys); try c.encode(multiPressTimeoutMs, forKey: .multiPressTimeoutMs)
            try c.encode(layout, forKey: .layout); try c.encode(speakNewLine, forKey: .speakNewLine)
            try c.encode(userGestures, forKey: .userGestures); try c.encode(optionCommander, forKey: .optionCommander)
            try c.encode(numpadCommander, forKey: .numpadCommander); try c.encode(keypadCommands, forKey: .keypadCommands)
        }
    }
    public struct EditableText: Codable {
        /// NVDA's caretMoveTimeoutMs: how long a caret script waits for the caret to move.
        public var caretMoveTimeoutMs = 100
        public init() {}
        enum Keys: String, CodingKey { case caretMoveTimeoutMs }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            caretMoveTimeoutMs = (try? c.decodeIfPresent(Int.self, forKey: .caretMoveTimeoutMs)) ?? 100
        }
    }
    public struct VirtualBuffers: Codable {
        /// NVDA's maxLineLength: a browse mode line is at most this many characters.
        public var maxLineLength = 100
        /// NVDA's "Automatic say all on page load" (on by default in NVDA): a new page is read from where it starts.
        public var autoSayAllOnPageLoad = true
        /// Quick navigation (H, K, F…) carries on from the other end of the page, and says so (7 Oct 2026).
        public var wrapQuickNav = true
        /// NVDA's "Use screen layout": links and controls flow with the text as on screen; off, each is on a line of
        /// its own (a tester, 6 Oct 2026).
        public var screenLayout = true
        /// NVDA's "Automatic focus mode for focus changes": a field taking the focus switches to focus mode by itself;
        /// off, only TurnOver Space does (a tester, 6 Oct 2026).
        public var autoFocusMode = true
        /// A picture with no description is read by its file name ("graphic, sunset beach"), as JAWS can; off, just
        /// "graphic" (a tester, AppleVis, 9 Oct 2026).
        public var imageFileNames = false
        public init() {}
        enum Keys: String, CodingKey { case maxLineLength, autoSayAllOnPageLoad, wrapQuickNav, screenLayout, autoFocusMode, imageFileNames }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            maxLineLength = (try? c.decodeIfPresent(Int.self, forKey: .maxLineLength)) ?? 100
            autoSayAllOnPageLoad = (try? c.decodeIfPresent(Bool.self, forKey: .autoSayAllOnPageLoad)) ?? true
            wrapQuickNav = (try? c.decodeIfPresent(Bool.self, forKey: .wrapQuickNav)) ?? true
            screenLayout = (try? c.decodeIfPresent(Bool.self, forKey: .screenLayout)) ?? true
            autoFocusMode = (try? c.decodeIfPresent(Bool.self, forKey: .autoFocusMode)) ?? true
            imageFileNames = (try? c.decodeIfPresent(Bool.self, forKey: .imageFileNames)) ?? false
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(maxLineLength, forKey: .maxLineLength)
            try c.encode(autoSayAllOnPageLoad, forKey: .autoSayAllOnPageLoad)
            try c.encode(wrapQuickNav, forKey: .wrapQuickNav)
            try c.encode(screenLayout, forKey: .screenLayout)
            try c.encode(autoFocusMode, forKey: .autoFocusMode)
            try c.encode(imageFileNames, forKey: .imageFileNames)
        }
    }
    /// Screen recognition (NVDA: the Windows OCR settings).
    public struct Recognition: Codable {
        /// NVDA's "Periodically refresh recognized content": read again every 1.5 s while the result is open, saying
        /// new rows as they appear. Off by default, as in NVDA.
        public var autoRefresh = false
        /// NVDA's "Automatically say all on result".
        public var autoSayAll = false
        public init() {}
        enum Keys: String, CodingKey { case autoRefresh, autoSayAll }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            autoRefresh = (try? c.decodeIfPresent(Bool.self, forKey: .autoRefresh)) ?? false
            autoSayAll = (try? c.decodeIfPresent(Bool.self, forKey: .autoSayAll)) ?? false
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(autoRefresh, forKey: .autoRefresh); try c.encode(autoSayAll, forKey: .autoSayAll)
        }
    }
    /// The rising tide: which applications TurnOver leads in; VoiceOver has the rest (NVDA: sleep mode, inverted).
    public struct Applications: Codable {
        // Word is a preview in the 1.0 beta, off until the user turns it on (TurnOver menu, Applications).
        public var leadBundles: [String] = ["com.apple.Safari", "com.apple.mail", "com.apple.Terminal"]
        /// TurnOver leads everywhere except the listed ones, instead of only in them.
        public var leadEverywhereElse = false
        /// Switch VoiceOver off and on by itself as the front application changes.
        public var automaticHandOver = true
        /// Who reads (wishlist 2, 13 Oct 2026; a tester, a tester a tester's report): "apps" (TurnOver in its apps,
        /// leadBundles), "everywhere" (TurnOver in every app but voiceOverBundles), "voiceover" (VoiceOver everywhere,
        /// TurnOver still running). Command Control Comma, A cycles them. Each mode keeps its own list.
        /// TurnOver everywhere by default (19 Oct 2026): VoiceOver keeps security, and any app can go back to
        /// it with Command Control Shift T. A settings file that already has a mode keeps it.
        public var leadMode = "everywhere"
        /// The apps VoiceOver keeps when TurnOver reads everywhere.
        public var voiceOverBundles: [String] = []
        /// Direct apps (18 Oct 2026: "like a direct touch sort of thing"): every key goes straight to the app,
        /// VoiceOver never sees it, and TurnOver says nothing; for a game that speaks for itself. By bundle identifier,
        /// or "process:<name>" for a program without one (a Godot game run from Terminal). Command Control Comma, D.
        public var directApps: [String] = []
        /// Readers per app (experimental since 22 Oct 2026): the modes, the app lists and switching as apps change.
        /// Off, TurnOver is simply on or off and reads everywhere while on; VoiceOver is on or off by its own key.
        /// A settings file that already holds a list or a mode other than everywhere reads as on, so nobody's set-up
        /// changes with the build.
        public var perAppReaders = false
        /// TurnOver and VoiceOver swap: one comes on as the other goes off. TurnOver turns VoiceOver off as it starts and
        /// on as it quits, comes on when VoiceOver turns off and steps aside when VoiceOver comes on. Off, each reader
        /// has its own switch and neither turns the other on or off: a Mac with no reader on purpose, such as VoiceOver
        /// reading inside a virtual machine (23 Oct 2026). Either way one reader speaks at a time: while VoiceOver is
        /// on and running TurnOver is quiet (25 Oct 2026, when both talked). One switch since 25 Oct 2026: the quit had
        /// its own, which said the same thing by halves.
        public var swapWithVoiceOver = true
        public init() {}
        public static let leadModes = ["apps", "everywhere", "voiceover"]
        /// The mode in force: the chosen one with readers per app, everywhere without.
        public var effectiveLeadMode: String { perAppReaders ? leadMode : "everywhere" }
        /// The apps VoiceOver keeps, in force: none without readers per app.
        public var effectiveVoiceOverBundles: [String] { perAppReaders ? voiceOverBundles : [] }
        /// Whether readers switch as the front app changes: only with readers per app, and the switch on.
        public var switchesAsAppsChange: Bool { perAppReaders && automaticHandOver }
        /// Whether TurnOver takes over at launch: always without readers per app; with them, when switching is on.
        public var handsOverAtLaunch: Bool { !perAppReaders || automaticHandOver }
        /// Whether the saved lists give `bundle` to TurnOver in the current mode (not pins or games: LeadWatcher).
        public func listedForTurnOver(_ bundle: String) -> Bool {
            switch effectiveLeadMode {
            case "voiceover": return false
            case "everywhere": return !effectiveVoiceOverBundles.contains(bundle)
            default: return leadBundles.contains(bundle)
            }
        }
        /// Saves `bundle` as TurnOver's or VoiceOver's in the current mode's own list (none in VoiceOver everywhere).
        public mutating func give(_ bundle: String, toTurnOver: Bool) {
            switch leadMode {
            case "voiceover": return
            case "everywhere":
                voiceOverBundles.removeAll { $0 == bundle }
                if !toTurnOver { voiceOverBundles.append(bundle) }
            default:
                leadBundles.removeAll { $0 == bundle }
                if toTurnOver { leadBundles.append(bundle) }
            }
        }
        public static func leadModeName(_ m: String) -> String {
            m == "everywhere" ? "TurnOver everywhere" : m == "voiceover" ? "VoiceOver everywhere" : "TurnOver in its apps"
        }
        enum Keys: String, CodingKey { case leadBundles, leadEverywhereElse, automaticHandOver, leadMode, voiceOverBundles, directApps, perAppReaders, swapWithVoiceOver }
        // Each field falls back on its own: a new field must never wipe the list of apps TurnOver leads in (8 Oct 2026).
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            let d = Applications()
            leadBundles = (try? c.decodeIfPresent([String].self, forKey: .leadBundles)) ?? d.leadBundles
            leadEverywhereElse = (try? c.decodeIfPresent(Bool.self, forKey: .leadEverywhereElse)) ?? d.leadEverywhereElse
            automaticHandOver = (try? c.decodeIfPresent(Bool.self, forKey: .automaticHandOver)) ?? d.automaticHandOver
            voiceOverBundles = (try? c.decodeIfPresent([String].self, forKey: .voiceOverBundles)) ?? []
            directApps = (try? c.decodeIfPresent([String].self, forKey: .directApps)) ?? []
            if let m = try? c.decodeIfPresent(String.self, forKey: .leadMode) {
                leadMode = Applications.leadModes.contains(m) ? m : "apps"
            } else {
                // Settings from before the modes (code review, 13 Oct) had an "everywhere else" switch; it was never
                // honoured, so such a file starts in apps mode.
                leadMode = "apps"
            }
            swapWithVoiceOver = (try? c.decodeIfPresent(Bool.self, forKey: .swapWithVoiceOver)) ?? d.swapWithVoiceOver
            if let chosen = try? c.decodeIfPresent(Bool.self, forKey: .perAppReaders) {
                perAppReaders = chosen
            } else {
                // A set-up from before the switch that uses the lists keeps working as it did.
                let usesLists = leadMode != "everywhere" || !voiceOverBundles.isEmpty
                perAppReaders = usesLists
            }
        }
    }
    public struct Presentation: Codable {
        public var reportObjectDescriptions = true
        public var reportKeyboardShortcuts = true
        public var reportObjectPositionInformation = true
        public var reportDynamicContentChanges = true
        /// VoiceOver's hints: after a pause on an item, what can be done with it ("Return opens its page"). On, as in
        /// VoiceOver, while people are learning TurnOver (7 Oct 2026).
        public var speakHints = true
        /// Notifications from other apps (a new message, a calendar alert) read as they appear, as VoiceOver and NVDA
        /// do (a tester, 6 Oct 2026).
        public var reportNotifications = true
        /// "Bambu Studio, with the Bambu Studio plugin" as an app with a plugin comes to the front (the plugin design notes 13).
        public var announcePlugins = true
        public init() {}
        enum Keys: String, CodingKey { case reportObjectDescriptions, reportKeyboardShortcuts, reportObjectPositionInformation, reportDynamicContentChanges, speakHints, reportNotifications, announcePlugins }
        // Each setting falls back on its own: a settings file from before speakHints keeps the others.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            reportObjectDescriptions = (try? c.decodeIfPresent(Bool.self, forKey: .reportObjectDescriptions)) ?? true
            reportKeyboardShortcuts = (try? c.decodeIfPresent(Bool.self, forKey: .reportKeyboardShortcuts)) ?? true
            reportObjectPositionInformation = (try? c.decodeIfPresent(Bool.self, forKey: .reportObjectPositionInformation)) ?? true
            reportDynamicContentChanges = (try? c.decodeIfPresent(Bool.self, forKey: .reportDynamicContentChanges)) ?? true
            speakHints = (try? c.decodeIfPresent(Bool.self, forKey: .speakHints)) ?? true
            reportNotifications = (try? c.decodeIfPresent(Bool.self, forKey: .reportNotifications)) ?? true
            announcePlugins = (try? c.decodeIfPresent(Bool.self, forKey: .announcePlugins)) ?? true
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(reportObjectDescriptions, forKey: .reportObjectDescriptions); try c.encode(reportKeyboardShortcuts, forKey: .reportKeyboardShortcuts)
            try c.encode(reportObjectPositionInformation, forKey: .reportObjectPositionInformation); try c.encode(reportDynamicContentChanges, forKey: .reportDynamicContentChanges)
            try c.encode(speakHints, forKey: .speakHints); try c.encode(reportNotifications, forKey: .reportNotifications)
            try c.encode(announcePlugins, forKey: .announcePlugins)
        }
    }
    public struct DocumentFormatting: Codable {
        public var reportFontName = false
        public var reportFontSize = false
        public var reportFontAttributes = false
        public var reportColor = false
        /// NVDA's element reporting, with VoiceOver's option of a sound instead of a word.
        public var headings: ElementReport = .speech
        public var reportHeadingLevel = true
        public var links: ElementReport = .speech
        public var lists: ElementReport = .speech
        public var landmarks: ElementReport = .speech
        public var tables: ElementReport = .speech
        public var graphics: ElementReport = .speech
        public var blockQuotes: ElementReport = .speech
        public var spellingErrors: ElementReport = .speech
        /// NVDA's table cell coordinates: "row 3, column 2" as you move between cells (a tester, 7 Oct 2026).
        public var tableCellCoordinates = true
        /// The row's and column's headers said as the caret moves into another row or column of a table (Word);
        /// off for just the cell (a tester, 8 Oct 2026).
        public var tableHeaders = true
        /// Where "heading level 1", "link", "button" go when reading: "before" the words (NVDA), "after" them
        /// (VoiceOver: "AppleVis, heading level 1"), or "auto", by the keyboard style (a tester T, 7 Oct 2026).
        public var roleOrder = "auto"
        /// The role and states come after the words.
        public var rolesAfterText: Bool { roleOrder == "after" || (roleOrder == "auto" && !config.general.windowsKeys) }
        public init() {}
        // Each setting falls back on its own, so a settings file from before one was added keeps the rest.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = DocumentFormatting.defaults
            func b(_ k: CodingKeys, _ v: Bool) -> Bool { (try? c.decodeIfPresent(Bool.self, forKey: k)) ?? v }
            func e(_ k: CodingKeys, _ v: ElementReport) -> ElementReport { (try? c.decodeIfPresent(ElementReport.self, forKey: k)) ?? v }
            reportFontName = b(.reportFontName, d.reportFontName); reportFontSize = b(.reportFontSize, d.reportFontSize)
            reportFontAttributes = b(.reportFontAttributes, d.reportFontAttributes); reportColor = b(.reportColor, d.reportColor)
            headings = e(.headings, d.headings); reportHeadingLevel = b(.reportHeadingLevel, d.reportHeadingLevel)
            links = e(.links, d.links); lists = e(.lists, d.lists); landmarks = e(.landmarks, d.landmarks); tables = e(.tables, d.tables)
            graphics = e(.graphics, d.graphics); blockQuotes = e(.blockQuotes, d.blockQuotes); spellingErrors = e(.spellingErrors, d.spellingErrors)
            tableCellCoordinates = b(.tableCellCoordinates, d.tableCellCoordinates)
            tableHeaders = b(.tableHeaders, d.tableHeaders)
            roleOrder = (try? c.decodeIfPresent(String.self, forKey: .roleOrder)) ?? d.roleOrder
        }
        static let defaults = DocumentFormatting()
    }
    /// Braille (NVDA's braille settings).
    public struct Braille: Codable {
        /// The output table's identifier; empty is the system's contracted table for the user's language.
        public var table = ""
        /// The word at the cursor in uncontracted braille (NVDA: expand to computer braille at the cursor).
        public var expandAtCursor = true
        /// Typing in contracted braille: each word is translated when it ends (space, Return). Off: letter by letter.
        public var contractedInput = true
        /// What is spoken while typing on the braille keyboard: "words", "characters", "both" or "off".
        public var inputEcho = "words"
        /// Messages and live text on the display (NVDA: show messages): "timeout", "indefinitely" (until a key) or "off".
        public var showMessages = "timeout"
        /// Seconds for each display's width of a message (NVDA: message timeout, 4).
        public var messageSeconds = 4
        /// NVDA's cursor settings: shown, blinking, how fast (ms), and its shape ("78" dots 7 and 8, "8", "all").
        public var showCursor = true
        public var blinkCursor = true
        public var blinkRateMs = 500
        public var cursorShape = "78"
        /// NVDA: avoid splitting words when possible (a window ends at a space, not in a word).
        public var wordWrap = true
        /// NVDA: show selection (dots 7 and 8 under selected text).
        public var showSelection = true
        /// NVDA: interrupt speech while scrolling.
        public var interruptSpeechWhileScrolling = true
        /// Look for a display paired over Bluetooth (macOS asks for Bluetooth permission the first time).
        public var bluetooth = false
        /// NVDA's tether (NVDA+Control+T): "auto" (the focus and caret, or TurnOver's own cursor), "focus", "review".
        public var tether = "auto"
        /// NVDA's braille mode (NVDA+Alt+T): "followCursors", or "speechOutput" (the display shows what is spoken).
        public var mode = "followCursors"
        /// NVDA's auto scroll (NVDA+Alt+K, L, J): seconds a window stays before the next.
        public var autoScrollSeconds = 3.0
        public init() {}
        enum Keys: String, CodingKey { case table, expandAtCursor, contractedInput, inputEcho, showMessages, messageSeconds, showCursor, blinkCursor, blinkRateMs, cursorShape, wordWrap, showSelection, interruptSpeechWhileScrolling, bluetooth, tether, mode, autoScrollSeconds }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            table = (try? c.decodeIfPresent(String.self, forKey: .table)) ?? ""
            expandAtCursor = (try? c.decodeIfPresent(Bool.self, forKey: .expandAtCursor)) ?? true
            contractedInput = (try? c.decodeIfPresent(Bool.self, forKey: .contractedInput)) ?? true
            inputEcho = (try? c.decodeIfPresent(String.self, forKey: .inputEcho)) ?? "words"
            showMessages = (try? c.decodeIfPresent(String.self, forKey: .showMessages)) ?? "timeout"
            messageSeconds = (try? c.decodeIfPresent(Int.self, forKey: .messageSeconds)) ?? 4
            showCursor = (try? c.decodeIfPresent(Bool.self, forKey: .showCursor)) ?? true
            blinkCursor = (try? c.decodeIfPresent(Bool.self, forKey: .blinkCursor)) ?? true
            blinkRateMs = (try? c.decodeIfPresent(Int.self, forKey: .blinkRateMs)) ?? 500
            cursorShape = (try? c.decodeIfPresent(String.self, forKey: .cursorShape)) ?? "78"
            wordWrap = (try? c.decodeIfPresent(Bool.self, forKey: .wordWrap)) ?? true
            showSelection = (try? c.decodeIfPresent(Bool.self, forKey: .showSelection)) ?? true
            interruptSpeechWhileScrolling = (try? c.decodeIfPresent(Bool.self, forKey: .interruptSpeechWhileScrolling)) ?? true
            bluetooth = (try? c.decodeIfPresent(Bool.self, forKey: .bluetooth)) ?? false
            tether = (try? c.decodeIfPresent(String.self, forKey: .tether)) ?? "auto"
            mode = (try? c.decodeIfPresent(String.self, forKey: .mode)) ?? "followCursors"
            autoScrollSeconds = (try? c.decodeIfPresent(Double.self, forKey: .autoScrollSeconds)) ?? 3.0
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(table, forKey: .table); try c.encode(expandAtCursor, forKey: .expandAtCursor)
            try c.encode(contractedInput, forKey: .contractedInput); try c.encode(inputEcho, forKey: .inputEcho)
            try c.encode(showMessages, forKey: .showMessages); try c.encode(messageSeconds, forKey: .messageSeconds)
            try c.encode(showCursor, forKey: .showCursor); try c.encode(blinkCursor, forKey: .blinkCursor); try c.encode(blinkRateMs, forKey: .blinkRateMs)
            try c.encode(cursorShape, forKey: .cursorShape); try c.encode(wordWrap, forKey: .wordWrap); try c.encode(showSelection, forKey: .showSelection)
            try c.encode(interruptSpeechWhileScrolling, forKey: .interruptSpeechWhileScrolling); try c.encode(bluetooth, forKey: .bluetooth)
            try c.encode(tether, forKey: .tether); try c.encode(mode, forKey: .mode); try c.encode(autoScrollSeconds, forKey: .autoScrollSeconds)
        }
    }
    public var general = General()
    public var speech = Speech()
    public var keyboard = Keyboard()
    public var editableText = EditableText()
    public var presentation = Presentation()
    public var virtualBuffers = VirtualBuffers()
    public var applications = Applications()
    public var documentFormatting = DocumentFormatting()
    public var braille = Braille()
    public var recognition = Recognition()
    /// Steam and CrossOver games speaking through TurnOver (Games.swift; this Mac only).
    public var games = Games()
    /// Per-application settings, by bundle identifier, as the app module defines them.
    public var apps: [String: [String: String]] = [:]

    public func appSetting(_ bundle: String, _ key: String, default d: String) -> String { apps[bundle]?[key] ?? d }
    public mutating func setAppSetting(_ bundle: String, _ key: String, _ value: String) { apps[bundle, default: [:]][key] = value }

    public init() {}

    /// A settings file written by an older TurnOver lacks the sections added since; each one falls back
    /// to its defaults instead of the whole file being thrown away (which lost the owner's rate once). Keys it has
    /// that are gone ("addons", the add-on loader's list) are ignored.
    enum Keys: String, CodingKey { case general, speech, keyboard, editableText, presentation, virtualBuffers, applications, documentFormatting, braille, recognition, games, apps }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        general = (try? c.decodeIfPresent(General.self, forKey: .general)) ?? General()
        speech = (try? c.decodeIfPresent(Speech.self, forKey: .speech)) ?? Speech()
        keyboard = (try? c.decodeIfPresent(Keyboard.self, forKey: .keyboard)) ?? Keyboard()
        editableText = (try? c.decodeIfPresent(EditableText.self, forKey: .editableText)) ?? EditableText()
        presentation = (try? c.decodeIfPresent(Presentation.self, forKey: .presentation)) ?? Presentation()
        virtualBuffers = (try? c.decodeIfPresent(VirtualBuffers.self, forKey: .virtualBuffers)) ?? VirtualBuffers()
        applications = (try? c.decodeIfPresent(Applications.self, forKey: .applications)) ?? Applications()
        documentFormatting = (try? c.decodeIfPresent(DocumentFormatting.self, forKey: .documentFormatting)) ?? DocumentFormatting()
        braille = (try? c.decodeIfPresent(Braille.self, forKey: .braille)) ?? Braille()
        recognition = (try? c.decodeIfPresent(Recognition.self, forKey: .recognition)) ?? Recognition()
        games = (try? c.decodeIfPresent(Games.self, forKey: .games)) ?? Games()
        apps = (try? c.decodeIfPresent([String: [String: String]].self, forKey: .apps)) ?? [:]
    }

    public static var url: URL {
        AppPaths.file("settings.json")
    }

    /// Set once this process has read the user's settings. Only then may it write them: the plugin tool, which
    /// never loads them, saved its built-in defaults over the user's (voice, rate, verbosity, keyboard style, apps) when
    /// listing plugins (13 Oct 2026).
    nonisolated(unsafe) public static var loaded = false
    /// Saving is TurnOver's alone: the app sets this before it starts; tools and tests never write the settings, even
    /// after reading them (the code review, 13 Oct 2026: turnover-coretest and explain load them, then could save).
    nonisolated(unsafe) public static var persists = false

    /// A copy a day in settings-history (the first of each day; the last 7 days kept): a bad write noticed late, after
    /// restarts, can still be undone (the code review, 13 Oct 2026).
    static func keepDailyCopy(_ data: Data) {
        let dir = url.deletingLastPathComponent().appendingPathComponent("settings-history", isDirectory: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let today = dir.appendingPathComponent("settings-\(f.string(from: Date())).json")
        let fm = FileManager.default
        guard !fm.fileExists(atPath: today.path) else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: today, options: .atomic)
        let all = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("settings-") }.sorted()
        for old in all.dropLast(7) { try? fm.removeItem(at: dir.appendingPathComponent(old)) }
    }

    public static func load() -> Config {
        loaded = true
        if let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Config.self, from: data) {
            if persists { keepDailyCopy(data) }
            return s
        }
        // A file that won't decode is kept beside the new one, never just overwritten (8 Oct 2026). Only TurnOver
        // itself does this: a tool built from older code may simply not read newer settings, and must leave them be
        // (code review, 13 Oct). Each copy is dated, so a second failure doesn't replace the first.
        if FileManager.default.fileExists(atPath: url.path) {
            guard persists else { Log.warning("settings: can't be read by this tool; left as they are"); return Config() }
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"
            let broken = url.deletingLastPathComponent().appendingPathComponent("settings-broken-\(f.string(from: Date())).json")
            try? FileManager.default.copyItem(at: url, to: broken)
            Log.warning("settings: couldn't be read; kept as \(broken.lastPathComponent), starting from the defaults")
        }
        let s = Config()
        s.save()
        return s
    }

    public func save() {
        // On the main thread only: the settings profiles' state is the main actor's, and a save from elsewhere read
        // it torn (a code review, 14 Oct 2026).
        guard Thread.isMainThread else { let copy = self; DispatchQueue.main.async { copy.save() }; return }
        guard Config.loaded, Config.persists else { Log.warning("settings: not saved: only TurnOver itself writes them (this is a tool or a test)"); return }
        try? FileManager.default.createDirectory(at: Config.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // With a settings profile on, its sections go into the profile; settings.json keeps the normal ones.
        if let data = try? encoder.encode(SettingsProfiles.forSaving(self)) {
            // What was there before each change is kept as settings-previous.json, so one bad write can be undone.
            if let old = try? Data(contentsOf: Config.url), old != data {
                try? old.write(to: Config.url.deletingLastPathComponent().appendingPathComponent("settings-previous.json"), options: .atomic)
            }
            do { try data.write(to: Config.url, options: .atomic) }
            catch { Log.warning("settings: not saved: \(error.localizedDescription)") }
            Config.keepDailyCopy(data)
        }
        if Thread.isMainThread { KeySettings.refresh() } else { DispatchQueue.main.async { KeySettings.refresh() } }
    }
}

/// The live configuration (NVDA: config.conf). Written on the main thread; read from any (the script lookup
/// queue runs availability checks that read it), so each read and write takes a lock: a Config is a value, and a
/// torn read of one of its strings or arrays is undefined (code review, 8 Oct 2026). The keyboard thread reads
/// KeySettings instead.
private let configLock = NSLock()
private var _config = Config()
public var config: Config {
    get { configLock.lock(); defer { configLock.unlock() }; return _config }
    set { configLock.lock(); _config = newValue; configLock.unlock() }
}

/// The four keyboard styles (docs/KEYBOARD-STYLES-PLAN.md, 19 Oct 2026): VoiceOver's keys, and NVDA's, Narrator's and
/// JAWS's on Mac keys. The raw values are what the settings file keeps ("mac" and "windows" from before).
nonisolated public enum KeyboardStyle: String, CaseIterable, Sendable {
    // Narrator keys are parked: the style exists and its table (Resources/keymaps/narrator.json) is empty, and K does not
    // offer it (GlobalCommands.offeredStyles). docs/DECISIONS.md.
    case voiceOver = "mac", nvda = "windows", narrator, jaws
    public enum Family: Sendable { case mac, windows }
    public var family: Family { self == .voiceOver ? .mac : .windows }
    /// What TurnOver says for it.
    public var spokenName: String {
        switch self {
        case .voiceOver: return "VoiceOver keys"
        case .nvda: return "NVDA keys"
        case .narrator: return "Narrator keys"
        case .jaws: return "JAWS keys"
        }
    }
}
