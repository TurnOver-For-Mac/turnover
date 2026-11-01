// SPDX-License-Identifier: GPL-3.0-or-later
// A request's mutable builder is created and consumed entirely on the model owner's serial worker.
// Its result is a value; none of these methods reaches AppStoreView's main-actor state (#54, 28 Oct 2026).
import Foundation
import AppKit
import ApplicationServices
import TurnOverAX

nonisolated package final class AppStoreAXModelSource: AppStoreModelSource, Sendable {
    let pid: pid_t
    private let makeNavigation: @Sendable (AXNavigationChildren.Limits, @escaping @Sendable () -> Bool) -> AXNavigationChildren
    package init(pid: pid_t,
                 makeNavigation: @escaping @Sendable (AXNavigationChildren.Limits, @escaping @Sendable () -> Bool) -> AXNavigationChildren = {
                     AXNavigationChildren(limits: $0, current: $1)
                 }) { self.pid = pid; self.makeNavigation = makeNavigation }
    package func read(_ request: AppStoreModelRequest, current: @escaping @Sendable () -> Bool) -> AppStoreModelResult? {
        // Navigation collection is bounded independently of legacy label/action helpers. End deliberately loads
        // several shelves; resolve/more can deliberately wait for materialization, so preserve those waits rather
        // than reporting an empty complete model after the preview's shorter allowance (28 Oct 2026, issue 174).
        let limits: AXNavigationChildren.Limits
        switch request.operation {
        case .end: limits = .init(durationNanoseconds: 30_000_000_000, queries: 8192, nodes: 12000)
        case .more, .carousel, .resolve: limits = .init(durationNanoseconds: 6_000_000_000)
        default: limits = .init()
        }
        let builder = AppStorePageBuilder(pid: pid, model: request.model, current: current, navigation: makeNavigation(limits, current))
        return builder.read(request.operation)
    }
}

nonisolated final class AppStorePageBuilder {
    static func root(pid: pid_t) -> (scroll: AXUIElement, list: AXUIElement)? {
        AppStorePageBuilder(pid: pid, model: AppStoreModel(), current: { true }).pageRoot()
    }
    private let pid: pid_t
    private let requestCurrent: @Sendable () -> Bool
    private let navigation: AXNavigationChildren
    private func current() -> Bool { requestCurrent() && navigation.check() }
    private func children(_ element: AXUIElement) -> [AXUIElement] { navigation.children(of: element) }
    private func first(in element: AXUIElement, depth: Int, where predicate: (AXUIElement) -> Bool) -> AXUIElement? {
        navigation.first(in: element, depth: depth) {
            guard current() else { return false }
            let match = predicate($0)
            return current() && match
        }
    }
    private var page: [AppStoreView.Entry]
    private var shelves: [String]
    private var sidebar: [AppStoreView.Entry]
    private var seen: [AXUIElement]
    private var lastSection: AXUIElement?
    private var nextSection: AXUIElement?
    private var tails: [Int: AXUIElement]
    private var pageKey: String
    private var identityChanged = false
    private var app: AXUIElement {
        let e = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(e, 0.3); return e
    }
    private var window: AXUIElement? {
        guard current(), let w = app.element(kAXFocusedWindowAttribute) ?? app.element(kAXMainWindowAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(w, 0.3); return w
    }
    private var card: AXUIElement? { window.flatMap { children($0).first { ($0.string(kAXIdentifierAttribute) ?? "").hasSuffix("pageBaseCardView") } } }
    private func known(_ e: AXUIElement) -> Bool { seen.contains { CFEqual($0, e) } }
    private typealias Entry = AppStoreView.Entry
    init(pid: pid_t, model: AppStoreModel, current: @escaping @Sendable () -> Bool,
         navigation: AXNavigationChildren? = nil) {
        self.pid = pid; self.requestCurrent = current
        self.navigation = navigation ?? AXNavigationChildren(current: current)
        page = model.page; shelves = model.shelves; sidebar = model.sidebar
        seen = model.seen; lastSection = model.lastSection; nextSection = model.nextSection; tails = model.tails
        pageKey = model.key
    }
    private func metadata() -> AppStorePageMetadata {
        guard current(), let (_, list) = pageRoot() else { return .init(key: "") }
        guard current() else { return .init(key: "") }
        let key = currentKey()
        guard current() else { return .init(key: "") }
        let result = AppStorePageMetadata(key: key, title: pageTitle, rootIdentifier: list.string(kAXIdentifierAttribute) ?? "", hasCard: card != nil)
        return current() ? result : .init(key: "")
    }
    private func snapshot(_ metadata: AppStorePageMetadata) -> AppStoreModel {
        var m = AppStoreModel()
        m.page = page; m.shelves = shelves; m.sidebar = sidebar
        m.key = metadata.key; m.title = metadata.title; m.rootIdentifier = metadata.rootIdentifier; m.hasCard = metadata.hasCard
        m.seen = seen; m.lastSection = lastSection; m.nextSection = nextSection; m.tails = tails
        return m
    }
    func read(_ operation: AppStoreModelRequest.Operation) -> AppStoreModelResult? {
        guard current() else { return nil }
        let before = metadata()
        if case .metadata = operation { return current() ? .init(metadata: before) : nil }
        guard !before.key.isEmpty || pageKey.isEmpty else { return nil }   // keep a usable model when the app is busy
        let rebuilding: Bool
        if case .page = operation { rebuilding = true } else if case .sidebar = operation { rebuilding = true } else { rebuilding = false }
        guard rebuilding || pageKey.isEmpty || before.key == pageKey else { return nil }
        var more = false
        var resolved: Entry?
        switch operation {
        case .page(let skip):
            buildPage(skipFlatResults: skip)
        case .sidebar:
            buildSidebar()
        case .more:
            more = loadMore()
        case .end:
            var n = 0
            while current(), n < 30, loadMore() { more = true; n += 1 }
        case .carousel(let shelf):
            more = extendShelf(shelf)
        case .resolve(let entry, let index):
            let matches = AppStoreEntryIdentity.indices(for: entry, in: page)
            if matches.count == 1, let matched = matches.first {
                resolved = resolve(page[matched], index: matched)
                if let resolved { page[matched] = resolved }
            }
            _ = index   // a hint from the captured page, never the identity of a later row
        case .metadata: break
        }
        guard current() else { return nil }
        let after = metadata()
        guard current(), before.key == after.key else { return nil }
        return .init(model: snapshot(after), metadata: after, resolved: resolved, more: more, needsRefresh: identityChanged)
    }
    private func resolve(_ entry: Entry, index: Int) -> Entry? {
        func name(_ value: String) -> String { (value.components(separatedBy: ",").first ?? value).trimmingCharacters(in: .whitespaces) }
        let wanted = name(entry.check.isEmpty ? entry.label : entry.check)
        guard !wanted.isEmpty, current() else { return nil }
        var row: AXUIElement?
        if entry.kind == .app || entry.kind == .card {
            row = bringIntoView(index, name: wanted)
            if let row {
                for _ in 0..<4 {
                    guard current() else { return nil }
                    if hitAgrees(row, wanted: wanted) { break }
                    usleep(250_000)
                }
            }
        } else {
            guard current() else { return nil }
            if let section = entry.section, !AppStoreView.isInside(entry.element, section) { return nil }
            reveal(entry); usleep(250_000)
            guard current() else { return nil }
            if let section = entry.section, !AppStoreView.isInside(entry.element, section) { return nil }
            guard current() else { return nil }
            if name(AppStoreView.identity(of: entry.element)) == wanted { row = entry.element }
        }
        guard current(), let row else { return nil }
        let observed = AppStoreView.identity(of: row)
        guard current() else { return nil }
        guard AppStoreEntryIdentity.fullText(observed) == AppStoreEntryIdentity.fullIdentity(entry) else {
            identityChanged = true
            return nil
        }
        var resolved = entry; resolved.element = row; resolved.check = observed
        return resolved
    }

    private func pageRoot() -> (scroll: AXUIElement, list: AXUIElement)? {
        guard let w = window else { return nil }
        // A card over the whole window (a category such as Arcade's Family: AppStore.productPage.pageBaseCardView
        // beside its own scroll area, and no sidebar): its page is the window's own scroll area.
        if children(w).contains(where: { ($0.string(kAXIdentifierAttribute) ?? "").hasSuffix("pageBaseCardView") }),
           let s = children(w).first(where: { $0.role == "AXScrollArea" }),
           let list = first(in: s, depth: 4, where: { $0.role == "AXList" && $0.string(kAXSubroleAttribute) == "AXCollectionList" }) { return (s, list) }
        guard let split = children(w).first(where: { $0.role == "AXSplitGroup" }) else { return nil }
        // The page's container is an AXScrollArea, or (seen after a relaunch, 6 Oct 2026) an AXGroup with the
        // scroll actions; the sidebar is a group of its own, or its parts sit loose beside the page.
        for s in children(split) where s.role == "AXScrollArea" || s.role == "AXGroup" {
            if let list = first(in: s, depth: 4, where: { $0.role == "AXList" && $0.string(kAXSubroleAttribute) == "AXCollectionList" }) { return (s, list) }
        }
        // No collection: a page of its own ("Cannot Connect … Retry", AppStore.error), read as it is.
        for s in children(split) where s.role == "AXScrollArea" || s.role == "AXGroup" {
            if let area = first(in: s, depth: 2, where: { $0.role == "AXScrollArea" && (($0.string(kAXIdentifierAttribute) ?? "").hasPrefix("AppStore.") || !children($0).isEmpty) }) { return (area, area) }
        }
        return nil
    }

    private func currentKey() -> String {
        guard let (_, list) = pageRoot() else { return "" }
        return "\(CFHash(list))|\(list.string(kAXIdentifierAttribute) ?? "")|\(list.string(kAXDescriptionAttribute) ?? "")"
    }

    private var pageTitle: String {
        guard let (scroll, list) = pageRoot() else { return "" }
        if let c = card, let d = c.string(kAXDescriptionAttribute), !d.isEmpty { return AppStoreView.tidy(d) }
        // The pages named by what they are (Updates' collection calls itself "Details" in one layout).
        let named = ["AppStore.updates": "Updates", "AppStore.discover": "Discover", "AppStore.arcade": "Arcade", "AppStore.error": "Cannot connect"]
        if let n = named[list.string(kAXIdentifierAttribute) ?? ""] { return n }
        if let p = first(in: list, depth: 4, where: { ($0.string(kAXIdentifierAttribute) ?? "").hasSuffix("shelfItemSubComponent.title") }), let v = p.string(kAXValueAttribute) { return v }
        if let h = first(in: scroll, depth: 4, where: { $0.role == "AXHeading" && !AppStoreView.isInside($0, list) }), let d = h.string(kAXDescriptionAttribute) ?? h.string(kAXValueAttribute) { return d }
        return list.string(kAXDescriptionAttribute) ?? ""
    }

    private func buildPage(skipFlatResults: Bool) {
        let start = Date()
        page = []; shelves = []
        guard let (scroll, list) = pageRoot() else { pageKey = ""; return }
        seen = []; lastSection = nil; nextSection = nil; tails = [:]
        if skipFlatResults, list.string(kAXIdentifierAttribute) == "AppStore.search.result" {
            pageKey = currentKey(); return
        }
        // Above the collection: the page's heading and its buttons.
        for c in children(scroll) where c.role == "AXGroup" && !CFEqual(scroll, list) {
            for b in children(c) where b.role == "AXButton" {
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
            for k in page.indices where page[k].check.isEmpty { page[k].check = AppStoreView.identity(of: page[k].element) }
        } else if let visible = first(in: list, depth: 2, where: { $0.string(kAXSubroleAttribute) == "AXSectionList" }) {
            var top = visible; var hops = 0
            while current(), let p = top.element("AXPreviousContentSibling"), hops < 200 { top = p; hops += 1 }
            addSections(from: top, limit: AppStoreView.batch, deferEmptyMaterialization: true)
        }
        pageKey = currentKey()
        Log.io("app store: page \"\(Log.words(pageTitle))\", \(shelves.filter { !$0.isEmpty }.count) shelves, \(page.count) items in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
    }

    private func addSections(from start: AXUIElement, limit: Int, deferEmptyMaterialization: Bool = false) {
        var section: AXUIElement? = start
        var count = 0
        let stopAt = page.count + limit
        nextSection = nil
        while let sec = section, count < 80, current() {
            AXUIElementSetMessagingTimeout(sec, 0.3)
            if page.count >= stopAt { nextSection = sec; return }
            count += 1
            let name = AppStoreView.shelfName(sec.string(kAXDescriptionAttribute) ?? "")
            let shelf = shelves.count
            shelves.append(name)
            let before = page.count
            let seenBefore = seen.count
            walk(sec, shelf: shelf, section: sec, known: known, mark: { self.seen.append($0) })
            // A shelf far from the screen is an empty shell until it comes near: bring it into view, read again.
            var tries = 0
            while current(), page.count == before, tries < 2, children(sec).count <= 1 || (sec.string(kAXDescriptionAttribute) ?? "").isEmpty {
                guard current() else { return }
                if deferEmptyMaterialization, before > 0 {
                    // A readable prefix is ready. Initial product-page collection took 1.6–1.9 s in Oliver's
                    // trial (28 Oct 2026); this retry path adds 250 ms waits before publication. Leave this exact
                    // shelf for more/End; they retain the existing eager materialization and reading order.
                    shelves.removeLast()
                    seen.removeSubrange(seenBefore..<seen.count)
                    tails.removeValue(forKey: shelf)
                    nextSection = sec
                    Log.io("app store: deferred empty shelf after \(before) readable items")
                    return
                }
                _ = AXUIElementPerformAction(sec, "AXScrollToVisible" as CFString)
                usleep(250_000); tries += 1
                shelves[shelf] = AppStoreView.shelfName(sec.string(kAXDescriptionAttribute) ?? "")
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
            for k in before..<page.count where page[k].check.isEmpty { page[k].check = AppStoreView.identity(of: page[k].element) }
            lastSection = sec
            section = sec.element("AXNextContentSibling")
        }
    }

    private func loadMore() -> Bool {
        let before = page.count
        if let next = nextSection { addSections(from: next, limit: AppStoreView.batch); if page.count > before { return true } }
        guard let last = lastSection else { return false }
        // Into view: the shelf, then its last item, so the shelves after it are made.
        let targets = [last] + Array(children(last).suffix(1))
        for t in targets {
            guard current() else { return false }
            _ = AXUIElementPerformAction(t, "AXScrollToVisible" as CFString)
            for _ in 0..<4 {
                guard current() else { return false }
                usleep(200_000)
                guard current() else { return false }
                if let next = last.element("AXNextContentSibling") { addSections(from: next, limit: AppStoreView.batch); break }
            }
            if page.count > before { break }
        }
        Log.io("app store: read on past \"\(Log.words(AppStoreView.shelfName(last.string(kAXDescriptionAttribute) ?? "")))\": \(page.count - before) more")
        return page.count > before
    }

    private func extendShelf(_ shelf: Int) -> Bool {
        guard let tail = tails[shelf], let lastIndex = page.lastIndex(where: { $0.shelf == shelf }) else { return false }
        tails[shelf] = nil
        let section = page[lastIndex].section ?? tail
        var added: [Entry] = []
        var item = tail.element("AXNextContentSibling")
        var lastRead = tail
        var n = 0
        while let it = item, current(), n < 30, AppStoreView.isItem(it), !known(it) {
            seen.append(it)
            added += AppStoreView.entries(for: it, shelf: shelf, section: section)
            lastRead = it
            item = it.element("AXNextContentSibling"); n += 1
        }
        if let more = item, AppStoreView.isItem(more), !known(more) { tails[shelf] = lastRead }
        for k in added.indices { added[k].check = AppStoreView.identity(of: added[k].element) }
        page.insert(contentsOf: added, at: lastIndex + 1)
        return !added.isEmpty
    }

    private func walk(_ e: AXUIElement, shelf: Int, section: AXUIElement, known: (AXUIElement) -> Bool, mark: (AXUIElement) -> Void,
                      depth: Int = 0, ancestors: Set<ElementKey> = []) {
        let key = ElementKey(e)
        guard !ancestors.contains(key) else { navigation.stop(.cycle); return }
        guard depth < 8 else { navigation.stop(.depthLimit); return }
        let ancestors = ancestors.union([key])
        for c in children(e) {
            guard current() else { return }
            AXUIElementSetMessagingTimeout(c, 0.3)
            if known(c) { continue }
            let role = c.role, id = c.string(kAXIdentifierAttribute) ?? ""
            if id.contains("shelfItem"), !id.contains("SubComponent") {
                // The item and, from it, the start of its carousel; the rest when the arrows get there. A list
                // scrolled down shows only its middle: back to its first item first.
                var head = c; var back = 0
                while current(), let p = head.element("AXPreviousContentSibling"), AppStoreView.isItem(p), !known(p), back < 400 { head = p; back += 1 }
                var item: AXUIElement? = head
                var n = 0
                var lastRead: AXUIElement?
                while let it = item, current(), n < AppStoreView.perCarousel, !known(it), AppStoreView.isItem(it) {
                    mark(it)
                    page += AppStoreView.entries(for: it, shelf: shelf, section: section)
                    lastRead = it
                    item = it.element("AXNextContentSibling"); n += 1
                }
                if let lastRead, let more = item, AppStoreView.isItem(more), !known(more) { tails[shelf] = lastRead }
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
                if !t.isEmpty, page.last?.label != t, t != shelves[shelf] { page.append(Entry(label: AppStoreView.tidy(t), element: c, kind: .text, shelf: shelf, section: section)) }
            case "AXImage":
                continue
            default:
                walk(c, shelf: shelf, section: section, known: known, mark: mark, depth: depth + 1, ancestors: ancestors)
            }
        }
    }

    private func buildSidebar() {
        _ = 0
        sidebar = []
        guard let w = window, let split = children(w).first(where: { $0.role == "AXSplitGroup" }) else { return }
        let page = pageRoot()?.scroll
        func visit(_ c: AXUIElement, _ depth: Int) {
            if let page, CFEqual(c, page) { return }
            if c.string(kAXSubroleAttribute) == "AXSearchField" {
                let v = (c.attr(kAXValueAttribute) as? String) ?? ""
                sidebar.append(Entry(label: v.isEmpty ? "Search" : "Search, \(v)", element: c, kind: .search, shelf: 0))
            } else if c.role == "AXOutline" {
                for row in children(c) where row.role == "AXRow" {
                    guard let cell = children(row).first, let d = cell.string(kAXDescriptionAttribute) else { continue }
                    let selected = (row.attr(kAXSelectedAttribute) as? Bool) == true
                    sidebar.append(Entry(label: d + (selected ? ", selected" : ""), element: cell, kind: .tab, shelf: 0))
                }
            } else if (c.string(kAXIdentifierAttribute) ?? "") == "AppStore.accountButton", let t = c.string(kAXTitleAttribute) {
                sidebar.append(Entry(label: "Account, \(t)", element: c, kind: .account, shelf: 0))
            } else if depth < 2, c.role == "AXGroup" {
                for k in children(c) { visit(k, depth + 1) }
            }
        }
        for c in children(split) { visit(c, 0) }
    }

    private func pageFrame() -> CGRect? {
        guard let (scroll, list) = pageRoot() else { return nil }
        if let f = TurnOverObject.frame(scroll), f.width > 10, f.height > 10 { return f }
        if let f = TurnOverObject.frame(list), f.width > 10, f.height > 10 { return f }
        return window.flatMap { TurnOverObject.frame($0) }
    }

    private func onScreen(_ x: AXUIElement) -> Bool {
        guard let f = TurnOverObject.frame(x), f.height > 4, let area = pageFrame() else { return false }
        return area.contains(CGPoint(x: f.midX, y: f.midY))
    }

    private func visibleRows() -> [AXUIElement] {
        guard let (_, list) = pageRoot() else { return [] }
        var out: [AXUIElement] = []
        func go(_ x: AXUIElement, _ d: Int) {
            guard current(), d < 5 else { return }
            for c in children(x) {
                guard current() else { return }
                AXUIElementSetMessagingTimeout(c, 0.3)
                if AppStoreView.isItem(c) { out.append(c) } else { go(c, d + 1) }
            }
        }
        go(list, 0)
        return out
    }

    private func bringIntoView(_ i: Int, name wanted: String) -> AXUIElement? {
        func name(_ s: String) -> String { (s.components(separatedBy: ",").first ?? s).trimmingCharacters(in: .whitespaces) }
        func lookOnScreen() -> AXUIElement? { visibleRows().first { name(AppStoreView.identity(of: $0)) == wanted && onScreen($0) } }
        if let r = lookOnScreen() { return r }
        let rows = visibleRows()
        Log.io("app store: \(rows.count) rows on screen; names \(rows.prefix(6).map { "\"\(Log.words(name(AppStoreView.identity(of: $0))))\"\(onScreen($0) ? "" : " (off)")" }.joined(separator: ", ")); root \(pageRoot().map { "\($0.scroll.role) > \($0.list.role)" } ?? "none")")
        guard let (scroll, _) = pageRoot() else { return nil }
        guard let bar = scroll.element(kAXVerticalScrollBarAttribute) else {
            // No scroll bar to drive (the search results' group): the row itself, or its list, asked to scroll into
            // view; then a look at what is on screen.
            if let row = rows.first(where: { name(AppStoreView.identity(of: $0)) == wanted }) ?? page[i].element as AXUIElement? {
                guard current() else { return nil }
                _ = AXUIElementPerformAction(row, "AXScrollToVisible" as CFString)
                usleep(200_000)
                guard current() else { return nil }
                if let r = lookOnScreen() { Log.io("app store: \"\(Log.words(wanted))\" scrolled into view"); return r }
            }
            return nil
        }
        var lo = 0.0, hi = 1.0
        var at = Double(i) / Double(max(1, page.count - 1))
        for step in 0..<10 {
            guard current() else { return nil }
            _ = bar.set(kAXValueAttribute, NSNumber(value: min(1, max(0, at))))
            usleep(180_000)
            if let r = lookOnScreen() { Log.io("app store: \"\(Log.words(wanted))\" brought on screen in \(step + 1) steps"); return r }
            // Which items are on screen: above or below the one wanted?
            let shown = visibleRows().compactMap { row -> Int? in let n = name(AppStoreView.identity(of: row)); return page.firstIndex { name($0.label) == n } }
            guard let lowest = shown.min(), let highest = shown.max() else { at = (lo + hi) / 2; continue }
            if i < lowest { hi = at } else if i > highest { lo = at } else { break }
            at = (lo + hi) / 2
        }
        return lookOnScreen()
    }

    private func reveal(_ e: Entry) {
        guard current() else { return }
        if let s = e.section { _ = AXUIElementPerformAction(s, "AXScrollToVisible" as CFString) }
        guard current() else { return }
        _ = AXUIElementPerformAction(e.element, "AXScrollToVisible" as CFString)
    }

    private func hitAgrees(_ row: AXUIElement, wanted: String) -> Bool {
        guard let f = TurnOverObject.frame(row) else { return false }
        let icon = first(in: row, depth: 5, where: { $0.role == "AXImage" && ($0.string(kAXDescriptionAttribute) ?? "Artwork") != "Artwork" }).flatMap { TurnOverObject.frame($0) }
        let p = icon.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: f.minX + min(20, f.width * 0.1), y: f.midY)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &hit) == .success, let hit else { return false }
        func name(_ s: String) -> String { (s.components(separatedBy: ",").first ?? s).trimmingCharacters(in: .whitespaces) }
        var x: AXUIElement? = hit; var hops = 0
        while let y = x, hops < 8 {
            if CFEqual(y, row) { return true }
            if AppStoreView.isItem(y) { return name(AppStoreView.identity(of: y)) == wanted }
            x = y.element(kAXParentAttribute); hops += 1
        }
        return false
    }
}

