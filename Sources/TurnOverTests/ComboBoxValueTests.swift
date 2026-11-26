// SPDX-License-Identifier: GPL-3.0-or-later
// An editable combo box says its new value after Up or Down (issue 323), once, and not while typing.
import Foundation
import ApplicationServices
import TurnOverCore
import AXFixtures

func comboBoxValueTests() {
    test("combo box value: Down says the new value once; typing a letter says nothing") {
        let sink = Speech.sink
        let key = InputManager.lastKeyIdentifier, at = InputManager.lastKeyDownAt
        defer { Speech.sink = sink; InputManager.lastKeyIdentifier = key; InputManager.lastKeyDownAt = at; API.setFocusObject(nil, ancestors: []); AXReplay.unload() }
        AXReplay.load(.init(app: "Word", bundle: "com.microsoft.Word", recorded: "synthetic", root: 0, application: nil, focus: 0, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXComboBox"), "AXTitle": .string("Font"), "AXValue": .string("Arial"), "AXSelectedTextRange": .string("")]),
        ]))
        let box = AXReplay.element(0)
        let obj = ObjectFactory.make(box)
        expect(obj is EditableComboBox, true, "an editable combo box: \(type(of: obj))")
        API.setFocusObject(obj, ancestors: [])
        var said: [String] = []
        Speech.sink = { said.append($0) }
        TurnOverObject.lastValueSaid = nil
        let change = { EventHandler.execute(.valueChange, on: API.focusObject!) }
        InputManager.lastKeyIdentifier = "downarrow"; InputManager.lastKeyDownAt = Date()
        _ = box.set(kAXValueAttribute, "Calibri" as CFString)
        change(); change()
        expect(said.filter { $0.contains("Calibri") }.count, 1, "Down: said once: \(said)")
        said = []
        InputManager.lastKeyIdentifier = "t"; InputManager.lastKeyDownAt = Date()
        _ = box.set(kAXValueAttribute, "Times" as CFString)
        change()
        expect(said.filter { $0.contains("Times") }.count, 0, "a typed letter: quiet: \(said)")
    }
    test("combo box value: which keys move through the list") {
        for k in ["uparrow", "downarrow", "pageup", "pagedown", "home", "end"] { expect(EditableComboBox.keyMovesThroughList(k, secondsSinceKey: 0.1), true, k) }
        expect(EditableComboBox.keyMovesThroughList("a", secondsSinceKey: 0.1), false, "a letter")
        expect(EditableComboBox.keyMovesThroughList("downarrow", secondsSinceKey: 3), false, "an old key")
    }
}
