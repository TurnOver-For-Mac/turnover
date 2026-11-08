// SPDX-License-Identifier: GPL-3.0-or-later
// Tests against recorded accessibility trees (Tests/Fixtures/*.json, made with turnover-coretest --record).
import Foundation
import ApplicationServices
import TurnOverCore
import AXFixtures

func fixtureTests() {
    test("navigation: flattened segments can be crossed in both directions without interacting") {
        let saved = config, sink = Speech.sink
        config.general.focusFollowsCursor = "off"
        Speech.sink = { _ in }
        var fixture = AXFixture(app: "TurnOver Settings", bundle: "com.turnover.settings", recorded: "", root: 0, application: nil, focus: 1, nodes: [])
        fixture.nodes = [
            .init(id: 0, attrs: ["AXRole": .string("AXWindow"), "AXChildren": .elements([1, 2, 5])]),
            .init(id: 1, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("Before"), "AXParent": .element(0), "AXWindow": .element(0)]),
            .init(id: 2, attrs: ["AXRole": .string("AXRadioGroup"), "AXTitle": .string("Show"), "AXChildren": .elements([3, 4]), "AXParent": .element(0), "AXWindow": .element(0)]),
            .init(id: 3, attrs: ["AXRole": .string("AXRadioButton"), "AXSubrole": .string("AXSegment"), "AXTitle": .string("Commands"), "AXParent": .element(2), "AXWindow": .element(0)]),
            .init(id: 4, attrs: ["AXRole": .string("AXRadioButton"), "AXSubrole": .string("AXSegment"), "AXTitle": .string("Changed keys"), "AXParent": .element(2), "AXWindow": .element(0)]),
            .init(id: 5, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("After"), "AXParent": .element(0), "AXWindow": .element(0)]),
        ]
        AXReplay.load(fixture)
        defer {
            AXReplay.unload(); ObjectNavigator.forgetGroupItems()
            config = saved; Speech.sink = sink
        }
        let navigator = ObjectNavigator.shared
        navigator.focusMoved(to: AXReplay.focus!, pid: AXReplay.focus!.pid)
        ObjectNavigator.forgetGroupItems()
        expect(ObjectNavigator.groupItems(AXReplay.root!).compactMap { AXReplay.id(of: $0) }, [1, 3, 4, 5])
        for id in [3, 4, 5] {
            navigator.groupStep(forward: true)
            expect(navigator.reviewElement.flatMap { AXReplay.id(of: $0) }, id)
        }
        for id in [4, 3, 1] {
            navigator.groupStep(forward: false)
            expect(navigator.reviewElement.flatMap { AXReplay.id(of: $0) }, id)
        }
        // Real radio groups still require interaction; only segmented controls are flattened.
        fixture.nodes[3].attrs["AXSubrole"] = nil
        fixture.nodes[4].attrs["AXSubrole"] = nil
        AXReplay.load(fixture); ObjectNavigator.forgetGroupItems()
        expect(ObjectNavigator.groupItems(AXReplay.root!).compactMap { AXReplay.id(of: $0) }, [1, 2, 5])
    }
    // System Settings' panes, macOS 27 (29 Oct 2026): 40 of a window's 169 elements, the focused button among them, give
    // no AXWindow, only a parent. Review took its bounds from AXWindow alone and said "nothing to review" at every step.
    test("navigation: an item that doesn't name its window is reviewed in the window its parents lead to") {
        let saved = config, sink = Speech.sink
        config.general.focusFollowsCursor = "off"
        Speech.sink = { _ in }
        var fixture = AXFixture(app: "System Settings", bundle: "com.apple.systempreferences", recorded: "", root: 0, application: nil, focus: 2, nodes: [])
        fixture.nodes = [
            .init(id: 0, attrs: ["AXRole": .string("AXWindow"), "AXChildren": .elements([1])]),
            .init(id: 1, attrs: ["AXRole": .string("AXGroup"), "AXParent": .element(0), "AXChildren": .elements([2, 3])]),
            .init(id: 2, attrs: ["AXRole": .string("AXButton"), "AXDescription": .string("Update Now"), "AXParent": .element(1)]),
            .init(id: 3, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("The Mac restarts to install the update."), "AXParent": .element(1)]),
        ]
        AXReplay.load(fixture)
        defer { AXReplay.unload(); config = saved; Speech.sink = sink }
        let navigator = ObjectNavigator.shared
        navigator.focusMoved(to: AXReplay.focus!, pid: AXReplay.focus!.pid)
        navigator.next()
        expect(navigator.reviewElement.flatMap { AXReplay.id(of: $0) }, 3, "on to the text after the button")
        navigator.previous()
        expect(navigator.reviewElement.flatMap { AXReplay.id(of: $0) }, 2, "and back to the button")
    }
    // System Settings' password sheet on macOS 27.2 (31 Oct 2026): the application's focused element is a password field
    // of another process (every replayed element has a pid of its own, the application's is 9's).
    // VO-J between a window's panes (8 Nov 2026, a second opinion's fixtures): the sidebar is the narrow pane with
    // something chosen; from it, the content's first readable item; from anywhere else, the chosen item. Where the
    // cursor is, is judged by position, so a row whose parent misleads (Music) still counts as the sidebar's.
    func paneWindow(split: Bool) -> AXFixture {
        var f = AXFixture(app: "T", bundle: "t", recorded: "", root: 0, application: nil, focus: 5, nodes: [])
        func n(_ id: Int, _ role: String, _ parent: Int, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ extra: [String: AXFixture.Value] = [:]) -> AXFixture.Node {
            var a: [String: AXFixture.Value] = ["AXRole": .string(role), "AXParent": .element(parent), "AXWindow": .element(0), "AXPosition": .point(x, y), "AXSize": .size(w, h)]
            for (k, v) in extra { a[k] = v }
            return .init(id: id, attrs: a)
        }
        var nodes: [AXFixture.Node] = [.init(id: 0, attrs: ["AXRole": .string("AXWindow"), "AXPosition": .point(0, 0), "AXSize": .size(1000, 600), "AXChildren": .elements([1])])]
        if split {
            // 1 split group: 2 sidebar scroll area (outline 3, rows 4 "Radio" and 5 "Search" selected), 11 search pane (field 12),
            // 6 splitter, 7 content group (scroll 8, group 9, button 10). Row 4's parent is the content group, as Music has it.
            nodes += [n(1, "AXSplitGroup", 0, 0, 0, 1000, 600, ["AXChildren": .elements([2, 11, 6, 7])]),
                      n(2, "AXScrollArea", 1, 0, 50, 200, 550, ["AXChildren": .elements([3])]),
                      n(3, "AXOutline", 2, 0, 50, 200, 550, ["AXDescription": .string("Sidebar"), "AXChildren": .elements([4, 5]), "AXRows": .elements([4, 5]), "AXSelectedRows": .elements([5])]),
                      n(4, "AXRow", 7, 0, 60, 200, 30, ["AXSubrole": .string("AXOutlineRow"), "AXDescription": .string("Radio")]),
                      n(5, "AXRow", 3, 0, 90, 200, 30, ["AXSubrole": .string("AXOutlineRow"), "AXDescription": .string("Search"), "AXSelected": .bool(true)]),
                      n(11, "AXGroup", 1, 5, 10, 190, 30, ["AXChildren": .elements([12])]),
                      n(12, "AXTextField", 11, 5, 10, 190, 30, ["AXSubrole": .string("AXSearchField")]),
                      n(6, "AXSplitter", 1, 200, 0, 1, 600),
                      n(7, "AXGroup", 1, 200, 0, 800, 600, ["AXChildren": .elements([8])]),
                      n(8, "AXScrollArea", 7, 200, 0, 800, 600, ["AXChildren": .elements([9])]),
                      n(9, "AXGroup", 8, 220, 20, 760, 560, ["AXChildren": .elements([10])]),
                      n(10, "AXButton", 9, 220, 20, 200, 40, ["AXDescription": .string("Radiohead Essentials, Playlist")])]
        } else {
            // No split group (Podcasts): 1 host, 13 layout with two big children: 2 the sidebar of texts (4 Shows, 5 Home selected),
            // 7 the content (group 9, heading 10) over the whole window; 14 a small split group inside the content, to be ignored.
            nodes += [n(1, "AXGroup", 0, 0, 0, 1000, 600, ["AXChildren": .elements([13])]),
                      n(13, "AXGroup", 1, 0, 0, 1000, 600, ["AXChildren": .elements([2, 7])]),
                      n(2, "AXGroup", 13, 0, 0, 220, 600, ["AXChildren": .elements([4, 5])]),
                      n(4, "AXStaticText", 2, 10, 60, 200, 30, ["AXDescription": .string("Shows")]),
                      n(5, "AXStaticText", 2, 10, 90, 200, 30, ["AXDescription": .string("Home"), "AXSelected": .bool(true)]),
                      n(7, "AXGroup", 13, 0, 0, 1000, 600, ["AXChildren": .elements([9])]),
                      n(9, "AXGroup", 7, 240, 20, 740, 560, ["AXDescription": .string("Home"), "AXChildren": .elements([10, 14])]),
                      n(10, "AXHeading", 9, 240, 20, 300, 30, ["AXDescription": .string("Home")]),
                      n(14, "AXSplitGroup", 9, 240, 300, 200, 100, ["AXChildren": .elements([15])]),
                      n(15, "AXGroup", 14, 240, 300, 200, 100)]
        }
        f.nodes = nodes
        return f
    }
    test("VO-J: a split view's sidebar and content, judged by position, with a search pane in the way") {
        AXReplay.load(paneWindow(split: true))
        let saved = config, keep = Speech.sink
        config.general.focusFollowsCursor = "off"
        Speech.sink = { _ in }
        defer { AXReplay.unload(); API.setFocusObject(nil, ancestors: []); config = saved; Speech.sink = keep }
        let nav = ObjectNavigator.shared
        @MainActor func jump(from id: Int) -> Int? { nav.place(AXReplay.element(id)); nav.jumpLinked(); return nav.reviewElement.flatMap { AXReplay.id(of: $0) } }
        expect(jump(from: 4), 10, "from a sidebar row whose parent misleads: the content's first readable item")
        expect(jump(from: 10), 5, "from the content: the sidebar's selected row")
        expect(jump(from: 12), 5, "from the search field, a pane of its own: the sidebar's selected row, not the content")
        expect(jump(from: 5), 10, "from the selected row: the content, not the search pane")
    }
    test("VO-J: a window with no split view: the sidebar is the narrow group with a selected item") {
        AXReplay.load(paneWindow(split: false))
        let saved = config, keep = Speech.sink
        config.general.focusFollowsCursor = "off"
        Speech.sink = { _ in }
        defer { AXReplay.unload(); API.setFocusObject(nil, ancestors: []); config = saved; Speech.sink = keep }
        let nav = ObjectNavigator.shared
        @MainActor func jump(from id: Int) -> Int? { nav.place(AXReplay.element(id)); nav.jumpLinked(); return nav.reviewElement.flatMap { AXReplay.id(of: $0) } }
        expect(jump(from: 4), 10, "from a sidebar text: the content's heading, the small split group inside ignored")
        expect(jump(from: 10), 5, "from the content: the selected sidebar text")
    }
    test("VO-J: the page round a landing is the outermost web area, however deep the landing is") {
        // 0 window, 1 group; 2 the page, with 21 a text at its top; 3 to 17 fifteen nested groups; under 17, 40 a text
        // and 18 a frame's page (19 its group, 20 its text); 30 a text outside any page.
        var f = AXFixture(app: "T", bundle: "t", recorded: "", root: 0, application: nil, focus: nil, nodes: [])
        func n(_ id: Int, _ role: String, _ parent: Int, _ children: [Int] = []) -> AXFixture.Node {
            .init(id: id, attrs: ["AXRole": .string(role), "AXParent": .element(parent), "AXWindow": .element(0), "AXChildren": .elements(children)])
        }
        var nodes: [AXFixture.Node] = [.init(id: 0, attrs: ["AXRole": .string("AXWindow"), "AXChildren": .elements([1])]),
                                       n(1, "AXGroup", 0, [2, 30]),
                                       n(2, "AXWebArea", 1, [3, 21])]
        for id in 3...16 { nodes.append(n(id, "AXGroup", id - 1, [id + 1])) }
        nodes += [n(17, "AXGroup", 16, [18, 40]), n(18, "AXWebArea", 17, [19]), n(19, "AXGroup", 18, [20]),
                  n(20, "AXStaticText", 19), n(40, "AXStaticText", 17), n(21, "AXStaticText", 2), n(30, "AXStaticText", 1)]
        f.nodes = nodes
        AXReplay.load(f)
        defer { AXReplay.unload() }
        @MainActor func page(of id: Int) -> Int? { AXReplay.id(of: ObjectNavigator.outermostWebArea(AXReplay.element(id))) }
        expect(page(of: 40), 2, "sixteen levels down: still in the page (twelve levels found nothing)")
        expect(page(of: 20), 2, "inside a frame: the page round it, not the frame")
        expect(page(of: 21), 2, "at the top of the page")
        expect(page(of: 30), nil, "outside any page")
    }
    test("VO-J: a landing where the keys type leaves TurnOver's focus with the keyboard") {
        // 0 window, 1 group: 2 a button (the keyboard's), 3 a text field, 8 a text field the keyboard is on, 4 a page
        // (the shim says every attribute can be set, so every replayed page is one being written in) with its group 5,
        // text 6 and text field 7.
        var f = AXFixture(app: "T", bundle: "t", recorded: "", root: 0, application: nil, focus: 2, nodes: [])
        func n(_ id: Int, _ role: String, _ parent: Int, _ extra: [String: AXFixture.Value] = [:]) -> AXFixture.Node {
            var a: [String: AXFixture.Value] = ["AXRole": .string(role), "AXParent": .element(parent), "AXWindow": .element(0),
                                                "AXPosition": .point(0, 0), "AXSize": .size(100, 30)]
            for (k, v) in extra { a[k] = v }
            return .init(id: id, attrs: a)
        }
        f.nodes = [.init(id: 0, attrs: ["AXRole": .string("AXWindow"), "AXChildren": .elements([1])]),
                   n(1, "AXGroup", 0, ["AXChildren": .elements([2, 3, 8, 4])]),
                   n(2, "AXButton", 1, ["AXDescription": .string("Send")]),
                   n(3, "AXTextField", 1, ["AXDescription": .string("Subject")]),
                   n(8, "AXTextField", 1, ["AXDescription": .string("To"), "AXFocused": .bool(true)]),
                   n(4, "AXWebArea", 1, ["AXChildren": .elements([5])]),
                   n(5, "AXGroup", 4, ["AXChildren": .elements([6, 7, 9])]),
                   n(6, "AXStaticText", 5, ["AXValue": .string("Hello")]),
                   n(7, "AXTextField", 5, ["AXDescription": .string("Name")]),
                   n(9, "AXTextField", 5, ["AXDescription": .string("Address"), "AXFocused": .bool(true)])]
        AXReplay.load(f)
        let saved = config, keep = Speech.sink
        config.general.focusFollowsCursor = "off"
        Speech.sink = { _ in }
        defer { AXReplay.unload(); API.setFocusObject(nil, ancestors: []); config = saved; Speech.sink = keep }
        let nav = ObjectNavigator.shared
        let button = ObjectFactory.make(AXReplay.element(2))
        @MainActor func jump(to id: Int) -> (cursor: Int?, focus: Int?) {
            API.setFocusObject(button, ancestors: [])
            nav.jumpTo(AXReplay.element(id))
            return (nav.reviewElement.flatMap { AXReplay.id(of: $0) }, API.focusObject.flatMap { AXReplay.id(of: $0.element) })
        }
        let field = jump(to: 3)
        expect(field.cursor, 3, "the cursor shows the text field")
        expect(field.focus, 2, "TurnOver's focus stays with the keyboard, on the button")
        let line = jump(to: 6)
        expect(line.cursor, 6, "the cursor shows the line in the page being written in")
        expect(line.focus, 2, "the reading stays with the keyboard")
        check(API.focusTreeInterceptor == nil, "no browse mode document for a page being written in")
        expect(AXReplay.sets.count, 0, "nothing asked of the app's keyboard focus")
        // A field the keyboard is on already, after a jump away left TurnOver's focus on the button: no focus event will
        // come to bring it back, so it is put there now (Codex, 8 Nov 2026).
        expect(jump(to: 8).focus, 8, "a field with the keyboard takes TurnOver's focus")
        expect(jump(to: 9).focus, 9, "so does one with the keyboard in a page being written in")
        // With the keyboard following the cursor, a field in the page gets the keyboard, and TurnOver's focus waits for
        // the app's own focus event (which a replay doesn't send).
        config.general.focusFollowsCursor = "on"
        expect(jump(to: 7).focus, 2, "TurnOver's focus isn't set directly in a page being written in")
        check(AXReplay.sets.contains { $0.id == 7 && $0.attribute == kAXFocusedAttribute }, "the keyboard was asked onto the field")
    }
    test("window spots: a walk cut short doesn't go round what it found") {
        expect(VoiceOverKeysPlugin.nextSpot(from: 2, count: 3, forward: true, complete: true), 0, "round, with the whole window seen")
        expect(VoiceOverKeysPlugin.nextSpot(from: 0, count: 3, forward: false, complete: true), 2, "round, backwards")
        expect(VoiceOverKeysPlugin.nextSpot(from: 1, count: 3, forward: true, complete: false), 2, "on through what was found")
        expect(VoiceOverKeysPlugin.nextSpot(from: 2, count: 3, forward: true, complete: false), nil, "not round part of a window")
        expect(VoiceOverKeysPlugin.nextSpot(from: 0, count: 3, forward: false, complete: false), nil, "nor back round it")
        expect(VoiceOverKeysPlugin.nextSpot(from: nil, count: 3, forward: true, complete: false), 0, "outside every spot: the first")
        expect(VoiceOverKeysPlugin.nextSpot(from: nil, count: 3, forward: false, complete: false), nil, "the last one isn't known")
        expect(VoiceOverKeysPlugin.nextSpot(from: 0, count: 1, forward: true, complete: true), 0, "one spot: itself again")
    }
    test("group items: a walk told to stop isn't kept for the steps after it") {
        AXReplay.load(paneWindow(split: true))
        ObjectNavigator.forgetGroupItems()
        defer { AXReplay.reads = nil; ObjectNavigator.forgetGroupItems(); AXReplay.unload() }
        let content = AXReplay.element(9)
        expect(ObjectNavigator.groupItems(content, stoppingWhen: { true }).count, 0, "stopped before the first child")
        var asked = 0
        let partial = ObjectNavigator.groupItems(content, stoppingWhen: { asked += 1; return asked > 1 })
        expect(partial.compactMap { AXReplay.id(of: $0) }, [10], "stopped after collecting: what was found, in the app's order")
        AXReplay.reads = []
        expect(ObjectNavigator.groupItems(content).compactMap { AXReplay.id(of: $0) }, [10], "the whole walk")
        check(!(AXReplay.reads ?? []).isEmpty, "walked afresh: neither stopped walk was kept")
    }
    test("VO-J: a narrow sidebar with something chosen spares the content its search") {
        AXReplay.load(paneWindow(split: true))
        let saved = config, keep = Speech.sink
        config.general.focusFollowsCursor = "off"
        Speech.sink = { _ in }
        defer { AXReplay.reads = nil; AXReplay.unload(); API.setFocusObject(nil, ancestors: []); config = saved; Speech.sink = keep }
        let nav = ObjectNavigator.shared
        nav.place(AXReplay.element(10))
        AXReplay.reads = []
        nav.jumpLinked()
        expect(nav.reviewElement.flatMap { AXReplay.id(of: $0) }, 5, "from the content: the sidebar's selected row, as before")
        let asked = Set((AXReplay.reads ?? []).filter { $0.attribute == kAXSelectedAttribute }.map(\.id))
        check(asked.isDisjoint(with: [7, 8, 9, 10]), "nothing in the wide content pane was asked whether it was selected: \(asked.sorted())")
    }
    test("VO-J: a press out of time stops its walks and still answers") {
        AXReplay.load(paneWindow(split: true))
        let saved = config, keep = Speech.sink, budget = ObjectNavigator.jumpBudgetSeconds
        config.general.focusFollowsCursor = "off"
        Speech.sink = { _ in }
        defer { ObjectNavigator.jumpBudgetSeconds = budget; AXReplay.reads = nil; AXReplay.unload(); API.setFocusObject(nil, ancestors: []); config = saved; Speech.sink = keep }
        let nav = ObjectNavigator.shared
        @MainActor func questions(from id: Int) -> Int {
            nav.place(AXReplay.element(id))
            AXReplay.reads = []
            nav.jumpLinked()
            return AXReplay.reads?.count ?? 0
        }
        let full = questions(from: 4)
        expect(nav.reviewElement.flatMap { AXReplay.id(of: $0) }, 10, "with time: the content's first readable item")
        ObjectNavigator.jumpBudgetSeconds = 0
        let cut = questions(from: 4)
        check(cut < full, "out of time, the press asks less: \(cut) questions against \(full)")
        check(nav.reviewElement.flatMap { AXReplay.id(of: $0) } != 4, "and still lands somewhere")
    }
    // System Settings' permission lists on macOS 27.2 (Screen & System Audio Recording, 8 Nov 2026): a row is a cell
    // holding the app's name as a text and a nameless AXCheckBox of subrole AXSwitch, so each row said only "Claude".
    test("row text: a nameless switch in a row says its role and state after the texts") {
        var fixture = AXFixture(app: "System Settings", bundle: "com.apple.systempreferences", recorded: "", root: 0, application: nil, focus: 1, nodes: [])
        fixture.nodes = [
            .init(id: 0, attrs: ["AXRole": .string("AXWindow"), "AXChildren": .elements([1])]),
            .init(id: 1, attrs: ["AXRole": .string("AXRow"), "AXSubrole": .string("AXOutlineRow"), "AXParent": .element(0), "AXChildren": .elements([2])]),
            .init(id: 2, attrs: ["AXRole": .string("AXCell"), "AXParent": .element(1), "AXChildren": .elements([3, 4])]),
            .init(id: 3, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("Claude"), "AXParent": .element(2)]),
            .init(id: 4, attrs: ["AXRole": .string("AXCheckBox"), "AXSubrole": .string("AXSwitch"), "AXValue": .number(1), "AXParent": .element(2)]),
        ]
        AXReplay.load(fixture); defer { AXReplay.unload() }
        expect(ObjectFactory.make(AXReplay.element(1)).name, "Claude, switch, on")
        fixture.nodes[4].attrs["AXValue"] = .number(0)
        AXReplay.load(fixture)
        expect(ObjectFactory.make(AXReplay.element(1)).name, "Claude, switch, off")
        fixture.nodes[4].attrs["AXSubrole"] = nil
        AXReplay.load(fixture)
        expect(ObjectFactory.make(AXReplay.element(1)).name, "Claude, check box, not checked", "a plain check box keeps its own words")
    }
    test("secure echo: a password field the application shows from another process is the one looked at") {
        var fixture = AXFixture(app: "System Settings", bundle: "com.apple.systempreferences", recorded: "", root: 0, application: 9, focus: 3, nodes: [])
        fixture.nodes = [
            .init(id: 0, attrs: ["AXRole": .string("AXWindow"), "AXChildren": .elements([1])]),
            .init(id: 1, attrs: ["AXRole": .string("AXSheet"), "AXParent": .element(0), "AXChildren": .elements([3])]),
            .init(id: 3, attrs: ["AXRole": .string("AXTextField"), "AXSubrole": .string("AXSecureTextField"), "AXParent": .element(1),
                                 "AXValue": .string("\u{2022}\u{2022}"), "AXSelectedTextRange": .range(2, 0)]),
            .init(id: 9, attrs: ["AXRole": .string("AXApplication"), "AXChildren": .elements([0]), "AXFocusedUIElement": .element(3)]),
        ]
        AXReplay.load(fixture); defer { AXReplay.unload() }
        expect(SecureEcho.otherProcessField(of: AXReplay.floor + 9).flatMap { AXReplay.id(of: $0) }, 3, "the sheet's password field")
        expect(SecureEcho.length(AXReplay.element(3)), 2, "its length counts what was typed")
        fixture.nodes[2].attrs["AXSubrole"] = nil
        AXReplay.load(fixture)
        check(SecureEcho.otherProcessField(of: AXReplay.floor + 9) == nil, "a plain text field there is not looked at")
    }

    test("replay: a recording answers like the application") {
        var f = AXFixture(app: "Test", bundle: "test", recorded: "", root: 0, application: nil, focus: 2, nodes: [])
        f.nodes = [
            .init(id: 0, attrs: ["AXRole": .string("AXWindow"), "AXTitle": .string("Untitled"), "AXChildren": .elements([1, 2]), "AXPosition": .point(10, 20)], params: [], actions: ["AXRaise"]),
            .init(id: 1, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("OK"), "AXParent": .element(0), "AXEnabled": .bool(true)], params: [], actions: ["AXPress"]),
            .init(id: 2, attrs: ["AXRole": .string("AXTextArea"), "AXValue": .string("one\ntwo"), "AXNumberOfCharacters": .number(7), "AXParent": .element(0)], params: [kAXStringForRangeParameterizedAttribute], actions: []),
        ]
        AXReplay.load(f)
        defer { AXReplay.unload() }
        let w = AXReplay.root!
        expect(w.role, "AXWindow")
        expect(w.string(kAXTitleAttribute), "Untitled")
        let children = w.elements(kAXChildrenAttribute)
        expect(children.count, 2)
        guard children.count == 2, let focus = AXReplay.focus else { return Harness.fail("the recording is not being replayed") }
        let b = children[0]
        expect(b.string(kAXTitleAttribute), "OK")
        check(CFEqual(b.element(kAXParentAttribute), w), "the parent is the window again")
        expect(b.attr(kAXEnabledAttribute) as? Bool, true)
        let t = focus
        expect(t.int(kAXNumberOfCharactersAttribute), 7)
        expect(t.param(kAXStringForRangeParameterizedAttribute, axRangeValue(4, 3)) as? String, "two")
        expect((t.param(kAXLineForIndexParameterizedAttribute, 5 as CFNumber) as? NSNumber)?.intValue, 1)
        expect(cfRange(t.param(kAXRangeForLineParameterizedAttribute, 0 as CFNumber))?.length, 4)
        expect(AXUIElementPerformAction(b, kAXPressAction as CFString), .success)
        expect(AXReplay.actions.map(\.action), ["AXPress"])
        expect(b.set(kAXFocusedAttribute, kCFBooleanTrue), .success)
        expect(b.attr(kAXFocusedAttribute) as? Bool, true, "a set value is read back")
        expect(w.string("AXNoSuchAttribute"), nil)
        let obj = ObjectFactory.make(b)
        expect(obj.role, .button)
        expect(obj.name, "OK")
    }

    test("an outline with no rows is empty, not its columns") {
        // Finder's list view of an empty folder: the outline's children are its four columns and the header group,
        // and no rows. It was "5 items, nothing selected", and Down arrow walked "column, 1 of 5" (21 Oct 2026).
        var f = AXFixture(app: "Finder", bundle: "com.apple.finder", recorded: "", root: 0, application: nil, focus: 1, nodes: [])
        var nodes: [AXFixture.Node] = [
            .init(id: 0, attrs: ["AXRole": .string("AXWindow"), "AXTitle": .string("Empty"), "AXChildren": .elements([1])], params: [], actions: []),
            .init(id: 1, attrs: ["AXRole": .string("AXOutline"), "AXDescription": .string("list view"), "AXParent": .element(0), "AXRows": .elements([]), "AXSelectedRows": .elements([]),
                                 "AXChildren": .elements([2, 3, 4, 5, 6])], params: [], actions: []),
            .init(id: 6, attrs: ["AXRole": .string("AXGroup"), "AXParent": .element(1)], params: [], actions: []),
        ]
        for (i, name) in ["Name", "Date Modified", "Size", "Kind"].enumerated() {
            nodes.append(.init(id: i + 2, attrs: ["AXRole": .string("AXColumn"), "AXDescription": .string(name), "AXParent": .element(1)], params: [], actions: []))
        }
        f.nodes = nodes
        AXReplay.load(f)
        defer { AXReplay.unload() }
        guard let focus = AXReplay.focus else { return Harness.fail("no focus in the fixture") }
        let list = ObjectFactory.make(focus)
        var said = ""
        let keep = Speech.sink
        Speech.sink = { said += $0 + " " }
        Speech.speakObject(list, reason: .focus)
        Speech.sink = keep
        check(said.contains("empty"), "an outline without rows is empty: \(said)")
        check(!said.contains("items"), "its columns are not counted as items: \(said)")
    }

    // Recorded windows: each test names what it expects of TurnOver's reading of that window.
    test("finder: a list view window reads as a tree view with the selected row and its position") {
        // Recorded on 21 Oct 2026: /Applications in list view, the first item selected. A contributor can record a
        // window of their own the same way (TESTING.md) and write what they expect TurnOver to say of it.
        let url = fixtureURL("finder-applications")
        guard FileManager.default.fileExists(atPath: url.path) else { print("     (no fixture, skipped)"); return }
        let f = try AXFixture.load(url)
        var said = ""
        let keep = Speech.sink
        Speech.sink = { said += $0 + " " }
        defer { Speech.sink = keep }
        AXReplay.load(f)
        defer { AXReplay.unload() }
        let w = ObjectFactory.make(AXReplay.root!)
        expect(w.role, .window)
        guard let focus = AXReplay.focus else { return Harness.fail("no focus recorded") }
        let list = ObjectFactory.make(focus)
        check([.treeView, .table, .list].contains(list.role), "the focus is the file list: \(list.role)")
        Speech.speakObject(list, reason: .focus)
        check(said.contains("list view"), "the view is named: \(said.prefix(120))")
        check(said.range(of: #"\b\d+ of \d+"#, options: .regularExpression) != nil, "the selected row and its position are read: \(said.prefix(120))")
        check(!said.contains("nothing selected"), "a selected row is not read as nothing selected")
    }

    test("textedit: a document window reads as a document") {
        let url = fixtureURL("textedit-guide")
        guard FileManager.default.fileExists(atPath: url.path) else { print("     (no fixture, skipped)"); return }
        let f = try AXFixture.load(url)
        AXReplay.load(f)
        defer { AXReplay.unload() }
        let w = ObjectFactory.make(AXReplay.root!)
        expect(w.role, .window)
        check(!w.name.isEmpty, "the window has a name")
        guard let focus = AXReplay.focus else { return Harness.fail("no focus recorded") }
        let doc = ObjectFactory.make(focus)
        expect(doc.role, .editableText)
        check(doc.hasNavigableText, "the document has text to move through")
        let parts = Speech.objectPropertiesSpeech(doc, reason: .focus)
        check(parts.contains("edit") || parts.contains("document") || parts.contains("text"), "says what it is: \(parts)")
    }

    // JAWS's lists of one kind (issue 125), on a made-up page: a heading, two links and a search field.
    test("JAWS keys: Caps Lock F7, F6 and F5 list a page's links, headings or form fields alone; F3 and F9 the whole list") {
        var f = AXFixture(app: "T", bundle: "t", recorded: "", root: 0, application: 9, focus: 0, nodes: [])
        f.nodes = [
            .init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.com/"), "AXParent": .element(9), "AXChildren": .elements([1, 7, 8, 6])]),
            .init(id: 1, attrs: ["AXRole": .string("AXHeading"), "AXTitle": .string("News"), "AXValue": .number(1), "AXParent": .element(0)]),
            .init(id: 7, attrs: ["AXRole": .string("AXGroup"), "AXParent": .element(0), "AXChildren": .elements([2])]),
            .init(id: 2, attrs: ["AXRole": .string("AXLink"), "AXParent": .element(7), "AXChildren": .elements([3])]),
            .init(id: 3, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("Home"), "AXParent": .element(2)]),
            .init(id: 8, attrs: ["AXRole": .string("AXGroup"), "AXParent": .element(0), "AXChildren": .elements([4])]),
            .init(id: 4, attrs: ["AXRole": .string("AXLink"), "AXParent": .element(8), "AXChildren": .elements([5])]),
            .init(id: 5, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("About"), "AXParent": .element(4)]),
            .init(id: 6, attrs: ["AXRole": .string("AXTextField"), "AXTitle": .string("Search"), "AXValue": .string(""), "AXParent": .element(0)]),
            .init(id: 9, attrs: ["AXRole": .string("AXApplication"), "AXTitle": .string("T"), "AXChildren": .elements([0])]),
        ]
        let saved = config, keep = Speech.sink
        var said = ""
        Speech.sink = { said += $0 + " " }
        AXReplay.load(f)
        defer { TurnOverMenu.shared.close(); AXReplay.unload(); API.setFocusObject(nil, ancestors: []); config = saved; Speech.sink = keep }
        config.general.keyboardStyle = "jaws"
        let page = BrowseModeHandler.shared.document(root: AXReplay.root!)
        API.setFocusObject(ObjectFactory.make(AXReplay.root!), ancestors: [], interceptor: page)
        /// The key's command, run as the key runs it; `said` from then on.
        @MainActor func press(_ id: String) -> String? {
            if TurnOverMenu.shared.isOpen { TurnOverMenu.shared.close() }
            guard let g = KeyboardGesture(identifier: id), let s = ScriptHandler.findScript(for: g) else { return nil }
            said = ""
            s.handler(g)
            return s.name
        }
        expect(press("kb:turnover+f7"), "jaws_linksList", "Caps Lock F7 is JAWS's links list")
        check(said.contains("Links, 2 items"), "the links alone: \(said)")
        said = ""
        let edges = Locked(0)
        Tones.onEdge = { edges.value += 1 }
        TurnOverMenu.shared.handle(KeyboardGesture(identifier: "kb:rightArrow")!)
        Tones.onEdge = nil
        check(TurnOverMenu.shared.isOpen && !said.contains("Headings") && edges.value == 1, "Right stays on the links, with the edge sound: \(said)")
        expect(press("kb:turnover+f6"), "jaws_headingsList", "Caps Lock F6 is JAWS's headings list")
        check(said.contains("Headings, 1 item,"), "the heading alone: \(said)")
        expect(press("kb:turnover+f5"), "jaws_formFieldsList", "Caps Lock F5 is JAWS's form fields list")
        check(said.contains("Form controls, 1 item,"), "the search field alone: \(said)")
        for key in ["kb:turnover+f3", "kb:turnover+f9"] {
            expect(press(key), "elementsList", "\(key) is still the whole elements list")
            check(said.contains("rotor"), "\(key): every kind, Left and Right between them: \(said)")
        }
        // In focus mode and off a page they do what NVDA+F7 does there: nothing on a page in focus mode, and an app's
        // own list where it has one (Word's document, Excel's module).
        page.passThrough = true
        expect(press("kb:turnover+f7"), "jaws_linksList")
        check(!TurnOverMenu.shared.isOpen, "in focus mode no list opens, as with NVDA+F7")
        page.passThrough = false
        let word = OwnF7(element: AXReplay.element(6))
        var ran = 0
        word.pressed = { ran += 1 }
        API.setFocusObject(word, ancestors: [])
        for key in ["kb:turnover+f5", "kb:turnover+f6", "kb:turnover+f7"] { _ = press(key) }
        expect(ran, 3, "off a page each runs the focus's own Caps Lock F7, as Word's elements list")
        config.general.keyboardStyle = "windows"
        API.setFocusObject(ObjectFactory.make(AXReplay.root!), ancestors: [], interceptor: page)
        expect(press("kb:turnover+f7"), "elementsList", "NVDA keys: Caps Lock F7 is still the whole elements list")
    }
}

/// An object with a Caps Lock F7 of its own, as Word's document has (its elements list).
final class OwnF7: TurnOverObject {
    var pressed: () -> Void = {}
    override func initOverlay() { script("test_ownF7", "", gestures: ["kb:turnover+f7"]) { [weak self] _ in self?.pressed() } }
}

// The focus rules (FocusChanges.swift) against made-up trees: what is ignored, what is followed.
func focusRuleTests() {
    /// A window (0) in an application (9) holding: a text field (1), a nameless group (2) with a page (3) inside,
    /// a page (4) with a blank frame (5) inside it, and a page with an address (6).
    func tree() -> AXFixture {
        var f = AXFixture(app: "T", bundle: "t", recorded: "", root: 0, application: 9, focus: 1, nodes: [])
        f.nodes = [
            .init(id: 0, attrs: ["AXRole": .string("AXWindow"), "AXSubrole": .string("AXStandardWindow"), "AXTitle": .string("Win"), "AXParent": .element(9),
                                 "AXChildren": .elements([1, 2, 4, 6]), "AXFocused": .bool(false)]),
            .init(id: 1, attrs: ["AXRole": .string("AXTextField"), "AXTitle": .string("Name"), "AXParent": .element(0), "AXWindow": .element(0), "AXValue": .string(""), "AXFocused": .bool(true)]),
            .init(id: 2, attrs: ["AXRole": .string("AXGroup"), "AXParent": .element(0), "AXWindow": .element(0), "AXChildren": .elements([3])]),
            .init(id: 3, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.com/a"), "AXParent": .element(2), "AXWindow": .element(0), "AXChildren": .elements([])]),
            .init(id: 4, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.com/b"), "AXParent": .element(0), "AXWindow": .element(0), "AXChildren": .elements([5])]),
            .init(id: 5, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("about:blank"), "AXParent": .element(4), "AXWindow": .element(0), "AXChildren": .elements([])]),
            .init(id: 6, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.com/c"), "AXParent": .element(0), "AXWindow": .element(0), "AXChildren": .elements([])]),
            .init(id: 9, attrs: ["AXRole": .string("AXApplication"), "AXTitle": .string("T"), "AXChildren": .elements([0]), "AXWindows": .elements([0]),
                                 "AXFocusedWindow": .element(0), "AXMainWindow": .element(0), "AXFocusedUIElement": .element(1)]),
        ]
        return f
    }
    func focusIs(_ id: Int) -> Bool { API.focusObject.map { AXReplay.id(of: $0.element) == id } ?? false }
    /// The replayed application (the tree above, or another) is the one in front.
    func playing(_ fixture: AXFixture? = nil, _ body: () -> Void) {
        AXReplay.load(fixture ?? tree()); AXHandler.shared.activePid = 900_009
        defer { AXReplay.unload(); AXHandler.shared.activePid = 0; API.setFocusObject(nil, ancestors: []) }
        API.setFocusObject(nil, ancestors: [])
        body()
    }

    test("focus rules: a field in the front window is the focus") {
        playing {
            AXHandler.shared.focusChanged(AXReplay.element(1), pid: 900_009)
            check(focusIs(1), "the field is the focus")
        }
    }
    test("focus rules: a blank frame inside a page is ignored") {
        playing {
            AXHandler.shared.focusChanged(AXReplay.element(6), pid: 900_009)
            check(focusIs(6), "the page is the focus first")
            AXHandler.shared.focusChanged(AXReplay.element(5), pid: 900_009)
            check(focusIs(6), "the blank frame did not take it")
        }
    }
    test("focus rules: a nameless group with a page inside is followed to the page") {
        playing {
            AXHandler.shared.focusChanged(AXReplay.element(1), pid: 900_009)
            AXHandler.shared.focusChanged(AXReplay.element(2), pid: 900_009)
            check(focusIs(3), "the page inside the group is the focus, not the group")
        }
    }
    // NVDA+Left and Right Arrow review by character in text (NVDA-PARITY.md, decision 3). JAWS has no such keys: its
    // characters are Caps Lock M, Comma and Period, and Insert+Left and Right Arrow are its words. In JAWS keys the two
    // stay the previous and next item in text too: in a text field they became the character review, and at the end of
    // the text said "bottom" at every press instead of going on (29 Oct 2026).
    test("JAWS keys: Caps Lock Left and Right Arrow are the previous and next item in a text field too") {
        playing {
            // Set, not reported: the rules would set aside a focus another test has just reported.
            API.setFocusObject(ObjectFactory.make(AXReplay.element(1)), ancestors: [])
            let style = config.general.keyboardStyle
            defer { config.general.keyboardStyle = style }
            @MainActor func command(_ key: String) -> String? { KeyboardGesture(identifier: key).flatMap { ScriptHandler.findScript(for: $0) }?.name }
            config.general.keyboardStyle = "windows"
            expect(command("kb:turnover+rightArrow"), "nvda_reviewNextCharacter", "NVDA keys: in text, NVDA's review by character")
            config.general.keyboardStyle = "jaws"
            expect(command("kb:turnover+rightArrow"), "reviewNext", "JAWS keys: the next item, in a text field as everywhere")
            expect(command("kb:turnover+leftArrow"), "reviewPrevious", "JAWS keys: the previous item, in a text field as everywhere")
        }
    }

    /// System Settings on macOS 27: the search field (22) has a stand-in (21) in the same place that answers nothing
    /// about its text (no value, no caret). SwiftUI reports the stand-in focused first and the field straight after,
    /// and the application gives the field as its focus. A switch (23) has a second reference (24); both answer. A
    /// long document (25) is an ordinary text area.
    /// Numbers of its own (the application stays 9, the pid the rules are given): the focus a test just before
    /// presented counts as reported twice for half a second, and the replay's element 1 is the same in every tree.
    func standIn() -> AXFixture {
        var f = AXFixture(app: "Settings", bundle: "s", recorded: "", root: 20, application: 9, focus: 22, nodes: [])
        func placed(_ attrs: [String: AXFixture.Value], _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [String: AXFixture.Value] {
            attrs.merging(["AXPosition": .point(x, y), "AXSize": .size(w, h), "AXParent": .element(20), "AXWindow": .element(20)]) { a, _ in a }
        }
        f.nodes = [
            .init(id: 20, attrs: ["AXRole": .string("AXWindow"), "AXSubrole": .string("AXStandardWindow"), "AXTitle": .string("About"), "AXParent": .element(9),
                                  "AXChildren": .elements([22, 23, 25]), "AXFocused": .bool(false)]),
            .init(id: 21, attrs: placed(["AXRole": .string("AXTextField"), "AXSubrole": .string("AXSearchField"), "AXFocused": .bool(true)], 10, 60, 232, 28)),
            .init(id: 22, attrs: placed(["AXRole": .string("AXTextField"), "AXSubrole": .string("AXSearchField"), "AXFocused": .bool(true), "AXValue": .string(""),
                                         "AXPlaceholderValue": .string("Search"), "AXSelectedTextRange": .range(0, 0), "AXNumberOfCharacters": .number(0)], 10, 60, 232, 28)),
            .init(id: 23, attrs: placed(["AXRole": .string("AXCheckBox"), "AXSubrole": .string("AXSwitch"), "AXTitle": .string("Wi-Fi"), "AXValue": .number(1)], 300, 120, 40, 22)),
            .init(id: 24, attrs: placed(["AXRole": .string("AXCheckBox"), "AXSubrole": .string("AXSwitch"), "AXTitle": .string("Wi-Fi"), "AXValue": .number(1)], 300, 120, 40, 22)),
            .init(id: 25, attrs: placed(["AXRole": .string("AXTextArea"), "AXFocused": .bool(true), "AXValue": .string(String(repeating: "A long document. ", count: 2000)),
                                         "AXSelectedTextRange": .range(0, 0), "AXNumberOfCharacters": .number(34_000)], 300, 200, 400, 300)),
            .init(id: 9, attrs: ["AXRole": .string("AXApplication"), "AXTitle": .string("Settings"), "AXChildren": .elements([20]), "AXWindows": .elements([20]),
                                  "AXFocusedWindow": .element(20), "AXMainWindow": .element(20), "AXFocusedUIElement": .element(22)]),
        ]
        return f
    }
    test("focus rules: a text field's stand-in gives way to the field the application has focused") {
        playing(standIn()) {
            AXHandler.shared.focusChanged(AXReplay.element(21), pid: 900_009)
            check(focusIs(22), "the field itself is the focus, not its stand-in")
            check((try? API.focusObject?.makeTextInfo(.caret)) != nil, "the focus gives its caret, so the review keys have text to move in")
            AXHandler.shared.focusChanged(AXReplay.element(22), pid: 900_009)
            check(focusIs(22), "the field, reported after its stand-in, is still the focus")
        }
    }
    test("focus rules: two references to a switch are one control, the first kept") {
        playing(standIn()) {
            AXHandler.shared.focusChanged(AXReplay.element(23), pid: 900_009)
            AXHandler.shared.focusChanged(AXReplay.element(24), pid: 900_009)
            check(focusIs(23), "the second reference to the switch is not a new focus")
        }
    }
    test("focus rules: a text area reported again is set aside without its whole text read") {
        playing(standIn()) {
            AXHandler.shared.focusChanged(AXReplay.element(25), pid: 900_009)
            check(focusIs(25), "the long document is the focus")
            AXReplay.reads = []
            defer { AXReplay.reads = nil }
            AXHandler.shared.focusChanged(AXReplay.element(25), pid: 900_009)
            let valueReads = (AXReplay.reads ?? []).filter { $0.id == 25 && $0.attribute == kAXValueAttribute }.count
            expect(valueReads, 0, "the same text area reported again: its value (34,000 characters) was not read")
            check(focusIs(25), "and it is still the focus")
        }
    }

    /// A Pages document: a window (0) in the application (9), its page layout (2) holding two pages (3, 5), each
    /// with its copy of the body text (4, 6). Both copies give the caret, or (a document just opened) neither does.
    func pages(caret: Bool) -> AXFixture {
        var f = AXFixture(app: "Pages", bundle: "com.apple.Pages", recorded: "", root: 0, application: 9, focus: 2, nodes: [])
        func body(_ id: Int, page: Int, shared: (Int, Int)) -> AXFixture.Node {
            var attrs: [String: AXFixture.Value] = ["AXRole": .string("AXTextArea"), "AXParent": .element(page), "AXWindow": .element(0), "AXFocused": .bool(true),
                                                    "AXNumberOfCharacters": .number(20), "AXSharedCharacterRange": .range(shared.0, shared.1)]
            if caret { attrs["AXSelectedTextRange"] = .range(5, 0) }
            return .init(id: id, attrs: attrs)
        }
        f.nodes = [
            .init(id: 0, attrs: ["AXRole": .string("AXWindow"), "AXParent": .element(9), "AXChildren": .elements([1])]),
            .init(id: 1, attrs: ["AXRole": .string("AXScrollArea"), "AXParent": .element(0), "AXWindow": .element(0), "AXChildren": .elements([2])]),
            .init(id: 2, attrs: ["AXRole": .string("AXLayoutArea"), "AXParent": .element(1), "AXWindow": .element(0), "AXFocused": .bool(true), "AXChildren": .elements([3, 5])]),
            .init(id: 3, attrs: ["AXRole": .string("AXPage"), "AXParent": .element(2), "AXWindow": .element(0), "AXChildren": .elements([4])]),
            body(4, page: 3, shared: (0, 12)),
            .init(id: 5, attrs: ["AXRole": .string("AXPage"), "AXParent": .element(2), "AXWindow": .element(0), "AXChildren": .elements([6])]),
            body(6, page: 5, shared: (12, 8)),
            .init(id: 9, attrs: ["AXRole": .string("AXApplication"), "AXChildren": .elements([0]), "AXWindows": .elements([0]),
                                 "AXFocusedWindow": .element(0), "AXFocusedUIElement": .element(2)]),
        ]
        return f
    }
    func pagesModule() -> AppModule? {
        BuiltInModules.register()
        return AppModuleHandler.shared.moduleType(for: "com.apple.Pages")?.init(pid: 900_009, bundleIdentifier: "com.apple.Pages", appName: "Pages")
    }
    func setsSaid() -> String { AXReplay.sets.map { "\($0.id) \($0.attribute)" }.joined(separator: ", ") }

    test("Pages: the layout with no caret in its body text gives the body text the focus") {
        AXReplay.load(pages(caret: false)); defer { AXReplay.unload() }
        guard let module = pagesModule() else { return Harness.fail("Pages' module is registered") }
        expect(module.redirectFocus(AXReplay.element(2)).flatMap { AXReplay.id(of: $0) }, 4, "the first page's body text is the focus")
        check(AXReplay.sets.contains { $0.id == 4 && $0.attribute == "AXFocused" && $0.value == .bool(true) },
              "the body text was given the focus, so Pages shows its caret (set: \(setsSaid()))")
    }
    test("Pages: the layout with the caret in its body text sets nothing in Pages") {
        AXReplay.load(pages(caret: true)); defer { AXReplay.unload() }
        guard let module = pagesModule() else { return Harness.fail("Pages' module is registered") }
        expect(module.redirectFocus(AXReplay.element(2)).flatMap { AXReplay.id(of: $0) }, 4, "the first page's body text is the focus")
        check(AXReplay.sets.isEmpty, "nothing set in Pages (set: \(setsSaid()))")
    }

    /// A conversation page (60) in a window (59) of the application (9), as the Claude app's: two lines of a reply (62,
    /// 64), its Copy button (65) and the prompt (66).
    func conversation() -> AXFixture {
        var f = AXFixture(app: "T", bundle: "t", recorded: "", root: 59, application: 9, focus: 65, nodes: [])
        f.nodes = [
            .init(id: 59, attrs: ["AXRole": .string("AXWindow"), "AXSubrole": .string("AXStandardWindow"), "AXTitle": .string("Chat"), "AXParent": .element(9),
                                  "AXChildren": .elements([60])]),
            .init(id: 60, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.com/chat"), "AXParent": .element(59), "AXWindow": .element(59),
                                  "AXChildren": .elements([61, 63, 65, 66])]),
            .init(id: 61, attrs: ["AXRole": .string("AXGroup"), "AXParent": .element(60), "AXWindow": .element(59), "AXChildren": .elements([62])]),
            .init(id: 62, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("The reply starts here."), "AXParent": .element(61), "AXWindow": .element(59)]),
            .init(id: 63, attrs: ["AXRole": .string("AXGroup"), "AXParent": .element(60), "AXWindow": .element(59), "AXChildren": .elements([64])]),
            .init(id: 64, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("The reading stopped on this line."), "AXParent": .element(63), "AXWindow": .element(59)]),
            .init(id: 65, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("Copy"), "AXParent": .element(60), "AXWindow": .element(59)]),
            .init(id: 66, attrs: ["AXRole": .string("AXTextArea"), "AXDescription": .string("Prompt"), "AXValue": .string(""), "AXParent": .element(60), "AXWindow": .element(59)]),
            .init(id: 9, attrs: ["AXRole": .string("AXApplication"), "AXTitle": .string("T"), "AXChildren": .elements([59]), "AXWindows": .elements([59]),
                                 "AXFocusedWindow": .element(59), "AXMainWindow": .element(59), "AXFocusedUIElement": .element(65)]),
        ]
        return f
    }

    // Command-Tab away and back: the Claude app and Safari give the focus back to the control that had it, and the
    // reading position went there too, into focus mode on the prompt (28 and 29 Oct 2026). NVDA leaves the reading
    // position and the mode as they were, and reads the line there.
    test("browse mode: back from another app onto the control that had the focus, the reading position and the mode stay") {
        AXReplay.load(conversation())
        let saved = config, keep = Speech.sink
        var said = ""
        Speech.sink = { said += $0 + " " }
        defer { AXReplay.unload(); API.setFocusObject(nil, ancestors: []); BrowseModeHandler.shared.forget(pid: 900_060); config = saved; Speech.sink = keep }
        config.virtualBuffers.autoFocusMode = true
        Speech.testResetFocusTiming()
        let page = BrowseModeHandler.shared.document(root: AXReplay.element(60))
        /// The focus on `id`, given to the page as AXHandler.present() and the event chain give it, from outside the page
        /// or from inside it. (Replayed, present() can't find the page from its focus: every replayed attribute is
        /// settable, so the web area reads as an editable one.) True when the page passes the event on to the control, as
        /// for a focus it follows.
        @MainActor func focus(_ id: Int, fromOutside: Bool) -> Bool {
            let f = ObjectFactory.make(AXReplay.element(id))
            API.setFocusObject(f, ancestors: f.ancestors, interceptor: page)
            page.focusFromOutside = fromOutside
            said = ""
            var passed = false
            page.handleEvent(Event(.gainFocus, f)) { passed = true }
            return passed
        }
        let stopped = page.buffer.text.range(of: "The reading stopped").location
        check(stopped != NSNotFound, "the reply is on the page")

        // Browse mode with the focus on Copy; the reading went on to the reply's second line; another app; back.
        check(focus(65, fromOutside: true), "the first focus on Copy is followed")
        page.position = stopped
        check(!focus(65, fromOutside: true), "back onto Copy, it is not read itself")
        expect(page.position, stopped, "the reading position stays where the reading stopped")
        check(said.contains("The reading stopped on this line"), "the line there is read: \(said)")

        // The prompt: focus mode as it takes the focus, Escape for browse mode, the reading went on, another app, back.
        check(focus(66, fromOutside: false), "into the prompt from inside the page, the focus is followed")
        check(page.passThrough && page.position != stopped, "focus mode on the prompt, the reading position on it")
        page.setPassThrough(false, announce: false)
        page.position = stopped
        check(!focus(66, fromOutside: true), "back onto the prompt, it is not read itself")
        check(!page.passThrough, "browse mode stays, though the prompt has the focus")
        expect(page.position, stopped, "the reading position stays where the reading stopped")

        // Back onto another control than the one that had the focus: followed, as NVDA does.
        check(focus(65, fromOutside: true), "back onto Copy while the prompt had the focus, it is followed")
        check(page.position != stopped, "the reading position went to Copy")

        // Typing in the prompt (focus mode), another app, back: typing still.
        check(focus(66, fromOutside: false) && page.passThrough, "into the prompt, focus mode")
        check(focus(66, fromOutside: true), "back into the prompt in focus mode, the focus is followed as before")
        check(page.passThrough, "focus mode stays")
    }
}

// Scale: a generated window with a 1,000-row list. Searches for a window's parts must not walk the rows, and
// every search must stay within a call budget (the Notes stall, 8 Oct 2026: SHAKE-OUT-PLAN.md).
func bigWindowFixture(rows: Int = 1000) -> AXFixture {
    var nodes: [AXFixture.Node] = []
    var rowIds: [Int] = []
    var next = 10
    for r in 0..<rows {
        let row = next, cell = next + 1, text = next + 2
        next += 3
        rowIds.append(row)
        nodes.append(.init(id: row, attrs: ["AXRole": .string("AXRow"), "AXParent": .element(2), "AXChildren": .elements([cell])]))
        nodes.append(.init(id: cell, attrs: ["AXRole": .string("AXCell"), "AXParent": .element(row), "AXChildren": .elements([text])]))
        nodes.append(.init(id: text, attrs: ["AXRole": .string("AXStaticText"), "AXParent": .element(cell), "AXValue": .string("Row \(r)")]))
    }
    let after = next   // a part after the big list, where a naive walk arrives last
    nodes.append(.init(id: after, attrs: ["AXRole": .string("AXTextArea"), "AXIdentifier": .string("Detail"), "AXParent": .element(0), "AXValue": .string("detail")]))
    nodes.append(.init(id: 0, attrs: ["AXRole": .string("AXWindow"), "AXSubrole": .string("AXStandardWindow"), "AXTitle": .string("Big"), "AXParent": .element(9), "AXChildren": .elements([1, 2, after])]))
    nodes.append(.init(id: 1, attrs: ["AXRole": .string("AXOutline"), "AXDescription": .string("Sidebar"), "AXParent": .element(0), "AXRows": .elements([]), "AXChildren": .elements([])]))
    nodes.append(.init(id: 2, attrs: ["AXRole": .string("AXTable"), "AXIdentifier": .string("BigList"), "AXParent": .element(0), "AXChildren": .elements(rowIds), "AXRows": .elements(rowIds)]))
    nodes.append(.init(id: 9, attrs: ["AXRole": .string("AXApplication"), "AXWindows": .elements([0]), "AXFocusedWindow": .element(0), "AXFocusedUIElement": .element(2)]))
    return AXFixture(app: "Big", bundle: "big", recorded: "", root: 0, application: 9, focus: 2, nodes: nodes)
}

func scaleTests() {
    test("scale: finding a window's parts never walks a 1,000-row list") {
        AXReplay.load(bigWindowFixture()); defer { AXReplay.unload() }
        let panes = RecipeView.Panes(parts: [
            .init(name: "Sidebar", match: { var m = ElementMatch(); m.roles = ["AXOutline"]; return m }()),
            .init(name: "List", match: { var m = ElementMatch(); m.identifier = "BigList"; return m }()),
            .init(name: "Detail", match: { var m = ElementMatch(); m.identifier = "Detail"; return m }()),
        ])
        let view = PanesView(pid: 900_009, panes: panes)
        let before = AXStats.calls
        expect(view.element(of: 2).flatMap(AXReplay.id(of:)) != nil, true, "the detail after the list is found")
        let calls = AXStats.calls - before
        check(calls < 60, "finding the part after a 1,000-row list took \(calls) accessibility calls; the rows were walked")
    }
    test("scale: a rule's search gives up within its budget on a huge window") {
        AXReplay.load(bigWindowFixture(rows: 3000)); defer { AXReplay.unload() }
        var m = ElementMatch(); m.identifier = "NothingHasThis"
        let t0 = Date()
        let found = ElementMatcher.find(m, pid: 900_009, limit: 1, budget: 0.2)
        let ms = Date().timeIntervalSince(t0) * 1000
        expect(found.count, 0)
        check(ms < 400, "the search ran \(Int(ms)) ms, past its 200 ms budget")
    }
}
