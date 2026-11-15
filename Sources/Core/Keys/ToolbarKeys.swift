// SPDX-License-Identifier: GPL-3.0-or-later
// One toolbar rule for every app (agreed with the owner, 15 Nov 2026). While the keyboard is on a control inside an
// AXToolbar: Left and Right move to the previous or next control of that toolbar, with the edge sound at either end;
// Escape goes back to the window's main content; Up, Down, Tab and Shift+Tab are not touched.
//
// These are the global commands' scripts, the last place a key is offered, so everything that already answers a key
// keeps it: the user's own keys, menus that are open, Quick Nav and browse mode, an app module's own scripts, the
// focused control's own scripts (a settings window's tab strip switches panes with the arrows, a slider changes its
// value) and the held places. What the rule adds is an answer where a toolbar control had none and the app said nothing.
//
// The decision itself is a pure function (`decide`); the accessibility calls are around it.
//
// Cost (15 Nov 2026, review): the availability check runs for every Left, Right and Escape in every app, so it makes no
// accessibility call. Whether the focus is a toolbar control is worked out once, as the focus moves (focusMoved), from
// the ancestors the focus already holds, and stored with its element; the key path reads that. Only a toolbar control
// with text in it is asked its value, on Escape.
import Foundation
import AppKit
import ApplicationServices

public enum ToolbarKeys {
    public enum Key: String, Sendable { case left, right, escape }

    public enum Decision: Equatable, Sendable {
        /// Left or Right: the keyboard moves to this control of the toolbar (an index into its focusable controls).
        case move(Int)
        /// Left or Right at an end of the toolbar: the edge sound, and the keyboard stays.
        case edge
        /// Escape: the keyboard goes back to the window's main content.
        case escapeToContent
        /// Not this rule's key here: the application gets it as it always did.
        case passThrough
    }

    /// What a key does on a toolbar control. `textEntry`: a text, search or combo field (it keeps its caret keys; its
    /// Escape too while it holds text). `usesArrowsItself`: a control whose arrows change something (a slider), or a
    /// strip with its own arrow script (a settings window's tabs). `index`: the focused control's place among the
    /// toolbar's focusable controls, nil when it could not be found.
    nonisolated public static func decide(_ key: Key, inToolbar: Bool, menuOpen: Bool, textEntry: Bool, hasText: Bool,
                                          usesArrowsItself: Bool, controlCount: Int, index: Int?) -> Decision {
        guard inToolbar, !menuOpen else { return .passThrough }
        switch key {
        case .escape:
            return textEntry && hasText ? .passThrough : .escapeToContent
        case .left, .right:
            // Right-to-left layouts (15 Nov 2026): TurnOver has no helper that says which way a window reads, so Left
            // is "previous" everywhere. Revisit when one exists.
            guard !textEntry, !usesArrowsItself, let i = index, controlCount > 0 else { return .passThrough }
            let n = i + (key == .right ? 1 : -1)
            return n >= 0 && n < controlCount ? .move(n) : .edge
        }
    }

    public enum EscapeSource: String, Equatable, Sendable { case previousFocus, appModule, firstContent }

    /// Where Escape goes, by preference: what had the keyboard in this window before it entered the toolbar (if it is
    /// still there), then the app module's own answer, then the first control outside the toolbar. Each is asked only
    /// if the one before gave nothing (walking a window costs).
    nonisolated public static func chooseEscapeTarget<T>(previous: () -> T?, appModule: () -> T?, firstContent: () -> T?) -> (target: T, source: EscapeSource)? {
        if let t = previous() { return (t, .previousFocus) }
        if let t = appModule() { return (t, .appModule) }
        if let t = firstContent() { return (t, .firstContent) }
        return nil
    }

    nonisolated public static func isTextEntry(axRole: String, subrole: String?) -> Bool {
        ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(axRole) || subrole == "AXSearchField"
    }
    nonisolated public static func keepsArrows(axRole: String) -> Bool {
        ["AXSlider", "AXIncrementor", "AXScrollBar", "AXValueIndicator", "AXSplitter"].contains(axRole)
    }

    /// The focus enters a toolbar from outside it (the toolbar's own focus-entered event, which comes before the
    /// group or control inside it): "tool bar" is said, as the role is, but whatever the reading order says about roles.
    /// The log of 15 Nov 2026 showed `focusEntered: AXToolbar ""` with nothing said in Finder, where this Mac's
    /// reading order leaves the kind of an item out. Not said again while the keys move inside the toolbar: no focus
    /// enters it then. False when the toolbar has a name of its own, which the ordinary announcement says.
    public static func sayEntering(_ obj: TurnOverObject) -> Bool {
        guard obj.role == .toolBar, obj.name.isEmpty else { return false }
        Log.io("toolbar: entered from outside")
        Speech.speakOnly(Role.toolBar.displayString)
        return true
    }

    // MARK: The accessibility side

    /// What had the keyboard outside any toolbar, most recently (main thread; set as the focus moves).
    private static var lastOutside: AXUIElement?

    /// The answer for the current focus, worked out once as the focus moved (main thread): the element, and whether it
    /// is a toolbar control the rule may act on.
    private static var stored: (element: AXUIElement, applies: Bool)?

    /// Pure: the ancestors (role, subrole) hold a toolbar and no sheet or dialog (their Escape is the dialog's).
    nonisolated public static func ancestorsAllow(_ ancestors: [(role: String, subrole: String?)]) -> Bool {
        guard ancestors.contains(where: { $0.role == "AXToolbar" }) else { return false }   // the common case, decided first
        return !ancestors.contains { $0.role == "AXSheet" || ["AXDialog", "AXSystemDialog"].contains($0.subrole ?? "") }
    }

    /// Called as the focus moves, once per focus change. Only for the focus as it now stands: API.focusObject and its
    /// ancestors are set before the gainFocus event is queued (FocusChanges), so the ancestors the objects already hold
    /// are used and no accessibility call is made. A late event for a focus that has since moved on is ignored.
    static func focusMoved(to obj: TurnOverObject) {
        guard let current = API.focusObject, current.isSameElement(as: obj) else { return }
        let applies = !(obj is PreferenceTab) && ancestorsAllow(API.focusAncestors.map { ($0.axRole, $0.axSubrole) })
        stored = (obj.element, applies)
        if !applies { lastOutside = obj.element }
    }

    /// The focus is a toolbar control the rule may act on, and no browse-mode document is in charge. Read from the
    /// answer stored as the focus moved; if the stored one is for another element, worked out from the ancestors the
    /// focus holds (no accessibility call either way, as this runs for every Left, Right and Escape in every app).
    private static func inToolbar(_ f: TurnOverObject) -> Bool {
        guard API.focusTreeInterceptor == nil else { return false }
        if let s = stored, CFEqual(s.element, f.element) { return s.applies }
        return !(f is PreferenceTab) && ancestorsAllow(API.focusAncestors.map { ($0.axRole, $0.axSubrole) })
    }

    private static func hasText(_ f: TurnOverObject) -> Bool { !(f.element.string(kAXValueAttribute) ?? "").isEmpty }

    private static func available(_ key: Key) -> Bool {
        guard let f = API.focusObject, inToolbar(f) else { return false }
        let entry = isTextEntry(axRole: f.axRole, subrole: f.axSubrole)
        // Index 0 of 2 stands in for "somewhere in the middle": only the cheap facts decide whether the key is ours.
        return decide(key, inToolbar: true, menuOpen: AXHandler.shared.isMenuOpen, textEntry: entry,
                      hasText: key == .escape && entry && hasText(f), usesArrowsItself: keepsArrows(axRole: f.axRole),
                      controlCount: 2, index: 0) != .passThrough
    }

    /// Every control of a toolbar that can take the keyboard, in order (the groups around them are looked through).
    static func controls(in toolbar: AXUIElement) -> [AXUIElement] {
        var out: [AXUIElement] = []
        func walk(_ e: AXUIElement, _ depth: Int) {
            for c in e.elements(kAXChildrenAttribute) {
                var settable: DarwinBoolean = false
                if AXUIElementIsAttributeSettable(c, kAXFocusedAttribute as CFString, &settable) == .success, settable.boolValue,
                   (c.attr(kAXEnabledAttribute) as? Bool) != false { out.append(c) }
                else if depth < 4 { walk(c, depth + 1) }
            }
        }
        walk(toolbar, 0)
        return out
    }

    /// The first control of the window outside its toolbar that can take the keyboard.
    static func firstContent(in window: AXUIElement) -> AXUIElement? {
        func find(_ e: AXUIElement, _ depth: Int) -> AXUIElement? {
            for c in e.elements(kAXChildrenAttribute) {
                let r = c.role
                if r == "AXToolbar" || r == "AXMenuBar" { continue }
                var settable: DarwinBoolean = false
                if !["AXScrollBar", "AXSplitter", "AXValueIndicator"].contains(r),
                   AXUIElementIsAttributeSettable(c, kAXFocusedAttribute as CFString, &settable) == .success, settable.boolValue,
                   (c.attr(kAXEnabledAttribute) as? Bool) != false { return c }
                if depth < 10, let f = find(c, depth + 1) { return f }
            }
            return nil
        }
        return find(window, 0)
    }

    private static func label(_ e: AXUIElement) -> String {
        "\(e.role) \"\(Log.words(e.string(kAXTitleAttribute) ?? e.string(kAXDescriptionAttribute) ?? ""))\""
    }

    /// Puts the keyboard on `target`; the focus event says it as any new focus. If no focus event comes (the app
    /// does not post one), it is said here after a moment. False if the app refused.
    private static func focus(_ target: AXUIElement, from f: TurnOverObject) -> Bool {
        guard target.set(kAXFocusedAttribute, kCFBooleanTrue) == .success else { return false }
        let before = f.element
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard API.focusObject?.isSameElement(as: before) == true, !CFEqual(target, before) else { return }
            Log.io("toolbar: no focus event came after the move; saying the control")
            Speech.speakObject(ObjectFactory.make(target), reason: .focus)
        }
        return true
    }

    private static func run(_ key: Key, _ g: KeyboardGesture) {
        guard let f = API.focusObject, inToolbar(f) else { g.send(); return }
        let app = NSRunningApplication(processIdentifier: f.pid)?.localizedName ?? "?"
        let name = key == .escape ? "Escape" : key == .left ? "Left" : "Right"
        var toolbar: AXUIElement?
        var chain: [AXUIElement] = []
        var p: AXUIElement? = f.element; var hops = 0
        while let x = p, hops < 12 { chain.append(x); if x.role == "AXToolbar" { toolbar = x; break }; p = x.element(kAXParentAttribute); hops += 1 }
        guard let toolbar else { g.send(); return }
        let entry = isTextEntry(axRole: f.axRole, subrole: f.axSubrole)
        var list: [AXUIElement] = []
        var index: Int?
        if key != .escape {
            list = controls(in: toolbar)
            index = list.firstIndex { c in chain.contains { CFEqual($0, c) } }
        }
        let decision = decide(key, inToolbar: true, menuOpen: AXHandler.shared.isMenuOpen, textEntry: entry,
                              hasText: key == .escape && entry && hasText(f), usesArrowsItself: keepsArrows(axRole: f.axRole),
                              controlCount: list.count, index: index)
        switch decision {
        case .passThrough:
            Log.io("toolbar: \(name) in \(app) on \(label(f.element)): not ours; passed to the app")
            g.send()
        case .edge:
            Log.io("toolbar: \(name) in \(app) on \(label(f.element)): edge")
            Tones.edge()
        case .move(let n):
            let to = list[n]
            Log.io("toolbar: \(name) in \(app): \(label(f.element)) -> \(label(to)) (\(n + 1) of \(list.count))")
            if !focus(to, from: f) { Log.io("toolbar: the app would not give the keyboard to \(label(to)); the key goes to the app"); g.send() }
        case .escapeToContent:
            guard let window = SettingsPanePlugin.windowOf(f.element) else { g.send(); return }
            let module = AppModuleHandler.shared.appModule(for: f.pid)
            let found = chooseEscapeTarget(
                previous: { () -> AXUIElement? in
                    guard let e = lastOutside, e.role != "?", !CFEqual(e, f.element), e.pid == f.pid,
                          let w = SettingsPanePlugin.windowOf(e), CFEqual(w, window) else { return nil }
                    return e
                },
                appModule: { module.toolbarEscapeTarget(in: window) },
                firstContent: { firstContent(in: window) })
            guard let found else {
                Log.io("toolbar: Escape in \(app) on \(label(f.element)): no content to return to; passed to the app")
                g.send(); return
            }
            Log.io("toolbar: Escape in \(app): \(label(f.element)) -> \(label(found.target)) (\(found.source.rawValue))")
            if !focus(found.target, from: f) { Log.io("toolbar: the app would not give the keyboard to \(label(found.target)); the key goes to the app"); g.send() }
        }
    }

    /// The scripts, declared on the global commands.
    static func declare(on commands: ScriptableObject) {
        let cat = "Object navigation"
        let items: [(String, String, Key, String)] = [
            ("toolbar_previous", String(localized: "In a toolbar: the previous control; the edge sound at the first", comment: "A command, as the key list and keyboard help say it"), .left, "kb:leftArrow"),
            ("toolbar_next", String(localized: "In a toolbar: the next control; the edge sound at the last", comment: "A command, as the key list and keyboard help say it"), .right, "kb:rightArrow"),
            ("toolbar_escape", String(localized: "In a toolbar: back to the window's content", comment: "A command, as the key list and keyboard help say it"), .escape, "kb:escape"),
        ]
        for (name, description, key, gesture) in items {
            commands.script(name, description, gestures: [gesture], category: cat) { g in run(key, g) }.isAvailable = { available(key) }
        }
    }
}
