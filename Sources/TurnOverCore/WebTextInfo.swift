// SPDX-License-Identifier: GPL-3.0-or-later
// Text in WebKit documents (Safari, Mail's message bodies, Help) through the
// text-marker API that VoiceOver uses: opaque positions, with WebKit doing the
// unit arithmetic. The TextInfo keeps offsets (AXIndexForTextMarker /
// AXTextMarkerForIndex round-trip exactly), so NVDA's offsets-based moves and
// comparisons work unchanged; every unit query goes to WebKit.
//
// Measured on Safari, 1 Oct 2026: line/word/sentence/paragraph ranges 0.05–0.2 ms,
// AXUIElementsForSearchPredicate 0.1–0.8 ms, headings carry their level in AXValue.
import Foundation
import ApplicationServices
import TurnOverAX

/// The calls on a web area element, typed.
nonisolated public final class WebDocumentBridge: Sendable {
    public let webArea: AXUIElement
    public init(webArea: AXUIElement) { self.webArea = webArea }

    public func marker(at index: Int) -> AXTextMarker? {
        guard let v = webArea.param("AXTextMarkerForIndex", max(0, index) as CFNumber), CFGetTypeID(v) == AXTextMarkerGetTypeID() else { return nil }
        return (v as! AXTextMarker)
    }
    public func index(of marker: AXTextMarker) -> Int? {
        (webArea.param("AXIndexForTextMarker", marker) as? NSNumber)?.intValue
    }
    public func range(_ s: Int, _ e: Int) -> AXTextMarkerRange? {
        guard let a = marker(at: s), let b = marker(at: e) else { return nil }
        return AXTextMarkerRangeCreate(kCFAllocatorDefault, a, b)
    }
    public func indices(of range: AXTextMarkerRange) -> (Int, Int)? {
        guard let s = index(of: AXTextMarkerRangeCopyStartMarker(range)), let e = index(of: AXTextMarkerRangeCopyEndMarker(range)) else { return nil }
        return (min(s, e), max(s, e))
    }
    public func string(_ range: AXTextMarkerRange) -> String {
        webArea.param("AXStringForTextMarkerRange", range) as? String ?? ""
    }
    public func attributedString(_ range: AXTextMarkerRange) -> NSAttributedString? {
        webArea.param("AXAttributedStringForTextMarkerRange", range) as? NSAttributedString
    }
    public func documentRange() -> AXTextMarkerRange? {
        guard let v = webArea.param("AXTextMarkerRangeForUIElement", webArea), CFGetTypeID(v) == AXTextMarkerRangeGetTypeID() else { return nil }
        return (v as! AXTextMarkerRange)
    }
    public func documentLength() -> Int {
        guard let r = documentRange() else { return 0 }
        return (webArea.param("AXLengthForTextMarkerRange", r) as? NSNumber)?.intValue ?? 0
    }
    /// A unit range around an index: "AXLineTextMarkerRangeForTextMarker" and friends.
    public func unitRange(_ attribute: String, at index: Int) -> (Int, Int)? {
        guard let m = marker(at: index), let v = webArea.param(attribute, m), CFGetTypeID(v) == AXTextMarkerRangeGetTypeID() else { return nil }
        return indices(of: v as! AXTextMarkerRange)
    }
    /// The next or previous position: "AXNextTextMarkerForTextMarker" and friends.
    public func step(_ attribute: String, from index: Int) -> Int? {
        guard let m = marker(at: index), let v = webArea.param(attribute, m), CFGetTypeID(v) == AXTextMarkerGetTypeID() else { return nil }
        return self.index(of: v as! AXTextMarker)
    }
    public func element(at index: Int) -> AXUIElement? {
        guard let m = marker(at: index), let v = webArea.param("AXUIElementForTextMarker", m), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    public func range(of element: AXUIElement) -> (Int, Int)? {
        guard let v = webArea.param("AXTextMarkerRangeForUIElement", element), CFGetTypeID(v) == AXTextMarkerRangeGetTypeID() else { return nil }
        return indices(of: v as! AXTextMarkerRange)
    }
    public func selection() -> (Int, Int)? {
        guard let v = webArea.attr("AXSelectedTextMarkerRange"), CFGetTypeID(v) == AXTextMarkerRangeGetTypeID() else { return nil }
        return indices(of: v as! AXTextMarkerRange)
    }
    public func setSelection(_ s: Int, _ e: Int) {
        guard let r = range(s, e) else { return }
        _ = webArea.set("AXSelectedTextMarkerRange", r)
    }
    /// WebKit's structural search (NVDA: _iterNodesByType). Keys are WebKit's AX*SearchKey strings.
    public func search(key: String, from element: AXUIElement, forward: Bool, limit: Int = 1) -> [AXUIElement] {
        let predicate: [String: Any] = [
            "AXSearchKey": key, "AXDirection": forward ? "AXDirectionNext" : "AXDirectionPrevious",
            "AXResultsLimit": limit, "AXStartElement": element, "AXImmediateDescendantsOnly": false, "AXVisibleOnly": false,
        ]
        return (webArea.param("AXUIElementsForSearchPredicate", predicate as CFDictionary) as? [AXUIElement]) ?? []
    }
    public var isValid: Bool { webArea.role != "?" }
}

/// An object whose text is WebKit's (read through text markers).
public protocol WebBridged: AnyObject { var bridge: WebDocumentBridge { get } }

/// An editable web area: Mail's compose body, a page's rich-text editor. It is typed into, never browsed:
/// TurnOver's edit-field behaviour over WebKit's own text and caret. (2 Oct 2026: in browse mode, typing into
/// Mail's body became quick navigation, "h" a heading, "e" an edit field.)
open class EditableWebArea: EditableText, WebBridged {
    public lazy var bridge = WebDocumentBridge(webArea: element)
    open override var role: Role { .editableText }
    open override var textInfoClass: TextInfo.Type { WebTextInfo.self }
    open override var name: String { element.string(kAXTitleAttribute) ?? element.string(kAXDescriptionAttribute) ?? "" }

    /// A web area whose text can be set is being edited (its AXValue is settable; a page's is not).
    public static func isEditable(_ e: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(e, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
    }
}

/// A web area, the document object (NVDA: the root NVDAObject of a browse mode document).
open class WebArea: TurnOverObject, WebBridged {
    public lazy var bridge = WebDocumentBridge(webArea: element)
    open override var role: Role { .document }
    open override var hasNavigableText: Bool { true }
    /// Browse mode reads the virtual buffer; without a document (not in browse mode) WebKit's own text.
    open override var textInfoClass: TextInfo.Type { document != nil ? BufferTextInfo.self : WebTextInfo.self }
    /// The browse-mode document holding the virtual caret, when one exists for this web area.
    public var document: BrowseModeDocument? { BrowseModeHandler.shared.existingDocument(for: element) }
    open override var name: String { element.string(kAXTitleAttribute) ?? "" }
}

public final class WebTextInfo: TextInfo {
    // A web object's own bridge; any other object's element bridged afresh, never a crash.
    var bridge: WebDocumentBridge { (obj as? WebBridged)?.bridge ?? WebDocumentBridge(webArea: obj.element) }
    private var cachedLength: Int?

    public override func storyLength() -> Int {
        if let n = cachedLength { return n }
        let n = bridge.documentLength(); cachedLength = n; return n
    }
    public override func textRange(_ s: Int, _ e: Int) -> String {
        guard e > s, let r = bridge.range(s, e) else { return "" }
        return bridge.string(r)
    }
    /// The virtual caret, when browse mode owns one; otherwise WebKit's selection.
    public override func caretOffset() -> Int? {
        if let d = (obj as? WebArea)?.document { return d.position }
        return bridge.selection().map { $0.1 }
    }
    public override func selectionOffsets() -> (Int, Int)? {
        if let d = (obj as? WebArea)?.document { return (d.position, d.position) }
        return bridge.selection()
    }
    public override func setCaretOffset(_ o: Int) {
        // The virtual caret; WebKit's selection is left alone (setting it makes Safari move its focus and speak).
        if let d = (obj as? WebArea)?.document { d.position = o } else { bridge.setSelection(o, o) }
    }
    public override func setSelectionOffsets(_ s: Int, _ e: Int) { bridge.setSelection(s, e) }

    // Every unit must end after the offset, or NVDA's move loop stalls: at the end of a line WebKit's
    // "line for marker" is the line just finished, so the "right" and "next end" forms are the fallbacks.
    // Characters use the shared composed-sequence reader over UTF-16 indices. WebKit's "next
    // text marker" skips a break and the following letter together (measured 1 Oct 2026).
    private func unit(_ containing: String, _ right: String?, _ nextEnd: String, at offset: Int) -> (Int, Int)? {
        // A caret on the break that ends a line belongs to the line after it (asked at the break, WebKit
        // answers with the line before, break included: every line was read twice, 2 Oct 2026).
        var offset = offset
        if offset < storyLength(), textRange(offset, offset + 1) == "\n" {
            // A break with a break (or the start) before it is an empty line of its own: the caret is on it (Mail's
            // blank line between paragraphs was read as the paragraph after it, 2 Oct 2026).
            if offset == 0 || textRange(offset - 1, offset) == "\n" { return (offset, offset + 1) }
            offset += 1
        }
        var found: (Int, Int)?
        if let r = bridge.unitRange(containing, at: offset), r.1 > offset, r.0 <= offset { found = r }
        else if let right, let r = bridge.unitRange(right, at: offset), r.1 > offset { found = (min(r.0, offset), r.1) }
        else if let e = bridge.step(nextEnd, from: offset), e > offset { found = (offset, e) }
        guard let found else { return nil }
        var a = found.0; let b = found.1
        // A unit that begins on the break before it belongs to the element after the break.
        while a < b - 1, textRange(a, a + 1) == "\n" { a += 1 }
        return (a, b)
    }
    public override func wordOffsets(_ offset: Int) -> (Int, Int) {
        unit("AXRightWordTextMarkerRangeForTextMarker", "AXLeftWordTextMarkerRangeForTextMarker", "AXNextWordEndTextMarkerForTextMarker", at: offset) ?? characterOffsets(offset)
    }
    static let controlRoles: Set<String> = ["AXButton", "AXLink", "AXPopUpButton", "AXComboBox", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXMenuItem", "AXImage", "AXSlider", "AXMenuButton"]

    public override func lineOffsets(_ offset: Int) -> (Int, Int)? {
        // A control is a line of its own (NVDA's buffer puts each button and link on its own line); WebKit's
        // line for a row of buttons is the whole row.
        // The caret after the last character (Command+Down in Mail's message) is on the last line, unless that
        // line has ended: no unit ends after the very end, so ask for the line of the last character.
        let n = storyLength()
        if offset >= n, n > 0 {
            if textRange(n - 1, n) == "\n" { return (n, n) }
            return lineOffsets(n - 1)
        }
        var probe = offset
        var lineAt = offset
        if probe < storyLength(), textRange(probe, probe + 1) == "\n" {
            if probe == 0 || textRange(probe - 1, probe) == "\n" { return (probe, probe + 1) }   // an empty line
            if obj is EditableWebArea {
                // Editing, the caret on the break that ends a line is at the end of that line: after a deletion left it
                // after "testers.", Down read the empty line below, and lines went missing (Mail, 5 Oct 2026).
                probe -= 1; lineAt = probe
            } else {
                probe += 1
            }
        }
        if let el = bridge.element(at: probe), Self.controlRoles.contains(el.role), let r = bridge.range(of: el), r.1 > probe, r.0 <= probe, r.1 - r.0 < 300 {
            return r
        }
        // Where WebKit has no line for a position (YouTube's rows of buttons), the paragraph stands in — wrapped like any line.
        guard let (a, b) = unit("AXLineTextMarkerRangeForTextMarker", "AXRightLineTextMarkerRangeForTextMarker", "AXNextLineEndTextMarkerForTextMarker", at: lineAt)
                ?? unit("AXParagraphTextMarkerRangeForTextMarker", nil, "AXNextParagraphEndTextMarkerForTextMarker", at: lineAt) else { return nil }
        // NVDA's virtual buffer wraps at maxLineLength: a one-paragraph e-mail reads in pieces, not as one line.
        // Not where the user edits (Mail's compose window), the app moves the caret by its own
        // lines, and a 100-character piece of one dropped the words after it ("response from", 5 Oct 2026).
        let maxLen = max(20, config.virtualBuffers.maxLineLength)
        guard b - a > maxLen, !(obj is EditableWebArea) else { return (a, b) }
        let text = Array(textRange(a, b).utf16)
        var start = 0
        while start < text.count {
            var end = min(start + maxLen, text.count)
            if end < text.count {
                var cut = end
                while cut > start + maxLen / 2, text[cut - 1] != 32, text[cut - 1] != 9 { cut -= 1 }
                if cut > start + maxLen / 2 { end = cut }
            }
            if offset < a + end || end == text.count { return (a + start, a + end) }
            start = end
        }
        return (a, b)
    }
    public override func sentenceOffsets(_ offset: Int) -> (Int, Int) {
        unit("AXSentenceTextMarkerRangeForTextMarker", nil, "AXNextSentenceEndTextMarkerForTextMarker", at: offset) ?? paragraphOffsets(offset)
    }
    public override func paragraphOffsets(_ offset: Int) -> (Int, Int) {
        unit("AXParagraphTextMarkerRangeForTextMarker", nil, "AXNextParagraphEndTextMarkerForTextMarker", at: offset) ?? lineOffsets(offset) ?? characterOffsets(offset)
    }

    public override func language(at offset: Int) -> String? { bridge.element(at: offset)?.string("AXLanguage") }

    public override func formatField(at offset: Int) -> FormatField? {
        guard let r = bridge.range(offset, offset + 1), let a = bridge.attributedString(r), a.length > 0 else { return nil }
        let attrs = a.attributes(at: 0, effectiveRange: nil)
        var f = FormatField()
        if let font = attrs[NSAttributedString.Key("AXFont")] as? [String: Any] {
            f.fontName = font["AXFontFamily"] as? String ?? font["AXFontName"] as? String
            if let size = font["AXFontSize"] as? NSNumber { f.fontSize = size.intValue }
            if let name = (font["AXFontName"] as? String)?.lowercased() {
                if name.contains("bold") { f.bold = true }
                if name.contains("italic") || name.contains("oblique") { f.italic = true }
            }
        }
        // (WebKit marks a misspelling AXMarkedMisspelled; only the older AXMisspelled was read, so Safari's fields
        // never said "spelling error": a tester, AppleVis, 9 Oct 2026.)
        if let m = attrs[NSAttributedString.Key("AXMisspelled")] as? NSNumber, m.boolValue { f.misspelled = true }
        if let m = attrs[NSAttributedString.Key("AXMarkedMisspelled")] as? NSNumber, m.boolValue { f.misspelled = true }
        if attrs[NSAttributedString.Key("AXLink")] != nil { f.link = true }
        return f
    }

    public override func misspelledWords() -> [String] {
        guard end > start, end - start < 5000, let r = bridge.range(start, end), let a = bridge.attributedString(r) else { return [] }
        return TextInfo.misspelled(in: a)
    }

    /// The element containing the start, and its ancestors inside the web area, nearest first.
    public func elementsAtStart() -> [AXUIElement] {
        guard let el = bridge.element(at: start) else { return [] }
        var out = [el]
        var e = el.element(kAXParentAttribute)
        while let p = e, out.count < 12 {
            if p.isSame(bridge.webArea) || p.role == "AXWebArea" { break }
            out.append(p)
            e = p.element(kAXParentAttribute)
        }
        return out
    }

    /// The containers the previous reading was inside; only new ones are announced (NVDA: SpeakTextInfoState).
    public var previousChain: [AXUIElement]?
    /// The chain this reading is inside, for the next one.
    public private(set) var chain: [AXUIElement] = []

    /// NVDA's control fields for speech: what the text is entering (heading level 2, link, list…),
    /// outermost first, plus "link" before each link run inside the range.
    public override func controlFieldSpeech() -> (prefix: [String], text: String?) {
        var prefix: [String] = []
        pendingTones.removeAll()
        chain = elementsAtStart()
        for el in chain.reversed() {
            if let prev = previousChain, prev.contains(where: { $0.isSame(el) }) { continue }
            let (mode, tone) = Self.reporting(for: el)
            switch mode {
            case .off: continue
            case .tone: if let tone { pendingTones.append(tone) }
            case .speech: if let s = Self.describe(el, forEntering: true), prefix.last != s { prefix.append(s) }
            }
        }
        // Quote levels where the user writes too (a Mail reply: a tester, 12 Oct 2026), as the reading view does
        // (BufferTextInfo): WebKit's AXBlockQuoteLevel on the text's element, said as it changes.
        if let lvl = (bridge.element(at: start)?.attr("AXBlockQuoteLevel") as? NSNumber)?.intValue, lvl != BufferTextInfo.lastQuoteLevel {
            if lvl > 0 {
                switch config.documentFormatting.blockQuotes {
                case .speech: prefix.append("quote level \(lvl)")
                case .tone: pendingTones.append { Tones.blockQuote() }
                case .off: break
                }
            } else if BufferTextInfo.lastQuoteLevel > 0, config.documentFormatting.blockQuotes == .speech {
                prefix.append("out of quote")
            }
            BufferTextInfo.lastQuoteLevel = lvl
        }
        let linkMode = config.documentFormatting.links
        // Links within the range: say "link" where each begins.
        guard let r = bridge.range(start, end), let a = bridge.attributedString(r), a.length > 0 else { return (prefix, nil) }
        var pieces: [String] = []
        var lastLink: AXUIElement?
        var sawLinkRun = false
        a.enumerateAttributes(in: NSRange(location: 0, length: a.length)) { attrs, range, _ in
            let piece = (a.string as NSString).substring(with: range)
            if let link = attrs[NSAttributedString.Key("AXLink")], CFGetTypeID(link as CFTypeRef) == AXUIElementGetTypeID() {
                let l = link as! AXUIElement
                if lastLink.map({ !$0.isSame(l) }) ?? true {
                    switch linkMode {
                    case .speech: pieces.append(" link ")
                    case .tone: pendingTones.append { Tones.link() }
                    case .off: break
                    }
                    sawLinkRun = true
                }
                lastLink = l
            } else {
                lastLink = nil
            }
            if let att = attrs[NSAttributedString.Key("AXAttachment")], CFGetTypeID(att as CFTypeRef) == AXUIElementGetTypeID() {
                let e = att as! AXUIElement
                let (mode, tone) = Self.reporting(for: e)
                let desc = e.string(kAXDescriptionAttribute) ?? e.string(kAXTitleAttribute) ?? ""
                switch mode {
                case .speech: pieces.append(Self.describe(e, forEntering: false) ?? e.role)
                case .tone: if let tone { pendingTones.append(tone) }; if !desc.isEmpty { pieces.append(" " + desc + " ") }
                case .off: if !desc.isEmpty { pieces.append(" " + desc + " ") }
                }
            } else {
                pieces.append(piece)
            }
        }
        // A range entirely inside one link already said "link" in the prefix.
        if sawLinkRun, prefix.contains("link") { pieces.removeAll { $0 == " link " } }
        return (prefix, pieces.joined().trimmingCharacters(in: .whitespaces))
    }

    /// The setting that governs an element, and the tone for it (NVDA's Document Formatting switches).
    public static func reporting(for el: AXUIElement) -> (ElementReport, (() -> Void)?) {
        let f = config.documentFormatting
        switch el.role {
        case "AXHeading": let level = (el.attr(kAXValueAttribute) as? NSNumber)?.intValue ?? 0; return (f.headings, { Tones.heading(level: level) })
        case "AXLink": return (f.links, { Tones.link() })
        case "AXList": return (f.lists, { Tones.list() })
        case "AXTable": return (f.tables, { Tones.table() })
        case "AXImage": return (f.graphics, { Tones.graphic() })
        case "AXGroup":
            let sub = el.string(kAXSubroleAttribute) ?? ""
            if sub.hasPrefix("AXLandmark") || sub == "AXDocumentArticle" { return (f.landmarks, { Tones.landmark() }) }
            if sub == "AXBlockQuote" { return (f.blockQuotes, { Tones.blockQuote() }) }
            return (.speech, nil)
        default: return (.speech, nil)
        }
    }

    /// How an element is announced when the reading enters it (NVDA's control field start).
    public static func describe(_ el: AXUIElement, forEntering: Bool) -> String? {
        let role = el.role
        let sub = el.string(kAXSubroleAttribute) ?? ""
        switch role {
        case "AXHeading":
            let level = (el.attr(kAXValueAttribute) as? NSNumber)?.intValue ?? 0
            return level > 0 && config.documentFormatting.reportHeadingLevel ? "heading level \(level)" : "heading"
        case "AXLink": return forEntering ? "link" : "link " + (el.string(kAXTitleAttribute) ?? el.string(kAXDescriptionAttribute) ?? "")
        case "AXButton": return forEntering ? "button" : "button " + (el.string(kAXTitleAttribute) ?? el.string(kAXDescriptionAttribute) ?? "")
        case "AXPopUpButton", "AXComboBox": return "combo box"
        case "AXCheckBox": return "check box" + (((el.attr(kAXValueAttribute) as? NSNumber)?.intValue ?? 0) != 0 ? " checked" : " not checked")
        case "AXRadioButton": return "radio button" + (((el.attr(kAXValueAttribute) as? NSNumber)?.intValue ?? 0) != 0 ? " checked" : "")
        case "AXTextField", "AXTextArea": return "edit"
        case "AXImage":
            var d = el.string(kAXDescriptionAttribute) ?? el.string(kAXTitleAttribute) ?? ""
            if d.isEmpty, config.virtualBuffers.imageFileNames { d = ImageNames.fromFile(el) }
            return "graphic" + (d.isEmpty ? "" : " " + d)
        case "AXList":
            var count: CFIndex = 0
            AXUIElementGetAttributeValueCount(el, kAXChildrenAttribute as CFString, &count)
            return forEntering ? "list with \(count) item\(count == 1 ? "" : "s")" : nil
        case "AXTable": return forEntering ? "table" : nil
        case "AXGroup":
            switch sub {
            case "AXLandmarkNavigation": return "navigation landmark"
            case "AXLandmarkMain": return "main landmark"
            case "AXLandmarkBanner": return "banner landmark"
            case "AXLandmarkContentInfo": return "content info landmark"
            case "AXLandmarkSearch": return "search landmark"
            case "AXLandmarkComplementary": return "complementary landmark"
            case "AXLandmarkRegion": return "region"
            case "AXDocumentArticle": return "article"
            // Chromium's dialogs and alerts (Google Docs' Share box; Day 3, 10 Oct 2026).
            case "AXApplicationDialog": return forEntering ? "dialog" : nil
            case "AXApplicationAlertDialog", "AXApplicationAlert": return forEntering ? "alert" : nil
            case "AXBlockQuote":
                // A quoted message in Mail: "quote level 2" inside a quote, as VoiceOver says it (a tester).
                var level = 1
                var p = el.element(kAXParentAttribute); var hops = 0
                while let x = p, hops < 40 { if x.string(kAXSubroleAttribute) == "AXBlockQuote" { level += 1 }; if x.role == "AXWebArea" { break }; p = x.element(kAXParentAttribute); hops += 1 }
                // Said from the text's own AXBlockQuoteLevel instead (WebBuffer), which Mail's quotes have.
                _ = level
                return nil
            default: return nil
            }
        case "AXMenuItem": return "menu item"
        case "AXMenuBar": return forEntering ? "menu bar" : nil
        case "AXToolbar": return forEntering ? "tool bar" : nil
        default: return nil
        }
    }
}
