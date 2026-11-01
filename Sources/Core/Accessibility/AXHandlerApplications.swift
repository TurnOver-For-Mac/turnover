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

// Applications coming to the front, their first window, their observers (NVDA: appModuleHandler + the focus settling after a switch).
extension AXHandler {
    // MARK: Applications

    func appActivated(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != getpid() else { return }
        if pid == activePid { return }
        let old = activePid
        activePid = pid
        Log.io("app activated: \(app.localizedName ?? "?") pid \(pid)")
        // An application's menus close when it leaves the front; one still counted open would take the letters
        // typed in the application now in front as menu type-ahead (Safari's page menu ate "in safari" in Claude).
        if old != 0, openMenus.contains(where: { $0.pid == old }) {
            Log.io("menus of the application that left the front dropped: \(openMenus.filter { $0.pid == old }.count)")
            openMenus.removeAll { $0.pid == old }
        }
        ProfileStore.shared.reload()   // a plugin just written or edited applies on the next visit to its app
        observe(pid)
        let module = AppModuleHandler.shared.appModule(for: pid)
        if old != 0, let oldModule = observers[old].map({ _ in AppModuleHandler.shared.appModule(for: old) }) { oldModule.event_appModuleLoseFocus() }
        module.event_appModuleGainFocus()
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 1.0)
        lastForegroundTitle = ""
        // Touch ID or an administrator's password (coreautha, SecurityAgent) coming forward: its message first ("App
        // Store is trying to authenticate your Apple Account… Touch ID or enter your password"), then its button,
        // not "coreautha, Untitled, window" (7 Oct 2026).
        if let b = app.bundleIdentifier, SystemPrompts.agents.contains(b) {
            SystemPrompts.shared.announceFront(pid: pid)
            return
        }
        // A system prompt (UserNotificationCenter's "wants access to control…") has a window but no focused window.
        let firstWindow = appEl.element(kAXFocusedWindowAttribute) ?? appEl.elements(kAXWindowsAttribute).first
        if let win = firstWindow {
            foregroundChanged(win, appName: app.localizedName)
        } else {
            // Just launched and no window yet: say so, so the wait is not mistaken for silence.
            let launching = app.launchDate.map { Date().timeIntervalSince($0) < 10 } ?? false
            Speech.speakOnly((app.localizedName ?? "application") + (launching ? ", starting" : ""))   // the display shows the focus
        }
        if let focused = appEl.element(kAXFocusedUIElementAttribute) { focusChanged(focused, pid: pid) }
        else if let win = firstWindow { focusChanged(win, pid: pid) }
        else { waitForFirstWindow(pid: pid, name: app.localizedName, tries: 12) }
        if API.focusObject?.pid == pid, API.focusObject?.role == .window { settleFocus(pid: pid, tries: 6) }
        // A system prompt still open behind this app: said after the app, with the way back to it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { SystemPrompts.shared.remindIfWaiting(activated: pid) }
    }

    /// An application just launched (Safari restoring its windows) has no window yet and may say nothing when one
    /// appears: ask again until it has one, so Tab and the arrows have somewhere to go.
    func waitForFirstWindow(pid: pid_t, name: String?, tries: Int) {
        guard tries > 0 else { Log.io("no window appeared in \(name ?? "pid \(pid)")"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.activePid == pid, API.focusObject?.pid != pid else { return }
            let appEl = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appEl, 1.0)
            guard let win = appEl.element(kAXFocusedWindowAttribute) ?? appEl.elements(kAXWindowsAttribute).first else { self.waitForFirstWindow(pid: pid, name: name, tries: tries - 1); return }
            Log.io("first window of \(name ?? "pid \(pid)") appeared")
            // Asked again now there is a window: Excel, opened cold, built no grid for an assistive app when asked only
            // as it started (no cells, no news on the arrows; Day 3, 10 Oct 2026). Off and on, so the app sees a change.
            _ = appEl.set("AXEnhancedUserInterface", kCFBooleanFalse)
            _ = appEl.set("AXEnhancedUserInterface", kCFBooleanTrue)
            _ = appEl.set("AXManualAccessibility", kCFBooleanTrue)
            self.lastForegroundTitle = ""
            self.foregroundChanged(win, appName: nil)
            self.focusChanged(appEl.element(kAXFocusedUIElementAttribute) ?? win, pid: pid)
            self.settleFocus(pid: pid, tries: 10)
        }
    }

    /// A just-launched application puts focus on its content a moment after its window appears, and Safari says
    /// nothing when it does. While TurnOver's focus is still the bare window, keep asking where focus is.
    func settleFocus(pid: pid_t, tries: Int) {
        guard tries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.activePid == pid, let cur = API.focusObject, cur.pid == pid, cur.role == .window else { return }
            let appEl = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appEl, 1.0)
            if let f = appEl.element(kAXFocusedUIElementAttribute), f.role != "AXWindow", !cur.isSameElement(as: ObjectFactory.make(f)) {
                Log.io("focus settled after launch on \(f.role)")
                self.focusChanged(f, pid: pid)
            } else {
                self.settleFocus(pid: pid, tries: tries - 1)
            }
        }
    }

    /// TurnOver is opening a menu in this application: a focus to its window just now is the menu's side effect.
    public func menuAboutToOpen(pid: pid_t) { lastMenuClosed = (pid, Date()) }

    func appTerminated(_ pid: pid_t) {
        if let obs = observers.removeValue(forKey: pid) { removeSource(obs) }
        ForeignChildren.forget(pid)
        AppModuleHandler.shared.remove(pid: pid)
        BrowseModeHandler.shared.forget(pid: pid)
        if API.focusObject?.pid == pid { API.setFocusObject(nil, ancestors: []) }
        if activePid == pid { activePid = 0 }
    }

    /// A helper process that belongs to the application in front: its bundle identifier extends the app's
    /// (com.apple.Safari.SandboxBroker serves Safari's Settings window). Its focus is the app's focus.
    func isHelperOfActiveApp(_ helper: NSRunningApplication) -> Bool {
        guard let frontApp = NSRunningApplication(processIdentifier: activePid) else { return false }
        if Self.servesPanel(helperBundle: helper.bundleIdentifier, helperName: helper.localizedName, frontName: frontApp.localizedName) { return true }
        guard let front = frontApp.bundleIdentifier, let b = helper.bundleIdentifier else { return false }
        return b.hasPrefix(front + ".")
    }

    /// The Open and Save dialogs are drawn by a system service, one per app, that names the app it serves: "Open and
    /// Save Panel Service (TextEdit)". Its focus was ignored as a process that is not an application, so a file dialog
    /// was never read, in TextEdit or in Safari's "browse for file" (issue 14, 29 Oct 2026). Only the service serving
    /// the app in front counts; another app's dialog left open behind stays ignored.
    nonisolated public static func servesPanel(helperBundle: String?, helperName: String?, frontName: String?) -> Bool {
        guard helperBundle == "com.apple.appkit.xpc.openAndSavePanelService", let name = helperName, let front = frontName, !front.isEmpty else { return false }
        return name.hasSuffix("(\(front))")
    }

    /// Watch a process for notifications (also for status items whose menus TurnOver opens).
    public func observe(_ pid: pid_t) {
        guard observers[pid] == nil else { return }
        var obs: AXObserver?
        let created = AXObserverCreateWithInfoCallback(pid, { _, element, name, info, refcon in
            guard let refcon else { return }
            let handler = Unmanaged<AXHandler>.fromOpaque(refcon).takeUnretainedValue()
            handler.notification(name as String, element, info as? [String: Any])
        }, &obs)
        guard created == .success, let obs else { Log.error("observer for pid \(pid) failed: \(describeError(created))"); return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        // What VoiceOver sets: WebKit builds the page's accessibility tree only for a client that asks this way
        // (and Chromium for AXManualAccessibility). Harmless where unsupported.
        let t0 = Date()
        _ = app.set("AXEnhancedUserInterface", kCFBooleanTrue)
        _ = app.set("AXManualAccessibility", kCFBooleanTrue)
        // The observer and the handler's pointer go to another thread: the accessibility client API takes them from
        // any thread (as TurnOver's walks already do).
        nonisolated(unsafe) let refcon = Unmanaged.passUnretained(self).toOpaque()
        nonisolated(unsafe) let observer = obs
        let names = Self.notifications
        let register: @Sendable (ArraySlice<String>) -> [String] = { some in
            some.filter { AXObserverAddNotification(observer, app, $0 as CFString, refcon) != .success }
        }
        // An application still starting refuses them all (Word, opened cold: no focus, sheet or caret news ever came,
        // 2 Oct 2026). Ask again as it settles.
        let settle: @MainActor @Sendable ([String]) -> Void = { [weak self] failed in
            guard let self else { return }
            if failed.count > names.count / 2 { self.retryNotifications(pid: pid, obs: obs, names: failed, delays: [1, 2, 4, 8]) }
        }
        // A slow app is signed up off the main thread: 27 questions to a Godot game in front held TurnOver for nearly
        // 4 s each time it came forward (18 Oct 2026). Slow: the two questions above, or the first notification, took
        // more than 30 ms (the questions alone missed it: an app can answer those at once and the sign-ups slowly).
        // Its first moments' news may be missed; the focus is read as the app comes forward anyway.
        let firstFailed = register(names.prefix(1))
        if Date().timeIntervalSince(t0) > 0.03 {
            Log.info("pid \(pid): slow to answer; its notifications are asked for in the background")
            DispatchQueue.global(qos: .userInitiated).async {
                let failed = firstFailed + register(names.dropFirst())
                DispatchQueue.main.async { MainActor.assumeIsolated { settle(failed) } }
            }
        } else {
            settle(firstFailed + register(names.dropFirst()))
        }
        let source = AXObserverGetRunLoopSource(obs)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, EventHandler.runLoopMode)
        observers[pid] = obs
        ForeignChildren.check(pid: pid)
        Log.info("observing pid \(pid)\(ForeignChildren.contains(pid) ? "; its windows list each other's elements (Qt Quick): filtered" : "")")
    }

    func retryNotifications(pid: pid_t, obs: AXObserver, names: [String], delays: [Double]) {
        guard let delay = delays.first else {
            // Not given up for good: an app held at launch by a system prompt (Audacity 4 asks for the microphone
            // before it answers anything) was never heard from again (parts sweep, 14 Oct 2026). The observer goes,
            // so the app's next activation watches it afresh.
            // Only an app that took none of them: the Dock always refuses most (24 of 27) and never comes to the front,
            // and dropping it silenced the Command Tab switcher (15 Oct 2026).
            guard names.count >= Self.notifications.count else {
                Log.error("pid \(pid): \(names.count) notifications never registered; the rest kept"); return
            }
            Log.error("pid \(pid): no notifications registered; trying again when it next comes to the front")
            if let current = observers[pid], current === obs { removeSource(obs); observers[pid] = nil }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let current = self.observers[pid], current === obs else { return }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 1.0)
            // Asked off the main thread, as observe() asks a slow app: an app that refused them all as it came forward
            // can go on answering slowly a second later. Asked here, Telegram Lite (a Qt app) held TurnOver for about
            // 10 s, and the watchdog gave speech back to VoiceOver (twice in eight times it came forward, 27 Oct 2026).
            // The observer and the handler's pointer go to another thread as in observe(): the accessibility client
            // API takes them from any thread, and both outlive the retry (the handler is `AXHandler.shared`, and the
            // closure holds the observer).
            nonisolated(unsafe) let refcon = Unmanaged.passUnretained(self).toOpaque()
            nonisolated(unsafe) let observer = obs
            let register: @Sendable ([String]) -> [String] = { some in
                some.filter { n in
                    let r = AXObserverAddNotification(observer, app, n as CFString, refcon)
                    return r != .success && r != .notificationAlreadyRegistered
                }
            }
            let started = Date()
            let settle: @MainActor @Sendable ([String]) -> Void = { [weak self] still in
                guard let self, let current = self.observers[pid], current === obs else { return }
                Log.info("pid \(pid): \(names.count - still.count) of \(names.count) notifications registered on retry, in \(Int(Date().timeIntervalSince(started) * 1000)) ms off the main thread")
                if still.count > Self.notifications.count / 2 { self.retryNotifications(pid: pid, obs: obs, names: still, delays: Array(delays.dropFirst())) }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let still = register(names)
                DispatchQueue.main.async { MainActor.assumeIsolated { settle(still) } }
            }
        }
    }

    func removeSource(_ obs: AXObserver) {
        let source = AXObserverGetRunLoopSource(obs)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, EventHandler.runLoopMode)
    }

}
