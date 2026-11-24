// SPDX-License-Identifier: GPL-3.0-or-later
// The accessibility API handler (NVDA: IAccessibleHandler / UIAHandler for
// Windows; here the one macOS API). It watches applications through
// AXObservers, keeps the focus and the foreground up to date, and turns each
// notification into an event for an object. Nothing here speaks; the objects
// and modules decide that.
import Foundation
import AppKit
import ApplicationServices
import TurnOverAX

// The focus changed: what to ignore, what to follow somewhere else, and what to present (NVDA: eventHandler's
// focus handling with focusEntered for new ancestors). Each special case is a named rule below, tried in order
// (8 Oct 2026, from the team review: "each `if` with a dated comment becomes a named rule").
extension AXHandler {
    /// What a rule says about a focus report.
    enum FocusVerdict {
        /// Not the focus: say nothing, keep what TurnOver had.
        case ignore
        /// The focus is really this element: start the rules again with it.
        case follow(AXUIElement)
        /// This element with the rule's say over it; on to the next rule.
        case go(AXUIElement)
        /// Taken: the rule has done what is needed (set the focus quietly, re-asked later).
        case done
    }

    /// The rules, in order. Each gets the element as the rules so far have it, the pid it was reported for and the
    /// element first reported (a re-check later asks whether it is still the focus).
    typealias FocusRule = (AXUIElement, pid_t, AXUIElement) -> FocusVerdict
    var focusRules: [(String, FocusRule)] {[
        ("not an application", ruleNotAnApplication),
        ("behind the app switcher", ruleBehindTheSwitcher),
        ("background application", ruleBackgroundApplication),
        ("set aside after a settings Tab", ruleSetAside),
        ("untitled window", ruleUntitledWindow),
        ("helper's window", ruleHelperWindow),
        ("switching preference tabs", rulePreferenceTabSwitch),
        ("background window", ruleBackgroundWindow),
        ("stand-in for a text field", ruleTextStandIn),
        ("duplicate", ruleDuplicate),
        ("hidden scroll bar", ruleHiddenScrollBar),
        ("blank frame", ruleBlankFrame),
        ("empty web area, no key pressed", ruleEmptyWebAreaUnbidden),
        ("field still has the keys", ruleFieldStillHasKeys),
        ("reported twice", ruleReportedTwice),
        ("no role", ruleNoRole),
        ("nameless container", ruleNamelessContainer),
        ("menu gap", ruleMenuGap),
        ("menu open", ruleMenuOpen),
        ("window while a control has the keys", ruleWindowWhileControlHasKeys),
        ("window already presented", ruleWindowAlreadyPresented),
        ("owned by another process", ruleOwnedByAnotherProcess),
    ]}

    /// The rules a hidden control that was verified (it says it has the keyboard, and its parent is the reported focus)
    /// skips: the ones that compare by role and frame, or drop a nameless one, would take it for something else while
    /// TurnOver kept the old focus. Every other rule, the menu ones and the exact duplicate included, still applies.
    static let hiddenSkippedRules: Set<String> = ["stand-in for a text field", "reported twice", "nameless container"]

    public func focusChanged(_ element: AXUIElement, pid: pid_t, verifiedHidden: Bool = false) {
        if !verifiedHidden { lastBrowserFocusNewsAt = Date() }
        let module = AppModuleHandler.shared.appModule(for: pid)
        var target = module.redirectFocus(element) ?? element
        for (name, rule) in focusRules {
            if verifiedHidden, Self.hiddenSkippedRules.contains(name) { continue }
            switch rule(target, pid, element) {
            case .ignore: Log.debug("focus rule \(name): ignored"); return
            case .done: Log.debug("focus rule \(name): handled"); return
            case .follow(let other): Log.debug("focus rule \(name): following"); focusChanged(other, pid: pid); return
            case .go(let t): target = t
            }
        }
        present(target, pid: pid)
    }

    // MARK: The rules

    /// The system's text-input cursor service (com.apple.TextInputUI.xpc.CursorUIViewService) reports its own
    /// untitled window as focused whenever a Chromium text field is typed into; a process that cannot be an
    /// application (an XPC service, activation policy prohibited) never has the keyboard.
    func ruleNotAnApplication(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        if pid != activePid, let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .prohibited, !isHelperOfActiveApp(app) {
            Log.io("focus from \(app.bundleIdentifier ?? "pid \(pid)") (not an application); ignored")
            return .ignore
        }
        return .go(target)
    }

    /// While Command Tab's app switcher has the focus, the app it was opened over can still report a focus of its own:
    /// Mail's message pane was read over the switcher ("Claude", then a PayPal message), and the next two Command Tabs
    /// said nothing (13 Nov 2026). Set aside while the switcher is there; once Command is let go it is gone, and the
    /// app that comes to the front is followed as ever.
    func ruleBehindTheSwitcher(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        guard let f = API.focusObject, f is AppSwitcherList else { return .go(target) }
        // Only the app the switcher came up over; the app being switched to is never held back (Codex's review, 14 Nov
        // 2026: the active app changes to it before its focus is read).
        guard let over = AppSwitcherList.openedOver, pid == over else { return .go(target) }
        // Only while Command is still held: the switcher closes when it is let go, whatever its element still answers.
        let commandHeld = CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
        guard commandHeld else { return .go(target) }
        Log.io("focus from pid \(pid) while the app switcher is up; set aside")
        // Escape can close the switcher with Command still held, and the app's focus then comes back with no further
        // news: the watcher started when the list gained the focus reads it again (SwitcherCloseWatcher, 22 Nov 2026,
        // issue 351; it replaced reconcileAfterSwitcher, which only covered this one app and this one case).
        return .ignore
    }

    /// An ordinary application in the background (Safari's page reloading behind Mail, 2 Oct 2026) can post focus
    /// events: they are not where the keys go. Followed, they put Safari's page under Mail and the arrows read it.
    /// (An application coming to the front is let through: it is frontmost before the activation news arrives.)
    func ruleBackgroundApplication(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        if pid != activePid, let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
           !isHelperOfActiveApp(app), !AXHandler.systemUIAgents.contains(app.bundleIdentifier ?? ""),
           NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            Log.io("focus from \(app.localizedName ?? "pid \(pid)") in the background; ignored")
            return .ignore
        }
        return .go(target)
    }

    /// Just after TurnOver took the place on a control that refused the focus: the application's own news is set aside.
    func ruleSetAside(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        if pid == activePid, SettingsPanePlugin.setsAside(target) {
            Log.io("focus to \(target.role) just after a settings Tab; set aside")
            return .ignore
        }
        return .go(target)
    }

    /// An untitled window: just after a settings tab switch (Safari's General rebuilds part of its window), back to
    /// the tab showing; from a helper (Safari's SandboxBroker while Safari's settings switch panes, 4 Oct 2026),
    /// ignored, and the application's real focus read a moment later.
    func ruleUntitledWindow(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        guard target.role == "AXWindow", (target.string(kAXTitleAttribute) ?? "").isEmpty else { return .go(target) }
        if Date().timeIntervalSince(PreferenceTab.lastTabFocusAt) < 1.5,
           let window = AXUIElementCreateApplication(activePid).element(kAXFocusedWindowAttribute), let tab = PreferenceTab.selectedTab(in: window) {
            Log.io("focus to an untitled window just after a settings tab switch; back to the tab")
            _ = tab.set(kAXFocusedAttribute, kCFBooleanTrue)
            PreferenceTab.lastTabFocusAt = Date()
            API.setFocusObject(ObjectFactory.make(tab), ancestors: API.focusAncestors)
            return .done
        }
        if pid != activePid, let helper = NSRunningApplication(processIdentifier: pid), isHelperOfActiveApp(helper),
           (AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute).map { $0.role == "AXWindow" } ?? true) {
            Log.io("focus to \(helper.bundleIdentifier ?? "a helper")'s untitled window; ignored, reading the real focus")
            let active = activePid
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.refocus(pid: active) }
            return .done
        }
        return .go(target)
    }

    /// A helper (Safari's SandboxBroker) reports its whole window as focused; the control inside is what has the keys.
    func ruleHelperWindow(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        if target.role == "AXWindow", pid != activePid, let helper = NSRunningApplication(processIdentifier: pid), isHelperOfActiveApp(helper),
           let inner = AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute), inner.role != "AXWindow" {
            return .go(inner)
        }
        return .go(target)
    }

    /// While a preference tab is being switched, the app may pull focus into the new pane (Safari's General puts
    /// it in the homepage field); the tab bar keeps it, as on Windows. PreferenceTab puts the app's focus back.
    func rulePreferenceTabSwitch(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        if Date() < PreferenceTab.quietUntil, !PreferenceTab.isPreferenceTab(target), target.role != "AXWindow" {
            Log.io("focus to \(target.role) while switching preference tabs; held on the tab")
            return .ignore
        }
        return .go(target)
    }

    /// Safari reports focus inside its background windows (a page loading, an advertisement taking focus in its own
    /// window); only the application's focused window has the keyboard. A window just opened may report focus before
    /// the application names it focused, so the application is asked again shortly.
    func ruleBackgroundWindow(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        guard let window = target.element(kAXWindowAttribute), window.string(kAXSubroleAttribute) == "AXStandardWindow",
              let front = AXUIElementCreateApplication(pid).element(kAXFocusedWindowAttribute),
              front.string(kAXSubroleAttribute) == "AXStandardWindow", !front.isSame(window) else { return .go(target) }
        Log.io("focus in the background window \"\(Log.words(String(window.string(kAXTitleAttribute)?.prefix(40) ?? "")))\"; ignored")
        if !backgroundRecheckPending {
            backgroundRecheckPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { return }
                self.backgroundRecheckPending = false
                if pid == self.activePid, let f = AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute), f.isSame(element) {
                    // Still the application's focus: the window is the front one after all.
                    if let w = f.element(kAXWindowAttribute), let fw = AXUIElementCreateApplication(pid).element(kAXFocusedWindowAttribute), w.isSame(fw) { self.focusChanged(f, pid: pid) }
                }
            }
        }
        return .ignore
    }

    /// SwiftUI reports the focus on a text field twice (System Settings' search field and the fields in its panes, macOS
    /// 27): first a stand-in in the same place that answers nothing about its text (value, caret and length all "no
    /// value"), then the field itself, which the application gives as its focus. "Reported twice" kept the stand-in and
    /// let the field go: the field was read as a bare "edit", and the review keys found no caret in it and said nothing,
    /// press after press (29 Oct 2026). The application's own focus, the same control with text, is the one presented.
    func ruleTextStandIn(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        // Its length, or else its caret, never its value: a long document's whole text was copied at each report, only for
        // the report to be set aside as a duplicate (the review of pull request 195, 29 Oct 2026).
        func hasText(_ e: AXUIElement) -> Bool { e.attr(kAXNumberOfCharactersAttribute) != nil || e.attr(kAXSelectedTextRangeAttribute) != nil }
        guard ["AXTextField", "AXTextArea"].contains(target.role), !hasText(target),
              let focused = AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute), !focused.isSame(target),
              hasText(focused), Self.sameControl(target, focused) else { return .go(target) }
        Log.io("focus on a \(target.role) with nothing behind it; the application's focus in the same place taken instead")
        return .go(focused)
    }

    /// The same element in the same window as TurnOver already has.
    func ruleDuplicate(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        let window = target.element(kAXWindowAttribute)
        if let f = API.focusObject, f.isSameElement(as: target), focusWindow.map({ w in window.map { $0.isSame(w) } ?? true }) ?? false {
            Log.debug("duplicate focus for \(f.axRole)")
            return .ignore
        }
        return .go(target)
    }

    /// Mail's Tab order stops on its message list's hidden scroll bar between the list and the message: a stop
    /// with nothing to say or do. Tab on past it, as the user meant.
    func ruleHiddenScrollBar(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        guard target.role == "AXScrollBar", (target.attr("AXHidden") as? Bool) == true else { return .go(target) }
        let key = InputManager.lastKeyIdentifier
        if Date().timeIntervalSince(InputManager.lastKeyDownAt) < 1.5, key == "kb:tab" || key == "kb:shift+tab", let g = KeyboardGesture(identifier: key) {
            Log.io("focus on a hidden scroll bar after \(key); passing on")
            g.send()
            return .done
        }
        return .go(target)
    }

    /// An advertisement or tracking frame (about:blank, no address, nothing in it) takes focus while a page loads;
    /// following it left the document empty and quick navigation said "no next heading" until Tab. Only a frame:
    /// inside another web area, or detached from any window. Mail's compose body is also a blank web area
    /// (about:blank) but sits in its window, and must be followed (2 Oct: Tab into it said nothing).
    func ruleBlankFrame(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        guard target.role == "AXWebArea" else { return .go(target) }
        let address = (target.attr("AXURL") as? URL)?.absoluteString ?? (target.attr("AXURL") as? String) ?? ""
        let blankAddress = address.isEmpty || address == "about:blank"
        var nested = false
        var p = target.element(kAXParentAttribute); var hops = 0
        while let x = p, hops < 40 { if x.role == "AXWebArea" { nested = true; break }; p = x.element(kAXParentAttribute); hops += 1 }
        let detached = target.element(kAXWindowAttribute) == nil
        if blankAddress, nested || detached {
            Log.io("focus on a blank frame (\(address.isEmpty ? "no address" : Log.words(address))); ignored")
            return .ignore
        }
        return .go(target)
    }

    /// An empty web area that takes the focus with no key pressed: an advertisement or consent frame refreshing, or
    /// the page's own web area emptied for a moment by a reload. Following it replaced the document, said blank, and
    /// the heading keys found nothing until the page came back (bridgesandballoons.com, every thirty seconds or so,
    /// 23 Oct 2026, issue 78). Left alone, the document in hand stays; if the page really went, the next key finds
    /// the window's current web area (browse mode's replaced-on-reload check). Only while a page is being read: a
    /// first page, or one reached by a key, is followed as before.
    /// Only in the window of the page in hand: a frame refreshing, or the page's own web area emptied by a reload,
    /// both arrive there; a page chosen with the mouse in another window or another app is followed as it was
    /// (a second reviewer, 23 Oct 2026). A page that fills a moment later posts its focus again with content, and
    /// is followed then.
    func ruleEmptyWebAreaUnbidden(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        guard target.role == "AXWebArea" else { return .go(target) }
        guard let document = API.focusTreeInterceptor else { return .go(target) }
        guard !document.passThrough else { return .go(target) }   // in focus mode the keys bypass browse mode's recovery
        guard Date().timeIntervalSince(InputManager.lastKeyDownAt) > 1 else { return .go(target) }
        guard target.elements(kAXChildrenAttribute).isEmpty else { return .go(target) }
        guard let targetWindow = target.element(kAXWindowAttribute) else { return .go(target) }
        let sameWindow: Bool
        if let documentWindow = document.webArea.element(kAXWindowAttribute) {
            sameWindow = targetWindow.isSame(documentWindow)
        } else {
            // The page's web area has been replaced and can no longer name its window: the same process is taken as
            // the same window (a reload is the case this rule exists for; a second reviewer, 23 Oct 2026).
            sameWindow = !document.isAlive && target.pid == document.webArea.pid
        }
        guard sameWindow else { return .go(target) }
        Log.io("focus on an empty web area with no key pressed, in the window of the page in hand; ignored")
        followIfPageWent(document, tries: 6)
        return .ignore
    }

    /// After an ignored empty web area, looked at every 0.4 s for about two seconds: the application's focus is
    /// asked again, and a web area that now has the focus and content, other than the page in hand, is followed
    /// (the ignored one filled, or another tab was chosen with the mouse while it was still empty). Failing that,
    /// if the page in hand has gone (its web area dead or emptied) and the window has a new one with content, that
    /// one is followed. Now, not at the next key, which would have read the old buffer (a second reviewer, 23 Oct
    /// 2026).
    func followIfPageWent(_ document: BrowseModeDocument, tries: Int, gaveUp: (() -> Void)? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pageWatchInterval) { [weak self] in
            guard let self, API.focusTreeInterceptor === document else { return }
            let app = AXUIElementCreateApplication(document.webArea.pid)
            if let focused = app.element(kAXFocusedUIElementAttribute), focused.role == "AXWebArea",
               !focused.isSame(document.webArea), !focused.elements(kAXChildrenAttribute).isEmpty {
                Log.io("focus: the web area that took the focus has content now; following it")
                self.focusChanged(focused, pid: focused.pid)
                return
            }
            let oldGone = !document.isAlive || document.webArea.elements(kAXChildrenAttribute).isEmpty
            if oldGone {
                document.followCurrentRoot(requireEmpty: false) { [weak self] followed in
                    guard !followed else { return }
                    if tries > 1 { self?.followIfPageWent(document, tries: tries - 1, gaveUp: gaveUp) } else { gaveUp?() }
                }
                return
            }
            if tries > 1 { self.followIfPageWent(document, tries: tries - 1, gaveUp: gaveUp) } else { gaveUp?() }
        }
    }
    /// How often followIfPageWent looks (a test shortens it).
    package static var pageWatchInterval: TimeInterval = 0.4

    /// Safari reports the page focused while its address bar, with the suggestions popup up, still has the keyboard.
    /// (Only a field you can type in: Mail's message window starts its focus on the read-only header, a text area,
    /// and the message itself was refused, leaving the user stuck on a blank field, 7 Oct 2026.)
    func ruleFieldStillHasKeys(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        if target.role == "AXWebArea", let cur = API.focusObject, cur.pid == pid, [.editableText, .searchField, .comboBox, .passwordEdit].contains(cur.role),
           (cur.element.attr(kAXFocusedAttribute) as? Bool) == true, cur.element.string(kAXIdentifierAttribute) != "message.header.content",
           { var st: DarwinBoolean = false; return AXUIElementIsAttributeSettable(cur.element, kAXValueAttribute as CFString, &st) == .success && st.boolValue }() {
            Log.io("focus to the web area while the \(cur.axRole) \"\(Log.words(cur.name))\" still reports focus; ignored")
            return .ignore
        }
        return .go(target)
    }

    /// Two references to one control: the same role, the same frame.
    nonisolated static func sameControl(_ a: AXUIElement, _ b: AXUIElement) -> Bool {
        let names = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute]
        let x = a.attrs(names), y = b.attrs(names)
        guard let ra = x[kAXRoleAttribute] as? String, ra == (y[kAXRoleAttribute] as? String),
              let pa = x[kAXPositionAttribute], let pb = y[kAXPositionAttribute], let sa = x[kAXSizeAttribute], let sb = y[kAXSizeAttribute] else { return false }
        func point(_ v: AnyObject) -> CGPoint { var p = CGPoint.zero; axValue(v, .cgPoint, &p); return p }
        func size(_ v: AnyObject) -> CGSize { var s = CGSize.zero; axValue(v, .cgSize, &s); return s }
        return point(pa) == point(pb) && size(sa) == size(sb) && size(sa).width > 0
    }

    /// The same element reported again within half a second.
    func ruleReportedTwice(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        // (SwiftUI hands over two references for one control: System Settings' switches were each read twice,
        // 10 Oct 2026. The same role in the same place on screen is the same control.)
        if let (last, at) = lastGainFocus, Date().timeIntervalSince(at) < 0.5, last.isSame(target) || Self.sameControl(last, target) {
            Log.debug("focus reported twice for the same element; ignored")
            return .ignore
        }
        return .go(target)
    }

    /// An element that answers no role is nothing to present.
    func ruleNoRole(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        if target.role == "?" { Log.debug("focus on an element with no role; ignored"); return .ignore }
        return .go(target)
    }

    /// Mail hands focus to an unnamed AXUnknown (its message view host). In the list's own window the list keeps
    /// the focus (arrows must stay in the list); in a message window the host's web area is what to read. A nameless
    /// container with a document inside (Mail's message window: an AXGroup or AXUnknown over the message body) is
    /// followed into the document.
    func ruleNamelessContainer(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        let axRole = target.role
        guard axRole == "AXUnknown" || axRole == "AXGroup", let current = API.focusObject else { return .go(target) }
        let obj = ObjectFactory.make(target)
        guard obj.name.isEmpty else { return .go(target) }
        let window = target.element(kAXWindowAttribute)
        let sameWindow = current.element.element(kAXWindowAttribute).map { w in window.map { $0.isSame(w) } ?? false } ?? false
        // What TurnOver is on (a list, a table, a button) still says it has the keyboard: the report is the app
        // announcing a pane it loaded, not a move. Outlook does it as each message loads, half a second after Down;
        // TurnOver followed it into the reading pane (or onto an empty group, before the pane had a page) and the
        // arrows went silent; after Tab to New Email the same report pulled TurnOver off the button (parts request #2
        // and its comment, by an AI making an Outlook plugin, 14 Oct 2026). As Safari's field rule, for any control.
        if sameWindow, current.pid == pid, !current.element.isSame(target) {
            let holder = Self.listHoldingKeys(from: current.element) ?? ((current.element.attr(kAXFocusedAttribute) as? Bool) == true ? current.element : nil)
            if let holder {
                Log.io("focus on a nameless \(axRole) while the \(holder.role) \"\(Log.words(holder.string(kAXDescriptionAttribute) ?? holder.string(kAXTitleAttribute) ?? ""))\" still reports focus; ignored")
                return .ignore
            }
        }
        if let web = target.firstDescendant(role: "AXWebArea", maxVisited: 300) {
            if sameWindow, axRole == "AXUnknown" { Log.io("focus on a nameless \(axRole) in the same window; ignored"); return .ignore }
            // A text field TurnOver is on still says it has the keyboard: the report is Safari's, around the page, not a
            // move. On a page whose form is in a frame of its own (a Wix site, 14 Nov 2026), each focus on the Email
            // field brought Safari's AutoFill list and, 190 ms later, focus on the page's nameless group. TurnOver went
            // back to browse mode, the address typed became commands, and the owner switched to VoiceOver to fill it in.
            // The frame runs in a process of its own, so the same-app check above never applied.
            if Self.fieldHoldsKeyboard(current.element, target, page: web) {
                Log.io("focus on a nameless \(axRole) while the field \"\(Log.words(current.name))\" still reports focus; ignored")
                recheckFieldFocus(current.element, pid: pid)
                return .ignore
            }
            // A list or table in the same window still says it has the keyboard: the report is the app announcing a
            // pane it loaded, not a move. Outlook does it for its reading pane each time a message loads, half a
            // second after Down, and the next Down moved by line in the message (parts request #2, written by an AI
            // making an Outlook plugin, 14 Oct 2026). As Safari's field rule, for lists.

            Log.io("focus on a nameless \(axRole): following it to its web area")
            return .follow(web)
        }
        if axRole == "AXUnknown" {
            // Another app's focus still held: keeping it let that app's commands answer here. Byword's text box
            // took Excel's arrows ("caret did not move", silence) because Excel's first focus is a nameless
            // AXUnknown over its grid (Day 2, 10 Oct 2026). Held quietly instead, and the app asked again a moment
            // later: Excel names its cell once it has built its tree for an assistive app.
            if current.pid != pid {
                Log.io("focus on a nameless AXUnknown in a new app; held quietly, asking again shortly")
                let obj = ObjectFactory.make(target)
                API.setFocusObject(obj, ancestors: obj.ancestors)
                // The cursor goes to the new app too, not left in the one that was left (22 Nov 2026, issue 351).
                ObjectNavigator.shared.focusMoved(to: target, pid: pid)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self, API.focusPid == pid, let f = AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute),
                          !f.isSame(target), f.role != "AXUnknown" else { return }
                    Log.io("focus asked again: \(f.role)")
                    self.focusChanged(f, pid: pid)
                }
                return .done
            }
            Log.io("focus on a nameless AXUnknown with no document inside; ignored"); return .ignore
        }
        // The group set aside, reported again while the new page is awaited and no key has been pressed since: still set
        // aside. Presented, it dropped the page and the watch with it, and the silence came back (Codex's review).
        if Self.isPageHostSetAside(target) {
            Log.io("focus on the nameless AXGroup set aside, reported again; still set aside")
            return .ignore
        }
        if Self.isSafariPageHostBetweenPages(target, pid: pid), let document = API.focusTreeInterceptor,
           let press = BrowseModeDocument.lastNavigationPress {
            // The press is the evidence for one page change only.
            BrowseModeDocument.lastNavigationPress = nil
            Self.pageHostSetAside = (target, document, press.keyAt)
            Log.io("focus on a nameless AXGroup with no page in it yet, just after a link or button was pressed; set aside, watching for the new page")
            let setAside = target
            let generation = document.pageGeneration
            followIfPageWent(document, tries: Self.pageHostWatchTries) { [weak self] in
                // No new page came: the focus set aside is presented, if the app still has it there.
                Self.pageHostSetAside = nil
                guard let self else { return }
                // The same document took a new page meanwhile and has read it: the group, presented now, would drop
                // that page and talk over it (review, 20 Nov 2026).
                guard document.pageGeneration == generation else {
                    Log.io("focus: the page changed while the nameless group was set aside; not presented")
                    return
                }
                guard let now = AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute), now.isSame(setAside) else {
                    Log.io("focus: no new page came, and the app's focus has moved on from the group set aside; not presented")
                    return
                }
                Log.io("focus: no new page came; the nameless group set aside is presented")
                self.present(setAside, pid: pid)
            }
            return .ignore
        }
        return .go(target)
    }

    /// The page host set aside, the page it was set aside for, and the key that pressed the link: while the page is still
    /// TurnOver's and no key has come since, a report of the same group again is set aside too. Ended by the watch
    /// giving up, by the new page being followed (the page is no longer TurnOver's), or by any key.
    package static var pageHostSetAside: (element: AXUIElement, document: BrowseModeDocument, keyAt: Date)?

    package static func isPageHostSetAside(_ target: AXUIElement) -> Bool {
        guard let held = pageHostSetAside else { return false }
        guard held.element.isSame(target) else { return false }
        guard API.focusTreeInterceptor === held.document else { return false }
        guard InputManager.lastKeyDownAt == held.keyAt else { return false }
        return true
    }

    /// How many looks, at pageWatchInterval, for the new page after Safari's page host takes the focus (about 5 s).
    package static var pageHostWatchTries = 12
    /// How long a press of a link or button stands as evidence of a page change.
    package static let pageHostPressWindow: TimeInterval = 4
    /// How far up the walk from the group to its window goes before it gives up (a test lowers it).
    package static var pageHostAncestorLimit = 40

    /// Safari, after VO Space or Return on a link or button: the focus goes to a nameless group outside any page, with
    /// no page in it yet, while the new page loads; the new page then takes the focus only as a blank frame
    /// (about:blank, ignored by its rule) and posts nothing more. Presented, the group said nothing, browse mode let go of
    /// the page, and nothing was said of the new page until a key was pressed (18 Nov 2026 at 07:13:28 and
    /// 07:18:31: VO Space on a link, then silence until Tab three seconds later). Set aside, the page in hand keeps the
    /// keys and the new page is followed as soon as it has content (followIfPageWent), as a reloaded page is; with no new
    /// page in about five seconds the group is presented after all. Only with positive evidence (a link or button
    /// pressed by VO Space or Return in this window within the last few seconds), only Safari (SHORTCOMINGS 13), only in
    /// the very window of that press, never in a dialog, a sheet or anything inside one.
    package static func isSafariPageHostBetweenPages(_ target: AXUIElement, pid: pid_t, now: Date = Date()) -> Bool {
        guard target.role == "AXGroup" else { return false }
        guard BrowseModeDocument.pageOnItsWayBundles.contains(ProfileStore.shared.bundle(of: pid)) else { return false }
        guard let document = API.focusTreeInterceptor else { return false }
        guard document.webArea.pid == pid else { return false }
        guard let press = BrowseModeDocument.lastNavigationPress else { return false }
        guard press.pid == pid else { return false }
        guard now.timeIntervalSince(press.at) < pageHostPressWindow else { return false }
        // No key since the one that pressed it: a Tab (a move into Safari's own controls) or any other key ends the
        // evidence for good (Codex's review: VO Space, Tab, then another key made the old press count again).
        guard InputManager.lastKeyDownAt == press.keyAt else { return false }
        // The very window the press was in, by identity.
        guard let targetWindow = target.element(kAXWindowAttribute) else { return false }
        guard targetWindow.isSame(press.window) else { return false }
        guard targetWindow.string(kAXSubroleAttribute) == "AXStandardWindow" else { return false }
        // Outside any page (a nameless group on a page is the page's own), and in no sheet or dialog.
        let dialogSubroles: Set<String> = ["AXDialog", "AXSystemDialog", "AXFloatingWindow", "AXSystemFloatingWindow"]
        // The walk must reach that very window: one stopped by its limit has not shown the group is outside a page.
        var p = target.element(kAXParentAttribute); var hops = 0
        var reachedWindow = false
        while let x = p, hops < Self.pageHostAncestorLimit {
            let role = x.role
            if role == "AXWebArea" { return false }
            if role == "AXSheet" { return false }
            if let sub = x.string(kAXSubroleAttribute), dialogSubroles.contains(sub) { return false }
            if role == "AXWindow" { reachedWindow = x.isSame(targetWindow); break }
            p = x.element(kAXParentAttribute); hops += 1
        }
        return reachedWindow
    }

    /// Whether `field`, where the focus is, is a text field in `page` that still says it has the keyboard, so a report
    /// of focus on `reported` (a nameless container around that page) is not a move. Asked of the field itself: a
    /// frame of the page can run in a process of its own, with no window of its own to compare. A field outside the
    /// page (Safari's address field, after Return) that lets the page have the keys is a move, and is followed.
    package static func fieldHoldsKeyboard(_ field: AXUIElement, _ reported: AXUIElement, page: AXUIElement) -> Bool {
        guard ["AXTextField", "AXTextArea", "AXComboBox"].contains(field.role) else { return false }
        guard !field.isSame(reported) else { return false }
        guard (field.attr(kAXFocusedAttribute) as? Bool) == true else { return false }
        // TurnOver's document for that page holds the field, or the field is inside the page.
        if let d = API.focusTreeInterceptor, d.webArea.isSame(page) { return true }
        var x = field.element(kAXParentAttribute); var hops = 0
        while let y = x, hops < 60 {
            if y.isSame(page) { return true }
            x = y.element(kAXParentAttribute); hops += 1
        }
        return false
    }

    /// A field's own word that it is focused is not proof that its frame still has the keys (WebKit answers it from
    /// the field's document; Codex's review, 14 Nov 2026). Looked at again a moment later: if the field no longer says
    /// so, or the app's focus is now a control of another kind, that is followed; the nameless group alone is not.
    func recheckFieldFocus(_ field: AXUIElement, pid: pid_t) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, API.focusObject?.element.isSame(field) == true else { return }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            let fieldStillSays = (field.attr(kAXFocusedAttribute) as? Bool) == true
            guard let now = app.element(kAXFocusedUIElementAttribute), !now.isSame(field) else { return }
            let containers: Set<String> = ["AXGroup", "AXWebArea", "AXUnknown", "AXScrollArea"]
            let elsewhere = !containers.contains(now.role)
            guard !fieldStillSays || elsewhere else { return }
            Log.io("focus: the field let go after all; the app's focus is on \(now.role)")
            self.focusChanged(now, pid: pid)
        }
    }

    /// The list, table or outline the focus is in (the focus itself, or a row or cell of it), if it still says it
    /// has the keyboard.
    static func listHoldingKeys(from e: AXUIElement) -> AXUIElement? {
        var x: AXUIElement? = e; var hops = 0
        while let y = x, hops < 4 {
            if ["AXList", "AXTable", "AXOutline"].contains(y.role) { return (y.attr(kAXFocusedAttribute) as? Bool) == true ? y : nil }
            x = y.element(kAXParentAttribute); hops += 1
        }
        return nil
    }

    static let menuRoles: Set<Role> = [.menu, .menuItem, .checkMenuItem, .radioMenuItem, .menuBar, .popupMenu]

    /// Right or Left in the menu bar closes one menu before opening the next, and the application hands focus back
    /// to its window in between. Wait a moment: if a menu opens, this focus never happened. (0.6 s: Mail can take
    /// longer than Safari between closing one menu and opening the next.)
    func ruleMenuGap(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        guard !isMenuOpen, let (mpid, at) = lastMenuClosed, mpid == pid, Date().timeIntervalSince(at) < 0.6 else { return .go(target) }
        let role = Role.from(axRole: target.role, subrole: target.string(kAXSubroleAttribute))
        guard !Self.menuRoles.contains(role) else { return .go(target) }
        Log.io("focus to \(target.role) just after a menu closed; waiting to see whether another opens")
        menuGapTarget = target
        if !menuGapRecheckPending {
            menuGapRecheckPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self else { return }
                self.menuGapRecheckPending = false
                let waited = self.menuGapTarget
                self.menuGapTarget = nil
                guard !self.isMenuOpen else { return }
                // The application may now answer with just its window (Safari loading the page typed into the
                // address bar, whose completion list was the menu): the element that took focus is the news.
                let now = AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute)
                if let w = waited, w.role != "AXWindow", w.element(kAXWindowAttribute) != nil, now == nil || now?.role == "AXWindow" {
                    Log.io("refocus after the menu gap: the application names only its window; taking the \(w.role) that took focus")
                    self.lastMenuClosed = nil
                    self.focusChanged(w, pid: pid)
                } else {
                    // The gap is over: a refocus asked for during it was diverted here and never presented, so this
                    // one must (the text area after a spelling menu was skipped as "again", and the arrows went
                    // quiet, 14 Oct 2026).
                    self.lastMenuClosed = nil
                    Log.io("focus after the menu gap: \(now?.role ?? "none")")
                    self.refocus(pid: pid)
                }
            }
        }
        return .done
    }

    /// Word hands focus back to the document under its menus; a menu open in the same application holds the focus back.
    func ruleMenuOpen(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        let role = Role.from(axRole: target.role, subrole: target.string(kAXSubroleAttribute))
        if isMenuOpen, !Self.menuRoles.contains(role), openMenus.contains(where: { $0.pid == pid }) {
            // A page's menu reports no close: focus landing elsewhere in the page means it has gone.
            if topMenuIsWeb, target.enclosingWebArea() != nil {
                Log.io("focus to \(target.role) in the page while its web menu was counted open: the menu has closed")
                openMenus.removeAll { $0.pid == pid }
                return .go(target)
            }
            Log.io("focus to \(target.role) while a menu is open in its application; ignored")
            return .ignore
        }
        return .go(target)
    }

    /// The window itself reported as the focus while a control inside it has it: a page in a tab you just left
    /// still says it is focused (Safari's Control+Tab), so if the window now shows another page, that page is the
    /// focus; Chromium and Electron apps send a focus event for the window while a control keeps the keyboard; and
    /// when the control has let go (Safari after Return in the address bar), the keys go to the page.
    func ruleWindowWhileControlHasKeys(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        guard target.role == "AXWindow", let f = API.focusObject, f.pid == pid, !f.isSameElement(as: target),
              f.element.element(kAXWindowAttribute).map({ $0.isSame(target) }) ?? false else { return .go(target) }
        let name = target.string(kAXTitleAttribute) ?? ""
        if let page = f.element.enclosingWebArea(), let shown = target.firstWebArea(), !shown.isSame(page) {
            Log.io("focus to the window \"\(Log.words(name))\": it shows another page now; to that page")
            return .follow(shown)
        }
        if (f.element.attr(kAXFocusedAttribute) as? Bool) != false {
            Log.io("focus to the window \"\(Log.words(name))\" while \(f.axRole) inside it has focus; ignored")
            return .ignore
        }
        if let web = target.firstWebArea() {
            Log.io("focus to the window \"\(Log.words(name))\" after \(f.axRole) let go; to its page")
            if f.axRole == "AXTextField", InputManager.lastKeyIdentifier == "kb:enter", Date().timeIntervalSince(InputManager.lastKeyDownAt) < 1 {
                // Whether the field was outside any page is asked only here, once a Return (16 Nov 2026, review).
                BrowseModeHandler.backFromAddressField = (Date(), web, f.element.enclosingWebArea() == nil)
            }
            return .follow(web)
        }
        // The control let go, but the app may only be passing the focus through its window on the way to the next
        // control: Reminders does it on every Tab between a reminder's title and its notes, and TurnOver said the
        // window and its list before each field (10 Oct 2026). Held a quarter of a second; said only if
        // nothing else takes the focus.
        let since = lastGainFocus?.1
        Log.io("focus to the window \"\(Log.words(name))\" after \(f.axRole) let go; held a moment")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.lastGainFocus?.1 == since, API.focusPid == pid else { return }
            Log.io("focus: nothing followed the window \"\(Log.words(name))\"; the window")
            self.present(target, pid: pid)
        }
        return .ignore
    }

    /// The window itself, already spoken as the foreground: take it as the focus quietly.
    func ruleWindowAlreadyPresented(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        if target.role == "AXWindow", focusWindow.map({ target.isSame($0) }) ?? false, Date().timeIntervalSince(lastForegroundAt) < 1.0 {
            let obj = ObjectFactory.make(target)
            focusWindow = target
            API.setFocusObject(obj, ancestors: obj.ancestors)
            // The review cursor goes with it (22 Nov 2026, issue 351): PS Remote Play's focus is its window, said as the
            // foreground, and with no cursor move TurnOver Right read the app left behind.
            ObjectNavigator.shared.focusMoved(to: target, pid: pid)
            return .done
        }
        return .go(target)
    }

    /// The element may carry the observed app's pid while its application ancestor is another process: the cursor
    /// service's window arrives this way through the Claude app's observer.
    func ruleOwnedByAnotherProcess(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        let obj = ObjectFactory.make(target)
        let ancestors = obj.ancestors
        madeForFocus = (target, obj, ancestors)
        if let top = ancestors.last, top.role == .application, top.pid != pid || top.pid != activePid {
            let owner = NSRunningApplication(processIdentifier: top.pid)
            let isContentProcess = (owner?.bundleIdentifier ?? "").hasPrefix("com.apple.WebKit.")   // Mail's message bodies live in WebContent
                || owner.map(isHelperOfActiveApp) ?? false   // Safari's Settings window is served by com.apple.Safari.SandboxBroker
            if !isContentProcess, owner == nil || owner?.activationPolicy == .prohibited {
                Log.io("focus on \(obj.axRole) \"\(Log.words(obj.name))\" owned by \(owner?.bundleIdentifier ?? "pid \(top.pid)") (not an application); ignored")
                return .ignore
            }
        }
        return .go(target)
    }

    // MARK: Presenting the new focus

    /// The focus is `target`: the ancestors newly entered, then the focus itself, as events.
    func present(_ target: AXUIElement, pid: pid_t) {
        let (obj, ancestors): (TurnOverObject, [TurnOverObject]) = {
            if let m = madeForFocus, m.element.isSame(target) { return (m.obj, m.ancestors) }
            let o = ObjectFactory.make(target); return (o, o.ancestors)
        }()
        madeForFocus = nil
        let window = target.element(kAXWindowAttribute)
        let old = API.focusObject
        let oldAncestors = API.focusAncestors
        focusWindow = window
        // The focus TurnOver moved itself, after its cursor (VoiceOver's "keyboard focus follows the cursor"): the
        // cursor has said it already, and stays where it is (on a row, while the list has the focus).
        if ObjectNavigator.shared.isFollowedFocus(obj.element) {
            if let old { EventHandler.queue(Event(.loseFocus, old)) }
            API.setFocusObject(obj, ancestors: ancestors, interceptor: BrowseModeHandler.shared.document(for: obj, ancestors: ancestors))
            Log.io("focus followed the cursor to \(obj.element.role); not spoken")
            return
        }
        if let old { EventHandler.queue(Event(.loseFocus, old)) }
        // Some apps rest the focus on a nameless group for a moment between items (Spring's timeline: every arrow went
        // tweet, nameless group, next tweet). The group says nothing, but its ancestors became the ones compared with,
        // so the list around the items was "entered" again and said ("Home, grouping"; 13 Oct 2026). Within
        // half a second of such a stop, the ancestors from before it count as known too.
        let namelessStop = obj.name.isEmpty && obj.element.role == "AXGroup"
        var known = oldAncestors
        if let b = beforeNamelessStop, Date().timeIntervalSince(b.at) < 0.5 {
            known += b.ancestors + (b.focus.map { [$0] } ?? [])
            if !namelessStop { Log.io("focus: passed through a nameless group; the ancestors from before it kept") }
        }
        if namelessStop {
            if beforeNamelessStop.map({ Date().timeIntervalSince($0.at) >= 0.5 }) ?? true { beforeNamelessStop = (oldAncestors, old, Date()) }
        } else {
            beforeNamelessStop = nil
        }
        let interceptor = BrowseModeHandler.shared.document(for: obj, ancestors: ancestors)
        interceptor?.noteFocusArrived(at: target)
        let fromOutside = interceptor !== API.focusTreeInterceptor
        // Automatic focus mode moving the keyboard to the field it has just named (17 Nov 2026: VO Right and F onto a
        // field in a named group said the group after the field, from the focus passing into it). The move is TurnOver's,
        // not the person's: no group it passes into is said. Tab, a click or the app's own move is said as ever.
        let ownFocusMove = interceptor?.isOwnCaretFocusMove(to: target, fromOutside: fromOutside) ?? false
        if ownFocusMove { Log.io("focus: automatic focus mode's own move to the \(target.role) it named; groups entered not said") }
        for a in ancestors.reversed() where a.isPresentableFocusAncestor {
            if ownFocusMove { continue }
            if known.contains(where: { $0.isSameElement(as: a) }) || old?.isSameElement(as: a) == true { continue }
            if let w = focusWindow, a.isSameElement(as: w) { continue }   // the window was presented as the foreground
            if let (el, at) = lastEntered, el.isSame(a.element), Date().timeIntervalSince(at) < 1.5 { continue }   // a sheet announced on creation
            // A cell with the same name as the button in it (WhatsApp's Settings): the button says it.
            if !a.name.isEmpty, a.name == obj.name { continue }
            // Tab on a page: the group the control sits in is not news (BrowseModeDocument.lastTabFromCaretAt).
            if a.role == .groupBox, Date().timeIntervalSince(BrowseModeDocument.lastTabFromCaretAt) < 1.0 { continue }
            lastEntered = (a.element, Date())
            EventHandler.queue(Event(.focusEntered, a))
        }
        lastGainFocus = (target, Date())
        // Into a document from outside it (another app, the window around the page): its focus event is told, as NVDA's
        // tree interceptor is (_enteringFromOutside).
        interceptor?.focusFromOutside = fromOutside
        API.setFocusObject(obj, ancestors: ancestors, interceptor: interceptor)
        ObjectNavigator.shared.focusMoved(to: obj.element, pid: pid)
        EventHandler.queue(Event(.gainFocus, obj))
        // 24 Nov 2026: the focus is presented as it always was; then, in the background, a check for a control that the
        // browser hides inside it and that has the keyboard (Steam's wishlist rows). Found, it is presented in turn.
        interceptor?.checkAfterArrival(at: target, role: obj.axRole)
    }

    /// A dialog or sheet is in front in this application: its focused window is one, or has one on it (Word's Save
    /// sheet is sometimes the focused window, sometimes a child of the document's).
    public static func modalInFront(pid: pid_t) -> Bool {
        guard let w = AXUIElementCreateApplication(pid).element(kAXFocusedWindowAttribute) else { return false }
        if w.role == "AXSheet" || ["AXDialog", "AXSystemDialog"].contains(w.string(kAXSubroleAttribute) ?? "") { return true }
        return w.elements(kAXChildrenAttribute).contains { $0.role == "AXSheet" }
    }

    func foregroundChanged(_ window: AXUIElement, appName: String?) {
        let obj = ObjectFactory.make(window)
        let subrole = obj.axSubrole ?? ""
        if subrole == "AXFloatingWindow" || subrole == "AXUnknown" { return }   // Word's "Cursor Actions" helper and the like
        let title = obj.name
        // Before the repeat check: a page titled Notification Center beneath the panel must not hide the transition.
        NotificationCentrePanel.noteForeground(window)
        if title == lastForegroundTitle, appName == nil { return }
        lastForegroundTitle = title
        lastForegroundAt = Date()
        focusWindow = window
        API.setForegroundObject(obj)
        EventHandler.queue(Event(.foreground, obj))
        if NotificationCentrePanel.isPanelOpeningForKey(window) {
            Log.io("foreground: Notification Centre's panel, for the key; the key says it")
            return
        }
        if subrole != "AXDesktop" { Tones.windowActivated() }   // not for the Finder's desktop, as VoiceOver
        if obj is Dialog { Tones.dialogAppeared() }
        let isDialog = obj.role == .dialog || obj.role == .sheet
        let shownTitle = appName == title ? "" : title
        // The app's name alone with the role is one phrase, as the language says it ("Finder penceresi" in Turkish);
        // in English as before: "Finder, window" in the Mac style, "Finder window" in the Windows style.
        let text = if let appName, !appName.isEmpty, shownTitle.isEmpty {
            switch (isDialog, config.general.windowsKeys) {
            case (false, false): String(localized: "\(appName), window", comment: "A window in front: %@ is its app (Mac style)")
            case (false, true): String(localized: "\(appName) window", comment: "A window in front: %@ is its app (Windows style)")
            case (true, false): String(localized: "\(appName), dialog", comment: "A dialog in front: %@ is its app (Mac style)")
            case (true, true): String(localized: "\(appName) dialog", comment: "A dialog in front: %@ is its app (Windows style)")
            }
        } else { Speech.joined([appName ?? "", shownTitle, (isDialog ? Role.dialog : Role.window).displayString]) }
        // The app module may say its own words for the window, or none (an empty string) (17 Nov 2026).
        let moduleWords = obj.appModule.windowAnnouncement(for: window, title: title)
        // a window's name: the display shows the focus in it
        if obj is Dialog {
            EventHandler.queue(Event(.focusEntered, obj))
        } else if let moduleWords {
            if !moduleWords.isEmpty { Speech.speakOnly(moduleWords) }
        } else {
            Speech.speakOnly(text)
        }
        // A window with nothing to read (OpenGL, custom drawing): said a moment later, with the recognition key (issue 74).
        if !(obj is Dialog), window.pid != ProcessInfo.processInfo.processIdentifier { EmptyWindowNotice.check(window, pid: window.pid) }
    }
}
