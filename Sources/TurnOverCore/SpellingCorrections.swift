// SPDX-License-Identifier: GPL-3.0-or-later
// Corrections for a misspelled word in any edit box (18 Oct 2026: "spelling should work in every edit box
// everywhere on the mac"). VO-Shift-M right-clicked at the caret, which gives the corrections only where the app's
// own menu has them (Word, TextEdit); Calendar's event title found the word (TurnOver E) but its menu had none.
// So TurnOver asks the Mac's spell checker itself: VO-Shift-M on a misspelled word (or just after one, as typed)
// opens TurnOver's list: the guesses, then Learn spelling, Ignore, and the app's own menu. Choosing a guess puts it in
// place of the word: the word selected, then replaced through accessibility, or pasted where a field won't take that.
// Word keeps its own menu (its corrections, its dictionary).
import AppKit
import ApplicationServices

public enum SpellingCorrections {
    static let ownMenuApps: Set<String> = ["com.microsoft.Word"]

    /// True when the caret is on a misspelled word and the list was offered.
    public static func offer() -> Bool {
        guard let f = API.focusObject, let info = try? f.makeTextInfo(.caret) else { return false }
        if let bundle = NSRunningApplication(processIdentifier: f.pid)?.bundleIdentifier, ownMenuApps.contains(bundle) { return false }
        // A word selected (Command Semicolon selects the next misspelling): the word at the selection's start; the caret
        // is at its end, after it.
        let selection = try? f.makeTextInfo(.selection)
        let caret = selection.flatMap { $0.isCollapsed ? nil : $0.start } ?? info.caretOffset() ?? info.start
        let n = info.storyLength()
        guard n > 0 else { return false }
        let lo = max(0, caret - 200), hi = min(n, caret + 200)
        let text = info.textRange(lo, hi) as NSString
        guard let r = wordRange(in: text, at: caret - lo) else { return false }
        let word = text.substring(with: r)
        let checker = NSSpellChecker.shared
        // In the checker's own language: left to identify the language, it can't from one word and calls every word
        // right ("seemless" passed, so VO Shift M fell back to a right click; 19 Oct 2026).
        let language = checker.language()
        guard checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location != NSNotFound else {
            Log.io("spelling: the word at the caret is spelt right (\(language)); no list"); return false
        }
        let guesses = checker.guesses(forWordRange: NSRange(location: 0, length: r.length), in: word, language: language, inSpellDocumentWithTag: 0) ?? []
        let start = lo + r.location, end = start + r.length
        Log.io("spelling: corrections offered (\(guesses.count))")
        var items = guesses.prefix(12).map { g in MenuItem(verbatim: g, .action { replace(info: info, element: f.element, start: start, end: end, with: g) }) }
        items.append(MenuItem("Learn spelling", .action { checker.learnWord(word); Speech.speakMessage(String(localized: "\(word) learnt", comment: "A word added to the dictionary")) }))
        items.append(MenuItem("Ignore", .action { checker.ignoreWord(word, inSpellDocumentWithTag: 0); Speech.speakMessage(String(localized: "ignored", comment: "Spoken message")) }))
        items.append(MenuItem("The app's own menu", .action { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { _ = GlobalCommands.contextMenuAtCaret() } }))
        TurnOverMenu.shared.openList(guesses.isEmpty ? "\(word), misspelled, no suggestions" : "\(word), misspelled", items: items)   // (both translatable: the list's title)
        return true
    }

    /// The word holding the caret, or the one just before it (the caret after a word typed).
    public static func wordRange(in text: NSString, at i: Int) -> NSRange? {
        func isWordChar(_ k: Int) -> Bool {
            guard k >= 0, k < text.length, let s = Unicode.Scalar(text.character(at: k)) else { return false }
            return CharacterSet.letters.contains(s) || s == "'" || s == "\u{2019}"
        }
        var k = i
        if !isWordChar(k) { k -= 1 }
        guard isWordChar(k) else { return nil }
        var a = k, b = k
        while isWordChar(a - 1) { a -= 1 }
        while isWordChar(b + 1) { b += 1 }
        // Not the apostrophes at its ends ('tis aside).
        while a <= b, !CharacterSet.letters.contains(Unicode.Scalar(text.character(at: a))!) { a += 1 }
        while b >= a, !CharacterSet.letters.contains(Unicode.Scalar(text.character(at: b))!) { b -= 1 }
        return a <= b ? NSRange(location: a, length: b - a + 1) : nil
    }

    /// The guess in place of the word, said once it's there.
    static func replace(info: TextInfo, element: AXUIElement, start: Int, end: Int, with guess: String) {
        info.setSelectionOffsets(start, end)
        let length = (guess as NSString).length
        let viaAX = element.set(kAXSelectedTextAttribute, guess as CFString) == .success
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if viaAX, info.textRange(start, start + length) == guess {
                info.setCaretOffset(start + length)
                Speech.cancel(); Speech.speakMessage(guess)
                return
            }
            // The field wouldn't take it that way (or said it did and didn't): read once more a moment later (a slow
            // field's text catches up), then pasted over the selection, the clipboard put back after.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { pasteIfNeeded(info: info, start: start, end: end, length: length, guess: guess, viaAX: viaAX) }
        }
    }

    private static func pasteIfNeeded(info: TextInfo, start: Int, end: Int, length: Int, guess: String, viaAX: Bool) {
        if info.textRange(start, start + length) == guess { info.setCaretOffset(start + length); Speech.cancel(); Speech.speakMessage(guess); return }
        let board = NSPasteboard.general
        // Not over a password a manager has put there (marked concealed or transient): putting it back would
        // undo the manager's clearing of it. The app's own menu instead.
        let marked: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]
        if (board.types ?? []).contains(where: { marked.contains($0.rawValue) }) {
            Log.io("spelling: not pasted (the clipboard holds a concealed item)")
            Speech.speakMessage(String(localized: "couldn't put it in here; the app's own menu", comment: "Spoken message"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { _ = GlobalCommands.contextMenuAtCaret() }
            return
        }
        Log.io("spelling: replaced by paste (accessibility \(viaAX ? "said yes, didn't" : "refused"))")
        info.setSelectionOffsets(start, end)
        let saved = board.pasteboardItems?.map { item in item.types.compactMap { t in item.data(forType: t).map { (t, $0) } } } ?? []
        board.clearContents()
        // Marked transient, so clipboard history apps leave it out.
        board.setString(guess, forType: .string)
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        let ours = board.changeCount
        KeyboardGesture(identifier: "kb:command+v")?.send()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // Put back only if nothing else has been copied since (a slow app's paste reads it by then).
            if board.changeCount == ours {
                board.clearContents()
                let items = saved.map { pairs -> NSPasteboardItem in let i = NSPasteboardItem(); for (t, d) in pairs { i.setData(d, forType: t) }; return i }
                if !items.isEmpty { board.writeObjects(items) }
            }
            Speech.cancel(); Speech.speakMessage(guess)
        }
    }
}
