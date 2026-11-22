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
    struct Extra {
        let element: AXUIElement
        let pid: pid_t
        let name: String
        let x: Double
        /// The system's own items carry one ("com.apple.menuextra.clock"); most apps' items carry none.
        let identifier: String?
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

    static func gather() -> [Extra] {
        let me = getpid()
        // Web content processes never own status items and answer slowly; everything else is asked at once.
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != me && !($0.bundleIdentifier ?? "").hasPrefix("com.apple.WebKit")
        }
        let found = Locked([[Extra]](repeating: [], count: apps.count))
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            found.value[i] = extras(of: apps[i])
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
            mine.append(Extra(element: item, pid: app.processIdentifier, name: name(of: item, app: app), x: x, identifier: identifier))
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
        var items = extras.map { e in
            MenuItem(verbatim: e.name, .action {
                press(e.element, owner: e.pid, name: e.name)
            })
        }
        // TurnOver's own item, at the right of the others it sits beside.
        items.append(MenuItem("TurnOver", .action { DispatchQueue.main.async { TurnOverMenu.shared.open() } }))
        Log.io("status menus: \(extras.count) items")
        TurnOverMenu.shared.openList("Status menus", items: items)
    }
}
