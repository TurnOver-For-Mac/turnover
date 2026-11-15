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

    struct CaretFocusRequest {
        let id = UUID()
        let started = Date()
        let clicks = caretFocusClicks()
        let element: AXUIElement
        let position: Int
        let page: Int
        let intent: Int
        let keys: Int
        let focusBefore: AXUIElement?
        let expires: Date
        var confirmed = false
    }

    package static var caretFocusClicks: () -> [UInt32] = {
        [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown].map {
            CGEventSource.counterForEventType(.combinedSessionState, eventType: $0)
        }
    }

    /// NVDA separates CARET from FOCUS settings and honours a manual mode override. Quick navigation
    /// uses this same arrival policy here so a field is ready for typing after its words (14 Nov 2026).
    func caretArrived(_ object: TurnOverObject) {
        caretFocusRequest = nil
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
        let request = CaretFocusRequest(element: object.element, position: position, page: pageGeneration,
            intent: bufferIntent, keys: ScriptHandler.keysArrivedCount, focusBefore: API.focusObject?.element,
            expires: Date().addingTimeInterval(0.5))
        caretFocusRequest = request
        outstandingCaretFocus = outstandingCaretFocus.filter { $0.value.page == pageGeneration }
        outstandingCaretFocus[ElementKey(object.element)] = request
        Self.confirmFocus(object.element) { [weak self] confirmed in
            guard let self, let active = caretFocusRequest,
                  active.id == request.id, !active.confirmed else { return }
            guard confirmed, caretFocusIsCurrent(request) else { caretFocusRequest = nil; return }
            // Some providers update native focus without posting AXFocusedUIElementChanged.
            // Attach to the already-spoken virtual item; a later native event is consumed once below.
            caretFocusRequest?.confirmed = true
            AXHandler.shared.focusChanged(object.element, pid: webArea.pid)
            // Adopt through the normal focus rules: an ignored or redirected native focus cannot enable typing.
            guard API.focusTreeInterceptor === self,
                  API.focusObject?.isSameElement(as: object.element) == true,
                  let adopted = caretFocusRequest, caretFocusIsCurrent(adopted) else { caretFocusRequest = nil; return }
            setPassThrough(true, announce: true)
            ModeAnnouncement.readingReported(self)
        }
    }

    private func caretFocusIsCurrent(_ request: CaretFocusRequest) -> Bool {
        guard API.focusTreeInterceptor === self, AXHandler.shared.activePid == webArea.pid,
              request.page == pageGeneration,
              request.position == position, request.intent == bufferIntent,
              request.keys == ScriptHandler.keysArrivedCount, Date() < request.expires,
              config.virtualBuffers.autoPassThroughOnCaretMove, !disableAutoPassThrough else { return false }
        if let current = API.focusObject?.element,
           !current.isSame(request.element), request.focusBefore?.isSame(current) != true { return false }
        return true
    }

    /// nil is ordinary native focus; false consumes an obsolete caret request without following or reporting it.
    func acceptCaretFocus(_ object: TurnOverObject) -> Bool? {
        guard let request = outstandingCaretFocus.removeValue(forKey: ElementKey(object.element)) else { return nil }
        if caretFocusRequest?.id == request.id { caretFocusRequest = nil }
        guard request.page == pageGeneration else { return nil }
        // A provider may never post the requested event. A later deliberate native focus move owns
        // its own event; do not swallow that Tab/click/app return as the old caret's reply. Merely
        // waiting is not a new intent: a late obsolete reply must still leave the reading place alone.
        let nativeTab = InputManager.lastKeyDownAt > request.started &&
            ["kb:tab", "kb:shift+tab"].contains(InputManager.lastKeyIdentifier)
        if nativeTab || Self.lastTabFromCaretAt > request.started ||
           Self.caretFocusClicks() != request.clicks || focusFromOutside { return nil }
        guard caretFocusIsCurrent(request) else { return false }
        setPassThrough(shouldPassThrough(object, caret: true), announce: true)
        lastFocusElement = object.element
        positionAtFocus = position
        if let field = object as? EditableText { field.initAutoSelectDetection() }
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
