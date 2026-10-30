// SPDX-License-Identifier: GPL-3.0-or-later
// Keynote (17 Oct 2026, the Apple apps sweep). With the slide itself focused (an AXLayoutArea, "Slide") the arrows,
// Page Up and Down, Home and End move from slide to slide, but Keynote posts nothing accessibility sees for it: the
// slide changed in silence (driver: three slides, Up, Up, Down, nothing said). TurnOver sends the key, then reads
// the slide the navigator now has selected: "Slide 2 of 3, Title, Presentation Title, Subtitle, …", its text boxes in
// order, a picture or a shape by name. The same when the slide area takes the focus.
//
// What Keynote gives accessibility (probe): the slide navigator is an AXOutline ("Slide navigator") of rows, the
// selected row being the slide shown, its image described "Slide 1, Text"; the slide is an AXLayoutArea of
// AXLayoutItems (described "Title, Presentation Title, Textbox"), each text box holding an AXTextArea.
import Foundation
import ApplicationServices

final class KeynoteAppModule: AppModule {
    static let bundleID = "com.apple.Keynote"

    required init(pid: pid_t, bundleIdentifier: String, appName: String) {
        super.init(pid: pid, bundleIdentifier: bundleIdentifier, appName: appName)
        let cat = "Keynote"
        // Playing: every key that moves the show reads the slide it lands on.
        for key in ["rightArrow", "leftArrow", "downArrow", "upArrow", "space", "enter", "pageDown", "pageUp", "home", "end", "n", "p"] {
            script("keynote_play_\(key)", String(localized: "While playing: the next or previous slide, read", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:\(key)"], category: cat) { [weak self] g in
                g.send()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.readPlayingSlide() }
            }.isAvailable = { [weak self] in self?.isPlaying() == true }
        }
        for key in ["upArrow", "downArrow", "pageUp", "pageDown", "home", "end", "leftArrow", "rightArrow"] {
            script("keynote_slide_\(key)", String(localized: "The previous or next slide, read (Keynote says nothing as it moves)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:\(key)"], category: cat) { [weak self] g in
                guard let self else { return }
                let before = self.selectedSlide()?.index
                g.send()
                _ = Poll.pumping(every: 0.02, limit: 0.3) { self.selectedSlide()?.index != before }
                if self.selectedSlide()?.index == before { Tones.edge() }
                self.saySlide()
            }.isAvailable = { [weak self] in self?.onSlide() == true }
        }
    }

    // MARK: Playing

    /// While a slideshow plays Keynote gives accessibility only an empty window (and a short "Slide 2, Text"
    /// announcement); the slide's words come from Keynote's own scripting: its current slide's title, body and
    /// presenter notes (18 Oct 2026). The first script brings up macOS's question, "TurnOver wants to control Keynote".
    private func isPlaying() -> Bool {
        guard let f = API.focusObject, f.pid == pid else { return false }
        let w = f.element.role == "AXWindow" ? f.element : f.element.element(kAXWindowAttribute)
        guard let w else { return false }
        return w.string(kAXSubroleAttribute) == "AXUnknown" && !w.elements(kAXChildrenAttribute).contains { $0.role == "AXSplitGroup" }
    }

    nonisolated private static let scriptQueue = DispatchQueue(label: "turnover.keynote.script")
    nonisolated(unsafe) private static var answered = false   // the script queue's

    private func readPlayingSlide() {
        let source = """
        tell application id "com.apple.Keynote"
            tell front document
                set s to current slide
                set t to ""
                try
                    set t to object text of default title item of s
                end try
                set b to ""
                try
                    set b to object text of default body item of s
                end try
                set n to ""
                try
                    set n to presenter notes of s
                end try
                return ((slide number of s) as text) & tab & ((count of slides) as text) & tab & t & tab & b & tab & n
            end tell
        end tell
        """
        Self.scriptQueue.async {
            let first = !Self.answered
            var error: NSDictionary?
            let result = NSAppleScript(source: "with timeout of \(first ? 300 : 4) seconds\n\(source)\nend timeout")?.executeAndReturnError(&error)
            if error == nil { Self.answered = true }
            let text = result?.stringValue
            DispatchQueue.main.async {
                if let error {
                    // The number only: the message can quote the slide's own text (a code review on 18 Oct 2026).
                    Log.warning("Keynote script error \(error[NSAppleScript.errorNumber] ?? "?")")
                    if (error[NSAppleScript.errorNumber] as? Int) == -1743 {
                        Speech.speakMessage(String(localized: "TurnOver needs permission to read the slide. In System Settings, Privacy and Security, Automation, turn on Keynote under TurnOver.", comment: "Spoken message"))
                    }
                    return
                }
                guard let parts = text?.components(separatedBy: "\t"), parts.count >= 5 else { return }
                let clean = { (t: String) in t.replacingOccurrences(of: "\n", with: ", ").replacingOccurrences(of: "\r", with: ", ").trimmingCharacters(in: .whitespaces) }
                var words = [Self.slide(parts[0], of: parts[1])]
                if !clean(parts[2]).isEmpty { words.append(Self.title(clean(parts[2]))) }
                if !clean(parts[3]).isEmpty { words.append(clean(parts[3])) }
                if !clean(parts[4]).isEmpty { words.append(Self.notes(clean(parts[4]))) }
                Speech.cancel()
                Speech.speakMessage(words.joined(separator: ", "))
            }
        }
    }

    // MARK: Where

    private func window() -> AXUIElement? { AXUIElementCreateApplication(pid).element(kAXFocusedWindowAttribute) }

    /// The keyboard is on the slide itself with nothing on it selected (a selected box takes the arrows to move it).
    private func onSlide() -> Bool {
        guard let f = API.focusObject, f.pid == pid, f.element.role == "AXLayoutArea" else { return false }
        return !f.element.elements(kAXChildrenAttribute).contains { ($0.attr(kAXSelectedAttribute) as? Bool) == true }
    }

    private func navigator() -> AXUIElement? {
        func find(_ e: AXUIElement, _ d: Int) -> AXUIElement? {
            if e.role == "AXOutline" { return e }
            if d > 5 { return nil }
            for c in e.elements(kAXChildrenAttribute) { if let f = find(c, d + 1) { return f } }
            return nil
        }
        return window().flatMap { find($0, 0) }
    }

    private func selectedSlide() -> (index: Int, count: Int, row: AXUIElement)? {
        guard let nav = navigator() else { return nil }
        let rows = nav.elements(kAXRowsAttribute)
        guard let i = rows.firstIndex(where: { ($0.attr(kAXSelectedAttribute) as? Bool) == true }) else { return nil }
        return (i, rows.count, rows[i])
    }

    private func slideArea() -> AXUIElement? {
        guard let f = API.focusObject, f.element.role == "AXLayoutArea" else { return nil }
        return f.element
    }

    // MARK: Reading

    /// The slide's contents in order: each text box's words, a picture, a shape.
    private func contents() -> [String] {
        guard let area = slideArea() else { return [] }
        return area.elements(kAXChildrenAttribute).compactMap { item -> String? in
            if let text = item.elements(kAXChildrenAttribute).first(where: { $0.role == "AXTextArea" }) {
                let words = (text.string(kAXValueAttribute) ?? "").replacingOccurrences(of: "\n", with: ", ").trimmingCharacters(in: .whitespaces)
                let kind = (item.string(kAXDescriptionAttribute) ?? "").components(separatedBy: ",").first ?? ""
                // A shape with nothing typed in it is named by its kind ("Square"); an empty text box is skipped.
                guard !words.isEmpty else { return kind.isEmpty || kind == "Textbox" || kind == "Title" || kind == "Body" ? nil : kind }
                if !["Title", "Body", "Textbox", ""].contains(kind) { return "\(kind), \(words)" }
                return ["Title", "Body"].contains(kind) && kind == "Title" ? Self.title(words) : words
            }
            let d = item.string(kAXDescriptionAttribute) ?? ""
            return d.isEmpty ? nil : d
        }
    }

    /// The slide's presenter notes when Keynote is showing them (View, Show Presenter Notes): the text area in the
    /// scroll area beside the slide's, outside the slide itself.
    private func notes() -> String? {
        guard let w = window(), let split = w.elements(kAXChildrenAttribute).first(where: { $0.role == "AXSplitGroup" }) else { return nil }
        let box = split.elements(kAXChildrenAttribute).filter { $0.role == "AXScrollArea" }
            .compactMap { sa in sa.elements(kAXChildrenAttribute).first { $0.role == "AXTextArea" } }.first
        let words = (box?.string(kAXValueAttribute) ?? "").replacingOccurrences(of: "\n", with: ", ").trimmingCharacters(in: .whitespaces)
        return words.isEmpty ? nil : words
    }

    /// "Slide 3 of 9", "title, Results", "notes, Thank everyone".
    nonisolated static func slide(_ n: String, of total: String) -> String { String(localized: "Slide \(n) of \(total)", comment: "A Keynote slide's position") }
    nonisolated static func title(_ words: String) -> String { String(localized: "title, \(words)", comment: "A Keynote slide's title: its words") }
    nonisolated static func notes(_ words: String) -> String { String(localized: "notes, \(words)", comment: "A Keynote slide's presenter notes: their words") }

    private func saySlide() {
        guard let s = selectedSlide() else { return }
        // The title first, whatever order the boxes sit in.
        let items = contents()
        // (The title found by how it was made, not by its words: they may be translated.)
        let titlePrefix = Self.title("")
        let parts = [Self.slide(String(s.index + 1), of: String(s.count))] + items.filter { $0.hasPrefix(titlePrefix) } + items.filter { !$0.hasPrefix(titlePrefix) }
            + (notes().map { [Self.notes($0)] } ?? [])
        Speech.cancel()
        Speech.speakMessage(parts.joined(separator: ", "))
    }

    /// The slide area taking the focus says which slide and what is on it, not just "Slide".
    override func handleEvent(_ event: Event, next: () -> Void) {
        // The show starting: its window takes the focus; the first slide is read.
        if event.kind == .gainFocus || event.kind == .foreground, event.obj.pid == pid, event.obj.element.role == "AXWindow",
           event.obj.element.string(kAXSubroleAttribute) == "AXUnknown" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in if self?.isPlaying() == true { self?.readPlayingSlide() } }
            return
        }
        if event.kind == .gainFocus, event.obj.pid == pid, event.obj.element.role == "AXLayoutArea", selectedSlide() != nil {
            DispatchQueue.main.async { [weak self] in self?.saySlide() }
            return
        }
        next()
    }
}
