// SPDX-License-Identifier: GPL-3.0-or-later
// Browse mode (NVDA: browseMode.BrowseModeDocumentTreeInterceptor + cursorManager).
//
// In a web document the reader owns a virtual caret: arrows read by line, word
// and character without the page seeing the keys; single letters jump to the
// next heading, link, button, list…; Enter activates what the caret is on. A
// focusable control that gains focus (an edit field) switches to focus mode,
// where keys pass through again; Caps+Space switches by hand; Escape returns.
//
// A browse mode document is a tree interceptor: it answers scripts and sees
// events for every object inside its web area, before the object itself.
import Foundation
import CryptoKit
import ApplicationServices
import AppKit
import TurnOverAX

/// Keeps one document per web area and decides when a focus is inside one (NVDA: treeInterceptorHandler).
public final class BrowseModeHandler {
    public static let shared = BrowseModeHandler()
    /// When Back or Forward was last pressed (Command [ or ]): only then does a page resume where it was left. A page
    /// opened afresh (typed, a link, a new tab, a bookmark) starts at the top, as NVDA's does (a tester, 13 Oct 2026:
    /// apple.com and AppleVis opened part way down, where he had last been).
    nonisolated(unsafe) public static var historyKeyAt = Date.distantPast   // main thread only
    static var cameBackByHistory: Bool { Date().timeIntervalSince(historyKeyAt) < 10 }
    var documents: [BrowseModeDocument] = []
    let lock = NSLock()

    public func existingDocument(for webArea: AXUIElement) -> BrowseModeDocument? {
        lock.lock(); defer { lock.unlock() }
        return documents.first { $0.webArea.isSame(webArea) }
    }

    /// A document over any element an app module nominates (Music's content pane), made once per root.
    public func document(root: AXUIElement) -> BrowseModeDocument {
        lock.lock(); defer { lock.unlock() }
        if let d = documents.first(where: { $0.webArea.isSame(root) }), d.isAlive { return d }
        let d = BrowseModeDocument(webArea: root)
        documents.append(d)
        Log.info("browse mode document over \(root.role) \"\(Log.words(root.string(kAXDescriptionAttribute) ?? ""))\" in pid \(root.pid)")
        return d
    }

    /// The document for a focus object, made on first sight (NVDA: the object's treeInterceptorClass).
    /// The outermost web area is the document; the frames inside it (advertisements, embeds) are part of it.
    public func document(for obj: TurnOverObject, ancestors: [TurnOverObject]) -> BrowseModeDocument? {
        let webAreaObj = ([obj] + ancestors).last { $0.axRole == "AXWebArea" }
        // Not a web page: the app's module may name a document of its own (Preview's pages, 17 Oct 2026).
        if webAreaObj == nil, let root = obj.appModule.browseRoot(for: obj.element, ancestors: ancestors) { return document(root: root) }
        guard let w = webAreaObj else { return nil }
        // An editable web area (Mail's compose body) is typed into, not browsed.
        if EditableWebArea.isEditable(w.element) { return nil }
        // The lock only around the list: looking up, and adding. The questions to the page and the building happen
        // outside it, so nothing reached during a build can deadlock on it (E6, 1 Oct; tightened 4 Oct 2026).
        lock.lock()
        let known = documents.first(where: { $0.webArea.isSame(w.element) })
        lock.unlock()
        if let known { return known.isAlive ? known : nil }
        guard supports(w) else { return nil }
        let d = BrowseModeDocument(webArea: w.element)
        lock.lock()
        if let raced = documents.first(where: { $0.webArea.isSame(w.element) }) { lock.unlock(); return raced }
        documents.append(d)
        // Dead pages go first (Mail's message bodies come and go by the dozen; forty of them pushed Safari's tab
        // out and it was announced again from the top on return: code review, 16 Oct 2026). Then the oldest.
        if documents.count > 40 { documents.removeAll { !$0.isAlive }; if documents.count > 40 { documents.removeFirst() } }
        lock.unlock()
        Log.info("browse mode document for \"\(Log.words(w.name))\" in pid \(w.pid)")
        return d
    }

    /// Chromium (Electron apps: Claude, Slack…) exposes AXManualAccessibility on the application.
    /// Electron apps say so with AXManualAccessibility; the Chromium browsers (Chrome, Brave, Edge, Arc, Vivaldi,
    /// Opera) do not, but carry a "… Framework" of Chromium's inside. Their own search for headings skipped one going
    /// forward (Brave: Shift H said "no previous heading", a tester, ; Chrome: H from the first heading went to
    /// the third, 7 Oct 2026): they are read from TurnOver's buffer, as Electron apps are.
    public static func isChromium(pid: pid_t) -> Bool {
        chromiumLock.lock(); defer { chromiumLock.unlock() }
        if let known = chromiumCache[pid] { return known }
        var names: CFArray?
        var yes = AXUIElementCopyAttributeNames(AXUIElementCreateApplication(pid), &names) == .success && ((names as? [String]) ?? []).contains("AXManualAccessibility")
        if !yes, let url = NSRunningApplication(processIdentifier: pid)?.bundleURL?.appendingPathComponent("Contents/Frameworks"),
           let items = try? FileManager.default.contentsOfDirectory(atPath: url.path) {
            yes = items.contains { n in ["Chrome Framework", "Chromium Framework", "Browser Framework", "Edge Framework", "Vivaldi Framework", "Opera Framework", "Electron Framework"].contains { n.contains($0) } }
        }
        chromiumCache[pid] = yes
        return yes
    }
    static var chromiumCache: [pid_t: Bool] = [:]
    static let chromiumLock = NSLock()

    /// WebKit documents, and Chromium's read from TurnOver's own buffer (which needs no text markers).
    func supports(_ webArea: TurnOverObject) -> Bool {
        if Self.isChromium(pid: webArea.pid) { return true }
        var params: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(webArea.element, &params) == .success, let p = params as? [String] else { return false }
        return p.contains("AXTextMarkerForIndex") && p.contains("AXLineTextMarkerRangeForTextMarker") && p.contains("AXUIElementsForSearchPredicate")
    }

    // Positions have their own lock: a document is built while `lock` is held, and its first
    // position is restored from here during that build (holding `lock` deadlocked the main thread).
    let positionsLock = NSLock()
    public struct Saved: Codable {
        public let offset: Int; public let text: String; public let at: Date?
        public init(offset: Int, text: String, at: Date? = Date()) { self.offset = offset; self.text = text; self.at = at }
    }
    /// The file holds a hash of each page's address, without its query or fragment, and 60 characters of the line:
    /// it held 500 full addresses, search terms and tokens among them (a code review, 14 Oct 2026). The query
    /// gone also answers the page that rewrites its own address after loading (Wikipedia's "&wprov=…").
    nonisolated public static func key(for url: String) -> String {
        var plain = url
        if let c = URLComponents(string: url) { plain = (c.scheme ?? "") + "://" + (c.host ?? "") + c.path }
        return SHA256.hash(data: Data(plain.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
    /// The address for a log line: its host and path only.
    nonisolated public static func shortURL(_ url: String) -> String {
        guard let c = URLComponents(string: url) else { return String(url.prefix(40)) }
        return String(((c.host ?? "") + c.path).prefix(60))
    }
    lazy var positions: [String: Saved] = Self.loadPositions()
    var saveScheduled = false
    static var positionsURL: URL { AppPaths.file("positions.json") }
    static func loadPositions() -> [String: Saved] {
        ((try? JSONDecoder().decode([String: Saved].self, from: Data(contentsOf: positionsURL))) ?? [:]).filter { !$0.key.contains("://") }
    }
    /// Only a page's real address names it: Mail's message view is "x-webdoc://…", one address for every
    /// message shown in it, so a place in one message was restored in the next (2 Oct 2026).
    static func isRememberable(_ url: String) -> Bool {
        url.hasPrefix("https://") || url.hasPrefix("http://") || url.hasPrefix("file://")
    }
    func savedPosition(for url: String) -> Saved? {
        guard Self.isRememberable(url) else { return nil }
        positionsLock.lock(); defer { positionsLock.unlock() }
        return positions[Self.key(for: url)]
    }
    func remember(url: String, position: Int, text: String) {
        guard Self.isRememberable(url) else { return }
        positionsLock.lock()
        positions[Self.key(for: url)] = Saved(offset: position, text: String(text.prefix(60)))
        if positions.count > 500, let oldest = positions.min(by: { ($0.value.at ?? .distantPast) < ($1.value.at ?? .distantPast) }) { positions.removeValue(forKey: oldest.key) }
        positionsLock.unlock()
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
            saveScheduled = false
            positionsLock.lock(); let snapshot = positions; positionsLock.unlock()
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: Self.positionsURL) }
        }
    }

    public func forget(pid: pid_t) {
        lock.lock(); documents.removeAll { $0.webArea.pid == pid }; lock.unlock()
    }
}
