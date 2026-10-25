// SPDX-License-Identifier: GPL-3.0-or-later
// The App Store's page and sidebar as TurnOver reads them (AppStoreAppModule has the keys and the story).
import Foundation
import AppKit
import ApplicationServices

public final class AppStoreView {
    /// ", selected" in the reader's language: added to the sidebar's selected entry, and found and taken off by it.
    nonisolated static var selectedSuffix: String { ", " + State.selected.displayString }
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
        public init(label: String, element: AXUIElement, kind: Kind, shelf: Int,
                    offer: AXUIElement? = nil, section: AXUIElement? = nil, check: String = "", offerTitle: String = "") {
            self.label = label; self.element = element; self.kind = kind; self.shelf = shelf
            self.offer = offer; self.section = section; self.check = check; self.offerTitle = offerTitle
        }
    }
    public enum Area { case sidebar, page }

    public let pid: pid_t
    var area: Area = .page
    public var page: [Entry] { modelOwner.model.page }
    public var shelves: [String] { modelOwner.model.shelves }
    private var sidebar: [Entry] { modelOwner.model.sidebar }
    private lazy var modelOwner: AppStoreModelOwner = {
        let owner = AppStoreModelOwner(pid: pid)
        owner.onApply = { [weak self] old, new in self?.applied(old, new) }
        return owner
    }()
    private var active = true
    private var canUseResult: Bool {
        active && Core.active && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }
    private func acceptsCurrentPage() -> Bool {
        guard canUseResult else { stop(); return false }
        return true
    }
    private var checkedAt = Date.distantPast
    private var sidebarBuiltAt = Date.distantPast
    private var pageIndex = 0, sideIndex = 0
    private var pageKey: String { modelOwner.model.key }
    private var purchaseConfirmation = AppStorePurchaseConfirmation()
    private var lastOpen: (String, Date)?

    nonisolated static func isDownloading(_ title: String) -> Bool {
        title.contains("%") || ["Loading", "Waiting", "Installing", "Preparing"].contains(where: { title.hasPrefix($0) })
    }

    /// Delete on an app that is downloading: cancels it (the only key that does).
    public func cancelDownload() {
        purchaseConfirmation.reset()
        guard ensureCurrent(retry: { [weak self] in self?.cancelDownload() }) else { return }
        guard area == .page, page.indices.contains(pageIndex) else { Speech.speakMessage(String(localized: "nothing downloading here", comment: "Spoken message")); return }
        confirmed(pageIndex) { e in
            guard let e, let o = Self.first(in: e.element, depth: 5, where: { ($0.string(kAXIdentifierAttribute) ?? "").contains("offerButton") }) else { return }
            let title = o.string(kAXTitleAttribute) ?? o.string(kAXDescriptionAttribute) ?? ""
            guard self.acceptsCurrentPage() else { return }
            guard Self.isDownloading(title) else { Speech.speakMessage(String(localized: "nothing downloading here", comment: "Spoken message")); return }
            _ = AXUIElementPerformAction(o, kAXPressAction as CFString)
            Log.io("app store: download cancelled with Delete")
            Speech.speakMessage(String(localized: "download cancelled", comment: "Spoken message"))
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
        AppStorePageBuilder.root(pid: pid)
    }

    nonisolated static func first(in e: AXUIElement, depth: Int, where test: (AXUIElement) -> Bool) -> AXUIElement? {
        if test(e) { return e }
        guard depth > 0 else { return nil }
        for c in e.elements(kAXChildrenAttribute) { if let f = first(in: c, depth: depth - 1, where: test) { return f } }
        return nil
    }

    nonisolated static func same(_ a: AXUIElement, _ b: AXUIElement) -> Bool { CFEqual(a, b) }

    /// Whether an element is inside another (a shelf's heading is inside the page's collection; the page's own
    /// heading is above it).
    nonisolated static func isInside(_ e: AXUIElement, _ container: AXUIElement) -> Bool {
        var p = e.element(kAXParentAttribute); var n = 0
        while let x = p, n < 30 { if CFEqual(x, container) { return true }; p = x.element(kAXParentAttribute); n += 1 }
        return false
    }

    /// What identifies the page: the collection element itself, its identifier and its name ("Results for …").
    /// Nothing that scrolling changes: a heading in view did, and every key read the whole page again (6 Oct 2026).
    private func currentKey() -> String { pageKey }

    /// The card over the window, if one is showing (its description names it: "Family, APPLE ARCADE").
    private var hasCard: Bool { modelOwner.model.hasCard }

    public var pageTitle: String { modelOwner.model.title }

    /// The page, shelf by shelf, a little at a time: the heading's area above the collection (Updates: "Update
    /// All"), then the shelves reached by AXNextContentSibling, until there are enough to start with. The rest is read
    /// as the arrows reach it (reading all 529 items of Discover at once took 5 s and froze TurnOver, 6 Oct 2026).
    // MARK: The flat view (developer switch `flatView`; docs/FLAT-VIEW-PLAN.md)

    /// The results page's host while a search results page is up; the old page machinery stands down meanwhile.
    private var results: AppStoreResults?
    private var resultsKey = ""
    private var flatDrives: Bool { results != nil || catalogDrives }
    private var flatOn: Bool { Edition.devDefault("flatView") }

    /// The catalog's answers for the latest search (AppStoreCatalog.swift): the results page's host while the
    /// Store shows that search's results, instead of the page's own rows.
    private var catalog: Catalog?
    private var catalogDrives = false
    /// The page just asked for by name: its title is not said again when it comes.
    private var openingTitle = ""

    /// A search is going out: the catalog is asked at the same time, and answers the results page.
    private func catalogSearch(term raw: String) {
        guard flatOn else { return }
        let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { Log.io("app store catalog: no term to search for"); return }
        catalog?.cancel()
        resultsEnd()   // the page's own reading stands down: the catalog answers this search
        let c = Catalog(kind: .apps, term: term, open: { [weak self] app in self?.openCatalogApp(app) },
                                fallBack: { [weak self] why in
                                    guard let self else { return }
                                    if why != "nothing found" { Speech.speakMessage(String(localized: "The catalog did not answer: \(why). Reading the page.", comment: "Spoken message")) }
                                    catalog = nil; catalogDrives = false; resultsKey = ""; buildPage()
                                })
        catalog = c; catalogDrives = true
        c.search()
    }
    /// A catalog result chosen: the Store opens its page by id, from wherever it is.
    private func openCatalogApp(_ app: Catalog.Entry) {
        let before = pageKey
        catalogDrives = false
        NSWorkspace.shared.open(app.url)
        Log.io("app store catalog: opening \"\(Log.words(app.name.prefix(40).description))\"")
        // Said at once: the Store takes two or three seconds to bring the page, and its first item is said when
        // the page has been read, so the person hears the start and the end of the wait.
        Speech.speakMessage(String(localized: "Opening \(app.name)", comment: "Spoken message"))
        openingTitle = app.name
        waitForNewPage(from: before)
    }

    private func resultsBegin() {
        if results == nil {
            results = AppStoreResults(pid: pid) { [weak self] name, point in self?.openResolvedRow(name, at: point) }
        }
        guard resultsKey != pageKey else { return }   // the same page read again: the host's own waves go on
        resultsKey = pageKey
        Log.io("app store: the results page is the flat view's")
        results?.start()
    }
    private func resultsEnd() {
        guard let r = results else { return }
        r.stop(); results = nil; resultsKey = ""
        Log.io("app store: the flat view hands the page back")
    }
    /// A row the host resolved: clicked at the point the system's hit test confirmed, the new page waited for.
    private func openResolvedRow(_ name: String, at p: CGPoint) {
        guard acceptsCurrentPage() else { return }
        let before = pageKey
        let home = CGEvent(source: nil)?.location
        Mouse.click(at: p, button: .left, count: 1)
        if let home { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Mouse.move(to: home) } }
        Log.io("app store: opened \"\(Log.words(name.prefix(40).description))\" at the point the hit test confirmed")
        waitForNewPage(from: before)
    }

    public func buildPage(then: @escaping @MainActor @Sendable () -> Void = {}) {
        modelOwner.read(.page(skipFlatResults: flatOn)) { [weak self] _ in
            guard let self, canUseResult else { return }
            checkedAt = Date()
            if flatOn, modelOwner.model.rootIdentifier == "AppStore.search.result" {
                if let c = catalog, c.failed == nil { catalogDrives = true; resultsEnd() }
                else { resultsBegin() }
            } else {
                catalogDrives = false; resultsEnd()
            }
            then()
        }
    }

    private func applied(_ old: AppStoreModel, _ new: AppStoreModel) {
        guard canUseResult else { stop(); return }
        if old.key != new.key { purchaseConfirmation.reset() }
        let selection = new.retainingPageSelection(from: old, index: pageIndex)
        pageIndex = selection.index
        if !selection.retained { purchaseConfirmation.reset() }
        sideIndex = min(sideIndex, max(0, new.sidebar.count - 1))
    }

    public func stop() {
        active = false; modelOwner.stop(); purchaseConfirmation.reset()
        resultsEnd(); catalog?.cancel()
    }

    public func beginSession() { active = true; invalidatePage() }

    private func invalidatePage() {
        modelOwner.invalidate(); purchaseConfirmation.reset()
        checkedAt = .distantPast; sidebarBuiltAt = .distantPast
    }

    private var loading: Bool { modelOwner.isLoading }
    private var lastSection: AXUIElement? { modelOwner.model.lastSection }
    private var nextSection: AXUIElement? { modelOwner.model.nextSection }
    private var tails: [Int: AXUIElement] { modelOwner.model.tails }
    private func queue(_ command: @escaping @MainActor () -> Void) { modelOwner.enqueue(command) }

    nonisolated static let batch = 40, perCarousel = 12

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
    private func confirmed(_ i: Int, then: @escaping @MainActor @Sendable (Entry?) -> Void) {
        guard page.indices.contains(i) else { purchaseConfirmation.reset(); then(nil); return }
        let captured = page[i], generation = modelOwner.session
        if loading {
            queue { [weak self] in
                guard let self, modelOwner.session == generation else { return }
                confirm(captured, then: then)
            }
        } else { confirm(captured, then: then) }
    }

    private func confirm(_ captured: Entry, then: @escaping @MainActor @Sendable (Entry?) -> Void) {
        let wanted = Self.itemName(captured.check.isEmpty ? captured.label : captured.check)
        let matches = AppStoreEntryIdentity.indices(for: captured, in: page)
        guard !wanted.isEmpty, matches.count == 1, let i = matches.first else {
            purchaseConfirmation.reset()
            Speech.speakMessage(String(localized: "could not identify this item unambiguously", comment: "Spoken message")); then(nil); return
        }
        modelOwner.read(.resolve(captured, index: i)) { [weak self] result in
            guard let self, canUseResult else { return }
            guard let resolved = result?.resolved else {
                purchaseConfirmation.reset()
                if result?.needsRefresh == true {
                    invalidatePage()
                    Speech.speakMessage(String(localized: "This item changed. Reading the page again.", comment: "Spoken message"))
                    buildPage { [weak self] in
                        guard let self, canUseResult, !page.isEmpty else { return }
                        speak(pageIndex, crossing: true)
                    }
                    then(nil); return
                }
                Speech.speakMessage(String(localized: "could not reach \(wanted); try again", comment: "Spoken message")); then(nil); return
            }
            then(resolved)
        }
    }

    nonisolated private static func itemName(_ value: String) -> String {
        (value.components(separatedBy: ",").first ?? value).trimmingCharacters(in: .whitespaces)
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

    nonisolated static func isItem(_ e: AXUIElement) -> Bool {
        let id = e.string(kAXIdentifierAttribute) ?? ""
        return id.contains("shelfItem") && !id.contains("SubComponent")
    }

    /// "Apps updated for macOS 27, Section 4" → "Apps updated for macOS 27"; "Section 3" → "".
    nonisolated static func shelfName(_ d: String) -> String {
        var s = d
        if let r = s.range(of: #"(,\s*)?Section \d+$"#, options: .regularExpression) { s.removeSubrange(r) }
        return s.trimmingCharacters(in: .whitespaces)
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
            label = [title, ratings.map { String(localized: "\($0) ratings", comment: "How many ratings an app has: %@ is the count as the App Store shows it") }, offerTitle.isEmpty ? nil : offerTitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        } else if id.contains("UpdatesLockup") {
            // Updates: the app and date, the button, then what's new.
            // The app and date are an inner group's description, or (the other layout) its first two texts.
            let inner = first(in: e, depth: 2) { $0.role == "AXGroup" && $0.string(kAXDescriptionAttribute) != nil }
            let all = texts()
            let head = inner?.string(kAXDescriptionAttribute) ?? all.prefix(2).joined(separator: ", ")
            let notes = all.dropFirst(2).filter { $0 != all.dropFirst().first }.max { $0.count < $1.count } ?? ""
            let ipad = first(in: e, depth: 3) { ($0.string(kAXTitleAttribute) ?? "").hasPrefix("Designed for iPad") } != nil
            label = [head, ipad ? String(localized: "designed for iPad", comment: "An App Store app made for iPad") : "", offerTitle].filter { !$0.isEmpty }.joined(separator: ", ") + (notes.count > 8 ? ". \(notes)" : "")
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
            return String(localized: "Rating \(score) out of 5, \(count.lowercased())", comment: "An app's rating: the score, then how many ratings")
        }
        if id.hasSuffix("badge.chartPosition") {
            let n = parts.first { Int($0) != nil } ?? ""
            let cat = rest.last { Int($0) == nil && $0 != "No." } ?? ""
            return String(localized: "Chart: number \(n) in \(cat)", comment: "An app's chart position: the number, then the category")
        }
        if id.hasSuffix("badge.artwork") {
            return String(localized: "Developer: \(rest.joined(separator: " "))", comment: "An app's developer")
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

    public func buildSidebar(then: @escaping @MainActor @Sendable () -> Void = {}) {
        modelOwner.read(.sidebar) { [weak self] _ in
            guard let self, canUseResult else { return }
            sidebarBuiltAt = Date(); then()
        }
    }

    private func ensureCurrent(retry: @escaping @MainActor @Sendable () -> Void) -> Bool {
        guard canUseResult else { stop(); return false }
        guard !loading || flatDrives else { queue(retry); return false }
        if hasCard { area = .page }
        if area == .sidebar, sidebar.isEmpty || Date().timeIntervalSince(sidebarBuiltAt) > 1 {
            buildSidebar(then: retry); return false
        }
        if area == .page, !flatDrives, page.isEmpty {
            buildPage { [weak self] in
                guard let self else { return }
                if !page.isEmpty || flatDrives { retry() }
                else { Speech.speakMessage(String(localized: "still reading the page; try again in a moment", comment: "Spoken message")) }
            }
            return false
        }
        if Date().timeIntervalSince(checkedAt) > 0.7, !flatDrives {
            modelOwner.read(.metadata) { [weak self] result in
                guard let self, canUseResult else { return }
                checkedAt = Date()
                if let metadata = result?.metadata, !metadata.key.isEmpty, metadata.key != pageKey {
                    invalidatePage(); buildPage(then: retry)
                } else { retry() }
            }
            return false
        }
        return true
    }

    // MARK: Speaking

    private func speak(_ i: Int, crossing: Bool) {
        let list = area == .page ? page : sidebar
        guard list.indices.contains(i) else { return }
        let e = list[i]
        var s = e.label
        // The button as it is now: a download's progress moves on, and Get becomes Open.
        if !e.offerTitle.isEmpty, let o = e.offer, let now = o.string(kAXTitleAttribute) ?? o.string(kAXDescriptionAttribute), now != e.offerTitle {
            s = now.isEmpty ? s.replacingOccurrences(of: ", " + e.offerTitle, with: "") : s.replacingOccurrences(of: e.offerTitle, with: now)
        }
        switch e.kind {
        case .heading: s += ", " + Role.heading.displayString
        case .button: s += ", " + Role.button.displayString
        case .search: s += ", " + String(localized: "search field", comment: "A role: a search field")
        default: break
        }
        if area == .page, crossing, shelves.indices.contains(e.shelf), !shelves[e.shelf].isEmpty {
            let n = page.filter { $0.shelf == e.shelf }.count
            s = "\(shelves[e.shelf]), \(Phrases.items(n)). " + s
        }
        let hint = hint(for: e)
        guard acceptsCurrentPage() else { return }
        Speech.speakItem(s)
        Hints.schedule(hint)
    }

    /// What can be done with an item, for the hint.
    private func hint(for e: Entry) -> String {
        if area == .sidebar {
            switch e.kind {
            case .search: return String(localized: "Return to type a search. Tab for the page.", comment: "A hint in the App Store")
            case .tab: return String(localized: "Return opens it. Tab for the page.", comment: "A hint in the App Store")
            case .account: return String(localized: "Return opens your account.", comment: "A hint in the App Store")
            default: return ""
            }
        }
        switch e.kind {
        case .app:
            if Self.isProductTop(e.element) { return String(localized: "Return or Space presses its button.", comment: "A hint in the App Store") }
            if e.offer == nil { return String(localized: "Return opens it.", comment: "A hint in the App Store") }
            return String(localized: "Return opens its page. Space presses its button. Left and Right for other shelves.", comment: "A hint in the App Store")
        case .card: return String(localized: "Return opens it. Left and Right for other shelves.", comment: "A hint in the App Store")
        case .button: return String(localized: "Return presses it.", comment: "A hint in the App Store")
        case .heading, .text: return String(localized: "Up and Down to read on. Left and Right for other shelves.", comment: "A hint in the App Store")
        default: return ""
        }
    }

    public func arrive(tries: Int = 8, moves initialMoves: Int? = nil, keys initialKeys: Int? = nil) {
        let startMoves = initialMoves ?? moves
        let startKeys = initialKeys ?? ScriptHandler.keysArrivedCount
        guard moves == startMoves, ScriptHandler.keysArrivedCount == startKeys else { return }
        if tries == 8 { active = true; invalidatePage() }
        area = .page
        let generation = modelOwner.session
        buildPage { [weak self] in
            guard let self, canUseResult, modelOwner.session == generation,
                  moves == startMoves, ScriptHandler.keysArrivedCount == startKeys else { return }
            if page.isEmpty, !flatDrives, tries > 0 {
                onMain(after: 0.7) { [weak self] in
                    guard let self, canUseResult, modelOwner.session == generation,
                          moves == startMoves, ScriptHandler.keysArrivedCount == startKeys,
                          NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                    arrive(tries: tries - 1, moves: startMoves, keys: startKeys)
                }
                return
            }
            pageIndex = 0
            let title = pageTitle, n = shelves.filter { !$0.isEmpty }.count
            let name = title.isEmpty ? "App Store" : title
            Speech.speakMessage(n > 0 ? String(localized: "\(name), \(String(n)) shelves", comment: "An App Store page: its title, then how many shelves") : name)
            if !page.isEmpty { speak(0, crossing: true) }
        }
    }

    // MARK: Moving

    public func move(_ d: Int) {
        if let c = catalog, catalogDrives, area == .page { c.move(d); return }
        if let r = results, area == .page { r.move(d); return }
        guard ensureCurrent(retry: { [weak self] in self?.move(d) }) else { return }
        moves += 1
        if area == .sidebar {
            let j = sideIndex + d
            guard sidebar.indices.contains(j) else { Tones.edge(); speak(sideIndex, crossing: false); return }
            purchaseConfirmation.reset(); sideIndex = j; speak(j, crossing: false); return
        }
        if d > 0, page.indices.contains(pageIndex), tails[page[pageIndex].shelf] != nil,
           pageIndex + 1 >= page.count || page[pageIndex + 1].shelf != page[pageIndex].shelf {
            modelOwner.read(.carousel(page[pageIndex].shelf)) { [weak self] result in
                guard let self else { return }
                if result != nil { move(d) } else { Tones.edge() }
            }
            return
        }
        let j = pageIndex + d
        if j >= page.count, lastSection != nil || nextSection != nil {
            modelOwner.read(.more) { [weak self] result in
                guard let self else { return }
                if result?.more == true { move(d) } else { Tones.edge(); speak(pageIndex, crossing: false) }
            }
            return
        }
        guard page.indices.contains(j), page.indices.contains(pageIndex) else { Tones.edge(); speak(pageIndex, crossing: false); return }
        let crossing = page[j].shelf != page[pageIndex].shelf
        purchaseConfirmation.reset(); pageIndex = j; speak(j, crossing: crossing)
    }

    public func jumpShelf(_ d: Int) {
        guard ensureCurrent(retry: { [weak self] in self?.jumpShelf(d) }) else { return }
        moves += 1
        guard area == .page, page.indices.contains(pageIndex) else { move(d); return }
        let cur = page[pageIndex].shelf
        if d > 0, !page.contains(where: { $0.shelf > cur }), lastSection != nil || nextSection != nil {
            modelOwner.read(.more) { [weak self] result in
                guard let self else { return }
                if result?.more == true { jumpShelf(d) } else { Tones.edge() }
            }
            return
        }
        let target = d > 0 ? page.firstIndex { $0.shelf > cur } : page.lastIndex { $0.shelf < cur }.map { last in page.firstIndex { $0.shelf == page[last].shelf } ?? last }
        guard let t = target else { Tones.edge(); return }
        purchaseConfirmation.reset(); pageIndex = t; speak(t, crossing: true)
    }

    public func toEnd(_ last: Bool) {
        if let c = catalog, catalogDrives, area == .page { c.toEnd(last); return }
        if let r = results, area == .page { r.toEnd(last); return }
        guard ensureCurrent(retry: { [weak self] in self?.toEnd(last) }) else { return }
        moves += 1; purchaseConfirmation.reset()
        if area == .sidebar { sideIndex = last ? sidebar.count - 1 : 0; speak(sideIndex, crossing: false); return }
        guard !page.isEmpty else { return }
        if last {
            modelOwner.read(.end) { [weak self] _ in
                guard let self else { return }
                pageIndex = page.count - 1; speak(pageIndex, crossing: true)
            }
        } else { pageIndex = 0; speak(pageIndex, crossing: true) }
    }
    /// Reading on a background queue: keys pressed meanwhile are kept and run when it is done (as MediaView does;
    /// they were dropped with "please wait", code review, 8 Oct 2026).


    public func letter(_ ch: Character) {
        if let c = catalog, catalogDrives, area == .page { c.letter(ch); return }
        if let r = results, area == .page { r.letter(ch); return }
        // While shelves are being read off the main thread, their lists are being written: wait, as the arrows do
        // (a code review, 14 Oct 2026).
        guard ensureCurrent(retry: { [weak self] in self?.letter(ch) }) else { return }
        moves += 1; purchaseConfirmation.reset()
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
        guard ensureCurrent(retry: { [weak self] in self?.switchArea() }) else { return }
        moves += 1; purchaseConfirmation.reset()
        // A card over the window has no sidebar: say how out, and stay.
        if hasCard {
            if area == .sidebar { area = .page; speak(pageIndex, crossing: true) }
            else { Speech.speakMessage(String(localized: "no sidebar here; Escape goes back", comment: "Spoken message")) }
            return
        }
        area = area == .page ? .sidebar : .page
        if area == .sidebar, sidebar.isEmpty || Date().timeIntervalSince(sidebarBuiltAt) > 1 {
            buildSidebar { [weak self] in self?.announceArea() }; return
        }
        announceArea()
    }

    private func announceArea() {
        if area == .sidebar {
            // Search first, where it is on screen (it could not be found under Discover, 6 Oct 2026); the tab in
            // use is said with it.
            sideIndex = 0
            let current = sidebar.first { $0.label.hasSuffix(Self.selectedSuffix) }?.label.replacingOccurrences(of: Self.selectedSuffix, with: "")
            Speech.speakMessage(current.map { String(localized: "sidebar, on \($0)", comment: "The App Store's sidebar: %@ is the tab in use") } ?? String(localized: "sidebar", comment: "The App Store's sidebar"))
            speak(sideIndex, crossing: false)
        } else {
            Speech.speakMessage(pageTitle.isEmpty ? Role.page.displayString : pageTitle)
            speak(pageIndex, crossing: true)
        }
    }

    // MARK: Acting

    public func open(press: AppStoreActionPress = .synthetic) {
        // While shelves are being read off the main thread, their lists are being written: wait, as the arrows do
        // (a code review, 14 Oct 2026). Not under the flat view, which has its own waits: a stale `loading` left
        // Return queued for good (27 Oct 2026).
        guard ensureCurrent(retry: { [weak self] in self?.open(press: press) }) else { return }
        if let c = catalog, catalogDrives, area == .page { c.openCurrent(); return }
        if let r = results, area == .page { r.open(); return }
        if area == .sidebar {
            purchaseConfirmation.reset()
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
                    guard acceptsCurrentPage() else { return }
                    r = outline.set(kAXSelectedRowsAttribute, [row] as CFArray)
                }
                if r != .success, let button = Self.first(in: e.element, depth: 3, where: { ($0.string(kAXIdentifierAttribute) ?? "").hasPrefix("AppStore.tabBar.") }) {
                    guard acceptsCurrentPage() else { return }
                    r = AXUIElementPerformAction(button, kAXPressAction as CFString)
                }
                guard acceptsCurrentPage() else { return }
                Log.io("app store: tab \(Log.words(e.label)) chosen (\(r.rawValue))")
                Speech.speakMessage(e.label.replacingOccurrences(of: Self.selectedSuffix, with: ""))
                area = .page; pageIndex = 0
                waitForNewPage(from: before)
            case .account:
                // The account button has no press action (measured): a click on it, and its page is read.
                guard let f = TurnOverObject.frame(e.element) else { return }
                let before = currentKey()
                let home = CGEvent(source: nil)?.location
                guard acceptsCurrentPage() else { return }
                Mouse.click(at: CGPoint(x: f.midX, y: f.midY), button: .left, count: 1)
                if let home { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Mouse.move(to: home) } }
                Speech.speakMessage(String(localized: "account", comment: "Spoken message"))
                area = .page; pageIndex = 0
                waitForNewPage(from: before)
            default: break
            }
            return
        }
        confirmed(pageIndex) { [weak self] e in if let e { self?.open(confirmed: e, press: press) } }
    }
    private func open(confirmed e: Entry, press: AppStoreActionPress) {
        guard acceptsCurrentPage() else { return }
        let before = pageKey
        switch e.kind {
        case .button:
            purchaseConfirmation.reset()
            _ = AXUIElementPerformAction(e.element, kAXPressAction as CFString)
            waitForNewPage(from: before)
        case .heading, .text:
            purchaseConfirmation.reset()
            Speech.speakMessage(e.label)
        case .app where Self.isProductTop(e.element):
            // On the app's own page, its first line is the app itself: Return presses its button, as Space does.
            offer(press: press)
        default:
            purchaseConfirmation.reset()
            // An app opens with a click on its icon (a press on the row reports success and does nothing).
            guard clickIcon(e) else {
                if acceptsCurrentPage() { Speech.speakMessage(String(localized: "cannot open this one", comment: "Spoken message")) }
                return
            }
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
        guard acceptsCurrentPage() else { return false }
        let home = CGEvent(source: nil)?.location
        Mouse.click(at: p, button: .left, count: 1)
        if let home { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Mouse.move(to: home) } }
        Log.io("app store: opened \"\(Log.words(String(e.label.prefix(40))))\" by its icon")
        return true
    }

    /// Whether the system's hit test under the row's icon (or its left edge) names this row. Off the main thread.


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
    public func offer(press: AppStoreActionPress = .synthetic) {
        guard ensureCurrent(retry: { [weak self] in self?.offer(press: press) }) else { return }
        guard area == .page, page.indices.contains(pageIndex) else { open(press: press); return }
        confirmed(pageIndex) { [weak self] e in if let e { self?.offer(confirmed: e, press: press) } }
    }
    private func offer(confirmed e: Entry, press: AppStoreActionPress) {
        // The button as it is now, inside the row just checked (never one remembered from earlier).
        let button = Self.first(in: e.element, depth: 5, where: { ($0.string(kAXIdentifierAttribute) ?? "").contains("offerButton") })
        guard acceptsCurrentPage() else { return }
        guard let o = button else {
            purchaseConfirmation.reset()
            Speech.speakMessage(String(localized: "no button here", comment: "Spoken message")); return
        }
        let title = o.string(kAXTitleAttribute) ?? o.string(kAXDescriptionAttribute) ?? ""
        guard acceptsCurrentPage() else { return }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            purchaseConfirmation.reset()
            Speech.speakMessage(String(localized: "the button is not ready; try again", comment: "Spoken message")); return
        }
        let name = e.label.components(separatedBy: ",").first ?? "this app"
        // Downloading: the button is Cancel now ("2.1% loaded", help "Cancel"). Space and Return only say how far it
        // has got; Delete cancels (two Spaces five seconds apart, checking progress, cancelled Outlook,
        // 14 Oct 2026).
        if Self.isDownloading(title) {
            purchaseConfirmation.reset()
            Speech.speakMessage(String(localized: "\(name), \(title). Delete cancels the download.", comment: "Spoken message"))
            return
        }
        // Open pressed already and the app still starting (a big app takes seconds): once is enough.
        if title.hasPrefix("Open"), let (n, at) = lastOpen, n == name, Date().timeIntervalSince(at) < 6 {
            purchaseConfirmation.reset()
            Speech.speakMessage(String(localized: "opening \(name)", comment: "Spoken message"))
            return
        }
        let free = ["Open", "Get", "Update", "Re-download", "Install", "Cancel", "Play"].contains { title.hasPrefix($0) }
        if !free {
            let identity = e.check.isEmpty ? e.label : e.check
            let context = AppStorePurchaseConfirmation.Context(page: modelOwner.session, itemIdentity: identity, offerTitle: title, button: o)
            switch purchaseConfirmation.decide(context, press: press, at: Date(), armTick: mach_absolute_time()) {
            case .confirm:
                guard acceptsCurrentPage() else { return }
                _ = AXUIElementPerformAction(o, kAXPressAction as CFString)
                Log.io("app store: buy pressed (confirmed)")
                Speech.speakMessage(String(localized: "buying; the App Store asks you to confirm", comment: "Spoken message"))
            case .prompt:
                Speech.speakMessage(String(localized: "Buy \(name) for \(title)? Press Space again to buy.", comment: "Spoken message"))
            case .ignore:
                break
            }
            return
        }
        purchaseConfirmation.reset()
        guard acceptsCurrentPage() else { return }
        _ = AXUIElementPerformAction(o, kAXPressAction as CFString)
        Log.io("app store: \(Log.words(title)) pressed")
        if title.hasPrefix("Open") { lastOpen = (name, Date()); Speech.speakMessage(String(localized: "opening \(name)", comment: "An app being opened: %@ is its name")) }
        else { Speech.speakMessage(title.components(separatedBy: ",").first ?? title) }
        if !title.hasPrefix("Open") { watchDownload(o, name: name) }
        // Get becomes Install (or starts at once); say what the button says now.
        let owner = modelOwner, generation = modelOwner.session, startMoves = moves
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, canUseResult, owner.session == generation, moves == startMoves, area == .page,
                  owner.model.containsSelection(e, at: pageIndex) else { return }
            // Read only; this delayed status must not hold main or follow a recycled button onto another app.
            DispatchQueue.global(qos: .utility).async {
                guard owner.isCurrentSession(generation),
                      let currentButton = Self.first(in: e.element, depth: 5, where: { ($0.string(kAXIdentifierAttribute) ?? "").contains("offerButton") }),
                      CFEqual(currentButton, o), owner.isCurrentSession(generation) else { return }
                let now = currentButton.string(kAXTitleAttribute) ?? currentButton.string(kAXDescriptionAttribute) ?? ""
                guard owner.isCurrentSession(generation) else { return }
                let identity = Self.identity(of: e.element)
                guard AppStoreEntryIdentity.fullText(identity) == AppStoreEntryIdentity.fullIdentity(e),
                      owner.isCurrentSession(generation) else { return }
                onMain { [weak self] in
                    guard let self, canUseResult, owner.session == generation, moves == startMoves, area == .page,
                          owner.model.containsSelection(e, at: pageIndex) else { return }
                    if !now.isEmpty, now != title { Speech.speakMessage(now == "Install" ? "Install; press Space again to install" : now) }
                }
            }
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
                Tones.beep(880, 80); Speech.speakMessage(String(localized: "\(name) installed", comment: "An app finished installing"))
                Log.io("app store: \(Log.words(name)) installed")
                return
            }
            if t.hasPrefix("Get") || t.hasPrefix("Re-download") || t.hasPrefix("Update") {
                if polls > 2 { Speech.speakMessage(String(localized: "\(name): download stopped", comment: "An app's download stopped")) }
                return
            }
            var quarter = lastQuarter
            if let r = t.range(of: #"^[\d.]+"#, options: .regularExpression), let pct = Double(t[r]) {
                let q = Int(pct / 25)
                if q > lastQuarter, q < 4 { quarter = q; Speech.speakMessage(String(localized: "\(name), \(String(q * 25)) percent", comment: "A download's progress: the app, then the percentage")) }
            }
            self.watchDownload(o, name: name, lastQuarter: quarter, polls: polls + 1)
        }
    }

    public func back() {
        purchaseConfirmation.reset()
        guard acceptsCurrentPage() else { return }
        let before = currentKey()
        // The Back button in the window's toolbar (a card over the window has one too).
        if let w = window, let tb = w.elements(kAXChildrenAttribute).first(where: { $0.role == "AXToolbar" }),
           let b = Self.first(in: tb, depth: 3, where: { $0.role == "AXButton" && ($0.string(kAXDescriptionAttribute) == "Back" || ($0.string(kAXIdentifierAttribute) ?? "").hasSuffix("backButton")) }) {
            guard acceptsCurrentPage() else { return }
            _ = AXUIElementPerformAction(b, kAXPressAction as CFString)
        } else {
            guard acceptsCurrentPage() else { return }
            Speech.speakMessage(String(localized: "no page to go back to", comment: "Spoken message")); return
        }
        area = .page
        waitForNewPage(from: before, back: true)
    }

    public func focusSearch() {
        moves += 1
        purchaseConfirmation.reset()
        buildSidebar { [weak self] in
            guard let self, let s = sidebar.first(where: { $0.kind == .search }) else { Speech.speakMessage(String(localized: "no search field", comment: "Spoken message")); return }
            let r = s.element.set(kAXFocusedAttribute, kCFBooleanTrue)
            Log.io("app store: search field focused (\(r.rawValue))")
            if r != .success { Speech.speakMessage(String(localized: "could not reach the search field", comment: "Spoken message")) }
        }
    }

    /// After Return in the search field: wait for the results, read them, and give the keys back to the page.
    public func afterSearch(term: String = "") {
        let before = currentKey()
        area = .page
        searching = true
        catalogSearch(term: term)
        waitForNewPage(from: before, thenFocusPage: true)
    }
    /// A search is under way: the results are read when they come, whatever keys are pressed meanwhile.
    private var searching = false

    private var lastPositions: [String: Int] = [:]
    /// The page's title when it was read (the title now may already be the next page's).
    private var builtTitle: String { modelOwner.model.title }

    /// A new page comes a moment after the click; read its title and first item once it has settled.
    private func settleResults(key: String, wave: Int) {
        let generation = modelOwner.session
        onMain(after: wave == 1 ? 0.7 : 0.8) { [weak self] in
            guard let self, canUseResult, modelOwner.session == generation, area == .page, pageKey == key else { return }
            buildPage { [weak self] in
                guard let self, modelOwner.session == generation else { return }
                if wave < 2 { settleResults(key: key, wave: 2) }
            }
        }
    }

    private func waitForNewPage(from before: String, back: Bool = false, thenFocusPage: Bool = false, tries: Int = 0, moves startMoves: Int? = nil) {
        if tries == 0 {
            if !builtTitle.isEmpty { lastPositions[builtTitle] = pageIndex }
            invalidatePage()
        }
        let generation = modelOwner.session, start = startMoves ?? moves
        onMain(after: 0.35) { [weak self] in
            guard let self, canUseResult, modelOwner.session == generation, moves == start || searching else { return }
            modelOwner.read(.metadata) { [weak self] result in
                guard let self, canUseResult, modelOwner.session == generation, moves == start || searching else { return }
                let metadata = result?.metadata
                let now = metadata?.key ?? ""
                let limit = thenFocusPage ? 20 : 16
                if (now == before || now.isEmpty), tries < limit {
                    waitForNewPage(from: before, back: back, thenFocusPage: thenFocusPage, tries: tries + 1, moves: start); return
                }
                let fromSearch = searching
                area = .page; searching = false
                if fromSearch { resultsKey = "" }
                let early = metadata?.title ?? ""
                let announced = openingTitle; openingTitle = ""
                if now != before, !early.isEmpty, !flatDrives, early != announced { Speech.speakMessage(early) }
                buildPage { [weak self] in
                    guard let self, canUseResult, modelOwner.session == generation, moves == start || fromSearch else { return }
                    pageIndex = back ? min(lastPositions[pageTitle] ?? 0, max(0, page.count - 1)) : 0
                    settleResults(key: pageKey, wave: 1)
                    // Focusing the page and action preparation remain separate from model construction (#119).
                    if thenFocusPage, let (_, list) = pageRoot() { _ = list.set(kAXFocusedAttribute, kCFBooleanTrue) }
                    let title = pageTitle
                    if now == before, !thenFocusPage { Log.io("app store: the page did not change"); return }
                    if (title != early || early.isEmpty), title != announced { Speech.speakMessage(title.isEmpty ? "page" : title) }
                    if !page.isEmpty, !flatDrives { speak(pageIndex, crossing: true) }
                }
            }
        }
    }
}

nonisolated extension Array {
    mutating func removeSubrange(_ r: Range<Int>, where test: (Element) -> Bool) {
        let keep = self[r].filter { !test($0) }
        replaceSubrange(r, with: keep)
    }
}
