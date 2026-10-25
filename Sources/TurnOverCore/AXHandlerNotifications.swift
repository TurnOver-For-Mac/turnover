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


    func notification(_ name: String, _ element: AXUIElement, _ info: [String: Any]?) {
        lastNewsAt[element.pid] = Date()
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
            if let f = API.focusObject, f.isSameElement(as: element) { EventHandler.queue(Event(.valueChange, f)); return }
            if pid == activePid, !ProfileStore.shared.profiles(for: ProfileStore.shared.bundle(of: pid)).isEmpty,
               ProfileStore.shared.watchRule(for: element, pid: pid) != nil {
                EventHandler.queue(Event(.valueChange, ObjectFactory.make(element)))
            }
        case kAXTitleChangedNotification:
            // The front window's title changing because of a key (Control+Tab to another tab, Command+1 to another
            // mailbox) is the news of where you are (NVDA reads a foreground name change). Not without a key: Mail
            // retitles its window as mail arrives.
            if element.role == "AXWindow", let w = focusWindow, w.isSame(element), pid == activePid,
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
            guard element.role == "AXMenu" else { Log.io("menu opened on a \(element.role); not a menu, ignored"); return }
            // A page's own navigation (role="menu") announces itself as a menu opening while the page loads, and
            // never closes: it held Safari's focus back for a whole visit and ate the letters typed in the next app
            // as menu type-ahead (17 Oct 2026). A popup needs a key; the page's structure arrives without one.
            if Date().timeIntervalSince(InputManager.lastKeyDownAt) > 2, MenuNavigationPlugin.isWebMenu(element) {
                Log.io("menu opened in a web page with no key for 2 s: the page's own menu, not counted")
                return
            }
            openMenus.removeAll { $0.isSame(element) }
            openMenus.append(element)
            menuOpenedAt = Date()
            logMenu(element)
            // Word opens its context menu and every submenu at once: one announcement.
            if Date().timeIntervalSince(lastMenuStart) > 0.5 { EventHandler.queue(Event(.menuStart, ObjectFactory.make(element))) }
            lastMenuStart = Date()
        case kAXMenuClosedNotification:
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
            if isMenuOpen { focusChanged(element, pid: pid) } else { Log.debug("menu item selected by shortcut: \(element.string(kAXTitleAttribute) ?? "")") }
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
                        else if d2.loadedAfterBlank(announce: !d2.passThrough) { Log.io("browse mode: page finished loading (\(name))") }
                    }
                }
            }
        case kAXWindowCreatedNotification, kAXDrawerCreatedNotification, kAXHelpTagCreatedNotification, kAXSelectedColumnsChangedNotification,
             kAXCreatedNotification, kAXRowCountChangedNotification,
             kAXMainWindowChangedNotification, kAXElementBusyChangedNotification, "AXLiveRegionCreated":
            // Role and title only, and at most 20 a second: a loading page or an 800-row list sends hundreds, each
            // costing the main thread four round trips for a log line (a code review, 14 Oct 2026).
            // A second window: does this app list every window's elements under each (Qt Quick)? Checked once it does.
            if name == kAXWindowCreatedNotification, !ForeignChildren.contains(pid) { ForeignChildren.check(pid: pid) }
            if Date().timeIntervalSince(loggedOnlyWindow) > 1 { loggedOnlyWindow = Date(); loggedOnlyCount = 0 }
            loggedOnlyCount += 1
            if loggedOnlyCount <= 20 { Log.io("notification \(name): \(element.role) \"\(Log.words(element.string(kAXTitleAttribute) ?? ""))\"") }
            else if loggedOnlyCount == 21 { Log.io("notifications: more than 20 this second; the rest not logged") }
        case kAXSelectedCellsChangedNotification:
            // A grid that moves its selection without moving the focus: Excel says only "selected cells changed" on
            // each arrow, and its focused cell catches up seconds later, if at all (Day 2, 10 Oct 2026). Where the
            // focus is in this grid, the one cell selected is the new focus (a range keeps the focus where it is).
            Log.io("notification \(name): \(element.role) \"\(Log.words(element.string(kAXTitleAttribute) ?? element.string(kAXDescriptionAttribute) ?? ""))\"")
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
            let key = { () -> String in var n: CFIndex = 0; AXUIElementGetAttributeValueCount(element, kAXSelectedRowsAttribute as CFString, &n); return n > 0 ? kAXSelectedRowsAttribute : kAXSelectedChildrenAttribute }()
            var count: CFIndex = 0
            AXUIElementGetAttributeValueCount(element, key as CFString, &count)
            var all: [AXUIElement] = []
            if count > 0 { var arr: CFArray?; if AXUIElementCopyAttributeValues(element, key as CFString, 0, min(count, 200), &arr) == .success { all = (arr as? [AXUIElement]) ?? [] } }
            let focused = API.focusObject.map { f in f.isSameElement(as: element) || API.focusAncestors.contains(where: { $0.isSameElement(as: element) }) } ?? false
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
                if text == lastAnnouncement.0, Date().timeIntervalSince(lastAnnouncement.1) < 30 { Log.io("announcement repeated; skipped"); break }
                // Not into the middle of a page being read ("Page Menu, Reader Available" between its lines).
                if SayAll.isRunning { Log.io("announcement during say all; skipped: \(Log.words(text))"); break }
                // iTerm2 announces each piece of new output itself; TurnOver's terminal reads it already (it was heard
                // twice, parts sweep 15 Oct 2026).
                if API.focusObject is TerminalText, API.focusObject?.pid == pid { Log.io("terminal's own announcement; TurnOver reads the output itself"); break }
                // Word says "Bold" or "Plain" for Command B, I and U; TurnOver's Word module says which ("bold off"):
                // both were heard, and flashed on the display one after the other (7 Oct 2026).
                if NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.microsoft.Word",
                   Date().timeIntervalSince(InputManager.lastKeyDownAt) < 0.8,
                   ["kb:command+b", "kb:command+i", "kb:command+u"].contains(InputManager.lastKeyIdentifier) {
                    Log.io("Word's own formatting announcement; TurnOver says it: \(Log.words(text))"); break
                }
                lastAnnouncement = (text, Date())
                Speech.speakMessage(text)
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
            Speech.speakMessage(minimised == 0 ? "no windows" : "no windows open, \(minimised) minimised")
            return
        }
        if let f = API.focusObject, f.pid == pid, f.element.role == "?" || f.element.element(kAXWindowAttribute) == nil {
            Log.io("window closed: the focus went with it; reading it again")
            refocus(pid: pid)
        }
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
