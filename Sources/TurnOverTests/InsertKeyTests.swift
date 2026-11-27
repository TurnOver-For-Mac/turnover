// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreGraphics
import TurnOverCore

func insertKeyTests() {
    test("Keyboard event clocks: normalize either live Quartz timestamp representation") {
        let ticks: UInt64 = 16_149_352_826_307
        let ns = KeyboardEventTime.nanoseconds(ticks)
        let uptime = ns + 5_183_916
        check(KeyboardEventTime.quartzNanoseconds(ticks, uptime: uptime) == ns, "Mach ticks normalize to uptime nanoseconds")
        check(KeyboardEventTime.quartzNanoseconds(ns, uptime: uptime) == ns, "nanosecond stamps stay in their domain")
        check(KeyboardEventTime.quartzTicks(ticks, uptime: uptime) == ticks, "Mach ticks stay on the gesture clock")
        let roundTrip = KeyboardEventTime.quartzTicks(ns, uptime: uptime)
        check(roundTrip == ticks || roundTrip == ticks - 1, "nanosecond conversion preserves Mach ordering within one tick")
        check(KeyboardEventTime.quartzNanoseconds(0, uptime: uptime) == 0, "unstamped synthetic events remain zero")
    }

    test("Insert proof: remember only valid physical identities") {
        func identity(_ value: String?) -> String? {
            InsertDeviceProof.identity(physicalID: value, vendor: 1, product: 2, transport: "USB")
        }
        for id in [nil, "", "  ", "0000"] as [String?] {
            check(identity(id) == nil, "missing or placeholder ID cannot transfer capability")
        }
        let first = identity("first-private-hardware-id")
        let other = identity("second-private-hardware-id")
        check(first != nil && other != nil && first != other, "distinct physical IDs remain distinct")
        var proof = InsertDeviceProof()
        _ = proof.connect(1, identity: first)
        check(proof.observe(82, connection: 1), "actual press establishes proof")
        check(!proof.observe(82, connection: 1), "repeated presses do not write preferences")
        check(!proof.observe(57, connection: 1), "an unrelated key cannot prove Insert")
        let data = proof.data ?? Data()
        check(!String(decoding: data, as: UTF8.self).contains("first-private-hardware-id"), "cache omits the raw identifier")
        var restored = InsertDeviceProof(data: data)
        _ = restored.connect(7, identity: first)
        _ = restored.connect(8, identity: other)
        _ = restored.connect(9, identity: nil)
        check(restored.keys(for: 7) == [82], "known physical ID restores proof")
        check(restored.keys(for: 8).isEmpty && restored.keys(for: 9).isEmpty, "other and unidentified devices remain unproven")
        let legacy = Data(#"{"1:2:serial:USB":[114]}"#.utf8)
        var migrated = InsertDeviceProof(data: legacy)
        _ = migrated.connect(1, identity: first)
        check(migrated.keys(for: 1).isEmpty, "legacy cache cannot provide proof")
    }

    test("Insert proof: collisions revoke cached proof without discarding live presses") {
        let id = InsertDeviceProof.identity(physicalID: "duplicate", vendor: 1, product: 2, transport: "USB")
        var proof = InsertDeviceProof()
        _ = proof.connect(1, identity: id)
        check(proof.observe(114, connection: 1), "seed prior proof")
        proof.disconnect(1)
        _ = proof.connect(2, identity: id)
        var available = InsertAvailability()
        available.connect(2)
        available.restore(proof.keys(for: 2), connection: 2)
        check(available.isAvailable(keypadCommands: false), "known device restores its separate Insert")
        available.connect(3)
        var alreadyLive = available
        alreadyLive.observePress(connection: 2, code: 114)
        let revoked = proof.connect(3, identity: id)
        check(Set(revoked) == [2, 3], "both sides of a collision lose cached proof")
        for peer in revoked {
            available.revokeRemembered(peer)
            alreadyLive.revokeRemembered(peer)
        }
        check(alreadyLive.isAvailable(keypadCommands: false), "revocation preserves a real press observed before the collision")
        check(!available.isAvailable(keypadCommands: true), "duplicate identity cannot disable Caps recovery")
        check(!proof.observe(82, connection: 3), "two overlapping services cannot reestablish remembered proof")
        available.observePress(connection: 3, code: 82)
        available.revokeRemembered(3)
        check(available.isAvailable(keypadCommands: true), "physical press continues to work on its own connection")
        check(!available.isAvailable(keypadCommands: false), "physical keypad zero still needs commands mode")
        available.disconnect(3)
        check(!available.isAvailable(keypadCommands: true), "disconnect removes live proof")
        var restarted = InsertDeviceProof(data: proof.data)
        _ = restarted.connect(4, identity: id)
        check(restarted.keys(for: 4).isEmpty, "relaunch alone does not clear a collision")
    }

    test("Insert proof: a keyboard with two services can be remembered after a fresh press") {
        let id = InsertDeviceProof.identity(physicalID: "composite", vendor: 1, product: 2, transport: "USB")
        var proof = InsertDeviceProof()
        _ = proof.connect(1, identity: id)
        check(proof.observe(114, connection: 1), "first service remembers a physical Insert press")
        check(Set(proof.connect(2, identity: id)) == [1, 2], "overlapping services revoke remembered proof")
        check(!proof.observe(82, connection: 2), "presses during overlap do not clear the block")

        proof.disconnect(1)
        check(proof.keys(for: 2).isEmpty, "removal alone cannot restore capability to the remaining service")
        check(!proof.observe(57, connection: 2), "an unrelated key cannot clear the block")
        check(proof.observe(82, connection: 2), "a fresh keypad zero press on the sole remaining service clears the block")
        check(proof.keys(for: 2) == [82], "relearning does not revive the old service's Insert proof")

        var restarted = InsertDeviceProof(data: proof.data)
        _ = restarted.connect(3, identity: id)
        check(restarted.keys(for: 3) == [82], "new single-service proof survives relaunch")
        check(Set(restarted.connect(4, identity: id)) == [3, 4], "another overlap can revoke relearned proof")
        check(restarted.keys(for: 3).isEmpty && restarted.keys(for: 4).isEmpty, "neither service inherits proof in another overlap")
    }

    test("Insert fallback: startup without known Insert hardware keeps Caps Lock available") {
        let saved = config
        defer { config = saved; KeySettings.refresh() }
        config.general.turnOverKey = "insert"
        KeySettings.refresh()
        check(KeySettings.current.capsIsTurnOver, "Caps is the fallback before hardware is proven available")
        check(!KeySettings.current.controlOptionIsTurnOver, "fallback does not capture Control Option")
        expect(config.general.turnOverKey, "insert", "fallback preserves the saved choice")
    }

    test("Insert fallback: proven keys are scoped to their connection and keypad mode") {
        var hardware = InsertAvailability()
        check(!hardware.isAvailable(keypadCommands: true), "unknown hardware keeps recovery")
        hardware.connect(1)
        check(!hardware.isAvailable(keypadCommands: true), "a descriptor alone does not prove Insert")
        hardware.observePress(connection: 1, code: 82)
        check(hardware.isAvailable(keypadCommands: true), "actual keypad press proves capability")
        check(!hardware.isAvailable(keypadCommands: false), "numbers need Caps fallback")
        hardware.connect(2); hardware.observePress(connection: 2, code: 114)
        check(hardware.isAvailable(keypadCommands: false), "separate Insert still works in numbers")
        hardware.disconnect(1)
        check(hardware.isAvailable(keypadCommands: false), "another connected Insert remains usable")
        hardware.disconnect(2)
        check(!hardware.isAvailable(keypadCommands: true), "unplug restores recovery")
        hardware.connect(2)
        check(!hardware.isAvailable(keypadCommands: true), "reconnected device starts unproven")
        hardware.observePress(connection: 99, code: 114)
        check(!hardware.isAvailable(keypadCommands: true), "late reports from removed devices are ignored")
    }
    test("Insert fallback: snapshots follow numbers and connection changes without saving a new modifier") {
        let saved = config; let devices = InsertAvailability.current.value
        defer { config = saved; InsertAvailability.current.value = devices; KeySettings.refresh() }
        config.general.turnOverKey = "insert"; config.keyboard.keypadCommands = true; KeySettings.refresh()
        var hardware = InsertAvailability(); hardware.connect(1); hardware.observePress(connection: 1, code: 82)
        InsertAvailability.current.value = hardware
        check(!KeySettings.current.capsIsTurnOver, "proven keypad restores ordinary Caps")
        config.keyboard.keypadCommands = false; KeySettings.refresh()
        check(KeySettings.current.capsIsTurnOver, "numbers activate Caps")
        config.keyboard.keypadCommands = true; KeySettings.refresh()
        check(!KeySettings.current.capsIsTurnOver, "commands restore proven keypad")
        hardware.disconnect(1); InsertAvailability.current.value = hardware
        check(KeySettings.current.capsIsTurnOver, "disconnect activates Caps without a config refresh")
        expect(config.general.turnOverKey, "insert", "choice remains Insert")
    }
    test("Insert fallback: Caps ownership survives availability changes and queued flags") {
        var s = KeySettings.current; s.insertIsTurnOver = true; s.capsIsTurnOver = true
        var caps = CapsPressState()
        check(caps.update(down: true, timestamp: 10, settings: s), "fallback owns fresh down")
        s.capsIsTurnOver = false
        check(caps.retainedFallback(settings: s), "proven Insert cannot steal held fallback")
        check(caps.update(down: false, timestamp: 20, settings: s), "release keeps ownership")
        check(!caps.retainedFallback(settings: s), "release clears modifier")
        check(!caps.capturesFlags(at: 30, settings: s), "next ordinary flags can precede their HID callback")
        check(!caps.update(down: true, timestamp: 30, settings: s), "next ordinary Caps stays ordinary")
        check(caps.capturesFlags(at: 20, settings: s), "queued old release still belongs to reader")
        s.capsIsTurnOver = true
        check(!caps.update(down: true, timestamp: 35, settings: s), "availability loss cannot capture a held ordinary press")
        check(!caps.capturesFlags(at: 30, settings: s), "ordinary flags remain application-owned")
        _ = caps.update(down: false, timestamp: 40, settings: s)
        check(caps.capturesFlags(at: 50, settings: s), "next fallback flags can precede their HID callback")
        check(caps.update(down: true, timestamp: 50, settings: s), "next fresh press becomes fallback")
        s.insertIsTurnOver = false; s.capsIsTurnOver = false
        check(!caps.retainedFallback(settings: s), "explicit selection change disables fallback")
        check(!caps.capturesFlags(at: 50, settings: s), "explicit selection change respected")
    }

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
        check(!state.isHeld, "explicit reset clears the held modifier")
        check(!state.handle(.keyUp, code: 114), "explicit reset does not retain consumed keys")
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
    test("Insert key: lost physical releases clear only the keys no longer down") {
        var state = InsertKeyState()
        state.update(enabled: true, keypadEnabled: true)
        _ = state.handle(.keyDown, code: 82)
        _ = state.handle(.keyDown, code: 114)
        state.reconcile { $0 == 114 }
        check(state.isHeld, "separate Insert remains physically down")
        state.reconcile { _ in false }
        check(!state.isHeld, "a disconnected keyboard cannot capture laptop typing")
        check(state.handle(.keyDown, code: 82, isRepeat: true), "a late repeat remains consumed")
        check(!state.isHeld, "late repeats cannot revive the modifier")
        check(state.handle(.keyUp, code: 82), "late up retains its consumed down ownership")
        check(state.handle(.keyDown, code: 114), "a genuinely fresh down starts a new press")
        check(state.isHeld, "the new press works normally")
        check(state.handle(.keyUp, code: 114), "new press release is consumed")
        check(!state.isHeld, "new press ends normally")
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
                    if snapshot.insertIsTurnOver && snapshot.controlOptionIsTurnOver {
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
    test("Insert key: timestamped physical history distinguishes queued and missing releases") {
        var history = InsertHardwareHistory()
        history.connect(1)
        history.record(connection: 1, code: 82, down: true, timestamp: 10)
        expect(history.observedDown(code: 82, at: 20, currentDown: false), nil, "missing or late HID report is uncertain")
        history.record(connection: 1, code: 82, down: false, timestamp: 30)
        expect(history.observedDown(code: 82, at: 20, currentDown: false), true, "queued chord precedes observed release")
        expect(history.observedDown(code: 82, at: 40, currentDown: false), false, "ordinary key follows observed release")
        expect(history.observedDown(code: 82, at: 5, currentDown: false), nil, "no invented state before first observation")
    }
    test("Insert key: old matching HID state is unknown after a newer Quartz press") {
        var history = InsertHardwareHistory()
        history.connect(1)
        history.record(connection: 1, code: 82, down: false, timestamp: 5)
        expect(history.observedDown(code: 82, at: 20, currentDown: false, after: 10), nil)
        var state = InsertKeyState()
        state.update(enabled: true, keypadEnabled: true)
        _ = state.handle(.keyDown, code: 82, timestamp: 10)
        state.reconcile { _ in false }
        check(!state.isHeld, "uncertain physical release cannot leave a stuck modifier")
        state.reconcile { _ in true }
        check(state.isHeld, "later history can restore eligibility for an earlier queued event")
        state.update(enabled: false, keypadEnabled: true)
        state.update(enabled: true, keypadEnabled: true)
        state.reconcile { _ in true }
        check(!state.isHeld, "settings invalidation cannot be undone by old physical history")
    }
    test("Insert key: another device's newer up cannot witness an unobserved press") {
        var history = InsertHardwareHistory()
        history.connect(1)
        history.connect(2)
        history.record(connection: 1, code: 82, down: true, timestamp: 10)
        history.record(connection: 1, code: 82, down: false, timestamp: 22)
        expect(history.observedDown(code: 82, at: 25, currentDown: false, after: 20), nil)
        history.record(connection: 2, code: 82, down: true, timestamp: 35)
        history.record(connection: 2, code: 82, down: false, timestamp: 40)
        expect(history.observedDown(code: 82, at: 25, currentDown: false, after: 20), nil, "a future down is not the missing press")
    }
    test("Insert key: physical history aggregates devices and retires connections") {
        var history = InsertHardwareHistory()
        history.connect(1)
        history.connect(2)
        history.record(connection: 1, code: 82, down: true, timestamp: 10)
        history.record(connection: 2, code: 82, down: true, timestamp: 15)
        history.record(connection: 1, code: 82, down: false, timestamp: 20)
        expect(history.observedDown(code: 82, at: 25, currentDown: true), true)
        history.disconnect(1)
        expect(history.observedDown(code: 82, at: 25, currentDown: true), true, "other keypad remains held")
        history.disconnect(2)
        expect(history.observedDown(code: 82, at: 25, currentDown: false), nil, "removal is not a fabricated timestamp")
        history.record(connection: 2, code: 82, down: true, timestamp: 30)
        expect(history.observedDown(code: 82, at: 35, currentDown: false), nil, "late report from removed generation is ignored")
        history.connect(3)
        history.record(connection: 3, code: 82, down: true, timestamp: 40)
        expect(history.observedDown(code: 82, at: 45, currentDown: true), true, "reconnection starts its own history")
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
