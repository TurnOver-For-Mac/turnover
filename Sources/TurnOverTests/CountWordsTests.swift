// SPDX-License-Identifier: GPL-3.0-or-later
// 24 Nov 2026: one of something is said in the singular ("1 minute", "1 hour ago", "table with 1 row and 3
// columns"), where the plural alone had said "1 minutes" and "1 hours ago".
import Foundation
import TurnOverCore

func countWordsTests() {
    test("Count words: the battery's time says one minute and one hour in the singular") {
        expect(GlobalCommands.batteryTime(minutes: -1), nil, "the Mac still working it out")
        expect(GlobalCommands.batteryTime(minutes: 0), nil, "nothing to say")
        expect(GlobalCommands.batteryTime(minutes: 1), "1 minute")
        expect(GlobalCommands.batteryTime(minutes: 45), "45 minutes")
        expect(GlobalCommands.batteryTime(minutes: 60), "1 hour")
        expect(GlobalCommands.batteryTime(minutes: 61), "1 hour 1 minute")
        expect(GlobalCommands.batteryTime(minutes: 121), "2 hours 1 minute")
        expect(GlobalCommands.batteryTime(minutes: 150), "2 hours 30 minutes")
    }
    test("Count words: a notification an hour old is \"1 hour ago\"") {
        expect(NotificationHistory.when(minutesAgo: 0), "just now")
        expect(NotificationHistory.when(minutesAgo: 1), "1 minute ago")
        expect(NotificationHistory.when(minutesAgo: 59), "59 minutes ago")
        expect(NotificationHistory.when(minutesAgo: 60), "1 hour ago")
        expect(NotificationHistory.when(minutesAgo: 119), "1 hour ago", "still under two hours")
        expect(NotificationHistory.when(minutesAgo: 120), "2 hours ago")
    }
    test("Count words: a Word table with one row or one column says so in the singular") {
        expect(WordTableWords.size(rows: 1, columns: 1), "table with 1 row and 1 column")
        expect(WordTableWords.size(rows: 1, columns: 3), "table with 1 row and 3 columns")
        expect(WordTableWords.size(rows: 4, columns: 1), "table with 4 rows and 1 column")
        expect(WordTableWords.size(rows: 4, columns: 3), "table with 4 rows and 3 columns", "unchanged")
    }
    test("Count words: a chat with fewer messages than asked for says how many, one in the singular") {
        expect(ChatView.fewerMessages(0), "no messages")
        expect(ChatView.fewerMessages(1), "only 1 message")
        expect(ChatView.fewerMessages(3), "only 3 messages", "unchanged")
    }
}
