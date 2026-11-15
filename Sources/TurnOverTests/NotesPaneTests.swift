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

private func notesWithAttachments() -> AXFixture {
    var fixture = notesPaneFixture()
    fixture.nodes[0].attrs["AXChildren"] = .elements([6])
    fixture.nodes[6].attrs["AXFocusedUIElement"] = .element(7)
    fixture.nodes += [
        .init(id: 6, attrs: ["AXRole": .string("AXGroup"), "AXDescription": .string("attachment browser"), "AXParent": .element(0), "AXChildren": .elements([7])]),
        .init(id: 7, attrs: ["AXRole": .string("AXList"), "AXDescription": .string("image and movie attachments"), "AXParent": .element(6), "AXChildren": .elements([])])
    ]
    return fixture
}

private func notesWait(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(1.2)
    while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(condition(), "Notes' bounded view callback completed")
}

func notesViewKeyTests() {
    test("Notes view keys: announce confirmed destinations then focus, and Tab exits attachments") {
        let savedSink = Speech.sink, savedPoster = KeyboardGesture.poster
        let state = Locked(notesWithAttachments())
        let sent = Locked<[String]>([])
        var said: [String] = []
        Speech.sink = { said.append($0) }
        AXReplay.load(state.value)
        API.setFocusObject(ObjectFactory.make(AXReplay.element(9)), ancestors: [])
        let panes = Recipes.recipe(for: "com.apple.Notes")!.view.panes!
        let view = PanesView(pid: 900_009, panes: panes)
        let navigation = NotesPaneNavigation(view: view)
        KeyboardGesture.poster = { g in
            sent.value.append(g.identifier)
            onMain {
                var f = state.value
                switch g.keyName {
                case "3":
                    let showing = f.nodes[0].attrs["AXChildren"] == .elements([6])
                    f.nodes[0].attrs["AXChildren"] = .elements(showing ? [1, 2, 3] : [6])
                    f.nodes[6].attrs["AXFocusedUIElement"] = .element(showing ? 2 : 7)
                case "1", "2":
                    f.nodes[2].attrs["AXRole"] = .string(g.keyName == "1" ? "AXTable" : "AXList")
                    f.nodes[2].attrs["AXIdentifier"] = .string(g.keyName == "1" ? "ICMNoteListTableView_list" : "")
                    f.nodes[2].attrs["AXDescription"] = .string(g.keyName == "1" ? "Notes" : "Sample Notes as Gallery")
                case "0":
                    f.nodes[0].attrs["AXChildren"] = f.nodes[0].attrs["AXChildren"] == .elements([1, 2, 3]) ? .elements([2, 3]) : .elements([1, 2, 3])
                default: break
                }
                state.value = f
                AXReplay.load(f)
            }
        }
        defer { ObjectNavigator.shared.releaseHold(); API.setFocusObject(nil, ancestors: []); Speech.sink = savedSink; KeyboardGesture.poster = savedPoster; AXReplay.unload() }
        for (key, words) in [("1", "list view"), ("2", "gallery view"), ("3", "attachments browser"), ("3", "notes view"), ("0", "folders hidden"), ("0", "folders shown")] {
            said.removeAll()
            navigation.changeView(KeyboardGesture(identifier: "kb:command+\(key)")!)
            notesWait { said.count >= 2 }
            expect(said.first, words, "view name precedes the actual focused control")
            check(said.last.map { $0.contains("list") || $0.contains("table") } == true, "actual focus is read even if no focus event was posted")
        }
        expect(Array(sent.value.prefix(2)), ["kb:command+3", "kb:command+1"], "list shortcut dismisses attachments before choosing list")
        // Keep the old cached notes element alive but unreachable. Tab must dismiss attachments, not use that cache.
        _ = view.element(of: 1)
        var attachmentState = state.value
        attachmentState.nodes[0].attrs["AXChildren"] = .elements([6])
        attachmentState.nodes[6].attrs["AXFocusedUIElement"] = .element(7)
        state.value = attachmentState; AXReplay.load(attachmentState)
        API.setFocusObject(ObjectFactory.make(AXReplay.element(9)), ancestors: [])
        navigation.step(forward: true)
        notesWait { ObjectNavigator.shared.isHolding }
        expect(view.currentIndex(), 0, "Tab from attachments reaches Folders")
        ObjectNavigator.shared.leaveHold(forward: true)
        check(AXReplay.sets.contains { $0.id == 2 && $0.attribute == "AXFocused" }, "the next Tab reaches notes")
    }
    test("Notes view keys: a refused switch speaks a reason and newer navigation cancels old feedback") {
        AXReplay.load(notesPaneFixture())
        API.setFocusObject(ObjectFactory.make(AXReplay.element(9)), ancestors: [])
        let view = PanesView(pid: 900_009, panes: Recipes.recipe(for: "com.apple.Notes")!.view.panes!)
        let navigation = NotesPaneNavigation(view: view)
        let savedSink = Speech.sink, savedPoster = KeyboardGesture.poster
        var said: [String] = []
        Speech.sink = { said.append($0) }; KeyboardGesture.poster = { _ in }
        defer { API.setFocusObject(nil, ancestors: []); Speech.sink = savedSink; KeyboardGesture.poster = savedPoster; AXReplay.unload() }
        navigation.changeView(KeyboardGesture(identifier: "kb:command+1")!)
        notesWait { !said.isEmpty }
        expect(said.first, "list view: the view did not change")
        said.removeAll()
        navigation.changeView(KeyboardGesture(identifier: "kb:command+1")!)
        navigation.changeView(KeyboardGesture(identifier: "kb:command+2")!)
        notesWait { !said.isEmpty }
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        check(!said.contains { $0.contains("list view") }, "superseded callback is silent")
        expect(said.first, "gallery view")
        let type = AppModuleHandler.shared.moduleType(for: "com.apple.Notes")!
        let module = type.init(pid: 900_009, bundleIdentifier: "com.apple.Notes", appName: "Notes")
        for key in ["0", "1", "2", "3"] {
            expect(module.script(for: KeyboardGesture(identifier: "kb:command+\(key)")!)?.name, "notes_view", "view key is wired through the app module")
        }
    }
}
