// SPDX-License-Identifier: GPL-3.0-or-later
// VoiceOver's find-by-formatting in a document (VO-Command-B, I, U, K, O, P and their Shift forms), where the text
// is an editable document (Word, TextEdit, Pages), not a web page. Only pages had them, and Word answered "not on a
// page" (a tester, 12 Oct 2026). The caret moves to the start of the next (or previous) run with that
// formatting, and the run is read, as VoiceOver reads what it finds.
import Foundation
import ApplicationServices

package enum FormatSearch {
    /// What each search looks for: a key for a run's formatting, and whether a run with that key is a find. A find is
    /// where the key changes to a wanted one (into bold), so the bold word the caret is in is not found again.
    package nonisolated struct Kind { let key: (FormatField) -> String; let wanted: (String) -> Bool; let detail: (FormatField) -> String? }

    @MainActor package static let kinds: [String: Kind] = {
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

    /// How many characters one read of the document takes. The search goes on chunk by chunk, so the whole document is
    /// searched either way (issue 201: backwards stopped 50,000 characters from the caret, "no bold text found" in a
    /// long document), and no one read holds the main thread for long.
    package static let chunk = 20_000
    /// The longest the whole search may take, in seconds, so a huge document never holds the main thread for long.
    package static let budget: TimeInterval = 2.5

    package enum Outcome { case found(start: Int, text: String, format: FormatField), none, failed }

    /// The search itself, on a document of `n` characters with the caret at `caret`. `fetch` reads the formatted text of a
    /// range. A run is found where the key changes to a wanted one; the run the caret is in is never found.
    package static func search(kind: Kind, n: Int, caret: Int, forward: Bool, chunk: Int = FormatSearch.chunk, budget: TimeInterval = FormatSearch.budget,
                       fetch: (_ lo: Int, _ hi: Int) -> NSAttributedString?) -> Outcome {
        let started = Date()
        // Forwards each chunk starts at `cursor`; backwards each chunk ends at `end`, and `probe` is a place known to lie in the
        // run the caret is in, whose start (`limit`) is found once a chunk shows that run from its start.
        var cursor = forward ? min(caret, n - 1) : 0
        var end = min(n, caret + 1), probe = min(caret, n - 1)
        var limit: Int?
        while true {
            let lo = forward ? cursor : max(0, end - chunk), hi = forward ? min(n, cursor + chunk) : end
            guard hi > lo, let a = fetch(lo, hi), a.length > 0 else { return .failed }
            var runs: [(start: Int, end: Int, key: String, format: FormatField)] = []
            a.enumerateAttributes(in: NSRange(location: 0, length: a.length)) { attrs, r, _ in
                let f = AXTextInfo.format(from: attrs)
                let k = kind.key(f)
                if let last = runs.last, last.key == k { runs[runs.count - 1].end = lo + NSMaxRange(r) }   // one run per key
                else { runs.append((lo + r.location, lo + NSMaxRange(r), k, f)) }
            }
            let target: Int?
            if forward {
                guard let here = runs.lastIndex(where: { $0.start <= cursor }) else { return .failed }
                target = runs.indices.first { $0 > here && kind.wanted(runs[$0].key) }
            } else {
                if limit == nil, let h = runs.lastIndex(where: { $0.start <= probe }), h > 0 || runs[h].start == 0 { limit = runs[h].start }
                // Before the caret's run. The chunk's first run is cut at its left edge unless the chunk starts the text: its
                // start is not known, so it counts only then; the next chunk, which overlaps this one, sees it whole.
                target = limit.flatMap { l in runs.indices.last { runs[$0].start < l && kind.wanted(runs[$0].key) && ($0 > 0 || runs[$0].start == 0) } }
            }
            if let t = target {
                let run = runs[t]
                var text = (a.string as NSString).substring(with: NSRange(location: run.start - lo, length: min(run.end - run.start, 200)))
                if let nl = text.firstIndex(where: \.isNewline) { text = String(text[..<nl]) }
                return .found(start: run.start, text: text.trimmingCharacters(in: .whitespaces), format: run.format)
            }
            if forward ? hi >= n : lo == 0 { return .none }
            if Date().timeIntervalSince(started) > budget { Log.io("format search: stopped after \(budget) s without covering the document"); return .none }
            if forward { cursor = runs.count > 1 ? runs[runs.count - 1].start : hi - 1 }
            else { probe = lo; end = lo + max(1, chunk / 2) }
        }
    }

    /// Find and move. False when this isn't a document TurnOver can search (the caller says so).
    @discardableResult
    static func find(_ searchKey: String, spoken: String, forward: Bool) -> Bool {
        guard let kind = kinds[searchKey], let obj = API.focusObject as? EditableText,
              let info = try? obj.makeTextInfo(.caret) as? AXTextInfo else { return false }
        let n = info.storyLength(), caret = info.start
        guard n > 0 else { Tones.edge(); Speech.speakMessage(Phrases.noNext(spoken, forward: forward)); return true }
        let outcome = search(kind: kind, n: n, caret: caret, forward: forward) { lo, hi in
            info.textElement.param(kAXAttributedStringForRangeParameterizedAttribute, axRangeValue(lo, hi - lo)) as? NSAttributedString
        }
        switch outcome {
        case .failed: return false
        case .none: Tones.edge(); Speech.speakMessage(Phrases.noNext(spoken, forward: forward)); return true
        case .found(let start, let text, let format):
            info.setCaretOffset(start)
            obj.initAutoSelectDetection()
            let said = [text.isEmpty ? Phrases.blank : text, kind.detail(format)].compactMap { $0 }.joined(separator: ", ")
            Speech.speakMessage(said)
            return true
        }
    }
}
