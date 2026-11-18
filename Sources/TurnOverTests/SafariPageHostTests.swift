// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import TurnOverAX
import AXFixtures

// VO Space on a link in Safari (18 Nov 2026 at 07:13:28 and 07:18:31): the focus went to a nameless group outside any
// page while the new page loaded, TurnOver presented it (saying nothing) and let go of the page, and the new page was
// said only after Tab. Which reports are that group. Logic evidence only: a made-up window, not Safari's own tree.
func safariPageHostTests() {
    test("Safari's nameless group between pages is told apart from groups on the page and Tab into Safari's controls") {
        let savedFocus = API.focusObject, savedAncestors = API.focusAncestors, savedPage = API.focusTreeInterceptor
        let savedBundle = ProfileStore.shared.replayBundle, savedKey = InputManager.lastKeyIdentifier
        AXReplay.load(.init(app: "Public page host trial", bundle: "test.page-host", recorded: "synthetic", root: 0, application: 1, focus: 4, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXWindow"), "AXTitle": .string("Events"), "AXParent": .element(1), "AXChildren": .elements([2, 3])]),
            .init(id: 1, attrs: ["AXRole": .string("AXApplication"), "AXChildren": .elements([0])]),
            // The group Safari focuses while the new page loads: nameless, outside the page, nothing in it yet.
            .init(id: 2, attrs: ["AXRole": .string("AXGroup"), "AXParent": .element(0), "AXWindow": .element(0)]),
            .init(id: 3, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.com/old"), "AXParent": .element(0), "AXWindow": .element(0), "AXChildren": .elements([4, 5])]),
            .init(id: 4, attrs: ["AXRole": .string("AXLink"), "AXTitle": .string("Events"), "AXParent": .element(3), "AXWindow": .element(0)], actions: ["AXPress"]),
            // A nameless group on the page itself.
            .init(id: 5, attrs: ["AXRole": .string("AXGroup"), "AXParent": .element(3), "AXWindow": .element(0)])
        ]))
        let page = BrowseModeDocument(webArea: AXReplay.element(3))
        API.setFocusObject(ObjectFactory.make(AXReplay.element(4)), ancestors: [], interceptor: page)
        let pid = AXReplay.element(3).pid
        defer {
            API.setFocusObject(savedFocus, ancestors: savedAncestors, interceptor: savedPage)
            ProfileStore.shared.replayBundle = savedBundle
            InputManager.lastKeyIdentifier = savedKey
            AXReplay.unload()
        }
        ProfileStore.shared.replayBundle = "com.apple.Safari"
        InputManager.lastKeyIdentifier = "kb:turnover+space"
        check(AXHandler.isSafariPageHostBetweenPages(AXReplay.element(2), pid: pid), "after VO Space, the group outside the page is the page host")
        check(!AXHandler.isSafariPageHostBetweenPages(AXReplay.element(5), pid: pid), "a nameless group on the page is the page's own")
        check(!AXHandler.isSafariPageHostBetweenPages(AXReplay.element(4), pid: pid), "a link is not a group")
        InputManager.lastKeyIdentifier = "kb:tab"
        check(!AXHandler.isSafariPageHostBetweenPages(AXReplay.element(2), pid: pid), "after Tab the group is a move into Safari's controls")
        InputManager.lastKeyIdentifier = "kb:turnover+space"
        ProfileStore.shared.replayBundle = "com.google.Chrome"
        check(!AXHandler.isSafariPageHostBetweenPages(AXReplay.element(2), pid: pid), "only Safari")
        ProfileStore.shared.replayBundle = "com.apple.Safari"
        API.setFocusObject(ObjectFactory.make(AXReplay.element(4)), ancestors: [], interceptor: nil)
        check(!AXHandler.isSafariPageHostBetweenPages(AXReplay.element(2), pid: pid), "only with a page in hand")
    }
}
