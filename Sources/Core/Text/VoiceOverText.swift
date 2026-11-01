// SPDX-License-Identifier: GPL-3.0-or-later
// VoiceOver's text and orientation commands the parity audit found missing or different (13 Oct 2026), by Apple's
// VoiceOver command pages (Text, Orientation, General, Interaction): VO-Home and VO-End in text, VO-Shift-Home and
// VO-Shift-End, VO-Return's text selection, VO-F4 twice, VO-F7 three times, VO-Shift-S's scrolling.
import Foundation
import AppKit
import Network

extension VoiceOverKeysPlugin {
    /// VO-Home, VO-End: the start or end of the text. VO-Shift-Home, VO-Shift-End: the first or last word in view.
    static func textEdge(_ f: TurnOverObject, last: Bool, visible: Bool) {
        guard let caret = try? f.makeTextInfo(.caret) else { Speech.speakMessage(String(localized: "no text", comment: "Spoken message")); return }
        let n = caret.storyLength()
        var target = last ? n : 0
        var unit: TextUnit = .line
        if visible, let v = f.element.attr(kAXVisibleCharacterRangeAttribute), CFGetTypeID(v) == AXValueGetTypeID() {
            var r = CFRange(); axValue(v, .cfRange, &r)
            target = last ? max(r.location, r.location + r.length - 1) : r.location
            unit = .word
        }
        target = max(0, min(n, target))
        caret.setCaretOffset(target)
        guard let at = try? f.makeTextInfo(.bookmark(Bookmark(start: target, end: target))) else { return }
        if unit == .word, last { at.expand(.word); at.setCaretOffset(at.start) }
        at.expand(unit)
        Speech.speakTextInfo(at, unit: unit, reason: .caret)
    }

    /// VO-Return in a text field: the first press marks where the selection starts; move with the arrows; the second
    /// press selects from there to the insertion point.
    nonisolated(unsafe) static var selectionAnchor: (element: AXUIElement, offset: Int)?   // main thread only
    static func textSelection(_ f: TurnOverObject) {
        guard let caret = try? f.makeTextInfo(.caret) else { Speech.speakMessage(String(localized: "no text", comment: "Spoken message")); return }
        guard let a = selectionAnchor, a.element.isSame(f.element) else {
            selectionAnchor = (f.element, caret.start)
            Speech.speakMessage(String(localized: "selection start", comment: "Spoken message"))
            return
        }
        selectionAnchor = nil
        let s = min(a.offset, caret.start), e = max(a.offset, caret.start)
        guard e > s else { Speech.speakMessage(String(localized: "nothing selected", comment: "Spoken message")); return }
        caret.setSelectionOffsets(s, e)
        let chosen = (try? f.makeTextInfo(.bookmark(Bookmark(start: s, end: e))))?.text ?? ""
        Speech.speakMessage(chosen.count > 300 ? String(localized: "\(Phrases.characters(e - s)) selected", comment: "A long selection: %@ is the count of characters") : String(localized: "selected \(chosen)", comment: "Selected text, read: %@ is the text"))
    }

    /// VO-F4 twice: more about the keyboard focus; in text, where the insertion point is.
    static func focusDetails() {
        guard let f = API.focusObject else { Speech.speakMessage(String(localized: "no focus", comment: "Spoken message")); return }
        if f.hasNavigableText, let caret = try? f.makeTextInfo(.caret) {
            let line = (f.element.param(kAXLineForIndexParameterizedAttribute, caret.start as CFNumber) as? Int).map { $0 + 1 }
            let lineInfo = caret.copy(); lineInfo.expand(.line)
            let column = caret.start - lineInfo.start + 1
            let total = lineCounts(f.element)
            Speech.speakMessage([String(localized: "insertion point", comment: "The caret, as VoiceOver calls it"), line.map { String(localized: "line \(String($0))", comment: "Where the caret is: the line number") },
                                 Phrases.column(column), total.isEmpty ? nil : total].compactMap { $0 }.joined(separator: ", "))
            return
        }
        var parts = Speech.objectPropertiesSpeech(f, reason: .query)
        if let p = f.positionInfo, let i = p.index, let n = p.count { parts.append(Phrases.position(i, of: n)) }
        if let h = f.element.string(kAXHelpAttribute), !h.isEmpty { parts.append(h) }
        Speech.speakMessage(parts.joined(separator: ", "))
    }

    /// VO-F7 three times: whether the Mac is online, and how.
    static func networkStatus() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let how = path.usesInterfaceType(.wifi) ? "Wi-Fi" : path.usesInterfaceType(.wiredEthernet) ? "Ethernet"
                : path.usesInterfaceType(.cellular) ? String(localized: "a phone", comment: "How the Mac is online: through a phone") : String(localized: "another connection", comment: "How the Mac is online")
            let text = path.status == .satisfied ? String(localized: "network connected by \(how)", comment: "How the Mac is online: %@ is how") : String(localized: "no network connection", comment: "The Mac is offline")
            monitor.cancel()
            onMain { Speech.speakMessage(text) }
        }
        monitor.start(queue: DispatchQueue.global(qos: .userInitiated))
    }

    /// VO-Shift-S: scroll the area with the keys, as VoiceOver's scroll bar commands do. Up and Down (Left and Right
    /// for a sideways bar) a little; Page Up and Page Down a page; Shift Page Up and Down to the top and bottom.
    static func scrollMode(_ area: AXUIElement) {
        let bars = area.elements(kAXChildrenAttribute).filter { $0.role == "AXScrollBar" }
        let vertical = bars.first { $0.string(kAXOrientationAttribute) == "AXVerticalOrientation" }
        let horizontal = bars.first { $0.string(kAXOrientationAttribute) == "AXHorizontalOrientation" }
        guard vertical ?? horizontal != nil else { Speech.speakMessage(String(localized: "no scroll bars", comment: "Spoken message")); return }
        func value(_ bar: AXUIElement) -> Double { (bar.attr(kAXValueAttribute) as? NSNumber)?.doubleValue ?? 0 }
        func set(_ bar: AXUIElement, _ v: Double) {
            let n = max(0, min(1, v))
            _ = bar.set(kAXValueAttribute, NSNumber(value: n))
            Speech.speakMessage(Phrases.percent(Int((value(bar) * 100).rounded())))
        }
        Speech.speakMessage(String(localized: "scrolling. Arrows, Page Up and Page Down; Escape stops", comment: "Spoken message"))
        func next() {
            InputManager.captureNext = { g in
                guard let g, !["escape", "enter", "numpadEnter"].contains(g.keyName) else { Speech.speakMessage(String(localized: "done", comment: "Spoken message")); return }
                let shift = g.modifiers.contains(.shift)
                switch g.keyName {
                case "upArrow": if let b = vertical { set(b, value(b) - 0.05) }
                case "downArrow": if let b = vertical { set(b, value(b) + 0.05) }
                case "leftArrow": if let b = horizontal { set(b, value(b) - 0.05) }
                case "rightArrow": if let b = horizontal { set(b, value(b) + 0.05) }
                case "pageUp": if let b = vertical ?? horizontal { set(b, shift ? 0 : value(b) - 0.25) }
                case "pageDown": if let b = vertical ?? horizontal { set(b, shift ? 1 : value(b) + 0.25) }
                default: Tones.edge()
                }
                next()
            }
        }
        next()
    }
}

extension ObjectNavigator {
    /// VO-A outside text: everything in the item in the VoiceOver cursor, as its parts say themselves.
    public func readContents() {
        guard let cur = element else { Speech.speakMessage(String(localized: "nothing here", comment: "Spoken message")); return }
        guard Self.isGroup(cur) || !cur.elements(kAXChildrenAttribute).isEmpty else { Speech.speakText(Self.words(cur)); return }
        // A list or table: its rows from the selected one on, thirty at most. Walking the whole thing (Mail's 301
        // messages: 5,147 accessibility calls) held TurnOver for three to four seconds before a word, read from the
        // first message whichever was selected, and the trackpad's gestures queued up behind it and ran all at once
        // (19 Oct 2026, two-finger flick down in Mail).
        if ["AXTable", "AXOutline", "AXList"].contains(cur.role) {
            let rows = cur.elements("AXRows").isEmpty ? cur.elements(kAXChildrenAttribute) : cur.elements("AXRows")
            if !rows.isEmpty {
                let selected = cur.elements("AXSelectedRows").first ?? cur.elements("AXSelectedChildren").first
                let from = selected.flatMap { s in rows.firstIndex { $0.isSame(s) } } ?? 0
                let parts = rows[from..<min(rows.count, from + 30)].map { Self.words($0) }.filter { !$0.isEmpty }
                Log.io("read contents: \(parts.count) rows from row \(from + 1) of \(rows.count)")
                Speech.speakText(parts.joined(separator: ". "))
                return
            }
        }
        let parts = Self.groupItems(cur).prefix(120).map { Self.words($0) }.filter { !$0.isEmpty }
        Speech.speakText((parts.isEmpty ? [Self.words(cur)] : parts).joined(separator: ". "))
    }
}
