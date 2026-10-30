// SPDX-License-Identifier: GPL-3.0-or-later
// Object navigation (NVDA: the navigator object and simple review mode; VoiceOver: the VoiceOver
// cursor). Moves through everything in the window whether or not the keyboard can reach it:
// Bambu Studio keeps its keyboard focus in a 3D view no reader can see, so Tab never reaches its
// settings; this does.
//
// The navigator follows the focus (NVDA's default). Next and previous walk the window in reading
// order and skip layout (unnamed groups, scroll areas, splitters, scroll bars, decorative images),
// as NVDA's simple review mode does. Parent and first child move through the structure itself.
import Foundation
import ApplicationServices
import AppKit

public final class ObjectNavigator {
    public static let shared = ObjectNavigator()
    /// The navigator object's element; nil means "the focus".
    private var current: AXUIElement? { didSet { cancelWindowSearch() } }
    private let windowSearch = AXWalkRunner<WindowKindSearchResult<AXUIElement>>()
    /// Where the review cursor is (for the plugin maker: the item it changes).
    public var reviewElement: AXUIElement? { current }
    private var currentPid: pid_t = 0

    /// The focus moved: the navigator goes with it (NVDA: follow focus).
    /// Whether the navigator is on this element or inside it (VO-Right follows the page only while it is in the page).
    public func isWithin(_ root: AXUIElement) -> Bool {
        guard let c = current else { return true }
        var p: AXUIElement? = c; var hops = 0
        while let x = p, hops < 60 { if x.isSame(root) { return true }; p = x.element(kAXParentAttribute); hops += 1 }
        return false
    }

    /// VoiceOver's cursor tracking, off for now (VO-Shift-F3): the review cursor stays where it is as the focus moves.
    public var tracksFocus = true

    public func focusMoved(to e: AXUIElement, pid: pid_t) {
        cancelWindowSearch()
        guard tracksFocus else { return }
        // Choosing in a held list moves the app's focus (Finder shows the folder): the cursor stays in the list.
        if heldList != nil, Date() < keepHoldUntil { return }
        // The focus TurnOver just put on the item the cursor landed on, and the app sent it on somewhere else (Safari's
        // toolbar buttons hand it back to the page): the cursor stays on the item. Following the bounce put the
        // cursor on the page, so VO-Right from the toolbar's first button bumped at an edge, or landed on the window's
        // close button (issue 106, 26 Oct 2026).
        if let f = followed, Date().timeIntervalSince(f.at) < 1.5, !CFEqual(f.element, e) {
            var p: AXUIElement? = e; var hops = 0; var inside = false
            while let x = p, hops < 10 { if x.isSame(f.element) { inside = true; break }; p = x.element(kAXParentAttribute); hops += 1 }
            if !inside { Log.io("review: the focus moved on to \(e.role) after following the cursor; the cursor stays"); return }
        }
        current = e; currentPid = pid; labelSource = nil; heldList = nil
    }
    private var keepHoldUntil = Date.distantPast

    /// The focus TurnOver gave to what its cursor landed on, and when.
    private var followed: (element: AXUIElement, at: Date)?
    public func isFollowedFocus(_ e: AXUIElement) -> Bool {
        guard let f = followed, Date().timeIntervalSince(f.at) < 1.5 else { return false }
        return CFEqual(f.element, e)
    }

    /// The keyboard focus follows the cursor, as VoiceOver's and Narrator's do by default: landing on the sidebar (or
    /// a row in it), the arrows then move in the sidebar (7 Oct 2026: Finder's sidebar and toolbar could be
    /// reached by the cursor, but the arrows still went to the file list). Only onto what can take the focus; never
    /// inside a page read in browse mode, where the reading position is the cursor.
    private func follow(_ e: AXUIElement) {
        guard config.general.cursorMovesFocus else { return }   // NVDA's review cursor leaves the keyboard where it is
        let controls: Set<String> = ["AXOutline", "AXTable", "AXList", "AXBrowser", "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
                                     "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXSlider", "AXLink", "AXTabGroup"]
        var target: AXUIElement?
        let role = e.role
        if controls.contains(role) { target = e }
        else if role == "AXRow" || role == "AXCell" {
            var p = e.element(kAXParentAttribute); var hops = 0
            while let x = p, hops < 4 { if ["AXOutline", "AXTable", "AXList", "AXBrowser"].contains(x.role) { target = x; break }; p = x.element(kAXParentAttribute); hops += 1 }
        }
        guard let t = target else { return }
        if let d = API.focusTreeInterceptor, !d.passThrough, isWithin(d.webArea) { return }
        if (t.attr(kAXFocusedAttribute) as? Bool) == true { return }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(t, kAXFocusedAttribute as CFString, &settable) == .success, settable.boolValue else {
            if ["AXOutline", "AXTable", "AXList"].contains(t.role) { hold(t) }
            return
        }
        followed = (t, Date())
        let r = t.set(kAXFocusedAttribute, kCFBooleanTrue)
        Log.io("review: the focus follows the cursor to \(t.role) → \(r.rawValue)")
    }

    var element: AXUIElement? {
        if let c = current, c.role != "?" { return c }
        return API.focusObject?.element
    }

    /// A list that will not take the keyboard (Finder's sidebar: AXFocused cannot be set, and a click on it leaves
    /// the keyboard in the file list; 7 Oct 2026). TurnOver holds it: while the cursor is in it, Up and Down move
    /// through its rows, Return and Space choose one (as selecting it with the mouse), Left and Right close and open.
    public private(set) var heldList: AXUIElement?
    private func hold(_ list: AXUIElement) {
        if let h = heldList, CFEqual(h, list) { return }
        heldList = list
        Log.io("review: holding \(list.role) \"\(Log.words(list.string(kAXDescriptionAttribute) ?? ""))\": it will not take the keyboard")
        Hints.schedule(String(localized: "Up and Down move through it; Return chooses.", comment: "Spoken message"))
    }

    /// Whether the arrows are the held list's: the cursor is still in it, and the keyboard has not moved since.
    public var isHolding: Bool {
        guard let h = heldList, let cur = current else { return false }
        if cur.role == "?" || h.role == "?" { heldList = nil; return false }
        return isWithin(h)
    }

    /// The rows: the list's own, or, for a list a plugin has TurnOver hold (Avalonia's grid has no rows attribute),
    /// its children.
    private var heldRows: [AXUIElement] {
        guard let h = heldList else { return [] }
        let rows = h.elements(kAXRowsAttribute)
        return rows.isEmpty ? h.elements(kAXChildrenAttribute) : rows
    }

    /// A plugin's hold rule: TurnOver holds this list and lands on its first row (parts request #4).
    public func holdForPlugin(_ list: AXUIElement) {
        heldList = list
        let rows = heldRows
        Log.io("review: holding \(list.role) for a plugin: \(rows.count) rows")
        guard let first = rows.first else { Speech.speakMessage(String(localized: "empty", comment: "Spoken message")); return }
        Speech.speakMessage(Phrases.items(rows.count))
        landRow(first, index: 0, count: rows.count)
        Hints.schedule(String(localized: "Up and Down move through it; Return chooses.", comment: "Spoken message"))
    }
    private var heldRowIndex: Int? {
        guard let cur = current else { return nil }
        var x: AXUIElement? = cur; var hops = 0
        while let y = x, hops < 4 { if let i = heldRows.firstIndex(where: { CFEqual($0, y) }) { return i }; x = y.element(kAXParentAttribute); hops += 1 }
        return nil
    }

    public func heldMove(_ delta: Int) {
        let rows = heldRows
        guard !rows.isEmpty else { return }
        let i = heldRowIndex.map { $0 + delta } ?? (delta > 0 ? 0 : rows.count - 1)
        guard rows.indices.contains(i) else { Tones.edge(); return }
        landRow(rows[i], index: i, count: rows.count)
    }

    public func heldEdge(last: Bool) {
        let rows = heldRows
        guard let r = last ? rows.last : rows.first else { return }
        landRow(r, index: last ? rows.count - 1 : 0, count: rows.count)
    }

    private func landRow(_ row: AXUIElement, index: Int, count: Int) {
        current = row; currentPid = row.pid; labelSource = nil
        var parts = Speech.objectPropertiesSpeech(ObjectFactory.make(row), reason: .query)
        // A row with no name of its own (a grid's cell holding a book's whole line): its texts, each its own phrase.
        if ObjectFactory.make(row).name.isEmpty { let t = ElementMatcher.text(of: row); if !t.isEmpty { parts.insert(t, at: 0) } }
        // Not when a position is said already: TurnOver's own ("3 of 9", in any language) or the app's own in its words.
        if !parts.contains(where: { Phrases.isPosition($0) || $0.contains(" of ") }) { parts.append(Phrases.position(index + 1, of: count)) }
        Speech.speakItem(parts.joined(separator: ", "))
    }

    /// Return or Space: choose the row, as clicking it would (Finder goes to that place).
    public func heldChoose() {
        guard let list = heldList, let i = heldRowIndex else { return }
        let rows = heldRows
        guard rows.indices.contains(i) else { Tones.edge(); return }
        let row = rows[i]
        let r = list.set(kAXSelectedRowsAttribute, [row] as CFArray)
        Log.io("review: held list, chose row \(i + 1) → \(r.rawValue)")
        if r == .success { Tones.press(); keepHoldUntil = Date().addingTimeInterval(2); return }
        // No rows to select (a plugin's held grid): the row pressed, or else its first button.
        if AXUIElementPerformAction(row, kAXPressAction as CFString) == .success { Tones.press(); keepHoldUntil = Date().addingTimeInterval(2); return }
        var queue = row.elements(kAXChildrenAttribute); var seen = 0
        while !queue.isEmpty, seen < 60 {
            let x = queue.removeFirst(); seen += 1
            var acts: CFArray?; AXUIElementCopyActionNames(x, &acts)
            if ((acts as? [String]) ?? []).contains(kAXPressAction as String), AXUIElementPerformAction(x, kAXPressAction as CFString) == .success {
                Log.io("review: held list, pressed row \(i + 1)'s \(x.role)"); Tones.press(); keepHoldUntil = Date().addingTimeInterval(2); return
            }
            queue += x.elements(kAXChildrenAttribute)
        }
        Speech.speakMessage(String(localized: "cannot choose it", comment: "Spoken message"))
    }

    /// Left and Right: close or open the row (a sidebar section).
    public func heldDisclose(open: Bool) {
        guard let i = heldRowIndex else { return }
        let rows = heldRows
        guard rows.indices.contains(i) else { Tones.edge(); return }
        let row = rows[i]
        guard let now = row.attr("AXDisclosing") as? Bool else { Tones.edge(); return }
        if now == open { Tones.edge(); return }
        _ = row.set("AXDisclosing", open as CFBoolean)
        Speech.speakMessage(open ? String(localized: "expanded", comment: "Spoken message") : String(localized: "collapsed", comment: "Spoken message"))
    }

    public func releaseHold() { heldList = nil }

    /// Into a list TurnOver holds, on its selected row (Finder: Tab from the files to the sidebar).
    public func enterHold(_ list: AXUIElement, name: String) {
        let rows = list.elements(kAXRowsAttribute)
        guard !rows.isEmpty else { return }
        let sel = list.elements(kAXSelectedRowsAttribute).first
        let i = sel.flatMap { s in rows.firstIndex { CFEqual($0, s) } } ?? 0
        heldList = list
        Speech.speakMessage(name)
        landRow(rows[i], index: i, count: rows.count)
    }

    /// Tab and Shift Tab out of a held list: where the app module says (Finder: the files, or the search field),
    /// else back to the keyboard focus. The app's own Tab would act on the focus, not here (it chose the next file).
    public var heldTab: ((_ forward: Bool) -> Bool)?
    public func leaveHold(forward: Bool) {
        heldList = nil
        if let h = heldTab, h(forward) { return }
        current = nil
        if let f = API.focusObject { Speech.speakObject(f, reason: .focus) }
    }

    // MARK: What counts as an item

    nonisolated static let layoutRoles: Set<String> = ["AXGroup", "AXSplitGroup", "AXScrollArea", "AXLayoutArea", "AXLayoutItem", "AXUnknown", "AXMatte", "AXGrowArea"]
    nonisolated static let skippedRoles: Set<String> = ["AXScrollBar", "AXSplitter", "AXValueIndicator", "AXRuler", "AXHelpTag"]

    /// An element worth stopping on in simple review: a control, text, a named container, a picture with a name.
    nonisolated static func isItem(_ e: AXUIElement) -> Bool {
        let role = e.role
        if skippedRoles.contains(role) || role == "AXWindow" || role == "AXApplication" || role == "?" { return false }
        let named = !(e.string(kAXTitleAttribute) ?? "").isEmpty || !(e.string(kAXDescriptionAttribute) ?? "").isEmpty
            || (ProfileStore.shared.label(for: e, pid: e.pid)?.0 != nil)
        // (Catalyst apps' texts have their words in the description: WhatsApp's sidebar, 7 Oct 2026.)
        if role == "AXStaticText" { return !((e.string(kAXValueAttribute) ?? "") + (e.string(kAXDescriptionAttribute) ?? "")).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // A cell or row with no words at all (a section's spacer) is not a stop: it said only "cell".
        if role == "AXCell" || role == "AXRow", !named, !hasWords(e) { return false }
        // A table's column with no title is its structure, not a stop: it said only "column" between Ulysses' panes
        // (Day 2, 10 Oct 2026). The cells are reached through the rows.
        if role == "AXColumn", !named { return false }
        // Action reads share health accounting and a worker's read scope, including nested searches (28 Oct 2026).
        if role == "AXImage" {
            return named || ((e.actionNamesResult().value as? [String]) ?? []).contains("AXPress")
        }
        if layoutRoles.contains(role) {
            // A container is an item only when it is a control in disguise (pressable) or has a name; otherwise
            // review goes straight into it.
            if ProfileStore.shared.isSilenced(e, pid: e.pid) { return false }
            let acts = (e.actionNamesResult().value as? [String]) ?? []
            return named && e.elements(kAXChildrenAttribute).isEmpty || acts.contains("AXPress") && e.elements(kAXChildrenAttribute).isEmpty
        }
        if ProfileStore.shared.isSilenced(e, pid: e.pid) { return false }
        return true
    }

    /// Whether review goes inside an element: not into skipped parts, nor into controls (a button's text is the button).
    /// The row before or after a row of a table or outline, fetched alone by its index: fetching every row to find
    /// the next took 120 ms a step in Contacts' 610 (10 Oct 2026). nil: not a row, or past the ends (then the
    /// children are walked as before).
    nonisolated static func neighbourRow(of e: AXUIElement, in parent: AXUIElement, offset: Int) -> AXUIElement? {
        // Former raw count/slice calls now share cancellation, budgets and health accounting with attribute reads.
        guard e.role == "AXRow", ["AXOutline", "AXTable"].contains(parent.role),
              let i = (e.attr("AXIndex") as? NSNumber)?.intValue else { return nil }
        guard let count = parent.attributeValueCountResult(kAXRowsAttribute).value else { return nil }
        let j = i + offset
        guard j >= 0, j < count else { return nil }
        guard let row = (parent.attributeValuesResult(kAXRowsAttribute, index: j, maxValues: 1).value as? [AXUIElement])?.first else { return nil }
        return row
    }

    /// Whether an element or anything just inside it has words (a value, title or description): a quick look,
    /// twelve elements at most, batched. (System Settings' sidebar rows hold a button, not a text.)
    nonisolated static func hasWords(_ e: AXUIElement) -> Bool {
        let names = [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXChildrenAttribute]
        var queue = [e], n = 0
        while !queue.isEmpty, n < 12 {
            let x = queue.removeFirst(); n += 1
            let a = x.attrs(names)
            for k in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                if let t = a[k] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
            }
            queue.append(contentsOf: (a[kAXChildrenAttribute] as? [AXUIElement]) ?? [])
        }
        return false
    }

    nonisolated static func descends(_ e: AXUIElement) -> Bool {
        let role = e.role
        if skippedRoles.contains(role) { return false }
        if ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXTextField", "AXTextArea", "AXComboBox",
            "AXSlider", "AXIncrementor", "AXLink", "AXStaticText", "AXImage", "AXMenuItem", "AXDisclosureTriangle"].contains(role) { return false }
        // A row that says something is one stop, as in VoiceOver and NVDA: its cell and the texts inside it are what
        // it already said. Going in read each again ("Today, cell", "Today", "0"), the duplicates a tester heard in the
        // Windows style and Contacts' 609 rows each read three times (10 Oct 2026). Interact (VO Shift Down, or the
        // first-child key) still goes in, to a row's buttons.
        // (A quick look for any text in it, not its whole name: working the name out here as well as when the row is
        // read doubled the time per step on Contacts' rows.)
        if role == "AXRow", Self.hasWords(e) { return false }
        // A heading of plain text is one stop: "Fixes, heading, 2" and then "Fixes" again (Bambu Studio's release
        // notes, Day 4, 11 Oct 2026). A heading holding a link is still gone into.
        if role == "AXHeading", e.elements(kAXChildrenAttribute).allSatisfy({ $0.role == "AXStaticText" }) { return false }
        return true
    }

    // MARK: Moving

    /// The window that bounds review: the navigator's own. An item that does not name its window is in the one its
    /// parents lead to: in System Settings' panes on macOS 27, 40 of a window's 169 elements give no AXWindow, the focused
    /// button among them, and review said "nothing to review" at every step (29 Oct 2026).
    private func window(of e: AXUIElement) -> AXUIElement? {
        if e.role == "AXWindow" { return e }
        if let w = e.element(kAXWindowAttribute) { return w }
        var p = e.element(kAXParentAttribute); var hops = 0
        while let x = p, hops < 60 {
            if x.role == "AXWindow" { return x }
            p = x.element(kAXParentAttribute); hops += 1
        }
        return nil
    }

    /// The next element in reading order (depth first) inside `root`, after `e`.
    private func nextInOrder(after e: AXUIElement, root: AXUIElement, enter: Bool) -> AXUIElement? {
        if enter, Self.descends(e), let first = e.elements(kAXChildrenAttribute).first { return first }
        var node = e
        var guardCount = 0
        while !node.isSame(root), guardCount < 200 {
            guardCount += 1
            guard let parent = node.element(kAXParentAttribute) else { return nil }
            if let row = Self.neighbourRow(of: node, in: parent, offset: 1) { return row }
            let kids = parent.elements(kAXChildrenAttribute)
            if let i = kids.firstIndex(where: { $0.isSame(node) }), i + 1 < kids.count { return kids[i + 1] }
            node = parent
        }
        return nil
    }

    /// The previous element in reading order: the previous sibling's deepest last descendant, or the parent.
    private func previousInOrder(before e: AXUIElement, root: AXUIElement) -> AXUIElement? {
        guard !e.isSame(root), let parent = e.element(kAXParentAttribute) else { return nil }
        var node: AXUIElement
        if let row = Self.neighbourRow(of: e, in: parent, offset: -1) { node = row } else {
            let kids = parent.elements(kAXChildrenAttribute)
            guard let i = kids.firstIndex(where: { $0.isSame(e) }), i > 0 else { return parent.isSame(root) ? nil : parent }
            node = kids[i - 1]
        }
        var guardCount = 0
        while Self.descends(node), let last = node.elements(kAXChildrenAttribute).last, guardCount < 60 { node = last; guardCount += 1 }
        return node
    }

    public func next() { step(forward: true) }
    public func previous() { step(forward: false) }

    /// The cursor came to rest on this item by a step (VO-Left, Right, Up, Down), not by the focus or by interacting:
    /// on a text area that means the item, not its text, so the next step goes on to the next item, as VoiceOver's
    /// does until you interact (Word: VO-Left from the status bar landed on the document and the next VO-Left went
    /// into its characters, 17 Oct 2026).
    public private(set) var landedByStep = false

    private func step(forward: Bool) {
        guard let start = element, let root = window(of: start) else { Speech.speakMessage(String(localized: "nothing to review", comment: "Spoken message")); return }
        var node: AXUIElement? = start.isSame(root) ? (forward ? root.elements(kAXChildrenAttribute).first : nil) : start
        var first = !start.isSame(root)
        var visited = 0
        while let n = node, visited < 3000 {
            visited += 1
            if first {
                first = false
                node = forward ? nextInOrder(after: n, root: root, enter: true) : previousInOrder(before: n, root: root)
                continue
            }
            if Self.isItem(n), !(labelSource.map { $0.isSame(n) } ?? false) { land(on: n); landedByStep = true; return }
            node = forward ? nextInOrder(after: n, root: root, enter: true) : previousInOrder(before: n, root: root)
        }
        Tones.edge()
        if !VoiceOverSounds.play("WrapBoundary.aiff") { } ; Speech.speakMessage(forward ? String(localized: "bottom", comment: "Spoken message") : String(localized: "top", comment: "Spoken message"))
    }

    public func parent() {
        guard let e = element, e.role != "AXWindow" else { Tones.edge(); return }
        var p = e.element(kAXParentAttribute)
        // Skip layout no one would name, as next and previous do.
        while let x = p, x.role != "AXWindow", !Self.isItem(x), Self.layoutRoles.contains(x.role), (x.string(kAXDescriptionAttribute) ?? x.string(kAXTitleAttribute) ?? "").isEmpty {
            p = x.element(kAXParentAttribute)
        }
        guard let target = p else { Tones.edge(); return }
        land(on: target)
    }

    public func firstChild() {
        guard let e = element else { return }
        var node = e.elements(kAXChildrenAttribute).first
        var visited = 0
        while let n = node, visited < 500 {
            visited += 1
            if Self.isItem(n) { land(on: n); return }
            node = (Self.descends(n) ? n.elements(kAXChildrenAttribute).first : nil) ?? nextInOrder(after: n, root: e, enter: false)
        }
        Tones.edge()
        Speech.speakMessage(String(localized: "no items inside", comment: "Spoken message"))
    }

    // MARK: VoiceOver's way: groups (the Mac style)

    /// Containers VoiceOver treats as groups to go into: they are one item where they sit.
    static let groupRoles: Set<String> = ["AXToolbar", "AXList", "AXTable", "AXOutline", "AXBrowser", "AXTabGroup", "AXRadioGroup", "AXWebArea", "AXGrid"]

    /// A group: one of those, or a named container holding two or more items. An unnamed container is only layout:
    /// its items sit at the level above (so a window is not a nest of empty groups to dig through).
    public static func isGroup(_ e: AXUIElement) -> Bool {
        let role = e.role
        guard groupRoles.contains(role) || layoutRoles.contains(role) else { return false }
        // Segments are flattened by groupItems. Their parent must also be skipped on the way back up, or
        // VO-Right enters the segments without interaction and cannot leave them (Settings, macOS 27, 23 Oct 2026).
        // Ask the count first: checking a table must not fetch thousands of children just to rule out segments.
        var count: CFIndex = 0
        if AXUIElementGetAttributeValueCount(e, kAXChildrenAttribute as CFString, &count) == .success,
           (1...6).contains(count), areSegments(e.elements(kAXChildrenAttribute)) { return false }
        if groupRoles.contains(role) { return true }
        let named = !(e.string(kAXTitleAttribute) ?? "").isEmpty || !(e.string(kAXDescriptionAttribute) ?? "").isEmpty
        return named && e.elements(kAXChildrenAttribute).count >= 2
    }

    private static func areSegments(_ children: [AXUIElement]) -> Bool {
        !children.isEmpty && children.count <= 6 && children.allSatisfy { $0.string(kAXSubroleAttribute) == "AXSegment" }
    }

    /// What VoiceOver's cursor steps through inside a container, in screen order: items, and groups as single items;
    /// layout in between is looked through.
    public static func groupItems(_ container: AXUIElement) -> [AXUIElement] {
        // The last answer, reused while the VO cursor steps along the same container (each walk reads a frame for
        // every element: ~20k questions a key on Music's grid, 8 Oct 2026). Let go after a moment, or when the
        // focus or the window changes (`forgetGroupItems`).
        if let c = groupCache, c.container.isSame(container), Date().timeIntervalSince(c.at) < groupCacheSeconds { return c.items }
        let items = walkGroupItems(container)
        groupCache = (container, items, Date())
        return items
    }
    private static var groupCache: (container: AXUIElement, items: [AXUIElement], at: Date)?
    static var groupCacheSeconds: TimeInterval = 1.5
    /// The focus or the window moved: the next step walks afresh (called from the event handler).
    public static func forgetGroupItems() { groupCache = nil }

    private static func walkGroupItems(_ container: AXUIElement) -> [AXUIElement] {
        // A table or outline: its rows, as the app orders them, in one call. Walked and sorted by position, Mail's
        // list of 6,500 messages took seconds a key, until the watchdog handed over to VoiceOver (a tester, build 14,
        // 7 Oct 2026).
        if ["AXTable", "AXOutline"].contains(container.role) {
            let rows = container.elements(kAXRowsAttribute)
            if !rows.isEmpty { return rows }
        }
        var out: [AXUIElement] = []
        var columnOf: [CGRect?] = []
        var visited = 0
        let win = TurnOverObject.frame(container.role == "AXWindow" ? container : (container.element(kAXWindowAttribute) ?? container))
        // A column: unnamed layout that runs most of the window's height but not its width (WhatsApp's sidebar, chats
        // and chat, 7 Oct 2026). What is in one column is read before the next, as VoiceOver does, not row by row
        // across them.
        func isColumn(_ e: AXUIElement) -> CGRect? {
            guard let w = win, let f = TurnOverObject.frame(e) else { return nil }
            return f.height > 0.5 * w.height && f.width < 0.75 * w.width ? f : nil
        }
        func collect(_ e: AXUIElement, _ depth: Int, _ column: CGRect?) {
            for c in e.elements(kAXChildrenAttribute) {
                visited += 1
                guard visited < 2500, depth < 25 else { return }
                let role = c.role
                if skippedRoles.contains(role) || role == "?" { continue }
                // A segmented control (Finder's Back/Forward, its four views): its segments are the items, as on
                // screen, rather than a group of two to go into ("unknown, 4 items").
                let kids = c.elements(kAXChildrenAttribute)
                // A nameless heading holding the named one (WhatsApp's "Favourites"): the inner one is the item.
                if role == "AXHeading", kids.count == 1, kids[0].role == role, (c.string(kAXDescriptionAttribute) ?? "").isEmpty, (c.string(kAXTitleAttribute) ?? "").isEmpty {
                    out.append(kids[0]); columnOf.append(column); continue
                }
                if areSegments(kids) {
                    out.append(contentsOf: kids); columnOf.append(contentsOf: kids.map { _ in column }); continue
                }
                if isGroup(c) { out.append(c); columnOf.append(column); continue }
                if !descends(c) || c.elements(kAXChildrenAttribute).isEmpty { if isItem(c) { out.append(c); columnOf.append(column) }; continue }
                if isItem(c), !layoutRoles.contains(role) { out.append(c); columnOf.append(column); continue }
                collect(c, depth + 1, column ?? (layoutRoles.contains(role) ? isColumn(c) : nil))
            }
        }
        collect(container, 0, nil)
        // Screen order: rows top to bottom (things level with each other are one row), then left to right. A toolbar
        // comes before the content under it (Safari lists its toolbar after the page).
        // The part of each that shows in the window: a long list reports its whole scrolled height (Mail's
        // messages: 39,306 points), which put it after everything level with it.
        let frames = out.map { e -> CGRect? in
            guard let f = TurnOverObject.frame(e) else { return nil }
            guard let w = win else { return f }
            let c = f.intersection(w)
            return c.isNull || c.isEmpty ? f : c
        }
        // What isn't in a column but sits within one (the window's buttons over WhatsApp's sidebar, its Edit button
        // under it) belongs to it.
        let columns = columnOf.compactMap { $0 }.reduce(into: [CGRect]()) { if !$0.contains($1) { $0.append($1) } }
        if !columns.isEmpty {
            for i in out.indices where columnOf[i] == nil {
                guard let f = frames[i] else { continue }
                columnOf[i] = columns.first { $0.minX <= f.midX && f.midX <= $0.maxX && $0.minY - 4 <= f.midY && f.midY <= $0.maxY }
            }
        }
        func before(_ fa: CGRect?, _ fb: CGRect?, _ a: Int, _ b: Int) -> Bool {
            guard let fa, let fb else { return a < b }
            let overlap = min(fa.maxY, fb.maxY) - max(fa.minY, fb.minY)
            // One row: level with each other and of a like height (a tall page area beside a toolbar is not a row).
            let alike = max(fa.height, fb.height) < 3 * max(1, min(fa.height, fb.height))
            if alike, overlap > 0.5 * min(fa.height, fb.height) { return fa.minX < fb.minX || (fa.minX == fb.minX && a < b) }
            if abs(fa.minY - fb.minY) < 2 { return fa.height < fb.height }   // starting level: the shorter (a toolbar) first
            return fa.minY < fb.minY
        }
        // Each column is one block, placed among the other items by its frame; two columns go in the app's own order
        // (WhatsApp's chats column starts under its sidebar, so where they are can't say). Inside a block, screen order.
        struct Block { var frame: CGRect?; var column: Int?; var members: [Int] }
        var blocks = columns.indices.map { c in Block(frame: columns[c], column: c, members: out.indices.filter { columnOf[$0] == columns[c] }) }
        blocks += out.indices.filter { columnOf[$0] == nil }.map { Block(frame: frames[$0], column: nil, members: [$0]) }
        blocks.removeAll { $0.members.isEmpty }
        // The window's own buttons first, as VoiceOver has them (Finder's sidebar and list start under its toolbar, at
        // the top of the window, which put close, minimise and full screen after them).
        let windowButtons: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXFullScreenButton", "AXZoomButton"]
        let isWindowButton = { (b: Block) in b.column == nil && windowButtons.contains(out[b.members[0]].string(kAXSubroleAttribute) ?? "") }
        blocks.sort { x, y in
            if isWindowButton(x) != isWindowButton(y) { return isWindowButton(x) }
            if let cx = x.column, let cy = y.column { return cx < cy }
            return before(x.frame, y.frame, x.members[0], y.members[0])
        }
        let order = blocks.flatMap { $0.members.sorted { before(frames[$0], frames[$1], $0, $1) } }
        return order.map { out[$0] }
    }

    /// The group an element is in: its nearest container that is a group, or the window.
    private func groupContainer(of e: AXUIElement) -> AXUIElement? {
        var p = e.element(kAXParentAttribute); var hops = 0
        while let x = p, hops < 60 {
            // A sheet is its own group: VO Right from a sheet's button climbed to the window and bumped at the
            // window's edge, so Terminal's "terminate running processes?" couldn't be read by VO arrows (// 15 Oct 2026); VoiceOver keeps its cursor inside the sheet.
            if x.role == "AXWindow" || x.role == "AXSheet" || Self.isGroup(x) { return x }
            p = x.element(kAXParentAttribute); hops += 1
        }
        return window(of: e)
    }

    /// Which of the container's items holds the element (it, or one of its ancestors).
    private func indexIn(_ items: [AXUIElement], of e: AXUIElement) -> Int? {
        var x: AXUIElement? = e; var hops = 0
        while let y = x, hops < 40 {
            if let i = items.firstIndex(where: { $0.isSame(y) }) { return i }
            x = y.element(kAXParentAttribute); hops += 1
        }
        return nil
    }

    /// VO Right and VO Left: the next or previous item in this group; at its end, a bump, as VoiceOver.
    public func groupStep(forward: Bool) {
        guard let cur = element, let container = cur.role == "AXWindow" || cur.role == "AXSheet" ? cur : groupContainer(of: cur) else { Speech.speakMessage(String(localized: "nothing to review", comment: "Spoken message")); return }
        let items = Self.groupItems(container)
        guard !items.isEmpty else { Tones.edge(); Log.io("review: edge (an empty group)"); return }
        let j: Int
        if cur.isSame(container) { j = forward ? 0 : items.count - 1 }
        else if let i = indexIn(items, of: cur) { j = i + (forward ? 1 : -1) }
        else { j = forward ? 0 : items.count - 1 }
        guard items.indices.contains(j) else { Tones.edge(); Log.io("review: edge of the group"); return }
        land(on: items[j])
    }

    /// VO Shift Down: into a group, on its first item.
    public func interact() {
        guard let cur = element else { return }
        // A text area reached by a step: VO-Shift-Down goes into its text (the caret keys work from here).
        if landedByStep, ObjectFactory.make(cur).hasNavigableText {
            landedByStep = false
            follow(cur)   // the keyboard focus goes in with the interaction, as VoiceOver's does
            Speech.speakMessage(String(localized: "in \(Speech.objectPropertiesSpeech(ObjectFactory.make(cur), reason: .query).first ?? String(localized: "the text", comment: "Going into a text with no name"))", comment: "Going into an item: %@ is the item"))
            return
        }
        guard Self.isGroup(cur) || cur.role == "AXWindow" else { firstChild(); return }
        let items = Self.groupItems(cur)
        guard let first = items.first else { Tones.edge(); Speech.speakMessage(String(localized: "no items inside", comment: "Spoken message")); return }
        if !VoiceOverSounds.play("DrillIn.aiff") { Tones.beep(660, 30) }
        land(on: first)
    }

    /// VO Shift Up: out to the group holding this one.
    public func stopInteracting() {
        guard let cur = element, cur.role != "AXWindow", let container = groupContainer(of: cur) else { Tones.edge(); return }
        // The window itself is the top level: the cursor rests on it, so VO-Left and Right then move among the window's
        // own items (the toolbar, the sidebar, the document) instead of staying in the text (Word, 17 Oct 2026).
        if container.role == "AXWindow" { current = container; currentPid = container.pid; VoiceOverSounds.play("DrillOut.aiff"); Speech.speakMessage(String(localized: "top level", comment: "Spoken message")); return }
        if !VoiceOverSounds.play("DrillOut.aiff") { Tones.beep(440, 30) }
        land(on: container)
    }

    // MARK: More of VoiceOver's moves (7 Oct 2026: "it needs to have all the keyboard controls in there")

    /// What an item says, as the cursor would.
    static func words(_ e: AXUIElement) -> String {
        if e.role == "AXStaticText", let v = e.string(kAXValueAttribute), !v.isEmpty { return v }
        return Speech.objectPropertiesSpeech(ObjectFactory.make(e), reason: .query).joined(separator: ", ")
    }

    /// VO-Home and VO-End (and VO-Shift-Home, VO-Shift-End): the first or last item of this group.
    public func groupEdge(last: Bool) {
        guard let cur = element, let container = cur.role == "AXWindow" ? cur : groupContainer(of: cur) else { Tones.edge(); return }
        let items = Self.groupItems(container)
        guard let target = last ? items.last : items.first else { Tones.edge(); return }
        land(on: target)
    }

    /// VO-Command-Home and VO-Command-End: the first or last item of the window.
    public func windowEdge(last: Bool) {
        guard let cur = element, let w = window(of: cur) else { Tones.edge(); return }
        let items = Self.groupItems(w)
        guard let target = last ? items.last : items.first else { Tones.edge(); return }
        land(on: target)
    }

    /// The next or previous element of a kind in the window, in reading order, from the cursor (VO-Command-H and
    /// friends outside a document).
    public func findInWindow(roles: Set<String>, forward: Bool, kind: String) {
        // Take references only: even resolving the cursor's window can wait on the target application. The worker
        // retains reading-order and row-neighbour rules, with a cooperative deadline instead of thousands of main
        // thread queries. A call already in flight is not preemptible, but never blocks key resolution (28 Oct 2026).
        let cursor = current
        let focus = API.focusObject?.element
        let foreground = API.foregroundObject?.element
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard cursor != nil || focus != nil else { Speech.speakMessage(String(localized: "nothing to search", comment: "Spoken message")); return }
        let queries = WindowKindQueries<AXUIElement, ElementKey>(
            identity: { ElementKey($0) },
            window: { $0.role == "AXWindow" ? $0 : $0.element(kAXWindowAttribute) },
            children: { $0.elements(kAXChildrenAttribute) },
            parent: { $0.element(kAXParentAttribute) },
            descends: { Self.descends($0) },
            matches: { roles.contains($0.role) && (Self.isItem($0) || $0.role == "AXHeading") },
            neighbourRow: { Self.neighbourRow(of: $0, in: $1, offset: $2) }
        )
        windowSearch.submit { request in
            let budget = AXWalkBudget(request: request)
            let resolvedStart: AXUIElement
            switch WindowSearchPreflight.resolve(cursor: cursor, focus: focus, budget: budget, role: { element in
                let result = element.attributeResult(kAXRoleAttribute)
                return AXQueryResult(value: result.value as? String, status: result.status,
                                     elapsedNanoseconds: result.elapsedNanoseconds, wasAttempted: result.wasAttempted)
            }) {
            case .ready(let element): resolvedStart = element
            case .unavailable: return .unavailable
            case .incomplete(let reason): return .incomplete(reason)
            }
            return AXReadScope.with(while: { budget.check() }, onQuery: { budget.admitAXQuery() }, onResult: { budget.record($0) }) {
                var search = WindowKindSearch(queries: queries, budget: budget)
                let result = search.find(from: resolvedStart, forward: forward)
                // A malformed cross-process child must never become the action target for this window's request.
                if case .found(let target) = result, target.pid != resolvedStart.pid { return .unavailable }
                return result
            }
        } publish: { [weak self] result in
            guard let self, Core.active,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost,
                  Self.sameSnapshot(self.current, cursor), Self.sameSnapshot(API.focusObject?.element, focus),
                  Self.sameSnapshot(API.foregroundObject?.element, foreground) else { return }
            switch result {
            case .found(let target):
                self.land(on: target)
            case .end:
                Tones.edge()
                Speech.speakMessage(forward ? String(localized: "no next \(kind)", comment: "Nothing more of a kind ahead: %@ is the kind (heading)") : String(localized: "no previous \(kind)", comment: "Nothing more of a kind behind: %@ is the kind (heading)"))
            case .unavailable:
                Speech.speakMessage(String(localized: "nothing to search", comment: "Spoken message"))
            case .incomplete(.cancelled): break
            case .incomplete(let reason):
                Log.io("review: window \(kind) search incomplete (\(reason.rawValue))")
                Speech.speakMessage(String(localized: "Search stopped before finishing. Try again.", comment: "Spoken message"))
            }
        }
    }

    /// Keys, cursor/focus movement and reader deactivation retire both queued work and held completion callbacks.
    public func cancelWindowSearch() { windowSearch.cancel() }

    private static func sameSnapshot(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let a?, let b?): return a.isSame(b)
        default: return false
        }
    }

    /// VO-Shift-Escape: out to the top level of the window, on its first item.
    public func topLevel() {
        guard let cur = element, let w = window(of: cur), let first = Self.groupItems(w).first else { Tones.edge(); return }
        Tones.beep(440, 30)
        land(on: first)
    }

    /// VO-Up and VO-Down outside text: the item above or below in this group (a grid of icons, a toolbar over a
    /// list), the nearest by how far across it is.
    public func verticalStep(down: Bool) {
        guard let cur = element, let container = cur.role == "AXWindow" ? cur : groupContainer(of: cur),
              let f = TurnOverObject.frame(cur) else { Tones.edge(); return }
        // A row of a table or outline: the row below or above, by its place (not the frames of thousands of rows).
        if ["AXTable", "AXOutline"].contains(container.role) {
            let rows = Self.groupItems(container)
            if let i = indexIn(rows, of: cur) {
                let j = i + (down ? 1 : -1)
                guard rows.indices.contains(j) else { Tones.edge(); return }
                land(on: rows[j]); return
            }
        }
        let items = Self.groupItems(container).filter { !$0.isSame(cur) }
        let candidates = items.compactMap { e -> (AXUIElement, CGFloat)? in
            guard let g = TurnOverObject.frame(e) else { return nil }
            let below = g.minY >= f.maxY - 2, above = g.maxY <= f.minY + 2
            guard down ? below : above else { return nil }
            let dy = down ? g.minY - f.maxY : f.minY - g.maxY
            let dx = abs(g.midX - f.midX)
            return (e, dy * 4 + dx)
        }
        guard let best = candidates.min(by: { $0.1 < $1.1 })?.0 else { Tones.edge(); return }
        land(on: best)
    }

    /// VO-J: the linked item (Mail's message list to the message), from the item's AXLinkedUIElements.
    public func jumpLinked() {
        guard let cur = element else { return }
        var x: AXUIElement? = cur; var hops = 0
        while let y = x, hops < 4 {
            if let linked = y.elements("AXLinkedUIElements").first { Tones.beep(660, 30); land(on: linked); return }
            x = y.element(kAXParentAttribute); hops += 1
        }
        Speech.speakMessage(String(localized: "no linked item", comment: "Spoken message"))
    }

    /// VO-Return: select the item: a row in its list, or a menu item.
    public func selectItem() {
        guard let cur = element else { return }
        if cur.role == "AXRow", let list = cur.element(kAXParentAttribute) {
            let r = list.set(kAXSelectedRowsAttribute, [cur] as CFArray)
            Log.io("review: select row → \(r.rawValue)")
            if r == .success { Speech.speakMessage(String(localized: "selected", comment: "Spoken message")) } else { activate() }
            return
        }
        activate()
    }

    /// VO-Backslash: open or close the disclosure triangle (a row's, or the one in the item).
    public func toggleDisclosure() {
        guard let cur = element else { return }
        if let open = cur.attr("AXDisclosing") as? Bool {
            let r = cur.set("AXDisclosing", (!open) as CFBoolean)
            Speech.speakMessage(r == .success ? (open ? State.collapsed.displayString : State.expanded.displayString) : String(localized: "cannot open or close it", comment: "Spoken message"))
            return
        }
        if let tri = cur.role == "AXDisclosureTriangle" ? cur : Self.firstDescendant(of: cur, role: "AXDisclosureTriangle") {
            _ = AXUIElementPerformAction(tri, kAXPressAction as CFString)
            return
        }
        Speech.speakMessage(String(localized: "no disclosure triangle", comment: "Spoken message"))
    }

    static func firstDescendant(of e: AXUIElement, role: String, depth: Int = 3) -> AXUIElement? {
        for c in e.elements(kAXChildrenAttribute) {
            if c.role == role { return c }
            if depth > 1, let f = firstDescendant(of: c, role: role, depth: depth - 1) { return f }
        }
        return nil
    }

    /// VO-Shift-Space: a mouse click on the item (twice: a double click), where the item really is, the pointer put
    /// back after.
    public func click(double: Bool) {
        guard let cur = element, let f = TurnOverObject.frame(cur), f.width > 1, f.height > 1 else { Speech.speakMessage(String(localized: "nothing to click", comment: "Spoken message")); return }
        let p = CGPoint(x: f.midX, y: f.midY)
        var hit: AXUIElement?
        if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &hit) == .success, let h = hit {
            var x: AXUIElement? = h; var hops = 0; var inside = false
            while let y = x, hops < 8 { if CFEqual(y, cur) { inside = true; break }; x = y.element(kAXParentAttribute); hops += 1 }
            if !inside { Speech.speakMessage(String(localized: "something else is over it; not clicked", comment: "Spoken message")); return }
        }
        let back = CGEvent(source: nil)?.location
        Mouse.click(at: p, button: .left, count: double ? 2 : 1)
        if let b = back { Mouse.move(to: b) }
        Tones.press()
    }

    /// VO-Shift-H: the item's help tag.
    public func readHelp() {
        guard let cur = element else { return }
        let h = (cur.string(kAXHelpAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        Speech.speakMessage(h.isEmpty ? String(localized: "no help tag", comment: "An item with no help tag") : h)
    }

    /// VO-Shift-U: a link's address.
    public func readURL() {
        guard let cur = element else { return }
        var x: AXUIElement? = cur; var hops = 0
        while let y = x, hops < 4 {
            if let u = y.attr(kAXURLAttribute) { Speech.speakPrivate((u as? URL)?.absoluteString ?? "\(u)"); return }
            x = y.element(kAXParentAttribute); hops += 1
        }
        Speech.speakMessage(String(localized: "not a link", comment: "Spoken message"))
    }

    /// VO-Shift-W: everything in the window, read through without moving.
    public func readWindow() {
        guard let cur = element, let w = window(of: cur) else { return }
        let parts = Self.groupItems(w).prefix(80).map { Self.words($0) }.filter { !$0.isEmpty }
        Speech.speakText(([w.string(kAXTitleAttribute) ?? ""] + parts).filter { !$0.isEmpty }.joined(separator: ". "))
    }

    /// VO-Command-Space: the item's actions, to choose from.
    public func actionsMenu() {
        guard let cur = element else { return }
        var names: CFArray?
        AXUIElementCopyActionNames(cur, &names)
        let acts = ((names as? [String]) ?? []).filter { !$0.hasPrefix("AXScroll") && $0 != "AXShowDefaultUI" && $0 != "AXShowAlternateUI" }
        guard !acts.isEmpty else { Speech.speakMessage(String(localized: "no actions", comment: "Spoken message")); return }
        let items = acts.map { a -> MenuItem in
            var desc: CFString?
            AXUIElementCopyActionDescription(cur, a as CFString, &desc)
            let custom = a.components(separatedBy: "\n").first { $0.hasPrefix("Name:") }.map { String($0.dropFirst(5)) }
            let title = custom ?? ((desc as String?).flatMap { $0.isEmpty ? nil : $0 } ?? a.replacingOccurrences(of: "AX", with: ""))
            return MenuItem(verbatim: title, .action { _ = AXUIElementPerformAction(cur, a as CFString) })
        }
        TurnOverMenu.shared.openList("Actions", items: items)
    }

    /// The window the cursor is in, for the window chooser (VO-F2-F2).
    public var cursorWindow: AXUIElement? { element.flatMap { window(of: $0) } }

    /// The text a plugin label took the item's name from: stepping onto it would say the name twice.
    private var labelSource: AXUIElement?

    /// Puts the review cursor on an element and reads it (VoiceOver's moves to a place: the desktop, a scroll bar).
    public func moveTo(_ e: AXUIElement) { land(on: e) }

    /// Puts the review cursor on an element without a word: what already said it (a dialog's Tab) keeps the two
    /// cursors together, so VO-Space presses what Tab reached.
    public func place(_ e: AXUIElement) {
        current = e
        currentPid = e.pid
    }

    private func land(on e: AXUIElement) {
        landedByStep = false
        current = e
        currentPid = e.pid
        labelSource = ProfileStore.shared.labelDetail(for: e, pid: e.pid)?.source
        report(e)
        follow(e)
    }

    /// For tests: what each property of the navigator object says.
    public func debugCurrent() -> String {
        guard let e = element else { return "none" }
        let o = ObjectFactory.make(e)
        return "role \(e.role) name=\(o.name.prefix(40)) value=\(o.value?.prefix(40) ?? "nil") description=\(o.description?.prefix(40) ?? "nil") roleText=\(o.roleText ?? "nil") shortcut=\(o.keyboardShortcut ?? "nil") class=\(type(of: o))"
    }

    public func reportCurrent() {
        guard let e = element else { Speech.speakMessage(String(localized: "nothing to review", comment: "Spoken message")); return }
        report(e)
    }

    private func report(_ e: AXUIElement) {
        let obj = ObjectFactory.make(e)
        // (A text with its words only in its description, as Catalyst apps have, is said as other items are.)
        if e.role == "AXStaticText", let v = e.string(kAXValueAttribute), !v.isEmpty {
            Speech.speakItem(v, processed: true)
            return
        }
        var parts = Speech.objectPropertiesSpeech(obj, reason: .query)
        // A group, the VoiceOver way: what it holds ("tool bar, 6 items"), and how to go in.
        if config.general.movesByGroups, Self.isGroup(e), !["AXTable", "AXOutline", "AXList", "AXWebArea"].contains(e.role) {
            let n = Self.groupItems(e).count
            parts.append(Phrases.items(n))
            Speech.speakItem(parts.joined(separator: ", "))
            Hints.schedule(String(localized: "VO Shift Down goes in.", comment: "Spoken message"))
            return
        }
        // (Not a value that only repeats the name: the App Store's headings carry their title as both, "Discover, heading, Discover".)
        if obj.hasNavigableText, let v = e.string(kAXValueAttribute), !v.isEmpty, e.string(kAXSubroleAttribute) != "AXSecureTextField",
           !parts.contains(where: { $0.trimmingCharacters(in: .whitespaces) == v.trimmingCharacters(in: .whitespaces) }) { parts.append(v) }
        if parts.isEmpty { parts = [obj.role.displayString] }
        if parts.joined().trimmingCharacters(in: .whitespaces).isEmpty { Log.io("review: nothing to say for \(e.role) \(e.string(kAXSubroleAttribute) ?? "")") }
        Speech.speakItem(parts.joined(separator: ", "))
    }

    /// Activate the navigator object: press it, or put the keyboard focus in it when it is for typing.
    public func activate() {
        guard let e = element else { return }
        let role = e.role
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) { moveFocusHere(); return }
        var acts: CFArray?
        AXUIElementCopyActionNames(e, &acts)
        let actions = (acts as? [String]) ?? []
        if actions.contains("AXPress") {
            let r = AXUIElementPerformAction(e, kAXPressAction as CFString)
            if r == .success { Tones.press() }
            Log.io("review: press \(role) → \(r.rawValue)")
            SystemPrompts.checkPress(of: e, name: ObjectFactory.make(e).name)
            // Something that opens and closes by its own actions (WhatsApp's "More" heading has Expand or Collapse,
            // 7 Oct 2026): say which it is now.
            let folds = { (a: [String]) -> String? in
                if a.contains(where: { $0.hasSuffix("Collapse") }) { return State.expanded.displayString }
                if a.contains(where: { $0.hasSuffix("Expand") }) { return State.collapsed.displayString }
                return nil
            }
            if let before = folds(actions) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    var now: CFArray?
                    AXUIElementCopyActionNames(e, &now)
                    if let after = folds((now as? [String]) ?? []), after != before { Speech.speakMessage(after) }
                }
            }
            // A toggle or a value: say what it is now.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, let cur = self.element, cur.isSame(e), ["AXCheckBox", "AXRadioButton"].contains(role) else { return }
                self.report(cur)
            }
        } else if actions.contains("AXConfirm") {
            _ = AXUIElementPerformAction(e, kAXConfirmAction as CFString)
        } else {
            moveFocusHere()
        }
    }

    /// NVDA: move focus to the navigator object.
    public func moveFocusHere() {
        guard let e = element else { return }
        let r = e.set(kAXFocusedAttribute, kCFBooleanTrue)
        Log.io("review: focus to \(e.role) → \(r.rawValue)")
        if r != .success { Speech.speakMessage(String(localized: "cannot take the focus", comment: "Spoken message")) }
        AXHandler.shared.refocus(pid: e.pid)
    }

    /// NVDA: move the navigator object to the focus.
    public func toFocus() {
        current = nil
        reportCurrent()
    }
}
