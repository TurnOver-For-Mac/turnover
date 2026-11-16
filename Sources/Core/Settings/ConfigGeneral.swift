// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension Config {
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
        /// What acts as the TurnOver key: "caps" (Caps Lock), "controlOption" (VoiceOver's VO keys), "both", or "insert" (Insert / number-pad 0).
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
        /// "voiceover" (VoiceOver's sound files where VoiceOver has a sound: links, misspellings, edges, the rotor, the
        /// trackpad; TurnOver's own set for the rest) or "turnover" (TurnOver's own set throughout); "" until one is
        /// chosen (effectiveSounds says what plays then).
        public var sounds = ""
        /// Whose sounds play ("voiceover" or "turnover"): the choice, or until one is made what always played, VoiceOver's
        /// unless the settings file says "experimental" (Tones).
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
        public var turnOverKeyName: String {
            if turnOverKey == "insert" { return String(localized: "insert", comment: "Insert as the TurnOver key, spoken before another key") }
            return turnOverKey == "controlOption" ? String(localized: "V O", comment: "The VO key (Control and Option), as spoken")
                : String(localized: "caps", comment: "Caps Lock as the TurnOver key, as spoken before another key")
        }
        public var capsIsTurnOver: Bool { turnOverKey != "controlOption" && turnOverKey != "insert" }
        public var controlOptionIsTurnOver: Bool { turnOverKey != "caps" && turnOverKey != "insert" }
        public var insertIsTurnOver: Bool { turnOverKey == "insert" }
    }
}
