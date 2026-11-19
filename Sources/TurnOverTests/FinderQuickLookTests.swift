// SPDX-License-Identifier: GPL-3.0-or-later
// Finder with Quick Look open (17 Nov 2026): the window has the focus, the selection moves in the list underneath,
// and the arrow says the file it moved to. Logic evidence only (a made-up tree; Finder's real Quick Look window was
// never recorded, so its subrole and the speed of its selection change are unconfirmed).
import Foundation
import ApplicationServices
import TurnOverCore
import AXFixtures

func finderQuickLookTests() {
    func tree(floatingFocus: Bool = true, second: String = "Second file") -> AXFixture {
        .init(app: "Finder", bundle: "com.apple.finder", recorded: "synthetic", root: 0, application: 8, focus: nil, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXWindow"), "AXSubrole": .string("AXStandardWindow"), "AXTitle": .string("Docs"), "AXParent": .element(8), "AXChildren": .elements([1])]),
            .init(id: 1, attrs: ["AXRole": .string("AXOutline"), "AXDescription": .string("list view"), "AXParent": .element(0), "AXWindow": .element(0),
                                 "AXRows": .elements([2, 3]), "AXChildren": .elements([2, 3]), "AXSelectedRows": .elements([2])]),
            .init(id: 2, attrs: ["AXRole": .string("AXRow"), "AXTitle": .string("First file"), "AXParent": .element(1), "AXWindow": .element(0)]),
            .init(id: 3, attrs: ["AXRole": .string("AXRow"), "AXTitle": .string(second), "AXParent": .element(1), "AXWindow": .element(0)]),
            .init(id: 8, attrs: ["AXRole": .string("AXApplication"), "AXChildren": .elements([0, 9]), "AXWindows": .elements([0, 9]),
                                 "AXMainWindow": .element(0), "AXFocusedWindow": .element(9), "AXFocusedUIElement": .element(floatingFocus ? 9 : 1)]),
            .init(id: 9, attrs: ["AXRole": .string("AXWindow"), "AXSubrole": .string("Quick Look"), "AXTitle": .string("Quick Look"), "AXParent": .element(8)]),
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
        script?.handler(KeyboardGesture(identifier: "kb:upArrow")!)
        expect(said, [], "a key that moved nothing, away from the ends, says nothing")
        // On the last row Down cannot move: "bottom" at once (no 400 ms wait), the key still sent. On the first, Up: "top".
        nonisolated(unsafe) var sent = 0
        KeyboardGesture.poster = { _ in sent += 1 }
        var start = Date()
        script?.handler(KeyboardGesture(identifier: "kb:downArrow")!)
        check(Date().timeIntervalSince(start) < 0.2, "the end is said without waiting")
        expect(said, ["bottom"], "Down on the last row says bottom")
        expect(sent, 1, "the key still went on")
        said = []
        _ = AXReplay.element(1).set(kAXSelectedRowsAttribute, [AXReplay.element(2)] as CFArray)
        start = Date()
        script?.handler(KeyboardGesture(identifier: "kb:upArrow")!)
        check(Date().timeIntervalSince(start) < 0.2, "the top is said without waiting")
        expect(said, ["top"], "Up on the first row says top")
        said = []
        script?.handler(KeyboardGesture(identifier: "kb:option+upArrow")!)
        check(said != ["top"], "with a modifier the end is not this script's to say")
        _ = AXReplay.element(1).set(kAXSelectedRowsAttribute, [AXReplay.element(3)] as CFArray)
        API.setFocusObject(ObjectFactory.make(AXReplay.element(1)), ancestors: [])
        check(script?.isAvailable?() == false, "not available with the list itself focused: its own arrows speak")
    }
    test("Finder Quick Look: an audio or video file is said by its name alone, and its window says no more") {
        let sink = Speech.sink, poster = KeyboardGesture.poster
        defer { Speech.sink = sink; KeyboardGesture.poster = poster; API.setFocusObject(nil, ancestors: []); AXReplay.unload() }
        AXReplay.load(tree(second: "Song.m4a"))
        let type = AppModuleHandler.shared.moduleType(for: "com.apple.finder")!
        let module = type.init(pid: 900_009, bundleIdentifier: "com.apple.finder", appName: "Finder")
        check(FinderAppModule.isMedia(row: AXReplay.element(3)), "an m4a is media")
        check(!FinderAppModule.isMedia(row: AXReplay.element(2)), "a name with no extension is not")
        API.setFocusObject(ObjectFactory.make(AXReplay.element(9)), ancestors: [])
        var said: [String] = []
        Speech.sink = { said.append($0) }
        KeyboardGesture.poster = { _ in _ = AXReplay.element(1).set(kAXSelectedRowsAttribute, [AXReplay.element(3)] as CFArray) }
        module.script(named: "finder_quickLookArrows")?.handler(KeyboardGesture(identifier: "kb:downArrow")!)
        expect(said, ["Song.m4a"], "the clip's name alone")
        // Events from the Quick Look window: not passed on (and the name said once when the window takes the focus).
        said = []
        var passed = 0
        module.handleEvent(Event(.valueChange, ObjectFactory.make(AXReplay.element(9)))) { passed += 1 }
        expect(passed, 0, "a window event is held back while a clip is selected")
        expect(said, [], "and nothing said")
        module.handleEvent(Event(.gainFocus, ObjectFactory.make(AXReplay.element(9)))) { passed += 1 }
        expect(module.windowAnnouncement(for: AXReplay.element(9), title: "Quick Look"), "", "Quick Look's window over a clip says nothing")
        expect(module.windowAnnouncement(for: AXReplay.element(0), title: "Docs"), nil, "another window keeps the reader's words")
        expect(module.windowAnnouncement(for: AXReplay.element(9), title: "Other"), "", "the panel is known by its subrole, not its title")
        _ = AXReplay.element(1).set(kAXSelectedRowsAttribute, [AXReplay.element(2)] as CFArray)
        expect(module.windowAnnouncement(for: AXReplay.element(9), title: "Quick Look"), "First file", "another file's name on opening")
        _ = AXReplay.element(1).set(kAXSelectedRowsAttribute, [AXReplay.element(3)] as CFArray)
        let plain = AppModule(pid: 900_010, bundleIdentifier: "com.example.plain", appName: "Plain")
        expect(plain.windowAnnouncement(for: AXReplay.element(0), title: "Docs"), nil, "the default leaves every announcement as it is")
        expect(said, [], "the window taking the focus adds nothing (its name is its announcement)")
        module.handleEvent(Event(.gainFocus, ObjectFactory.make(AXReplay.element(1)))) { passed += 1 }
        expect(passed, 1, "an event from the file list is passed on as usual")
        _ = AXReplay.element(1).set(kAXSelectedRowsAttribute, [AXReplay.element(2)] as CFArray)
        module.handleEvent(Event(.valueChange, ObjectFactory.make(AXReplay.element(9)))) { passed += 1 }
        expect(passed, 2, "with a file that is not a clip, the window's events are passed on")
    }
    test("Finder Quick Look: the end of a list is known from the selected row's place, without its rows") {
        let fixture = AXFixture(app: "Finder", bundle: "com.apple.finder", recorded: "synthetic", root: 1, application: 8, focus: nil, nodes: [
            .init(id: 1, attrs: ["AXRole": .string("AXOutline"), "AXRowCount": .number(3), "AXSelectedRows": .elements([2])]),
            .init(id: 2, attrs: ["AXRole": .string("AXRow"), "AXIndex": .number(0), "AXParent": .element(1)]),
            .init(id: 3, attrs: ["AXRole": .string("AXRow"), "AXIndex": .number(2), "AXParent": .element(1)]),
            .init(id: 4, attrs: ["AXRole": .string("AXRow"), "AXIndex": .number(1), "AXParent": .element(1)]),
            .init(id: 8, attrs: ["AXRole": .string("AXApplication")]),
        ])
        AXReplay.load(fixture)
        defer { AXReplay.unload() }
        let list = AXReplay.element(1)
        expect(FinderAppModule.listEnd(of: list, key: "upArrow", modifiers: [], selected: AXReplay.element(2))?.said, String(localized: "top", comment: "Spoken message"), "index 0 and Up: top")
        expect(FinderAppModule.listEnd(of: list, key: "downArrow", modifiers: [], selected: AXReplay.element(3))?.said, String(localized: "bottom", comment: "Spoken message"), "the last index and Down: bottom")
        check(FinderAppModule.listEnd(of: list, key: "downArrow", modifiers: [], selected: AXReplay.element(4)) == nil, "a middle row is not an end")
        check(FinderAppModule.listEnd(of: list, key: "upArrow", modifiers: [], selected: AXReplay.element(3)) == nil, "Up on the last row is not an end")
    }
    test("Finder Quick Look: when a clip's name waits") {
        check(abs((FinderAppModule.nameDelay(clipLength: 2) ?? 0) - 2.45) < 0.001, "a 2 s clip: 0.3 + 2 + 0.15")
        check(abs((FinderAppModule.nameDelay(clipLength: 5) ?? 0) - 5.45) < 0.001, "5 s is still short")
        expect(FinderAppModule.nameDelay(clipLength: 5.1), nil, "longer than 5 s: at once")
        expect(FinderAppModule.nameDelay(clipLength: nil), nil, "not known: at once")
        expect(FinderAppModule.nameDelay(clipLength: .nan), nil, "not a number: at once")
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
