// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreGraphics
import TurnOverCore

func insertKeyTests() {
    test("Insert key: persisted selection does not also capture Caps Lock or Control Option") {
        let data = Data(#"{"general":{"bosunKey":"insert"},"keyboard":{"layout":"desktop"}}"#.utf8)
        let settings = try JSONDecoder().decode(Config.self, from: data)
        check(!settings.general.capsIsTurnOver, "Insert leaves Caps Lock available to the system")
        check(!settings.general.controlOptionIsTurnOver, "Insert leaves Control Option available to the system")
        expect(settings.general.turnOverKeyName, "insert", "shortcut help names the selected modifier")
        let restored = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(settings))
        expect(restored.general.turnOverKey, "insert", "selection survives saving and loading")
    }

    test("Insert key: number-pad zero holds the modifier for JAWS letters and function keys") {
        let saved = config
        defer { config = saved; KeySettings.refresh() }
        config.general.keyboardStyle = "jaws"
        config.general.turnOverKey = "insert"
        config.keyboard.layout = "desktop"
        KeySettings.refresh()
        check(KeySettings.current.insertIsTurnOver, "keyboard snapshot enables Insert")
        var state = InsertKeyState()
        state.update(enabled: KeySettings.current.insertIsTurnOver, keypadEnabled: true)
        check(state.handle(.keyDown, code: 82), "zero down is consumed")
        let settings = KeyboardGesture(keyCode: 120, modifiers: state.addingModifier(to: []), characters: "", timestamp: 0, isRepeat: false, flags: [])
        expect(ScriptHandler.findScript(for: settings)?.name, "jaws_settings", "zero plus F2 reaches the JAWS command")
        let word = KeyboardGesture(keyCode: 38, modifiers: state.addingModifier(to: []), characters: "j", timestamp: 0, isRepeat: false, flags: [])
        expect(ScriptHandler.findScript(for: word)?.name, "jaws_sayPriorWord", "zero plus J reaches the JAWS command")
        check(!state.handle(.keyUp, code: 120), "another key's release cannot release Insert")
        check(state.isHeld, "Insert stays held across chords")
        check(state.handle(.keyUp, code: 82), "zero up is consumed")
        expect(state.addingModifier(to: .shift), .shift, "following typing has no Insert modifier")
    }
    test("Insert key: repeats do not toggle the modifier or manufacture a press") {
        var state = InsertKeyState()
        state.update(enabled: true, keypadEnabled: true)
        check(!state.handle(.keyDown, code: 82, isRepeat: true), "a key held before enabling Insert stays ordinary")
        check(!state.isHeld, "no modifier from an unowned repeat")
        check(state.handle(.keyDown, code: 82), "fresh down is captured")
        check(state.handle(.keyDown, code: 82, isRepeat: true), "owned repeat is consumed")
        check(state.isHeld, "repeat does not release the modifier")
        expect(state.addingModifier(to: [.control, .shift]), [.turnover, .control, .shift], "other modifiers are preserved")
    }
    test("Insert key: changing settings releases the modifier but consumes its paired key up") {
        var state = InsertKeyState()
        state.update(enabled: true, keypadEnabled: true)
        _ = state.handle(.keyDown, code: 82)
        state.update(enabled: false, keypadEnabled: true)
        check(!state.isHeld, "switching to Caps Lock releases Insert immediately")
        check(state.handle(.keyUp, code: 82), "no unmatched release reaches an app")
        check(!state.handle(.keyDown, code: 82), "the next zero is ordinary")
        check(!state.handle(.keyUp, code: 82), "its ordinary release also passes")
    }
    test("Insert key: keypad numbers and pass-through do not leave a held modifier") {
        var state = InsertKeyState()
        state.update(enabled: true, keypadEnabled: true)
        _ = state.handle(.keyDown, code: 82)
        state.update(enabled: true, keypadEnabled: false)
        check(!state.isHeld, "Clear switching to numbers removes the modifier")
        check(state.handle(.keyUp, code: 82), "release of consumed down stays consumed")
        check(!state.handle(.keyDown, code: 82), "zero types when keypad commands are off")
        check(state.handle(.keyDown, code: 114), "a separate Insert still works in number mode")
        state.reset()
        check(!state.isHeld, "tap bypass or stop clears the held modifier")
        check(!state.handle(.keyUp, code: 114), "bypass does not retain consumed keys")
        state.update(enabled: false, keypadEnabled: true)
        check(!state.handle(.keyDown, code: 82), "pass-next-key allows the real zero through")
    }
    test("Insert key: separate Insert and zero can be held independently") {
        var state = InsertKeyState()
        state.update(enabled: true, keypadEnabled: true)
        _ = state.handle(.keyDown, code: 82)
        _ = state.handle(.keyDown, code: 114)
        _ = state.handle(.keyUp, code: 82)
        check(state.isHeld, "releasing zero does not release the separate Insert")
        _ = state.handle(.keyUp, code: 114)
        check(!state.isHeld, "both released ends the chord")
        check(!state.handle(.flagsChanged, code: 57), "Caps Lock does not enter the Insert state")
        check(!state.handle(.keyDown, code: 29), "main keyboard zero is ordinary")
    }
    test("Insert key: concurrent keyboard readers see a complete settings snapshot") {
        let saved = config
        defer { config = saved; KeySettings.refresh() }
        config.general.turnOverKey = "both"
        KeySettings.refresh()
        let invalid = Locked(false)
        let readers = DispatchGroup()
        for _ in 0..<4 {
            readers.enter()
            DispatchQueue.global().async {
                defer { readers.leave() }
                for _ in 0..<10_000 {
                    let snapshot = KeySettings.current
                    if snapshot.insertIsTurnOver && (snapshot.capsIsTurnOver || snapshot.controlOptionIsTurnOver) {
                        invalid.value = true
                    }
                    if !snapshot.insertIsTurnOver && !snapshot.capsIsTurnOver && !snapshot.controlOptionIsTurnOver {
                        invalid.value = true
                    }
                }
            }
        }
        for index in 0..<2_000 {
            config.general.turnOverKey = index.isMultiple(of: 2) ? "insert" : "both"
            KeySettings.refresh()
        }
        readers.wait()
        check(!invalid.value, "readers never see a partially updated modifier choice")
    }
    test("Insert key: existing modifier choices retain their behaviour") {
        for (choice, caps, vo) in [("both", true, true), ("caps", true, false), ("controlOption", false, true)] {
            var general = Config.General()
            general.turnOverKey = choice
            expect(general.capsIsTurnOver, caps, choice)
            expect(general.controlOptionIsTurnOver, vo, choice)
            check(!general.insertIsTurnOver, "Insert is opt-in for \(choice)")
        }
    }
}
