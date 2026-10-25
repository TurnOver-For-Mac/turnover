// SPDX-License-Identifier: GPL-3.0-or-later
// Typing on the display's braille keyboard (NVDA: brailleInput; VoiceOver: contracted braille input). A chord is the
// dots held together, acted on when all are let go.
// - Contracted (the default, as most braille readers read): the cells of a word are held until it ends (space, Return), then
//   translated and typed together, as contractions only make sense whole.
// - Uncontracted: each letter is typed as it comes; the word's cells are still translated together, so capital and
//   number signs work, and what was typed is corrected as the word grows.
// Space alone types a space; dot 7 alone is Backspace and dot 8 alone Return, as with VoiceOver. What is spoken
// follows Preferences, Braille, Speak braille typing (words by default).
import Foundation
import ApplicationServices

public enum BrailleInput {
    private static var word: [UInt8] = []     // the cells of the word being typed
    /// Cells typed in contracted braille and not yet translated: the display shows them at the cursor.
    public static var pending: [UInt8] { config.braille.contractedInput ? word : [] }
    private static var typed = ""              // uncontracted: what has been typed for them so far

    // The input tests supply a translator here so privacy does not depend on which private macOS tables are
    // installed (28 Oct 2026). Production keeps the system translator; all access stays on the main actor.
    package static var backTranslate: ([UInt8], Bool) -> String = { BrailleOutput.backTranslate($0, contracted: $1) }

    private static var echoWords: Bool { ["words", "both"].contains(config.braille.inputEcho) }
    private static var echoCharacters: Bool { ["characters", "both"].contains(config.braille.inputEcho) }
    private static var isSecureInput: Bool { API.focusObject?.role == .passwordEdit || Speech.typingIntoSecretField }

    /// A chord let go: its dots (1 to 8) and whether space was in it.
    // MARK: Modifiers (VoiceOver: space with dot 7 holds a modifier for the next key, with dot 8 locks it)

    /// Held for the next key only, and locked until unlocked.
    static var oneShot: Modifiers = []
    static var locked: Modifiers = []
    static var held: Modifiers { oneShot.union(locked) }

    static func modifier(_ m: Modifiers, name: String, lock: Bool) {
        if lock {
            if locked.contains(m) { locked.remove(m); Speech.speakMessage(String(localized: "\(name) off", comment: "A modifier key unlocked from the braille keyboard: %@ is the key")) }
            else { locked.insert(m); Speech.speakMessage(String(localized: "\(name) locked", comment: "A modifier key locked from the braille keyboard: %@ is the key")) }
        } else {
            oneShot.insert(m); Speech.speakMessage(name)
        }
    }

    /// The modifiers held, as written in a key's name ("command+shift+").
    static func takeModifiers() -> String {
        let m = held
        oneShot = []
        return [(Modifiers.control, "control"), (.option, "option"), (.command, "command"), (.shift, "shift")].filter { m.contains($0.0) }.map { $0.1 + "+" }.joined()
    }

    /// Space this long after a chord's last dot (or after a dot was let go) is typing that ran into the space, not a
    /// command: "quite a few" typed fast gave space with dot 1, "previous item", and the cursor jumped (7 Oct 2026).
    static let lateSpaceSeconds = 0.12
    /// The last letter typed, for "still typing".
    private static var lastTypedAt = Date.distantPast

    /// The keyboard is in text (a field, a document, Terminal).
    private static var inText: Bool {
        guard let f = API.focusObject else { return false }
        return f.states.contains(.editable) || f.role == .terminal || (f.role == .document && f.hasNavigableText)
    }

    public static func chord(dots: Set<Int>, space: Bool, spaceLate: Bool = false) {
        Speech.cancel()   // as a typed key does
        // Input help: the chord says what it does, except keyboard help itself (space with 1 3), which turns it off.
        if InputManager.isInputHelpActive, !(space && (dots == [1, 3] || dots == [1, 3, 7])) {
            BrailleHelp.explain(BrailleHelp.describe(dots: dots, space: space))
            return
        }
        // The TurnOver menu open: letters jump to items, as typed keys do; dot 8 chooses, dot 7 does nothing.
        if TurnOverMenu.shared.isOpen, !space {
            if dots == [8] { KeyboardGesture(identifier: "kb:enter").map { TurnOverMenu.shared.handle($0) }; return }
            let cell = dots.reduce(UInt8(0)) { $0 | UInt8(1 << ($1 - 1)) }
            if let ch = backTranslate([cell & 0x3F], false).lowercased().first,
               let g = KeyboardGesture(identifier: "kb:\(ch)") { TurnOverMenu.shared.handle(g) }
            return
        }
        // A modifier held: the cell is a key to press with it (Command S), not text to type.
        if !held.isEmpty, !space, !dots.isEmpty, dots != [7], dots != [8] {
            flush()
            let cell = dots.reduce(UInt8(0)) { $0 | UInt8(1 << ($1 - 1)) }
            let ch = backTranslate([cell & 0x3F], false).lowercased().first
            let mods = takeModifiers()
            if let ch, let g = KeyboardGesture(identifier: "kb:\(mods)\(ch)") {
                Log.io("braille input: modified key")
                if let s = ScriptHandler.findScript(for: g) { ScriptHandler.executeScript(s, gesture: g) } else { g.send() }
            } else { Tones.edge() }
            return
        }
        // A password field: the cells are typed, never logged or echoed (the keyboard's typing has the same rule).
        // Dots encode what was typed, including passwords. Keep them out even with developer speech logging
        // enabled, and out of the late-space and unrecognised-command diagnostics below (#61, 28 Oct 2026).
        if isSecureInput { Log.io("braille input: (a cell in a password field)") }
        else { Log.io("braille input: \(space ? "space" : "a cell")") }
        if space && dots.isEmpty { finishWord(then: " "); return }
        // Typing in text, the space landing a moment after the letter: the letter, then the space, not the command
        // the two make together (only while typing: a command after a pause still runs).
        if space, spaceLate, inText, dots.isSubset(of: 1...6), Date().timeIntervalSince(lastTypedAt) < 2 {
            Log.io("braille input: space pressed after a cell while typing; typed as the cell, then a space")
            word.append(dots.reduce(UInt8(0)) { $0 | UInt8(1 << ($1 - 1)) })
            lastTypedAt = Date()
            finishWord(then: " ")
            return
        }
        if space { command(dots); return }
        if dots == [7] { if held.isEmpty { backspace() } else { BrailleCommands.press(takeModifiers() + "backspace") }; return }
        if dots == [8] { finishWord(then: nil); BrailleCommands.press(takeModifiers() + "enter"); return }
        let cell = dots.reduce(UInt8(0)) { $0 | UInt8(1 << ($1 - 1)) }
        // Dots 7 and 8 together, with nothing else: no character (it was typed as a blank cell).
        if cell & 0x3F == 0 { Tones.edge(); return }
        word.append(cell)
        lastTypedAt = Date()
        if word.count == 1 { followTypingIntoField(); typingElement = API.focusObject?.element }   // from the first cell, so the word shows in its line
        if config.braille.contractedInput {
            if echoCharacters, !isSecureInput { Speech.speakPrivate(backTranslate([cell], false)) }
            Braille.refreshSoon()
        } else {
            retype()
        }
    }

    /// Anything else happening (the caret moved, a display key): a word half typed in contracted braille is typed now,
    /// rather than lost.
    public static func flush() {
        guard !word.isEmpty else { return }
        finishWord(then: nil)
    }

    /// Where the word being typed began.
    private static var typingElement: AXUIElement?
    /// The focus moved to another control while a contracted word was half typed (Command Tab on the keyboard): the
    /// word is dropped, with a tone, never typed into the new field (a code review, 14 Oct 2026).
    public static func focusChanged() {
        guard !word.isEmpty else { return }
        if let t = typingElement, let f = API.focusObject?.element, t.isSame(f) { return }
        word.removeAll(); typingElement = nil
        Tones.edge(); Log.io("braille input: a half-typed word dropped; the focus moved")
    }
    /// A keyboard key that runs a command while a word is half typed: the word goes in first, as the display's own
    /// keys do (an arrow after "hel" moved first, and "hel" landed later, elsewhere).
    public static func flushForKey() { if !word.isEmpty { flush() } }

    /// Space with dots: VoiceOver's braille commands (BrailleCommands). A word half typed is typed first.
    private static func command(_ dots: Set<Int>) {
        flush()
        if !BrailleCommands.run(dots) {
            // Space pressed a moment before the word's last cell was let go: "the" (2 3 4 6) became space with 2 3 4 6,
            // no command, and the word was lost (7 Oct 2026). A chord that is no command is that cell, then the space.
            guard !dots.contains(7), !dots.contains(8) else {
                Log.io("braille input: unrecognised space chord")
                Tones.edge(); return
            }
            Log.io("braille input: unrecognised space chord; typed as the cell, then a space")
            word.append(dots.reduce(UInt8(0)) { $0 | UInt8(1 << ($1 - 1)) })
            finishWord(then: " ")
        }
    }

    /// The word ends: in contracted braille it is translated and typed now. Then `after` (a space), and the word
    /// spoken if words are echoed.
    private static func finishWord(then after: String?) {
        var spoken = typed
        if config.braille.contractedInput, !word.isEmpty {
            let text = backTranslate(word, true)
            type(text)
            spoken = text
        }
        if let after { type(after) }
        // Typing echo follows the keyboard's private speech path: heard, but excluded from speech history and
        // reports, including when developer speech logging is on (#61, 28 Oct 2026).
        if echoWords, !spoken.isEmpty, !isSecureInput { Speech.speakPrivate(spoken) } else if after == " ", echoCharacters, !isSecureInput { Speech.speakPrivate(" ") }
        word.removeAll(); typed = ""
    }

    /// Uncontracted: type what the word's cells now say, correcting what was typed before.
    private static func retype() {
        let text = backTranslate(word, false)
        let common = typed.commonPrefix(with: text)
        for _ in 0..<(typed.count - common.count) { KeyboardGesture(identifier: "kb:backspace")?.send() }
        let add = String(text.dropFirst(common.count))
        if !add.isEmpty { type(add) }
        typed = text
        // Not speakMessage: that would flash the letter on the display.
        if echoCharacters, !isSecureInput, let last = add.last { Speech.speakPrivate(String(last)) }
    }

    private static func backspace() {
        // Typed text: as the keyboard's Backspace, through TurnOver's script, which says what went (dot 7 deleted in
        // silence, 7 Oct 2026).
        if word.isEmpty {
            guard let g = KeyboardGesture(identifier: "kb:backspace") else { return }
            if let s = ScriptHandler.findScript(for: g) { ScriptHandler.executeScript(s, gesture: g) } else { g.send() }
            return
        }
        let cell = word.removeLast()
        if config.braille.contractedInput {
            // The cell taken off, as a letter ("deleted d"), not just "deleted".
            // The pending cell has not reached the field, so SecureEcho cannot protect this deletion. Never
            // translate or announce it in a password field (braille privacy review, 28 Oct 2026).
            if !isSecureInput {
                let letter = backTranslate([cell], false)
                Speech.speakPrivate(letter.isEmpty ? "deleted" : "deleted " + letter)
            }
            Braille.refreshSoon()
        } else { retype() }
    }

    /// Text into the focused field.
    private static func type(_ s: String) {
        guard !s.isEmpty else { return }
        followTypingIntoField()
        KeyboardGesture.textPoster?(s)
    }

    /// Typing on the display in browse mode, with the keyboard in a text field (VO Command H in Claude's prompt reads
    /// on in browse mode and leaves the keyboard in the prompt): the text goes into the field, so TurnOver goes there
    /// too, in focus mode. Before, the display and joystick stayed on the reading position (7 Oct 2026).
    private static func followTypingIntoField() {
        guard let d = API.focusTreeInterceptor, !d.passThrough else { return }
        let app = AXUIElementCreateApplication(d.webArea.pid)
        guard let f = app.element(kAXFocusedUIElementAttribute), ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"].contains(f.role) else { return }
        Log.io("braille input: typing went to a text field in browse mode; focus mode there")
        d.setPassThrough(true, announce: true)
        AXHandler.shared.focusChanged(f, pid: d.webArea.pid)
    }
}
