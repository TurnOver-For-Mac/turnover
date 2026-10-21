// SPDX-License-Identifier: GPL-3.0-or-later
// Speech (NVDA: speech.speech). What to say for an object, a range of text, a
// typed character, a selection change — and the sequencing: speech queues; a
// gesture cancels it (the input manager does that, NVDA's way), so the reader
// never falls behind the user.
//
// The engine underneath is TurnOverSpeech's SpeechPlayer (the Mac-specific path:
// AVSpeechSynthesizer as a renderer, our own player for cancellation).
import Foundation
import TurnOverSpeech
import ApplicationServices
import AppKit
import TurnOverAX

public enum OutputReason { case focus, focusEntered, caret, query, change, message, sayAll, selection, mouse }

/// NVDA's speech modes, cycled by NVDA+S: talk; beeps (a short tone where speech would be); off; on demand (only
/// what a reporting command asks for: the time, the current line, the title …).
public enum SpeechMode { case off, talk, onDemand, beeps }

public enum Speech {
    public static var player: SpeechPlayer! { didSet { SpeechPlayer.current = player } }
    public static var mode: SpeechMode = .talk
    /// On-demand mode: speech allowed until then, set as a reporting command starts (ScriptHandler).
    nonisolated(unsafe) public static var demandedUntil = Date.distantPast
    nonisolated(unsafe) private static var lastBeep = Date.distantPast
    public private(set) static var lastSpoken = ""
    /// What was said, kept in memory for a feedback report the tester asks to include speech in: the log on disk
    /// holds lengths only (a code review, 14 Oct 2026: it held 30 days of mail, chat and Terminal). The last
    /// 3,000 phrases; never the private ones.
    nonisolated public static let history = Locked<[(at: Date, text: String)]>([])
    /// Words in the log instead of lengths, for a developer's own Mac: defaults write com.turnover.reader logSpeech -bool true
    nonisolated static let logsWords = Edition.devDefault("logSpeech")
    public static var isPrivateNow: Bool { privateNext }
    private static var typedWord: [Character] = []
    /// The letters typed since the last word ended, as typed (Mail's autocorrect check compares them with the field).
    public static var typedWordSoFar: String { String(typedWord) }
    /// The word being typed had a Backspace in it, so typedWordSoFar is only its end.
    public static var typedWordWasEdited: Bool { backspacedSinceWord }

    // MARK: - Primitives

    /// Stop now (NVDA: cancelSpeech). Every gesture does this before its script runs.
    public static func cancel() {
        player?.cancel()
    }

    /// Control alone: pause speech, or carry on if it is paused (VoiceOver's way). Say All waits with it.
    public static func togglePause() {
        guard let p = player else { return }
        if p.isPaused { p.resume() } else if p.isBusy { p.pause() }
    }

    /// The lowest level: text already processed, queued behind what is playing.
    /// Receives everything that would be spoken, before the mode check (tests and the log viewer).
    public static var sink: ((String) -> Void)?

    /// TurnOver's own words inside text being read ("link", "heading level 2"): marked, so that on a page in another
    /// language they are said by the reader's own voice, not by the page's ("link" read by the Arabic voice as a
    /// transliteration; a tester).
    public static func ui(_ words: String) -> String { words.isEmpty ? "" : "\u{F8F0}\(words)\u{F8F1}" }

    /// Put before a capital letter said on its own, so that it is said at a raised pitch (NVDA's capital pitch change).
    public static let capitalMark = "\u{F8F2}"

    static func enqueue(_ text: String, language: String? = nil, onStart: (@Sendable () -> Void)? = nil, completion: (@Sendable (Bool) -> Void)? = nil) {
        if text.contains(capitalMark) {
            // Raised only when the capital is the whole utterance; inside longer speech ("word A") the mark just goes.
            let plain = text.replacingOccurrences(of: capitalMark, with: "")
            if text.hasPrefix(capitalMark), !plain.contains(capitalMark), cleaned(plain).count <= 6 {
                pitchNext = 1 + Float(config.speech.capitalPitch) / 100
            }
            return enqueue(plain, language: language, onStart: onStart, completion: completion)
        }
        if text.contains("\u{F8F0}") {
            // In another language's voice: TurnOver's words in the reader's voice, the text in the language's.
            if Languages.voice(for: language) != nil {
                var parts: [(String, Bool)] = []
                var cur = "", inUI = false
                for ch in text {
                    if ch == "\u{F8F0}" || ch == "\u{F8F1}" {
                        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { parts.append((cur, inUI)) }
                        cur = ""; inUI = ch == "\u{F8F0}"; continue
                    }
                    cur.append(ch)
                }
                if !cur.trimmingCharacters(in: .whitespaces).isEmpty { parts.append((cur, inUI)) }
                for (i, (t, isUI)) in parts.enumerated() {
                    enqueue(t, language: isUI ? nil : language, onStart: i == 0 ? onStart : nil, completion: i == parts.count - 1 ? completion : nil)
                }
                if parts.isEmpty { completion?(true) }
                return
            }
            return enqueue(text.replacingOccurrences(of: "\u{F8F0}", with: "").replacingOccurrences(of: "\u{F8F1}", with: ""), language: language, onStart: onStart, completion: completion)
        }
        // Unmarked text with no language given (a Word table cell, an object's name, a chat row): a piece in another
        // script goes to that language's voice, the rest stays in the reader's. Arabic cells in Word were silent
        // under an English voice (a tester, 12 Oct 2026). Only where letters beyond Latin appear.
        if language == nil, !splittingLanguages, config.speech.autoLanguageSwitching,
           text.unicodeScalars.contains(where: { $0.value > 0x024F && CharacterSet.letters.contains($0) }) {
            let pieces = Languages.splitByLanguage(text)
            if pieces.contains(where: { $0.language != nil }) {
                splittingLanguages = true
                defer { splittingLanguages = false }
                for (i, piece) in pieces.enumerated() {
                    enqueue(piece.text, language: piece.language, onStart: i == 0 ? onStart : nil, completion: i == pieces.count - 1 ? completion : nil)
                }
                return
            }
        }
        // Taken here, before the mode, VoiceOver and empty-text returns: a capital spelt while VoiceOver was talking
        // raised the pitch of the next real utterance instead (code review, 16 Oct 2026).
        let pitch = pitchNext; pitchNext = nil
        sink?(cleaned(text))
        switch mode {
        case .talk: break
        case .onDemand where Date() < demandedUntil: break
        case .beeps:
            if !NSWorkspace.shared.isVoiceOverEnabled, Date().timeIntervalSince(lastBeep) > 0.1 { lastBeep = Date(); Tones.beep(1000, 15, volume: 0.25) }
            completion?(false); return
        default: completion?(false); return
        }
        // While VoiceOver is on it does the talking: TurnOver speaking too (its own menu-bar menu, read item by
        // item over VoiceOver, 3 Oct 2026) is two voices at once.
        if NSWorkspace.shared.isVoiceOverEnabled, !Coexist.on { completion?(false); return }   // (coexisting, VoiceOver is on and silent in TurnOver's apps)
        let s = cleaned(text)
        // Nothing left to say (zero-width marks, a bidi mark): it still "starts", or say all's count of queued
        // chunks never came down and three such lines stopped it for good (a code review, 14 Oct 2026).
        guard !s.isEmpty else { onStart?(); completion?(true); return }
        lastSpoken = s
        // Speech that came with its text as written (a message, text from the screen) keeps it for "copy last
        // spoken"; anything else (an object: "alert, dialog") is copied as spoken.
        if rawPending { rawPending = false } else { lastRaw = "" }
        echoOnly = false
        let voice = Languages.voice(for: language)
        if privateNext { Log.io("say: (private, \(s.count) characters)") }
        else if Self.logsWords { Log.io("say\(voice != nil ? " [\(language ?? "")]" : ""): \(s.prefix(160))") }
        else { Log.io("say\(voice != nil ? " [\(language ?? "")]" : ""): [\(s.count) characters]") }
        if !privateNext { history.value.append((Date(), s)); if history.value.count > 3000 { history.value.removeFirst(500) } }
        if let pitch { Log.io("say: (pitch raised to \(Int(pitch * 100)) percent)") }
        // Kokoro (the maintainer's Mac): say all, or everything, in a natural voice; another language keeps its own voice, and
        // a capital said higher keeps the Mac voice (Kokoro has no pitch).
        let kokoro: String? = voice == nil && pitch == nil && KokoroVoice.wanted(reading: readingNow) ? "external:" + KokoroVoice.voice : nil
        // No player (the plugin tool and the tests start no speech): nothing to say it with (a plugin list crashed
        // here, 13 Oct 2026).
        guard player != nil else { completion?(false); return }
        player.speak(s, interrupt: false, voice: kokoro ?? voice, rate: voice == nil ? nil : Languages.rate(for: language), pitch: pitch, onStart: onStart, completion: completion)
    }
    private static var pitchNext: Float?
    /// Set by say all while it queues its text: Kokoro's "for reading" takes it.
    public static var readingNow = false
    /// The next utterance is private (the clipboard, a link's address, a notification: a copied password, a reset
    /// token, a two-factor code): spoken, but logged only as its length (the code review, 12 Oct 2026).
    private static var privateNext = false
    public static func speakPrivate(_ text: String) { asPrivate { speakText(text) } }
    /// Whatever is spoken inside is logged only as its length (every part, if the speech is split by language).
    public static func asPrivate(_ speak: () -> Void) { privateNext = true; speak(); privateNext = false }

    /// Strip bidi isolates and marks the Finder puts in names ("⁨Desktop⁩ — iCloud").
    /// A name made of an icon font's private characters says nothing to the ear ("󰋜, button": Bambu Studio's web
    /// pages, Day 4, 11 Oct 2026); those characters are dropped, and a name of nothing else is no name.
    public static func withoutIconGlyphs(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { Self.isIconGlyph($0) }) else { return s }
        return String(String.UnicodeScalarView(s.unicodeScalars.filter { !Self.isIconGlyph($0) })).trimmingCharacters(in: .whitespaces)
    }
    /// The private-use areas, less TurnOver's own marks (U+F8F0 to U+F8F2).
    static func isIconGlyph(_ u: Unicode.Scalar) -> Bool {
        (0xE000...0xF8EF).contains(u.value) || (0xF8F3...0xF8FF).contains(u.value) || u.value >= 0xF0000
    }

    public static func cleaned(_ raw: String) -> String {
        // Bidi isolates and marks, zero-width joiners and spaces, soft hyphens, byte order marks: e-mail previews are full of them.
        let invisible: Set<UInt32> = [0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x00AD, 0xFEFF, 0x2060, 0xFFFC, 0xF8F2]
        return String(String.UnicodeScalarView(raw.unicodeScalars.filter { !(0x2066...0x2069).contains($0.value) && !invisible.contains($0.value) && !isIconGlyph($0) }))
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// NVDA's expired focus events: when focus moves on within moments (Mail passes through the old message on
    /// its way to the list after Command+1), what was said for the focus it left is dropped, not finished.
    private static var lastFocusAt = Date.distantPast
    public static var sinceFocusSpoken: TimeInterval { Date().timeIntervalSince(lastFocusAt) }
    /// Set when a focus follows another within 0.4 s; the drop happens only once the new focus has words of its own
    /// (speakObject, reason focus). A nameless pane or a blip the module ignores on the way to a control used to cut
    /// the control's speech and say nothing in its place (code review, 16 Oct 2026).
    private static var dropForFocusUntil: Date?
    /// For the tests: whether a drop is waiting for the next focus's words, and whether a capital's pitch is pending.
    public static var testDropForFocusPending: Bool { dropForFocusUntil != nil }
    public static var testPitchPending: Bool { pitchNext != nil }
    public static func testResetFocusTiming() { lastFocusAt = .distantPast; dropForFocusUntil = nil }
    public static func focusMoving() {
        Tones.focusTick()
        if Date().timeIntervalSince(lastFocusAt) < 0.4 { dropForFocusUntil = Date().addingTimeInterval(0.5) }
        lastFocusAt = Date()
    }

    /// A message from the reader itself (NVDA: speakMessage / ui.message).
    public static func speakMessage(_ text: String) {
        lastRaw = text; rawPending = true
        enqueue(text)
        if Thread.isMainThread { Braille.message(text) } else { DispatchQueue.main.async { Braille.message(text) } }
    }

    /// Words for the ear only: the display already shows what they are about ("new line" while it shows the new line,
    /// a window's name while it shows the focus, "messages" while it shows the message). As a braille message they
    /// hid the line for seconds on a 20-cell display (7 Oct 2026).
    public static func speakOnly(_ text: String) {
        lastRaw = text; rawPending = true
        enqueue(text)
    }

    /// TurnOver's own cursor landed on an item (a held list, the menu, the VoiceOver cursor): spoken, and kept on the
    /// display until the focus or caret moves (Braille.item).
    public static func speakItem(_ text: String, processed: Bool = false) {
        if processed { speakText(text) } else { lastRaw = text; rawPending = true; enqueue(text) }
        if Thread.isMainThread { Braille.item(text) } else { DispatchQueue.main.async { Braille.item(text) } }
    }

    /// TurnOver's own confirmations ("copied"): spoken, but not remembered as the last thing said.
    public static func speakMessage(_ text: String, remember: Bool) {
        let keepRaw = lastRaw, keepSpoken = lastSpoken
        enqueue(text)
        if !remember { lastRaw = keepRaw; lastSpoken = keepSpoken }
    }

    /// What was last spoken, as written on screen (not "slash Users slash …"): what "copy last spoken" copies.
    public private(set) static var lastRaw = ""
    private static var rawPending = false

    /// Text from the screen: symbols named at the user's level (NVDA: speakText).
    public static func speakText(_ text: String, symbolLevel: SymbolLevel? = nil, onStart: (@Sendable () -> Void)? = nil, completion: (@Sendable (Bool) -> Void)? = nil) {
        lastRaw = text; rawPending = true
        enqueue(processed(text, symbolLevel: symbolLevel), onStart: onStart, completion: completion)
    }

    /// Text that arrives by itself (a live region such as Claude's progress, new Terminal output, a reply): spoken,
    /// and shown on the braille display too, for as long as it takes to read (6 Oct 2026).
    public static func speakNews(_ text: String) {
        speakText(text)
        if Thread.isMainThread { Braille.message(text) } else { DispatchQueue.main.async { Braille.message(text) } }
    }

    /// NVDA: processText — symbol processing, with lone characters and pure punctuation always named.
    public static func processed(_ text: String, symbolLevel: SymbolLevel? = nil) -> String {
        let t = text.replacingOccurrences(of: "\r\n", with: "\n")
        if t.count == 1, let c = t.first { return Symbols.name(of: c) }
        if Symbols.isAllSymbols(t) { return Symbols.spelled(t.filter { !$0.isWhitespace }) }
        let flat = t.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        return Symbols.process(flat, level: symbolLevel ?? config.speech.symbolLevel)
    }

    /// Spell text character by character (NVDA: speakSpelling).
    public static func speakSpelling(_ text: String) {
        guard !text.isEmpty else { enqueue("blank"); return }
        // With capitals raised, each character is its own utterance, so each capital can have its pitch.
        if config.speech.capitalPitch > 0, text.contains(where: \.isUppercase) {
            for c in text.prefix(500) { enqueue(Symbols.name(of: c)) }
            return
        }
        enqueue(Symbols.spelled(String(text.prefix(500))))
    }

    // MARK: - Objects

    /// The pieces of one announcement ("Settings", "submenu", "3 of 9") as one line to speak. The Mac family joins them
    /// with commas, as VoiceOver does; the Windows family with spaces, as NVDA does, so the voice doesn't pause at
    /// each piece (a tester in the Windows style, 20 Oct 2026: the pauses after "Settings" and "submenu" in menus).
    public static func joined(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: config.general.windowsKeys ? " " : ", ")
    }

    /// Speak an object the way NVDA does on focus: name, role, value, states, description, shortcut, position; then its text if it has any.
    private static var passwordHintSaid = Date.distantPast
    private static var lastFocusWords = ""
    private static var lastFocusWordsAt = Date.distantPast
    public static func speakObject(_ obj: TurnOverObject, reason: OutputReason) {
        var parts = objectPropertiesSpeech(obj, reason: reason)
        // A password field while coexisting: the keyboard is the Mac's alone there (secure input), so the VoiceOver
        // keys are off and TurnOver echoes a count; said once an hour (a code review on 17 Oct 2026).
        if reason == .focus, obj.role == .passwordEdit, Coexist.on, Date().timeIntervalSince(passwordHintSaid) > 3600 {
            passwordHintSaid = Date()
            parts.append("TurnOver counts the characters as you type; Tab moves on")
        }
        // A table or list that takes focus on macOS keeps its selection inside it: say the selected row too,
        // as NVDA's focus on a list item does on Windows ("Internet accounts, table, GMail, IMAP, 3 of 3").
        if reason == .focus || reason == .query, [.table, .list, .treeView, .outline, .browser].contains(obj.role) {
            if let sel = obj.element.elements(kAXSelectedRowsAttribute).first ?? obj.element.elements(kAXSelectedChildrenAttribute).first {
                let row = ObjectFactory.make(sel)
                parts.append(contentsOf: objectPropertiesSpeech(row, reason: .focus))
                TurnOverObject.noteSelectionSpoken(sel)   // the selection event that follows is the same news
            } else {
                var count: CFIndex = 0
                AXUIElementGetAttributeValueCount(obj.element, kAXRowsAttribute as CFString, &count)
                // A plain list holds its items as children; a table or outline with no rows is empty (its children
                // are its columns: Finder's empty folder was "5 items", 21 Oct 2026).
                if count == 0, !["AXOutline", "AXTable"].contains(obj.element.role) { AXUIElementGetAttributeValueCount(obj.element, kAXChildrenAttribute as CFString, &count) }
                parts.append(count == 0 ? "empty" : "\(count) item\(count == 1 ? "" : "s"), nothing selected")
            }
        }
        let reportText = reason != .focusEntered && reason != .mouse && obj.hasNavigableText
        if reportText, obj.role == .passwordEdit {
            parts.append(secureCount(obj))
        } else if reportText, let info = try? obj.makeTextInfo(.selection) {
            if !info.isCollapsed {
                parts.append("selected " + processed(info.text))
            } else {
                let line = (try? obj.makeTextInfo(.caret)) ?? info
                line.expand(.line)
                let text = line.text
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let p = obj.placeholder, !p.isEmpty, p != obj.name { parts.append(p) }
                // An empty box whose value is elsewhere (a spinner's number, on the AXIncrementor around it: Libation)
                // says the value, not "blank" (parts request #5, 14 Oct 2026).
                if text.isEmpty, let v = obj.value, !v.isEmpty { parts.append(v) } else { parts.append(textInfoSpeech(line, unit: .line, reason: .caret)) }
            }
        } else if reportText, let v = obj.element.string(kAXValueAttribute), !v.isEmpty {
            // No caret to read from (LibreOffice Calc's cells report the selection at NSNotFound): the value itself.
            // Calc's cells were "A1, edit" with 12 in them (parts sweep, 14 Oct 2026).
            parts.append(v.count > 500 ? String(v.prefix(500)) : v)
        }
        let words = joined(parts)
        // The same focus reported twice within half a second says it once (Excel after Return and Up: "12, A1" twice;
        // the stress test of 17 Oct 2026). Compared once the words are whole: compared on the object alone, two
        // "list view" outlines in a row (Finder opening a folder) looked the same with different rows selected.
        if reason == .focus {
            if words == lastFocusWords, Date().timeIntervalSince(lastFocusWordsAt) < 0.5 { Log.io("focus: the same words again within 0.5 s; not repeated"); return }
            lastFocusWords = words; lastFocusWordsAt = Date()
        }
        if reason == .focus, let until = dropForFocusUntil {
            dropForFocusUntil = nil
            if Date() < until, !words.isEmpty { cancel(); Log.io("focus moved on at once: the speech for the focus before it dropped") }
        }
        enqueue(words)
        if reason == .focus { Hints.schedule(Hints.forObject(obj)) }
    }

    /// NVDA: speakObjectProperties with reason CHANGE — only the named property.
    public static func speakObjectProperty(_ obj: TurnOverObject, value: Bool = false, name: Bool = false, description: Bool = false, states: Bool = false) {
        var parts: [String] = []
        if name { parts.append(obj.name) }
        if value, !Role.silentValues.contains(obj.role), let v = obj.value { parts.append(v) }
        if states { parts.append(contentsOf: statesSpeech(role: obj.role, states: obj.states, reason: .change)) }
        if description, let d = obj.description { parts.append(d) }
        enqueue(joined(parts))
    }

    /// A check box or radio button just pressed: "checked", "not checked" or "half checked", read fresh.
    private static var lastCheckSpoken: (AXUIElement, Date)?
    public static func speakCheckState(of element: AXUIElement) {
        if let (e, t) = lastCheckSpoken, CFEqual(e, element), Date().timeIntervalSince(t) < 0.3 { return }   // event and press both
        lastCheckSpoken = (element, Date())
        let fresh = ObjectFactory.make(element)
        let s = fresh.states
        enqueue(fresh.role == .switchControl ? (s.contains(.on) ? "on" : "off")
                : s.contains(.checked) ? "checked" : s.contains(.halfChecked) ? "half checked" : fresh.role == .toggleButton ? (s.contains(.pressed) ? "pressed" : "not pressed") : "not checked")
    }

    /// NVDA: getObjectPropertiesSpeech / getPropertiesSpeech, in NVDA's order.
    /// When a menu bar item was last announced: its menu opening a moment later is not announced again.
    public static var lastMenuBarItemSpoken = Date.distantPast

    public static func objectPropertiesSpeech(_ obj: TurnOverObject, reason: OutputReason) -> [String] {
        // A progress bar read is watched from now on, its climb said (ProgressWatch).
        if obj.role == .progressBar, Thread.isMainThread { MainActor.assumeIsolated { ProgressWatch.watch(obj) } }
        var parts: [String] = []
        let role = obj.role
        // A web list's number or bullet: just itself ("1", not "text, 1").
        if obj.axRole == "AXListMarker" { return [obj.value ?? obj.name].filter { !$0.isEmpty } }
        let name = Self.withoutIconGlyphs(obj.name)
        if !name.isEmpty { parts.append(name) }
        // A scroll area the keyboard itself lands on (Shortcuts' editor, Tab from the list, 10 Oct 2026): what it holds,
        // then "scroll area", as VoiceOver says it. Silence there left the user nowhere. Passing through, still nothing.
        if role == .scrollPane, name.isEmpty, reason == .focus, obj.element.elements(kAXChildrenAttribute).contains(where: { $0.role != "AXScrollBar" }) {
            let held = obj.contentText(limit: 2)
            return [held.isEmpty ? "scroll area" : "\(held), scroll area"]
        }
        if (role == .groupBox || role == .tabControl || role == .scrollPane || role == .splitPane), name.isEmpty, reason == .focus || reason == .focusEntered { return [] }   // focus passing through nameless containers
        if role == .menu, reason == .focus { return [] }   // the menu was announced when it opened
        if obj.axRole == "AXMenuBarItem" {
            // "View menu, 5 of 10" (not "View, subMenu"); the menu that opens under it then says nothing more.
            lastMenuBarItemSpoken = Date()
            var out = [name.isEmpty ? "menu" : "\(name) menu"]
            if config.presentation.reportObjectPositionInformation, let p = obj.positionInfo, let i = p.index, let n = p.count, i > 0, i <= n { out.append("\(i) of \(n)") }
            return out
        }
        // A web page (Safari, a Mail message) is not announced as "document": where you are in it says it (NVDA says
        // "document" coming back to a page; the owner did not want it, 3 Oct 2026).
        let silentWebPage = obj.axRole == "AXWebArea" && (reason == .focus || reason == .focusEntered)
        // Text is never announced as "text": iPhone apps on the Mac (Books, Audible) name their texts by description,
        // and "Home, text, selected" said a word too many (Day 5, 11 Oct 2026).
        if !silentWebPage, role != .staticText, !(reason == .focus || reason == .focusEntered) || !Role.silentOnFocus.contains(role) {
            // Never "unknown": it tells nothing ("Download details, unknown, 722 MB of 787 MB" in an installer,
            // 18 Oct 2026).
            let roleWords = obj.roleText ?? role.displayString
            if roleWords.lowercased() != "unknown" { parts.append(roleWords) }
        }
        let reportsText = obj.hasNavigableText && reason != .focusEntered && reason != .mouse
        // A value that only repeats the name is not said twice (Excel's headings give both, 10 Oct 2026).
        if !reportsText, reason != .focusEntered, !Role.silentValues.contains(role), let v = obj.value, !v.isEmpty, v != name { parts.append(v) }
        parts.append(contentsOf: statesSpeech(role: role, states: obj.states, reason: reason))
        if config.presentation.reportObjectDescriptions, let d = obj.description, !d.isEmpty, d != name { parts.append(d) }
        if config.presentation.reportKeyboardShortcuts, reason != .focusEntered || role == .list, let k = obj.keyboardShortcut, !k.isEmpty { parts.append(k) }
        if config.presentation.reportObjectPositionInformation, let p = obj.positionInfo {
            if let i = p.index, let n = p.count, i > 0, i <= n { parts.append("\(i) of \(n)") }
            if reason != .focusEntered, let l = p.level { parts.append("level \(l)") }
        }
        // A check box whose label is a paragraph (an agreement): what it is and whether it is checked first, so the
        // state is not lost at the end of a long sentence.
        if [.checkBox, .radioButton, .toggleButton, .switchControl].contains(role), name.count > 80, parts.first == name {
            return Array(parts.dropFirst()) + [name]
        }
        return parts
    }

    // MARK: - Text

    /// Speak a range (NVDA: speakTextInfo). A character unit is spelled; a blank range says "blank".
    public static func speakTextInfo(_ info: TextInfo, unit: TextUnit? = nil, reason: OutputReason, onStart: (@Sendable () -> Void)? = nil, completion: (@Sendable (Bool) -> Void)? = nil) {
        lastRaw = info.text; rawPending = true
        let language = unit == .character ? Languages.forCharacter(info.text, marked: info.language(at: info.start)) : info.language()
        let speech = textInfoSpeech(info, unit: unit, reason: reason)
        // A character in another language: "spelling error" in the interface's voice, the letter in its own (the
        // Arabic voice said the English words; a tester, 12 Oct 2026).
        if unit == .character, language != nil, !characterPrefix.isEmpty, speech.hasPrefix(characterPrefix + " ") {
            enqueue(characterPrefix, language: nil)
            enqueue(String(speech.dropFirst(characterPrefix.count + 1)), language: language, onStart: onStart, completion: completion)
            return
        }
        enqueue(speech, language: language, onStart: onStart, completion: completion)
    }
    /// What the last character's speech began with (its formatting), so it can be said apart from the letter.
    private static var sayAllTones: [() -> Void] = []
    /// The element tones of the say-all chunk just made (textInfoSpeech, reason sayAll), for its onStart.
    public static func takeSayAllTones() -> [() -> Void] { let t = sayAllTones; sayAllTones.removeAll(); return t }
    private static var characterPrefix = ""
    /// Set while one utterance is said in pieces by language, so the pieces aren't split again.
    private static var splittingLanguages = false
    /// Whether the last character read was in a misspelled word: by character, "spelling error" is said on entering
    /// one and "out of spelling error" on leaving, not on every letter (as NVDA and VoiceOver;).
    private static var inMisspelling = false

    public static func textInfoSpeech(_ info: TextInfo, unit: TextUnit?, reason: OutputReason) -> String {
        var text = info.text
        var prefix: [String] = []
        if unit != .character {
            let fields = info.controlFieldSpeech()
            prefix.append(contentsOf: fields.prefix)
            if let t = fields.text { text = t }
            // Say all queues three chunks ahead: its tones sound when the chunk starts, not when it is queued (they
            // sounded two paragraphs early: code review, 16 Oct 2026). SayAll takes them with `takeSayAllTones`.
            if reason == .sayAll { sayAllTones.append(contentsOf: info.pendingTones) } else { info.pendingTones.forEach { $0() } }
            info.pendingTones.removeAll()
        }
        let format = reason != .sayAll ? info.formatField() : nil
        var wasInMisspelling = false
        if unit == .character, reason != .sayAll {
            let now = format?.misspelled ?? false
            wasInMisspelling = inMisspelling
            if !now, wasInMisspelling, config.documentFormatting.spellingErrors == .speech { prefix.append("out of spelling error") }
            inMisspelling = now
        } else if reason != .sayAll {
            inMisspelling = false
        }
        if let f = format, !f.isEmpty {
            // NVDA reports formatting changes as the caret moves when configured; by default only spelling errors and headings.
            if f.misspelled, unit != .character || !wasInMisspelling {
                switch config.documentFormatting.spellingErrors {
                case .speech: prefix.append("spelling error")
                case .tone: Tones.spellingError()
                case .off: break
                }
            }
            if config.documentFormatting.reportFontName, let n = f.fontName { prefix.append(n) }
            if config.documentFormatting.reportFontSize, let s = f.fontSize { prefix.append("\(s) point") }
            if config.documentFormatting.reportFontAttributes {
                if f.bold { prefix.append("bold") }; if f.italic { prefix.append("italic") }; if f.underline { prefix.append("underlined") }
            }
        }
        if unit == .character {
            characterPrefix = prefix.joined(separator: " ")
            text = text.replacingOccurrences(of: "\r\n", with: "\n")
            // One character that stands for more (an attachment: Mail's recipient token) is said whole.
            if text.count > 1 { return (prefix + [text]).joined(separator: " ") }
            return (prefix + [text.isEmpty ? "blank" : Symbols.spelled(text)]).joined(separator: " ")
        }
        // A misspelled word inside the line, not only at its start: "spelling error" before it, as NVDA says it.
        if reason != .sayAll, unit == .line || unit == .paragraph || unit == .sentence, config.documentFormatting.spellingErrors != .off {
            let ranges = info.misspelledRanges()
            if !ranges.isEmpty {
                // By offset, last to first ("cat" after "concatenate" was marked in the wrong place: code review, 16 Oct 2026).
                let ns = text as NSString
                for r in ranges.sorted(by: { $0.location > $1.location }) where r.location + r.length <= ns.length && !(r.location == 0 && prefix.contains("spelling error")) {
                    if config.documentFormatting.spellingErrors == .speech { text = ns.replacingCharacters(in: NSRange(location: r.location, length: 0), with: ui("spelling error") + " ") } else { Tones.spellingError() }
                }
            } else {
                var from = text.startIndex
                for w in info.misspelledWords() where !(prefix.contains("spelling error") && text.hasPrefix(w)) {
                    guard let r = text.range(of: w, range: from..<text.endIndex) else { continue }
                    if config.documentFormatting.spellingErrors == .speech { text.replaceSubrange(r, with: ui("spelling error") + " " + w); from = text.index(r.lowerBound, offsetBy: ui("spelling error").count + 1 + w.count) } else { Tones.spellingError(); from = r.upperBound }
                }
            }
        }
        // Highlights and comments on the line, after it ("light orange highlight: the words"): Pages, 18 Oct 2026.
        if reason != .sayAll, unit == .line || unit == .paragraph || unit == .sentence {
            // Not the spelling and grammar marks: Word announces those itself, by its setting (tone, words or nothing),
            // and they were read twice: the line, then "Grammatical error: after" (18 Oct 2026).
            let marks = info.annotations().filter { m in
                let l = m.label.lowercased()
                return !(l.contains("grammatical") || l.contains("grammar") || l.contains("spelling") || l.contains("misspell"))
            }
            // A comment says its own words ("Comment: Check this by A. Reviewer") and what it is on; a highlight its colour
            // and its words; a bare highlight under a comment is the comment's.
            func isComment(_ l: String) -> Bool { l.lowercased().contains("comment") }
            let hasComment = marks.contains { isComment($0.label) }
            let words = marks.compactMap { m -> String? in
                if isComment(m.label) {
                    // "light orange highlight, Comment: Check this by A. Reviewer": the comment, without the colour.
                    let l = m.label.range(of: "comment", options: .caseInsensitive).map { String(m.label[$0.lowerBound...]) } ?? m.label
                    return m.text.isEmpty ? l : "\(l), on \(m.text)"
                }
                if hasComment, m.text.isEmpty { return nil }
                return m.text.isEmpty ? m.label : "\(m.label): \(m.text)"
            }
            if !words.isEmpty { text = text.trimmingCharacters(in: .whitespaces) + words.map { ", " + $0 }.joined() }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // NVDA: a line of only whitespace is "blank"; a lone space or tab is named.
            // (Not a lone non-breaking space: Mail fills each empty line of a message with one, and it was read as
            // "non breaking space" on every blank line, 5 Oct 2026.)
            if text.count == 1, let c = text.first, c != "\r", c != "\n", c != "\u{2029}", c != "\u{a0}" { return (prefix + [Symbols.name(of: c)]).joined(separator: " ") }
            return (prefix + ["blank"]).joined(separator: " ")
        }
        // VoiceOver's order: the words, then what they are, innermost first ("AppleVis, heading level 1").
        if config.documentFormatting.rolesAfterText, !prefix.isEmpty {
            return ([processed(trimmed)] + [ui(prefix.reversed().joined(separator: ", "))]).filter { !$0.isEmpty }.joined(separator: ", ")
        }
        return ([ui(prefix.joined(separator: " "))] + [processed(trimmed)]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: - Typing

    /// NVDA: speakTypedCharacters. Characters are echoed per the setting; a word is echoed when a non-word character ends it.
    /// True while what is queued is only the echo of typing: a typed key then does not cut it short
    /// (fast typing lost the "period" after "fast."). Any other speech clears it.
    public private(set) static var echoOnly = false
    /// The echo of typing is spoken as private: the log keeps only its length and the history a feedback report
    /// carries leaves it out, so what was typed never reaches a report (a contributor reading the code, 20 Oct 2026).
    private static func echo(_ text: String) { asPrivate { echoSpeech(text) } }
    private static func echoSpeech(_ text: String) {
        let wasEcho = echoOnly || !(player?.isBusy ?? false)
        // A typed letter or short word in another script (Arabic in Safari, Brave, TextEdit) in that script's voice:
        // too short for the language guess, so silent under an English voice (a tester, ; wishlist 7).
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        if let first = letters.first, letters.allSatisfy({ $0.value > 0x024F }),
           let lang = Languages.forCharacter(String(Character(first)), marked: nil) {
            enqueue(text, language: lang)
            echoOnly = wasEcho
            return
        }
        enqueue(text)
        echoOnly = wasEcho
    }

    /// `wordBefore`: the word before the caret as the field now holds it. After Backspace the letters typed no longer
    /// match the field ("cat", Backspace, space said nothing, 4 Oct 2026); the field's own text is the truth.
    /// Typing goes into a password field that isn't TurnOver's focus: browse mode sent the keys to the field at the
    /// reading position while the app reported its focus elsewhere. Kindle's Amazon password was echoed word by word
    /// and written to the log that way (18 Oct 2026): the field typed into decides, not the focus.
    public static var typingIntoSecretField: Bool {
        guard let d = API.focusTreeInterceptor, d.passThrough, let e = d.editableAtPosition() else { return false }
        return Role.from(axRole: e.role, subrole: e.string(kAXSubroleAttribute)) == .passwordEdit
    }

    public static func speakTypedCharacter(_ ch: Character, inEditable editable: Bool, wordBefore: (() -> String?)? = nil) {
        if typingIntoSecretField { typedWord.removeAll(); backspacedSinceWord = false; return }
        if ch.isLetter || ch.isNumber || ch == "'" || ch == "’" {
            typedWord.append(ch)
        } else if ch == "\u{8}" {
            if !typedWord.isEmpty { typedWord.removeLast() }
            backspacedSinceWord = true
            return
        } else if let word = ((!typedWord.isEmpty || backspacedSinceWord) ? wordBefore?() : nil).flatMap({ $0.isEmpty ? nil : $0 })
                    ?? (typedWord.isEmpty ? nil : String(typedWord)) {
            // (Only after typing or deleting since the last word: a second space would otherwise say the word again.)
            typedWord.removeAll()
            backspacedSinceWord = false
            Log.io("typed word (\(word.count) characters)")
            let mode = config.keyboard.speakTypedWords
            if mode == .always || (mode == .editControls && editable) {
                // The word and the character that ended it in one breath ("fast period"): the next key cuts speech
                // short, and two separate echoes lost the second.
                let chars = config.keyboard.speakTypedCharacters
                if ch > " ", chars == .always || (chars == .editControls && editable) || (!ch.isLetter && !ch.isNumber) {
                    echo(processed(word) + " " + Symbols.name(of: ch)); return
                }
                echo(processed(word))
            }
        }
        let mode = config.keyboard.speakTypedCharacters
        guard ch >= " " else { return }
        if mode == .always || (mode == .editControls && editable) { echo(Symbols.name(of: ch)); return }
        // Typed words only: a symbol is never part of a word, so it would never be heard. Say it as it is typed
        // (` grave, § section, / slash), as a word is said when it ends.
        let words = config.keyboard.speakTypedWords
        // (Not an apostrophe: it is part of a word, and "I've" was heard as "apostrophe", then "I've".)
        if ch != " ", ch != "'", ch != "’", !ch.isLetter, !ch.isNumber, words == .always || (words == .editControls && editable) {
            echo(Symbols.name(of: ch))
        }
    }

    public static func clearTypedWordBuffer() { typedWord.removeAll(); backspacedSinceWord = false }
    /// Something before the caret was deleted: the next word end reads the word from the text.
    public static func noteBackspace() { typedWord.removeAll(); backspacedSinceWord = true }
    private static var backspacedSinceWord = false

    /// A key typed into a password field (NVDA: "star"): it is never spoken or kept as a word, and never logged.
    public static func speakSecureCharacter() {
        typedWord.removeAll()   // SecureEcho gives the feedback, from the field's length
    }

    /// How many characters a password field holds (its value is bullets, or nothing, never the password).
    /// Safari gives a password field's value as nothing at all, so its length is read wherever it shows: the count
    /// if given, the value (bullets in a Mac field), the end of the selection or caret, the visible range.
    public static func secureCount(_ obj: TurnOverObject) -> String {
        let n = SecureEcho.length(obj.element)
        return n == 0 ? "blank" : n == 1 ? "1 character" : "\(n) characters"
    }

    /// Return and Tab end a word as a space does: say it (NVDA), then start afresh.
    public static func finishTypedWord() {
        guard !typedWord.isEmpty else { return }
        let word = String(typedWord)
        typedWord.removeAll()
        Log.io("typed word (\(word.count) characters)")
        let mode = config.keyboard.speakTypedWords
        if mode != .off { echo(processed(word)) }
    }

    // MARK: - Selection

    /// A selection changed: say only the difference. What is in the new selection and not the old was selected; what
    /// was in the old and not the new was unselected. Each is at most two pieces (before and after the overlap).
    /// `generalize`: a big jump (Select All, a whole line) is said as the selection itself, not the pieces.
    public static func speakSelectionChange(old: TextInfo, new: TextInfo, generalize: Bool = false) {
        if old.isCollapsed && new.isCollapsed { return }
        // A password field: never its text (Safari gives none: "selected" alone was said), only how much.
        if new.obj.role == .passwordEdit { return }   // AutoFill's selection steps were read 10 times over
        typealias Span = (start: Int, end: Int)
        let before: Span? = old.isCollapsed ? nil : (old.start, old.end)
        let after: Span? = new.isCollapsed ? nil : (new.start, new.end)
        /// The parts of `a` outside `b`, in order.
        func outside(_ a: Span?, _ b: Span?) -> [Span] {
            guard let a else { return [] }
            guard let b, b.start < a.end, b.end > a.start else { return [a] }
            var parts: [Span] = []
            if a.start < b.start { parts.append((a.start, b.start)) }
            if b.end < a.end { parts.append((b.end, a.end)) }
            return parts
        }
        let added = outside(after, before).map { new.textRange($0.start, $0.end) }
        let removed = outside(before, after).map { old.textRange($0.start, $0.end) }
        func spoken(_ t: String) -> String { t.count == 1 ? Symbols.name(of: t.first!) : (t.count > 1000 ? "\(t.count) characters" : processed(t)) }
        if generalize {
            if !added.isEmpty { enqueue("selected " + spoken(new.text)) }
            if !removed.isEmpty { enqueue(new.isCollapsed ? "selection removed" : "now selected " + spoken(new.text)) }
            return
        }
        for t in added where !t.isEmpty { enqueue("selected " + spoken(t)) }
        for t in removed where !t.isEmpty { enqueue(spoken(t) + " unselected") }
    }
}

extension Speech {
    /// VoiceOver's VO-Shift-C: the last thing spoken, as written, to the clipboard.
    public static func copyLastSpoken() {
        let t = lastRaw.isEmpty ? lastSpoken : lastRaw
        guard !t.isEmpty else { speakMessage("nothing spoken yet", remember: false); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
        Log.io("copied the last spoken: \(Log.words(String(t.prefix(80))))")
        speakMessage("last phrase copied to clipboard", remember: false)
    }
}
