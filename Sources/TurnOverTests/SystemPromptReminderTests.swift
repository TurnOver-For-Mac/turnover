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
}
