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

public final class AXHandler {
    public static let shared = AXHandler()
    var observers: [pid_t: AXObserver] = [:]
    var workspaceTokens: [NSObjectProtocol] = []
    public var activePid: pid_t = 0   // (settable: the tests play an application)
    var focusWindow: AXUIElement?
    var lastForegroundTitle = ""
    var lastSelectionReport: (AXUIElement, Date)?
    /// The rows selected in a container at its last change, so the row that just changed can be told from the rest.
    var lastSelectedRows: (container: AXUIElement, rows: [AXUIElement])?

    var lastSheet: (AXUIElement, Date)?
    var lastEntered: (AXUIElement, Date)?
    /// The focus's object and ancestors from the rules, for present(): they were made twice per focus change, and
    /// each level is parent, role, subrole and a module lookup (a code review, 14 Oct 2026).
    var madeForFocus: (element: AXUIElement, obj: TurnOverObject, ancestors: [TurnOverObject])?
    var loggedOnlyWindow = Date.distantPast
    var loggedOnlyCount = 0
    /// Where the focus was before it rested a moment on a nameless group (FocusChanges.present).
    var beforeNamelessStop: (ancestors: [TurnOverObject], focus: TurnOverObject?, at: Date)?
    var lastGainFocus: (AXUIElement, Date)?
    var lastWebAreaFocus = Date.distantPast
    var webAreaFocusSkipped = 0
    var running = false

    static let notifications = [
        kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification, kAXSelectedTextChangedNotification,
        kAXValueChangedNotification, kAXTitleChangedNotification, kAXMenuOpenedNotification, kAXMenuClosedNotification,
        kAXMenuItemSelectedNotification, kAXSelectedChildrenChangedNotification, kAXSelectedRowsChangedNotification,
        kAXRowExpandedNotification, kAXRowCollapsedNotification, kAXSheetCreatedNotification, kAXAnnouncementRequestedNotification,
        // Logged only, so the log shows what an application sends around its own controls (Word's menus).
        kAXWindowCreatedNotification, kAXDrawerCreatedNotification, kAXHelpTagCreatedNotification, kAXSelectedColumnsChangedNotification,
        kAXSelectedCellsChangedNotification, kAXCreatedNotification, kAXLayoutChangedNotification, kAXRowCountChangedNotification,
        kAXMainWindowChangedNotification, kAXElementBusyChangedNotification, "AXLiveRegionChanged", "AXLiveRegionCreated",
        "AXLoadComplete",
    ]
    /// Menus open right now, from AXMenuOpened / AXMenuClosed (NVDA tracks menu mode the same way).
    /// Only real AXMenu elements count: Safari's address-bar suggestions announce themselves as a menu
    /// opening on an AXScrollArea and close under another identity, which left this stuck for a session.
    /// Read from any thread (the keyboard thread asks on every key); changed only on the main thread. (E6 audit,
    /// 4 Oct 2026: the keyboard thread pruned this list while main appended to it: a crash waiting to happen.)
    public internal(set) var openMenus: [AXUIElement] {
        get { menuLock.lock(); defer { menuLock.unlock() }; return _openMenus }
        set {
            // Whether the top menu belongs to a web page, worked out here on main, once, not on every key.
            let web = newValue.last.map { MenuNavigationPlugin.isWebMenu($0) } ?? false
            menuLock.lock(); _openMenus = newValue; _topMenuIsWeb = web; menuLock.unlock()
            Self.anyMenuOpen.value = !newValue.isEmpty
        }
    }
    /// For the keyboard thread: whether any app menu is open.
    nonisolated public static let anyMenuOpen = Locked(false)
    var _openMenus: [AXUIElement] = []
    var _topMenuIsWeb = false
    let menuLock = NSLock()
    public var topMenuIsWeb: Bool { menuLock.lock(); defer { menuLock.unlock() }; return _topMenuIsWeb }
    var menuOpenedAt = Date.distantPast
    public var isMenuOpen: Bool {
        // Measured on Word (1 Oct 2026): an open AXMenu has a size; a closed one reports 0 × 0 whatever else it says.
        // Only main prunes (it asks the menus their size); other threads read the list as it is.
        if Thread.isMainThread, Date().timeIntervalSince(menuOpenedAt) > 0.3 {
            let now = openMenus
            let open = now.filter { Self.hasSize($0) }
            if open.count != now.count {
                openMenus = open
                // Left or Right between menu-bar menus: the old one is found closed here before its menuEnd arrives, and
                // Mail's focus had gone back to the message body in the gap ("message body, blank" on every menu,
                // A tester, build 14, 8 Oct 2026). Closed now means the gap has started.
                if open.isEmpty, let last = now.last { lastMenuClosed = (last.pid, Date()) }
            }
        }
        return !openMenus.isEmpty
    }
    static func hasSize(_ e: AXUIElement) -> Bool {
        guard let v = e.attr(kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return e.role == "AXMenu" }
        var size = CGSize.zero
        return axValue(v, .cgSize, &size) && size.height > 0
    }
    var lastMenuStart = Date.distantPast
    var lastForegroundAt = Date.distantPast

    public func start() {
        guard !running else { return }
        running = true
        let nc = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.appActivated(app) }
        })
        workspaceTokens.append(nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.appTerminated(app.processIdentifier) }
        })
        // A system agent never activates, so one launched after TurnOver (Siri AI is started on demand and relaunched)
        // is observed when it starts, or Spotlight went unread until TurnOver restarted (code review, 21 Oct 2026).
        workspaceTokens.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  Self.systemUIAgents.contains(app.bundleIdentifier ?? "") else { return }
            // A moment for the new process to answer accessibility questions before its notifications are asked for.
            let pid = app.processIdentifier
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.running else { return }   // stopped meanwhile: no observer left behind
                self.observe(pid)
            }
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.seedNotifications() }
        for bundle in Self.systemUIAgents {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundle) { observe(app.processIdentifier) }
        }
        if let front = NSWorkspace.shared.frontmostApplication { appActivated(front) }
        SystemPrompts.shared.start()
        if !watchingSpotlightEscape { watchingSpotlightEscape = true; InputManager.passThroughWatchers.append { [weak self] g in self?.spotlightEscape(g) } }
    }
    /// Processes that take the keyboard without becoming the active application. On macOS 27 Spotlight's panel is
    /// drawn by "Siri AI" (com.apple.campo): unwatched, Command Space said nothing and the letters typed went to
    /// browse mode's quick navigation behind it (21 Oct 2026).
    public static let systemUIAgents = ["com.apple.dock", "com.apple.Spotlight", "com.apple.campo", "com.apple.notificationcenterui", "com.apple.controlcenter"]

    /// Escape in Spotlight: its panel closes, but the application in front never changed, so no news came and
    /// TurnOver stayed on the gone search field, saying nothing (macOS 27, 21 Oct 2026). As VoiceOver does, it says
    /// so and reads the application's focus again. Only from Siri AI's search field itself: Escape on a result row
    /// clears the query and the row goes while the panel stays open, and Spotlight on macOS 26 (com.apple.Spotlight)
    /// may already read the application again, which would say it twice (review, 21 Oct 2026).
    private var watchingSpotlightEscape = false
    private func spotlightEscape(_ g: KeyboardGesture) {
        guard g.keyName == "escape", g.modifiers.isEmpty, let f = API.focusObject,
              NSRunningApplication(processIdentifier: f.pid)?.bundleIdentifier == "com.apple.campo",
              f.element.string(kAXIdentifierAttribute) == "SpotlightSearchField" else { return }
        let pid = f.pid
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.running, API.focusObject?.pid == pid else { return }
            // Closed: the field TurnOver is on is gone or no longer focused, or the panel has no focused window.
            let field = API.focusObject?.element
            let gone = field.map { $0.role == "?" || ($0.attr(kAXFocusedAttribute) as? Bool) != true } ?? true
            guard gone || AXUIElementCreateApplication(pid).element(kAXFocusedWindowAttribute) == nil else { return }
            Log.io("spotlight: closed; back to the application")
            Speech.speakMessage(String(localized: "Spotlight closed", comment: "Spoken message"))
            self.refocus(pid: self.activePid)
        }
    }

    public func stop() {
        guard running else { return }
        running = false
        workspaceTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceTokens.removeAll()
        for (_, obs) in observers { removeSource(obs) }
        observers.removeAll()
        API.setFocusObject(nil, ancestors: [])
        API.setForegroundObject(nil)
        focusWindow = nil
        NotificationCentrePanel.reset()
        activePid = 0
        AppModuleHandler.shared.terminateAll()
    }

    // Stored properties of the parts in the other files (an extension cannot hold them).
    lazy var notificationCentrePid: pid_t = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first?.processIdentifier ?? -1
    var seenNotifications: [String] = []
    var notificationCheck: DispatchWorkItem?
    var backgroundRecheckPending = false
    var navigationCheckPending = false
    /// When the last open menu closed, and in which process (menu-to-menu moves pass through no menu at all).
    var lastMenuClosed: (pid_t, Date)?
    var menuGapRecheckPending = false
    /// When each application last sent any accessibility news (main thread): a key it should react to, and no news
    /// after it, means it is not responding.
    public internal(set) var lastNewsAt: [pid_t: Date] = [:]
    /// Ask the application what has focus now and treat it as a focus change (after a menu closes: Word sends nothing).
    var menuGapTarget: AXUIElement?
    var lastAnnouncement = ("", Date.distantPast)
    var lastRefocus: (AXUIElement, Date)?
}

extension AXHandler {
    /// The highlighted item in the open menus, by whatever the app marks it with (NVDA reads menus by focus events; Word's own menus need this).
    public func highlightedMenuItem() -> AXUIElement? {
        for menu in openMenus.reversed() {
            if let sel = menu.elements(kAXSelectedChildrenAttribute).first { return sel }
            let kids = menu.elements(kAXChildrenAttribute)
            if let f = kids.first(where: { ($0.attr(kAXFocusedAttribute) as? Bool) == true }) { return f }
            if let s = kids.first(where: { ($0.attr(kAXSelectedAttribute) as? Bool) == true }) { return s }
            // A page's own menu (Claude's model picker in Safari, 3 Oct 2026): its items sit inside groups, and the
            // highlighted one is the one with the focus. Every arrow found nothing and said nothing.
            let app = AXUIElementCreateApplication(menu.pid)
            if let f = app.element(kAXFocusedUIElementAttribute), f.role == "AXMenuItem" {
                var p: AXUIElement? = f; var hops = 0
                while let x = p, hops < 6 { if x.isSame(menu) { return f }; p = x.element(kAXParentAttribute); hops += 1 }
            }
            for g in kids where g.role == "AXGroup" {
                let inner = g.elements(kAXChildrenAttribute)
                if let f = inner.first(where: { ($0.attr(kAXFocusedAttribute) as? Bool) == true }) { return f }
                if let s = inner.first(where: { ($0.attr(kAXSelectedAttribute) as? Bool) == true }) { return s }
            }
        }
        return nil
    }

    func logMenu(_ menu: AXUIElement) {
        let kids = menu.elements(kAXChildrenAttribute)
        Log.io("menu opened: \(menu.role) \"\(Log.words(menu.string(kAXTitleAttribute) ?? ""))\" subrole \(menu.string(kAXSubroleAttribute) ?? "-") \(kids.count) children; attributes \((menu.attr(kAXSelectedChildrenAttribute) as? [AXUIElement])?.count ?? -1) selected")
        for k in kids.prefix(12) {
            Log.io("  \(k.role) \"\(Log.words(k.string(kAXTitleAttribute) ?? k.string(kAXDescriptionAttribute) ?? ""))\" selected=\(k.attr(kAXSelectedAttribute) as? Bool ?? false) focused=\(k.attr(kAXFocusedAttribute) as? Bool ?? false) enabled=\(k.attr(kAXEnabledAttribute) as? Bool ?? true)")
        }
    }
}

nonisolated public extension AXUIElement {
    func isSame(_ other: AXUIElement) -> Bool { CFEqual(self, other) }
}

nonisolated extension AXUIElement {
    /// The page this element is in (itself, if it is one).
    public func enclosingWebArea() -> AXUIElement? {
        var p: AXUIElement? = self; var hops = 0
        while let x = p, hops < 50 { if x.role == "AXWebArea" { return x }; p = x.element(kAXParentAttribute); hops += 1 }
        return nil
    }

    /// The page in a window, without wandering through long lists on the way (Safari's Reading List has hundreds of rows).
    public func firstWebArea(maxVisited: Int = 400) -> AXUIElement? {
        var queue = [self]; var visited = 0
        while !queue.isEmpty, visited < maxVisited {
            let e = queue.removeFirst(); visited += 1
            let r = e.role
            if r == "AXWebArea" { return e }
            if ["AXTable", "AXOutline", "AXList", "AXRow", "AXToolbar"].contains(r) { continue }
            queue.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
        return nil
    }
}
