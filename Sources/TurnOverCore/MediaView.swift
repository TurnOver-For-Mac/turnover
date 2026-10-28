// SPDX-License-Identifier: GPL-3.0-or-later
// Apple's media apps (Music, Podcasts, TV) as three flat areas, with no groups to enter or leave:
// the sidebar, the page (shelves of items, read as one list), and the player.
//
// Measured 2 Oct 2026 (macOS 27):
// - Music and Podcasts share one framework: shelf headings carry identifiers with "shelf.header",
//   items "shelfItem" (their parts "shelfItemSubComponent"), and the player is a group whose
//   identifier holds "miniPlayer.contentView" (transport buttons, a "metadataRegion").
// - Music's and TV's sidebars are AXOutlines described "Sidebar"; Podcasts' sidebar is pressable
//   AXStaticTexts (and AXHeadings for its groups) with identifiers "podcasts.tabBar.…".
// - Music's shelves: an AXHeading, then a grid of AXButtons, each described. Podcasts': a header group
//   (its AXButton is the title and "see all"), then item groups whose parts are artwork (value: the
//   show), a description and a "Play, Remaining Time: …" button. TV's: AXList/AXSectionList described
//   with the shelf's title; items load as the view scrolls.
// - Library views (Music's Songs) are AXTables: each row is an item.
//
// Keys, while focus is not in a text field (MediaKeys in the app module): Tab and Shift+Tab move
// between the areas; Up and Down move through the area's items (the shelf is named when crossing
// into it); Left and Right jump between shelves; Home and End; Enter opens; Space plays the item or
// pauses; Escape goes back; a letter jumps to the next item starting with it.
import Foundation
import ApplicationServices
import AppKit

public final class MediaView {
    nonisolated public struct Item: Sendable {
        public var label: String
        public var element: AXUIElement
        public var press: AXUIElement?
        public var play: AXUIElement?
        /// How to play it: a Play button's press, or Podcasts' own action on the episode ("Name:Play, Remaining Time:
        /// 15 minutes…", an AXCustomAction: its Home page episodes have no Play button, 7 Oct 2026).
        public var playAction = kAXPressAction as String
        public var isHeader = false
        public var selected = false
        public var tableRow = false
        /// What identifies the item again after the page has scrolled and its element gone or been reused: its
        /// identifier (Music's carry the item's id, "Music.shelfItem.HorizontalLockup[id=ra.68…,parentId=…]") and
        /// description, and where the page's scroll bar was when it was read.
        public var ident = ""
        public var desc = ""
        public var scrollValue: Double?
        /// Music's and TV's identifiers name the item ("…[id=ra.68…", "….id=\"umc.cmc.31qa8j…\""); others are
        /// shared by a shelf's items, so the words are added.
        var key: String { ident.contains("id=") ? ident : ident + "|" + label }
    }
    nonisolated public struct Shelf: Sendable {
        public var title: String; public var items: [Item]
        /// Where the shelf begins on the screen when read, then (in `build`) on the whole page: shelves read at
        /// different scroll positions are put in order by it.
        var top: CGFloat?
    }

    /// The toolbar: its buttons (More, Share; not Back, which Escape is), as Podcasts keeps Unfollow and Report in More.
    public enum Pane: Int { case sidebar, page, player, toolbar }

    public let pid: pid_t
    public init(pid: pid_t) { self.pid = pid }

    // The model, rebuilt when stale.
    nonisolated(unsafe) public private(set) var sidebar: [Item] = []
    public private(set) var shelves: [Shelf] = []
    public private(set) var player: [Item] = []
    public private(set) var toolbar: [Item] = []
    public private(set) var pageTitle = ""
    private var builtAt = Date.distantPast

    // Where the user is.
    public var pane: Pane = .page
    private var index: [Pane: Int] = [:]

    var flatPage: [(shelf: Int, item: Item)] {
        shelves.enumerated().flatMap { s, shelf in shelf.items.map { (s, $0) } }
    }

    nonisolated private static let windowWalkLimit = 6000
    private static let searchPageTries = 14
    private static let paneCount = 4

    // MARK: Building

    /// Rebuilding walks the window (about 0.7 s in Music and Podcasts), so arrows use the model as it is, and it is
    /// rebuilt on opening, going back and changing area, or when it is a few seconds old.
    /// True when the model can answer now. False when it was empty and is being read in the background (the
    /// first key after opening the app: 1 to 5 s of questions, which used to hold the main thread, 8 Oct 2026):
    /// the caller queues itself (`queued`) and is run again when the model is in; "please wait" is said if it is slow.
    @discardableResult
    public func rebuild(force: Bool = false) -> Bool {
        if !force {
            // Stale but usable: answer this key from the model as it is, and refresh it in the background.
            if Date().timeIntervalSince(builtAt) > 8.0, !refreshing, !sidebar.isEmpty || !shelves.isEmpty {
                refreshing = true
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self else { return }
                    let built = self.build()
                    DispatchQueue.main.async { self.apply(built); self.refreshing = false }
                }
                return true
            }
            guard sidebar.isEmpty && shelves.isEmpty else { return true }
            guard !loadingMore else { return false }
            loadingMore = true
            Poll.background({ [weak self] in self?.build() }) { [weak self] built in
                guard let self else { return }
                apply(built ?? nil)
                loadingMore = false
                runQueued()
            }
            return false
        }
        apply(build())
        return true
    }
    private var refreshing = false

    /// Read the window in the background, then carry on (arriving in the app).
    public func refresh(keepSidebar: Bool = false, then: @escaping @MainActor () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let built = self.build(keepSidebar: keepSidebar)
            DispatchQueue.main.async { self.apply(built); then() }
        }
    }

    nonisolated struct Built: Sendable { var sidebar: [Item]; var shelves: [Shelf]; var player: [Item]; var pageTitle: String; var playerRoot: AXUIElement?; var pageScroll: AXUIElement?; var pageID: String; var toolbar: [Item] = [] }
    /// Which page the model holds: a read of the same page is merged into it, as the page only shows the shelves
    /// near the screen.
    nonisolated(unsafe) private var pageID = ""
    private var playerRoot: AXUIElement?
    private var pageScroll: AXUIElement?

    /// The player alone, read again (its few buttons: quick enough for any thread).
    private func refreshPlayer() { if let r = playerRoot { player = Self.playerItems(r) } }

    /// The sidebar and page id are read by a build on a background queue while the main thread may be applying
    /// another: both sides take this lock (8 Oct 2026, from the code review).
    private let modelLock = NSLock()
    nonisolated private func snapshot() -> ([Item], String) { modelLock.lock(); defer { modelLock.unlock() }; return (sidebar, pageID) }

    private func apply(_ b: Built?) {
        guard let b else { return }
        let keep = currentItem().flatMap { $0.tableRow ? nil : $0.label }
        let keepIndex = index[pane]
        let isTable = b.shelves.contains { $0.items.first?.tableRow == true }
        shelves = !isTable && !b.pageID.isEmpty && b.pageID == pageID ? Self.merge(shelves, b.shelves) : b.shelves
        modelLock.lock()
        sidebar = b.sidebar; pageID = b.pageID
        modelLock.unlock()
        player = b.player; toolbar = b.toolbar; pageTitle = b.pageTitle; playerRoot = b.playerRoot; pageScroll = b.pageScroll
        builtAt = Date()
        rowLabels = [:]
        if let keep, let i = items(of: pane).firstIndex(where: { $0.label == keep }) { index[pane] = i }
        else if let k = keepIndex { index[pane] = min(k, max(0, items(of: pane).count - 1)) }
        Log.io("media: \(sidebar.count) sidebar, \(shelves.count) shelves (\(flatPage.count) items), \(player.count) player, page \(Log.words(pageTitle))")
    }

    /// Read the app's window into a model (any thread: accessibility calls only).
    /// `keepSidebar`: the page alone, as it scrolls (Music's sidebar takes 3 to 4 s to read, 7 Oct 2026).
    nonisolated private func build(topped: Bool = false, keepSidebar: Bool = false) -> Built? {
        if Self.showsVideo(pid: pid) { return nil }   // the video player has no page to read
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        guard let window = app.element(kAXFocusedWindowAttribute) ?? app.element(kAXMainWindowAttribute) else { return nil }
        let (sidebarRoot, playerRoot, tabBarItems) = Self.regions(in: window)
        let (keptSidebar, knownPageID) = snapshot()   // the model as the main thread has it, read under its lock
        let sidebar = keepSidebar ? keptSidebar : sidebarRoot.map(Self.outlineItems) ?? tabBarItems.map(Self.tabBarItem)
        let player = playerRoot.map(Self.playerItems) ?? []
        // Podcasts' sidebar is a block of tab-bar items with the account name beside it: leave the whole block out.
        let tabBarBlock = tabBarItems.first?.element(kAXParentAttribute)?.element(kAXParentAttribute)
        // Podcasts keeps the page you came from in the tree behind the new one, the same size (the search behind a
        // show's page, 7 Oct 2026): the one named as the window is titled is showing; the others are skipped.
        let behind = Self.hiddenPages(in: window)
        var shelves = Self.shelves(in: window, skipping: [sidebarRoot, playerRoot, tabBarBlock].compactMap { $0 } + tabBarItems + behind)
        // The window's own title when it names the page (Podcasts: "Example Podcast", not the sidebar's "Search");
        // the sidebar's choice when the window is just the app's name (Music).
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
        let windowName = window.string(kAXTitleAttribute) ?? ""
        let pageTitle = !windowName.isEmpty && windowName != appName ? windowName : (sidebar.first(where: { $0.selected })?.label ?? windowName)
        // A table with no name of its own is the page's list ("Songs", not the window's "Music").
        let windowTitle = window.string(kAXTitleAttribute) ?? ""
        for i in shelves.indices where shelves[i].title == windowTitle || shelves[i].title == "List" { shelves[i].title = pageTitle }
        // The scroll area holding the page: scrolling it loads more shelves. The first item's nearest ancestor that
        // scrolls up and down (a carousel inside may be a scroll area of its own, sideways). Podcasts' is a group
        // with a scroll bar ("podcasts.listen[viewState=loaded,sections=19]").
        var scroll: AXUIElement?
        var x = shelves.first?.items.first?.element.element(kAXParentAttribute)
        var hops = 0
        while let e = x, hops < 30 {
            if e.element(kAXVerticalScrollBarAttribute) != nil { scroll = e; break }
            if e.role == "AXScrollArea", scroll == nil { scroll = e }
            x = e.element(kAXParentAttribute); hops += 1
        }
        let barValue = (scroll?.element(kAXVerticalScrollBarAttribute)?.attr(kAXValueAttribute) as? NSNumber)?.doubleValue
        Self.rememberPositions(in: &shelves, scroll: scroll, barValue: barValue)
        // The page: its title, and the scroll area (its identifier, "Music.Genre[id=176843,sections=15]", or the
        // element itself, which stays the same while the page is shown).
        // (Less what changes as it loads: Podcasts' "podcasts.listen[viewState=loaded,sections=19]".)
        let pageID = scroll.map { sc -> String in
            let id = (sc.string(kAXIdentifierAttribute) ?? "").replacingOccurrences(of: "(viewState|sections)=[^,\\]]*,?", with: "", options: .regularExpression)
            return pageTitle + "|" + id + "|\(CFHash(sc))"
        } ?? ""
        // A page new to the model, shown part way down (Music keeps where it was): read it from the top, since the
        // shelves above the screen are not there to read.
        if !topped, pageID != knownPageID, let v = barValue, v > 0.01, let bar = scroll?.element(kAXVerticalScrollBarAttribute),
           bar.set(kAXValueAttribute, NSNumber(value: 0)) == .success {
            Log.io("media: a new page part way down (\(String(format: "%.2f", v))): reading it from the top")
            usleep(400_000)
            return build(topped: true, keepSidebar: keepSidebar)
        }
        // Podcasts' scroll bar has no value to read or set: up a page at a time to the top. A page scrolls only once
        // the one before has finished (measured 7 Oct 2026), so each waits, and it stops when nothing moves.
        if !topped, pageID != knownPageID, barValue == nil, let sc = scroll, let size = Self.cgSize(sc, kAXSizeAttribute),
           let content = Self.cgSize(sc, "AXContentSize"), size.height > 0, content.height > size.height * 1.2 {   // a zero height made Int(infinity), a crash (code review, 20 Oct 2026)
            func shown() -> String { sc.elements(kAXChildrenAttribute).prefix(3).map { $0.string(kAXIdentifierAttribute) ?? "" }.joined(separator: "|") }
            var n = 0
            var before = shown()
            while n < Int(content.height / size.height) + 2, AXUIElementPerformAction(sc, "AXScrollUpByPage" as CFString) == .success {
                usleep(350_000)
                let now = shown()
                if now == before { break }
                before = now; n += 1
            }
            Log.io("media: a new page, up \(n) pages to read it from the top")
            if n > 0 { return build(topped: true, keepSidebar: keepSidebar) }
        }
        let bar = Self.toolbarItems(in: window)
        return Built(sidebar: sidebar, shelves: shelves, player: player, pageTitle: pageTitle, playerRoot: playerRoot, pageScroll: scroll, pageID: pageID, toolbar: bar)
    }

    nonisolated private static func rememberPositions(in shelves: inout [Shelf], scroll: AXUIElement?, barValue: Double?) {
        // Shelves' places on the whole page: on screen, less the page's top, plus how far it is scrolled.
        if let sc = scroll, let v = barValue, let origin = Self.position(sc), let size = Self.cgSize(sc, kAXSizeAttribute),
           let content = Self.cgSize(sc, "AXContentSize") {
            let offset = CGFloat(v) * max(0, content.height - size.height)
            for i in shelves.indices { shelves[i].top = shelves[i].top.map { $0 - origin.y + offset } }
        } else {
            for i in shelves.indices { shelves[i].top = nil }
        }
        for s in shelves.indices {
            for i in shelves[s].items.indices where !shelves[s].items[i].tableRow {
                let e = shelves[s].items[i].element
                shelves[s].items[i].ident = e.string(kAXIdentifierAttribute) ?? ""
                shelves[s].items[i].desc = e.string(kAXDescriptionAttribute) ?? ""
                shelves[s].items[i].scrollValue = barValue
            }
        }
    }

    nonisolated private static func regions(in window: AXUIElement) -> (AXUIElement?, AXUIElement?, [AXUIElement]) {
        var sidebarRoot: AXUIElement?
        var playerRoot: AXUIElement?
        var tabBarItems: [AXUIElement] = []
        // Find the regions.
        var stack = [window]
        var visited = 0
        while let e = stack.popLast(), visited < Self.windowWalkLimit {
            visited += 1
            let id = e.string(kAXIdentifierAttribute) ?? ""
            if sidebarRoot == nil, e.role == "AXOutline", e.string(kAXDescriptionAttribute) == "Sidebar" { sidebarRoot = e; continue }
            if playerRoot == nil, id.contains("miniPlayer.contentView") { playerRoot = e; continue }
            if id.contains(".tabBar.") { tabBarItems.append(e); continue }
            // A library table can hold thousands of songs: finding the areas never goes inside one.
            if e.role == "AXTable" || e.role == "AXOutline" || e.role == "AXRow" { continue }
            stack.append(contentsOf: e.elements(kAXChildrenAttribute).reversed())
        }
        return (sidebarRoot, playerRoot, tabBarItems)
    }

    nonisolated private static func hiddenPages(in window: AXUIElement) -> [AXUIElement] {
        var pages: [AXUIElement] = []
        do {
            var st = [window], n = 0
            while let e = st.popLast(), n < 4000 {
                n += 1
                let id = e.string(kAXIdentifierAttribute) ?? ""
                if id.contains("[viewState="), !id.contains("miniPlayer") { pages.append(e); continue }
                if e.role == "AXTable" || e.role == "AXOutline" { continue }
                st.append(contentsOf: e.elements(kAXChildrenAttribute))
            }
        }
        let title = window.string(kAXTitleAttribute) ?? ""
        var behind: [AXUIElement] = []
        if pages.count > 1, pages.contains(where: { ($0.string(kAXDescriptionAttribute) ?? "") == title }) {
            behind = pages.filter { ($0.string(kAXDescriptionAttribute) ?? "") != title }
        }
        return behind
    }

    nonisolated private static func toolbarItems(in window: AXUIElement) -> [Item] {
        // The window's toolbar buttons (Podcasts' More, Share): Back is Escape's.
        var bar: [Item] = []
        if let tb = window.elements(kAXChildrenAttribute).first(where: { $0.role == "AXToolbar" }) {
            var st = tb.elements(kAXChildrenAttribute), n = 0
            while !st.isEmpty, n < 200 {
                let e = st.removeFirst(); n += 1
                if ["AXButton", "AXMenuButton", "AXPopUpButton"].contains(e.role) {
                    let t = e.string(kAXDescriptionAttribute) ?? e.string(kAXTitleAttribute) ?? ""
                    if !t.isEmpty, t != "Back", e.string(kAXIdentifierAttribute) != "BackButton" { bar.append(Item(label: t + (e.role == "AXButton" ? ", button" : ", menu button"), element: e, press: e)) }
                    continue
                }
                st.append(contentsOf: e.elements(kAXChildrenAttribute))
            }
        }
        return bar
    }

    /// A newer read of the same page into the model: shelves already known take the new items and fresher elements;
    /// new shelves go in after the last known one before them. Music keeps only the shelves near the screen, so the
    /// ones scrolled past stay as they were read.
    public static func merge(_ old: [Shelf], _ new: [Shelf]) -> [Shelf] {
        func same(_ a: Shelf, _ b: Shelf) -> Bool {
            if !a.title.isEmpty || !b.title.isEmpty { return a.title == b.title }
            return a.items.first?.key == b.items.first?.key
        }
        var out = old
        // New shelves before the first known one go just above it; with none known (Podcasts scrolls a few
        // screens at a time, and has no places to sort by), the new ones are further down: after the rest.
        var at = new.lazy.compactMap { ns in out.firstIndex { same($0, ns) } }.first ?? out.count
        for ns in new {
            if let j = out.firstIndex(where: { same($0, ns) }) {
                var items = out[j].items
                for it in ns.items {
                    if let k = items.firstIndex(where: { $0.key == it.key }) { items[k] = it } else { items.append(it) }
                }
                out[j].items = items
                if out[j].top == nil { out[j].top = ns.top }
                at = j + 1
            } else {
                out.insert(ns, at: min(at, out.count))
                at += 1
            }
        }
        // In the page's order, where every shelf's place is known (a stable sort: equal places keep their order).
        if out.allSatisfy({ $0.top != nil }) {
            out = out.enumerated().sorted { ($0.element.top!, $0.offset) < ($1.element.top!, $1.offset) }.map(\.element)
        }
        return out
    }

    nonisolated static func outlineItems(_ outline: AXUIElement) -> [Item] {
        outline.elements(kAXRowsAttribute).compactMap { row in
            let cell = row.elements(kAXChildrenAttribute).first
            // The cell's description, else the row's text (slow to gather: 4 s for Music's 35 rows, 7 Oct 2026).
            var label = cell?.string(kAXDescriptionAttribute) ?? ""
            if label.isEmpty { label = ElementMatcher.text(of: row) }
            guard !label.isEmpty else { return nil }
            var acts: CFArray?
            if let c = cell { AXUIElementCopyActionNames(c, &acts) }
            let pressable = ((acts as? [String]) ?? []).contains("AXPress")
            // TV's group rows (Library, Channels) cannot be pressed; Music's carry an Edit button.
            let header = cell.map { c in c.elements(kAXChildrenAttribute).contains { $0.role == "AXButton" && $0.string(kAXTitleAttribute) == "Edit" } } ?? false
            return Item(label: label, element: row, press: pressable ? cell : nil, isHeader: header,
                        selected: (row.attr(kAXSelectedAttribute) as? Bool) == true)
        }
    }

    nonisolated static func tabBarItem(_ e: AXUIElement) -> Item {
        let label = e.string(kAXDescriptionAttribute) ?? ElementMatcher.text(of: e)
        return Item(label: label, element: e, press: e, isHeader: e.role == "AXHeading",
                    selected: (e.attr(kAXSelectedAttribute) as? Bool) == true || (e.attr("AXValue") as? NSNumber)?.boolValue == true)
    }

    nonisolated static func playerItems(_ root: AXUIElement) -> [Item] {
        var out: [Item] = []
        func walk(_ e: AXUIElement) {
            let role = e.role
            if ["AXButton", "AXPopUpButton", "AXCheckBox", "AXSlider"].contains(role) {
                var label = e.string(kAXDescriptionAttribute) ?? e.string(kAXTitleAttribute) ?? ""
                if let v = e.attr(kAXValueAttribute).map({ "\($0)" }), !v.isEmpty, role != "AXCheckBox", !v.hasPrefix("<") { label += ", \(v)" }
                if (e.attr(kAXEnabledAttribute) as? Bool) == false { label += ", unavailable" }
                if !label.isEmpty, !["More", "Mini Player Artwork"].contains(label) { out.append(Item(label: label, element: e, press: e)) }
                return
            }
            if (e.string(kAXIdentifierAttribute) ?? "").contains("metadataRegion") {
                let t = ElementMatcher.text(of: e)
                let desc = e.elements(kAXChildrenAttribute).compactMap { $0.string(kAXDescriptionAttribute) }
                    .filter { !$0.isEmpty && !["Show Now Playing", "Mini Player Artwork", "More", "Track Position"].contains($0) }
                    .map { $0.replacingOccurrences(of: "Mini Player Artwork, ", with: "").replacingOccurrences(of: ", Track Position, More", with: "") }
                let label = ([t] + desc).filter { !$0.isEmpty }.joined(separator: ", ")
                out.append(Item(label: label.isEmpty ? "Nothing playing" : label, element: e, press: nil))
                return
            }
            for c in e.elements(kAXChildrenAttribute) { walk(c) }
        }
        walk(root)
        return out
    }

    /// Everything that is not the sidebar or the player, as shelves of items, in reading order.
    nonisolated static func shelves(in window: AXUIElement, skipping: [AXUIElement]) -> [Shelf] {
        var shelves: [Shelf] = []
        var current = Shelf(title: "", items: [])
        var visited = 0
        func startShelf(_ title: String, at e: AXUIElement? = nil) {
            if !current.items.isEmpty { shelves.append(current) }
            current = Shelf(title: title, items: [], top: e.flatMap { Self.position($0)?.y })
        }
        func pressable(_ e: AXUIElement) -> Bool {
            var acts: CFArray?
            AXUIElementCopyActionNames(e, &acts)
            return ((acts as? [String]) ?? []).contains("AXPress")
        }
        func addLeaf(_ e: AXUIElement, role: String, desc: String, title: String) -> Bool {
            if ["AXButton", "AXLink", "AXRadioButton", "AXCheckBox", "AXPopUpButton", "AXMenuButton", "AXCell"].contains(role) {
                let label = tidy(desc.isEmpty ? (title.isEmpty ? ElementMatcher.text(of: e) : title) : desc)
                if !label.isEmpty, !label.hasSuffix("Chevron") { current.items.append(Item(label: label, element: e, press: e)) }
                return true
            }
            if role == "AXStaticText" || role == "AXGenericElement" {
                let v = e.string(kAXValueAttribute) ?? ""
                let t = role == "AXStaticText" && !v.isEmpty ? v : desc   // TV's texts carry their words as a description
                if !t.trimmingCharacters(in: .whitespaces).isEmpty { current.items.append(Item(label: tidy(t), element: e, press: pressable(e) ? e : nil)) }
                return true
            }
            if role == "AXImage" {
                // The value read once: Music reuses elements as it scrolls, and a second read could be nil (code review, 20 Oct 2026).
                let value = e.attr(kAXValueAttribute).map { "\($0)" } ?? ""
                if pressable(e), !desc.isEmpty || !value.isEmpty {
                    current.items.append(Item(label: desc.isEmpty ? value : desc, element: e, press: e))
                }
                return true
            }
            if role == "AXGroup", pressable(e), !desc.isEmpty, e.elements(kAXChildrenAttribute).isEmpty {
                current.items.append(Item(label: desc, element: e, press: e)); return true
            }
            return false
        }
        func walk(_ e: AXUIElement, depth: Int) {
            visited += 1
            guard visited < Self.windowWalkLimit, depth < 40 else { return }
            if skipping.contains(where: { $0.isSame(e) }) { return }
            let role = e.role, sub = e.string(kAXSubroleAttribute) ?? "", id = e.string(kAXIdentifierAttribute) ?? ""
            if ["AXScrollBar", "AXSplitter", "AXValueIndicator", "AXToolbar", "AXMenuBar"].contains(role) { return }
            if ["AXCloseButton", "AXZoomButton", "AXMinimizeButton", "AXFullScreenButton"].contains(sub) { return }
            if id.lowercased().contains("account") { return }   // the account button is not part of the page
            let desc = e.string(kAXDescriptionAttribute) ?? "", title = e.string(kAXTitleAttribute) ?? ""
            // A shelf begins.
            if role == "AXHeading" { startShelf(desc.isEmpty ? (title.isEmpty ? ElementMatcher.text(of: e) : title) : desc, at: e); return }
            if id.contains("shelf.header") {
                // Music: the header is itself a button carrying the shelf's name; Podcasts: a group with the button inside.
                let own = [desc, title].first { !$0.isEmpty }
                let t = own ?? e.elements(kAXChildrenAttribute).compactMap { $0.string(kAXDescriptionAttribute) ?? $0.string(kAXTitleAttribute) }.first { !$0.isEmpty } ?? ElementMatcher.text(of: e)
                startShelf(t, at: e)
                return
            }
            if role == "AXList", sub == "AXSectionList" {
                startShelf(desc, at: e)
                let kids = e.elements(kAXChildrenAttribute)
                for c in kids { walk(c, depth: depth + 1) }
                // TV: a carousel holds only the cells near the screen; the rest follow by AXNextContentSibling.
                var next = kids.last?.element("AXNextContentSibling")
                var n = 0
                // (Not one already read: a show's header cell names itself as the next.)
                var seenCells = kids
                while let c = next, n < 80, (c.string(kAXIdentifierAttribute) ?? "").hasPrefix("UIA.TV.Cell"), !seenCells.contains(where: { CFEqual($0, c) }) {
                    seenCells.append(c)
                    walk(c, depth: depth + 1)
                    next = c.element("AXNextContentSibling"); n += 1
                }
                return
            }
            // A TV cell: its button holds the words ("Example Show, New Movie 16 Oct, Apple Tv Logo, Context Menu"). A cell
            // far along a carousel has none until it is shown; it is kept, and read when it is reached.
            // TV's page header (a show's: Play Episode, Remove from Watchlist) is a cell with real buttons in it.
            if id.hasPrefix("UIA.TV.Cell"), first(in: e, depth: 6, where: { ($0.string(kAXIdentifierAttribute) ?? "").hasPrefix("UIA.TV.Button") }) != nil {
                current.items.append(contentsOf: splitHeader(e)); return
            }
            if id.hasPrefix("UIA.TV.Cell") {
                var it = item(e)
                if it.press == nil { it.press = first(in: e, depth: 4) { $0.role == "AXButton" && pressable($0) } }
                if !it.label.isEmpty { current.items.append(it) }
                return
            }
            if id.contains("seeAll"), role == "AXButton" { current.items.append(Item(label: "See all", element: e, press: e)); return }
            // An item.
            // A page's header (Podcasts' show and episode headers): its words as one item, then each of its buttons
            // (Follow, Play, Download, Save) as an item of its own, so they can be reached and pressed.
            if id.contains("shelfItem"), id.contains("Header") { current.items.append(contentsOf: splitHeader(e)); return }
            if id.contains("shelfItem"), !id.contains("SubComponent") { let it = item(e); if !it.label.isEmpty { current.items.append(it) }; return }
            if role == "AXTable" || (role == "AXOutline" && desc != "Sidebar") {
                startShelf(desc.isEmpty ? (title.isEmpty ? "List" : title) : desc)
                // Rows are read when they are reached, not now: reading every song took seconds.
                for row in e.elements(kAXRowsAttribute).prefix(20_000) {
                    current.items.append(Item(label: "", element: row, press: nil, tableRow: true))
                }
                return
            }
            if addLeaf(e, role: role, desc: desc, title: title) { return }
            for c in e.elements(kAXChildrenAttribute) { walk(c, depth: depth + 1) }
        }
        walk(window, depth: 0)
        if !current.items.isEmpty { shelves.append(current) }
        // The apps' own status lines are not items: Podcasts' "Refreshing content" was the first thing read on Home
        // every time; Music's "Loading Cloud Library…", "Updating artist artwork…".
        let status = try? NSRegularExpression(pattern: "^(Refreshing content|Content refreshed|Loading.*…|Updating.*…|Adding item to Library)$", options: .caseInsensitive)
        for i in shelves.indices {
            shelves[i].items.removeAll { it in
                // (Pressable or not: every Catalyst text can be pressed.)
                !it.tableRow && it.play == nil
                    && status?.firstMatch(in: it.label, range: NSRange(it.label.startIndex..., in: it.label)) != nil
            }
        }
        // A shelf's own name read again as its first item (TV's heading text).
        for i in shelves.indices where !shelves[i].title.isEmpty && shelves[i].items.first?.label == shelves[i].title && shelves[i].items.first?.press == nil {
            shelves[i].items.removeFirst()
        }
        return shelves.filter { !$0.items.isEmpty }
    }

    nonisolated private static func headerParts(_ e: AXUIElement) -> ([String], [AXUIElement]) {
        var words: [String] = []
        var buttons: [AXUIElement] = []
        func gather(_ x: AXUIElement, _ d: Int) {
            for c in x.elements(kAXChildrenAttribute) {
                let r = c.role
                if r == "AXButton" { buttons.append(c); continue }
                if r == "AXStaticText" || r == "AXHeading" || r == "AXTextArea" {
                    if let t = [c.string(kAXDescriptionAttribute), c.string(kAXValueAttribute)].compactMap({ $0 }).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty && $0 != "·" }) { words.append(t) }
                    continue
                }
                if d < 8 { gather(c, d + 1) }
            }
        }
        gather(e, 0)
        return (words, buttons)
    }

    /// A page's header: its words as one item, then each of its buttons (Follow, Play, Remove from Watchlist…)
    /// as an item of its own, so they can be reached and pressed.
    nonisolated private static func splitHeader(_ e: AXUIElement) -> [Item] {
        var items: [Item] = []
        let (words, buttons) = headerParts(e)
        if !words.isEmpty { items.append(Item(label: tidy(words.joined(separator: ", ")), element: e, press: nil)) }
        for b in buttons {
            let t = b.string(kAXDescriptionAttribute) ?? b.string(kAXTitleAttribute) ?? (b.attr(kAXValueAttribute) as? String) ?? ""
            guard !t.isEmpty, t.uppercased() != "MORE" else { continue }
            var it = Item(label: tidy(t) + ", button", element: b, press: b)
            if t.hasPrefix("Play") { it.play = b }
            items.append(it)
        }
        return items
    }

    nonisolated static func position(_ e: AXUIElement) -> CGPoint? {
        guard let v = e.attr(kAXPositionAttribute), CFGetTypeID(v as CFTypeRef) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return axValue(v, .cgPoint, &p) ? p : nil
    }

    nonisolated static func first(in e: AXUIElement, depth: Int, where test: (AXUIElement) -> Bool) -> AXUIElement? {
        for c in e.elements(kAXChildrenAttribute) {
            if test(c) { return c }
            if depth > 1, let f = first(in: c, depth: depth - 1, where: test) { return f }
        }
        return nil
    }

    /// Words that only get in the way: TV names each item's context menu and the Apple TV logo.
    nonisolated public static func tidy(_ label: String) -> String {
        // Podcasts separates details with middle dots ("Show · Example Podcast"), which were read as "middle dot".
        let label = label.replacingOccurrences(of: "\\s*[·•]\\s*", with: ", ", options: .regularExpression)
        let junk: Set<String> = ["Context Menu", "Apple Tv Logo", "Apple TV Logo"]
        let parts = label.components(separatedBy: ", ").filter { !junk.contains($0) }
        return parts.joined(separator: ", ")
    }

    /// One shelf item, its parts read as one line: "Example Podcast, 1d ago, Episode Title…, Remaining Time: 15 Minutes".
    nonisolated static func item(_ e: AXUIElement) -> Item {
        var parts: [String] = []
        var press: AXUIElement?
        var play: AXUIElement?
        var playAction = kAXPressAction as String
        var acts: CFArray?
        AXUIElementCopyActionNames(e, &acts)
        if ((acts as? [String]) ?? []).contains("AXPress") { press = e }
        /// A custom "Play" action on the element: play with it, and say how long is left.
        func customPlay(_ x: AXUIElement, _ names: [String]) {
            guard play == nil, let a = names.first(where: { $0.hasPrefix("Name:Play") }) else { return }
            play = x; playAction = a
            playWords = String((a.components(separatedBy: "\n").first ?? "").dropFirst(5))   // "Play, Remaining Time: 1 minute"
        }
        var playWords = ""
        var firstButton: AXUIElement?
        customPlay(e, (acts as? [String]) ?? [])
        func add(_ s: String?) {
            guard var t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return }
            if ["Podcast Artwork", "Artwork"].contains(t) { return }
            if t.hasPrefix("Play, ") { t = String(t.dropFirst(6)) } else if t == "Play" { return }
            if !parts.contains(t) { parts.append(t) }
        }
        add(e.string(kAXDescriptionAttribute))
        add(e.string(kAXTitleAttribute))
        func walk(_ x: AXUIElement, _ depth: Int) {
            guard depth < 8 else { return }
            for c in x.elements(kAXChildrenAttribute) {
                let r = c.role
                var a: CFArray?
                AXUIElementCopyActionNames(c, &a)
                let canPress = ((a as? [String]) ?? []).contains("AXPress")
                customPlay(c, (a as? [String]) ?? [])
                if r == "AXButton", let d = c.string(kAXDescriptionAttribute) ?? c.string(kAXTitleAttribute), d.hasPrefix("Play") || d.hasPrefix("Replay") || d.hasPrefix("Resume") { play = c; add(d); continue }
                if r == "AXImage" { add((c.attr(kAXValueAttribute) as? String) ?? c.string(kAXDescriptionAttribute)); if press == nil, canPress { press = c }; continue }
                // (An empty value is no value: Podcasts' search results keep their words in the description, and
                // were read as just "Explicit", 7 Oct 2026.)
                // Both, description first: an episode's words are its description and "Explicit" its value.
                if r == "AXStaticText" { add(c.string(kAXDescriptionAttribute)); add(c.string(kAXValueAttribute)); continue }
                if r == "AXGenericElement" || r == "AXButton" {
                    add(c.string(kAXDescriptionAttribute) ?? c.string(kAXTitleAttribute))
                    if press == nil, canPress, r != "AXButton" { press = c }
                    if firstButton == nil, canPress, r == "AXButton" { firstButton = c }
                    continue
                }
                walk(c, depth + 1)
            }
        }
        walk(e, 0)
        // An item that is just a button (a show in Podcasts' search results): pressing it opens it ("nothing to open").
        if press == nil { press = firstButton }
        add(playWords)   // how long is left, after the title
        var it = Item(label: tidy(parts.joined(separator: ", ")), element: e, press: press, play: play)
        it.playAction = playAction
        return it
    }

    // MARK: Moving

    func items(of p: Pane) -> [Item] {
        switch p { case .sidebar: return sidebar; case .page: return flatPage.map(\.item); case .player: return player; case .toolbar: return toolbar }
    }

    /// An item's words; a table row's are read the first time it is reached.
    private var rowLabels: [Int: String] = [:]
    func label(_ item: Item, at i: Int) -> String {
        if !item.tableRow, item.label.isEmpty {
            // A TV cell far along its carousel: shown, then read.
            if let l = rowLabels[i] { return l }
            var l = Self.item(item.element).label
            if l.isEmpty {
                _ = AXUIElementPerformAction(item.element, "AXScrollToVisible" as CFString)
                l = Self.item(item.element).label
            }
            if !l.isEmpty { rowLabels[i] = l }
            return l.isEmpty ? "item not loaded yet" : l
        }
        guard item.tableRow, item.label.isEmpty else { return item.label }
        if let l = rowLabels[i] { return l }
        let l = Self.rowText(item.element).joined(separator: ", ")
        rowLabels[i] = l
        return l.isEmpty ? "blank" : l
    }

    /// A row's columns, in order: Music's song rows hold them as text fields ("Song Title",
    /// "3:36", "Artist", "Album", "Rock", "3 plays"); other tables as static text in cells.
    static func rowText(_ row: AXUIElement, limit: Int = 12) -> [String] {
        var out: [String] = []
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard out.count < limit, depth < 4 else { return }
            for c in e.elements(kAXChildrenAttribute) {
                switch c.role {
                case "AXStaticText", "AXTextField":
                    if let v = c.string(kAXValueAttribute)?.trimmingCharacters(in: .whitespaces), !v.isEmpty { out.append(v) }
                case "AXButton", "AXCheckBox": continue   // "More", "not loved"
                default: walk(c, depth + 1)
                }
            }
        }
        walk(row, 0)
        return out
    }
    func currentItem() -> Item? {
        let all = items(of: pane)
        guard !all.isEmpty else { return nil }
        return all[max(0, min(all.count - 1, index[pane] ?? 0))]
    }

    public func move(_ delta: Int) {
        if let c = catalog, catalogDrives, pane == .page { c.move(delta); return }
        guard rebuildOrQueue(waitForLoading: true, retry: { [weak self] in self?.move(delta) }) else { return }
        let all = items(of: pane)
        guard !all.isEmpty else { Speech.speakMessage(pane == .page ? "nothing on this page yet" : "empty"); return }
        let old = max(0, min(all.count - 1, index[pane] ?? 0))
        let new = old + delta
        guard all.indices.contains(new) else {
            if pane == .page, delta > 0 { loadMore(then: { [weak self] in self?.move(delta) }) } else { Tones.edge() }
            return
        }
        index[pane] = new
        announce(crossedFrom: old)
    }

    /// Music and TV show a page's later shelves only as it scrolls: at the end of what is known, scroll on by most
    /// of a screen, read what came into view and add it; the edge sound only when nothing more comes.
    /// Measured 7 Oct 2026: Music's page has a scroll bar whose value can be set (0 to 1), though "scroll down by
    /// page" fails and the wheel does nothing; it keeps only the shelves near the screen, so the model keeps the
    /// rest. TV keeps every shelf once loaded, and its bar's value drops as the page grows.
    private var loadingMore = false
    /// Arrows pressed while more of the page was loading, answered in turn once it has.
    private var queued: [() -> Void] = []
    private func rebuildOrQueue(waitForLoading: Bool = false, retry: @escaping () -> Void) -> Bool {
        if (waitForLoading && loadingMore) || !rebuild() {
            queued.append(retry)
            return false
        }
        return true
    }

    private func runQueued() {
        let q = queued
        queued = []
        q.forEach { $0() }
    }

    /// Music's video player is up (opened from the page): the app has the keys until it closes.
    public var inVideo = false
    private func loadMore(attempts: Int = 3, then: @escaping () -> Void, nothing: (() -> Void)? = nil) {
        let none = nothing ?? { Tones.edge() }
        // A key while more is loading: that load answers it (an edge sound here was wrong, 7 Oct 2026).
        if loadingMore { return }
        guard let scroll = pageScroll else {
            Log.io("media: no more to load (scroll area \(pageScroll != nil), loading \(loadingMore))")
            none(); return
        }
        let countBefore = flatPage.count
        var scrolled = false
        if let bar = scroll.element(kAXVerticalScrollBarAttribute), let cur = (bar.attr(kAXValueAttribute) as? NSNumber)?.doubleValue {
            var step = 0.2
            if let size = Self.cgSize(scroll, kAXSizeAttribute), let content = Self.cgSize(scroll, "AXContentSize"), content.height > size.height {
                // Music keeps the shelves a screen or two either side (at quarter steps through Radio's 15 shelves,
                // none was missed): a screen and a half at a time. TV keeps few beyond the screen: most of a screen.
                let screens = (scroll.string(kAXIdentifierAttribute) ?? "").hasPrefix("Music.") ? 1.5 : 0.8
                step = max(0.03, screens * size.height / (content.height - size.height))
            }
            if cur < 0.999 { scrolled = bar.set(kAXValueAttribute, NSNumber(value: min(1.0, cur + step))) == .success }
            Log.io("media: scrolling the page from \(String(format: "%.2f", cur)) by \(String(format: "%.2f", step)) → \(scrolled)")
        } else {
            var acts: CFArray?
            AXUIElementCopyActionNames(scroll, &acts)
            if ((acts as? [String]) ?? []).contains("AXScrollDownByPage") {
                for _ in 0..<3 { scrolled = AXUIElementPerformAction(scroll, "AXScrollDownByPage" as CFString) == .success || scrolled }
            }
            Log.io("media: scrolling the page by its action → \(scrolled)")
        }
        if !scrolled { loadingMore = false; none(); return }
        loadingMore = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refresh(keepSidebar: true) { [weak self] in
                guard let self else { return }
                loadingMore = false
                if flatPage.count > countBefore { then() }
                // A step that showed only shelves already known: on, while the page still scrolls.
                else if attempts > 1 { loadMore(attempts: attempts - 1, then: then, nothing: nothing); return }
                else { none() }
                runQueued()
            }
        }
    }

    /// Music's video player fills the window (an interview opened from Radio, 7 Oct 2026): its own buttons, and Escape
    /// to leave it, are the app's, not the media view's.
    nonisolated public static func showsVideo(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let w = app.element(kAXFocusedWindowAttribute) else { return false }
        return first(in: w, depth: 3) { $0.string(kAXIdentifierAttribute) == "Toggle Controls" } != nil
    }

    nonisolated static func cgSize(_ e: AXUIElement, _ name: String) -> CGSize? {
        guard let v = e.attr(name), CFGetTypeID(v as CFTypeRef) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return axValue(v, .cgSize, &s) ? s : nil
    }

    /// Every shelf of the page, scrolling to the bottom (End).
    private func loadAll(rounds: Int = 25, then: @escaping () -> Void) {
        guard rounds > 0 else { then(); return }
        loadMore(then: { [weak self] in self?.loadAll(rounds: rounds - 1, then: then) }, nothing: then)
    }

    public func toEnd(_ last: Bool) {
        if let c = catalog, catalogDrives, pane == .page { c.toEnd(last); return }
        guard rebuildOrQueue(retry: { [weak self] in self?.toEnd(last) }) else { return }
        if last, pane == .page, pageScroll != nil, !loadingMore {
            let t = Date()
            var done = false
            // Reading to the bottom of a long page takes a few seconds: say so, rather than silence.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { if !done { Speech.speakMessage("reading the whole page", remember: false) } }
            loadAll { [weak self] in
                done = true
                Log.io("media: End loaded \(self?.shelves.count ?? 0) shelves in \(String(format: "%.1f", Date().timeIntervalSince(t))) s")
                self?.goToEnd(true); self?.onEnd?()
            }
            return
        }
        goToEnd(last)
    }

    /// For the test tool: End has finished loading.
    public var onEnd: (() -> Void)?

    private func goToEnd(_ last: Bool) {
        let all = items(of: pane)
        guard !all.isEmpty else { return }
        let old = index[pane] ?? 0
        index[pane] = last ? all.count - 1 : 0
        announce(crossedFrom: old)
    }

    /// The previous or next shelf of the page (in the sidebar, the previous or next group heading).
    public func jumpShelf(_ delta: Int) {
        guard rebuildOrQueue(waitForLoading: true, retry: { [weak self] in self?.jumpShelf(delta) }) else { return }
        if pane != .page { move(delta * 5); return }
        let flat = flatPage
        guard !flat.isEmpty else { return }
        let cur = max(0, min(flat.count - 1, index[.page] ?? 0))
        let shelf = flat[cur].shelf + delta
        guard shelves.indices.contains(shelf), let first = flat.firstIndex(where: { $0.shelf == shelf }) else {
            if delta > 0 { loadMore(then: { [weak self] in self?.jumpShelf(delta) }) } else { Tones.edge() }
            return
        }
        let old = cur
        index[.page] = first
        announce(crossedFrom: old, forceShelf: true)
    }

    public func letter(_ ch: Character) {
        if let c = catalog, catalogDrives, pane == .page { c.letter(ch); return }
        guard rebuildOrQueue(retry: { [weak self] in self?.letter(ch) }) else { return }
        let all = items(of: pane)
        guard !all.isEmpty else { return }
        let cur = min(index[pane] ?? 0, all.count - 1)   // (a stale index past a shorter page made an invalid range, 8 Oct 2026)
        let lower = String(ch).lowercased()
        let order = Array((cur + 1)..<all.count) + Array(0...cur)
        // A table row is matched by its first column (a song's title) alone: reading whole rows of a library is slow.
        func key(_ j: Int) -> String { all[j].tableRow && all[j].label.isEmpty ? (Self.rowText(all[j].element, limit: 1).first ?? "") : all[j].label }
        guard let hit = order.prefix(5000).first(where: { key($0).lowercased().hasPrefix(lower) }) else { Tones.edge(); return }
        let old = cur
        index[pane] = hit
        announce(crossedFrom: old)
    }

    public func switchPane(_ delta: Int) {
        guard rebuildOrQueue(retry: { [weak self] in self?.switchPane(delta) }) else { return }
        var p = pane.rawValue
        for _ in 0..<Self.paneCount {
            p = (p + delta + Self.paneCount) % Self.paneCount
            if !items(of: Pane(rawValue: p)!).isEmpty { break }
        }
        pane = Pane(rawValue: p)!
        if pane == .sidebar, index[.sidebar] == nil, let sel = sidebar.firstIndex(where: { $0.selected }) { index[.sidebar] = sel }
        if index[pane] == nil { index[pane] = 0 }
        let name: String
        switch pane { case .sidebar: name = "sidebar"; case .page: name = pageTitle.isEmpty ? "page" : "\(pageTitle) page"; case .player: name = "player"; case .toolbar: name = "tool bar" }
        Speech.speakOnly(name)   // the area's name: the display shows its item
        announce(crossedFrom: -1, forceShelf: pane == .page)
    }

    private func announce(crossedFrom old: Int, forceShelf: Bool = false) {
        let all = items(of: pane)
        guard let i = index[pane], all.indices.contains(i) else { return }
        let item = all[i]
        var parts: [String] = []
        if pane == .page {
            let flat = flatPage
            let s = flat[i].shelf
            let inShelf = flat.filter { $0.shelf == s }
            let pos = (flat[..<i].filter { $0.shelf == s }.count) + 1
            if forceShelf || old < 0 || !flat.indices.contains(old) || flat[old].shelf != s {
                let title = shelves[s].title
                if !title.isEmpty { parts.append("\(title), \(inShelf.count) item\(inShelf.count == 1 ? "" : "s")") }
            }
            parts.append(label(item, at: i))
            parts.append("\(pos) of \(inShelf.count)")
        } else {
            parts.append(item.label)
            if item.isHeader { parts.append("heading") }
            if item.selected { parts.append("selected") }
            parts.append("\(i + 1) of \(all.count)")
        }
        Speech.speakItem(parts.joined(separator: ", "), processed: true)
        Hints.schedule(hint(for: item))
    }

    private func hint(for item: Item) -> String {
        switch pane {
        case .sidebar: return item.isHeader ? "Down moves to its places." : "Return goes there; Tab moves to the page."
        case .player: return "Return presses it; Space plays and pauses. Tab moves on."
        case .toolbar: return "Return presses it. Tab moves to the sidebar."
        case .page:
            if item.play != nil { return "Return plays it; Shift Return opens its page. Left and Right move between shelves." }
            if item.press != nil || item.tableRow { return "Return opens it. Left and Right move between shelves; Tab moves to the sidebar and player." }
            return "Left and Right move between shelves; Tab moves to the sidebar and player."
        }
    }

    // MARK: Acting

    /// Enter: play the item when it has its own Play button (a Podcasts episode); otherwise open it (or, in the
    /// sidebar, go to the section), then read the new page. `openOnly` (Shift+Enter) always opens.
    public func activate(openOnly: Bool = false) {
        if let c = catalog, catalogDrives, pane == .page { c.openCurrent(); return }
        guard rebuildOrQueue(retry: { [weak self] in self?.activate(openOnly: openOnly) }) else { return }
        guard let item = currentItem() else { return }
        whenCurrent(item) { [weak self] in self?.press($0, openOnly: openOnly) }
    }

    /// The item with an element that still shows it. Music drops and reuses its items' elements as the page scrolls
    /// (as the App Store does), so one read before scrolling on may be gone, or now show another item: pressing it
    /// would open the wrong thing. Such an item is found again by scrolling back to where it was read.
    private func whenCurrent(_ item: Item, _ go: @escaping @MainActor (Item) -> Void) {
        if pane != .page || item.tableRow || isCurrent(item) { go(item); return }
        Log.io("media: \(Log.words(String(item.label.prefix(40)))) has scrolled away; finding it again")
        let bar = pageScroll?.element(kAXVerticalScrollBarAttribute)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var found: Item?
            var last: Built?
            let places = [item.scrollValue].compactMap { $0 } + Array(stride(from: 0.0, through: 1.0, by: 0.15))
            for v in places {
                if let bar { _ = bar.set(kAXValueAttribute, NSNumber(value: v)); usleep(450_000) }
                guard let b = build(keepSidebar: true) else { break }
                last = b
                if let f = b.shelves.lazy.flatMap(\.items).first(where: { $0.key == item.key }) { found = f; break }
                if bar == nil { break }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let last { apply(last) }
                if let found { go(found) } else { Speech.speakMessage("cannot find that item on the page now") }
            }
        }
    }

    private func isCurrent(_ item: Item) -> Bool {
        if item.ident.isEmpty && item.desc.isEmpty { return true }   // nothing to tell it by: as read
        let e = item.element
        guard (e.string(kAXIdentifierAttribute) ?? "") == item.ident, (e.string(kAXDescriptionAttribute) ?? "") == item.desc else { return false }
        // Music's identifiers name the item ("[id=ra.6812860223,…]"); others (TV's cells) are shared by a shelf's
        // items, so the words are compared too.
        if item.ident.contains("id=") { return true }
        return item.ident.contains("shelfItem") ? Self.item(e).label == item.label : true
    }

    private func press(_ item: Item, openOnly: Bool) {
        if !openOnly, pane == .page, let play = item.play {
            let r = AXUIElementPerformAction(play, item.playAction as CFString)
            Log.io("media: play \(Log.words(String(item.label.prefix(50)))) → \(r.rawValue)")
            let title = item.label.components(separatedBy: ", ").prefix(2).joined(separator: ", ")
            Speech.speakText("playing, " + title)
            confirmPlaying()
            return
        }
        let before = signature()
        if pane == .page { places[pageKey()] = item.key }
        if pane == .sidebar, item.press == nil, let outline = item.element.element(kAXParentAttribute) {
            _ = outline.set(kAXSelectedRowsAttribute, [item.element] as CFArray)
        } else if item.tableRow, let table = item.element.element(kAXParentAttribute) {
            _ = table.set(kAXFocusedAttribute, kCFBooleanTrue)
            _ = table.set(kAXSelectedRowsAttribute, [item.element] as CFArray)
            KeyboardGesture(identifier: "kb:enter")?.send()   // Music plays the selected song on Return
            // Said, as for a Play button (Return on a song in the library was silent, 8 Oct 2026), and checked.
            Speech.speakMessage("playing", remember: false)
            confirmPlaying()
            return
        } else if let target = item.press ?? (item.playAction == kAXPressAction as String ? item.play : nil) {
            let r = AXUIElementPerformAction(target, kAXPressAction as CFString)
            Log.io("media: press \(Log.words(String(item.label.prefix(50)))) → \(r.rawValue)")
        } else {
            Speech.speakMessage("nothing to open"); return
        }
        if pane == .player { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refreshPlayer(); self?.announce(crossedFrom: -2) }; return }
        nowPlayingBefore = playingText()
        waitForNewPage(different: before)
    }

    private func playerControlName(_ item: Item) -> String {
        item.label.components(separatedBy: ",").first ?? ""
    }

    private func isPlaybackToggle(_ item: Item) -> Bool {
        ["Play", "Pause", "Stop", "play", "pause", "stop"].contains(playerControlName(item))
    }

    /// Space: play the item when it can be played; otherwise the app's own play and pause.
    public func playOrPause(_ g: KeyboardGesture) {
        guard rebuildOrQueue(retry: { [weak self] in self?.playOrPause(g) }) else { return }
        // Something already playing: Space pauses it, whatever the cursor is on. On an episode row it pressed the
        // row's own Play again and said "playing" while nothing changed (Podcasts, 28 Oct 2026); the player's Pause
        // was only reached from the player pane.
        refreshPlayer()
        let playerPlaying = (playerRoot?.string(kAXIdentifierAttribute) ?? "").contains("isPlaying=true")
            || player.contains { ["pause", "stop"].contains(playerControlName($0).lowercased()) }
        if pane == .page, !playerPlaying, let item = currentItem(), item.play != nil {
            whenCurrent(item) { found in
                guard let play = found.play else { return }
                _ = AXUIElementPerformAction(play, found.playAction as CFString)
                Speech.speakMessage("playing", remember: false)
            }
            return
        }
        // (Live radio has Stop where other things have Pause.)
        if let toggle = player.first(where: isPlaybackToggle) {
            let r = AXUIElementPerformAction(toggle.element, kAXPressAction as CFString)
            Log.io("media: play/pause \(Log.words(toggle.label)) → \(r.rawValue)")
            // Say what was pressed: Music takes a moment to change its button, and reading it straight away said
            // "paused" as playback started (7 Oct 2026). Checked again after, and corrected only if it differs.
            let pressedPlay = playerControlName(toggle).lowercased() == "play"
            let pressedStop = playerControlName(toggle).lowercased() == "stop"
            Speech.speakMessage(pressedPlay ? "playing" : pressedStop ? "stopped" : "paused", remember: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self else { return }
                refreshPlayer()
                let now = player.first(where: isPlaybackToggle).map { playerControlName($0).lowercased() } ?? ""
                let playing = now == "pause" || now == "stop"
                if !now.isEmpty, playing != pressedPlay { Speech.speakMessage(playing ? "playing" : "paused", remember: false) }
            }
            return
        }
        Log.io("media: no play/pause in the player (\(Log.words(String(describing: player.map(\.label).prefix(4))))); Space to the app")
        g.send()
    }

    /// Return in the app's search field: the search runs; when the results replace the page, read them, and the
    /// arrows are the page's again (Music and Podcasts said nothing, and the first Down read the old page).
    public func afterSearch(term: String = "") {
        let before = signature()
        pane = .page
        catalogSearch(term: term)
        waitForNewPage(different: before, tries: Self.searchPageTries, focusPage: true)
    }

    // MARK: The catalog (developer switch `flatView`; Catalog.swift)

    /// The catalog's answers for the latest search: the page's host while its results are up, instead of the
    /// app's own results page.
    private var catalog: Catalog?
    /// The catalog's list has the keys (the module gives it the arrows even while the search field has the focus).
    public private(set) var catalogDrives = false
    /// The term the catalog's list answers, while it has the keys.
    public var catalogTerm: String? { catalogDrives ? catalog?.term : nil }
    /// The page just asked for by name: its title is not said again when it comes.
    private var openingTitle = ""

    private func catalogSearch(term raw: String) {
        guard Edition.devDefault("flatView"), let kind = Catalog.kind(for: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier) else { return }
        let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { Log.io("catalog: no term to search for"); return }
        catalog?.cancel()
        let c = Catalog(kind: kind, term: term, open: { [weak self] e in self?.openCatalogEntry(e) },
                        fallBack: { [weak self] why in
                            guard let self else { return }
                            if why != "nothing found" { Speech.speakMessage("The catalog did not answer: \(why). Reading the page.") }
                            catalog = nil; catalogDrives = false
                            // The page may already be up and unspoken: read it now.
                            let flat = flatPage
                            if !flat.isEmpty { Speech.speakMessage(pageTitle.isEmpty ? "page" : pageTitle); land(on: nil) }
                        })
        catalog = c; catalogDrives = true
        c.search()
    }
    private func openCatalogEntry(_ e: Catalog.Entry) {
        let before = signature()
        catalogDrives = false
        NSWorkspace.shared.open(e.url)
        Log.io("catalog: opening \"\(Log.words(e.name.prefix(40).description))\"")
        Speech.speakMessage("Opening \(e.name)")
        openingTitle = e.name
        waitForNewPage(different: before, tries: Self.searchPageTries)
    }
    /// Escape from an opened entry lands on the results page again: the catalog's list is back.
    private func catalogBack() { if catalog != nil { catalogDrives = true } }

    /// Escape: back a page.
    public func back() {
        let before = signature()
        catalogBack()
        let app = AXUIElementCreateApplication(pid)
        // Podcasts: a Back button in the toolbar. Music and TV: Controls > Back (Command+[), disabled at the top.
        if let window = app.element(kAXFocusedWindowAttribute),
           let backButton = window.elements(kAXChildrenAttribute).first(where: { $0.role == "AXToolbar" })?.elements(kAXChildrenAttribute)
               .first(where: { $0.string(kAXDescriptionAttribute) == "Back" || $0.string(kAXIdentifierAttribute) == "BackButton" }) {
            if (backButton.attr(kAXEnabledAttribute) as? Bool) == false { Speech.speakMessage("no previous page", remember: false); return }
            _ = AXUIElementPerformAction(backButton, kAXPressAction as CFString)
        } else if let item = MenuPath.find(["Controls", "Back"], pid: pid) ?? MenuPath.find(["Go", "Back"], pid: pid) {
            if (item.attr(kAXEnabledAttribute) as? Bool) == false { Speech.speakMessage("no previous page", remember: false); return }
            _ = AXUIElementPerformAction(item, kAXPressAction as CFString)
        } else {
            KeyboardGesture(identifier: "kb:command+[")?.send()
        }
        waitForNewPage(different: before, tries: 5, goingBack: true)
    }

    /// After asking to play: make sure it did. A subscribers-only episode in Podcasts said "playing" and stayed
    /// silent (7 Oct 2026). The player says whether it plays (Podcasts' "…isPlaying=true", or a Pause button).
    private func confirmPlaying() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            refreshPlayer()
            let playing = (playerRoot?.string(kAXIdentifierAttribute) ?? "").contains("isPlaying=true")
                || player.contains { playerControlName($0).lowercased() == "pause" }
            if !playing {
                Log.io("media: asked to play, but the player is not playing")
                Speech.speakMessage("not playing; it may need a subscription or a download")
            }
        }
    }

    private var nowPlayingBefore = ""
    /// What the player's information area says, or "" when nothing is playing.
    private func playingText() -> String {
        let t = player.first { $0.press == nil }?.label ?? ""
        return t == "Nothing playing" ? "" : t
    }

    public func nowPlaying() {
        if playerRoot == nil { rebuild(force: true) } else { refreshPlayer() }
        Speech.speakText(player.first { $0.press == nil }?.label ?? "nothing playing")
    }

    /// Where the user was on each page, so Back lands on the item that was opened.
    /// (The item's key, not its place in the list: the page is read again from the top when it comes back, and the
    /// item may be further down than that first read reaches.)
    private var places: [String: String] = [:]
    private func pageKey() -> String { pageTitle + "|" + (shelves.first?.title ?? "") + "|" + (flatPage.first?.item.label.prefix(40).description ?? "") }

    private func signature() -> String { (shelves.first?.title ?? "") + "|" + (flatPage.first?.item.label ?? "") + "|" + pageTitle }
    private func signature(of b: Built) -> String { (b.shelves.first?.title ?? "") + "|" + (b.shelves.first?.items.first?.label ?? "") + "|" + b.pageTitle }

    /// On a page come back to: the item that was opened from it, reading further down the page until it is reached.
    private func land(on key: String?, rounds: Int = 12) {
        let flat = flatPage
        if let key, let i = flat.firstIndex(where: { $0.item.key == key }) {
            index[.page] = i
        } else if key != nil, rounds > 0, pageScroll != nil {
            loadMore(then: { [weak self] in self?.land(on: key, rounds: rounds - 1) },
                     nothing: { [weak self] in self?.land(on: nil) })
            return
        } else {
            index[.page] = 0
        }
        announce(crossedFrom: -1, forceShelf: true)
    }

    /// After a press: when the page has changed, read where it went (its title, first shelf and item).
    private func waitForNewPage(different before: String, tries: Int = 8, goingBack: Bool = false, focusPage: Bool = false) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
          // Read the window off the main thread, so keys pressed meanwhile are answered at once.
          DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if !goingBack, Self.showsVideo(pid: pid) {
                DispatchQueue.main.async { self.inVideo = true; Speech.speakMessage("video playing. Space plays and pauses; Escape leaves the video") }
                return
            }
            guard let built = build() else { return }
            DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // A page still loading (no shelves yet, 7 Oct 2026): wait for it, rather than read an empty page.
            if signature(of: built) == before || (built.shelves.isEmpty && tries > 0) {
                if tries > 0 { waitForNewPage(different: before, tries: tries - 1, goingBack: goingBack, focusPage: focusPage) }
                else if goingBack { Speech.speakMessage("no previous page", remember: false) }
                else {
                    // No new page: a song or episode that plays when opened. Say so, from the player.
                    refreshPlayer()
                    let now = playingText()
                    if !now.isEmpty, now != nowPlayingBefore { Speech.speakText("playing, " + now) }
                }
                return   // nothing changed (an item that only plays): nothing to say
            }
            apply(built)
            pane = .page
            // After a search the keyboard is still in the search field, where the arrows are the field's: give it to
            // the results, so Down reads them.
            if focusPage, let first = flatPage.first?.item.element {
                if first.set(kAXFocusedAttribute, kCFBooleanTrue) != .success { _ = pageScroll?.set(kAXFocusedAttribute, kCFBooleanTrue) }
            }
            // The catalog's list answered this search and is being read: the app's own results page stays unspoken.
            if focusPage, catalogDrives { return }
            let announced = openingTitle; openingTitle = ""
            if pageTitle != announced { Speech.speakMessage(pageTitle.isEmpty ? "page" : pageTitle) }
            land(on: places[pageKey()])
            }
          }
        }
    }
}


// (For the tests: in an extension, so the memberwise initialisers above stay.)
public extension MediaView.Item {
    nonisolated init(label: String, element: AXUIElement, ident: String = "", desc: String = "") {
        self.init(label: label, element: element, press: nil, play: nil, ident: ident, desc: desc)
    }
}
public extension MediaView.Shelf {
    nonisolated init(title: String, items: [MediaView.Item]) { self.init(title: title, items: items, top: nil) }
}
