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

// Browse mode: quick navigation, single letters to the next heading, link, button, list… (NVDA: _quickNavScript).
extension BrowseModeDocument {
    // MARK: Quick navigation (NVDA: _quickNavScript)

    static let quickNavRoles: [String: Set<String>] = [
        "Heading": ["AXHeading"], "Heading1": ["AXHeading"], "Heading2": ["AXHeading"], "Heading3": ["AXHeading"], "Heading4": ["AXHeading"], "Heading5": ["AXHeading"], "Heading6": ["AXHeading"],
        "Link": ["AXLink"], "Button": ["AXButton", "AXMenuButton", "AXPopUpButton"], "Edit": ["AXTextField", "AXTextArea"], "FormField": ["AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXSlider"],
        "List": ["AXList"], "Table": ["AXTable"], "CheckBox": ["AXCheckBox"], "RadioButton": ["AXRadioButton"], "ComboBox": ["AXPopUpButton", "AXComboBox"], "Graphic": ["AXImage"],
        "Landmark": ["AXLandmark"], "BlockQuote": ["AXBlockQuote"],
        "Heading7": ["AXHeading"], "Heading8": ["AXHeading"], "Heading9": ["AXHeading"],
        "ListItem": ["AXListItem"], "Separator": ["AXSplitter"], "EmbeddedObject": ["EmbeddedObject"], "Annotation": ["Annotation"],
        // VoiceOver's (the Mac style).
        "SameLevelHeading": ["AXHeading"], "TextField": ["AXTextField", "AXTextArea"], "RadioGroup": ["AXRadioGroup", "AXRadioButton"],
        "Control": ["AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXSlider", "AXMenuButton", "AXDisclosureTriangle"],
    ]

    package func quickNav(_ q: QuickNavType, forward: Bool, afterRefresh: Bool = false) {
        if readFromCopyIfSilent({ quickNav(q, forward: forward, afterRefresh: afterRefresh) }) { return }
        let navigationTicket = ModeAnnouncement.navigationStarted(self)
        ModeAnnouncement.begin()
        var waitingForResult = false
        defer {
            if !waitingForResult { ModeAnnouncement.navigationFinished(self, ticket: navigationTicket) }
            ModeAnnouncement.end()
        }
        positionMovedAt = Date()
        refreshIfNavigated()
        clearSelection()
        guard ensureContent({ [weak self] in self?.quickNav(q, forward: forward, afterRefresh: afterRefresh) }) else { waitingForResult = true; return }
        refreshBufferIfNeeded(stale: 20)
        /// Search the buffer by role (headings, buttons, links…): no WebKit to ask, or WebKit's answer is unusable.
        /// Nothing further this way: from the other end of the page (wrapping on), or "no next heading".
        func wrapOrStop() {
            defer { ModeAnnouncement.navigationFinished(self, ticket: navigationTicket) }
            // A copy read in part is not wrapped past its unread rest. A page being read again is wrapped from the copy
            // held, as the arrows read it: previous heading said only "top", five times on 13 Nov 2026, while a
            // refresh was under way (MacRumors: two presses running, during a read of 933 ms).
            if !canWrapFromCopy { reportBufferEnd(forward: forward); return }
            guard config.virtualBuffers.wrapQuickNav, let roles = BrowseModeDocument.quickNavRoles[q.name] else {
                Speech.speakMessage(Phrases.noNext(q.spoken, forward: forward)); return
            }
            let level = headingLevel(for: q)
            guard let (at, el) = buffer.find(from: forward ? -1 : buffer.text.length + 1, forward: forward, roles: roles, headingLevel: level), at != position else {
                Speech.speakMessage(Phrases.noNext(q.spoken, forward: forward)); return
            }
            Tones.edge()
            Speech.speakMessage(forward ? String(localized: "wrapped to the top", comment: "Spoken message") : String(localized: "wrapped to the bottom", comment: "Spoken message"))
            land(at, el)
        }
        /// Put the caret on what was found and read it.
        func land(_ at: Int, _ el: AXUIElement) {
            position = at
            lastQuickNavTarget = el
            if BrowseModeDocument.controlRoles.contains(el.role), !(el.role == "AXLink" && buffer.linkEnd(at: at) != nil) {
                let obj = ObjectFactory.make(el)
                Speech.speakMessage(Speech.objectPropertiesSpeech(obj, reason: .focus).joined(separator: ", "))
                ModeAnnouncement.navigationReported(self, object: obj)
                lastChain = []
            } else { speakQuickNavText(at: at, link: q.name.contains("Link"), element: el) }
        }
        func bufferSearch() {
            guard let roles = BrowseModeDocument.quickNavRoles[q.name] else { Speech.speakMessage(String(localized: "not available here", comment: "Spoken message")); return }
            let level = headingLevel(for: q)
            var hit = buffer.find(from: position, forward: forward, roles: roles, headingLevel: level)
            // A long page read only in part (a long chat, issue 227): read on first; with more still not read, said,
            // rather than wrapping to the top past it.
            if hit == nil, forward, buffer.canReadOn {
                waitingForResult = true
                readOnUntil({ [weak self] in
                    guard let self else { return true }
                    return buffer.find(from: position, forward: forward, roles: roles, headingLevel: level) != nil
                }) { [weak self] found in
                    guard let self else { return }
                    if !found, buffer.stoppedAtLimit { ModeAnnouncement.navigationFinished(self, ticket: navigationTicket); Speech.speakMessage(String(localized: "page read in part, it is very long", comment: "Spoken message")); return }
                    quickNav(q, forward: forward, afterRefresh: afterRefresh)
                }
                return
            }
            // Nothing ahead on a page that may have more below: once, the page read again from its end. Only where that
            // can find something (quickWrapWaits); elsewhere the wrap is at once, as NVDA's, and the end is looked at in
            // the background.
            let atTheEnd = hit == nil && forward && !afterRefresh
            if atTheEnd, !quickWrapWaits() { reachEndInBackground() }
            if atTheEnd, quickWrapWaits(), reachForMore({ [weak self] more in
                guard let self else { return }
                if more { quickNav(q, forward: forward, afterRefresh: true) } else { wrapOrStop() }
            }) { waitingForResult = true; return }
            guard let (at, el) = hit else {
                wrapOrStop(); return
            }
            position = at
            lastQuickNavTarget = el
            // A link with text in the buffer is read as text (with the link reported as the user set it), like the arrows.
            if BrowseModeDocument.controlRoles.contains(el.role), !(el.role == "AXLink" && buffer.linkEnd(at: at) != nil) {
                let obj = ObjectFactory.make(el)
                Speech.speakMessage(Speech.objectPropertiesSpeech(obj, reason: .focus).joined(separator: ", "))
                ModeAnnouncement.navigationReported(self, object: obj)
                lastChain = []
            } else { speakQuickNavText(at: at, link: q.name.contains("Link"), element: el) }
        }
        // P and N: paragraphs and the text after links come from the buffer's own text (NVDA's textParagraph and
        // notLinkBlock), never from WebKit's search.
        if q.name == "Paragraph" || q.name == "NotLinkBlock" {
            let kind: WebBuffer.TextKind = q.name == "Paragraph" ? .paragraph : .afterLinks
            var hit = buffer.findText(from: position, forward: forward, kind: kind)
            // The rest of a long page read on first (issue 227); with more still not read, said rather than wrapping.
            if hit == nil, forward, buffer.canReadOn {
                waitingForResult = true
                readOnUntil({ [weak self] in
                    guard let self else { return true }
                    return buffer.findText(from: position, forward: forward, kind: kind) != nil
                }) { [weak self] found in
                    guard let self else { return }
                    if !found, buffer.stoppedAtLimit { ModeAnnouncement.navigationFinished(self, ticket: navigationTicket); Speech.speakMessage(String(localized: "page read in part, it is very long", comment: "Spoken message")); return }
                    quickNav(q, forward: forward, afterRefresh: afterRefresh)
                }
                return
            }
            if hit == nil, canWrapFromCopy, config.virtualBuffers.wrapQuickNav,
               let w = buffer.findText(from: forward ? -1 : buffer.text.length + 1, forward: forward, kind: kind), w.offset != position {
                Tones.edge(); Speech.speakMessage(forward ? String(localized: "wrapped to the top", comment: "Spoken message") : String(localized: "wrapped to the bottom", comment: "Spoken message")); hit = w
            }
            guard let (at, el) = hit else { if !canWrapFromCopy { reportBufferEnd(forward: forward) } else { Speech.speakMessage(Phrases.noNext(q.spoken, forward: forward)) }; return }
            position = at
            if let el { lastQuickNavTarget = el }
            speakQuickNavText(at: at, link: false, element: el)
            return
        }
        // VoiceOver's D with no WebKit search: the next line that is a different kind of thing from this one.
        // (A silent page first: finding out whether WebKit's search is there asks the page.)
        if q.name == "DifferentItem", pageSilent || !hasWebKitSearch {
            let different = buffer.withSnapshot {
                let here = buffer.lineIndex(at: position).flatMap { buffer.lines[$0].element?.role }
                let order = forward ? Array(((buffer.lineIndex(at: position) ?? 0) + 1)..<buffer.lines.count) : Array((0..<(buffer.lineIndex(at: position) ?? 0)).reversed())
                return order.first { !buffer.lineContinues($0) && buffer.lines[$0].element?.role != here }
            }
            guard let j = different else {
                if buffer.isPartial || buffer.isLoading { reportBufferEnd(forward: forward) }
                else { Speech.speakMessage(forward ? String(localized: "no next different item", comment: "Spoken message") : String(localized: "no previous different item", comment: "Spoken message")) }; return
            }
            position = buffer.lines[j].start
            speakQuickNavText(at: position, link: false, element: buffer.lines[j].element)
            return
        }
        // Kinds WebKit's search has no key for (list items, separators, embedded objects, annotations, headings 7 to 9).
        // A page that is not answering: its own search would not answer either. The copy has the headings.
        if pageSilent { bufferSearch(); return }
        if !hasWebKitSearch || q.searchKey.isEmpty { bufferSearch(); return }
        let startEl = (try? rootObject.makeTextInfo(.caret) as? BufferTextInfo)?.element(at: position) ?? webArea
        let raw = bridge.search(key: q.searchKey, from: startEl, forward: forward, limit: q.roles == nil ? 1 : 25)
        // A page in a background window (Safari) answers with dead elements (no process, every attribute an error).
        var candidates = raw.filter { $0.pid > 0 && $0.role != "?" }
        if !raw.isEmpty && candidates.isEmpty {
            Log.io("browse mode: WebKit's search answered with \(raw.count) dead elements; searching the buffer")
            bufferSearch(); return
        }
        if let roles = q.roles { candidates = candidates.filter { roles.contains($0.role) } }
        // (A WebKit index was compared with the buffer's offset here to skip "the element we are on"; the two can
        // coincide by chance and a heading was skipped. The buffer-offset checks below do that job: code review, 16 Oct 2026.)
        // Nothing from the search: the buffer decides. Chromium's search (the ChatGPT app, Brave) answers nothing going
        // back, and "no previous heading" was said with headings above (a tester, 9 and 13 Oct 2026).
        guard let target = candidates.first else {
            // Kinds the buffer can't find by role (visited links, landmarks …) end as the search said.
            guard BrowseModeDocument.quickNavRoles[q.name] != nil else { wrapOrStop(); return }
            Log.io("browse mode: the page's search found nothing \(forward ? "ahead" : "back"); searching the buffer"); bufferSearch(); return
        }
        var found = buffer.offset(of: target)
        if found == nil {
            if afterRefresh { bufferSearch(); return }
            let wait = startCopyWait()
            waitingForResult = true
            buffer.build { [weak self] in
                guard let self else { return }
                guard copyWaitAnswers(wait, "next or previous \(q.name)") else {
                    ModeAnnouncement.navigationFinished(self, ticket: navigationTicket)
                    return
                }
                if let at = buffer.offset(of: target), at != position { land(at, target) } else { bufferSearch() }
            }
            return
        }
        if found == position, let again = bridge.search(key: q.searchKey, from: target, forward: forward, limit: 1).first, let at = buffer.offset(of: again) {
            found = at   // WebKit handed back the element we are on; the one past it is the move
        }
        guard let at = found else { Log.io("browse mode: WebKit's \(target.role) is not in the buffer; searching the buffer"); bufferSearch(); return }
        // WebKit handed back the element already under the caret (on a page still loading, or the first heading
        // going back): the buffer decides, so the answer is the next one or "no previous heading", never the same.
        if at == position { Log.io("browse mode: WebKit's answer is where the caret is; searching the buffer"); bufferSearch(); return }
        let r = (at, at)
        position = r.0
        lastQuickNavTarget = target
        // NVDA: report the item, then move. A control is reported as itself (label, role, value);
        // text is read with what it is inside of.
        if BrowseModeDocument.controlRoles.contains(target.role), !(target.role == "AXLink" && buffer.linkEnd(at: r.0) != nil) {
            let obj = ObjectFactory.make(target)
            Speech.speakMessage(Speech.objectPropertiesSpeech(obj, reason: .focus).joined(separator: ", ") + (obj.value.map { _ in "" } ?? ((obj.hasNavigableText && ((try? obj.makeTextInfo(.all))?.text.isEmpty ?? true)) ? ", " + Phrases.blank : "")))
            ModeAnnouncement.navigationReported(self, object: obj)
            lastChain = []
        } else {
            // The element too, so a heading wrapped over several lines is read whole (19 Nov 2026: H on a long AppleVis
            // heading said its first line, Down Arrow the rest); the buffer's own search below already passed it.
            speakQuickNavText(at: r.0, link: q.name.contains("Link"), element: target)
        }
    }

    /// A key that waits for a fresh copy of the page: what has to stay the same for it still to be answered.
    struct CopyWait { let epoch: Int; let movedAt: Date; let intent: Int; let keys: Int; let ticket: Int }
    func startCopyWait() -> CopyWait {
        copyWaitTicket += 1
        return CopyWait(epoch: pageGeneration, movedAt: positionMovedAt, intent: bufferIntent, keys: ScriptHandler.keysArrivedCount, ticket: copyWaitTicket)
    }
    /// Whether a key that waited for a fresh copy is still answered when the copy comes (17 Nov 2026). Until then any
    /// later key dropped it without a word: F in a long Claude chat said nothing when Tab or Shift came while the page
    /// was read (17 Nov 2026 log). Now it is dropped only when something else has answered or will: a later key moved the
    /// reading, the page changed or lost the keyboard, a later key is itself waiting for the copy, or focus mode came on.
    /// A later key that did none of these leaves it to be answered. Each drop has a log line.
    func copyWaitAnswers(_ wait: CopyWait, _ what: String) -> Bool {
        let stillThePage = API.focusTreeInterceptor === self
        let samePage = pageGeneration == wait.epoch
        let readingStayed = positionMovedAt == wait.movedAt
        let newestWait = copyWaitTicket == wait.ticket
        let lookedUpSince = bufferIntent != wait.intent
        let arrivedSince = ScriptHandler.keysArrivedCount != wait.keys
        let keysCame = lookedUpSince || arrivedSince
        let modeStayed = !keysCame || !passThrough
        if stillThePage, samePage, readingStayed, newestWait, modeStayed {
            if keysCame { Log.io("browse mode: \(what) waited for the page's copy; later keys moved nothing, so it is answered") }
            return true
        }
        let why = !stillThePage ? "the page lost the keyboard"
            : !samePage ? "the page changed"
            : !readingStayed ? "the reading moved"
            : !newestWait ? "a later key is waiting for the copy"
            : "focus mode came on"
        Log.io("browse mode: \(what) waited for the page's copy and is not answered: \(why)")
        return false
    }

    /// Whether quick navigation may wrap round from the copy held: it is not read in part, and it holds the page (a
    /// read again keeps the copy until it is done, and the arrows read it meanwhile).
    var canWrapFromCopy: Bool {
        if buffer.isPartial { return false }
        if buffer.lines.isEmpty { return false }
        return true
    }

    /// NVDA's TextInfoQuickNavItem.report: the line from the item, but no further than the item's end — a link
    /// is read as itself, not with the rest of its line (a second link on the line sounded like the first again).
    /// What quick navigation says on landing: the whole of the element found (a heading over two lines was read
    /// only to the end of its first line, then again from the caret, 8 Oct 2026), or the line when the
    /// element is not known.
    package func speakQuickNavText(at offset: Int, link: Bool, element: AXUIElement? = nil) {
        guard let info = makeTextInfo(.bookmark(Bookmark(start: offset, end: offset))) else { return }
        info.expand(.line)
        if element != nil, let i = buffer.lineIndex(at: offset) {
            // On through the lines that carry on the element (a wrapped heading), to the last.
            let (_, b) = buffer.elementRange(fromLine: i)
            info.end = max(info.end, b)
        }
        if link, let end = buffer.linkEnd(at: offset), end > offset {
            info.start = offset
            info.end = min(info.end, end)
        }
        speak(info, unit: .line)
        if let element = element ?? lastQuickNavTarget { ModeAnnouncement.navigationReported(self, object: ObjectFactory.make(element)) }
    }

    static func isInside(_ x: AXUIElement, _ root: AXUIElement) -> Bool {
        var p: AXUIElement? = x; var hops = 0
        while let e = p, hops < 12 { if e.isSame(root) { return true }; p = e.element(kAXParentAttribute); hops += 1 }
        return false
    }


    static let tabRoles: Set<String> = ["AXLink", "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXSlider", "AXMenuButton", "AXDisclosureTriangle"]

    /// Whether an offset in the copy falls inside a span (start, end) of it. Pure.
    package static func offset(_ at: Int, isInside span: (Int, Int)) -> Bool { at >= span.0 && at < span.1 }

    /// The span of one focus element from its pieces of text, starting at its own first piece: a link's own words (pieces
    /// that touch, as the quick-navigation search counts them), not the line they are on, so that a second link on the
    /// same line is not inside the first, and a link on the next line is not either (24 Nov 2026: "See the Terms and the
    /// Privacy notice"). Anything that is not a link has its lines (`lineEnd`). Pure.
    package static func ownSpan(startingAt start: Int, pieces: [(start: Int, end: Int, isLink: Bool)], lineEnd: Int) -> (Int, Int) {
        guard let first = pieces.first, first.start == start, first.isLink else { return (start, max(lineEnd, start + 1)) }
        var end = first.end
        for next in pieces.dropFirst() {
            guard next.isLink, next.start == end else { break }
            end = next.end
        }
        return (start, max(end, start + 1))
    }

    /// The span of the copy that is one element's own: its own words if it is a link, else its lines.
    func span(ofFocus element: AXUIElement) -> (Int, Int)? {
        guard let start = buffer.offset(of: element), let line = buffer.lineIndex(at: start) else { return nil }
        let (_, end) = buffer.elementRange(fromLine: line)
        return Self.ownSpan(startingAt: start, pieces: buffer.pieces(from: start), lineEnd: end)
    }

    /// The element, or a parent of it up to five levels, that takes the keyboard: the first one of a Tab role whose
    /// focus can be set. A link's text is found by its words: the link itself is a parent. Nothing is changed.
    static func focusTarget(from el: AXUIElement) -> AXUIElement? { focusTargets(from: el).first }

    /// All of them, nearest first: when the focus write on one fails, the walk goes on to the parent that can take it
    /// (Codex's review, 24 Nov 2026: the candidate was skipped after one failed write).
    static func focusTargets(from el: AXUIElement) -> [AXUIElement] {
        var found: [AXUIElement] = []
        var x: AXUIElement? = el; var hops = 0
        while let y = x, hops < 5 {
            var settable: DarwinBoolean = false
            let takesKeyboard = tabRoles.contains(y.role)
            let canSetFocus = takesKeyboard && AXUIElementIsAttributeSettable(y, kAXFocusedAttribute as CFString, &settable) == .success && settable.boolValue
            if canSetFocus { found.append(y) }
            x = y.element(kAXParentAttribute); hops += 1
        }
        return found
    }

    /// NVDA: Tab in browse mode goes on from the reading position, not from wherever the page's focus was left (the
    /// top of a long post, 3 Oct 2026). If the caret has moved since the focus did, focus the next (or previous)
    /// link or control after (before) it; the focus event then reads it. Otherwise the browser's own Tab.
    func focusFromCaret(forward: Bool) -> Bool {
        guard position != positionAtFocus else { return false }
        // Putting the keyboard on a control asks the page, some of it by calls that wait out the timeout each time.
        guard !pageSilent else { return false }
        // As NVDA's _tabOverride: a reading position inside the control that has the focus leaves Tab to the browser.
        let current = API.focusObject.flatMap { $0.pid == webArea.pid && !$0.isSameElement(as: webArea) ? $0.element : nil }
        // A control hidden inside a container has the container's place in the copy.
        let own = current.flatMap { span(ofFocus: focusPlace(of: $0)) }
        if let own, Self.offset(position, isInside: own) { return false }
        var from = position
        for _ in 0..<30 {
            guard let (at, el) = buffer.find(from: from, forward: forward, roles: Self.tabRoles) else { return false }
            // One walk for this candidate: the control that takes the keyboard. If it is the one that has the focus,
            // setting the focus would bring no event and nothing would be said (24 Nov 2026, 06:51:49; 23 Nov, 12:17:08).
            let targets = Self.focusTargets(from: el)
            let target = targets.first
            // Only a control that says it has the keyboard is read without a focus write (Codex's review, 24 Nov 2026: the
            // cached focus can be stale, and the write is what moves the keyboard).
            if let current, let target, target.isSame(current), (current.attr(kAXFocusedAttribute) as? Bool) == true {
                Log.io("browse mode: Tab from the reading position to the control that has the focus, at \(at); read here")
                position = at
                positionAtFocus = at
                // Spoken as the focus event speaks an object, not through the focus news, whose duplicate rule would drop it.
                // An explicit report: the repeat rule must not drop it either (Codex's review: arrows away and Tab back
                // within half a second said nothing).
                Speech.explicitFocusReport = true
                ObjectFactory.make(current).reportFocus()
                Speech.explicitFocusReport = false
                return true
            }
            for target in targets {
                // The focus write, on its own; if it fails, the next parent that can take the keyboard.
                let written = target.set(kAXFocusedAttribute, kCFBooleanTrue)
                if written == .success {
                    Log.io("browse mode: Tab from the reading position to \(target.role) at \(at)")
                    position = at
                    positionAtFocus = at
                    // A page whose script is stuck takes the request and does nothing until it wakes (the freeze
                    // test, 4 Oct 2026: Tab after Tab was silent). If the focus has not come within a second, say so.
                    PageWatch.keySent(to: target.pid)
                    return true
                }
            }
            from = at
        }
        return false
    }


    /// NVDA's comma and Shift comma: past the end of the list, table, block quote or landmark the caret is in, or to
    /// its start. The innermost one that holds the caret.
    func moveToContainerEdge(end: Bool) {
        refreshIfNavigated()
        clearSelection()
        guard ensureContent() else { return }
        refreshBufferIfNeeded(stale: 20)
        guard let c = buffer.containers.filter({ $0.start <= position && position < $0.end }).min(by: { $0.end - $0.start < $1.end - $1.start }) else {
            Speech.speakMessage(String(localized: "not in a container", comment: "Spoken message")); return
        }
        if end {
            guard c.end < buffer.text.length else {
                if buffer.isPartial || buffer.isLoading { reportBufferEnd(forward: true) }
                else {
                    let role = buffer.withSnapshot { ObjectFactory.make(c.element).role.displayString }
                    Speech.speakMessage(String(localized: "no more text after the \(role)", comment: "Moving past an element with no text after it: %@ is its role"))
                }
                return
            }
            position = c.end
        } else {
            position = c.start
        }
        speakUnit(.line, caretMoved: true)
    }

    /// The heading level a quick key wants: "Heading3" is 3; VoiceOver's M is the level of the heading the caret is
    /// in or last passed; anything else, none.
    func headingLevel(for q: QuickNavType) -> Int? {
        buffer.withSnapshot { headingLevelInSnapshot(for: q) }
    }
    private func headingLevelInSnapshot(for q: QuickNavType) -> Int? {
        if q.name.hasPrefix("Heading"), q.name.count > 7 { return Int(q.name.dropFirst(7)) }
        guard q.name == "SameLevelHeading", let i = buffer.lineIndex(at: position) else { return nil }
        for j in stride(from: i, through: 0, by: -1) {
            let l = buffer.lines[j]
            let h = l.element?.role == "AXHeading" ? l.element : l.entering.first { $0.role == "AXHeading" }
            if let h, let n = (h.attr(kAXValueAttribute) as? NSNumber)?.intValue { return n }
        }
        return nil
    }
}
