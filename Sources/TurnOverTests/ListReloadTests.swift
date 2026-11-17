// SPDX-License-Identifier: GPL-3.0-or-later
// A Finder list that is reloading is not called empty (17 Nov 2026). Logic evidence only: the timing against
// Finder's real reload is for Oliver's ear.
import Foundation
import TurnOverCore

func listReloadTests() {
    test("list reload: its own news or its rows coming back is not empty; nothing within the limit is") {
        expect(SelectableList.settleReload(limit: 0.05, eventPending: { true }, rowsBack: { false }), .event, "a selection or focus event")
        expect(SelectableList.settleReload(limit: 0.05, eventPending: { false }, rowsBack: { true }), .rows, "the rows came back")
        var looks = 0
        expect(SelectableList.settleReload(limit: 0.5, eventPending: { false }, rowsBack: { looks += 1; return looks >= 3 }), .rows, "rows after a few looks")
        expect(SelectableList.settleReload(limit: 0.03, eventPending: { false }, rowsBack: { false }), .empty, "nothing came: empty")
    }
}
