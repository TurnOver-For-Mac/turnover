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

    // A review, 26 Nov 2026: a prompt that was slow to answer was treated as a prompt with nothing in focus, and Return
    // went on to press the default button whatever was in hand.
    test("system prompts: a prompt that does not say where its focus is gets no Return, then Return as it is") {
        typealias P = SystemPrompts
        for before in [false, true] {
            expect(P.returnGoes(from: .control(role: "AXButton", isDefault: false), unansweredJustBefore: before), .asSpace,
                   "a button that is not the default takes Space")
            expect(P.returnGoes(from: .control(role: "AXButton", isDefault: nil), unansweredJustBefore: before), .asSpace,
                   "so does a button in a window that names no default")
            expect(P.returnGoes(from: .control(role: "AXButton", isDefault: true), unansweredJustBefore: before), .asItIs,
                   "the default button keeps Return")
            expect(P.returnGoes(from: .control(role: "AXSecureTextField", isDefault: nil), unansweredJustBefore: before), .asItIs,
                   "a password field keeps Return")
            expect(P.returnGoes(from: .nothing, unansweredJustBefore: before), .asItIs, "a prompt with no focus keeps Return")
        }
        expect(P.returnGoes(from: .unanswered, unansweredJustBefore: false), .nowhere,
               "the first Return to a prompt that does not answer is not sent")
        expect(P.returnGoes(from: .unanswered, unansweredJustBefore: true), .asItIs,
               "the second goes on as it is, so the prompt can always be answered")
    }

    // A review, 26 Nov 2026: Return held on a default button pressed the default button of each prompt queued behind it.
    test("system prompts: a held Return presses one button") {
        typealias P = SystemPrompts
        let agents = ["com.apple.LocalAuthentication.UIAgent", "com.apple.SecurityAgent", "com.apple.UserNotificationCenter",
                      "com.apple.CoreLocationAgent", "com.apple.coreservices.uiagent"]
        for agent in agents {
            check(P.dropsHeldReturn(keyCode: 36, isRepeat: true, plain: true, frontBundle: agent), "Return held in \(agent)")
            check(P.dropsHeldReturn(keyCode: 76, isRepeat: true, plain: true, frontBundle: agent), "numpad Enter held in \(agent)")
        }
        let agent = "com.apple.UserNotificationCenter"
        check(!P.dropsHeldReturn(keyCode: 36, isRepeat: false, plain: true, frontBundle: agent), "the press itself goes on")
        check(!P.dropsHeldReturn(keyCode: 36, isRepeat: true, plain: false, frontBundle: agent), "with a modifier it is another key")
        check(!P.dropsHeldReturn(keyCode: 49, isRepeat: true, plain: true, frontBundle: agent), "Space repeats as usual")
        check(!P.dropsHeldReturn(keyCode: 48, isRepeat: true, plain: true, frontBundle: agent), "Tab repeats as usual")
        check(!P.dropsHeldReturn(keyCode: 36, isRepeat: true, plain: true, frontBundle: "com.apple.TextEdit"),
              "Return held in an ordinary application repeats as usual")
        check(!P.dropsHeldReturn(keyCode: 36, isRepeat: true, plain: true, frontBundle: ""), "no application in front")
    }

    // A review, 26 Nov 2026: Shift with numpad Enter, a stopped main thread and a restarted tap each left Space held
    // down in the application, because the record of the key was asked too late or thrown away.
    test("keys sent as others: the repeats are dropped and the release goes as the other key") {
        var keys = KeysSentAsOthers()
        check(keys.isEmpty, "nothing yet")
        expect(keys.step(code: 36, down: true, isRepeat: false), .asItIs, "a key that went as itself")
        expect(keys.step(code: 36, down: false, isRepeat: false), .asItIs, "and its release")
        keys.wentDown(36, as: 49)
        check(!keys.isEmpty, "Return is down as Space")
        expect(keys.step(code: 36, down: true, isRepeat: true), .dropped, "its repeat goes nowhere")
        expect(keys.step(code: 36, down: true, isRepeat: true), .dropped, "however many")
        expect(keys.step(code: 48, down: true, isRepeat: false), .asItIs, "another key pressed meanwhile is not touched")
        expect(keys.step(code: 48, down: false, isRepeat: false), .asItIs, "nor its release")
        expect(keys.step(code: 36, down: true, isRepeat: true), .dropped, "and the held key still repeats nowhere")
        expect(keys.step(code: 36, down: false, isRepeat: false), .releasedAs(49), "the release is Space's release")
        check(keys.isEmpty, "nothing is left over")
        expect(keys.step(code: 36, down: true, isRepeat: false), .asItIs, "the next press is its own")
        expect(keys.step(code: 36, down: true, isRepeat: true), .asItIs, "and repeats as usual")
        expect(keys.step(code: 36, down: false, isRepeat: false), .asItIs, "and is released as itself")
    }

    test("keys sent as others: a release that was never seen is made up for") {
        var keys = KeysSentAsOthers()
        keys.wentDown(76, as: 49)
        expect(keys.step(code: 76, down: true, isRepeat: false), .pressedAgain(owed: 49),
               "pressed afresh, the key it went down as is owed its release")
        check(keys.isEmpty, "and the fresh press is its own")
        expect(keys.step(code: 76, down: false, isRepeat: false), .asItIs, "so its release is not rewritten")

        // The tap was off for a while: the keys no longer held are forgotten, each owed its release.
        keys.wentDown(36, as: 49)
        keys.wentDown(76, as: 53)
        expect(keys.forget(where: { $0 == 36 }), [49], "Return was let go while the tap was off")
        expect(keys.step(code: 76, down: false, isRepeat: false), .releasedAs(53), "numpad Enter is still held and ends as usual")
        check(keys.isEmpty, "nothing is left over")
        keys.wentDown(36, as: 49)
        expect(keys.forget(where: { _ in false }), [], "a key still held is kept")
        expect(keys.step(code: 36, down: true, isRepeat: true), .dropped, "and still repeats nowhere")
        expect(keys.forget(where: { _ in true }), [49], "let go, it is forgotten")
        check(keys.isEmpty, "the record is empty again")
    }

    // An unbound key stands in for Return on a prompt's button: the rule itself is tested above.
    let standIn = KeyboardGesture(identifier: "kb:control+option+shift+f15")!
    let standInHeld = KeyboardGesture(keyCode: standIn.keyCode, modifiers: standIn.modifiers, characters: "", timestamp: 0,
                                      isRepeat: true, flags: standIn.flags)
    let space = KeyboardGesture(keyCode: 49, modifiers: [], characters: " ", timestamp: 0, isRepeat: false, flags: [])

    test("system prompts: the key tap is told how a key goes on: as another key, as itself or nowhere") {
        let saved = InputManager.keyGoesOnAs
        defer { InputManager.keyGoesOnAs = saved }
        ScriptHandler.resetOrderedLane()
        let answer = Locked<ScriptHandler.KeyDecision?>(nil)
        func ask(_ key: KeyboardGesture) -> ScriptHandler.KeyDecision? {
            answer.value = nil
            Thread { answer.value = ScriptHandler.askMain(key) }.start()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            return answer.value
        }
        InputManager.keyGoesOnAs = { $0.keyCode == standIn.keyCode && !$0.isRepeat ? .asAnother(space) : .asItIs }
        expect(ask(standIn), .passedAs(49), "the key tap is told which key to make it")
        // The keyboard thread drops the repeats of that key itself (KeysSentAsOthers); nothing is remembered here.
        expect(ask(standInHeld), .passed, "a repeat that does reach the main thread is decided afresh")
        check(InputManager.sentOnAs == nil, "nothing is left over from the key before")
        InputManager.keyGoesOnAs = { _ in .nowhere }
        expect(ask(standIn), .taken, "a key that goes nowhere is swallowed whole, its release too")
        check(InputManager.sentOnAs == nil, "and goes on as nothing")
        InputManager.keyGoesOnAs = { _ in .asItIs }
        expect(ask(standIn), .passed, "a key the rule leaves alone goes on as itself")
        expect(ask(standInHeld), .passed, "and its repeats go on with it")
        check(InputManager.sentOnAs == nil, "nothing is left over for the next key")
    }

    // A review, 26 Nov 2026: a key queued behind others was decided when it was typed, and by its turn the focus
    // could be on another button or in another prompt.
    test("system prompts: a key that waits its turn is asked how it goes on when its turn comes") {
        let saved = InputManager.keyGoesOnAs, savedPoster = KeyboardGesture.orderedPoster
        let posted = Locked<[Int64]>([])
        KeyboardGesture.orderedPoster = { posted.value.append($0.keyCode) }
        ScriptHandler.resetOrderedLane()
        defer {
            ScriptHandler.resetOrderedLane()
            KeyboardGesture.orderedPoster = savedPoster
            InputManager.keyGoesOnAs = saved
        }
        func pump() { RunLoop.current.run(until: Date().addingTimeInterval(0.025)) }
        let a = KeyboardGesture(identifier: "kb:a")!, b = KeyboardGesture(identifier: "kb:b")!
        var asked = 0
        InputManager.keyGoesOnAs = { _ in asked += 1; return .asAnother(space) }

        // The lane is busy with a key TurnOver is sending; the key pressed now takes its turn behind it.
        ScriptHandler.queueInOrder(a, lookUp: false, notes: false, masked: true)
        check(InputManager.handleKeyDown(standIn), "the key pressed is swallowed, to be sent on in its turn")
        pump()
        expect(posted.value, [a.keyCode], "the key ahead of it is sent first")
        expect(asked, 0, "and nothing has been asked yet")
        ScriptHandler.orderedKeySeen()
        pump()
        expect(asked, 1, "asked once, when its turn came")
        expect(posted.value, [a.keyCode, 49], "and sent as the key it goes on as")
        ScriptHandler.orderedKeySeen()
        pump()

        // A key that goes nowhere is not sent, and the keys behind it go on.
        posted.value = []
        InputManager.keyGoesOnAs = { _ in asked += 1; return .nowhere }
        ScriptHandler.queueInOrder(standIn, lookUp: false, notes: false, masked: false, mayGoOnAsAnother: true)
        ScriptHandler.queueInOrder(b, lookUp: false, notes: false, masked: true)
        pump()
        expect(asked, 2, "asked at its turn")
        expect(posted.value, [b.keyCode], "only the key behind it is sent, and a key TurnOver sends itself is not asked about")
        ScriptHandler.orderedKeySeen()
        pump()
    }
}
