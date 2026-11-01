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

    public func setPassThrough(_ on: Bool, announce: Bool) {
        guard passThrough != on else { return }
        passThrough = on
        Log.io("browse mode: \(on ? "focus mode" : "browse mode")\(announce ? "" : " (quietly)")")
        guard announce else { return }
        // NVDA: with its audio indication on, a sound says it and the words are left out.
        if config.general.navigationSounds { on ? Tones.focusMode() : Tones.browseMode() }
        else { Speech.speakMessage(on ? String(localized: "focus mode", comment: "Spoken message") : String(localized: "browse mode", comment: "Spoken message")) }
    }

    /// NVDA: shouldPassThrough — an editable or otherwise interactive focus means focus mode.
    public func shouldPassThrough(_ obj: TurnOverObject) -> Bool {
        if disableAutoPassThrough { return passThrough }
        if !config.virtualBuffers.autoFocusMode { return passThrough }   // NVDA: automatic focus mode off
        if obj.axRole == "AXWebArea" { return false }
        if Self.inPlayerOrApplication(obj.element) { return true }
        let s = obj.states
        if s.contains(.editable) && !s.contains(.unavailable) { return true }
        switch obj.role {
        case .comboBox, .popUpButton, .slider, .spinButton, .list, .table, .treeView, .menu, .menuItem, .tabControl, .tab: return true
        case .listItem, .treeViewItem: return true   // NVDA's LISTITEM, TREEVIEWITEM
        default:
            // Focus on the text of an option (Safari focuses the text of a search box's suggestion as Down moves
            // through them): the list it is in decides, as if the option had the focus.
            guard ["AXStaticText", "AXGroup", "AXUnknown"].contains(obj.axRole) else { return false }
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
