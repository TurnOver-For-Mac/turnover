// SPDX-License-Identifier: GPL-3.0-or-later
// Text ranges (NVDA: textInfos.TextInfo, textInfos.offsets.OffsetsTextInfo).
//
// A TextInfo is a range of text in an object, in offsets. It can expand to a
// unit (character, word, line, sentence, paragraph), move by units, compare
// its ends with another range, fetch its text and formatting, and put the
// caret or selection where it is. Everything the reader says about text goes
// through one of these, so a control that exposes text differently only has
// to subclass the primitives at the bottom.
import Foundation
import ApplicationServices
import TurnOverAX

public enum TextUnit { case character, word, line, sentence, paragraph, readingChunk, story }
public enum TextPosition { case first, last, caret, selection, all, bookmark(Bookmark) }
public enum EndPointComparison { case startToStart, startToEnd, endToStart, endToEnd }
public enum EndPoint { case start, end }

public struct Bookmark: Equatable { public let start: Int; public let end: Int
    public init(start: Int, end: Int) { self.start = start; self.end = end }
}

public struct TextInfoError: Error, CustomStringConvertible { public let description: String; public init(_ d: String) { description = d } }

/// Formatting at a position (NVDA: textInfos.FormatField).
public struct FormatField {
    public var fontName: String?
    public var fontSize: Int?
    public var bold = false
    public var italic = false
    public var underline = false
    public var strikethrough = false
    public var misspelled = false
    public var language: String?
    public var link = false
    /// For the detailed report (the command pressed twice): colour, background, super- or subscript, alignment.
    public var colour: String?
    public var background: String?
    public var superscript: Int = 0
    public var alignment: String?
    public var isEmpty: Bool { fontName == nil && fontSize == nil && !bold && !italic && !underline && !strikethrough && !misspelled && !link }
    public init() {}

    /// The detail JAWS gives on a second press (a tester, 8 Oct 2026): everything, plus colour and the rest.
    /// (The colour and alignment are kept in English, as values, and put into words here.)
    public var detailedDescription: String {
        var parts = [fullDescription]
        if let c = colour { parts.append(String(localized: "\(TextFormat.colour(c)) text", comment: "The text's colour: %@ is the colour (red text)")) }
        if let b = background, b != "white" { parts.append(String(localized: "on \(TextFormat.colour(b))", comment: "The colour behind the text: %@ is the colour (on yellow)")) }
        if superscript > 0 { parts.append(String(localized: "superscript", comment: "Text formatting")) } else if superscript < 0 { parts.append(String(localized: "subscript", comment: "Text formatting")) }
        if let a = alignment { parts.append(TextFormat.aligned(a)) }
        return parts.joined(separator: ", ")
    }

    /// A colour in words, near enough ("dark red", "light grey"): the detail is for hearing, not matching.
    public static func name(ofColour c: CGColor) -> String? {
        guard let rgb = c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil), let k = rgb.components, k.count >= 3 else { return nil }
        let r = Double(k[0]), g = Double(k[1]), b = Double(k[2])
        let mx = max(r, g, b), mn = min(r, g, b)
        if mx - mn < 0.08 { return mx < 0.2 ? "black" : mx > 0.92 ? "white" : mx < 0.5 ? "dark grey" : "light grey" }
        let d = mx - mn
        var h: Double
        if mx == r { h = (g - b) / d } else if mx == g { h = 2 + (b - r) / d } else { h = 4 + (r - g) / d }
        h *= 60; if h < 0 { h += 360 }
        let hue: String
        switch h {
        case ..<15, 345...: hue = "red"
        case 15..<45: hue = "orange"
        case 45..<70: hue = "yellow"
        case 70..<160: hue = "green"
        case 160..<200: hue = "turquoise"
        case 200..<260: hue = "blue"
        case 260..<300: hue = "purple"
        default: hue = "pink"
        }
        if hue == "orange", mx < 0.6 { return "brown" }
        return mx < 0.45 ? "dark \(hue)" : (mn > 0.6 ? "light \(hue)" : hue)
    }

    /// Everything, for the report-formatting command.
    public var fullDescription: String {
        var parts: [String] = []
        if let n = fontName { parts.append(n) }
        if let s = fontSize { parts.append(TextFormat.points(s)) }
        if bold { parts.append(TextFormat.bold) }
        if italic { parts.append(TextFormat.italic) }
        if underline { parts.append(TextFormat.underlined) }
        if strikethrough { parts.append(String(localized: "strikethrough", comment: "Text formatting")) }
        if link { parts.append(Role.link.displayString) }
        if misspelled { parts.append(String(localized: "spelling error", comment: "Said before a misspelled word")) }
        // The language by name ("English (United Kingdom)"), not its code ("en_GB").
        if let l = language { parts.append(Phrases.languageName(l)) }
        return parts.isEmpty ? String(localized: "plain", comment: "Text with no formatting") : parts.joined(separator: ", ")
    }
}

/// Formatting in words.
nonisolated public enum TextFormat {
    public static var bold: String { String(localized: "bold", comment: "Text formatting") }
    public static var italic: String { String(localized: "italic", comment: "Text formatting") }
    public static var underlined: String { String(localized: "underlined", comment: "Text formatting") }
    /// "12 point".
    public static func points(_ size: Int) -> String { String(localized: "\(String(size)) point", comment: "A font size: 12 point") }

    /// A colour named by FormatField.name(ofColour:) ("dark red", "light grey"), in the reader's language.
    public static func colour(_ english: String) -> String {
        if english.hasPrefix("dark ") { return String(localized: "dark \(colour(String(english.dropFirst(5))))", comment: "A colour: %@ is the colour (dark red)") }
        if english.hasPrefix("light ") { return String(localized: "light \(colour(String(english.dropFirst(6))))", comment: "A colour: %@ is the colour (light grey)") }
        switch english {
        case "red": return String(localized: "red", comment: "A colour")
        case "orange": return String(localized: "orange", comment: "A colour")
        case "yellow": return String(localized: "yellow", comment: "A colour")
        case "green": return String(localized: "green", comment: "A colour")
        case "turquoise": return String(localized: "turquoise", comment: "A colour")
        case "blue": return String(localized: "blue", comment: "A colour")
        case "purple": return String(localized: "purple", comment: "A colour")
        case "pink": return String(localized: "pink", comment: "A colour")
        case "brown": return String(localized: "brown", comment: "A colour")
        case "black": return String(localized: "black", comment: "A colour")
        case "white": return String(localized: "white", comment: "A colour")
        case "grey": return String(localized: "grey", comment: "A colour")
        default: return english
        }
    }

    /// Paragraph formatting Word reports (alignment and line spacing), by its English words.
    public static func word(_ english: String) -> String {
        switch english {
        case "centred": return String(localized: "centred", comment: "Paragraph alignment")
        case "right aligned": return String(localized: "right aligned", comment: "Paragraph alignment")
        case "left aligned": return String(localized: "left aligned", comment: "Paragraph alignment")
        case "justified": return String(localized: "justified", comment: "Paragraph alignment")
        case "distributed": return String(localized: "distributed", comment: "Paragraph alignment")
        case "double spacing": return String(localized: "double spacing", comment: "Paragraph line spacing")
        case "1.5 line spacing": return String(localized: "1.5 line spacing", comment: "Paragraph line spacing")
        case "single spacing": return String(localized: "single spacing", comment: "Paragraph line spacing")
        case "line spacing at least": return String(localized: "line spacing at least", comment: "Paragraph line spacing")
        case "exact line spacing": return String(localized: "exact line spacing", comment: "Paragraph line spacing")
        default: return english
        }
    }

    /// An alignment as FormatField keeps it ("left", "right", "centre", "justified"), in words.
    public static func aligned(_ alignment: String) -> String {
        switch alignment {
        case "left": return String(localized: "aligned left", comment: "Paragraph alignment")
        case "right": return String(localized: "aligned right", comment: "Paragraph alignment")
        case "centre": return String(localized: "aligned centre", comment: "Paragraph alignment")
        case "justified": return String(localized: "aligned justified", comment: "Paragraph alignment")
        default: return String(localized: "aligned \(alignment)", comment: "Paragraph alignment: %@ is how")
        }
    }
}

/// Offsets-based text range. Subclasses supply the primitives (story length,
/// text for a range, the caret and selection, line ranges); the units, moves
/// and comparisons are implemented here once, as NVDA's OffsetsTextInfo does.
open class TextInfo {
    public let obj: TurnOverObject
    public var start: Int
    public var end: Int

    public required init(obj: TurnOverObject, position: TextPosition) throws {
        self.obj = obj
        start = 0; end = 0
        switch position {
        case .first: start = 0; end = 0
        case .last: let n = storyLength(); start = n; end = n
        case .all: start = 0; end = storyLength()
        case .caret:
            guard let c = caretOffset() else { throw TextInfoError("no caret") }
            start = c; end = c
        case .selection:
            guard let (s, e) = selectionOffsets() else { throw TextInfoError("no selection") }
            start = s; end = e
        case .bookmark(let b): start = b.start; end = b.end
        }
    }

    public required init(obj: TurnOverObject, start: Int, end: Int) {
        self.obj = obj; self.start = start; self.end = end
    }

    // MARK: Primitives (override)

    open func storyLength() -> Int { 0 }
    /// Nil when counting characters would require fetching an unbounded text value.
    open func characterStoryLength() -> Int? { storyLength() }
    open func textRange(_ s: Int, _ e: Int) -> String { "" }
    /// Unexpanded source text: spoken attachment labels must not change UTF-16 positions.
    open func characterTextRange(_ s: Int, _ e: Int) -> String { textRange(s, e) }
    open func caretOffset() -> Int? { nil }
    open func selectionOffsets() -> (Int, Int)? { nil }
    open func setCaretOffset(_ o: Int) {}
    open func setSelectionOffsets(_ s: Int, _ e: Int) {}
    /// The line containing an offset, if the control knows its lines; nil means "use paragraphs".
    open func lineOffsets(_ offset: Int) -> (Int, Int)? { nil }
    open func formatField(at offset: Int) -> FormatField? { nil }
    /// The words in this range the application marks as misspelled, in order (at most five).
    open func misspelledWords() -> [String] { [] }
    /// Highlights and comments in this range (AXAnnotation: Pages, 18 Oct 2026): each one's label and its words.
    open func annotations() -> [(label: String, text: String)] { [] }
    /// The same, as ranges relative to this range's start, in order (for placing "spelling error" by offset).
    open func misspelledRanges() -> [NSRange] { [] }
    public static func misspelledRanges(in a: NSAttributedString) -> [NSRange] {
        var out: [NSRange] = []
        for key in ["AXMarkedMisspelled", "AXMisspelled"] {
            a.enumerateAttribute(NSAttributedString.Key(key), in: NSRange(location: 0, length: a.length)) { v, r, stop in
                guard (v as? NSNumber)?.boolValue == true, r.length > 0 else { return }
                if !out.contains(where: { NSIntersectionRange($0, r).length > 0 }) { out.append(r) }
                if out.count >= 5 { stop.pointee = true }
            }
        }
        return out.sorted { $0.location < $1.location }
    }
    public static func misspelled(in a: NSAttributedString) -> [String] {
        var out: [String] = []
        let ns = a.string as NSString
        for key in ["AXMarkedMisspelled", "AXMisspelled"] {
            a.enumerateAttribute(NSAttributedString.Key(key), in: NSRange(location: 0, length: a.length)) { v, r, stop in
                guard (v as? NSNumber)?.boolValue == true else { return }
                let w = ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                if !w.isEmpty, !out.contains(w) { out.append(w) }
                if out.count >= 5 { stop.pointee = true }
            }
        }
        return out
    }

    /// The language of the text at an offset ("ar", "fr-FR"), or nil when the document does not say.
    open func language(at offset: Int) -> String? { formatField(at: offset)?.language }

    /// The language of the range, from its first letter (NVDA switches voice on the format field's language).
    public func language() -> String? {
        let t = text as NSString
        var i = 0
        while i < t.length, let s = UnicodeScalar(t.character(at: i)), CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).contains(s) { i += 1 }
        guard i < t.length else { return nil }
        let l = language(at: start + i)
        // A label that cannot be right (Chrome labels unmarked Arabic as English): the text decides.
        if let l, !l.isEmpty { return Languages.contradicts(l, text) ? (Languages.detectUnmarked(text) ?? l) : l }
        // Not marked: text in another script than the reader's voice is recognised from its words (an Arabic
        // paragraph on a page that says nothing about its language; a tester).
        return Languages.detectUnmarked(text)
    }
    /// "page 3, line 12" where the control can tell (NVDA: locationText).
    open var locationText: String? { nil }
    /// The same, for an application that must be asked slowly (Word, by Apple Events): `done` on the main thread.
    open func locationText(_ done: @escaping (String?) -> Void) { done(locationText) }
    /// NVDA's control fields: what to say before the text (heading level, link, list) and,
    /// optionally, the text with inline markers ("link" before link runs). Documents override.
    open func controlFieldSpeech() -> (prefix: [String], text: String?) { ([], nil) }
    /// Sounds to play before the text (element kinds set to "tone"), collected by the last controlFieldSpeech.
    public var pendingTones: [() -> Void] = []

    // MARK: Units

    open func characterOffsets(_ offset: Int) -> (Int, Int) {
        guard let n = characterStoryLength() else { return (offset, offset) }
        return CharacterBoundaries.offsets(at: offset, length: n, read: characterTextRange) ?? (offset, offset)
    }

    /// NVDA's word unit: a run of word characters with its trailing whitespace; punctuation is its own word; a line break is a word.
    open func wordOffsets(_ offset: Int) -> (Int, Int) {
        let n = storyLength()
        let base = max(0, offset - 200)
        let chars = Array((textRange(base, min(n, offset + 200))).utf16)
        guard !chars.isEmpty else { return (offset, offset) }
        let local = min(max(offset - base, 0), chars.count - 1)
        enum Kind { case word, space, punct, newline }
        func kind(_ u: UInt16) -> Kind {
            if u == 13 || u == 10 || u == 0x2029 || u == 0x0B || u == 12 { return .newline }
            if u == 32 || u == 9 || u == 0xa0 { return .space }
            if let sc = Unicode.Scalar(u) {
                let c = Character(sc)
                if c.isLetter || c.isNumber || u == 0x27 || u == 0x2019 || u == 0x5f { return .word }
                return .punct
            }
            return .word   // a surrogate half: part of a word
        }
        let k = kind(chars[local])
        var s = local, e = local + 1
        if k == .newline { return (base + s, base + e) }
        if k == .space {
            // Whitespace after a word belongs to that word (NVDA); leading whitespace is its own unit.
            while s > 0 && kind(chars[s - 1]) == .space { s -= 1 }
            if s > 0 && kind(chars[s - 1]) != .newline {
                let k2 = kind(chars[s - 1]); var s2 = s
                while s2 > 0 && kind(chars[s2 - 1]) == k2 { s2 -= 1 }
                s = s2
            }
            while e < chars.count && kind(chars[e]) == .space { e += 1 }
            return (base + s, base + e)
        }
        while s > 0 && kind(chars[s - 1]) == k { s -= 1 }
        while e < chars.count && kind(chars[e]) == k { e += 1 }
        while e < chars.count && kind(chars[e]) == .space { e += 1 }
        return (base + s, base + e)
    }

    open func sentenceOffsets(_ offset: Int) -> (Int, Int) {
        let (ps, pe) = paragraphOffsets(offset)
        let para = textRange(ps, pe) as NSString
        var found: (Int, Int)?
        let local = offset - ps
        para.enumerateSubstrings(in: NSRange(location: 0, length: para.length), options: [.bySentences, .substringNotRequired]) { _, r, _, stop in
            if NSLocationInRange(local, r) || r.location > local { found = (ps + r.location, ps + r.location + r.length); stop.pointee = true }
        }
        return found ?? (ps, pe)
    }

    /// The paragraph containing an offset, including its terminating break (NVDA's paragraph unit).
    /// What say all reads at a time: a paragraph, unless a kind of text knows better (browse mode).
    open func readingChunkOffsets(_ offset: Int) -> (Int, Int) { paragraphOffsets(offset) }
    open func paragraphOffsets(_ offset: Int) -> (Int, Int) {
        let n = storyLength()
        let radius = 4000
        let base = max(0, offset - radius)
        let chars = Array(textRange(base, min(n, offset + radius)).utf16)
        guard !chars.isEmpty else { return (offset, offset) }
        let local = min(max(offset - base, 0), chars.count)
        func isBreak(_ u: UInt16) -> Bool { u == 13 || u == 10 || u == 0x2029 || u == 0x0B || u == 12 }
        var s = local
        while s > 0 && !isBreak(chars[s - 1]) { s -= 1 }
        var e = local
        while e < chars.count && !isBreak(chars[e]) { e += 1 }
        if e < chars.count { e += 1; if e < chars.count, chars[e - 1] == 13, chars[e] == 10 { e += 1 } }
        return (base + s, base + e)
    }

    public func unitOffsets(_ unit: TextUnit, _ offset: Int) -> (Int, Int) {
        switch unit {
        case .character: return characterOffsets(offset)
        case .word: return wordOffsets(offset)
        case .line: return lineOffsets(offset) ?? paragraphOffsets(offset)
        case .sentence: return sentenceOffsets(offset)
        case .paragraph: return paragraphOffsets(offset)
        case .readingChunk: return readingChunkOffsets(offset)
        case .story: return (0, storyLength())
        }
    }

    // MARK: Range operations

    public var isCollapsed: Bool { start >= end }
    public var text: String { isCollapsed ? "" : textRange(start, end) }
    public var bookmark: Bookmark { Bookmark(start: start, end: end) }

    public func collapse(toEnd: Bool = false) { if toEnd { start = end } else { end = start } }

    public func expand(_ unit: TextUnit) {
        let (s, e) = unitOffsets(unit, start)
        start = s; end = e
    }

    public func copy() -> Self { Self(obj: obj, start: start, end: end) }

    public func compareEndPoints(_ other: TextInfo, _ which: EndPointComparison) -> Int {
        let a: Int, b: Int
        switch which {
        case .startToStart: a = start; b = other.start
        case .startToEnd: a = start; b = other.end
        case .endToStart: a = end; b = other.start
        case .endToEnd: a = end; b = other.end
        }
        return a < b ? -1 : (a > b ? 1 : 0)
    }

    public func setEndPoint(_ other: TextInfo, _ which: EndPointComparison) {
        switch which {
        case .startToStart: start = other.start
        case .startToEnd: start = other.end
        case .endToStart: end = other.start
        case .endToEnd: end = other.end
        }
    }

    /// Move by whole units: the caret (collapsing the range first), or only its start or end. Forward, each step goes
    /// to the end of the unit the point is in; backward, to the start of the unit just before it. Stepping stops when
    /// the text runs out or a step gets nowhere. A caret or a start may not come to rest at the very end of the text
    /// (there is nothing there to read); the end of a range may. Returns the units moved, negative going back; 0, and
    /// nothing changed, if the point could not move.
    @discardableResult
    public func move(_ unit: TextUnit, _ direction: Int, endPoint: EndPoint? = nil) -> Int {
        guard direction != 0 else { return 0 }
        let length: Int
        if unit == .character {
            guard let n = characterStoryLength() else { return 0 }
            length = n
        } else { length = storyLength() }
        let forward = direction > 0
        var position = endPoint == .end ? end : start
        var moved = 0
        for _ in 0..<abs(direction) {
            let next: Int
            if forward {
                guard position < length else { break }
                let range = unitOffsets(unit, position)
                if unit == .character, range.0 == range.1 { break }
                next = range.1
            } else {
                guard position > 0 else { break }
                let range = unitOffsets(unit, position - 1)
                if unit == .character, range.0 == range.1 { break }
                next = range.0
            }
            guard forward ? next > position : next < position else { break }
            position = next
            moved += 1
        }
        let lastPlace = endPoint == .end ? length : length - 1
        guard moved > 0, position >= 0, position <= lastPlace else { return 0 }
        switch endPoint {
        case .end: end = position
        case .start: start = position
        case nil: start = position; end = position
        }
        if start > end { swap(&start, &end) }
        return forward ? moved : -moved
    }

    public func updateCaret() { setCaretOffset(start) }
    public func updateSelection() { setSelectionOffsets(start, end) }
    public func formatField() -> FormatField? { formatField(at: start) }

    /// Does this range contain the same text positions as another?
    public func isSame(_ other: TextInfo) -> Bool { start == other.start && end == other.end }
}

/// A TextInfo over any macOS accessibility element with text: AXNumberOfCharacters,
/// AXStringForRange, AXSelectedTextRange, AXLineForIndex/AXRangeForLine. Reads are
/// bounded (never the whole value), measured at 0.1 ms on a long Word document (about 350,000 characters).
open class AXTextInfo: TextInfo {
    /// The element whose text this is; subclasses may redirect (Word's page areas).
    nonisolated open var textElement: AXUIElement { obj.element }

    open override func storyLength() -> Int {
        if let n = textElement.int(kAXNumberOfCharactersAttribute) { return n }
        return (textElement.string(kAXValueAttribute) as NSString?)?.length ?? 0
    }

    open override func characterStoryLength() -> Int? {
        textElement.int(kAXNumberOfCharactersAttribute)
    }

    open override func textRange(_ s: Int, _ e: Int) -> String {
        let t = rawTextRange(s, e)
        return t.contains(Attachments.mark) ? Attachments.expand(t, in: textElement, from: max(0, s)) : t
    }

    open override func characterTextRange(_ s: Int, _ e: Int) -> String {
        guard let n = characterStoryLength() else { return "" }
        return rawTextRange(s, e, knownLength: n, valueLimit: CharacterBoundaries.maximumContextLength)
    }

    private func rawTextRange(_ s: Int, _ e: Int, knownLength: Int? = nil, valueLimit: Int? = nil) -> String {
        // Nothing lies past the end (WebKit answers a range at the end of a one-line field with "\n": "new line").
        let n = knownLength ?? storyLength()
        let e = min(e, n)
        guard e > s else { return "" }
        if let t = textElement.param(kAXStringForRangeParameterizedAttribute, axRangeValue(s, e - s)) as? String {
            return t
        }
        // Controls without parameterized attributes (a plain AppKit text field): slice the value.
        // Character probing may fetch a small field's value, never a whole large document.
        if let valueLimit, n > valueLimit { return "" }
        guard let v = textElement.string(kAXValueAttribute) else { return "" }
        let ns = v as NSString
        let cs = min(max(s, 0), ns.length), ce = min(max(e, cs), ns.length)
        return ns.substring(with: NSRange(location: cs, length: ce - cs))
    }

    open override func caretOffset() -> Int? {
        guard let r = cfRange(textElement.attr(kAXSelectedTextRangeAttribute)), r.location != Int.max, r.location >= 0 else { return nil }
        return r.location + r.length   // the active end; NVDA's caret in a selection is the end
    }

    open override func selectionOffsets() -> (Int, Int)? {
        guard let r = cfRange(textElement.attr(kAXSelectedTextRangeAttribute)), r.location != Int.max, r.location >= 0 else { return nil }
        return (r.location, r.location + r.length)
    }

    open override func setCaretOffset(_ o: Int) { _ = textElement.set(kAXSelectedTextRangeAttribute, axRangeValue(o, 0)) }
    open override func setSelectionOffsets(_ s: Int, _ e: Int) { _ = textElement.set(kAXSelectedTextRangeAttribute, axRangeValue(s, e - s)) }

    nonisolated(unsafe) static var warnedBadLines = false
    open override func lineOffsets(_ offset: Int) -> (Int, Int)? {
        let n = storyLength()
        // After a final paragraph mark the caret is on an empty last line of its own (Word, after Return at the end).
        if offset >= n, n > 0, let last = textRange(n - 1, n).last, last == "\r" || last == "\n" || last == "\u{2029}" { return (n, n) }
        let probe = offset >= n && n > 0 ? n - 1 : offset
        guard let line = (textElement.param(kAXLineForIndexParameterizedAttribute, probe as CFNumber) as? NSNumber)?.intValue,
              let r = cfRange(textElement.param(kAXRangeForLineParameterizedAttribute, line as CFNumber)) else { return nil }
        // A range outside the text is no answer (Spring's reply box gives 2147483647 for every line, 13 Oct 2026):
        // the paragraph stands in for the line, as when the app has no line queries at all.
        guard r.location >= 0, r.location <= n, r.length >= 0, r.location + r.length <= n + 1 else {
            if !Self.warnedBadLines { Self.warnedBadLines = true; Log.warning("text: the app's line range \(r.location)+\(r.length) is outside its \(n) characters; reading by paragraph instead") }
            return nil
        }
        return (r.location, r.location + r.length)
    }

    open override func annotations() -> [(label: String, text: String)] {
        guard end > start, let a = textElement.param(kAXAttributedStringForRangeParameterizedAttribute, axRangeValue(start, min(end - start, 4000))) as? NSAttributedString else { return [] }
        var out: [(label: String, text: String)] = []
        a.enumerateAttribute(NSAttributedString.Key("AXAnnotation"), in: NSRange(location: 0, length: a.length)) { v, r, _ in
            guard let list = v as? [AnyObject] else { return }
            for item in list {
                guard let d = item as? [String: Any] else { continue }
                let label = ((d["AXAnnotationLabel"] as? String) ?? "annotation").trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FFFC}")))
                let words = (a.string as NSString).substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
                if let last = out.last, last.label == label, words.isEmpty { continue }
                out.append((label, words))
            }
        }
        return out
    }

    open override func misspelledWords() -> [String] {
        guard end > start, end - start < 5000, end <= storyLength(),
              let a = textElement.param(kAXAttributedStringForRangeParameterizedAttribute, axRangeValue(start, end - start)) as? NSAttributedString else { return [] }
        return TextInfo.misspelled(in: a)
    }
    open override func misspelledRanges() -> [NSRange] {
        guard end > start, end - start < 5000, end <= storyLength(),
              let a = textElement.param(kAXAttributedStringForRangeParameterizedAttribute, axRangeValue(start, end - start)) as? NSAttributedString else { return [] }
        return TextInfo.misspelledRanges(in: a)
    }

    open override func formatField(at offset: Int) -> FormatField? {
        let n = storyLength()
        guard offset < n,
              let a = textElement.param(kAXAttributedStringForRangeParameterizedAttribute, axRangeValue(offset, 1)) as? NSAttributedString, a.length > 0 else { return nil }
        return Self.format(from: a.attributes(at: 0, effectiveRange: nil))
    }

    /// A run's formatting from its accessibility attributes (one character's, or a whole run's).
    public static func format(from attrs: [NSAttributedString.Key: Any]) -> FormatField {
        var f = FormatField()
        if let font = attrs[NSAttributedString.Key("AXFont")] as? [String: Any] {
            f.fontName = font["AXFontFamily"] as? String ?? font["AXFontName"] as? String
            if let size = font["AXFontSize"] as? NSNumber { f.fontSize = size.intValue }
            if let name = (font["AXFontName"] as? String)?.lowercased() {
                if name.contains("bold") { f.bold = true }
                if name.contains("italic") || name.contains("oblique") { f.italic = true }
            }
        }
        if let b = attrs[NSAttributedString.Key("AXFontBold")] as? NSNumber, b.boolValue { f.bold = true }
        if let i = attrs[NSAttributedString.Key("AXFontItalic")] as? NSNumber, i.boolValue { f.italic = true }
        if let u = attrs[NSAttributedString.Key("AXUnderline")] as? NSNumber, u.intValue != 0 { f.underline = true }
        if let s = attrs[NSAttributedString.Key("AXStrikethrough")] as? NSNumber, s.boolValue { f.strikethrough = true }
        // Word sends AXUnderlineColor and AXStrikethroughColor on every run; they mean nothing on their own.
        if let m = attrs[NSAttributedString.Key("AXMisspelled")] as? NSNumber, m.boolValue { f.misspelled = true }
        if let m = attrs[NSAttributedString.Key("AXMarkedMisspelled")] as? NSNumber, m.boolValue { f.misspelled = true }
        if attrs[NSAttributedString.Key("AXLink")] != nil { f.link = true }
        f.language = attrs[NSAttributedString.Key("AXLanguage")] as? String
        if let c = attrs[NSAttributedString.Key("AXForegroundColor")], CFGetTypeID(c as CFTypeRef) == CGColor.typeID { f.colour = FormatField.name(ofColour: c as! CGColor) }
        if let c = attrs[NSAttributedString.Key("AXBackgroundColor")], CFGetTypeID(c as CFTypeRef) == CGColor.typeID { f.background = FormatField.name(ofColour: c as! CGColor) }
        if let sup = attrs[NSAttributedString.Key("AXSuperscript")] as? NSNumber { f.superscript = sup.intValue }
        if let a = attrs[NSAttributedString.Key("AXTextAlignment")] as? NSNumber {
            f.alignment = ["left", "right", "centre", "justified"][safe: a.intValue]   // NSTextAlignment's order
        }
        return f
    }
}

/// Attachments in a text (Mail's recipient tokens: the To field's value is one U+FFFC per address, and
/// each address is a static text child). Each mark is replaced by its child's text, so "To, edit" says
/// who it is to, and the arrows read the address they pass over.
public enum Attachments {
    public static let mark: Character = "\u{FFFC}"

    /// The text of each attachment of an element, in order.
    public static func texts(of element: AXUIElement) -> [String] {
        element.elements(kAXChildrenAttribute).compactMap { c -> String? in
            let t = c.string(kAXValueAttribute) ?? c.string(kAXTitleAttribute) ?? c.string(kAXDescriptionAttribute)
            guard let t = t?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
    }

    /// Replace the marks in a slice of the element's text that starts at offset `from`.
    public static func expand(_ text: String, in element: AXUIElement, from: Int) -> String {
        let names = texts(of: element)
        guard !names.isEmpty else { return text.replacingOccurrences(of: String(mark), with: "") }
        // How many marks come before the slice: they number the first one in it.
        var index = 0
        if from > 0, let whole = element.string(kAXValueAttribute) {
            let before = (whole as NSString).substring(to: min(from, (whole as NSString).length))
            index = before.filter { $0 == mark }.count
        }
        var out = ""
        var previousWasMark = false
        for ch in text {
            if ch == mark {
                if previousWasMark { out += ", " }
                out += index < names.count ? names[index] : ""
                index += 1
                previousWasMark = true
            } else { out.append(ch); previousWasMark = false }
        }
        return out
    }
}


extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
