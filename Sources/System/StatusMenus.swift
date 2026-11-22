// SPDX-License-Identifier: GPL-3.0-or-later
// The status menus (Windows: the notification area, Windows+B), as a spoken list.
// Option+B gathers every application's menu bar extras (Control Center's Wi-Fi,
// battery and clock, other apps' items, TurnOver's own) in screen order, left to
// right. Enter presses the item and its menu is read as any menu is. TurnOver's
// own item opens the spoken TurnOver menu: TurnOver never makes accessibility calls
// into its own process, which would block its main thread.
//
// The system's Control-F8 ("move focus to status menus") moved nothing when
// measured on 1 Oct 2026, which is why TurnOver lists them itself.
import Foundation
import AppKit
import ApplicationServices

public enum StatusMenus {
    /// The status item just opened from the list: its menu carries no name of its own ("a VPN app's menu").
    public static var lastOpened: (String, Date)?
    nonisolated struct Extra: @unchecked Sendable {
        let element: AXUIElement
        let pid: pid_t
        let name: String
        let x: Double
        /// The system's own items carry one ("com.apple.menuextra.clock"); most apps' items carry none.
        let identifier: String?
        let overflow: Overflow?
    }

    nonisolated enum Overflow: Sendable {
        case show, hide

        private static let labels: (show: Set<String>, hide: Set<String>) = {
            // MenuBarAgent publishes localized descriptions for this toggle. Only use
            // them for that process, since an ordinary app may name its item anything.
            let url = URL(fileURLWithPath: "/System/Library/CoreServices/MenuBarAgent.app/Contents/Resources/MenuBarCore.loctable")
            let table = (try? Data(contentsOf: url)).flatMap {
                try? PropertyListSerialization.propertyList(from: $0, format: nil)
            } as? [String: [String: String]]
            let locales = (table ?? [:]).values
            return (
                Set(locales.compactMap { $0["menuBar.showOverflowItemsAccessibilityLabel"] } + ["Show Hidden Menu Bar Items"]),
                Set(locales.compactMap { $0["menuBar.hideOverflowItemsAccessibilityLabel"] } + ["Hide Menu Bar Items"])
            )
        }()

        static func matching(_ label: String) -> Self? {
            if labels.show.contains(label) { return .show }
            if labels.hide.contains(label) { return .hide }
            return nil
        }
    }

    /// The item currently selected in the old row, or the first revealed item
    /// when the cursor is still on the control that opened the overflow.
    static func refreshedSelection(old: [Extra], new: [Extra], selected: Int, toggle: Extra) -> Int {
        if selected == old.count { return new.count }  // TurnOver's own item
        guard old.indices.contains(selected) else { return 0 }
        let current = old[selected]
        if sameItem(current, toggle), toggle.overflow == .show,
           let first = firstRevealed(old: old, new: new) { return first }
        return new.firstIndex { sameItem($0, current) } ?? min(selected, new.count)
    }

    private static func firstRevealed(old: [Extra], new: [Extra]) -> Int? {
        new.firstIndex { item in item.overflow == nil && !old.contains { sameItem($0, item) } }
    }

    private static func sameRow(_ previous: [Extra], _ new: [Extra]) -> Bool {
        previous.count == new.count && zip(previous, new).allSatisfy { sameItem($0.0, $0.1) }
    }

    private static func sameItem(_ first: Extra, _ second: Extra) -> Bool {
        guard first.pid == second.pid else { return false }
        if first.overflow != nil, second.overflow != nil { return true }
        if let id = first.identifier, id == second.identifier { return true }
        return CFEqual(first.element, second.element)
    }

    private final class OverflowRequest {
        let toggle: Extra
        let old: [Extra]
        let direction: Overflow
        let deadline = ContinuousClock.now + .seconds(4)
        var candidate: [Extra]?
        let isCurrent: @MainActor () -> Bool
        let refreshed: @MainActor ([Extra]) -> Void

        init(toggle: Extra, old: [Extra], direction: Overflow, isCurrent: @escaping @MainActor () -> Bool,
             refreshed: @escaping @MainActor ([Extra]) -> Void) {
            self.toggle = toggle
            self.old = old
            self.direction = direction
            self.isCurrent = isCurrent
            self.refreshed = refreshed
        }
    }

    private static var pendingOverflow: OverflowRequest?

    /// Press and reread outside the keyboard decision. The agent can take about a
    /// second to reveal the row. Apply the result only to the menu that issued the press.
    static func toggleOverflow(
        _ toggle: Extra, from old: [Extra], isCurrent: @escaping @MainActor () -> Bool,
        refreshed: @escaping @MainActor ([Extra]) -> Void
    ) {
        guard let direction = toggle.overflow else { return }
        if let pendingOverflow, accepts(pendingOverflow) { return }
        let request = OverflowRequest(toggle: toggle, old: old, direction: direction, isCurrent: isCurrent, refreshed: refreshed)
        pendingOverflow = request
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if pendingOverflow === request {
                pendingOverflow = nil
                Log.io("status menus: overflow refresh expired")
            }
        }
        prepareOverflow(request)
    }

    private static func prepareOverflow(_ request: OverflowRequest) {
        guard accepts(request) else { return }
        let pid = request.toggle.pid
        // Read the current toggle before pressing. If an earlier request
        // revealed the items late, another press would hide them again.
        DispatchQueue.global(qos: .userInitiated).async {
            let liveToggle = NSRunningApplication(processIdentifier: pid)
                .flatMap { extras(of: $0).first { $0.overflow != nil } }
            DispatchQueue.main.async {
                guard accepts(request) else { return }
                guard let liveToggle else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { prepareOverflow(request) }
                    return
                }
                guard liveToggle.overflow == request.direction else {
                    readOverflow(request)
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = AXUIElementPerformAction(liveToggle.element, kAXPressAction as CFString)
                    DispatchQueue.main.async {
                        Log.io("status menus: overflow press returned \(result.rawValue)")
                        readOverflow(request)
                    }
                }
            }
        }
    }

    private static func accepts(_ request: OverflowRequest) -> Bool {
        guard pendingOverflow === request else { return false }
        if request.isCurrent(), ContinuousClock.now < request.deadline { return true }
        pendingOverflow = nil
        return false
    }

    private static func readOverflow(_ request: OverflowRequest) {
        guard accepts(request) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let row = gather()
            DispatchQueue.main.async {
                guard accepts(request) else { return }
                let stateChanged = row.contains {
                    $0.pid == request.toggle.pid && $0.overflow != nil && $0.overflow != request.direction
                }
                if stateChanged, request.direction == .hide || firstRevealed(old: request.old, new: row) != nil {
                    let stable = request.candidate.map { sameRow($0, row) } ?? false
                    let keptVisibleItems = request.direction == .show && request.old.allSatisfy { oldItem in
                        row.contains { sameItem(oldItem, $0) }
                    }
                    if keptVisibleItems || stable {
                        pendingOverflow = nil
                        Log.io("status menus: overflow refreshed from \(request.old.count) to \(row.count) items")
                        request.refreshed(row)
                        return
                    }
                    request.candidate = row
                } else {
                    request.candidate = nil
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { readOverflow(request) }
            }
        }
    }

    /// The names, in order, for tests.
    public static func names() -> [String] { gather().map(\.name) }

    /// The processes that host the system's own items (the clock, Control Centre, battery, Wi-Fi): MenuBarAgent on
    /// macOS 27.2 (measured 23 Oct 2026), Control Centre and SystemUIServer on earlier systems.
    static let systemHosts = ["com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver"]

    /// One of the system's items by its identifier ("com.apple.menuextra.clock"). Only the system hosts are asked,
    /// each with the quarter-second timeout, so a slow third-party app cannot hold the key up: until 23 Oct 2026
    /// only Control Centre's own process was asked, and on macOS 27.2 it answers no value for its extras bar.
    static func find(identifier: String) -> Extra? {
        for bundle in systemHosts {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundle) {
                if let extra = extras(of: app).first(where: { $0.identifier == identifier }) { return extra }
            }
        }
        return nil
    }

    nonisolated static func gather() -> [Extra] {
        let me = getpid()
        // Web content processes never own status items and answer slowly; everything else is asked at once.
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != me && !($0.bundleIdentifier ?? "").hasPrefix("com.apple.WebKit")
        }
        let found = Locked([[Extra]](repeating: [], count: apps.count))
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            let items = extras(of: apps[i])
            // Store this app's result in one lock acquisition so parallel reads cannot lose another app's items.
            found.lock.withLock { found.unsafeValue[i] = items }
        }
        return found.value.flatMap { $0 }.sorted { $0.x < $1.x }
    }

    /// One application's items in its extras bar, each call given a quarter of a second.
    nonisolated static func extras(of app: NSRunningApplication) -> [Extra] {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.25)
        guard let bar = ax.element("AXExtrasMenuBar") else { return [] }
        // Each element keeps the timeout it was given: the bar and its items too, or a hung app costs 2 s apiece.
        AXUIElementSetMessagingTimeout(bar, 0.25)
        var mine: [Extra] = []
        for outer in bar.elements(kAXChildrenAttribute) {
            AXUIElementSetMessagingTimeout(outer, 0.25)
            // macOS's own items (MenuBarAgent) are unlabelled holders of a labelled item: Wi-Fi, Battery, Clock.
            var item = outer
            if (outer.string(kAXDescriptionAttribute) ?? "").isEmpty, (outer.string(kAXTitleAttribute) ?? "").isEmpty,
               let inner = outer.elements(kAXChildrenAttribute).first(where: { !($0.string(kAXDescriptionAttribute) ?? $0.string(kAXTitleAttribute) ?? "").isEmpty }) {
                item = inner
            }
            var x = 0.0
            if let v = item.attr(kAXPositionAttribute), CFGetTypeID(v as CFTypeRef) == AXValueGetTypeID() { var p = CGPoint.zero; axValue(v, .cgPoint, &p); x = p.x }
            let identifier = item.string(kAXIdentifierAttribute) ?? outer.string(kAXIdentifierAttribute)
            let overflow = app.bundleIdentifier == "com.apple.MenuBarAgent"
                ? [kAXDescriptionAttribute, kAXTitleAttribute].lazy.compactMap { item.string($0) }.compactMap(Overflow.matching).first
                : nil
            mine.append(Extra(element: item, pid: app.processIdentifier, name: name(of: item, app: app), x: x,
                              identifier: identifier, overflow: overflow))
        }
        return mine
    }

    /// A spoken name: the item's label, else its owner's name, with the tooltip when it says more ("a Bluetooth device, Disconnected").
    /// 22 Nov 2026, issue 298: the item's value follows its name, as VoiceOver says it ("Battery, 100%, charging"); the
    /// battery item said no level because only the label was read. With no value, the battery says what the power
    /// source says (GlobalCommands.batteryText).
    public nonisolated static func name(of item: AXUIElement, app: NSRunningApplication) -> String {
        let base = labelName(of: item, app: app)
        // Words only: a bare number (a third-party item's 0 or 1) would be said as a meaningless "Name, 1".
        var value = (item.attr(kAXValueAttribute) as? String) ?? ""
        value = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: ", ")
        if value.isEmpty, (item.string(kAXIdentifierAttribute) ?? "").hasSuffix(".battery") { value = GlobalCommands.batteryText() }
        guard !value.isEmpty, !base.localizedCaseInsensitiveContains(value) else { return base }
        return "\(base), \(value)"
    }

    nonisolated static func labelName(of item: AXUIElement, app: NSRunningApplication) -> String {
        func clean(_ s: String?) -> String? {
            let t = (s ?? "").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–")))
            return t.isEmpty || t.lowercased() == "menu" ? nil : t
        }
        let help = clean(item.string(kAXHelpAttribute))?.replacingOccurrences(of: "\n", with: ", ")
        if let label = clean(item.string(kAXDescriptionAttribute)) ?? clean(item.string(kAXTitleAttribute)) {
            if let help, !help.hasPrefix(label) { return "\(label), \(help)" }
            return label
        }
        // No label at all (Control Center's items on macOS 26.5: every one was "Control Center", a tester, 8 Oct 2026):
        // the identifier's last part, as words ("com.apple.menuextra.battery" → "battery").
        if let id = item.string(kAXIdentifierAttribute) ?? item.element(kAXParentAttribute)?.string(kAXIdentifierAttribute),
           let last = id.split(separator: ".").last, !last.isEmpty, last.count < 40 {
            var words = ""
            for c in last { if c.isUppercase, !words.isEmpty { words += " " }; words.append(c == "_" || c == "-" ? " " : c) }
            let w = words.lowercased()
            if let help { return "\(w), \(help)" }
            return w
        }
        let owner: String
        switch app.bundleIdentifier ?? "" {
        case "com.apple.TextInputMenuAgent": owner = "Input menu"
        case "com.apple.MenuBarAgent": owner = "System item"
        default: owner = app.localizedName ?? "Item"
        }
        return help.map { "\(owner), \($0)" } ?? owner
    }

    /// An unsuccessful AX reply is only a failure if no menu opened during the attempt.
    public static func shouldReportOpenFailure(menuStartBeforePress: Date, latestMenuStart: Date,
                                              isMenuOpen: Bool) -> Bool {
        latestMenuStart == menuStartBeforePress && !isMenuOpen
    }

    static func press(_ element: AXUIElement, owner: pid_t, name: String) {
        AXHandler.shared.observe(owner)
        lastOpened = (name, Date())
        let menuStartBeforePress = AXHandler.shared.lastMenuStart
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        Log.io("status menus: press \"\(Log.words(name))\" → \(result.rawValue)")
        guard result != .success else { return }
        // macOS 27.2, 15 Nov 2026: AXPress returned cannotComplete, then the status menu
        // opened 2 ms later and closed before this check. Remember the opening, not just
        // whether a menu is still open; capture before AXPress, which can deliver callbacks.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if shouldReportOpenFailure(menuStartBeforePress: menuStartBeforePress,
                                       latestMenuStart: AXHandler.shared.lastMenuStart,
                                       isMenuOpen: AXHandler.shared.isMenuOpen) {
                Speech.speakMessage(String(localized: "could not open \(name)", comment: "A menu could not be opened: %@ is its name"))
            }
        }
    }

    public static func openList() {
        let extras = gather()
        Log.io("status menus: \(extras.count) items")
        TurnOverMenu.shared.openList("Status menus", items: listItems(extras))
    }

    private static func listItems(_ extras: [Extra]) -> [MenuItem] {
        var items = extras.map { e in
            if e.overflow != nil {
                return MenuItem(verbatim: e.name, .select {
                    let menu = TurnOverMenu.shared
                    let generation = menu.listGeneration
                    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    toggleOverflow(e, from: extras, isCurrent: {
                        menu.isOpen && menu.listGeneration == generation
                            && NSWorkspace.shared.frontmostApplication?.processIdentifier == front
                    }, refreshed: { row in
                        menu.refreshList(generation: generation, items: listItems(row)) { selected in
                            refreshedSelection(old: extras, new: row, selected: selected, toggle: e)
                        }
                    })
                })
            }
            return MenuItem(verbatim: e.name, .action {
                press(e.element, owner: e.pid, name: e.name)
            })
        }
        // TurnOver's own item, at the right of the others it sits beside.
        items.append(MenuItem("TurnOver", .action { DispatchQueue.main.async { TurnOverMenu.shared.open() } }))
        return items
    }
}
