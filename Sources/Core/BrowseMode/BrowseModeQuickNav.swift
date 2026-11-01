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

    func quickNav(_ q: QuickNavType, forward: Bool) {
        refreshIfNavigated()
        clearSelection()
        guard ensureContent() else { return }
        rebuildIfCheap(stale: 20)
        /// Search the buffer by role (headings, buttons, links…): no WebKit to ask, or WebKit's answer is unusable.
        /// Nothing further this way: from the other end of the page (wrapping on), or "no next heading".
        func wrapOrStop() {
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
                lastChain = []
            } else { speakQuickNavText(at: at, link: q.name.contains("Link"), element: el) }
        }
        func bufferSearch() {
            guard let roles = BrowseModeDocument.quickNavRoles[q.name] else { Speech.speakMessage(String(localized: "not available here", comment: "Spoken message")); return }
            let level = headingLevel(for: q)
            var hit = buffer.find(from: position, forward: forward, roles: roles, headingLevel: level)
            // Nothing ahead on a page that may have more below (): once, the page read again from its end.
            if hit == nil, forward, reachForMore() { hit = buffer.find(from: position, forward: forward, roles: roles, headingLevel: level) }
            guard let (at, el) = hit else {
                wrapOrStop(); return
            }
            position = at
            lastQuickNavTarget = el
            // A link with text in the buffer is read as text (with the link reported as the user set it), like the arrows.
            if BrowseModeDocument.controlRoles.contains(el.role), !(el.role == "AXLink" && buffer.linkEnd(at: at) != nil) {
                let obj = ObjectFactory.make(el)
                Speech.speakMessage(Speech.objectPropertiesSpeech(obj, reason: .focus).joined(separator: ", "))
                lastChain = []
            } else { speakQuickNavText(at: at, link: q.name.contains("Link"), element: el) }
        }
        // P and N: paragraphs and the text after links come from the buffer's own text (NVDA's textParagraph and
        // notLinkBlock), never from WebKit's search.
        if q.name == "Paragraph" || q.name == "NotLinkBlock" {
            let kind: WebBuffer.TextKind = q.name == "Paragraph" ? .paragraph : .afterLinks
            var hit = buffer.findText(from: position, forward: forward, kind: kind)
            if hit == nil, config.virtualBuffers.wrapQuickNav,
               let w = buffer.findText(from: forward ? -1 : buffer.text.length + 1, forward: forward, kind: kind), w.offset != position {
                Tones.edge(); Speech.speakMessage(forward ? String(localized: "wrapped to the top", comment: "Spoken message") : String(localized: "wrapped to the bottom", comment: "Spoken message")); hit = w
            }
            guard let (at, el) = hit else { Speech.speakMessage(Phrases.noNext(q.spoken, forward: forward)); return }
            position = at
            if let el { lastQuickNavTarget = el }
            speakQuickNavText(at: at, link: false, element: el)
            return
        }
        // VoiceOver's D with no WebKit search: the next line that is a different kind of thing from this one.
        if q.name == "DifferentItem", !hasWebKitSearch {
            let here = buffer.lineIndex(at: position).flatMap { buffer.lines[$0].element?.role }
            let order = forward ? Array(((buffer.lineIndex(at: position) ?? 0) + 1)..<buffer.lines.count) : Array((0..<(buffer.lineIndex(at: position) ?? 0)).reversed())
            guard let j = order.first(where: { !buffer.lineContinues($0) && buffer.lines[$0].element?.role != here }) else {
                Speech.speakMessage(forward ? String(localized: "no next different item", comment: "Spoken message") : String(localized: "no previous different item", comment: "Spoken message")); return
            }
            position = buffer.lines[j].start
            speakQuickNavText(at: position, link: false, element: buffer.lines[j].element)
            return
        }
        // Kinds WebKit's search has no key for (list items, separators, embedded objects, annotations, headings 7 to 9).
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
        if found == nil { buffer.build(); clampPosition(); found = buffer.offset(of: target) }
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
            lastChain = []
        } else {
            speakQuickNavText(at: r.0, link: q.name.contains("Link"))
        }
    }

    /// NVDA's TextInfoQuickNavItem.report: the line from the item, but no further than the item's end — a link
    /// is read as itself, not with the rest of its line (a second link on the line sounded like the first again).
    /// What quick navigation says on landing: the whole of the element found (a heading over two lines was read
    /// only to the end of its first line, then again from the caret, 8 Oct 2026), or the line when the
    /// element is not known.
    func speakQuickNavText(at offset: Int, link: Bool, element: AXUIElement? = nil) {
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
    }

    static func isInside(_ x: AXUIElement, _ root: AXUIElement) -> Bool {
        var p: AXUIElement? = x; var hops = 0
        while let e = p, hops < 12 { if e.isSame(root) { return true }; p = e.element(kAXParentAttribute); hops += 1 }
        return false
    }


    /// NVDA: Tab in browse mode goes on from the reading position, not from wherever the page's focus was left (the
    /// top of a long post, 3 Oct 2026). If the caret has moved since the focus did, focus the next (or previous)
    /// link or control after (before) it; the focus event then reads it. Otherwise the browser's own Tab.
    func focusFromCaret(forward: Bool) -> Bool {
        guard position != positionAtFocus else { return false }
        let roles: Set<String> = ["AXLink", "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXSlider", "AXMenuButton", "AXDisclosureTriangle"]
        var from = position
        for _ in 0..<30 {
            guard let (at, el) = buffer.find(from: from, forward: forward, roles: roles) else { return false }
            // A link's text is found by its words: the link itself is a parent.
            var x: AXUIElement? = el; var hops = 0
            while let y = x, hops < 5 {
                var settable: DarwinBoolean = false
                if roles.contains(y.role), AXUIElementIsAttributeSettable(y, kAXFocusedAttribute as CFString, &settable) == .success, settable.boolValue,
                   y.set(kAXFocusedAttribute, kCFBooleanTrue) == .success {
                    Log.io("browse mode: Tab from the reading position to \(y.role) at \(at)")
                    position = at
                    positionAtFocus = at
                    // A page whose script is stuck takes the request and does nothing until it wakes (the freeze
                    // test, 4 Oct 2026: Tab after Tab was silent). If the focus has not come within a second, say so.
                    PageWatch.keySent(to: y.pid)
                    return true
                }
                x = y.element(kAXParentAttribute); hops += 1
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
        rebuildIfCheap(stale: 20)
        guard let c = buffer.containers.filter({ $0.start <= position && position < $0.end }).min(by: { $0.end - $0.start < $1.end - $1.start }) else {
            Speech.speakMessage(String(localized: "not in a container", comment: "Spoken message")); return
        }
        if end {
            guard c.end < buffer.text.length else { Speech.speakMessage(String(localized: "no more text after the \(ObjectFactory.make(c.element).role.displayString)", comment: "Moving past an element with no text after it: %@ is its role")); return }
            position = c.end
        } else {
            position = c.start
        }
        speakUnit(.line)
    }

    /// The heading level a quick key wants: "Heading3" is 3; VoiceOver's M is the level of the heading the caret is
    /// in or last passed; anything else, none.
    func headingLevel(for q: QuickNavType) -> Int? {
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
