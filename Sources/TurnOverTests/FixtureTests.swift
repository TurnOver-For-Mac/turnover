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

    /// The same document after a jump: the pages were laid out afresh, so the first page's old copy (4) is gone and
    /// answers nothing, and Pages has its focus on the new copy (7), which gives the caret.
    func pagesLaidOutAfresh() -> AXFixture {
        var f = pages(caret: true)
        f.nodes = f.nodes.filter { ![3, 4, 5, 6, 9].contains($0.id) } + [
            .init(id: 3, attrs: ["AXRole": .string("AXPage"), "AXParent": .element(2), "AXWindow": .element(0), "AXChildren": .elements([7])]),
            .init(id: 4, attrs: [:]),
            .init(id: 5, attrs: ["AXRole": .string("AXPage"), "AXParent": .element(2), "AXWindow": .element(0), "AXChildren": .elements([8])]),
            .init(id: 7, attrs: ["AXRole": .string("AXTextArea"), "AXParent": .element(3), "AXWindow": .element(0), "AXFocused": .bool(true),
                                 "AXNumberOfCharacters": .number(20), "AXSharedCharacterRange": .range(0, 12), "AXSelectedTextRange": .range(0, 0)]),
            .init(id: 8, attrs: ["AXRole": .string("AXTextArea"), "AXParent": .element(5), "AXWindow": .element(0), "AXFocused": .bool(true),
                                 "AXNumberOfCharacters": .number(20), "AXSharedCharacterRange": .range(12, 8), "AXSelectedTextRange": .range(0, 0)]),
            .init(id: 9, attrs: ["AXRole": .string("AXApplication"), "AXChildren": .elements([0]), "AXWindows": .elements([0]),
                                 "AXFocusedWindow": .element(0), "AXFocusedUIElement": .element(7)]),
        ]
        return f
    }
    /// The class Pages' module gives the first page's copy of the body text.
    func pagesBodyClass() -> TurnOverObject.Type? {
        AXReplay.load(pages(caret: true)); defer { AXReplay.unload() }
        return pagesModule()?.objectClass(for: AXReplay.element(4), role: .editableText, subrole: nil)
    }
    /// Pages' module for the replayed element's own pid (each replayed element has a pid of its own).
    func pagesModule(for id: Int) -> AppModule? {
        BuiltInModules.register()
        return AppModuleHandler.shared.moduleType(for: "com.apple.Pages")?.init(pid: AXReplay.floor + pid_t(id), bundleIdentifier: "com.apple.Pages", appName: "Pages")
    }

    test("Pages: a jump that leaves the copy of the text gone and brings no focus reads from Pages' focus") {
        guard let kind = pagesBodyClass() else { return Harness.fail("Pages' body text has its class") }
        AXReplay.load(pagesLaidOutAfresh()); defer { AXReplay.unload(); API.setFocusObject(nil, ancestors: []) }
        let gone = kind.init(element: AXReplay.element(4))
        API.setFocusObject(gone, ancestors: [])
        (gone as? EditableText)?.caretMoved(speak: nil, gesture: KeyboardGesture(identifier: "kb:command+upArrow")!, info: nil)
        expect(API.focusObject.flatMap { AXReplay.id(of: $0.element) }, 7, "the copy Pages has its focus on is the focus")
    }
    test("Pages: the caret at a page's first character is that page's") {
        var f = pages(caret: true)
        // Neither copy says it has the focus, and the caret is where the first page's part ends and the second's starts.
        f.nodes = f.nodes.map { n in
            guard [4, 6].contains(n.id) else { return n }
            var attrs = n.attrs; attrs["AXFocused"] = nil; attrs["AXSelectedTextRange"] = .range(12, 0)
            return .init(id: n.id, attrs: attrs)
        }
        AXReplay.load(f); defer { AXReplay.unload() }
        guard let module = pagesModule() else { return Harness.fail("Pages' module is registered") }
        expect(module.redirectFocus(AXReplay.element(2)).flatMap { AXReplay.id(of: $0) }, 6, "the second page's body text is the focus")
    }
    test("Pages: coming to Pages, the body text's focus is no hop from another page") {
        guard let kind = pagesBodyClass() else { return Harness.fail("Pages' body text has its class") }
        AXReplay.load(pages(caret: true)); defer { AXReplay.unload(); API.setFocusObject(nil, ancestors: []); InputManager.lastKeyDownAt = .distantPast }
        guard let module = pagesModule(for: 4) else { return Harness.fail("Pages' module is registered") }
        let body = kind.init(element: AXReplay.element(4))
        // As present() leaves it: the new focus is TurnOver's already, Command-Tab has just gone down, and the focus
        // that left was another app's.
        API.setFocusObject(body, ancestors: [])
        InputManager.lastKeyDownAt = Date()
        check(!module.ignoresFocus(Event(.gainFocus, body)), "the first focus in Pages is read")
    }
    test("Pages: a hop from one page's body text to another's just after a key is quiet") {
        guard let kind = pagesBodyClass() else { return Harness.fail("Pages' body text has its class") }
        AXReplay.load(pages(caret: true)); defer { AXReplay.unload(); API.setFocusObject(nil, ancestors: []); InputManager.lastKeyDownAt = .distantPast }
        guard let module = pagesModule(for: 6) else { return Harness.fail("Pages' module is registered") }
        let old = kind.init(element: AXReplay.element(4)), new = kind.init(element: AXReplay.element(6))
        module.handleEvent(Event(.loseFocus, old)) {}
        API.setFocusObject(new, ancestors: [])
        InputManager.lastKeyDownAt = Date()
        check(module.ignoresFocus(Event(.gainFocus, new)), "the hop is quiet: the key's own reading stands")
    }
    test("Pages: after a key the copy of the text that gives the caret stays the focus") {
        guard let kind = pagesBodyClass() else { return Harness.fail("Pages' body text has its class") }
        AXReplay.load(pages(caret: true)); defer { AXReplay.unload(); API.setFocusObject(nil, ancestors: []) }
        let copy = kind.init(element: AXReplay.element(4))
        API.setFocusObject(copy, ancestors: [])
        (copy as? EditableText)?.caretMoved(speak: nil, gesture: KeyboardGesture(identifier: "kb:command+upArrow")!, info: nil)
        expect(API.focusObject.flatMap { AXReplay.id(of: $0.element) }, 4, "the copy is still the focus")
    }

    /// The two pages' copies of the text (4, 6) with words: the first page's part of the story is "One two three\nfour",
    /// the second's ", five six". Each copy answers for the whole story, as Pages' do, with the caret at `caret`.
    func pagesStory(caret: Int) -> AXFixture {
        var f = pages(caret: true)
        f.nodes = f.nodes.map { n in
            guard [4, 6].contains(n.id) else { return n }
            var attrs = n.attrs
            attrs["AXValue"] = .string("One two three\nfour, five six"); attrs["AXNumberOfCharacters"] = .number(28)
            attrs["AXSharedCharacterRange"] = n.id == 4 ? .range(0, 18) : .range(18, 10); attrs["AXSelectedTextRange"] = .range(caret, 0)
            return .init(id: n.id, attrs: attrs)
        }
        return f
    }
    /// A caret key on the first page's copy whose move crosses onto the second page. Pages moves its focus as the caret
    /// crosses, so the key's wait for the caret sees a focus event waiting; then the caret is at `to`, and the second
    /// page's copy gets the focus. What was said for that focus, as Pages' module takes it.
    func pagesCrossing(pressed: String, sends: String, script: String, from: Int, to: Int) -> [String] {
        guard let kind = pagesBodyClass(), let module = pagesModule(for: 6) else { Harness.fail("Pages' module is registered"); return [] }
        AXReplay.load(pagesStory(caret: from))
        let sink = Speech.sink, direct = InputManager.directPid
        defer { AXReplay.unload(); API.setFocusObject(nil, ancestors: []); Speech.sink = sink; InputManager.directPid = direct; InputManager.lastKeyDownAt = .distantPast }
        Speech.sink = { _ in }
        let old = kind.init(element: AXReplay.element(4)), new = kind.init(element: AXReplay.element(6))
        API.setFocusObject(old, ancestors: [])
        InputManager.lastKeyIdentifier = pressed
        InputManager.lastKeyDownAt = Date()
        // The focus event waits behind the key's script. Its stand-in (the window) is not run: its pid is a direct app's.
        InputManager.directPid = AXReplay.floor
        ScriptHandler.executeScript(Script(name: "pagesCrossing", description: "", category: "", owner: nil) { g in
            EventHandler.queue(Event(.gainFocus, TurnOverObject(element: AXReplay.element(0))))
            old.script(named: script)?.handler(g)
        }, gesture: KeyboardGesture(identifier: sends)!)
        var r = CFRange(location: to, length: 0)
        for id in [4, 6] { _ = AXUIElementSetAttributeValue(AXReplay.element(id), kAXSelectedTextRangeAttribute as CFString, AXValueCreate(.cfRange, &r)!) }
        var said: [String] = []
        Speech.sink = { said.append($0) }
        module.handleEvent(Event(.loseFocus, old)) {}
        API.setFocusObject(new, ancestors: [])
        let hop = Event(.gainFocus, new)
        _ = module.ignoresFocus(hop)
        module.handleEvent(hop) {}
        return said
    }
    test("Pages: a VoiceOver key's move onto the next page reads the line, as the arrow it sends does") {
        // VO-Down sends Down, and the hop was checked against VO-Down itself: nothing was said (a code review, 29 Oct 2026).
        expect(pagesCrossing(pressed: "kb:turnover+downArrow", sends: "kb:downArrow", script: "caret_moveByLine", from: 5, to: 19), ["four, five six"])
    }
    test("Pages: Right onto the next page reads the character crossed and Option Right the word, as within a page") {
        let saved = config; defer { config = saved }
        // On the Mac, the character and the word passed over, not the comma after the caret that Option Right stops on.
        config.general.keyboardStyle = KeyboardStyle.voiceOver.rawValue
        expect(pagesCrossing(pressed: "kb:rightArrow", sends: "kb:rightArrow", script: "caret_moveByCharacter", from: 17, to: 18), ["r"])
        expect(pagesCrossing(pressed: "kb:option+rightArrow", sends: "kb:option+rightArrow", script: "caret_moveByWord", from: 14, to: 18), ["four"])
        // In the Windows style, Option Right goes on to the next word and reads it.
        config.general.keyboardStyle = KeyboardStyle.jaws.rawValue
        expect(pagesCrossing(pressed: "kb:option+rightArrow", sends: "kb:option+rightArrow", script: "caret_moveByWord", from: 14, to: 18), ["five"])
    }
    test("Pages: after a copy of the text takes over from a gone one, Shift with an arrow reads the selection") {
        guard let kind = pagesBodyClass() else { return Harness.fail("Pages' body text has its class") }
        var f = pagesLaidOutAfresh()
        f.nodes = f.nodes.map { n in
            guard [7, 8].contains(n.id) else { return n }
            var attrs = n.attrs; attrs["AXValue"] = .string("Twenty characters ok")
            return .init(id: n.id, attrs: attrs)
        }
        AXReplay.load(f)
        let sink = Speech.sink, poster = KeyboardGesture.poster
        var said: [String] = []
        defer { AXReplay.unload(); API.setFocusObject(nil, ancestors: []); Speech.sink = sink; KeyboardGesture.poster = poster }
        Speech.sink = { _ in }
        let gone = kind.init(element: AXReplay.element(4))
        API.setFocusObject(gone, ancestors: [])
        (gone as? EditableText)?.caretMoved(speak: nil, gesture: KeyboardGesture(identifier: "kb:command+upArrow")!, info: nil)
        // Shift Option Right: Pages selects the first word.
        KeyboardGesture.poster = { _ in
            var r = CFRange(location: 0, length: 6)
            _ = AXUIElementSetAttributeValue(AXReplay.element(7), kAXSelectedTextRangeAttribute as CFString, AXValueCreate(.cfRange, &r)!)
        }
        Speech.sink = { said.append($0) }
        API.focusObject?.script(named: "caret_changeSelection")?.handler(KeyboardGesture(identifier: "kb:option+shift+rightArrow")!)
        check(said.contains { $0.contains("Twenty") }, "the selection is said (said: \(said))")
    }
    test("Pages: after a hop between the pages' copies of the text, Shift with an arrow reads the selection") {
        guard let kind = pagesBodyClass(), let module = pagesModule(for: 6) else { return Harness.fail("Pages' module is registered") }
        AXReplay.load(pagesStory(caret: 18))
        let sink = Speech.sink, poster = KeyboardGesture.poster
        var said: [String] = []
        defer { AXReplay.unload(); API.setFocusObject(nil, ancestors: []); Speech.sink = sink; KeyboardGesture.poster = poster; InputManager.lastKeyDownAt = .distantPast }
        Speech.sink = { _ in }
        let old = kind.init(element: AXReplay.element(4)), new = kind.init(element: AXReplay.element(6))
        InputManager.lastKeyIdentifier = "kb:rightArrow"
        InputManager.lastKeyDownAt = Date()
        module.handleEvent(Event(.loseFocus, old)) {}
        API.setFocusObject(new, ancestors: [])
        let hop = Event(.gainFocus, new)
        check(module.ignoresFocus(hop), "the hop is quiet")
        module.handleEvent(hop) {}
        // Shift Option Right: Pages selects ", five".
        KeyboardGesture.poster = { _ in
            var r = CFRange(location: 18, length: 6)
            for id in [4, 6] { _ = AXUIElementSetAttributeValue(AXReplay.element(id), kAXSelectedTextRangeAttribute as CFString, AXValueCreate(.cfRange, &r)!) }
        }
        Speech.sink = { said.append($0) }
        new.script(named: "caret_changeSelection")?.handler(KeyboardGesture(identifier: "kb:option+shift+rightArrow")!)
        check(said.contains { $0.contains("five") }, "the selection is said (said: \(said))")
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
