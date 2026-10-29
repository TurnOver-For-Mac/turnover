// SPDX-License-Identifier: GPL-3.0-or-later
// Terminal (NVDA: the Windows console support: new output read as it arrives, typing not
// echoed twice, a review cursor for what has scrolled by).
//
// Measured 2 Oct 2026, Terminal on macOS 27: the window holds one AXTextArea, subrole
// AXTerminalTextArea, description "shell", whose AXValue is the whole scrollback padded with
// empty rows to the window's height. AXSelectedTextRange is the cursor. AXLineForIndex,
// AXRangeForLine and AXStringForRange work. Output arrives as AXValueChanged with
// AXSelectedTextChanged on the text area, batched (a command's echo and its first output come
// together; a later line about every second for `sleep 1`). The window title changes with the
// running command.
//
// Only what follows the start of the cursor's line is ever re-read, so a long scrollback costs
// nothing.
import Foundation
import ApplicationServices

final class TerminalAppModule: AppModule {
    static let bundleID = "com.apple.Terminal"
    override func objectClass(for element: AXUIElement, role: Role, subrole: String?) -> TurnOverObject.Type? {
        // (7 Oct 2026: Terminal no longer gives the subrole; the text area is still described as "shell".)
        if subrole == "AXTerminalTextArea" { return TerminalText.self }
        return element.role == "AXTextArea" && element.string(kAXDescriptionAttribute) == "shell" ? TerminalText.self : nil
    }
}

final class TerminalText: TurnOverObject {
    /// What TurnOver knows of one terminal (tab or window), kept across the fresh objects made for each event.
    final class State {
        var anchor = -1                 // where the cursor's line started when last read
        var anchorText = ""             // that line as it was
        var typed = ""                  // keys typed since then (the shell echoes them; they are not news)
        var enterAt = Date.distantPast  // the last Return: the line it finished was already heard
        var review: Int?                // the review cursor's line
        var pending = false
        var prompt = ""                 // the shell's prompt line, as last seen with the shell waiting
        var lastOutput: (String, Date)? // the output last read, and when
        var held = false                // output arrived while a menu or sheet was in the way: read on the way back
    }
    static var states: [Int: State] = [:]
    var state: State {
        let k = Int(CFHash(element))
        if let s = Self.states[k] { return s }
        let s = State(); Self.states[k] = s; return s
    }

    override var role: Role { .editableText }
    override var roleText: String? { "terminal" }
    override var name: String { "" }

    // MARK: Text helpers

    private func int(_ attr: String) -> Int? { (element.attr(attr) as? NSNumber)?.intValue }
    private var cursor: Int? {
        guard let v = element.attr(kAXSelectedTextRangeAttribute) else { return nil }
        guard let r = cfRange(v), r.location >= 0, r.location != Int.max else { return nil }
        return r.location
    }
    private func string(_ location: Int, _ length: Int) -> String {
        var r = CFRange(location: location, length: max(0, length))
        guard let v = AXValueCreate(.cfRange, &r), let s = element.param(kAXStringForRangeParameterizedAttribute, v) as? String else { return "" }
        return s
    }
    /// Shell AX positions are UTF-16, while spoken characters are extended graphemes. The old one-unit reads
    /// split supplementary and combining characters (28 Oct 2026, #180). Never fetch AXValue scrollback to repair
    /// an unavailable slice: keep key delivery and leave the unproven character unspoken.
    private func character(at offset: Int) -> String? {
        guard let length = int(kAXNumberOfCharactersAttribute), length >= 0, offset >= 0, offset <= length else { return nil }
        if offset == length { return "" }
        guard let (start, end) = CharacterBoundaries.offsets(at: offset, length: length, read: { start, end in
            self.string(start, end - start)
        }) else { return nil }
        let text = string(start, end - start)
        guard text.utf16.count == end - start, text.count == 1 else { return nil }
        return text
    }

    private func lineIndex(at i: Int) -> Int? {
        (element.param(kAXLineForIndexParameterizedAttribute, NSNumber(value: i)) as? NSNumber)?.intValue
    }
    private func lineRange(_ line: Int) -> CFRange? {
        guard let v = element.param(kAXRangeForLineParameterizedAttribute, NSNumber(value: line)) else { return nil }
        var r = CFRange(); axValue(v, .cfRange, &r); return r
    }
    private func lineText(_ line: Int) -> String? {
        guard let r = lineRange(line) else { return nil }
        return string(r.location, r.length).trimmingCharacters(in: .newlines)
    }
    /// The line the cursor is on: (start, text).
    private func cursorLine() -> (Int, String)? {
        guard let c = cursor, let l = lineIndex(at: c), let r = lineRange(l) else { return nil }
        return (r.location, string(r.location, r.length).trimmingCharacters(in: .newlines))
    }
    /// The last line with anything on it (below it is the window's empty padding).
    private func lastContentLine() -> Int {
        guard let n = int(kAXNumberOfCharactersAttribute), n > 0, var l = lineIndex(at: n - 1) else { return 0 }
        while l > 0, (lineText(l) ?? "").trimmingCharacters(in: .whitespaces).isEmpty { l -= 1 }
        return l
    }

    // MARK: Events

    /// A shell prompt not yet learned (TurnOver started with the shell already open): "user@host folder %" — up to the
    /// first " % ", " $ " or " # " after the "@".
    static func guessPrompt(_ line: String) -> String? {
        guard let at = line.firstIndex(of: "@") else { return nil }
        let tail = line[at...]
        for mark in [" % ", " $ ", " # "] {
            if let r = tail.range(of: mark) { return String(line[..<r.lowerBound]) + mark.trimmingCharacters(in: .whitespaces) }
        }
        for mark in [" %", " $", " #"] where line.hasSuffix(mark) { return line }
        return nil
    }

    /// What differs between two prompts: what is left when their common start and common end are taken away.
    static func changedPart(from old: String, to new: String) -> String {
        let o = old.trimmingCharacters(in: .whitespaces), n = new.trimmingCharacters(in: .whitespaces)
        if o == n { return "" }
        let head = o.commonPrefix(with: n)
        let oRest = String(o.dropFirst(head.count)), nRest = String(n.dropFirst(head.count))
        let tail = String(String(oRest.reversed()).commonPrefix(with: String(nRest.reversed())).reversed())
        let middle = String(nRest.dropLast(tail.count)).trimmingCharacters(in: .whitespaces)
        return middle.isEmpty ? n : middle
    }

    /// A line that is the shell's prompt coming back: the same start (user@host) and the same last character
    /// as the prompt seen before. ("Password:" or a program's question is not, and is read.)
    private func isPrompt(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces), p = state.prompt.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !p.isEmpty, let last = p.last, t.last == last else { return false }
        let head = p.split(separator: " ").first.map(String.init) ?? p
        return t.hasPrefix(head)
    }

    override func event_gainFocus() {
        let s = state
        // Back from a menu or a sheet with output held meanwhile: that first, from where the reading left off.
        if s.held, !AXHandler.shared.isMenuOpen, !AXHandler.modalInFront(pid: pid) {
            s.held = false
            API.setFocusObject(self, ancestors: API.focusAncestors)   // the guard in readNewOutput asks for the focus
            readNewOutput()
            return
        }
        if let (start, text) = cursorLine() { s.anchor = start; s.anchorText = text }
        if let line = cursorLine()?.1, let last = line.trimmingCharacters(in: .whitespaces).last, "%$#>❯➜".contains(last) { s.prompt = line }
        s.review = nil
        let line = cursorLine()?.1.trimmingCharacters(in: .whitespaces) ?? ""
        Speech.speakMessage(["terminal", line].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    override func event_typedCharacter(_ ch: Character) {
        let s = state
        if ch == "\r" || ch == "\n" { s.enterAt = Date(); s.typed = "" }
        else if ch == "\u{8}" { if !s.typed.isEmpty { s.typed.removeLast() } }
        else { s.typed.append(ch) }
        Speech.speakTypedCharacter(ch, inEditable: true)
    }

    override func event_caret() {}   // the cursor moves with every byte of output: the value change speaks

    override func event_valueChange() {
        let s = state
        guard !s.pending else { return }
        s.pending = true
        // Output arrives in bursts: gather a moment's worth and read it once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [self] in
            s.pending = false
            readNewOutput()
        }
    }

    /// Read what changed from the start of the cursor's old line to the end.
    private func readNewOutput() {
        let s = state
        // Not over a menu, or a sheet or dialog that has the keyboard (Terminal's "terminate running processes?"):
        // a command printing every second talked over both (15 Oct 2026). The anchor stays, so what came
        // meanwhile is read on the way back to the terminal.
        if AXHandler.shared.isMenuOpen || TurnOverMenu.shared.isOpen || AXHandler.modalInFront(pid: pid)
            || !(API.focusObject?.isSameElement(as: self) ?? false) {
            Log.io("terminal: new output held (menu, sheet, or the keyboard elsewhere)")
            s.held = true
            return
        }
        guard let total = int(kAXNumberOfCharactersAttribute) else { return }
        // Up and Down recall history: the whole command, as NVDA reads the new line ("python3 hello.py", not the
        // "hello.py" that differs from the command before). A command may span lines (printf with newlines): it runs
        // from the last line that starts with the prompt to the end.
        if ["kb:upArrow", "kb:downArrow"].contains(InputManager.lastKeyIdentifier), Date().timeIntervalSince(InputManager.lastKeyDownAt) < 1 {
            let p = s.prompt.trimmingCharacters(in: .whitespaces)
            var l = lastContentLine(); var parts: [String] = []; var found = false
            while l >= 0, parts.count < 40, let t = lineText(l) {
                // The prompt line: the prompt learned, or any "user@host folder %" (the folder may have changed since).
                if let here = (!p.isEmpty && t.hasPrefix(p)) ? p : Self.guessPrompt(t) {
                    parts.insert(String(t.dropFirst(here.count)), at: 0); found = true; break
                }
                parts.insert(t, at: 0); l -= 1
            }
            // No shell prompt above (a program's own prompt, Python's >>>): just the line the cursor is on.
            if !found { parts = [cursorLine()?.1 ?? parts.last ?? ""] }
            let command = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if let (start, text) = cursorLine() { s.anchor = start; s.anchorText = text } else { s.anchor = total }
            s.review = nil
            Speech.speakText(command.isEmpty ? "blank" : command)
            return
        }
        guard s.anchor >= 0, s.anchor <= total else {
            if let (start, text) = cursorLine() { s.anchor = start; s.anchorText = text }
            return
        }
        let region = string(s.anchor, min(total - s.anchor, 40_000))
        var lines = region.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty, lines.count > 1 { lines.removeLast() }
        guard let first = lines.first else { return }
        let rest = Array(lines.dropFirst())
        var speech: [String] = []


        if rest.isEmpty {
            // The same line: typing echoed by the shell (silent), a completion or a recalled command (the new part).
            let common = first.commonPrefix(with: s.anchorText)
            let added = String(first.dropFirst(common.count)).trimmingCharacters(in: .whitespaces)
            let justTyped = Date().timeIntervalSince(InputManager.lastKeyDownAt) < 0.5 && added.count <= 1
            if !added.isEmpty, !justTyped, added != s.typed.trimmingCharacters(in: .whitespaces), !s.typed.hasSuffix(added) { speech.append(added) }
            if added == s.typed.trimmingCharacters(in: .whitespaces) { s.typed = "" }
        } else {
            // New lines: the finished command line was heard as it was typed; the rest is output.
            // Only the first change after Return finishes the command line; later lines are all output.
            let finishedByEnter = Date().timeIntervalSince(s.enterAt) < 5
            s.enterAt = .distantPast
            if !finishedByEnter {
                let common = first.commonPrefix(with: s.anchorText)
                let added = String(first.dropFirst(common.count)).trimmingCharacters(in: .whitespaces)
                if !added.isEmpty { speech.append(added) }
            }
            var output = rest
            // The prompt coming back after the output: the same prompt is not news; a changed one is (after cd,
            // the folder), and only the part that changed is read: "Audible", not the whole user@host line.
            if let last = output.last, isPrompt(last) {
                output.removeLast()
                let changed = Self.changedPart(from: s.prompt, to: last)
                s.prompt = last
                if !changed.isEmpty { output.append(changed) }
            }
            speech.append(contentsOf: output)
            s.typed = ""
        }

        if let (start, text) = cursorLine() { s.anchor = start; s.anchorText = text } else { s.anchor = total }
        s.review = nil
        let out = speech.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return }
        // The same output again a moment later: iTerm2 moves its cursor after the text arrives, so the next change
        // starts from the old line and finds it again ("second test" twice, parts sweep 15 Oct 2026).
        Log.io("terminal: read \(out.count) characters (\(rest.isEmpty ? "same line" : "\(rest.count) new lines"), anchor \(s.anchor))")
        if let (last, at) = s.lastOutput, last == out, Date().timeIntervalSince(at) < 1.5 { return }
        s.lastOutput = (out, Date())
        Speech.speakNews(out.count > 5000 ? String(out.prefix(5000)) + " … and more" : out)
    }

    // MARK: Review (NVDA's review cursor; VoiceOver's VO+Up and VO+Down in text)

    override func initOverlay() {
        super.initOverlay()
        let cat = "Terminal"
        // Return: the command goes; the word typed last is spoken (typed words), and what follows is output.
        script("terminal_enter", "Sends the command line to the shell", gestures: ["kb:enter", "kb:numpadEnter"], category: cat) { [weak self] g in
            guard let self else { g.send(); return }
            let s = self.state
            s.enterAt = Date()
            s.typed = ""
            Speech.speakTypedCharacter("\n", inEditable: true)
            g.send()
        }
        script("terminal_reviewPrevious", "Previous line of output; reads the previous line of the terminal, without disturbing the shell", gestures: ["kb:turnover+upArrow"], category: cat) { [weak self] _ in self?.review(-1) }
        script("terminal_reviewNext", "Next line of output; reads the next line of the terminal", gestures: ["kb:turnover+downArrow"], category: cat) { [weak self] _ in self?.review(1) }
        script("terminal_reviewTop", "Reads the first line of the terminal's history", gestures: ["kb:turnover+home"], category: cat) { [weak self] _ in self?.reviewTo(top: true) }
        script("terminal_reviewBottom", "Reads the last line of output", gestures: ["kb:turnover+end"], category: cat) { [weak self] _ in self?.reviewTo(top: false) }
        script("terminal_reviewCurrent", "Reads the line the review cursor is on; the cursor's line if it has not moved", gestures: ["kb:turnover+l"], category: cat) { [weak self] _ in self?.review(0) }
        // Editing keys, as in any edit field: what was deleted is said, and where the cursor went.
        script("terminal_backspace", "Deletes the character before the cursor and says it", gestures: ["kb:backspace"], category: cat) { [weak self] g in
            guard let self, let c = self.cursor, !self.atInputStart(c) else { Tones.edge(); g.send(); return }
            let ch = self.character(at: c - 1)
            g.send()
            if !self.state.typed.isEmpty { self.state.typed.removeLast() }
            Speech.clearTypedWordBuffer()
            if let ch { self.sayCharacter(ch) }
        }
        script("terminal_deleteForward", "Deletes the character at the cursor and says it", gestures: ["kb:delete"], category: cat) { [weak self] g in
            guard let self, let c = self.cursor else { g.send(); return }
            let ch = self.character(at: c)
            g.send()
            guard let ch else { return }
            if ch.isEmpty || ch == "\n" || self.inputAfter(c).isEmpty { Tones.edge() } else { self.sayCharacter(ch) }
        }
        script("terminal_deleteWord", "Deletes the word before the cursor and says it", gestures: ["kb:option+backspace", "kb:control+w"], category: cat) { [weak self] g in
            guard let self, let c = self.cursor, !self.atInputStart(c) else { Tones.edge(); g.send(); return }
            let before = self.inputBefore(c)
            let trimmed = before.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            let word = trimmed.split(whereSeparator: { $0 == " " || $0 == "/" }).last.map(String.init) ?? trimmed
            g.send()
            Speech.speakText(word.isEmpty ? "space" : word)
        }
        script("terminal_clearLine", "Clears what has been typed on the command line", gestures: ["kb:control+u"], category: cat) { [weak self] g in
            g.send()
            self?.state.typed = ""
            Speech.speakMessage("line cleared", remember: false)
        }
        for (key, forward) in [("option+leftArrow", false), ("option+rightArrow", true)] {
            script("terminal_word_\(forward ? "next" : "previous")", "Moves the shell's cursor by a word and reads it", gestures: ["kb:\(key)"], category: cat) { [weak self] g in
                g.send()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    guard let self, let c = self.cursor else { return }
                    let after = self.inputAfter(c)
                    let word = after.split(whereSeparator: { $0 == " " }).first.map(String.init) ?? ""
                    if word.isEmpty { Tones.edge(); Speech.speakText("blank") } else { Speech.speakText(word) }
                }
            }
        }
        for (key, start) in [("control+a", true), ("control+e", false)] {
            script("terminal_line\(start ? "Start" : "End")", start ? "Moves to the start of the command line and reads it" : "Moves to the end of the command line", gestures: ["kb:\(key)"], category: cat) { [weak self] g in
                g.send()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    guard let self, let c = self.cursor else { return }
                    let rest = self.inputAfter(c)
                    Speech.speakText(start ? (rest.isEmpty ? "blank" : rest) : "end")
                }
            }
        }
        // Left and Right go to the shell; then the character under the cursor is read, as in an edit field.
        // At the start of what was typed (Left) or past its end (Right) the shell cannot move: a bump, as an edit
        // field gives, and the key is kept from the shell.
        for key in ["leftArrow", "rightArrow"] {
            script("terminal_\(key)", "Moves the shell's cursor and reads the character there", gestures: ["kb:\(key)"], category: cat) { [weak self] g in
                if let self, let c = self.cursor, key == "leftArrow" ? self.atInputStart(c) : self.atInputEnd(c) {
                    Tones.edge()
                    return
                }
                g.send()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    guard let self, let c = self.cursor else { return }
                    guard let ch = self.character(at: c) else { return }
                    Speech.speakText(ch.isEmpty || ch == "\n" ? "blank" : ch, symbolLevel: .all)
                }
            }
        }
    }

    // MARK: The command line being typed

    /// The cursor's line from its start to the cursor, and from the cursor to the end.
    private func inputBefore(_ c: Int) -> String {
        guard let l = lineIndex(at: c), let r = lineRange(l) else { return "" }
        let before = string(r.location, c - r.location)
        // Without the prompt, when the line starts with it.
        let p = state.prompt.trimmingCharacters(in: .whitespaces)
        if !p.isEmpty, before.hasPrefix(p) { return String(before.dropFirst(p.count)).replacingOccurrences(of: "^\\s", with: "", options: .regularExpression) }
        return before
    }
    private func inputAfter(_ c: Int) -> String {
        guard let l = lineIndex(at: c), let r = lineRange(l) else { return "" }
        return string(c, r.location + r.length - c).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// The cursor is right after the prompt: nothing typed to delete.
    private func atInputStart(_ c: Int) -> Bool {
        guard let l = lineIndex(at: c), let r = lineRange(l) else { return false }
        let before = string(r.location, c - r.location)
        if before.isEmpty { return true }
        let p = state.prompt.trimmingCharacters(in: .whitespaces)
        return !p.isEmpty && before.trimmingCharacters(in: .whitespaces) == p
    }
    /// Nothing after the cursor on its line (spaces typed at the end still count: Right can move over them).
    private func atInputEnd(_ c: Int) -> Bool {
        guard let l = lineIndex(at: c), let r = lineRange(l) else { return false }
        return string(c, r.location + r.length - c).trimmingCharacters(in: .newlines).isEmpty
    }
    private func sayCharacter(_ ch: String) {
        guard let first = ch.first, ch != "\n" else { Speech.speakText("blank"); return }
        Speech.speakText(Symbols.name(of: first))
    }

    private func review(_ step: Int) {
        let s = state
        let here = s.review ?? (cursor.flatMap { lineIndex(at: $0) } ?? lastContentLine())
        var target = here + step
        let last = lastContentLine()
        if target < 0 { target = 0; Tones.edge() }
        if target > last { target = last; Tones.edge() }
        s.review = target
        let t = (lineText(target) ?? "").trimmingCharacters(in: .whitespaces)
        Speech.speakItem(t.isEmpty ? "blank" : t, processed: true)   // on the display too, until the shell line moves (8 Oct 2026)
    }

    private func reviewTo(top: Bool) {
        let s = state
        let target = top ? 0 : lastContentLine()
        s.review = target
        let t = (lineText(target) ?? "").trimmingCharacters(in: .whitespaces)
        Speech.speakItem(t.isEmpty ? "blank" : t, processed: true)   // on the display too, until the shell line moves (8 Oct 2026)
    }
}
