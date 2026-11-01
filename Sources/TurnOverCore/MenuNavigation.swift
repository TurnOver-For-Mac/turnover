// SPDX-License-Identifier: GPL-3.0-or-later
// Menus (NVDA reads menus by their focus events; macOS menus need more help).
//
// Measured on Word, 1 Oct 2026: menu items chosen through AXPress report success
// and do nothing; Return and Escape re-posted by TurnOver are ignored by menu-bar
// menus, while the real keys work; pressing a menu-bar title through AXPress
// opens its menu; an open menu has a size, a closed one is 0 × 0; the
// highlighted item is reported through AXSelectedChildrenChanged.
//
// So: Control-F2 opens the application menu itself (no keyboard mode to guess
// at), arrows and letters are scripts that re-post the key and speak the
// highlighted item, Return, Space and Escape go through untouched and the menu
// is watched until it closes, when the real focus is read again.
import Foundation
import ApplicationServices
import TurnOverAX

final class MenuNavigationPlugin: GlobalPlugin {
    static var menuBarPid: pid_t = 0
    private var lastItem: AXUIElement?
    private var lastSpoken: (AXUIElement, Date)?

    required init() {
        super.init()
        let cat = "Menus"
        for key in ["upArrow", "downArrow", "leftArrow", "rightArrow", "home", "end", "pageUp", "pageDown"] {
            script("menu_\(key)", String(localized: "Moves in the open menu and reads the item", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:\(key)"], category: cat) { [weak self] g in self?.move(g) }
        }
        for letter in "abcdefghijklmnopqrstuvwxyz" {
            script("menu_type_\(letter)", String(localized: "Jumps to the item starting with the letter", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:\(letter)"], category: cat) { [weak self] g in self?.move(g) }
        }
        for key in ["upArrow", "downArrow", "home", "end", "rightArrow", "enter", "space"] {
            script("webMenu_\(key)", String(localized: "In a page's own menu: moves through its items or presses one", comment: "A command, as the key list and keyboard help say it"), gestures: [], category: cat) { [weak self] g in self?.webMenu(g) }
        }
        // The menu bar as VoiceOver has it (Mac style, 8 Oct 2026): VO M lands on the Apple menu's title, Left
        // and Right go along the bar, Down (or VO Space, Return) opens the menu, Escape leaves. The Windows style
        // opens the Apple menu straight away, and Up and Down move through it as a list, as NVDA.
        for key in ["leftArrow", "rightArrow", "turnover+leftArrow", "turnover+rightArrow", "home", "end", "downArrow", "turnover+space", "enter", "space", "escape", "turnover+downArrow"] {
            script("menuBar_\(key)", String(localized: "On the menu bar: Left and Right move along it, Down opens the menu, Escape leaves", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:\(key)"], category: cat) { g in
                Self.barKey(g)
            }.isAvailable = { Self.heldBar != nil }
        }
        script("menuBar_activate", String(localized: "Opens the application's menus", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:control+f2", "kb:control+function+f2"], category: cat) { [weak self] g in self?.openMenuBar(g) }
        InputManager.onPassThrough = { [weak self] g in self?.passedThrough(g) }
    }

    override func script(for gesture: KeyboardGesture) -> Script? {
        // On the menu bar's titles (Mac style): the bar's own keys, by the usual lookup.
        if Self.heldBar != nil, let s = super.script(for: gesture), s.name.hasPrefix("menuBar_") { return s }
        let key = gesture.keyName
        if key == "f2", gesture.modifiers.contains(.control), !gesture.modifiers.contains(.turnover) { return script(named: "menuBar_activate") }
        guard AXHandler.shared.isMenuOpen, gesture.modifiers.subtracting(.shift).isEmpty else { return nil }
        // A page's own menu (a web page's role="menu"): TurnOver moves through it itself (see webMenu).
        if AXHandler.shared.topMenuIsWeb, gesture.modifiers.isEmpty,
           let s = script(named: "webMenu_\(key == "numpadEnter" ? "enter" : key)") { return s }
        if key == "enter" || key == "numpadEnter" || key == "space" || key == "escape" { return nil }   // the real key, untouched
        if key.count == 1, key.first!.isLetter { return script(named: "menu_type_\(key)") }
        return script(named: "menu_\(key)")
    }

    // MARK: A page's own menu
    //
    // Claude's model picker in Safari (3 Oct 2026): a web menu whose items Safari shows to accessibility, but the
    // arrows did nothing on the page (VoiceOver could not move in it either). So in a menu that belongs to a web page
    // TurnOver walks the items itself, as VoiceOver's VO-arrows do: Up and Down read them, Enter, Space or Right
    // press the one it is on (Right only where it opens more). Escape still goes to the page.

    static func isWebMenu(_ menu: AXUIElement) -> Bool {
        var p = menu.element(kAXParentAttribute); var hops = 0
        while let x = p, hops < 40 { if x.role == "AXWebArea" { return true }; p = x.element(kAXParentAttribute); hops += 1 }
        return false
    }

    /// The menu's items in order, through the groups that hold them; separators left out.
    static func webMenuItems(_ menu: AXUIElement) -> [AXUIElement] {
        var out: [AXUIElement] = []
        func walk(_ e: AXUIElement, _ depth: Int) {
            for c in e.elements(kAXChildrenAttribute) {
                let r = c.role
                if r == "AXMenuItem" { out.append(c) }
                else if r != "AXSplitter", r != "AXMenu", depth < 4 { walk(c, depth + 1) }
            }
        }
        walk(menu, 0)
        return out
    }
    private var webMenu: AXUIElement?
    private var webIndex = 0

    private func webMenu(_ g: KeyboardGesture) {
        guard let menu = AXHandler.shared.openMenus.last else { g.send(); return }
        let items = Self.webMenuItems(menu)
        guard !items.isEmpty else { g.send(); return }
        if webMenu.map({ !$0.isSame(menu) }) ?? true {
            // A menu new to us: start on the item the page has focused or checked, else before the first.
            webMenu = menu
            let focused = AXUIElementCreateApplication(menu.pid).element(kAXFocusedUIElementAttribute)
            webIndex = items.firstIndex { i in focused.map { i.isSame($0) } ?? false } ?? -1
        }
        let n = items.count
        switch g.keyName {
        case "downArrow": webIndex = (webIndex + 1) % n
        case "upArrow": webIndex = webIndex <= 0 ? n - 1 : webIndex - 1
        case "home": webIndex = 0
        case "end": webIndex = n - 1
        default:
            let i = max(0, min(webIndex, n - 1))
            let item = items[i]
            if g.keyName == "rightArrow", item.elements(kAXChildrenAttribute).first(where: { $0.role == "AXMenu" }) == nil,
               (item.attr("AXHasPopup") as? Bool) != true, item.string("AXPopupValue") == nil {
                Tones.edge(); return
            }
            let r = AXUIElementPerformAction(item, kAXPressAction as CFString)
            Log.io("web menu: press \"\(Log.words(item.string(kAXTitleAttribute) ?? ""))\" → \(describeError(r))")
            if r == .success { Tones.press(); webMenu = nil } else { g.send() }
            return
        }
        let item = items[webIndex]
        _ = item.set(kAXFocusedAttribute, kCFBooleanTrue)   // the page's own highlight follows, where it can
        let obj = ObjectFactory.make(item)
        API.setFocusObject(obj, ancestors: API.focusAncestors)
        lastSpoken = (item, Date())
        // Its place among all the items: the groups made every item "1 of 1".
        var parts = Speech.objectPropertiesSpeech(obj, reason: .focus).filter { !Phrases.isPosition($0) }
        parts.append(Phrases.position(webIndex + 1, of: n))
        Speech.cancel()
        Speech.speakMessage(Speech.joined(parts))
    }

    /// Control-F2, VO-M, Command alone: open the Apple menu through accessibility, as macOS and VoiceOver land there
    /// (8 Oct 2026: the application menu is what the Mac does NOT do).
    private func openMenuBar(_ g: KeyboardGesture) {
        guard let pid = API.focusPid, let bar = AXUIElementCreateApplication(pid).element(kAXMenuBarAttribute) else { g.send(); return }
        let titles = bar.elements(kAXChildrenAttribute)
        guard titles.count > 1 else { g.send(); return }
        Self.menuBarPid = pid
        // The application hands focus back to its window as its menu opens (Safari's page, Mail's message body): that
        // focus is held back as in the gap between two menus, and dropped when the menu opens (a tester, 7 Oct 2026).
        AXHandler.shared.menuAboutToOpen(pid: pid)
        let r = AXUIElementPerformAction(titles[0], kAXPressAction as CFString)
        Log.io("menu bar: open \"\(titles[0].string(kAXTitleAttribute).map(Log.words) ?? "Apple")\" → \(describeError(r))")
        if r != .success { g.send() }
    }

    /// Return, Space or Escape went to the application: watch for the menu to close, then read the focus.
    private func passedThrough(_ g: KeyboardGesture) {
        guard AXHandler.shared.isMenuOpen, ["enter", "numpadEnter", "space", "escape"].contains(g.keyName) else { return }
        let pid = AXHandler.shared.openMenus.last?.pid ?? Self.menuBarPid
        watchToken += 1
        let token = watchToken
        var done = false
        for delay in [0.25, 0.6, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, token == watchToken, !done, !AXHandler.shared.isMenuOpen else { return }
                done = true
                lastItem = nil; lastSpoken = nil
                Log.io("menu closed after \(g.keyName)")
                AXHandler.shared.refocus(pid: pid)
            }
        }
    }
    private var watchToken = 0

    // MARK: The menu bar held across (Mac style)

    /// The bar's titles while TurnOver's cursor is on them (no menu open yet), and which one.
    static var heldBar: (pid: pid_t, titles: [AXUIElement], index: Int)?
    /// Holding the status items instead (VO M M): their names and owning processes, by index.
    static var heldStatus: (names: [String], pids: [pid_t])?

    /// The status menus as VoiceOver has them (Mac style, VO M M): along the right of the menu bar with Left and
    /// Right, Down opens one (a vertical list, with the arrows bumping, was the NVDA way: a tester, 8 Oct 2026).
    static func holdStatusItems() {
        let extras = StatusMenus.gather()
        guard let pid = API.focusPid else { Tones.edge(); return }
        // TurnOver's own item last, as in the list on Windows+B; it was missing here (9 Oct 2026).
        let me = getpid()
        heldBar = (pid, extras.map(\.element) + [AXUIElementCreateApplication(me)], 0)
        heldStatus = (extras.map(\.name) + ["TurnOver"], extras.map(\.pid) + [me])
        Speech.speakMessage(String(localized: "status menus, \(String(extras.count + 1))", comment: "The status menus list opened: how many"))
        sayBarTitle()
        Hints.schedule(String(localized: "Left and Right move along the status menus. Down opens one; Escape leaves.", comment: "Spoken message"))
    }

    static func holdMenuBar() {
        guard let pid = API.focusPid, let bar = AXUIElementCreateApplication(pid).element(kAXMenuBarAttribute) else { Tones.edge(); return }
        let titles = bar.elements(kAXChildrenAttribute)
        guard !titles.isEmpty else { Tones.edge(); return }
        heldBar = (pid, titles, 0)
        Speech.speakMessage(String(localized: "menu bar", comment: "Spoken message"))
        sayBarTitle()
        Hints.schedule(String(localized: "Left and Right move along the menu bar. Down opens the menu; Escape leaves.", comment: "Spoken message"))
    }

    static func releaseBar() { heldBar = nil; heldStatus = nil }

    /// Leaving the bar: where the keyboard still is, said (refocus alone was silent when nothing had changed, 8 Oct 2026).
    static func backFromBar(pid: pid_t) {
        if let f = API.focusObject, f.pid == pid, !f.name.isEmpty { Speech.speakObject(f, reason: .focus) }
        else if let w = API.foregroundObject, !w.name.isEmpty { Speech.speakMessage(w.name + ", " + Role.window.displayString) }
        else { AXHandler.shared.refocus(pid: pid) }
    }

    private static func sayBarTitle() {
        guard let h = heldBar else { return }
        if let st = heldStatus, st.names.indices.contains(h.index) {
            Speech.speakItem("\(st.names[h.index]), \(Phrases.position(h.index + 1, of: h.titles.count))")
            return
        }
        let t = h.titles[h.index]
        let name = t.string(kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 } ?? (h.index == 0 ? "Apple" : Role.menu.displayString)
        Speech.speakItem(String(localized: "\(name) menu", comment: "A menu bar item: %@ is its name (View menu)") + ", " + Phrases.position(h.index + 1, of: h.titles.count))
    }

    private static func barKey(_ g: KeyboardGesture) {
        guard var h = heldBar else { g.send(); return }
        guard API.focusPid == h.pid else { heldBar = nil; g.send(); return }
        switch g.keyName {
        case "leftArrow", "rightArrow":
            let j = h.index + (g.keyName == "rightArrow" ? 1 : -1)
            guard h.titles.indices.contains(j) else { Tones.edge(); return }
            h.index = j; heldBar = h; sayBarTitle()
        case "home", "end":
            h.index = g.keyName == "home" ? 0 : h.titles.count - 1; heldBar = h; sayBarTitle()
        case "downArrow", "space", "enter":
            let title = h.titles[h.index]
            Braille.releaseItem()   // (the bar's title came back on the display after the menu closed, 8 Oct 2026)
            if let st = heldStatus, st.pids.indices.contains(h.index) {
                // A status item: its own process answers (observed first), as the list did.
                let name = st.names[h.index], owner = st.pids[h.index]
                heldBar = nil; heldStatus = nil
                if owner == getpid() { DispatchQueue.main.async { TurnOverMenu.shared.open() }; return }   // TurnOver's own: its menu
                AXHandler.shared.observe(owner)
                StatusMenus.lastOpened = (name, Date())
                let r = AXUIElementPerformAction(title, kAXPressAction as CFString)
                Log.io("status menus: press \"\(Log.words(name))\" → \(r.rawValue)")
                if r != .success { DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if !AXHandler.shared.isMenuOpen { Speech.speakMessage(String(localized: "could not open \(name)", comment: "A menu could not be opened: %@ is its name")) } } }
                return
            }
            heldBar = nil
            menuBarPid = h.pid
            AXHandler.shared.menuAboutToOpen(pid: h.pid)
            let r = AXUIElementPerformAction(title, kAXPressAction as CFString)
            Log.io("menu bar: open \"\(title.string(kAXTitleAttribute).map(Log.words) ?? "Apple")\" → \(describeError(r))")
            if r != .success { Tones.edge() }
        case "escape":
            heldBar = nil; heldStatus = nil
            Braille.releaseItem()
            Self.backFromBar(pid: h.pid)
        default:
            g.send()
        }
    }

    /// A search box in the menu (Mail's "Ask Siri", a few levels down inside its first item).
    static func searchBox(in menu: AXUIElement) -> AXUIElement? {
        var queue = [(menu, 0)], n = 0
        while !queue.isEmpty, n < 60 {
            let (e, d) = queue.removeFirst(); n += 1
            if e.role == "AXTextField" { return e }
            if d < 4 { queue.append(contentsOf: e.elements(kAXChildrenAttribute).prefix(6).map { ($0, d + 1) }) }
        }
        return nil
    }

    /// An item the filter has left showing (a filtered-out one has no size).
    static func isShowing(_ e: AXUIElement) -> Bool {
        guard let v = e.attr(kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return true }
        var size = CGSize.zero
        return axValue(v, .cgSize, &size) && size.height > 0
    }

    /// Two references to the same menu item (some apps hand out a new reference each time they are asked).
    static func sameItem(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        if a.isSame(b) { return true }
        return a.string(kAXTitleAttribute) == b.string(kAXTitleAttribute)
            && (a.element(kAXParentAttribute).map { p in b.element(kAXParentAttribute).map { p.isSame($0) } ?? false } ?? false)
    }

    private func move(_ gesture: KeyboardGesture) {
        let menusBefore = AXHandler.shared.openMenus.count
        // What is highlighted now, asked before the key goes: the new item is whatever differs from it. (Comparing
        // with what TurnOver last said fell one behind in a VPN app's menus, and Right then opened the wrong submenu.)
        let before = AXHandler.shared.highlightedMenuItem()
        // A letter in a menu with a search box at the top (Mail's context menu, "Ask Siri"): the menu's own type-ahead
        // finds items by prefix ("m", "mo"), but a letter that matches nothing goes into the box and filters the menu
        // down to nothing, and the arrows then move the box's caret (8 Oct 2026). Such a letter is taken
        // back out, with a bump.
        let isLetter = gesture.keyName.count == 1 && (gesture.keyName.first?.isLetter ?? false)
        if isLetter, let menu = AXHandler.shared.openMenus.last, let box = Self.searchBox(in: menu) {
            // The menu's own search: letters filter its items. Say what the box holds and how many items are left,
            // so a filter that matches nothing isn't silence (8 Oct 2026); Up and Down then move through
            // the items left.
            gesture.send()
            Poll.pumping(every: 0.01, limit: 0.25) { false }   // let the menu filter
            let text = box.string(kAXValueAttribute) ?? ""
            let left = menu.elements(kAXChildrenAttribute).filter { $0.role == "AXMenuItem" && !($0.string(kAXTitleAttribute) ?? "").isEmpty && Self.isShowing($0) }
            // (The count isn't reliable while the menu filters; only "nothing left" is worth saying.)
            Speech.speakMessage(text.isEmpty ? Role.searchField.displayString : (left.count <= 1 ? String(localized: "\(text), no matches", comment: "Typing in a menu found nothing: %@ is what was typed") : text))
            if left.count <= 1 { Tones.edge() }
            return
        }
        // Right on an item with no submenu, in a menu that isn't the menu bar's: macOS does nothing, so nothing is sent
        // and nothing waited for; the edge sound says so. Each Right waited nearly a second for a submenu that never
        // came, the keys queued up behind, and the watchdog took TurnOver as stuck (a tester, 19 Oct 2026, a web
        // page's context menu).
        if gesture.keyName == "rightArrow", gesture.modifiers.isEmpty, let b = before, !Self.hasSubmenu(b), !Self.inMenuBar(b) {
            Tones.edge()
            return
        }
        gesture.send()
        let start = Date()
        var item: AXUIElement?
        // The menu marks the new item within a few milliseconds; poll briefly rather than guess a delay. Right into
        // a submenu waits longer: Mail's Move To list takes half a second to appear, and Right said nothing (5 Oct 2026).
        let limit = gesture.keyName == "rightArrow" ? 0.9 : 0.2
        _ = start
        var closed = false
        Poll.pumping(limit: limit) {
            if !AXHandler.shared.isMenuOpen { closed = true; return true }
            if let i = AXHandler.shared.highlightedMenuItem(), !Self.sameItem(i, before) { item = i; return true }
            return false
        }
        if closed { return }
        // Right on an item with a submenu that the app ignored (Mail's context menu, once letters have gone into its
        // "Ask Siri" box, moves that box's caret instead): open the submenu by accessibility, and step into it.
        if item == nil, gesture.keyName == "rightArrow", let b = before, Self.hasSubmenu(b) {
            Log.io("menu: Right did not open the submenu; opening it by accessibility")
            AXUIElementPerformAction(b, kAXPressAction as CFString)
            Poll.pumping(every: 0.01, limit: 0.8) { AXHandler.shared.openMenus.count > menusBefore }
            if AXHandler.shared.openMenus.count > menusBefore {
                KeyboardGesture(keyCode: 125, modifiers: [], characters: "", timestamp: 0, isRepeat: false, flags: []).send()   // to its first item
                Poll.pumping(limit: 0.4) {
                    if let i = AXHandler.shared.highlightedMenuItem(), !Self.sameItem(i, b) { item = i; return true }
                    return false
                }
                if let i = item {   // said here, with the submenu's name: its opening was news before this item was known
                    lastItem = i; lastSpoken = (i, Date())
                    let obj = ObjectFactory.make(i)
                    API.setFocusObject(obj, ancestors: API.focusAncestors)
                    Speech.speakMessage(String(localized: "\(b.string(kAXTitleAttribute) ?? "") submenu", comment: "A submenu opened: its name"))
                    speak(i, obj)
                    return
                }
            }
        }
        guard let item else {
            Log.io("menu: no highlighted item found after \(gesture.identifier)")
            if ["upArrow", "downArrow"].contains(gesture.keyName) { Tones.edge() }   // the end of the menu, not silence
            return
        }
        lastItem = item
        let obj = ObjectFactory.make(item)
        API.setFocusObject(obj, ancestors: API.focusAncestors)
        // The key opened a submenu: its opening says the menu's name, then this item, in that order.
        if gesture.keyName == "rightArrow" || gesture.keyName == "enter", AXHandler.shared.openMenus.count > menusBefore { pendingSubmenuItem = item; return }
        lastSpoken = (item, Date())
        speak(item, obj)
    }

    /// Whether an item opens a submenu: a menu among its children. (Any child counted: Mail's and TextEdit's "Ask
    /// Siri" item holds a text field, Right "opened" it by pressing, and the menu closed: 19 Oct 2026.)
    static func hasSubmenu(_ item: AXUIElement) -> Bool { item.elements(kAXChildrenAttribute).contains { $0.role == "AXMenu" } }

    /// Whether an item belongs to the menu bar (Right there moves to the next menu) rather than a context menu.
    static func inMenuBar(_ item: AXUIElement) -> Bool {
        var p = item.element(kAXParentAttribute)
        for _ in 0..<8 {
            guard let x = p else { return false }
            if x.role == "AXMenuBar" || x.role == "AXMenuBarItem" { return true }
            p = x.element(kAXParentAttribute)
        }
        return false
    }

    /// An item, with its section heading when it starts a new section (Mail's Move To list groups mailboxes under
    /// each account; the headings can't be highlighted, so the arrows skip them and they were never heard), and a
    /// name from inside it when it has none of its own (Mail's "Ask Siri" box at the top of its context menu).
    private var lastHeading: String?
    private func speak(_ item: AXUIElement, _ obj: TurnOverObject) {
        var parts: [String] = []
        // Sometimes the highlight lands on a heading itself (Mail's, opened from the keyboard): say it as one, once.
        if Self.isHeading(item) {
            lastHeading = item.string(kAXTitleAttribute)
            Speech.speakMessage("\(lastHeading ?? ""), \(Role.heading.displayString)")
            return
        }
        let heading = Self.heading(of: item)
        if let h = heading, h != lastHeading { parts.append(h) }
        lastHeading = heading
        if obj.name.isEmpty, let inner = Self.innerName(item) {
            parts.append(inner)
            Speech.speakMessage(Speech.joined(parts))
            return
        }
        if !parts.isEmpty { Speech.speakMessage(Speech.joined(parts)) }
        Speech.speakObject(obj, reason: .focus)
        // On the display too, as the item TurnOver's cursor is on (a held "Mail menu" message hid the items, 8 Oct 2026).
        Braille.item(Speech.objectPropertiesSpeech(obj, reason: .focus).joined(separator: ", "))
    }

    /// The heading above an item: the nearest item before it that is dimmed, has a title, no shortcut and no submenu,
    /// and starts its section (first in the menu, or just after a separator). Not every dimmed item: an unavailable
    /// command is not a heading.
    static func isHeading(_ item: AXUIElement) -> Bool {
        guard (item.attr(kAXEnabledAttribute) as? Bool) == false, !(item.string(kAXTitleAttribute) ?? "").isEmpty,
              item.elements(kAXChildrenAttribute).isEmpty, let menu = item.element(kAXParentAttribute) else { return false }
        let kids = menu.elements(kAXChildrenAttribute)
        guard let i = kids.firstIndex(where: { $0.isSame(item) }) else { return false }
        let afterSeparator = i == 0 || (kids[i - 1].string(kAXTitleAttribute) ?? "").isEmpty
        let sameKindNext = i + 1 < kids.count && (kids[i + 1].string(kAXIdentifierAttribute) ?? "") == (item.string(kAXIdentifierAttribute) ?? "")
        return afterSeparator && sameKindNext
    }

    static func heading(of item: AXUIElement) -> String? {
        guard let menu = item.element(kAXParentAttribute) else { return nil }
        let kids = menu.elements(kAXChildrenAttribute)
        guard let i = kids.firstIndex(where: { $0.isSame(item) }) else { return nil }
        var j = i - 1
        while j >= 0 {
            let k = kids[j]
            let title = k.string(kAXTitleAttribute) ?? ""
            if title.isEmpty { return nil }   // a separator: this section has no heading
            let enabled = (k.attr(kAXEnabledAttribute) as? Bool) ?? true
            // ...and is the same kind of item as those under it (Mail gives its account headings its mailbox items'
            // identifier). Typing in Mail's context menu dims every command that doesn't match, and "Mark as
            // Unread" was read as a heading (5 Oct 2026).
            if !enabled, (k.string("AXMenuItemCmdChar") ?? "").isEmpty, k.elements(kAXChildrenAttribute).isEmpty,
               j == 0 || (kids[j - 1].string(kAXTitleAttribute) ?? "").isEmpty,
               (k.string(kAXIdentifierAttribute) ?? "") == (item.string(kAXIdentifierAttribute) ?? "") {
                return title
            }
            j -= 1
        }
        return nil
    }

    /// A name for an item with none: a field's placeholder or description, or a text inside it.
    static func innerName(_ item: AXUIElement) -> String? {
        var queue = item.elements(kAXChildrenAttribute); var seen = 0
        while !queue.isEmpty, seen < 20 {
            let e = queue.removeFirst(); seen += 1
            for a in [kAXPlaceholderValueAttribute, kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute] {
                if let s = e.string(a)?.trimmingCharacters(in: .whitespaces), !s.isEmpty {
                    return e.role == "AXTextField" ? "\(s), edit" : s
                }
            }
            queue.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
        return nil
    }
    /// The highlighted item of a submenu just opened by a key, spoken after the submenu's name.
    private var pendingSubmenuItem: AXUIElement?
    private var lastMenuStart = Date.distantPast
    private var settlingSelection: AXUIElement?
    private var settleScheduled = false

    override func handleEvent(_ event: Event, next: () -> Void) {
        if event.kind == .menuEnd {
            // Only when the whole menu has gone: a submenu closing as the arrows move on (Mail opens each one it
            // passes) cleared this, and the item it had just said was said again.
            guard !AXHandler.shared.isMenuOpen else { return }
            lastItem = nil; lastSpoken = nil; lastHeading = nil
            if API.focusObject?.role == .menuItem || API.focusObject?.role == .menu {
                let pid = event.obj.pid
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { if !AXHandler.shared.isMenuOpen { AXHandler.shared.refocus(pid: pid) } }
            }
        }
        if event.kind == .selection || event.kind == .gainFocus, let (el, at) = lastSpoken, Self.sameItem(event.obj.element, el), Date().timeIntervalSince(at) < 1 {
            return   // the menu reported what the arrow script already spoke
        }
        if event.kind == .selection, [.menuItem, .checkMenuItem, .radioMenuItem].contains(event.obj.role) {
            // Just after a menu opens, the highlight can be reported twice in quick succession (a VPN app's
            // "My Devices", then its search field): wait a moment and read only the last report.
            if Date().timeIntervalSince(lastMenuStart) < 0.3 {
                settlingSelection = event.obj.element
                if !settleScheduled {
                    settleScheduled = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in
                        guard let self else { return }
                        self.settleScheduled = false
                        guard let i = self.settlingSelection, AXHandler.shared.isMenuOpen else { return }
                        self.settlingSelection = nil
                        if self.lastSpoken.map({ Self.sameItem($0.0, i) && Date().timeIntervalSince($0.1) < 1 }) ?? false { return }
                        self.lastItem = i; self.lastSpoken = (i, Date())
                        Speech.speakObject(ObjectFactory.make(i), reason: .focus)
                    }
                }
                return
            }
            // The menu's own report of its highlight is the truth: remember it, and say it once.
            lastItem = event.obj.element
            lastSpoken = (event.obj.element, Date())
        }
        if event.kind == .menuStart {
            // A submenu the app opened by itself as Up or Down passed its item (Mail does, for each one): not news,
            // and saying "All Junk submenu" at every step buried the list. Right or Return still announce it.
            if AXHandler.shared.openMenus.count > 1, ["upArrow", "downArrow"].contains(where: { InputManager.lastKeyIdentifier.hasSuffix($0) }),
               Date().timeIntervalSince(InputManager.lastKeyDownAt) < 0.8 {
                lastMenuStart = Date()
                return
            }
            lastMenuStart = Date()
            lastItem = nil
            next()
            // Only an item of the menu that just opened (a VPN app's menu reported a stale "Forum" from elsewhere),
            // and not one already spoken.
            let pending = pendingSubmenuItem
            pendingSubmenuItem = nil
            let menu = event.obj.element
            // A submenu's highlight can settle a moment after it opens (a VPN app's search field takes it from the
            // first device); read where it settles, once.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self, AXHandler.shared.isMenuOpen, self.settlingSelection == nil, !self.settleScheduled else { return }
                guard let i = AXHandler.shared.highlightedMenuItem() ?? pending, i.element(kAXParentAttribute)?.isSame(menu) ?? false,
                      !(self.lastSpoken.map { Self.sameItem($0.0, i) && Date().timeIntervalSince($0.1) < 1 } ?? false) else { return }
                self.lastItem = i; self.lastSpoken = (i, Date())
                Speech.speakObject(ObjectFactory.make(i), reason: .focus)
            }
            return
        }
        next()
    }
}
