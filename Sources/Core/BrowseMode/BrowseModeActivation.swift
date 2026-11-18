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
    package func activate(_ gesture: KeyboardGesture, byAccessibility: Bool = false) {
        let voSpaceOrReturn = byAccessibility || ["enter", "numpadEnter"].contains(gesture.keyName)
        Self.activationKeyAt = voSpaceOrReturn ? Date() : .distantPast
        // VO-Space reaches here without a script lookup; Return and Space were refused there already (16 Nov 2026).
        if refuseIfPageOnItsWay(gesture, command: "activatePosition") { return }
        if navigationWaiting ||
           earlyTitleURL != nil {
            if deferInitialContent({ [weak self] in self?.activate(gesture, byAccessibility: byAccessibility) }) { return }
        }
        // A press needs the page itself, and asks it by calls that wait out the timeout each time: on a page that is
        // not answering it is not tried, and that is said (a review, 11 Nov 2026).
        if pageSilent {
            // A control that already has the keyboard still gets the real key: that asks the page nothing, and a
            // page that is not answering accessibility may yet take a key (a review, 11 Nov 2026). Only the control
            // the reader means, as the live path below decides it: the item at the reading position, or one the
            // keyboard moved to after the reading position last moved. Any control with the keyboard was given the
            // key, so a button left behind, the reader since on another, would have been pressed as the page woke (a
            // third review, 12 Nov 2026). What TurnOver already knows of the focus, and the copy of the page, say so;
            // nothing is asked to find out.
            let focus = API.focusObject
            let choice = Self.silentPress(byAccessibility: byAccessibility,
                                          focusRole: focus.flatMap { $0.pid == webArea.pid ? $0.axRole : nil },
                                          focusAtReadingPosition: focus.map { isAtReadingPositionInCopy($0) } ?? false,
                                          keyboardMovedAfterPosition: Speech.sinceFocusSpoken < Date().timeIntervalSince(positionMovedAt))
            if choice == .sendKey {
                Log.io("browse mode: \(gesture.keyName) sent to the control with the keyboard; the page is not answering, so nothing is asked of it")
                gesture.send()
                return
            }
            Log.io("browse mode: \(gesture.keyName) not tried: the page is not answering")
            sayPageNotResponding()
            return
        }
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
            notePressForNavigation(y, role: f.axRole)
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
                    notePressForNavigation(y, role: y.role)
                    if ["AXButton", "AXLink", "AXMenuButton"].contains(y.role) { Tones.press() }
                    watchStateChange(y, before: before)
                    return
                }
                x = y.element(kAXParentAttribute); hops += 1
            }
        }
        if press(nearestTo: e) { if let e { enterPlayer(e) }; return }
        let text = lineText(at: position).trimmingCharacters(in: .whitespacesAndNewlines)
        // Text the page itself takes clicks on, with no link or button made of it: a questionnaire's "Yes" and "No"
        // were plain text in three groups, and Enter, Space and VO-Space all said "nothing to activate"; the form
        // could only be filled in with VoiceOver (Cloud Pharmacy's assessment, 11 Nov 2026). Safari lists a press
        // among the actions of text that is listened to for clicks, on it or on what holds it, and of no other text
        // (Safari 27.2, a test page, 11 Nov 2026), so text nothing listens to still says there is nothing there.
        if pressClickableText(from: e) { return }
        // 17 Nov 2026, VO-Space only (Mail's "Unsubscribe." line, Steam's "Sign in to add…"): VoiceOver stops on a link
        // inside a line as an item of its own, and VO-Space presses it; this copy reads the line whole, so VO-Space
        // looks along the line that was heard. Enter and Space keep NVDA's rule: only what is under the caret.
        let lineIndex = buffer.lineIndex(at: position)
        if byAccessibility, let i = lineIndex, pressOrNameOnLine(i) { return }
        // 17 Nov 2026: VO-Space on plain text says so at once. Recovery is for a control the copy held and the page has
        // since rebuilt (Claude's "Copy code"); plain text never matches one, yet waited out its 150 ms to say so.
        let heldControl = lineIndex.map { i in buffer.lines[i].isControl || !linksOnLine(i).isEmpty } ?? false
        // 14 Nov 2026, Claude: the dead button can be beyond thousands of older messages. Search its cached
        // ancestors and the page's end off main; a single fresh-copy retry shares the key's short deadline.
        if let e, !text.isEmpty,
           !byAccessibility || heldControl {
            activationRecovery.start(document: self, element: e, name: text)
            return
        }
        // What was there, for the log: the buffer's element and its ancestors (alive or gone).
        var chain: [String] = []; var x = e; var d = 0
        while let y = x, d < 6 { chain.append("\(y.role) \"\((y.string(kAXTitleAttribute) ?? y.string(kAXValueAttribute) ?? "").prefix(30))\""); x = y.element(kAXParentAttribute); d += 1 }
        Log.io("browse mode: nothing to activate at \"\(Log.words(String(text.prefix(40))))\"; buffer element: \(chain.isEmpty ? "none" : Log.words(chain.joined(separator: " < "))); live page: \(text.isEmpty ? "not searched" : "no link or button with that text")")
        Speech.speakMessage(String(localized: "nothing to activate", comment: "Spoken message"))
    }

    /// What a press does on a page that is not answering (a review, 11 Nov 2026; a third, 12 Nov 2026): the real key,
    /// for a control on this page that has the keyboard and is the one the reader means, the item at the reading
    /// position or a control the keyboard moved to after the reading position last moved; otherwise nothing is tried.
    /// VO-Space presses through accessibility, which needs the page, and is never tried. Never a text field, where
    /// Return would send its form.
    nonisolated package enum SilentPress: Equatable { case sendKey, notTried }
    /// The controls a real key presses.
    package nonisolated static let pressedByAKey: Set<String> = ["AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXMenuButton", "AXPopUpButton", "AXMenuItem", "AXTab", "AXDisclosureTriangle", "AXSwitch"]
    /// `focusRole`: the role of the control with the keyboard, nil when the keyboard is not on this page.
    package nonisolated static func silentPress(byAccessibility: Bool, focusRole: String?, focusAtReadingPosition: Bool, keyboardMovedAfterPosition: Bool) -> SilentPress {
        guard !byAccessibility, let role = focusRole, pressedByAKey.contains(role) else { return .notTried }
        return focusAtReadingPosition || keyboardMovedAfterPosition ? .sendKey : .notTried
    }

    /// Whether `f` is the item at the reading position, by the copy of the page alone (identity, nothing asked): the
    /// text's own element, its line's, or a container the copy holds around the position.
    func isAtReadingPositionInCopy(_ f: TurnOverObject) -> Bool {
        if let s = buffer.segment(at: position), f.isSameElement(as: s.element) { return true }
        if let i = buffer.lineIndex(at: position), let e = buffer.lines[i].element, f.isSameElement(as: e) { return true }
        return buffer.containers.contains { $0.start <= position && position < $0.end && f.isSameElement(as: $0.element) }
    }

    /// Whether a control's value is a check state, by TurnOver's own role (the subrole counts: a web switch is an
    /// AXCheckBox or an AXButton with the AXSwitch subrole; a code review, 25 Oct 2026).
    static func isCheckable(_ e: AXUIElement) -> Bool {
        [.checkBox, .radioButton, .switchControl, .toggleButton].contains(Role.from(axRole: e.role, subrole: e.string(kAXSubroleAttribute)))
    }

    /// The keyboard put on `e`, then `done(true)` once the app's own focused element is it, or `done(false)` after a
    /// fifth of a second; looked at by timer, never by holding the main thread (a code review, 25 Oct 2026).
    static func confirmFocus(_ e: AXUIElement, deadline: Date = Date().addingTimeInterval(0.2), done: @escaping (Bool) -> Void) {
        guard Date() < deadline else { done(false); return }
        guard e.set(kAXFocusedAttribute, kCFBooleanTrue) == .success else { done(false); return }
        let app = AXUIElementCreateApplication(e.pid)
        func check() {
            guard Date() < deadline else { done(false); return }
            let focused = app.element(kAXFocusedUIElementAttribute)?.isSame(e) == true
            guard Date() < deadline else { done(false); return }
            if focused { done(true); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + min(0.02, max(0, deadline.timeIntervalSinceNow))) { check() }
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
        let keyAtPress = InputManager.lastKeyDownAt
        let speechAtPress = Speech.lastSpoken
        var stateChanged = false
        var acknowledged = false
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
                    if next == 1.0, !acknowledged, element.role == "AXButton" {
                        // 15 Nov 2026 log review: Submit received a native key but no changed state or speech.
                        // Acknowledge only that press, never submission, and never interrupt a later interaction.
                        if !stateChanged, !movedOn, watch == Self.lastWatch,
                           InputManager.lastKeyDownAt == keyAtPress, Speech.lastSpoken == speechAtPress {
                            acknowledged = true
                            Speech.speakMessage(String(localized: "pressed", comment: "Spoken acknowledgement that an activation was sent, not that a form was submitted"))
                        }
                    }
                    if tries.count == 1 { self.finishWatch(watch, element, changed: false, movedOn: movedOn) }
                    else { look(tries.dropFirst()) }
                    return
                }
                stateChanged = true
                // The focus's own expansion and selection events say those for it; only a check state is said for
                // the focus too (pages often change it with no event), de-duplicated with the event. A change that
                // isn't said keeps the watch going, for one that is (a code review, 25 Oct 2026).
                let isFocus = API.focusObject?.element.isSame(element) == true
                let said = movedOn ? ObjectFactory.make(element).name : ""
                let prefix = said.isEmpty ? "" : "\(said), "
                if checkable, let v = now.value, v != before.value {
                    if !Speech.checkStateSpoken(of: element, since: pressedAt) { Speech.speakCheckState(of: element, named: movedOn) }
                } else if let e = now.expanded, e != before.expanded,
                          !(isFocus && Speech.stateSaid(e ? State.expanded.displayString : State.collapsed.displayString, of: element, since: pressedAt)) {
                    // The focus too, unless the page's own event has said it: AppleVis's "Filter posts" sent none, and
                    // "expanded" came a second later, after Oliver had moved on with Tab (14 Nov 2026).
                    let word = e ? State.expanded.displayString : State.collapsed.displayString
                    Speech.noteStateSaid(word, of: element)
                    Speech.speakMessage(prefix + word)
                } else if let sel = now.selected, sel != before.selected, !isFocus {
                    Speech.speakMessage(prefix + (sel ? State.selected.displayString : State.selected.negativeDisplayString))
                } else {
                    if tries.count == 1 { self.finishWatch(watch, element, changed: true, movedOn: movedOn) } else { look(tries.dropFirst()) }
                    return
                }
                self.finishWatch(watch, element, changed: true, movedOn: movedOn)
            }
        }
        look([0.1, 0.25, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0][...])
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
    /// reads it, as quick navigation does; typing a few letters jumps to the item that starts with them. Given a kind,
    /// that kind alone, as JAWS's lists of links, headings and form fields (Insert+F7, F6, F5): Left and Right stay on it.
    func elementsList(only kind: String? = nil) {
        refreshIfNavigated()
        guard ensureContent() else { return }
        if buffer.isDirty { rebuildKeepingPlace() }
        let kinds: [(String, Set<String>)] = [
            ("Headings", ["AXHeading"]),
            ("Links", ["AXLink"]),
            ("Form controls", ["AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXSlider", "AXButton", "AXMenuButton"]),
            ("Landmarks", ["AXLandmark"]),
            ("Tables", ["AXTable"]),
        ].filter { kind == nil || $0.0 == kind }
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
                items.append(MenuItem(verbatim: label, .action { [weak self] in self?.goToListedElement(el, at: at) }))
            }
            // (The kind stays English, as a key; the rotor says it in the reader's language.)
            let names = ["Headings": String(localized: "Headings", comment: "A rotor kind"), "Links": String(localized: "Links", comment: "A rotor kind"),
                         "Form controls": String(localized: "Form controls", comment: "A rotor kind"), "Landmarks": String(localized: "Landmarks", comment: "A rotor kind"),
                         "Tables": String(localized: "Tables", comment: "A rotor kind")]
            groups.append((names[title] ?? title, items))
        }
        if let kind { TurnOverMenu.shared.openChooser(verbatim: groups.first?.name ?? kind, items: groups.first?.items ?? []); return }   // the kind by its translated name
        TurnOverMenu.shared.openRotor(groups)
    }

    func elementsListLabel(_ el: AXUIElement, at: Int, kind: String) -> String {
        buffer.withSnapshot { elementsListLabelInSnapshot(el, at: at, kind: kind) }
    }
    private func elementsListLabelInSnapshot(_ el: AXUIElement, at: Int, kind: String) -> String {
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
            return text.isEmpty ? "" : text + (level.map { ", " + Phrases.level($0) } ?? "")
        case "Links":
            if let end = buffer.linkEnd(at: at), end > at, end <= buffer.text.length {
                let t = buffer.text.substring(with: NSRange(location: at, length: end - at)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
            return el.string(kAXTitleAttribute) ?? el.string(kAXDescriptionAttribute) ?? line
        case "Tables":
            let name = el.string(kAXTitleAttribute) ?? el.string(kAXDescriptionAttribute) ?? ""
            let rows = el.attributeValueCountResult(kAXRowsAttribute).value ?? 0
            return (name.isEmpty ? Role.table.displayString : "\(name), \(Role.table.displayString)") + (rows > 0 ? ", " + String(localized: "\(String(rows)) rows", comment: "A table's size") : "")
        case "Landmarks":
            let what = el.string(kAXRoleDescriptionAttribute) ?? Role.landmark.displayString
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
        guard ensureContent() else { return }
        if buffer.isDirty { rebuildKeepingPlace() }
        var items: [MenuItem] = []
        for (j, line) in buffer.lines.enumerated() where line.end > line.start && line.end <= buffer.text.length {
            if buffer.lineContinues(j) { continue }   // a wrapped line's later pieces belong to the entry before
            let (a, b) = buffer.elementRange(fromLine: j)
            let text = buffer.text.substring(with: NSRange(location: a, length: min(b - a, 150))).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let kind = buffer.withSnapshot { line.isControl ? (line.element?.string(kAXRoleDescriptionAttribute) ?? "") : "" }
            let label = kind.isEmpty ? text : "\(text), \(kind)"
            let start = line.start, el = line.element, control = line.isControl
            items.append(MenuItem(verbatim: label, .action { [weak self] in
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
            let read = { [self] in
                if BrowseModeDocument.controlRoles.contains(el.role), !(el.role == "AXLink" && buffer.linkEnd(at: position) != nil) {
                    Speech.speakMessage(Speech.objectPropertiesSpeech(ObjectFactory.make(el), reason: .focus).joined(separator: ", "))
                    ModeAnnouncement.navigationReported(self, object: ObjectFactory.make(el))
                    lastChain = []
                } else { speakQuickNavText(at: position, link: el.role == "AXLink", element: el) }   // the whole element (19 Nov 2026)
            }
            // Later than the key that chose it: on a page that is not answering, read from the copy like the key.
            if !readFromCopyIfSilent(read) { read() }
        }
    }

    /// Read the page again (NVDA's buffer follows the page as it changes) and stay at the same place: on `anchor` if
    /// given, otherwise on the same line's text nearest where it was.
    func rebuildKeepingPlace(anchor: AXUIElement? = nil) {
        if let anchor { followFocusAfterBuild(anchor, requiresFocus: false) }
        else { buffer.build() }
    }

    /// The key that presses a control when it is pressed by the keyboard and not by accessibility's press.
    public enum KeyboardPress: Equatable { case space, returnKey }

    /// How a control of this role is pressed by the keyboard: Space for a menu button in any app, Return for a role
    /// the app's module names (AppModule.rolesPressedByKeyboard). Nil: accessibility's press, as before.
    public static func keyboardPress(role: String, moduleRoles: Set<String>) -> KeyboardPress? {
        if ["AXPopUpButton", "AXMenuButton"].contains(role) { return .space }
        if moduleRoles.contains(role) { return .returnKey }
        return nil
    }

    /// Whether the person moved on while the keyboard was being put on a control, so that it must not be pressed.
    /// The focus ending up elsewhere counts only when a key arrived meanwhile (a Tab): with no key it is the page's own
    /// answer to the request for the focus, which is no reason to leave the control the person asked for unpressed.
    /// The reading position leaving the control always counts.
    public static func movedOn(focusMovedElsewhere: Bool, keyArrived: Bool, positionLeftIt: Bool) -> Bool {
        positionLeftIt || (focusMovedElsewhere && keyArrived)
    }

    /// When VO-Space or Return last asked browse mode to activate something (distant past for Space and the rest).
    static var activationKeyAt = Date.distantPast
    /// A link or button pressed by VO-Space or Return, with the window of its page, for the focus rules: Safari's
    /// nameless page host taking the focus just after is the page changing, not a move (18 Nov 2026). Used once.
    package static var lastNavigationPress: (window: AXUIElement, pid: pid_t, at: Date)?

    func notePressForNavigation(_ x: AXUIElement, role: String) {
        guard role == "AXLink" || role == "AXButton" else { return }
        guard Date().timeIntervalSince(Self.activationKeyAt) < 2 else { return }
        guard let window = x.element(kAXWindowAttribute) ?? webArea.element(kAXWindowAttribute) else { return }
        Self.lastNavigationPress = (window, webArea.pid, Date())
    }

    /// True means an activation started; completion reports whether it actually sent a key or pressed.
    /// Recovery supplies its absolute deadline, shared by focus confirmation and the final action.
    func press(nearestTo start: AXUIElement?, deadline: Date? = nil, valid: @escaping () -> Bool = { true },
               completion: @escaping (Bool) -> Void = { _ in }) -> Bool {
        guard valid() else { return false }
        var e = start
        // The element at the caret or its nearest actionable ancestor; a static text or group is never it.
        var depth = 0
        while let x = e, depth < 8 {
            let role = x.role
            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(x, kAXFocusedAttribute as CFString, &settable)
            let focusable = settable.boolValue
            if role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox" || (focusable && role == "AXGroup" && (x.attr("AXEditableAncestor") != nil)) {
                guard valid() else { return false }
                // (The module first: Kindle's fields answer the request with success and do nothing.)
                if !AppModuleHandler.shared.appModule(for: x.pid).takeFocus(x) { _ = x.set(kAXFocusedAttribute, kCFBooleanTrue) }
                setPassThrough(true, announce: true)
                completion(true)
                return true
            }
            if BrowseModeDocument.actionable(x) || (focusable && !["AXStaticText", "AXGroup", "AXWebArea", "AXScrollArea", "AXHeading", "AXList", "AXTable", "AXRow", "AXCell"].contains(role)) {
                let before = ControlState(x)
                // A menu button by the keyboard, not by accessibility's press: the Claude app's menus (Radix, common on
                // the web) open on the pointer going down or on a key, never on the click a press sends, so "More
                // options" reported success and opened nothing, and Delete was out of reach (25 Oct 2026). Only once
                // the keyboard is confirmed on it, so the Space can't go to whatever had the focus before; otherwise
                // the press as before. Never both: one activation, so nothing is pressed twice.
                // The same for a role the app's module names, with Return: the Claude app's buttons, whose press
                // reported success and did nothing (11 Nov 2026; ClaudeAppModule.rolesPressedByKeyboard).
                let moduleRoles = AppModuleHandler.shared.appModule(for: x.pid).rolesPressedByKeyboard
                if let key = Self.keyboardPress(role: role, moduleRoles: moduleRoles) {
                    let activation = Self.beginWatch(x)   // an older watch of this control stops
                    let name = Log.words(x.string(kAXTitleAttribute) ?? x.string(kAXDescriptionAttribute) ?? "")
                    let asked = Date()
                    let keysBefore = ScriptHandler.keysArrivedCount
                    let focusBefore = API.focusObject?.element
                    guard valid() else { return false }
                    Self.confirmFocus(x, deadline: deadline ?? Date().addingTimeInterval(0.2)) { [weak self] confirmed in
                        guard let self, Self.watching(activation), API.focusTreeInterceptor === self else {
                            Self.endWatch(activation); completion(false); return
                        }
                        Self.endWatch(activation)   // the press watch below is its own entry; none left behind on the ways out
                        guard valid() else { completion(false); return }
                        // Moved on while the keyboard was being put there (Tab, or the reading position): nothing pressed.
                        let focusNow = API.focusObject?.element
                        let focusMovedElsewhere = focusNow.map { now in !now.isSame(x) && !(focusBefore.map { now.isSame($0) } ?? false) } ?? false
                        let onIt = self.buffer.segment(at: self.position)?.element.isSame(x) ?? false
                        let keyArrived = ScriptHandler.keysArrivedCount != keysBefore
                        if Self.movedOn(focusMovedElsewhere: focusMovedElsewhere, keyArrived: keyArrived, positionLeftIt: self.positionMovedAt > asked && !onIt) {
                            Log.io("browse mode: moved on before \(role) \"\(name)\" could be pressed; not pressed")
                            completion(false)
                            return
                        }
                        if focusMovedElsewhere {
                            // No key came and the reading position stayed: the page moved the focus itself in answer to
                            // the request (the Claude app puts it on the first rating button when a code block's Copy
                            // or Run button cannot take it, 15 Nov 2026), so it is not the person moving on.
                            Log.io("browse mode: the focus went elsewhere on its own after the request for \(role) \"\(name)\"; pressing it")
                        }
                        if confirmed {
                            switch key {
                            case .space:
                                Log.io("browse mode: \(role) \"\(name)\" by the keyboard: Space")
                                KeyboardGesture(keyCode: 49, modifiers: [], characters: " ", timestamp: 0, isRepeat: false, flags: []).send()
                            case .returnKey:
                                Log.io("browse mode: \(role) \"\(name)\" by the keyboard: Return")
                                KeyboardGesture(keyCode: 36, modifiers: [], characters: "\r", timestamp: 0, isRepeat: false, flags: []).send()
                            }
                        } else {
                            let r = AXUIElementPerformAction(x, kAXPressAction as CFString)
                            Log.io("browse mode: \(role) \"\(name)\": the keyboard didn't reach it; pressed → \(describeError(r))")
                            guard r == .success else { completion(false); return }
                        }
                        Tones.press()
                        self.notePressForNavigation(x, role: role)
                        self.watchStateChange(x, before: before)
                        completion(true)
                    }
                    return true
                }
                guard valid() else { return false }
                let r = AXUIElementPerformAction(x, kAXPressAction as CFString)
                Log.io("browse mode: press \(role) \"\(Log.words(x.string(kAXTitleAttribute) ?? x.string(kAXDescriptionAttribute) ?? ""))\" → \(describeError(r))")
                if r == .success {
                    Tones.press()
                    notePressForNavigation(x, role: role)
                    // A press often changes the page without loading another (AppleVis's Main Menu opens its links;
                    // the old copy still had the closed menu's text, with nothing to press, 3 Oct 2026): the watch
                    // reads it again, and says the control's new state (a check box pressed from the page gets no
                    // state event, as it isn't the focus).
                    watchStateChange(x, before: before)
                    completion(true)
                    return true
                }
            }
            e = x.element(kAXParentAttribute); depth += 1
        }
        return false
    }

    /// Which of the element at the reading position and what holds it, nearest first, the page takes a click on:
    /// the first that lists a press, before the page itself is reached and no more than six up. Nil when none does.
    public static func clickableText(in chain: [(role: String, actions: [String])]) -> Int? {
        for (i, x) in chain.prefix(6).enumerated() {
            if x.role == "AXWebArea" || x.role == "AXScrollArea" { return nil }
            if x.actions.contains(kAXPressAction as String) { return i }
        }
        return nil
    }

    /// Text at the reading position that the page takes clicks on is pressed. False when there is none.
    func pressClickableText(from start: AXUIElement?) -> Bool {
        var elements: [AXUIElement] = []; var chain: [(role: String, actions: [String])] = []
        var e = start
        while let x = e, chain.count < 6 {
            var names: CFArray?; AXUIElementCopyActionNames(x, &names)
            elements.append(x); chain.append((x.role, (names as? [String]) ?? []))
            if x.isSame(webArea) { break }
            e = x.element(kAXParentAttribute)
        }
        guard let i = Self.clickableText(in: chain) else { return false }
        let x = elements[i]
        let before = ControlState(x)
        let r = AXUIElementPerformAction(x, kAXPressAction as CFString)
        Log.io("browse mode: press the clickable \(chain[i].role) at the reading position\(i > 0 ? ", \(i) above it" : "") → \(describeError(r))")
        guard r == .success else { return false }
        Tones.press()
        watchStateChange(x, before: before)   // the page is read again: a chosen answer often changes what follows
        return true
    }

    /// The copy's link pieces on line i, as heard: the wrapped piece, not the whole paragraph (17 Nov 2026).
    func linksOnLine(_ i: Int) -> [WebBuffer.Segment] {
        let line = buffer.lines[i]
        return buffer.segments.filter { $0.isLink && $0.start < line.end && $0.end > line.start }
    }

    /// VO-Space on a line of text (17 Nov 2026). True when it was dealt with: the one link or control on the line
    /// pressed, or several named and none pressed, since a guess could act unwanted. With none, the field a label on
    /// the line names, only as the page itself pairs them (AXServesAsTitleForUIElements, as VO-J reads it).
    func pressOrNameOnLine(_ i: Int) -> Bool {
        let line = buffer.lines[i]
        let pieces = buffer.segments.filter { $0.start < line.end && $0.end > line.start }
        var found: [(element: AXUIElement, name: String)] = []
        for s in pieces {
            // The piece itself or what holds it, two levels up: a link's text, or its text in a span. A picture is
            // not a control of its own; the link around it is.
            var x: AXUIElement? = s.element; var hops = 0
            while let y = x, hops < 3, !(Self.actionable(y) && y.role != "AXImage") { x = y.element(kAXParentAttribute); hops += 1 }
            guard let c = x, hops < 3 else { continue }
            let heard = buffer.text.substring(with: NSRange(location: max(s.start, line.start), length: min(s.end, line.end) - max(s.start, line.start)))
            if let k = found.firstIndex(where: { $0.element.isSame(c) }) { found[k].name += heard } else { found.append((c, heard)) }
        }
        var kind = found.allSatisfy { $0.element.role == "AXLink" } ? "links" : "controls"
        if found.isEmpty {
            for s in pieces where s.element.role == "AXStaticText" {
                for f in s.element.elements("AXServesAsTitleForUIElements") where f.role != "?" && !found.contains(where: { $0.element.isSame(f) }) {
                    found.append((f, f.string(kAXTitleAttribute) ?? f.string(kAXDescriptionAttribute) ?? f.string(kAXPlaceholderValueAttribute) ?? ""))
                }
            }
            kind = "fields"
        }
        if found.count == 1 {
            Log.io("browse mode: VO-Space on a line with one \(kind == "fields" ? "labelled field" : "control"): \(found[0].element.role) \"\(Log.words(found[0].name))\"")
            return press(nearestTo: found[0].element)
        }
        guard found.count > 1 else { return false }
        let names = found.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: ", ")
        Log.io("browse mode: VO-Space on a line with \(found.count) \(kind); none pressed: \(Log.words(names))")
        let n = found.count
        switch kind {
        case "links": Speech.speakMessage(String(localized: "\(n) links: \(names)", comment: "VO-Space on a line holding several links, none pressed: how many, then their names"))
        case "fields": Speech.speakMessage(String(localized: "\(n) fields: \(names)", comment: "VO-Space on a label for several fields, none acted on: how many, then their names"))
        default: Speech.speakMessage(String(localized: "\(n) controls: \(names)", comment: "VO-Space on a line holding several controls, none pressed: how many, then their names"))
        }
        return true
    }

    static func actionable(_ x: AXUIElement) -> Bool {
        ["AXLink", "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem", "AXImage", "AXDisclosureTriangle"].contains(x.role)
    }


    /// The context menu of the link or control at the reading position (its own AXShowMenu), as if it had been
    /// right-clicked: a link's menu has Open in New Tab, Copy Link and the rest. False when there is nothing that
    /// takes one there (plain text keeps the page's own menu).
    func showContextMenuAtCaret() -> Bool {
        guard !pageSilent else { return false }
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
