// SPDX-License-Identifier: GPL-3.0-or-later
// The accessibility API handler (NVDA: IAccessibleHandler / UIAHandler for
// Windows; here the one macOS API). It watches applications through
// AXObservers, keeps the focus and the foreground up to date, and turns each
// notification into an event for an object. Nothing here speaks; the objects
// and modules decide that.
//
// Measured on Word (30 Sep 2026): AXSelectedTextChanged on every caret move,
// AXFocusedUIElementChanged when the caret crosses a page, AXValueChanged noise
// from AutoSave labels and scroll bars with every move. The focus object is
// the only one whose value changes are spoken, so the noise costs an object
// construction and nothing else.
import Foundation
import AppKit
import ApplicationServices
import TurnOverAX

// Each accessibility notification becomes an event for an object; menus opening and closing; windows closing.
extension AXHandler {
    // MARK: Notifications → events


    /// What a log line says about an element: its description when the app is in front, else only the pid. Asking a
    /// background app (maybe hung) costs the main thread a wait for a log line; nothing is asked of it here.
    public static func logDescription(pid: pid_t, activePid: pid_t, _ describe: () -> String) -> String {
        pid == activePid ? describe() : "(pid \(pid), in the background; not asked)"
    }

    /// Whether a selection change is left unasked: an app in the background, busy, made the main thread wait 6 s in
    /// three unanswered questions about its list's selection, before the focus was even looked at (Mail, 16 Nov 2026
    /// at about 10:02 and 19:38 UTC; fixed 17 Nov 2026). Nothing is asked only when all four hold. Processes that
    /// never come to the front (the Dock's Command Tab switcher, menu extras, Notification Centre, system prompts)
    /// show their lists while another app is in front, and keep today's path untouched (the 15 Oct rule).
    nonisolated public static func skipsSelectionQuestions(pid: pid_t, activePid: pid_t, containerHoldsFocus: Bool,
                                                           focusPid: pid_t?, comesToFront: Bool) -> Bool {
        let notTheActiveApp = pid != activePid            // the app the keys go to is always asked
        let notTheFocusContainer = !containerHoldsFocus   // the list holding the focus is always asked
        let focusNotInThisApp = focusPid != pid           // a selection landing on the focus is always asked
        let anOrdinaryApp = comesToFront                  // agents and the Dock stay on today's path
        return notTheActiveApp && notTheFocusContainer && focusNotInThisApp && anOrdinaryApp
    }

    func notification(_ name: String, _ element: AXUIElement, _ info: [String: Any]?) {
        Core.noteMainWork(name, pid: element.pid)   // for the watchdog's trip line (17 Nov 2026)
        lastNewsAt[element.pid] = Date()
        AXHealth.heardFrom(pid: element.pid)   // a sign of life: what was silent in the app is looked at again now
        guard running else { return }
        let pid = element.pid
        // A banner from Notification Centre (a message, a calendar alert): read as it appears, as VoiceOver and NVDA do
        // (a tester, 6 Oct 2026). The banner is a group of subrole AXNotificationCenterAlert, with title, subtitle and
        // body texts, in a "Notification Center" window (measured 8 Oct 2026).
        if pid == notificationCentrePid, [kAXCreatedNotification, kAXWindowCreatedNotification, kAXLayoutChangedNotification].contains(name) {
            NotificationCentrePanel.cursorBackIfStranded()
            announceNotificationsSoon()
            return
        }
        switch name {
        case kAXFocusedUIElementChangedNotification:
            if API.focusTreeInterceptor != nil, element.role == "AXWebArea" {
                if Date().timeIntervalSince(lastWebAreaFocus) < 0.2 { webAreaFocusSkipped += 1; return }
                if webAreaFocusSkipped > 0 { Log.io("skipped \(webAreaFocusSkipped) web area focus events in a burst"); webAreaFocusSkipped = 0 }
                lastWebAreaFocus = Date()
            }
            focusChanged(element, pid: pid)
        case kAXFocusedWindowChangedNotification:
            foregroundChanged(element, appName: nil)
            // The window's own focus follows; if the app does not say, ask it.
            if let app = observers[pid].map({ _ in AXUIElementCreateApplication(pid) }), let f = app.element(kAXFocusedUIElementAttribute), !f.isSame(element) {
                focusChanged(f, pid: pid)
            }
            // Word, closing its Find bar with Escape, gives the document back its focus a moment later and says
            // nothing: only "Document1, window" was heard (7 Oct 2026). Ask again once it has settled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, pid == self.activePid else { return }
                let app = AXUIElementCreateApplication(pid)
                // (Only while TurnOver's focus is still in another window: Word's table cells are TurnOver's own
                // objects, and asking again took the caret "out of table" as a table was inserted.)
                guard let f = app.element(kAXFocusedUIElementAttribute), f.element(kAXWindowAttribute)?.isSame(element) == true,
                      !(API.focusObject.map { $0.element.isSame(f) } ?? false),
                      !(API.focusObject?.element.element(kAXWindowAttribute)?.isSame(element) ?? false) else { return }
                Log.io("focus after a window change, asked again: \(f.role)")
                self.focusChanged(f, pid: pid)
            }
        case kAXSelectedTextChangedNotification:
            EventHandler.queue(Event(.caret, object(for: element)))
        case kAXValueChangedNotification:
            // Safari sends a thousand of these a second for dying elements while a page loads; only the focus's matter,
            // and elements a plugin watches (a status line, a progress bar) in the application in front.
            // The progress bar being watched beeps as it moves (ProgressWatch); the event goes on as before.
            ProgressWatch.valueChanged(element)
            if let f = API.focusObject, f.isSameElement(as: element) { EventHandler.queue(Event(.valueChange, f)); return }
            if pid == activePid, !ProfileStore.shared.profiles(for: ProfileStore.shared.bundle(of: pid)).isEmpty,
               ProfileStore.shared.watchRule(for: element, pid: pid) != nil {
                EventHandler.queue(Event(.valueChange, ObjectFactory.make(element)))
            }
        case kAXTitleChangedNotification:
            // The front window's title changing because of a key (Control+Tab to another tab, Command+1 to another
            // mailbox) is the news of where you are (NVDA reads a foreground name change). Not without a key: Mail
            // retitles its window as mail arrives.
            // The app in front first: Mail retitles its window as mail arrives, and asking a busy background app its
            // role cost the main thread a wait (17 Nov 2026). Only the order changed; each test is free of side effects.
            if pid == activePid, let w = focusWindow, w.isSame(element), element.role == "AXWindow",
               Date().timeIntervalSince(InputManager.lastKeyDownAt) < 2, Self.switchesView(InputManager.lastKeyIdentifier),
               let t = element.string(kAXTitleAttribute), !t.isEmpty, t != lastForegroundTitle {
                lastForegroundTitle = t
                if let f = API.focusObject, f.axRole == "AXWebArea", f.pid == pid, Speech.sinceFocusSpoken < 0.6 {
                    // The page took focus a moment before its title arrived: the title first, then where you are in it.
                    Speech.cancel()
                    Speech.speakMessage(t)
                    Speech.speakObject(f, reason: .focus)
                } else {
                    Speech.speakMessage(t)
                }
            }
            guard let f = API.focusObject, f.isSameElement(as: element) else { return }
            EventHandler.queue(Event(.nameChange, f))
        case kAXMenuOpenedNotification:
            // Claude 5.1231.2, macOS 27.2, 14 Nov 2026: slash suggestions and Effort
            // submenus announce AXGroup, not AXMenu. Let the opt-in module own them.
            if element.role == "AXGroup", AppModuleHandler.shared.appModule(for: pid).handlesGroupMenus {
                guard pid == activePid else { return }
                EventHandler.queue(Event(.menuStart, ObjectFactory.make(element)))
                return
            }
            guard element.role == "AXMenu" else { Log.io("menu opened on a \(element.role); not a menu, ignored"); return }
            // A page's own navigation (role="menu") announces itself as a menu opening while the page loads, and
            // never closes: it held Safari's focus back for a whole visit and ate the letters typed in the next app
            // as menu type-ahead (17 Oct 2026). A popup needs a key; the page's structure arrives without one.
            if Date().timeIntervalSince(InputManager.lastKeyDownAt) > 2, MenuNavigationPlugin.isWebMenu(element) {
                Log.io("menu opened in a web page with no key for 2 s: the page's own menu, not counted")
                return
            }
            menuOpened(element)
        case kAXMenuClosedNotification:
            if element.role == "AXGroup", AppModuleHandler.shared.appModule(for: pid).handlesGroupMenus {
                guard pid == activePid else { return }
                EventHandler.queue(Event(.menuEnd, ObjectFactory.make(element)))
                return
            }
            let before = openMenus.count
            openMenus.removeAll { $0.isSame(element) }
            if openMenus.count == before { openMenus.removeAll { $0.role != "AXMenu" } }
            if openMenus.count == before, before > 0 { Log.io("menu closed under another identity; clearing \(before) open menus"); openMenus.removeAll() }
            if element.role == "AXMenu" { EventHandler.queue(Event(.menuEnd, ObjectFactory.make(element))) }
            // Only a real menu closing opens the gap: Safari's address completions (a scroll area, never counted as
            // open) closing made the next focus wait and the window get read ("Boson - Wikipedia, window").
            if openMenus.isEmpty, before > 0 || element.role == "AXMenu" { lastMenuClosed = (pid, Date()) }
        case kAXMenuItemSelectedNotification:
            // A keyboard shortcut also "selects" its menu item (Cmd+A: "Select All"); only a menu the user is in counts.
            if isMenuOpen { focusChanged(element, pid: pid) } else { Log.debug("menu item selected by shortcut: \(Self.logDescription(pid: pid, activePid: activePid) { element.string(kAXTitleAttribute) ?? "" })") }
        case kAXLayoutChangedNotification, "AXLiveRegionChanged", "AXLoadComplete":
            if name == "AXLiveRegionChanged", pid == activePid { EventHandler.queue(Event(.liveRegionChange, ObjectFactory.make(element))) }
            if let d = API.focusTreeInterceptor, d.webArea.pid == pid {
                d.buffer.isDirty = true
                // Back, Forward or a link: the page in this web area changed. Once it settles, resume where it was left.
                if !navigationCheckPending {
                    navigationCheckPending = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + (name == "AXLoadComplete" ? 0.1 : 0.6)) { [weak self] in
                        self?.navigationCheckPending = false
                        guard let d2 = API.focusTreeInterceptor, d2 === d, !ScriptHandler.isScriptRunning else { return }
                        if d2.refreshIfNavigated(announce: !d2.passThrough) { Log.io("browse mode: page changed under the document (\(name))") }
                        else { d2.loadedAfterBlank(announce: !d2.passThrough) }
                    }
                }
            }
        case kAXWindowCreatedNotification, kAXDrawerCreatedNotification, kAXHelpTagCreatedNotification, kAXSelectedColumnsChangedNotification,
             kAXCreatedNotification, kAXRowCountChangedNotification,
             kAXMainWindowChangedNotification, kAXElementBusyChangedNotification, "AXLiveRegionCreated":
            // Role and title only, and at most 20 a second: a loading page or an 800-row list sends hundreds, each
            // costing the main thread four round trips for a log line (a code review, 14 Oct 2026).
            // A second window: does this app list every window's elements under each (Qt Quick)? Checked once it does.
            if name == kAXWindowCreatedNotification {
                if !ForeignChildren.contains(pid) { ForeignChildren.check(pid: pid) }
            }
            if Date().timeIntervalSince(loggedOnlyWindow) > 1 { loggedOnlyWindow = Date(); loggedOnlyCount = 0 }
            loggedOnlyCount += 1
            if loggedOnlyCount <= 20 {
                // Only the front app is asked what the element is: a background app that is hung made every one of
                // these reads wait on the main thread and froze the keys for 4 s (Mail, 15 Nov 2026).
                Log.io("notification \(name): " + Self.logDescription(pid: pid, activePid: activePid) { "\(element.role) \"\(Log.words(element.string(kAXTitleAttribute) ?? ""))\"" })
            }
            else if loggedOnlyCount == 21 { Log.io("notifications: more than 20 this second; the rest not logged") }
        case kAXSelectedCellsChangedNotification:
            // A grid that moves its selection without moving the focus: Excel says only "selected cells changed" on
            // each arrow, and its focused cell catches up seconds later, if at all (Day 2, 10 Oct 2026). Where the
            // focus is in this grid, the one cell selected is the new focus (a range keeps the focus where it is).
            Log.io("notification \(name): " + Self.logDescription(pid: pid, activePid: activePid) { "\(element.role) \"\(Log.words(element.string(kAXTitleAttribute) ?? element.string(kAXDescriptionAttribute) ?? ""))\"" })
            guard pid == activePid, let f = API.focusObject,
                  f.isSameElement(as: element) || API.focusAncestors.contains(where: { $0.isSameElement(as: element) }) else { return }
            // Counted, not fetched: a whole column selected is a million cells.
            var count: CFIndex = 0
            AXUIElementGetAttributeValueCount(element, "AXSelectedCells" as CFString, &count)
            if AppModuleHandler.shared.appModule(for: pid).gridSelectionChanged(element, count: count) { return }
            var first: CFArray?
            guard count == 1, AXUIElementCopyAttributeValues(element, "AXSelectedCells" as CFString, 0, 1, &first) == .success,
                  var cell = (first as? [AXUIElement])?.first else { return }
            // Excel's selected cell is a wrapper with no name; the cell with the address and value is inside it.
            let inner = cell.elements(kAXChildrenAttribute)
            if inner.count == 1, inner[0].role == "AXCell" { cell = inner[0] }
            guard !f.element.isSame(cell), !Self.sameControl(f.element, cell) else { return }
            focusChanged(cell, pid: pid)
        case kAXSelectedChildrenChangedNotification, kAXSelectedRowsChangedNotification:
            // Several rows highlighted at once (Shift Down, Command click): the row that just changed is said, then
            // how many are selected, as VoiceOver does; the first selected row was said every time (16 Oct
            // 2026). Counted first, so a whole column of a million never comes across; at most 200 rows fetched.
            // Whether the focus is in this list is known without asking the app, so it is decided first (17 Nov 2026).
            let focused = API.focusObject.map { f in f.isSameElement(as: element) || API.focusAncestors.contains(where: { $0.isSameElement(as: element) }) } ?? false
            if Self.skipsSelectionQuestions(pid: pid, activePid: activePid, containerHoldsFocus: focused, focusPid: API.focusObject?.pid,
                                            comesToFront: NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular) {
                Log.io("selection changed: (pid \(pid), in the background; not asked)")
                // What was known of this list's selection is out of date now.
                if lastSelectedRows?.container.isSame(element) == true { lastSelectedRows = nil }
                return
            }
            // Through the health check (17 Nov 2026): these were raw calls, each waiting the full 2 s on an app that
            // did not answer, unnoted, so the next one waited again. Now a timeout rests the app and the rest fail at
            // once. An answer gives what the raw calls gave: the rows if any are selected, else the children; the
            // count; at most 200 fetched. A failed count is 0, as before.
            let rowCount = element.attributeValueCountResult(kAXSelectedRowsAttribute).value ?? 0
            let key = rowCount > 0 ? kAXSelectedRowsAttribute : kAXSelectedChildrenAttribute
            let count = key == kAXSelectedRowsAttribute ? rowCount : (element.attributeValueCountResult(key).value ?? 0)
            var all: [AXUIElement] = []
            if count > 0 { all = (element.attributeValuesResult(key, index: 0, maxValues: min(count, 200)).value as? [AXUIElement]) ?? [] }
            let before = lastSelectedRows?.container.isSame(element) == true ? (lastSelectedRows?.rows ?? []) : []
            lastSelectedRows = (element, all)
            if count > 1 {
                let added = all.filter { a in !before.contains { $0.isSame(a) } }
                let removed = before.filter { b in !all.contains { $0.isSame(b) } }
                guard focused, let target = added.last ?? removed.last ?? all.last else { return }
                TurnOverObject.selectionNote = (removed.isEmpty || !added.isEmpty ? "" : "not selected, ") + "\(count) selected"
                lastSelectionReport = (target, Date())
                EventHandler.queue(Event(.selection, ObjectFactory.make(target)))
                return
            }
            if count == 0, before.count > 0, focused, element.elements(kAXChildrenAttribute).first(where: { ($0.attr(kAXFocusedAttribute) as? Bool) == true }) == nil {
                // A context menu just asked for takes the selection with it (the Dock's item menu): not news.
                if Self.menuJustAsked(requestedAt: TurnOverObject.contextMenuRequestedAt, now: Date(), menuOpen: isMenuOpen) { return }
                Speech.speakMessage(String(localized: "nothing selected", comment: "Spoken message")); return
            }
            // The Dock's Cmd+Tab list marks its highlighted item focused rather than selected.
            guard let selected = all.first ?? element.elements(kAXChildrenAttribute).first(where: { ($0.attr(kAXFocusedAttribute) as? Bool) == true }) else { return }
            if let (last, at) = lastSelectionReport, last.isSame(selected), Date().timeIntervalSince(at) < 0.4 { return }
            lastSelectionReport = (selected, Date())
            // Only the focused container's selection matters (a sidebar changing under a dialog does not).
            if focused || API.focusObject?.isSameElement(as: selected) == true {
                EventHandler.queue(Event(.selection, ObjectFactory.make(selected)))
            }
        case kAXRowExpandedNotification, kAXRowCollapsedNotification:
            EventHandler.queue(Event(.stateChange, object(for: element)))
        case kAXSheetCreatedNotification:
            if let (last, at) = lastSheet, last.isSame(element), Date().timeIntervalSince(at) < 1 { return }
            lastSheet = (element, Date())
            lastEntered = (element, Date())
            let obj = ObjectFactory.make(element)
            lastForegroundTitle = obj.name
            focusWindow = element
            API.setForegroundObject(obj)
            EventHandler.queue(Event(.focusEntered, obj))
        case kAXAnnouncementRequestedNotification:
            // Safari announces "Page Menu, Reader Available" as each page loads, sometimes twice: the same news once.
            if let text = info?["AXAnnouncementKey"] as? String, !text.isEmpty {
                if text == lastAnnouncement.0, Date().timeIntervalSince(lastAnnouncement.1) < 30,
                   !AppModuleHandler.shared.appModule(for: pid).announcementRepeatIsNews(text) { Log.io("announcement repeated; skipped"); break }
                // Not into the middle of a page being read ("Page Menu, Reader Available" between its lines).
                if SayAll.isRunning { Log.io("announcement during say all; skipped: \(Log.words(text))"); break }
                // iTerm2 announces each piece of new output itself; TurnOver's terminal reads it already (it was heard
                // twice, parts sweep 15 Oct 2026).
                if API.focusObject is TerminalText, API.focusObject?.pid == pid { Log.io("terminal's own announcement; TurnOver reads the output itself"); break }
                if AppModuleHandler.shared.appModule(for: pid).ignoresAnnouncement(text, after: InputManager.lastKeyIdentifier,
                        elapsed: Date().timeIntervalSince(InputManager.lastKeyDownAt)) {
                    Log.io("app module suppressed a native announcement: \(Log.words(text))"); break
                }
                lastAnnouncement = (text, Date())
                Speech.speakMessage(text)
                // After the speech is queued and every skip above: a module hears only what was really said.
                AppModuleHandler.shared.appModule(for: pid).announcementSpoken(text)
            }
        default:
            break
        }
    }

    /// The object for a notification: the live focus object when it is the same element, so its state carries.
    func object(for element: AXUIElement) -> TurnOverObject {
        if let f = API.focusObject, f.isSameElement(as: element) { return f }
        return ObjectFactory.make(element)
    }

    /// A menu was closed by an action the application does not report (Word's menu-bar items chosen by press).
    public func menusClosed() {
        if !openMenus.isEmpty { Log.io("menus cleared: \(openMenus.count) were open"); openMenus.removeAll() }
    }


    /// Keys that show another tab, mailbox or page in the same window. Only after these is a new window title news:
    /// Terminal retitles its window as the shell starts and with every cd, and that is noise.
    static func switchesView(_ key: String) -> Bool {
        let k = key.replacingOccurrences(of: "kb:", with: "")
        // Not Back and Forward: Safari's title is the bare address until the page arrives, and the page reads itself.
        if ["control+tab", "control+shift+tab", "command+shift+[", "command+shift+]", "command+w"].contains(k) { return true }
        if k.hasPrefix("command+"), let last = k.last, last.isNumber, k.count == "command+1".count { return true }
        return false
    }

    /// Command+W closed a window. If it was the application's last, nothing reports a new focus: TurnOver stayed on
    /// the closed message and the arrows read it ("top, blank", Mail, 3 Oct 2026). Say so, and let the page go. If a
    /// window is left but the old focus has gone with the closed one, read the focus again.
    public func afterWindowClose(pid: pid_t) {
        guard pid == activePid, running else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        let all = app.elements(kAXWindowsAttribute)
        let open = all.filter { ($0.attr(kAXMinimizedAttribute) as? Bool) != true }
        if open.isEmpty {
            Log.io("window closed: no window left")
            API.setFocusObject(ObjectFactory.make(app), ancestors: [])
            let minimised = all.count
            Speech.speakMessage(minimised == 0 ? String(localized: "no windows", comment: "An app with no windows") : String(localized: "no windows open, \(String(minimised)) minimised", comment: "Spoken message: %@ is how many windows are in the Dock"))
            return
        }
        if let f = API.focusObject, f.pid == pid, f.element.role == "?" || f.element.element(kAXWindowAttribute) == nil {
            Log.io("window closed: the focus went with it; reading it again")
            refocus(pid: pid)
        }
    }

    nonisolated enum DriveAlertFocus: Sendable {
        case replacement(focus: AXUIElement, window: AXUIElement?)
        case closed
    }

    /// Drive can dismiss its window without sending a window or focus event.
    func recoverFocusAfterDriveAlertPress(button: AXUIElement, page: BrowseModeDocument) {
        guard running, let visit = ApplicationChooser.driveAlertVisit, visit.pid == page.webArea.pid,
              activePid == visit.pid, let old = API.focusObject, old.isSameElement(as: button),
              (focusWindow ?? API.foregroundObject?.element)?.isSame(visit.window) == true else { return }
        let press = UUID()
        driveAlertPress = press
        Log.io("Google Drive alert: checking focus after a button press")
        let keys = ScriptHandler.keysArrivedCount
        let stillCurrent: @MainActor @Sendable () -> Bool = { [self] in
            running && activePid == visit.pid && ScriptHandler.keysArrivedCount == keys &&
            driveAlertPress == press && ApplicationChooser.driveAlertVisit?.window.isSame(visit.window) == true &&
            API.focusObject === old && API.focusTreeInterceptor === page &&
            MenuNavigationPlugin.heldBar == nil && MenuNavigationPlugin.heldStatus == nil
        }
        let read: @MainActor @Sendable () -> Void = { [self] in
            guard stillCurrent(), let front = NSWorkspace.shared.frontmostApplication else { return }
            if front.processIdentifier != visit.pid {
                if front.activationPolicy == .regular { self.appActivated(front) }
                return
            }
            let pid = visit.pid
            let oldWindow = visit.window
            self.driveAlertFocusRead.submit(collect: { request in
                let budget = AXWalkBudget(request: request, duration: 150_000_000, maxAXQueries: 6)
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.15)
                return AXReadScope.with(while: { budget.check() }, onQuery: { budget.admitAXQuery() },
                                        onResult: { budget.record($0) }) {
                    let focus = Self.driveAlertFocus(in: app, oldButton: button, oldWindow: oldWindow)
                    return budget.check() ? focus : nil
                }
            }, publish: { answer in
                guard let answer, stillCurrent(),
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                switch answer {
                case let .replacement(focus, window):
                    self.driveAlertPress = nil
                    Log.io("Google Drive alert: the app reported replacement focus")
                    if let window { self.foregroundChanged(window, appName: nil) }
                    self.focusChanged(focus, pid: pid)
                case .closed:
                    guard !visit.previous.isTerminated, visit.previous.activationPolicy == .regular else { return }
                    if visit.previous.activate() {
                        self.driveAlertPress = nil
                        ApplicationChooser.driveAlertVisit = nil
                        Log.io("Google Drive alert closed: returning to the application left by the chooser")
                    }
                }
            })
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20, execute: read)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: read)
    }

    nonisolated package static func driveAlertEnded(in app: AXUIElement) -> Bool {
        let (value, result) = app.attrError(kAXWindowsAttribute)
        return result == .success && (value as? [AXUIElement])?.isEmpty == true
    }

    nonisolated static func driveAlertFocus(in app: AXUIElement, oldButton: AXUIElement,
                                            oldWindow: AXUIElement) -> DriveAlertFocus? {
        // Ask for the window list before reading focus. Immediately after dismissal, an old focus element can
        // report invalid UI element, which ends the read budget even when the application is answering.
        if driveAlertEnded(in: app) { return .closed }
        guard let replacement = browseButtonReplacement(in: app, oldButton: oldButton, oldWindow: oldWindow) else { return nil }
        return .replacement(focus: replacement.focus, window: replacement.window)
    }

    nonisolated package static func browseButtonReplacement(in app: AXUIElement, oldButton: AXUIElement,
                                                             oldWindow: AXUIElement?) -> (focus: AXUIElement, window: AXUIElement?)? {
        // The created window may be a background window. Only use the window the app itself says has focus.
        let window = app.element(kAXFocusedWindowAttribute)
        let newWindow = window.flatMap { candidate in
            oldWindow?.isSame(candidate) == false && candidate.role == "AXWindow" ? candidate : nil
        }
        if let focus = app.element(kAXFocusedUIElementAttribute), !focus.isSame(oldButton) {
            let role = focus.role
            let inFocusedWindow = newWindow.map { focus.isSame($0) || focus.element(kAXWindowAttribute)?.isSame($0) == true } ?? true
            if role != "?", !role.isEmpty, role != "AXApplication", inFocusedWindow {
                return (focus, newWindow)
            }
        }
        return newWindow.map { ($0, $0) }
    }

    public func refocus(pid: pid_t) {
        guard pid != 0, running else { return }
        // While TurnOver holds the menu bar or the status menus (Mac style, VO M), the application's focus is not
        // news: it spoke over "Apple menu, 1 of 10" (a tester, 8 Oct 2026).
        guard MenuNavigationPlugin.heldBar == nil, MenuNavigationPlugin.heldStatus == nil else { Log.io("refocus skipped: the menu bar is held"); return }
        let app = AXUIElementCreateApplication(pid)
        guard let f = app.element(kAXFocusedUIElementAttribute) else { return }
        // The same element again within a moment (two Escapes closing two menus each set a watch, and the message
        // row was read three times, 8 Oct 2026): once is enough.
        // Once is enough only when that refocus was presented: one diverted into the menu gap never was.
        if let (el, at) = lastRefocus, el.isSame(f), Date().timeIntervalSince(at) < 1.5, API.focusObject?.isSameElement(as: f) == true {
            Log.io("refocus: \(f.role) again; skipped"); return
        }
        lastRefocus = (f, Date())
        Log.io("refocus: \(f.role)")
        focusChanged(f, pid: pid)
    }

}
