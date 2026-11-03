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

    override var usesNativeSpellingMenu: Bool { true }
    override var handlesNativeFormattingShortcuts: Bool { true }

    // Word's cells can sit six parents above their text (19 Oct 2026), beyond the shared four-parent walk.
    override func isTableCellText(_ element: AXUIElement) -> Bool { WordTableCell.cell(of: element) != nil }

    override func ignoresAnnouncement(_ text: String, after key: String, elapsed: TimeInterval) -> Bool {
        // Word says "Bold" or "Plain" for these keys; its document scripts report the actual state. Both were
        // heard and flashed on the display one after the other (7 Oct 2026).
        elapsed < 0.8 && ["kb:command+b", "kb:command+i", "kb:command+u"].contains(key)
    }

    override func hint(for object: TurnOverObject) -> String? {
        // Not a dialog's text box: Insert Table's column width got the document hint (7 Oct 2026).
        guard (object.role == .document || object.role == .editableText), !AXHandler.modalInFront(pid: object.pid) else { return nil }
        return String(localized: "TurnOver Down reads from here; TurnOver H moves by heading.", comment: "A hint, said after a pause on an item")
    }

    override func paragraphFormatting(_ completion: @escaping @MainActor (String) -> Void) {
        script.paragraphFormat(completion)
    }

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

    var inTableCheckedAt = Date.distantPast
    var inTableLastAnswer = false

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
    var lastDocument: (element: AXUIElement, windowElement: AXUIElement?)?
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
