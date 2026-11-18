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
        let savedFocus = API.focusObject, savedAncestors = API.focusAncestors, savedPage = API.focusTreeInterceptor
        let savedBundle = ProfileStore.shared.replayBundle, savedKey = InputManager.lastKeyIdentifier
        let savedPid = AXHandler.shared.activePid, savedPress = BrowseModeDocument.lastNavigationPress
        let savedTries = AXHandler.pageHostWatchTries, savedInterval = AXHandler.pageWatchInterval
        let window: [String: AXFixture.Value] = ["AXWindow": .element(0)]
        func attrs(_ a: [String: AXFixture.Value]) -> [String: AXFixture.Value] { a.merging(window) { x, _ in x } }
        AXReplay.load(.init(app: "Public page host trial", bundle: "test.page-host", recorded: "synthetic", root: 0, application: 1, focus: appFocus, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXWindow"), "AXSubrole": .string("AXStandardWindow"), "AXTitle": .string("Events"), "AXParent": .element(1), "AXChildren": .elements(newPage ? [2, 3, 8, 6] : [2, 3, 8])]),
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
        // VO Space pressed the link just now.
        InputManager.lastKeyIdentifier = "kb:turnover+space"
        BrowseModeDocument.lastNavigationPress = (AXReplay.element(0), pid, Date())
        AXHandler.pageHostWatchTries = 2
        AXHandler.pageWatchInterval = 0.05
        defer {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))   // the watch ends before the fixture goes
            API.setFocusObject(savedFocus, ancestors: savedAncestors, interceptor: savedPage)
            AXHandler.shared.activePid = savedPid
            ProfileStore.shared.replayBundle = savedBundle
            InputManager.lastKeyIdentifier = savedKey
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
            InputManager.lastKeyIdentifier = "kb:tab"
            check(!isHost(2, pid), "after Tab the group is a move into Safari's controls")
            InputManager.lastKeyIdentifier = "kb:turnover+space"
            ProfileStore.shared.replayBundle = "com.google.Chrome"
            check(!isHost(2, pid), "only Safari")
            ProfileStore.shared.replayBundle = "com.apple.Safari"
            BrowseModeDocument.lastNavigationPress = nil
            check(!isHost(2, pid), "with no press there is no evidence")
        }
    }

    test("Safari's page host set aside: the new page is handed on when it comes, and the group is presented when none does") {
        // No new page comes: set aside at first, presented once the watch ends.
        withSafari(appFocus: 2) { pid in
            AXHandler.shared.focusChanged(AXReplay.element(2), pid: pid)
            check(API.focusObject?.element.isSame(AXReplay.element(4)) == true, "the group is set aside: the link keeps the focus")
            check(BrowseModeDocument.lastNavigationPress == nil, "the press is used up")
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            check(API.focusObject?.element.isSame(AXReplay.element(2)) == true, "with no new page, the group set aside is presented")
        }
        // The new page comes and takes the app's focus, with no focus event of its own: it is followed.
        withSafari(appFocus: 6, newPage: true) { pid in
            let savedObserver = Log.observer, savedLevel = Log.level
            let lines = Locked<[String]>([])
            Log.level = .debug
            Log.observer = { lines.value.append($0) }
            defer { Log.observer = savedObserver; Log.level = savedLevel }
            AXHandler.shared.focusChanged(AXReplay.element(2), pid: pid)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            // The watch hands the new page to the focus rules. Whether it is then presented is not checked here: in the
            // replay the window's owner is another made-up process, and the last rule turns it away (a fixture limit).
            check(lines.value.contains { $0.contains("the web area that took the focus has content now; following it") }, "the new page is handed to the focus rules")
        }
    }
}
