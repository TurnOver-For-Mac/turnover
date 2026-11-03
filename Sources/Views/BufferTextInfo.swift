// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverAX

/// A TextInfo over the buffer: offsets in its text; lines from its table; the element behind any offset.
public final class BufferTextInfo: TextInfo {
    private(set) var buffer: WebBuffer
    private weak var document: BrowseModeDocument?
    private var documentGeneration: Int

    public required init(obj: TurnOverObject, position: TextPosition) throws {
        let owner = (obj as? WebArea)?.document
        document = owner; documentGeneration = owner?.pageGeneration ?? 0
        buffer = owner?.buffer.frozen() ?? WebBuffer(webArea: obj.element)
        try super.init(obj: obj, position: position)
    }
    public required init(obj: TurnOverObject, start: Int, end: Int) {
        let owner = (obj as? WebArea)?.document
        document = owner; documentGeneration = owner?.pageGeneration ?? 0
        buffer = owner?.buffer.frozen() ?? WebBuffer(webArea: obj.element)
        super.init(obj: obj, start: start, end: end)
    }
    public override func copy() -> Self {
        let result = super.copy()
        result.buffer = buffer; result.document = document; result.documentGeneration = documentGeneration
        return result
    }
    public var previousChain: [AXUIElement]?
    public private(set) var chain: [AXUIElement] = []

    public override func storyLength() -> Int { buffer.text.length }
    public override func characterOffsets(_ offset: Int) -> (Int, Int) {
        CharacterBoundaries.offsets(in: buffer.text, at: offset) ?? (offset, offset)
    }
    public override func textRange(_ s: Int, _ e: Int) -> String {
        let n = buffer.text.length
        let a = max(0, min(s, n)), b = max(a, min(e, n))
        return buffer.text.substring(with: NSRange(location: a, length: b - a))
    }
    public override func caretOffset() -> Int? { document?.position }
    public override func selectionOffsets() -> (Int, Int)? { caretOffset().map { ($0, $0) } }
    public override func setCaretOffset(_ o: Int) {
        guard let document, document.pageGeneration == documentGeneration, document.buffer.revision == buffer.revision else { return }
        document.position = o
    }
    public override func lineOffsets(_ offset: Int) -> (Int, Int)? {
        guard let i = buffer.lineIndex(at: offset) else { return nil }
        let l = buffer.lines[i]
        return (l.start, l.endWithBreak)
    }
    public override func paragraphOffsets(_ offset: Int) -> (Int, Int) { lineOffsets(offset) ?? characterOffsets(offset) }
    /// Say all reads a line at a time, as NVDA does; a long paragraph is wrapped into 100-character lines. Kokoro says
    /// each piece as a whole sentence, so "users of" ended like a full stop (12 Oct 2026: "the say all went a
    /// bit weird"). For Kokoro the pieces of one wrapped line are read together, up to about 600 characters.
    public override func readingChunkOffsets(_ offset: Int) -> (Int, Int) {
        guard KokoroVoice.wanted(reading: true), var i = buffer.lineIndex(at: offset) else { return paragraphOffsets(offset) }
        let start = buffer.lines[i].start
        while !buffer.lines[i].hasBreak, i + 1 < buffer.lines.count, buffer.lines[i + 1].start == buffer.lines[i].end,
              buffer.lines[i + 1].end - start <= 600 { i += 1 }
        return (start, buffer.lines[i].endWithBreak)
    }
    public override func sentenceOffsets(_ offset: Int) -> (Int, Int) {
        guard let (ls, le) = lineOffsets(offset) else { return characterOffsets(offset) }
        let line = textRange(ls, le) as NSString
        var found: (Int, Int)?
        let local = offset - ls
        line.enumerateSubstrings(in: NSRange(location: 0, length: line.length), options: [.bySentences, .substringNotRequired]) { _, r, _, stop in
            if NSLocationInRange(local, r) || r.location > local { found = (ls + r.location, ls + r.location + r.length); stop.pointee = true }
        }
        return found ?? (ls, le)
    }
    public override func formatField(at offset: Int) -> FormatField? {
        var f = FormatField()
        if let s = buffer.segment(at: offset), s.isLink { f.link = true }
        return f
    }
    /// WebKit puts the lang attribute on each element (AXLanguage), not in the text's attributes (measured 6 Oct 2026).
    public override func language(at offset: Int) -> String? { buffer.withSnapshot { element(at: offset)?.string("AXLanguage") } }
    public func element(at offset: Int) -> AXUIElement? {
        buffer.segment(at: offset)?.element ?? buffer.lineIndex(at: offset).flatMap { buffer.lines[$0].element }
    }

    /// The quote level last said, so it is said only when it changes.
    static var lastQuoteLevel = 0

    public override func controlFieldSpeech() -> (prefix: [String], text: String?) {
        buffer.withSnapshot { controlFieldSpeechInSnapshot() }
    }
    private func controlFieldSpeechInSnapshot() -> (prefix: [String], text: String?) {
        pendingTones.removeAll()
        guard let i = buffer.lineIndex(at: start) else { return ([], nil) }
        let line = buffer.lines[i]
        var prefix: [String] = []
        // Containers entered by any line inside the range (a heading's line carries "heading level 2").
        var entering: [AXUIElement] = []
        var j = i
        while j < buffer.lines.count, buffer.lines[j].start < end { entering.append(contentsOf: buffer.lines[j].entering); j += 1 }
        chain = entering
        for el in entering {
            if let prev = previousChain, prev.contains(where: { $0.isSame(el) }) { continue }
            let (mode, tone) = WebTextInfo.reporting(for: el)
            switch mode {
            case .off: continue
            case .tone: if let tone { pendingTones.append(tone) }
            case .speech: if let s = WebTextInfo.describe(el, forEntering: true), prefix.last != s { prefix.append(s) }
            }
        }
        // Quote levels (Mail's quoted replies): WebKit gives each piece of text its level, AXBlockQuoteLevel, which is
        // what VoiceOver reads; Mail's quotes carry no container TurnOver could see (a tester, 7 Oct 2026: none said).
        // Said as the level changes, as VoiceOver does.
        if let lvl = (element(at: start)?.attr("AXBlockQuoteLevel") as? NSNumber)?.intValue, lvl != Self.lastQuoteLevel {
            if lvl > 0 {
                switch config.documentFormatting.blockQuotes {
                case .speech: prefix.append(String(localized: "quote level \(String(lvl))", comment: "How deep a quote is in a Mail message"))
                case .tone: pendingTones.append { Tones.blockQuote() }
                case .off: break
                }
            }
            Self.lastQuoteLevel = lvl
        }
        if line.isControl {
            // "button Create", then its states and value (NVDA's control field, role first).
            let role = line.fields.first.map { [$0] } ?? []
            let rest = Array(line.fields.dropFirst())
            let name = textRange(start, end).trimmingCharacters(in: .whitespacesAndNewlines)
            // VoiceOver's order: "Create, button", then its states.
            if config.documentFormatting.rolesAfterText {
                return (prefix, ([name] + role.map { Speech.ui($0) } + rest).filter { !$0.isEmpty }.joined(separator: ", "))
            }
            return (prefix + role, (name + (rest.isEmpty ? "" : ", " + rest.joined(separator: ", "))))
        }
        // Links inline.
        let linkMode = config.documentFormatting.links
        var pieces: [String] = []
        var lastLink: AXUIElement?
        var cursor = start
        for s in buffer.segments where s.end > start && s.start < end {
            if s.start > cursor { pieces.append(textRange(cursor, s.start)) }
            let a = max(s.start, start), b = min(s.end, end)
            // A word or character inside a link that began before it (reading "about us" word by word): the link was
            // said on its first word, not again on each (a tester, 7 Oct 2026). A line that starts part way through a
            // link still says it.
            let insideEarlierLink = s.start < start && start > line.start
            let after = config.documentFormatting.rolesAfterText
            if s.isLink, !insideEarlierLink, lastLink.map({ !$0.isSame(s.element) }) ?? true {
                switch linkMode {
                case .speech: if !after { pieces.append(" " + Speech.ui(Role.link.displayString) + " ") }
                case .tone: pendingTones.append { Tones.link() }
                case .off: break
                }
            }
            lastLink = s.isLink ? s.element : nil
            pieces.append(textRange(a, b))
            // VoiceOver's order: "About us, link", where the link ends (once, on the piece that ends it).
            if after, s.isLink, linkMode == .speech, s.end <= end, !(s.start < start && start > line.start && s.end > end) {
                pieces.append(", " + Speech.ui(Role.link.displayString) + " ")
            }
            cursor = b
        }
        if cursor < end { pieces.append(textRange(cursor, end)) }
        return (prefix, pieces.joined().replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces))
    }
}
