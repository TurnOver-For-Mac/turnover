// SPDX-License-Identifier: GPL-3.0-or-later
// Microsoft Word (NVDA: appModules/winword.py and NVDAObjects/window/winword.py).
//
// Facts this is built on, all measured on a long document (about 350,000 characters), 30 Sep 2026:
// - Word exposes each page as an AXTextArea; every one shares a single
//   document-global character index, so a range read on any page area works.
// - AXSelectedTextChanged fires on every caret move naming the element that
//   holds the caret — before the element's AXSelectedTextRange has been
//   updated. The core's caret scripts poll the caret after sending the key
//   (NVDA's _hasCaretMoved), so the late value is simply read when it lands.
//   AXFocusedUIElementChanged names the page area when the caret crosses a page.
// - The app's AXFocusedUIElement misreports the document as a split group;
//   the focus is redirected to the page area that holds the caret.
// - Bounded reads (AXLineForIndex, AXRangeForLine, AXStringForRange) cost
//   0.1 ms. AXValue is never read.
// - Word's `browser` object is not scriptable; `go to next … what goto a X item`
//   is, and it returns the range it landed on.
import Foundation
import ApplicationServices
import AppKit
import CoreServices

final class WordAppModule: AppModule {
    static let bundleID = "com.microsoft.Word"
    let script = WordScript()

    // Word's own dictionary is the one that counts when it supplies spelling marks, including in dialog fields.
    override var supplementsSpellingMarks: Bool { false }

    // Word/macOS already sounds at a rejected native caret key (reported 29 Oct 2026, #190), including when
    // TurnOver leads without coexist. Keep the native sound alone; review/table commands remain TurnOver's.
    override var playsNativeCaretBoundarySound: Bool { false }

    required init(pid: pid_t, bundleIdentifier: String, appName: String) {
        super.init(pid: pid, bundleIdentifier: bundleIdentifier, appName: appName)
        declareTableScripts()
        // Windows' Escape from the ribbon: back to the document. Word on the Mac leaves the focus where it is.
        script("word_leaveBars", String(localized: "In the ribbon, sidebar, status bar or toolbar: back to the document", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:escape"], category: "Microsoft Word") { [weak self] g in
            g.send()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.backToPage() }
        }.isAvailable = { [weak self] in
            guard let self, API.focusPid == self.pid, !AXHandler.shared.isMenuOpen, let f = API.focusObject?.element else { return false }
            return Self.inBars(f) && f.attr("AXExpanded") as? Bool != true
        }
        // Word's sheets (Save changes on Command Q, Save As) keep Tab among their text fields, passing through the page:
        // Don't Save, Cancel and Save were never reached (21 Oct 2026; VoiceOver gets them with its own cursor).
        // In a sheet, Tab and Shift+Tab are TurnOver's: every control in the sheet, in order, round.
        for forward in [true, false] {
            script(forward ? "word_sheetNext" : "word_sheetPrevious",
                   forward ? "In a sheet: the next control, its buttons included" : "In a sheet: the previous control, its buttons included",
                   gestures: [forward ? "kb:tab" : "kb:shift+tab"], category: "Microsoft Word") { [weak self] g in
                self?.sheetMove(g, forward: forward)
            }.isAvailable = { [weak self] in
                guard let self, API.focusPid == self.pid, !AXHandler.shared.isMenuOpen, let f = API.focusObject?.element else { return false }
                return Self.sheet(of: f) != nil
            }
        }
    }

    /// The sheet a control is in, if any. Word can report the sheet as its focused window with subrole AXDialog
    /// instead of role AXSheet (review, 21 Oct 2026); either is taken.
    static func sheet(of e: AXUIElement) -> AXUIElement? {
        var p: AXUIElement? = e; var hops = 0
        while let x = p, hops < 15 {
            let r = x.role
            if r == "AXSheet" { return x }
            if r == "AXWindow" { return x.string(kAXSubroleAttribute) == "AXDialog" ? x : nil }
            p = x.element(kAXParentAttribute); hops += 1
        }
        return nil
    }

    private func sheetMove(_ g: KeyboardGesture, forward: Bool) {
        guard let f = API.focusObject?.element, let sheet = Self.sheet(of: f) else { g.send(); return }
        // Enabled and on screen: the collapsed Save As sheet keeps its file browser at zero size (review, 21 Oct 2026).
        let all = SettingsPanePlugin.controlsInOrder(in: sheet).filter {
            ($0.attr(kAXEnabledAttribute) as? Bool) != false && (TurnOverObject.frame($0).map { $0.width > 0 && $0.height > 0 } ?? false)
        }
        // Where the focus is: the control itself, or the control it is inside (a field's completion list).
        var here: Int?
        var p: AXUIElement? = f; var hops = 0
        while let x = p, hops < 5, here == nil { here = all.firstIndex { $0.isSame(x) }; p = x.element(kAXParentAttribute); hops += 1 }
        guard !all.isEmpty else { g.send(); return }
        let n = here.map { (($0 + (forward ? 1 : -1)) + all.count) % all.count } ?? (forward ? 0 : all.count - 1)
        Log.io("Word sheet: \(forward ? "Tab" : "Shift+Tab") to \(all[n].role) \(n + 1) of \(all.count)")
        SettingsPanePlugin.focus(all[n])
    }

    /// In the ribbon, sidebar, status bar or the window's toolbar.
    static func inBars(_ e: AXUIElement) -> Bool {
        var p: AXUIElement? = e; var hops = 0
        while let x = p, hops < 12 {
            let r = x.role, d = x.string(kAXDescriptionAttribute) ?? ""
            if r == "AXTabGroup", d == "Sidebar" || d == "ribbon" { return true }
            if r == "AXToolbar" || (r == "AXGroup" && d == "Status Bar") { return true }
            if r == "AXWindow" { return false }
            p = x.element(kAXParentAttribute); hops += 1
        }
        return false
    }

    /// Put the focus on the page where the caret is, and say it.
    private func backToPage() {
        let app = AXUIElementCreateApplication(pid)
        if let f = app.element(kAXFocusedUIElementAttribute), !Self.inBars(f), !(f.role == "AXTabGroup") { return }   // Escape did it
        if let area = locateCaret() {
            _ = area.set(kAXFocusedAttribute, kCFBooleanTrue)
            caretArea = area
            lastLostWasPage = false
            AXHandler.shared.focusChanged(area, pid: pid)
        } else if let w = app.element(kAXFocusedWindowAttribute), let layout = Self.documentLayout(in: w) {
            _ = layout.set(kAXFocusedAttribute, kCFBooleanTrue)
            announcePage = true
            sidebarToPage(since: InputManager.lastKeyDownAt, delays: [0.1, 0.3, 0.7])
        }
    }
    /// The page area that holds the caret, from the last caret or focus notification.
    private(set) var caretArea: AXUIElement?

    static func isPageArea(_ element: AXUIElement) -> Bool {
        element.role == "AXTextArea" && (element.string(kAXDescriptionAttribute) ?? "").hasPrefix("Page")
    }

    /// The cell the caret is in now. Word's focus stays on the page (or its scroll area) while the caret is in a
    /// table, so: the focused element when it is a cell's text area; else the cell TurnOver last spoke (a move by
    /// row or column starts from it); else, in a small table, the cell marked focused.
    func liveCell() -> WordTableCell? {
        let app = AXUIElementCreateApplication(pid)
        if let f = app.element(kAXFocusedUIElementAttribute), f.role == "AXTextArea", WordTableCell.cell(of: f) != nil { return WordTableCell(element: f) }
        if let last = WordTableCell.last, let area = WordTableCell.textArea(last.table, row: last.row, column: last.column) { return WordTableCell(element: area) }
        // The focused cell in any table of the window, not only the first: the first table's cell was found in
        // every later table, and its moves said "top" and "bottom" (19 Oct 2026). Small tables only (each cell is asked).
        guard let win = app.element(kAXFocusedWindowAttribute) else { return nil }
        var stack = [win], seen = 0
        while let e = stack.popLast(), seen < 1500 {
            seen += 1
            if e.role == "AXTable" {
                guard let rows = e.attr("AXRowCount") as? Int, rows <= 60 else { continue }
                for row in e.elements(kAXRowsAttribute) {
                    for cell in row.elements(kAXChildrenAttribute) where cell.role == "AXCell" && (cell.attr(kAXFocusedAttribute) as? Bool) == true {
                        if let area = cell.firstDescendant(role: "AXTextArea", maxVisited: 6) { return WordTableCell(element: area) }
                    }
                }
                continue
            }
            stack.append(contentsOf: e.elements(kAXChildrenAttribute).reversed())
        }
        return nil
    }
    /// Table moves by the live caret (TurnOver plus the arrows in the Windows style; the VO keys ask by name).
    private var inTableCheckedAt = Date.distantPast
    private var inTableLastAnswer = false
    func declareTableScripts() {
        // VO-Command-T and Shift from inside a table: the focus is the cell, so the page's own nextTable wasn't found
        // by name and VoiceOver's window walk ran instead, "no next table" with tables below (a tester, 
        // 16 Oct 2026). The module answers by name and hands the page's script the move.
        for (name, forward) in [("nextTable", true), ("previousTable", false)] {
            script(name, "Moves to the \(forward ? "next" : "previous") table, the caret in its first cell", gestures: [], category: "Microsoft Word") { [weak self] _ in
                guard let self else { return }
                if let d = API.focusObject as? WordDocument { d.goToTable(forward: forward); return }
                // (lastDocument is cleared by the loseFocus the first move queued, so the second press from the cell
                // needs the caret's area: code review, 16 Oct 2026.)
                guard let page = lastDocument?.element ?? caretArea else { Tones.edge(); Speech.speakMessage(String(localized: "not in a document", comment: "Spoken message")); return }
                Log.io("Word: \(name) from a table cell, through the page")
                WordDocument(element: page).goToTable(forward: forward)
            }
        }
        // The page's other moves likewise answered by name from a cell (the rotor: headings, comments, tracked
        // changes, misspelled words, pages; a code review on 17 Oct 2026).
        for name in ["nextHeading", "previousHeading", "nextComment", "previousComment", "nextRevision", "previousRevision", "nextSpellingError", "previousSpellingError", "nextPage", "previousPage"] {
            script(name, "Moves to the \(name.hasPrefix("next") ? "next" : "previous") \(name.replacingOccurrences(of: "next", with: "").replacingOccurrences(of: "previous", with: "").lowercased())", gestures: [], category: "Microsoft Word") { [weak self] g in
                guard let self else { return }
                if let d = API.focusObject as? WordDocument, let s = d.script(named: name) { s.handler(g); return }
                guard let page = lastDocument?.element ?? caretArea else { Tones.edge(); Speech.speakMessage(String(localized: "not in a document", comment: "Spoken message")); return }
                let doc = WordDocument(element: page)
                guard let s = doc.script(named: name) else { Tones.edge(); Speech.speakMessage(String(localized: "not in a document", comment: "Spoken message")); return }
                Log.io("Word: \(name) from a table cell, through the page")
                s.handler(g)
            }
        }
        for (name, dr, dc, keys) in [("table_nextColumn", 0, 1, ["kb:turnover+rightArrow"]), ("table_previousColumn", 0, -1, ["kb:turnover+leftArrow"]),
                                     ("table_nextRow", 1, 0, ["kb:turnover+downArrow"]), ("table_previousRow", -1, 0, ["kb:turnover+upArrow"])] {
            let description = dr == 0 ? (dc > 0 ? String(localized: "In a table: the next cell in the row, the caret at its start (NVDA's table keys; TurnOver plus the arrows)", comment: "A command, as the key list and keyboard help say it")
                                                : String(localized: "In a table: the previous cell in the row, the caret at its start (NVDA's table keys; TurnOver plus the arrows)", comment: "A command, as the key list and keyboard help say it"))
                : (dr > 0 ? String(localized: "In a table: the cell below, the caret at its start (NVDA's table keys; TurnOver plus the arrows)", comment: "A command, as the key list and keyboard help say it")
                          : String(localized: "In a table: the cell above, the caret at its start (NVDA's table keys; TurnOver plus the arrows)", comment: "A command, as the key list and keyboard help say it"))
            script(name, description, gestures: keys, category: "Microsoft Word") { [weak self] _ in
                self?.liveCell()?.move(dr, dc)
            }.isAvailable = { [weak self] in
                guard let self, API.focusPid == pid else { return false }
                // Once a second: liveCell searches the window (up to 1,500 elements) when no cell is known, and this
                // ran before every arrow key outside a table, with the keyboard waiting (a code review, 14 Oct 2026).
                if Date().timeIntervalSince(inTableCheckedAt) < 1 { return inTableLastAnswer }
                inTableLastAnswer = liveCell() != nil; inTableCheckedAt = Date()
                return inTableLastAnswer
            }
        }
    }

    override func objectClass(for element: AXUIElement, role: Role, subrole: String?) -> TurnOverObject.Type? {
        guard element.role == "AXTextArea" else { return nil }
        let desc = element.string(kAXDescriptionAttribute) ?? ""
        if desc.hasPrefix("Page") { return WordDocument.self }
        if desc.hasPrefix("Header") || desc.hasPrefix("Footer") { return WordHeaderFooter.self }
        if WordTableCell.cell(of: element) != nil { return WordTableCell.self }
        return WordTextArea.self
    }

    /// The split group or layout area Word reports as focused is the document: hand back the caret's page area.
    override func redirectFocus(_ element: AXUIElement) -> AXUIElement? {
        let role = element.role
        guard ["AXSplitGroup", "AXLayoutArea", "AXScrollArea", "AXGroup", "AXWindow"].contains(role) else {
            if Self.isPageArea(element) { caretArea = element }
            return nil
        }
        if let a = caretArea, let r = cfRange(a.attr(kAXSelectedTextRangeAttribute)), r.location != Int.max { return a }
        if let found = locateCaret() { caretArea = found; return found }
        scheduleCaretSearch()
        return nil
    }

    /// Word, just opened, has no page yet when it first takes focus, and says nothing when the page appears: TurnOver
    /// was left on a split group, typing unechoed and the arrows silent (2 Oct 2026). Look again over a few seconds,
    /// and on the next key, while the focus is still a container.
    private var caretSearchPending = false
    private func scheduleCaretSearch(delays: [Double] = [0.7, 1.5, 3, 6]) {
        guard !caretSearchPending, let delay = delays.first else { return }
        caretSearchPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.caretSearchPending = false
            self.retryCaretSearch(rest: Array(delays.dropFirst()))
        }
    }
    private func retryCaretSearch(rest: [Double]) {
        guard API.focusPid == pid, let f = API.focusObject, !(f is WordDocument),
              ["AXSplitGroup", "AXLayoutArea", "AXScrollArea", "AXGroup", "AXWindow"].contains(f.axRole) else { return }
        // Word builds its page for accessibility when asked: what has focus now, and what is inside it.
        let app = AXUIElementCreateApplication(pid)
        var direct = app.element(kAXFocusedUIElementAttribute)
        if let d = direct, !Self.isPageArea(d) {
            direct = d.elements(kAXChildrenAttribute).first(where: Self.isPageArea) ?? d.firstDescendant(role: "AXTextArea", maxVisited: 40).flatMap { Self.isPageArea($0) ? $0 : nil }
        }
        if let found = direct ?? locateCaret() {
            caretArea = found
            Log.io("Word: the page appeared; focus to it")
            AXHandler.shared.focusChanged(found, pid: pid)
        } else if !rest.isEmpty {
            AppWake.nudge(pid: pid, reason: "no page in the document")   // a tester's report: a cold start builds no page until activated
            // No page yet: read through the window (the status bar's page count makes Word build it), then look again.
            if let w = app.element(kAXFocusedWindowAttribute) {
                DispatchQueue.global(qos: .userInitiated).async { Self.readThrough(w) }
            }
            scheduleCaretSearch(delays: rest)
        }
    }

    private var sidebarToPagePending = false
    /// When a page last gained the focus (to avoid reading it twice as TurnOver also moves there).
    private var lastPageFocusAt = Date.distantPast
    /// A window opening left the focus in the sidebar: say the page once TurnOver has put the focus on it.
    private var announcePage = false
    private func sidebarToPage(since key: Date, delays: [Double]) {
        guard !sidebarToPagePending, let delay = delays.first else { return }
        sidebarToPagePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.sidebarToPagePending = false
            guard API.focusPid == self.pid, InputManager.lastKeyDownAt == key else { return }
            let focused = AXUIElementCreateApplication(self.pid).element(kAXFocusedUIElementAttribute)
            if let area = self.locateCaret() {
                _ = area.set(kAXFocusedAttribute, kCFBooleanTrue)
                self.caretArea = area
                Log.io("Word: to the page")
                // Word's own focus news for the page may have just been read (after a wake-up): not twice.
                if let f = API.focusObject, f.isSameElement(as: area), Date().timeIntervalSince(self.lastPageFocusAt) < 1.5 {
                    self.announcePage = false
                    return
                }
                if self.announcePage, let f = API.focusObject, f.isSameElement(as: area) {
                    self.announcePage = false
                    API.setFocusObject(f, ancestors: API.focusAncestors)
                    f.reportFocus()
                } else {
                    self.announcePage = false
                    AXHandler.shared.focusChanged(area, pid: self.pid)
                }
                return
            }
            // Word started cold builds no page until it is activated again (): when a look finds none, give it
            // that activation (AppWake: a moment in TurnOver's own process and back), then look again.
            if let w = focused.flatMap({ SettingsPanePlugin.windowOf($0) }) ?? AXUIElementCreateApplication(self.pid).element(kAXFocusedWindowAttribute),
               delays.count <= 5, let layout = Self.documentLayout(in: w), layout.elements(kAXChildrenAttribute).isEmpty {   // from about 1 s on
                AppWake.nudge(pid: self.pid, reason: "no page in the document") { [weak self] in
                    self?.sidebarToPage(since: key, delays: [0.05, 0.4, 1])   // look at once, not at the next scheduled look
                }
            }
            guard let f = focused, Self.inSidebarOrRibbon(f), let window = SettingsPanePlugin.windowOf(f) else {
                self.sidebarToPage(since: key, delays: Array(delays.dropFirst()))
                return
            }
            // Word builds no page while the focus is in the sidebar, until something reads through the window (as
            // VoiceOver does): read it off the main thread, then focus the document, and the page appears.
            DispatchQueue.global(qos: .userInitiated).async {
                Self.readThrough(window)
                DispatchQueue.main.async {
                    if let layout = Self.documentLayout(in: window) {
                        _ = layout.set(kAXFocusedAttribute, kCFBooleanTrue)
                        Log.io("Word: focus to the document area, \(layout.elements(kAXChildrenAttribute).count) pages")
                    }
                    self.sidebarToPage(since: key, delays: Array(delays.dropFirst()))
                }
            }
        }
    }

    /// One bounded scan when nothing else has told us where the caret is.
    private func locateCaret() -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        guard let win = app.element(kAXFocusedWindowAttribute) else { return nil }
        var queue = [win]; var visited = 0
        let t0 = Date()
        while !queue.isEmpty && visited < 6000 {
            let e = queue.removeFirst(); visited += 1
            if Self.isPageArea(e), let sel = cfRange(e.attr(kAXSelectedTextRangeAttribute)), sel.location != Int.max {
                Log.info("Word: caret located at \(sel.location) after \(visited) elements, \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
                return e
            }
            queue.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
        Log.info("Word: caret not in a page area")
        return nil
    }

    /// A sidebar page thumbnail ("Page 3", a button inside the Sidebar tab group): its page number.
    static func thumbnailPage(_ e: AXUIElement) -> Int? {
        guard e.role == "AXButton", let t = e.string(kAXTitleAttribute) ?? e.string(kAXDescriptionAttribute), t.hasPrefix("Page "),
              let n = Int(t.dropFirst(5)) else { return nil }
        var p = e.element(kAXParentAttribute); var hops = 0
        while let x = p, hops < 8 { if x.role == "AXTabGroup", x.string(kAXDescriptionAttribute) == "Sidebar" { return n }; p = x.element(kAXParentAttribute); hops += 1 }
        return nil
    }

    /// `e` is `group` or inside it.
    static func inside(_ group: AXUIElement, _ e: AXUIElement) -> Bool {
        var p: AXUIElement? = e; var hops = 0
        while let x = p, hops < 12 { if x.isSame(group) { return true }; if x.role == "AXWindow" { return false }; p = x.element(kAXParentAttribute); hops += 1 }
        return false
    }
    /// In the sidebar or the ribbon (the "Sidebar" or "ribbon" tab group, or anything inside it).
    static func inSidebarOrRibbon(_ e: AXUIElement) -> Bool {
        var p: AXUIElement? = e; var hops = 0
        while let x = p, hops < 10 {
            if x.role == "AXTabGroup", ["Sidebar", "ribbon"].contains(x.string(kAXDescriptionAttribute) ?? "") { return true }
            if x.role == "AXWindow" { return false }
            p = x.element(kAXParentAttribute); hops += 1
        }
        return false
    }
    /// Every element's name and children, as a screen reader's first look reads them (Word builds its page then).
    /// What builds it is reading the status bar's "Page 1 of 18": Word lays out its pages to answer, and makes the
    /// page's text area then. A document opened with Word starting cold had no page at all until something did
    /// (5 Oct 2026); its own AppleScript even said 0 pages. Values are read too, for that.
    nonisolated static func readThrough(_ window: AXUIElement) {
        var queue = [window]; var visited = 0
        while !queue.isEmpty, visited < 1500 {
            let e = queue.removeFirst(); visited += 1
            _ = e.string(kAXDescriptionAttribute)
            if e.role == "AXButton" || e.role == "AXStaticText" { _ = e.attr(kAXValueAttribute); _ = e.string(kAXTitleAttribute) }
            queue.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
    }

    /// The document's layout area (the pages' container), not the sidebar's thumbnails.
    static func documentLayout(in window: AXUIElement) -> AXUIElement? {
        var queue = [window]; var visited = 0
        while !queue.isEmpty, visited < 200 {
            let e = queue.removeFirst(); visited += 1
            if e.role == "AXLayoutArea" { return e }
            if e.role == "AXTabGroup" || e.role == "AXToolbar" { continue }   // not the sidebar or ribbon
            queue.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
        return nil
    }
    /// The user moved there: a key that moves the focus around the sidebar or ribbon, pressed within the last second.
    static func keyMovedFocus() -> Bool {
        guard Date().timeIntervalSince(InputManager.lastKeyDownAt) < 1 else { return false }
        let k = InputManager.lastKeyIdentifier
        return ["f6", "tab", "Arrow", "space", "enter", "escape", "home", "end"].contains(where: { k.hasSuffix($0) || k.contains($0) })
    }

    /// The text area of page `n` ("Page 3 content") in a document window.
    static func pageArea(number n: Int, in window: AXUIElement) -> AXUIElement? {
        var queue = [window]; var visited = 0
        while !queue.isEmpty, visited < 600 {
            let e = queue.removeFirst(); visited += 1
            if e.role == "AXTextArea", e.string(kAXDescriptionAttribute) == "Page \(n) content" { return e }
            if e.role == "AXTabGroup" { continue }   // not into the sidebar
            queue.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
        return nil
    }

    /// Asked before the event is acted on (Events.swift), so the dialog field's speech isn't dropped for the blip.
    private var lastIgnoreAsk: (element: AXUIElement, at: Date, answer: Bool)?
    override func ignoresFocus(_ event: Event) -> Bool {
        guard event.kind == .gainFocus, event.obj is WordDocument else { return false }
        // Asked twice per event (Events.swift and handleEvent), each a walk of the window's children: one answer.
        if let l = lastIgnoreAsk, l.element.isSame(event.obj.element), Date().timeIntervalSince(l.at) < 0.1 { return l.answer }
        let answer = AXHandler.modalInFront(pid: event.obj.pid)
        lastIgnoreAsk = (event.obj.element, Date(), answer)
        return answer
    }

    override func handleEvent(_ event: Event, next: () -> Void) {
        // The page's focus is adopted silently only straight after another page had it (crossing a page). Through
        // the ribbon or sidebar and back by Tab, the page was not news and the user heard nothing (5 Oct 2026).
        if event.kind == .gainFocus, !(event.obj is WordDocument) { lastLostWasPage = false }
        // Tab onto the ribbon's Font or Font Size box: Word reports the page focused 40 ms later (as its
        // suggestion list is made), while the keys still go to the box. Followed, the user heard "document" and
        // the arrows and Return went unspoken (5 Oct 2026). A page focus with no key since a ribbon control took
        // the focus, within half a second, is that echo.
        // Tab in a dialog (Insert Table) passes the focus through the page for a moment: "document, blank" was heard
        // between the dialog's fields (7 Oct 2026). While a dialog is in front, the page isn't news.
        // (A Save sheet too: the page blipped on every Tab in it.)
        if ignoresFocus(event) {
            Log.io("Word: the page took the focus while a dialog or sheet is in front; ignored")
            return
        }
        if event.kind == .gainFocus {
            if Self.inBars(event.obj.element) {
                barFocus = (Date(), InputManager.lastKeyDownAt)
            } else if event.obj is WordDocument, let b = barFocus, Date().timeIntervalSince(b.at) < 0.5, InputManager.lastKeyDownAt == b.key {
                Log.io("Word: the page claimed the focus just after a ribbon control did; ignored")
                return
            }
        }
        if event.kind == .gainFocus, WordTableCell.last != nil, !(event.obj is WordTableCell) {
            // Word hands the focus back to the page a moment after a cell (a tester's log, 8 Oct 2026): after a
            // TurnOver key, the caret is still in the table, so the cell is kept and nothing is said.
            if event.obj is WordDocument, InputManager.lastKeyIdentifier.hasPrefix("kb:turnover+"), Date().timeIntervalSince(InputManager.lastKeyDownAt) < 1.5 {
                Log.io("Word: the page took the focus after a table move; still in the table")
                return
            }
            WordTableCell.last = nil
            if let d = event.obj as? WordDocument {
                // NVDA's words, then the line the caret came out on. The page's own focus news stays quiet: Word
                // hands the focus back to the page it took it from.
                Speech.speakOnly(String(localized: "out of table", comment: "The caret left a table"))   // the display shows the line itself
                if let c = try? d.makeTextInfo(.caret) { c.expand(.line); Speech.speakTextInfo(c, unit: .line, reason: .caret) }
                lastLostWasPage = true
            }
        }
        switch event.kind {
        case .gainFocus where event.obj is WordDocument:
            caretArea = event.obj.element
            lastPageFocusAt = Date()
            // Crossing a page is not a focus change to the user: adopt the new page area silently.
            // Only from one page to the next: coming back from a comment (also a Word text area) is news.
            if lastLostWasPage, let previous = lastDocument, previous.windowElement.map({ event.obj.element.element(kAXWindowAttribute)?.isSame($0) ?? false }) ?? false {
                (event.obj as? EditableText)?.initAutoSelectDetection()
                lastDocument = (event.obj.element, event.obj.element.element(kAXWindowAttribute))
                return
            }
            lastDocument = (event.obj.element, event.obj.element.element(kAXWindowAttribute))
            next()
        case .gainFocus where lastDocument != nil && Self.thumbnailPage(event.obj.element) != nil
                              && !["f6", "tab"].contains(where: { InputManager.lastKeyIdentifier.hasSuffix($0) }):
            // With the sidebar's thumbnails open, Word moves the focus to "Page 3" as the caret crosses into page 3;
            // followed, the user was thrown out of the document mid-table (4 Oct 2026). Put it back on that page.
            guard let n = Self.thumbnailPage(event.obj.element) else { next(); return }   // (the sidebar can change between the two reads)
            if let window = event.obj.element.element(kAXWindowAttribute) ?? SettingsPanePlugin.windowOf(event.obj.element),
               let area = Self.pageArea(number: n, in: window) {
                _ = area.set(kAXFocusedAttribute, kCFBooleanTrue)
                caretArea = area
                Log.io("Word: the sidebar took the focus at page \(n); back to the page")
                if announcePage {
                    // The end of a window opening: say the page, as the user has heard nothing since the window.
                    announcePage = false
                    AXHandler.shared.focusChanged(area, pid: pid)
                } else {
                    API.setFocusObject(ObjectFactory.make(area), ancestors: API.focusAncestors)
                }
                return
            }
            next()
        case .focusEntered where ["AXTable", "AXRow", "AXCell"].contains(event.obj.element.role):
            return   // the cell says the table, row and column itself (WordTableCell)
        case .focusEntered where event.obj.element.role == "AXTabGroup" && API.focusObject.map({ Self.inside(event.obj.element, $0.element) }) == true:
            return   // "ribbon, tab control" again on each Tab between its commands: already inside it
        case .focusEntered where Self.inSidebarOrRibbon(event.obj.element) && !Self.keyMovedFocus():
            return   // "ribbon, tab control" as a window opens: Word passing the focus through; not news
        case .gainFocus where Self.inSidebarOrRibbon(event.obj.element) && !Self.keyMovedFocus():
            // A document opening puts the focus on the sidebar's tabs, then the ribbon, then the sidebar again, not
            // the page: the user heard "Sidebar, tab control" with the arrows and Tab doing nothing useful (4 Oct
            // 2026). Unless F6, Tab or an arrow just took the user there, say nothing and put the focus where the
            // caret is. A window just opening has no page yet: look again for a moment, as long as no key is pressed.
            Log.io("Word: focus in the sidebar or ribbon with no key; to the page")
            announcePage = true
            sidebarToPage(since: InputManager.lastKeyDownAt, delays: [0.05, 0.3, 0.7, 1.5, 3, 3, 4])   // Word starting cold takes a while
        case .loseFocus where event.obj is WordDocument:
            lastLostWasPage = Self.isPageArea(event.obj.element)
            if !(API.focusObject is WordDocument) { lastDocument = nil }
            next()
        case .caret where event.obj is WordDocument:
            caretArea = event.obj.element
            if let f = API.focusObject as? WordDocument, !f.isSameElement(as: event.obj) {
                // The caret moved to another page before Word said so: follow it without speaking.
                API.setFocusObject(event.obj, ancestors: API.focusAncestors)
                (event.obj as? EditableText)?.initAutoSelectDetection()
                lastDocument = (event.obj.element, event.obj.element.element(kAXWindowAttribute))
                return
            }
            next()
        case .typedCharacter where !(API.focusObject is WordDocument):
            next()
            retryCaretSearch(rest: [])
        default:
            next()
        }
    }
    private var lastDocument: (element: AXUIElement, windowElement: AXUIElement?)?
    private var lastLostWasPage = false

    // Leaving Word with the page focused, then coming back with Command Tab, looked like crossing a page: the page
    // was adopted silently and only "Document1, window" was heard (7 Oct 2026). Coming back is news.
    override func event_appModuleLoseFocus() {
        lastLostWasPage = false
        super.event_appModuleLoseFocus()
    }
    /// When a ribbon, sidebar or bar control last took the focus, and the key that was last then.
    private var barFocus: (at: Date, key: Date)?

    /// Back to the page after TurnOver used the sidebar (the rotor's headings): the page's focus would otherwise be
    /// taken for the echo after a ribbon control and ignored, and the heading chosen was never read (7 Oct 2026).
    func adoptPage() {
        barFocus = nil
        lastLostWasPage = false
        let app = AXUIElementCreateApplication(pid)
        // The page Word focused (the heading may be on another page), else the last one known.
        let focused = app.element(kAXFocusedUIElementAttribute).flatMap { $0.role == "AXTextArea" ? $0 : nil }
        guard let area = focused ?? caretArea else { return }
        _ = area.set(kAXFocusedAttribute, kCFBooleanTrue)
        AXHandler.shared.focusChanged(area, pid: pid)
    }

    override func terminate() { caretArea = nil; lastDocument = nil; pageRanges = []; pageRangeWindow = nil }

    /// Word's own section of the TurnOver menu: how comments are announced as the caret reaches them, and the
    /// Word commands that have no key of their own.
    static let bundle = "com.microsoft.Word"
    static var commentReport: ElementReport { ElementReport(rawValue: config.appSetting(bundle, "comments", default: "speech")) ?? .speech }
    override func menuItems() -> [MenuItem] {
        [
            MenuItem("Comments as the caret reaches them", .cycle(options: ElementReport.allCases.map(\.name),
                get: { ElementReport.allCases.firstIndex(of: WordAppModule.commentReport) ?? 0 },
                set: { config.setAppSetting(WordAppModule.bundle, "comments", ElementReport.allCases[$0].rawValue) })),
            MenuItem("Elements list: headings and comments", .action { (API.focusObject as? WordDocument)?.script(named: "elementsList")?.handler(KeyboardGesture(keyCode: 0, modifiers: [], characters: "", timestamp: 0, isRepeat: false, flags: [])) }),
            MenuItem("Report the comment at the caret", .action { (API.focusObject as? WordDocument)?.script(named: "reportCurrentComment")?.handler(KeyboardGesture(keyCode: 0, modifiers: [], characters: "", timestamp: 0, isRepeat: false, flags: [])) }),
            MenuItem("Report the page and line", .action { GlobalCommands.shared.script(named: "reportCaretLocation")?.handler(KeyboardGesture(keyCode: 0, modifiers: [], characters: "", timestamp: 0, isRepeat: false, flags: [])) }),
            MenuItem("Show or hide the sidebar (navigation pane)", .action { [weak self] in self?.toggleSidebar() }),
        ]
    }

    func toggleSidebar() {
        let app = AXUIElementCreateApplication(pid)
        guard let bar = app.element(kAXMenuBarAttribute),
              let view = bar.elements(kAXChildrenAttribute).first(where: { $0.string(kAXTitleAttribute) == "View" }),
              let item = Self.sidebarItem(in: view) else { return }
        AXUIElementPerformAction(item, kAXPressAction as CFString)
        Speech.speakMessage(String(localized: "sidebar", comment: "Spoken message"))
    }

    /// The rows of View > Sidebar > Document Map (Word's navigation outline), opening the sidebar if it is closed,
    /// with a closure that puts the sidebar back as it was.
    /// View > Sidebar, or in newer Word the Sidebar submenu's Navigation (pressing a submenu only opens it, and an
    /// open menu stops Word answering AppleScript: the elements list then found nothing, 2 Oct 2026).
    nonisolated static func sidebarItem(in view: AXUIElement) -> AXUIElement? {
        guard let item = view.elements(kAXChildrenAttribute).first?.elements(kAXChildrenAttribute).first(where: { $0.string(kAXTitleAttribute) == "Sidebar" }) else { return nil }
        if let sub = item.elements(kAXChildrenAttribute).first(where: { $0.role == "AXMenu" }) {
            return sub.elements(kAXChildrenAttribute).first(where: { $0.string(kAXTitleAttribute) == "Navigation" })
        }
        return item
    }

    nonisolated func documentMapRows() -> ([AXUIElement], @Sendable () -> Void) {
        let app = AXUIElementCreateApplication(pid)
        // On the main thread: the whole search, sidebar opening included, stops at 2.5 s (the watchdog trips at 4;
        // a closed sidebar meant up to 10 searches of 2,000 elements, E6 audit, 4 Oct 2026).
        let deadline = Date().addingTimeInterval(2.5)
        func outline() -> AXUIElement? {
            guard let win = app.element(kAXFocusedWindowAttribute) else { return nil }
            var queue = [win]; var n = 0
            while !queue.isEmpty, n < 2000, Date() < deadline {
                let e = queue.removeFirst(); n += 1
                let r = e.role
                if r == "AXTextArea" || r == "AXMenuBar" { continue }
                if r == "AXTabGroup", e.string(kAXDescriptionAttribute) == "Sidebar" {
                    if let map = e.elements(kAXChildrenAttribute).first(where: { $0.role == "AXRadioButton" && $0.string(kAXTitleAttribute) == "Document Map" }),
                       (map.attr(kAXValueAttribute) as? NSNumber)?.intValue != 1 {
                        AXUIElementPerformAction(map, kAXPressAction as CFString); usleep(300_000)
                    }
                    return e.firstDescendant(role: "AXOutline", maxVisited: 400)
                }
                queue.append(contentsOf: e.elements(kAXChildrenAttribute))
            }
            return nil
        }
        var opened = false
        var o = outline()
        if o == nil, let bar = app.element(kAXMenuBarAttribute),
           let view = bar.elements(kAXChildrenAttribute).first(where: { $0.string(kAXTitleAttribute) == "View" }),
           let item = Self.sidebarItem(in: view) {
            AXUIElementPerformAction(item, kAXPressAction as CFString)
            opened = true
            for _ in 0..<10 where Date() < deadline { usleep(150_000); o = outline(); if o != nil { break } }
        }
        let rows = (o?.elements(kAXChildrenAttribute) ?? []).filter { $0.role == "AXRow" }
        Log.info("Word: document map \(rows.count) rows\(opened ? " (sidebar opened)" : "")")
        let wasOpened = opened
        let restore: @Sendable () -> Void = {
            guard wasOpened, let bar = app.element(kAXMenuBarAttribute),
                  let view = bar.elements(kAXChildrenAttribute).first(where: { $0.string(kAXTitleAttribute) == "View" }),
                  let item = Self.sidebarItem(in: view) else { return }
            AXUIElementPerformAction(item, kAXPressAction as CFString)
        }
        return (rows, restore)
    }

    /// Every page area with its slice of the document-global index space. A window change or reflow must not
    /// reuse another document's page or old bounds (source regression, 29 Oct 2026, issue 178).
    private var pageRanges: [(area: AXUIElement, start: Int, end: Int)] = []
    private var pageRangeWindow: AXUIElement?
    func pageArea(containing offset: Int, near element: AXUIElement) -> AXUIElement? {
        guard offset >= 0 else { return nil }
        func range(of area: AXUIElement) -> (start: Int, end: Int)? {
            guard let r = cfRange(area.attr("AXSharedCharacterRange")), r.location >= 0, r.length >= 0,
                  r.location != Int.max else { return nil }
            let (end, overflow) = r.location.addingReportingOverflow(r.length)
            guard !overflow else { return nil }
            return (r.location, end)
        }
        // The end is inclusive: Word omits the paragraph mark ending a page from its shared range.
        func contains(_ r: (start: Int, end: Int)) -> Bool { offset >= r.start && offset <= r.end }
        // Normal caret reads need one bounded range query, rather than mapping every page in a long document.
        if let r = range(of: element), contains(r) { return element }
        let window = element.element(kAXWindowAttribute) ?? SettingsPanePlugin.windowOf(element)
        if window == nil || pageRangeWindow == nil || !CFEqual(window, pageRangeWindow) {
            pageRanges = []
            pageRangeWindow = window
        }
        if let cached = pageRanges.first(where: { contains(($0.start, $0.end)) })?.area,
           let live = range(of: cached), contains(live) { return cached }
        let t0 = Date()
        let areas = element.elements("AXSharedTextUIElements")
        pageRanges = areas.compactMap { a in
            guard let r = range(of: a) else { return nil }
            return (a, r.start, r.end)
        }
        Log.debug("Word: \(pageRanges.count) page areas mapped in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        return pageRanges.first { contains(($0.start, $0.end)) }?.area
    }
}

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
        script("toggleBold", String(localized: "Toggles bold and reports it", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+b"], category: cat) { [weak self] g in self?.afterKey(g) { $0.fontState { String(localized: "bold \(Phrases.onOff($0.bold))", comment: "Bold turned on or off in Word") } } }
        script("toggleItalic", String(localized: "Toggles italic and reports it", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+i"], category: cat) { [weak self] g in self?.afterKey(g) { $0.fontState { String(localized: "italic \(Phrases.onOff($0.italic))", comment: "Italic turned on or off in Word") } } }
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
    private func scripted(_ nothing: String, _ body: @escaping (@escaping @MainActor (String?) -> Void) -> Void) {
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

    /// Word marks misspellings in the text it gives accessibility (AXMarkedMisspelled): the next or previous one on
    /// this page, the caret at its start. (The AppleScript search found the word it was on again.)
    /// Where Word's whole-document search should start when the laid-out pages have no misspelling beyond the caret:
    /// after the marked word the caret is on, or Word finds that word again.
    private var misspellingSearchFrom: Int?
    private func goToMisspelling(forward: Bool) -> Bool {
        misspellingSearchFrom = nil
        guard let info = try? makeTextInfo(.caret) as? AXTextInfo else { return false }
        let el = info.textElement
        let n = info.storyLength()
        if n == 0 { Tones.edge(); Speech.speakMessage(forward ? String(localized: "no next spelling error", comment: "Spoken message") : String(localized: "no previous spelling error", comment: "Spoken message")); return true }   // nothing to search: answered without Word's script (it errored -1728 each press)
        guard n > 0, let a = el.param(kAXAttributedStringForRangeParameterizedAttribute, axRangeValue(0, min(n, 50_000))) as? NSAttributedString else { return false }
        var words: [NSRange] = []
        let ns = a.string as NSString
        a.enumerateAttribute(NSAttributedString.Key("AXMarkedMisspelled"), in: NSRange(location: 0, length: a.length)) { val, range, _ in
            guard (val as? NSNumber)?.boolValue == true else { return }
            // Word marks the word and sometimes the space after it: the word.
            var r = range
            while r.length > 0, let c = ns.substring(with: NSRange(location: NSMaxRange(r) - 1, length: 1)).first, c.isWhitespace || c.isPunctuation { r.length -= 1 }
            if r.length > 0 { words.append(r) }
        }
        let caret = info.start
        let target = forward ? words.first { $0.location > caret } : words.last { $0.location < caret }
        guard let r = target else {
            // Word lays out only the pages near the view, so "none beyond the caret here" is not "none in the
            // document": the whole-document search runs. (It never did while any misspelling was on these pages,
            // and errors on page 7 of 21 went unfound, 's tester, 5 Oct 2026.)
            if forward, let here = words.first(where: { NSLocationInRange(caret, $0) }) { misspellingSearchFrom = NSMaxRange(here) }
            return false
        }
        info.setCaretOffset(r.location)
        initAutoSelectDetection()
        Speech.speakMessage(String(localized: "\(ns.substring(with: r)), misspelled", comment: "A misspelled word reached: %@ is the word"))
        return true
    }

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

    private func goToSpellingError(forward: Bool) {
        if goToMisspelling(forward: forward) { return }
        guard let s = module?.script else { Log.io("Word: no script bridge for the spelling move"); Tones.edge(); Speech.speakMessage(forward ? String(localized: "no next spelling error", comment: "Spoken message") : String(localized: "no previous spelling error", comment: "Spoken message")); return }
        scripted(forward ? String(localized: "no next spelling error", comment: "Spoken message") : String(localized: "no previous spelling error", comment: "Spoken message")) { done in
            s.nextSpellingError(forward: forward, from: self.misspellingSearchFrom) { done($0.map { String(localized: "\($0), misspelled", comment: "A misspelled word reached: %@ is the word") }) }
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

/// Any other Word text area (a comment, a text box): editable text that is not "unavailable".
class WordTextArea: EditableText {
    override var states: Set<State> { super.states.subtracting([.unavailable]) }   // Word reports AXEnabled false on its text areas
}

/// A cell of a Word table. Word exposes real tables (AXTable, AXRow, AXCell, with AXRowIndexRange and
/// AXColumnIndexRange), each cell's text its own text area that takes the focus as the caret enters it, so Tab,
/// the arrows and clicks all arrive as focus changes. NVDA's table reading: say what changed (entering: the table's
/// size; then row and column), the column's title (the first row's text) and the row's title (the first column's,
/// as in a form: "Telephone"), then the text, or "blank"; "selected" when Tab selected the whole cell, as typing
/// then replaces it. TurnOver plus the arrows go cell to cell with the caret at the start, nothing selected.
/// (4 Oct 2026: this replaced asking Word by AppleScript, which took 150 ms a cell and hung with the Automation
/// alert unanswered.)
final class WordTableCell: WordTextArea {
    struct Place { let table: AXUIElement; let row: Int; let column: Int }
    /// The last cell spoken, to say only what changed; nil once the focus leaves the tables.
    static var last: Place?
    /// The last table spoken and when: its size is said once, not after every focus bounce through the page.
    static var lastTable: (AXUIElement, Date)?

    static func cell(of e: AXUIElement) -> AXUIElement? {
        // Up to six parents (asked for it; two missed the cells of later tables, which sit deeper: a tester,
        // 19 Oct 2026, "only the first table is navigable"). Stops at the table, the window or the page.
        var p = e.element(kAXParentAttribute)
        for _ in 0..<6 {
            guard let x = p else { return nil }
            if x.role == "AXCell" { return x }
            if x.role == "AXTable" || x.role == "AXWindow" || WordAppModule.isPageArea(x) { return nil }
            p = x.element(kAXParentAttribute)
        }
        return nil
    }
    var place: Place? {
        guard let c = Self.cell(of: element), let row = c.element(kAXParentAttribute), let table = row.element(kAXParentAttribute),
              table.role == "AXTable", let r = cfRange(c.attr("AXRowIndexRange")), let col = cfRange(c.attr("AXColumnIndexRange")) else { return nil }
        return Place(table: table, row: r.location, column: col.location)
    }
    /// The text area of a cell (rows and columns from 0).
    static func textArea(_ table: AXUIElement, row: Int, column: Int) -> AXUIElement? {
        guard row >= 0, column >= 0, let c = table.param("AXCellForColumnAndRow", [column, row] as CFArray),
              CFGetTypeID(c) == AXUIElementGetTypeID() else { return nil }
        return (c as! AXUIElement).firstDescendant(role: "AXTextArea", maxVisited: 6)
    }
    static func text(of area: AXUIElement) -> String {
        (area.string(kAXValueAttribute) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\r\n\u{7}").union(.whitespaces))
    }

    override func reportFocus() { Speech.speakMessage(describe()) }

    func describe() -> String {
        let t = Self.text(of: element)
        guard let p = place else { return t.isEmpty ? "blank" : t }
        let old = Self.last
        Self.last = p
        // The same table within a few seconds (Word hands the focus to the page between cells, which clears `last`):
        // its size is not news again (it was said at every cell, a tester's log, 8 Oct 2026).
        let sameTable = old.map { $0.table.isSame(p.table) } ?? (Self.lastTable.map { $0.0.isSame(p.table) && Date().timeIntervalSince($0.1) < 10 } ?? false)
        Self.lastTable = (p.table, Date())
        var parts: [String] = []
        if !sameTable {
            let rows = (p.table.attr("AXRowCount") as? Int) ?? p.table.elements("AXRows").count
            let columns = (p.table.attr("AXColumnCount") as? Int) ?? p.table.elements("AXColumns").count
            parts.append(String(localized: "table with \(String(rows)) rows and \(String(columns)) columns", comment: "A Word table reached: its size"))
        }
        // Back in the same table within the 10 s, but with no last cell (the focus went to the page between): row and
        // column are news. The force-unwrap here crashed TurnOver in a 201-row table (a tester, 12 Oct 2026).
        let rowChanged = !sameTable || (old.map { $0.row != p.row } ?? true)
        let columnChanged = !sameTable || (old.map { $0.column != p.column } ?? true)
        let coords = config.documentFormatting.tableCellCoordinates
        if rowChanged, coords { parts.append(Phrases.row(p.row + 1)) }
        if columnChanged, coords { parts.append(Phrases.column(p.column + 1)) }
        if config.documentFormatting.tableHeaders, columnChanged, p.row > 0, let h = Self.textArea(p.table, row: 0, column: p.column).map(Self.text(of:)), !h.isEmpty { parts.append(h) }
        if config.documentFormatting.tableHeaders, rowChanged, p.row > 0, p.column > 0, let h = Self.textArea(p.table, row: p.row, column: 0).map(Self.text(of:)), !h.isEmpty { parts.append(h) }
        parts.append(t.isEmpty ? Phrases.blank : t)
        if !t.isEmpty, let sel = cfRange(element.attr(kAXSelectedTextRangeAttribute)), sel.length > 0, sel.length >= t.count { parts.append(State.selected.displayString) }
        return parts.joined(separator: ", ")
    }

    override func initOverlay() {
        super.initOverlay()
        let cat = "Microsoft Word"
        for (name, dr, dc, keys) in [("table_nextColumn", 0, 1, [String]()), ("table_previousColumn", 0, -1, []),
                                     ("table_nextRow", 1, 0, ["kb:turnover+downArrow"]), ("table_previousRow", -1, 0, ["kb:turnover+upArrow"])] {
            let description = dr == 0 ? (dc > 0 ? String(localized: "In a table: the next cell in the row, the caret at its start (NVDA's table keys; TurnOver plus the arrows)", comment: "A command, as the key list and keyboard help say it")
                                                : String(localized: "In a table: the previous cell in the row, the caret at its start (NVDA's table keys; TurnOver plus the arrows)", comment: "A command, as the key list and keyboard help say it"))
                : (dr > 0 ? String(localized: "In a table: the cell below, the caret at its start (NVDA's table keys; TurnOver plus the arrows)", comment: "A command, as the key list and keyboard help say it")
                          : String(localized: "In a table: the cell above, the caret at its start (NVDA's table keys; TurnOver plus the arrows)", comment: "A command, as the key list and keyboard help say it"))
            script(name, description, gestures: keys, category: cat) { [weak self] _ in
                self?.move(dr, dc)
            }
        }
    }

    func move(_ dr: Int, _ dc: Int) {
        guard let p = place else { return }
        guard let target = Self.textArea(p.table, row: p.row + dr, column: p.column + dc) else {
            Tones.edge(); Speech.speakOnly(String(localized: "edge of table", comment: "Spoken message")); return
        }
        _ = target.set(kAXSelectedTextRangeAttribute, axRangeValue(0, 0))
        AXHandler.shared.focusChanged(target, pid: element.pid)
    }
}

/// A header or footer area: ordinary editable text named by its description.
final class WordHeaderFooter: WordTextArea {
    override var name: String { (element.string(kAXDescriptionAttribute) ?? "").replacingOccurrences(of: " -Section 1-", with: "") }
}

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

// MARK: - Word's scripting object model, on demand and off the main thread

final class WordScript {
    private let queue = DispatchQueue(label: "turnover.wordscript", qos: .userInitiated)

    struct Landing { let moved: Bool; let level: Int?; let text: String }

    /// Move the selection with `go to next/previous … what <item>`, collapse it to the start, and report where it landed.
    func goTo(item: String, forward: Bool, completion: @escaping @MainActor (Landing) -> Void) {
        queue.async {
            let r = self.run("""
            tell application "Microsoft Word"
                set s to selection start of selection
                set r to \(forward ? "go to next" : "go to previous") (text object of selection) what \(item)
                select r
                set selection end of selection to selection start of selection
                set p to paragraph 1 of selection
                return (s as text) & "|" & ((selection start of selection) as text) & "|" & ((outline level of p) as text) & "|" & (content of text object of p)
            end tell
            """)
            let parts = (r ?? "").components(separatedBy: "|")
            guard parts.count >= 4 else { DispatchQueue.main.async { completion(Landing(moved: false, level: nil, text: "")) }; return }
            let landing = Landing(moved: parts[0] != parts[1], level: Int(parts[2].filter(\.isNumber)),
                                  text: parts[3...].joined(separator: "|").trimmingCharacters(in: .whitespacesAndNewlines))
            DispatchQueue.main.async { completion(landing) }
        }
    }

    /// The caret to the start of the document's nth heading (1 is the first), by stepping from the top: the rotor's
    /// choice. (Pressing the row in the sidebar failed once TurnOver had closed the sidebar again, 7 Oct 2026.)
    func goToHeading(number n: Int, completion: @escaping @MainActor (Landing) -> Void) {
        queue.async {
            let r = self.run("""
            tell application "Microsoft Word"
                set selection start of selection to 0
                set selection end of selection to 0
                set k to \(n)
                if ((outline level of paragraph 1 of selection) as text) does not contain "body" then set k to k - 1
                repeat k times
                    set r to go to next (text object of selection) what goto a heading item
                    select r
                    set selection end of selection to selection start of selection
                end repeat
                set p to paragraph 1 of selection
                return "1|1|" & ((outline level of p) as text) & "|" & (content of text object of p)
            end tell
            """)
            let parts = (r ?? "").components(separatedBy: "|")
            guard parts.count >= 4 else { DispatchQueue.main.async { completion(Landing(moved: false, level: nil, text: "")) }; return }
            let landing = Landing(moved: true, level: Int(parts[2].filter(\.isNumber)),
                                  text: parts[3...].joined(separator: "|").trimmingCharacters(in: .whitespacesAndNewlines))
            DispatchQueue.main.async { completion(landing) }
        }
    }

    func selectionInformation(_ completion: @escaping @MainActor (Int?, Int?) -> Void) {
        let menuOpen = AXHandler.shared.isMenuOpen
        queue.async { let (p, l) = self.selectionInformationSync(menuOpen: menuOpen); DispatchQueue.main.async { completion(p, l) } }
    }

    nonisolated func selectionInformationSync(menuOpen: Bool) -> (Int?, Int?) {
        if menuOpen { return (nil, nil) }   // Word does not answer Apple Events while a menu is open (measured: -1712 after 5 s)
        let page = run("tell application \"Microsoft Word\" to return get selection information selection information type (active end adjusted page number)")
        let line = run("tell application \"Microsoft Word\" to return get selection information selection information type (first character line number)")
        return (page.flatMap(Int.init), line.flatMap(Int.init))
    }

    /// The comment whose scope contains the selection, as "author: text".
    func commentAtSelection(_ completion: @escaping @MainActor (String?) -> Void) {
        queue.async {
            let r = self.run("""
            tell application "Microsoft Word"
                set s to selection start of selection
                set n to count Word comments of active document
                repeat with i from 1 to n
                    set c to Word comment i of active document
                    set sc to scope of c
                    if (start of content of sc) ≤ (s + 1) and (end of content of sc) ≥ s then
                        return (author of c) & ": " & (content of comment text of c)
                    end if
                end repeat
                return ""
            end tell
            """)
            let answer = r?.isEmpty == false ? r : nil
            DispatchQueue.main.async { completion(answer) }
        }
    }

    func nextRevision(forward: Bool, completion: @escaping @MainActor (String?) -> Void) {
        queue.async {
            let r = self.run("""
            tell application "Microsoft Word"
                try
                    set r to \(forward ? "next revision" : "previous revision") selection with wrap
                    return ((revision type of r) as text) & "|" & (author of r) & "|" & (content of text object of r)
                on error
                    return ""
                end try
            end tell
            """)
            guard let r, !r.isEmpty else { DispatchQueue.main.async { completion(nil) }; return }
            let parts = r.components(separatedBy: "|")
            let kind = parts[0].replacingOccurrences(of: "revision ", with: "")
            let author = parts.count > 1 ? parts[1] : ""
            let text = parts.count > 2 ? parts[2...].joined(separator: "|") : ""
            let answer = author.isEmpty ? "\(kind): \(text.prefix(400))" : String(localized: "\(kind) by \(author): \(String(text.prefix(400)))", comment: "A tracked change: its kind (from Word), author and text")
            DispatchQueue.main.async { completion(answer) }
        }
    }

    /// The next spelling error after the selection (searching from its END, or the same word is found again), or the previous one.
    func nextSpellingError(forward: Bool, from: Int? = nil, completion: @escaping @MainActor (String?) -> Void) {
        queue.async {
            let r = self.run("""
            tell application "Microsoft Word"
                set d to active document
                if \(forward ? "true" : "false") then
                    set rg to create range d start \(from.map(String.init) ?? "((selection end of selection) + 1)") end (end of content of text object of d)
                    if (count of spelling errors of rg) = 0 then return ""
                    set e to first spelling error of rg
                else
                    set s to selection start of selection
                    if s = 0 then return ""
                    set rg to create range d start 0 end s
                    if (count of spelling errors of rg) = 0 then return ""
                    set e to last spelling error of rg
                end if
                select e
                set selection end of selection to selection start of selection
                return content of e
            end tell
            """)
            let answer = r?.isEmpty == false ? r : nil
            DispatchQueue.main.async { completion(answer) }
        }
    }

    struct FontState { let bold: Bool; let italic: Bool; let underline: Bool; let size: Int }
    func fontState(_ report: @escaping @MainActor (FontState) -> String) {
        queue.async {
            let r = self.run("""
            tell application "Microsoft Word"
                set f to font object of selection
                return ((bold of f) as text) & "|" & ((italic of f) as text) & "|" & ((underline of f) as text) & "|" & ((font size of f) as text)
            end tell
            """)
            let p = (r ?? "").components(separatedBy: "|")
            guard p.count >= 4 else { return }
            let state = FontState(bold: p[0] == "true", italic: p[1] == "true", underline: !(p[2].contains("none") || p[2] == "false"), size: Int(Double(p[3]) ?? 0))
            DispatchQueue.main.async { Speech.speakMessage(report(state)) }
        }
    }
    func alignment() {
        queue.async {
            let r = self.run("tell application \"Microsoft Word\" to return (alignment of paragraph format of selection) as text") ?? ""
            let words = r.contains("center") ? TextFormat.word("centred") : r.contains("right") ? TextFormat.word("right aligned") : r.contains("justify") ? TextFormat.word("justified") : TextFormat.word("left aligned")
            DispatchQueue.main.async { Speech.speakMessage(words) }
        }
    }
    func lineSpacing() {
        queue.async {
            let r = self.run("tell application \"Microsoft Word\" to return (line spacing rule of paragraph format of selection) as text") ?? ""
            let words = r.contains("double") ? TextFormat.word("double spacing") : r.contains("1pt5") || r.contains("one and a half") ? TextFormat.word("1.5 line spacing")
                : r.contains("single") ? TextFormat.word("single spacing") : String(localized: "line spacing \(r)", comment: "Word's line spacing rule, as Word names it")
            DispatchQueue.main.async { Speech.speakMessage(words) }
        }
    }
    /// Alignment and line spacing in words, for the detailed formatting report (VO-T twice; a tester): Word
    /// doesn't give them to accessibility.
    func paragraphFormat(_ completion: @escaping @MainActor (String) -> Void) {
        queue.async {
            let a = self.run("tell application \"Microsoft Word\" to return (alignment of paragraph format of selection) as text") ?? ""
            let l = self.run("tell application \"Microsoft Word\" to return (line spacing rule of paragraph format of selection) as text") ?? ""
            let pts = self.run("tell application \"Microsoft Word\" to return (line spacing of paragraph format of selection) as text") ?? ""
            // Word's words, spaces taken out ("line space1 pt5" and "line space 1pt5" both seen); a selection of
            // paragraphs that differ comes back as missing value or 9999999 (code review, 13 Oct: raw values were said).
            let aw = a.lowercased().replacingOccurrences(of: " ", with: ""), lw = l.lowercased().replacingOccurrences(of: " ", with: "")
            func mixed(_ v: String) -> Bool { v.isEmpty || v.contains("missing") || v.contains("9999999") }
            let align = mixed(aw) ? "" : aw.contains("center") ? TextFormat.word("centred") : aw.contains("right") ? TextFormat.word("right aligned")
                : aw.contains("distribute") ? TextFormat.word("distributed") : aw.contains("justify") ? TextFormat.word("justified") : aw.contains("left") ? TextFormat.word("left aligned") : ""
            let points = Double(pts.replacingOccurrences(of: ",", with: ".")).map { $0 == $0.rounded() ? String(Int($0)) : String(format: "%.1f", $0) }
            let space: String
            if mixed(lw) { space = "" }
            else if lw.contains("double") { space = TextFormat.word("double spacing") }
            else if lw.contains("1pt5") || lw.contains("onepointfive") { space = TextFormat.word("1.5 line spacing") }
            else if lw.contains("single") { space = TextFormat.word("single spacing") }
            else if lw.contains("atleast") { space = points.map { String(localized: "line spacing at least \($0) points", comment: "Paragraph line spacing: %@ is the size") } ?? TextFormat.word("line spacing at least") }
            else if lw.contains("exactly") { space = points.map { String(localized: "line spacing exactly \($0) points", comment: "Paragraph line spacing: %@ is the size") } ?? TextFormat.word("exact line spacing") }
            else if lw.contains("multiple"), let p = Double(pts.replacingOccurrences(of: ",", with: ".")) {
                let lines = p / 12; space = String(localized: "line spacing \(lines == lines.rounded() ? String(Int(lines)) : String(format: "%.2g", lines)) lines", comment: "Paragraph line spacing in lines: %@ is how many")
            } else { space = "" }
            let words = [align, space].filter { !$0.isEmpty }.joined(separator: ", ")
            DispatchQueue.main.async { completion(words) }
        }
    }
    func trackChanges() {
        queue.async {
            let r = self.run("tell application \"Microsoft Word\" to return (track revisions of active document) as text") ?? ""
            DispatchQueue.main.async { Speech.speakMessage(r == "true" ? String(localized: "track changes on", comment: "Spoken message") : String(localized: "track changes off", comment: "Spoken message")) }
        }
    }
    struct Comment { let author: String; let text: String; let start: Int }
    func comments(_ completion: @escaping @MainActor ([Comment]) -> Void) {
        queue.async {
            let r = self.run("""
            tell application "Microsoft Word"
                set out to ""
                set n to count Word comments of active document
                if n > 100 then set n to 100
                repeat with i from 1 to n
                    set c to Word comment i of active document
                    set out to out & (author of c) & tab & (content of comment text of c) & tab & ((start of content of scope of c) as text) & linefeed
                end repeat
                return out
            end tell
            """) ?? ""
            let list = r.split(separator: "\n").compactMap { line -> Comment? in
                let p = line.components(separatedBy: "\t")
                guard p.count >= 3, let start = Int(p[2]) else { return nil }
                return Comment(author: p[0], text: p[1], start: start)
            }
            DispatchQueue.main.async { completion(list) }
        }
    }
    func goToOffset(_ offset: Int, completion: @escaping @MainActor () -> Void) {
        queue.async {
            _ = self.run("tell application \"Microsoft Word\" to select (create range active document start \(offset) end \(offset))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { completion() }
        }
    }

    nonisolated(unsafe) private static var lastRefusalSpoken = Date.distantPast   // the script queue's
    /// Word has answered a script this run (so the Automation question is settled); a script is waiting on the question.
    nonisolated(unsafe) private static var wordAnswered = false
    nonisolated(unsafe) private static var asking = false


    nonisolated private func run(_ source: String) -> String? {
        // No AEDeterminePermissionToAutomateTarget: on this Mac it never returned, even when told not to wait (it sat on a
        // semaphore inside AE), and every Word command hung behind it (4 Oct 2026). The script itself brings up macOS's
        // question the first time; a refusal (-1743) is explained below.
        // The first script brings up macOS's question, "TurnOver wants to control Microsoft Word", and the question
        // lasts only as long as the script waits: at 5 s it vanished while a tester arrowed to Allow (
        // 5 Oct 2026). Until Word has answered once, wait as long as the user needs, and say what is being asked.
        let first = !Self.wordAnswered
        if first {
            Self.asking = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                guard Self.asking, NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.UserNotificationCenter").contains(where: { !$0.isTerminated }) else { return }
                Speech.speakMessage(String(localized: "macOS is asking whether TurnOver may control Microsoft Word. Choose Allow; there is no hurry.", comment: "Spoken message"))
            }
        }
        var error: NSDictionary?
        let result = NSAppleScript(source: "with timeout of \(first ? 300 : 5) seconds\n\(source)\nend timeout")?.executeAndReturnError(&error)
        Self.asking = false
        if error == nil { Self.wordAnswered = true }
        if let error {
            // The number only: the message can quote the document's own text (a code review on 18 Oct 2026).
            Log.warning("Word script error \(error[NSAppleScript.errorNumber] ?? "?")")
            // Refused (errAEEventNotPermitted, -1743): say why, once in a while, not fail in silence.
            if (error[NSAppleScript.errorNumber] as? Int) == -1743, Date().timeIntervalSince(Self.lastRefusalSpoken) > 30 {
                Self.lastRefusalSpoken = Date()
                DispatchQueue.main.async {
                    Speech.speakMessage(String(localized: "TurnOver needs permission to control Word. In System Settings, Privacy and Security, Automation, turn on Microsoft Word under TurnOver.", comment: "Spoken message"))
                }
            }
            return nil
        }
        return result?.stringValue
    }
}
