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

// Browse mode: when keys pass through to the page (focus mode), and when they switch back: the policy, in one place.
extension BrowseModeDocument {
    // MARK: Pass-through (focus mode)

    /// After a rebuild of a page that got shorter, a position past the end left Left and Right saying "top" and
    /// "bottom" for ever (8 Oct 2026).
    func clampPosition() {
        let n = (buffer.text as NSString).length
        if position > n { position = max(0, n - 1) }
    }

    /// Automatic changes use a sound; explicit mode controls retain the navigation-sounds preference.
    public func setPassThrough(_ on: Bool, announce: Bool, playSound: Bool = true, manual: Bool = false) {
        // A by-hand choice of focus mode (Quick Nav off, TurnOver Space) sticks only while focus mode lasts. Leaving it
        // by any other way (a heading key) left the flag set, so F onto the Prompt next switched to nothing and the
        // letters typed were kept from the page (15 Nov 2026, log 2074 to 2082). Every by-hand switch to browse mode
        // already sets it false first; a switch to focus mode sets it itself after this.
        if !on { disableAutoPassThrough = false }
        guard passThrough != on else { return }
        ModeAnnouncement.begin()
        defer { ModeAnnouncement.end() }
        ModeAnnouncement.changed(self, from: passThrough, announce: announce, playSound: playSound, manual: manual)
        passThrough = on
        Log.io("browse mode: \(on ? "focus mode" : "browse mode")\(announce ? "" : " (quietly)")")
    }

    // 14 Nov 2026: observe the sound request in regression tests without playing audio.
    package static var modeSound: (Bool) -> Void = { focus in
        focus ? Tones.focusMode() : Tones.browseMode()
    }

    /// NVDA: shouldPassThrough — an editable or otherwise interactive focus means focus mode.
    public func shouldPassThrough(_ obj: TurnOverObject, caret: Bool = false) -> Bool {
        if disableAutoPassThrough { return passThrough }
        if !(caret ? config.virtualBuffers.autoPassThroughOnCaretMove : config.virtualBuffers.autoFocusMode) { return passThrough }   // NVDA: automatic focus mode off
        if obj.axRole == "AXWebArea" { return false }
        if Self.inPlayerOrApplication(obj.element) { return true }
        let s = obj.states
        if s.contains(.editable) && !s.contains(.unavailable) { return true }
        switch obj.role {
        // A button that opens a menu or a dialog (aria-haspopup) is a button to NVDA, and stays in browse mode; a choice
        // list (a <select>, its options a menu inside it) is a combo box, and goes to focus mode. Tab onto Claude's
        // Model and Permissions buttons went to focus mode, and the F typed next to find the prompt went into it
        // (14 Nov 2026; both say AXPopupValue "menu" and hold no menu until opened).
        case .popUpButton: return !Self.isMenuButton(obj.element)
        case .menuItem, .tab: return !caret
        case .comboBox, .slider, .spinButton, .list, .table, .treeView, .menu, .tabControl: return true
        case .listItem, .treeViewItem: return true   // NVDA's LISTITEM, TREEVIEWITEM
        default:
            // Focus on the text of an option (Safari focuses the text of a search box's suggestion as Down moves
            // through them): the list it is in decides, as if the option had the focus.
            guard !caret, ["AXStaticText", "AXGroup", "AXUnknown"].contains(obj.axRole) else { return false }
            var p = obj.element.element(kAXParentAttribute); var hops = 0
            while let x = p, hops < 6 {
                let r = x.role
                if r == "AXWebArea" { return false }
                if r == "AXComboBox" || r == "AXMenu" || r == "AXListBox" || (r == "AXList" && x.string(kAXSubroleAttribute) != "AXContentList") { return true }
                p = x.element(kAXParentAttribute); hops += 1
            }
            return false
        }
    }

    package struct CaretFocusRequest {
        let id = UUID()
        let started = Date()
        let clicks = caretFocusClicks()
        let element: AXUIElement
        let position: Int
        let page: Int
        let intent: Int
        /// ScriptHandler.supersedingKeysCount when the request was made: the keys that end it are the ones counted
        /// since (16 Nov 2026: this was every key that reached the tap, so a Backspace 8 ms after the Prompt's focus
        /// event, handled a moment after it, ended a request the focus event had just answered).
        let supersedingKeys: Int
        let focusBefore: AXUIElement?
        let expires: Date
        /// An editable field: typing keys that come before its focus event are held for it, not run.
        let editable: Bool
        /// The quick navigation key that made the request. Pressed again, it is a command and is not held.
        let navigation: KeyboardGesture?
        var confirmed = false
    }

    /// The keys held for a request's field (16 Nov 2026): kept here, not on a document, so that a page that goes away
    /// before the request runs out cannot lose them. Main thread.
    struct CaretHold {
        let id: UUID
        var keys: [KeyboardGesture]
        /// Where they were typed (16 Nov 2026, review): they go to this page's field, or run on this page, or nowhere.
        weak var document: BrowseModeDocument?
        let pid: pid_t
        let page: Int
        let field: AXUIElement
        let focusBefore: AXUIElement?
    }
    static var caretHold: CaretHold?

    package static var caretFocusClicks: () -> [UInt32] = {
        [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown].map {
            CGEventSource.counterForEventType(.combinedSessionState, eventType: $0)
        }
    }

    /// NVDA separates CARET from FOCUS settings and honours a manual mode override. Quick navigation
    /// uses this same arrival policy here so a field is ready for typing after its words (14 Nov 2026).
    func caretArrived(_ object: TurnOverObject) {
        // A new caret move ends the older request; keys held for it run as they would have (16 Nov 2026).
        Self.releaseCaretHold(because: "a newer caret move replaced the request for the field")
        if let older = caretFocusRequest { Log.io("browse mode: caret focus on \(older.element.role) replaced by a newer caret move") }
        caretFocusRequest = nil
        newestCaretRequest = nil
        // 14 Nov 2026: the saved copy can be read while its provider is unresponsive. Caret policy
        // includes live player/menu queries and native focus writes, so none is safe on that path.
        guard !pageSilent else { return }
        guard config.virtualBuffers.autoPassThroughOnCaretMove, !disableAutoPassThrough,
              API.focusTreeInterceptor === self, AXHandler.shared.activePid == webArea.pid else { return }
        guard shouldPassThrough(object, caret: true) else { setPassThrough(false, announce: true); return }
        if API.focusObject?.isSameElement(as: object.element) == true {
            setPassThrough(true, announce: true)
            return
        }
        // The quick navigation key is the last key pressed (the page's own copy may be read after it, but any key in
        // between would have ended this move). It may be nil, or not typing, in which case nothing is excluded.
        let navigationKey = InputManager.lastKeyGesture.flatMap { $0.isTypingKeyForCaretFocus ? $0 : nil }
        let editable = object.states.contains(.editable)
        // The tap's gate first, then the count (16 Nov 2026, review): a typing key counted between the two would have been
        // counted under the old gate, and so have ended this request.
        ScriptHandler.setCaretHoldGate(holding: editable, navigation: navigationKey)
        let request = CaretFocusRequest(element: object.element, position: position, page: pageGeneration,
            intent: bufferIntent, supersedingKeys: ScriptHandler.supersedingKeysCount, focusBefore: API.focusObject?.element,
            expires: Date().addingTimeInterval(0.5), editable: editable, navigation: navigationKey)
        caretFocusRequest = request
        newestCaretRequest = request
        outstandingCaretFocus = outstandingCaretFocus.filter { $0.value.page == pageGeneration }
        outstandingCaretFocus[ElementKey(object.element)] = request
        Self.confirmFocus(object.element) { [weak self] confirmed in
            guard let self, let active = caretFocusRequest,
                  active.id == request.id, !active.confirmed else { return }
            // Not a failure of the request: its native event may still come, until it runs out (keys held for it wait).
            guard confirmed, caretFocusIsCurrent(request) else {
                let why = confirmed ? (caretFocusFailure(request) ?? "it was no longer current") : "the application did not report the field focused in time"
                Log.io("browse mode: caret focus on \(request.element.role) not confirmed: \(why)")
                caretFocusRequest = nil
                return
            }
            // Some providers update native focus without posting AXFocusedUIElementChanged.
            // Attach to the already-spoken virtual item; a later native event is consumed once below.
            caretFocusRequest?.confirmed = true
            if newestCaretRequest?.id == request.id { newestCaretRequest?.confirmed = true }
            AXHandler.shared.focusChanged(object.element, pid: webArea.pid)
            // Adopt through the normal focus rules: an ignored or redirected native focus cannot enable typing.
            guard API.focusTreeInterceptor === self,
                  API.focusObject?.isSameElement(as: object.element) == true,
                  let adopted = caretFocusRequest, caretFocusIsCurrent(adopted) else {
                // The focus event itself may have been accepted by the call above, and so have sent the held keys.
                if Self.caretHold?.id == request.id {
                    Log.io("browse mode: caret focus on \(request.element.role) not adopted after the native focus was seen")
                }
                caretFocusRequest = nil
                return
            }
            setPassThrough(true, announce: true)
            ModeAnnouncement.readingReported(self)
            if passThrough {
                Self.deliverCaretHold(request.id)
                // Answered: typing keys go to the field from now on, never held again for it (16 Nov 2026, review).
                if newestCaretRequest?.id == request.id { newestCaretRequest = nil }
            }
        }
    }

    /// Why a request is no longer current, for the log (16 Nov 2026: a Backspace 8 ms after the Prompt's focus event left
    /// browse mode on, and the log had no line for the request that was thrown away). nil when it is current.
    package func caretFocusFailure(_ request: CaretFocusRequest) -> String? {
        if API.focusTreeInterceptor !== self { return "the page no longer has the keyboard" }
        if AXHandler.shared.activePid != webArea.pid { return "the application is no longer in front" }
        if request.page != pageGeneration { return "the page changed" }
        if request.position != position { return "the reading position moved" }
        if request.intent != bufferIntent { return "another command came after it" }
        if request.supersedingKeys != ScriptHandler.supersedingKeysCount { return "a key that is not typing came after it" }
        if Date() >= request.expires { return "it ran out of time" }
        if !config.virtualBuffers.autoPassThroughOnCaretMove || disableAutoPassThrough { return "automatic focus mode is off" }
        if let current = API.focusObject?.element,
           !current.isSame(request.element), request.focusBefore?.isSame(current) != true { return "the focus is on another control" }
        return nil
    }

    /// The keyboard thread's question's answer, on the main thread, asked before any lookup of a key (16 Nov 2026). True:
    /// the key is held for the field whose focus has been asked for, and the caller must not look it up or run it.
    /// False: the key goes on as ever; keys held for an earlier request are first run as the commands they would have been,
    /// so that they come before this key.
    package static func offerKeyToCaretFocus(_ gesture: KeyboardGesture) -> Bool {
        if let page = API.focusTreeInterceptor as? BrowseModeDocument, page.holdKeyForCaretFocus(gesture) { return true }
        releaseCaretHold(because: "a key that is not typing, or the same quick navigation key, came before the field's focus")
        return false
    }

    private func holdKeyForCaretFocus(_ gesture: KeyboardGesture) -> Bool {
        // Not in focus mode (16 Nov 2026, review): once it is on, the keys go to the application, whatever is pending.
        // The quick navigation key is matched by the key alone: Shift F after F is the previous field, a command.
        guard gesture.isTypingKeyForCaretFocus, !passThrough,
              let request = newestCaretRequest, request.editable, !request.confirmed,
              outstandingCaretFocus[ElementKey(request.element)]?.id == request.id,
              request.navigation.map({ $0.keyCode != gesture.keyCode }) ?? true,
              caretFocusIsCurrent(request) else { return false }
        if Self.caretHold?.id != request.id {
            Self.releaseCaretHold(because: "a newer request began")
            Self.caretHold = CaretHold(id: request.id, keys: [], document: self, pid: webArea.pid, page: request.page,
                                       field: request.element, focusBefore: request.focusBefore)
            // The request's own lifetime bounds the hold: when it runs out, the keys run as they would have.
            let id = request.id
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, request.expires.timeIntervalSinceNow) + 0.02) {
                Self.releaseCaretHold(id, because: "the field's focus did not arrive in time")
            }
        }
        Self.caretHold?.keys.append(gesture)
        Log.io("browse mode: a typing key held for the field's focus (\(Self.caretHold?.keys.count ?? 0) held)")
        return true
    }

    /// The field has the focus and focus mode is on: the held keys go to it, in order, once (16 Nov 2026). Main thread.
    /// Each is handled as a key typed in the field then (the review, the same day): its command, if it has one, runs
    /// (Backspace says what it deleted, or bumps in an empty field), and otherwise it is sent on. They take their turn in
    /// the ordered lane (ScriptHandler.queueInOrder), so a key typed meanwhile, already on its way, comes after them.
    static func deliverCaretHold(_ id: UUID) {
        guard let hold = caretHold, hold.id == id else { return }
        caretHold = nil
        if let why = whyHeldKeysCannotGo(hold) { dropHeldKeys(hold, because: why); return }
        Log.io("browse mode: \(hold.keys.count) held typing key(s) sent to the field, which took the focus")
        for key in hold.keys {
            ScriptHandler.queueInOrder(key, lookUp: true, notes: true, masked: true) { _ in
                // Asked again at each key's turn: the field must still have the focus.
                whyHeldKeysCannotGo(hold) ?? (isFieldOrPart(API.focusObject?.element, of: hold.field) ? nil : "the focus is no longer on the field")
            }
        }
    }

    /// The field did not take the focus, or the request ended some other way: the held keys run as they would have, in
    /// order, once (16 Nov 2026). `id` nil is any request's keys. Main thread.
    /// Only on the page they were typed on (the review, the same day), and, unless browse mode's own command, only while
    /// the focus is on the field or on the control it was on when they were typed: never into another field or app.
    package static func releaseCaretHold(_ id: UUID? = nil, because reason: String) {
        guard let hold = caretHold, id == nil || hold.id == id else { return }
        caretHold = nil
        if let why = whyHeldKeysCannotGo(hold) { dropHeldKeys(hold, because: why); return }
        Log.io("browse mode: \(hold.keys.count) held typing key(s) run as ordinary keys: \(reason)")
        for key in hold.keys {
            // Asked at each key's turn. Browse mode's own commands run on the page; anything else (a key sent on, or a
            // command of the focused control, such as a field's Backspace, which sends the key into it) only while the
            // focus is where it was or on the field.
            ScriptHandler.queueInOrder(key, lookUp: true, notes: true, masked: true) { script in
                if let why = whyHeldKeysCannotGo(hold) { return why }
                if let script, script.owner === hold.document { return nil }
                let current = API.focusObject?.element
                if isFieldOrPart(current, of: hold.field) { return nil }
                if let current, hold.focusBefore?.isSame(current) == true { return nil }
                return "the focus has moved to another control"
            }
        }
    }

    /// Why held keys can no longer go anywhere: the page they were typed on no longer has the keyboard (16 Nov 2026,
    /// review). nil: they can.
    static func whyHeldKeysCannotGo(_ hold: CaretHold) -> String? {
        guard let page = hold.document, API.focusTreeInterceptor === page else { return "the page no longer has the keyboard" }
        guard AXHandler.shared.activePid == hold.pid else { return "the application is no longer in front" }
        guard page.pageGeneration == hold.page else { return "the page changed" }
        return nil
    }

    /// Held keys that can go nowhere they were meant for are dropped, said by the edge sound, not typed elsewhere: a
    /// letter typed into another application's field, or run as a command on a page not heard yet, does more harm than
    /// a letter lost, which the sound tells of (16 Nov 2026, review).
    static func dropHeldKeys(_ hold: CaretHold, because reason: String) {
        Log.io("browse mode: \(hold.keys.count) held typing key(s) dropped, typed nowhere: \(reason)")
        Tones.edge()
    }

    /// Whether the focus is on the field, or on a part of it: an element inside it, or an editable element it is inside
    /// (a field's inner element or its wrapper may take the focus for it). Not the page itself.
    static func isFieldOrPart(_ current: AXUIElement?, of field: AXUIElement) -> Bool {
        guard let current else { return false }
        if current.isSame(field) || isWithin(current, field) { return true }
        guard current.role != "AXWebArea", let focus = API.focusObject, focus.element.isSame(current),
              focus.states.contains(.editable) else { return false }
        return isWithin(field, current)
    }

    /// `inner` is a few levels inside `outer`, below the page itself.
    static func isWithin(_ inner: AXUIElement, _ outer: AXUIElement) -> Bool {
        var p = inner.element(kAXParentAttribute); var hops = 0
        while let x = p, hops < 4 {
            if x.isSame(outer) { return true }
            if x.role == "AXWebArea" { return false }
            p = x.element(kAXParentAttribute); hops += 1
        }
        return false
    }

    /// An ordinary focus event in this page while keys are held for a field's focus (16 Nov 2026, review): the focus
    /// came on another element than the one asked for. On the field or a part of it, with focus mode on: the keys go to
    /// it. On another control in focus mode: dropped, never typed into it. In browse mode: they run as they would have.
    /// Back on the control the focus was on before, on the page itself, or in browse mode on an element around the field
    /// or inside it (its own event may follow): still waiting, as the request's lifetime allows.
    func settleCaretHold(afterFocusOn object: TurnOverObject) {
        guard let hold = Self.caretHold, hold.document === self, EventHandler.sameDocumentProcess(object.pid, hold.pid),
              !object.isSameElement(as: webArea) else { return }
        if let before = hold.focusBefore, object.element.isSame(before) { return }
        if !passThrough, Self.isWithin(object.element, hold.field) || Self.isWithin(hold.field, object.element) { return }
        if passThrough, Self.isFieldOrPart(object.element, of: hold.field) {
            Log.io("browse mode: the focus came on a part of the field asked for (\(object.axRole))")
            Self.deliverCaretHold(hold.id)
            if newestCaretRequest?.id == hold.id { newestCaretRequest = nil }
        } else if passThrough {
            Self.caretHold = nil
            Self.dropHeldKeys(hold, because: "the focus went to another control (\(object.axRole)), in focus mode")
        } else {
            Self.releaseCaretHold(hold.id, because: "the focus went to another control, and browse mode stays on")
        }
    }

    private func caretFocusIsCurrent(_ request: CaretFocusRequest) -> Bool {
        guard API.focusTreeInterceptor === self, AXHandler.shared.activePid == webArea.pid,
              request.page == pageGeneration,
              request.position == position, request.intent == bufferIntent,
              request.supersedingKeys == ScriptHandler.supersedingKeysCount, Date() < request.expires,
              config.virtualBuffers.autoPassThroughOnCaretMove, !disableAutoPassThrough else { return false }
        if let current = API.focusObject?.element,
           !current.isSame(request.element), request.focusBefore?.isSame(current) != true { return false }
        return true
    }

    /// nil is ordinary native focus; false consumes an obsolete caret request without following or reporting it.
    func acceptCaretFocus(_ object: TurnOverObject) -> Bool? {
        guard let request = outstandingCaretFocus.removeValue(forKey: ElementKey(object.element)) else { return nil }
        if caretFocusRequest?.id == request.id { caretFocusRequest = nil }
        guard request.page == pageGeneration else {
            // The page changed under the request (16 Nov 2026, review): its held keys are not left waiting.
            Self.releaseCaretHold(request.id, because: "the page changed")
            return nil
        }
        // A provider may never post the requested event. A later deliberate native focus move owns
        // its own event; do not swallow that Tab/click/app return as the old caret's reply. Merely
        // waiting is not a new intent: a late obsolete reply must still leave the reading place alone.
        let nativeTab = InputManager.lastKeyDownAt > request.started &&
            ["kb:tab", "kb:shift+tab"].contains(InputManager.lastKeyIdentifier)
        if nativeTab || Self.lastTabFromCaretAt > request.started ||
           Self.caretFocusClicks() != request.clicks || focusFromOutside {
            Self.releaseCaretHold(request.id, because: "the focus came from a Tab, a click or another application")
            return nil
        }
        guard caretFocusIsCurrent(request) else {
            // SHORTCOMINGS rule 3: the request was thrown away without a word in the log (16 Nov 2026).
            let why = caretFocusFailure(request) ?? "it was no longer current"
            Log.io("browse mode: focus on \(object.element.role) from an earlier caret move is left alone: \(why)")
            Self.releaseCaretHold(request.id, because: why)
            return false
        }
        setPassThrough(shouldPassThrough(object, caret: true), announce: true)
        lastFocusElement = object.element
        positionAtFocus = position
        if let field = object as? EditableText { field.initAutoSelectDetection() }
        if passThrough {
            Self.deliverCaretHold(request.id)
            if newestCaretRequest?.id == request.id { newestCaretRequest = nil }
        } else {
            Self.releaseCaretHold(request.id, because: "focus mode did not go on for the field")
        }
        return true
    }

    /// A pop up button that opens a menu or a dialog, not a list of choices of its own: its AXPopupValue says "menu",
    /// "dialog" or "true", and it holds no options. A <select> holds them: as a menu in WebKit, and as menu items
    /// straight inside it in Chromium, which also says "menu" for it (Codex's review, 14 Nov 2026, from Chromium's
    /// own Mac fixture). Claude's buttons hold their label's text and a picture, or nothing.
    /// Only on what can be read: a button whose children can't be counted, or one of whose children answers no role,
    /// stays a choice list (Codex's second review, 14 Nov 2026).
    package static func isMenuButton(_ e: AXUIElement) -> Bool {
        guard let value = (e.attr("AXPopupValue") as? String)?.lowercased() else { return false }
        guard ["menu", "dialog", "true"].contains(value) else { return false }
        var count: CFIndex = 0
        switch AXUIElementGetAttributeValueCount(e, kAXChildrenAttribute as CFString, &count) {
        case .success: break
        case .noValue, .attributeUnsupported: count = 0   // no children, as the button says
        default: return false   // not answered: not known
        }
        if count == 0 { return true }
        let kids = e.elements(kAXChildrenAttribute)
        guard kids.count == count else { return false }
        for child in kids {
            let r = child.role
            if r == "?" || r.isEmpty { return false }
            if r == "AXMenu" || r == "AXMenuItem" { return false }
        }
        return true
    }

    /// A video player, or an ARIA application, holds the element (WebKit: subrole AXVideo, AXWebApplication; YouTube's
    /// player is a group with the video in it). Its keys are its own (YouTube's J, K and L, 6 Oct 2026), so
    /// the focus there means focus mode, as NVDA does for an application.
    static func inPlayerOrApplication(_ element: AXUIElement) -> Bool {
        // YouTube's video is an empty group described "video playback", a level down inside the player (measured
        // in WebKit, 6 Oct 2026); a <video> with controls has the subrole AXVideo.
        func isVideo(_ e: AXUIElement) -> Bool {
            e.string(kAXSubroleAttribute) == "AXVideo" || e.string(kAXRoleDescriptionAttribute) == "video playback"
        }
        func kids(_ e: AXUIElement, upTo n: Int) -> [AXUIElement] {
            var count: CFIndex = 0
            guard AXUIElementGetAttributeValueCount(e, kAXChildrenAttribute as CFString, &count) == .success, count <= n else { return [] }
            return e.elements(kAXChildrenAttribute)
        }
        var x: AXUIElement? = element; var hops = 0
        while let y = x, hops < 8 {
            if y.role == "AXWebArea" { return false }
            if y.string(kAXSubroleAttribute) == "AXWebApplication" || isVideo(y) { return true }
            if hops > 0, y.role == "AXGroup" {
                if let d = y.string(kAXDescriptionAttribute)?.lowercased(), d.contains("video player") || d.contains("media player") { return true }
                for c in kids(y, upTo: 40) where isVideo(c) || kids(c, upTo: 6).contains(where: isVideo) { return true }
            }
            x = y.element(kAXParentAttribute); hops += 1
        }
        return false
    }

    /// Enter pressed a control in a player (YouTube's Play): the keyboard goes to the player, in focus mode, so its
    /// own keys work at once.
    /// Not with automatic focus mode off, or after a switch by hand: then the mode is the person's to change
    /// (a tester, 15 Oct 2026: Space on YouTube's Play put him in focus mode with the setting off).
    func enterPlayer(_ element: AXUIElement) {
        guard !passThrough, Self.inPlayerOrApplication(element) else { return }
        guard config.virtualBuffers.autoFocusMode, !disableAutoPassThrough else {
            Log.io("browse mode: a player's control pressed; staying in browse mode (automatic focus mode \(config.virtualBuffers.autoFocusMode ? "off by hand" : "off"))")
            return
        }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString, &settable) == .success, settable.boolValue {
            _ = element.set(kAXFocusedAttribute, kCFBooleanTrue)
        }
        setPassThrough(true, announce: true)
    }


    /// Events for objects inside the document (NVDA: tree interceptor event handling).
}
