// SPDX-License-Identifier: GPL-3.0-or-later
// snapshot: how long one copy of a window's accessibility tree takes, three ways (prototype, 10 Nov 2026).
//
// 1. AXSnapshotCapture with the private whole-subtree read (AXHierarchyBridge), where this macOS has it.
// 2. AXSnapshotCapture with the public batched read only: one question an element.
// 3. One attribute a question, as most of the reader asks today: the baseline the snapshot is meant to replace.
//
// Read-only. It logs counts, timings and a role census; never a title, label, value or identifier.
import Foundation
import ApplicationServices
import TurnOverAX
import AppKit

func runSnapshotGate(_ args: [String]) {
    let opts = Options(args)
    guard let app = resolveApp(opts) else { Log.line("no target app"); return }
    Log.line("target: \(app.bundleIdentifier ?? "?"), pid \(app.processIdentifier)")
    let appEl = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(appEl, 5)
    guard let window = appEl.element(kAXFocusedWindowAttribute) ?? appEl.elements(kAXWindowsAttribute).first else {
        Log.line("no window"); return
    }
    AXUIElementSetMessagingTimeout(window, 5)
    if opts.has("profile") { profileSnapshot(window, seconds: opts.double("seconds", 8)); return }
    Log.line("private whole-subtree read available: \(AXHierarchyBridge.isAvailable)")
    let limits = AXSnapshotLimits(maxNodes: 20_000, maxDepth: 80, seconds: 10)
    let repeats = max(1, opts.int("repeat", 3))

    func describe(_ name: String, _ s: AXSnapshot) {
        let source = [s.source.contains(.hierarchy) ? "hierarchy" : nil, s.source.contains(.batched) ? "batched" : nil].compactMap { $0 }.joined(separator: "+")
        let unfilled = s.unfilledCount
        Log.line(String(format: "%@: %d elements, %d questions, %.0f ms, source %@, unfilled %d, stop %@",
                        name, s.nodes.count, s.questions, s.milliseconds, source.isEmpty ? "none" : source, unfilled, s.stop?.rawValue ?? "none"))
    }

    var last: AXSnapshot?
    rounds: for round in 1...repeats {
        Log.line("round \(round)")
        // The public batched read first, then the baseline, and the private read last: if it times out the app is
        // left busy, and nothing measured after it would mean anything (the 56,000-element page, 10 Nov 2026).
        let batched = AXSnapshotCapture.capture(window, limits: limits, useHierarchy: false)
        describe("  public batched   ", batched)
        last = batched
        if batched.stop == .appResting { Log.line("  the app is resting after a timeout; stopping here"); break }

        // The baseline: the same attributes, one question each, over as many elements in the same order.
        let before = AXStats.calls
        let cap = max(1, batched.nodes.count)
        let single = timed {
            var stack = [window], visited = 0
            var seen = Set<ElementKey>()
            while let e = stack.popLast(), visited < cap {
                guard seen.insert(ElementKey(e)).inserted else { continue }
                visited += 1
                for name in [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
                             kAXIdentifierAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute] { _ = e.attr(name) }
                stack.append(contentsOf: ((e.attr(kAXChildrenAttribute) as? [AXUIElement]) ?? []).reversed())
            }
            return visited
        }
        Log.line(String(format: "  one attribute each: %d elements, %d questions, %.0f ms", single.value, AXStats.calls - before, single.ms))

        if AXHierarchyBridge.isAvailable {
            if AXHierarchyBridge.timedOutRecently(app.processIdentifier) { Log.line("  with private read: skipped, it timed out on this app within the last minute"); continue }
            let s = AXSnapshotCapture.capture(window, limits: limits, useHierarchy: true)
            describe("  with private read", s)
            if s.stop == .appBusy { Log.line("  the private read timed out and the app is still busy with it; stopping here"); break rounds }
        }
    }

    guard let last else { return }
    var census: [String: Int] = [:]
    for node in last.nodes { census[node.role.isEmpty ? "(none)" : node.role, default: 0] += 1 }
    Log.line("roles in the last batched snapshot, deepest level \(last.nodes.map(\.depth).max() ?? 0):")
    for (role, n) in census.sorted(by: { $0.value > $1.value }).prefix(15) { Log.line("  \(n)\t\(role)") }
}

/// --profile: where a window's batched read spends its time. One batched question an element, as the snapshot asks,
/// each timed; then the totals by role, and for the slowest roles each attribute asked alone on a few elements.
/// Roles, counts and milliseconds only.
private func profileSnapshot(_ window: AXUIElement, seconds: Double) {
    let names = [kAXChildrenAttribute, kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
                 kAXIdentifierAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute, kAXRoleDescriptionAttribute]
    struct Tally { var count = 0; var ms = 0.0; var worst = 0.0; var children = 0; var samples: [AXUIElement] = [] }
    var byRole: [String: Tally] = [:]
    var byDepth: [Int: (count: Int, ms: Double)] = [:]
    var stack: [(AXUIElement, Int)] = [(window, 0)]
    var seen = Set<ElementKey>()
    let started = Date()
    var visited = 0
    while let (e, depth) = stack.popLast(), Date().timeIntervalSince(started) < seconds {
        guard seen.insert(ElementKey(e)).inserted else { continue }
        visited += 1
        let t = timed { e.attrs(names) }
        let role = t.value[kAXRoleAttribute] as? String ?? "(no answer)"
        let kids = (t.value[kAXChildrenAttribute] as? [AXUIElement]) ?? []
        var tally = byRole[role] ?? Tally()
        tally.count += 1; tally.ms += t.ms; tally.worst = max(tally.worst, t.ms); tally.children += kids.count
        if tally.samples.count < 12 { tally.samples.append(e) }
        byRole[role] = tally
        let d = byDepth[depth] ?? (0, 0)
        byDepth[depth] = (d.count + 1, d.ms + t.ms)
        stack.append(contentsOf: kids.reversed().map { ($0, depth + 1) })
    }
    // Rows on screen against rows scrolled out of sight: a table lists every row it has loaded as a child, but the
    // app may only have built the ones showing.
    func subtreeCost(_ roots: [AXUIElement]) -> (elements: Int, ms: Double) {
        var n = 0, ms = 0.0
        var todo = roots
        while let e = todo.popLast(), n < 4000 {
            let t = timed { e.attrs(names) }
            n += 1; ms += t.ms
            todo.append(contentsOf: (t.value[kAXChildrenAttribute] as? [AXUIElement]) ?? [])
        }
        return (n, ms)
    }
    for role in ["AXTable", "AXOutline"] {
        for table in byRole[role]?.samples ?? [] {
            let rows = table.elements(kAXRowsAttribute), visible = table.elements("AXVisibleRows")
            guard rows.count > 0 else { continue }
            // What an arrow key asks of a list before the key is even sent on (SelectableList.moveSelection).
            let askRows = (0..<5).map { _ in timed { _ = table.elements(kAXRowsAttribute) }.ms }.sorted()[2]
            let askSelected = (0..<5).map { _ in timed { _ = table.elements(kAXSelectedRowsAttribute) }.ms }.sorted()[2]
            Log.line(String(format: "%@ with %d rows: asking for all its rows takes %.2f ms, for its selected rows %.2f ms (medians of five)", role, rows.count, askRows, askSelected))
            let shown = Set(visible.map(ElementKey.init))
            let hidden = rows.filter { !shown.contains(ElementKey($0)) }
            let a = subtreeCost(Array(visible.prefix(40))), b = subtreeCost(Array(hidden.prefix(40)))
            let again = subtreeCost(Array(hidden.prefix(40)))
            Log.line(String(format: "%@ with %d rows, %d on screen: on-screen rows %d elements at %.2f ms each; off-screen rows %d elements at %.2f ms each, and %.2f ms each asked again at once",
                            role, rows.count, visible.count, a.elements, a.ms / Double(max(1, a.elements)), b.elements, b.ms / Double(max(1, b.elements)), again.ms / Double(max(1, again.elements))))
        }
    }
    let total = byRole.values.reduce(0) { $0 + $1.ms }
    Log.line(String(format: "profile: %d elements in %.0f ms of questions (%.2f ms each)%@", visited, total, total / Double(max(1, visited)),
                    stack.isEmpty ? "" : ", stopped at the time limit with \(stack.count) waiting"))
    Log.line("by role: count, total ms, mean ms, worst ms, children listed")
    let ranked = byRole.sorted { $0.value.ms > $1.value.ms }
    for (role, t) in ranked.prefix(12) {
        Log.line(String(format: "  %@: %d, %.0f, %.2f, %.1f, %d", role, t.count, t.ms, t.ms / Double(t.count), t.worst, t.children))
    }
    Log.line("by depth: count, total ms")
    for depth in byDepth.keys.sorted() { Log.line(String(format: "  %d: %d, %.0f", depth, byDepth[depth]!.count, byDepth[depth]!.ms)) }
    for (role, t) in ranked.prefix(4) {
        Log.line("each attribute alone, mean ms over \(t.samples.count) \(role) elements:")
        var line: [String] = []
        for name in names {
            let ms = t.samples.map { e in timed { _ = e.attr(name) }.ms }.reduce(0, +) / Double(max(1, t.samples.count))
            line.append(String(format: "%@ %.2f", name, ms))
        }
        Log.line("  " + line.joined(separator: ", "))
    }
}
