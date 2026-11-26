// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore
import AXFixtures

func systemPromptReminderTests() {
    test("system prompts: plain action keys reach the frontmost protected agent in both keyboard styles") {
        let savedFocus = API.focusObject, savedAncestors = API.focusAncestors, savedPage = API.focusTreeInterceptor
        let savedStyle = config.general.keyboardStyle
        let savedPluginTypes = GlobalPluginHandler.shared.plugins.map { type(of: $0) }
        let ordinaryBundle = "com.apple.TextEdit"
        let protectedBundle = "com.apple.UserNotificationCenter"
        AXReplay.load(.init(app: "Save sheet", bundle: ordinaryBundle, recorded: "synthetic", root: 1, application: nil,
                            focus: 2, nodes: [
            .init(id: 1, attrs: ["AXRole": .string("AXSheet"), "AXDefaultButton": .element(3)]),
            .init(id: 2, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("Cancel"), "AXParent": .element(1),
                                 "AXFocused": .bool(true)], actions: ["AXPress"]),
            .init(id: 3, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("Save"), "AXParent": .element(1)],
                  actions: ["AXPress"])
        ]))
        GlobalPluginHandler.shared.terminateAll()
        GlobalPluginHandler.shared.register(SettingsPanePlugin.self)
        GlobalPluginHandler.shared.register(VoiceOverKeysPlugin.self)
        defer {
            config.general.keyboardStyle = savedStyle
            GlobalPluginHandler.shared.terminateAll()
            for pluginType in savedPluginTypes { GlobalPluginHandler.shared.register(pluginType) }
            API.setFocusObject(savedFocus, ancestors: savedAncestors, interceptor: savedPage)
            AXReplay.unload()
        }
        @MainActor
        func command(_ key: String, front bundle: String) -> String? {
            ScriptHandler.findScript(for: KeyboardGesture(identifier: "kb:" + key)!) { bundle }?.name
        }
        for style in ["mac", "windows"] {
            config.general.keyboardStyle = style
            API.setFocusObject(ObjectFactory.make(AXReplay.element(2)), ancestors: [])
            for key in ["enter", "numpadEnter"] {
                expect(command(key, front: ordinaryBundle), "dialog_pressFocused", "\(style): ordinary Return override is available")
                check(command(key, front: protectedBundle) == nil, "\(style): the foreground prompt owns \(key)")
            }
            API.setFocusObject(Dialog(element: AXReplay.element(1)), ancestors: [])
            for (key, script) in [("space", "dialog_press"), ("escape", "dialog_cancel")] {
                expect(command(key, front: ordinaryBundle), script, "\(style): ordinary dialog keeps \(key)")
                check(command(key, front: protectedBundle) == nil, "\(style): the foreground prompt owns \(key)")
            }
        }
        config.general.keyboardStyle = "mac"
        let readerCommand = command("turnover+space", front: ordinaryBundle)
        check(readerCommand != nil, "VO-Space resolves as an explicit reader command")
        expect(command("turnover+space", front: protectedBundle), readerCommand, "VO-Space stays available in the prompt")
    }

    test("system prompts: repeated application switches allow only two reminders five minutes apart") {
        var reminders = SystemPromptReminders<Int>(isSame: ==)
        let prompts: [(window: Int, pid: pid_t)] = [(1, 10)]
        check(reminders.next(in: prompts, activated: 10, now: 0) == nil, "activating the dialog's agent does not spend a reminder")
        check(reminders.next(in: prompts, activated: 20, now: 10) == 0, "first switch away reminds immediately")
        for time in [11.0, 16, 100, 309.999] {
            check(reminders.next(in: prompts, activated: 20, now: time) == nil, "switches before five minutes stay quiet")
        }
        check(reminders.next(in: prompts, activated: 10, now: 310) == nil, "returning to the dialog does not spend the second reminder")
        check(reminders.next(in: prompts, activated: 20, now: 310) == 0, "second reminder is eligible exactly five minutes after the first")
        for time in [311.0, 610, 10_000] {
            check(reminders.next(in: prompts, activated: 20, now: time) == nil, "there is never a third reminder")
        }
    }

    test("system prompts: each dialog has its own reminders even under the same agent") {
        var reminders = SystemPromptReminders<Int>(isSame: ==)
        let prompts: [(window: Int, pid: pid_t)] = [(1, 10), (2, 10), (3, 30)]
        check(reminders.next(in: prompts, activated: 20, now: 0) == 0, "first dialog reminds")
        check(reminders.next(in: prompts, activated: 20, now: 1) == 1, "waiting first dialog does not hide a second dialog from the same agent")
        check(reminders.next(in: prompts, activated: 10, now: 2) == 2, "dialogs owned by the activated agent are skipped")
        check(reminders.next(in: prompts, activated: 20, now: 300) == 0, "first dialog gets its second reminder")
        check(reminders.next(in: prompts, activated: 20, now: 300) == nil, "other dialogs keep their own deadlines")
        check(reminders.next(in: prompts, activated: 20, now: 301) == 1, "second dialog gets its second reminder")
        check(reminders.next(in: prompts, activated: 20, now: 302) == 2, "third dialog gets its second reminder")
        check(reminders.next(in: prompts, activated: 20, now: 900) == nil, "all dialogs have exhausted their reminders")
    }

    test("system prompts: reannouncing preserves history and only closing resets it") {
        var reminders = SystemPromptReminders<Int>(isSame: ==)
        let prompts: [(window: Int, pid: pid_t)] = [(1, 10), (2, 20)]
        check(reminders.next(in: prompts, activated: 30, now: 0) == 0, "first dialog reminds")
        check(reminders.next(in: prompts, activated: 30, now: 1) == 1, "second dialog reminds")
        reminders.retainOpen([1, 2])
        // Reannouncing replaces/reorders summaries, but must not create a new dialog lifetime.
        check(reminders.next(in: Array(prompts.reversed()), activated: 30, now: 2) == nil, "a reordered summary retains both histories")
        reminders.retainOpen([2])
        check(reminders.next(in: [prompts[1]], activated: 30, now: 3) == nil, "closing one dialog preserves the other's history")
        check(reminders.next(in: prompts, activated: 30, now: 4) == 0, "a dialog observed closed can remind again if reopened")
        reminders.retainOpen([])
        check(reminders.next(in: [prompts[1]], activated: 30, now: 5) == 0, "closing all dialogs clears the remaining history")
    }

    let crash = ["Example quit unexpectedly.", "Click Reopen to open it again."]

    test("system prompts: a lock-hidden prompt returns quietly with both reminders still spent") {
        var prompts = SystemPromptContinuity()
        let first = prompts.appear(pid: 10, lines: crash, now: 0)
        check(first.quietUntil == nil, "the initial prompt is read")
        expect(prompts.nextReminder(in: [(first.id, 10)], activated: 20, now: 0), 0, "first reminder")
        expect(prompts.nextReminder(in: [(first.id, 10)], activated: 20, now: 300), 0, "second reminder")
        prompts.observeLock(true, now: 310)
        prompts.park(id: first.id, pid: 10, lines: crash, now: 311)
        check(!prompts.discardExpired(open: [], now: 600), "a locked prompt has not closed")
        prompts.observeLock(false, now: 620)
        check(!prompts.discardExpired(open: [], now: 621), "unlock gives the prompt time to return")
        let returned = prompts.appear(pid: 10, lines: crash, now: 622)
        expect(returned.id, first.id, "the returned prompt keeps its identity")
        expect(returned.quietUntil, 650, "the returned prompt is not announced")
        check(prompts.nextReminder(in: [(returned.id, 10)], activated: 20, now: 950) == nil, "there is no third reminder")
    }

    test("system prompts: a lock half a second after disappearance still preserves the reminder deadline") {
        var prompts = SystemPromptContinuity()
        let first = prompts.appear(pid: 10, lines: crash, now: 0)
        expect(prompts.nextReminder(in: [(first.id, 10)], activated: 20, now: 10), 0, "first reminder")
        prompts.park(id: first.id, pid: 10, lines: crash, now: 20)
        check(!prompts.discardExpired(open: [], now: 20), "the first missing poll cannot decide why it disappeared")
        prompts.observeLock(true, now: 20.5)
        prompts.observeLock(false, now: 30)
        let returned = prompts.appear(pid: 10, lines: crash, now: 31)
        expect(returned.id, first.id, "the lock explains the earlier disappearance")
        check(returned.quietUntil != nil, "the returned prompt is quiet")
        check(prompts.nextReminder(in: [(returned.id, 10)], activated: 20, now: 309.9) == nil, "the original deadline still applies")
        expect(prompts.nextReminder(in: [(returned.id, 10)], activated: 20, now: 310), 0, "the second reminder is still due")
    }

    test("system prompts: an ordinary close lets a later prompt with the same words be read") {
        for returnTime in [4.0, 15] {
            var prompts = SystemPromptContinuity()
            let first = prompts.appear(pid: 10, lines: crash, now: 0)
            expect(prompts.nextReminder(in: [(first.id, 10)], activated: 20, now: 0), 0, "the old prompt used a reminder")
            prompts.park(id: first.id, pid: 10, lines: crash, now: 1)
            expect(prompts.discardExpired(open: [], now: returnTime), returnTime > 11, "the close is settled after ten seconds")
            let reopened = prompts.appear(pid: 10, lines: crash, now: returnTime)
            check(reopened.id != first.id && reopened.quietUntil == nil, "the prompt is read again even during the lock wait")
            expect(prompts.nextReminder(in: [(reopened.id, 10)], activated: 20, now: returnTime), 0, "the new prompt gets its own reminder")
        }
    }

    test("system prompts: a lock thirty seconds after disappearance cannot revive the old prompt") {
        var prompts = SystemPromptContinuity()
        let first = prompts.appear(pid: 10, lines: crash, now: 0)
        prompts.park(id: first.id, pid: 10, lines: crash, now: 1)
        prompts.observeLock(true, now: 31)
        prompts.observeLock(false, now: 40)
        let returned = prompts.appear(pid: 10, lines: crash, now: 41)
        check(returned.id != first.id && returned.quietUntil == nil, "a delayed poll cannot turn a late lock into a match")
    }

    test("system prompts: a different process or changed lines after unlock are read") {
        var prompts = SystemPromptContinuity()
        let first = prompts.appear(pid: 10, lines: crash, now: 0)
        prompts.observeLock(true, now: 1)
        prompts.park(id: first.id, pid: 10, lines: crash, now: 2)
        prompts.observeLock(false, now: 10)
        let changed = prompts.appear(pid: 10, lines: [crash[0], "Click OK."], now: 11)
        check(changed.id != first.id && changed.quietUntil == nil, "matching the first line alone is insufficient")
        let otherAgent = prompts.appear(pid: 11, lines: crash, now: 12)
        check(otherAgent.id != first.id && otherAgent.quietUntil == nil, "matching words in a different process are insufficient")
    }

    test("system prompts: a prompt that returns two minutes after unlock is read") {
        var prompts = SystemPromptContinuity()
        let first = prompts.appear(pid: 10, lines: crash, now: 0)
        prompts.observeLock(true, now: 1)
        prompts.park(id: first.id, pid: 10, lines: crash, now: 2)
        prompts.observeLock(false, now: 10)
        let late = prompts.appear(pid: 10, lines: crash, now: 130)
        check(late.id != first.id && late.quietUntil == nil, "the deadline applies even before the next clean-up")
    }

    test("system prompts: two parked prompts from the same process keep separate histories") {
        var prompts = SystemPromptContinuity()
        let other = ["Example needs permission."]
        let first = prompts.appear(pid: 10, lines: crash, now: 0)
        let second = prompts.appear(pid: 10, lines: other, now: 0)
        expect(prompts.nextReminder(in: [(first.id, 10)], activated: 20, now: 0), 0, "only the first has reminded")
        prompts.observeLock(true, now: 1)
        prompts.park(id: first.id, pid: 10, lines: crash, now: 2)
        prompts.park(id: second.id, pid: 10, lines: other, now: 2)
        prompts.observeLock(false, now: 10)
        let secondBack = prompts.appear(pid: 10, lines: other, now: 11)
        let firstBack = prompts.appear(pid: 10, lines: crash, now: 11)
        expect(secondBack.id, second.id, "the second prompt can return first")
        expect(firstBack.id, first.id, "the first prompt also keeps its identity")
        check(secondBack.quietUntil != nil && firstBack.quietUntil != nil, "both prompts return quietly")
        expect(prompts.nextReminder(in: [(firstBack.id, 10), (secondBack.id, 10)], activated: 20, now: 12), 1,
               "only the second prompt has an immediate reminder left")
    }

    test("system prompts: locked switches do not speak or spend a reminder") {
        var prompts = SystemPromptContinuity()
        let first = prompts.appear(pid: 10, lines: crash, now: 0)
        prompts.observeLock(true, now: 1)
        check(prompts.nextReminder(in: [(first.id, 10)], activated: 20, now: 2) == nil, "still listed but locked")
        prompts.observeLock(false, now: 3)
        expect(prompts.nextReminder(in: [(first.id, 10)], activated: 20, now: 4), 0, "the unlocked switch gets the first reminder")
    }

    test("system prompts: missing and ambiguous identities are read after the unlock") {
        var prompts = SystemPromptContinuity()
        let first = prompts.appear(pid: 10, lines: crash, now: 0)
        let second = prompts.appear(pid: 10, lines: crash, now: 0)
        let unreadable = prompts.appear(pid: 11, lines: nil, now: 0)
        prompts.observeLock(true, now: 1)
        prompts.park(id: first.id, pid: 10, lines: crash, now: 2)
        prompts.park(id: second.id, pid: 10, lines: crash, now: 2)
        prompts.park(id: unreadable.id, pid: 11, lines: nil, now: 2)
        prompts.observeLock(false, now: 3)
        check(prompts.appear(pid: 10, lines: crash, now: 4).quietUntil == nil, "two equal parked prompts are ambiguous")
        check(prompts.appear(pid: 11, lines: nil, now: 4).quietUntil == nil, "an unsafe or unreadable prompt cannot match")
    }

    // 26 Nov 2026: Return on Ignore in a crash dialog pressed Report…, the default button, eleven times running.
    test("system prompts: Return goes on as Space only from a button that is not the default") {
        check(SystemPrompts.returnGoesAsSpace(role: "AXButton", isDefault: false), "a button that is not the default")
        check(SystemPrompts.returnGoesAsSpace(role: "AXButton", isDefault: nil), "a window that names no default button")
        check(!SystemPrompts.returnGoesAsSpace(role: "AXButton", isDefault: true), "the default button keeps Return")
        for role in ["AXTextField", "AXSecureTextField", "AXCheckBox", "AXPopUpButton", "AXRadioButton", "AXStaticText", "?", ""] {
            check(!SystemPrompts.returnGoesAsSpace(role: role, isDefault: false), "\(role) keeps Return")
            check(!SystemPrompts.returnGoesAsSpace(role: role, isDefault: nil), "\(role) keeps Return when no default is named")
        }
    }

    test("system prompts: a key that went on as another key drops its repeats until a fresh key") {
        var keys = ReplacedKeyRepeats()
        check(!keys.dropsRepeat(of: 36), "nothing replaced yet")
        keys.pressed(36, replaced: true)
        check(keys.dropsRepeat(of: 36), "the replaced key's repeat is dropped")
        check(!keys.dropsRepeat(of: 49), "another key's repeat is not")
        keys.pressed(48, replaced: false)
        check(!keys.dropsRepeat(of: 36), "a fresh key ends it")
        keys.pressed(36, replaced: true)
        keys.pressed(36, replaced: false)
        check(!keys.dropsRepeat(of: 36), "the same key pressed afresh and not replaced repeats as usual")
    }

    test("system prompts: a key that goes on as another key reaches the key tap as that key, once") {
        let saved = InputManager.keyGoesOnAs
        defer { InputManager.keyGoesOnAs = saved }
        ScriptHandler.resetOrderedLane()
        // An unbound key stands in for Return on a prompt's button: the rule itself is tested above.
        let pressed = KeyboardGesture(identifier: "kb:control+option+shift+f15")!
        let held = KeyboardGesture(keyCode: pressed.keyCode, modifiers: pressed.modifiers, characters: "", timestamp: 0,
                                   isRepeat: true, flags: pressed.flags)
        let space = KeyboardGesture(keyCode: 49, modifiers: [], characters: " ", timestamp: 0, isRepeat: false, flags: [])
        let answer = Locked<ScriptHandler.KeyDecision?>(nil)
        func ask(_ key: KeyboardGesture) -> ScriptHandler.KeyDecision? {
            answer.value = nil
            Thread { answer.value = ScriptHandler.askMain(key) }.start()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            return answer.value
        }
        InputManager.keyGoesOnAs = { $0.keyCode == pressed.keyCode ? space : nil }
        expect(ask(pressed), .passedAs(49), "the key tap is told which key to make it")
        expect(ask(held), .taken, "held down, its repeats go nowhere")
        expect(ask(held), .taken, "however many")
        // A fresh press that goes on as itself ends it.
        InputManager.keyGoesOnAs = { _ in nil }
        expect(ask(pressed), .passed, "a key the rule leaves alone goes on as itself")
        expect(ask(held), .passed, "and its repeats go on with it")
        check(InputManager.sentOnAs == nil, "nothing is left over for the next key")
    }
}
