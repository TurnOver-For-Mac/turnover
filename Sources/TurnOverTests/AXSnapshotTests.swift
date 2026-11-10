// SPDX-License-Identifier: GPL-3.0-or-later
// The window snapshot (10 Nov 2026), built from a replayed recording: order, limits, cancellation, rows on screen.
import Foundation
import ApplicationServices
import TurnOverAX
import AXFixtures

func axSnapshotTests() {
    /// A window (0) holding a toolbar (1) with two buttons (2, 3) and a list (4) with one row (5) holding text (6).
    func window() -> AXFixture {
        var f = AXFixture(app: "T", bundle: "t", recorded: "", root: 0, application: nil, focus: nil, nodes: [])
        func n(_ id: Int, _ role: String, _ parent: Int?, _ children: [Int] = [], _ extra: [String: AXFixture.Value] = [:]) -> AXFixture.Node {
            var a: [String: AXFixture.Value] = ["AXRole": .string(role), "AXPosition": .point(Double(id) * 10, 5), "AXSize": .size(40, 20)]
            if let parent { a["AXParent"] = .element(parent) }
            if !children.isEmpty { a["AXChildren"] = .elements(children) }
            for (k, v) in extra { a[k] = v }
            return .init(id: id, attrs: a)
        }
        f.nodes = [n(0, "AXWindow", nil, [1, 4], ["AXTitle": .string("Sample")]),
                   n(1, "AXToolbar", 0, [2, 3]),
                   n(2, "AXButton", 1, [], ["AXDescription": .string("Back"), "AXEnabled": .bool(false)]),
                   n(3, "AXButton", 1, [], ["AXTitle": .string("Share"), "AXIdentifier": .string("share")]),
                   n(4, "AXList", 0, [5]),
                   n(5, "AXRow", 4, [6]),
                   n(6, "AXStaticText", 5, [], ["AXValue": .string("Hello")])]
        return f
    }

    test("snapshot: the batched read copies a recorded window in order, one question an element") {
        AXReplay.load(window()); defer { AXReplay.unload() }
        let s = AXSnapshotCapture.capture(AXReplay.element(0))
        expect(s.nodes.map(\.role), ["AXWindow", "AXToolbar", "AXButton", "AXButton", "AXList", "AXRow", "AXStaticText"], "preorder")
        expect(s.questions, 7, "questions")
        check(s.isComplete, "complete")
        expect(s.nodes[0].title, "Sample"); expect(s.nodes[0].children, [1, 4])
        expect(s.nodes[2].label, "Back"); expect(s.nodes[2].enabled, false)
        expect(s.nodes[3].identifier, "share"); expect(s.nodes[3].parent, 1)
        expect(s.nodes[6].value, .text("Hello")); expect(s.nodes[6].depth, 3)
        expect(s.nodes[2].frame, CGRect(x: 20, y: 5, width: 40, height: 20))
        expect(s.index(of: AXReplay.element(5)), 5, "an element finds its node")
        expect(s.subtree(1), 1..<4, "the toolbar and its buttons")
        expect(s.first(from: 3) { $0.role == "AXStaticText" }, 6, "the next text after the second button")
    }

    test("snapshot: limits stop it and say why") {
        AXReplay.load(window()); defer { AXReplay.unload() }
        let few = AXSnapshotCapture.capture(AXReplay.element(0), limits: AXSnapshotLimits(maxNodes: 3))
        expect(few.nodes.count, 3); expect(few.stop, .nodes)
        let shallow = AXSnapshotCapture.capture(AXReplay.element(0), limits: AXSnapshotLimits(maxDepth: 1))
        expect(shallow.nodes.map(\.role), ["AXWindow", "AXToolbar", "AXList"], "children, not grandchildren")
        expect(shallow.stop, .depth)
        let late = AXSnapshotCapture.capture(AXReplay.element(0), limits: AXSnapshotLimits(seconds: 0))
        expect(late.nodes.count, 0); expect(late.stop, .deadline)
        let cancelled = AXReadScope.with(while: { false }) { AXSnapshotCapture.capture(AXReplay.element(0)) }
        expect(cancelled.stop, .clientStopped, "the caller's read scope is honoured")
    }

    test("snapshot: an element listed twice, or a child that lists its parent, is taken once") {
        var f = window()
        f.nodes[5].attrs["AXChildren"] = .elements([6, 0, 6])
        AXReplay.load(f); defer { AXReplay.unload() }
        let s = AXSnapshotCapture.capture(AXReplay.element(0))
        expect(s.nodes.count, 7, "no loop, no duplicate")
    }

    test("snapshot: a resting app is not asked, and the snapshot says so") {
        AXReplay.load(window()); defer { AXReplay.unload() }
        let pid = AXReplay.floor   // the window's own element
        var now: UInt64 = 1_000_000_000
        _ = AXHealth.query(pid: pid, clock: { defer { now += 1_500_000_000 }; return now }) { .cannotComplete }
        defer { AXHealth.forget(pid: pid) }
        let s = AXSnapshotCapture.capture(AXReplay.element(0))
        expect(s.stop, .appResting); expect(s.nodes.count, 1); expect(s.unfilledCount, 1)
        check(!s.isComplete, "an unanswered window is not a complete snapshot")
    }

    /// A window (0) with a button (1) and a table (2) of six rows (10...15), each a cell (20...25) holding a text
    /// (30...35), and one column (3) listing every cell again. Rows 11 and 12 are showing.
    func mailbox(visible: [Int]?) -> AXFixture {
        var f = AXFixture(app: "T", bundle: "t", recorded: "", root: 0, application: nil, focus: nil, nodes: [])
        func n(_ id: Int, _ role: String, _ parent: Int, _ children: [Int] = [], _ extra: [String: AXFixture.Value] = [:]) -> AXFixture.Node {
            var a: [String: AXFixture.Value] = ["AXRole": .string(role), "AXParent": .element(parent)]
            if !children.isEmpty { a["AXChildren"] = .elements(children) }
            for (k, v) in extra { a[k] = v }
            return .init(id: id, attrs: a)
        }
        var table: [String: AXFixture.Value] = ["AXRows": .elements(Array(10...15)), "AXDescription": .string("messages")]
        if let visible { table["AXVisibleRows"] = .elements(visible) }
        var nodes = [n(0, "AXWindow", 0, [1, 2]), n(1, "AXButton", 0, [], ["AXTitle": .string("Reply")]),
                     n(2, "AXTable", 0, Array(10...15) + [3], table), n(3, "AXColumn", 2, Array(20...25))]
        for i in 0...5 {
            nodes += [n(10 + i, "AXRow", 2, [20 + i]), n(20 + i, "AXCell", 10 + i, [30 + i]),
                      n(30 + i, "AXStaticText", 20 + i, [], ["AXValue": .string("Message \(i)")])]
        }
        f.nodes = nodes
        return f
    }

    test("snapshot: rows scrolled out of sight are left out when asked, and the column does not bring them back") {
        AXReplay.load(mailbox(visible: [11, 12])); defer { AXReplay.unload() }
        let s = AXSnapshotCapture.capture(AXReplay.element(0), onScreenRowsOnly: true)
        expect(s.nodes.compactMap { AXReplay.id(of: $0.element) }, [0, 1, 2, 11, 21, 31, 12, 22, 32, 3], "the two rows showing, and the column unopened")
        expect(s.rowsLeftOut, 4)
        let all = AXSnapshotCapture.capture(AXReplay.element(0))
        expect(all.nodes.count, 22, "every element once, without the option"); expect(all.rowsLeftOut, 0)
    }

    test("snapshot: a table that does not say which rows are showing, or shows them all, is taken whole") {
        AXReplay.load(mailbox(visible: nil))
        let silent = AXSnapshotCapture.capture(AXReplay.element(0), onScreenRowsOnly: true)
        AXReplay.unload()
        expect(silent.nodes.count, 22); expect(silent.rowsLeftOut, 0)
        AXReplay.load(mailbox(visible: Array(10...15))); defer { AXReplay.unload() }
        let whole = AXSnapshotCapture.capture(AXReplay.element(0), onScreenRowsOnly: true)
        expect(whole.nodes.count, 22); expect(whole.rowsLeftOut, 0)
    }
}
