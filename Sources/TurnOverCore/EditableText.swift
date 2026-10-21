// SPDX-License-Identifier: GPL-3.0-or-later
// Editable text (NVDA: editableText): the caret scripts every text field and document shares, and the combo box that edits.
// Behaviours (NVDA: NVDAObjects.behaviors): the object classes every application shares; app modules subclass them.
import Foundation
import ApplicationServices
import AppKit
import TurnOverAX

/// Editable text (NVDA: EditableTextWithAutoSelectDetection). Navigation keys
/// are scripts: the key is sent on, the script waits for the caret to move
/// (events if they come quickly, polling the caret otherwise, 100 ms at most),
/// then speaks the unit at the new caret. Typing is never read from the caret;
/// it is echoed from the typed-character event. Selection changes are detected
/// on the caret event by comparing the old and new selection.
open class EditableText: TurnOverObject {
    /// Whether to announce the text before the caret on a new line (auto numbering).
    open var announceNewLineText: Bool { true }
    open var caretMoveTimeout: TimeInterval { Double(config.editableText.caretMoveTimeoutMs) / 1000 }
    /// A field inside a web page (an HTML input in Safari): WebKit is slow to report the caret.
    public lazy var isInWebContent: Bool = {
        var p = element.element(kAXParentAttribute); var hops = 0
        while let x = p, hops < 40 { if x.role == "AXWebArea" { return true }; p = x.element(kAXParentAttribute); hops += 1 }
        return false
    }()
    open override var hasNavigableText: Bool { true }
    open override var textInfoClass: TextInfo.Type { AXTextInfo.self }

    private var lastSelection: TextInfo?
    private var autoSelectDetection = false
    public var hasContentChangedSinceLastSelection = false

    open override func initOverlay() {
        super.initOverlay()
        let cat = "Text navigation"
        script("caret_moveByLine", "Moves the caret by a line and reads it", gestures: ["kb:upArrow", "kb:downArrow", "kb:pageUp", "kb:pageDown", "kb:command+upArrow", "kb:command+downArrow", "kb:command+home", "kb:command+end"], category: cat, resumesSayAll: true) { [weak self] g in guard let self else { return }; caretMovement(g, .line) }
        script("caret_moveByCharacter", "Moves the caret by a character and reads it", gestures: ["kb:leftArrow", "kb:rightArrow", "kb:home", "kb:end", "kb:command+leftArrow", "kb:command+rightArrow"], category: cat) { [weak self] g in guard let self else { return }; caretMovement(g, .character) }
        script("caret_moveByWord", "Moves the caret by a word and reads it", gestures: ["kb:option+leftArrow", "kb:option+rightArrow"], category: cat) { [weak self] g in guard let self else { return }; caretMovement(g, .word) }
        script("caret_moveByParagraph", "Moves the caret by a paragraph and reads it", gestures: ["kb:option+upArrow", "kb:option+downArrow"], category: cat, resumesSayAll: true) { [weak self] g in guard let self else { return }; caretMovement(g, .paragraph) }
        script("caret_deleteCharacter", "Deletes the character after the caret and reads the next", gestures: ["kb:delete", "kb:function+backspace"], category: cat) { [weak self] g in guard let self else { return }; deleteScript(g, .character) }
        script("caret_deleteWord", "Deletes the word after the caret and reads the next", gestures: ["kb:option+delete"], category: cat) { [weak self] g in guard let self else { return }; deleteScript(g, .word) }
        script("caret_backspaceCharacter", "Deletes the character before the caret and reads it", gestures: ["kb:backspace", "kb:shift+backspace"], category: cat) { [weak self] g in guard let self else { return }; backspaceScript(g, .character) }
        script("caret_backspaceWord", "Deletes the word before the caret and reads it", gestures: ["kb:option+backspace"], category: cat) { [weak self] g in guard let self else { return }; backspaceScript(g, .word) }
        script("caret_backspaceLine", "Deletes to the start of the line and reads it", gestures: ["kb:command+backspace"], category: cat) { [weak self] g in guard let self else { return }; backspaceScript(g, .line) }
        // Shift with the arrows (NVDA: caret_changeSelection): the key goes on and the selection is read as soon as
        // it changes, not when the app's notice comes (Word's came 300 ms after the key: "draggy", 17 Oct 2026).
        script("caret_changeSelection", "Extends or shrinks the selection and reads what changed", gestures: ["kb:shift+leftArrow", "kb:shift+rightArrow", "kb:shift+upArrow", "kb:shift+downArrow", "kb:shift+home", "kb:shift+end", "kb:shift+pageUp", "kb:shift+pageDown", "kb:option+shift+leftArrow", "kb:option+shift+rightArrow", "kb:option+shift+upArrow", "kb:option+shift+downArrow", "kb:command+shift+leftArrow", "kb:command+shift+rightArrow", "kb:command+shift+upArrow", "kb:command+shift+downArrow"], category: cat) { [weak self] g in guard let self else { return }; selectionScript(g) }
        // Only while this field still has the keyboard: with Word's "save changes?" sheet up, Command Delete ran
        // the delete-to-line-start script before reaching Don't Save (8 Oct 2026). A sheet or dialog in front of
        // the field's application means its keys are the sheet's.
        for name in ["caret_moveByLine", "caret_moveByCharacter", "caret_moveByWord", "caret_moveByParagraph", "caret_deleteCharacter",
                     "caret_deleteWord", "caret_backspaceCharacter", "caret_backspaceWord", "caret_backspaceLine", "caret_changeSelection"] {
            script(named: name)?.isAvailable = { [weak self] in
                guard let self else { return false }
                if (element.attr(kAXFocusedAttribute) as? Bool) == false { return false }
                return !AXHandler.modalInFront(pid: pid)
            }
        }
        // Spelling errors in any text (TextEdit, Mail, Notes): Word's TurnOver E, everywhere (a tester, build 14,
        // 7 Oct 2026). Word's module has its own, which searches the whole document.
        script("nextSpellingError", "Moves to the next spelling error", gestures: ["kb:turnover+e"], category: cat) { [weak self] _ in self?.goToMisspelling(forward: true) }
        script("previousSpellingError", "Moves to the previous spelling error", gestures: ["kb:turnover+shift+e"], category: cat) { [weak self] _ in self?.goToMisspelling(forward: false) }
        if announceNewLineText { script("caret_newLine", "Starts a new line", gestures: ["kb:enter", "kb:numpadEnter"], category: cat) { [weak self] g in guard let self else { return }; newLineScript(g) } }
    }

    /// The next or previous misspelled word: the app's marks (AXMarkedMisspelled, AXMisspelled), else macOS's checker.
    /// Forward: the first word starting after the caret, or at it unless the last search put the caret there.
    /// Back: the last word starting before the caret (the one just typed, with the caret at its end).
    public nonisolated static func misspellingTarget(_ words: [NSRange], caret: Int, forward: Bool, placedHere: Bool) -> NSRange? {
        forward ? words.first { $0.location > caret || ($0.location == caret && !placedHere) } : words.last { $0.location < caret }
    }
    func goToMisspelling(forward: Bool) {
        guard let info = try? makeTextInfo(.caret) else { Speech.speakMessage("no text"); return }
        let n = info.storyLength()
        // The text with its marks: WebKit's (Safari's comment boxes, Mail's message body) through the bridge, a
        // Cocoa field's through its element ("no text" was said in every web field, 8 Oct 2026).
        // Fetching up to 100,000 characters with their marks can take a second in a long document: off the main
        // thread, "please wait" if slow, then the search and the move on it (8 Oct 2026, from the code review).
        // Taken on the main thread; the fetch itself runs off it.
        let bridge = (info as? WebTextInfo)?.bridge, textElement = (info as? AXTextInfo)?.textElement
        Poll.background({ () -> Handed<NSAttributedString?> in
            guard n > 0 else { return Handed(nil) }
            if let bridge, let r = bridge.range(0, min(n, 100_000)) { return Handed(bridge.attributedString(r)) }
            if let textElement { return Handed(textElement.param(kAXAttributedStringForRangeParameterizedAttribute, axRangeValue(0, min(n, 100_000))) as? NSAttributedString) }
            return Handed(nil)
        }) { [weak self] handed in
            guard let self else { return }
            let attributed = handed.value
            guard n > 0, let a = attributed ?? (info.textRange(0, min(n, 100_000)).isEmpty ? nil : NSAttributedString(string: info.textRange(0, min(n, 100_000)))) else {
                Speech.speakMessage(forward ? "no next spelling error" : "no previous spelling error"); return
            }
            goToMisspelling(forward: forward, in: a, info: info, length: n)
        }
    }
    private func goToMisspelling(forward: Bool, in a: NSAttributedString, info: TextInfo, length n: Int) {
        let attributed: NSAttributedString? = a
        let ns = a.string as NSString
        var words: [NSRange] = []
        // Either of WebKit's two marks: the one for a word the page has underlined (AXMarkedMisspelled) and the one
        // for a word the checker knows is wrong (AXMisspelled); the format reader takes both, the search took one
        // (14 Oct 2026: Safari's comment box gave one of two misspelled words).
        for key in ["AXMarkedMisspelled", "AXMisspelled"] {
            a.enumerateAttribute(NSAttributedString.Key(key), in: NSRange(location: 0, length: a.length)) { val, range, _ in
                guard (val as? NSNumber)?.boolValue == true else { return }
                var r = range
                while r.length > 0, let c = ns.substring(with: NSRange(location: NSMaxRange(r) - 1, length: 1)).first, c.isWhitespace || c.isPunctuation { r.length -= 1 }
                if r.length > 0, !words.contains(where: { NSIntersectionRange($0, r).length > 0 }) { words.append(r) }
            }
        }
        words.sort { $0.location < $1.location }
        // TextEdit doesn't mark its misspellings for accessibility (measured 8 Oct 2026), and nor do Safari's text
        // areas now (probe, 14 Oct 2026: no AXMisspelled or AXMarkedMisspelled in a comment box with two wrong
        // words): ask macOS's spell checker. Its one-word-at-a-time call, with the language guessed, wrapped back to
        // the first word and missed the rest ("toste" after "Thiss"); the whole-text check finds them all.
        // The app's marks can be only some of them: TextEdit marks the one word Command Semicolon found, and the search
        // then knew no other, coming back to that word (19 Oct 2026: "TO E is being a bit funky"). So the Mac's
        // checker is asked as well and its words added, except in Word, whose own dictionary is the one that counts.
        if words.isEmpty || appModule.bundleIdentifier != "com.microsoft.Word" {
            let marked = words.count
            let results = NSSpellChecker.shared.check(a.string, range: NSRange(location: 0, length: ns.length),
                types: NSTextCheckingResult.CheckingType.spelling.rawValue, options: nil, inSpellDocumentWithTag: 0, orthography: nil, wordCount: nil)
            for r in results.prefix(500).map(\.range) where r.length > 0 && !words.contains(where: { NSIntersectionRange($0, r).length > 0 }) { words.append(r) }
            words.sort { $0.location < $1.location }
            Log.io("spelling: \(marked) marked by the app, \(words.count - marked) more from the Mac's spell checker")
        }
        let caret = info.start
        Log.io("spelling: \(type(of: info)) length \(n), attributed \(attributed?.length ?? -1), marked \(words.count), caret \(caret)")
        // Forward: a word starting after the caret, or at it unless this search put the caret there (typing
        // "Thiss" first left the caret at 0 and the word at 0 was never found). Back: a word starting before the
        // caret, so the word just typed counts (the caret at 5 after "Thiss" found nothing; 14 Oct 2026).
        let placedHere = misspellingPlaced.map { $0.at == caret && Date().timeIntervalSince($0.when) < 60 } ?? false
        let target = Self.misspellingTarget(words, caret: caret, forward: forward, placedHere: placedHere)
        guard let r = target else { Tones.edge(keySent: true); Speech.speakMessage(forward ? "no next spelling error" : "no previous spelling error"); return }
        misspellingPlaced = (r.location, Date())
        info.setCaretOffset(r.location)
        Speech.speakMessage("\(ns.substring(with: r)), misspelled")
    }

    // MARK: Did the caret move?

    /// After a key has gone to the application: watch for evidence that the caret moved, until it shows or time is up.
    /// The evidence: the focus went elsewhere (the focus event will read it); the caret is somewhere new; or, after a
    /// moment, the word at the caret is different (a word deleted where the caret stands). The application's own
    /// "caret moved" news only prompts a look: Word sends it before its caret has actually changed.
    /// Gives way at once if another key is already waiting.
    public func hasCaretMoved(from bookmark: Bookmark?, originalWord: String? = nil) -> (Bool, TextInfo?) {
        let began = Date()
        // WebKit's text fields (Safari's pages) post the caret move 100 ms or more after the key: wait longer there
        // before calling it an edge (Left in Wikipedia's search said nothing and bumped, 2 Oct 2026).
        let patience = caretMoveTimeout * (isInWebContent ? 3 : 1)
        var looks = 0
        var caret: TextInfo?
        let keys = ScriptHandler.keysArrivedCount
        while true {
            if ScriptHandler.isScriptWaiting { return (false, nil) }
            // Another key has come (typed after a Backspace): this one gives way, taken as done. Each Backspace in
            // Claude's prompt waited the whole 300 ms for a caret the page reports late, and the letters typed after
            // it came that much later (12 Oct 2026: "typing in the edit field here is not working properly").
            if ScriptHandler.keysArrivedCount != keys {
                Log.io("caret wait ended by the next key after \(Int(Date().timeIntervalSince(began) * 1000)) ms")
                return (true, nil)
            }
            EventHandler.pumpPendingEvents()
            if EventHandler.isPending(.gainFocus) { Log.debug("focus event while waiting for the caret"); return (true, nil) }
            let waited = Date().timeIntervalSince(began)
            let announced = EventHandler.isPending(.caret) || EventHandler.isPending(.textChange)
            caret = try? makeTextInfo(.caret)
            guard let now = caret else {
                if announced { return (true, nil) }   // moved, by its own account, and the caret cannot be read yet
                if waited >= patience { break }
                usleep(2000); looks += 1; continue
            }
            if now.bookmark != bookmark {
                Log.debug("caret moved, seen after \(Int(waited * 1000)) ms, \(looks) looks")
                return (true, now)
            }
            if let word = originalWord, waited >= 0.03 {
                let here = now.copy(); here.expand(.word)
                if here.text != word { return (true, now) }
            }
            if waited >= patience { break }
            usleep(looks < 3 ? 1000 : 2000)
            looks += 1
        }
        Log.debug("caret did not move within \(Int(caretMoveTimeout * 1000)) ms")
        return (false, caret)
    }

    /// After a caret key: read the caret afresh, note the selection for the next comparison, and say the unit moved
    /// by, unless the focus is already going elsewhere, another key is waiting, or say all is about to carry on.
    open func caretMoved(speak unit: TextUnit?, gesture: KeyboardGesture, info: TextInfo?) {
        guard !ScriptHandler.isScriptWaiting, !EventHandler.isPending(.gainFocus),
              let caret = info ?? (try? makeTextInfo(.caret)) else { return }
        Speech.clearTypedWordBuffer()
        lastSelection = (try? makeTextInfo(.selection)) ?? caret
        guard let unit, !SayAll.willResume(gesture) else { return }
        // Entering, moving in or leaving a table in a Cocoa text view (TextEdit), said first, as NVDA does ().
        if config.documentFormatting.tables != .off, let el = (caret as? AXTextInfo)?.textElement {
            TextTables.report(element: el, offset: caret.start, length: caret.storyLength(), tone: config.documentFormatting.tables == .tone)
        }
        caret.expand(unit)
        Speech.speakTextInfo(caret, unit: unit, reason: .caret)
    }

    /// The caret, if it has moved from `bookmark` within another 150 ms (polled, giving way to a new key).
    enum LateCaret { case moved(TextInfo), stayed, gaveWay }
    /// The caret, if it moves from `bookmark` within another 60 ms (the late move measured was 7 ms; the code review
    /// asked for a short window). A new key or a focus change gives way, and is no edge.
    func laterCaret(than bookmark: Bookmark) -> LateCaret {
        let keys = ScriptHandler.keysArrivedCount
        for _ in 0..<6 {
            if ScriptHandler.keysArrivedCount != keys || ScriptHandler.isScriptWaiting { return .gaveWay }
            usleep(10_000)
            EventHandler.pumpPendingEvents()
            if EventHandler.isPending(.gainFocus) { return .gaveWay }
            if let now = try? makeTextInfo(.caret), now.bookmark != bookmark { return .moved(now) }
        }
        return .stayed
    }

    /// Up and Down at the edge read the line in a one-line field (a search box, the To field), as NVDA and VoiceOver
    /// do (a tester), and in a box that holds one line of text: a reply, a message, a prompt (13 Oct
    /// 2026, Spring's reply box). A document only bumps at its top and bottom (the owner's choice, 1 Oct 2026).
    var readsLineAtEdge: Bool {
        if ["AXTextField", "AXSearchField", "AXComboBox"].contains(axRole) || element.string(kAXSubroleAttribute) == "AXSearchField" { return true }
        // The length first, so a whole document is never fetched to find out (Word's body is a text area too).
        guard axRole == "AXTextArea",
              let n = element.int(kAXNumberOfCharactersAttribute), n < 2000,
              let v = element.string(kAXValueAttribute) else { return false }
        return !v.contains(where: \.isNewline)
    }

    /// Shift with a movement key: the key goes on, and the selection is read the moment it differs (polled, as the
    /// caret is for a plain arrow); if it hasn't changed within the caret's patience, the app's own notice reads it.
    func selectionScript(_ gesture: KeyboardGesture) {
        if GoogleDocs.isEditor(element) { gesture.send(); return }
        guard autoSelectDetection, let old = try? makeTextInfo(.selection) else { gesture.send(); return }
        gesture.send()
        let began = Date()
        let patience = caretMoveTimeout * (isInWebContent ? 3 : 1)
        let keys = ScriptHandler.keysArrivedCount
        while Date().timeIntervalSince(began) < patience {
            if ScriptHandler.isScriptWaiting || ScriptHandler.keysArrivedCount != keys { return }
            EventHandler.pumpPendingEvents()
            if let new = try? makeTextInfo(.selection), !new.isSame(old) {
                Log.io("selection changed, seen after \(Int(Date().timeIntervalSince(began) * 1000)) ms")
                detectPossibleSelectionChange()
                return
            }
            usleep(2000)
        }
        Log.io("selection: no change seen within \(Int(patience * 1000)) ms; the app's notice will read it")
    }

    func caretMovement(_ gesture: KeyboardGesture, _ unit: TextUnit) {
        // Google Docs, Sheets, Slides: the text box is a hidden typing target; Google says the move itself.
        if GoogleDocs.isEditor(element) { gesture.send(); return }
        guard let info = try? makeTextInfo(.caret) else { gesture.send(); return }
        let bookmark = info.bookmark
        let oldLine = info.copy(); oldLine.expand(.line)
        // An edge known before the key is sent is an edge at once, not after the caret's patience: at the end of
        // Claude's prompt every Down waited 300 ms before bumping ("TurnOver froze", 17 Oct 2026). Only the
        // line keys: Left and Right move the other way in right-to-left text (). Only with nothing selected: an
        // arrow at the end of a selection collapses it, and swallowing it made the next letter replace the text
        // (a code review on 17 Oct). The key still goes, unwaited, so the app and VoiceOver's own boundary sound see it.
        let key = gesture.keyName
        let length = info.storyLength()
        let collapsed = (try? makeTextInfo(.selection))?.isCollapsed ?? true
        let backwards = key == "upArrow" || key == "home" || key == "pageUp"
        let forwards = key == "downArrow" || key == "end" || key == "pageDown"
        // Not in a table cell: the cell's text is short and Up or Down leave the cell for the next row (Word's demo
        // document, 17 Oct 2026: "1 of 1; sent unwaited", then the next cell read).
        var inCell = element.role == "AXCell"
        var up: AXUIElement? = element.element(kAXParentAttribute)
        for _ in 0..<4 { guard let e = up, !inCell else { break }; if ["AXCell", "AXRow", "AXTable"].contains(e.role) { inCell = true }; up = e.element(kAXParentAttribute) }
        if !inCell, WordTableCell.cell(of: element) != nil { inCell = true }   // Word's cells hang off the page, not a row
        let noRoom = collapsed && !inCell && !gesture.modifiers.contains(.shift) && unit == .line
            && ((backwards && oldLine.start <= 0 && info.start <= 0) || (forwards && length > 0 && oldLine.end >= length && info.start >= length))
        if noRoom {
            Log.io("edge: nothing \(backwards ? "before" : "after") the caret (\(info.start) of \(length)); sent unwaited")
            gesture.send()
            Tones.edge(keySent: true)
            caretMoved(speak: readsLineAtEdge ? .line : nil, gesture: gesture, info: info)
            return
        }
        gesture.send()
        var (moved, newInfo) = hasCaretMoved(from: bookmark)
        // A selection collapsed by the key is a move, though the caret's end stays put (Command-A then Right: the
        // caret was already at the end; it bumped instead, 17 Oct 2026).
        if !moved, !collapsed, (try? makeTextInfo(.selection))?.isCollapsed == true {
            Log.io("the selection collapsed: read as a move")
            moved = true; newInfo = try? makeTextInfo(.caret)
        }
        // At the edge of the document a line key moves the caret within the same line or not at all.
        // NVDA reads the line again; TurnOver bumps instead (the owner asked, 1 Oct 2026). "Same line" means
        // the line the new caret is on starts where the old one did — never a position test, which
        // mistook the first character of the next line for the end of this one.
        var sameLine = false
        if unit == .line, moved, let n = newInfo {
            // The same line is the line whose start has not changed: the end of the last line is still that line,
            // the first character of the next line is not (the line queries say which).
            let newLine = n.copy(); newLine.expand(.line)
            sameLine = newLine.start == oldLine.start && newLine.text == oldLine.text
        }
        if sameLine, let n = newInfo {
            // Word moves the caret to the start of the last line on the first Up from its end (measured 2 Oct 2026);
            // the key meant the line above: send it once more and read where it lands.
            let b2 = n.bookmark
            gesture.send()
            let (moved2, info2) = hasCaretMoved(from: b2)
            if moved2, let n2 = info2, n2.start < oldLine.start || n2.start >= oldLine.end {
                caretMoved(speak: unit, gesture: gesture, info: n2)
                return
            }
            Log.io("edge: caret stayed on its line (old line \(oldLine.start)-\(oldLine.end), caret \(info2?.start ?? n.start))")
            Tones.edge(keySent: true)
            caretMoved(speak: readsLineAtEdge ? .line : nil, gesture: gesture, info: info2 ?? n)
            return
        }
        // Another key came while this one was waiting for the caret: this one gives way, and is no edge. (Pressing
        // Down again before the line was read played the edge sound in the middle of text: a tester, .)
        if !moved, ScriptHandler.isScriptWaiting { return }
        // In a table cell the key took the caret to another cell: the old cell reports no caret, and the new cell's
        // focus reads itself (Word's demo document, 17 Oct 2026: a bump before each row).
        // The caret gone after the key (Word reports none): it went to another area, a cell, the endnotes, a text box,
        // whose focus reads itself; no edge (Command-End into the endnote area bumped, 17 Oct 2026).
        if !moved, (newInfo?.start ?? -1) < 0 { Log.io("caret left \(inCell ? "the cell" : "this area"); its focus reads the next"); return }
        if !moved {
            // One more look, a little later: in right-to-left text (Arabic), Right at a paragraph's start went to the
            // paragraph before, but TextEdit moved the caret 7 ms after the wait ended, and the edge sounded on a real
            // move (a tester, 13 Oct 2026). A caret that has moved by now is read as a move.
            // Not in web content: it already waits three times as long, and the extra look made every arrow at the
            // edge of Claude's empty prompt take half a second (13 Oct 2026: "the reading is broken").
            // Only Left and Right by character (the right-to-left case), outside web content.
            // Also a word move (Option-Right at a paragraph's last word in Word: the caret arrived after the wait, twice, 17 Oct 2026).
            if !isInWebContent, unit == .character || unit == .word, ["leftArrow", "rightArrow"].contains(gesture.keyName) {
                switch laterCaret(than: bookmark) {
                case .moved(let late):
                    Log.io("caret moved late (after the wait); read as a move")
                    caretMoved(speak: unit, gesture: gesture, info: late)
                    return
                case .gaveWay: return
                case .stayed: break
                }
            }
            Log.io("edge: caret did not move (old line \(oldLine.start)-\(oldLine.end), caret \(newInfo?.start ?? -1))")
            Tones.edge(keySent: true)
            caretMoved(speak: unit == .line && readsLineAtEdge ? .line : nil, gesture: gesture, info: newInfo)
            return
        }
        // VoiceOver's reading of a plain Right by character: the character just passed over, now before the caret, so
        // what you hear is what Backspace will delete (Oliver, 20 Oct 2026: "you have to be to the right of the
        // object you want to backspace"). NVDA reads the character after the caret; the Windows family keeps that.
        if unit == .character, config.general.macKeys, gesture.keyName == "rightArrow", gesture.modifiers.isEmpty,
           let n = newInfo, n.start > 0, let old = try? makeTextInfo(.bookmark(bookmark)), n.start > old.start {
            let passed = n.copy(); passed.collapse(); _ = passed.move(.character, -1); passed.expand(.character)
            caretMoved(speak: nil, gesture: gesture, info: n)
            Speech.speakTextInfo(passed, unit: .character, reason: .caret)
            return
        }
        // Option+Right on the Mac stops at the end of the word, on the space or comma after it: say the word passed
        // over, as VoiceOver does, not "blank" or "comma" (Mail's compose window, 5 Oct 2026).
        if unit == .word, gesture.keyName == "rightArrow", let n = newInfo, n.start > 0 {
            func isWordChar(_ t: String) -> Bool { t.unicodeScalars.first.map { CharacterSet.alphanumerics.contains($0) || $0 == "'" || $0 == "\u{2019}" } ?? false }
            // The Windows style (Control Right): on to the start of the next word and read that word, as NVDA does on
            // a PC. The Mac's Option Right stops at the end of the word, so TurnOver steps over the spaces and
            // punctuation after it (a tester, 11 Oct 2026: "it speaks text the cursor passes"). At the end of the text it
            // stays where the Mac put it.
            if config.general.windowsKeys, isWordChar(n.textRange(n.start - 1, n.start)) {
                var target = n.start
                let limit = n.storyLength()
                while target < limit, target - n.start < 40, !isWordChar(n.textRange(target, target + 1)), n.textRange(target, target + 1) != "\n" { target += 1 }
                if target > n.start, target < limit {
                    let next = type(of: n).init(obj: n.obj, start: target, end: target)
                    next.updateCaret()
                    _ = hasCaretMoved(from: n.bookmark)
                    caretMoved(speak: .word, gesture: gesture, info: next)
                    return
                }
            }
            if isWordChar(n.textRange(n.start - 1, n.start)), !isWordChar(n.textRange(n.start, n.start + 1)) {
                caretMoved(speak: nil, gesture: gesture, info: n)
                let passed = type(of: n).init(obj: n.obj, start: n.start - 1, end: n.start - 1)
                passed.expand(.word)
                if passed.end > n.start { passed.end = n.start }   // the word, not the space or comma after it
                Speech.speakTextInfo(passed, unit: .word, reason: .caret)
                return
            }
        }
        caretMoved(speak: unit, gesture: gesture, info: newInfo)
    }

    /// Enter: read what is on the new line before the caret (auto numbering, a bullet), or just note the move.
    func newLineScript(_ gesture: KeyboardGesture) {
        // A one-line field has no new line: Return in Safari's address field said "new line" as the page was opening
        // (12 Oct 2026), after a 100 ms wait for a caret that never moves there.
        if axRole == "AXTextField" { gesture.send(); return }
        guard let info = try? makeTextInfo(.caret) else { gesture.send(); return }
        let bookmark = info.bookmark
        let lengthBefore = info.storyLength()
        gesture.send()
        Speech.speakTypedCharacter("\r", inEditable: true)
        let (moved, newInfo) = hasCaretMoved(from: bookmark)
        guard moved, let newInfo, let line = try? makeTextInfo(.caret) else { return }
        // Return sent what was typed (Claude's prompt, a chat box): the text got shorter, not a line longer. Nothing
        // to say ("new line" was heard as Claude's prompt sent, 7 Oct 2026).
        if lengthBefore > 0, line.storyLength() < lengthBefore { Log.io("Return sent the text; no new line"); return }
        // Say the new line was made (the owner asked, 4 Oct 2026), then anything already on it (a list number).
        if config.keyboard.speakNewLine { Speech.speakOnly("new line") }   // the display shows the new line itself
        line.expand(.line)
        line.setEndPoint(newInfo, .endToStart)
        if line.isCollapsed { return }
        Speech.speakTextInfo(line, unit: .line, reason: .caret)
    }

    func backspaceScript(_ gesture: KeyboardGesture, _ unit: TextUnit) {
        if GoogleDocs.isEditor(element) { gesture.send(); return }   // Google says what was deleted
        if role == .passwordEdit { gesture.send(); return }   // SecureEcho hears the field get shorter
        guard let old = try? makeTextInfo(.caret) else { gesture.send(); return }
        let bookmark = old.bookmark
        // A selection goes as a whole: say what went, not the character before the caret.
        if let sel = try? makeTextInfo(.selection), !sel.isCollapsed {
            let gone = sel.text.trimmingCharacters(in: .whitespacesAndNewlines)
            gesture.send()
            _ = hasCaretMoved(from: bookmark)
            lastSelection = try? makeTextInfo(.selection)
            Speech.speakMessage(gone.isEmpty ? "selection deleted" : gone.count <= 80 ? "deleted " + (gone.count == 1 ? Symbols.name(of: gone.first!) : gone) : "selection deleted")
            return
        }
        let test = old.copy()
        var chunk = ""
        if test.move(.character, -1) < 0 {
            if unit == .line { let l = old.copy(); l.expand(.line); l.setEndPoint(old, .endToStart); chunk = l.text }
            else if unit == .word {
                // The word before the caret, past any spaces: Option Backspace takes it and the spaces after it. The
                // word unit at a space is the space alone in a web editor, so after the first word in Mail nothing
                // more was said (a tester, 7 Oct 2026); TextEdit happened to include the space.
                let l = old.copy(); l.expand(.line); l.setEndPoint(old, .endToStart)
                let before = l.text
                let trimmed = before.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
                if trimmed.isEmpty { chunk = before.isEmpty ? "\n" : before }
                else { chunk = String(trimmed.split(whereSeparator: { $0.isWhitespace }).last ?? Substring(trimmed)) }
            }
            else { test.expand(unit); chunk = test.text }
        }
        gesture.send()
        Speech.speakTypedCharacter("\u{8}", inEditable: true)
        let c = chunk.replacingOccurrences(of: "\r\n", with: "\n")
        // Said at once, before the caret is waited for: with something before the caret the deletion is certain, and
        // the wait (up to 300 ms in web content, 100 to 160 accessibility calls) held back every repeated Backspace
        // in Mail's compose window (Oliver, 20 Oct 2026: "not reading so well").
        if !c.isEmpty {
            // A line break has nothing to spell: say what it was ("new line"), as for any character named on its own.
            if let only = c.first, c.count == 1, only.isNewline { Speech.speakMessage(Symbols.name(of: only)) }
            // A word or a line deleted says so ("deleted more"); a single character is just the character, as in NVDA.
            else if c.count > 1 { Speech.speakText(unit == .character ? c : "deleted " + c.trimmingCharacters(in: .whitespaces)) } else { Speech.speakSpelling(c) }
        }
        let (moved, newInfo) = hasCaretMoved(from: bookmark)
        guard moved else { return }
        caretMoved(speak: nil, gesture: gesture, info: newInfo)
        // caretMoved forgets the word being typed; a deletion changes it, and the next space or punctuation says the
        // word as it now is ("think", Backspace, Space: "thin"; a tester).
        Speech.noteBackspace()
    }

    func deleteScript(_ gesture: KeyboardGesture, _ unit: TextUnit) {
        if role == .passwordEdit { gesture.send(); return }   // SecureEcho hears the field get shorter
        guard let info = try? makeTextInfo(.caret) else { gesture.send(); return }
        let bookmark = info.bookmark
        let w = info.copy(); w.expand(.word)
        gesture.send()
        let (_, newInfo) = hasCaretMoved(from: bookmark, originalWord: w.text)
        caretMoved(speak: unit, gesture: gesture, info: newInfo)
    }

    // MARK: Selection detection (NVDA: initAutoSelectDetection / detectPossibleSelectionChange)

    public func initAutoSelectDetection() {
        lastSelection = try? makeTextInfo(.selection)
        hasContentChangedSinceLastSelection = false
        autoSelectDetection = true
    }
    public func terminateAutoSelectDetection() { lastSelection = nil; autoSelectDetection = false }

    private var lastTypedAt = Date.distantPast
    private var completionWork: DispatchWorkItem?

    public func detectPossibleSelectionChange() {
        guard autoSelectDetection, let new = try? makeTextInfo(.selection) else { return }
        let old = lastSelection
        lastSelection = new.copy()
        guard let old else { return }
        let changed = hasContentChangedSinceLastSelection
        hasContentChangedSinceLastSelection = false
        if Date().timeIntervalSince(lastTypedAt) < 0.3 {
            // An address bar completing what is typed: say the completion, not what was unselected (NVDA's generalized
            // form) — once typing pauses. Safari completes again on every letter; each one read was a stutter
            // ("selected kipedia.org", "selected ipedia.org"… 2 Oct 2026).
            if !new.isCollapsed, !new.isSame(old) {
                completionWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, API.focusObject?.isSameElement(as: self) == true,
                          Date().timeIntervalSince(InputManager.lastKeyDownAt) >= 0.5,
                          let sel = try? self.makeTextInfo(.selection), !sel.isCollapsed else { return }
                    Speech.speakOnly("selected " + Speech.processed(sel.text))   // the display marks it with dots 7 and 8
                }
                completionWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
            }
            return
        }
        Speech.speakSelectionChange(old: old, new: new, generalize: changed)
    }
    open override func event_typedCharacter(_ ch: Character) { lastTypedAt = Date(); super.event_typedCharacter(ch) }

    open override func event_gainFocus() {
        if isParagraphHop() { readParagraphHop() } else { super.event_gainFocus() }
        initAutoSelectDetection()
    }
    open override func event_loseFocus() {
        if let p = element.element(kAXParentAttribute) { Self.lastLeft = (element, p, Date()) }
        terminateAutoSelectDetection(); super.event_loseFocus()
    }

    /// The text box the focus last left, and its parent: LibreOffice's documents are one text box per paragraph, and
    /// every arrow over a paragraph's edge moved the focus and was read "edit, " and the whole paragraph (parts sweep,
    /// 14 Oct 2026). NVDA reads such a move as a caret move.
    nonisolated(unsafe) static var lastLeft: (element: AXUIElement, parent: AXUIElement, at: Date)?

    /// The focus came from a sibling text box by a caret key (an arrow, Home, End, Page Up or Down, with Shift or
    /// Option or not): the same document, a new paragraph. Tab between fields of a form is never one.
    private func isParagraphHop() -> Bool {
        guard axRole == "AXTextArea", let left = Self.lastLeft, Date().timeIntervalSince(left.at) < 0.5, !left.element.isSame(element),
              Date().timeIntervalSince(InputManager.lastKeyDownAt) < 1,
              let parent = element.element(kAXParentAttribute), parent.isSame(left.parent) else { return false }
        let key = InputManager.lastKeyIdentifier.lowercased()
        guard !key.contains("turnover"), !key.contains("control") else { return false }
        guard ["uparrow", "downarrow", "leftarrow", "rightarrow", "home", "end", "pageup", "pagedown"].contains(where: { key.hasSuffix($0) }) else { return false }
        // Paragraphs have no names; fields of a form do (Down between a card's fields keeps saying which field).
        return name.isEmpty && ObjectFactory.make(left.element).name.isEmpty
    }

    /// A paragraph hop: the selection if there is one, else the line (or the word or character, by the key).
    private func readParagraphHop() {
        Log.io("text: the focus moved to the next paragraph's text box; read as a caret move")
        Speech.clearTypedWordBuffer()
        if let sel = try? makeTextInfo(.selection), sel.end > sel.start {
            lastSelection = sel
            Speech.speakMessage("selected " + sel.text)
            return
        }
        guard let caret = try? makeTextInfo(.caret) else { return }
        lastSelection = caret
        let key = InputManager.lastKeyIdentifier.lowercased()
        let unit: TextUnit = key.contains("uparrow") || key.contains("downarrow") || key.contains("page") || key.contains("command")
            ? .line : key.contains("option") ? .word : (key.hasSuffix("home") || key.hasSuffix("end")) ? .line : .character
        caret.expand(unit)
        Speech.speakTextInfo(caret, unit: unit, reason: .caret)
    }
    open override func event_caret() {
        super.event_caret()
        if API.focusObject?.isSameElement(as: self) == true, !EventHandler.isPending(.gainFocus) { detectPossibleSelectionChange() }
    }

    open override func event_textChange() { hasContentChangedSinceLastSelection = true }
    /// A text control's value changes with every keystroke; that is typing, not a value to announce.
    open override func event_valueChange() { hasContentChangedSinceLastSelection = true }
}

/// A combo box you type into: a text field whose Up and Down belong to its list of suggestions.
open class EditableComboBox: EditableText {
    open override func initOverlay() {
        super.initOverlay()
        removeGestures(["kb:upArrow", "kb:downArrow"])
    }
}

/// Where the last spelling search put the caret, so the next search forward moves on from it.
private var misspellingPlaced: (at: Int, when: Date)?
