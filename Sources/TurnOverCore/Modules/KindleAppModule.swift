// SPDX-License-Identifier: GPL-3.0-or-later
// Kindle (18 Oct 2026, the Apple apps sweep; "The actual log in screen is inaccessible which isn't a good
// start"). Kindle for Mac is the iPad app (bundle com.amazon.Lassen), and its sign-in screen is Amazon's web page in
// an iOS web view. What the iOS bridge gives accessibility (probe): the window's content group, a few empty groups,
// then the page as an AXGroup with AXURL (role description "frame", described "Amazon Sign In") holding the heading,
// the two choices, the email field, Continue, the links. No AXWebArea anywhere, so TurnOver never read it as a page:
// the focus sat on an empty group, Tab moved nothing it could hear, and VO-Right went from the group to the close
// button (driver). TurnOver reads that frame as a web page instead: the arrows by line, H, say all.
//
// What the bridge gets wrong, and TurnOver's answers:
// - Every element of the page says AXFocused is true and none can be given the focus: Tab moves the reading
//   position to the next control (browseTabMovesReadingPosition), and typing into a field clicks it first.
// - The keyboard focus stays on a nameless group while a field is typed into, and it blips (lose and gain) as
//   keys go in: in focus mode that group is taken to be the field at the reading position, so the field is what
//   is read and focus mode stays (the first try: the blip put browse mode back mid-address).
// - The buttons carry a value of "5" (said as "button, 5"): left out.
// - Continue replaces the page with the next step's: the new frame is found in the window.
// - The window is blank whenever Kindle is behind another app, and was once blank in front too; quitting and
//   opening Kindle brought the page back (18 Oct 2026). Coming to the front, the page is looked for again for a
//   few seconds.
import Foundation
import ApplicationServices
import AppKit

final class KindleAppModule: AppModule {
    static let bundleID = "com.amazon.Lassen"

    /// An iOS web view's page: a group that carries the page's address.
    static func isWebFrame(_ e: AXUIElement) -> Bool {
        e.role == "AXGroup" && e.attr("AXURL") != nil
    }

    private func frame(below e: AXUIElement, limit: Int = 200) -> AXUIElement? {
        var queue = [(e, 0)], seen = 0
        let deadline = Date().addingTimeInterval(0.15)   // Kindle going behind answers slowly or not at all (a 24 s hang, 18 Oct 2026)
        while !queue.isEmpty, seen < limit, Date() < deadline {
            let (x, d) = queue.removeFirst(); seen += 1
            if Self.isWebFrame(x) { return x }
            if d < 14 { queue.append(contentsOf: x.elements(kAXChildrenAttribute).map { ($0, d + 1) }) }
        }
        return nil
    }

    override func browseRoot(for element: AXUIElement, ancestors: [TurnOverObject]) -> AXUIElement? {
        if Self.isWebFrame(element) { return element }
        if let a = ancestors.first(where: { Self.isWebFrame($0.element) }) { return a.element }
        // Only from a bare group: Kindle's own screens (the library, a book) are not web pages.
        guard element.role == "AXGroup" else { return nil }
        if let f = frame(below: element) ?? element.element(kAXWindowAttribute).flatMap({ frame(below: $0, limit: 400) }) { return f }
        // Kindle's own screens (the welcome, 18 Oct 2026: "Welcome to the new Kindle for Mac", its texts and a Let's
        // go button under the content group the focus sits on, VO-Right going past them to the close button): the
        // window's content read as a document too, the arrows through its texts and buttons, Return pressing.
        if element.string(kAXSubroleAttribute) == Self.contentSubrole { return element }
        return ancestors.first { $0.element.string(kAXSubroleAttribute) == Self.contentSubrole }?.element
    }
    static let contentSubrole = "iOSContentGroup"
    /// Kindle builds a page's words for accessibility only once it has seen VoiceOver running (18 Oct 2026: none with
    /// VoiceOver off; VoiceOver on for five seconds and off again, and every page after had its words, minutes later
    /// too). A page without them is a picture page or that.
    static let noTextWords = "No text on this page. If it has words, turn VoiceOver on and off once, and Kindle shows them."

    override func browseRoot(inWindow window: AXUIElement) -> AXUIElement? {
        frame(below: window, limit: 400) ?? window.elements(kAXChildrenAttribute).first { $0.string(kAXSubroleAttribute) == Self.contentSubrole }
    }

    override var browseTabMovesReadingPosition: Bool { true }

    /// A click in the middle of the field, the pointer put back (Numbers' way into a table).
    override func takeFocus(_ element: AXUIElement) -> Bool {
        guard let f = TurnOverObject.frame(element), f.width > 0 else { return false }
        let at = CGPoint(x: f.midX, y: f.midY)
        let back = CGEvent(source: nil)?.location ?? at
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(30_000)
        }
        CGWarpMouseCursorPosition(back)
        Log.io("kindle: into the field by a click")
        return true
    }

    /// In focus mode, the nameless group reported as the focus is the field being typed into.
    override func redirectFocus(_ element: AXUIElement) -> AXUIElement? {
        // The page itself too ("Amazon Sign In"): the keys went to the field while the bridge named the page (the
        // second try, 18 Oct 2026: no echo).
        guard element.role == "AXGroup", Self.isWebFrame(element) || (element.string(kAXDescriptionAttribute) ?? "").isEmpty,
              let doc = API.focusTreeInterceptor, doc.passThrough, doc.webArea.pid == pid,
              let field = doc.editableAtPosition() else { return nil }
        return field
    }

    /// Tab in a field: Kindle moves its keyboard on but says nothing of it, so TurnOver leaves focus mode and takes
    /// the reading position to the next control, read (18 Oct 2026: after the address, Tab and the arrows
    /// were silent).
    required init(pid: pid_t, bundleIdentifier: String, appName: String) {
        super.init(pid: pid, bundleIdentifier: bundleIdentifier, appName: appName)
        script("kindle_tabOut", String(localized: "From a field on Kindle's page to the next or previous control", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:tab", "kb:shift+tab"], category: "Kindle") { [weak self] g in
            guard let self, let doc = API.focusTreeInterceptor, doc.webArea.pid == self.pid else { g.send(); return }
            doc.setPassThrough(false, announce: true)
            let roles: Set<String> = ["AXLink", "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXSlider"]
            if let (at, _) = doc.buffer.find(from: doc.position, forward: !g.modifiers.contains(.shift), roles: roles) { doc.position = at; doc.speakUnit(.line) }
            else { Tones.edge() }
        }.isAvailable = { [weak self] in
            guard let self, let doc = API.focusTreeInterceptor else { return false }
            return doc.passThrough && doc.webArea.pid == self.pid && Self.isWebFrame(doc.webArea)
        }
        bookScripts()
        WebBuffer.iosLeadingIdentifiers.insert("bookmark-full-page-view")
    }

    // MARK: Books

    /// The open book's page: one element holding the whole page's words (role AXGenericElement), under the reader.
    private func pageText(in root: AXUIElement) -> AXUIElement? {
        var queue = [root], seen = 0
        let deadline = Date().addingTimeInterval(0.15)
        while !queue.isEmpty, seen < 200, Date() < deadline {
            let e = queue.removeFirst(); seen += 1
            if e.role == "AXGenericElement", !(e.string(kAXValueAttribute) ?? "").isEmpty { return e }
            queue.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
        return nil
    }

    /// The reader: the open book's view (identifier ReaderView), whether or not its page has words (a cover is a picture).
    private func reader(in root: AXUIElement) -> AXUIElement? {
        var queue = [root], seen = 0
        let deadline = Date().addingTimeInterval(0.15)
        while !queue.isEmpty, seen < 200, Date() < deadline {
            let e = queue.removeFirst(); seen += 1
            if e.string(kAXIdentifierAttribute) == "ReaderView" { return e }
            queue.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
        return nil
    }

    /// The document while a book is open and being read (not typed into), and the page's words if it has any.
    private func bookDocument() -> (doc: BrowseModeDocument, page: AXUIElement?)? {
        // Only with Kindle in front: behind, its window goes blank and its answers slow (the hang of 18 Oct 2026, say all
        // turning a page as Command-Tab took Kindle away).
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let doc = API.focusTreeInterceptor, doc.webArea.pid == pid, !doc.passThrough, let r = reader(in: doc.webArea) else { return nil }
        return (doc, pageText(in: r))
    }

    /// The first and last lines of the page's words in the copy (the hint and the bookmark button are not the page).
    private func textLines(_ doc: BrowseModeDocument, _ page: AXUIElement?) -> (first: Int, last: Int)? {
        guard let page else { return nil }
        let i = doc.buffer.lines.indices.filter { doc.buffer.lines[$0].element.map { $0.isSame(page) } ?? false }
        guard let a = i.first, let b = i.last else { return nil }
        return (a, b)
    }

    /// Kindle's own arrow keys turn the page (probe: Right forward, Left back, the words changed within a second).
    /// The key goes to Kindle, the words are watched for, and `done` hears whether the page turned. A picture page
    /// (the cover) has no words to watch: from or to one, a moment's wait stands in.
    private func turnPage(forward: Bool, _ done: @escaping (Bool) -> Void) {
        guard let (doc, page) = bookDocument() else { done(false); return }
        let before = page?.string(kAXValueAttribute) ?? ""
        KeyboardGesture(identifier: forward ? "kb:rightArrow" : "kb:leftArrow")?.send()
        func check(_ n: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == self.pid else { Log.io("kindle: left before the page turned"); done(false); return }
                let now = self.reader(in: doc.webArea).flatMap { self.pageText(in: $0) }?.string(kAXValueAttribute) ?? ""
                if now != before { doc.buffer.build(); done(true) }
                else if n > 1 { check(n - 1) }
                else if before.isEmpty { doc.buffer.build(); done(true) }
                else { Log.io("kindle: the page did not turn"); done(false) }
            }
        }
        check(before.isEmpty ? 8 : 20)
    }

    /// Down on the page's last line, Up on its first, Page Down and Page Up: the next or previous page, read from its
    /// first line (or, going back by line, its last). VoiceOver reads a Kindle book a page at a time; this is the
    /// arrows carrying on from page to page, as in any long document.
    private func bookScripts() {
        let cat = "Kindle"
        script("kindle_nextPageByLine", String(localized: "Next line; on the page's last line, the next page", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:downArrow"], category: cat) { [weak self] g in
            self?.turnAndRead(forward: true, atEnd: false, g)
        }.isAvailable = { [weak self] in self?.onEdgeLine(last: true) == true }
        script("kindle_previousPageByLine", String(localized: "Previous line; on the page's first line, the previous page's last", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:upArrow"], category: cat) { [weak self] g in
            self?.turnAndRead(forward: false, atEnd: true, g)
        }.isAvailable = { [weak self] in self?.onEdgeLine(last: false) == true }
        script("kindle_nextPage", String(localized: "The next page, read from its first line", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:pageDown"], category: cat) { [weak self] g in
            self?.turnAndRead(forward: true, atEnd: false, g)
        }.isAvailable = { [weak self] in self?.bookDocument() != nil }
        script("kindle_previousPage", String(localized: "The previous page, read from its first line", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:pageUp"], category: cat) { [weak self] g in
            self?.turnAndRead(forward: false, atEnd: false, g)
        }.isAvailable = { [weak self] in self?.bookDocument() != nil }
    }

    private func onEdgeLine(last: Bool) -> Bool {
        guard let (doc, page) = bookDocument() else { return false }
        // A picture page: the arrows turn on at once (the cover said "Add Bookmark" and "bottom" for ever, 18 Oct 2026).
        guard let lines = textLines(doc, page) else { return true }
        guard let i = doc.buffer.lineIndex(at: doc.position) else { return false }
        return last ? i >= lines.last : i <= lines.first
    }

    private func turnAndRead(forward: Bool, atEnd: Bool, _ g: KeyboardGesture) {
        turnPage(forward: forward) { [weak self] turned in
            guard let self, let (doc, page) = self.bookDocument() else { return }
            guard turned else { Tones.edge(); Speech.speakMessage(forward ? String(localized: "end of the book", comment: "Spoken message") : String(localized: "start of the book", comment: "Spoken message")); return }
            guard let lines = self.textLines(doc, page) else { Speech.speakMessage(Self.noTextWords); return }
            doc.position = doc.buffer.lines[atEnd ? lines.last : lines.first].start
            doc.speakUnit(.line)
        }
    }

    /// Say all reaching the page's end turns the page and reads on, as VoiceOver's continuous reading does.
    override func sayAllReachedEnd(_ obj: TurnOverObject, resume: @escaping (TextInfo) -> Void) -> Bool {
        guard obj.pid == pid, bookDocument() != nil else { return false }
        turnPage(forward: true) { [weak self] turned in
            guard let self, turned, let (doc, page) = self.bookDocument() else { if !turned { Speech.speakMessage(String(localized: "end of the book", comment: "Spoken message")) }; return }
            guard let lines = self.textLines(doc, page) else { Speech.speakMessage(Self.noTextWords); return }
            doc.position = doc.buffer.lines[lines.first].start
            if let info = doc.makeTextInfo(.caret) { resume(info) }
        }
        return true
    }

    override func objectClass(for element: AXUIElement, role: Role, subrole: String?) -> TurnOverObject.Type? {
        [.button, .checkBox, .switchControl, .radioButton].contains(role) ? KindleButton.self : nil
    }

    // MARK: The page coming late

    private var lookingSince = Date.distantPast

    override func handleEvent(_ event: Event, next: () -> Void) {
        next()
        // The window's content taking the focus says nothing of itself (it has no name): the line the reading
        // position is on is read, as VoiceOver reads the item it lands on ("Welcome to the new Kindle for Mac" was
        // skipped, the first Down going past it).
        if event.kind == .gainFocus, event.obj.pid == pid, event.obj.element.string(kAXSubroleAttribute) == Self.contentSubrole {
            let root = event.obj.element
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard let doc = API.focusTreeInterceptor, doc.webArea.isSame(root), !doc.passThrough else { return }
                doc.speakUnit(.line)
            }
        }
        guard event.kind == .gainFocus, event.obj.pid == pid, event.obj.element.role == "AXGroup",
              API.focusTreeInterceptor?.webArea.pid != pid, Date().timeIntervalSince(lookingSince) > 6 else { return }
        lookingSince = Date()
        look(5)
    }

    /// Every second for a few: once the window holds a page, the focus is taken there.
    private func look(_ left: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, NSWorkspace.shared.frontmostApplication?.processIdentifier == self.pid,
                  API.focusTreeInterceptor?.webArea.pid != self.pid else { return }
            let app = AXUIElementCreateApplication(self.pid)
            if let w = app.element(kAXFocusedWindowAttribute), let f = self.frame(below: w, limit: 400) {
                Log.io("kindle: the page came after \(6 - left) s")
                AXHandler.shared.focusChanged(f, pid: self.pid)
            } else if left > 1 {
                self.look(left - 1)
            } else {
                Log.io("kindle: the window still holds no page (Kindle's blank window; quitting and opening it again has brought it back)")
            }
        }
    }
}

/// A button or switch on Kindle's page: the bridge's value ("button, 5", "switch, 1, off") is not the control's.
final class KindleButton: TurnOverObject {
    override var value: String? {
        guard let v = super.value, !v.isEmpty, !v.allSatisfy(\.isNumber) else { return nil }
        return v
    }
}
