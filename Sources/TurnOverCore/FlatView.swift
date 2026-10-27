// SPDX-License-Identifier: GPL-3.0-or-later
// The flat view (docs/FLAT-VIEW-PLAN.md, 27 Oct 2026): one area of a window as a list of items kept by position,
// never by element, with the names learned as the app answers them. Measured on the App Store's results page the
// same evening: the rows' structure (which rows, in what order) answers reliably; a row's name answers in bursts,
// blank most of the time while the app loads, on screen or not. So: positions from the structure, names asked for
// patiently around where the person is and kept once answered, and acting in one breath: walk to the position,
// wait for the name, confirm it, scroll into view, hit test, click. Behind the developer switch `flatView`.
import Foundation
import AppKit
import ApplicationServices

nonisolated public enum FlatKey: Hashable, Sendable {
    /// The item's place among the area's rows: readable even when its name is not.
    case position(Int)
    public var text: String { if case .position(let n) = self { return "row \(n + 1)" }; return "" }
}

nonisolated public struct FlatItem: Sendable, Equatable {
    public var key: FlatKey
    /// The name as the app answered it, once it did; nil until then.
    public var name: String?
    /// What is said: the adapter's label once the name is known, else a placeholder ("row 7").
    public var label: String
    public var index: Int
    public init(key: FlatKey, name: String?, label: String, index: Int) { self.key = key; self.name = name; self.label = label; self.index = index }
}

/// What an app's module tells the engine about an area. Every method runs off the main thread and reads the live
/// tree only.
nonisolated public protocol FlatAdapter: AnyObject, Sendable {
    func areaRoot() -> AXUIElement?
    func isItem(_ e: AXUIElement) -> Bool
    /// The item's name as the app answers it now, or nil when it answers blank (asked again later).
    func name(for e: AXUIElement) -> String?
    /// What is said for an item whose name is known (the name and its button).
    func label(for e: AXUIElement, name: String) -> String
    func clickPoint(for e: AXUIElement) -> CGPoint?
    func unsafeHit(_ e: AXUIElement) -> Bool
    var settleTimes: [Double] { get }
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
    public private(set) var items: [FlatItem] = []
    public var onChange: (([FlatItem]) -> Void)?
    private let queue: DispatchQueue          // discovery: the structure
    private let nameQueue: DispatchQueue      // the names, patiently, never holding the structure up
    private let actQueue: DispatchQueue       // resolve: never behind a wave
    private let lock = NSLock()
    nonisolated(unsafe) private var resolving = false   // owned by `lock`: no freshness walk meanwhile
    // Owned by `lock`:
    nonisolated(unsafe) private var generation = 0
    nonisolated(unsafe) private var rows: [AXUIElement] = []        // the structure as last walked, by position
    nonisolated(unsafe) private var names: [Int: String] = [:]      // the names learned, by position
    nonisolated(unsafe) private var labels: [Int: String] = [:]
    nonisolated(unsafe) private var cursor = 0
    nonisolated(unsafe) private var naming = false
    private var freshness: Timer?

    public init(name: String, adapter: FlatAdapter) {
        self.name = name; self.adapter = adapter
        queue = DispatchQueue(label: "turnover.flatview.\(name)", qos: .utility)
        nameQueue = DispatchQueue(label: "turnover.flatview.\(name).names", qos: .utility)
        actQueue = DispatchQueue(label: "turnover.flatview.\(name).act", qos: .userInitiated)
    }

    // MARK: Discover

    /// A page changed or the area is being entered: the structure now, the settle waves after, and the names
    /// around the start.
    public func begin() {
        lock.lock(); generation += 1; let g = generation; rows = []; names = [:]; labels = [:]; cursor = 0; lock.unlock()
        Log.io("flat view \(name): begin (generation \(g))")
        structure(reason: "begin", generation: g)
        for t in adapter.settleTimes {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.structure(reason: "settle \(t) s", generation: g) }
        }
        freshness?.invalidate()
        freshness = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lock.lock(); let busy = self.resolving; self.lock.unlock()
                if !busy { self.structure(reason: "freshness", generation: g) }
            }
        }
    }

    public func end() { freshness?.invalidate(); freshness = nil; lock.lock(); generation += 1; let g = generation; lock.unlock(); Log.io("flat view \(name): end (generation \(g))") }

    /// The person is on this item: its name and its neighbours' are asked for until they answer.
    public func cursor(at index: Int) {
        lock.lock(); cursor = index; let g = generation; lock.unlock()
        learnNames(generation: g)
    }

    /// The rows in order: the ones the collection lists, then the siblings before and after, non-rows skipped.
    /// Bounded: 400 listed elements, 600 siblings, a second and a half.
    nonisolated static func walkStructure(adapter: FlatAdapter) -> (rows: [AXUIElement], complete: Bool, topReached: Bool) {
        guard let root = adapter.areaRoot() else { return ([], false, false) }
        AXUIElementSetMessagingTimeout(root, 0.3)
        let deadline = Date().addingTimeInterval(1.5)
        var listed: [AXUIElement] = []; var visited = 0; var complete = true
        func walk(_ e: AXUIElement, _ depth: Int) {
            if visited >= 400 || depth >= 10 || Date() > deadline { complete = false; return }
            visited += 1
            AXUIElementSetMessagingTimeout(e, 0.3)
            if adapter.isItem(e) { listed.append(e); return }
            for k in e.elements(kAXChildrenAttribute) { walk(k, depth + 1); if !complete { return } }
        }
        walk(root, 0)
        var hops = 0
        var ended = false   // the chain ended at the end (no sibling), not at a bound
        func chain(from start: AXUIElement?, forward: Bool) -> [AXUIElement] {
            var out: [AXUIElement] = []; var cursor = start; var skipped = 0
            ended = false
            while let c = cursor, hops < 600, Date() < deadline {
                guard let next = forward ? adapter.nextSibling(of: c) : adapter.previousSibling(of: c) else { ended = true; break }
                if listed.contains(where: { CFEqual($0, next) }) || out.contains(where: { CFEqual($0, next) }) { ended = true; break }
                hops += 1
                AXUIElementSetMessagingTimeout(next, 0.3)
                if adapter.isItem(next) { out.append(next); skipped = 0 } else { skipped += 1; if skipped > 20 { break } }
                cursor = next
            }
            if cursor == nil { ended = true }
            return out
        }
        // The top first: a position means nothing unless the walk reached the first row.
        let before = chain(from: listed.first, forward: false).reversed()
        let topReached = ended
        let after = chain(from: listed.last, forward: true)
        if Date() >= deadline || hops >= 600 { complete = false }
        return (Array(before) + listed + after, complete, topReached)
    }

    private func structure(reason: String, generation g: Int) {
        queue.async { [self] in
            lock.lock(); let current = generation; lock.unlock()
            guard current == g else { Log.io("flat view \(name): \(reason) dropped (generation \(g), now \(current))"); return }
            let start = Date()
            let (found, complete, topReached) = Self.walkStructure(adapter: adapter)
            lock.lock()
            let still = generation == g
            // A walk that did not reach the first row cannot number the rows: kept out.
            if still, !found.isEmpty, topReached, complete || found.count >= rows.count { rows = found }
            let count = rows.count
            lock.unlock()
            guard still else { return }
            Log.io("flat view \(name): \(reason): \(found.count) rows in \(Int(Date().timeIntervalSince(start) * 1000)) ms\(complete ? "" : " (cut short)")\(topReached ? "" : " (top not reached)"); \(count) kept")
            publish()
            learnNames(generation: g)
        }
    }

    /// The names near the cursor, asked for every 150 ms for up to two seconds, until they answer; what answers is
    /// kept and published. One run at a time.
    private func learnNames(generation g: Int) {
        nameQueue.async { [self] in
            lock.lock()
            guard generation == g, !naming else { lock.unlock(); return }
            naming = true
            lock.unlock()
            defer { lock.lock(); naming = false; lock.unlock() }
            // Patient: as long as the row the person is on has no name, keep asking (every 300 ms, up to ten seconds);
            // the neighbours' names come with it. The Store answers in bursts.
            let end = Date().addingTimeInterval(10.0)
            var rounds = 0, blankRounds = 0
            while Date() < end, rounds < 40 {
                rounds += 1
                lock.lock()
                let still = generation == g
                let c = cursor
                let window = rows.isEmpty ? [] : Array(max(0, c - 5)...min(rows.count - 1, c + 15)).filter { names[$0] == nil }
                let elements = window.map { ($0, rows[$0]) }
                let cursorNamed = names[c] != nil
                lock.unlock()
                guard still else { return }
                if elements.isEmpty || (cursorNamed && rounds > 3) { break }
                var learned = 0
                for (i, e) in elements {
                    AXUIElementSetMessagingTimeout(e, 0.3)
                    guard let n = adapter.name(for: e) else { continue }
                    let label = adapter.label(for: e, name: n)
                    lock.lock(); names[i] = n; labels[i] = label; lock.unlock()
                    learned += 1
                }
                if learned > 0 { Log.io("flat view \(name): \(learned) names answered (round \(rounds))"); publish(); blankRounds = 0 } else { blankRounds += 1 }
                usleep(300_000)
            }
            if blankRounds > 0 { Log.io("flat view \(name): \(blankRounds) rounds with no name answered (cursor row \(cursor + 1))") }
        }
    }

    private func publish() {
        lock.lock()
        let list = rows.indices.map { i in FlatItem(key: .position(i), name: names[i], label: labels[i] ?? "row \(i + 1)", index: i) }
        lock.unlock()
        DispatchQueue.main.async { MainActor.assumeIsolated {
            guard list != self.items else { return }
            self.items = list
            self.onChange?(list)
        } }
    }

    // MARK: Resolve

    /// The item found again, now: the row at its position (the structure walked again if the one kept has gone),
    /// asked for its name until it answers, which must be the name that was read; scrolled into view; the hit test
    /// under its click point agreeing. Two seconds in all, then a reason. `then` runs on main.
    public func resolve(_ item: FlatItem, then: @escaping @MainActor @Sendable (AXUIElement?) -> Void) {
        guard case .position(let n) = item.key else { then(nil); return }
        let adapter = self.adapter, viewName = self.name
        lock.lock(); let kept = rows.indices.contains(n) ? rows[n] : nil; let expected = names[n]; resolving = true; lock.unlock()
        Log.io("flat view \(viewName): resolving row \(n + 1)\(expected.map { " (\($0))" } ?? "")")
        actQueue.async {
            defer { self.lock.lock(); self.resolving = false; self.lock.unlock() }
            let end = Date().addingTimeInterval(3.0)
            var row = kept
            var reason = "the row didn't answer in time"
            var answered: String?
            var blankSince = Date()
            if let r = row { _ = AXUIElementPerformAction(r, "AXScrollToVisible" as CFString) }   // on screen first: it answers sooner there
            while Date() < end {
                if let r = row {
                    AXUIElementSetMessagingTimeout(r, 0.3)
                    if let n = adapter.name(for: r) {
                        answered = n
                        if let expected, expected != n { row = nil; reason = "the row is now \(n), not \(expected)" }
                        else {
                            _ = AXUIElementPerformAction(r, "AXScrollToVisible" as CFString)
                            usleep(150_000)
                            if Self.hitAgrees(r, name: n, adapter: adapter) {
                                let e = r; DispatchQueue.main.async { MainActor.assumeIsolated { then(e) } }; return
                            }
                            reason = "something else is under it on screen"
                        }
                    } else if r.role == "?" || Date().timeIntervalSince(blankSince) > 0.6 { row = nil }   // gone, or blank too long: the structure again
                }
                if row == nil {
                    let (rows, _, topReached) = Self.walkStructure(adapter: adapter)
                    if topReached {
                        // The row at the position, or, the page having shifted a little, a neighbour with the name read.
                        var candidates = rows.indices.contains(n) ? [rows[n]] : []
                        if let expected { for d in [-1, 1, -2, 2, -3, 3] where rows.indices.contains(n + d) { candidates.append(rows[n + d]) } }
                        row = candidates.first { expected == nil || adapter.name(for: $0) == expected } ?? candidates.first
                        if let r = row { _ = AXUIElementPerformAction(r, "AXScrollToVisible" as CFString); let named = (expected != nil && adapter.name(for: r) == expected); _ = named }
                        if let r = row, let expected, adapter.name(for: r) != expected, adapter.name(for: r) != nil { reason = "the page has moved; the row is elsewhere now"; row = nil }
                    }
                    if row == nil { reason = reason == "the row didn't answer in time" ? "the page's rows couldn't be counted" : reason }
                    blankSince = Date()
                }
                usleep(150_000)
            }
            Log.io("flat view \(viewName): could not open row \(n + 1)\(expected.map { " (\($0))" } ?? ""): \(reason)\(answered.map { "; it answered \($0)" } ?? "")")
            let said = reason
            DispatchQueue.main.async { MainActor.assumeIsolated { Speech.speakMessage("Not opened: \(said)."); then(nil) } }
        }
    }

    nonisolated static func hitAgrees(_ e: AXUIElement, name: String, adapter: FlatAdapter) -> Bool {
        guard let p = adapter.clickPoint(for: e) else { return true }
        let app = AXUIElementCreateApplication(e.pid)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &hit) == .success, let hit else { return false }
        var x: AXUIElement? = hit; var hops = 0
        while let y = x, hops < 8 {
            if adapter.unsafeHit(y) { return false }
            if CFEqual(y, e) { return true }
            if adapter.isItem(y) {
                // The row under the point, asked its name until it answers (blank is not "another row").
                for _ in 0..<6 {
                    if let n = adapter.name(for: y) { return n == name }
                    usleep(150_000)
                }
                Log.io("flat view: the row under the click point answered no name in a second")
                return false
            }
            x = y.element(kAXParentAttribute); hops += 1
        }
        Log.io("flat view: under the click point is \(hit.role) \(hit.string(kAXIdentifierAttribute) ?? ""), not the row")
        return false
    }
}
