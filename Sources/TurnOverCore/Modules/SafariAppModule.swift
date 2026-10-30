// SPDX-License-Identifier: GPL-3.0-or-later
// Safari. Find (Command+F): Return, Shift+Return and Command+G read the line where the match is, and the
// virtual caret goes there (Safari says nothing and exposes no match count).
import Foundation
import ApplicationServices
import AppKit

package final class SafariAppModule: AppModule {
    static let bundleID = "com.apple.Safari"

    package required init(pid: pid_t, bundleIdentifier: String, appName: String) {
        super.init(pid: pid, bundleIdentifier: bundleIdentifier, appName: appName)
        let cat = "Safari"
        script("safari_findInBar", String(localized: "In the Find bar: finds the next or previous match and reads it", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:enter", "kb:shift+enter"], category: cat) { [weak self] g in
            g.send(); self?.readMatch()
        }.isAvailable = { [weak self] in self?.focusInFindBanner ?? false }
        script("safari_backForward", String(localized: "Goes back or forward a page", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+[", "kb:command+]"], category: cat) { [weak self] g in
            self?.cancelReply()
            self?.navigating = (Date(), API.focusObject?.element.enclosingWebArea().flatMap { Self.address(of: $0) } ?? "")
            g.send()
        }
        // A Tab that went to Safari and brought no news at all: the page is stuck (the freeze test, 4 Oct 2026: nine
        // seconds of Tabs and arrows in silence). Say so, now and then.
        let pid = self.pid
        InputManager.passThroughWatchers.append { g in
            guard g.keyName == "tab", g.modifiers.subtracting(.shift).isEmpty,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            PageWatch.keySent(to: pid)
        }
        // Switching tabs said nothing (a tester, 9 Oct 2026): the new tab's title, once the window shows it (NVDA reads the
        // document's title as its tab takes the focus). The tab's page then reads as usual.
        let tabKeys = ["kb:command+shift+]", "kb:command+shift+[", "kb:control+tab", "kb:control+shift+tab"] + (1...9).map { "kb:command+\($0)" }
        script("safari_switchTab", String(localized: "Switches tab and says the tab's title", comment: "A command, as the key list and keyboard help say it"), gestures: tabKeys, category: cat) { [weak self] g in
            guard let self, let request = self.beginReply() else { g.send(); return }
            let app = AXUIElementCreateApplication(self.pid)
            let window = app.element(kAXFocusedWindowAttribute)
            let before = window?.string(kAXTitleAttribute) ?? ""
            g.send()
            guard let window, self.canReply(request) else { self.finishReply(request); return }
            let keyCount = self.replies.keyCount
            self.replies.poll({
                // The worker reads only immutable request data and the locked cancellation flag. No module,
                // reader or mutable configuration state crosses onto Poll's queue (#181, 28 Oct 2026).
                if request.cancelled.value || keyCount() != request.keys { return true }
                guard let current = app.element(kAXFocusedWindowAttribute), CFEqual(current, window) else {
                    request.cancelled.value = true; return true
                }
                let now = current.string(kAXTitleAttribute) ?? ""
                return !now.isEmpty && now != before
            }) { [weak self] changed in
                guard let self else { return }
                guard self.canReply(request) else { self.finishReply(request); return }
                guard let current = app.element(kAXFocusedWindowAttribute), CFEqual(current, window) else {
                    self.finishReply(request); return
                }
                let title = current.string(kAXTitleAttribute) ?? ""
                guard self.canReply(request) else { self.finishReply(request); return }
                self.finishReply(request)
                Log.io("Safari: tab switch \(changed ? "to a new title" : "with the title unchanged")")
                if changed, !title.isEmpty { Speech.cancel(); Speech.speakMessage(title + ", tab") }
            }
        }.isAvailable = { [weak self] in
            guard let self, API.focusPid == self.pid, !AXHandler.shared.isMenuOpen, !TurnOverMenu.shared.isOpen else { return false }
            return true
        }
        script("safari_reload", String(localized: "Reloads the page and says so", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+r"], category: cat) { [weak self] g in
            self?.cancelReply()
            g.send(); Speech.speakMessage(String(localized: "reload page", comment: "Spoken message"))
        }
        script("safari_findAgain", String(localized: "Finds the next or previous match and reads it", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+g", "kb:command+shift+g"], category: cat) { [weak self] g in
            g.send(); self?.readMatch()
        }
    }

    package convenience init(pid: pid_t, bundleIdentifier: String, appName: String, replies: SafariReplyEnvironment) {
        self.init(pid: pid, bundleIdentifier: bundleIdentifier, appName: appName)
        self.replies = replies
    }

    private struct Reply: Sendable {
        let id = UUID()
        let keys: Int
        let cancelled = Locked(false)
    }
    private var replies = SafariReplyEnvironment()
    private var pendingReply: Reply?
    private var terminated = false

    private func cancelReply() {
        pendingReply?.cancelled.value = true
        pendingReply = nil
    }
    private func beginReply() -> Reply? {
        cancelReply()
        guard !terminated, replies.isCurrent(pid) else { return nil }
        let request = Reply(keys: replies.keyCount())
        pendingReply = request
        return request
    }
    private func canReply(_ request: Reply) -> Bool {
        !terminated && !request.cancelled.value && pendingReply?.id == request.id
            && replies.keyCount() == request.keys && replies.isCurrent(pid)
    }
    private func finishReply(_ request: Reply) {
        if pendingReply?.id == request.id { cancelReply() }
    }

    package override func event_appModuleLoseFocus() {
        cancelReply()
        findLock.lock(); _inFind = false; findLock.unlock()
    }
    package override func terminate() {
        terminated = true
        event_appModuleLoseFocus()
    }

    /// Back or Forward pressed: when, and the address being left. Safari puts the focus back on the old page for a
    /// moment first; read, it was the old page's line, twice (3 Oct 2026). Those focus events are dropped.
    private var navigating: (Date, String)?

    static func address(of web: AXUIElement) -> String? {
        (web.attr("AXURL") as? URL)?.absoluteString ?? (web.attr("AXURL") as? String)
    }

    /// Whether the focus is in the Find bar, worked out on the main thread as the focus moves. The keyboard thread
    /// asked Safari itself on every Enter, and with Safari busy every key waited (E6 audit, 4 Oct 2026).
    private let findLock = NSLock()
    private var _inFind = false
    var focusInFindBanner: Bool { findLock.lock(); defer { findLock.unlock() }; return _inFind }

    package override func handleEvent(_ event: Event, next: () -> Void) {
        if event.kind == .gainFocus {
            let inFind = event.obj.element.element(kAXParentAttribute)?.string(kAXDescriptionAttribute) == "Find Banner"
            findLock.lock(); _inFind = inFind; findLock.unlock()
        }
        if event.kind == .gainFocus, event.obj.axRole == "AXWebArea", let (at, old) = navigating, Date().timeIntervalSince(at) < 2, !old.isEmpty,
           Self.address(of: event.obj.element) == old {
            Log.io("Safari: focus on the page being left; not read")
            return
        }
        super.handleEvent(event, next: next)
    }

    private func readMatch() {
        guard let request = beginReply() else { return }
        let app = AXUIElementCreateApplication(pid)
        guard let originalWindow = app.element(kAXFocusedWindowAttribute), canReply(request) else {
            finishReply(request); return
        }
        replies.after(0.35) { [weak self] in
            guard let self else { return }
            guard self.canReply(request) else { self.finishReply(request); return }
            guard let window = app.element(kAXFocusedWindowAttribute), CFEqual(window, originalWindow),
                  let web = window.firstWebArea(), self.canReply(request) else { self.finishReply(request); return }
            let bridge = WebDocumentBridge(webArea: web)
            guard let sel = bridge.selection(), sel.1 > sel.0 else {
                guard self.canReply(request) else { self.finishReply(request); return }
                self.finishReply(request)
                Speech.speakMessage(String(localized: "not found", comment: "Spoken message")); return
            }
            let line = bridge.unitRange("AXLineTextMarkerRangeForTextMarker", at: sel.0) ?? sel
            let text = bridge.range(line.0, line.1).map { bridge.string($0) } ?? ""
            guard self.canReply(request) else { self.finishReply(request); return }
            Speech.speakText(text.trimmingCharacters(in: .whitespacesAndNewlines))
            if self.canReply(request) { BrowseModeHandler.shared.existingDocument(for: web)?.followWebKitSelection(force: true) }
            self.finishReply(request)
        }
    }
}
