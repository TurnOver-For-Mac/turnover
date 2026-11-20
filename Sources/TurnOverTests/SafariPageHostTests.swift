// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import TurnOverAX
import AXFixtures

// VO Space on a link in Safari (18 Nov 2026 at 07:13:28 and 07:18:31): the focus went to a nameless group outside any
// page while the new page loaded, TurnOver presented it (saying nothing) and let go of the page, and the new page was
// said only after Tab. Logic evidence only: made-up windows, not Safari's own tree, and no real page load.
func safariPageHostTests() {
    /// Safari's window (0) with the page host (2), the page in hand (3) and its link (4), a group on the page (5), a sheet
    /// (8) holding a nameless group (9), and a second window (10) with a nameless group (11). `appFocus`: what the app
    /// says has its focus; `newPage`: a new page (6, with a link 7) in the window, beside the host.
    func withSafari(appFocus: Int, newPage: Bool = false, _ body: (pid_t) -> Void) {
        // The made-up elements keep their identities from one load to the next: a group presented by the test before is
        // "reported twice" for half a second (ruleReportedTwice). That half second goes by first.
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let savedFocus = API.focusObject, savedAncestors = API.focusAncestors, savedPage = API.focusTreeInterceptor
        let savedBundle = ProfileStore.shared.replayBundle, savedKeyAt = InputManager.lastKeyDownAt
        let savedSetAside = AXHandler.pageHostSetAside, savedLimit = AXHandler.pageHostAncestorLimit
        let savedPid = AXHandler.shared.activePid, savedPress = BrowseModeDocument.lastNavigationPress
        let savedTries = AXHandler.pageHostWatchTries, savedInterval = AXHandler.pageWatchInterval
        let window: [String: AXFixture.Value] = ["AXWindow": .element(0)]
        func attrs(_ a: [String: AXFixture.Value]) -> [String: AXFixture.Value] { a.merging(window) { x, _ in x } }
        AXReplay.load(.init(app: "Public page host trial", bundle: "test.page-host", recorded: "synthetic", root: 0, application: 1, focus: appFocus, nodes: [
            // With a new page, the window has no parent: in the replay every element is a process of its own, and the
            // application above the window would make the new page "owned by another process" (the last rule).
            .init(id: 0, attrs: ["AXRole": .string("AXWindow"), "AXSubrole": .string("AXStandardWindow"), "AXTitle": .string("Events"),
                                 "AXChildren": .elements(newPage ? [2, 3, 8, 6] : [2, 3, 8])].merging(newPage ? [:] : ["AXParent": .element(1)]) { x, _ in x }),
            .init(id: 1, attrs: ["AXRole": .string("AXApplication"), "AXChildren": .elements([0, 10]), "AXFocusedWindow": .element(0), "AXMainWindow": .element(0), "AXFocusedUIElement": .element(appFocus)]),
            .init(id: 2, attrs: attrs(["AXRole": .string("AXGroup"), "AXParent": .element(0)])),
            .init(id: 3, attrs: attrs(["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.com/old"), "AXParent": .element(0), "AXChildren": .elements([4, 5])])),
            .init(id: 4, attrs: attrs(["AXRole": .string("AXLink"), "AXTitle": .string("Events"), "AXParent": .element(3)]), actions: ["AXPress"]),
            .init(id: 5, attrs: attrs(["AXRole": .string("AXGroup"), "AXParent": .element(3)])),
            .init(id: 6, attrs: attrs(["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.com/new"), "AXTitle": .string("New page"), "AXParent": .element(0), "AXChildren": .elements([7])])),
            .init(id: 7, attrs: attrs(["AXRole": .string("AXLink"), "AXTitle": .string("Log in"), "AXParent": .element(6)]), actions: ["AXPress"]),
            .init(id: 8, attrs: attrs(["AXRole": .string("AXSheet"), "AXParent": .element(0), "AXChildren": .elements([9])])),
            .init(id: 9, attrs: attrs(["AXRole": .string("AXGroup"), "AXParent": .element(8)])),
            .init(id: 10, attrs: ["AXRole": .string("AXWindow"), "AXSubrole": .string("AXStandardWindow"), "AXParent": .element(1), "AXChildren": .elements([11])]),
            .init(id: 11, attrs: ["AXRole": .string("AXGroup"), "AXParent": .element(10), "AXWindow": .element(10)])
        ]))
        let pid = AXReplay.element(3).pid
        let page = BrowseModeDocument(webArea: AXReplay.element(3))
        API.setFocusObject(ObjectFactory.make(AXReplay.element(4)), ancestors: [], interceptor: page)
        AXHandler.shared.activePid = pid
        ProfileStore.shared.replayBundle = "com.apple.Safari"
        // VO Space pressed the link just now, and no key since.
        let keyAt = Date()
        InputManager.lastKeyDownAt = keyAt
        BrowseModeDocument.lastNavigationPress = (AXReplay.element(0), pid, Date(), keyAt)
        AXHandler.pageHostWatchTries = 2
        AXHandler.pageWatchInterval = 0.05
        defer {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))   // the watch ends before the fixture goes
            API.setFocusObject(savedFocus, ancestors: savedAncestors, interceptor: savedPage)
            AXHandler.shared.activePid = savedPid
            ProfileStore.shared.replayBundle = savedBundle
            InputManager.lastKeyDownAt = savedKeyAt
            AXHandler.pageHostSetAside = savedSetAside
            AXHandler.pageHostAncestorLimit = savedLimit
            BrowseModeDocument.lastNavigationPress = savedPress
            AXHandler.pageHostWatchTries = savedTries
            AXHandler.pageWatchInterval = savedInterval
            AXReplay.unload()
        }
        body(pid)
    }
    func isHost(_ id: Int, _ pid: pid_t, now: Date = Date()) -> Bool {
        AXHandler.isSafariPageHostBetweenPages(AXReplay.element(id), pid: pid, now: now)
    }

    test("Safari's page host is set aside only just after VO Space or Return on a link, in that window, outside pages and sheets") {
        withSafari(appFocus: 2) { pid in
            check(isHost(2, pid), "after VO Space on a link, the nameless group outside the page is the page host")
            check(!isHost(5, pid), "a nameless group on the page is the page's own")
            check(!isHost(9, pid), "a group in a sheet is the sheet's")
            check(!isHost(11, pid), "a group in another window of the process is not this window's")
            check(!isHost(4, pid), "a link is not a group")
            check(!isHost(2, pid, now: Date().addingTimeInterval(5)), "a press five seconds ago is no evidence")
            // Any key since the press (Tab into Safari's controls, then another key) ends the evidence for good.
            let pressedAt = InputManager.lastKeyDownAt
            InputManager.lastKeyDownAt = pressedAt.addingTimeInterval(0.5)   // Tab
            check(!isHost(2, pid), "after Tab the press is no evidence")
            InputManager.lastKeyDownAt = pressedAt.addingTimeInterval(1)     // another key
            check(!isHost(2, pid), "nor after a key after Tab")
            InputManager.lastKeyDownAt = pressedAt
            // A walk stopped by its limit before the window has not shown the group is outside a page.
            AXHandler.pageHostAncestorLimit = 0
            check(!isHost(2, pid), "a walk that never reaches the window declines")
            AXHandler.pageHostAncestorLimit = 40
            ProfileStore.shared.replayBundle = "com.google.Chrome"
            check(!isHost(2, pid), "only Safari")
            ProfileStore.shared.replayBundle = "com.apple.Safari"
            BrowseModeDocument.lastNavigationPress = nil
            check(!isHost(2, pid), "with no press there is no evidence")
        }
    }

    test("Safari's page host reported again after a key is no longer set aside") {
        withSafari(appFocus: 2) { pid in
            AXHandler.shared.focusChanged(AXReplay.element(2), pid: pid)
            check(AXHandler.isPageHostSetAside(AXReplay.element(2)), "set aside after the press")
            InputManager.lastKeyDownAt = Date().addingTimeInterval(1)
            check(!AXHandler.isPageHostSetAside(AXReplay.element(2)), "a key since ends it: Oliver has moved")
        }
    }

    // 19 Nov 2026, Codex's review: a Quick Nav arrow (or a keypad command) never reaches InputManager, so its key time
    // stayed that of the press, and the group could still be set aside after it.
    test("A Quick Nav arrow or keypad key after the press ends it as evidence, and ends a group set aside") {
        withSafari(appFocus: 2) { pid in
            BrowseModeDocument.keyBypassedInputManager()
            check(!AXHandler.isSafariPageHostBetweenPages(AXReplay.element(2), pid: pid), "no press to go on after the arrow")
        }
        withSafari(appFocus: 2) { pid in
            AXHandler.shared.focusChanged(AXReplay.element(2), pid: pid)
            check(AXHandler.isPageHostSetAside(AXReplay.element(2)), "set aside after the press")
            BrowseModeDocument.keyBypassedInputManager()
            check(!AXHandler.isPageHostSetAside(AXReplay.element(2)), "the arrow ends it: Oliver has moved")
        }
    }

    test("Safari's page host set aside: the new page is handed on when it comes, and the group is presented when none does") {
        // No new page comes: set aside at first, presented once the watch ends.
        withSafari(appFocus: 2) { pid in
            AXHandler.shared.focusChanged(AXReplay.element(2), pid: pid)
            check(API.focusObject?.element.isSame(AXReplay.element(4)) == true, "the group is set aside: the link keeps the focus")
            check(BrowseModeDocument.lastNavigationPress == nil, "the press is used up")
            // Safari reports the same group again while the page is awaited: still set aside, the page still TurnOver's.
            AXHandler.shared.focusChanged(AXReplay.element(2), pid: pid)
            check(API.focusObject?.element.isSame(AXReplay.element(4)) == true, "the group reported again is still set aside")
            check(API.focusTreeInterceptor != nil, "the page is still in hand, so the watch goes on")
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            check(API.focusObject?.element.isSame(AXReplay.element(2)) == true, "with no new page, the group set aside is presented")
        }
        // The new page comes and takes the app's focus, with no focus event of its own: it is followed.
        withSafari(appFocus: 6, newPage: true) { pid in
            let savedObserver = Log.observer, savedLevel = Log.level
            let lines = Locked<[String]>([])
            Log.level = .debug
            Log.observer = { lines.value.append($0) }
            let savedDriver = Speech.enqueueTestDriver, said = Locked<[String]>([])
            Speech.enqueueTestDriver = { text, _, _ in said.value.append(text) }
            defer { Log.observer = savedObserver; Log.level = savedLevel; Speech.enqueueTestDriver = savedDriver }
            AXHandler.shared.focusChanged(AXReplay.element(2), pid: pid)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            // The watch hands the new page to the focus rules, and it is presented and said (19 Nov 2026, Codex's review:
            // only the hand-over was checked, so the page itself could be dropped unseen). Browse mode's document for it
            // is not checked: a replayed web area has no text markers, so browse mode does not take it (a fixture limit).
            check(lines.value.contains { $0.contains("the web area that took the focus has content now; following it") }, "the new page is handed to the focus rules")
            check(API.focusObject?.element.isSame(AXReplay.element(6)) == true, "the new page is TurnOver's focus")
            check(said.value.contains { $0.contains("New page") }, "the new page is said: \(said.value)")
        }
    }

    // 20 Nov 2026 (review): the same document took a new page while the nameless group was set aside; presenting the group
    // then would drop that page and talk over it.
    test("Safari's page host set aside: when the page's generation changed during the watch, the group is not presented") {
        withSafari(appFocus: 2) { pid in
            AXHandler.shared.focusChanged(AXReplay.element(2), pid: pid)
            check(API.focusObject?.element.isSame(AXReplay.element(4)) == true, "the group is set aside")
            guard let document = API.focusTreeInterceptor as? BrowseModeDocument else { return check(false, "the page is in hand") }
            document.pageGeneration += 1   // the document read a new page meanwhile
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))   // the watch (2 tries of 0.05 s) gives up
            check(AXHandler.pageHostSetAside == nil, "the watch has ended")
            check(API.focusObject?.element.isSame(AXReplay.element(2)) != true, "the group is not presented over the new page")
        }
    }
}
