// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import TurnOverCore

/// The log line that should settle the TurnOver key lost with the Command-Tab switcher open (16 Nov 2026). Unhappy
/// cases: a typed key (never named), the Caps Lock TurnOver key, Control and Option held for their own sake when they
/// are not the TurnOver key, and the switcher closed with everything as expected.
func keyboardModifierDiagnosticsTests() {
    func gesture(_ modifiers: Modifiers, _ flags: CGEventFlags, keyCode: Int64 = 4, characters: String = "") -> KeyboardGesture {
        KeyboardGesture(keyCode: keyCode, modifiers: modifiers, characters: characters, timestamp: 0, isRepeat: false, flags: flags)
    }
    let controlOption: CGEventFlags = [.maskControl, .maskAlternate]

    test("keyboard modifier diagnostics: nothing is logged when the switcher is closed and the names agree") {
        let named = gesture([.turnover, .command, .shift], [.maskControl, .maskAlternate, .maskCommand, .maskShift])
        check(KeyboardModifierDiagnostics.line(for: named, keyboardFlags: [.maskControl, .maskAlternate, .maskCommand, .maskShift],
                                               controlOptionIsTurnOver: true, switcherOpen: false) == nil, "a TurnOver key named as one")
        let plain = gesture([.command, .shift], [.maskCommand, .maskShift])
        check(KeyboardModifierDiagnostics.line(for: plain, keyboardFlags: [.maskCommand, .maskShift],
                                               controlOptionIsTurnOver: true, switcherOpen: false) == nil, "an ordinary shortcut")
        let ownSake = gesture([.control, .option], controlOption)
        check(KeyboardModifierDiagnostics.line(for: ownSake, keyboardFlags: controlOption,
                                               controlOptionIsTurnOver: false, switcherOpen: false) == nil,
              "Control and Option are themselves when they are not the TurnOver key (Caps Lock is)")
    }

    test("keyboard modifier diagnostics: with the switcher open, the event's flags beside what the keyboard holds") {
        let key = gesture([.command, .shift], [.maskCommand, .maskShift])
        let line = KeyboardModifierDiagnostics.line(for: key, keyboardFlags: [.maskControl, .maskAlternate, .maskCommand, .maskShift],
                                                    controlOptionIsTurnOver: true, switcherOpen: true) ?? ""
        check(line.contains("kb:command+shift+h"), "the name TurnOver gave the key")
        check(line.contains("event flags 0x120000"), "the event's own modifier flags")
        check(line.contains("the keyboard holds 0x1e0000"), "the modifiers the keyboard holds")
        check(line.contains("application switcher open"), "why it was logged")
        check(line.contains("not named the TurnOver key"), "the lost TurnOver key is said in words")
    }

    test("keyboard modifier diagnostics: Control and Option held but not named the TurnOver key, switcher closed") {
        let key = gesture([.control, .command, .shift], [.maskControl, .maskCommand, .maskShift])
        let line = KeyboardModifierDiagnostics.line(for: key, keyboardFlags: [.maskControl, .maskAlternate, .maskCommand, .maskShift],
                                                    controlOptionIsTurnOver: true, switcherOpen: false) ?? ""
        check(line.contains("kb:control+command+shift+h"), "logged with its name")
        check(!line.contains("switcher"), "the switcher was not open")
    }

    test("keyboard modifier diagnostics: a typed key stays masked") {
        let typed = gesture([], [], keyCode: 0, characters: "a")
        let line = KeyboardModifierDiagnostics.line(for: typed, keyboardFlags: controlOption,
                                                    controlOptionIsTurnOver: true, switcherOpen: true) ?? ""
        check(line.contains("(a typed key)"), "only that it was a typed key")
        check(!line.contains("kb:a"), "never which key")
    }
}
