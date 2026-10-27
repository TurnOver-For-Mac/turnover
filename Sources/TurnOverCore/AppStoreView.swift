// SPDX-License-Identifier: GPL-3.0-or-later
// The App Store's page and sidebar as TurnOver reads them (AppStoreAppModule has the keys and the story).
import Foundation
import AppKit
import ApplicationServices

public final class AppStoreView {
    nonisolated public enum Kind: Sendable { case heading, app, card, text, button, tab, search, account }
    nonisolated public struct Entry: Sendable {
        public var label: String
        public var element: AXUIElement
        public var kind: Kind
        public var shelf: Int
        var offer: AXUIElement?
        var section: AXUIElement?
        /// What the element showed when read: checked again before anything is pressed (rows are reused as the
        /// list scrolls, and a reused row is another app; a press meant for WhatsApp got another app's Get, 6 Oct 2026).
        var check = ""
        /// The app's button as it read when the item was made ("Get", "73.2% loaded"): replaced by the button as it
        /// is now whenever the item is read (14 Oct 2026: "73.2% loaded" was read long after Outlook installed).
        var offerTitle = ""
    }
    public enum Area { case sidebar, page }

    public let pid: pid_t
    var area: Area = .page
    // Read by the background loader while the main thread moves (as before Swift 6; a race the compiler now names).
    nonisolated(unsafe) public private(set) var page: [Entry] = []
    nonisolated(unsafe) public private(set) var shelves: [String] = []
    nonisolated(unsafe) private var sidebar: [Entry] = []
    private var pageIndex = 0, sideIndex = 0
    private var pageKey = ""
    private var pendingBuy: (AXUIElement, Date)?
    private var lastOpen: (String, Date)?

    nonisolated static func isDownloading(_ title: String) -> Bool {
        title.contains("%") || ["Loading", "Waiting", "Installing", "Preparing"].contains(where: { title.hasPrefix($0) })
    }

    /// Delete on an app that is downloading: cancels it (the only key that does).
    public func cancelDownload() {
        ensureCurrent()
        guard area == .page, page.indices.contains(pageIndex) else { Speech.speakMessage("nothing downloading here"); return }
        confirmed(pageIndex) { e in
            guard let e, let o = Self.first(in: e.element, depth: 5, where: { ($0.string(kAXIdentifierAttribute) ?? "").contains("offerButton") }) else { return }
            let title = o.string(kAXTitleAttribute) ?? o.string(kAXDescriptionAttribute) ?? ""
            guard Self.isDownloading(title) else { Speech.speakMessage("nothing downloading here"); return }
            _ = AXUIElementPerformAction(o, kAXPressAction as CFString)
            Log.io("app store: download cancelled with Delete")
            Speech.speakMessage("download cancelled")
        }
    }
    /// Counts the user's moves: a page change being waited for gives way to them (it reset the place to the top
    /// after the arrows had moved on, and Space found no button, 6 Oct 2026).
    private var moves = 0

    public init(pid: pid_t) { self.pid = pid }

    public static func hasSheet(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        return app.elements(kAXWindowsAttribute).contains { w in w.role == "AXSheet" || w.elements(kAXChildrenAttribute).contains { $0.role == "AXSheet" } }
    }

    nonisolated private var app: AXUIElement { AXUIElementCreateApplication(pid) }
    nonisolated private var window: AXUIElement? { app.element(kAXFocusedWindowAttribute) ?? app.element(kAXMainWindowAttribute) }

    // MARK: Reading the window

    /// The page's collection (AXCollectionList) and the scroll area holding it.
    nonisolated private func pageRoot() -> (scroll: AXUIElement, list: AXUIElement)? {
        guard let w = window else { return nil }
        // A card over the whole window (a category such as Arcade's Family: AppStore.productPage.pageBaseCardView
        // beside its own scroll area, and no sidebar): its page is the window's own scroll area.
        if w.elements(kAXChildrenAttribute).contains(where: { ($0.string(kAXIdentifierAttribute) ?? "").hasSuffix("pageBaseCardView") }),
           let s = w.elements(kAXChildrenAttribute).first(where: { $0.role == "AXScrollArea" }),
           let list = Self.first(in: s, depth: 4, where: { $0.role == "AXList" && $0.string(kAXSubroleAttribute) == "AXCollectionList" }) { return (s, list) }
        guard let split = w.elements(kAXChildrenAttribute).first(where: { $0.role == "AXSplitGroup" }) else { return nil }
        // The page's container is an AXScrollArea, or (seen after a relaunch, 6 Oct 2026) an AXGroup with the
        // scroll actions; the sidebar is a group of its own, or its parts sit loose beside the page.
        for s in split.elements(kAXChildrenAttribute) where s.role == "AXScrollArea" || s.role == "AXGroup" {
            if let list = Self.first(in: s, depth: 4, where: { $0.role == "AXList" && $0.string(kAXSubroleAttribute) == "AXCollectionList" }) { return (s, list) }
        }
        // No collection: a page of its own ("Cannot Connect … Retry", AppStore.error), read as it is.
        for s in split.elements(kAXChildrenAttribute) where s.role == "AXScrollArea" || s.role == "AXGroup" {
            if let area = Self.first(in: s, depth: 2, where: { $0.role == "AXScrollArea" && (($0.string(kAXIdentifierAttribute) ?? "").hasPrefix("AppStore.") || !$0.elements(kAXChildrenAttribute).isEmpty) }) { return (area, area) }
        }
        return nil
    }

    nonisolated static func first(in e: AXUIElement, depth: Int, where test: (AXUIElement) -> Bool) -> AXUIElement? {
        if test(e) { return e }
        guard depth > 0 else { return nil }
        for c in e.elements(kAXChildrenAttribute) { if let f = first(in: c, depth: depth - 1, where: test) { return f } }
        return nil
    }

    nonisolated private static func same(_ a: AXUIElement, _ b: AXUIElement) -> Bool { CFEqual(a, b) }

    /// Whether an element is inside another (a shelf's heading is inside the page's collection; the page's own
    /// heading is above it).
    static func isInside(_ e: AXUIElement, _ container: AXUIElement) -> Bool {
        var p = e.element(kAXParentAttribute); var n = 0
        while let x = p, n < 30 { if CFEqual(x, container) { return true }; p = x.element(kAXParentAttribute); n += 1 }
        return false
    }

    /// What identifies the page: the collection element itself, its identifier and its name ("Results for …").
    /// Nothing that scrolling changes: a heading in view did, and every key read the whole page again (6 Oct 2026).
    private func currentKey() -> String {
        guard let (_, list) = pageRoot() else { return "" }
        return "\(CFHash(list))|\(list.string(kAXIdentifierAttribute) ?? "")|\(list.string(kAXDescriptionAttribute) ?? "")"
    }

    /// The card over the window, if one is showing (its description names it: "Family, APPLE ARCADE").
    private var card: AXUIElement? { window?.elements(kAXChildrenAttribute).first { ($0.string(kAXIdentifierAttribute) ?? "").hasSuffix("pageBaseCardView") } }

    public var pageTitle: String {
        guard let (scroll, list) = pageRoot() else { return "" }
        if let c = card, let d = c.string(kAXDescriptionAttribute), !d.isEmpty { return Self.tidy(d) }
        // The pages named by what they are (Updates' collection calls itself "Details" in one layout).
        let named = ["AppStore.updates": "Updates", "AppStore.discover": "Discover", "AppStore.arcade": "Arcade", "AppStore.error": "Cannot connect"]
        if let n = named[list.string(kAXIdentifierAttribute) ?? ""] { return n }
        if let p = Self.first(in: list, depth: 4, where: { ($0.string(kAXIdentifierAttribute) ?? "").hasSuffix("shelfItemSubComponent.title") }), let v = p.string(kAXValueAttribute) { return v }
        if let h = Self.first(in: scroll, depth: 4, where: { $0.role == "AXHeading" && !Self.isInside($0, list) }), let d = h.string(kAXDescriptionAttribute) ?? h.string(kAXValueAttribute) { return d }
        return list.string(kAXDescriptionAttribute) ?? ""
    }

    /// The page, shelf by shelf, a little at a time: the heading's area above the collection (Updates: "Update
    /// All"), then the shelves reached by AXNextContentSibling, until there are enough to start with. The rest is read
    /// as the arrows reach it (reading all 529 items of Discover at once took 5 s and froze TurnOver, 6 Oct 2026).
    // MARK: The flat view (developer switch `flatView`; docs/FLAT-VIEW-PLAN.md)

    private var flat: FlatView?
    /// The flat items beside `page`, same indices, while the flat view drives the page.
    private var flatItems: [FlatItem] = []
    private var flatDrives = false
    private var flatOn: Bool { Edition.devDefault("flatView") }

    /// The results page read by the flat view: its list replaces `page` as the waves come, the place kept by key.
    private var flatKey = ""
    /// The first row of this page said once (the waves publish several times as the page fills).
    private var flatSpokeFirst = false
    private func flatBegin() {
        if flat == nil {
            let f = FlatView(name: "App Store results", adapter: AppStoreFlatAdapter(pid: pid))
            f.onChange = { [weak self] items in self?.flatChanged(items) }
            flat = f
        }
        // The same page read again (the settle waves call buildPage): the view's own waves go on; no restart.
        if flatDrives, flatKey == pageKey { return }
        flatDrives = true; flatKey = pageKey; flatSpokeFirst = false
        flat?.begin()
    }
    private func flatEnd() { guard flatDrives else { return }; flatDrives = false; flatItems = []; flat?.end() }
    /// The index whose placeholder ("row 7") was said while its name was still to come: said again when it comes.
    private var flatPlaceholderSpoken: Int?
    private func flatChanged(_ items: [FlatItem]) {
        guard flatDrives else { return }
        let wasEmpty = page.isEmpty || !flatSpokeFirst
        let placeholder = AXUIElementCreateApplication(pid)   // an entry's element is never acted on here; resolve finds the live row
        page = items.map { it in var e = Entry(label: it.label, element: placeholder, kind: .app, shelf: 1); e.check = it.name ?? ""; return e }
        flatItems = items; shelves = ["", ""]
        pageIndex = min(pageIndex, max(0, page.count - 1))
        if wasEmpty, !page.isEmpty { flatSpokeFirst = true; Log.io("app store: the flat view gives the results page \(page.count) rows"); speak(pageIndex, crossing: true) }
        else if let waiting = flatPlaceholderSpoken, waiting == pageIndex, items.indices.contains(waiting), items[waiting].name != nil {
            flatPlaceholderSpoken = nil
            Speech.speakItem(items[waiting].label)
        }
    }

    public func buildPage() {
        let start = Date()
        page = []; shelves = []
        guard let (scroll, list) = pageRoot() else { pageKey = ""; flatEnd(); return }
        if flatOn, list.string(kAXIdentifierAttribute) == "AppStore.search.result" {
            pageKey = currentKey(); builtTitle = pageTitle
            if !flatDrives || flatKey != pageKey { Log.io("app store: page \"\(Log.words(pageTitle))\" is the flat view's") }
            flatBegin()
            return
        }
        flatEnd()
        seen = []
        // Above the collection: the page's heading and its buttons.
        for c in scroll.elements(kAXChildrenAttribute) where c.role == "AXGroup" && !CFEqual(scroll, list) {
            for b in c.elements(kAXChildrenAttribute) where b.role == "AXButton" {
                if let t = b.string(kAXTitleAttribute) ?? b.string(kAXDescriptionAttribute) { page.append(Entry(label: t, element: b, kind: .button, shelf: 0)) }
            }
        }
        shelves.append("")
        lastSection = nil; nextSection = nil; tails = [:]
        // The collection lists only the shelves on screen: from the one in view, back to the page's first.
        if CFEqual(scroll, list) {
            // A page with no shelves: its texts and buttons in order.
            shelves.append("")
            walk(list, shelf: 1, section: list, known: known, mark: { self.seen.append($0) })
            for k in page.indices where page[k].check.isEmpty { page[k].check = Self.identity(of: page[k].element) }
        } else if let visible = Self.first(in: list, depth: 2, where: { $0.string(kAXSubroleAttribute) == "AXSectionList" }) {
            var top = visible; var hops = 0
            while let p = top.element("AXPreviousContentSibling"), hops < 200 { top = p; hops += 1 }
            addSections(from: top, limit: Self.batch)
        }
        pageKey = currentKey()
        builtTitle = pageTitle
        Log.io("app store: page \"\(Log.words(pageTitle))\", \(shelves.filter { !$0.isEmpty }.count) shelves, \(page.count) items in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
    }

    nonisolated(unsafe) private var seen: [AXUIElement] = []
    nonisolated(unsafe) private var lastSection: AXUIElement?
    /// The next shelf not read yet (nil: none ready, or the end).
    nonisolated(unsafe) private var nextSection: AXUIElement?
    /// Carousels not read to the end: the shelf's last item read so far.
    nonisolated(unsafe) private var tails: [Int: AXUIElement] = [:]
    nonisolated static let batch = 40, perCarousel = 12
    nonisolated private func known(_ e: AXUIElement) -> Bool { seen.contains { Self.same($0, e) } }

    /// Shelves from this one on, as far as the App Store has them ready.
    nonisolated private func addSections(from start: AXUIElement, limit: Int) {
        var section: AXUIElement? = start
        var count = 0
        let stopAt = page.count + limit
        nextSection = nil
        while let sec = section, count < 80 {
            if page.count >= stopAt { nextSection = sec; return }
            count += 1
            let name = Self.shelfName(sec.string(kAXDescriptionAttribute) ?? "")
            let shelf = shelves.count
            shelves.append(name)
            let before = page.count
            walk(sec, shelf: shelf, section: sec, known: known, mark: { self.seen.append($0) })
            // A shelf far from the screen is an empty shell until it comes near: bring it into view, read again.
            var tries = 0
            while page.count == before, tries < 2, sec.elements(kAXChildrenAttribute).count <= 1 || (sec.string(kAXDescriptionAttribute) ?? "").isEmpty {
                _ = AXUIElementPerformAction(sec, "AXScrollToVisible" as CFString)
                usleep(250_000); tries += 1
                shelves[shelf] = Self.shelfName(sec.string(kAXDescriptionAttribute) ?? "")
                walk(sec, shelf: shelf, section: sec, known: known, mark: { self.seen.append($0) })
            }
            if page.count == before { shelves[shelf] = "" }
            // A shelf with no heading named by what it holds: the banners at the top, a row of categories.
            if shelves[shelf].isEmpty, page.count > before {
                let ids = page[before..<page.count].map { $0.element.string(kAXIdentifierAttribute) ?? "" }
                if ids.contains(where: { $0.contains("RibbonBar") }) { shelves[shelf] = "Categories" }
                else if ids.contains(where: { $0.contains("Hero") || $0.contains("LargeCard") }) { shelves[shelf] = "Featured" }
            }
            // The shelf's own heading is said as its name; not again as an item.
            if !shelves[shelf].isEmpty { page.removeSubrange(before..<page.count, where: { $0.kind == .heading && $0.label == shelves[shelf] }) }
            for k in before..<page.count where page[k].check.isEmpty { page[k].check = Self.identity(of: page[k].element) }
            lastSection = sec
            section = sec.element("AXNextContentSibling")
        }
    }

    /// The end of what was read: the App Store makes the shelves further down only as they come into view. Bring
    /// the last one into view and read on. True if there was more.
    nonisolated private func loadMore() -> Bool {
        let before = page.count
        if let next = nextSection { addSections(from: next, limit: Self.batch); if page.count > before { return true } }
        guard let last = lastSection else { return false }
        // Into view: the shelf, then its last item, so the shelves after it are made.
        let targets = [last] + Array(last.elements(kAXChildrenAttribute).suffix(1))
        for t in targets {
            _ = AXUIElementPerformAction(t, "AXScrollToVisible" as CFString)
            for _ in 0..<4 {
                usleep(200_000)
                if let next = last.element("AXNextContentSibling") { addSections(from: next, limit: Self.batch); break }
            }
            if page.count > before { break }
        }
        Log.io("app store: read on past \"\(Log.words(Self.shelfName(last.string(kAXDescriptionAttribute) ?? "")))\": \(page.count - before) more")
        return page.count > before
    }

    /// The words an element shows now: its own title or description, or its first titled part that is not the
    /// offer button.
    nonisolated static func identity(of e: AXUIElement) -> String {
        if let t = e.string(kAXTitleAttribute) ?? e.string(kAXDescriptionAttribute), !t.isEmpty { return t }
        if e.role == "AXStaticText", let v = e.string(kAXValueAttribute) { return v }
        // The first named thing inside: a titled part, or plain text. The Updates page's rows hold the app's name as
        // plain text only ("Asobi: Remote Play"), so they had no name, never matched, and Update was refused as unsafe
        // (14 Oct 2026: "still struggling to press buttons").
        func named(_ x: AXUIElement) -> String? {
            if (x.string(kAXIdentifierAttribute) ?? "").contains("offerButton") || x.role == "AXImage" { return nil }
            if let t = x.string(kAXTitleAttribute) ?? x.string(kAXDescriptionAttribute), !t.isEmpty { return t }
            if x.role == "AXStaticText", let v = x.string(kAXValueAttribute), !v.trimmingCharacters(in: .whitespaces).isEmpty { return v }
            return nil
        }
        return first(in: e, depth: 4) { named($0) != nil }.flatMap(named) ?? ""
    }

    /// The entry at the place, made sure of: its element still shows what was read. If the row was reused for
    /// another app, the page is read again and the same item found; nil if it cannot be. The looking (scrolling
    /// and waiting, up to two seconds) happens off the main thread, and `then` runs on it (8 Oct 2026).
    private func confirmed(_ i: Int, then: @escaping (Entry?) -> Void) {
        guard page.indices.contains(i) else { Log.io("app store: nothing at \(i + 1) of \(page.count) to act on"); then(nil); return }
        let e = page[i]
        // The flat view's page: the item is resolved by key in the live tree, brought on screen, the hit test agreeing.
        if flatDrives, let flat, flatItems.indices.contains(i) {
            let item = flatItems[i]
            guard item.name != nil else { Speech.speakMessage("still reading this row; a moment"); then(nil); return }
            flat.resolve(item) { [weak self] live in
                guard let self, let live, page.indices.contains(i) else { then(nil); return }
                page[i].element = live
                if let n = item.name { page[i].check = n }
                then(page[i])
            }
            return
        }
        @Sendable nonisolated func name(_ s: String) -> String { (s.components(separatedBy: ",").first ?? s).trimmingCharacters(in: .whitespaces) }
        let wanted = name(e.check.isEmpty ? e.label : e.check)
        // The element still shows it: on screen and not reused.
        if !e.check.isEmpty, name(Self.identity(of: e.element)) == wanted, onScreen(e.element),
           e.kind != .app && e.kind != .card || visibleRows().contains(where: { CFEqual($0, e.element) }) { then(e); return }
        guard !loading else { queued.append { [weak self] in self?.confirmed(i, then: then) }; return }
        loading = true
        Poll.background({ [weak self] () -> AXUIElement? in
            guard let self else { return nil }
            // An app's row: rows are reused as the list scrolls (the element remembered may now be another app, or
            // empty), so the row is found again on screen by its name, moving the page there with its scroll bar.
            if e.kind == .app || e.kind == .card {
                guard let row = bringIntoView(i, name: wanted) else { return nil }
                // The Store's hit-testing lags a new results page: under the row's icon it still named a row of the
                // search before ("Pages: Create Documents" under "WaterMinder", 27 Oct 2026), so the click was refused.
                // Up to a second, a quarter at a time, for the system to agree about what is under the point.
                for attempt in 0..<4 {
                    if hitAgrees(row, wanted: wanted) { if attempt > 0 { Log.io("app store: the hit test agreed after \(attempt) waits") }; return row }
                    usleep(250_000)
                }
                Log.io("app store: the hit test still names something else under \"\(Log.words(wanted))\"; handing the row over anyway")
                return row
            }
            // A heading's button (See All): into view, and checked.
            reveal(e)
            usleep(250_000)
            return name(Self.identity(of: e.element)) == wanted ? e.element : nil
        }) { [weak self] row in
            guard let self else { return }
            loading = false
            guard let row, page.indices.contains(i) else {
                Log.io("app store: could not find \"\(Log.words(wanted))\" on screen (kind \(e.kind), element now \"\(Log.words(name(Self.identity(of: e.element))))\", on screen \(self.onScreen(e.element)))")
                Speech.speakMessage("could not reach \(wanted); try again")
                then(nil); return
            }
            page[i].element = row
            then(page[i])
        }
    }

    /// The page's frame on screen: its scroll area's, or, where that is a group with no size of its own (the search
    /// results page: an AXGroup with the scroll actions whose frame is empty, so every row counted as off screen and
    /// Return said "could not reach", 27 Oct 2026), its list's, else the window's.
    nonisolated private func pageFrame() -> CGRect? {
        guard let (scroll, list) = pageRoot() else { return nil }
        if let f = TurnOverObject.frame(scroll), f.width > 10, f.height > 10 { return f }
        if let f = TurnOverObject.frame(list), f.width > 10, f.height > 10 { return f }
        return window.flatMap { TurnOverObject.frame($0) }
    }

    /// Inside the page's area on screen (an item read ahead of the screen has a frame far above or below it).
    nonisolated private func onScreen(_ x: AXUIElement) -> Bool {
        guard let f = TurnOverObject.frame(x), f.height > 4, let area = pageFrame() else { return false }
        return area.contains(CGPoint(x: f.midX, y: f.midY))
    }

    /// The page's area a click can reach: its scroll area less the toolbar, which floats over the top of it (Return
    /// on the first search result clicked the toolbar, and Kindle "cannot open this one", 18 Oct 2026).
    nonisolated private func visibleArea() -> CGRect? {
        guard var area = pageFrame() else { return nil }
        if let w = window, let tb = w.elements(kAXChildrenAttribute).first(where: { $0.role == "AXToolbar" }), let tf = TurnOverObject.frame(tb), tf.maxY > area.minY {
            let cut = min(area.height, tf.maxY - area.minY)
            area.origin.y += cut; area.size.height -= cut
        }
        return area
    }

    /// The rows of the page on screen now (the collection lists only those).
    nonisolated private func visibleRows() -> [AXUIElement] {
        guard let (_, list) = pageRoot() else { return [] }
        var out: [AXUIElement] = []
        func go(_ x: AXUIElement, _ d: Int) {
            guard d < 5 else { return }
            for c in x.elements(kAXChildrenAttribute) { if Self.isItem(c) { out.append(c) } else { go(c, d + 1) } }
        }
        go(list, 0)
        return out
    }

    /// The live row of item i on screen, scrolling there if need be: a binary search on the scroll bar, each step
    /// judged by which items are on screen.
    nonisolated private func bringIntoView(_ i: Int, name wanted: String) -> AXUIElement? {
        func name(_ s: String) -> String { (s.components(separatedBy: ",").first ?? s).trimmingCharacters(in: .whitespaces) }
        func lookOnScreen() -> AXUIElement? { visibleRows().first { name(Self.identity(of: $0)) == wanted && onScreen($0) } }
        if let r = lookOnScreen() { return r }
        let rows = visibleRows()
        Log.io("app store: \(rows.count) rows on screen; names \(rows.prefix(6).map { "\"\(Log.words(name(Self.identity(of: $0))))\"\(onScreen($0) ? "" : " (off)")" }.joined(separator: ", ")); root \(pageRoot().map { "\($0.scroll.role) > \($0.list.role)" } ?? "none")")
        guard let (scroll, _) = pageRoot() else { return nil }
        guard let bar = scroll.element(kAXVerticalScrollBarAttribute) else {
            // No scroll bar to drive (the search results' group): the row itself, or its list, asked to scroll into
            // view; then a look at what is on screen.
            if let row = rows.first(where: { name(Self.identity(of: $0)) == wanted }) ?? page[i].element as AXUIElement? {
                _ = AXUIElementPerformAction(row, "AXScrollToVisible" as CFString)
                usleep(200_000)
                if let r = lookOnScreen() { Log.io("app store: \"\(Log.words(wanted))\" scrolled into view"); return r }
            }
            return nil
        }
        var lo = 0.0, hi = 1.0
        var at = Double(i) / Double(max(1, page.count - 1))
        for step in 0..<10 {
            _ = bar.set(kAXValueAttribute, NSNumber(value: min(1, max(0, at))))
            usleep(180_000)
            if let r = lookOnScreen() { Log.io("app store: \"\(Log.words(wanted))\" brought on screen in \(step + 1) steps"); return r }
            // Which items are on screen: above or below the one wanted?
            let shown = visibleRows().compactMap { row -> Int? in let n = name(Self.identity(of: row)); return page.firstIndex { name($0.label) == n } }
            guard let lowest = shown.min(), let highest = shown.max() else { at = (lo + hi) / 2; continue }
            if i < lowest { hi = at } else if i > highest { lo = at } else { break }
            at = (lo + hi) / 2
        }
        return lookOnScreen()
    }

    nonisolated static func isItem(_ e: AXUIElement) -> Bool {
        let id = e.string(kAXIdentifierAttribute) ?? ""
        return id.contains("shelfItem") && !id.contains("SubComponent")
    }

    /// The rest of a carousel, read when the arrows reach the end of what was read of it; put in place after it.
    private func extendShelf(_ shelf: Int) -> Bool {
        guard let tail = tails[shelf], let lastIndex = page.lastIndex(where: { $0.shelf == shelf }) else { return false }
        tails[shelf] = nil
        let section = page[lastIndex].section ?? tail
        var added: [Entry] = []
        var item = tail.element("AXNextContentSibling")
        var lastRead = tail
        var n = 0
        while let it = item, n < 30, Self.isItem(it), !known(it) {
            seen.append(it)
            added += Self.entries(for: it, shelf: shelf, section: section)
            lastRead = it
            item = it.element("AXNextContentSibling"); n += 1
        }
        if let more = item, Self.isItem(more), !known(more) { tails[shelf] = lastRead }
        for k in added.indices { added[k].check = Self.identity(of: added[k].element) }
        page.insert(contentsOf: added, at: lastIndex + 1)
        return !added.isEmpty
    }

    /// "Apps updated for macOS 27, Section 4" → "Apps updated for macOS 27"; "Section 3" → "".
    nonisolated static func shelfName(_ d: String) -> String {
        var s = d
        if let r = s.range(of: #"(,\s*)?Section \d+$"#, options: .regularExpression) { s.removeSubrange(r) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    nonisolated private func walk(_ e: AXUIElement, shelf: Int, section: AXUIElement, known: (AXUIElement) -> Bool, mark: (AXUIElement) -> Void, depth: Int = 0) {
        guard depth < 8 else { return }
        for c in e.elements(kAXChildrenAttribute) {
            if known(c) { continue }
            let role = c.role, id = c.string(kAXIdentifierAttribute) ?? ""
            if id.contains("shelfItem"), !id.contains("SubComponent") {
                // The item and, from it, the start of its carousel; the rest when the arrows get there. A list
                // scrolled down shows only its middle: back to its first item first.
                var head = c; var back = 0
                while let p = head.element("AXPreviousContentSibling"), Self.isItem(p), !known(p), back < 400 { head = p; back += 1 }
                var item: AXUIElement? = head
                var n = 0
                var lastRead: AXUIElement?
                while let it = item, n < Self.perCarousel, !known(it), Self.isItem(it) {
                    mark(it)
                    page += Self.entries(for: it, shelf: shelf, section: section)
                    lastRead = it
                    item = it.element("AXNextContentSibling"); n += 1
                }
                if let lastRead, let more = item, Self.isItem(more), !known(more) { tails[shelf] = lastRead }
                continue
            }
            if id.hasPrefix("chevron.") { continue }
            switch role {
            case "AXHeading":
                // The shelf's own heading is its name, said on arriving; a heading inside a shelf is read as one.
                let t = c.string(kAXDescriptionAttribute) ?? c.string(kAXValueAttribute) ?? ""
                if !t.isEmpty, t != shelves[shelf] { page.append(Entry(label: t, element: c, kind: .heading, shelf: shelf, section: section)) }
            case "AXButton":
                let t = c.string(kAXTitleAttribute) ?? c.string(kAXDescriptionAttribute) ?? ""
                if !t.isEmpty, !["Backward", "Forward", "Play", "Pause", "Unmute", "Mute"].contains(t) {
                    let label = t == "See All" && !shelves[shelf].isEmpty ? "See all, \(shelves[shelf])" : t
                    page.append(Entry(label: label, element: c, kind: .button, shelf: shelf, section: section))
                }
            case "AXStaticText":
                let t = (c.string(kAXValueAttribute) ?? c.string(kAXDescriptionAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, page.last?.label != t, t != shelves[shelf] { page.append(Entry(label: Self.tidy(t), element: c, kind: .text, shelf: shelf, section: section)) }
            case "AXImage":
                continue
            default:
                walk(c, shelf: shelf, section: section, known: known, mark: mark, depth: depth + 1)
            }
        }
    }

    /// A shelf item: one entry, or, for a block of text with links under it (the description, with Website and
    /// Support), the text and then each link.
    nonisolated static func entries(for e: AXUIElement, shelf: Int, section: AXUIElement) -> [Entry] {
        let id = e.string(kAXIdentifierAttribute) ?? ""
        let hasOffer = first(in: e, depth: 5) { ($0.string(kAXIdentifierAttribute) ?? "").contains("offerButton") } != nil
        if !hasOffer, !id.contains("Lockup"), !id.contains("Card"), !id.contains("Badge"), !id.contains("SearchResult") {
            var texts: [String] = [], buttons: [(String, AXUIElement)] = []
            func go(_ x: AXUIElement, _ d: Int) {
                guard d < 6 else { return }
                for c in x.elements(kAXChildrenAttribute) {
                    if c.role == "AXStaticText" {
                        let v = (c.string(kAXValueAttribute) ?? c.string(kAXDescriptionAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !v.isEmpty, !texts.contains(v) { texts.append(v) }
                        continue
                    }
                    if c.role == "AXButton", let t = c.string(kAXTitleAttribute) ?? c.string(kAXDescriptionAttribute), !t.isEmpty { buttons.append((t, c)); continue }
                    go(c, d + 1)
                }
            }
            go(e, 0)
            if texts.joined().count > 40, !buttons.isEmpty {
                return [Entry(label: tidy(texts.joined(separator: " ")), element: e, kind: .text, shelf: shelf, section: section)]
                    + buttons.map { Entry(label: $0.0, element: $0.1, kind: .button, shelf: shelf, section: section) }
            }
        }
        return entry(for: e, shelf: shelf, section: section).map { [$0] } ?? []
    }

    /// One shelf item, read in order: the app, what it is, its rating, and its button last.
    nonisolated static func entry(for e: AXUIElement, shelf: Int, section: AXUIElement) -> Entry? {
        let id = e.string(kAXIdentifierAttribute) ?? ""
        let offer = first(in: e, depth: 5) { ($0.string(kAXIdentifierAttribute) ?? "").contains("offerButton") }
        let offerTitle = offer.flatMap { $0.string(kAXTitleAttribute) ?? $0.string(kAXDescriptionAttribute) } ?? ""
        func texts() -> [String] {
            var out: [String] = []
            func go(_ x: AXUIElement, _ d: Int) {
                guard d < 6 else { return }
                for c in x.elements(kAXChildrenAttribute) {
                    if c.role == "AXStaticText" { let v = (c.string(kAXValueAttribute) ?? c.string(kAXDescriptionAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines); if !v.isEmpty { out.append(v) }; continue }
                    go(c, d + 1)
                }
            }
            go(e, 0)
            return out
        }
        var label = ""
        var kind = Kind.app
        if id.contains("ProductLockup") {
            // The product page's top: "Microsoft Word, by Microsoft Corporation, Open".
            let title = first(in: e, depth: 2) { ($0.string(kAXIdentifierAttribute) ?? "").hasSuffix("shelfItemSubComponent.title") }?.string(kAXValueAttribute) ?? ""
            let dev = e.elements(kAXChildrenAttribute).first { $0.role == "AXButton" && !($0.string(kAXIdentifierAttribute) ?? "").contains("offerButton") }?.string(kAXTitleAttribute)
            label = [title, dev, offerTitle.isEmpty ? nil : offerTitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        } else if id.contains("BadgeCollectionViewCell") {
            kind = .text
            label = badge(e)
        } else if id.contains("ContentSearchResult") {
            // Search results: "WhatsApp Messenger, Simple. Reliable. Private., four and three quarters stars", the
            // number of ratings, then the button.
            // The title is on an inner AXGroup, or (the other layout) an AXLink that already ends with the button's
            // words ("WeChat, Social Networking, two and three quarters stars, , Get").
            let holder = first(in: e, depth: 2) { ($0.string(kAXTitleAttribute) ?? "").count > 0 && ($0.role == "AXGroup" || $0.role == "AXLink") && !($0.string(kAXIdentifierAttribute) ?? "").contains("offerButton") }
            var title = holder?.string(kAXTitleAttribute) ?? ""
            if !offerTitle.isEmpty, title.hasSuffix(offerTitle) { title = String(title.dropLast(offerTitle.count)) }
            title = title.replacingOccurrences(of: ", ,", with: ",").trimmingCharacters(in: CharacterSet(charactersIn: ", "))
            let ratings = texts().last { $0.range(of: #"^[\d.,]+[kKmM]?$"#, options: .regularExpression) != nil }
            label = [title, ratings.map { "\($0) ratings" }, offerTitle.isEmpty ? nil : offerTitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        } else if id.contains("UpdatesLockup") {
            // Updates: the app and date, the button, then what's new.
            // The app and date are an inner group's description, or (the other layout) its first two texts.
            let inner = first(in: e, depth: 2) { $0.role == "AXGroup" && $0.string(kAXDescriptionAttribute) != nil }
            let all = texts()
            let head = inner?.string(kAXDescriptionAttribute) ?? all.prefix(2).joined(separator: ", ")
            let notes = all.dropFirst(2).filter { $0 != all.dropFirst().first }.max { $0.count < $1.count } ?? ""
            let ipad = first(in: e, depth: 3) { ($0.string(kAXTitleAttribute) ?? "").hasPrefix("Designed for iPad") } != nil
            label = [head, ipad ? "designed for iPad" : "", offerTitle].filter { !$0.isEmpty }.joined(separator: ", ") + (notes.count > 8 ? ". \(notes)" : "")
        } else {
            // Tiles and cards: the description of the item or of the button inside it.
            let own = e.string(kAXTitleAttribute) ?? e.string(kAXDescriptionAttribute)
            let all = texts()
            let inner = first(in: e, depth: 4) { ($0.role == "AXButton" || $0.role == "AXUnknown") && !($0.string(kAXIdentifierAttribute) ?? "").contains("offerButton") && ($0.string(kAXDescriptionAttribute) ?? "").count > 3 }?.string(kAXDescriptionAttribute)
            // Two or more texts (a hero banner: "New Game, Cosy Up With Fun Mini-Games…, Pusheen's Place, Collect
            // kitties.") say more than an inner button's name ("Video").
            label = own ?? (all.count >= 2 ? all.joined(separator: ", ") : nil) ?? inner ?? all.joined(separator: ", ")
            if !offerTitle.isEmpty, !label.contains(offerTitle) { label += ", \(offerTitle)" }
            if offer == nil { kind = id.contains("Card") || id.contains("RibbonBar") ? .card : (id.contains("Lockup") ? .app : .text) }
            if id.contains("ProductMediaItem") { return nil }   // screenshots: pictures only
        }
        label = tidy(label)
        guard !label.isEmpty, label != "Artwork" else { return nil }
        var entry = Entry(label: label, element: e, kind: kind, shelf: shelf, offer: offer, section: section)
        entry.offerTitle = offerTitle
        return entry
    }

    /// The product page's badges, in the order they are meant: "Rating 4.5 out of 5, 314K ratings"; "Size 2.76 GB".
    nonisolated static func badge(_ e: AXUIElement) -> String {
        guard let t = first(in: e, depth: 2, where: { ($0.string(kAXIdentifierAttribute) ?? "").contains("productPage.badge") }) else { return e.string(kAXDescriptionAttribute) ?? "" }
        let id = t.string(kAXIdentifierAttribute) ?? ""
        var parts: [String] = []
        func go(_ x: AXUIElement) { for c in x.elements(kAXChildrenAttribute) { if c.role == "AXStaticText", let v = c.string(kAXValueAttribute), !v.isEmpty, c.elements(kAXChildrenAttribute).isEmpty { parts.append(v) }; if c.role != "AXImage" { go(c) } } }
        go(t)
        let caption = parts.first { $0 == $0.uppercased() && $0.rangeOfCharacter(from: .letters) != nil && $0.rangeOfCharacter(from: .decimalDigits) == nil && $0.count > 2 }
        let rest = parts.filter { $0 != caption }
        if id.hasSuffix("badge.rating") {
            let score = parts.first { Double($0) != nil } ?? ""
            let count = parts.first { $0.uppercased().contains("RATING") } ?? ""
            return "Rating \(score) out of 5, \(count.lowercased())"
        }
        if id.hasSuffix("badge.chartPosition") {
            let n = parts.first { Int($0) != nil } ?? ""
            let cat = rest.last { Int($0) == nil && $0 != "No." } ?? ""
            return "Chart: number \(n) in \(cat)"
        }
        if id.hasSuffix("badge.artwork") {
            return "Developer: \(rest.joined(separator: " "))"
        }
        guard let caption else { return t.string(kAXDescriptionAttribute) ?? "" }
        return "\(caption.capitalized): \(rest.joined(separator: " "))"
    }

    /// Shouted labels spoken as words: "GAMES WE LOVE" as "Games We Love". Only a whole phrase in capitals of two
    /// words or more, or one long word ("ESSENTIALS"); acronyms (APA, ADHD, RSS) stay as they are.
    nonisolated static func tidy(_ raw: String) -> String {
        let s = raw.replacingOccurrences(of: "\u{FFFC}", with: "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return s.components(separatedBy: ", ").map { part -> String in
            let letters = part.filter { $0.isLetter }
            guard letters.count >= 3, String(letters) == String(letters).uppercased(), part.rangeOfCharacter(from: .decimalDigits) == nil else { return part }
            let words = part.split(separator: " ").count
            return words >= 2 || letters.count >= 6 ? part.capitalized : part
        }.joined(separator: ", ")
    }

    public func buildSidebar() {
        _ = 0
        sidebar = []
        guard let w = window, let split = w.elements(kAXChildrenAttribute).first(where: { $0.role == "AXSplitGroup" }) else { return }
        let page = pageRoot()?.scroll
        func visit(_ c: AXUIElement, _ depth: Int) {
            if let page, Self.same(c, page) { return }
            if c.string(kAXSubroleAttribute) == "AXSearchField" {
                let v = (c.attr(kAXValueAttribute) as? String) ?? ""
                sidebar.append(Entry(label: v.isEmpty ? "Search" : "Search, \(v)", element: c, kind: .search, shelf: 0))
            } else if c.role == "AXOutline" {
                for row in c.elements(kAXChildrenAttribute) where row.role == "AXRow" {
                    guard let cell = row.elements(kAXChildrenAttribute).first, let d = cell.string(kAXDescriptionAttribute) else { continue }
                    let selected = (row.attr(kAXSelectedAttribute) as? Bool) == true
                    sidebar.append(Entry(label: d + (selected ? ", selected" : ""), element: cell, kind: .tab, shelf: 0))
                }
            } else if (c.string(kAXIdentifierAttribute) ?? "") == "AppStore.accountButton", let t = c.string(kAXTitleAttribute) {
                sidebar.append(Entry(label: "Account, \(t)", element: c, kind: .account, shelf: 0))
            } else if depth < 2, c.role == "AXGroup" {
                for k in c.elements(kAXChildrenAttribute) { visit(k, depth + 1) }
            }
        }
        for c in split.elements(kAXChildrenAttribute) { visit(c, 0) }
    }

    private func ensureCurrent() {
        guard !loading || flatDrives else { return }   // the lists are being written off the main thread
        if card != nil { area = .page }   // a card over the window: no sidebar to be in
        // Under the flat view the list element comes and goes as the Store redraws; the view's own waves keep up, so
        // a changed key with the same title is no reason to start over (Return emptied the page and did nothing,
        // 27 Oct 2026).
        let samePage = flatDrives && pageTitle == builtTitle && pageRoot() != nil
        if area == .page, page.isEmpty || (currentKey() != pageKey && !samePage) { buildPage(); pageIndex = min(pageIndex, max(0, page.count - 1)) }
        if area == .sidebar { buildSidebar(); sideIndex = min(sideIndex, max(0, sidebar.count - 1)) }
    }

    // MARK: Speaking

    private func speak(_ i: Int, crossing: Bool) {
        let list = area == .page ? page : sidebar
        guard list.indices.contains(i) else { return }
        let e = list[i]
        var s = e.label
        // The flat view's page: the names near here are asked for; a row still to answer is said by its place, then
        // by name when the name comes.
        if area == .page, flatDrives, let flat {
            flat.cursor(at: i)
            flatPlaceholderSpoken = flatItems.indices.contains(i) && flatItems[i].name == nil ? i : nil
        }
        // The button as it is now: a download's progress moves on, and Get becomes Open.
        if !e.offerTitle.isEmpty, let o = e.offer, let now = o.string(kAXTitleAttribute) ?? o.string(kAXDescriptionAttribute), now != e.offerTitle {
            s = now.isEmpty ? s.replacingOccurrences(of: ", " + e.offerTitle, with: "") : s.replacingOccurrences(of: e.offerTitle, with: now)
        }
        switch e.kind {
        case .heading: s += ", heading"
        case .button: s += ", button"
        case .search: s += ", search field"
        default: break
        }
        if area == .page, crossing, shelves.indices.contains(e.shelf), !shelves[e.shelf].isEmpty {
            let n = page.filter { $0.shelf == e.shelf }.count
            s = "\(shelves[e.shelf]), \(n) item\(n == 1 ? "" : "s"). " + s
        }
        Speech.speakItem(s)
        Hints.schedule(hint(for: e))
    }

    /// What can be done with an item, for the hint.
    private func hint(for e: Entry) -> String {
        if area == .sidebar {
            switch e.kind {
            case .search: return "Return to type a search. Tab for the page."
            case .tab: return "Return opens it. Tab for the page."
            case .account: return "Return opens your account."
            default: return ""
            }
        }
        switch e.kind {
        case .app:
            if Self.isProductTop(e.element) { return "Return or Space presses its button." }
            if e.offer == nil { return "Return opens it." }
            return "Return opens its page. Space presses its button. Left and Right for other shelves."
        case .card: return "Return opens it. Left and Right for other shelves."
        case .button: return "Return presses it."
        case .heading, .text: return "Up and Down to read on. Left and Right for other shelves."
        default: return ""
        }
    }

    nonisolated private func reveal(_ e: Entry) {
        if let s = e.section { _ = AXUIElementPerformAction(s, "AXScrollToVisible" as CFString) }
        _ = AXUIElementPerformAction(e.element, "AXScrollToVisible" as CFString)
    }

    public func arrive(tries: Int = 8) {
        area = .page
        buildPage()
        // At launch the page isn't there yet (only "App Store" was said, 7 Oct 2026): wait for it.
        if page.isEmpty, tries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, NSWorkspace.shared.frontmostApplication?.processIdentifier == self.pid else { return }
                self.arrive(tries: tries - 1)
            }
            return
        }
        pageIndex = 0
        let title = pageTitle
        let n = shelves.filter { !$0.isEmpty }.count
        Speech.speakMessage("\(title.isEmpty ? "App Store" : title)\(n > 0 ? ", \(n) shelves" : "")")
        if !page.isEmpty { speak(0, crossing: true) }
    }

    // MARK: Moving

    public func move(_ d: Int) {
        guard !loading else { queued.append { [weak self] in self?.move(d) }; return }
        moves += 1
        ensureCurrent()
        if area == .sidebar {
            let j = sideIndex + d
            guard sidebar.indices.contains(j) else { Tones.edge(); speak(sideIndex, crossing: false); return }
            sideIndex = j; speak(j, crossing: false); return
        }
        if d > 0, page.indices.contains(pageIndex), tails[page[pageIndex].shelf] != nil,
           pageIndex + 1 >= page.count || page[pageIndex + 1].shelf != page[pageIndex].shelf {
            _ = extendShelf(page[pageIndex].shelf)
        }
        let j = pageIndex + d
        if j >= page.count, area == .page, lastSection != nil || nextSection != nil {
            // Past what has been read: the App Store makes the next shelves as they come into view, so the move
            // waits for them off the main thread, then goes on (8 Oct 2026).
            loading = true
            Poll.background({ [weak self] in self?.loadMore() ?? false }) { [weak self] more in
                guard let self else { return }
                loading = false
                if more { move(d) } else { Tones.edge(); speak(pageIndex, crossing: false) }
            }
            return
        }
        guard page.indices.contains(j) else { Tones.edge(); speak(pageIndex, crossing: false); return }
        let crossing = page[j].shelf != page[pageIndex].shelf
        pageIndex = j
        speak(j, crossing: crossing)
    }

    public func jumpShelf(_ d: Int) {
        guard !loading else { queued.append { [weak self] in self?.jumpShelf(d) }; return }
        moves += 1
        ensureCurrent()
        guard area == .page, page.indices.contains(pageIndex) else { move(d); return }
        let cur = page[pageIndex].shelf
        if d > 0, !page.contains(where: { $0.shelf > cur }), lastSection != nil || nextSection != nil {
            loading = true
            Poll.background({ [weak self] in self?.loadMore() ?? false }) { [weak self] more in
                guard let self else { return }
                loading = false
                if more { jumpShelf(d) } else { Tones.edge() }
            }
            return
        }
        let target = d > 0 ? page.firstIndex { $0.shelf > cur } : page.lastIndex { $0.shelf < cur }.map { last in page.firstIndex { $0.shelf == page[last].shelf } ?? last }
        guard let t = target else { Tones.edge(); return }
        pageIndex = t
        speak(t, crossing: true)
    }

    public func toEnd(_ last: Bool) {
        moves += 1
        ensureCurrent()
        if area == .sidebar { sideIndex = last ? sidebar.count - 1 : 0; speak(sideIndex, crossing: false); return }
        guard !page.isEmpty else { return }
        guard !loading else { queued.append { [weak self] in self?.toEnd(last) }; return }
        if last {
            // The App Store makes its shelves only as they come into view: reading to the end scrolls and waits,
            // shelf by shelf, off the main thread, with "please wait" if it takes long (8 Oct 2026).
            loading = true
            Poll.background({ [weak self] in var n = 0; while let self, n < 30, self.loadMore() { n += 1 } }) { [weak self] _ in
                guard let self else { return }
                loading = false
                pageIndex = page.count - 1
                speak(pageIndex, crossing: true)
            }
            return
        }
        pageIndex = 0
        speak(pageIndex, crossing: true)
    }
    /// Reading on a background queue: keys pressed meanwhile are kept and run when it is done (as MediaView does;
    /// they were dropped with "please wait", code review, 8 Oct 2026).
    private var loading = false { didSet { if !loading, !queued.isEmpty { let q = queued; queued = []; q.forEach { $0() } } } }
    private var queued: [() -> Void] = []

    public func letter(_ ch: Character) {
        // While shelves are being read off the main thread, their lists are being written: wait, as the arrows do
        // (a code review, 14 Oct 2026).
        guard !loading else { queued.append { [weak self] in self?.letter(ch) }; return }
        moves += 1
        ensureCurrent()
        let list = area == .page ? page : sidebar
        let cur = area == .page ? pageIndex : sideIndex
        guard !list.isEmpty else { return }
        for k in 1...list.count {
            let j = (cur + k) % list.count
            if list[j].label.lowercased().first == ch {
                if area == .page { let crossing = page[j].shelf != page[pageIndex].shelf; pageIndex = j; speak(j, crossing: crossing) } else { sideIndex = j; speak(j, crossing: false) }
                return
            }
        }
        Tones.edge()
    }

    public func switchArea() {
        // While shelves are being read off the main thread, their lists are being written: wait, as the arrows do
        // (a code review, 14 Oct 2026).
        guard !loading else { queued.append { [weak self] in self?.switchArea() }; return }
        moves += 1
        // A card over the window has no sidebar: say how out, and stay.
        if card != nil {
            if area == .sidebar { area = .page; ensureCurrent(); speak(pageIndex, crossing: true) }
            else { Speech.speakMessage("no sidebar here; Escape goes back") }
            return
        }
        area = area == .page ? .sidebar : .page
        ensureCurrent()
        if area == .sidebar {
            // Search first, where it is on screen (it could not be found under Discover, 6 Oct 2026); the tab in
            // use is said with it.
            sideIndex = 0
            let current = sidebar.first { $0.label.hasSuffix(", selected") }?.label.replacingOccurrences(of: ", selected", with: "")
            Speech.speakMessage("sidebar" + (current.map { ", on \($0)" } ?? ""))
            speak(sideIndex, crossing: false)
        } else {
            Speech.speakMessage(pageTitle.isEmpty ? "page" : pageTitle)
            speak(pageIndex, crossing: true)
        }
    }

    // MARK: Acting

    public func open() {
        // While shelves are being read off the main thread, their lists are being written: wait, as the arrows do
        // (a code review, 14 Oct 2026). Not under the flat view, which has its own waits: a stale `loading` left
        // Return queued for good (27 Oct 2026).
        guard !loading || flatDrives else { queued.append { [weak self] in self?.open() }; return }
        ensureCurrent()
        if area == .sidebar {
            guard sidebar.indices.contains(sideIndex) else { return }
            let e = sidebar[sideIndex]
            switch e.kind {
            case .search: focusSearch()
            case .tab:
                // The tab's own button inside the cell (AppStore.tabBar.…): pressing the cell did nothing.
                // Selecting the row in the sidebar's list is what changes the page; pressing the tab's button or
                // its cell is accepted and does nothing (measured 6 Oct 2026).
                let before = currentKey()
                var r = AXError.failure
                if let row = e.element.element(kAXParentAttribute), let outline = row.element(kAXParentAttribute) {
                    r = outline.set(kAXSelectedRowsAttribute, [row] as CFArray)
                }
                if r != .success, let button = Self.first(in: e.element, depth: 3, where: { ($0.string(kAXIdentifierAttribute) ?? "").hasPrefix("AppStore.tabBar.") }) {
                    r = AXUIElementPerformAction(button, kAXPressAction as CFString)
                }
                Log.io("app store: tab \(Log.words(e.label)) chosen (\(r.rawValue))")
                Speech.speakMessage(e.label.replacingOccurrences(of: ", selected", with: ""))
                area = .page; pageIndex = 0
                waitForNewPage(from: before)
            case .account:
                // The account button has no press action (measured): a click on it, and its page is read.
                guard let f = TurnOverObject.frame(e.element) else { return }
                let before = currentKey()
                let home = CGEvent(source: nil)?.location
                Mouse.click(at: CGPoint(x: f.midX, y: f.midY), button: .left, count: 1)
                if let home { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Mouse.move(to: home) } }
                Speech.speakMessage("account")
                area = .page; pageIndex = 0
                waitForNewPage(from: before)
            default: break
            }
            return
        }
        confirmed(pageIndex) { [weak self] e in if let e { self?.open(confirmed: e) } }
    }
    private func open(confirmed e: Entry) {
        let before = pageKey
        switch e.kind {
        case .button:
            _ = AXUIElementPerformAction(e.element, kAXPressAction as CFString)
            waitForNewPage(from: before)
        case .heading, .text:
            Speech.speakMessage(e.label)
        case .app where Self.isProductTop(e.element):
            // On the app's own page, its first line is the app itself: Return presses its button, as Space does.
            offer()
        default:
            // An app opens with a click on its icon (a press on the row reports success and does nothing).
            guard clickIcon(e) else { Speech.speakMessage("cannot open this one"); return }
            waitForNewPage(from: before)
        }
    }

    /// The app's page opens with a click on the tile away from its button: the icon, at its left.
    static func isProductTop(_ e: AXUIElement) -> Bool { (e.string(kAXIdentifierAttribute) ?? "").contains("ProductLockup") }

    static func actions(of e: AXUIElement) -> [String] {
        var n: CFArray?
        AXUIElementCopyActionNames(e, &n)
        return (n as? [String]) ?? []
    }

    private func clickIcon(_ e: Entry) -> Bool {
        guard let f = TurnOverObject.frame(e.element), let w = window, let wf = TurnOverObject.frame(w) else { return false }
        // The app's icon (an image named for the app, not the "Artwork" screenshot), else the row's left edge.
        let icon = Self.first(in: e.element, depth: 5, where: { $0.role == "AXImage" && ($0.string(kAXDescriptionAttribute) ?? "Artwork") != "Artwork" }).flatMap { TurnOverObject.frame($0) }
        // A card or a category (Action, Puzzle) has no icon: its middle. Then, should the toolbar cover that point,
        // the lower part of the item, left and middle.
        let first = icon.map { CGPoint(x: $0.midX, y: $0.midY) } ?? (e.kind == .card ? CGPoint(x: f.midX, y: f.midY) : CGPoint(x: f.minX + min(20, f.width * 0.1), y: f.midY))
        let candidates = [first, CGPoint(x: f.minX + min(20, f.width * 0.1), y: f.maxY - min(12, f.height * 0.2)), CGPoint(x: f.midX, y: f.maxY - min(12, f.height * 0.2))]
        let offer = Self.first(in: e.element, depth: 5, where: { ($0.string(kAXIdentifierAttribute) ?? "").contains("offerButton") }).flatMap { TurnOverObject.frame($0) }
        // On screen: inside the page's own area (not under the toolbar or off the bottom).
        let area = visibleArea() ?? wf
        // What is really under the point, asked of the system: the item itself (or a part of it), and never an
        // offer button. An item's reported position can be stale; a click meant for Puzzle once landed on a Get
        // button and brought up Touch ID to install (7 Oct 2026).
        // Under the flat view the engine has just had the hit test agree, patiently; the check here answers blank
        // while the Store is busy and would refuse a row it has confirmed.
        guard let p = candidates.first(where: { c in
            !(offer?.insetBy(dx: -6, dy: -6).contains(c) ?? false) && area.insetBy(dx: 2, dy: 2).contains(c) && (flatDrives || hitIsSafe(c, for: e))
        }) else { Log.io("app store: no safe point on the item to click (area \(area))"); return false }
        let home = CGEvent(source: nil)?.location
        Mouse.click(at: p, button: .left, count: 1)
        if let home { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Mouse.move(to: home) } }
        Log.io("app store: opened \"\(Log.words(String(e.label.prefix(40))))\" by its icon")
        return true
    }

    /// Whether the system's hit test under the row's icon (or its left edge) names this row. Off the main thread.
    nonisolated private func hitAgrees(_ row: AXUIElement, wanted: String) -> Bool {
        guard let f = TurnOverObject.frame(row) else { return false }
        let icon = Self.first(in: row, depth: 5, where: { $0.role == "AXImage" && ($0.string(kAXDescriptionAttribute) ?? "Artwork") != "Artwork" }).flatMap { TurnOverObject.frame($0) }
        let p = icon.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: f.minX + min(20, f.width * 0.1), y: f.midY)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &hit) == .success, let hit else { return false }
        func name(_ s: String) -> String { (s.components(separatedBy: ",").first ?? s).trimmingCharacters(in: .whitespaces) }
        var x: AXUIElement? = hit; var hops = 0
        while let y = x, hops < 8 {
            if CFEqual(y, row) { return true }
            if Self.isItem(y) { return name(Self.identity(of: y)) == wanted }
            x = y.element(kAXParentAttribute); hops += 1
        }
        return false
    }

    private func hitIsSafe(_ p: CGPoint, for e: Entry) -> Bool {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &hit) == .success, let hit else {
            Log.io("app store: nothing found under the click point; not clicking"); return false
        }
        func name(_ s: String) -> String { (s.components(separatedBy: ",").first ?? s).trimmingCharacters(in: .whitespaces) }
        let wanted = name(e.check.isEmpty ? e.label : e.check)
        var x: AXUIElement? = hit
        var hops = 0
        while let y = x, hops < 8 {
            let id = y.string(kAXIdentifierAttribute) ?? ""
            if id.contains("offerButton") { Log.io("app store: the click point is on an offer button; not clicking"); return false }
            if CFEqual(y, e.element) { return true }
            if Self.isItem(y) {
                if name(Self.identity(of: y)) == wanted { return true }
                Log.io("app store: under the click point is \"\(Log.words(name(Self.identity(of: y))))\", not \"\(Log.words(wanted))\"; not clicking"); return false
            }
            x = y.element(kAXParentAttribute); hops += 1
        }
        Log.io("app store: under the click point is not the item (\(hit.role)); not clicking")
        return false
    }

    /// The app's own button. Open, Get, Update and Re-download press at once; a price is a purchase, and needs
    /// Space again within five seconds.
    public func offer() {
        ensureCurrent()
        guard area == .page, page.indices.contains(pageIndex) else { open(); return }
        confirmed(pageIndex) { [weak self] e in if let e { self?.offer(confirmed: e) } }
    }
    private func offer(confirmed e: Entry) {
        // The button as it is now, inside the row just checked (never one remembered from earlier).
        guard let o = Self.first(in: e.element, depth: 5, where: { ($0.string(kAXIdentifierAttribute) ?? "").contains("offerButton") }) else {
            Speech.speakMessage("no button here"); return
        }
        let title = o.string(kAXTitleAttribute) ?? o.string(kAXDescriptionAttribute) ?? ""
        let name = e.label.components(separatedBy: ",").first ?? "this app"
        // Downloading: the button is Cancel now ("2.1% loaded", help "Cancel"). Space and Return only say how far it
        // has got; Delete cancels (two Spaces five seconds apart, checking progress, cancelled Outlook,
        // 14 Oct 2026).
        if Self.isDownloading(title) {
            Speech.speakMessage("\(name), \(title). Delete cancels the download.")
            return
        }
        // Open pressed already and the app still starting (a big app takes seconds): once is enough.
        if title.hasPrefix("Open"), let (n, at) = lastOpen, n == name, Date().timeIntervalSince(at) < 6 {
            Speech.speakMessage("opening \(name)")
            return
        }
        let free = ["Open", "Get", "Update", "Re-download", "Install", "Cancel", "Play"].contains { title.hasPrefix($0) }
        if !free {
            if let (el, at) = pendingBuy, Self.same(el, o), Date().timeIntervalSince(at) < 5 {
                pendingBuy = nil
                _ = AXUIElementPerformAction(o, kAXPressAction as CFString)
                Log.io("app store: buy pressed (confirmed)")
                Speech.speakMessage("buying; the App Store asks you to confirm")
                return
            }
            pendingBuy = (o, Date())
            Speech.speakMessage("Buy \(name) for \(title)? Press Space again to buy.")
            return
        }
        _ = AXUIElementPerformAction(o, kAXPressAction as CFString)
        Log.io("app store: \(Log.words(title)) pressed")
        if title.hasPrefix("Open") { lastOpen = (name, Date()); Speech.speakMessage("opening \(name)") }
        else { Speech.speakMessage(title.components(separatedBy: ",").first ?? title) }
        if !title.hasPrefix("Open") { watchDownload(o, name: name) }
        // Get becomes Install (or starts at once); say what the button says now.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            let now = o.string(kAXTitleAttribute) ?? o.string(kAXDescriptionAttribute) ?? ""
            if !now.isEmpty, now != title { Speech.speakMessage(now == "Install" ? "Install; press Space again to install" : now) }
        }
    }

    /// A download, followed from its button: each quarter as it passes, and the end ("WhatsApp Messenger
    /// installed"), wherever the user is.
    private func watchDownload(_ button: AXUIElement, name: String, lastQuarter: Int = 0, polls: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, polls < 1800 else { return }
            // Rows are reused as the list scrolls: the button counts only while its row still shows this app;
            // otherwise the app's row is looked for on screen.
            func shows(_ b: AXUIElement) -> Bool { b.element(kAXParentAttribute).map { Self.identity(of: $0).hasPrefix(name) } ?? false }
            var o = button
            if !shows(o) {
                guard let list = self.pageRoot()?.list, let row = Self.first(in: list, depth: 6, where: { Self.isItem($0) && Self.identity(of: $0).hasPrefix(name) }),
                      let b = Self.first(in: row, depth: 5, where: { ($0.string(kAXIdentifierAttribute) ?? "").contains("offerButton") }) else {
                    self.watchDownload(button, name: name, lastQuarter: lastQuarter, polls: polls + 1); return
                }
                o = b
            }
            let t = o.string(kAXTitleAttribute) ?? ""
            if t.hasPrefix("Open") {
                Tones.beep(880, 80); Speech.speakMessage("\(name) installed")
                Log.io("app store: \(Log.words(name)) installed")
                return
            }
            if t.hasPrefix("Get") || t.hasPrefix("Re-download") || t.hasPrefix("Update") {
                if polls > 2 { Speech.speakMessage("\(name): download stopped") }
                return
            }
            var quarter = lastQuarter
            if let r = t.range(of: #"^[\d.]+"#, options: .regularExpression), let pct = Double(t[r]) {
                let q = Int(pct / 25)
                if q > lastQuarter, q < 4 { quarter = q; Speech.speakMessage("\(name), \(q * 25) percent") }
            }
            self.watchDownload(o, name: name, lastQuarter: quarter, polls: polls + 1)
        }
    }

    public func back() {
        let before = currentKey()
        // The Back button in the window's toolbar (a card over the window has one too).
        if let w = window, let tb = w.elements(kAXChildrenAttribute).first(where: { $0.role == "AXToolbar" }),
           let b = Self.first(in: tb, depth: 3, where: { $0.role == "AXButton" && ($0.string(kAXDescriptionAttribute) == "Back" || ($0.string(kAXIdentifierAttribute) ?? "").hasSuffix("backButton")) }) {
            _ = AXUIElementPerformAction(b, kAXPressAction as CFString)
        } else {
            Speech.speakMessage("no page to go back to"); return
        }
        area = .page
        waitForNewPage(from: before, back: true)
    }

    public func focusSearch() {
        buildSidebar()
        guard let s = sidebar.first(where: { $0.kind == .search }) else { Speech.speakMessage("no search field"); return }
        let r = s.element.set(kAXFocusedAttribute, kCFBooleanTrue)
        Log.io("app store: search field focused (\(r.rawValue))")
        if r != .success { Speech.speakMessage("could not reach the search field") }
    }

    /// After Return in the search field: wait for the results, read them, and give the keys back to the page.
    public func afterSearch() {
        let before = currentKey()
        area = .page
        searching = true
        waitForNewPage(from: before, thenFocusPage: true)
    }
    /// A search is under way: the results are read when they come, whatever keys are pressed meanwhile.
    private var searching = false

    private var lastPositions: [String: Int] = [:]
    /// The page's title when it was read (the title now may already be the next page's).
    private var builtTitle = ""

    /// A new page comes a moment after the click; read its title and first item once it has settled.
    private func settleResults(key: String, wave: Int) {
        let delay = wave == 1 ? 0.7 : 0.8
        let names = page.map { $0.label }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.area == .page, self.currentKey() == key else { return }
            let current = page.indices.contains(pageIndex) ? page[pageIndex].label : ""
            self.buildPage()
            let changed = page.map { $0.label } != names
            if changed {
                Log.io("app store: the results changed as they settled (\(names.count) → \(page.count) items); read again")
                if let i = page.firstIndex(where: { $0.label == current }) { pageIndex = i } else { pageIndex = min(pageIndex, max(0, page.count - 1)) }
            }
            if wave < 2 { self.settleResults(key: key, wave: 2) }
        }
    }

    private func waitForNewPage(from before: String, back: Bool = false, thenFocusPage: Bool = false, tries: Int = 0, moves startMoves: Int? = nil) {
        // The place on this page, by its title (the collection element is a new one when the page comes back).
        if tries == 0, !builtTitle.isEmpty { lastPositions[builtTitle] = pageIndex }
        let start = startMoves ?? moves
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            let moved = self.moves != start && !self.searching
            let now = self.currentKey()
            // The same search again leaves the same page: after a moment, read it all the same.
            let limit = thenFocusPage ? 20 : 16
            if (now == before || now.isEmpty) && tries < limit { self.waitForNewPage(from: before, back: back, thenFocusPage: thenFocusPage, tries: tries + 1, moves: start); return }
            let fromSearch = self.searching
            self.area = .page
            self.searching = false
            // A new search gives the same list element and title ("Results for …"): the flat view starts over.
            if fromSearch { self.flatKey = "" }
            self.buildPage()
            // Keys pressed while waiting were on the old page: the new page starts at its top (or where it was left).
            self.pageIndex = back ? min(self.lastPositions[self.pageTitle] ?? 0, max(0, self.page.count - 1)) : 0
            // Search results arrive in stages: the first read of "water" had 23 items starting with one app, the
            // screen a moment later 25 starting with another, and Return then looked for rows the page no longer had
            // (27 Oct 2026). Looked at again after 0.7 s and 1.5 s: a different list is read again, quietly, the
            // place kept by name.
            self.settleResults(key: now, wave: 1)
            _ = moved
            if thenFocusPage, let (_, list) = self.pageRoot() { _ = list.set(kAXFocusedAttribute, kCFBooleanTrue) }
            let title = self.pageTitle
            if now == before, !thenFocusPage { Log.io("app store: the page did not change"); return }
            Speech.speakMessage(title.isEmpty ? "page" : title)
            if !self.page.isEmpty, !self.flatDrives { self.speak(self.pageIndex, crossing: true) }   // the flat view says its first row itself
        }
    }
}

nonisolated extension Array {
    mutating func removeSubrange(_ r: Range<Int>, where test: (Element) -> Bool) {
        let keep = self[r].filter { !test($0) }
        replaceSubrange(r, with: keep)
    }
}
