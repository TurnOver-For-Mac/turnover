// SPDX-License-Identifier: GPL-3.0-or-later
// VoiceOver's find-by-formatting in a document (VO-Command-B, I, U, K, O, P and their Shift forms), where the text
// is an editable document (Word, TextEdit, Pages), not a web page. Only pages had them, and Word answered "not on a
// page" (a tester, 12 Oct 2026). The caret moves to the start of the next (or previous) run with that
// formatting, and the run is read, as VoiceOver reads what it finds.
import Foundation
import ApplicationServices

enum FormatSearch {
    /// What each search looks for: a key for a run's formatting, and whether a run with that key is a find. A find is
    /// where the key changes to a wanted one (into bold), so the bold word the caret is in is not found again.
    nonisolated struct Kind { let key: (FormatField) -> String; let wanted: (String) -> Bool; let detail: (FormatField) -> String? }

    @MainActor static let kinds: [String: Kind] = {
        func flag(_ on: @escaping (FormatField) -> Bool) -> Kind { Kind(key: { on($0) ? "y" : "n" }, wanted: { $0 == "y" }, detail: { _ in nil }) }
        return [
            "AXBoldFontSearchKey": flag { $0.bold },
            "AXItalicFontSearchKey": flag { $0.italic },
            "AXUnderlineSearchKey": flag { $0.underline },
            "AXPlainTextSearchKey": flag { !$0.bold && !$0.italic && !$0.underline },
            "AXFontColorChangeSearchKey": Kind(key: { $0.colour ?? "" }, wanted: { _ in true }, detail: { $0.colour }),
            "AXFontChangeSearchKey": Kind(key: { "\($0.fontName ?? "") \($0.fontSize ?? 0)" }, wanted: { _ in true },
                                          detail: { f in f.fontName.map { n in f.fontSize.map { "\(n) \($0) point" } ?? n } }),
        ]
    }()

    /// How far either way is searched, in characters (Word gives only the pages it has laid out, in any case).
    static let window = 50_000

    /// Find and move. False when this isn't a document TurnOver can search (the caller says so).
    @discardableResult
    static func find(_ searchKey: String, spoken: String, forward: Bool) -> Bool {
        guard let kind = kinds[searchKey], let obj = API.focusObject as? EditableText,
              let info = try? obj.makeTextInfo(.caret) as? AXTextInfo else { return false }
        let n = info.storyLength(), caret = info.start
        guard n > 0 else { Tones.edge(); Speech.speakMessage(Phrases.noNext(spoken, forward: forward)); return true }
        let lo = forward ? min(caret, n - 1) : max(0, caret - window), hi = forward ? min(n, caret + window) : min(n, caret + 1)
        guard hi > lo, let a = info.textElement.param(kAXAttributedStringForRangeParameterizedAttribute, axRangeValue(lo, hi - lo)) as? NSAttributedString,
              a.length > 0 else { return false }
        var runs: [(start: Int, end: Int, key: String, format: FormatField)] = []
        a.enumerateAttributes(in: NSRange(location: 0, length: a.length)) { attrs, r, _ in
            let f = AXTextInfo.format(from: attrs)
            let k = kind.key(f)
            if let last = runs.last, last.key == k { runs[runs.count - 1].end = lo + NSMaxRange(r) }   // one run per key
            else { runs.append((lo + r.location, lo + NSMaxRange(r), k, f)) }
        }
        guard let here = runs.lastIndex(where: { $0.start <= caret }) else { return false }
        let target: Int?
        if forward {
            target = runs.indices.first { $0 > here && kind.wanted(runs[$0].key) }
        } else {
            // Before the run the caret is in; the window's first run counts only if it starts the text.
            target = runs.indices.last { $0 < here && kind.wanted(runs[$0].key) && ($0 > 0 || runs[$0].start == 0) }
        }
        guard let t = target else { Tones.edge(); Speech.speakMessage(Phrases.noNext(spoken, forward: forward)); return true }
        let run = runs[t]
        info.setCaretOffset(run.start)
        obj.initAutoSelectDetection()
        var text = (a.string as NSString).substring(with: NSRange(location: run.start - lo, length: min(run.end - run.start, 200)))
        if let nl = text.firstIndex(where: \.isNewline) { text = String(text[..<nl]) }
        text = text.trimmingCharacters(in: .whitespaces)
        let said = [text.isEmpty ? "blank" : text, kind.detail(run.format)].compactMap { $0 }.joined(separator: ", ")
        Speech.speakMessage(said)
        return true
    }
}
