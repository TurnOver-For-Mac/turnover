// SPDX-License-Identifier: GPL-3.0-or-later
// The object (NVDA: NVDAObjects.NVDAObject). One widget, abstracted: name,
// role, value, states, description, shortcut, position; its relations; the
// text inside it; the events it receives and the scripts it answers. The rest
// of the reader works with this and never with the accessibility API.
//
// Objects are made by ObjectFactory: the app module may choose a class for an
// element, then the role picks a behaviour (EditableText for text fields,
// Dialog for dialogs), then the base class.
import Foundation
import ApplicationServices
import AppKit
import TurnOverAX

open class TurnOverObject: ScriptableObject {
    public let element: AXUIElement
    public let axRole: String
    public let axSubrole: String?
    public let pid: pid_t

    public required init(element: AXUIElement) {
        self.element = element
        axRole = element.role
        axSubrole = element.string(kAXSubroleAttribute)
        pid = element.pid
        super.init()
        initOverlay()
    }

    /// Where subclasses declare their scripts (NVDA: initOverlayClass).
    open func initOverlay() {}

    // MARK: - Properties (lazy, cached per object: objects are made fresh per event)

    open var role: Role { _role }
    private lazy var _role: Role = Role.from(axRole: axRole, subrole: axSubrole)

    /// A role's spoken name when the control supplies a better one (NVDA: roleText), or a plugin's.
    open var roleText: String? { profileLabel?.1 }
    /// A plugin profile's name and role for this element, if one applies (PLUGIN-GUIDE.md).
    public private(set) lazy var profileLabel: (String?, String?)? = ProfileStore.shared.label(for: element, pid: pid)

    /// NVDA's name: the title; or the description that AppKit and Office use as a label; or the label element beside it.
    open var name: String {
        // A field with no label but a placeholder ("Title" in Safari's bookmark sheet) is named by it, as VoiceOver does.
        if _name.isEmpty, [.editableText, .searchField, .comboBox].contains(role), let p = placeholder, !p.isEmpty { return p }
        // The window's own buttons have no name: VoiceOver calls them by what they do.
        if _name.isEmpty, let n = ["AXCloseButton": "close", "AXMinimizeButton": "minimise", "AXZoomButton": "zoom", "AXFullScreenButton": "full screen"][element.string(kAXSubroleAttribute) ?? ""] { return n }
        if _name.isEmpty, let l = swiftUILabel() { return l }
        return _name
    }
    /// The name as the element gives it, for a subclass that knows where else to look (TurnOver Settings' module).
    var rawName: String { _name }
    /// SwiftUI links a control to its label (AXTitleUIElement) a moment after the control takes the focus: asked
    /// at once, the name was empty and stayed so ("switch, on" in TurnOver Settings, 18 Oct 2026). Asked again.
    func swiftUILabel() -> String? {
        guard let l = element.element(kAXTitleUIElementAttribute)?.string(kAXValueAttribute)?.trimmingCharacters(in: CharacterSet(charactersIn: ": \n")),
              !l.isEmpty, l.count <= 60 else { return nil }
        return l
    }
    private lazy var _name: String = { Self.oneLine(computedName) }()

    /// A programming class name standing in for a title ("Avalonia.Controls.Grid": .NET's Avalonia titles controls
    /// it wasn't given a name for with their class): no name at all (parts request #5, Libation, 14 Oct 2026). Three
    /// or more dotted parts, each a capitalised word, no spaces. Pure.
    nonisolated public static func isClassName(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, !s.contains(" ") else { return false }
        return parts.allSatisfy { p in p.first.map { $0.isUppercase } == true && p.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } }
    }

    /// A title on several lines says each different line once ("user@example.com\nuser@example.com" in a VPN app's menu).
    static func oneLine(_ s: String) -> String {
        guard s.contains("\n") else { return s }
        var seen: [String] = []
        for l in s.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) where !l.isEmpty && !seen.contains(l) { seen.append(l) }
        return seen.joined(separator: ", ")
    }

    private var computedName: String {
        if let n = profileLabel?.0, !n.isEmpty { return n }
        if let t = element.string(kAXTitleAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !isValueEcho(t), !Self.isClassName(t) { return t }
        if let d = element.string(kAXDescriptionAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty, !isValueEcho(d), !Self.isClassName(d) { usedDescriptionAsName = true; return d }
        // A spin button titled by its text field (Word's Paragraph dialog: "0 cm"): the field's own label names it.
        if let tu = element.element(kAXTitleUIElementAttribute), tu.role == "AXTextField" {
            let field = ObjectFactory.make(tu).name
            if !field.isEmpty { return field }
        }
        if let label = element.element(kAXTitleUIElementAttribute)?.string(kAXValueAttribute)?.trimmingCharacters(in: CharacterSet(charactersIn: ": \n")), !label.isEmpty, label.count <= 60 { return label }
        if let l = neighbourLabel() { return l }
        // An icon button with only a tooltip is named by it, as VoiceOver reads it: Cyberduck's Back, Forward and its
        // Browser, Bookmarks and History buttons were just "button" and "radio button" (Day 4, 11 Oct 2026).
        // Not the window's own buttons: the green one's tooltip ("this button also has an action to zoom the
        // window", Voice Memos, 14 Oct 2026) is read instead of "full screen".
        if [.button, .radioButton, .checkBox, .popUpButton, .menuButton, .toggleButton].contains(role),
           !["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"].contains(axSubrole ?? ""),
           let h = element.string(kAXHelpAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty, h.count <= 60 { return h }
        // A row or cell with no name of its own is the text of what it holds (Mail's message list: sender, subject, date, preview).
        if [.tableRow, .tableCell, .listItem, .treeViewItem, .cell].contains(role) { return contentText(limit: 8) }
        // An item, button or link whose name is only in the text it holds (Electron apps: GitHub Desktop's repository
        // list is menu items with the repository's name in a child, so each was a nameless "menu item", 21 Oct 2026).
        if [.menuItem, .button, .link].contains(role) {
            let held = contentText(limit: 4)
            if !held.isEmpty { return held }
        }
        // The switch inside a SwiftUI toggle: Tab forward lands on it, a nameless button holding no text, while Shift
        // Tab lands on the check box around it, which has the label (TurnOver Settings, Screen reader behaviour, 25
        // Oct 2026: "switch, on" one way, the full name the other). Named by that check box, only when it has no name
        // or text of its own and nothing else is inside it (a code review, 25 Oct 2026).
        if [.button, .switchControl, .toggleButton].contains(role), element.elements(kAXChildrenAttribute).isEmpty,
           let p = element.element(kAXParentAttribute), p.role == "AXCheckBox" {
            let named = [p.string(kAXTitleAttribute), p.string(kAXDescriptionAttribute)]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            if let named { return named }
        }
        return ""
    }

    /// The text that labels an unnamed control from beside it: on its row to its left, else just above it. Native
    /// windows only (a web page names its own controls), and only among a modest number of siblings.
    private func neighbourLabel() -> String? {
        guard [.popUpButton, .comboBox, .editableText, .slider, .spinButton, .menuButton, .checkBox, .radioButton].contains(role),
              let parent = element.element(kAXParentAttribute), let me = Self.frame(element) else { return nil }
        let siblings = parent.elements(kAXChildrenAttribute)
        guard siblings.count <= 80, !siblings.contains(where: { $0.role == "AXWebArea" }), parent.role != "AXWebArea" else { return nil }
        var left: (String, CGFloat)?, above: (String, CGFloat)?
        for s in siblings where s.role == "AXStaticText" {
            guard let t = s.string(kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, t.count <= 60,
                  let f = Self.frame(s) else { continue }
            if abs(f.midY - me.midY) <= max(6, me.height / 2), f.maxX <= me.minX + 8 {
                if left == nil || f.maxX > left!.1 { left = (t, f.maxX) }
            } else if f.maxY <= me.minY + 4, me.minY - f.maxY < 30, abs(f.minX - me.minX) < 80 {
                if above == nil || f.maxY > above!.1 { above = (t, f.maxY) }
            }
        }
        return (left ?? above).map { $0.0.trimmingCharacters(in: CharacterSet(charactersIn: ": ")) }
    }

    /// The static text, values and descriptions inside this element, in order, bounded.
    public func contentText(limit: Int) -> String {
        var parts: [String] = []
        var images: [String] = []
        var queue = element.elements(kAXChildrenAttribute)
        var visited = 0
        // Each element's role, value, title, description and children in one question (SwiftUI apps are slow to
        // answer: Contacts' rows took 80 ms each to name, 10 Oct 2026).
        let names = [kAXRoleAttribute, kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXChildrenAttribute]
        func trimmed(_ v: AnyObject?) -> String? {
            guard let t = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        while !queue.isEmpty, visited < 60, parts.count < limit {
            let e = queue.removeFirst(); visited += 1
            let a = e.attrs(names)
            let r = (a[kAXRoleAttribute] as? String) ?? "?"
            let kids = { (a[kAXChildrenAttribute] as? [AXUIElement]) ?? [] }
            let value = a[kAXValueAttribute], title = trimmed(a[kAXTitleAttribute]), desc = trimmed(a[kAXDescriptionAttribute])
            if r == "AXCheckBox", let t = title {
                let on = (value as? NSNumber)?.intValue == 1
                parts.append("\(t), \(on ? "checked" : "not checked")")
            } else if r == "AXStaticText" || r == "AXTextField" {
                if let v = trimmed(value) { parts.append(String(v.prefix(300))) }
                else if r == "AXTextField" { queue.append(contentsOf: kids()) }
            } else if (r == "AXCell" || r == "AXGroup"), let d = desc {
                // A cell that describes itself (Safari's Reading List: "Boson, en.wikipedia.org") says it once.
                parts.append(String(d.prefix(300)))
            } else if r == "AXHeading", let d = desc ?? title ?? trimmed(value) {
                // System Settings' Automation list: each app's name is a heading in its row (only "collapsed, 1 of
                // 13" was heard, 7 Oct 2026).
                parts.append(String(d.prefix(300)))
            } else if r == "AXImage" {
                if let d = desc { images.append(d) }
            } else if r == "AXButton" || r == "AXCheckBox" {
                if let d = desc ?? title { parts.append(d) }
            } else {
                queue.append(contentsOf: kids())
            }
        }
        // An icon's description only stands in when the row has no text of its own.
        return (parts.isEmpty ? images : parts).joined(separator: ", ")
    }
    private var usedDescriptionAsName = false

    /// Word puts a field's contents into its own title; a label equal to the value is no label.
    private func isValueEcho(_ t: String) -> Bool {
        guard role == .editableText || role == .searchField || role == .comboBox, let v = element.string(kAXValueAttribute) else { return false }
        return t.caseInsensitiveCompare(v) == .orderedSame
    }

    open var description: String? { _description }

    /// The texts on the same row as a control whose name its siblings share (Mail's Fonts settings: three
    /// "Select…" buttons, each beside its own "Message font:" and "Helvetica 12"). Nothing ties them to the
    /// button but where they are, so where they are is used: the texts whose middle is level with it, left to right.
    private func rowLabel() -> String? {
        guard [.button, .popUpButton, .menuButton].contains(role), let parent = element.element(kAXParentAttribute) else { return nil }
        let siblings = parent.elements(kAXChildrenAttribute)
        guard siblings.count <= 60, let me = Self.frame(element) else { return nil }
        let title = element.string(kAXTitleAttribute) ?? element.string(kAXDescriptionAttribute) ?? ""
        guard !title.isEmpty, siblings.filter({ ($0.string(kAXTitleAttribute) ?? $0.string(kAXDescriptionAttribute)) == title }).count >= 2 else { return nil }
        var row: [(CGFloat, String)] = []
        for s in siblings where s.role == "AXStaticText" {
            guard let f = Self.frame(s), let v = s.string(kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { continue }
            if f.midY >= me.minY, f.midY <= me.maxY { row.append((f.minX, v)) }
        }
        guard !row.isEmpty else { return nil }
        return row.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: " ")
    }

    public static func debugFrame(_ e: AXUIElement) -> String { frame(e).map { "(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height)))" } ?? "-" }
    /// An element's frame on screen, in points from the top left of the main display (accessibility's own
    /// convention, so it compares with CGEvent and Vision points without flipping). Nil when the app gives no
    /// position or size, or gives something that isn't one: never a made-up zero. The one place this is read
    /// (20 Oct 2026: seven copies became this one); callable off the main thread.
    nonisolated static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = e.attr(kAXPositionAttribute), let z = e.attr(kAXSizeAttribute) else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard axValue(p, .cgPoint, &pt), axValue(z, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }

    private lazy var _description: String? = {
        _ = _name
        if let r = rowLabel() { return r }
        if !usedDescriptionAsName, let d = element.string(kAXDescriptionAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty, d != _name, !Role.withNavigableText.contains(role) { return d }
        // AXHelp is the hover tip ("Drag to the Mini Player to add to the queue"): not a description, as NVDA treats it.
        return nil
    }()

    open var placeholder: String? { element.string("AXPlaceholderValue") }

    /// The value as text, formatted for the role (NVDA: value). Check boxes carry theirs in states.
    open var value: String? { _value }
    /// A number box with nothing in it whose spinner holds the number: Avalonia's NumericUpDown puts the value on the
    /// AXIncrementor around the text box that has the focus, which read "blank" while showing 3 (parts request #5,
    /// Libation, 14 Oct 2026).
    /// Apps where a deep walk found an incrementor, and apps where one full walk found none: after that, two levels
    /// (every empty search box paid up to 28 round trips on the focus: code review, 16 Oct 2026).
    nonisolated(unsafe) private static var deepIncrementorPids: Set<pid_t> = []
    nonisolated(unsafe) private static var shallowIncrementorPids: Set<pid_t> = []
    private var incrementorValue: String? {
        guard [.editableText, .spinButton].contains(role) else { return nil }
        let deep = !Self.shallowIncrementorPids.contains(pid)
        let limit = deep ? 14 : 2   // eleven levels in Libation's spinner
        var p = element.element(kAXParentAttribute); var hops = 0
        while let x = p, hops < limit {
            if x.role == "AXIncrementor", let v = x.attr(kAXValueAttribute) { Self.deepIncrementorPids.insert(pid); let t = "\(v)"; return t.isEmpty ? nil : t }
            p = x.element(kAXParentAttribute); hops += 1
        }
        if deep, !Self.deepIncrementorPids.contains(pid) { Self.shallowIncrementorPids.insert(pid) }
        return nil
    }
    private lazy var _value: String? = {
        guard let v = element.attr(kAXValueAttribute) else { return incrementorValue }
        if let s = v as? String {
            if s.isEmpty, let n = incrementorValue { return n }
            // Some toolkits (wxWidgets: Bambu Studio) hand over an object's debug description as its value.
            if s.hasPrefix("<NS"), s.contains(" 0x") { return nil }
            if s.contains(Attachments.mark) { return Attachments.expand(s, in: element, from: 0) }
            return s
        }
        if let n = v as? NSNumber {
            switch role {
            case .checkBox, .radioButton, .toggleButton, .switchControl, .disclosureTriangle, .menuItem, .checkMenuItem, .radioMenuItem, .tab, .button, .menuButton, .popUpButton: return nil
            case .slider, .progressBar, .levelIndicator, .spinButton:
                if let s = element.string("AXValueDescription"), !s.isEmpty { return s }
                // A slider from 0 to 1 is a fraction: said as a percentage, as VoiceOver says it (9 Oct 2026).
                if role == .slider, let lo = element.attr(kAXMinValueAttribute) as? NSNumber, let hi = element.attr(kAXMaxValueAttribute) as? NSNumber,
                   lo.doubleValue == 0, hi.doubleValue == 1 { return "\(Int((n.doubleValue * 100).rounded())) percent" }
                // A progress bar is always a percentage of its range, as VoiceOver and NVDA say it: an installer's
                // download was "0.9" (18 Oct 2026).
                if role == .progressBar {
                    let lo = (element.attr(kAXMinValueAttribute) as? NSNumber)?.doubleValue ?? 0
                    let hi = (element.attr(kAXMaxValueAttribute) as? NSNumber)?.doubleValue ?? (n.doubleValue <= 1 ? 1 : 100)
                    if hi > lo { return "\(Int(((n.doubleValue - lo) / (hi - lo) * 100).rounded())) percent" }
                }
                return n.doubleValue == n.doubleValue.rounded() ? "\(n.intValue)" : String(format: "%.1f", n.doubleValue)
            default: return n.stringValue
            }
        }
        if let d = v as? Date { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f.string(from: d) }
        if let u = v as? URL { return u.absoluteString }
        return nil
    }()

    open var states: Set<State> { _states }
    private lazy var _states: Set<State> = {
        var s = Set<State>()
        // Unavailable is said only of things that can be used. Preview's page list and its PDF pages report themselves
        // disabled, and "list, unavailable" or "page, unavailable" means nothing to the user (Day 2, 10 Oct 2026).
        // An item of a collection says it's disabled though it can be chosen and opened (every board in Freeform was
        // "unavailable", parts sweep, 14 Oct 2026): not said there.
        // Nor a control that has the keyboard: a disabled one can't take it. Java's (PDFsam) report every button
        // disabled, and each Tab said "Split, button, unavailable" (parts sweep, 14 Oct 2026).
        if let enabled = element.attr(kAXEnabledAttribute) as? Bool, !enabled, !Role.neverUnavailable.contains(role),
           element.element(kAXParentAttribute)?.string(kAXSubroleAttribute) != "AXSectionList",
           (element.attr(kAXFocusedAttribute) as? Bool) != true { s.insert(.unavailable) }
        if let f = element.attr(kAXFocusedAttribute) as? Bool, f { s.insert(.focused) }
        if let sel = element.attr(kAXSelectedAttribute) as? Bool, sel { s.insert(.selected) }
        if let n = element.attr(kAXValueAttribute) as? NSNumber {
            switch role {
            case .checkBox, .checkMenuItem, .radioButton, .radioMenuItem, .toggleButton:
                if n.intValue == 2 { s.insert(.halfChecked) } else if n.intValue != 0 { s.insert(role == .toggleButton ? .pressed : .checked) }
            case .switchControl: if n.intValue != 0 { s.insert(.on) }
            case .tab: if n.intValue != 0 { s.insert(.selected) }   // a tab button's value: the tab showing
            case .disclosureTriangle: s.insert(n.intValue != 0 ? .expanded : .collapsed)
            default: break
            }
        }
        if let e = element.attr(kAXExpandedAttribute) as? Bool { s.insert(e ? .expanded : .collapsed) }
        if let d = element.attr("AXDisclosing") as? Bool, role == .treeViewItem {
            // Finder's list view: only a row that can disclose (a folder) is expanded or collapsed.
            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(element, "AXDisclosing" as CFString, &settable)
            if settable.boolValue || d { s.insert(d ? .expanded : .collapsed) }
        }
        if let m = element.string("AXMenuItemMarkChar"), !m.isEmpty { s.insert(.checked) }
        if role == .menuItem, element.elements(kAXChildrenAttribute).contains(where: { $0.role == "AXMenu" }) { s.insert(.hasPopup) }
        // "password edit" says it is protected; "protected" as well was one word too many (3 Oct 2026).
        if let r = element.attr("AXRequired") as? Bool, r { s.insert(.required) }
        if let m = element.attr(kAXModalAttribute) as? Bool, m { s.insert(.modal) }
        if let b = element.attr("AXElementBusy") as? Bool, b { s.insert(.busy) }
        // Safari marks every empty required field invalid before anything is typed: that is not news. Invalid is
        // said once the field holds something the page rejects.
        if let inv = element.attr("AXInvalid") as? String, inv != "false", !inv.isEmpty {
            let empty = role == .passwordEdit ? SecureEcho.length(element) == 0 : (element.string(kAXValueAttribute) ?? "").isEmpty
            if !(empty && s.contains(.required)) { s.insert(.invalidEntry) }
        }
        if Role.withNavigableText.contains(role), role != .document, role != .webArea, axRole != "AXWebArea" { s.insert(.editable); if axRole == "AXTextArea" { s.insert(.multiLine) } }
        return s
    }()

    /// "command N" from a menu item's command character and modifiers.
    open var keyboardShortcut: String? { _shortcut }
    private lazy var _shortcut: String? = {
        guard let ch = element.string("AXMenuItemCmdChar"), !ch.isEmpty else { return nil }
        let mods = element.int("AXMenuItemCmdModifiers") ?? 0
        var parts: [String] = []
        if mods & 4 != 0 { parts.append("control") }
        if mods & 2 != 0 { parts.append("option") }
        if mods & 1 != 0 { parts.append("shift") }
        if mods & 8 == 0 { parts.append("command") }
        parts.append(ch.count == 1 && ch.first!.isLetter ? ch.lowercased() : ch)
        return parts.joined(separator: " ")
    }()

    public struct PositionInfo { public var index: Int?; public var count: Int?; public var level: Int? }
    open var positionInfo: PositionInfo? { _positionInfo }
    private lazy var _positionInfo: PositionInfo? = {
        guard [.listItem, .tableRow, .treeViewItem, .tab, .menuItem, .checkMenuItem, .radioMenuItem, .radioButton, .dockItem].contains(role) else { return nil }
        var p = PositionInfo()
        if role == .treeViewItem, let level = element.int("AXDisclosureLevel"), level > 0 { p.level = level + 1 }   // NVDA-style: the top level goes without saying
        if let parent = element.element(kAXParentAttribute) {
            var count: CFIndex = 0
            let attr = parent.role == "AXTable" || parent.role == "AXOutline" ? "AXRows" : kAXChildrenAttribute
            if AXUIElementGetAttributeValueCount(parent, attr as CFString, &count) == .success, count > 0 {
                if count <= 200, let siblings = parent.attr(attr) as? [AXUIElement] {
                    // Only siblings of the same role count, and a menu's separators (untitled, disabled items) don't.
                    let same = siblings.filter { s in
                        guard s.role == axRole else { return false }
                        if axRole == "AXMenuItem", (s.string(kAXTitleAttribute) ?? "").isEmpty { return false }
                        return true
                    }
                    if let i = same.firstIndex(where: { CFEqual($0, element) }) { p.index = i + 1; p.count = same.count }
                } else if let i = element.int(kAXIndexAttribute) { p.index = i + 1; p.count = Int(count) }
            }
        }
        return p.index == nil && p.level == nil ? nil : p
    }()

    // MARK: - Relations

    open var parent: TurnOverObject? { element.element(kAXParentAttribute).map { ObjectFactory.make($0) } }
    open var children: [TurnOverObject] { element.elements(kAXChildrenAttribute).map { ObjectFactory.make($0) } }
    open var firstChild: TurnOverObject? { element.elements(kAXChildrenAttribute).first.map { ObjectFactory.make($0) } }
    open var next: TurnOverObject? { sibling(+1) }
    open var previous: TurnOverObject? { sibling(-1) }
    private func sibling(_ delta: Int) -> TurnOverObject? {
        guard let parent = element.element(kAXParentAttribute) else { return nil }
        let kids = parent.elements(kAXChildrenAttribute)
        guard let i = kids.firstIndex(where: { CFEqual($0, element) }), kids.indices.contains(i + delta) else { return nil }
        return ObjectFactory.make(kids[i + delta])
    }
    /// Ancestors from the parent up to the application, bounded.
    open var ancestors: [TurnOverObject] {
        var out: [TurnOverObject] = []
        var e = element.element(kAXParentAttribute)
        while let p = e, out.count < 40 {
            let o = ObjectFactory.make(p)
            out.append(o)
            if o.axRole == "AXApplication" { break }   // the role the object already read (one call per level less: code review, 16 Oct 2026)
            e = p.element(kAXParentAttribute)
        }
        return out
    }
    open var window: TurnOverObject? { element.element(kAXWindowAttribute).map { ObjectFactory.make($0) } }
    open var appModule: AppModule { AppModuleHandler.shared.appModule(for: pid) }

    /// NVDA: isPresentableFocusAncestor — spoken when the focus enters it.
    open var isPresentableFocusAncestor: Bool {
        if Role.presentableAncestors.contains(role) { return role != .groupBox || !name.isEmpty }
        return false
    }

    // MARK: - Text

    open var hasNavigableText: Bool { Role.withNavigableText.contains(role) }

    /// The TextInfo class for this object; EditableText overrides to AXTextInfo.
    open var textInfoClass: TextInfo.Type { hasNavigableText ? AXTextInfo.self : TextInfo.self }

    public func makeTextInfo(_ position: TextPosition) throws -> TextInfo {
        guard hasNavigableText else { throw TextInfoError("no text") }
        return try textInfoClass.init(obj: self, position: position)
    }

    // MARK: - Identity

    public func isSameElement(as other: TurnOverObject?) -> Bool { other.map { CFEqual(element, $0.element) } ?? false }
    public func isSameElement(as other: AXUIElement) -> Bool { CFEqual(element, other) }

    // MARK: - Actions

    public func setFocus() { _ = element.set(kAXFocusedAttribute, kCFBooleanTrue) }
    public func doDefaultAction() { AXUIElementPerformAction(element, kAXPressAction as CFString) }

    // MARK: - Events (NVDA: event_*). The object is the last handler in the chain.

    /// Speak this object as the focus (NVDA: reportFocus).
    open func reportFocus() {
        TurnOverObject.lastName = (element, name)
        // The selection event that follows on the same element is the same news (LibreOffice Calc's cells take the
        // focus and are selected on each arrow: every cell was said twice, parts sweep 14 Oct 2026).
        TurnOverObject.noteSelectionSpoken(element)
        Speech.speakObject(self, reason: .focus)
    }

    /// The focus's name as last spoken. Claude's collapsed summary button ("Ran 23 commands (2 failed), compacted the
    /// session, read MediaView.swift") reports a name change each time the conversation moves on, with the same name:
    /// it was read again every few seconds (7 Oct 2026). Only a new name is news.
    static var lastName: (element: AXUIElement, name: String)?

    open func event_gainFocus() {
        // A settings window opens with the focus on the window itself (Mail): nothing for the arrows to move.
        // Put it on the pane's tab, as Windows opens a dialog on its tab control; that focus speaks.
        if role == .window, let tab = PreferenceTab.selectedTab(in: element) {
            Log.io("settings window has no focus inside; to its tab \"\(Log.words(tab.string(kAXTitleAttribute) ?? ""))\"")
            _ = tab.set(kAXFocusedAttribute, kCFBooleanTrue)
            return
        }
        reportFocus()
    }
    open func event_loseFocus() { Speech.clearTypedWordBuffer() }
    open func event_focusEntered() { Speech.speakObject(self, reason: .focusEntered) }
    open func event_focusExited() {}
    open func event_foreground() { Speech.cancel() }
    open func event_valueChange() {
        guard API.focusObject?.isSameElement(as: self) == true else { return }
        // A check box keeps its state in its value (a number): the news is "checked" / "not checked" (NVDA's state
        // change). Pressing the developer agreement's box said nothing, 3 Oct 2026.
        if [.checkBox, .radioButton, .toggleButton, .switchControl].contains(role) {
            // Read afresh, a moment after the event: this object may be the focus object made before the press, its
            // states remembered (it said "checked" as the box became unchecked, 3 Oct 2026). Only the check state
            // is news here, not "required" or "invalid entry".
            // Only if the focus is still on it: Qt (MuseScore) reports a value change on the box being left, just
            // before the focus moves, and its state was said after the next control's (parts sweep, 14 Oct 2026).
            let el = element
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard API.focusObject?.element.isSame(el) == true else { return }
                Speech.speakCheckState(of: el)
            }
            return
        }
        // The value is read afresh: this is the focus object, made when the control took the focus, and its value
        // is remembered from then (a slider said 0.9 at every step, in a game, 9 Oct 2026).
        let fresh = ObjectFactory.make(element)
        Speech.speakObjectProperty(fresh, value: true)
    }
    open func event_nameChange() {
        guard role != .window, API.focusObject?.isSameElement(as: self) == true else { return }
        let n = name
        if let last = TurnOverObject.lastName, CFEqual(last.element, element), last.name == n { return }
        TurnOverObject.lastName = (element, n)
        Speech.speakObjectProperty(self, name: true)
    }
    open func event_stateChange() { if API.focusObject?.isSameElement(as: self) == true { Speech.speakObjectProperty(self, states: true) } }
    open func event_descriptionChange() {}
    open func event_caret() {}
    open func event_selection() {
        // A list that announces its own selection and the script that waited for it can both report one row.
        if let (e, t) = TurnOverObject.lastSelectionSpoken, Date().timeIntervalSince(t) < 0.6, e.isSame(element) { return }
        TurnOverObject.lastSelectionSpoken = (element, Date())
        Speech.speakObject(self, reason: .focus)
        if let note = TurnOverObject.selectionNote { TurnOverObject.selectionNote = nil; Speech.speakMessage(note) }   // "3 selected", after the row that changed
    }
    /// Set by the selection notification when several rows are selected: said after the row that changed.
    public static var selectionNote: String?
    private static var lastSelectionSpoken: (AXUIElement, Date)?
    public static func noteSelectionSpoken(_ e: AXUIElement) { lastSelectionSpoken = (e, Date()) }
    open func event_textChange() {}
    open func event_alert() { Speech.speakObject(self, reason: .focus) }
    /// NVDA: a live region's new text is spoken, politely (queued) or assertively (interrupting).
    open func event_liveRegionChange() {
        guard config.presentation.reportDynamicContentChanges else { return }
        let t = ClaudeTranscript.text(of: element, skipHidden: false)
        guard !t.isEmpty else { return }
        LiveRegions.speak(t, from: element, assertive: element.string("AXARIALive") == "assertive")
    }
    open func event_menuStart() {
        // A menu bar menu is named by the menu bar item above it (Word's menus have no names of their own).
        // A submenu is named by the item that holds it ("Clear submenu").
        let parent = element.element(kAXParentAttribute)
        let parentRole = parent?.role ?? ""
        var menuName = name.isEmpty ? (parent?.string(kAXTitleAttribute) ?? "") : name
        // A status menu hangs off an unnamed menu extra: it is the application's menu ("a VPN app's menu").
        if menuName.isEmpty, parentRole == "AXMenuBarItem" || parent?.string(kAXSubroleAttribute) == "AXMenuExtra" {
            menuName = parent?.string(kAXDescriptionAttribute) ?? NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
        }
        if menuName.isEmpty, let (n, at) = StatusMenus.lastOpened, Date().timeIntervalSince(at) < 3 {
            StatusMenus.lastOpened = nil
            menuName = n.components(separatedBy: ",").first ?? n
            Speech.speakMessage("\(menuName) menu")
            return
        }
        let kind = parentRole == "AXMenuItem" ? "submenu" : "menu"
        if parentRole == "AXMenuBarItem", Date().timeIntervalSince(Speech.lastMenuBarItemSpoken) < 0.4 { return }   // already said ("View menu, 5 of 10")
        // A context menu says so (6 Oct 2026): one just asked for (VO Shift M, the right Option, Shift F10), or
        // any menu that hangs off no menu bar, menu or button, even when the app gives it a name.
        let asked = Date().timeIntervalSince(Self.contextMenuRequestedAt) < 2
        let ownMenu: Set<String> = ["AXMenuBarItem", "AXMenuItem", "AXPopUpButton", "AXMenuButton", "AXComboBox", "AXButton"]   // a menu bar, submenu or pop-up button's menu
        if asked || (!ownMenu.contains(parentRole) && parent?.string(kAXSubroleAttribute) != "AXMenuExtra" && StatusMenus.lastOpened == nil) {
            Self.contextMenuRequestedAt = .distantPast
            VoiceOverSounds.play("PopupAppeared.aiff")
            Speech.speakMessage("context menu")
            return
        }
        Speech.speakMessage(menuName.isEmpty ? "context menu" : "\(menuName) \(kind)")
    }
    /// When a context menu was last asked for by key; the menu that opens then is announced as one.
    public static var contextMenuRequestedAt = Date.distantPast
    open func event_menuEnd() {}
    open func event_typedCharacter(_ ch: Character) {
        if role == .passwordEdit || Speech.typingIntoSecretField { Speech.speakSecureCharacter(); return }
        let wordEnds = !(ch.isLetter || ch.isNumber || ch == "'" || ch == "’") && ch != "\u{8}"
        Speech.speakTypedCharacter(ch, inEditable: hasNavigableText && !states.contains(.readOnly),
                                   wordBefore: wordEnds && hasNavigableText ? { [weak self] in self?.wordBeforeCaret(typed: ch) } : nil)
    }

    /// The word just before the caret, from the field's text (the character just typed left off if it is already in).
    func wordBeforeCaret(typed ch: Character) -> String? {
        guard let info = try? makeTextInfo(.caret) else { return nil }
        let end = info.start
        var t = info.textRange(max(0, end - 80), end)
        if t.last == ch { t.removeLast() }
        let word = t.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" }
        return word.isEmpty ? nil : String(word.reversed())
    }

    /// Dispatch (NVDA: eventHandler.executeEvent's last step).
    open func handleEvent(_ event: Event) {
        if event.kind == .caret || event.kind == .valueChange || event.kind == .selection, let f = API.focusObject, f.role == .passwordEdit,
           f.isSameElement(as: self) || axRole == "AXWebArea" {
            SecureEcho.changed(f.element)
            return
        }
        if event.kind == .gainFocus, role == .passwordEdit { SecureEcho.focused(element) }
        if event.kind == .gainFocus { SettingsPanePlugin.focusMoved(to: self) }
        switch event.kind {
        case .gainFocus: event_gainFocus()
        case .loseFocus: event_loseFocus()
        case .focusEntered: event_focusEntered()
        case .focusExited: event_focusExited()
        case .foreground: event_foreground()
        case .valueChange: event_valueChange()
        case .nameChange: event_nameChange()
        case .stateChange: event_stateChange()
        case .descriptionChange: event_descriptionChange()
        case .caret: event_caret()
        case .selection: event_selection()
        case .textChange: event_textChange()
        case .alert: event_alert()
        case .menuStart: event_menuStart()
        case .menuEnd: event_menuEnd()
        case .typedCharacter: if let c = event.character { event_typedCharacter(c) }
        case .appModuleGainFocus, .appModuleLoseFocus: break
        case .liveRegionChange: event_liveRegionChange()
        }
    }
}

/// Makes the right object for an element (NVDA: NVDAObject.__new__ with findOverlayClasses).
public enum ObjectFactory {
    public static func make(_ element: AXUIElement) -> TurnOverObject {
        let axRole = element.role
        let subrole = element.string(kAXSubroleAttribute)
        let role = Role.from(axRole: axRole, subrole: subrole)
        let module = AppModuleHandler.shared.appModule(for: element.pid)
        if let cls = module.objectClass(for: element, role: role, subrole: subrole) { return cls.init(element: element) }
        for plugin in GlobalPluginHandler.shared.plugins {
            if let cls = plugin.objectClass(for: element, role: role, subrole: subrole) { return cls.init(element: element) }
        }
        if role == .button, PreferenceTab.isPreferenceTab(element) { return PreferenceTab(element: element) }
        switch role {
        case .webArea: return EditableWebArea.isEditable(element) ? EditableWebArea(element: element) : WebArea(element: element)
        case .editableText, .searchField, .passwordEdit, .document, .textFrame: return EditableText(element: element)
        // A combo box you type into (a web search box with suggestions: Wikipedia's) is edited like a text field.
        case .comboBox where element.attr(kAXSelectedTextRangeAttribute) != nil: return EditableComboBox(element: element)
        case .dialog, .sheet: return Dialog(element: element)
        case .slider: return Slider(element: element)
        case .table, .list, .treeView, .outline, .browser: return SelectableList(element: element)
        default: return TurnOverObject(element: element)
        }
    }
}

/// Repeats of the same live text within a moment are one announcement (Chromium posts a change per node).
public enum LiveRegions {
    private static var last: (String, Date) = ("", .distantPast)
    public static func speak(_ text: String, from element: AXUIElement, assertive: Bool) {
        let t = String(text.prefix(500))
        // A streaming page re-posts the same text many times; it is news once (again only after a long quiet).
        if t == last.0, Date().timeIntervalSince(last.1) < 30 { last.1 = Date(); return }
        // A live region inside another posts for both: the same words again, one a part of the other, at once
        // (The Playroom's Uno, a tester, 9 Oct 2026). Within a second and a half, a part of what was just said is not news.
        if Date().timeIntervalSince(last.1) < 1.5, !last.0.isEmpty, last.0.contains(t) { Log.io("live region: repeat of a part, not said"); return }
        last = (t, Date())
        if assertive { Speech.cancel() }
        Log.io("live region: \(Log.words(String(t.prefix(80))))")
        Speech.speakNews(t)
    }
}
