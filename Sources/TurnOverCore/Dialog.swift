// SPDX-License-Identifier: GPL-3.0-or-later
// Dialogs: a window or sheet that reads its text when it opens (NVDA: Dialog).
// Behaviours (NVDA: NVDAObjects.behaviors): the object classes every application shares; app modules subclass them.
import Foundation
import ApplicationServices
import AppKit
import TurnOverAX

/// A dialog or sheet (NVDA: behaviors.Dialog): when the focus enters it, its name
/// and the text it shows are read, so the user hears the question before the button.
open class Dialog: TurnOverObject {
    open override var role: Role { .dialog }
    open override var isPresentableFocusAncestor: Bool { true }
    /// What TurnOver+Tab / VO-F3 adds after "dialog": its text and its choices, as when it opened.
    open override var description: String? {
        let list = choices.map(\.1)
        let parts = [dialogText] + (list.isEmpty ? [] : ["\(list.count) choice\(list.count == 1 ? "" : "s"): " + list.joined(separator: ", ")])
        let t = parts.filter { !$0.isEmpty }.joined(separator: ", ")
        return t.isEmpty ? nil : t
    }

    static let containerRoles: Set<String> = ["AXGroup", "AXScrollArea", "AXSplitGroup", "AXLayoutArea", "AXToolbar", "AXTabGroup", "AXList", "AXUnknown", "AXCell", "AXRow"]

    private static func pressable(_ e: AXUIElement) -> Bool {
        var acts: CFArray?
        AXUIElementCopyActionNames(e, &acts)
        return ((acts as? [String]) ?? []).contains("AXPress")
    }
    private static func isReadOnlyText(_ e: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(e, kAXValueAttribute as CFString, &settable)
        return !settable.boolValue
    }

    /// NVDA's getDialogText: the dialog's message, from static text and read-only text areas (TV's notification
    /// sheet keeps its message in AXTextAreas), leaving out labels of controls and the choices themselves.
    open var dialogText: String {
        var texts: [String] = []
        var labels = Set<String>()
        let choiceNames = Set(choices.map(\.1))
        var queue = element.elements(kAXChildrenAttribute)
        var visited = 0
        while !queue.isEmpty, visited < 600, texts.count < 16 {
            let e = queue.removeFirst(); visited += 1
            let r = e.role
            if r == "AXStaticText" {
                // Its value, or (iPad-style apps: Podcasts' "Get Notified About New Episodes" sheet, 7 Oct 2026) its
                // description: the sheet said only "dialog".
                let v = [e.string(kAXValueAttribute), e.string(kAXDescriptionAttribute)].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
                if let v, !choiceNames.contains(v), !texts.contains(v) { texts.append(v) }
            } else if (r == "AXTextArea" || r == "AXTextField"), Self.isReadOnlyText(e) {
                if let v = e.string(kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty, !texts.contains(v) { texts.append(v) }
            } else if r == "AXTable" || r == "AXScrollArea" && e.elements(kAXChildrenAttribute).first?.role == "AXTable" {
                // A small table of figures (Word's Word Count: "Pages 1", "Words 11"…): each row as one line.
                let table = r == "AXTable" ? e : e.elements(kAXChildrenAttribute)[0]
                for row in table.elements(kAXRowsAttribute).prefix(20) {
                    let cells = row.elements(kAXChildrenAttribute).compactMap { c -> String? in
                        let v = (c.string(kAXValueAttribute) ?? c.string(kAXTitleAttribute) ?? ObjectFactory.make(c).name).trimmingCharacters(in: .whitespacesAndNewlines)
                        return v.isEmpty ? nil : v
                    }
                    if !cells.isEmpty { texts.append(cells.joined(separator: " ")) }
                }
            } else if Self.containerRoles.contains(r) {
                queue.append(contentsOf: e.elements(kAXChildrenAttribute))
            } else if let l = e.element(kAXTitleUIElementAttribute)?.string(kAXValueAttribute) { labels.insert(l.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        return texts.filter { !labels.contains($0) }.joined(separator: ", ")
    }

    /// What can be chosen in the dialog, in order: buttons and the other controls, and text the dialog makes into a
    /// choice (TV's "Not Now" is a static text in its own group beside the "Enable Notifications" button).
    open var choices: [(AXUIElement, String)] {
        var out: [(AXUIElement, String)] = []
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard depth < 12, out.count < 40 else { return }
            for c in e.elements(kAXChildrenAttribute) {
                let r = c.role, sub = c.string(kAXSubroleAttribute) ?? ""
                if ["AXCloseButton", "AXZoomButton", "AXMinimizeButton", "AXFullScreenButton"].contains(sub) { continue }
                if (c.attr(kAXEnabledAttribute) as? Bool) == false, r != "AXStaticText" { continue }
                switch r {
                case "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXLink":
                    let n = [c.string(kAXTitleAttribute), c.string(kAXDescriptionAttribute)].compactMap { $0 }.first { !$0.isEmpty } ?? ElementMatcher.text(of: c)
                    if !n.isEmpty { out.append((c, n)) }
                case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField":
                    if !Self.isReadOnlyText(c) { out.append((c, c.string(kAXDescriptionAttribute) ?? c.string(kAXPlaceholderValueAttribute) ?? "edit")) }
                case "AXStaticText":
                    // A lone text in its own unknown or group wrapper, beside the buttons: a choice, not message.
                    if let p = c.element(kAXParentAttribute), ["AXUnknown"].contains(p.role) || Self.pressable(c),
                       let v = c.string(kAXValueAttribute), !v.isEmpty, v.count < 40 { out.append((c, v)) }
                default:
                    walk(c, depth + 1)
                }
            }
        }
        walk(element, 0)
        return out
    }

    /// Everything to read in the dialog, in order: its texts and its choices (Up and Down go through these; Tab only
    /// through the choices). A dialog that is more a page than a question (the App Store's account sheet: a title,
    /// a list of settings, "Cannot Connect … Retry") was only its buttons before (7 Oct 2026).
    open var items: [(AXUIElement, String, Bool)] {
        let choiceList = choices
        var out: [(AXUIElement, String, Bool)] = []
        func isChoice(_ e: AXUIElement) -> String? { choiceList.first { $0.0.isSame(e) }?.1 }
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard depth < 12, out.count < 80 else { return }
            for c in e.elements(kAXChildrenAttribute) {
                if let n = isChoice(c) { out.append((c, n, true)); continue }
                if c.role == "AXStaticText" {
                    if let v = c.string(kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty, !out.contains(where: { $0.1 == v }) { out.append((c, v, false)) }
                    continue
                }
                if c.role == "AXBusyIndicator" { out.append((c, c.string(kAXDescriptionAttribute) ?? "loading", false)); continue }
                walk(c, depth + 1)
            }
        }
        walk(element, 0)
        // Choices the walk did not meet (an unusual nesting) still count.
        for c in choiceList where !out.contains(where: { $0.0.isSame(c.0) }) { out.append((c.0, c.1, true)) }
        return out
    }
    static var lineIndex: [Int: Int] = [:]

    static var spokenAt: (AXUIElement, Date)?
    static var choiceIndex: [Int: Int] = [:]

    private func announce(choicesToo: Bool) {
        if let (e, at) = Self.spokenAt, e.isSame(element), Date().timeIntervalSince(at) < 0.8 { return }
        Self.spokenAt = (element, Date())
        let list = choices.map(\.1)
        var parts = [name, role.displayString, dialogText].filter { !$0.isEmpty }
        if choicesToo, !list.isEmpty { parts.append("\(list.count) choice\(list.count == 1 ? "" : "s"): " + list.joined(separator: ", ")) }
        Speech.speakMessage(parts.joined(separator: ", "))
    }

    open override func event_focusEntered() {
        // Moving between the groups inside a dialog enters it again (Word's save sheet, on every Tab): once is enough.
        // (Word passes the focus through the document behind the sheet on its way, so it is "entered" afresh.)
        if let (e, at) = Self.spokenAt, e.isSame(element), Date().timeIntervalSince(at) < 60 { return }
        announce(choicesToo: false)
    }

    /// The dialog itself has the focus (no control in it does): read it, with its choices, and let the keys move
    /// among the choices.
    open override func event_gainFocus() {
        // Safari's bookmark sheet takes the focus itself for a moment between each of its fields: already read, say nothing.
        if let (e, at) = Self.spokenAt, e.isSame(element), Date().timeIntervalSince(at) < 60 { return }
        // A web page inside the dialog (an account page): read it as a page, in browse mode.
        if let web = element.firstDescendant(role: "AXWebArea", maxVisited: 400) {
            Self.spokenAt = (element, Date())
            Speech.speakMessage([name, role.displayString].filter { !$0.isEmpty }.joined(separator: ", "))
            let pid = element.pid
            DispatchQueue.main.async { AXHandler.shared.focusChanged(web, pid: pid) }
            return
        }
        announce(choicesToo: true)
    }

    open override func initOverlay() {
        super.initOverlay()
        let cat = "Dialogs"
        for (key, delta) in [("tab", 1), ("shift+tab", -1), ("rightArrow", 1), ("leftArrow", -1)] {
            script("dialog_choice_\(key)", "Moves between the dialog's choices", gestures: ["kb:\(key)"], category: cat) { [weak self] _ in self?.moveChoice(delta) }
                .isAvailable = { [weak self] in !(self.map { SystemPrompts.isProtected($0.element.pid) } ?? false) }
        }
        for (key, delta) in [("downArrow", 1), ("upArrow", -1)] {
            script("dialog_line_\(key)", "Reads the dialog line by line: its text and its choices", gestures: ["kb:\(key)"], category: cat) { [weak self] _ in self?.moveLine(delta) }
        }
        script("dialog_press", "Presses the dialog's choice", gestures: ["kb:enter", "kb:numpadEnter", "kb:space"], category: cat) { [weak self] g in self?.pressChoice(g) }
            .isAvailable = { [weak self] in !(self.map { SystemPrompts.isProtected($0.element.pid) } ?? false) }
        script("dialog_cancel", "Cancels the dialog", gestures: ["kb:escape"], category: cat) { [weak self] g in self?.cancel(g) }
    }

    private var key: Int { Int(CFHash(element)) }

    private func moveLine(_ delta: Int) {
        let all = items
        guard !all.isEmpty else { Speech.speakMessage("empty"); return }
        // Start from the choice Tab is on, if any.
        let fromChoice = Self.choiceIndex[key].flatMap { ci -> Int? in let ch = choices; return ch.indices.contains(ci) ? all.firstIndex { $0.0.isSame(ch[ci].0) } : nil }
        let cur = Self.lineIndex[key] ?? fromChoice
        let next = cur.map { min(max(0, $0 + delta), all.count - 1) } ?? (delta > 0 ? 0 : all.count - 1)
        if let cur, next == cur { Tones.edge(keySent: true) }
        Self.lineIndex[key] = next
        let (e, n, isChoice) = all[next]
        if isChoice, let ci = choices.firstIndex(where: { $0.0.isSame(e) }) { Self.choiceIndex[key] = ci } else { Self.choiceIndex[key] = nil }
        let kind = isChoice ? (e.role == "AXStaticText" ? "button" : ObjectFactory.make(e).role.displayString) : ""
        Speech.speakMessage(kind.isEmpty ? n : "\(n), \(kind)")
    }

    private func moveChoice(_ delta: Int) {
        let all = choices
        guard !all.isEmpty else { Speech.speakMessage("no choices"); return }
        let cur = Self.choiceIndex[key]
        let next = cur.map { ($0 + delta + all.count) % all.count } ?? (delta > 0 ? 0 : all.count - 1)
        Self.choiceIndex[key] = next
        Self.lineIndex[key] = nil
        let (e, n) = all[next]
        let kind = e.role == "AXStaticText" ? "button" : ObjectFactory.make(e).role.displayString
        Speech.speakMessage("\(n), \(kind), \(next + 1) of \(all.count)")
        // VO-Space and NVDA+Enter press what the review cursor is on: keep it on the choice Tab reached. (Tab said
        // "Allow" and VO-Space pressed something else, so macOS's audio permission prompt stayed up, 12 Oct 2026.)
        ObjectNavigator.shared.place(e)
    }

    private func press(_ e: AXUIElement) -> Bool {
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(e.role) { return e.set(kAXFocusedAttribute, kCFBooleanTrue) == .success }
        var x: AXUIElement? = e
        var hops = 0
        while let y = x, hops < 4 {   // the text, or the group holding it, takes the press
            if AXUIElementPerformAction(y, kAXPressAction as CFString) == .success { Tones.press(); return true }
            x = y.element(kAXParentAttribute); hops += 1
            if x?.role == "AXSheet" || x?.role == "AXWindow" { break }
        }
        return false
    }

    private func pressChoice(_ g: KeyboardGesture) {
        let all = choices
        guard let i = Self.choiceIndex[key], all.indices.contains(i) else {
            // No choice picked yet: Return is the dialog's default button, as always.
            g.send(); return
        }
        let (e, n) = all[i]
        if press(e) { Log.io("dialog: pressed \(Log.words(n))"); SystemPrompts.checkPress(of: e, name: n) }
        else if ["not now", "cancel", "close", "no", "don’t allow", "don't allow", "later"].contains(n.lowercased()) { cancel(g) }
        else { Speech.speakMessage("\(n) cannot be pressed") }
    }

    private func cancel(_ g: KeyboardGesture) {
        let all = choices
        if let (e, n) = all.first(where: { ["cancel", "not now", "close", "no", "don’t allow", "don't allow", "later"].contains($0.1.lowercased()) }), press(e) {
            Log.io("dialog: cancelled with \(Log.words(n))"); return
        }
        if AXUIElementPerformAction(element, kAXCancelAction as CFString) == .success { return }
        g.send()
    }
}
