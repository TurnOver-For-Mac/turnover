// SPDX-License-Identifier: GPL-3.0-or-later
// Tests against recorded accessibility trees (Tests/Fixtures/*.json, made with turnover-coretest --record).
import Foundation
import ApplicationServices
import TurnOverCore
import AXFixtures

func fixtureTests() {
    func heldFolderFixture(rows: [Int] = [1, 2]) -> AXFixture {
        .init(app: "Public Notes sample", bundle: "com.apple.Notes", recorded: "synthetic", root: 0, application: nil, focus: nil, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXOutline"), "AXRows": .elements(rows), "AXChildren": .elements(rows), "AXSelectedRows": .elements([1])]),
            .init(id: 1, attrs: ["AXRole": .string("AXRow"), "AXTitle": .string("Sample folder"), "AXParent": .element(0)]),
            .init(id: 2, attrs: ["AXRole": .string("AXRow"), "AXTitle": .string("Second folder"), "AXParent": .element(0)])
        ])
    }
    test("Notes held folders: the app module enables choice feedback for its folder pane") {
        AXReplay.load(notesPaneFixture())
        let sink = Speech.sink
        var said: [String] = []
        Speech.sink = { said.append($0) }
        defer { ObjectNavigator.shared.releaseHold(); API.setFocusObject(nil, ancestors: []); Speech.sink = sink; AXReplay.unload() }
        API.setFocusObject(ObjectFactory.make(AXReplay.element(9)), ancestors: [])
        let type = AppModuleHandler.shared.moduleType(for: "com.apple.Notes")!
        let module = type.init(pid: 900_009, bundleIdentifier: "com.apple.Notes", appName: "Notes")
        module.script(named: "panes_part1")?.handler(KeyboardGesture(identifier: "kb:control+command+1")!)
        said.removeAll()
        ObjectNavigator.shared.heldChoose()
        expect(said, ["Sample folder, selected"], "real app wiring opts the Folders pane into spoken feedback")
    }
    test("Notes held folders: choosing a row selects it and announces the confirmed outcome") {
        AXReplay.load(heldFolderFixture())
        let navigator = ObjectNavigator.shared, sink = Speech.sink
        var said: [String] = []
        Speech.sink = { said.append($0) }
        defer { navigator.releaseHold(); Speech.sink = sink; AXReplay.unload() }
        navigator.enterHold(AXReplay.root!, name: "Folders", announceChoice: true)
        navigator.heldMove(1)
        said.removeAll()
        navigator.heldChoose()
        expect(AXReplay.root!.elements(kAXSelectedRowsAttribute).compactMap { AXReplay.id(of: $0) }, [2], "the chosen folder changes the provider selection")
        expect(said, ["Second folder, selected"], "Return and Space share heldChoose and must provide spoken confirmation")
    }
    test("Notes held folders: a row that disappeared explains why it cannot be chosen") {
        AXReplay.load(heldFolderFixture())
        let navigator = ObjectNavigator.shared, sink = Speech.sink
        var said: [String] = []
        Speech.sink = { said.append($0) }
        defer { navigator.releaseHold(); Speech.sink = sink; AXReplay.unload() }
        navigator.enterHold(AXReplay.root!, name: "Folders", announceChoice: true)
        AXReplay.load(heldFolderFixture(rows: [2]))
        said.removeAll()
        navigator.heldChoose()
        expect(said, ["cannot choose the folder: it is no longer available"], "a stale folder must not silently swallow activation or claim success")
        check(AXReplay.sets.isEmpty, "the vanished row is never selected")
    }
    test("Held lists: folder choice announcements are opt in and do not leak into another hold") {
        AXReplay.load(heldFolderFixture())
        let navigator = ObjectNavigator.shared, sink = Speech.sink
        var said: [String] = []
        Speech.sink = { said.append($0) }
        defer { navigator.releaseHold(); Speech.sink = sink; AXReplay.unload() }
        navigator.enterHold(AXReplay.root!, name: "Folders", announceChoice: true)
        navigator.releaseHold()
        navigator.enterHold(AXReplay.root!, name: "Other list")
        said.removeAll()
        navigator.heldChoose()
        check(said.isEmpty, "existing Finder and plugin holds keep their existing feedback")
    }
    test("Held lists: part Tab callback survives release and cannot leak into the next hold") {
        AXReplay.load(heldFolderFixture())
        let navigator = ObjectNavigator.shared, sink = Speech.sink, oldTab = ObjectNavigator.shared.heldTab
        Speech.sink = { _ in }
        var directions: [Bool] = [], fallbackCount = 0
        navigator.heldTab = { _ in fallbackCount += 1; return true }
        defer { navigator.releaseHold(); navigator.heldTab = oldTab; Speech.sink = sink; AXReplay.unload() }
        navigator.enterHold(AXReplay.root!, name: "Folders", onTab: { directions.append($0) })
        navigator.leaveHold(forward: false)
        expect(directions, [false], "the originating part handles Shift Tab after release")
        expect(fallbackCount, 0, "the existing Finder hook is not overwritten or invoked")
        navigator.enterHold(AXReplay.root!, name: "Other list")
        navigator.leaveHold(forward: true)
        expect(directions, [false], "the old part callback is retired")
        expect(fallbackCount, 1, "the existing global fallback still handles another list")
    }
    test("dialog: unnamed fields stay navigable without filling the opening or description") {
        let sink = Speech.sink
        var said: [String] = []
        Speech.sink = { said.append($0) }
        AXReplay.load(.init(app: "Public open panel", bundle: "test.dialog-summary", recorded: "synthetic", root: 0, application: nil, focus: 1, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXSheet"), "AXTitle": .string("Open"), "AXChildren": .elements([1, 2, 3, 4])]),
            .init(id: 1, attrs: ["AXRole": .string("AXTextField"), "AXParent": .element(0)]),
            .init(id: 2, attrs: ["AXRole": .string("AXTextField"), "AXDescription": .string(""), "AXParent": .element(0)]),
            .init(id: 3, attrs: ["AXRole": .string("AXTextField"), "AXSubrole": .string("AXSearchField"), "AXPlaceholderValue": .string("Search"), "AXParent": .element(0)]),
            .init(id: 4, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("Cancel"), "AXParent": .element(0)])
        ]))
        defer { Speech.sink = sink; AXReplay.unload() }
        let dialog = Dialog(element: AXReplay.element(0))
        expect(dialog.choices.count, 4, "unnamed fields are still reachable with dialog navigation")
        expect(dialog.description, "2 choices: Search, Cancel", "only actual names describe the choices")
        dialog.event_gainFocus()
        expect(said, ["Open, dialog"], "opening the panel does not enumerate fields")
        Speech.speakObject(ObjectFactory.make(AXReplay.element(3)), reason: .focus)
        check(said.last?.contains("Search") == true, "the focused field is still read separately")
    }
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
        expect(jump(from: 12), 5, "from the search field, a strip above the sidebar (not a pane since 9 Nov 2026): the sidebar's selected row, not the content")
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
    // Safari with its "Open in App Banner" (9 Nov 2026, Oliver: "I can't get into the page"): the banner, the whole width
    // and 54 points tall, is a child of the window's split view and lies over the top of the page. VO-J from the address
    // bar took it for a second pane, landed on its words, and put the keyboard on the page's "Hide sidebar" under it.
    /// `decoyFirst`: the page's first layer isn't marked empty and holds an empty wrapper (19), before the site's (Codex).
    func safariBannerWindow(decoyFirst: Bool = false) -> AXFixture {
        var f = AXFixture(app: "Safari", bundle: "com.apple.Safari", recorded: "", root: 0, application: nil, focus: 3, nodes: [])
        func n(_ id: Int, _ role: String, _ parent: Int, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ extra: [String: AXFixture.Value] = [:]) -> AXFixture.Node {
            var a: [String: AXFixture.Value] = ["AXRole": .string(role), "AXParent": .element(parent), "AXWindow": .element(0), "AXPosition": .point(x, y), "AXSize": .size(w, h)]
            for (k, v) in extra { a[k] = v }
            return .init(id: id, attrs: a)
        }
        // 0 window: 1 toolbar (3 the address field), 2 split view: 4 splitter, 5 tab group (7 group, 8 page), 6 the banner
        // (11 its words, 12 its Open button). The page holds three layers the size of the page: 13 with the site in it,
        // 14 an empty group, 15 an empty one. In 13: 16 the site's sidebar (9 "Hide sidebar" under the banner, 18 its
        // first words) and 17 its main part, the whole width behind the sidebar (10 a text).
        f.nodes = [.init(id: 0, attrs: ["AXRole": .string("AXWindow"), "AXPosition": .point(0, 0), "AXSize": .size(1024, 768), "AXChildren": .elements([1, 2])]),
                   n(1, "AXToolbar", 0, 0, 0, 1024, 52, ["AXChildren": .elements([3])]),
                   n(3, "AXTextField", 1, 300, 10, 400, 30, ["AXDescription": .string("smart search field"), "AXFocused": .bool(true)]),
                   n(2, "AXSplitGroup", 0, 0, 0, 1024, 768, ["AXChildren": .elements([4, 5, 6])]),
                   n(4, "AXSplitter", 2, -1, 52, 0, 716),
                   n(5, "AXTabGroup", 2, 0, 0, 1024, 768, ["AXChildren": .elements([7])]),
                   n(7, "AXGroup", 5, 0, 52, 1024, 716, ["AXChildren": .elements([8])]),
                   n(8, "AXWebArea", 7, 0, 52, 1024, 716, ["AXChildren": .elements(decoyFirst ? [14, 13, 15] : [13, 14, 15])]),
                   n(13, "AXGroup", 8, 0, 52, 1024, 716, ["AXChildren": .elements([16, 17])]),
                   decoyFirst ? n(14, "AXGroup", 8, 0, 52, 1024, 716, ["AXChildren": .elements([19])])
                              : n(14, "AXGroup", 8, 0, 52, 1024, 716, ["AXSubrole": .string("AXEmptyGroup")]),
                   n(19, "AXGroup", 14, 0, 52, 1024, 716),
                   n(15, "AXGroup", 8, 0, 52, 1024, 716),
                   n(16, "AXGroup", 13, 0, 52, 288, 716, ["AXChildren": .elements([9, 18])]),
                   n(9, "AXButton", 16, 10, 60, 40, 30, ["AXDescription": .string("Hide sidebar")]),
                   n(18, "AXStaticText", 16, 10, 120, 200, 20, ["AXValue": .string("Recents")]),
                   n(17, "AXGroup", 13, 0, 52, 1024, 716, ["AXSubrole": .string("AXLandmarkMain"), "AXChildren": .elements([10])]),
                   n(10, "AXStaticText", 17, 300, 200, 300, 20, ["AXValue": .string("Northampton as a place to live")]),
                   n(6, "AXGroup", 2, 0, 52, 1024, 54, ["AXDescription": .string("Open in App Banner"), "AXChildren": .elements([11, 12])]),
                   n(11, "AXStaticText", 6, 60, 60, 200, 20, ["AXValue": .string("Tally")]),
                   n(12, "AXButton", 6, 900, 62, 80, 30, ["AXDescription": .string("Open")])]
        return f
    }
    test("VO-J: in Safari the banner isn't a pane, and the page's layers are gone through to the site's own parts") {
        AXReplay.load(safariBannerWindow())
        let saved = config, keep = Speech.sink
        config.general.focusFollowsCursor = "on"
        var said: [String] = []
        Speech.sink = { said.append($0) }
        defer { AXReplay.unload(); API.setFocusObject(nil, ancestors: []); config = saved; Speech.sink = keep }
        let window = CGRect(x: 0, y: 0, width: 1024, height: 768)
        check(ObjectNavigator.isStrip(AXReplay.element(6), in: window), "the banner, 54 points of 768, is a strip")
        check(ObjectNavigator.isStrip(AXReplay.element(4), in: window), "so is the splitter, no width at all")
        check(!ObjectNavigator.isStrip(AXReplay.element(5), in: window), "the tab group is a pane")
        let page = CGRect(x: 0, y: 52, width: 1024, height: 716)
        check(ObjectNavigator.areLayers([page, page, page]), "three groups the size of the page lie one over another")
        check(!ObjectNavigator.areLayers([CGRect(x: 0, y: 52, width: 288, height: 716), page]),
              "a sidebar in front of a main part as wide as the window is beside it (Podcasts')")
        let nav = ObjectNavigator.shared
        nav.place(AXReplay.element(3))
        nav.jumpLinked()
        expect(nav.reviewElement.flatMap { AXReplay.id(of: $0) }, 18, "from the address bar: into the page, the site's sidebar, not the banner")
        check(!said.contains { $0.contains("no linked item") }, "and not \"no linked item\": \(said)")
        expect(AXReplay.sets.filter { $0.attribute == kAXFocusedAttribute }.count, 0, "the keyboard wasn't moved: in a page only the reading goes")
        nav.jumpLinked()
        expect(nav.reviewElement.flatMap { AXReplay.id(of: $0) }, 10, "then on to the site's main part")
        // A first layer that leads nowhere (only an empty wrapper) gives way to the site's.
        AXReplay.load(safariBannerWindow(decoyFirst: true))
        nav.place(AXReplay.element(3))
        nav.jumpLinked()
        expect(nav.reviewElement.flatMap { AXReplay.id(of: $0) }, 18, "past a first layer holding only an empty wrapper, into the site's sidebar")
    }
    test("VO-J: Finder's file list, in a split view of its own inside the sidebar's, goes to the sidebar") {
        // Recorded on 21 Oct 2026: /Applications in list view. Split view 1 holds the sidebar (7, outline 18, row 27
        // selected) and split view 9, which holds the file list (19, outline 36, the focus) and the path bar (20, 28
        // points tall). Codex, 9 Nov 2026: with the path bar left out, split view 9 has one pane, and VO-J said "no
        // linked item" instead of looking round it.
        let url = fixtureURL("finder-applications")
        guard FileManager.default.fileExists(atPath: url.path) else { print("     (no fixture, skipped)"); return }
        AXReplay.load(try AXFixture.load(url))
        let saved = config, keep = Speech.sink
        config.general.focusFollowsCursor = "off"
        Speech.sink = { _ in }
        defer { AXReplay.unload(); API.setFocusObject(nil, ancestors: []); config = saved; Speech.sink = keep }
        let nav = ObjectNavigator.shared
        nav.place(AXReplay.element(36))
        nav.jumpLinked()
        expect(nav.reviewElement.flatMap { AXReplay.id(of: $0) }, 27, "from the file list: the sidebar's selected row")
    }
    test("VO-J: the keyboard is put near a landing within the part landed in, not on what lies under it") {
        AXReplay.load(safariBannerWindow())
        let saved = config, keep = Speech.sink
        config.general.focusFollowsCursor = "on"
        Speech.sink = { _ in }
        defer { AXReplay.unload(); API.setFocusObject(nil, ancestors: []); config = saved; Speech.sink = keep }
        check(!ObjectNavigator.isWithin(AXReplay.element(2), AXReplay.element(6), from: AXReplay.element(11)), "the split view is above the banner")
        check(ObjectNavigator.isWithin(AXReplay.element(6), AXReplay.element(6), from: AXReplay.element(11)), "the banner is itself")
        ObjectNavigator.shared.jumpTo(AXReplay.element(11), within: AXReplay.element(6))
        let focused = AXReplay.sets.filter { $0.attribute == kAXFocusedAttribute }.map(\.id)
        check(focused.contains(12), "the keyboard went to the banner's own button: \(focused)")
        check(focused.allSatisfy { ![5, 6, 7, 8, 9].contains($0) }, "nothing round or under the banner took it: \(focused)")
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
        waitForBuffer(page.buffer)
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
        waitForBuffer(page.buffer)
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

    // 14 Nov 2026: these assertions observe output after Speech.enqueue's real gates, not Speech.sink.
    func withModeWords(role: String = "AXTextArea", buttonTitle: String = "Copy", value: String = "", trailing: Bool = false, detachedApp: Bool = false, automatic: Bool = true, _ body: (ModeWordsTrial, BrowseModeDocument) -> Void) {
        var fixture = conversation()
        let button = fixture.nodes.firstIndex { $0.id == 65 }!
        fixture.nodes[button].attrs["AXTitle"] = .string(buttonTitle)
        let field = fixture.nodes.firstIndex { $0.id == 66 }!
        fixture.nodes[field].attrs["AXRole"] = .string(role)
        fixture.nodes[field].attrs["AXValue"] = .string(value)
        if trailing {
            let root = fixture.nodes.firstIndex { $0.id == 60 }!
            fixture.nodes[root].attrs["AXChildren"] = .elements([61, 63, 65, 66, 67])
            fixture.nodes.append(.init(id: 67, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("After the field"), "AXParent": .element(60), "AXWindow": .element(59)]))
        }
        if detachedApp {
            let window = fixture.nodes.firstIndex { $0.id == 59 }!
            fixture.nodes[window].attrs.removeValue(forKey: "AXParent")
            // Each replay node has its own fake pid. Seed that fake application focus directly;
            // AXReplay.set deliberately does not persist scalar AXUIElement writes.
            fixture.nodes[field].attrs[kAXFocusedUIElementAttribute] = .element(66)
            let root = fixture.nodes.firstIndex { $0.id == 60 }!
            fixture.nodes[root].attrs["AXReplayReadOnlyAttributes"] = .strings([kAXValueAttribute])
        }
        AXReplay.load(fixture)
        let activePidBefore = AXHandler.shared.activePid
        AXHandler.shared.activePid = 900_060
        let trial = ModeWordsTrial()
        let page = BrowseModeHandler.shared.document(root: AXReplay.element(60))
        defer {
            API.setFocusObject(nil, ancestors: [])
            BrowseModeHandler.shared.forget(pid: 900_060)
            AXHandler.shared.activePid = activePidBefore
            AXReplay.unload()
            trial.restore()
        }
        API.setFocusObject(ObjectFactory.make(AXReplay.element(65)), ancestors: [], interceptor: page)
        page.refreshIfNavigated()
        waitForBuffer(page.buffer)
        page.hasWebKitSearch = false
        trial.queued = []
        trial.events = []
        trial.sound = []
        body(trial, page)
        if automatic {
            check(!trial.words.contains("focus mode") && !trial.words.contains("browse mode"), "automatic cues never speak mode words")
        }
    }
    func modeFocus(_ id: Int, page: BrowseModeDocument) {
        let field = ObjectFactory.make(AXReplay.element(id))
        API.setFocusObject(field, ancestors: [], interceptor: page)
        EventHandler.execute(.gainFocus, on: field)
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }

    test("caret focus: old configuration defaults on and explicit off round trips") {
        check(Config.VirtualBuffers().autoPassThroughOnCaretMove, "new configuration defaults on")
        do {
            let old = try JSONDecoder().decode(Config.VirtualBuffers.self, from: Data("{}".utf8))
            check(old.autoPassThroughOnCaretMove, "older saved settings enable caret focus")
            var changed = old
            changed.autoPassThroughOnCaretMove = false
            let decoded = try JSONDecoder().decode(Config.VirtualBuffers.self, from: JSONEncoder().encode(changed))
            check(!decoded.autoPassThroughOnCaretMove, "explicit off is preserved")
        } catch { Harness.fail("caret setting Codable: \(error)") }
    }

    test("caret focus: saved-copy arrows and quick navigation make no provider calls") {
        withModeWords { trial, page in
            config.virtualBuffers = Config.VirtualBuffers()
            let schedules = AXHealth.schedulesChecks
            let unresponsive = AXHealth.onUnresponsive
            AXHealth.schedulesChecks = false
            AXHealth.onUnresponsive = nil
            defer {
                AXReplay.reads = nil
                AXHealth.forget(pid: page.webArea.pid)
                AXHealth.schedulesChecks = schedules
                AXHealth.onUnresponsive = unresponsive
            }
            var ticks: [UInt64] = [100, 2_000_000_100]
            _ = AXHealth.query(pid: page.webArea.pid, element: page.webArea,
                               clock: { ticks.removeFirst() }) { .cannotComplete }
            check(page.pageSilent, "the page has entered timeout backoff")
            page.position = 0
            let arrow = KeyboardGesture(identifier: "kb:downArrow")!
            guard let command = page.script(for: arrow) else { Harness.fail("saved-copy arrow"); return }
            AXReplay.reads = [] // The shim counts raw calls too, which AXStats cannot see.
            ScriptHandler.executeScript(command, gesture: arrow)
            check(trial.events.joined().contains("The reading stopped on this line"), "text inside a group is read from the copy")
            let quick = KeyboardGesture(identifier: "kb:f")!
            guard let find = page.script(for: quick) else { Harness.fail("saved-copy field command"); return }
            ScriptHandler.executeScript(find, gesture: quick)
            check(trial.events.joined().contains("Prompt"), "quick navigation reads the saved field")
            expect(AXReplay.reads?.count, 0, "no raw count query or other provider read escapes the snapshot")
            check(!AXReplay.sets.contains { $0.attribute == kAXFocusedAttribute }, "a saved field never requests native focus")
            check(!page.passThrough, "reading the copy stays in browse mode")
        }
    }

    test("caret focus: manual browse override prevents a real arrow requesting focus") {
        for manual in [false, true] {
            withModeWords { trial, page in
                config.virtualBuffers.autoPassThroughOnCaretMove = true
                page.disableAutoPassThrough = manual
                page.position = page.buffer.offset(of: AXReplay.element(65)) ?? 0
                guard let command = page.script(for: KeyboardGesture(identifier: "kb:downArrow")!) else { Harness.fail("arrow command"); return }
                ScriptHandler.executeScript(command, gesture: KeyboardGesture(identifier: "kb:downArrow")!)
                check(trial.events.joined().contains("Prompt"), "real arrow reports the field")
                expect(AXReplay.sets.contains { $0.id == 66 && $0.attribute == kAXFocusedAttribute }, !manual, "only automatic browse mode requests keyboard focus")
                check(!page.passThrough, "browse mode remains until native focus confirms entry")
            }
        }
    }

    test("caret focus: silent native focus confirms once and VO Right leaves multiline text") {
        withModeWords(value: "First line\nSecond line", trailing: true, detachedApp: true) { trial, page in
            config.virtualBuffers.autoPassThroughOnCaretMove = true
            config.virtualBuffers.autoFocusMode = false
            page.position = page.buffer.offset(of: AXReplay.element(65)) ?? 0
            ObjectNavigator.shared.toFocus()
            trial.queued = []
            trial.events = []
            trial.sound = []
            // The fixture seeded native provider focus without sending a reader focus event.
            check(AXReplay.element(66).element(kAXFocusedUIElementAttribute)?.isSame(AXReplay.element(66)) == true, "silent native focus fixture is readable before the command")
            check(!EditableWebArea.isEditable(AXReplay.element(60)), "native focus adoption sees a browse page")
            let plugin = VoiceOverKeysPlugin()
            guard let find = plugin.script(named: "vo_nextFormField"), let next = plugin.script(named: "vo_next") else { Harness.fail("VO commands"); return }
            ScriptHandler.executeScript(find, gesture: KeyboardGesture(identifier: "kb:turnover+command+j")!)
            trial.advance(0.1)
            check(page.passThrough, "confirmed native focus enables typing without an event")
            check(API.focusObject?.isSameElement(as: AXReplay.element(66)) == true, "normal focus adoption updates the actual reader owner")
            expect(trial.events.filter { $0 == "focus sound" }.count, 1)
            check(trial.events.dropLast().joined().contains("Prompt"), "field words precede focus mode")
            let beforeEvent = trial.events
            AXHandler.shared.focusChanged(AXReplay.element(66), pid: 900_060)
            trial.advance(0.1)
            expect(trial.events, beforeEvent, "delayed matching native event repeats neither field nor mode")
            ScriptHandler.executeScript(next, gesture: KeyboardGesture(identifier: "kb:turnover+rightArrow")!)
            trial.advance(0.1)
            check(!page.passThrough, "VO Right leaves multiline edit in browse mode")
            check(trial.events.joined().contains("After the field"), "VO Right crosses the whole field")
        }
    }

    test("caret focus: arrival on the reader's already-focused field queues mode after its words") {
        withModeWords { trial, page in
            config.virtualBuffers.autoPassThroughOnCaretMove = true
            config.virtualBuffers.autoFocusMode = false
            API.setFocusObject(ObjectFactory.make(AXReplay.element(66)), ancestors: [], interceptor: page)
            page.position = page.buffer.offset(of: AXReplay.element(65)) ?? 0
            let plugin = VoiceOverKeysPlugin()
            guard let command = plugin.script(named: "vo_nextFormField") else { Harness.fail("VO form command"); return }
            ScriptHandler.executeScript(command, gesture: KeyboardGesture(identifier: "kb:turnover+command+j")!)
            trial.advance(0.1)
            check(page.passThrough, "already-focused field is ready for typing")
            expect(trial.events.filter { $0 == "focus sound" }.count, 1)
            expect(trial.events.last, "focus sound")
            check(trial.events.dropLast().joined().contains("Prompt"), "field words precede mode")
            check(!AXReplay.sets.contains { $0.id == 66 && $0.attribute == kAXFocusedAttribute }, "already-adopted focus needs no extra native request")
        }
    }

    test("caret focus: default settings reject delayed entry after VO Right or another command") {
        for vo in [false, true] {
            for delay in [0.0, 0.55] {
                withModeWords(trailing: true) { trial, page in
                    config.virtualBuffers = Config.VirtualBuffers()
                    check(config.virtualBuffers.autoFocusMode, "native automatic focus uses its default")
                    check(config.virtualBuffers.autoPassThroughOnCaretMove, "caret automatic focus uses its default")
                    page.position = page.buffer.offset(of: AXReplay.element(65)) ?? 0
                    let down = KeyboardGesture(identifier: "kb:downArrow")!
                    guard let command = page.script(for: down) else { Harness.fail("arrow command"); return }
                    ScriptHandler.executeScript(command, gesture: down)
                    check(AXReplay.sets.contains { $0.id == 66 && $0.attribute == kAXFocusedAttribute }, "first command requested focus")
                    let nextKey = KeyboardGesture(identifier: vo ? "kb:turnover+rightArrow" : "kb:upArrow")!
                    let next = vo ? VoiceOverKeysPlugin().script(named: "vo_next") : page.script(for: nextKey)
                    guard let next else { Harness.fail("superseding command"); return }
                    ScriptHandler.executeScript(next, gesture: nextKey)
                    let movedTo = page.position
                    check(movedTo != page.buffer.offset(of: AXReplay.element(66)), "the command really left the field")
                    // Also deliver after confirmFocus has timed out and discarded its active callback.
                    if delay > 0 { RunLoop.current.run(until: Date().addingTimeInterval(delay)) }
                    trial.advance(0.1)
                    let before = trial.events
                    modeFocus(66, page: page)
                    trial.advance(0.4)
                    check(!page.passThrough, "obsolete native entry cannot restore focus mode with defaults")
                    expect(page.position, movedTo, "obsolete event cannot restore the old reading position")
                    expect(trial.events, before, "obsolete event repeats neither the field nor its mode")
                    modeFocus(66, page: page)
                    check(page.passThrough, "a later ordinary focus event is still followed")
                    // A missing notification must not swallow a fresh intentional Tab or click.
                    for click in [false, true] {
                        page.setPassThrough(false, announce: false)
                        API.setFocusObject(ObjectFactory.make(AXReplay.element(65)), ancestors: [], interceptor: page)
                        page.position = page.buffer.offset(of: AXReplay.element(65)) ?? 0
                        ScriptHandler.executeScript(command, gesture: down)
                        let oldKey = InputManager.lastKeyIdentifier, oldTime = InputManager.lastKeyDownAt
                        let oldClicks = BrowseModeDocument.caretFocusClicks
                        if click { BrowseModeDocument.caretFocusClicks = { [UInt32.max, UInt32.max, UInt32.max] } }
                        else {
                            InputManager.lastKeyIdentifier = "kb:tab"
                            InputManager.lastKeyDownAt = Date()
                        }
                        modeFocus(66, page: page)
                        check(page.passThrough, "a fresh native Tab or click owns its focus even without the old event")
                        InputManager.lastKeyIdentifier = oldKey
                        InputManager.lastKeyDownAt = oldTime
                        BrowseModeDocument.caretFocusClicks = oldClicks
                    }
                }
            }
        }
    }

    test("caret focus: app departure invalidates delayed native entry") {
        withModeWords { trial, page in
            config.virtualBuffers.autoPassThroughOnCaretMove = true
            config.virtualBuffers.autoFocusMode = false
            page.position = page.buffer.offset(of: AXReplay.element(65)) ?? 0
            guard let command = page.script(for: KeyboardGesture(identifier: "kb:downArrow")!) else { Harness.fail("arrow command"); return }
            ScriptHandler.executeScript(command, gesture: KeyboardGesture(identifier: "kb:downArrow")!)
            check(AXReplay.sets.contains { $0.id == 66 && $0.attribute == kAXFocusedAttribute }, "command requested focus")
            AXHandler.shared.activePid = 900_999
            modeFocus(66, page: page)
            trial.advance(0.4)
            check(!page.passThrough, "lagging API focus does not authorize entry after app departure")
            check(!trial.events.contains("focus sound"), "departed app has no caret mode announcement")
        }
    }

    test("caret focus: menu items switch for focus changes but not caret moves") {
        withModeWords(role: "AXMenuItem") { _, page in
            config.virtualBuffers.autoPassThroughOnCaretMove = true
            config.virtualBuffers.autoFocusMode = true
            let item = ObjectFactory.make(AXReplay.element(66))
            check(page.shouldPassThrough(item), "native menu focus uses focus policy")
            check(!page.shouldPassThrough(item, caret: true), "caret excludes focus-only menu items")
        }
    }

    test("caret focus: real arrows and quick navigation use the independent option") {
        for enabled in [false, true] {
            for kind in ["arrow", "vo", "quick"] {
              for role in ["AXTextField", "AXTextArea", "AXComboBox"] {
                withModeWords(role: role, value: role == "AXTextArea" ? "First line\nSecond line" : "") { trial, page in
                    let quick = kind == "quick"
                    config.virtualBuffers.autoPassThroughOnCaretMove = enabled
                    config.virtualBuffers.autoFocusMode = false
                    page.position = page.buffer.offset(of: AXReplay.element(65)) ?? 0
                    ObjectNavigator.shared.toFocus()
                    trial.queued = []
                    trial.events = []
                    trial.sound = []
                    let plugin = VoiceOverKeysPlugin()
                    let command = quick ? plugin.script(named: "vo_nextFormField") : kind == "vo" ? plugin.script(named: "vo_next") : page.script(for: KeyboardGesture(identifier: "kb:downArrow")!)
                    guard let command else { Harness.fail("real navigation command exists"); return }
                    ScriptHandler.executeScript(command, gesture: KeyboardGesture(identifier: quick ? "kb:turnover+command+j" : "kb:downArrow")!)
                    check(trial.events.joined().contains("Prompt"), "the command reads the field")
                    expect(AXReplay.sets.contains { $0.id == 66 && $0.attribute == kAXFocusedAttribute }, enabled, "only caret option requests keyboard focus")
                    check(!page.passThrough, "native focus must confirm entry")
                    modeFocus(66, page: page)
                    trial.advance(0.4)
                    expect(page.passThrough, enabled, "focus setting off does not override caret intent")
                    expect(trial.events.filter { $0 == "focus sound" }.count, enabled ? 1 : 0)
                    if enabled {
                        let next = plugin.script(named: "vo_previous")
                        guard let next else { Harness.fail("VO previous command exists"); return }
                        ScriptHandler.executeScript(next, gesture: KeyboardGesture(identifier: "kb:turnover+leftArrow")!)
                        check(!page.passThrough, "VO leaves the field in browse mode")
                    }
                }
              }
            }
        }
    }

    test("manual mode: toggle and Escape retain words, or sound with navigation sounds") {
        for sounds in [false, true] {
            withModeWords(automatic: false) { trial, page in
                config.general.navigationSounds = sounds
                guard let toggle = GlobalCommands.shared.script(named: "toggleVirtualBufferPassThrough"),
                      let escape = page.script(named: "disablePassThrough") else { Harness.fail("manual mode scripts exist"); return }
                ScriptHandler.executeScript(toggle, gesture: KeyboardGesture(identifier: "kb:turnover+space")!)
                trial.advance(0.4)
                expect(trial.words.filter { $0 == "focus mode" }.count, sounds ? 0 : 1)
                ScriptHandler.executeScript(escape, gesture: KeyboardGesture(identifier: "kb:escape")!)
                trial.advance(0.4)
                expect(trial.words.filter { $0 == "browse mode" }.count, sounds ? 0 : 1)
                if sounds { check(trial.sound.contains(false), "Escape plays the browse sound") }
            }
        }
    }

    test("mode cues: Enter waits for delayed native focus, with sounds on and off") {
        for sounds in [false, true] {
            withModeWords { trial, page in
                config.general.navigationSounds = sounds
                page.position = page.buffer.offset(of: AXReplay.element(66)) ?? 0
                guard let enter = page.script(named: "activatePosition") else { Harness.fail("Enter script exists"); return }
                ScriptHandler.executeScript(enter, gesture: KeyboardGesture(identifier: "kb:enter")!)
                check(page.passThrough, "real Enter changes mode")
                check(!trial.events.contains("focus sound"), "no mode at synchronous key return")
                trial.advance(0.2)
                check(!trial.events.contains("focus sound"), "still awaiting the field")
                modeFocus(66, page: page)
                trial.drain()
                check(trial.events.dropLast().joined().contains("Prompt"), "native field words precede mode: \(trial.events)")
                expect(trial.events.last, "focus sound")
                trial.advance(0.4)
                expect(trial.events.filter { $0 == "focus sound" }.count, 1)
                expect(trial.sound, [true])
            }
        }
    }

    test("mode cues: an absent focus has a short ceiling after key speech") {
        withModeWords { trial, page in
            let key = Script(name: "modeWords", description: "", category: "", owner: nil) { _ in
                page.setPassThrough(true, announce: true)
                Speech.speakMessage("key words")
            }
            ScriptHandler.executeScript(key, gesture: KeyboardGesture(identifier: "kb:enter")!)
            expect(trial.events, ["key words"])
            trial.advance(0.36)
            expect(trial.events, ["key words", "focus sound"])
        }
    }

    test("mode cues: ordinary cancellation transfers to a newer field and Control retires it") {
        for explicit in [false, true] {
            withModeWords { trial, page in
                trial.finish = false
                modeFocus(66, page: page)
                expect(trial.sound, [], "the field is still speaking")
                let old = trial.queued.last?.1
                Speech.cancel(explicit: explicit)
                var fixture = conversation()
                fixture.nodes.append(.init(id: 100, attrs: ["AXRole": .string("AXTextField"), "AXTitle": .string("Next field"), "AXValue": .string(""), "AXParent": .element(60)]))
                AXReplay.load(fixture)
                trial.finish = true
                modeFocus(100, page: page)
                old?(false)
                trial.advance(0.5)
                expect(trial.sound, explicit ? [] : [true], "only ordinary cancellation transfers an unfinished cue")
                check(trial.words.last?.contains("Next field") == true, "new field speech still works")
            }
        }
    }

    test("mode cues: stale field completions cannot play on a later page, field, return or after expiry") {
        for change in ["page", "field", "return", "expiry"] {
            withModeWords { trial, page in
                trial.finish = false
                modeFocus(66, page: page)
                expect(trial.sound, [])
                let completion = trial.queued.last?.1
                switch change {
                case "page":
                    var fixture = conversation()
                    let root = fixture.nodes.firstIndex { $0.id == 60 }!
                    fixture.nodes[root].attrs["AXURL"] = .url("https://example.com/a-new-page")
                    AXReplay.load(fixture)
                    page.refreshIfNavigated()
                case "field": API.setFocusObject(ObjectFactory.make(AXReplay.element(65)), ancestors: [], interceptor: page)
                case "return":
                    API.setFocusObject(nil, ancestors: [])
                    API.setFocusObject(ObjectFactory.make(AXReplay.element(66)), ancestors: [], interceptor: page)
                default: trial.advance(8.1)
                }
                completion?(false)
                trial.advance(0.2)
                expect(trial.sound, [], "old cue cannot play after \(change)")
            }
        }
    }

    test("mode cues: forty fields retain focus mode and a menu button returns to browse mode") {
        withModeWords { trial, page in
            var fixture = conversation()
            for id in 100..<140 {
                fixture.nodes.append(.init(id: id, attrs: ["AXRole": .string("AXTextField"), "AXTitle": .string("Field \(id)"), "AXValue": .string(""), "AXParent": .element(60)]))
            }
            let button = fixture.nodes.firstIndex { $0.id == 65 }!
            fixture.nodes[button].attrs["AXRole"] = .string("AXPopUpButton")
            fixture.nodes[button].attrs["AXPopupValue"] = .string("menu")
            AXReplay.load(fixture)
            for id in 100..<140 {
                modeFocus(id, page: page)
                check(page.passThrough, "each field keeps focus mode")
            }
            expect(trial.events.filter { $0 == "focus sound" }.count, 1, "completed unchanged mode is not repeated")
            modeFocus(65, page: page)
            trial.drain()
            check(!page.passThrough, "menu button stays in browse mode")
            expect(trial.events.last, "browse sound")
        }
    }

    test("mode cues: temporary same-key transitions stay silent") {
        withModeWords { trial, page in
            page.passThrough = true
            let refresh = Script(name: "modeWordsRefresh", description: "", category: "", owner: nil) { _ in
                page.setPassThrough(false, announce: true)
                page.setPassThrough(true, announce: true)
                Speech.speakMessage("Prompt, edit")
            }
            ScriptHandler.executeScript(refresh, gesture: KeyboardGesture(identifier: "kb:enter")!)
            trial.advance(0.4)
            expect(trial.events, ["Prompt, edit"])
        }
    }

    test("mode cues: a long field completes before mode submission, and a departed page never submits it") {
        for leave in [false, true] {
            withModeWords { trial, page in
                trial.finish = false
                modeFocus(66, page: page)
                check(!trial.events.contains("focus sound"), "mode is not in the audio queue behind a long label")
                let label = trial.queued.last?.1
                trial.advance(0.6)
                check(!trial.events.contains("focus sound"), "the focus ceiling cannot overtake outstanding field speech")
                if leave { API.setFocusObject(nil, ancestors: []) }
                label?(true)
                trial.drain()
                expect(trial.events.contains("focus sound"), !leave, "only the current page submits mode after label playback")
            }
        }
    }

    test("quick navigation: the real VoiceOver command waits for deferred content and plays mode once") {
        AXReplay.load(conversation())
        let trial = ModeWordsTrial()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let buffer = WebBuffer(webArea: AXReplay.element(60), collect: { root, focus, request in
            entered.signal()
            _ = release.wait(timeout: .now() + 3)
            return WebBufferCollection.collect(root: root, focus: focus, request: request)
        })
        let page = BrowseModeDocument(webArea: AXReplay.element(60), buffer: buffer)
        defer {
            release.signal()
            API.setFocusObject(nil, ancestors: [])
            waitForBuffer(buffer)
            AXReplay.unload()
            trial.restore()
        }
        API.setFocusObject(ObjectFactory.make(AXReplay.element(65)), ancestors: [], interceptor: page)
        page.refreshIfNavigated()
        check(entered.wait(timeout: .now() + 1) == .success, "real collection held on its worker")
        page.passThrough = true
        page.hasWebKitSearch = false
        let plugin = VoiceOverKeysPlugin()
        guard let command = plugin.script(named: "vo_nextFormField") else { Harness.fail("real VoiceOver form-field command"); return }
        ScriptHandler.executeScript(command, gesture: KeyboardGesture(identifier: "kb:turnover+command+j")!)
        trial.advance(0.5)
        check(!trial.events.contains("browse sound"), "deferred navigation cannot announce before its item, even beyond focus ceiling")
        release.signal()
        waitForBuffer(buffer)
        trial.advance(0.1)
        check(trial.events.dropLast().joined().contains("Prompt"), "the real deferred command reported the field: \(trial.events)")
        expect(trial.events.last, "browse sound")
        expect(trial.events.filter { $0 == "browse sound" }.count, 1)
        check(!trial.words.contains("browse mode"), "deferred navigation uses sound only")
    }

    test("mode cues: superseded deferred quick navigation releases its ticket for the newer command") {
        for arrow in [false, true] {
            var fixture = conversation()
            let root = fixture.nodes.firstIndex { $0.id == 60 }!
            fixture.nodes[root].attrs["AXURL"] = .url("https://example.com/deferred-mode-\(arrow)")
            AXReplay.load(fixture)
            let trial = ModeWordsTrial()
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let buffer = WebBuffer(webArea: AXReplay.element(60), collect: { root, focus, request in
                entered.signal()
                _ = release.wait(timeout: .now() + 3)
                return WebBufferCollection.collect(root: root, focus: focus, request: request)
            })
            let page = BrowseModeDocument(webArea: AXReplay.element(60), buffer: buffer)
            BrowseModeHandler.shared.adopt(page)
            let savedStuck = ScriptHandler.mainStuck
            defer {
                ScriptHandler.mainStuck = savedStuck
                release.signal()
                API.setFocusObject(nil, ancestors: [])
                waitForBuffer(buffer)
                BrowseModeHandler.shared.forget(pid: 900_060)
                AXReplay.unload()
                trial.restore()
            }
            let focus = ObjectFactory.make(AXReplay.element(65))
            API.setFocusObject(focus, ancestors: [], interceptor: page)
            ObjectNavigator.shared.toFocus()
            trial.queued = []
            trial.events = []
            trial.sound = []
            page.refreshIfNavigated()
            check(entered.wait(timeout: .now() + 1) == .success, "collection is held off main")
            page.passThrough = true
            page.hasWebKitSearch = false
            let plugin = VoiceOverKeysPlugin()
            let gesture = KeyboardGesture(identifier: "kb:turnover+command+j")!
            guard let command = plugin.script(named: "vo_nextFormField") else { Harness.fail("form-field command"); continue }
            ScriptHandler.executeScript(command, gesture: gesture)
            trial.advance(0.5)
            check(!trial.events.contains("browse sound"), "the original command still owns its wait")
            // Exercise the real key-arrival counter without posting keys or running InputManager.
            ScriptHandler.mainStuck = { true }
            _ = ScriptHandler.askMain(gesture)
            ScriptHandler.mainStuck = savedStuck
            Speech.cancel()
            let newer = arrow ? plugin.script(named: "vo_next") : GlobalCommands.shared.script(named: "reportCurrentFocus")
            guard let newer else { Harness.fail("replacement command"); continue }
            ScriptHandler.executeScript(newer, gesture: KeyboardGesture(identifier: "kb:turnover+rightArrow")!)
            trial.advance(0.5)
            if arrow { check(!trial.events.contains("browse sound"), "a deferred line cannot be overtaken by its mode") }
            release.signal()
            waitForBuffer(buffer)
            trial.advance(0.4)
            check(trial.events.contains("browse sound"), "the newer command carries the mode when the old callback is discarded: \(trial.events)")
            expect(trial.events.filter { $0 == "browse sound" }.count, 1)
            check(!trial.words.contains("browse mode"), "replacement command uses sound only")
            if arrow {
                let modeIndex = trial.events.firstIndex(of: "browse sound") ?? 0
                check(trial.events.prefix(modeIndex).joined().contains("The reading stopped on this line."), "VO-Right reads its line before the mode: \(trial.events)")
                check(!trial.events.joined().contains("Prompt"), "the obsolete quick-navigation callback never runs")
            }
        }
    }

    test("mode cues: a virtual retry follows the actual reading position, not the last quick target") {
        withModeWords { trial, page in
            trial.finish = false
            page.position = page.buffer.offset(of: AXReplay.element(65)) ?? 0
            let navigation = BrowseModeDocument.quickNav.first { $0.name == "Edit" }!
            page.quickNav(navigation, forward: true)
            trial.drain()
            expect(trial.sound, [])
            let completion = trial.queued.last?.1
            // Arrows update this same caret without replacing lastQuickNavTarget. No new item has
            // been reported yet: an interrupted field's retry must not use that stale target.
            page.position = page.buffer.offset(of: AXReplay.element(64)) ?? 0
            completion?(false)
            trial.drain()
            trial.advance(0.2)
            expect(trial.sound, [], "the old virtual field cannot play elsewhere")
        }
    }

    test("mode cues: a heading container reports mode at its captured text-child position") {
        withModeWords { trial, page in
            var fixture = conversation()
            let heading = fixture.nodes.firstIndex { $0.id == 63 }!
            fixture.nodes[heading].attrs["AXRole"] = .string("AXHeading")
            AXReplay.load(fixture)
            page.buffer.buildForInspection()
            page.position = page.buffer.offset(of: AXReplay.element(65)) ?? 0
            page.passThrough = true
            trial.queued = []
            trial.events = []
            trial.sound = []
            let plugin = VoiceOverKeysPlugin()
            guard let command = plugin.script(named: "vo_previousHeading") else { Harness.fail("heading command"); return }
            ScriptHandler.executeScript(command, gesture: KeyboardGesture(identifier: "kb:turnover+command+shift+h")!)
            trial.advance(0.4)
            check(page.elementAtPosition()?.isSame(AXReplay.element(64)) == true, "the actual position is the heading's text child")
            expect(trial.events.last, "browse sound", "a container target does not fail the current-position check")
            expect(trial.events.filter { $0 == "browse sound" }.count, 1)
        }
    }

    test("Maps: Command F plays the focus sound after search, once, with navigation sounds on and off") {
        for sounds in [false, true] {
            withModeWords { trial, page in
                config.general.navigationSounds = sounds
                trial.finish = false
                let poster = KeyboardGesture.poster
                let skipped = WebBuffer.iosSkippedSubroles
                KeyboardGesture.poster = nil
                defer { KeyboardGesture.poster = poster; WebBuffer.iosSkippedSubroles = skipped }
                let module = MapsAppModule(pid: page.webArea.pid, bundleIdentifier: "com.apple.Maps", appName: "Maps")
                guard let command = module.script(named: "maps_search") else { Harness.fail("Maps search command"); return }
                ScriptHandler.executeScript(command, gesture: KeyboardGesture(identifier: "kb:command+f")!)
                expect(trial.words, ["search"])
                expect(trial.sound, [], "the cue waits for search speech to finish")
                trial.queued.last?.1?(true)
                trial.drain()
                expect(trial.events, ["search", "focus sound"], "Maps says search, then plays its cue")
                // The search field leaves browse mode; its arrival must not produce a second cue.
                trial.finish = true
                let field = ObjectFactory.make(AXReplay.element(66))
                API.setFocusObject(field, ancestors: [], interceptor: nil)
                EventHandler.execute(.gainFocus, on: field)
                trial.advance(0.4)
                expect(trial.sound, [true])
            }
        }
    }

    test("quick navigation: editable targets sound browse mode once; arrows do not") {
        withModeWords { trial, page in
            for kind in ["FormField", "Edit", "TextField", "Control"] {
                guard let navigation = (BrowseModeDocument.quickNav + BrowseModeDocument.voiceOverQuickNav).first(where: { $0.name == kind }) else { Harness.fail("quick navigation exists"); return }
                page.position = page.buffer.offset(of: AXReplay.element(65)) ?? 0
                trial.queued = []
                trial.events = []
                trial.sound = []
                page.quickNav(navigation, forward: true)
                trial.advance(0.4)
                check(trial.events.dropLast().joined().contains("Prompt"), "field before mode")
                expect(trial.events.last, "browse sound")
                expect(trial.events.filter { $0 == "browse sound" }.count, 1)
            }
            trial.queued = []
            trial.events = []
            trial.sound = []
            page.position = max(0, (page.buffer.offset(of: AXReplay.element(66)) ?? 1) - 1)
            page.script(named: "moveByLine_forward")?.handler(KeyboardGesture(identifier: "kb:downArrow")!)
            trial.advance(0.4)
            check(!trial.events.contains("browse sound"), "arrows do not add mode cues")
        }
    }

    // 14 Nov 2026: replay the app-switch transition from present(), then use real event and key paths.
    func returnToPrompt(_ page: BrowseModeDocument) {
        API.setFocusObject(nil, ancestors: [])
        let field = ObjectFactory.make(AXReplay.element(66))
        page.focusFromOutside = page !== API.focusTreeInterceptor
        API.setFocusObject(field, ancestors: [], interceptor: page)
        waitForBuffer(page.buffer)
        EventHandler.execute(.gainFocus, on: field)
    }

    test("app return: Prompt replaces the saved button position and accepts paste and Space") {
        for initialFocusMode in [false, true] {
            withModeWords(buttonTitle: "Hide sidebar") { trial, page in
                modeFocus(66, page: page)
                page.setPassThrough(initialFocusMode, announce: false)
                page.position = page.buffer.offset(of: AXReplay.element(65)) ?? 0
                trial.events = []
                trial.queued = []
                Speech.testResetFocusTiming()
                let actions = AXReplay.actions.count
                returnToPrompt(page)
                trial.advance(0.4)
                check(page.passThrough, "return to Prompt enters focus mode from either saved mode")
                expect(page.position, page.buffer.offset(of: AXReplay.element(66)), "reading position follows Prompt rather than Hide sidebar")
                check(trial.words.joined().contains("Prompt"), "return reports the focused Prompt")
                check(!trial.words.joined().contains("Hide sidebar"), "return does not report the saved button")
                check((API.focusObject as? EditableText)?.isFollowingSelection == true, "returned Prompt follows selection")
                let paste = KeyboardGesture(identifier: "kb:command+v")!
                check(ScriptHandler.findScript(for: paste) == nil, "paste belongs to the application after return")
                // Native paste changes the provider value and posts its normal text/caret events.
                _ = AXReplay.element(66).set(kAXValueAttribute, "Public pasted sample" as CFString)
                if let field = API.focusObject {
                    EventHandler.execute(.valueChange, on: field)
                    EventHandler.execute(.caret, on: field)
                }
                trial.drain()
                check(page.passThrough, "native paste notifications preserve focus mode")
                expect(page.position, page.buffer.offset(of: AXReplay.element(66)), "native paste keeps reading aligned with Prompt")
                let space = KeyboardGesture(identifier: "kb:space")!
                let script = ScriptHandler.findScript(for: space)
                check(script == nil, "Space belongs to the application after paste")
                // A failed assertion must never repost a key to the developer's real frontmost app.
                if script == nil {
                    let keyBefore = InputManager.lastKeyIdentifier
                    let timeBefore = InputManager.lastKeyDownAt
                    defer {
                        InputManager.lastKeyIdentifier = keyBefore
                        InputManager.lastKeyDownAt = timeBefore
                    }
                    check(!InputManager.handleKeyDown(space), "Space passes through the real input manager after paste")
                    trial.drain()
                }
                expect(AXReplay.actions.count, actions, "paste and Space never activate the saved button")
            }
        }
    }

    test("app return: pending and obsolete automatic caret focus cannot consume Prompt return") {
        for obsolete in [false, true] {
            withModeWords(trailing: true) { trial, page in
                modeFocus(66, page: page)
                page.setPassThrough(false, announce: false)
                API.setFocusObject(ObjectFactory.make(AXReplay.element(65)), ancestors: [], interceptor: page)
                config.virtualBuffers.autoPassThroughOnCaretMove = true
                page.position = page.buffer.offset(of: AXReplay.element(65)) ?? 0
                let down = KeyboardGesture(identifier: "kb:downArrow")!
                guard let command = page.script(for: down) else { Harness.fail("caret navigation command exists"); return }
                ScriptHandler.executeScript(command, gesture: down)
                check(AXReplay.sets.contains { $0.id == 66 && $0.attribute == kAXFocusedAttribute }, "caret arrival requested native Prompt focus")
                if obsolete {
                    let up = KeyboardGesture(identifier: "kb:upArrow")!
                    guard let command = page.script(for: up) else { Harness.fail("superseding navigation exists"); return }
                    ScriptHandler.executeScript(command, gesture: up)
                    page.position = page.buffer.offset(of: AXReplay.element(65)) ?? 0
                }
                trial.events = []
                trial.queued = []
                Speech.testResetFocusTiming()
                returnToPrompt(page)
                trial.advance(0.4)
                check(page.passThrough, "fresh app return owns focus despite an unanswered caret request")
                expect(page.position, page.buffer.offset(of: AXReplay.element(66)), "fresh return aligns the caret with Prompt")
                check(trial.words.joined().contains("Prompt"), "fresh return reports Prompt")
                check((API.focusObject as? EditableText)?.isFollowingSelection == true, "fresh return follows selection")
            }
        }
    }

    test("app return: manual browse mode and disabled automatic focus preserve the saved position") {
        for manual in [false, true] {
            withModeWords { trial, page in
                modeFocus(66, page: page)
                page.setPassThrough(false, announce: false)
                page.disableAutoPassThrough = manual
                config.virtualBuffers.autoFocusMode = manual
                let saved = page.buffer.offset(of: AXReplay.element(65)) ?? 0
                page.position = saved
                returnToPrompt(page)
                trial.advance(0.4)
                check(!page.passThrough, "return respects manual browse mode or disabled automatic focus")
                expect(page.position, saved, "explicit preference preserves the saved reading position")
                check((API.focusObject as? EditableText)?.isFollowingSelection == true, "selection following resumes even in browse mode")
            }
        }
    }

    // Saved browse positions still survive returns to buttons and an explicit manual browse override.
    // Automatic field returns use the regression above; an already active focus mode still resumes below.
    test("browse mode: returning to a button or manually overridden Prompt preserves the reading position") {
        AXReplay.load(conversation())
        let saved = config, keep = Speech.sink
        var said = ""
        Speech.sink = { said += $0 + " " }
        defer { API.setFocusObject(nil, ancestors: []); BrowseModeHandler.shared.forget(pid: 900_060); AXReplay.unload(); config = saved; Speech.sink = keep }
        config.virtualBuffers.autoFocusMode = true
        Speech.testResetFocusTiming()
        let page = BrowseModeHandler.shared.document(root: AXReplay.element(60))
        waitForBuffer(page.buffer)
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
            page.handleEvent(Event(.gainFocus, f)) {
                passed = true
                f.handleEvent(Event(.gainFocus, f))
            }
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
        page.disableAutoPassThrough = true
        page.position = stopped
        check(!focus(66, fromOutside: true), "back onto the prompt, it is not read itself")
        check((API.focusObject as? EditableText)?.isFollowingSelection == true,
              "back onto the prompt, its selection is followed again, so Shift and the arrows are read")
        check(!page.passThrough, "browse mode stays, though the prompt has the focus")
        expect(page.position, stopped, "the reading position stays where the reading stopped")

        // Back onto another control than the one that had the focus: followed, as NVDA does.
        check(focus(65, fromOutside: true), "back onto Copy while the prompt had the focus, it is followed")
        check(page.position != stopped, "the reading position went to Copy")

        page.disableAutoPassThrough = false
        // Typing in the prompt (focus mode), another app, back: typing still.
        check(focus(66, fromOutside: false) && page.passThrough, "into the prompt, focus mode")
        // 14 Nov 2026: API departure cancels collection, but the document retains its focus mode.
        // Re-entry must say the field itself, never the old virtual reading line.
        API.setFocusObject(nil, ancestors: [])
        check(page.passThrough, "focus mode survives leaving the app (including the lock screen)")
        check(BrowseModeHandler.shared.document(root: AXReplay.element(60)) === page, "re-entry reuses the page and its mode")
        Speech.speakObject(ObjectFactory.make(AXReplay.element(65)), reason: .focus)
        check(focus(66, fromOutside: true), "back into the prompt in focus mode, the focus is followed as before")
        check(page.passThrough, "focus mode stays")
        check(said.contains("Prompt"), "the field is said as an ordinary focus: \(said)")
        check(!said.contains("The reading stopped"), "the old reading line is not said in focus mode")
        check((API.focusObject as? EditableText)?.isFollowingSelection == true, "ordinary focus resumes selection following too")
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
