// SPDX-License-Identifier: GPL-3.0-or-later
// Browse mode (NVDA: browseMode.BrowseModeDocumentTreeInterceptor + cursorManager).
//
// In a web document the reader owns a virtual caret: arrows read by line, word
// and character without the page seeing the keys; single letters jump to the
// next heading, link, button, list…; Enter activates what the caret is on. A
// focusable control that gains focus (an edit field) switches to focus mode,
// where keys pass through again; Caps+Space switches by hand; Escape returns.
//
// A browse mode document is a tree interceptor: it answers scripts and sees
// events for every object inside its web area, before the object itself.
import Foundation
import ApplicationServices
import AppKit
import TurnOverAX

/// A key the page should answer (Tab), and no news from the application after it: the page is stuck (the freeze
/// tests, 4 Oct 2026: runs of silent Tabs). Says "page not responding", at most every 5 s.
public enum PageWatch {
    static var lastSpoken = Date.distantPast
    /// The first key since the page last sent news, and how many have gone unanswered since. One key alone can be
    /// dropped by a page that is fine (a false "not responding", 4 Oct 2026): two in a row, with no news, is stuck.
    static var waitingSince: Date?
    static var unanswered = 0
    public static func keySent(to pid: pid_t) {
        let now = Date()
        let news = AXHandler.shared.lastNewsAt[pid] ?? .distantPast
        if let since = waitingSince, news < since { unanswered += 1 } else { waitingSince = now; unanswered = 1 }
        let since = waitingSince ?? now
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard unanswered >= 2, (AXHandler.shared.lastNewsAt[pid] ?? .distantPast) < since,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  Date().timeIntervalSince(lastSpoken) > 5 else { return }
            lastSpoken = Date()
            Log.io("no news from pid \(pid) after \(unanswered) keys; the page seems stuck")
            Speech.speakMessage(String(localized: "please wait", comment: "Spoken message"))   // the page is busy; "not responding" overstated it
        }
    }
}

public final class BrowseModeDocument: ScriptableObject {
    /// When Tab last moved the focus from the reading position: a container the focus then enters is not announced,
    /// as VoiceOver does not on a page. Safari names a plain group after a heading nearby, and AppleVis's comment
    /// form read "Description of App, grouping" on every Tab into it (9 Oct 2026).
    public static var lastTabFromCaretAt = Date.distantPast
    public let webArea: AXUIElement
    public let bridge: WebDocumentBridge
    /// WebKit answers structural searches; other roots (Music's content pane) are searched in the buffer.
    public lazy var hasWebKitSearch: Bool = {
        if BrowseModeHandler.isChromium(pid: webArea.pid) { return false }   // Chromium answers searches, but TurnOver's buffer is the reliable path
        var names: CFArray?
        return AXUIElementCopyParameterizedAttributeNames(webArea, &names) == .success && ((names as? [String]) ?? []).contains("AXUIElementsForSearchPredicate")
    }()
    /// TurnOver's own copy of the page (NVDA's virtual buffer), rebuilt when the page changes.
    public let buffer: WebBuffer
    /// The virtual caret, an offset in the document. Remembered per page address, so returning to a page
    /// (Back after a link) lands where the reading was, as a file tree keeps its selection.
    public var position: Int = 0 {
        // Not while the page is empty (still arriving after Back): "the top of nothing" overwrote the place it was
        // left, so Back on MacRumors started at the top (3 Oct 2026).
        didSet {
            positionMovedAt = Date()
            if buffer.text.length > 0 { BrowseModeHandler.shared.remember(url: url, position: position, text: lineText(at: position)) }
        }
    }
    /// When the reading position last moved: a keyboard focus that moved since (Tab onto a control the buffer does
    /// not hold yet) is what Enter and Space mean.
    var positionMovedAt = Date.distantPast
    /// The text of the buffer line at an offset (what Back looks for when the page comes back rearranged).
    func lineText(at offset: Int) -> String {
        guard let i = buffer.lineIndex(at: offset) else { return "" }
        let l = buffer.lines[i]
        guard l.end > l.start, l.end <= buffer.text.length else { return "" }
        return String(buffer.text.substring(with: NSRange(location: l.start, length: min(l.end - l.start, 120))))
    }
    /// WebKit's selection when the document last looked (to notice a find, or a selection the page made).
    var lastWebSelection: (Int, Int)?

    /// Put the virtual caret where WebKit's selection now is, if it moved since last time (NVDA: after Find, the caret
    /// is on the match). Safari's Find leaves the match selected; coming back to the page now reads it.
    @discardableResult
    public func followWebKitSelection(force: Bool = false) -> Bool {
        guard let sel = bridge.selection() else { return false }
        let first = lastWebSelection == nil
        if let last = lastWebSelection, last == sel, !force { return false }
        lastWebSelection = sel
        if first && !force { return false }
        // Find the match by its words in the buffer (WebKit's element at an index and the buffer disagree): the
        // match with what follows it on its line, nearest where it sits in proportion to the page.
        let line = bridge.unitRange("AXLineTextMarkerRangeForTextMarker", at: sel.0) ?? sel
        let lineEnd = max(line.1, sel.1)
        func webText(_ a: Int, _ b: Int) -> String { b > a ? (bridge.range(a, b).map { bridge.string($0) } ?? "") : "" }
        let pre = webText(max(line.0, sel.0 - 15), sel.0)
        let post = webText(sel.0, min(lineEnd, sel.1 + 25))
        let total = max(1, bridge.documentLength())
        let guess = Int(Double(sel.0) / Double(total) * Double(buffer.text.length))
        func occurrences(_ needle: String) -> [Int] {
            guard !needle.isEmpty, !needle.contains("\n") else { return [] }
            var out: [Int] = []; var from = 0
            while from < buffer.text.length {
                let r = buffer.text.range(of: needle, options: .literal, range: NSRange(location: from, length: buffer.text.length - from))
                if r.location == NSNotFound { break }
                out.append(r.location); from = r.location + 1
            }
            return out
        }
        var hits = occurrences(pre + post).map { $0 + (pre as NSString).length }
        if hits.isEmpty { hits = occurrences(post) }
        if hits.isEmpty { hits = occurrences(webText(sel.0, sel.1)) }
        guard let at = hits.min(by: { abs($0 - guess) < abs($1 - guess) }) else { Log.io("browse mode: WebKit's selection not found in the buffer"); return false }
        position = at
        Log.io("browse mode: to WebKit's selection at \(at)")
        return true
    }

    /// The page address now: Safari reuses one web area across navigations, so this is read each time.
    public var url: String { (webArea.attr("AXURL") as? URL)?.absoluteString ?? (webArea.attr("AXURL") as? String) ?? "" }
    var lastURL = ""

    /// After Back, Forward or a link: a new page in the same web area. Rebuild, and resume where this page was left.
    @discardableResult
    public func refreshIfNavigated(announce: Bool = false) -> Bool {
        let now = url
        guard now != lastURL else { return false }
        let first = lastURL.isEmpty
        lastURL = now
        if !first {
            buffer.newPage()   // "page read in part" once per page, not per web area (Safari reuses one)
            buffer.build()
            // A new page starts in browse mode, as NVDA's new document does. Focus mode carried over from the page
            // before (Google's search box) kept the new page from being announced, and its keys went to the page
            // (a tester, 12 Oct 2026). A page that puts the focus in a field switches again by itself.
            if passThrough { Log.io("browse mode: a new page; focus mode from the last one ended") }
            passThrough = false; disableAutoPassThrough = false
        }
        let saved = BrowseModeHandler.cameBackByHistory ? BrowseModeHandler.shared.savedPosition(for: now) : nil
        let at = resumeOffset(saved)
        position = at
        Log.io("browse mode: page \(Log.words(BrowseModeHandler.shortURL(now))) — resuming at \(position)\(saved == nil ? "" : " (saved \(saved!.offset))")")
        if announce, !buffer.lines.isEmpty { announcePage() }
        GoogleDocs.checkSoon(self)
        if !first, buffer.lines.isEmpty, webArea.role != "AXWebArea" { followReplacedRoot(tries: 10) }
        return true
    }

    /// A module's page emptied as it moved on (Kindle's sign-in steps: Continue empties the old frame and a new one
    /// comes a moment later): the window's new page is followed as soon as it is there, rather than at the next key
    /// (Tab after Tab was silent, and Tab bonked, until an arrow found it, 18 Oct 2026).
    func followReplacedRoot(tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, API.focusTreeInterceptor === self, buffer.lines.isEmpty else { return }
            buffer.build()
            if !buffer.lines.isEmpty { return }
            if let fresh = currentWebArea(), !fresh.isSame(webArea) {
                Log.io("browse mode: the page moved on to another; following it")
                AXHandler.shared.focusChanged(fresh, pid: webArea.pid)
            } else if tries > 1 { followReplacedRoot(tries: tries - 1) }
        }
    }
    /// The page last announced (its title and its reading), so a page is announced once as it arrives.
    var announcedURL = ""

    /// NVDA: a page arriving says its title, then is read (automatic say all, on by default), or, with that off,
    /// its first line (or the line it resumes at).
    func announcePage() {
        announcedURL = url
        let title = (webArea.string(kAXDescriptionAttribute) ?? webArea.element(kAXWindowAttribute)?.string(kAXTitleAttribute) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { Speech.speakMessage(title) }
        if config.virtualBuffers.autoSayAllOnPageLoad {
            // Not a page the focus only passes through: Mail's message pane, on the way to the search field, had the
            // whole message read out (8 Oct 2026).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, API.focusTreeInterceptor === self else { return }
                SayAll.readText(from: self.rootObject)
            }
        } else if let info = makeTextInfo(.bookmark(Bookmark(start: position, end: position))) {
            info.expand(.line); speak(info, unit: .line)
            Hints.schedule(Hints.page)   // not over a say all: only when the page is not being read out
        }
    }

    /// Where to resume on a page: the place it was left, found by its line's text if the page came back rearranged
    /// (YouTube's recommendations), the occurrence nearest where it was.
    func resumeOffset(_ saved: BrowseModeHandler.Saved?) -> Int {
        var at = min(saved?.offset ?? 0, max(0, buffer.text.length - 1))
        if let saved, !saved.text.isEmpty, lineText(at: at) != saved.text {
            let matches = buffer.lines.filter { $0.end > $0.start && $0.end <= buffer.text.length &&
                String(buffer.text.substring(with: NSRange(location: $0.start, length: min($0.end - $0.start, 120)))) == saved.text }
            if let best = matches.min(by: { abs($0.start - saved.offset) < abs($1.start - saved.offset) }) { at = best.start }
        }
        return at
    }

    /// A page that was still empty when the document was made (a link just followed) has content now: read
    /// where it resumes, as NVDA reads a page once it has loaded, instead of leaving "document, blank" as the last word.
    @discardableResult
    public func loadedAfterBlank(announce: Bool) -> Bool {
        guard buffer.lines.isEmpty else { return false }
        buffer.build()
        guard !buffer.lines.isEmpty else { return false }
        let saved = BrowseModeHandler.cameBackByHistory ? BrowseModeHandler.shared.savedPosition(for: url) : nil
        position = resumeOffset(saved)
        VoiceOverSounds.play("WebPageLoaded.aiff")
        Log.io("browse mode: page arrived — resuming at \(position)\(saved == nil ? "" : " (saved \(saved!.offset))")")
        if announce, url != announcedURL { announcePage() }
        return true
    }

    /// NVDA's passThrough: true is focus mode (keys go to the application).
    public var passThrough = false
    /// NVDA+Shift+Space: single-letter navigation on or off for this page (off: the letters go to the page).
    public var singleLetterNavigation = true
    public var disableAutoPassThrough = false
    var lastQuickNavTarget: AXUIElement?
    static let controlRoles: Set<String> = ["AXTextField", "AXTextArea", "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXSlider", "AXIncrementor", "AXMenuButton", "AXLink"]
    /// The containers the last reading was inside (NVDA: the control field stack between reads).
    var lastChain: [AXUIElement] = []

    func speak(_ info: TextInfo, unit: TextUnit) {
        if let w = info as? WebTextInfo { w.previousChain = lastChain }
        if let b = info as? BufferTextInfo { b.previousChain = lastChain }
        Speech.speakTextInfo(info, unit: unit, reason: .caret)
        if let w = info as? WebTextInfo { lastChain = w.chain }
        if let b = info as? BufferTextInfo { lastChain = b.chain }
    }

    init(webArea: AXUIElement) {
        self.webArea = webArea
        bridge = WebDocumentBridge(webArea: webArea)
        buffer = WebBuffer(webArea: webArea)
        super.init()
        buffer.build()
        refreshIfNavigated()
        let nav = "Browse mode"
        // NVDA's cursor manager, on Mac modifiers.
        script("moveByLine_back", String(localized: "Moves to the previous line", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:upArrow"], category: nav, resumesSayAll: true) { [weak self] _ in guard let self else { return }; move(.line, -1) }
        script("moveByLine_forward", String(localized: "Moves to the next line", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:downArrow"], category: nav, resumesSayAll: true) { [weak self] _ in guard let self else { return }; move(.line, 1) }
        script("moveByCharacter_back", String(localized: "Moves to the previous character", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:leftArrow"], category: nav) { [weak self] _ in guard let self else { return }; move(.character, -1) }
        script("moveByCharacter_forward", String(localized: "Moves to the next character", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:rightArrow"], category: nav) { [weak self] _ in guard let self else { return }; move(.character, 1) }
        script("moveByWord_back", String(localized: "Moves to the previous word", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:option+leftArrow"], category: nav) { [weak self] _ in guard let self else { return }; move(.word, -1) }
        script("moveByWord_forward", String(localized: "Moves to the next word", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:option+rightArrow"], category: nav) { [weak self] _ in guard let self else { return }; move(.word, 1) }
        // The Windows style adds NVDA's Control Up and Down for paragraphs (a tester, 14 Oct 2026); the Mac style
        // keeps VoiceOver's Option arrows only.
        script("moveByParagraph_back", String(localized: "Moves to the previous paragraph", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:option+upArrow"], category: nav, resumesSayAll: true) { [weak self] _ in guard let self else { return }; move(.paragraph, -1) }
        script("moveByParagraph_forward", String(localized: "Moves to the next paragraph", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:option+downArrow"], category: nav, resumesSayAll: true) { [weak self] _ in guard let self else { return }; move(.paragraph, 1) }
        // (Bound always and gated by the style at each press, as the letters are: bound once at the document's
        // creation, a style switch left every open page with the old keys. code review, 16 Oct 2026.)
        script("moveByParagraph_back_nvda", String(localized: "Moves to the previous paragraph (NVDA's Control Up)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:control+upArrow"], category: nav, resumesSayAll: true) { [weak self] _ in guard let self else { return }; move(.paragraph, -1) }
            .isAvailable = { config.general.windowsKeys }
        script("moveByParagraph_forward_nvda", String(localized: "Moves to the next paragraph (NVDA's Control Down)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:control+downArrow"], category: nav, resumesSayAll: true) { [weak self] _ in guard let self else { return }; move(.paragraph, 1) }
            .isAvailable = { config.general.windowsKeys }
        script("moveByPage_back", String(localized: "Moves up a page", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:pageUp"], category: nav) { [weak self] _ in guard let self else { return }; move(.line, -20) }
        script("moveByPage_forward", String(localized: "Moves down a page", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:pageDown"], category: nav) { [weak self] _ in guard let self else { return }; move(.line, 20) }
        script("startOfLine", String(localized: "Moves to the start of the line", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:home", "kb:command+leftArrow"], category: nav) { [weak self] _ in guard let self else { return }; edgeOfLine(start: true) }
        script("endOfLine", String(localized: "Moves to the end of the line", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:end", "kb:command+rightArrow"], category: nav) { [weak self] _ in guard let self else { return }; edgeOfLine(start: false) }
        let sel = "Selecting"
        script("selectCharacter_back", String(localized: "Selects the previous character", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+leftArrow"], category: sel) { [weak self] _ in self?.select(.character, -1) }
        script("selectCharacter_forward", String(localized: "Selects the next character", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+rightArrow"], category: sel) { [weak self] _ in self?.select(.character, 1) }
        script("selectWord_back", String(localized: "Selects the previous word", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+option+leftArrow"], category: sel) { [weak self] _ in self?.select(.word, -1) }
        script("selectWord_forward", String(localized: "Selects the next word", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+option+rightArrow"], category: sel) { [weak self] _ in self?.select(.word, 1) }
        script("selectLine_back", String(localized: "Selects up a line", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+upArrow"], category: sel) { [weak self] _ in self?.select(.line, -1) }
        script("selectLine_forward", String(localized: "Selects down a line", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+downArrow"], category: sel) { [weak self] _ in self?.select(.line, 1) }
        // Paragraphs too (a tester, : Shift Option Down selected nothing that was said). Windows's Control Shift
        // Down is the same in the Windows style.
        script("selectParagraph_back", String(localized: "Selects up a paragraph", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+option+upArrow", "kb:shift+control+upArrow"], category: sel) { [weak self] _ in self?.select(.paragraph, -1) }
        script("selectParagraph_forward", String(localized: "Selects down a paragraph", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+option+downArrow", "kb:shift+control+downArrow"], category: sel) { [weak self] _ in self?.select(.paragraph, 1) }
        script("selectToLineStart", String(localized: "Selects to the start of the line", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+home", "kb:shift+command+leftArrow"], category: sel) { [weak self] _ in
            guard let self, let info = caretInfo() else { return }; info.expand(.line); select(nil, 0, to: info.start)
        }
        script("selectToLineEnd", String(localized: "Selects to the end of the line", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+end", "kb:shift+command+rightArrow"], category: sel) { [weak self] _ in
            guard let self, let info = caretInfo() else { return }; info.expand(.line); select(nil, 0, to: info.end)
        }
        script("selectToTop", String(localized: "Selects to the top of the document", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+command+upArrow", "kb:shift+control+home"], category: sel) { [weak self] _ in self?.select(nil, 0, to: 0) }
        script("selectToBottom", String(localized: "Selects to the bottom of the document", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+command+downArrow", "kb:shift+control+end"], category: sel) { [weak self] _ in
            guard let self else { return }; select(nil, 0, to: buffer.text.length)
        }
        script("selectAll", String(localized: "Selects the whole document", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+a"], category: sel) { [weak self] _ in
            guard let self else { return }
            selectionAnchor = 0; position = buffer.text.length
            Speech.speakMessage(String(localized: "all selected", comment: "Spoken message"), remember: false)
        }
        script("copySelection", String(localized: "Copies what is selected in the document; with nothing selected, the application's own copy", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+c"], category: sel) { [weak self] g in
            self?.copySelection(g)
        }
        script("topOfDocument", String(localized: "Moves to the top of the document", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+upArrow", "kb:control+home"], category: nav, resumesSayAll: true) { [weak self] _ in guard let self else { return }; position = 0; speakUnit(.line) }
        script("bottomOfDocument", String(localized: "Moves to the bottom of the document", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+downArrow", "kb:control+end"], category: nav) { [weak self] _ in guard let self else { return }; position = max(0, buffer.text.length - 1); speakUnit(.line) }
        script("activatePosition", String(localized: "Activates the element at the caret", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:enter", "kb:numpadEnter", "kb:space"], category: nav) { [weak self] g in guard let self else { return }; activate(g) }
        // NVDA+F7 in the Windows style (the parity audit, 13 Oct 2026: it did nothing on a page); in the Mac style
        // VO-F7 stays VoiceOver's, and VO-U and VO-I reach this list.
        let elements = script("elementsList", String(localized: "Elements list; lists the page's headings, links, form fields, buttons and landmarks; Enter goes there (NVDA+F7, VoiceOver's Item Chooser)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+f7"], category: nav) { [weak self] _ in
            self?.elementsList()
        }
        elements.isAvailable = { [weak self] in config.general.windowsKeys && self?.passThrough == false }
        script("tabFromCaret", String(localized: "Next link or control; moves to the next link or control after the reading position (Shift: before it)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:tab", "kb:shift+tab"], category: nav) { [weak self] g in
            guard let self else { return }
            BrowseModeDocument.lastTabFromCaretAt = Date()
            if focusFromCaret(forward: !g.modifiers.contains(.shift)) { return }
            if AppModuleHandler.shared.appModule(for: webArea.pid).browseTabMovesReadingPosition {
                guard ensureContent() else { return }
                let roles: Set<String> = ["AXLink", "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXSlider"]
                if let (at, _) = buffer.find(from: position, forward: !g.modifiers.contains(.shift), roles: roles) { position = at; speakUnit(.line) }
                else { Tones.edge() }
                return
            }
            g.send(); PageWatch.keySent(to: webArea.pid)
        }
        script("disablePassThrough", String(localized: "Switches back to browse mode", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:escape"], category: nav) { [weak self] g in
            guard let self else { return }
            if passThrough {
                // The virtual caret goes to the control that had focus (NVDA): on a page that was still arriving when
                // the field took focus, the field was not in the buffer yet and the caret stayed at the top.
                if let f = API.focusObject, f.pid == webArea.pid, !f.isSameElement(as: webArea) {
                    var at = buffer.offset(of: f.element)
                    if at == nil { buffer.build(); at = buffer.offset(of: f.element) }
                    if let at { position = at }
                }
                disableAutoPassThrough = false   // Escape ends the by-hand choice too: the next field switches by itself again
                setPassThrough(false, announce: true)
            } else { g.send() }
        }
        // NVDA's quick navigation keys. Shift goes backwards.
        // Each style its own reader's letters: NVDA's in the Windows style, VoiceOver's in the Mac style. A letter the
        // style's reader doesn't use goes to the page. NVDA+Shift+Space turns them off for a page (singleLetterNavigation).
        for (table, windows) in [(BrowseModeDocument.quickNav, true), (BrowseModeDocument.voiceOverQuickNav, false)] {
            let prefix = windows ? "" : "vo_"
            for q in table {
                let next = script("\(prefix)next\(q.name)", String(localized: "Moves to the next \(q.spoken)", comment: "A command: %@ is a kind of thing to find (heading)"), gestures: ["kb:\(q.key)"], category: "Quick navigation") { [weak self] g in
                    guard let self else { return }
                    if !singleLetterNavigation { g.send(); return }
                    quickNav(q, forward: true)
                }
                let previous = script("\(prefix)previous\(q.name)", String(localized: "Moves to the previous \(q.spoken)", comment: "A command: %@ is a kind of thing to find (heading)"), gestures: ["kb:shift+\(q.key)"], category: "Quick navigation") { [weak self] g in
                    guard let self else { return }
                    if !singleLetterNavigation { g.send(); return }
                    quickNav(q, forward: false)
                }
                next.isAvailable = { config.general.windowsKeys == windows }
                previous.isAvailable = { config.general.windowsKeys == windows }
            }
        }
        // NVDA's; VoiceOver has none, so the Mac style leaves comma to the page.
        script("pastEndOfContainer", String(localized: "Moves past the end of the list, table or other container (NVDA: comma)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:,"], category: "Quick navigation") { [weak self] g in
            guard let self else { return }
            if !singleLetterNavigation { g.send(); return }
            moveToContainerEdge(end: true)
        }.isAvailable = { config.general.windowsKeys }
        script("startOfContainer", String(localized: "Moves to the start of the list, table or other container (NVDA: Shift comma)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+,"], category: "Quick navigation") { [weak self] g in
            guard let self else { return }
            if !singleLetterNavigation { g.send(); return }
            moveToContainerEdge(end: false)
        }.isAvailable = { config.general.windowsKeys }
    }

    public struct QuickNavType { public let name: String; public let key: String; public let spoken: String; let searchKey: String; let roles: Set<String>? }
    public static let quickNav: [QuickNavType] = [
        .init(name: "Heading", key: "h", spoken: String(localized: "heading", comment: "A kind of thing to find, after next or previous"), searchKey: "AXHeadingSearchKey", roles: nil),
        .init(name: "Heading1", key: "1", spoken: Phrases.headingLevel(1), searchKey: "AXHeadingLevel1SearchKey", roles: nil),
        .init(name: "Heading2", key: "2", spoken: Phrases.headingLevel(2), searchKey: "AXHeadingLevel2SearchKey", roles: nil),
        .init(name: "Heading3", key: "3", spoken: Phrases.headingLevel(3), searchKey: "AXHeadingLevel3SearchKey", roles: nil),
        .init(name: "Heading4", key: "4", spoken: Phrases.headingLevel(4), searchKey: "AXHeadingLevel4SearchKey", roles: nil),
        .init(name: "Heading5", key: "5", spoken: Phrases.headingLevel(5), searchKey: "AXHeadingLevel5SearchKey", roles: nil),
        .init(name: "Heading6", key: "6", spoken: Phrases.headingLevel(6), searchKey: "AXHeadingLevel6SearchKey", roles: nil),
        .init(name: "Heading7", key: "7", spoken: Phrases.headingLevel(7), searchKey: "", roles: nil),
        .init(name: "Heading8", key: "8", spoken: Phrases.headingLevel(8), searchKey: "", roles: nil),
        .init(name: "Heading9", key: "9", spoken: Phrases.headingLevel(9), searchKey: "", roles: nil),
        .init(name: "Link", key: "k", spoken: String(localized: "link", comment: "A kind of thing to find, after next or previous"), searchKey: "AXLinkSearchKey", roles: nil),
        .init(name: "VisitedLink", key: "v", spoken: String(localized: "visited link", comment: "A kind of thing to find, after next or previous"), searchKey: "AXVisitedLinkSearchKey", roles: nil),
        .init(name: "UnvisitedLink", key: "u", spoken: String(localized: "unvisited link", comment: "A kind of thing to find, after next or previous"), searchKey: "AXUnvisitedLinkSearchKey", roles: nil),
        .init(name: "FormField", key: "f", spoken: String(localized: "form field", comment: "A kind of thing to find, after next or previous"), searchKey: "AXControlSearchKey", roles: nil),
        .init(name: "List", key: "l", spoken: String(localized: "list", comment: "A kind of thing to find, after next or previous"), searchKey: "AXListSearchKey", roles: nil),
        .init(name: "Button", key: "b", spoken: String(localized: "button", comment: "A kind of thing to find, after next or previous"), searchKey: "AXButtonSearchKey", roles: nil),
        .init(name: "Edit", key: "e", spoken: String(localized: "edit field", comment: "A kind of thing to find, after next or previous"), searchKey: "AXTextFieldSearchKey", roles: nil),
        .init(name: "Frame", key: "m", spoken: String(localized: "frame", comment: "A kind of thing to find, after next or previous"), searchKey: "AXFrameSearchKey", roles: nil),
        .init(name: "RadioButton", key: "r", spoken: String(localized: "radio button", comment: "A kind of thing to find, after next or previous"), searchKey: "AXRadioGroupSearchKey", roles: nil),
        .init(name: "ComboBox", key: "c", spoken: String(localized: "combo box", comment: "A kind of thing to find, after next or previous"), searchKey: "AXControlSearchKey", roles: ["AXPopUpButton", "AXComboBox"]),
        .init(name: "CheckBox", key: "x", spoken: String(localized: "check box", comment: "A kind of thing to find, after next or previous"), searchKey: "AXCheckBoxSearchKey", roles: nil),
        .init(name: "Graphic", key: "g", spoken: String(localized: "graphic", comment: "A kind of thing to find, after next or previous"), searchKey: "AXGraphicSearchKey", roles: nil),
        .init(name: "BlockQuote", key: "q", spoken: String(localized: "block quote", comment: "A kind of thing to find, after next or previous"), searchKey: "AXBlockquoteSearchKey", roles: nil),
        .init(name: "Landmark", key: "d", spoken: String(localized: "landmark", comment: "A kind of thing to find, after next or previous"), searchKey: "AXLandmarkSearchKey", roles: nil),
        .init(name: "Table", key: "t", spoken: String(localized: "table", comment: "A kind of thing to find, after next or previous"), searchKey: "AXTableSearchKey", roles: nil),
        .init(name: "Annotation", key: "a", spoken: String(localized: "annotation", comment: "A kind of thing to find, after next or previous"), searchKey: "", roles: nil),
        .init(name: "SpellingError", key: "w", spoken: String(localized: "spelling error", comment: "A kind of thing to find, after next or previous"), searchKey: "AXMisspelledWordSearchKey", roles: nil),
        // Text kinds: no WebKit search key; found in the buffer (BrowseModeDocument.quickNav).
        .init(name: "Paragraph", key: "p", spoken: String(localized: "paragraph", comment: "A kind of thing to find, after next or previous"), searchKey: "", roles: nil),
        .init(name: "NotLinkBlock", key: "n", spoken: String(localized: "text after links", comment: "A kind of thing to find, after next or previous"), searchKey: "", roles: nil),
        .init(name: "ListItem", key: "i", spoken: String(localized: "list item", comment: "A kind of thing to find, after next or previous"), searchKey: "", roles: nil),
        .init(name: "Separator", key: "s", spoken: String(localized: "separator", comment: "A kind of thing to find, after next or previous"), searchKey: "", roles: nil),
        .init(name: "EmbeddedObject", key: "o", spoken: String(localized: "embedded object", comment: "A kind of thing to find, after next or previous"), searchKey: "", roles: nil),
    ]

    /// The Mac style's letters: VoiceOver's own single-key Quick Nav, as its defaults on the Mac set them
    /// (ScreenReaderConfiguration, SCRQuickNavSingleLetterCommander; the parity audit, 13 Oct 2026). "mac keys
    /// should do what voiceover keys are expected to do, and windows mode should do what NVDA keys are expected to do."
    public static let voiceOverQuickNav: [QuickNavType] = [
        .init(name: "Heading", key: "h", spoken: String(localized: "heading", comment: "A kind of thing to find, after next or previous"), searchKey: "AXHeadingSearchKey", roles: nil),
        .init(name: "Heading1", key: "1", spoken: Phrases.headingLevel(1), searchKey: "AXHeadingLevel1SearchKey", roles: nil),
        .init(name: "Heading2", key: "2", spoken: Phrases.headingLevel(2), searchKey: "AXHeadingLevel2SearchKey", roles: nil),
        .init(name: "Heading3", key: "3", spoken: Phrases.headingLevel(3), searchKey: "AXHeadingLevel3SearchKey", roles: nil),
        .init(name: "Heading4", key: "4", spoken: Phrases.headingLevel(4), searchKey: "AXHeadingLevel4SearchKey", roles: nil),
        .init(name: "Heading5", key: "5", spoken: Phrases.headingLevel(5), searchKey: "AXHeadingLevel5SearchKey", roles: nil),
        .init(name: "Heading6", key: "6", spoken: Phrases.headingLevel(6), searchKey: "AXHeadingLevel6SearchKey", roles: nil),
        .init(name: "SameLevelHeading", key: "m", spoken: String(localized: "heading at the same level", comment: "A kind of thing to find, after next or previous"), searchKey: "AXHeadingSameLevelSearchKey", roles: nil),
        .init(name: "Link", key: "l", spoken: String(localized: "link", comment: "A kind of thing to find, after next or previous"), searchKey: "AXLinkSearchKey", roles: nil),
        .init(name: "VisitedLink", key: "v", spoken: String(localized: "visited link", comment: "A kind of thing to find, after next or previous"), searchKey: "AXVisitedLinkSearchKey", roles: nil),
        .init(name: "TextField", key: "f", spoken: String(localized: "text field", comment: "A kind of thing to find, after next or previous"), searchKey: "AXTextFieldSearchKey", roles: nil),
        .init(name: "Control", key: "j", spoken: String(localized: "control", comment: "A kind of thing to find, after next or previous"), searchKey: "AXControlSearchKey", roles: nil),
        .init(name: "List", key: "x", spoken: String(localized: "list", comment: "A kind of thing to find, after next or previous"), searchKey: "AXListSearchKey", roles: nil),
        .init(name: "Button", key: "b", spoken: String(localized: "button", comment: "A kind of thing to find, after next or previous"), searchKey: "AXButtonSearchKey", roles: nil),
        .init(name: "Table", key: "t", spoken: String(localized: "table", comment: "A kind of thing to find, after next or previous"), searchKey: "AXTableSearchKey", roles: nil),
        .init(name: "Graphic", key: "g", spoken: String(localized: "graphic", comment: "A kind of thing to find, after next or previous"), searchKey: "AXGraphicSearchKey", roles: nil),
        .init(name: "Landmark", key: "n", spoken: String(localized: "landmark", comment: "A kind of thing to find, after next or previous"), searchKey: "AXLandmarkSearchKey", roles: nil),
        .init(name: "CheckBox", key: "c", spoken: String(localized: "check box", comment: "A kind of thing to find, after next or previous"), searchKey: "AXCheckBoxSearchKey", roles: nil),
        .init(name: "RadioGroup", key: "r", spoken: String(localized: "radio group", comment: "A kind of thing to find, after next or previous"), searchKey: "AXRadioGroupSearchKey", roles: nil),
        .init(name: "DifferentItem", key: "d", spoken: String(localized: "different item", comment: "A kind of thing to find, after next or previous"), searchKey: "AXDifferentTypeSearchKey", roles: nil),
    ]

    // MARK: The document object and its text

    /// A fresh object for the root, so TextInfos read the live page (any root: a web area, or a content pane).
    public var rootObject: WebArea { WebArea(element: webArea) }
    public func makeTextInfo(_ p: TextPosition) -> TextInfo? { try? rootObject.makeTextInfo(p) }
    public var isAlive: Bool { webArea.role != "?" }

    func caretInfo() -> TextInfo? { makeTextInfo(.caret) }

    func speakUnit(_ unit: TextUnit) {
        guard let info = caretInfo() else { return }
        info.expand(unit)
        speak(info, unit: unit)
    }

    /// Find (NVDA's browse-mode find, VoiceOver's VO-F): the next or previous match from the reading position,
    /// ignoring case; the reading position goes there and the line is read. False when there is none.
    public func find(_ s: String, forward: Bool) -> Bool {
        refreshIfNavigated()
        clearSelection()
        let text = buffer.text, n = text.length
        guard n > 0, !s.isEmpty else { return false }
        let from = min(position + 1, n)
        let r = forward
            ? text.range(of: s, options: .caseInsensitive, range: NSRange(location: from, length: n - from))
            : text.range(of: s, options: [.caseInsensitive, .backwards], range: NSRange(location: 0, length: min(position, n)))
        guard r.location != NSNotFound else { return false }
        position = r.location
        guard let info = makeTextInfo(.bookmark(Bookmark(start: r.location, end: r.location))) else { return true }
        info.expand(.line)
        speak(info, unit: .line)
        return true
    }

    /// The copy of the page is empty (read while it was still loading, or while Safari was not answering): look
    /// again now, and keep looking for half a minute, reading the page when it comes. A tester's report (6 Oct
    /// 2026): after a reload the copy stayed empty and every arrow said "bottom" or "top", then "blank".
    @discardableResult
    func ensureContent() -> Bool {
        // An empty address too: Safari not answering reports none (6 Oct 2026, playtestcloud: "page  —", 0 lines,
        // and every key said "no next heading").
        guard buffer.lines.isEmpty, url != "about:blank" else { return true }
        buffer.build()
        guard buffer.lines.isEmpty else { Log.io("browse mode: the page has arrived"); return true }
        // Safari can swap in a new web area on a reload (6 Oct 2026, fast.com: after Command R the copy was
        // of the old one, one element and no address, while the page was there and Tab reached it). The window's
        // web area now, if it is another one, is the page: move there, as Tab did.
        if let fresh = currentWebArea(), !fresh.isSame(webArea) {
            Log.io("browse mode: this web area was replaced (a reload); moving to the window's current one")
            let pid = webArea.pid
            DispatchQueue.main.async { AXHandler.shared.focusChanged(fresh, pid: pid) }
            return false
        }
        Speech.speakMessage(String(localized: "nothing on this page yet; it may still be loading", comment: "Spoken message"))
        watchForContent()
        return false
    }

    /// The web area in the focused window of this document's application now (nil if there is none).
    func currentWebArea() -> AXUIElement? {
        let app = AXUIElementCreateApplication(webArea.pid)
        guard let window = app.element(kAXFocusedWindowAttribute) ?? app.element(kAXMainWindowAttribute) else { return nil }
        return window.firstDescendant(role: "AXWebArea", maxVisited: 400) ?? AppModuleHandler.shared.appModule(for: webArea.pid).browseRoot(inWindow: window)
    }

    var watchingFor = ""
    /// Look again every second for 30 s while the copy is empty; when the page comes, say so and read it.
    func watchForContent() {
        let waiting = url
        guard watchingFor != waiting else { return }
        watchingFor = waiting
        func look(_ n: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, url == waiting, watchingFor == waiting else { return }
                if buffer.lines.isEmpty { buffer.build() }
                if buffer.lines.isEmpty, API.focusTreeInterceptor === self, let fresh = currentWebArea(), !fresh.isSame(webArea) {
                    watchingFor = ""
                    Log.io("browse mode: this web area was replaced while waiting; moving to the window's current one")
                    AXHandler.shared.focusChanged(fresh, pid: webArea.pid)
                    return
                }
                if !buffer.lines.isEmpty {
                    watchingFor = ""
                    // Once: AXLoadComplete may have announced it already (the title was said twice, 12 Oct 2026).
                    guard url != announcedURL else { Log.io("browse mode: the page arrived after \(n + 1) s (already announced)"); return }
                    Log.io("browse mode: the page arrived after \(n + 1) s")
                    if API.focusTreeInterceptor === self, !passThrough { position = resumeOffset(BrowseModeHandler.cameBackByHistory ? BrowseModeHandler.shared.savedPosition(for: url) : nil); announcePage() }
                    return
                }
                if n < 29 { look(n + 1) } else { watchingFor = ""; Log.io("browse mode: still nothing on the page after 30 s") }
            }
        }
        look(0)
    }

    /// One rule for the arrows, the letters and the container keys (code review, 16 Oct 2026, item 28: the letters
    /// rebuilt on any dirty flag, up to 2 s on main): a dirty page is rebuilt when the last build was cheap, and a
    /// page older than `stale` seconds is rebuilt whatever it cost.
    func rebuildIfCheap(stale: TimeInterval? = nil) {
        let age = Date().timeIntervalSince(buffer.builtAt)
        if let stale, age > stale { buffer.build(); clampPosition(); return }
        if buffer.isDirty, buffer.lastBuildMs < 250, age > 1 { rebuildKeepingPlace() }
    }

    /// At the end of a page that loads more as it scrolls (YouTube said "bottom" before the end): the last
    /// element scrolled into view, the page read again with a fresh deadline, and true if there is more now.
    func reachForMore() -> Bool {
        guard buffer.isDirty || buffer.isPartial || buffer.lastBuildMs >= 250 || Date().timeIntervalSince(buffer.builtAt) > 1 else { return false }
        if let last = buffer.lines.last?.element { _ = AXUIElementPerformAction(last, "AXScrollToVisible" as CFString) }
        let before = buffer.text.length
        rebuildKeepingPlace()
        let more = buffer.text.length > before
        Log.io("browse mode: at the end, the page read again: \(more ? "more now (\(buffer.text.length - before) characters)" : "nothing more")")
        return more
    }

    /// A paged document (Preview's PDF): the page is said as the reading position crosses onto another one, as
    /// VoiceOver says it. Web pages have no pages, so this costs them one string compare.
    var lastPageIndex: Int?
    lazy var isPaged: Bool = webArea.string(kAXSubroleAttribute) == PreviewAppModule.containerSubrole
    func announcePageIfChanged() {
        guard isPaged, let el = buffer.segment(at: position)?.element, let page = PreviewAppModule.page(of: el) else { return }
        defer { lastPageIndex = page.index }
        if let last = lastPageIndex, last != page.index { Speech.speakMessage(page.words) }
    }

    /// Preview's comments and highlights on the line just read, after it (PreviewAppModule.marks).
    func sayMarksOnLine() {
        guard isPaged, let i = buffer.lineIndex(at: position), let el = buffer.segment(at: position)?.element,
              let page = PreviewAppModule.page(of: el) else { return }
        let l = buffer.lines[i]
        let text = buffer.text.substring(with: NSRange(location: l.start, length: l.end - l.start))
        let marks = PreviewAppModule.marks(for: webArea, page: page.index, line: text)
        guard !marks.isEmpty else { return }
        switch PreviewAppModule.markReport {
        case .off: return
        case .speech: for words in marks { Speech.speakMessage(words) }
        case .tone:
            Tones.comment()
            for words in marks { if let w = PreviewAppModule.wordsWithTone(words) { Speech.speakMessage(w) } }
        }
    }

    func move(_ unit: TextUnit, _ direction: Int) {
        refreshIfNavigated()
        clearSelection()
        guard ensureContent() else { return }
        rebuildIfCheap()
        guard var info = caretInfo() else { return }
        // NVDA's _caretMovementScriptHelper: expand to the unit and collapse to its start before moving, so Up from
        // the middle of a line (where Find left the caret) goes to the line above, not the start of this one.
        if unit != .character { info.expand(unit); info.collapse() }
        var moved = info.move(unit, direction)
        if moved != 0, unit == .line || unit == .paragraph {
            // HTML mail is full of empty lines: a run of them is one "blank", not four presses of it.
            var hops = 0
            while hops < 30 {
                let probe = info.copy(); probe.expand(unit)
                guard probe.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
                let next = info.copy()
                guard next.move(unit, direction) != 0 else { break }
                let look = next.copy(); look.expand(unit)
                guard look.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }   // the next line has text: stop on this blank
                info.start = next.start; info.end = next.end; hops += 1
            }
            if hops > 0 { moved += hops * (direction > 0 ? 1 : -1) }
        }
        if moved == 0, direction > 0, reachForMore(), let again = caretInfo() {
            if unit != .character { again.expand(unit); again.collapse() }
            moved = again.move(unit, direction)
            if moved != 0 { info = again }
        }
        if moved == 0 { Speech.speakMessage(direction > 0 ? String(localized: "bottom", comment: "Spoken message") : String(localized: "top", comment: "Spoken message")) }
        position = info.start
        // Say all carries on from here and reads this line itself (NVDA's willSayAllResume).
        if SayAll.resuming { return }
        announcePageIfChanged()
        speakUnit(unit == .character ? .character : unit)
        if unit == .line || unit == .paragraph { sayMarksOnLine() }
    }

    // (An override cannot live in an extension: the pass-through decision itself is in FocusModePolicy.swift.)
    /// Scripts answer only in browse mode (NVDA: passThrough filters the tree interceptor's scripts).
    public override func script(for gesture: KeyboardGesture) -> Script? {
        // NVDA's way, in both styles (Oliver, 23 Oct 2026, issue 82): in browse mode a letter is always a command. A
        // field is typed into after Return or Tab has entered it (focus mode), or after the switch by hand. Until then
        // a letter typed while the reading position was on a field went into it (Mac style, 9 Oct 2026), and a letter
        // typed while a page field still had the keyboard resumed focus mode quietly (8 Oct 2026); the Safari stress
        // test of 23 Oct 2026 showed both typing h into a field the user had just left with Escape, on four pages.
        if let s = super.script(for: gesture) {
            if passThrough && s.name != "disablePassThrough" { return nil }
            return s
        }
        // A letter or digit with no command of its own (z, 0) is kept from the page in browse mode, as NVDA's trap
        // non-command gestures does: otherwise it would reach a field that still has the keyboard after Escape.
        // Punctuation and Backspace still reach the page (a page's own ? for its shortcut help). Not with single-letter
        // navigation off, when the page's own letter keys are wanted (a second reviewer, 23 Oct 2026).
        let inBrowseMode = !passThrough
        let lettersAreCommands = singleLetterNavigation
        let isLetterOrDigit = gesture.typedCharacter.map { $0.isLetter || $0.isNumber } ?? false
        let isPlainKey = gesture.modifiers.subtracting(.shift).isEmpty
        if inBrowseMode, lettersAreCommands, isLetterOrDigit, isPlainKey {
            return Script(name: "browseModeTrap", description: String(localized: "A letter or digit with no command in browse mode: nothing", comment: "A command, as the key list and keyboard help say it"), category: "navigation", owner: self) { _ in
                Log.io("browse mode: a letter or digit with no command; kept from the page")
            }
        }
        return nil
    }

    /// The text field, text area or combo box at the reading position, if that is what is there.
    /// The element at the reading position (a picture to describe, a field to type into).
    public func elementAtPosition() -> AXUIElement? {
        buffer.segment(at: position)?.element ?? buffer.lineIndex(at: position).flatMap { buffer.lines[$0].element }
    }

    func editableAtPosition() -> AXUIElement? {
        let e: AXUIElement? = buffer.segment(at: position)?.element ?? buffer.lineIndex(at: position).flatMap { buffer.lines[$0].element }
        guard let e, ["AXTextField", "AXTextArea", "AXComboBox"].contains(e.role) else { return nil }
        return e
    }

    // Stored properties of the parts in the other files (an extension cannot hold them).
    /// Where the selection started; nil when nothing is selected.
    public internal(set) var selectionAnchor: Int?
    /// Where the virtual caret was when the focus last moved (followed or set). Tab from there is the browser's own.
    var positionAtFocus = -1
}
