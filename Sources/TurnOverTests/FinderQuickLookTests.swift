// SPDX-License-Identifier: GPL-3.0-or-later
// Finder with Quick Look open (17 Nov 2026): the window has the focus, the selection moves in the list underneath,
// and the arrow says the file it moved to. Logic evidence only (a made-up tree; Finder's real Quick Look window was
// never recorded, so its subrole and the speed of its selection change are unconfirmed).
import Foundation
import ApplicationServices
import TurnOverCore
import AXFixtures

func finderQuickLookTests() {
    func tree(floatingFocus: Bool = true) -> AXFixture {
        .init(app: "Finder", bundle: "com.apple.finder", recorded: "synthetic", root: 0, application: 8, focus: nil, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXWindow"), "AXSubrole": .string("AXStandardWindow"), "AXTitle": .string("Docs"), "AXParent": .element(8), "AXChildren": .elements([1])]),
            .init(id: 1, attrs: ["AXRole": .string("AXOutline"), "AXDescription": .string("list view"), "AXParent": .element(0), "AXWindow": .element(0),
                                 "AXRows": .elements([2, 3]), "AXChildren": .elements([2, 3]), "AXSelectedRows": .elements([2])]),
            .init(id: 2, attrs: ["AXRole": .string("AXRow"), "AXTitle": .string("First file"), "AXParent": .element(1), "AXWindow": .element(0)]),
            .init(id: 3, attrs: ["AXRole": .string("AXRow"), "AXTitle": .string("Second file"), "AXParent": .element(1), "AXWindow": .element(0)]),
            .init(id: 8, attrs: ["AXRole": .string("AXApplication"), "AXChildren": .elements([0, 9]), "AXWindows": .elements([0, 9]),
                                 "AXMainWindow": .element(0), "AXFocusedWindow": .element(9), "AXFocusedUIElement": .element(floatingFocus ? 9 : 1)]),
            .init(id: 9, attrs: ["AXRole": .string("AXWindow"), "AXSubrole": .string("AXSystemFloatingWindow"), "AXTitle": .string("Quick Look"), "AXParent": .element(8)]),
        ])
    }
    test("Finder Quick Look: the selection's move is told, and only with the panel itself holding the focus") {
        let sink = Speech.sink, poster = KeyboardGesture.poster
        defer { Speech.sink = sink; KeyboardGesture.poster = poster; API.setFocusObject(nil, ancestors: []); AXReplay.unload() }
        AXReplay.load(tree())
        let type = AppModuleHandler.shared.moduleType(for: "com.apple.finder")!
        let module = type.init(pid: 900_009, bundleIdentifier: "com.apple.finder", appName: "Finder")
        let script = module.script(named: "finder_quickLookArrows")
        check(script != nil, "the script exists")
        API.setFocusObject(ObjectFactory.make(AXReplay.element(9)), ancestors: [])
        check(script?.isAvailable?() == true, "available with the panel holding the focus")
        var said: [String] = []
        Speech.sink = { said.append($0) }
        KeyboardGesture.poster = { _ in _ = AXReplay.element(1).set(kAXSelectedRowsAttribute, [AXReplay.element(3)] as CFArray) }
        script?.handler(KeyboardGesture(identifier: "kb:downArrow")!)
        check(said.joined(separator: " ").contains("Second file"), "the new file is said: \(said)")
        said = []
        KeyboardGesture.poster = { _ in }
        script?.handler(KeyboardGesture(identifier: "kb:downArrow")!)
        expect(said, [], "a key that moved nothing says nothing")
        API.setFocusObject(ObjectFactory.make(AXReplay.element(1)), ancestors: [])
        check(script?.isAvailable?() == false, "not available with the list itself focused: its own arrows speak")
    }
    test("Finder Quick Look: the selection test") {
        AXReplay.load(tree())
        defer { AXReplay.unload() }
        let a = AXReplay.element(2), b = AXReplay.element(3)
        check(FinderRows.selectionMoved(from: a, to: b), "another row")
        check(!FinderRows.selectionMoved(from: a, to: a), "the same row")
        check(!FinderRows.selectionMoved(from: a, to: nil), "nothing now")
        check(FinderRows.selectionMoved(from: nil, to: b), "something where nothing was")
    }
}
