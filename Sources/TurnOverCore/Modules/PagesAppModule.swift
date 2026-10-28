// SPDX-License-Identifier: GPL-3.0-or-later
// Pages (17 Oct 2026, the Apple apps sweep). Pages is written for VoiceOver and its body text reads well with
// TurnOver's ordinary text support (lines, words, characters, selection: driver, the calibre demo document). Two
// things it needs on top:
// - Its reported focus slips: after Command-Down or Command-Up (and other jumps) Pages says the page layout
//   ("Document", an AXLayoutArea) has the focus while the caret is still in the text, so the next arrows found no
//   text and went silent. The focus is put back on the body text that holds the caret.
// - Headings: Pages marks a paragraph's style by name in its text attributes (AXStyleName "Heading", "Heading 2",
//   "Title"), so VO-Command-H and VO-Command-Shift-H go from heading to heading in the body, and the rotor's
//   headings with them.
import Foundation
import ApplicationServices

final class PagesAppModule: AppModule {
    static let bundleID = "com.apple.Pages"

    required init(pid: pid_t, bundleIdentifier: String, appName: String) {
        super.init(pid: pid, bundleIdentifier: bundleIdentifier, appName: appName)
        let cat = "Pages"
        // Named as VO-Command-H asks for them (VoiceOverKeys' find: the application module's "nextHeading" first).
        script("nextHeading", "The next heading in the document (VO-Command-H)", gestures: [], category: cat) { [weak self] g in
            self?.heading(forward: true, g)
        }.isAvailable = { [weak self] in self?.body() != nil }
        script("previousHeading", "The previous heading in the document (VO-Command-Shift-H)", gestures: [], category: cat) { [weak self] g in
            self?.heading(forward: false, g)
        }.isAvailable = { [weak self] in self?.body() != nil }
        // Tables: VO-Shift-Down on a table's line reads it cell by cell, as VoiceOver's interact does; the arrows move
        // by cell, VO-Shift-Up or Escape comes back to the text. Nothing in the document is selected or changed.
        script("app_interact", "Into the table on this line (VO-Shift-Down)", gestures: [], category: cat) { [weak self] g in
            guard let self, let t = self.tableOnLine() else { g.send(); return }
            self.table = t
            self.sayCell(entering: true)
        }.isAvailable = { [weak self] in self?.table == nil && self?.tableOnLine() != nil }
        for (key, dr, dc) in [("leftArrow", 0, -1), ("rightArrow", 0, 1), ("upArrow", -1, 0), ("downArrow", 1, 0)] {
            script("pages_table_\(key)", "In a table: the next cell that way", gestures: ["kb:\(key)"], category: cat) { [weak self] _ in
                self?.moveCell(dr, dc)
            }.isAvailable = { [weak self] in self?.table != nil }
        }
        script("app_stopInteracting", "Out of the table, back to the text (VO-Shift-Up)", gestures: [], category: cat) { [weak self] _ in
            self?.table = nil
            Speech.cancel(); Speech.speakMessage("out of table")
        }.isAvailable = { [weak self] in self?.table != nil }
        script("pages_tableEscape", "Out of the table, back to the text (Escape)", gestures: ["kb:escape"], category: cat) { [weak self] _ in
            self?.table = nil
            Speech.cancel(); Speech.speakMessage("out of table")
        }.isAvailable = { [weak self] in self?.table != nil }
    }

    // MARK: The body's text

    /// The pages' body text: its embedded objects named (Pages leaves a bare placeholder character for a table or a
    /// picture, which was read as "blank").
    override func objectClass(for element: AXUIElement, role: Role, subrole: String?) -> TurnOverObject.Type? {
        if element.role == "AXTextArea", element.element(kAXParentAttribute)?.role == "AXPage" { return PagesBody.self }
        return nil
    }

    // MARK: Focus

    /// The focus hopping from one page's body text to another's (or back from the layout) just after a key is the
    /// same text: the key's own reading stands ("Body, edit, blank" replaced the line after Command-Down, Up).
    override func ignoresFocus(_ event: Event) -> Bool {
        guard event.kind == .gainFocus, event.obj.element.role == "AXTextArea", event.obj.element.element(kAXParentAttribute)?.role == "AXPage",
              let prev = API.focusObject, prev.pid == pid, Date().timeIntervalSince(InputManager.lastKeyDownAt) < 1.5 else { return false }
        let prevIsBody = prev.element.role == "AXTextArea" && prev.element.element(kAXParentAttribute)?.role == "AXPage"
        let quiet = prevIsBody || prev.element.role == "AXLayoutArea"
        if quiet { quietFocus = (event.obj.element, Date()) }
        return quiet
    }
    private var quietFocus: (element: AXUIElement, at: Date)?
    /// Typing or the caret moving ends the reading of a table.
    private func endTableOnEdit(_ event: Event) { if table != nil, [.caret, .valueChange, .typedCharacter].contains(event.kind) { table = nil } }
    /// Not read: the hop ignoresFocus picked out (the focus object still follows it).
    /// The page the caret was on: "page 3" is said as it crosses onto another, after the line.
    private var lastPage: Int?
    private func notePage() {
        guard let text = body(), let page = text.element(kAXParentAttribute), page.role == "AXPage",
              let n = Int((page.string(kAXDescriptionAttribute) ?? "").components(separatedBy: CharacterSet.decimalDigits.inverted).first { !$0.isEmpty } ?? "") else { return }
        defer { lastPage = n }
        guard let last = lastPage, last != n else { return }
        Speech.speakMessage("page \(n)")
    }

    override func handleEvent(_ event: Event, next: () -> Void) {
        endTableOnEdit(event)
        if event.kind == .caret, event.obj.pid == pid, table == nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.notePage() } }
        if event.kind == .gainFocus, let q = quietFocus, Date().timeIntervalSince(q.at) < 1, q.element.isSame(event.obj.element) {
            quietFocus = nil
            Log.io("pages: the focus hopped to another page's body text after a key; not read")
            // A jump (Command-Up or Down, Page Up or Down) lands in another page's copy of the text, where the key's
            // own reading lost track of the caret: the line it landed on is read here instead (silence, 17 Oct 2026).
            let key = InputManager.lastKeyIdentifier
            if ["kb:command+upArrow", "kb:command+downArrow", "kb:pageUp", "kb:pageDown", "kb:command+home", "kb:command+end"].contains(key),
               let info = try? event.obj.makeTextInfo(.caret) {
                info.expand(.line)
                Speech.cancel()
                Speech.speakTextInfo(info, unit: .line, reason: .caret)
            }
            return
        }
        next()
    }

    /// The page layout reported as the focus while a body text holds the caret: the body text has it.
    override func redirectFocus(_ element: AXUIElement) -> AXUIElement? {
        guard element.role == "AXLayoutArea" else { return nil }
        let areas = Self.bodies(in: element)
        let focused = areas.first { ($0.attr(kAXFocusedAttribute) as? Bool) == true }
        // A .docx just opened (Pages 15.4, macOS 27.0.1, 28 Oct 2026): the layout keeps the focus and the body text
        // gives no caret (AXSelectedTextRange has no value in any page's copy), so the caret keys were silent and the
        // review keys read the whole story. Given the focus, as the navigator's moveFocusHere gives it, the body text
        // shows its caret again.
        if let body = focused ?? areas.first, Self.caret(body) == nil {
            let r = body.set(kAXFocusedAttribute, kCFBooleanTrue)
            Log.io("pages: the layout has the focus and no body text gives its caret; the body text focused → \(r.rawValue)")
            return body
        }
        if let focused { return focused }
        // None says so: the one whose part of the story holds the caret, else the first.
        guard let caret = Self.caret(areas.first) else { return areas.first }
        return areas.first { a in
            guard let v = a.attr("AXSharedCharacterRange"), CFGetTypeID(v) == AXValueGetTypeID() else { return false }
            var r = CFRange(); axValue(v, .cfRange, &r)
            return caret >= r.location && caret <= r.location + r.length
        } ?? areas.first
    }

    /// The pages' body texts under the layout.
    static func bodies(in layout: AXUIElement) -> [AXUIElement] {
        layout.elements(kAXChildrenAttribute).filter { $0.role == "AXPage" }.flatMap { page in
            page.elements(kAXChildrenAttribute).filter { $0.role == "AXTextArea" }
        }
    }

    /// The page's body text whose part of the story holds an offset (each page's copy answers only for its page).
    static func body(holding offset: Int, near text: AXUIElement) -> AXUIElement? {
        guard let layout = text.element(kAXParentAttribute)?.element(kAXParentAttribute) else { return nil }
        return bodies(in: layout).first { a in
            guard let v = a.attr("AXSharedCharacterRange"), CFGetTypeID(v) == AXValueGetTypeID() else { return false }
            var r = CFRange(); axValue(v, .cfRange, &r)
            return offset >= r.location && offset < r.location + r.length
        }
    }

    static func caret(_ e: AXUIElement?) -> Int? {
        guard let e, let v = e.attr(kAXSelectedTextRangeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange(); axValue(v, .cfRange, &r)
        return r.location
    }

    /// The body text the keyboard is in, if it is: the page's copy now holding the caret. (The one TurnOver met
    /// first leaves accessibility once its page scrolls away, and a stale one answers nothing: the table on the
    /// caret's line was never found, 18 Oct 2026.)
    private func body() -> AXUIElement? {
        guard let f = API.focusObject, f.pid == pid else { return nil }
        let isBody = f.element.role == "AXTextArea" && f.element.element(kAXParentAttribute)?.role == "AXPage"
        guard isBody || f.element.role == "AXLayoutArea" else { return nil }
        guard let layout = Self.layout(of: pid) else { return isBody ? f.element : nil }
        let all = Self.bodies(in: layout)
        guard let caret = all.lazy.compactMap({ Self.caret($0) }).first else { return all.first }
        return all.first { a in
            guard let v = a.attr("AXSharedCharacterRange"), CFGetTypeID(v) == AXValueGetTypeID() else { return false }
            var r = CFRange(); axValue(v, .cfRange, &r)
            return caret >= r.location && caret <= r.location + r.length
        } ?? all.first
    }

    /// The document's page layout in the front window.
    static func layout(of pid: pid_t) -> AXUIElement? {
        guard let w = AXUIElementCreateApplication(pid).element(kAXFocusedWindowAttribute) else { return nil }
        func find(_ e: AXUIElement, _ d: Int) -> AXUIElement? {
            if e.role == "AXLayoutArea" { return e }
            if d > 4 { return nil }
            for c in e.elements(kAXChildrenAttribute) { if let f = find(c, d + 1) { return f } }
            return nil
        }
        return find(w, 0)
    }

    // MARK: Tables

    struct TableCursor { let name: String; let layout: AXUIElement; let rows: Int; let cols: Int; var row: Int; var col: Int; var lastMove: (Int, Int) }
    private var table: TableCursor?

    /// The table whose placeholder is on the caret's line.
    private func tableOnLine() -> TableCursor? {
        guard let text = body() else { return nil }
        guard let caret = Self.caret(text),
              let lineV = text.param(kAXLineForIndexParameterizedAttribute, caret as CFNumber) as? Int,
              let rv = text.param(kAXRangeForLineParameterizedAttribute, lineV as CFNumber), CFGetTypeID(rv) == AXValueGetTypeID() else { return nil }
        var r = CFRange(); axValue(rv, .cfRange, &r)
        guard let line = Self.text(text, r.location, r.length) else { return nil }
        var offset = r.location
        for ch in line {
            if ch == Attachments.mark, let o = PagesTextInfo.objectElement(in: text, at: offset), o.role == "AXTable",
               let size = PagesTable.size(of: o), let layout = text.element(kAXParentAttribute)?.element(kAXParentAttribute) {
                return TableCursor(name: PagesTable.name(of: o), layout: layout, rows: size.rows, cols: size.cols, row: 0, col: 0, lastMove: (0, 0))
            }
            offset += String(ch).utf16.count
        }
        return nil
    }

    private func moveCell(_ dr: Int, _ dc: Int) {
        guard var t = table else { return }
        let r = t.row + dr, c = t.col + dc
        guard r >= 0, r < t.rows, c >= 0, c < t.cols else { Tones.edge(); return }
        t.row = r; t.col = c; t.lastMove = (dr, dc)
        table = t
        sayCell(entering: false)
    }

    private func sayCell(entering: Bool) {
        guard let t = table else { return }
        let cell = PagesTable.cell(t.layout, t.name, row: t.row, col: t.col)
        let v = cell.map(PagesTable.value) ?? ""
        let words = v.isEmpty ? "blank" : v
        var parts: [String] = []
        if entering { parts.append("\(t.name), \(t.rows) rows, \(t.cols) columns") }
        // Along a row, the column's heading (the first row); down a column, the row's (the first column).
        if t.lastMove.1 != 0 || entering, t.row > 0, let h = PagesTable.cell(t.layout, t.name, row: 0, col: t.col).map(PagesTable.value), !h.isEmpty { parts.append(h) }
        if t.lastMove.0 != 0, t.col > 0, let h = PagesTable.cell(t.layout, t.name, row: t.row, col: 0).map(PagesTable.value), !h.isEmpty { parts.append(h) }
        parts.append(words)
        if entering || t.lastMove.0 != 0 { parts.append("row \(t.row + 1)") }
        if entering || t.lastMove.1 != 0 { parts.append("column \(t.col + 1)") }
        Speech.cancel()
        Speech.speakMessage(parts.joined(separator: ", "))
    }

    // MARK: Headings

    struct Heading { let start: Int; let level: Int?; let name: String }
    private var headingCache: (length: Int, at: Date, list: [Heading])?

    /// Every paragraph styled as a heading or title, from the text's style names (2,000 characters at a time).
    private func headings(_ text: AXUIElement) -> [Heading] {
        let total = (text.attr(kAXNumberOfCharactersAttribute) as? Int) ?? 0
        if let c = headingCache, c.length == total, Date().timeIntervalSince(c.at) < 5 { return c.list }
        var out: [Heading] = []
        var loc = 0
        while loc < total {
            var r = CFRange(location: loc, length: min(2000, total - loc))
            guard let rv = AXValueCreate(.cfRange, &r) else { break }
            var o: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(text, "AXAttributedStringForRange" as CFString, rv, &o) == .success,
                  let att = o as? NSAttributedString else { break }
            att.enumerateAttribute(NSAttributedString.Key("AXStyleName"), in: NSRange(location: 0, length: att.length)) { v, range, _ in
                guard let name = v as? String else { return }
                let lower = name.lowercased()
                guard lower.hasPrefix("heading") || lower == "title" || lower == "subtitle" else { return }
                let start = loc + range.location
                // A style run continuing from the chunk before is the same paragraph.
                if let last = out.last, last.name == name, start <= last.start + 400, (att.string as NSString).substring(to: range.location).isEmpty { return }
                let level = lower == "title" ? 0 : Int(name.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? (lower.hasPrefix("heading") ? 1 : nil)
                out.append(Heading(start: start, level: level, name: name))
            }
            loc += 2000
        }
        // Runs of one paragraph broken by formatting inside it: keep the first of each paragraph.
        var merged: [Heading] = []
        for h in out where !(merged.last.map { prev in prev.name == h.name && !(Self.text(text, prev.start, h.start - prev.start) ?? "").contains("\n") } ?? false) { merged.append(h) }
        headingCache = (total, Date(), merged)
        return merged
    }

    static func text(_ e: AXUIElement, _ start: Int, _ length: Int) -> String? {
        guard length > 0 else { return "" }
        var r = CFRange(location: start, length: length)
        guard let rv = AXValueCreate(.cfRange, &r) else { return nil }
        var o: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(e, kAXStringForRangeParameterizedAttribute as CFString, rv, &o) == .success else { return nil }
        return o as? String
    }

    private func heading(forward: Bool, _ g: KeyboardGesture) {
        guard let text = body(), let caret = Self.caret(text) else {
            // Outside the body (a dialog, the sidebar): TurnOver's own search of the window.
            if let s = GlobalCommands.shared.script(named: forward ? "nextHeading" : "previousHeading") { s.handler(g) } else { Speech.speakMessage("not in a document") }
            return
        }
        let list = headings(text)
        Log.io("pages: \(list.count) headings; caret \(caret)")
        guard let h = forward ? list.first(where: { $0.start > caret }) : list.last(where: { $0.start < caret }) else {
            Tones.edge(); Speech.speakMessage(forward ? "no next heading" : "no previous heading"); return
        }
        var r = CFRange(location: h.start, length: 0)
        if let rv = AXValueCreate(.cfRange, &r) { _ = text.set(kAXSelectedTextRangeAttribute, rv) }
        let total = (text.attr(kAXNumberOfCharactersAttribute) as? Int) ?? h.start
        let words = (Self.text(text, h.start, min(300, total - h.start)) ?? "").components(separatedBy: "\n").first ?? ""
        let kind = h.level == 0 ? "title" : h.level.map { "heading \($0)" } ?? "heading"
        Speech.cancel()
        Speech.speakMessage("\(words.trimmingCharacters(in: .whitespaces)), \(kind)")
    }
}

/// A page's body text in Pages.
final class PagesBody: EditableText {
    override var textInfoClass: TextInfo.Type { PagesTextInfo.self }
}

/// Pages' text with its embedded objects named: "table, 13 rows, 13 columns", "image, Sunset", "footnote 1".
final class PagesTextInfo: AXTextInfo {
    override func textRange(_ s: Int, _ e: Int) -> String {
        let e = min(e, storyLength())
        guard e > s, let t = textElement.param(kAXStringForRangeParameterizedAttribute, axRangeValue(s, e - s)) as? String else { return super.textRange(s, e) }
        guard t.contains(Attachments.mark) else { return t }
        var out = ""
        var offset = s
        for ch in t {
            if ch == Attachments.mark {
                let name = PagesTextInfo.objectName(in: textElement, at: offset)
                out += out.isEmpty || out.hasSuffix(" ") || out.hasSuffix("\n") ? name : " " + name
                out += ", "
            } else { out.append(ch) }
            offset += String(ch).utf16.count
        }
        return out.replacingOccurrences(of: ", \n", with: "\n").replacingOccurrences(of: ", , ", with: ", ")
    }

    /// What sits at a placeholder: the attachment Pages names (a footnote), else the table or picture on the page
    /// that the placeholder's position falls in.
    static func objectName(in text: AXUIElement, at offset: Int) -> String {
        guard let o = attachment(in: text, at: offset) else { return "object" }
        if o.role == "AXLink", let n = o.string(kAXTitleAttribute), n.lowercased().hasPrefix("footnote") { return n.lowercased() }
        return describe(o)
    }

    /// What a placeholder stands for: Pages points each one at its table, picture or footnote (the text attribute
    /// AXAttachment), but only through the copy of the story on that object's page, and only while that page is laid
    /// out (17 and 18 Oct 2026: asked of another page's copy, it answered nothing).
    static func attachment(in given: AXUIElement, at offset: Int) -> AXUIElement? {
        var copies: [AXUIElement] = []
        if let holder = PagesAppModule.body(holding: offset, near: given) { copies.append(holder) }
        if let l = PagesAppModule.layout(of: given.pid) { copies += PagesAppModule.bodies(in: l) }
        copies.append(given)
        for text in copies {
            guard let att = text.param(kAXAttributedStringForRangeParameterizedAttribute, axRangeValue(offset, 1)) as? NSAttributedString, att.length > 0,
                  let v = att.attribute(NSAttributedString.Key("AXAttachment"), at: 0, effectiveRange: nil), CFGetTypeID(v as CFTypeRef) == AXUIElementGetTypeID() else { continue }
            return (v as! AXUIElement)
        }
        return nil
    }

    static func objectElement(in given: AXUIElement, at offset: Int) -> AXUIElement? {
        guard let o = attachment(in: given, at: offset), o.role != "AXLink" else { return nil }
        return o
    }

    static func describe(_ o: AXUIElement) -> String {
        switch o.role {
        case "AXTable":
            // "Table 3, paginated, rows 1 to 4 of 8, columns 1 to 4 of 4": the whole table's size.
            let title = o.string(kAXTitleAttribute) ?? ""
            if let size = PagesTable.size(of: o) { return "\(PagesTable.name(of: o)), \(size.rows) row\(size.rows == 1 ? "" : "s"), \(size.cols) column\(size.cols == 1 ? "" : "s")" }
            return title.isEmpty ? "table" : title
        case "AXImage":
            let d = o.string(kAXDescriptionAttribute) ?? o.string(kAXTitleAttribute) ?? ""
            return d.isEmpty ? "image" : "image, \(d)"
        default:
            let d = o.string(kAXDescriptionAttribute) ?? ""
            return d.isEmpty ? "object" : d
        }
    }

}

/// Pages' tables read without selecting anything: any cell is asked for by column and row (AXCellForColumnAndRow),
/// and a table split across pages is several AXTables of one name ("Table 3, paginated, rows 1 to 4 of 8, …").
enum PagesTable {
    /// "Table 3".
    static func name(of t: AXUIElement) -> String {
        (t.string(kAXTitleAttribute) ?? "table").components(separatedBy: ", ").first ?? "table"
    }

    /// The whole table's size, from Pages' title: "6 rows, 6 columns", "1 row, 2 columns", or, split across pages,
    /// "rows 1 to 4 of 8, columns 1 to 4 of 4".
    static func size(of t: AXUIElement) -> (rows: Int, cols: Int)? {
        let title = t.string(kAXTitleAttribute) ?? ""
        func num(_ pattern: String) -> Int? {
            guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
                  let r = Range(m.range(at: 1), in: title) else { return nil }
            return Int(title[r])
        }
        if let rows = num(#"rows \d+ to \d+ of (\d+)"#), let cols = num(#"columns \d+ to \d+ of (\d+)"#) { return (rows, cols) }
        if let rows = num(#"(\d+) rows?"#), let cols = num(#"(\d+) columns?"#) { return (rows, cols) }
        return nil
    }

    static func cell(_ layout: AXUIElement, _ name: String, row: Int, col: Int) -> AXUIElement? {
        let parts = layout.elements(kAXChildrenAttribute).filter { $0.role == "AXPage" }.flatMap { $0.elements(kAXChildrenAttribute) }
            .filter { $0.role == "AXTable" && Self.name(of: $0) == name }
        for p in parts {
            var out: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(p, "AXCellForColumnAndRow" as CFString, [col, row] as CFArray, &out) == .success,
               let o = out, CFGetTypeID(o) == AXUIElementGetTypeID() { return (o as! AXUIElement) }
        }
        return nil
    }

    /// A cell's words: its lines joined, without Pages' notes ("spans 4,294,967,309 columns" on a merged cell).
    static func value(_ cell: AXUIElement) -> String {
        var t = cell.string(kAXTitleAttribute) ?? cell.string(kAXValueAttribute) ?? ""
        if let re = try? NSRegularExpression(pattern: #", spans [\d,]{8,} (columns|rows)"#) { t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "") }
        return t.components(separatedBy: CharacterSet(charactersIn: "\n\t")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

