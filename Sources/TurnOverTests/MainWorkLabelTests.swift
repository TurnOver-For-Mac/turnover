// SPDX-License-Identifier: GPL-3.0-or-later
// The words that say what the main thread had begun, for the log (17 Nov 2026). Logic evidence only: the words, not
// the timing of any real activation.
import Foundation
import TurnOverCore

func mainWorkLabelTests() {
    test("main work label: what was begun, with its pid and age; nothing labelled says so") {
        expect(Core.describe(Core.MainWork(what: "notification AXRowCountChanged", pid: 123, at: 1_000_000_000), now: 7_000_000_000),
               "notification AXRowCountChanged (pid 123), begun 6.0 s ago")
        expect(Core.describe(Core.MainWork(what: "script vo_next", pid: 0, at: 5_000_000_000), now: 5_400_000_000), "script vo_next, begun 0.4 s ago")
        expect(Core.describe(Core.MainWork(what: "", pid: 0, at: 0), now: 1), "nothing labelled yet")
    }
}
