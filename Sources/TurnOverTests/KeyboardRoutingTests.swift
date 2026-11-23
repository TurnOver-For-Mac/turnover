// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreGraphics
import TurnOverCore

func keyboardRoutingTests() {
    test("keyboard routing A1: JAWS desktop reads the caret instead of navigating NVDA objects") {
        let saved = config
        defer { config = saved }
        config.general.keyboardStyle = "jaws"
        config.keyboard.layout = "desktop"
        for (key, expected) in [("turnover+numpad8", "run:reportCurrentLine"), ("turnover+numpad2", "run:sayAll"), ("turnover+numpad5", "run:reportCurrentWord"), ("numpad5", "run:reportCurrentCharacter")] {
            let g = KeyboardGesture(identifier: "kb:" + key)!
            expect(Keypad.action(for: g, windows: config.general.windowsKeys, jawsDesktop: true), expected, key)
        }
    }

    test("keyboard routing A1: dispatch captures JAWS actions and preserves NVDA") {
        var s = routingSettings(); s.windowsKeys = true; s.keyboardStyle = .jaws; s.desktopLayout = true
        var router = KeypadEventRouter()
        for (code, action) in [(Int64(91), "run:reportCurrentLine"), (84, "run:sayAll"), (87, "run:reportCurrentWord")] {
            let decision = router.route(.keyDown, code: code, flags: [], isRepeat: false, settings: s, modifierHeld: true)
            if case .command(let gesture, let actual) = decision {
                expect(actual, action)
                check(gesture.modifiers.contains(.turnover), "modifier reaches command")
                check(ScriptHandler.findScript(named: String(actual.dropFirst(4))) != nil, "dispatch names an existing command")
            } else { check(false, "expected JAWS command") }
            _ = router.route(.keyUp, code: code, flags: [], isRepeat: false, settings: s, modifierHeld: false)
        }
        s.keyboardStyle = .nvda
        if case .command(_, let action) = router.route(.keyDown, code: 91, flags: [], isRepeat: false, settings: s, modifierHeld: true) {
            expect(action, "run:reviewParent", "NVDA's existing object command is retained")
        } else { check(false, "expected NVDA command") }
    }
    test("keyboard routing A2: app Enter retains its release when Insert is pressed later") {
        var s = routingSettings(); s.windowsKeys = true; s.keyboardStyle = .nvda
        var router = KeypadEventRouter()
        var app: [String] = []
        for (type, held, label) in [(CGEventType.keyDown, false, "down"), (.keyDown, true, "repeat"), (.keyUp, true, "up")] {
            let d = router.route(type, code: 76, flags: [], isRepeat: label == "repeat", settings: s, modifierHeld: held)
            if case .unhandled = d { app.append(label) } else { check(false, "app-owned key was captured: \(label)") }
        }
        expect(app, ["down", "repeat", "up"], "app receives a complete pair and its repeats")
    }
    test("keyboard routing A2: consumed Enter retains its release after modifier and settings changes") {
        var s = routingSettings(); s.windowsKeys = true; s.keyboardStyle = .nvda
        var router = KeypadEventRouter()
        if case .command(_, let action) = router.route(.keyDown, code: 76, flags: [], isRepeat: false, settings: s, modifierHeld: true) {
            expect(action, "run:reviewActivate")
        } else { check(false, "command down must be owned") }
        s.keypadCommands = false
        if case .command(_, let action) = router.route(.keyDown, code: 76, flags: [], isRepeat: true, settings: s, modifierHeld: false) {
            expect(action, "run:reviewActivate", "repeat retains the original command")
        } else { check(false, "owned repeat must not become typing") }
        if case .consume = router.route(.keyUp, code: 76, flags: [], isRepeat: false, settings: s, modifierHeld: false) {} else { check(false, "owned up leaked") }
        if case .unhandled = router.route(.keyDown, code: 76, flags: [], isRepeat: false, settings: s, modifierHeld: false) {} else { check(false, "new number-mode down must pass") }
    }
    test("keyboard routing: reset retires keypad ownership after a disabled tap") {
        let s = routingSettings()
        var router = KeypadEventRouter()
        _ = router.route(.keyDown, code: 76, flags: [], isRepeat: false, settings: s, modifierHeld: true)
        router.reset()
        if case .unhandled = router.route(.keyDown, code: 76, flags: [], isRepeat: false, settings: s, modifierHeld: false) {} else {
            check(false, "a restarted tap must not reuse the old command owner")
        }
    }
    test("keyboard routing A3: Clear toggles once per press in both reader paths") {
        for modeOnly in [false, true] {
            var s = routingSettings(); s.windowsKeys = true
            var router = KeypadEventRouter(); var toggles = 0
            for (type, repeatKey) in [(CGEventType.keyDown, false), (.keyDown, true), (.keyUp, false), (.keyDown, false), (.keyUp, false)] {
                let result = router.route(type, code: 71, flags: [], isRepeat: repeatKey, settings: s, modifierHeld: false, modeOnly: modeOnly)
                if case .toggleNumbers = result { toggles += 1; s.keypadCommands.toggle() }
                else if case .consume = result {} else { check(false, "Clear event escaped") }
            }
            expect(toggles, 2); check(s.keypadCommands, "second Clear restores commands")
            if case .unhandled = router.route(.keyDown, code: 71, flags: [], isRepeat: false, settings: s, modifierHeld: false, passNext: true, modeOnly: modeOnly) {} else { check(false, "pass-next must take precedence over Clear") }
            _ = router.route(.keyUp, code: 71, flags: [], isRepeat: false, settings: s, modifierHeld: false, modeOnly: modeOnly)
            if case .unhandled = router.route(.keyDown, code: 71, flags: [], isRepeat: false, settings: s, modifierHeld: false, asleep: true, modeOnly: modeOnly) {} else { check(false, "sleep must take precedence over Clear") }
        }
    }
    test("keyboard routing A4: lone Insert is replayed as an ordinary matched pair in sleep") {
        for code in [Int64(82), 114] {
            var router = SleepInsertRouter()
            let down = keyboardEvent(.keyDown, code: code)
            expect(router.route(.keyDown, event: down, asleep: true, enabled: true, keypadEnabled: true, pid: 123).disposition, .consume)
            let up = keyboardEvent(.keyUp, code: code)
            let result = router.route(.keyUp, event: up, asleep: true, enabled: true, keypadEnabled: true, pid: 123)
            expect(result.disposition, .consume)
            expect(result.replay.map { $0.event.type }, [.keyDown, .keyUp])
            expect(result.replay.map { $0.event.getIntegerValueField(.keyboardEventKeycode) }, [code, code])
            expect(result.replay.map { $0.pid }, [123, 123])
        }
    }
    test("keyboard routing A4: wake consumes only its complete chord in either release order") {
        for order in [[Int64(6), 82], [82, 6]] {
            var router = SleepInsertRouter()
            _ = router.route(.keyDown, event: keyboardEvent(.keyDown, code: 82), asleep: true, enabled: true, keypadEnabled: true, pid: 123)
            let wake = router.route(.keyDown, event: keyboardEvent(.keyDown, code: 6, flags: .maskShift), asleep: true, enabled: true, keypadEnabled: true, pid: 123)
            expect(wake.disposition, .wake); check(wake.replay.isEmpty, "no zero typed by wake")
            for code in order {
                let up = router.route(.keyUp, event: keyboardEvent(.keyUp, code: code), asleep: false, enabled: true, keypadEnabled: true, pid: 123)
                expect(up.disposition, .consume, "waking cannot leak an owned release")
            }
            expect(router.route(.keyDown, event: keyboardEvent(.keyDown, code: 0), asleep: false, enabled: true, keypadEnabled: true, pid: 123).disposition, .pass)
        }
    }
    test("keyboard routing A4: non-wake keys and repeats preserve input order and target") {
        var router = SleepInsertRouter()
        _ = router.route(.keyDown, event: keyboardEvent(.keyDown, code: 82), asleep: true, enabled: true, keypadEnabled: true, pid: 123)
        let next = router.route(.keyDown, event: keyboardEvent(.keyDown, code: 0), asleep: true, enabled: true, keypadEnabled: true, pid: 123)
        expect(next.replay.map { $0.event.getIntegerValueField(.keyboardEventKeycode) }, [82, 0])
        for code in [Int64(0), 82] {
            expect(router.route(.keyUp, event: keyboardEvent(.keyUp, code: code), asleep: true, enabled: true, keypadEnabled: true, pid: 123).disposition, .consume)
        }
        _ = router.route(.keyDown, event: keyboardEvent(.keyDown, code: 82), asleep: true, enabled: true, keypadEnabled: true, pid: 123)
        let changed = router.route(.keyDown, event: keyboardEvent(.keyDown, code: 0), asleep: true, enabled: true, keypadEnabled: true, pid: 456)
        expect(changed.disposition, .pass); expect(changed.replay.map { $0.pid }, [123], "old zero never migrates to the new app")
    }
    test("keyboard routing A4: focus and mode changes preserve the original Insert release target") {
        for pid in [Int32(123), 456] {
            var router = SleepInsertRouter()
            _ = router.route(.keyDown, event: keyboardEvent(.keyDown, code: 82), asleep: true, enabled: true, keypadEnabled: true, pid: 123)
            let up = router.route(.keyUp, event: keyboardEvent(.keyUp, code: 82), asleep: false, enabled: false, keypadEnabled: false, pid: pid)
            expect(up.disposition, .consume)
            expect(up.replay.map { $0.event.type }, [.keyDown, .keyUp])
            expect(up.replay.map { $0.pid }, [123, 123])
        }
        var router = SleepInsertRouter()
        _ = router.route(.keyDown, event: keyboardEvent(.keyDown, code: 82), asleep: true, enabled: true, keypadEnabled: true, pid: 123)
        let repeatEvent = keyboardEvent(.keyDown, code: 82)
        repeatEvent.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        let repeated = router.route(.keyDown, event: repeatEvent, asleep: true, enabled: true, keypadEnabled: true, pid: 123)
        expect(repeated.replay.count, 0, "repeat stays pending so a delayed wake remains available")
        let up = router.route(.keyUp, event: keyboardEvent(.keyUp, code: 82), asleep: false, enabled: false, keypadEnabled: false, pid: 456)
        expect(up.disposition, .consume); expect(up.replay.map { $0.pid }, [123, 123, 123])
    }
    test("keyboard routing A5: JAWS F2 and top-row 3 precede NVDA defaults") {
        expect(VoiceOverKeyPolicy.command(style: .jaws, code: 120, modifiers: .turnover), .settings)
        expect(VoiceOverKeyPolicy.command(style: .jaws, code: 20, modifiers: .turnover), .passNext)
        expect(VoiceOverKeyPolicy.command(style: .nvda, code: 120, modifiers: .turnover), .passNext)
        expect(VoiceOverKeyPolicy.command(style: .nvda, code: 20, modifiers: .turnover), nil)
        expect(VoiceOverKeyPolicy.command(style: .jaws, code: 120, modifiers: [.turnover, .shift]), nil)
        let saved = config; defer { config = saved }
        config.general.keyboardStyle = "jaws"
        expect(ScriptHandler.findScript(for: KeyboardGesture(identifier: "kb:turnover+f2")!)?.name, "jaws_settings")
        check(ScriptHandler.findScript(for: KeyboardGesture(identifier: "kb:turnover+3")!) != nil, "JAWS pass-next alias resolves in the primary reader too")
    }
}

private func keyboardEvent(_ type: CGEventType, code: Int64, flags: CGEventFlags = []) -> CGEvent {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: type == .keyDown)!
    event.type = type; event.flags = flags
    return event
}

private func routingSettings() -> KeySettings {
    var s = KeySettings.current
    s.windowsKeys = true; s.keyboardStyle = .nvda; s.desktopLayout = true
    s.keypadCommands = true; s.insertIsTurnOver = false
    s.capsIsTurnOver = true; s.controlOptionIsTurnOver = true; s.numpadCommander = false
    return s
}
