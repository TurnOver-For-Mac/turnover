// SPDX-License-Identifier: GPL-3.0-or-later
// Google Docs, Sheets and Slides draw their documents as pictures; only with their own "screen reader support" on
// (Command Option Z, remembered by the Google account) is the text there for any screen reader, NVDA's, JAWS's and
// VoiceOver's alike. With it off, TurnOver's browse mode saw only the menus and the arrows said nothing (// 12 Oct 2026, in Safari: no Docs announcements at all in the log). With it on, Docs adds an "Accessibility" menu to
// its menu bar: that is how TurnOver tells. When it is off, TurnOver says how to turn it on, once per document.
import Foundation
import ApplicationServices

enum GoogleDocs {
    private static var told: Set<String> = []

    // MARK: The editor (12 Oct 2026)
    //
    // In Docs, Sheets and Slides the text box Safari reports is only Google's hidden typing target: the caret never
    // moves in it (a test Doc: 39 "caret did not move" in a minute, each after a wait), and the document itself is
    // drawn. With screen reader support on, Google says each move by writing it into a live region, id
    // "docs-aria-speakable", which is how NVDA and VoiceOver read Docs; Safari did not pass those changes on to
    // TurnOver (no live region events at all). So in the editor TurnOver leaves the keys to Google and reads that
    // region itself, ten times a second, while the focus is there.

    private static var editorElement: AXUIElement?
    private static var speakable: AXUIElement?
    private static var lastHeard = ""
    private static var timer: Timer?

    /// Whether this element is Google's typing target in a Docs, Sheets or Slides page (the outer page's address).
    static func isEditor(_ e: AXUIElement) -> Bool {
        if let ed = editorElement, CFEqual(ed, e) { return true }
        guard ["AXTextArea", "AXTextField"].contains(e.role) else { return false }
        var x: AXUIElement? = e.element(kAXParentAttribute); var hops = 0
        while let y = x, hops < 25 {
            if y.role == "AXWebArea", let u = (y.attr("AXURL") as? URL)?.absoluteString, isGoogleEditor(u) { return true }
            x = y.element(kAXParentAttribute); hops += 1
        }
        return false
    }

    /// The focus moved: start or stop listening to Google's announcements.
    static func focusMoved(to e: AXUIElement) {
        if isEditor(e) {
            guard editorElement.map({ !CFEqual($0, e) }) ?? true else { return }
            editorElement = e
            speakable = findSpeakable(from: e)
            lastHeard = currentText()
            Log.io("Google Docs: editor focused; reading Google's announcements \(speakable == nil ? "(none found)" : "")")
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in MainActor.assumeIsolated { poll() } }
        } else if editorElement != nil {
            editorElement = nil; speakable = nil
            timer?.invalidate(); timer = nil
            Log.io("Google Docs: left the editor")
        }
    }

    private static func findSpeakable(from e: AXUIElement) -> AXUIElement? {
        // The outer page: the last web area going up.
        var page: AXUIElement?; var x: AXUIElement? = e; var hops = 0
        while let y = x, hops < 30 { if y.role == "AXWebArea" { page = y }; x = y.element(kAXParentAttribute); hops += 1 }
        guard let root = page else { return nil }
        let began = Date()
        var queue = [root], seen = 0
        while !queue.isEmpty, seen < 4000, Date().timeIntervalSince(began) < 0.4 {
            let n = queue.removeFirst(); seen += 1
            if n.string("AXDOMIdentifier") == "docs-aria-speakable" { return n }
            queue += n.elements(kAXChildrenAttribute)
        }
        return nil
    }

    private static func currentText() -> String {
        guard let s = speakable else { return "" }
        var parts: [String] = []
        var stack = [s]; var n = 0
        while let e = stack.popLast(), n < 200 {
            n += 1
            if e.role == "AXStaticText", let v = e.string(kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { parts.append(v) }
            stack += e.elements(kAXChildrenAttribute).reversed()
        }
        return parts.joined(separator: " ")
    }

    private static func poll() {
        guard editorElement != nil else { return }
        if speakable == nil, let e = editorElement { speakable = findSpeakable(from: e) }
        let now = currentText()
        guard now != lastHeard else { return }
        let before = lastHeard
        lastHeard = now
        // Google appends: say what's new; if it replaced the text, say all of it.
        let new = now.hasPrefix(before) && !before.isEmpty ? String(now.dropFirst(before.count)).trimmingCharacters(in: .whitespaces) : now
        guard !new.isEmpty else { return }
        Speech.asPrivate { Speech.cancel(); Speech.speakText(new) }   // the user's document: never into the log
    }

    static func isGoogleEditor(_ url: String) -> Bool {
        guard let u = URL(string: url), u.host == "docs.google.com" else { return false }
        return ["/document/", "/spreadsheets/", "/presentation/"].contains { u.path.contains($0) }
    }

    /// A moment after the page arrives (Docs builds its menu bar late): is screen reader support on?
    static func checkSoon(_ d: BrowseModeDocument) {
        let url = d.url
        guard isGoogleEditor(url), !told.contains(url) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak d] in
            guard let d, d.url == url, !told.contains(url) else { return }
            let found = hasAccessibilityMenu(d.webArea)
            Log.io("Google Docs: screen reader support \(found ? "on" : "off (no Accessibility menu)")")
            guard !found else { return }
            told.insert(url)
            Hints.schedule(String(localized: "Google's screen reader support is off for this document, so its text can't be read. Press Command Option Z to turn it on; Google remembers it.", comment: "Spoken message"))
        }
    }

    /// The menu bar's "Accessibility" item: 800 items looked at, at most, a quarter of a second.
    static func hasAccessibilityMenu(_ web: AXUIElement) -> Bool {
        let began = Date()
        var queue = [web], seen = 0
        while !queue.isEmpty, seen < 800, Date().timeIntervalSince(began) < 0.25 {
            let e = queue.removeFirst(); seen += 1
            let names = [e.string(kAXTitleAttribute), e.string(kAXDescriptionAttribute)].compactMap { $0 }
            if ["AXButton", "AXMenuButton", "AXMenuItem", "AXStaticText"].contains(e.role), names.contains("Accessibility") { return true }
            queue += e.elements(kAXChildrenAttribute)
        }
        return false
    }
}
