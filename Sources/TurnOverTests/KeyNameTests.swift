// SPDX-License-Identifier: GPL-3.0-or-later
// 24 Nov 2026: input help and the command-key echo name every key in words. The number pad, the right-hand modifiers
// and the volume keys were said by the table's own names ("numpadMultiply", "rightOption").
import Foundation
import TurnOverCore

func keyNameTests() {
    test("Key names: the number pad is said in words") {
        expect(KeyNames.spoken(for: 82, characters: "0"), "numpad 0")
        expect(KeyNames.spoken(for: 87, characters: "5"), "numpad 5")
        expect(KeyNames.spoken(for: 92, characters: "9"), "numpad 9")
        expect(KeyNames.spoken(for: 65, characters: "."), "numpad decimal")
        expect(KeyNames.spoken(for: 67, characters: "*"), "numpad multiply")
        expect(KeyNames.spoken(for: 75, characters: "/"), "numpad divide")
        expect(KeyNames.spoken(for: 69, characters: "+"), "numpad plus")
        expect(KeyNames.spoken(for: 78, characters: "-"), "numpad minus")
        expect(KeyNames.spoken(for: 81, characters: "="), "numpad equals")
        expect(KeyNames.spoken(for: 71, characters: ""), "numpad clear")
        expect(KeyNames.spoken(for: 76, characters: "\r"), "numpad enter", "unchanged")
    }
    test("Key names: the right-hand modifiers and the volume keys are said in words") {
        expect(KeyNames.spoken(for: 54, characters: ""), "right command")
        expect(KeyNames.spoken(for: 60, characters: ""), "right shift")
        expect(KeyNames.spoken(for: 61, characters: ""), "right option")
        expect(KeyNames.spoken(for: 62, characters: ""), "right control")
        expect(KeyNames.spoken(for: 72, characters: ""), "volume up")
        expect(KeyNames.spoken(for: 73, characters: ""), "volume down")
        expect(KeyNames.spoken(for: 74, characters: ""), "mute")
    }
    test("Key names: the keys that were already words keep them") {
        expect(KeyNames.spoken(for: 0, characters: "a"), "a")
        expect(KeyNames.spoken(for: 18, characters: "1"), "1")
        expect(KeyNames.spoken(for: 96, characters: ""), "F5")
        expect(KeyNames.spoken(for: 126, characters: ""), "up arrow")
        expect(KeyNames.spoken(for: 36, characters: "\r"), "enter")
        expect(KeyNames.spoken(for: 44, characters: "/"), "slash")
    }
    test("Key names: a key named in a binding is still found by the table's name") {
        expect(KeyNames.code(for: "numpadMultiply"), 67)
        expect(KeyNames.code(for: "rightOption"), 61)
        expect(KeyNames.name(for: 87), "numpad5")
    }
}
