// SPDX-License-Identifier: GPL-3.0-or-later
// Find (VoiceOver's VO-F, NVDA's NVDA+Ctrl+F): TurnOver+F asks what to find; type it, Return jumps to the next
// match and leaves you there, Escape cancels. TurnOver+G and TurnOver+Shift+G find the next and previous match.
// The prompt lives in TurnOver's own key handling (as its menu does), so the application keeps its focus.
// Where it looks: a web page or message in browse mode (its text, from the reading position); text being edited
// (from the caret; the match is selected); anything else (every item's name and value in the window, from the
// current item: the focus moves there if it can take it, otherwise the object navigator does).
import Foundation
import ApplicationServices

public final class FindPrompt {
    public static let shared = FindPrompt()
    /// Read on the keyboard thread as well; written here, on the main thread.
    private let _isOpen = Locked(false)
    public private(set) var isOpen: Bool { get { _isOpen.value } set { _isOpen.value = newValue } }
    private var typed = ""
    public private(set) var lastSearch = ""

    public func open() {
        typed = ""
        isOpen = true
        Speech.speakMessage(lastSearch.isEmpty ? String(localized: "find", comment: "Find opened") : String(localized: "find, last \(lastSearch)", comment: "Find opened: %@ is the last search"))
    }

    /// Whether the open prompt takes this key: what can be typed into it, Backspace, Return and Escape, and a Control or
    /// Option key it sends on to the Mac while it stays open (Control Space switches the keyboard language). Any other
    /// key (Tab, an arrow, a Command or TurnOver key) leaves the prompt and does what it always does: before, the
    /// prompt took them all and said nothing, and left without Return it stayed open through Command Tab and in every
    /// app, with Tab, the arrows and TurnOver's keys silent until TurnOver was turned off (Oliver, Safari, 17 Nov 2026
    /// at 20:42). Asked on the keyboard's way in (InputManager), before any command is looked up for the key.
    nonisolated package static func keeps(_ g: KeyboardGesture) -> Bool {
        if g.modifiers.contains(.turnover) { return false }
        if g.modifiers.contains(.command) { return false }
        if ["escape", "enter", "numpadEnter", "backspace"].contains(g.keyName) { return true }
        // Control or Option with a key: sent on by the prompt, which stays open (handle, below).
        if !g.modifiers.subtracting(.shift).isEmpty { return true }
        return !typedText(g).isEmpty
    }

    /// What a key types into the prompt: its own character; a synthetic or first key can arrive without one, so the
    /// key's name stands in. Tab, the arrows, the function keys and the like type nothing (an arrow's character is a
    /// private-use one, not a control character, and would have gone into the search).
    nonisolated package static func typedText(_ g: KeyboardGesture) -> String {
        if KeyNames.isSpecial(g.keyCode) { return "" }
        var ch = g.characters
        let hasControl = ch.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        if ch.isEmpty || hasControl {
            ch = g.keyName == "space" ? " " : g.keyName.count == 1 ? g.keyName : ""
            if g.modifiers.contains(.shift) { ch = ch.uppercased() }
        }
        return ch
    }

    /// The prompt is left for a key it does not take (`keeps`), which then goes on as it would have. Any thread: the
    /// keyboard's way in calls it, so the next key already finds the prompt closed.
    nonisolated package func leave() {
        guard _isOpen.value else { return }
        _isOpen.value = false
        // The key itself is on the input line that follows (a typed key is never named in the log).
        Log.io("find: the prompt is left without a search; the next key goes on as it would have")
    }

    /// Every key while the prompt is open that it takes (InputManager routes them here, on the main thread).
    public func handle(_ g: KeyboardGesture) {
        switch g.keyName {
        case "escape":
            isOpen = false; Speech.speakMessage(String(localized: "find cancelled", comment: "Spoken message"))
        case "enter", "numpadEnter":
            isOpen = false
            let s = typed.isEmpty ? lastSearch : typed
            guard !s.isEmpty else { Speech.speakMessage(String(localized: "nothing to find", comment: "Spoken message")); return }
            lastSearch = s
            Self.find(s, forward: true)
        case "backspace":
            if let c = typed.popLast() { Speech.speakSpelling(String(c)) } else { Speech.speakMessage(String(localized: "blank", comment: "Spoken message")) }
        default:
            // Control or Option with a key is the Mac's (Control Space switches the keyboard language): it goes on,
            // and the next letters come in that language (a tester, 14 Oct 2026: the prompt kept English).
            guard g.modifiers.subtracting(.shift).isEmpty else { g.send(); return }
            // A key left behind the prompt by one that closed it (keys queued for the main thread): not typed.
            guard isOpen else { return }
            let ch = Self.typedText(g)
            guard !ch.isEmpty else { return }
            typed += ch
            if ch == " " { Speech.speakMessage(String(localized: "space", comment: "Spoken message")) } else { Speech.speakSpelling(ch) }
        }
    }

    /// TurnOver+G / TurnOver+Shift+G.
    public func again(forward: Bool) {
        guard !lastSearch.isEmpty else { open(); return }
        Self.find(lastSearch, forward: forward)
    }

    // MARK: Searching

    public static func find(_ s: String, forward: Bool) {
        Log.io("find \(forward ? "next" : "previous"): \(Log.words(s))")
        if let d = API.focusTreeInterceptor, !d.passThrough {
            if !d.find(s, forward: forward) { Speech.speakMessage(String(localized: "\(s) not found", comment: "Find found nothing: %@ is what was searched for")) }
            return
        }
        if let f = API.caretObject, f.hasNavigableText {
            if !findInText(f, s, forward: forward) { Speech.speakMessage(String(localized: "\(s) not found", comment: "Find found nothing: %@ is what was searched for")) }
            return
        }
        findInWindow(s, forward: forward)
    }

    /// Text being edited: from the caret; the match is selected and its line read.
    private static func findInText(_ obj: TurnOverObject, _ s: String, forward: Bool) -> Bool {
        guard let caret = try? obj.makeTextInfo(.caret) else { return false }
        let n = caret.storyLength()
        guard n > 0, n < 2_000_000 else { return false }
        let all = caret.textRange(0, n) as NSString
        let from = caret.start
        let r = forward
            ? all.range(of: s, options: .caseInsensitive, range: NSRange(location: min(from + 1, all.length), length: max(0, all.length - min(from + 1, all.length))))
            : all.range(of: s, options: [.caseInsensitive, .backwards], range: NSRange(location: 0, length: min(from, all.length)))
        guard r.location != NSNotFound else { return false }
        caret.setSelectionOffsets(r.location, r.location + r.length)
        if let line = try? obj.makeTextInfo(.bookmark(Bookmark(start: r.location, end: r.location))) {
            line.expand(.line)
            Speech.speakTextInfo(line, unit: .line, reason: .caret)
        }
        return true
    }

    /// Anything else: the window's items in reading order, from the current one; names, descriptions and values.
    /// The walk runs off the main thread (Mail's message list is thousands of elements: walked on the main thread
    /// it froze TurnOver for 5 s and the watchdog stepped in, 3 Oct 2026), one batched query per element, and
    /// stops after 3 seconds.
    private static let walkQueue = DispatchQueue(label: "turnover.find", qos: .userInitiated)

    private static func findInWindow(_ s: String, forward: Bool) {
        guard let f = API.focusObject, let window = f.element.element(kAXWindowAttribute) ?? (f.role == .window ? f.element : nil) else {
            Speech.speakMessage(String(localized: "\(s) not found", comment: "Find found nothing: %@ is what was searched for")); return
        }
        var here = ObjectNavigator.shared.element ?? f.element
        // In a list or table, "here" is the selected row: the next match is after the message you are on.
        if ["AXTable", "AXOutline", "AXList"].contains(here.role), let row = here.elements(kAXSelectedRowsAttribute).first { here = row }
        let needle = s.lowercased()
        let from = here   // fixed for the walk
        walkQueue.async {
            let deadline = Date().addingTimeInterval(3)
            let names = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXChildrenAttribute] as CFArray
            var visited = 0
            /// Whether the element matches, and its children.
            func look(_ e: AXUIElement) -> (Bool, [AXUIElement]) {
                visited += 1
                var values: CFArray?
                guard AXUIElementCopyMultipleAttributeValues(e, names, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
                      let v = values as? [AnyObject], v.count == 4 else { return (false, []) }
                let text = [v[0], v[1], v[2]].compactMap { $0 as? String }.joined(separator: " ").lowercased()
                return (text.contains(needle), (v[3] as? [AXUIElement]) ?? [])
            }
            // An item's own contents are part of it: a row's cells, a button's label. Containers are searched inside.
            let leafRoles: Set<String> = ["AXRow", "AXCell", "AXButton", "AXLink", "AXStaticText", "AXCheckBox", "AXRadioButton", "AXMenuItem", "AXPopUpButton", "AXTextField", "AXTextArea", "AXImage"]
            var hit: AXUIElement?
            if forward {
                // Reading order from just after from: from's inside (for a container), then what follows it, then up.
                var stack: [AXUIElement] = leafRoles.contains(from.role) ? [] : Array(look(from).1.reversed())
                var cur = from
                search: while Date() < deadline {
                    while let e = stack.popLast() {
                        let (m, kids) = look(e)
                        if m { hit = e; break search }
                        if Date() >= deadline { break search }
                        stack.append(contentsOf: kids.reversed())
                    }
                    guard !cur.isSame(window), let parent = cur.element(kAXParentAttribute) else { break }
                    let siblings = parent.elements(kAXChildrenAttribute)
                    if let i = siblings.firstIndex(where: { $0.isSame(cur) }) { stack = Array(siblings[(i + 1)...].reversed()) }
                    cur = parent
                }
            } else {
                // Backwards: the window in reading order up to from, the last match before it.
                var stack: [AXUIElement] = [window]
                while let e = stack.popLast(), Date() < deadline {
                    if e.isSame(from) { break }
                    let (m, kids) = look(e)
                    if m { hit = e }
                    stack.append(contentsOf: kids.reversed())
                }
                // A match inside a row stands for the row: not the row we are on.
            }
            let timedOut = Date() >= deadline
            DispatchQueue.main.async {
                Log.io("find: \(visited) items searched\(timedOut ? ", stopped at 3 s" : "")")
                guard let hit else { Speech.speakMessage(String(localized: "\(s) not found", comment: "Find found nothing: %@ is what was searched for")); return }
                go(to: hit)
            }
        }
    }

    /// Leave the user on the match: a row is selected (a message in Mail's list), anything that can take the focus
    /// takes it (the focus event reads it), otherwise the object navigator goes there and reads it.
    private static func go(to hit: AXUIElement) {
        var chain: [AXUIElement] = [hit]
        var p = hit.element(kAXParentAttribute)
        while let x = p, chain.count < 5 { chain.append(x); p = x.element(kAXParentAttribute) }
        func settable(_ e: AXUIElement, _ a: String) -> Bool {
            var ok: DarwinBoolean = false
            return AXUIElementIsAttributeSettable(e, a as CFString, &ok) == .success && ok.boolValue
        }
        if let row = chain.first(where: { $0.role == "AXRow" }), settable(row, kAXSelectedAttribute),
           row.set(kAXSelectedAttribute, kCFBooleanTrue) == .success {
            if let table = row.element(kAXParentAttribute) { _ = table.set(kAXFocusedAttribute, kCFBooleanTrue) }
            Log.io("find: row selected")
            return
        }
        // A static text is the label inside the thing to reach (a button, a cell, a link): go to that.
        let target = hit.role == "AXStaticText" ? (chain.dropFirst().first(where: { settable($0, kAXFocusedAttribute) }) ?? hit) : hit
        if settable(target, kAXFocusedAttribute), target.set(kAXFocusedAttribute, kCFBooleanTrue) == .success {
            Log.io("find: focus to \(target.role)")
            return
        }
        ObjectNavigator.shared.focusMoved(to: hit, pid: hit.pid)
        ObjectNavigator.shared.reportCurrent()
    }
}
