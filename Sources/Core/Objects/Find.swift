// SPDX-License-Identifier: GPL-3.0-or-later
// Find (VoiceOver's VO-F, NVDA's NVDA+Ctrl+F): TurnOver+F asks what to find; type it, Return jumps to the next
// match and leaves you there, Escape cancels. TurnOver+G and TurnOver+Shift+G find the next and previous match.
// The prompt lives in TurnOver's own key handling (as its menu does), so the application keeps its focus.
// Where it looks: a web page or message in browse mode (its text, from the reading position); text being edited
// (from the caret; the match is selected); anything else (every item's name and value in the window, from the
// current item: the focus moves there if it can take it, otherwise the object navigator does).
import Foundation
import ApplicationServices

// Sendable by hand: the open state and the opening number are behind locks and read from any thread (the keyboard's
// way in, Quick Nav's arrows, the menu); everything else is touched on the main thread only.
public final class FindPrompt: @unchecked Sendable {
    nonisolated public static let shared = FindPrompt()
    /// The open state, the opening number and the last cancellation, behind one lock (19 Nov 2026, Codex's fourth
    /// review): opening and closing each read and write them as one step, so no close can fall between an opening's
    /// check and its being open. Read on the keyboard thread as well. Only state is done under the lock.
    private struct State {
        var isOpen = false
        /// Which opening of the prompt a key was given to (18 Nov 2026, Codex's review): a key is decided on the
        /// keyboard's way in and handled later on the main thread, and in between the prompt can close (Command Tab, an
        /// app switch) or be opened again. A handler acts only on the opening its key was given to, while it is open.
        var generation = 0
        /// When the prompt was last closed, or an opening stopped, on the gestures' clock (mach ticks). TurnOver+F is
        /// decided on the keyboard's way in and opens later on the main thread, behind the script queue; a close in
        /// between (a Quick Nav arrow, an app switch, the menu, the lock, secure input, the reader stopping) found
        /// the prompt still closed, and the opening then came over the new app or took the next letters. An opening
        /// whose key came before the last close does not happen.
        var cancelledAt: UInt64 = 0
        /// The key code of the key that caused the last close, or nil: the same key (same time and code) may open the prompt
        /// again, as TurnOver+F does with Find open; a different key at an equal time may not (19 Nov 2026, Codex).
        var cancelledByKey: Int64? = nil
    }
    private let state = Locked(State())
    public var isOpen: Bool { state.value.isOpen }
    nonisolated public var generation: Int { state.value.generation }
    /// Return or Escape: closed, in one step with the rest of the state, so a close or cancellation at the same moment
    /// is not written over.
    private func finish() { state.lock.lock(); state.unsafeValue.isOpen = false; state.unsafeValue.generation += 1; state.lock.unlock() }
    private var typed = ""
    public package(set) var lastSearch = ""

    /// `pressedAt`: the time of the key that asked for it (its gesture's timestamp); 0 when unknown (the key list, the
    /// menu), which always opens.
    public func open(pressedAt: UInt64 = 0, keyCode: Int64? = nil) {
        state.lock.lock()
        let overtaken = pressedAt != 0 && (pressedAt < state.unsafeValue.cancelledAt
            || (pressedAt == state.unsafeValue.cancelledAt && !(keyCode != nil && keyCode == state.unsafeValue.cancelledByKey)))
        if !overtaken { state.unsafeValue.isOpen = true; state.unsafeValue.generation += 1 }
        state.lock.unlock()
        // Closed before it opened: nothing is said, as for any key that closes it; that key or switch goes on.
        guard !overtaken else { Log.io("find: the prompt not opened (closed after its key)"); return }
        typed = ""
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

    /// The prompt is closed without a search, from any thread: a key it does not take (`keeps`), which then goes on as
    /// it would have; Quick Nav's arrows, which never reach InputManager; another app coming to the front however it
    /// came (Command Tab, the mouse, the Dock), which is also TurnOver's own app giving up the front; TurnOver's menu
    /// opening; the lock, sleep or a user switch; secure input coming on (TurnOver hears no keys then). Any queued key
    /// for this opening is then dropped (`generation`). Nothing is said.
    ///
    /// A close caused by a key passes that key's own time, so the same key may then open the prompt again (TurnOver+F
    /// with Find open closes it and asks to open it with the same time, which is not earlier: 19 Nov 2026, Codex's review).
    ///
    /// Every close also stops an opening asked for before it and not yet made (`open`), as of `arrowAt` (a Quick Nav
    /// arrow's own event time, on the gestures' clock) or else now. The log line is written on the main thread: this is called on the
    /// keyboard's tap, where a stalled log write would hold every key (19 Nov 2026, Codex's review).
    nonisolated package func close(because why: String, arrowAt time: UInt64 = 0, byKey keyCode: Int64? = nil) {
        let at = time != 0 ? time : mach_absolute_time()
        state.lock.lock()
        if at > state.unsafeValue.cancelledAt { state.unsafeValue.cancelledAt = at; state.unsafeValue.cancelledByKey = time != 0 ? keyCode : nil }
        else if at == state.unsafeValue.cancelledAt, state.unsafeValue.cancelledByKey != keyCode { state.unsafeValue.cancelledByKey = nil }
        let wasOpen = state.unsafeValue.isOpen
        if wasOpen { state.unsafeValue.isOpen = false; state.unsafeValue.generation += 1 }
        state.lock.unlock()
        guard wasOpen else { return }
        // The key itself, when there is one, is on the input line that follows (a typed key is never named in the log).
        let line = "find: the prompt closed without a search (\(why))"
        if Thread.isMainThread { Log.io(line) } else { DispatchQueue.main.async { Log.io(line) } }
    }

    /// Every key while the prompt is open that it takes (InputManager routes them here, on the main thread), with the
    /// opening it was given to.
    public func handle(_ g: KeyboardGesture, generation given: Int) {
        // Control or Option with a key is the Mac's (Control Space switches the keyboard language): it goes on, and the
        // next letters come in that language (a tester, 14 Oct 2026: the prompt kept English). Sent even when the
        // prompt has gone since: the key was kept from the Mac for the prompt, and is the Mac's.
        let macKey = !["escape", "enter", "numpadEnter", "backspace"].contains(g.keyName) && !g.modifiers.subtracting(.shift).isEmpty
        if macKey { g.send(); return }
        // A key given to an opening that has closed, or been replaced by a new one: nothing is done with it.
        guard given == generation, isOpen else { return }
        switch g.keyName {
        case "escape":
            finish(); Speech.speakMessage(String(localized: "find cancelled", comment: "Spoken message"))
        case "enter", "numpadEnter":
            finish()
            let s = typed.isEmpty ? lastSearch : typed
            guard !s.isEmpty else { Speech.speakMessage(String(localized: "nothing to find", comment: "Spoken message")); return }
            lastSearch = s
            Self.find(s, forward: true)
        case "backspace":
            if let c = typed.popLast() { Speech.speakSpelling(String(c)) } else { Speech.speakMessage(String(localized: "blank", comment: "Spoken message")) }
        default:
            let ch = Self.typedText(g)
            guard !ch.isEmpty else { return }
            typed += ch
            if ch == " " { Speech.speakMessage(String(localized: "space", comment: "Spoken message")) } else { Speech.speakSpelling(ch) }
        }
    }

    /// What has been typed into the open prompt (tests).
    package var typedSoFar: String { typed }

    /// TurnOver+G / TurnOver+Shift+G.
    public func again(forward: Bool, pressedAt: UInt64 = 0, keyCode: Int64? = nil) {
        guard !lastSearch.isEmpty else { open(pressedAt: pressedAt, keyCode: keyCode); return }
        Self.find(lastSearch, forward: forward)
    }

    // MARK: Searching

    public static func find(_ s: String, forward: Bool) {
        Log.io("find \(forward ? "next" : "previous"): \(Log.words(s))")
        if let d = API.focusTreeInterceptor, !d.passThrough {
            if !d.find(s, forward: forward) { Speech.speakMessage(String(localized: "\(s) not found", comment: "Find found nothing: %@ is what was searched for")); Tones.searchNotFound() }
            return
        }
        if let f = API.caretObject, f.hasNavigableText {
            if !findInText(f, s, forward: forward) { Speech.speakMessage(String(localized: "\(s) not found", comment: "Find found nothing: %@ is what was searched for")); Tones.searchNotFound() }
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
            Speech.speakMessage(String(localized: "\(s) not found", comment: "Find found nothing: %@ is what was searched for")); Tones.searchNotFound(); return
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
                guard let hit else { Speech.speakMessage(String(localized: "\(s) not found", comment: "Find found nothing: %@ is what was searched for")); Tones.searchNotFound(); return }
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
