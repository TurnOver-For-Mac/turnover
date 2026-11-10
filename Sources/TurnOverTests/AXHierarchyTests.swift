// SPDX-License-Identifier: GPL-3.0-or-later
// The private whole-subtree read (AXHierarchyBridge), 10 Nov 2026: its answer unwrapped, its fall back to the batched
// read, a timed-out app spared it, and a bulk read never resting an app. The call itself cannot be replayed;
// `turnover-probe snapshot` measures it against live apps.
import Foundation
import ApplicationServices
import TurnOverAX
import AXFixtures

func axHierarchyTests() {
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

    test("snapshot: with the private read asked for, a recording still falls back to the batched read") {
        AXReplay.load(window()); defer { AXReplay.unload() }
        let s = AXSnapshotCapture.capture(AXReplay.element(0), useHierarchy: true)
        expect(s.nodes.count, 7)
        check(s.source == .batched, "nothing came from the private read")
        expect(s.questions, 8, "one private question at the root, then one an element")
    }

    test("snapshot: a hierarchy answer is unwrapped, and an unfilled element is marked") {
        let root = AXReplay.element(40), button = AXReplay.element(41), remote = AXReplay.element(42)
        func wrap(_ value: Any) -> NSDictionary { ["value": value] }
        // Built with Core Foundation's own key callbacks (retain, CFEqual, CFHash), as the real answer is: an
        // NSDictionary literal would try to copy its keys, and an AXUIElement cannot be copied.
        let raw = CFDictionaryCreateMutable(nil, 0, [kCFTypeDictionaryKeyCallBacks].withUnsafeBufferPointer { $0.baseAddress },
                                            [kCFTypeDictionaryValueCallBacks].withUnsafeBufferPointer { $0.baseAddress })!
        func put(_ key: AnyObject, _ value: AnyObject) {
            CFDictionarySetValue(raw, Unmanaged.passUnretained(key).toOpaque(), Unmanaged.passUnretained(value).toOpaque())
        }
        put(root, ["AXRole": wrap("AXWindow"), "AXChildren": ["value": [button, remote], "count": 2] as NSDictionary] as NSDictionary)
        put(button, ["AXRole": wrap("AXButton"), "AXTitle": wrap("OK"), "AXValue": wrap(1), "AXEnabled": wrap(true)] as NSDictionary)
        put(remote, ["incmplt": 1] as NSDictionary)
        put("stray" as NSString, "not an element" as NSString)
        let entries = AXHierarchyBridge.entries(from: raw)
        expect(entries.count, 3, "the stray key is skipped")
        check(entries[ElementKey(remote)]?.incomplete == true, "the remote element is marked incomplete")
        let s = AXSnapshotCapture.assemble(root: root, entries: entries)
        expect(s.nodes.map(\.role), ["AXWindow", "AXButton", ""])
        expect(s.nodes[1].title, "OK"); expect(s.nodes[1].value, .number(1)); expect(s.nodes[1].enabled, true)
        check(!s.nodes[2].isFilled, "the remote element is in the tree, unfilled")
        expect(s.questions, 0, "no question was asked of any app")
    }

    test("snapshot: an app whose private read timed out is spared it for a while") {
        let pid: pid_t = 987_655
        check(!AXHierarchyBridge.timedOutRecently(pid), "nothing noted yet")
        AXHierarchyBridge.noteTimeout(pid: pid); defer { AXHierarchyBridge.forget(pid: pid) }
        check(AXHierarchyBridge.timedOutRecently(pid), "noted")
        AXHierarchyBridge.forget(pid: pid)
        check(!AXHierarchyBridge.timedOutRecently(pid), "forgotten")
    }

    test("snapshot: a bulk read's duration and timeout never rest an app") {
        let pid: pid_t = 987_654
        AXHealth.forget(pid: pid); defer { AXHealth.forget(pid: pid) }
        var now: UInt64 = 1_000_000_000
        _ = AXHealth.query(pid: pid, policy: .bulkRead, clock: { defer { now += 1_500_000_000 }; return now }) { .cannotComplete }
        check(AXHealth.backoff(for: pid) == nil, "a timed-out bulk read is the question being too big, not the app hanging")
        now = 1_000_000_000
        _ = AXHealth.query(pid: pid, clock: { defer { now += 1_500_000_000 }; return now }) { .cannotComplete }
        check(AXHealth.backoff(for: pid) != nil, "an ordinary timed-out question still rests it")
        var asked = false
        _ = AXHealth.query(pid: pid, policy: .bulkRead) { asked = true; return .success }
        check(!asked, "a bulk read respects that rest")
    }
}
