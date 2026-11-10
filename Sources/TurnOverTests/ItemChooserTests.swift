// SPDX-License-Identifier: GPL-3.0-or-later
// The Item Chooser and the window Rotor from a snapshot (10 Nov 2026): held to the walk used until build 24 on every
// recorded window, each item listed once, the rows on screen first and the rest filled in.
import Foundation
import ApplicationServices
import TurnOverAX
import TurnOverCore
import AXFixtures

func itemChooserTests() {
    /// One line an item, to compare two lists: which element, and what it is listed as.
    func lines(_ found: [ItemChooser.Found]) -> [String] {
        found.map { "\(AXReplay.id(of: $0.element) ?? -1) | \($0.label) | \($0.role) | \($0.subrole)" }
    }

    test("item chooser: the snapshot lists what the old walk listed, each item once, on every recorded window") {
        let folder = fixtureURL("x").deletingLastPathComponent()
        let recordings = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        check(recordings.count >= 10, "the recordings were found (\(recordings.count))")
        var total = 0
        for url in recordings {
            guard let fixture = try? AXFixture.load(url) else { Harness.fail("unreadable \(url.lastPathComponent)"); continue }
            AXReplay.load(fixture); defer { AXReplay.unload() }
            let root = AXReplay.element(fixture.root)
            let walked = lines(ItemChooser.oldWalkItems(in: root).items)
            // The one intended difference: a table lists each cell under its row and again under its column, and
            // the old walk went into both, so every cell's contents were listed twice (Excel's recording: 960 cells,
            // and its list filled to the 1,500 limit with repeats). The snapshot takes each element once, the first
            // time it is met. So the old list is compared with its repeats taken out; and where the old walk stopped
            // at its limit, the snapshot must begin with all of it and may go on.
            var met = Set<String>()
            let old = walked.filter { met.insert($0).inserted }
            let all = lines(ItemChooser.snapshotItems(in: root, onceByName: false).items)   // the rules as moved, before the repeated-name rule
            let new = walked.count >= 1500 ? Array(all.prefix(old.count)) : all
            total += old.count
            if old != new {
                let at = (0..<min(old.count, new.count)).first { old[$0] != new[$0] } ?? min(old.count, new.count)
                Harness.fail("\(url.lastPathComponent): \(old.count) items by the old walk, \(new.count) by the snapshot; first difference at \(at): old \(at < old.count ? old[at] : "(none)"), new \(at < new.count ? new[at] : "(none)")")
            }
        }
        check(total > 200, "the recordings hold items to compare (\(total))")
    }

    test("item chooser: the item rules hold on the snapshot as on the live window") {
        var f = AXFixture(app: "T", bundle: "t", recorded: "", root: 0, application: nil, focus: nil, nodes: [])
        func n(_ id: Int, _ role: String, _ children: [Int] = [], _ extra: [String: AXFixture.Value] = [:], actions: [String] = []) -> AXFixture.Node {
            var a: [String: AXFixture.Value] = ["AXRole": .string(role), "AXParent": .element(0)]
            if !children.isEmpty { a["AXChildren"] = .elements(children) }
            for (k, v) in extra { a[k] = v }
            return .init(id: id, attrs: a, actions: actions)
        }
        f.nodes = [n(0, "AXWindow", Array(1...12)),
                   n(1, "AXStaticText", [], ["AXValue": .string("   ")]),                                  // blank text: not an item
                   n(2, "AXStaticText", [], ["AXDescription": .string("Words in the description")]),      // Catalyst's texts
                   n(3, "AXImage"),                                                                         // a nameless picture
                   n(4, "AXImage", [], ["AXRoleDescription": .string("image")], actions: ["AXPress"]),     // pressable but nameless: an item, unlisted
                   n(5, "AXImage", [], ["AXDescription": .string("Logo"), "AXRoleDescription": .string("image")]),
                   n(6, "AXGroup", [], ["AXTitle": .string("Named empty group")]),                          // a control in disguise
                   n(7, "AXGroup", [13], ["AXTitle": .string("Named group with a child")]),                 // gone into, not listed
                   n(8, "AXRow", [14]),                                                                     // a spacer row: no words
                   n(9, "AXColumn"),                                                                        // structure
                   n(10, "AXButton", [], ["AXTitle": .string("Save"), "AXRoleDescription": .string("button")]),
                   n(11, "AXScrollBar", [], ["AXTitle": .string("Never listed")]),
                   n(12, "AXList"),                                                                         // a container is listed even unnamed
                   n(13, "AXCheckBox", [], ["AXTitle": .string("Inside"), "AXSubrole": .string("AXToggle")]),
                   n(14, "AXCell")]
        AXReplay.load(f); defer { AXReplay.unload() }
        let old = lines(ItemChooser.oldWalkItems(in: AXReplay.element(0)).items)
        let new = lines(ItemChooser.snapshotItems(in: AXReplay.element(0), onceByName: false).items)
        expect(new, old, "the two agree")
        expect(new, ["2 | Words in the description | AXStaticText | ", "5 | Logo, image | AXImage | ", "6 | Named empty group | AXGroup | ",
                     "13 | Inside | AXCheckBox | AXToggle", "10 | Save, button | AXButton | ", "12 |  | AXList | "], "and list what they should")
    }

    test("item chooser: a snapshot asks about an element's actions only where the answer turns on them") {
        var f = AXFixture(app: "T", bundle: "t", recorded: "", root: 0, application: nil, focus: nil, nodes: [])
        f.nodes = [.init(id: 0, attrs: ["AXRole": .string("AXWindow"), "AXChildren": .elements([1, 2, 3])]),
                   .init(id: 1, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("A")]),
                   .init(id: 2, attrs: ["AXRole": .string("AXImage"), "AXDescription": .string("Named")]),
                   .init(id: 3, attrs: ["AXRole": .string("AXImage")])]
        AXReplay.load(f); defer { AXReplay.unload() }
        let snapshot = AXSnapshotCapture.capture(AXReplay.element(0))
        nonisolated(unsafe) var asked: [Int] = []   // this test's own thread only: the closure runs inside chooserItems, synchronously
        let live = SnapshotItems.Live(profileNamed: { _ in false }, isSilenced: { _ in false },
                                      actions: { asked.append(AXReplay.id(of: $0) ?? -1); return [] })
        let items = SnapshotItems.chooserItems(snapshot, live: live)
        expect(items.map(\.label), ["A", "Named"])
        expect(asked, [3], "only the nameless picture needed its actions")
    }

    test("item chooser: a text that only repeats the item holding it is listed once") {
        var f = AXFixture(app: "Mail", bundle: "com.apple.mail", recorded: "", root: 0, application: nil, focus: nil, nodes: [])
        func n(_ id: Int, _ role: String, _ parent: Int, _ children: [Int] = [], _ extra: [String: AXFixture.Value] = [:]) -> AXFixture.Node {
            var a: [String: AXFixture.Value] = ["AXRole": .string(role), "AXParent": .element(parent)]
            if !children.isEmpty { a["AXChildren"] = .elements(children) }
            for (k, v) in extra { a[k] = v }
            return .init(id: id, attrs: a)
        }
        // An outline (1) of three rows. Row 2: a cell named Favourites holding a text Favourites. Row 5: a cell named
        // Important holding a text field Important. Row 8: a cell named Play holding a button Play and a text "3 new".
        f.nodes = [n(0, "AXWindow", 0, [1]), n(1, "AXOutline", 0, [2, 5, 8], ["AXDescription": .string("mailboxes")]),
                   n(2, "AXRow", 1, [3]), n(3, "AXCell", 2, [4], ["AXDescription": .string("Favourites")]),
                   n(4, "AXStaticText", 3, [], ["AXValue": .string("Favourites")]),
                   n(5, "AXRow", 1, [6]), n(6, "AXCell", 5, [7], ["AXDescription": .string("Important")]),
                   n(7, "AXTextField", 6, [], ["AXValue": .string("Important")]),
                   n(8, "AXRow", 1, [9]), n(9, "AXCell", 8, [10, 11], ["AXDescription": .string("Play")]),
                   n(10, "AXButton", 9, [], ["AXTitle": .string("Play")]),
                   n(11, "AXStaticText", 9, [], ["AXValue": .string("3 new")]),
                   n(12, "AXTextField", 0, [], ["AXValue": .string("Favourites")])]
        f.nodes[0].attrs["AXChildren"] = .elements([1, 12])
        AXReplay.load(f); defer { AXReplay.unload() }
        let before = lines(ItemChooser.snapshotItems(in: AXReplay.element(0), onceByName: false).items).map { String($0.prefix(2)).trimmingCharacters(in: .whitespaces) }
        expect(before, ["1", "3", "4", "6", "7", "9", "10", "11", "12"], "as the old walk listed it: every mailbox twice")
        let once = lines(ItemChooser.snapshotItems(in: AXReplay.element(0)).items)
        expect(once, ["1 | mailboxes | AXOutline | ", "3 | Favourites | AXCell | ", "6 | Important | AXCell | ", "9 | Play | AXCell | ",
                      "10 | Play | AXButton | ", "11 | 3 new | AXStaticText | ", "12 | Favourites | AXTextField | "],
               "each mailbox once; the button, the different text and the field outside any cell are kept")
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

    test("item chooser: the list of what is on screen, then everything, with the same items keeping their tags") {
        AXReplay.load(mailbox(visible: [11, 12])); defer { AXReplay.unload() }
        let first = ItemChooser.snapshotItems(in: AXReplay.element(0), onScreenRowsOnly: true)
        expect(first.rowsLeftOut, 4)
        let shown = ItemChooser.tagged(first.items, after: [])
        expect(shown.map(\.label), ["Reply", "messages", "Message 1", "Message 2"])
        expect(shown.compactMap(\.tag), [0, 1, 2, 3])
        let all = ItemChooser.tagged(ItemChooser.snapshotItems(in: AXReplay.element(0)).items, after: shown)
        expect(all.map(\.label), ["Reply", "messages", "Message 0", "Message 1", "Message 2", "Message 3", "Message 4", "Message 5"])
        expect(all.compactMap(\.tag), [0, 1, 4, 2, 3, 5, 6, 7], "Message 1 and 2 keep the tags they opened with")
    }

    test("chooser: a fuller list fills in quietly, keeping the cursor on its item and what was typed") {
        let menu = TurnOverMenu.shared
        let speechMode = Speech.mode; Speech.mode = .off; defer { Speech.mode = speechMode; if menu.isOpen { menu.close() } }
        @MainActor func items(_ titles: [(String, Int)]) -> [MenuItem] { titles.map { MenuItem(verbatim: $0.0, .action {}, tag: $0.1) } }
        let shown = items([("Reply", 0), ("messages", 1), ("Message 1", 2), ("Message 2", 3)])
        let all = items([("Reply", 0), ("messages", 1), ("Message 0", 4), ("Message 1", 2), ("Message 2", 3), ("Message 3", 5)])
        menu.openChooser(verbatim: "Items", items: shown)
        let generation = menu.listGeneration
        guard let down = KeyboardGesture(identifier: "kb:downArrow") else { return Harness.fail("no down arrow gesture") }
        menu.handle(down); menu.handle(down)
        expect(menu.debugPosition?.title, "Message 1"); expect(menu.debugPosition?.count, 4)
        menu.refillChooser(generation: generation, items: all)
        expect(menu.debugPosition?.title, "Message 1", "still on the same item"); expect(menu.debugPosition?.index, 3); expect(menu.debugPosition?.count, 6)
        menu.refillChooser(generation: generation - 1, items: shown)
        expect(menu.debugPosition?.count, 6, "a fill for another list is ignored")
        menu.close()
        menu.refillChooser(generation: generation, items: all)
        check(!menu.isOpen, "a fill after the list closed does nothing")
    }
}
