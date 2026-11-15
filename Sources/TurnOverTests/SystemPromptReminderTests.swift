// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

func systemPromptReminderTests() {
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
