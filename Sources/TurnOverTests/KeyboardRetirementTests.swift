// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreGraphics
import TurnOverCore

func keyboardRetirementTests() {
    func event(_ type: CGEventType, _ code: Int64, repeatKey: Bool = false, flags: CGEventFlags = []) -> CGEvent {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: type == .keyDown)!
        e.type = type; e.flags = flags
        e.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
        return e
    }
    test("keyboard retirement: repeated Insert can still wake without typing") {
        for code in [Int64(82), 114] {
            var r = SleepInsertRouter()
            _ = r.route(.keyDown, event: event(.keyDown, code), asleep: true, enabled: true, keypadEnabled: true, pid: 123)
            for _ in 0..<1_000 {
                let repeatResult = r.route(.keyDown, event: event(.keyDown, code, repeatKey: true), asleep: true, enabled: true, keypadEnabled: true, pid: 123)
                check(repeatResult.replay.isEmpty, "a possible wake must not type a zero")
            }
            let wake = r.route(.keyDown, event: event(.keyDown, 6, flags: .maskShift), asleep: true, enabled: true, keypadEnabled: true, pid: 123)
            expect(wake.disposition, .wake); check(wake.replay.isEmpty, "wake consumes repeats too")
            for key in [Int64(6), code] {
                expect(r.route(.keyUp, event: event(.keyUp, key), asleep: false, enabled: true, keypadEnabled: true, pid: 123).disposition, .consume)
            }
        }
    }
    test("keyboard retirement: ordinary held zero retains all repeat counts") {
        var r = SleepInsertRouter()
        _ = r.route(.keyDown, event: event(.keyDown, 82), asleep: true, enabled: true, keypadEnabled: true, pid: 123)
        for _ in 0..<1_000 {
            _ = r.route(.keyDown, event: event(.keyDown, 82, repeatKey: true), asleep: true, enabled: true, keypadEnabled: true, pid: 123)
        }
        let up = r.route(.keyUp, event: event(.keyUp, 82), asleep: true, enabled: true, keypadEnabled: true, pid: 123)
        expect(up.replay.map(\.count), [1, 1_000, 1], "bounded retained events preserve the ordinary input count")
        expect(up.replay.map { $0.event.type }, [.keyDown, .keyDown, .keyUp])
    }
    test("keyboard retirement: soft recovery retains original PID release ownership") {
        var r = SleepInsertRouter()
        _ = r.route(.keyDown, event: event(.keyDown, 82), asleep: true, enabled: true, keypadEnabled: true, pid: 123)
        let recovery = r.retire()
        expect(recovery.map { $0.pid }, [123])
        check(r.retire().isEmpty, "retirement never duplicates a down")
        let up = r.route(.keyUp, event: event(.keyUp, 82), asleep: false, enabled: false, keypadEnabled: false, pid: 456)
        expect(up.disposition, .consume); expect(up.replay.map { $0.pid }, [123])
        expect(up.replay.map { $0.event.type }, [.keyUp])
        check(r.finish().replay.isEmpty, "no outstanding down after its real release")
    }
    test("keyboard retirement: stopping completes pending and forwarded app streams once") {
        for flushFirst in [false, true] {
            var r = SleepInsertRouter()
            _ = r.route(.keyDown, event: event(.keyDown, 82), asleep: true, enabled: true, keypadEnabled: true, pid: 123)
            if flushFirst { _ = r.route(.keyDown, event: event(.keyDown, 0), asleep: true, enabled: true, keypadEnabled: true, pid: 123) }
            let end = r.finish()
            expect(end.replay.map { $0.pid }, [123,123])
            expect(end.replay.map { $0.event.type }, flushFirst ? [.keyUp,.keyUp] : [.keyDown,.keyUp])
            expect(end.releasedCodes, flushFirst ? Set<Int64>([0,82]) : [82])
            check(r.finish().replay.isEmpty, "a second teardown cannot type or release anything again")
        }
    }
    test("keyboard retirement: app stream preserves down translation without freezing unrelated modifiers") {
        var r = KeypadApplicationStream()
        let down = event(.keyDown, 76, flags: .maskControl)
        down.setIntegerValueField(.keyboardEventKeycode, value: 36); down.flags = .maskCommand
        r.recordDown(code: 76, flags: .maskControl, delivered: down)
        let repeated = event(.keyDown, 76, repeatKey: true, flags: [.maskControl,.maskShift])
        check(r.continuePress(.keyDown, event: repeated), "repeat belongs to app")
        expect(repeated.getIntegerValueField(.keyboardEventKeycode), 36)
        expect(repeated.flags, [.maskCommand,.maskShift])
        let up = event(.keyUp, 76)
        check(r.continuePress(.keyUp, event: up), "up belongs to app")
        expect(up.getIntegerValueField(.keyboardEventKeycode), 36)
        check(!r.continuePress(.keyDown, event: event(.keyDown, 76)), "next down is resolved afresh")
    }
}
