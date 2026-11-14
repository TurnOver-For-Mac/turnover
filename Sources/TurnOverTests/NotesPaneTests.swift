// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import AXFixtures

// Public sample content; gallery shape from the 14 November 2026 Notes log.
func notesPaneFixture(gallery: Bool = true) -> AXFixture {
    .init(app: "Notes", bundle: "com.apple.Notes", recorded: "synthetic", root: 0, application: 9, focus: 2, nodes: [
        .init(id: 0, attrs: ["AXRole": .string("AXWindow"), "AXChildren": .elements([1, 2, 3]), "AXParent": .element(9)]),
        .init(id: 1, attrs: ["AXRole": .string("AXOutline"), "AXDescription": .string("Folders"), "AXParent": .element(0), "AXRows": .elements([4]), "AXSelectedRows": .elements([4]), "AXChildren": .elements([4]), "AXReplayReadOnlyAttributes": .strings(["AXFocused"])]),
        .init(id: 2, attrs: ["AXRole": .string(gallery ? "AXList" : "AXTable"), "AXDescription": .string(gallery ? "Sample Notes as Gallery" : "Notes"), "AXIdentifier": .string(gallery ? "" : "ICMNoteListTableView_asList[sample]"), "AXParent": .element(0), "AXChildren": .elements([5]), "AXRows": .elements([5]), "AXSelectedChildren": .elements([5]), "AXSelectedRows": .elements([5])]),
        .init(id: 3, attrs: ["AXRole": .string("AXTextArea"), "AXIdentifier": .string("Note[sample]"), "AXValue": .string("Sample note"), "AXParent": .element(0)]),
        .init(id: 4, attrs: ["AXRole": .string("AXRow"), "AXTitle": .string("Sample folder"), "AXParent": .element(1)]),
        .init(id: 5, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("Sample note"), "AXParent": .element(2)], actions: ["AXPress"]),
        .init(id: 9, attrs: ["AXRole": .string("AXApplication"), "AXWindows": .elements([0]), "AXFocusedWindow": .element(0), "AXFocusedUIElement": .element(2)])
    ])
}

func notesPaneTests() {
    test("Notes panes: list and gallery cycle folders, notes and editor in both directions") {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        Recipes.load(builtIn: repo.appendingPathComponent("Resources/recipes"), plugins: [])
        let savedSink = Speech.sink
        Speech.sink = { _ in }
        defer { API.setFocusObject(nil, ancestors: []); ObjectNavigator.shared.releaseHold(); Speech.sink = savedSink; AXReplay.unload() }
        for gallery in [false, true] {
            AXReplay.load(notesPaneFixture(gallery: gallery))
            let view = PanesView(pid: 900_002, panes: Recipes.recipe(for: "com.apple.Notes")!.view.panes!)
            expect(view.element(of: 1).flatMap(AXReplay.id(of:)), 2, "the current notes representation is a pane")
            API.setFocusObject(ObjectFactory.make(AXReplay.element(2)), ancestors: [])
            view.go(to: 0)
            check(ObjectNavigator.shared.isHolding, "folders are held when AXFocused is not settable")
            expect(view.currentIndex(), 0, "held folders take priority over keyboard focus in notes")
            ObjectNavigator.shared.leaveHold(forward: true)
            check(AXReplay.sets.contains { $0.id == 2 && $0.attribute == "AXFocused" }, "Tab from held folders reaches notes")
            API.setFocusObject(ObjectFactory.make(AXReplay.element(2)), ancestors: [])
            view.step(forward: true)
            check(AXReplay.sets.contains { $0.id == 3 && $0.attribute == "AXFocused" }, "Tab reaches the open note")
            API.setFocusObject(ObjectFactory.make(AXReplay.element(3)), ancestors: [])
            view.step(forward: false)
            expect(view.currentIndex(), 2, "real focus events own the current pane")
            API.setFocusObject(ObjectFactory.make(AXReplay.element(2)), ancestors: [])
            view.step(forward: false)
            check(ObjectNavigator.shared.isHolding, "Shift Tab reaches folders")
            ObjectNavigator.shared.leaveHold(forward: false)
            check(AXReplay.sets.last?.id == 3, "Shift Tab from held folders wraps to the open note")
        }
    }
    test("Notes panes: Return on a gallery note forwards Notes' native open key") {
        AXReplay.load(notesPaneFixture())
        defer { EventHandler.drain(); API.setFocusObject(nil, ancestors: []); AXReplay.unload() }
        let savedPoster = KeyboardGesture.poster
        let sent = Locked<[String]>([])
        KeyboardGesture.poster = { g in
            sent.value.append(g.identifier)
        }
        defer { KeyboardGesture.poster = savedPoster }
        let gallery = ObjectFactory.make(AXReplay.element(2))
        API.setFocusObject(gallery, ancestors: [])
        let key = KeyboardGesture(identifier: "kb:enter")!
        gallery.script(for: key)?.handler(key)
        expect(sent.value, ["kb:enter"], "Return reaches Notes once, opening its selected note")
        expect(AXReplay.actions.map(\.id), [5], "if Notes ignores Return, the selected gallery note is pressed")
    }
}
