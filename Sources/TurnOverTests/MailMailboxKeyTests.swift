// SPDX-License-Identifier: GPL-3.0-or-later
// Mail: a mailbox key that chooses the mailbox already shown is read without waiting for a new title (17 Nov 2026).
// Logic evidence only: the learning and the decision, not Mail's real timing, which is for the owner's ear.
import Foundation
import TurnOverCore

func mailMailboxKeyTests() {
    test("Mail mailbox keys: a key is known to choose the shown mailbox only once its title was seen") {
        var keys = MailAppModule.MailboxKeys()
        check(!keys.isShown(key: "kb:command+1", title: "Inbox – Personal"), "a key not seen yet takes the wait")
        keys.learn(key: "kb:command+1", title: "Inbox – Personal")
        check(keys.isShown(key: "kb:command+1", title: "Inbox – Personal"), "the same key on the same mailbox")
        check(!keys.isShown(key: "kb:command+1", title: "Junk – Personal"), "the same key, another mailbox shown")
        check(!keys.isShown(key: "kb:command+2", title: "Inbox – Personal"), "another key")
        keys.learn(key: "kb:command+2", title: "")
        check(!keys.isShown(key: "kb:command+2", title: ""), "no title is never a match")
    }
}
