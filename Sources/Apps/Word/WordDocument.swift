// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import AppKit

/// The document body: NVDA's WordDocument. Editable text whose TextInfo reads
/// through the page areas, plus the structure commands through the object model.
final class WordDocument: EditableText {
    override var role: Role { .document }
    override var name: String { "" }   // "Page 3 content" is not a name the user needs; the window title was just spoken
    override var textInfoClass: TextInfo.Type { WordTextInfo.self }
    override var states: Set<State> { super.states.subtracting([.unavailable]) }   // Word reports AXEnabled false on its page areas

    var module: WordAppModule? { appModule as? WordAppModule }

    /// Arrowing onto a table: Word moves the caret into its first cell, and that cell's focus says the table, row,
    /// column and text. The page's own text there is only Word's stand-in ("Table, 6 Rows, 2 Columns, , "): say
    /// nothing for it, unless the focus stays on the page.
    override func caretMoved(speak unit: TextUnit?, gesture: KeyboardGesture, info: TextInfo?) {
        if unit == .line, let caret = info ?? (try? makeTextInfo(.caret)) {
            let line = caret.copy(); line.expand(.line)
            // Down onto the line just after a table: the caret went into the table (the page reports the offset
            // after the table's stand-in, 4 Oct 2026); its first cell's focus follows within 300 ms.
            let before = line.start > 0 ? line.textRange(max(0, line.start - 60), line.start) : ""
            let intoTable = gesture.keyName == "downArrow" && before.range(of: #"Table, \d+ Rows, \d+ Columns[, ]*$"#, options: .regularExpression) != nil
            if intoTable {
                super.caretMoved(speak: nil, gesture: gesture, info: caret)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self, API.focusObject?.isSameElement(as: self) == true else { return }
                    Speech.speakTextInfo(line, unit: .line, reason: .caret)
                }
                return
            }
            if WordTextInfo.isTableStandIn(line.text) {
                super.caretMoved(speak: nil, gesture: gesture, info: caret)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self, API.focusObject?.isSameElement(as: self) == true else { return }
                    Speech.speakMessage(String(localized: "table", comment: "Spoken message"))
                }
                return
            }
        }
        announcePageIfChanged(info)
        super.caretMoved(speak: unit, gesture: gesture, info: info)
    }

    /// The page, said as the caret arrives on a new one (NVDA and JAWS do; someone on AppleVis, 5 Oct 2026: there
    /// was no way to tell which page you were on). Each page is its own area in Word ("Page 3 content").
    private var lastPage: Int?
    private func announcePageIfChanged(_ info: TextInfo?) {
        guard let caret = info ?? (try? makeTextInfo(.caret)), let module else { return }
        guard let area = module.pageArea(containing: caret.start, near: element),
              let page = Int((area.string(kAXDescriptionAttribute) ?? "").filter(\.isNumber)) else { return }
        defer { lastPage = page }
        guard let last = lastPage, last != page else { return }
        Speech.speakMessage(Phrases.page(page))
    }

    /// Word's AXSelectedTextChanged arrives before AXSelectedTextRange is updated (measured 30 Sep 2026:
    /// a third of reads inside the callback were one move behind). The caret scripts poll and do not
    /// care; selection detection waits 25 ms, and once more if the selection still reads unchanged.
    private var pendingSelectionCheck: DispatchWorkItem?
    override func event_caret() {
        guard API.focusObject?.isSameElement(as: self) == true, !EventHandler.isPending(.gainFocus) else { return }
        pendingSelectionCheck?.cancel()
        let before = try? makeTextInfo(.selection)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let b = before, let now = try? makeTextInfo(.selection), now.isSame(b) {
                let again = DispatchWorkItem { [weak self] in self?.detectPossibleSelectionChange() }
                pendingSelectionCheck = again
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: again)
                return
            }
            detectPossibleSelectionChange()
        }
        pendingSelectionCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: work)
    }

    override func initOverlay() {
        super.initOverlay()
        let cat = "Microsoft Word"
        script("nextHeading", String(localized: "Moves to the next heading", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+h"], category: cat) { [weak self] _ in guard let self else { return }; goTo("goto a heading item", forward: true) }
        script("previousHeading", String(localized: "Moves to the previous heading", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+shift+h"], category: cat) { [weak self] _ in guard let self else { return }; goTo("goto a heading item", forward: false) }
        script("nextComment", String(localized: "Moves to the next comment (in the rotor and This app)", comment: "A command, as the key list and keyboard help say it"), gestures: [], category: cat) { [weak self] _ in guard let self else { return }; goToComment(forward: true) }
        script("previousComment", String(localized: "Moves to the previous comment", comment: "A command, as the key list and keyboard help say it"), gestures: [], category: cat) { [weak self] _ in guard let self else { return }; goToComment(forward: false) }
        script("nextRevision", String(localized: "Moves to the next tracked change", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+r"], category: cat) { [weak self] _ in guard let self else { return }; goToRevision(forward: true) }
        script("previousRevision", String(localized: "Moves to the previous tracked change", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+shift+r"], category: cat) { [weak self] _ in guard let self else { return }; goToRevision(forward: false) }
        script("nextSpellingError", String(localized: "Moves to the next spelling error", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+e"], category: cat) { [weak self] _ in guard let self else { return }; goToSpellingError(forward: true) }
        script("previousSpellingError", String(localized: "Moves to the previous spelling error", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+shift+e"], category: cat) { [weak self] _ in guard let self else { return }; goToSpellingError(forward: false) }
        // VO-Command-T: Word's own table search, the caret into the first cell (the VoiceOver cursor went to the
        // table, but the caret stayed, and the arrows read from where it was; a tester, 12 Oct 2026).
        script("nextTable", String(localized: "Moves to the next table, the caret in its first cell", comment: "A command, as the key list and keyboard help say it"), gestures: [], category: cat) { [weak self] _ in self?.goToTable(forward: true) }
        script("previousTable", String(localized: "Moves to the previous table, the caret in its first cell", comment: "A command, as the key list and keyboard help say it"), gestures: [], category: cat) { [weak self] _ in self?.goToTable(forward: false) }
        script("nextPage", String(localized: "Moves to the next page", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+pageDown"], category: cat) { [weak self] _ in guard let self else { return }; goToPage(forward: true) }
        script("previousPage", String(localized: "Moves to the previous page", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+pageUp"], category: cat) { [weak self] _ in guard let self else { return }; goToPage(forward: false) }
        // NVDA's Word scripts: the key goes to Word, then the result is reported.
        script("toggleBold", String(localized: "Toggles bold and reports it", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+b"], category: cat) { [weak self] g in self?.afterKey(g) { $0.fontState { Phrases.bold($0.bold) } } }
        script("toggleItalic", String(localized: "Toggles italic and reports it", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+i"], category: cat) { [weak self] g in self?.afterKey(g) { $0.fontState { Phrases.italic($0.italic) } } }
        script("toggleUnderline", String(localized: "Toggles underline and reports it", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+u"], category: cat) { [weak self] g in self?.afterKey(g) { $0.fontState { String(localized: "underline \(Phrases.onOff($0.underline))", comment: "Underline turned on or off in Word") } } }
        script("increaseFontSize", String(localized: "Makes the text bigger and reports the size", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+shift+."], category: cat) { [weak self] g in self?.afterKey(g) { $0.fontState { TextFormat.points($0.size) } } }
        script("decreaseFontSize", String(localized: "Makes the text smaller and reports the size", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+shift+,"], category: cat) { [weak self] g in self?.afterKey(g) { $0.fontState { TextFormat.points($0.size) } } }
        script("alignLeft", String(localized: "Aligns left and reports the alignment", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+l"], category: cat) { [weak self] g in self?.afterKey(g) { $0.alignment() } }
        script("alignCenter", String(localized: "Centres and reports the alignment", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+e"], category: cat) { [weak self] g in self?.afterKey(g) { $0.alignment() } }
        script("alignRight", String(localized: "Aligns right and reports the alignment", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+r"], category: cat) { [weak self] g in self?.afterKey(g) { $0.alignment() } }
        script("justify", String(localized: "Justifies and reports the alignment", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+j"], category: cat) { [weak self] g in self?.afterKey(g) { $0.alignment() } }
        script("lineSpacingSingle", String(localized: "Sets single spacing and reports it", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+1"], category: cat) { [weak self] g in self?.afterKey(g) { $0.lineSpacing() } }
        script("lineSpacingDouble", String(localized: "Sets double spacing and reports it", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+2"], category: cat) { [weak self] g in self?.afterKey(g) { $0.lineSpacing() } }
        script("lineSpacingOneAndHalf", String(localized: "Sets 1.5 spacing and reports it", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+5"], category: cat) { [weak self] g in self?.afterKey(g) { $0.lineSpacing() } }
        script("applyStyle", String(localized: "Apply a style; applies a heading or the Normal style and reports the style", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+option+1", "kb:command+option+2", "kb:command+option+3", "kb:command+shift+n"], category: cat) { [weak self] g in
            guard let self else { return }
            g.send()
            // Word marks the paragraph style in AXCustom ("Heading 1"); a paragraph with none of those is Normal.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, let info = try? self.makeTextInfo(.caret) as? AXTextInfo else { return }
                let at = info.start
                let el = info.textElement
                guard let a = el.param(kAXAttributedStringForRangeParameterizedAttribute, axRangeValue(at, 1)) as? NSAttributedString, a.length > 0 else { return }
                let custom = a.attributes(at: 0, effectiveRange: nil)[NSAttributedString.Key("AXCustom")] as? [String] ?? []
                Speech.speakMessage(custom.first(where: { $0.hasPrefix("Heading") || $0 == "Title" || $0.hasPrefix("List") }) ?? "Normal")
            }
        }
        script("toggleTrackChanges", String(localized: "Turns track changes on or off and reports it", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+shift+e"], category: cat) { [weak self] g in self?.afterKey(g) { $0.trackChanges() } }
        script("reportCurrentComment", String(localized: "Reports the comment at the caret (NVDA+Alt+C)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+option+c", "kb:turnover+command+c"], category: cat) { [weak self] _ in
            guard let self, let s = module?.script else { return }
            s.commentAtSelection { c in DispatchQueue.main.async { Speech.speakMessage(c ?? String(localized: "no comment at the caret", comment: "Spoken message")) } }
        }
        // NVDA in Word: Alt Up and Down Arrow, the previous and next sentence. Windows style only, where the PC's Alt is
        // the Mac's Command (Control Home and End still go to the top and bottom) (12 Oct 2026).
        for (name, forward) in [("windows_nextSentence", true), ("windows_previousSentence", false)] {
            script(name, forward ? String(localized: "Moves to the next sentence (Windows style: Alt Down Arrow)", comment: "A command, as the key list and keyboard help say it")
                               : String(localized: "Moves to the previous sentence (Windows style: Alt Up Arrow)", comment: "A command, as the key list and keyboard help say it"),
                   gestures: [forward ? "kb:command+downArrow" : "kb:command+upArrow"], category: cat) { _ in VoiceOverKeysPlugin.sentence(forward: forward) }
                .isAvailable = { config.general.windowsKeys }
        }
        script("elementsList", String(localized: "Elements list; opens the elements list: headings and comments", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+f7"], category: cat) { [weak self] _ in self?.elementsList() }
    }

    /// Send the key, then ask Word (off the main thread) and speak the answer.
    private func afterKey(_ g: KeyboardGesture, _ ask: @escaping (WordScript) -> Void) {
        guard let s = module?.script, !AXHandler.shared.isMenuOpen else { g.send(); return }
        g.send()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { ask(s) }
    }

    /// NVDA's elements list (NVDA+F7): the headings from Word's Document Map and the document's comments.
    private func elementsList() {
        guard let module else { return }
        let s = module.script
        // The document map is walked off the main thread (up to 2.5 s of questions to Word, with the sidebar
        // opening): "please wait" is said if it takes long, and speech carries on meanwhile (8 Oct 2026).
        Poll.background({ module.documentMapRows() }) { [weak self] rows, restore in
            self?.elementsList(rows: rows.map { ObjectFactory.make($0) }, restore: restore, s: s, module: module)
        }
    }
    private func elementsList(rows: [TurnOverObject], restore: @escaping @Sendable () -> Void, s: WordScript, module: WordAppModule) {
        var items: [MenuItem] = []
        for row in rows {
            let title = row.contentText(limit: 3)
            guard !title.isEmpty else { continue }
            let level = (row.element.int("AXDisclosureLevel") ?? 0) + 1
            let number = items.count + 1
            items.append(MenuItem(verbatim: "\(title), \(Phrases.headingLevel(level))", .action { [weak self] in
                // (The menu's onClose restores the sidebar; doing it here too opened it again, 8 Oct 2026.)
                guard let self else { return }
                self.scripted(String(localized: "no heading", comment: "Spoken message")) { done in
                    s.goToHeading(number: number) { landing in
                        DispatchQueue.main.async { module.adoptPage() }
                        done(Self.headingLanding(landing.level, landing.text))
                    }
                }
            }))
        }
        s.comments { comments in
            DispatchQueue.main.async {
                var commentItems: [MenuItem] = []
                for c in comments {
                    commentItems.append(MenuItem(verbatim: String(localized: "comment by \(c.author): \(String(c.text.prefix(80)))", comment: "A comment in the elements list: its author, then its words"), .action {
                        s.goToOffset(c.start) {
                            // Back to the page, as for a heading: the sidebar had the focus.
                            _ = module.caretArea.map { _ = $0.set(kAXFocusedAttribute, kCFBooleanTrue) }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                if let info = try? (API.focusObject as? WordDocument)?.makeTextInfo(.caret) { info.expand(.line); Speech.speakTextInfo(info, unit: .line, reason: .caret) }
                            }
                        }
                    }))
                }
                if items.isEmpty && commentItems.isEmpty { restore(); Speech.speakMessage(String(localized: "no headings or comments", comment: "Spoken message")); return }
                TurnOverMenu.shared.onClose = { restore() }
                // The rotor (VO-U): Left and Right between headings and comments.
                TurnOverMenu.shared.openRotor([(name: String(localized: "Headings", comment: "A rotor kind"), items: items), (name: String(localized: "Comments", comment: "A rotor kind"), items: commentItems)])
            }
        }
    }

    /// Run a scripted move off the main thread and speak what it landed on. The caret
    /// notification it causes carries a collapsed selection, so it says nothing itself.
    /// `nothing`: what is said when the move finds nothing ("no next heading").
    func scripted(_ nothing: String, _ body: @escaping (@escaping @MainActor (String?) -> Void) -> Void) {
        guard let module else { return }
        SayAll.stop()
        body { result in
            DispatchQueue.main.async {
                (API.focusObject as? EditableText)?.initAutoSelectDetection()
                Speech.speakMessage(result.map { $0.isEmpty ? nothing : $0 } ?? nothing)
            }
        }
        _ = module
    }

    /// "heading level 2, Results": where a move to a heading landed.
    static func headingLanding(_ level: Int?, _ text: String) -> String {
        (level.map(Phrases.headingLevel) ?? Role.heading.displayString) + ", " + (text.isEmpty ? Phrases.blank : Speech.processed(String(text.prefix(300))))
    }

    private func goTo(_ item: String, forward: Bool) {
        guard let s = module?.script else { return }
        scripted(Phrases.noNext(Role.heading.displayString, forward: forward)) { done in
            s.goTo(item: item, forward: forward) { landing in
                guard landing.moved else { done(nil); return }
                done(Self.headingLanding(landing.level, landing.text))
            }
        }
    }

    func goToTable(forward: Bool) {
        guard let module else { return }
        SayAll.stop()
        WordTableCell.last = nil   // another table: the cell spoken last belongs to the one being left
        if goToTableByAccessibility(forward: forward) { return }
        let s = module.script
        let pid = element.pid
        s.goTo(item: "goto a table item", forward: forward) { landing in
            guard landing.moved else { Tones.edge(); Speech.speakMessage(forward ? String(localized: "no next table", comment: "Spoken message") : String(localized: "no previous table", comment: "Spoken message")); return }
            // Word moves its focus to the cell's text area, and the cell says the table, row and column; if that
            // focus doesn't come, follow it here.
            // Word is slow to know its cell: a second look before the fallback ("edit, ITEM" then "table, ITEM" were
            // both heard, 17 Oct 2026).
            let text = landing.text
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { Self.settleTableLanding(pid: pid, text: text, look: 1) }
        }
    }

    /// The next or previous table from what Word gives accessibility: each table has its stand-in in the page's text
    /// ("Table, 5 Rows, 3 Columns"), and its AXTable in the window, in the same order. The caret goes into the first
    /// cell, as a cell move does (WordTableCell.move), which Word follows. Word's AppleScript "go to next … table"
    /// found nothing in a document with a table (the test run, 12 Oct 2026). False when the two don't line up (pages
    /// Word hasn't laid out), and the AppleScript is tried.
    private func goToTableByAccessibility(forward: Bool) -> Bool {
        guard let info = try? makeTextInfo(.caret) as? AXTextInfo, let win = AXUIElementCreateApplication(element.pid).element(kAXFocusedWindowAttribute) else { return false }
        let text = info.textRange(0, min(info.storyLength(), 100_000)) as NSString   // beyond that, Word is asked
        guard let re = try? NSRegularExpression(pattern: #"Table, \d+ Rows, \d+ Columns"#) else { return false }
        let standIns = re.matches(in: text as String, range: NSRange(location: 0, length: text.length)).map(\.range)
        var tables: [AXUIElement] = []
        var stack: [AXUIElement] = [win], visited = 0
        while let e = stack.popLast(), visited < 3000 {
            visited += 1
            if e.role == "AXTable" { tables.append(e); continue }
            stack.append(contentsOf: e.elements(kAXChildrenAttribute).reversed())   // depth first, in document order
        }
        guard !standIns.isEmpty, standIns.count == tables.count else {
            Log.io("Word tables: \(standIns.count) in the text, \(tables.count) in the window; asking Word instead")
            return standIns.isEmpty && tables.isEmpty ? { Tones.edge(); Speech.speakMessage(forward ? String(localized: "no next table", comment: "Spoken message") : String(localized: "no previous table", comment: "Spoken message")); return true }() : false
        }
        let caret = info.start
        // Inside a table the page reports the offset just after its stand-in: that table is "here", not next.
        let here = standIns.lastIndex { $0.location <= caret && caret <= NSMaxRange($0) + 2 }
        let pick = forward ? standIns.indices.first { $0 != here && standIns[$0].location > caret }
                           : standIns.indices.last { $0 != here && NSMaxRange(standIns[$0]) < caret }
        guard let k = pick, let cell = WordTableCell.textArea(tables[k], row: 0, column: 0) else {
            Tones.edge(); Speech.speakMessage(forward ? String(localized: "no next table", comment: "Spoken message") : String(localized: "no previous table", comment: "Spoken message")); return true
        }
        _ = cell.set(kAXSelectedTextRangeAttribute, axRangeValue(0, 0))
        WordTableCell.last = nil
        AXHandler.shared.focusChanged(cell, pid: element.pid)
        return true
    }

    private func goToComment(forward: Bool) {
        guard let s = module?.script else { return }
        scripted(Phrases.noNext(String(localized: "comment", comment: "A Word comment, as a kind of thing to find"), forward: forward)) { done in
            s.goTo(item: "goto a comment item", forward: forward) { landing in
                guard landing.moved else { done(nil); return }
                s.commentAtSelection { done($0 ?? String(localized: "comment", comment: "A Word comment, as a kind of thing to find")) }
            }
        }
    }

    private func goToRevision(forward: Bool) {
        if goToMarkedChange(forward: forward) { return }
        guard let s = module?.script else { return }
        scripted(Phrases.noNext(String(localized: "change", comment: "A tracked change in Word, as a kind of thing to find"), forward: forward)) { done in s.nextRevision(forward: forward, completion: done) }
    }

    var misspellingSearchFrom: Int?

    /// Word marks tracked changes in the text it gives accessibility ("Insertion change", "Deletion change",
    /// "Formatting change" annotations): find the next or previous one on this page and select it. Word's
    /// AppleScript "next revision" answered nothing (2 Oct 2026); the marks are what VoiceOver reads too.
    private func goToMarkedChange(forward: Bool) -> Bool {
        guard let info = try? makeTextInfo(.caret) as? AXTextInfo else { return false }
        let el = info.textElement
        let n = info.storyLength()
        if n == 0 { Tones.edge(); Speech.speakMessage(forward ? String(localized: "no next spelling error", comment: "Spoken message") : String(localized: "no previous spelling error", comment: "Spoken message")); return true }   // nothing to search: answered without Word's script (it errored -1728 each press)
        guard n > 0, let a = el.param(kAXAttributedStringForRangeParameterizedAttribute, axRangeValue(0, min(n, 50_000))) as? NSAttributedString else { return false }
        var changes: [(NSRange, String)] = []
        a.enumerateAttribute(NSAttributedString.Key("AXAnnotation"), in: NSRange(location: 0, length: a.length)) { val, range, _ in
            for d in (val as? [[String: Any]]) ?? [] {
                if let label = d["AXAnnotationLabel"] as? String, label.lowercased().hasSuffix("change") {
                    if let last = changes.last, last.1 == label, NSMaxRange(last.0) == range.location { changes[changes.count - 1].0.length += range.length }
                    else { changes.append((range, label)) }
                }
            }
        }
        let caret = info.start
        let target = forward ? changes.first { $0.0.location > caret } : changes.last { $0.0.location < caret }
        guard let (range, label) = target else {
            return false   // none beyond the caret on the laid-out pages: Word's own search covers the whole document
        }
        info.setSelectionOffsets(range.location, range.location + range.length)
        let text = (a.string as NSString).substring(with: range)
        initAutoSelectDetection()
        Speech.speakMessage("\(label.replacingOccurrences(of: " change", with: "")): \(text)")
        return true
    }

    static func settleTableLanding(pid: pid_t, text: String, look: Int) {
        if API.focusObject is WordTableCell { return }
        if let f = AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute), f.role == "AXTextArea", WordTableCell.cell(of: f) != nil {
            // Known as a cell now: read as one ("table with r rows and c columns, row 1, column 1, …"), replacing
            // the plain "edit" the focus event gave before Word knew (17 Oct 2026).
            Speech.cancel()
            AXHandler.shared.focusChanged(f, pid: pid)
        } else if look < 3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settleTableLanding(pid: pid, text: text, look: look + 1) }
        } else if Speech.sinceFocusSpoken > 1.5 {
            // Nothing was said for the landing at all: the table's first cell, at least.
            Speech.speakMessage(Role.table.displayString + ", " + (text.isEmpty ? Phrases.blank : Speech.processed(String(text.prefix(200)))))
        }
    }

    private func goToPage(forward: Bool) {
        guard let s = module?.script else { return }
        scripted(Phrases.noNext(Role.page.displayString, forward: forward)) { done in
            s.goTo(item: "goto a page item", forward: forward) { landing in
                guard landing.moved else { done(nil); return }
                s.selectionInformation { page, _ in done((page.map { Phrases.page($0) + ", " } ?? "") + Speech.processed(String(landing.text.prefix(200)))) }
            }
        }
    }
}
