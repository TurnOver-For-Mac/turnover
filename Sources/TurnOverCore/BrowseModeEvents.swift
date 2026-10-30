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

// Browse mode: events for objects inside the document (NVDA: tree interceptor event handling).
extension BrowseModeDocument {
    public func handleEvent(_ event: Event, next: () -> Void) {
        switch event.kind {
        case .gainFocus:
            refreshIfNavigated()
            if event.obj.isSameElement(as: webArea) { followWebKitSelection() }
            if event.obj.axRole == "AXWebArea", !event.obj.isSameElement(as: webArea) {
                // A frame inside the document (an advertisement loading): usually not a focus change to the user, as the
                // focus goes straight on into it. But a frame can keep it (Cloudflare's check, once passed, left Tab
                // on its frame and the key seemed to do nothing, 3 Oct 2026): if it still has it a moment later, say so.
                Log.io("browse mode: focus on a nested web area; waiting to see if it stays")
                let frame = event.obj.element, pid = event.obj.pid
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    let app = AXUIElementCreateApplication(pid)
                    guard let now = app.element(kAXFocusedUIElementAttribute), now.isSame(frame) else { return }
                    var name = frame.string(kAXDescriptionAttribute) ?? frame.string(kAXTitleAttribute) ?? ""
                    var p = frame.element(kAXParentAttribute); var hops = 0
                    while name.isEmpty, let x = p, hops < 4 { name = x.string(kAXDescriptionAttribute) ?? x.string(kAXTitleAttribute) ?? ""; p = x.element(kAXParentAttribute); hops += 1 }
                    Speech.speakMessage(name.isEmpty ? String(localized: "frame", comment: "A web page's frame") : String(localized: "\(name), frame", comment: "A web page's frame: %@ is its name"))
                }
                return
            }
            if event.obj.isSameElement(as: webArea), buffer.lines.isEmpty, !url.isEmpty, url != "about:blank" {
                // A page still arriving: NVDA says "Loading document..." only if it is still loading a second later,
                // and reads the page once it has loaded (no "document, blank").
                if Date().timeIntervalSince(buffer.builtAt) > 0.5 { buffer.build() }
                if buffer.lines.isEmpty {
                    let waiting = url
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                        guard let self, buffer.lines.isEmpty, url == waiting, API.focusTreeInterceptor === self else { return }
                        Speech.speakMessage(String(localized: "loading page", comment: "Spoken message"))
                    }
                    watchForContent()   // and read it when it comes, even if no focus event says so
                    return
                }
            }
            // A page reached for the first time (a new page, Back, a reload): NVDA's first gain focus, the title and then
            // the reading (say all, or the line).
            if event.obj.isSameElement(as: webArea), !passThrough, url != announcedURL, !buffer.lines.isEmpty {
                setPassThrough(false, announce: false)
                positionAtFocus = position
                lastChain = []
                announcePage()
                return
            }
            // Into a player, say so (a page that puts the focus on its player by itself must not leave the letters
            // silently going to the page).
            let wanted = shouldPassThrough(event.obj)
            Log.io("browse mode: focus on \(event.obj.axRole) wants \(wanted ? "focus" : "browse") mode (editable \(event.obj.states.contains(.editable)), manual \(disableAutoPassThrough))")
            // Said (or its sound) whenever TurnOver switches by itself, as NVDA: a silent switch on a list or table left
            // H and K doing nothing (8 Oct 2026).
            setPassThrough(wanted, announce: wanted != passThrough)   // both ways, as NVDA: back to browse mode had no sound (a tester, 12 Oct 2026)
            // Follow the focus with the virtual caret.
            if !event.obj.isSameElement(as: webArea) {
                var at = buffer.offset(of: event.obj.element)
                if at == nil, Date().timeIntervalSince(buffer.builtAt) > 1 { buffer.build(); at = buffer.offset(of: event.obj.element) }
                if let at { position = at }
            }
            positionAtFocus = position
            lastChain = []
            next()
        default:
            next()
        }
    }
}
