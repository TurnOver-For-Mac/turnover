// SPDX-License-Identifier: GPL-3.0-or-later
// Browse mode (NVDA: browseMode.BrowseModeDocumentTreeInterceptor + cursorManager).
//
// In a web document the reader owns a virtual caret: arrows read by line, word
// and character without the page seeing the keys; single letters jump to the
// next heading, link, button, list…; Enter activates what the caret is on. A
// focusable control that gains focus (an edit field) switches to focus mode,
// where keys pass through again; Caps+Space switches by hand; Escape returns.
//
// A browse mode document is a tree interceptor: it answers scripts and sees
// events for every object inside its web area, before the object itself.
import Foundation
import ApplicationServices
import AppKit
import TurnOverAX

// Browse mode: activating what the caret is on, the elements list and the item chooser (NVDA: _activatePosition, elementsList).
extension BrowseModeDocument {
    // MARK: Activation (NVDA: _activatePosition)

    /// `byAccessibility`: VO-Space. The control with the keyboard is pressed through accessibility, as VoiceOver's
    /// VO-Space presses it, where Enter and Space send the real key (below): a page that ignores one answers the other.
    func activate(_ gesture: KeyboardGesture, byAccessibility: Bool = false) {
        var e: AXUIElement? = nil
        if let t = lastQuickNavTarget, buffer.offset(of: t) == position {
            e = BrowseModeDocument.actionable(t) ? t : t.firstDescendant(role: "AXLink", maxVisited: 60) ?? t.firstDescendant(role: "AXButton", maxVisited: 60) ?? t
        } else if let seg = buffer.segment(at: position) {
            e = seg.element
        } else if let i = buffer.lineIndex(at: position) {
            e = buffer.lines[i].element
        }
        // The keyboard moved onto a control after the reading position last did (Tab onto a cookie banner's button,
        // which the buffer did not hold yet): Enter and Space are for that control, not for what the reading position
        // was left on. Enter pressed the policy link before the banner's "Accept all cookies" (10 Oct 2026).
        let controls = ["AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXMenuButton", "AXPopUpButton", "AXMenuItem", "AXTab", "AXDisclosureTriangle", "AXSwitch"]
        if let f = API.focusObject, f.pid == webArea.pid, controls.contains(f.axRole),
           Speech.sinceFocusSpoken < Date().timeIntervalSince(positionMovedAt),
           !(e.map { f.isSameElement(as: $0) } ?? false) {
            let y = f.element
            if byAccessibility, press(nearestTo: y) { return }
            Log.io("browse mode: \(gesture.keyName) to the focused \(f.axRole) (the keyboard moved there after the reading position)")
            let before = ControlState(y)
            gesture.send()
            if ["AXButton", "AXLink", "AXMenuButton"].contains(f.axRole) { Tones.press() }
            watchStateChange(y, before: before)
            return
        }
        guard e != nil else { gesture.send(); return }
        // The control already has the keyboard (Tab took it there): let the real Enter or Space go to the page, as if
        // browse mode were not there. A press through accessibility is a synthetic click, and some pages ignore those:
        // AppleVis's forum Save reported success three times and never posted (4 Oct 2026).
        if let f = API.focusObject, f.pid == webArea.pid, !f.isSameElement(as: webArea) {
            var x = e; var hops = 0
            while let y = x, hops < 6 {
                // (Not a text field: Enter there goes into it to type, below, rather than sending the form.)
                // Only a control: a group, a dialog or the page holding the focus is not "the control already has the
                // keyboard" (Enter on "Accept All" went to the "Privacy Settings" group around it, 10 Oct 2026).
                if f.isSameElement(as: y), controls.contains(y.role), f.role != .passwordEdit {
                    if byAccessibility, press(nearestTo: y) { return }
                    Log.io("browse mode: \(gesture.keyName) to the focused \(y.role) itself")
                    let before = ControlState(y)
                    gesture.send()
                    if ["AXButton", "AXLink", "AXMenuButton"].contains(y.role) { Tones.press() }
                    watchStateChange(y, before: before)
                    return
                }
                x = y.element(kAXParentAttribute); hops += 1
            }
        }
        if press(nearestTo: e) { if let e { enterPlayer(e) }; return }
        // The page rebuilt that part of itself after the buffer was read (AppleVis's Main Menu: its items are made
        // anew when it opens, so "Log out" in the buffer pointed at an element that no longer exists, 3 Oct 2026).
        // Find the live link or button with the line's text and press that.
        let text = lineText(at: position).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, let live = Self.liveActionable(named: text, in: webArea) {
            Log.io("browse mode: \"\(Log.words(text))\" was stale in the buffer; pressing the page's own \(live.role)")
            if press(nearestTo: live) { buffer.build(); clampPosition(); return }
        }
        // What was there, for the log: the buffer's element and its ancestors (alive or gone).
        var chain: [String] = []; var x = e; var d = 0
        while let y = x, d < 6 { chain.append("\(y.role) \"\((y.string(kAXTitleAttribute) ?? y.string(kAXValueAttribute) ?? "").prefix(30))\""); x = y.element(kAXParentAttribute); d += 1 }
        Log.io("browse mode: nothing to activate at \"\(Log.words(String(text.prefix(40))))\"; buffer element: \(chain.isEmpty ? "none" : Log.words(chain.joined(separator: " < "))); live page: \(text.isEmpty ? "not searched" : "no link or button with that text")")
        Speech.speakMessage("nothing to activate")
    }

    /// Whether a control's value is a check state, by TurnOver's own role (the subrole counts: a web switch is an
    /// AXCheckBox or an AXButton with the AXSwitch subrole; a code review, 25 Oct 2026).
    static func isCheckable(_ e: AXUIElement) -> Bool {
        [.checkBox, .radioButton, .switchControl, .toggleButton].contains(Role.from(axRole: e.role, subrole: e.string(kAXSubroleAttribute)))
    }

    /// The keyboard put on `e`, then `done(true)` once the app's own focused element is it, or `done(false)` after a
    /// fifth of a second; looked at by timer, never by holding the main thread (a code review, 25 Oct 2026).
    static func confirmFocus(_ e: AXUIElement, done: @escaping (Bool) -> Void) {
        guard e.set(kAXFocusedAttribute, kCFBooleanTrue) == .success else { done(false); return }
        let app = AXUIElementCreateApplication(e.pid)
        let end = Date().addingTimeInterval(0.2)
        func check() {
            if let f = app.element(kAXFocusedUIElementAttribute), f.isSame(e) { done(true); return }
            if Date() > end { done(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { check() }
        }
        check()
    }
    /// The presses being watched, oldest first. A new press of the same control ends its older watch; presses of
    /// different controls are watched side by side, each named if it is said after the reader moved on (a code
    /// review, 25 Oct 2026, and the maintainer's Tab, Space, Tab, Space along a row of switches). Main thread.
    static var watches: [(element: AXUIElement, id: Int)] = []
    static var lastWatch = 0
    static func beginWatch(_ e: AXUIElement) -> Int {
        lastWatch += 1
        watches.removeAll { $0.element.isSame(e) }
        watches.append((e, lastWatch))
        if watches.count > 6 { watches.removeFirst() }
        return lastWatch
    }
    static func watching(_ id: Int) -> Bool { watches.contains { $0.id == id } }
    static func endWatch(_ id: Int) { watches.removeAll { $0.id == id } }

    /// What a press can change about a control, as the control says it: its value (a check box's 0 or 1, a switch's),
    /// whether it is expanded (a menu button, a disclosure), whether it is selected (a tab, a list item).
    struct ControlState: Equatable {
        var value: Int?, expanded: Bool?, selected: Bool?
        init(_ e: AXUIElement) {
            value = e.int(kAXValueAttribute)
            expanded = (e.attr("AXExpanded") as? NSNumber)?.boolValue
            selected = (e.attr(kAXSelectedAttribute) as? NSNumber)?.boolValue
        }
        /// The control still there: its role can be read. (A control with none of the three states is still there.)
        static func alive(_ e: AXUIElement) -> Bool { (e.attr(kAXRoleAttribute) as? String).map { !$0.isEmpty } ?? false }
    }

    /// A control pressed: its new state said, and the buffer read again, once the page has changed it. A press used
    /// to be followed by nothing at all unless the control was a check box with the focus: Squarespace's switches
    /// (VO-Space said nothing, and the buffer went on saying "off"), the Claude app's Apps button (expanded or
    /// collapsed, never said), 25 Oct 2026. Looked at for three seconds (Squarespace changes a switch two seconds
    /// after the key); said once, the page's own event and this look sharing the de-duplication; a state that can't
    /// be read is never guessed. The reader moving on (Tab to the next control, or the reading position) doesn't
    /// end the watch: a change that lands after that is said with the control's name, so it is clear which one
    /// changed, and the reading position is left where it is.
    func watchStateChange(_ element: AXUIElement, before: ControlState) {
        let watch = Self.beginWatch(element)
        let pressedAt = Date()
        let checkable = Self.isCheckable(element)
        let focusAtPress = API.focusObject?.element
        let urlAtPress = url   // another page since (a link followed, Back): nothing said about the one left
        func look(_ tries: ArraySlice<Double>) {
            guard let next = tries.first else { Self.endWatch(watch); return }
            let delay = max(0, pressedAt.addingTimeInterval(next).timeIntervalSinceNow)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, Self.watching(watch), API.focusTreeInterceptor === self, self.url == urlAtPress else { Self.endWatch(watch); return }
                // Moved on: the reading position moved off the control, or the focus went to another one. (The focus
                // arriving on the pressed control moves the reading position to it: that is not moving on. And the
                // focus is compared with the focus at the press, since in browse mode it is often on another control
                // entirely when the reading position's control is pressed.)
                let onIt = self.buffer.segment(at: self.position)?.element.isSame(element) ?? false
                let positionMoved = self.positionMovedAt > pressedAt && !onIt
                let focusMoved = API.focusObject.map { o in let f = o.element; return !f.isSame(element) && !(focusAtPress.map { f.isSame($0) } ?? false) } ?? false
                let movedOn = positionMoved || focusMoved
                guard ControlState.alive(element) else { self.finishWatch(watch, element, changed: true, movedOn: movedOn); return }   // gone: nothing said
                let now = ControlState(element)
                guard now != before else {
                    if tries.count == 1 { self.finishWatch(watch, element, changed: false, movedOn: movedOn) } else { look(tries.dropFirst()) }
                    return
                }
                // The focus's own expansion and selection events say those for it; only a check state is said for
                // the focus too (pages often change it with no event), de-duplicated with the event. A change that
                // isn't said keeps the watch going, for one that is (a code review, 25 Oct 2026).
                let isFocus = API.focusObject?.element.isSame(element) == true
                let said = movedOn ? ObjectFactory.make(element).name : ""
                let prefix = said.isEmpty ? "" : "\(said), "
                if checkable, let v = now.value, v != before.value {
                    if !Speech.checkStateSpoken(of: element, since: pressedAt) { Speech.speakCheckState(of: element, named: movedOn) }
                } else if let e = now.expanded, e != before.expanded, !isFocus {
                    Speech.speakMessage(prefix + (e ? "expanded" : "collapsed"))
                } else if let sel = now.selected, sel != before.selected, !isFocus {
                    Speech.speakMessage(prefix + (sel ? "selected" : "not selected"))
                } else {
                    if tries.count == 1 { self.finishWatch(watch, element, changed: true, movedOn: movedOn) } else { look(tries.dropFirst()) }
                    return
                }
                self.finishWatch(watch, element, changed: true, movedOn: movedOn)
            }
        }
        look([0.25, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0][...])
    }
    /// The watch over. The buffer is read again now if the control changed, or if this was the last watch running
    /// (one read for several presses, not one each: six builds in a row stalled the keys; a code review, 25 Oct
    /// 2026). Once the reader has moved on, the buffer is only marked stale: the next move reads it again, keeping
    /// the place, where a read now would have put the reading position back at the start of its line.
    private func finishWatch(_ id: Int, _ element: AXUIElement, changed: Bool, movedOn: Bool) {
        Self.endWatch(id)
        if movedOn { buffer.isDirty = true; return }
        if changed || Self.watches.isEmpty { rebuildKeepingPlace(anchor: element) }
    }

    /// NVDA's Elements List (NVDA+F7), VoiceOver's Item Chooser (VO-I): the page's headings, links, form fields,
    /// buttons and landmarks, each kind a submenu in reading order. Enter puts the reading position on the item and
    /// reads it, as quick navigation does; typing a few letters jumps to the item that starts with them.
    func elementsList() {
        refreshIfNavigated()
        if buffer.isDirty { rebuildKeepingPlace() }
        let kinds: [(String, Set<String>)] = [
            ("Headings", ["AXHeading"]),
            ("Links", ["AXLink"]),
            ("Form controls", ["AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXSlider", "AXButton", "AXMenuButton"]),
            ("Landmarks", ["AXLandmark"]),
            ("Tables", ["AXTable"]),
        ]
        var groups: [(name: String, items: [MenuItem])] = []
        for (title, roles) in kinds {
            var items: [MenuItem] = []
            var from = -1
            var seen: [AXUIElement] = []
            while items.count < 500, let (at, el) = buffer.find(from: from, forward: true, roles: roles) {
                from = at
                if seen.contains(where: { $0.isSame(el) }) { continue }
                seen.append(el)
                let label = elementsListLabel(el, at: at, kind: title)
                guard !label.isEmpty else { continue }
                items.append(MenuItem(label, .action { [weak self] in self?.goToListedElement(el, at: at) }))
            }
            groups.append((title, items))
        }
        TurnOverMenu.shared.openRotor(groups)
    }

    func elementsListLabel(_ el: AXUIElement, at: Int, kind: String) -> String {
        // The whole element, not its first wrapped line (a long heading showed cut short in the list, 8 Oct 2026).
        let line: String = {
            guard let i = buffer.lineIndex(at: at) else { return lineText(at: at) }
            let (a, b) = buffer.elementRange(fromLine: i)
            return buffer.text.substring(with: NSRange(location: a, length: max(0, min(b, buffer.text.length) - a)))
        }().replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case "Form controls" where el.role == "AXLink":
            return ""
        case "Headings":
            let level = (el.attr(kAXValueAttribute) as? NSNumber)?.intValue
            let text = el.string(kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 } ?? line
            return text.isEmpty ? "" : text + (level.map { ", level \($0)" } ?? "")
        case "Links":
            if let end = buffer.linkEnd(at: at), end > at, end <= buffer.text.length {
                let t = buffer.text.substring(with: NSRange(location: at, length: end - at)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
            return el.string(kAXTitleAttribute) ?? el.string(kAXDescriptionAttribute) ?? line
        case "Tables":
            let name = el.string(kAXTitleAttribute) ?? el.string(kAXDescriptionAttribute) ?? ""
            var rows: CFIndex = 0
            AXUIElementGetAttributeValueCount(el, kAXRowsAttribute as CFString, &rows)
            return (name.isEmpty ? "table" : "\(name), table") + (rows > 0 ? ", \(rows) rows" : "")
        case "Landmarks":
            let what = el.string(kAXRoleDescriptionAttribute) ?? "landmark"
            let name = el.string(kAXDescriptionAttribute) ?? el.string(kAXTitleAttribute) ?? ""
            return name.isEmpty || name.lowercased() == what.lowercased() ? what : "\(name), \(what)"
        default:
            let obj = ObjectFactory.make(el)
            return Speech.objectPropertiesSpeech(obj, reason: .focus).joined(separator: ", ")
        }
    }

    /// VoiceOver's Item Chooser on a page: every line in reading order (a control with what it is), narrowed as you
    /// type; Enter puts the reading position there and reads it.
    public func openItemChooser() {
        refreshIfNavigated()
        if buffer.isDirty { rebuildKeepingPlace() }
        var items: [MenuItem] = []
        for (j, line) in buffer.lines.enumerated() where line.end > line.start && line.end <= buffer.text.length {
            if buffer.lineContinues(j) { continue }   // a wrapped line's later pieces belong to the entry before
            let (a, b) = buffer.elementRange(fromLine: j)
            let text = buffer.text.substring(with: NSRange(location: a, length: min(b - a, 150))).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let kind = line.isControl ? (line.element?.string(kAXRoleDescriptionAttribute) ?? "") : ""
            let label = kind.isEmpty ? text : "\(text), \(kind)"
            let start = line.start, el = line.element, control = line.isControl
            items.append(MenuItem(label, .action { [weak self] in
                guard let self else { return }
                // A control by its element; text by its own line (a wrapped paragraph's element is its first line).
                if control, let el { goToListedElement(el, at: start) }
                else { position = start; DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.speakQuickNavText(at: start, link: false) } }
            }))
        }
        TurnOverMenu.shared.openChooser("Items", items: items)
    }

    /// The chosen item: the reading position goes there and it is read, as quick navigation does.
    func goToListedElement(_ el: AXUIElement, at: Int) {
        position = buffer.offset(of: el) ?? at
        lastQuickNavTarget = el
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            if BrowseModeDocument.controlRoles.contains(el.role), !(el.role == "AXLink" && buffer.linkEnd(at: position) != nil) {
                Speech.speakMessage(Speech.objectPropertiesSpeech(ObjectFactory.make(el), reason: .focus).joined(separator: ", "))
                lastChain = []
            } else { speakQuickNavText(at: position, link: el.role == "AXLink") }
        }
    }

    /// Read the page again (NVDA's buffer follows the page as it changes) and stay at the same place: on `anchor` if
    /// given, otherwise on the same line's text nearest where it was.
    func rebuildKeepingPlace(anchor: AXUIElement? = nil) {
        let oldLine = lineText(at: position).trimmingCharacters(in: .whitespacesAndNewlines)
        let oldPosition = position
        buffer.build()
        let n = buffer.text.length
        if let a = anchor, let o = buffer.offset(of: a) { position = o; return }
        if !oldLine.isEmpty {
            var best: Int?; var from = 0
            while from < n {
                let r = buffer.text.range(of: oldLine, options: .literal, range: NSRange(location: from, length: n - from))
                if r.location == NSNotFound { break }
                if best == nil || abs(r.location - oldPosition) < abs(best! - oldPosition) { best = r.location }
                from = r.location + max(r.length, 1)
            }
            if let best { position = best; return }
        }
        position = min(oldPosition, max(0, n - 1))
    }

    /// The element or its nearest actionable ancestor is pressed (a text field is entered instead). False if none.
    func press(nearestTo start: AXUIElement?) -> Bool {
        var e = start
        // The element at the caret or its nearest actionable ancestor; a static text or group is never it.
        var depth = 0
        while let x = e, depth < 8 {
            let role = x.role
            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(x, kAXFocusedAttribute as CFString, &settable)
            let focusable = settable.boolValue
            if role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox" || (focusable && role == "AXGroup" && (x.attr("AXEditableAncestor") != nil)) {
                // (The module first: Kindle's fields answer the request with success and do nothing.)
                if !AppModuleHandler.shared.appModule(for: x.pid).takeFocus(x) { _ = x.set(kAXFocusedAttribute, kCFBooleanTrue) }
                setPassThrough(true, announce: true)
                return true
            }
            if BrowseModeDocument.actionable(x) || (focusable && !["AXStaticText", "AXGroup", "AXWebArea", "AXScrollArea", "AXHeading", "AXList", "AXTable", "AXRow", "AXCell"].contains(role)) {
                let before = ControlState(x)
                // A menu button by the keyboard, not by accessibility's press: the Claude app's menus (Radix, common on
                // the web) open on the pointer going down or on a key, never on the click a press sends, so "More
                // options" reported success and opened nothing, and Delete was out of reach (25 Oct 2026). Only once
                // the keyboard is confirmed on it, so the Space can't go to whatever had the focus before; otherwise
                // the press as before. Never both: one activation, so nothing is pressed twice.
                if ["AXPopUpButton", "AXMenuButton"].contains(role) {
                    let activation = Self.beginWatch(x)   // an older watch of this control stops
                    let name = Log.words(x.string(kAXTitleAttribute) ?? x.string(kAXDescriptionAttribute) ?? "")
                    let asked = Date()
                    let focusBefore = API.focusObject?.element
                    Self.confirmFocus(x) { [weak self] confirmed in
                        guard let self, Self.watching(activation), API.focusTreeInterceptor === self else { Self.endWatch(activation); return }
                        Self.endWatch(activation)   // the press watch below is its own entry; none left behind on the ways out
                        // Moved on while the keyboard was being put there (Tab, or the reading position): nothing pressed.
                        let focusNow = API.focusObject?.element
                        let focusMovedElsewhere = focusNow.map { now in !now.isSame(x) && !(focusBefore.map { now.isSame($0) } ?? false) } ?? false
                        let onIt = self.buffer.segment(at: self.position)?.element.isSame(x) ?? false
                        if focusMovedElsewhere || (self.positionMovedAt > asked && !onIt) {
                            Log.io("browse mode: moved on before \(role) \"\(name)\" could be pressed; not pressed")
                            return
                        }
                        if confirmed {
                            Log.io("browse mode: \(role) \"\(name)\" by the keyboard: Space")
                            KeyboardGesture(keyCode: 49, modifiers: [], characters: " ", timestamp: 0, isRepeat: false, flags: []).send()
                        } else {
                            let r = AXUIElementPerformAction(x, kAXPressAction as CFString)
                            Log.io("browse mode: \(role) \"\(name)\": the keyboard didn't reach it; pressed → \(describeError(r))")
                        }
                        Tones.press()
                        self.watchStateChange(x, before: before)
                    }
                    return true
                }
                let r = AXUIElementPerformAction(x, kAXPressAction as CFString)
                Log.io("browse mode: press \(role) \"\(Log.words(x.string(kAXTitleAttribute) ?? x.string(kAXDescriptionAttribute) ?? ""))\" → \(describeError(r))")
                if r == .success {
                    Tones.press()
                    // A press often changes the page without loading another (AppleVis's Main Menu opens its links;
                    // the old copy still had the closed menu's text, with nothing to press, 3 Oct 2026): the watch
                    // reads it again, and says the control's new state (a check box pressed from the page gets no
                    // state event, as it isn't the focus).
                    watchStateChange(x, before: before)
                    return true
                }
            }
            e = x.element(kAXParentAttribute); depth += 1
        }
        return false
    }

    /// A link or button on the live page whose text is `name`.
    static func liveActionable(named name: String, in root: AXUIElement) -> AXUIElement? {   // bounded: it runs only when the buffer failed
        let wanted = name.lowercased()
        var queue = [root]; var visited = 0
        while !queue.isEmpty, visited < 3000 {
            let e = queue.removeFirst(); visited += 1
            let role = e.role
            if ["AXLink", "AXButton", "AXMenuItem", "AXCheckBox", "AXRadioButton", "AXPopUpButton"].contains(role) {
                let own = [e.string(kAXTitleAttribute), e.string(kAXDescriptionAttribute)].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                let inner = e.elements(kAXChildrenAttribute).compactMap { $0.string(kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.joined(separator: " ")
                if own.contains(wanted) || inner == wanted { return e }
            }
            queue.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
        return nil
    }

    static func actionable(_ x: AXUIElement) -> Bool {
        ["AXLink", "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem", "AXImage", "AXDisclosureTriangle"].contains(x.role)
    }


    /// The context menu of the link or control at the reading position (its own AXShowMenu), as if it had been
    /// right-clicked: a link's menu has Open in New Tab, Copy Link and the rest. False when there is nothing that
    /// takes one there (plain text keeps the page's own menu).
    func showContextMenuAtCaret() -> Bool {
        refreshIfNavigated()
        guard let start = (try? rootObject.makeTextInfo(.caret) as? BufferTextInfo)?.element(at: position) else { return false }
        let wanted: Set<String> = ["AXLink", "AXButton", "AXImage", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXMenuButton"]
        var e: AXUIElement? = start; var hops = 0
        while let x = e, hops < 6, !x.isSame(webArea) {
            if wanted.contains(x.role) {
                var names: CFArray?; AXUIElementCopyActionNames(x, &names)
                guard ((names as? [String]) ?? []).contains("AXShowMenu") else { return false }
                let r = AXUIElementPerformAction(x, "AXShowMenu" as CFString)
                Log.io("browse mode: the context menu of the \(x.role) at \(position): \(r.rawValue)")
                if r == .success { TurnOverObject.contextMenuRequestedAt = Date(); return true }
                return false
            }
            e = x.element(kAXParentAttribute); hops += 1
        }
        return false
    }
}
