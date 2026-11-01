// SPDX-License-Identifier: GPL-3.0-or-later
// Settings windows (a toolbar of tabs over a pane: Mail's and Safari's Settings). With the Mac's keyboard
// navigation at its default, Tab only reaches text fields and lists: in Safari's General tab it bounced on the one
// Homepage field (4 Oct 2026). Here, as on Windows, Tab and Shift+Tab go through every control in the pane in the
// order they are on screen (top to bottom, then left to right); Shift+Tab from the first goes back to the tab, and
// Tab from the last goes round to it too. The tab itself (PreferenceTab) already sends Tab into the pane.
import Foundation
import AppKit
import ApplicationServices

public final class SettingsPanePlugin: GlobalPlugin {
    /// Whether the focus is in a settings pane: worked out on the main thread as the focus moves, read by the keyboard
    /// thread's availability check (no questions to the app on that thread).
    private static let lock = NSLock()
    private static var _inPane = false
    static var inPane: Bool { lock.lock(); defer { lock.unlock() }; return _inPane }

    /// The focus moved (main thread).
    private static var _onRibbonTab = false
    static var onRibbonTab: Bool { lock.lock(); defer { lock.unlock() }; return _onRibbonTab }

    /// Microsoft Office's ribbon (Word, Excel, PowerPoint, Outlook): a tab group described "ribbon"; each tab's
    /// commands sit in a scroll area described "<Tab> Tab Commands", there only while that tab is open.
    static func ribbon(of e: AXUIElement) -> AXUIElement? {
        var p: AXUIElement? = e; var hops = 0
        while let x = p, hops < 10 { if x.role == "AXTabGroup", x.string(kAXDescriptionAttribute)?.lowercased() == "ribbon" { return x }; p = x.element(kAXParentAttribute); hops += 1 }
        return nil
    }
    static func ribbonCommands(of e: AXUIElement) -> AXUIElement? {
        var p: AXUIElement? = e; var hops = 0
        while let x = p, hops < 10 { if x.role == "AXScrollArea", x.string(kAXDescriptionAttribute)?.hasSuffix("Tab Commands") == true { return x }; p = x.element(kAXParentAttribute); hops += 1 }
        return nil
    }
    static func commandsArea(in ribbon: AXUIElement) -> AXUIElement? {
        ribbon.elements(kAXChildrenAttribute).first { $0.role == "AXScrollArea" && $0.string(kAXDescriptionAttribute)?.hasSuffix("Tab Commands") == true }
    }
    static func selectedRibbonTab(_ ribbon: AXUIElement) -> AXUIElement? {
        let tabs = ribbon.elements(kAXChildrenAttribute).filter { $0.role == "AXRadioButton" }
        return tabs.first { ($0.attr(kAXValueAttribute) as? NSNumber)?.intValue == 1 } ?? tabs.first
    }

    /// Groups where an app was seen to ignore Tab (main thread), and whether the focus is in one now (any thread).
    static var trapZones: [AXUIElement] = []
    private static var _inTrapZone = false
    /// The focus is a button, and Return would press the window's default button instead.
    static var returnWouldMissFocus: Bool {
        guard let f = API.focusObject, f.role == .button, f.axRole == "AXButton" else { return false }
        let e = f.element
        // The sheet or window holding the button, nearest first: a sheet's default is the sheet's, not its window's.
        // Claude's "Claude is still working" alert is a sheet on the main window: Return on "Quit anyway" went to
        // Claude, which pressed Cancel (7 Oct 2026).
        var p = e.element(kAXParentAttribute); var hops = 0
        while let x = p, hops < 30 {
            if let def = x.element(kAXDefaultButtonAttribute) { return !CFEqual(def, e) }
            let modal = x.role == "AXSheet" || ["AXDialog", "AXSystemDialog"].contains(x.string(kAXSubroleAttribute) ?? "")
            if modal { return true }   // an alert that doesn't say which is its default: the button you're on
            if x.role == "AXWindow" { break }
            p = x.element(kAXParentAttribute); hops += 1
        }
        guard let window = e.element(kAXWindowAttribute) ?? e.element(kAXTopLevelUIElementAttribute),
              let def = window.element(kAXDefaultButtonAttribute) else { return false }
        return !CFEqual(def, e)
    }

    static var inTrapZone: Bool { lock.lock(); defer { lock.unlock() }; return _inTrapZone }
    /// The last window's controls in screen order, reused for a few seconds (walking the window costs 60 ms).
    static var trapList: (window: AXUIElement, controls: [AXUIElement], at: Date)?

    /// The named section around a control (Mail's "Formatting" bar): each button sits in a little group of its own.
    static func zone(of e: AXUIElement) -> AXUIElement? {
        var p = e.element(kAXParentAttribute); var hops = 0
        while let x = p, hops < 5 {
            if ["AXGroup", "AXToolbar", "AXRadioGroup", "AXScrollArea"].contains(x.role),
               !((x.string(kAXDescriptionAttribute) ?? "") + (x.string(kAXTitleAttribute) ?? "")).isEmpty { return x }
            if x.role == "AXWindow" { break }
            p = x.element(kAXParentAttribute); hops += 1
        }
        return e.element(kAXParentAttribute)
    }

    private func trapMove(_ g: KeyboardGesture, forward: Bool) {
        // From TurnOver's held place when the app's buttons do not take the focus, else from the focus.
        Self.dropDeadHold()
        guard let current = Self.virtual ?? API.focusObject?.element, let window = Self.windowOf(current) else { g.send(); return }
        var all: [AXUIElement]
        if let c = Self.trapList, c.window.isSame(window), Date().timeIntervalSince(c.at) < 5 { all = c.controls }
        else { all = Self.controls(in: window, toolbars: true); Self.trapList = (window, all, Date()) }
        var here = all.firstIndex { $0.isSame(current) }
        if here == nil { all = Self.controls(in: window, toolbars: true); Self.trapList = (window, all, Date()); here = all.firstIndex { $0.isSame(current) } }
        guard var i = here, !all.isEmpty else { g.send(); return }
        var n = ((forward ? i + 1 : i - 1) + all.count) % all.count   // round, as the app's own Tab goes
        // The list kept from a moment ago can name controls the app has since thrown away: TurnOver Settings rebuilds
        // its pane on a new section, and Tab from the sidebar went to a dead check box, held it, and was silent from
        // then on (21 Oct 2026). Walk the window again.
        if all[n].role == "?" {
            all = Self.controls(in: window, toolbars: true); Self.trapList = (window, all, Date())
            guard let j = all.firstIndex(where: { $0.isSame(current) }), !all.isEmpty else { g.send(); return }
            i = j; n = ((forward ? i + 1 : i - 1) + all.count) % all.count
        }
        Self.trapList = (window, all, Date())
        Self.focus(all[n])
        Self.setTrapState(for: all[n])
    }

    /// Whether a control is in a place where the app ignores Tab; set as the focus (or TurnOver's held place) moves.
    static func setTrapState(for e: AXUIElement) {
        // A text field keeps the app's own Tab even inside a remembered place: Reminders' sidebar was judged to ignore
        // Tab, and the place remembered took Tab from a new reminder's title too, so TurnOver moved the focus itself
        // and the window was announced between the fields (10 Oct 2026).
        let editable = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(e.role)
        let inTrap = !trapZones.isEmpty && !editable && {
            var p: AXUIElement? = e.element(kAXParentAttribute); var hops = 0
            while let x = p, hops < 6 { if trapZones.contains(where: { $0.isSame(x) }) { return true }; p = x.element(kAXParentAttribute); hops += 1 }
            return false
        }()
        lock.lock(); let was = _inTrapZone; _inTrapZone = inTrap; lock.unlock()
        if was != inTrap { Log.io("tab trap: \(inTrap ? "in" : "out of") a remembered place (\(e.role) \"\(Log.words(e.string(kAXDescriptionAttribute) ?? e.string(kAXTitleAttribute) ?? ""))\")") }
    }

    static func focusMoved(to obj: TurnOverObject) {
        let e = obj.element
        setTrapState(for: e)
        let onTab = e.role == "AXRadioButton" && ribbon(of: e) != nil && ribbonCommands(of: e) == nil
        lock.lock(); _onRibbonTab = onTab; lock.unlock()
        if ribbonCommands(of: e) != nil { lock.lock(); _inPane = true; lock.unlock(); return }
        // A real focus change ends any held place.
        if let v = virtual, !obj.isSameElement(as: v) { virtual = nil; lock.lock(); _holding = false; lock.unlock() }
        var inside = false
        if let window = windowOf(e), PreferenceTab.selectedTab(in: window) != nil {
            var p: AXUIElement? = e; var hops = 0; var inToolbar = false
            while let x = p, hops < 12 { if x.role == "AXToolbar" { inToolbar = true; break }; p = x.element(kAXParentAttribute); hops += 1 }
            inside = !inToolbar
        }
        lock.lock(); _inPane = inside; lock.unlock()
    }

    required init() {
        super.init()
        // An app that ignores Tab or Shift+Tab on a control: Mail's compose window keeps the focus on the formatting
        // bar's "more…" button, so Shift+Tab went nowhere and said nothing (5 Oct 2026). If the focus has not moved
        // shortly after the key, TurnOver moves it to the next or previous control in screen order.
        InputManager.passThroughWatchers.append { g in
            guard g.keyName == "tab", g.modifiers.subtracting(.shift).isEmpty, let f = API.focusObject,
                  !Self.typesTab(f), let window = Self.windowOf(f.element) else { return }
            let before = f.element, pid = before.pid, at = Date()
            // 0.4 s: Reminders' SwiftUI sidebar takes longer than a quarter of a second to pass Tab on (10 Oct 2026).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard API.focusObject?.isSameElement(as: before) == true,
                      (AXHandler.shared.lastNewsAt[pid] ?? .distantPast) < at else { return }
                let all = Self.controls(in: window, toolbars: true)
                guard let here = all.firstIndex(where: { $0.isSame(before) }) else { return }
                let forward = !g.modifiers.contains(.shift)
                let n = ((forward ? here + 1 : here - 1) + all.count) % all.count
                Log.io("tab trap: the app ignored \(forward ? "Tab" : "Shift+Tab") on \(before.role); TurnOver moves to \(all[n].role) \(n + 1) of \(all.count)")
                // Remember where the app ignores Tab (the group around the control): from now on Tab there is
                // TurnOver's at once, with no wait (each step took 300 ms, "draggy", 5 Oct 2026).
                if let zone = Self.zone(of: before), !Self.trapZones.contains(where: { $0.isSame(zone) }) {
                    Log.io("tab trap: remembering \(zone.role) \"\(Log.words(zone.string(kAXDescriptionAttribute) ?? ""))\" as a place where Tab is TurnOver's")
                    Self.trapZones.append(zone)
                    if Self.trapZones.count > 20 { Self.trapZones.removeFirst() }
                }
                Self.trapList = (window, all, Date())
                Self.focus(all[n])
                Self.setTrapState(for: all[n])   // Mail's buttons do not take the focus: TurnOver holds the place
            }
        }
        script("trap_next", "Where the app ignores Tab: the next control, in screen order", gestures: ["kb:tab"], category: "Settings") { [weak self] g in self?.trapMove(g, forward: true) }.isAvailable = { Self.inTrapZone }
        script("trap_previous", "Where the app ignores Shift+Tab: the previous control, in screen order", gestures: ["kb:shift+tab"], category: "Settings") { [weak self] g in self?.trapMove(g, forward: false) }.isAvailable = { Self.inTrapZone }
        script("settings_next", "In a settings pane: the next control, in screen order", gestures: ["kb:tab"], category: "Settings") { [weak self] g in self?.move(g, forward: true) }.isAvailable = { Self.inPane }
        script("settings_previous", "In a settings pane: the previous control, in screen order", gestures: ["kb:shift+tab"], category: "Settings") { [weak self] g in self?.move(g, forward: false) }.isAvailable = { Self.inPane }
        script("ribbon_into", "On a ribbon tab: into its commands (Tab or Down; Shift+Tab to the last)", gestures: ["kb:tab", "kb:downArrow", "kb:shift+tab"], category: "Settings") { [weak self] g in self?.intoRibbon(g) }.isAvailable = { Self.onRibbonTab }
        // Return on a focused button presses that button, as on Windows. A Mac alert sends Return to its default button
        // whatever has the focus: a tester tabbed to "Open System Settings", heard it, pressed Return, and the alert's
        // default, Deny, was pressed instead (7 Oct 2026). Only where the window's default is another button.
        script("dialog_pressFocused", "On a button in a window with a different default button: presses the button you are on", gestures: ["kb:enter", "kb:numpadEnter"], category: "Settings") { g in
            guard let b = API.focusObject?.element else { g.send(); return }
            let r = AXUIElementPerformAction(b, kAXPressAction as CFString)
            Log.io("Return on a focused button that is not the default: pressed it → \(r.rawValue)")
            if r != .success { g.send() } else { SystemPrompts.checkPress(of: b, name: ObjectFactory.make(b).name) }
        }.isAvailable = { Self.returnWouldMissFocus }
        script("settings_pressHeld", "In a settings pane: presses the control TurnOver is holding", gestures: ["kb:space", "kb:enter"], category: "Settings") { [weak self] g in self?.pressHeld(g) }.isAvailable = { Self.holdingVirtual }
    }

    // MARK: Holding the place on a control that will not take the focus

    private static var virtual: AXUIElement?

    /// Move to a control in the pane (Tab, Shift+Tab, and from the tab bar). Safari's settings buttons take the focus
    /// and Safari moves it straight back to the toolbar (10 ms later); Tab then threw the user back to the tab
    /// (4 Oct 2026). For a moment, focus news for anything else is set aside; if the control has lost the focus by
    /// then, TurnOver holds the place on it, as VoiceOver's cursor does: Space and Return press it, and Tab goes on
    /// from it. A list with nothing selected has its first item selected, as on Windows ("228 items, nothing selected"
    /// said nothing useful).
    public static func focus(_ target: AXUIElement) {
        _ = target.set(kAXFocusedAttribute, kCFBooleanTrue)
        if ["AXTable", "AXOutline"].contains(target.role), target.elements(kAXSelectedRowsAttribute).isEmpty,
           let first = target.elements(kAXRowsAttribute).first {
            _ = target.set(kAXSelectedRowsAttribute, [first] as CFArray)
        }
        expected = target
        ignoreOthersUntil = Date().addingTimeInterval(0.3)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard expected.map({ $0.isSame(target) }) ?? false else { return }
            expected = nil
            let app = AXUIElementCreateApplication(target.pid)
            if !(app.element(kAXFocusedUIElementAttribute).map { $0.isSame(target) } ?? false) {
                holdVirtual(target, speak: API.focusObject?.isSameElement(as: target) != true)
            }
        }
    }

    /// The first or last control of a window's pane (from the tab bar: Tab goes to the first, Shift+Tab to the last).
    public static func endControl(in window: AXUIElement, last: Bool) -> AXUIElement? {
        let all = controls(in: window)
        return last ? all.last : all.first
    }

    /// The control just moved to, and until when news of focus elsewhere is set aside (main thread).
    static var expected: AXUIElement?
    public static var ignoreOthersUntil = Date.distantPast
    public static func setsAside(_ e: AXUIElement) -> Bool {
        guard Date() < ignoreOthersUntil, let x = expected else { return false }
        return !x.isSame(e)
    }

    static func holdVirtual(_ target: AXUIElement, speak: Bool = true) {
        // A control the app has thrown away meanwhile is no place to hold: the keys would go nowhere from it.
        guard target.role != "?" else { Log.io("settings: the control moved to is gone; not held"); return }
        virtual = target
        lock.lock(); _holding = true; lock.unlock()
        let obj = ObjectFactory.make(target)
        API.setFocusObject(obj, ancestors: API.focusAncestors)
        lock.lock(); _inPane = true; lock.unlock()
        Log.io("settings: \(target.role) will not keep the focus; TurnOver holds the place on it")
        if speak { Speech.cancel(); Speech.speakObject(obj, reason: .focus) }
    }

    /// Space or Return on a held control: press it.
    private func pressHeld(_ g: KeyboardGesture) {
        guard let v = Self.virtual, API.focusObject?.isSameElement(as: v) == true else { g.send(); return }
        let r = AXUIElementPerformAction(v, kAXPressAction as CFString)
        Log.io("settings: pressed the held \(v.role) → \(describeError(r))")
        if r == .success {
            Tones.press()
            if ["AXCheckBox", "AXRadioButton"].contains(v.role) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { Speech.speakCheckState(of: v) } }
        }
    }
    /// A held place on a control the app has since thrown away (a pane rebuilt): let go, and back to the app's focus.
    static func dropDeadHold() {
        guard let v = virtual, v.role == "?" else { return }
        virtual = nil; lock.lock(); _holding = false; lock.unlock()
        Log.io("settings: the held control is gone; back to the app's focus")
        if let pid = API.focusObject?.element.pid, let f = AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute) {
            API.setFocusObject(ObjectFactory.make(f), ancestors: API.focusAncestors)
            focusMoved(to: ObjectFactory.make(f))
        }
    }
    static var holdingVirtual: Bool { lock.lock(); defer { lock.unlock() }; return _holding }
    private static var _holding = false

    /// The window an element is in. Safari's settings controls do not say (no AXWindow; 4 Oct 2026): walk up to it.
    public static func windowOf(_ e: AXUIElement) -> AXUIElement? {
        if let w = e.element(kAXWindowAttribute) { return w }
        var p = e.element(kAXParentAttribute); var hops = 0
        while let x = p, hops < 20 { if x.role == "AXWindow" { return x }; p = x.element(kAXParentAttribute); hops += 1 }
        return nil
    }

    static let controlRoles: Set<String> = ["AXButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea", "AXComboBox",
                                            "AXSlider", "AXTable", "AXOutline", "AXList", "AXIncrementor", "AXMenuButton", "AXColorWell", "AXDateField", "AXLink"]

    /// The pane's controls in screen order: rows top to bottom (within 8 points is one row), then left to right.
    static func controls(in window: AXUIElement, toolbars: Bool = false) -> [AXUIElement] {
        var found: [(AXUIElement, CGRect)] = []
        var visited = 0
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard visited < 600, depth < 14 else { return }
            visited += 1
            let role = e.role
            if role == "AXToolbar", !toolbars { return }
            let sub = e.string(kAXSubroleAttribute) ?? ""
            if ["AXCloseButton", "AXZoomButton", "AXMinimizeButton", "AXFullScreenButton"].contains(sub) { return }
            if controlRoles.contains(role), (e.attr(kAXEnabledAttribute) as? Bool) != false, let f = TurnOverObject.frame(e), f.width > 0, f.height > 0 {
                var settable: DarwinBoolean = false
                AXUIElementIsAttributeSettable(e, kAXFocusedAttribute as CFString, &settable)
                if settable.boolValue { found.append((e, f)) }
                if ["AXTable", "AXOutline", "AXList", "AXTextArea"].contains(role) { return }   // one stop each
            }
            for k in e.elements(kAXChildrenAttribute) { walk(k, depth + 1) }
        }
        walk(window, 0)
        return found.sorted { a, b in
            let ra = Int(a.1.midY / 8), rb = Int(b.1.midY / 8)
            return ra != rb ? ra < rb : a.1.minX < b.1.minX
        }.map { $0.0 }
    }

    /// Where Tab is typed or handled by the page, not a move between controls: text, documents, web content.
    static func typesTab(_ obj: TurnOverObject) -> Bool {
        if [.editableText, .passwordEdit, .document].contains(obj.role) { return true }
        var p: AXUIElement? = obj.element; var hops = 0
        while let x = p, hops < 20 { if x.role == "AXWebArea" { return true }; p = x.element(kAXParentAttribute); hops += 1 }
        return false
    }

    private func intoRibbon(_ g: KeyboardGesture) {
        guard let tab = API.focusObject?.element, let r = Self.ribbon(of: tab) else { g.send(); return }
        let last = g.modifiers.contains(.shift)
        func enter() -> Bool {
            guard let area = Self.commandsArea(in: r) else { return false }
            // The app's own order (its children), as Word's Tab goes: Paste first, not the Font box at the top.
            // Not a greyed-out one (Paste with nothing to paste): it refuses the focus.
            let all = Self.controlsInOrder(in: area).filter { ($0.attr(kAXEnabledAttribute) as? Bool) != false }
            guard let target = last ? all.last : all.first else { return false }
            Log.io("ribbon: into \(area.string(kAXDescriptionAttribute).map(Log.words) ?? "the commands") at \(target.role)")
            Self.focus(target)
            return true
        }
        if enter() { return }
        // A collapsed ribbon shows a tab's commands only while it is open: open it, then go in.
        AXUIElementPerformAction(tab, kAXPressAction as CFString)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if !enter() { Speech.speakMessage("no commands") }
        }
    }

    /// The controls inside an element in the order of its children (depth first).
    static func controlsInOrder(in root: AXUIElement) -> [AXUIElement] {
        var out: [AXUIElement] = []; var visited = 0
        func walk(_ e: AXUIElement) {
            visited += 1
            guard visited < 800 else { return }
            if controlRoles.contains(e.role) || e.role == "AXRadioButton" { out.append(e); return }
            for c in e.elements(kAXChildrenAttribute) { walk(c) }
        }
        walk(root)
        return out
    }

    private func move(_ g: KeyboardGesture, forward: Bool) {
        Self.dropDeadHold()
        guard let focus = API.focusObject, let window = Self.windowOf(focus.element) else { g.send(); return }
        let commands = Self.ribbonCommands(of: focus.element)
        let all = Self.controls(in: commands ?? window)
        guard !all.isEmpty else { g.send(); return }
        // Where the focus is: the control itself, or the control it is inside (a cell in a table).
        var here: Int?
        var p: AXUIElement? = focus.element; var hops = 0
        while let x = p, hops < 8, here == nil { here = all.firstIndex { $0.isSame(x) }; p = x.element(kAXParentAttribute); hops += 1 }
        let next: Int? = here.map { forward ? $0 + 1 : $0 - 1 } ?? (forward ? 0 : all.count - 1)
        if let n = next, all.indices.contains(n) {
            Log.io("settings: \(forward ? "Tab" : "Shift+Tab") to \(all[n].role) \(n + 1) of \(all.count)")
            Self.focus(all[n])
            return
        }
        // Past either end: back to the tab showing (Windows' Ctrl+Tab bar is the way out of a pane).
        if commands != nil, let r = Self.ribbon(of: focus.element), let tab = Self.selectedRibbonTab(r) {
            _ = tab.set(kAXFocusedAttribute, kCFBooleanTrue)
            Log.io("ribbon: \(forward ? "Tab" : "Shift+Tab") back to the tab")
        } else if let tab = PreferenceTab.selectedTab(in: window) {
            _ = tab.set(kAXFocusedAttribute, kCFBooleanTrue)
            Log.io("settings: \(forward ? "Tab" : "Shift+Tab") back to the tab")
        } else { g.send() }
    }
}
