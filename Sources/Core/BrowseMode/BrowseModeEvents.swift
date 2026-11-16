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
        var reportFocus = event.kind == .gainFocus
        ModeAnnouncement.begin()
        defer {
            if reportFocus { ModeAnnouncement.focusReported(self, field: event.obj.element) }
            ModeAnnouncement.end()
        }
        switch event.kind {
        case .gainFocus:
            let navigated = refreshIfNavigated()
            if let accepted = acceptCaretFocus(event.obj) {
                reportFocus = accepted
                return
            }
            // Returning to the last focused control normally keeps the saved browse position (NVDA #3145).
            // But an automatically focused edit must use the ordinary field event below: Claude's Prompt had
            // the keyboard while the saved position said Hide sidebar, and Space after a paste pressed it
            // (14 Nov 2026, turnover-2026-11-14T145341Z.log, 16388.7 s). Honour explicit browse overrides.
            let fromOutside = focusFromOutside
            focusFromOutside = false
            let returningToEdit = fromOutside
                && event.obj.states.contains(.editable)
                && shouldPassThrough(event.obj)
            // 14 Nov 2026: mode lives on this page across app departure and unlock. Only browse mode
            // ignores the repeated focus; in focus mode the ordinary field event below must run (NVDA).
            if fromOutside,
               !navigated,
               !passThrough,
               !returningToEdit,
               let last = lastFocusElement,
               event.obj.isSameElement(as: last) {
                Log.io("browse mode: back from outside onto the \(event.obj.axRole) that had the focus; the reading position stays at \(position)")
                positionMovedAt = Date()   // Enter and Space are for the reading position again, not that control (activate)
                // The control's own gain focus is not run here, and with it went the following of a text field's
                // selection: back in the Claude app's prompt, every Shift-arrow selection said nothing until the focus
                // moved (all 8 of them on 11 and 12 Nov 2026, against 0 of 113 after an ordinary focus). Followed again.
                if let field = event.obj as? EditableText {
                    field.initAutoSelectDetection()
                }
                speakUnit(.line)
                return
            }
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
                setPassThrough(false, announce: true)
                positionAtFocus = position
                lastChain = []
                announcePage()
                return
            }
            // Back on the page after Return in the address field: a new page is most likely on its way, and the page
            // being left was read meanwhile ("I agree", from the page left, on three of five loads, 13 Nov 2026). The new
            // page announces itself when it comes; if none has come in a second and a half, and no key since, the line.
            if event.obj.isSameElement(as: webArea), let back = BrowseModeHandler.backFromAddressField,
               Date().timeIntervalSince(back.at) < 0.5, back.page.isSame(webArea) {
                BrowseModeHandler.backFromAddressField = nil
                setPassThrough(false, announce: true)
                positionAtFocus = position
                lastChain = []
                Log.io("browse mode: back on the page after Return in the address field; its line waits for the new page")
                let waiting = url, epoch = pageGeneration, keys = ScriptHandler.keysArrivedCount
                // The page being left is also marked as left (16 Nov 2026, Safari: a Space 0.3 s before the new page came
                // pressed a link at the old page's reading position). Until the mark is cleared, a key meant for the page's
                // content is refused and "loading page" said (refuseIfPageOnItsWay).
                let token = beginPageOnItsWay()
                // While the page says it is busy (loading), up to eight seconds: a slow load is not a page that stayed
                // (Codex's review, 14 Nov 2026).
                // A key that arrives no longer ends the wait early (16 Nov 2026): the old page's line is not read then, but the
                // mark stays until this check has decided, or the first refused key would have given the old page its keys back
                // at the next half second while the new one was still on its way.
                func readIfStayed(_ waited: Double, keyArrived: Bool = false) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self else { return }
                        guard API.focusTreeInterceptor === self, pageGeneration == epoch, url == waiting else {
                            endPageOnItsWay(because: "the page or its document changed", token: token)
                            return
                        }
                        let keyed = keyArrived || ScriptHandler.keysArrivedCount != keys
                        let busy = (webArea.attr("AXElementBusy") as? Bool) == true
                        if waited < 1.5 || (busy && waited < 8) { readIfStayed(waited + 0.5, keyArrived: keyed); return }
                        // Still loading after eight seconds: the new page announces itself when it comes; the old one's
                        // line is not read (Codex's second review, 14 Nov 2026).
                        if busy {
                            Log.io("browse mode: the page is still loading; the old page's line is not read")
                            endPageOnItsWay(because: "the page was still loading after eight seconds", token: token)
                            return
                        }
                        if keyed {
                            endPageOnItsWay(because: "the page stayed (a key had arrived, so its line is not read)", token: token)
                            return
                        }
                        endPageOnItsWay(because: "the page stayed", token: token)
                        speakUnit(.line)
                    }
                }
                readIfStayed(0)
                return
            }
            // Into a player, say so (a page that puts the focus on its player by itself must not leave the letters
            // silently going to the page).
            let wanted = shouldPassThrough(event.obj)
            Log.io("browse mode: focus on \(event.obj.axRole) wants \(wanted ? "focus" : "browse") mode (editable \(event.obj.states.contains(.editable)), manual \(disableAutoPassThrough))")
            // Said (or its sound) whenever TurnOver switches by itself, as NVDA: a silent switch on a list or table left
            // H and K doing nothing (8 Oct 2026).
            setPassThrough(wanted, announce: true)
            // Follow the focus with the virtual caret.
            if !event.obj.isSameElement(as: webArea) {
                lastFocusElement = event.obj.element
                let at = buffer.offset(of: event.obj.element)
                if at == nil, Date().timeIntervalSince(buffer.builtAt) > 1 { followFocusAfterBuild(event.obj.element) }
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

// A page asked for from the address field (16 Nov 2026).
extension BrowseModeDocument {
    /// How long the mark may stand: the longest the stay check waits on a busy page. A test shortens it.
    package static var pageOnItsWayLimit: TimeInterval = 8
    /// How long before "loading page" is said again to further refused keys. A test shortens it.
    package static var pageOnItsWayRepeat: TimeInterval = 2

    /// Marks this document as the page being left. Returns the mark's ticket, which only the check that made it, or the
    /// eight second limit, may use to clear it again (a newer mark is never cleared by an older check).
    func beginPageOnItsWay() -> Int {
        pageOnItsWayTicket += 1
        let token = pageOnItsWayTicket
        pageOnItsWay = PageOnItsWay(token: token, since: Date(), saidAt: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pageOnItsWayLimit) { [weak self] in
            self?.endPageOnItsWay(because: "the limit of \(Int(Self.pageOnItsWayLimit)) seconds passed", token: token)
        }
        return token
    }

    /// Gives the keys back to this document. With a ticket, only that mark is cleared.
    package func endPageOnItsWay(because reason: String, token: Int? = nil) {
        guard let mark = pageOnItsWay, token == nil || token == mark.token else { return }
        pageOnItsWay = nil
        Log.io("browse mode: keys act on this page again: \(reason)")
    }

    /// Whether keys for the content are refused now. Looks only; the limit's timer clears the mark itself.
    package var pageIsOnItsWay: Bool {
        guard let mark = pageOnItsWay else { return false }
        return Date().timeIntervalSince(mark.since) < Self.pageOnItsWayLimit
    }

    /// A key meant for the page's content while the new page is on its way: nothing is pressed, nothing moves, and it
    /// says so (once, and again only after two seconds). The key is refused, not held: it would have to be handed to a
    /// document that may not exist yet, and a held Space would press whatever is at the top of a page not yet heard.
    @discardableResult
    func refuseIfPageOnItsWay(_ gesture: KeyboardGesture, command: String) -> Bool {
        guard pageIsOnItsWay, var mark = pageOnItsWay else { return false }
        let due = mark.saidAt.map { Date().timeIntervalSince($0) > Self.pageOnItsWayRepeat } ?? true
        Log.io("browse mode: \(gesture.logDescription(commandName: command, secure: API.focusObject?.role == .passwordEdit)) refused; a new page is on its way after Return in the address field\(due ? "" : " (not said again)")")
        if due {
            mark.saidAt = Date()
            pageOnItsWay = mark
            Speech.speakMessage(String(localized: "loading page", comment: "Spoken message"))
        }
        return true
    }

    /// The script that stands in for a browse mode command while the page is on its way: it keeps the command's name,
    /// description and key, so keyboard help is unchanged, and refuses when it runs.
    func refusingScript(for script: Script) -> Script {
        let refusing = Script(name: script.name, description: script.description, category: script.category, owner: self) { [weak self] gesture in
            guard let self else { return }
            // The wait may have ended between the key's lookup and its run: then the command is the real one.
            if !refuseIfPageOnItsWay(gesture, command: script.name) { script.handler(gesture) }
        }
        refusing.canPropagate = script.canPropagate
        refusing.bypassInputHelp = script.bypassInputHelp
        refusing.isAvailable = script.isAvailable
        return refusing
    }
}
