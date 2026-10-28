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

public final class FlatScreen {
    nonisolated struct Tile: Sendable {
        var name: String
        var label: String
        var point: CGPoint        // a point whose hit test reached the tile, with nothing unsafe on the way
        var bar: Double           // the scroll bar's value when the tile was there
    }

    public let adapter: FlatAdapter
    public let name: String
    public private(set) var items: [FlatItem] = []
    public var onChange: (([FlatItem]) -> Void)?
    private let queue: DispatchQueue
    private let lock = NSLock()
    // Owned by `lock`:
    nonisolated(unsafe) private var generation = 0
    nonisolated(unsafe) private var tiles: [Tile] = []
    nonisolated(unsafe) private var atEnd = false

    public init(name: String, adapter: FlatAdapter) {
        self.name = name; self.adapter = adapter
        queue = DispatchQueue(label: "turnover.flatscreen.\(name)", qos: .userInitiated)
    }

    // MARK: Pages

    /// The area is being entered: to the top, one scan, and the first tile is published.
    public func begin() {
        lock.lock(); generation += 1; let g = generation; tiles = []; atEnd = false; lock.unlock()
        Log.io("flat screen \(name): begin (generation \(g))")
        queue.async { [self] in
            guard current(g) else { return }
            if let bar = adapter.scrollBar(), let v = bar.attr(kAXValueAttribute) as? Double, v > 0.001 {
                _ = bar.set(kAXValueAttribute, NSNumber(value: 0)); usleep(300_000)
                Log.io("flat screen \(name): to the top (was \(String(format: "%.2f", v)))")
            }
            // The Store draws a results page in stages: a scan that finds nothing is tried again for two seconds.
            var found: [Tile] = []
            for _ in 0..<6 { found = scan(); if !found.isEmpty { break }; usleep(350_000); guard current(g) else { return } }
            lock.lock(); if generation == g { tiles = found }; lock.unlock()
            publish(g)
        }
    }

    public func end() { lock.lock(); generation += 1; let g = generation; lock.unlock(); Log.io("flat screen \(name): end (generation \(g))") }

    /// More tiles, from the next screen down: `then` gets the new count, or the same count at the end of the area.
    public func extend(then: @escaping @MainActor @Sendable (Int) -> Void) {
        lock.lock(); let g = generation; let known = tiles; let ended = atEnd; lock.unlock()
        guard !ended else { DispatchQueue.main.async { MainActor.assumeIsolated { then(known.count) } }; return }
        queue.async { [self] in
            guard current(g), let bar = adapter.scrollBar() else { finish(then, known.count); return }
            let page = pageFraction()
            let before = (bar.attr(kAXValueAttribute) as? Double) ?? 0
            let at = min(1, before + page)
            _ = bar.set(kAXValueAttribute, NSNumber(value: at)); usleep(300_000)
            var fresh: [Tile] = []
            for _ in 0..<3 {
                fresh = scan().filter { t in !known.contains { $0.name == t.name } }
                if !fresh.isEmpty { break }; usleep(300_000); guard current(g) else { return }
            }
            lock.lock()
            if generation == g {
                tiles.append(contentsOf: fresh)
                if fresh.isEmpty, at >= 0.999 { atEnd = true }
            }
            let count = tiles.count
            lock.unlock()
            Log.io("flat screen \(name): scrolled to \(String(format: "%.2f", at)): \(fresh.count) new tiles, \(count) in all\(fresh.isEmpty && at >= 0.999 ? ", the end" : "")")
            publish(g)
            finish(then, count)
        }
    }

    /// Where a tile is now: the page back to where it was, the screen scanned for it, and the point to click.
    public func resolve(_ item: FlatItem, then: @escaping @MainActor @Sendable (CGPoint?) -> Void) {
        lock.lock(); let g = generation; let tile = tiles.indices.contains(item.index) ? tiles[item.index] : nil; lock.unlock()
        guard let tile else { DispatchQueue.main.async { MainActor.assumeIsolated { then(nil) } }; return }
        queue.async { [self] in
            guard current(g) else { return }
            if let bar = adapter.scrollBar(), let v = bar.attr(kAXValueAttribute) as? Double, abs(v - tile.bar) > 0.005 {
                _ = bar.set(kAXValueAttribute, NSNumber(value: tile.bar)); usleep(300_000)
            }
            let point = FlatView.scanFor(tile.name, position: 0, of: 1, adapter: adapter)
            if point == nil { Log.io("flat screen \(name): \"\(Log.words(tile.name.prefix(40).description))\" is not under any point on its screen now") }
            DispatchQueue.main.async { MainActor.assumeIsolated { then(point) } }
        }
    }

    // MARK: Scan

    /// The tiles on screen in reading order (rows of the grid top to bottom, left to right): the area hit tested
    /// every 60 by 40 points, each hit followed up to the tile it belongs to.
    nonisolated private func scan() -> [Tile] {
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
                var hit: AXUIElement?
                if AXUIElementCopyElementAtPosition(app, Float(x), Float(y), &hit) == .success, let hit {
                    hits += 1
                    var e: AXUIElement? = hit; var hops = 0; var unsafe = false; var viaImage = false
                    while let c = e, hops < 8 {
                        if adapter.unsafeHit(c) { unsafe = true; break }
                        if c.role == "AXImage" { viaImage = true }
                        if adapter.isItem(c) {
                            if !unsafe, let n = adapter.name(for: c) {
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

    nonisolated private func current(_ g: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return generation == g }

    nonisolated private func publish(_ g: Int) {
        lock.lock()
        let list = generation == g ? tiles.enumerated().map { FlatItem(key: .position($0.offset), name: $0.element.name, label: $0.element.label, index: $0.offset) } : nil
        lock.unlock()
        guard let list else { return }
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { guard let self else { return }; self.items = list; self.onChange?(list) } }
    }

    nonisolated private func finish(_ then: @escaping @MainActor @Sendable (Int) -> Void, _ count: Int) {
        DispatchQueue.main.async { MainActor.assumeIsolated { then(count) } }
    }
}
