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
    /// The replayed application is the one in front.
    func playing(_ body: () -> Void) {
        AXReplay.load(tree()); AXHandler.shared.activePid = 900_009
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
