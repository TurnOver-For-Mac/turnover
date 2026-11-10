// SPDX-License-Identifier: GPL-3.0-or-later
// The page buffer from a snapshot (10 Nov 2026): the same lines as by asking, far fewer questions, and the copies taken
// ahead in the background used only while they stand for the page.
import Foundation
import ApplicationServices
import TurnOverAX
import TurnOverCore
import AXFixtures

func pageBufferSnapshotTests() {
    /// A page (0, under application 1): a heading, a paragraph with a link, a button, a tick box, and a list of two.
    func page() -> AXFixture {
        var f = AXFixture(app: "T", bundle: "t", recorded: "", root: 0, application: 1, focus: 0, nodes: [])
        func n(_ id: Int, _ role: String, _ parent: Int, _ children: [Int] = [], _ extra: [String: AXFixture.Value] = [:]) -> AXFixture.Node {
            var a: [String: AXFixture.Value] = ["AXRole": .string(role), "AXParent": .element(parent)]
            if !children.isEmpty { a["AXChildren"] = .elements(children) }
            for (k, v) in extra { a[k] = v }
            return .init(id: id, attrs: a)
        }
        f.nodes = [n(0, "AXWebArea", 1, [10, 20, 30, 31, 40], ["AXURL": .url("https://example.com/sample")]),
                   .init(id: 1, attrs: ["AXRole": .string("AXApplication"), "AXTitle": .string("T"), "AXChildren": .elements([0])]),
                   n(10, "AXHeading", 0, [11], ["AXValue": .number(1)]), n(11, "AXStaticText", 10, [], ["AXValue": .string("Sample page")]),
                   n(20, "AXGroup", 0, [21, 22]), n(21, "AXStaticText", 20, [], ["AXValue": .string("Read the")]),
                   n(22, "AXLink", 20, [23], ["AXURL": .url("https://example.com/guide")]), n(23, "AXStaticText", 22, [], ["AXValue": .string("guide")]),
                   n(30, "AXButton", 0, [], ["AXTitle": .string("Save"), "AXEnabled": .bool(true)]),
                   n(31, "AXCheckBox", 0, [], ["AXTitle": .string("Remember me"), "AXValue": .number(1), "AXEnabled": .bool(true)]),
                   n(40, "AXList", 0, [41, 43]),
                   n(41, "AXGroup", 40, [42], ["AXSubrole": .string("AXListItem")]), n(42, "AXStaticText", 41, [], ["AXValue": .string("First")]),
                   n(43, "AXGroup", 40, [44], ["AXSubrole": .string("AXListItem")]), n(44, "AXStaticText", 43, [], ["AXValue": .string("Second")])]
        return f
    }

    test("page buffer: built from a snapshot it has the same lines, and asks the app far less") {
        AXReplay.load(page()); defer { AXReplay.unload(); WebBuffer.snapshotOverride = nil }
        @MainActor func built(snapshot: Bool) -> (text: String, lines: [String], controls: [String], asked: Int, buffer: WebBuffer) {
            WebBuffer.snapshotOverride = snapshot
            let buffer = WebBuffer(webArea: AXReplay.element(0))
            let counted = AXAttributeCache.counting { buffer.build() }
            let lines = buffer.lines.map { buffer.text.substring(with: NSRange(location: $0.start, length: $0.end - $0.start)) }
            let controls = buffer.lines.filter { $0.isControl }.map { $0.fields.joined(separator: "/") }
            return (buffer.text as String, lines, controls, counted.counts.values.reduce(0, +), buffer)
        }
        let old = built(snapshot: false), new = built(snapshot: true)
        check(old.lines.count >= 6, "the page was read (\(old.lines.count) lines)")
        expect(new.text, old.text, "the same text")
        expect(new.lines, old.lines, "the same lines")
        expect(new.controls, old.controls, "the same words for each control")
        expect(new.buffer.containers.count, old.buffer.containers.count, "the same containers")
        expect(new.buffer.segments.count, old.buffer.segments.count, "the same segments")
        check(new.buffer.lastSnapshotUse.answered > 30, "the snapshot answered the walk's questions (\(new.buffer.lastSnapshotUse.answered))")
        check(new.asked * 2 < old.asked, "the walk asked the app less than half as much (\(new.asked) against \(old.asked))")
        expect(old.buffer.lastSnapshotUse.answered, 0, "and nothing came from a snapshot with the switch off")
    }

    test("page buffer: what a snapshot does not hold is asked for, so a cut-short snapshot still gives the whole page") {
        AXReplay.load(page()); defer { AXReplay.unload() }
        let buffer = WebBuffer(webArea: AXReplay.element(0))
        WebBuffer.snapshotOverride = false
        buffer.build()
        let whole = buffer.text as String
        // The first four elements only: the rest of the page is outside the snapshot.
        let short = AXSnapshotCapture.capture(AXReplay.element(0), limits: AXSnapshotLimits(maxNodes: 4), names: WebBuffer.snapshotNames)
        expect(short.nodes.count, 4)
        let again = WebBuffer(webArea: AXReplay.element(0))
        let use = AXAttributeCache.with(short) { again.build() }.use
        WebBuffer.snapshotOverride = nil
        expect(again.text as String, whole, "the same page")
        check(use.hits > 0 && use.misses > 0, "some answers from the snapshot, the rest asked (\(use.hits), \(use.misses))")
    }

    test("page buffer: a snapshot taken ahead is used, unless the page was marked changed after it began") {
        AXReplay.load(page()); defer { AXReplay.unload(); WebBuffer.snapshotOverride = nil; WebBuffer.aheadOverride = false }
        WebBuffer.snapshotOverride = true; WebBuffer.aheadOverride = true
        let buffer = WebBuffer(webArea: AXReplay.element(0))
        buffer.build()
        check(!buffer.lastSnapshotWasAhead, "a page's first reading takes its snapshot there and then")
        let text = buffer.text as String
        buffer.isDirty = true
        buffer.takeSnapshotAheadNow()
        let asked = AXAttributeCache.counting { buffer.build() }.counts.values.reduce(0, +)
        check(buffer.lastSnapshotWasAhead, "the copy taken after the mark is used")
        expect(buffer.text as String, text, "and gives the same page")
        check(!buffer.isDirty, "the page is read")
        buffer.takeSnapshotAheadNow()
        buffer.isDirty = true          // marked changed again after that copy began: recent, not current
        buffer.build()
        check(buffer.lastSnapshotWasAhead, "a copy a moment old is still read from")
        check(buffer.isDirty, "and the page stays marked changed")
        expect(buffer.text as String, text)
        buffer.build()
        check(!buffer.lastSnapshotWasAhead, "a copy is used once")
        check(!buffer.isDirty, "a snapshot taken there and then leaves the page read")
        buffer.takeSnapshotAheadNow()
        buffer.buildAfresh()
        check(!buffer.lastSnapshotWasAhead, "a refresh asked for by key never uses a copy from before")
        check(asked < 40, "with the copy to hand, the build asked the app little (\(asked))")
    }

    test("page buffer: when a copy taken ahead stands for the page") {
        let t = Date()
        expect(WebBuffer.aheadUse(startedAt: t, dirtyAt: t.addingTimeInterval(-0.2), now: t.addingTimeInterval(5)), .current, "begun after the last mark")
        expect(WebBuffer.aheadUse(startedAt: t, dirtyAt: t.addingTimeInterval(0.05), now: t.addingTimeInterval(1)), .recent, "marked again, a second old")
        expect(WebBuffer.aheadUse(startedAt: t, dirtyAt: t.addingTimeInterval(0.05), now: t.addingTimeInterval(2)), WebBuffer.AheadUse.none, "marked again, two seconds old")
        expect(WebBuffer.aheadUse(startedAt: t, dirtyAt: t.addingTimeInterval(-0.2), now: t.addingTimeInterval(31)), WebBuffer.AheadUse.none, "too old to trust")
        expect(WebBuffer.aheadUse(startedAt: t, dirtyAt: t.addingTimeInterval(0.05), now: t.addingTimeInterval(1), mustBeCurrent: true), WebBuffer.AheadUse.none, "a refresh by key")
    }
}
