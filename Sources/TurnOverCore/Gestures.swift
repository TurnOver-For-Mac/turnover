// SPDX-License-Identifier: GPL-3.0-or-later
// Input gestures (NVDA: inputCore.InputGesture, keyboardHandler.KeyboardInputGesture).
//
// A keyboard gesture is one key press with its modifiers, named layout-
// independently from the key code ("kb:turnover+shift+upArrow"), so a binding
// written once holds on any keyboard. "turnover" is the reader's modifier (the
// Caps Lock key); "option" and "command" are the Mac names, with "alt" and
// "windows" accepted as NVDA's spellings when a binding is parsed.
import Foundation
import CoreGraphics

nonisolated public struct Modifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = Modifiers(rawValue: 1)
    public static let control = Modifiers(rawValue: 2)
    public static let option = Modifiers(rawValue: 4)
    public static let command = Modifiers(rawValue: 8)
    public static let turnover = Modifiers(rawValue: 16)

    /// Canonical order in identifiers: turnover, control, option, command, shift.
    var names: [String] {
        var n: [String] = []
        if contains(.turnover) { n.append("turnover") }
        if contains(.control) { n.append("control") }
        if contains(.option) { n.append("option") }
        if contains(.command) { n.append("command") }
        if contains(.shift) { n.append("shift") }
        return n
    }
    public static func named(_ s: String) -> Modifiers? {
        switch s.lowercased() {
        case "turnover", "bosun", "nvda", "caps", "capslock": return .turnover   // "bosun": the code name, in older plugins and settings
        case "shift": return .shift
        case "control", "ctrl": return .control
        case "option", "alt": return .option
        case "command", "cmd", "windows": return .command
        default: return nil
        }
    }
}

nonisolated public struct KeyboardGesture: CustomStringConvertible, Sendable {
    public let keyCode: Int64
    public let modifiers: Modifiers
    /// The characters the key would type with the real (non-TurnOver) modifiers, if any.
    public let characters: String
    /// mach_absolute_time ticks of the originating event.
    public let timestamp: UInt64
    public let isRepeat: Bool
    /// The real flags, for re-posting the key.
    public let flags: CGEventFlags

    public init(keyCode: Int64, modifiers: Modifiers, characters: String, timestamp: UInt64, isRepeat: Bool, flags: CGEventFlags) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.characters = characters; self.timestamp = timestamp; self.isRepeat = isRepeat; self.flags = flags
    }

    /// A gesture from a binding identifier ("kb:turnover+shift+h"), for running a script from the shortcuts list.
    public init?(identifier: String) {
        let n = normalizeGestureIdentifier(identifier)
        guard let colon = n.firstIndex(of: ":") else { return nil }
        var mods = Modifiers(); var key = ""
        for part in n[n.index(after: colon)...].split(separator: "+", omittingEmptySubsequences: false) {
            if let m = Modifiers.named(String(part)) { mods.insert(m) } else { key = String(part) }
        }
        if key.isEmpty { key = "+" }
        guard let code = KeyNames.code(for: key) else { return nil }
        // The flags a real press carries, so the gesture can be sent (function keys and arrows carry fn on a Mac).
        var flags: CGEventFlags = []
        if mods.contains(.control) { flags.insert(.maskControl) }
        if mods.contains(.option) { flags.insert(.maskAlternate) }
        if mods.contains(.command) { flags.insert(.maskCommand) }
        if mods.contains(.shift) { flags.insert(.maskShift) }
        if KeyNames.isSpecial(code), code >= 96 { flags.insert(.maskSecondaryFn) }
        // The arrows, Home, End and the page keys carry the keypad flag too, as the keyboard's own do: without it Word
        // didn't move its caret for a VO-Left made from a name (it opened something instead, 17 Oct 2026).
        if [115, 116, 119, 121, 123, 124, 125, 126].contains(code) { flags.insert(.maskNumericPad) }
        self.init(keyCode: code, modifiers: mods, characters: key.count == 1 ? key : "", timestamp: 0, isRepeat: false, flags: flags)
    }

    /// The key's layout-independent name ("upArrow", "a", "f12", "."), or "key123".
    public var keyName: String { KeyNames.name(for: keyCode) }

    /// The normalized identifier: "kb:turnover+shift+upArrow".
    public var identifier: String { "kb:" + (modifiers.names + [keyName]).joined(separator: "+") }

    /// Diagnostics must not identify typing, including when main is stalled and no focus or script is known
    /// (issue 60, 28 Oct 2026). Option/dead keys and composed text can type without a single typedCharacter.
    /// A known script may name its key, as browse-mode commands do, except in a password field.
    public func logDescription(commandName: String? = nil, secure: Bool = false) -> String {
        // Key codes 54–62 are modifier keys, rather than text keys (including Caps Lock).
        let mayType = modifiers.intersection([.control, .command, .turnover]).isEmpty &&
            (typedCharacter != nil || (!KeyNames.isSpecial(keyCode) && !(54...62).contains(keyCode)))
        if mayType, commandName == nil || secure { return "(a typed key)" }
        return identifier + (commandName.map { " → \($0)" } ?? "")
    }

    /// Identifiers to try in order: layout-specific first, then the general one (NVDA: normalizedIdentifiers).
    @MainActor public var identifiers: [String] {
        let body = (modifiers.names + [keyName]).joined(separator: "+")
        return ["kb(\(config.keyboard.layout)):" + body, "kb:" + body]
    }

    /// Spoken form: "caps shift up arrow".
    @MainActor public var displayName: String {
        var parts: [String] = []
        if modifiers.contains(.turnover) { parts.append(config.general.turnOverKeyName) }
        for (m, name) in [(Modifiers.control, "control"), (.option, "option"), (.command, "command"), (.shift, "shift")] where modifiers.contains(m) {
            parts.append(KeyNames.spokenNames[name] ?? name)
        }
        parts.append(KeyNames.spoken(for: keyCode, characters: characters))
        return parts.joined(separator: " ")
    }

    public var isTurnOverModifier: Bool { modifiers.contains(.turnover) }

    /// NVDA's shouldReportAsCommand: keys with modifiers or special keys, never plain typing.
    public var shouldReportAsCommand: Bool {
        if isTurnOverModifier { return false }
        if !modifiers.isEmpty && !(modifiers == .shift) { return true }
        return KeyNames.isSpecial(keyCode)
    }

    /// The character this gesture types, if it is typing (NVDA: typedCharacter events).
    public var typedCharacter: Character? {
        guard !isTurnOverModifier, !modifiers.contains(.command), !modifiers.contains(.control) else { return nil }
        if keyCode == 51 { return "\u{8}" }   // backspace, so the typed-word buffer can drop a character
        guard characters.count == 1, let c = characters.first, c.asciiValue.map({ $0 >= 32 }) ?? true, !c.isNewline || keyCode == 36 || keyCode == 76 else { return nil }
        if KeyNames.isSpecial(keyCode) && c != " " && c != "\r" && c != "\t" { return nil }
        return c
    }

    public var description: String { identifier }

    /// Send the key on to the system (NVDA: gesture.send): re-posted as a HID-level
    /// event carrying TurnOver's marker so the tap lets it through. Down and up.
    public func send() {
        KeyboardGesture.poster?(self)
    }
    /// Installed by the keyboard handler (the Mac-specific layer).
    nonisolated(unsafe) public static var poster: (@Sendable (KeyboardGesture) -> Void)?   // set once at start
    /// Whether the TurnOver key is held now (Caps Lock, or Control and Option): the trackpad's on and off.
    nonisolated(unsafe) public static var turnOverHeld: (@Sendable () -> Bool)?
    /// Presses a key as if typed (an AI trying a plugin, PluginTry): TurnOver handles it like the owner's own key.
    nonisolated(unsafe) public static var typedPoster: (@Sendable (KeyboardGesture) -> Void)?
    /// Types text into the focused application (braille input), likewise installed by the keyboard handler.
    nonisolated(unsafe) public static var textPoster: (@Sendable (String) -> Void)?
    /// Keys pressed together (Left and Right: VoiceOver's Quick Nav toggle), installed by the keyboard handler.
    nonisolated(unsafe) public static var chordPoster: (@Sendable ([Int64]) -> Void)?
}

/// Normalize a binding written by a developer or in a gesture map: "kb:NVDA+Control+UpArrow" → "kb:turnover+control+upArrow".
nonisolated public func normalizeGestureIdentifier(_ identifier: String) -> String {
    guard let colon = identifier.firstIndex(of: ":") else { return identifier }
    let source = String(identifier[..<colon])
    let body = identifier[identifier.index(after: colon)...]
    var mods = Modifiers()
    var key = ""
    for part in body.split(separator: "+", omittingEmptySubsequences: false) {
        if let m = Modifiers.named(String(part)) { mods.insert(m) } else { key = String(part) }
    }
    if key.isEmpty { key = "+" }   // "kb:turnover++" is the plus key
    return source + ":" + (mods.names + [KeyNames.canonical(key)]).joined(separator: "+")
}

nonisolated public enum KeyNames {
    /// ANSI key codes → names (NVDA's vkCode names where they exist).
    static let table: [Int64: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 10: "section", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
        16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "o",
        32: "u", 33: "[", 34: "i", 35: "p", 36: "enter", 37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "n", 46: "m", 47: ".",
        48: "tab", 49: "space", 50: "`", 51: "backspace", 52: "numpadEnter", 53: "escape", 54: "rightCommand", 55: "command", 56: "shift", 57: "capsLock", 58: "option", 59: "control",
        60: "rightShift", 61: "rightOption", 62: "rightControl", 63: "function", 64: "f17", 65: "numpadDecimal", 67: "numpadMultiply", 69: "numpadPlus", 71: "numpadClear",
        72: "volumeUp", 73: "volumeDown", 74: "mute", 75: "numpadDivide", 76: "numpadEnter", 78: "numpadMinus", 79: "f18", 80: "f19", 81: "numpadEquals",
        82: "numpad0", 83: "numpad1", 84: "numpad2", 85: "numpad3", 86: "numpad4", 87: "numpad5", 88: "numpad6", 89: "numpad7", 90: "f20", 91: "numpad8", 92: "numpad9",
        96: "f5", 97: "f6", 98: "f7", 99: "f3", 100: "f8", 101: "f9", 103: "f11", 105: "f13", 106: "f16", 107: "f14", 109: "f10", 111: "f12", 113: "f15",
        114: "help", 115: "home", 116: "pageUp", 117: "delete", 118: "f4", 119: "end", 120: "f2", 121: "pageDown", 122: "f1", 123: "leftArrow", 124: "rightArrow", 125: "downArrow", 126: "upArrow",
    ]
    static let codes: [String: Int64] = { var d: [String: Int64] = [:]; for (k, v) in table { d[v.lowercased()] = k }; return d }()
    static let special: Set<Int64> = [36, 48, 51, 52, 53, 63, 64, 71, 72, 73, 74, 76, 79, 80, 90, 96, 97, 98, 99, 100, 101, 103, 105, 106, 107, 109, 111, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126]
    /// The slash key's name in the TurnOver layer's list.
    public static var slashName: String { String(localized: "Slash", comment: "The / key") }
    /// The keys as they are spoken, in the reader's language (as the Mac's own keyboard names them, in Turkish).
    static var spokenNames: [String: String] { [
        "enter": String(localized: "key.enter", defaultValue: "enter", comment: "A key's name"),
        "tab": String(localized: "key.tab", defaultValue: "tab", comment: "A key's name"),
        "space": String(localized: "key.space", defaultValue: "space", comment: "A key's name"),
        "backspace": String(localized: "key.backspace", defaultValue: "backspace", comment: "A key's name"),
        "escape": String(localized: "key.escape", defaultValue: "escape", comment: "A key's name"),
        "delete": String(localized: "key.delete", defaultValue: "delete", comment: "A key's name (forward delete)"),
        "home": String(localized: "key.home", defaultValue: "home", comment: "A key's name"),
        "end": String(localized: "key.end", defaultValue: "end", comment: "A key's name"),
        "pageUp": String(localized: "key.pageUp", defaultValue: "page up", comment: "A key's name"),
        "pageDown": String(localized: "key.pageDown", defaultValue: "page down", comment: "A key's name"),
        "leftArrow": String(localized: "key.leftArrow", defaultValue: "left arrow", comment: "A key's name"),
        "rightArrow": String(localized: "key.rightArrow", defaultValue: "right arrow", comment: "A key's name"),
        "upArrow": String(localized: "key.upArrow", defaultValue: "up arrow", comment: "A key's name"),
        "downArrow": String(localized: "key.downArrow", defaultValue: "down arrow", comment: "A key's name"),
        "numpadEnter": String(localized: "key.numpadEnter", defaultValue: "numpad enter", comment: "A key's name"),
        "capsLock": String(localized: "key.capsLock", defaultValue: "caps lock", comment: "A key's name"),
        "function": String(localized: "key.function", defaultValue: "fn", comment: "A key's name"),
        "help": String(localized: "key.help", defaultValue: "help", comment: "A key's name"),
        "section": String(localized: "key.section", defaultValue: "section", comment: "A key's name (§, beside 1 on some keyboards)"),
        "command": String(localized: "key.command", defaultValue: "command", comment: "A modifier key's name"),
        "control": String(localized: "key.control", defaultValue: "control", comment: "A modifier key's name"),
        "option": String(localized: "key.option", defaultValue: "option", comment: "A modifier key's name"),
        "shift": String(localized: "key.shift", defaultValue: "shift", comment: "A modifier key's name"),
    ] }

    public static func name(for keyCode: Int64) -> String { table[keyCode] ?? "key\(keyCode)" }
    public static func code(for name: String) -> Int64? { codes[name.lowercased()] }
    public static func isSpecial(_ keyCode: Int64) -> Bool { special.contains(keyCode) }
    /// Canonical spelling of a key name as written in a binding ("UpArrow" → "upArrow", "Enter" → "enter", "return" → "enter").
    static func canonical(_ name: String) -> String {
        let lower = name.lowercased()
        if lower == "return" { return "enter" }
        if lower == "alt" { return "option" }
        if let code = codes[lower] { return table[code]! }
        return name
    }
    /// How a key is spoken in input help and command-key echo.
    public static func spoken(for keyCode: Int64, characters: String) -> String {
        let n = name(for: keyCode)
        if let s = spokenNames[n] { return s }
        if n.hasPrefix("f"), n.count <= 3, Int(n.dropFirst()) != nil { return n.uppercased() }
        if n.count == 1, let c = n.first, c.isLetter || c.isNumber { return n }
        if n.count == 1, let c = n.first { return Symbols.name(of: c, sayCap: false) }
        return n
    }
}
