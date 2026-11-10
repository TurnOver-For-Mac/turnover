// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

func pointerReaderTests() {
    func snap(_ role: String, _ edit: (inout PointerSnapshot) -> Void = { _ in }) -> PointerSnapshot {
        var s = PointerSnapshot()
        s.axRole = role
        s.roleDescription = String(role.dropFirst(2)).lowercased()
        edit(&s)
        return s
    }

    test("pointer reader: a button is its name and role") {
        expect(PointerReader.compose(snap("AXButton") { $0.title = "Save" }), "Save, button")
    }

    test("pointer reader: a check box says its state, not its number") {
        expect(PointerReader.compose(snap("AXCheckBox") { $0.title = "Mute"; $0.number = 1; $0.value = "1" }), "Mute, checkbox, checked")
        expect(PointerReader.compose(snap("AXCheckBox") { $0.title = "Mute"; $0.number = 0 }), "Mute, checkbox, not checked")
    }

    test("pointer reader: a static text is just its value") {
        expect(PointerReader.compose(snap("AXStaticText") { $0.value = "Hello there" }), "Hello there")
    }

    test("pointer reader: a value that only repeats the name is not said twice") {
        expect(PointerReader.compose(snap("AXHeading") { $0.title = "Discover"; $0.value = "Discover" }), "Discover, heading")
        expect(PointerReader.compose(snap("AXSlider") { $0.title = "Volume"; $0.value = "50" }), "Volume, slider, 50")
    }

    test("pointer reader: a secure field's value is never spoken") {
        let s = snap("AXTextField") { $0.subrole = "AXSecureTextField"; $0.title = "Password"; $0.value = "hunter2"; $0.roleDescription = "secure text field" }
        let said = PointerReader.compose(s)
        expect(said, "Password, secure text field")
        check(!said.contains("hunter2"), "the password is not in what is said")
    }

    test("pointer reader: a group says how many items it holds") {
        let s = snap("AXToolbar") { $0.title = "Main"; $0.isGroup = true; $0.groupItemCount = 6 }
        expect(PointerReader.compose(s), "Main, toolbar, \(Phrases.items(6))")
    }

    test("pointer reader: a group not counted in time is said without a count") {
        let s = snap("AXToolbar") { $0.title = "Main"; $0.isGroup = true; $0.groupItemCount = nil }
        expect(PointerReader.compose(s), "Main, toolbar")
    }

    test("pointer reader: nothing to say falls back to the role word") {
        expect(PointerReader.compose(snap("AXImage")), "image")
    }
}
