// SPDX-License-Identifier: GPL-3.0-or-later
// The flat view (docs/FLAT-VIEW-PLAN.md, 27 Oct 2026): one area of a window as a list of items kept by key, never by
// element. Discover reads the area in waves off the main thread, each wave bounded, and merges by key; resolve finds
// an item again in the live tree, brings it on screen the app's way and makes the system's hit test agree before
// anything is clicked; on doubt it refuses. The first user is the App Store's search results page, behind the
// developer switch `flatView` (Oliver: "give this flattening logic a whirl, just for me though").
import Foundation
import AppKit
import ApplicationServices

/// How an item is found again. A record id the app gives (Music's tiles), a name the adapter declares stable in its
/// area (the app's name on a Store tile), or nothing stable: readable, not actable by identity.
nonisolated public enum FlatKey: Hashable, Sendable {
    case id(String), name(String), unstable(String)
    public var isStable: Bool { if case .unstable = self { return false }; return true }
    public var text: String {
        switch self { case .id(let s): return "id " + s; case .name(let s): return s; case .unstable(let s): return "unstable " + s }
    }
}

nonisolated public struct FlatItem: Sendable, Equatable {
    public var key: FlatKey
    public var label: String
    public var section: Int
    public var index: Int
    public init(key: FlatKey, label: String, section: Int, index: Int) { self.key = key; self.label = label; self.section = section; self.index = index }
}

/// What an app's module tells the engine about an area. Every method is called off the main thread and must not
/// touch main-actor state: read the live tree and answer.
nonisolated public protocol FlatAdapter: AnyObject, Sendable {
    /// The area's live root, found afresh each time (the page, the results list).
    func areaRoot() -> AXUIElement?
    /// An element that is one of the area's items (a row, a tile).
    func isItem(_ e: AXUIElement) -> Bool
    /// The item's key: a record id, a stable name, or unstable with whatever tells rows apart for reading.
    func key(for e: AXUIElement, index: Int) -> FlatKey
    /// What is said for the item.
    func label(for e: AXUIElement) -> String
    /// Where a click opens the item (the icon; the left edge; the middle), or nil for an item that is not clicked.
    func clickPoint(for e: AXUIElement) -> CGPoint?
    /// An element under the click point that must never be clicked (an offer button, a toolbar).
    func unsafeHit(_ e: AXUIElement) -> Bool
    /// Seconds after a page change at which the area is read again, as results arrive in stages.
    var settleTimes: [Double] { get }
    /// The element after this one that the tree does not list (a virtualised collection hands the rest over by
    /// AXNextContentSibling without scrolling); nil at the end. Not every sibling is an item: a spacer or a story
    /// group between rows is skipped. The defaults follow the content-sibling attributes both ways.
    func nextSibling(of e: AXUIElement) -> AXUIElement?
    func previousSibling(of e: AXUIElement) -> AXUIElement?
}

extension FlatAdapter {
    nonisolated public func nextSibling(of e: AXUIElement) -> AXUIElement? { e.element("AXNextContentSibling") }
    nonisolated public func previousSibling(of e: AXUIElement) -> AXUIElement? { e.element("AXPreviousContentSibling") }
}

public final class FlatView {
    public let adapter: FlatAdapter
    public let name: String
    /// The list as last published, with the live elements the wave saw (for reading only; never acted on).
    public private(set) var items: [FlatItem] = []
    nonisolated(unsafe) private var elements: [FlatKey: AXUIElement] = [:]   // owned by `lock`
    private let lock = NSLock()
    /// Called on main with the new list whenever it changes.
    public var onChange: (([FlatItem]) -> Void)?
    private let queue: DispatchQueue
    nonisolated(unsafe) private var generation = 0   // owned by `lock`
    private var freshness: Timer?

    public init(name: String, adapter: FlatAdapter) {
        self.name = name; self.adapter = adapter
        queue = DispatchQueue(label: "turnover.flatview.\(name)", qos: .userInitiated)
    }

    /// The element the last wave saw for an item: for reading what it shows now, never for a click.
    public func element(for key: FlatKey) -> AXUIElement? { lock.lock(); defer { lock.unlock() }; return elements[key] }

    // MARK: Discover

    /// A page changed or the area is being entered: a wave now, and the settle waves after.
    public func begin() {
        lock.lock(); generation += 1; let g = generation; lock.unlock()
        discover(reason: "begin", generation: g)
        for t in adapter.settleTimes {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.discover(reason: "settle \(t) s", generation: g) }
        }
        freshness?.invalidate()
        freshness = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.freshen(generation: g) }
        }
    }

    /// Every few seconds: the rows the collection lists now (cheap, no siblings) against the keys known; a row that
    /// is new, or a list that lost one, means a full wave. Keeps the full waves (a second of calls over a long page)
    /// for when the page has really changed.
    nonisolated(unsafe) private var listedKeys: [FlatKey] = []   // owned by `lock`
    private func freshen(generation g: Int) {
        queue.async { [self] in
            lock.lock(); let current = generation; let known = Set(elements.keys); lock.unlock()
            guard current == g, let root = adapter.areaRoot() else { return }
            var listed: [FlatKey] = []; var visited = 0
            func walk(_ e: AXUIElement, _ depth: Int) {
                guard visited < 300, depth < 10 else { return }
                visited += 1
                AXUIElementSetMessagingTimeout(e, 0.3)
                if adapter.isItem(e) { listed.append(adapter.key(for: e, index: -1)); return }
                for k in e.elements(kAXChildrenAttribute) { walk(k, depth + 1) }
            }
            walk(root, 0)
            lock.lock(); let same = listed == listedKeys; listedKeys = listed; lock.unlock()
            let unknown = listed.filter { !known.contains($0) }
            if !same && !unknown.isEmpty { discover(reason: "freshness: \(unknown.count) new rows listed", generation: g) }
        }
    }

    /// The area is left: no more waves.
    public func end() { freshness?.invalidate(); freshness = nil; lock.lock(); generation += 1; lock.unlock() }

    private func discover(reason: String, generation g: Int) {
        queue.async { [self] in
            lock.lock(); let current = generation; lock.unlock()
            guard current == g else { return }
            let start = Date()
            let (found, seen, complete) = Self.wave(adapter: adapter)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            lock.lock(); let still = generation == g; lock.unlock()
            guard still else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated {
                let merged = Self.merge(old: self.items, new: found, complete: complete)
                self.lock.lock(); for (k, e) in seen { self.elements[k] = e }; self.lock.unlock()
                let changed = merged != self.items
                if changed || reason == "begin" {
                    Log.io("flat view \(self.name): \(reason): \(found.count) items in \(ms) ms\(complete ? "" : " (cut short)")\(changed ? "; the list changed" : "")")
                }
                guard changed else { return }
                self.items = merged
                self.onChange?(merged)
            } }
        }
    }

    /// One wave over the area: the items in tree order, each with a key and a label. Bounded: 400 elements, 10
    /// levels, 300 ms, 0.3 s per element. `complete` is false when a bound cut the wave short.
    nonisolated static func wave(adapter: FlatAdapter) -> (items: [FlatItem], seen: [(FlatKey, AXUIElement)], complete: Bool) {
        guard let root = adapter.areaRoot() else { return ([], [], false) }
        let deadline = Date().addingTimeInterval(0.3)
        var items: [FlatItem] = [], seen: [(FlatKey, AXUIElement)] = []
        var visited = 0, index = 0, complete = true, section = 0
        func walk(_ e: AXUIElement, _ depth: Int) {
            if visited >= 400 || depth >= 10 || Date() > deadline { complete = false; return }
            visited += 1
            AXUIElementSetMessagingTimeout(e, 0.3)
            if adapter.isItem(e) {
                let key = adapter.key(for: e, index: index)
                items.append(FlatItem(key: key, label: adapter.label(for: e), section: section, index: index))
                seen.append((key, e)); index += 1
                return
            }
            if e.role == "AXHeading" { section += 1 }
            for k in e.elements(kAXChildrenAttribute) { walk(k, depth + 1); if !complete { return } }
        }
        walk(root, 0)
        // Materialise: the rows the collection does not list (the Store lists sixteen, the rest come as content
        // siblings) are reached from the last one listed forwards and the first one backwards, siblings that are not
        // items (a story group, a spacer) skipped, until the end or a bound. The deadline for this is a second.
        let materialiseBy = Date().addingTimeInterval(1.0)
        var listed = seen.map { $0.1 }
        var hops = 0
        func chain(from start: AXUIElement?, forward: Bool) -> [AXUIElement] {
            var out: [AXUIElement] = []; var cursor = start; var skipped = 0
            while let c = cursor, hops < 600, Date() < materialiseBy {
                guard let next = forward ? adapter.nextSibling(of: c) : adapter.previousSibling(of: c) else { break }
                if listed.contains(where: { CFEqual($0, next) }) { break }   // come round on itself
                hops += 1
                AXUIElementSetMessagingTimeout(next, 0.3)
                if adapter.isItem(next) {
                    if listed.contains(where: { CFEqual($0, next) }) || out.contains(where: { CFEqual($0, next) }) { break }
                    out.append(next); skipped = 0
                } else { skipped += 1; if skipped > 20 { break } }
                cursor = next
            }
            return out
        }
        let before = chain(from: listed.first, forward: false).reversed()   // to the top first: index 0 must be the first row
        let after = chain(from: listed.last, forward: true)
        listed = Array(before) + listed + after
        if Date() >= materialiseBy || hops >= 600 { complete = false }
        items = []; seen = []; index = 0
        var blank = 0
        for e in listed {
            let key = adapter.key(for: e, index: index)
            let label = adapter.label(for: e)
            // A row that answers blank is not a nameless row: the App Store answers blank while it loads (measured
            // 27 Oct 2026: a row's name empty at once and at 1.5 s, there at 0.5 s). Left out, and the wave is not
            // complete, so the next wave looks again rather than a blank taking a known row's place.
            if !key.isStable, label.isEmpty { blank += 1; continue }
            items.append(FlatItem(key: key, label: label, section: 0, index: index))
            seen.append((key, e)); index += 1
        }
        if blank > 0 { complete = false }
        return (items, seen, complete)
    }

    /// The new wave's list, in its order, over the old: an item seen before keeps its place only as the new wave
    /// has it; a wave cut short keeps the old items the new one did not reach. Pure, for the tests.
    public static func merge(old: [FlatItem], new: [FlatItem], complete: Bool) -> [FlatItem] {
        guard !complete, !old.isEmpty else { return new }
        var out = new
        let have = Set(new.map { $0.key })
        for o in old where !have.contains(o.key) { out.append(o) }
        for i in out.indices { out[i].index = i }
        return out
    }

    // MARK: Resolve

    /// The item found again, now, in the live tree: by its key, brought on screen the app's way, the system's hit
    /// test under its click point agreeing (up to a second). `then` runs on main with the element, or nil with the
    /// reason said. An unstable key is refused.
    public func resolve(_ item: FlatItem, then: @escaping @MainActor @Sendable (AXUIElement?) -> Void) {
        guard item.key.isStable else {
            Log.io("flat view \(name): \(Log.words(item.label.prefix(40).description)) has no stable key; not acting")
            Speech.speakMessage("TurnOver can't tell this item from another like it; not opening it")
            then(nil); return
        }
        let adapter = self.adapter, name = self.name, key = item.key
        let remembered = element(for: item.key)
        queue.async {
            var found: AXUIElement?
            for attempt in 0..<4 {
                // The element the wave saw, if it still answers to the key (the Store answers blank while it loads:
                // asked again a few times before it counts as gone); else the live tree.
                found = remembered.flatMap { Self.stillAnswers($0, to: key, adapter: adapter) ? $0 : nil } ?? Self.find(key, adapter: adapter)
                if let f = found {
                    _ = AXUIElementPerformAction(f, "AXScrollToVisible" as CFString)
                    usleep(150_000)
                    if Self.hitAgrees(f, key: key, adapter: adapter) {
                        if attempt > 0 { Log.io("flat view \(name): \(key.text) resolved after \(attempt) waits") }
                        let e = f; DispatchQueue.main.async { MainActor.assumeIsolated { then(e) } }; return
                    }
                }
                usleep(250_000)
            }
            Log.io("flat view \(name): could not resolve \(key.text): \(found == nil ? "not in the live tree" : "the hit test names something else")")
            let missing = found == nil
            DispatchQueue.main.async { MainActor.assumeIsolated { Speech.speakMessage(missing ? "could not find it on the page now; try again" : "something else is under it on screen; not opening"); then(nil) } }
        }
    }

    /// Whether the element answers to the key: asked up to four times, 100 ms apart, while it answers blank.
    nonisolated static func stillAnswers(_ e: AXUIElement, to key: FlatKey, adapter: FlatAdapter) -> Bool {
        AXUIElementSetMessagingTimeout(e, 0.3)
        for _ in 0..<4 {
            let k = adapter.key(for: e, index: -1)
            if k == key { return true }
            if k.isStable { return false }   // it answers, with another name: reused for another row
            usleep(100_000)
        }
        return false
    }

    /// The live element with this key, among the area's items (600 elements, 10 levels), a blank-answering row
    /// asked again before it is passed over.
    nonisolated static func find(_ key: FlatKey, adapter: FlatAdapter) -> AXUIElement? {
        guard let root = adapter.areaRoot() else { return nil }
        var visited = 0, index = 0, hit: AXUIElement?
        func matches(_ e: AXUIElement) -> Bool { stillAnswers(e, to: key, adapter: adapter) }
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard hit == nil, visited < 600, depth < 10 else { return }
            visited += 1
            AXUIElementSetMessagingTimeout(e, 0.3)
            if adapter.isItem(e) {
                if matches(e) { hit = e }
                index += 1; return
            }
            for k in e.elements(kAXChildrenAttribute) { walk(k, depth + 1) }
        }
        walk(root, 0)
        if hit != nil { return hit }
        // Off screen: the rows the collection does not list, reached from the last listed one (as the wave does).
        var lastSeen: AXUIElement?
        var visited2 = 0
        func lastItem(_ e: AXUIElement, _ depth: Int) {
            guard visited2 < 600, depth < 10 else { return }
            visited2 += 1
            if adapter.isItem(e) { lastSeen = e; return }
            for k in e.elements(kAXChildrenAttribute) { lastItem(k, depth + 1) }
        }
        lastItem(root, 0)
        var firstSeen: AXUIElement?
        var visited3 = 0
        func firstItem(_ e: AXUIElement, _ depth: Int) {
            guard firstSeen == nil, visited3 < 600, depth < 10 else { return }
            visited3 += 1
            if adapter.isItem(e) { firstSeen = e; return }
            for k in e.elements(kAXChildrenAttribute) { firstItem(k, depth + 1) }
        }
        firstItem(root, 0)
        let deadline = Date().addingTimeInterval(1.5)
        var hops = 0
        var walked: [AXUIElement] = []   // a chain that comes round on itself stops (600 hops seen, 27 Oct 2026)
        for (start, forward) in [(lastSeen, true), (firstSeen, false)] {
            var cursor = start; var skipped = 0
            while let c = cursor, hops < 600, Date() < deadline {
                guard let next = forward ? adapter.nextSibling(of: c) : adapter.previousSibling(of: c) else { break }
                if walked.contains(where: { CFEqual($0, next) }) { break }
                walked.append(next)
                hops += 1
                AXUIElementSetMessagingTimeout(next, 0.3)
                if adapter.isItem(next) {
                    if matches(next) { return next }
                    skipped = 0
                } else { skipped += 1; if skipped > 20 { break } }
                cursor = next
            }
        }
        Log.io("flat view: \(key.text) not among \(index) listed items nor \(hops) siblings either way")
        return nil
    }

    /// Whether what the system finds under the item's click point is the item (or a part of it) and not something
    /// the adapter forbids.
    nonisolated static func hitAgrees(_ e: AXUIElement, key: FlatKey, adapter: FlatAdapter) -> Bool {
        guard let p = adapter.clickPoint(for: e) else { return true }   // an item acted on by its own action, not a click
        let app = AXUIElementCreateApplication(e.pid)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &hit) == .success, let hit else { return false }
        var x: AXUIElement? = hit; var hops = 0
        while let y = x, hops < 8 {
            if adapter.unsafeHit(y) { return false }
            if CFEqual(y, e) { return true }
            if adapter.isItem(y) { return adapter.key(for: y, index: -1) == key }
            x = y.element(kAXParentAttribute); hops += 1
        }
        return false
    }
}
