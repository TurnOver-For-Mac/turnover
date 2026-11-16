// SPDX-License-Identifier: GPL-3.0-or-later
// The toolbar rule (ToolbarKeys.swift): the pure decision, the way back, and the file view Finder offers.
import Foundation
import ApplicationServices
import TurnOverCore
import AXFixtures

func toolbarKeysTests() {
    func decide(_ key: ToolbarKeys.Key, inToolbar: Bool = true, menuOpen: Bool = false, textEntry: Bool = false, hasText: Bool = false,
                usesArrows: Bool = false, count: Int = 4, index: Int? = 1) -> ToolbarKeys.Decision {
        ToolbarKeys.decide(key, inToolbar: inToolbar, menuOpen: menuOpen, textEntry: textEntry, hasText: hasText,
                           usesArrowsItself: usesArrows, controlCount: count, index: index)
    }
    test("toolbar keys: Left and Right move to the previous and next control in the middle") {
        expect(decide(.right), .move(2))
        expect(decide(.left), .move(0))
    }
    test("toolbar keys: at either end the edge sound, and the keyboard stays") {
        expect(decide(.left, index: 0), .edge, "before the first")
        expect(decide(.right, index: 3), .edge, "after the last")
        expect(decide(.right, count: 1, index: 0), .edge, "a toolbar of one")
    }
    test("toolbar keys: a text field keeps Left and Right; Escape goes to the app only while it holds text") {
        expect(decide(.left, textEntry: true), .passThrough)
        expect(decide(.right, textEntry: true, hasText: true), .passThrough)
        expect(decide(.escape, textEntry: true, hasText: true), .passThrough, "text in the field: Escape clears it")
        expect(decide(.escape, textEntry: true, hasText: false), .escapeToContent, "an empty field: back to the content")
    }
    test("toolbar keys: a slider or a tab strip keeps its arrows") {
        expect(decide(.right, usesArrows: true), .passThrough)
        expect(decide(.escape, usesArrows: true), .escapeToContent)
        check(ToolbarKeys.keepsArrows(axRole: "AXSlider"), "a slider")
        check(!ToolbarKeys.keepsArrows(axRole: "AXButton"), "a button")
    }
    test("toolbar keys: an open menu has the keys") {
        expect(decide(.right, menuOpen: true), .passThrough)
        expect(decide(.escape, menuOpen: true), .passThrough)
    }
    test("toolbar keys: outside a toolbar nothing is touched") {
        for k in [ToolbarKeys.Key.left, .right, .escape] { expect(decide(k, inToolbar: false), .passThrough, k.rawValue) }
    }
    test("toolbar keys: a control that cannot be placed in the toolbar passes the arrows on") {
        expect(decide(.right, index: nil), .passThrough)
        expect(decide(.right, count: 0, index: 0), .passThrough)
    }
    test("toolbar keys: text entry is found by role or by the search subrole") {
        for r in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] { check(ToolbarKeys.isTextEntry(axRole: r, subrole: nil), r) }
        check(ToolbarKeys.isTextEntry(axRole: "AXTextField", subrole: "AXSearchField"), "a search field")
        check(!ToolbarKeys.isTextEntry(axRole: "AXButton", subrole: nil), "a button")
        check(!ToolbarKeys.isTextEntry(axRole: "AXPopUpButton", subrole: nil), "a pop-up button")
    }
    test("toolbar keys: the stored answer needs a toolbar among the ancestors and no sheet or dialog") {
        check(ToolbarKeys.ancestorsAllow([("AXGroup", nil), ("AXToolbar", nil), ("AXWindow", nil)]), "a toolbar control")
        check(!ToolbarKeys.ancestorsAllow([("AXGroup", nil), ("AXWindow", nil)]), "no toolbar")
        check(!ToolbarKeys.ancestorsAllow([("AXToolbar", nil), ("AXSheet", nil), ("AXWindow", nil)]), "a toolbar in a sheet")
        check(!ToolbarKeys.ancestorsAllow([("AXToolbar", nil), ("AXWindow", "AXDialog")]), "a toolbar in a dialog")
        check(!ToolbarKeys.ancestorsAllow([]), "nothing")
    }
    test("toolbar keys: Escape prefers the place the keyboard was, then the app's answer, then the first control") {
        func choose(_ p: Int?, _ m: Int?, _ f: Int?) -> (Int, ToolbarKeys.EscapeSource)? {
            ToolbarKeys.chooseEscapeTarget(previous: { p }, appModule: { m }, firstContent: { f }).map { ($0.target, $0.source) }
        }
        expect(choose(1, 2, 3)?.0, 1); expect(choose(1, 2, 3)?.1, .previousFocus)
        expect(choose(nil, 2, 3)?.0, 2); expect(choose(nil, 2, 3)?.1, .appModule)
        expect(choose(nil, nil, 3)?.0, 3); expect(choose(nil, nil, 3)?.1, .firstContent)
        check(choose(nil, nil, nil) == nil, "nothing to return to")
        var asked: [String] = []
        _ = ToolbarKeys.chooseEscapeTarget(previous: { asked.append("p"); return Optional(1) }, appModule: { asked.append("m"); return Optional(2) }, firstContent: { asked.append("f"); return Optional(3) })
        expect(asked, ["p"], "the later ones are not asked when the first answers")
    }
    test("toolbar keys: Finder's way back finds the file list, never the sidebar or the toolbar's own list") {
        defer { AXReplay.unload() }
        AXReplay.load(.init(app: "Finder", bundle: "com.apple.finder", recorded: "synthetic", root: 0, application: nil, focus: nil, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXWindow"), "AXChildren": .elements([1, 2, 5])]),
            .init(id: 1, attrs: ["AXRole": .string("AXToolbar"), "AXChildren": .elements([6])]),
            .init(id: 2, attrs: ["AXRole": .string("AXSplitGroup"), "AXChildren": .elements([3, 4])]),
            .init(id: 3, attrs: ["AXRole": .string("AXOutline"), "AXDescription": .string("sidebar")]),
            .init(id: 4, attrs: ["AXRole": .string("AXOutline"), "AXDescription": .string("list view")]),
            .init(id: 5, attrs: ["AXRole": .string("AXGroup")]),
            .init(id: 6, attrs: ["AXRole": .string("AXList"), "AXDescription": .string("toolbar list")])
        ]))
        expect(FinderRows.fileView(in: AXReplay.root!).flatMap { AXReplay.id(of: $0) }, 4, "the list view")
    }
    test("toolbar keys: entering a toolbar from outside says tool bar, even with the kind of an item left out of the reading order") {
        defer { AXReplay.unload() }
        AXReplay.load(.init(app: "Finder", bundle: "com.apple.finder", recorded: "synthetic", root: 0, application: nil, focus: nil, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXWindow"), "AXChildren": .elements([1, 3])]),
            .init(id: 1, attrs: ["AXRole": .string("AXToolbar"), "AXChildren": .elements([2]), "AXParent": .element(0)]),
            .init(id: 2, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("back"), "AXParent": .element(1)]),
            .init(id: 3, attrs: ["AXRole": .string("AXToolbar"), "AXTitle": .string("Tools"), "AXParent": .element(0)])
        ]))
        let saved = config, sink = Speech.sink
        defer { config = saved; Speech.sink = sink }
        config.presentation.verbosityByApp["com.apple.finder"] = Config.Verbosity(order: Config.Verbosity.pieces, off: ["role"])
        var said: [String] = []
        Speech.sink = { said.append($0) }
        check(ToolbarKeys.sayEntering(ObjectFactory.make(AXReplay.element(1))), "a nameless toolbar is said")
        expect(said, ["tool bar"])
        said = []
        check(!ToolbarKeys.sayEntering(ObjectFactory.make(AXReplay.element(3))), "a toolbar with a name of its own is left to the ordinary announcement")
        check(!ToolbarKeys.sayEntering(ObjectFactory.make(AXReplay.element(2))), "a button is not a toolbar")
        expect(said, [])
    }
}
