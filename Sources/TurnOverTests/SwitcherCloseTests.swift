// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import AXFixtures
import TurnOverCore

/// The application switcher closing without news (issue 351, 22 Nov 2026). The decision is pure; the review cursor's
/// rule is tested on recorded elements (logic only: the timing and the real switcher were not tried here).
func switcherCloseTests() {
    typealias W = SwitcherCloseWatcher
    func decide(held: Bool = false, front: pid_t? = 10, active: pid_t = 10, said: String? = nil,
                name: String? = "Safari", closed: Double? = 0) -> SwitcherCloseStep {
        W.decide(commandHeld: held, frontPid: front, activePid: active, lastAnnounced: said,
                 frontName: name, closedFor: closed)
    }

    test("switcher close: nothing is read while Command is held, however long") {
        expect(decide(held: true, closed: nil), .keepWaiting, "open")
        expect(decide(held: true, said: "Safari", closed: 99), .keepWaiting, "open for a long time, even on the app in front")
    }
    test("switcher close: the app already in front was chosen, read at once") {
        expect(decide(said: "Safari", name: "Safari"), .refocusActive, "item last said is the front app")
    }
    test("switcher close: after Escape with Command still held, the app is read once Command is let go") {
        expect(decide(held: true, said: "Mail", name: "Safari", closed: 0.1), .keepWaiting, "Command held: the focus rules would set the read aside")
        expect(decide(said: "Mail", name: "Safari", closed: 2), .refocusActive, "let go: the list went long ago, so at once")
    }
    test("switcher close: the same app in front but another named waits a moment, then is read") {
        expect(decide(said: "Mail", name: "Safari", closed: 0.2), .keepWaiting, "another app may still come forward")
        expect(decide(said: "Mail", name: "Safari", closed: 0.6), .refocusActive, "none came")
        expect(decide(said: nil, name: nil, closed: 0.1), .keepWaiting, "no names are not a match")
    }
    test("switcher close: a different app on its way is waited for, and read if it never arrives") {
        expect(decide(front: 20, active: 10, said: "Mail", name: "Mail", closed: 0.8), .keepWaiting, "the activation is coming")
        expect(decide(front: 20, active: 10, said: "Mail", name: "Mail", closed: 1.49), .keepWaiting, "not yet")
        expect(decide(front: 20, active: 10, said: "Mail", name: "Mail", closed: 1.5), .refocusFront, "never arrived: the front app's focus")
    }
    test("switcher close: no app in front stops the watcher after the wait") {
        expect(decide(front: nil, closed: 0.5), .keepWaiting, "not yet")
        expect(decide(front: nil, closed: 1.5), .stop, "gave up")
    }
    test("switcher close: Command held with another app in front still waits for Command") {
        expect(decide(held: true, front: 20, active: 10, closed: 5), .keepWaiting, "nothing read while Command is held")
        expect(decide(front: 20, active: 10, closed: 5), .refocusFront, "let go, and no activation came: the front app")
    }

    test("review cursor: a focus in another app always moves it; the bounce rule is for the same app") {
        check(!ObjectNavigator.keepsCursorAfterFollowing(cursorPid: 10, focusPid: 20), "another app: the cursor moves")
        check(ObjectNavigator.keepsCursorAfterFollowing(cursorPid: 10, focusPid: 10), "the same app: the cursor stays")
        check(!ObjectNavigator.keepsCursorAfterFollowing(cursorPid: nil, focusPid: 10), "no cursor: nothing to keep")
    }

    test("review cursor: after following the cursor, a focus in another app still moves it") {
        guard AXReplay.isAvailable else { return }
        AXReplay.load(.init(app: "Fixture", bundle: "org.example.fixture", recorded: "synthetic", root: 1, application: nil, focus: 2, nodes: [
            .init(id: 1, attrs: ["AXRole": .string("AXWindow"), "AXChildren": .elements([2, 3, 4])]),
            .init(id: 2, attrs: ["AXRole": .string("AXButton"), "AXParent": .element(1)]),
            .init(id: 3, attrs: ["AXRole": .string("AXButton"), "AXParent": .element(1)]),
            .init(id: 4, attrs: ["AXRole": .string("AXButton"), "AXParent": .element(1)]),
        ]))
        let nav = ObjectNavigator.shared
        let savedFollowed = nav.followed
        let savedElement = nav.reviewElement
        defer { nav.followed = savedFollowed; if let e = savedElement { nav.focusMoved(to: e, pid: e.pid) }; AXReplay.unload() }
        let a = AXReplay.element(2), b = AXReplay.element(3), c = AXReplay.element(4)
        nav.focusMoved(to: a, pid: 10)
        nav.followed = (a, Date())
        nav.focusMoved(to: b, pid: 10)
        check(nav.reviewElement.map { CFEqual($0, a) } ?? false, "the same app: the bounce is kept off the cursor")
        nav.focusMoved(to: c, pid: 20)
        check(nav.reviewElement.map { CFEqual($0, c) } ?? false, "another app: the cursor moves with the focus")
    }
}
