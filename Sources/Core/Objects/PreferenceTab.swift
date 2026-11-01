// SPDX-License-Identifier: GPL-3.0-or-later
// Preference panes: a tab that reads its contents when chosen.
// Behaviours (NVDA: NVDAObjects.behaviors): the object classes every application shares; app modules subclass them.
import Foundation
import ApplicationServices
import AppKit
import TurnOverAX

/// A preference-window toolbar (Mail's Settings: General, Accounts, Junk Mail…): plain buttons that
/// switch panes, with only the window title saying which is showing. Presented as a tab control, the
/// Windows way: Up/Down or Left/Right switch panes at once, Tab moves into the pane.
open class PreferenceTab: TurnOverObject {
    open override var role: Role { .tab }

    /// Is this toolbar button one of a set of panes? True when the window's title is one of the buttons' titles.
    static func isPreferenceTab(_ element: AXUIElement) -> Bool {
        guard element.role == "AXButton", let toolbar = element.element(kAXParentAttribute), toolbar.role == "AXToolbar",
              let window = element.element(kAXWindowAttribute), let title = window.string(kAXTitleAttribute), !title.isEmpty else { return false }
        let siblings = toolbar.elements(kAXChildrenAttribute)
        return siblings.count >= 2 && siblings.contains { $0.string(kAXTitleAttribute) == title }
    }

    var tabs: [AXUIElement] { element.element(kAXParentAttribute)?.elements(kAXChildrenAttribute).filter { $0.role == "AXButton" } ?? [] }

    /// The tab showing in a settings window: its toolbar button named as the window is.
    public static func selectedTab(in window: AXUIElement) -> AXUIElement? {
        guard let title = window.string(kAXTitleAttribute), !title.isEmpty,
              let toolbar = window.elements(kAXChildrenAttribute).first(where: { $0.role == "AXToolbar" }) else { return nil }
        let buttons = toolbar.elements(kAXChildrenAttribute).filter { $0.role == "AXButton" }
        guard buttons.count >= 2 else { return nil }
        return buttons.first { $0.string(kAXTitleAttribute) == title }
    }

    open override var positionInfo: PositionInfo? {
        let all = tabs
        guard let i = all.firstIndex(where: { $0.isSame(element) }) else { return nil }
        return PositionInfo(index: i + 1, count: all.count, level: nil)
    }
    open override var states: Set<State> {
        var s = super.states
        if element.element(kAXWindowAttribute)?.string(kAXTitleAttribute) == name { s.insert(.selected) }
        return s
    }

    open override func initOverlay() {
        super.initOverlay()
        let cat = "Tabs"
        script("tab_next", "Switches to the next pane", gestures: ["kb:downArrow", "kb:rightArrow"], category: cat) { [weak self] _ in self?.step(1) }
        script("tab_previous", "Switches to the previous pane", gestures: ["kb:upArrow", "kb:leftArrow"], category: cat) { [weak self] _ in self?.step(-1) }
        script("tab_first", "Switches to the first pane", gestures: ["kb:home"], category: cat) { [weak self] _ in self?.go(to: 0) }
        script("tab_last", "Switches to the last pane", gestures: ["kb:end"], category: cat) { [weak self] _ in self?.go(to: Int.max) }
        script("tab_intoPane", "Moves into the pane's controls", gestures: ["kb:tab"], category: cat) { [weak self] g in self?.intoPane(g) }
        script("tab_intoPaneEnd", "Moves to the pane's last control (Tab in reverse)", gestures: ["kb:shift+tab"], category: cat) { [weak self] g in self?.intoPane(g, last: true) }
    }

    /// Tab from a tab goes into the pane (Windows), not along the toolbar (macOS): the pane's first control in screen
    /// order; Shift+Tab, its last (Tab in reverse; it walked along the toolbar, 4 Oct 2026).
    private func intoPane(_ g: KeyboardGesture, last: Bool = false) {
        guard let window = SettingsPanePlugin.windowOf(element), let target = SettingsPanePlugin.endControl(in: window, last: last) else { g.send(); return }
        // Going into the pane on purpose: end the hold on the tab from the last switch, or it pulls the focus straight
        // back (Mail's settings needed Tab twice, 4 Oct 2026).
        PreferenceTab.quietUntil = .distantPast
        PreferenceTab.switchGeneration += 1
        Log.io("tab control: into the pane at \(target.role) \"\(Log.words(target.string(kAXTitleAttribute) ?? target.string(kAXDescriptionAttribute) ?? ""))\"\(last ? " (the last)" : "")")
        SettingsPanePlugin.focus(target)
    }

    private func step(_ delta: Int) {
        let all = tabs
        guard let i = all.firstIndex(where: { $0.isSame(element) }) else { return }
        let j = i + delta
        guard all.indices.contains(j) else { Tones.edge(keySent: true); return }
        go(to: j)
    }

    /// While a switch is in progress, the focus events it causes (the app re-focuses the pressed button,
    /// sometimes by way of the old one) say nothing: the switch speaks its target once.
    static var quietUntil = Date.distantPast
    static var lastTabFocusAt = Date.distantPast
    /// Each switch, and each Tab into the pane, moves this on: a switch's late "back to the tab" checks stand down.
    nonisolated static var switchGeneration: Int {
        get { generationLock.lock(); defer { generationLock.unlock() }; return _switchGeneration }
        set { generationLock.lock(); _switchGeneration = newValue; generationLock.unlock() }
    }
    nonisolated(unsafe) private static var _switchGeneration = 0   // under `generationLock`
    static let switchQueue = DispatchQueue(label: "turnover.prefTabs", qos: .userInitiated)
    /// The generation, read from the switch queue (it is changed on the main thread).
    nonisolated private static let generationLock = NSLock()
    nonisolated static func currentGeneration() -> Int { switchGeneration }

    private func go(to index: Int) {
        let all = tabs
        guard !all.isEmpty else { return }
        let target = all[max(0, min(all.count - 1, index))]
        PreferenceTab.quietUntil = Date().addingTimeInterval(1.2)   // the switch starts 0.12 s later; panes load late
        PreferenceTab.lastTabFocusAt = Date()
        PreferenceTab.switchGeneration += 1
        let generation = PreferenceTab.switchGeneration
        // Say the tab first, then switch: Safari answers the press only once the new pane has loaded (a quarter to half a
        // second), and speech waiting for it felt draggy (4 Oct 2026).
        let obj = ObjectFactory.make(target)
        API.setFocusObject(obj, ancestors: API.focusAncestors)
        Speech.speakObject(obj, reason: .focus)
        // The switch a moment later, off the main thread: the speech starts before Safari gets busy loading the pane
        // (speech then took a third of a second to begin, 4 Oct 2026), and arrows pressed quickly skip the tabs passed
        // over: only the one stopped on is loaded.
        PreferenceTab.switchQueue.asyncAfter(deadline: .now() + 0.12) {
            guard generation == PreferenceTab.currentGeneration() else { return }
            _ = target.set(kAXFocusedAttribute, kCFBooleanTrue)
            AXUIElementPerformAction(target, kAXPressAction as CFString)
        }
        // The new pane may take the keyboard focus as it appears; give it back to the tab (twice: panes load late).
        for delay in [0.35, 0.8, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard generation == PreferenceTab.switchGeneration, API.focusObject?.isSameElement(as: obj) == true else { return }
                let app = AXUIElementCreateApplication(obj.pid)
                // The tab looked up afresh: loading a pane can rebuild the toolbar (Safari's General), and focusing the
                // old button sent the focus to the window instead (4 Oct 2026).
                let tab = app.element(kAXFocusedWindowAttribute).flatMap { PreferenceTab.selectedTab(in: $0) } ?? target
                if let f = app.element(kAXFocusedUIElementAttribute), !f.isSame(tab) {
                    _ = tab.set(kAXFocusedAttribute, kCFBooleanTrue)
                    if !tab.isSame(target) { API.setFocusObject(ObjectFactory.make(tab), ancestors: API.focusAncestors) }
                    Log.io("tab control: the pane took the focus; back to the tab")
                }
            }
        }
    }

    open override func event_gainFocus() {
        let fromTab = Date().timeIntervalSince(PreferenceTab.lastTabFocusAt) < 1.0
        PreferenceTab.lastTabFocusAt = Date()
        if Date() < PreferenceTab.quietUntil { return }
        // Shift+Tab from the pane lands on the toolbar's last button on macOS; Windows returns to the
        // selected tab. Send the focus there instead, and let that focus event speak.
        if !fromTab, !states.contains(.selected), let window = element.element(kAXWindowAttribute), let title = window.string(kAXTitleAttribute),
           let selected = tabs.first(where: { $0.string(kAXTitleAttribute) == title }), !selected.isSame(element) {
            Log.io("tab control: focus came from the pane; moving it to the selected tab \"\(Log.words(title))\"")
            _ = selected.set(kAXFocusedAttribute, kCFBooleanTrue)
            return
        }
        super.event_gainFocus()
    }
}
