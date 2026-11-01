// SPDX-License-Identifier: GPL-3.0-or-later
// The numeric keypad (12 Oct 2026: "I want numpad support sooner, it's important to some people").
//
// Mac style: VoiceOver's NumPad Commander, off until VO-Clear turns it on, with VoiceOver's own default assignments
// (read from VoiceOver's ScreenReaderConfiguration on macOS 27: plain keys, keypad 0 held, Command, Option, Shift,
// Control). Each runs the VoiceOver command TurnOver already answers on its VO key, so the two never differ.
// Windows style: NVDA's desktop layout on the keypad. A Mac keypad has no Num Lock, so Clear, in Num Lock's place,
// switches between the commands (NVDA with Num Lock off, the default) and typing numbers. Keypad 0 held is the NVDA
// key, as NVDA's numpad Insert; Caps Lock works too.
import Foundation
import AppKit
import ApplicationServices

public enum Keypad {
    /// The keypad's key codes: 0 to 9, decimal, multiply, plus, clear, divide, enter, minus, equals.
    nonisolated public static let codes: Set<Int64> = [82, 83, 84, 85, 86, 87, 88, 89, 91, 92, 65, 67, 69, 71, 75, 76, 78, 81]
    nonisolated public static let zero: Int64 = 82
    nonisolated public static let clear: Int64 = 71

    /// VoiceOver's defaults: "<layer>:<key>" → "vo:<VO key>", "run:<script>" or "key:<key>". Layers: "" (plain),
    /// "zero" (keypad 0 held), "command", "option", "shift", "control".
    nonisolated static let mac: [String: String] = [
        ":numpad1": "vo:turnover+i", ":numpad2": "vo:turnover+downArrow", ":numpad4": "vo:turnover+leftArrow",
        ":numpad5": "vo:turnover+space", ":numpad6": "vo:turnover+rightArrow", ":numpad7": "vo:turnover+shift+upArrow",
        ":numpad8": "vo:turnover+upArrow", ":numpad9": "vo:turnover+shift+downArrow", ":numpadMultiply": "vo:turnover+shift+d",
        ":numpadClear": "vo:turnover+d", ":numpadDecimal": "key:escape", ":numpadEquals": "vo:turnover+m",
        ":numpadMinus": "run:keypad_guide", ":numpadPlus": "vo:turnover+shift+m", ":numpadDivide": "run:keypad_windows",
        "zero:numpad1": "vo:turnover+command+shift+l", "zero:numpad2": "vo:turnover+command+l", "zero:numpad3": "vo:turnover+command+shift+v",
        "zero:numpadEnter": "vo:turnover+command+v", "zero:numpad4": "vo:turnover+command+shift+h", "zero:numpad5": "vo:turnover+command+h",
        "zero:numpad6": "vo:turnover+command+shift+j", "zero:numpadPlus": "vo:turnover+command+j", "zero:numpad7": "vo:turnover+command+shift+j",
        "zero:numpad8": "vo:turnover+command+j", "zero:numpad9": "vo:turnover+[", "zero:numpadMinus": "vo:turnover+]",
        "zero:numpadMultiply": "vo:turnover+command+g", "zero:numpadDivide": "vo:turnover+command+shift+g",
        "zero:numpadClear": "vo:turnover+command+shift+t", "zero:numpadEquals": "vo:turnover+command+t", "zero:numpadDecimal": "vo:turnover+u",
        "command:numpad1": "vo:turnover+leftArrow", "command:numpad2": "vo:turnover+rightArrow", "command:numpad3": "vo:turnover+f",
        "command:numpad4": "vo:turnover+upArrow", "command:numpad5": "vo:turnover+downArrow", "command:numpad6": "vo:turnover+command+shift+b",
        "command:numpad7": "run:keypad_previousWord", "command:numpad8": "run:keypad_nextWord", "command:numpad9": "vo:turnover+command+shift+i",
        "command:numpadMultiply": "vo:turnover+command+u", "command:numpadClear": "key:pageUp", "command:numpadDecimal": "vo:turnover+t",
        "command:numpadEnter": "run:keypad_selectText", "command:numpadEquals": "key:pageDown", "command:numpadMinus": "vo:turnover+command+i",
        "command:numpadPlus": "vo:turnover+command+b", "command:numpadDivide": "vo:turnover+command+shift+u",
        "option:numpad7": "run:keypad_sector1", "option:numpad8": "run:keypad_sector2", "option:numpad9": "run:keypad_sector3",
        "option:numpad4": "run:keypad_sector4", "option:numpad5": "run:keypad_sector5", "option:numpad6": "run:keypad_sector6",
        "option:numpad1": "run:keypad_sector7", "option:numpad2": "run:keypad_sector8", "option:numpad3": "run:keypad_sector9",
        "option:numpadMultiply": "vo:turnover+`", "option:numpadEquals": "vo:turnover+shift+`", "option:numpadDivide": "vo:turnover+command+`",
        "option:numpadClear": "vo:turnover+command+shift+`", "option:numpadMinus": "vo:turnover+command+f3", "option:numpadPlus": "vo:turnover+command+f3",
        "shift:numpad1": "vo:turnover+r", "shift:numpad3": "vo:turnover+c", "shift:numpad5": "vo:turnover+shift+t",
        "shift:numpad7": "vo:turnover+shift+upArrow", "shift:numpad9": "run:keypad_tableHeader", "shift:numpadMultiply": "vo:turnover+command+f4",
        "shift:numpadDivide": "vo:turnover+shift+f4", "shift:numpadClear": "vo:turnover+shift+f5", "shift:numpadEquals": "vo:turnover+command+f5",
        "shift:numpadDecimal": "vo:turnover+shift+w", "shift:numpadEnter": "vo:turnover+c", "shift:numpadMinus": "vo:turnover+f8",
        "shift:numpadPlus": "vo:turnover+\\",
        "control:numpad5": "vo:turnover+shift+space",
    ]

    /// NVDA's desktop layout: layers "" (plain), "shift", "turnover" (NVDA), "turnover+shift".
    nonisolated static let windows: [String: String] = [
        ":numpad7": "run:nvda_reviewPreviousLine", ":numpad8": "run:nvda_reviewCurrentLine", ":numpad9": "run:nvda_reviewNextLine",
        ":numpad4": "run:nvda_reviewPreviousWord", ":numpad5": "run:nvda_reviewCurrentWord", ":numpad6": "run:nvda_reviewNextWord",
        ":numpad1": "run:keypad_reviewPreviousCharacter", ":numpad2": "run:nvda_reviewCurrentCharacter", ":numpad3": "run:keypad_reviewNextCharacter",
        ":numpadPlus": "run:nvda_reviewSayAll", ":numpadDivide": "run:nvda_leftClick", ":numpadMultiply": "run:nvda_rightClick",
        "shift:numpad7": "run:nvda_reviewTop", "shift:numpad9": "run:nvda_reviewBottom", "shift:numpad1": "run:nvda_reviewLineStart",
        "shift:numpad3": "run:nvda_reviewLineEnd", "shift:numpad2": "run:nvda_reportShortcut",
        "shift:numpadDivide": "run:nvda_leftLock", "shift:numpadMultiply": "run:nvda_rightLock",
        "turnover:numpad5": "run:reviewCurrent", "turnover:numpad8": "run:reviewParent", "turnover:numpad4": "run:reviewPrevious",
        "turnover:numpad6": "run:reviewNext", "turnover:numpad9": "run:nvda_previousFlattened", "turnover:numpad3": "run:nvda_nextFlattened",
        "turnover:numpad2": "run:reviewFirstChild", "turnover:numpadMinus": "run:reviewToFocus", "turnover:numpadEnter": "run:reviewActivate",
        "turnover:numpadDecimal": "run:reportCaretLocation", "turnover:numpadDivide": "run:nvda_mouseToNavigator",
        "turnover:numpadMultiply": "run:nvda_navigatorToMouse", "turnover:numpad7": "run:keypad_reviewModes", "turnover:numpad1": "run:keypad_reviewModes",
        "turnover+shift:numpadMinus": "run:reviewMoveFocus", "turnover+shift:numpadDecimal": "run:nvda_reviewLocation",
    ]

    nonisolated static func layer(_ m: Modifiers, windows: Bool) -> String {
        if windows {
            var parts: [String] = []
            if m.contains(.turnover) { parts.append("turnover") }
            if m.contains(.shift) { parts.append("shift") }
            if m.contains(.control) { parts.append("control") }
            if m.contains(.option) { parts.append("option") }
            if m.contains(.command) { parts.append("command") }
            return parts.joined(separator: "+")
        }
        // VoiceOver: one layer at a time; keypad 0 held (or the TurnOver key) is "zero".
        if m.contains(.turnover) { return "zero" }
        if m.contains(.command) { return "command" }
        if m.contains(.option) { return "option" }
        if m.contains(.shift) { return "shift" }
        if m.contains(.control) { return "control" }
        return ""
    }

    /// The keypad key's action in this style, if it has one (any thread: the key tap asks before swallowing a key).
    nonisolated public static func action(for g: KeyboardGesture, windows: Bool) -> String? {
        (windows ? Self.windows : mac)["\(layer(g.modifiers, windows: windows)):\(g.keyName)"]
    }

    /// Runs the keypad key's action (main thread). In keyboard help, says what it does instead.
    public static func run(_ g: KeyboardGesture, windows: Bool) {
        guard let a = action(for: g, windows: windows) else { return }
        guard !TurnOverMenu.shared.isOpen else { return }   // the menu has the keys: the keypad does nothing there
        let parts = a.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        Log.io("keypad \(g.identifier) → \(a)")
        // As every key: what was being said stops (the code review: keypad 9 pressed fast queued lines).
        Speech.cancel(); SayAll.stop(byGesture: true)
        // The first keypad key in the Windows style says once what the keypad does now (12 Oct 2026).
        if windows, !UserDefaults.standard.bool(forKey: "keypadHintGiven") {
            UserDefaults.standard.set(true, forKey: "keypadHintGiven")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { Speech.speakMessage(String(localized: "Keypad commands, as NVDA with Num Lock off. Clear switches to numbers.", comment: "Spoken message")) }
        }
        switch parts[0] {
        case "vo":
            guard let vg = KeyboardGesture(identifier: "kb:" + parts[1]), let s = ScriptHandler.findScript(for: vg) else { Speech.speakMessage(String(localized: "not available here", comment: "Spoken message")); return }
            if InputManager.isInputHelpActive { InputManager.handleInputHelp(g, script: s) } else { ScriptHandler.queueScript(s, gesture: vg) }
        case "run":
            guard let s = KeypadCommands.shared.script(named: parts[1]) ?? GlobalCommands.shared.script(named: parts[1]) ?? ScriptHandler.findScript(named: parts[1]) else {
                Log.warning("keypad: no script \(parts[1])"); return
            }
            if InputManager.isInputHelpActive { InputManager.handleInputHelp(g, script: s) } else { ScriptHandler.queueScript(s, gesture: g) }
        case "key":
            if InputManager.isInputHelpActive { Speech.speakMessage(parts[1] == "escape" ? "Escape" : parts[1] == "pageUp" ? "Page Up" : "Page Down"); return }
            KeyboardGesture(identifier: "kb:" + parts[1])?.send()
        default: break
        }
    }

    /// For the tests: every table entry that would reach nothing ("style key → action"). A renamed command or VO key
    /// would otherwise fail silently (the code review, 12 Oct 2026). Sets the style in memory only; never saves.
    public static func unresolved() -> [String] {
        let saved = config.general.keyboardStyle
        defer { config.general.keyboardStyle = saved }
        var bad: [String] = []
        for (style, table) in [("mac", mac), ("windows", windows)] {
            config.general.keyboardStyle = style
            let vo = VoiceOverKeysPlugin()
            for (key, a) in table.sorted(by: { $0.key < $1.key }) {
                let parts = a.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { bad.append("\(style) \(key) → \(a)"); continue }
                switch parts[0] {
                case "vo":
                    let g = KeyboardGesture(identifier: "kb:" + parts[1])
                    let s = g.flatMap { vo.script(for: $0) ?? GlobalCommands.shared.script(for: $0) }
                    if s == nil || (style == "mac" && !(s!.name.hasPrefix("vo_") || ["find", "sayAll", "findNext", "findPrevious"].contains(s!.name))) {
                        bad.append("\(style) \(key) → \(a) (\(s?.name ?? "nothing"))")
                    }
                case "run":
                    if KeypadCommands.shared.script(named: parts[1]) == nil && GlobalCommands.shared.script(named: parts[1]) == nil {
                        bad.append("\(style) \(key) → \(a)")
                    }
                case "key": if KeyboardGesture(identifier: "kb:" + parts[1]) == nil { bad.append("\(style) \(key) → \(a)") }
                default: bad.append("\(style) \(key) → \(a)")
                }
            }
        }
        return bad
    }

    /// VO-Clear (Mac style).
    public static func toggleCommander() {
        config.keyboard.numpadCommander.toggle(); config.save(); KeySettings.refresh()
        Speech.speakMessage(config.keyboard.numpadCommander ? String(localized: "NumPad Commander on", comment: "Spoken message") : String(localized: "NumPad Commander off", comment: "Spoken message"))
    }

    /// Clear, in Num Lock's place (Windows style).
    public static func toggleWindows() {
        config.keyboard.keypadCommands.toggle(); config.save(); KeySettings.refresh()
        Speech.speakMessage(config.keyboard.keypadCommands ? String(localized: "keypad commands", comment: "Spoken message") : String(localized: "keypad numbers", comment: "Spoken message"))
    }
}

/// The keypad's own commands, where no existing command does the job.
public final class KeypadCommands: ScriptableObject {
    public static let shared = KeypadCommands()

    private override init() {
        super.init()
        let cat = "Keypad"
        script("keypad_guide", String(localized: "Opens the TurnOver guide (keypad Minus, as VoiceOver's)", comment: "A command, as the key list and keyboard help say it"), category: cat) { _ in TurnOverGuide.open() }
        script("keypad_windows", String(localized: "The window chooser (keypad Slash, as VoiceOver's)", comment: "A command, as the key list and keyboard help say it"), category: cat) { _ in VoiceOverKeysPlugin.windowChooser() }
        for (name, forward) in [("keypad_previousWord", false), ("keypad_nextWord", true)] {
            script(name, forward ? String(localized: "Next word (Command keypad 8)", comment: "A command, as the key list and keyboard help say it") : String(localized: "Previous word (Command keypad 7)", comment: "A command, as the key list and keyboard help say it"), category: cat) { _ in
                let key = KeyboardGesture(identifier: forward ? "kb:option+rightArrow" : "kb:option+leftArrow")!
                if let d = API.focusTreeInterceptor, !d.passThrough, let s = d.script(named: forward ? "moveByWord_forward" : "moveByWord_back") { s.handler(key); return }
                if let f = API.focusObject, f.hasNavigableText, let s = f.script(named: "caret_moveByWord") { s.handler(key); return }
                Speech.speakMessage(String(localized: "not in text", comment: "Spoken message"))
            }
        }
        for n in 1...9 {
            script("keypad_sector\(n)", String(localized: "The item in part \(String(n)) of the screen, as the keypad lies: 7 top left, 3 bottom right (Option keypad)", comment: "A command: %@ is a keypad digit"), category: cat) { _ in
                guard let screen = NSScreen.screens.first?.frame else { return }
                let col = (n - 1) % 3, row = (n - 1) / 3
                let p = CGPoint(x: screen.width * (CGFloat(col) + 0.5) / 3, y: screen.height * (CGFloat(row) + 0.5) / 3)
                guard let e = VoiceOverKeysPlugin.element(at: p) else { Speech.speakMessage(String(localized: "nothing there", comment: "Spoken message")); return }
                ObjectNavigator.shared.moveTo(e)
            }
        }
        for (name, what) in [("keypad_selectText", String(localized: "Selecting the text under the VoiceOver cursor", comment: "A VoiceOver feature")), ("keypad_tableHeader", String(localized: "Moving to the table's header", comment: "A VoiceOver feature")),
                             ("keypad_reviewModes", String(localized: "Review modes", comment: "A VoiceOver feature"))] {
            script(name, String(localized: "\(what): not in TurnOver yet", comment: "A VoiceOver feature TurnOver lacks: %@ is the feature"), category: cat) { _ in Speech.speakMessage(String(localized: "\(what) isn't available in TurnOver yet", comment: "A VoiceOver feature TurnOver lacks: %@ is the feature")) }
        }
        // NVDA's keypad 1 and 3: review by character anywhere (Caps Lock Left and Right do it only in text).
        script("keypad_reviewPreviousCharacter", String(localized: "Moves the review cursor to the previous character (keypad 1)", comment: "A command, as the key list and keyboard help say it"), category: cat) { _ in TextReview.move(.character, -1) }
        script("keypad_reviewNextCharacter", String(localized: "Moves the review cursor to the next character (keypad 3)", comment: "A command, as the key list and keyboard help say it"), category: cat) { _ in TextReview.move(.character, 1) }
    }
}
