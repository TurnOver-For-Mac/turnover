// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import AppKit

/// Word's text through the page areas. Indices are document-global, so any page
/// area answers a range read; the caret is read from the object's own page area,
/// or from the neighbouring page when the caret has just crossed.
final class WordTextInfo: AXTextInfo {
    override func caretOffset() -> Int? {
        if let c = super.caretOffset() { return c }
        return neighbourSelection().map { $0.location + $0.length }
    }
    override func selectionOffsets() -> (Int, Int)? {
        if let s = super.selectionOffsets() { return s }
        return neighbourSelection().map { ($0.location, $0.location + $0.length) }
    }
    /// The pages before and after this one, when the caret has moved off it.
    private func neighbourSelection() -> CFRange? {
        let shared = textElement.elements("AXSharedTextUIElements")
        guard let i = shared.firstIndex(where: { $0.isSame(textElement) }) else { return nil }
        for j in [i + 1, i - 1] where shared.indices.contains(j) {
            if let r = cfRange(shared[j].attr(kAXSelectedTextRangeAttribute)), r.location != Int.max { return r }
        }
        return nil
    }
    override func setCaretOffset(_ o: Int) {
        // Setting the selection on a page area that does not hold the caret works: the index space is shared.
        super.setCaretOffset(o)
    }
    /// Lines are per page: AXLineForIndex on the wrong page answers with that page's last line
    /// (the repeated lines at page boundaries, 1 Oct 2026). Ask the page that holds the index.
    override func lineOffsets(_ offset: Int) -> (Int, Int)? {
        let module = obj.appModule as? WordAppModule
        let area = module?.pageArea(containing: offset, near: textElement) ?? textElement
        let n = storyLength()
        guard offset >= 0, n >= 0 else { return nil }
        // The empty last paragraph (after Return at the end): Word counts no mark for it, so the caret is past the end.
        if offset >= n, n > 0, let last = textRange(n - 1, n).last, last == "\r" || last == "\n" { return (n, n) }
        let probe = offset >= n && n > 0 ? n - 1 : offset
        guard let line = (area.param(kAXLineForIndexParameterizedAttribute, probe as CFNumber) as? NSNumber)?.intValue,
              let r = cfRange(area.param(kAXRangeForLineParameterizedAttribute, line as CFNumber)), r.length > 0 else { return nil }
        let (lineEnd, overflow) = r.location.addingReportingOverflow(r.length)
        let (storyEnd, storyOverflow) = n.addingReportingOverflow(1)
        guard r.location >= 0, !overflow, !storyOverflow, r.location <= n, lineEnd <= storyEnd else { return nil }
        // An empty paragraph is one paragraph mark; Word's line for its index can be the line after it.
        // The line must hold the index asked for, or the empty line is the mark itself.
        if offset < n, (offset < r.location || offset >= lineEnd) {
            let ch = textRange(offset, offset + 1)
            if ch == "\r" || ch == "\n" { return (offset, offset + 1) }
        }
        // Word answers the wrong page's last line when a page disappeared or moved between queries. Refuse that
        // line so the existing paragraph fallback can read the requested position instead of repeating old text.
        guard probe >= r.location, probe < lineEnd else { return nil }
        // Word's line can run past a paragraph mark into a table's stand-in ("Client details⏎Table, 6 Rows,
        // 2 Columns, , "): a line ends at its paragraph mark.
        var a = r.location, b = lineEnd
        let t = textRange(a, b) as NSString
        let base = a
        for i in 0..<max(0, t.length - 1) where t.character(at: i) == 13 || t.character(at: i) == 10 {
            if offset <= base + i { b = base + i + 1; break }
            a = base + i + 1
        }
        return (a, b)
    }
    /// The text Word puts in a page for a table: "Table, 6 Rows, 2 Columns, , ".
    static func isTableStandIn(_ text: String) -> Bool {
        text.range(of: #"^\s*Table, \d+ Rows, \d+ Columns"#, options: .regularExpression) != nil
    }
    /// Word puts the paragraph style in AXCustom ("Heading 1", "Paragraph"); NVDA says "heading level 1" as a line is read.
    override func controlFieldSpeech() -> (prefix: [String], text: String?) {
        pendingTones.removeAll()
        guard end > start, let a = textElement.param(kAXAttributedStringForRangeParameterizedAttribute, axRangeValue(start, min(end - start, 400))) as? NSAttributedString, a.length > 0 else { return ([], nil) }
        var prefix: [String] = []
        // The paragraph style at the start: a heading announces itself (speech, tone or nothing).
        if let custom = a.attributes(at: 0, effectiveRange: nil)[NSAttributedString.Key("AXCustom")] as? [String],
           let style = custom.first(where: { $0.hasPrefix("Heading") || $0 == "Title" }) {
            let level = Int(style.filter(\.isNumber)) ?? (style == "Title" ? 1 : 0)
            switch config.documentFormatting.headings {
            case .off: break
            case .tone: pendingTones.append { Tones.heading(level: level) }
            case .speech: prefix.append(level > 0 && config.documentFormatting.reportHeadingLevel ? Phrases.headingLevel(level) : Role.heading.displayString)
            }
        }
        // Annotations anywhere in the range (measured 2 Oct 2026): a comment is an AXAnnotation with an element and
        // no label; a grammar error carries AXAnnotationLabel "Grammatical error".
        var hasComment = false
        var labels: [String] = []
        a.enumerateAttribute(NSAttributedString.Key("AXAnnotation"), in: NSRange(location: 0, length: a.length)) { v, _, _ in
            for d in (v as? [[String: Any]]) ?? [] {
                if let label = d["AXAnnotationLabel"] as? String { if !labels.contains(label) { labels.append(label) } } else { hasComment = true }
            }
        }
        if hasComment {
            switch WordAppModule.commentReport {
            case .off: break
            case .tone: pendingTones.append { Tones.comment() }
            case .speech: prefix.append(String(localized: "comment", comment: "A Word comment, as a kind of thing to find"))
            }
        }
        for label in labels {
            switch config.documentFormatting.spellingErrors {
            case .off: break
            case .tone: pendingTones.append { Tones.spellingError() }
            case .speech: prefix.append(label.lowercased().replacingOccurrences(of: "grammatical", with: "grammar"))
            }
        }
        return (prefix, nil)
    }

    /// Asked on Word's script queue, never the main thread: two Apple Events of up to 5 s each, and on first use
    /// macOS's permission question, held TurnOver's main thread (E6 audit, 4 Oct 2026).
    override func locationText(_ done: @escaping (String?) -> Void) {
        guard let module = obj.appModule as? WordAppModule else { done(nil); return }
        module.script.selectionInformation { page, line in
            let parts = [page.map(Phrases.page), line.map { String(localized: "line \(String($0))", comment: "Where the caret is: the line number") }].compactMap { $0 }
            DispatchQueue.main.async { done(parts.isEmpty ? nil : parts.joined(separator: ", ")) }
        }
    }
}
