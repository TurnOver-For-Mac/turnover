// SPDX-License-Identifier: GPL-3.0-or-later
// The flat screen (docs/FLAT-VIEW-PLAN.md, 27 Oct 2026): an area read from what the app has drawn, not from what its
// tree lists. Measured on the App Store's results page that evening: the list's children are every result, but a
// result the Store hasn't drawn answers blank (its title is an invalid element), the frames of rows lag the page by
// a row after a reflow, and the page keeps the last search's scroll offset. The system's hit test, though, names
// what is really at a point, and a click at such a point opens the row. So the area is a run of screens: the visible
// area is scanned with hit tests, the tiles found are the items in reading order, moving past the last tile scrolls
// a screen and scans again, and opening clicks the point the scan found. Behind the developer switch `flatView`.
import Foundation
import AppKit
import ApplicationServices

/// Synchronous reads on the screen's serial worker. Providers must check `current` before
/// scrolling or further reads after a wait; the owner also checks every returned snapshot.
nonisolated public protocol FlatScreenSource: Sendable {
    func firstScreen(current: @Sendable () -> Bool) -> [FlatScreen.Tile]
    func nextScreen(known: [FlatScreen.Tile], current: @Sendable () -> Bool) -> (tiles: [FlatScreen.Tile], ended: Bool)
    func point(for tile: FlatScreen.Tile, current: @Sendable () -> Bool) -> CGPoint?
}

public final class FlatScreen {
    nonisolated public struct Tile: Sendable {
        public var name: String
        public var label: String
        public var point: CGPoint        // a point whose hit test reached the tile, with nothing unsafe on the way
        public var bar: Double           // the scroll bar's value when the tile was there
        public init(name: String, label: String, point: CGPoint, bar: Double) {
            self.name = name; self.label = label; self.point = point; self.bar = bar
        }
    }

    nonisolated public let adapter: FlatAdapter
    nonisolated public let name: String
    public private(set) var items: [FlatItem] = []
    public var onChange: (([FlatItem]) -> Void)?
    nonisolated private let queue: DispatchQueue
    nonisolated private let source: FlatScreenSource?
    nonisolated private let deliver: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    nonisolated private struct State: Sendable {
        var generation = 0
        var active = false
        var page = UUID()
        var revision = 0
        var resolveRequest = 0
        var tiles: [Tile] = []
        var atEnd = false
    }
    // All worker/main lifecycle, snapshots and request identities share this one lock. UI state
    // (`items`, `onChange`) belongs to main; a queued delivery rechecks the locked identity there.
    // A check before dispatch alone let an old page publish or open after end/begin (#167, 28 Oct 2026).
    nonisolated private let state = Locked(State())

    public init(name: String, adapter: FlatAdapter, source: FlatScreenSource? = nil, queue: DispatchQueue? = nil,
                deliver: @escaping @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void = { onMain($0) }) {
        self.name = name; self.adapter = adapter
        self.source = source
        self.queue = queue ?? DispatchQueue(label: "turnover.flatscreen.\(name)", qos: .userInitiated)
        self.deliver = deliver
    }

    // MARK: Pages

    /// The area is being entered: to the top, one scan, and the first tile is published.
    public func begin() {
        state.lock.lock()
        state.unsafeValue.generation += 1
        state.unsafeValue.active = true
        state.unsafeValue.page = UUID()
        state.unsafeValue.tiles = []; state.unsafeValue.atEnd = false
        state.unsafeValue.revision += 1
        let g = state.unsafeValue.generation
        state.lock.unlock()
        items = []
        onChange?([])
        Log.io("flat screen \(name): begin (generation \(g))")
        queue.async { [self] in
            guard current(g) else { return }
            let found = source?.firstScreen(current: { current(g) }) ?? firstScreen(g)
            state.lock.lock()
            guard state.unsafeValue.active, state.unsafeValue.generation == g else { state.lock.unlock(); return }
            state.unsafeValue.tiles = found; state.unsafeValue.revision += 1
            state.lock.unlock()
            publish(g)
        }
    }

    public func end() {
        state.lock.lock()
        state.unsafeValue.generation += 1; state.unsafeValue.active = false
        state.unsafeValue.tiles = []; state.unsafeValue.atEnd = false
        let g = state.unsafeValue.generation
        state.lock.unlock()
        items = []; onChange?([])
        Log.io("flat screen \(name): end (generation \(g))")
    }

    /// More tiles, from the next screen down: `then` gets the new count, or the same count at the end of the area.
    public func extend(then: @escaping @MainActor @Sendable (Int) -> Void) {
        let snapshot = state.value
        guard snapshot.active else { return }
        let g = snapshot.generation
        queue.async { [self] in
            let snapshot = state.value
            guard snapshot.active, snapshot.generation == g else { return }
            // Take the list when this serial operation starts, after earlier extensions finish.
            let known = snapshot.tiles
            guard !snapshot.atEnd else { finish(then, known.count, generation: g); return }
            let result = source?.nextScreen(known: known, current: { current(g) }) ?? nextScreen(known: known, generation: g)
            state.lock.lock()
            guard state.unsafeValue.active, state.unsafeValue.generation == g else { state.lock.unlock(); return }
            let fresh = result.tiles.filter { t in !state.unsafeValue.tiles.contains { $0.name == t.name } }
            state.unsafeValue.tiles.append(contentsOf: fresh)
            state.unsafeValue.atEnd = result.ended
            state.unsafeValue.revision += 1
            let count = state.unsafeValue.tiles.count
            state.lock.unlock()
            publish(g)
            finish(then, count, generation: g)
        }
    }

    /// Where a tile is now: the page back to where it was, the screen scanned for it, and the point to click.
    public func cancelResolution() {
        state.lock.lock(); state.unsafeValue.resolveRequest += 1; state.lock.unlock()
    }

    /// Resolve only the captured item on its original page, while this remains the newest request.
    public func resolve(_ item: FlatItem, then: @escaping @MainActor @Sendable (CGPoint?) -> Void) {
        state.lock.lock()
        state.unsafeValue.resolveRequest += 1
        let snapshot = state.unsafeValue
        state.lock.unlock()
        let g = snapshot.generation, request = snapshot.resolveRequest
        guard snapshot.active, item.page == snapshot.page else { return }
        guard case .position(let position) = item.key, position == item.index,
              snapshot.tiles.indices.contains(position), let expected = item.name,
              snapshot.tiles[position].name == expected else { then(nil); return }
        let tile = snapshot.tiles[position]
        queue.async { [self] in
            guard current(g, request: request) else { return }
            let point: CGPoint?
            if let source { point = source.point(for: tile, current: { current(g, request: request) }) }
            else { point = resolvePoint(tile, generation: g, request: request) }
            guard current(g, request: request) else { return }
            if point == nil { Log.io("flat screen \(name): \"\(Log.words(tile.name.prefix(40).description))\" is not under any point on its screen now") }
            deliver { [self] in
                guard current(g, request: request), items.indices.contains(item.index) else { return }
                let published = items[item.index]
                guard published.page == item.page, published.name == expected else { return }
                then(point)
            }
        }
    }

    nonisolated private func firstScreen(_ g: Int) -> [Tile] {
        guard current(g) else { return [] }
        if let bar = adapter.scrollBar(), current(g), let v = bar.attr(kAXValueAttribute) as? Double, v > 0.001 {
            guard current(g) else { return [] }
            _ = bar.set(kAXValueAttribute, NSNumber(value: 0)); usleep(300_000)
        }
        var found: [Tile] = []
        for _ in 0..<6 {
            guard current(g) else { return [] }
            found = scan(current: { current(g) })
            if !found.isEmpty { break }
            usleep(350_000)
        }
        return found
    }

    nonisolated private func nextScreen(known: [Tile], generation g: Int) -> (tiles: [Tile], ended: Bool) {
        guard current(g), let bar = adapter.scrollBar() else { return ([], false) }
        let page = pageFraction()
        guard current(g) else { return ([], false) }
        let before = (bar.attr(kAXValueAttribute) as? Double) ?? 0
        let at = min(1, before + page)
        guard current(g) else { return ([], false) }
        _ = bar.set(kAXValueAttribute, NSNumber(value: at)); usleep(300_000)
        var fresh: [Tile] = []
        for _ in 0..<3 {
            guard current(g) else { return ([], false) }
            fresh = scan(current: { current(g) }).filter { t in !known.contains { $0.name == t.name } }
            if !fresh.isEmpty { break }
            usleep(300_000)
        }
        return (fresh, fresh.isEmpty && at >= 0.999)
    }

    nonisolated private func resolvePoint(_ tile: Tile, generation g: Int, request: Int) -> CGPoint? {
        guard current(g, request: request) else { return nil }
        if let bar = adapter.scrollBar(), current(g, request: request),
           let v = bar.attr(kAXValueAttribute) as? Double, abs(v - tile.bar) > 0.005 {
            guard current(g, request: request) else { return nil }
            _ = bar.set(kAXValueAttribute, NSNumber(value: tile.bar)); usleep(300_000)
        }
        guard current(g, request: request) else { return nil }
        return FlatView.scanFor(tile.name, position: 0, of: 1, adapter: adapter, current: { self.current(g, request: request) })
    }

    // MARK: Scan

    /// The tiles on screen in reading order (rows of the grid top to bottom, left to right): the area hit tested
    /// every 60 by 40 points, each hit followed up to the tile it belongs to.
    nonisolated private func scan(current: @Sendable () -> Bool) -> [Tile] {
        guard current() else { return [] }
        guard let area = adapter.screenArea(), let root = adapter.areaRoot() else { return [] }
        let app = AXUIElementCreateApplication(root.pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        let bar = (adapter.scrollBar()?.attr(kAXValueAttribute) as? Double) ?? 0
        let start = Date()
        var seen: [String: (tile: Tile, score: Int, origin: CGPoint)] = [:]
        var hits = 0
        var y = area.minY + 20
        while y < area.maxY - 10 {
            var x = area.minX + 20
            while x < area.maxX - 10 {
                guard current() else { return [] }
                var hit: AXUIElement?
                if AXUIElementCopyElementAtPosition(app, Float(x), Float(y), &hit) == .success, let hit {
                    hits += 1
                    var e: AXUIElement? = hit; var hops = 0; var unsafe = false; var viaImage = false
                    while let c = e, hops < 8 {
                        guard current() else { return [] }
                        if adapter.unsafeHit(c) { unsafe = true; break }
                        guard current() else { return [] }
                        if c.role == "AXImage" { viaImage = true }
                        guard current() else { return [] }
                        if adapter.isItem(c) {
                            guard current() else { return [] }
                            if !unsafe, let n = adapter.name(for: c) {
                                guard current() else { return [] }
                                let score = viaImage ? 2 : (hit.role == "AXGroup" ? 1 : 0)
                                let p = CGPoint(x: x, y: y)
                                if var have = seen[n] {
                                    if score > have.score { have.tile.point = p; have.score = score; seen[n] = have }
                                } else {
                                    seen[n] = (Tile(name: n, label: adapter.label(for: c, name: n), point: p, bar: bar), score, p)
                                }
                            }
                            break
                        }
                        guard current() else { return [] }
                        e = c.element(kAXParentAttribute); hops += 1
                    }
                }
                x += 60
            }
            y += 40
        }
        // Reading order: the grid's rows 80 points apart or more, left to right within a row.
        let ordered = seen.values.sorted { a, b in
            let ra = Int(a.origin.y / 80), rb = Int(b.origin.y / 80)
            return ra != rb ? ra < rb : a.origin.x < b.origin.x
        }.map { $0.tile }
        Log.io("flat screen \(name): \(hits) hits in \(Int(Date().timeIntervalSince(start) * 1000)) ms, \(ordered.count) tiles: \(ordered.map { $0.name.prefix(16) }.joined(separator: " | ").prefix(240))")
        return ordered
    }

    /// How far one screen moves the scroll bar.
    nonisolated private func pageFraction() -> Double {
        guard let area = adapter.screenArea(), let root = adapter.areaRoot(), let total = TurnOverObject.frame(root)?.height, total > area.height else { return 1 }
        return area.height / (total - area.height) * 0.85
    }

    nonisolated private func current(_ g: Int, request: Int? = nil) -> Bool {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.unsafeValue.active && state.unsafeValue.generation == g
            && (request == nil || state.unsafeValue.resolveRequest == request)
    }

    nonisolated private func publish(_ g: Int) {
        let snapshot = state.value
        guard snapshot.active, snapshot.generation == g else { return }
        let list = itemList(snapshot)
        deliver { [weak self] in
            guard let self else { return }
            let current = state.value
            guard current.active, current.generation == g, current.revision == snapshot.revision else { return }
            guard items != list else { return }
            items = list; onChange?(list)
        }
    }

    nonisolated private func finish(_ then: @escaping @MainActor @Sendable (Int) -> Void, _ count: Int, generation g: Int) {
        deliver { [weak self] in
            guard let self else { return }
            let snapshot = state.value
            guard snapshot.active, snapshot.generation == g else { return }
            // A later extension can supersede the publication queued before this completion.
            // The cursor callback must see at least the rows represented by its returned count.
            let list = itemList(snapshot)
            if items != list { items = list; onChange?(list) }
            guard current(g) else { return }   // an observer may have ended or changed the page
            then(count)
        }
    }

    nonisolated private func itemList(_ snapshot: State) -> [FlatItem] {
        snapshot.tiles.enumerated().map {
            FlatItem(key: .position($0.offset), name: $0.element.name, label: $0.element.label, index: $0.offset, page: snapshot.page)
        }
    }
}
