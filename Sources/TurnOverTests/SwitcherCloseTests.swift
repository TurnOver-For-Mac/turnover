// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import AXFixtures
import TurnOverCore
import TurnOverAX

/// The application switcher closing without news (issue 351, 22 Nov 2026). The decision is pure; the review cursor's
/// rule is tested on recorded elements (logic only: the timing and the real switcher were not tried here).
func switcherCloseTests() {
    typealias W = SwitcherCloseWatcher
    func decide(held: Bool = false, front: pid_t? = 10, active: pid_t = 10, said: String? = nil,
                name: String? = "Safari", closed: Double? = 0, switcherFocused: Bool = true,
                focusedPid: pid_t? = nil) -> SwitcherCloseStep {
        W.decide(commandHeld: held, frontPid: front, activePid: active, lastAnnounced: said,
                 frontName: name, closedFor: closed, switcherFocused: switcherFocused, focusedPid: focusedPid)
    }

    test("switcher input: a decision's outputs stay in order before the next decision") {
        let savedPoster = KeyboardGesture.orderedPoster
        let posted = Locked<[String]>([])
        KeyboardGesture.orderedPoster = { posted.value.append($0.identifier) }
        defer {
            ScriptHandler.resetOrderedLane()
            KeyboardGesture.orderedPoster = savedPoster
        }
        func gesture(_ key: String) -> KeyboardGesture { KeyboardGesture(identifier: "kb:" + key)! }
        func pump() { RunLoop.current.run(until: Date().addingTimeInterval(0.025)) }

        var decisions = [String]()
        ScriptHandler.queueInput(gesture("a"), isCurrent: { true }) { key in
            decisions.append(key.identifier)
            ScriptHandler.queueInOrder(key, lookUp: false, notes: false, masked: true)
            ScriptHandler.queueInOrder(gesture("b"), lookUp: false, notes: false, masked: true)
        }
        ScriptHandler.queueInput(gesture("c"), isCurrent: { true }) { key in
            decisions.append(key.identifier)
            ScriptHandler.queueInOrder(key, lookUp: false, notes: false, masked: true)
        }
        ScriptHandler.queueInput(gesture("d"), isCurrent: { false }) { decisions.append($0.identifier) }

        pump()
        expect(posted.value, ["kb:a"], "the first output reaches the tap first")
        expect(decisions, ["kb:a"], "the next key has not been decided")
        ScriptHandler.orderedKeySeen()
        pump()
        expect(posted.value, ["kb:a", "kb:b"], "the second output is next")
        expect(decisions, ["kb:a"], "the next key still waits")
        ScriptHandler.orderedKeySeen()
        pump()
        expect(posted.value, ["kb:a", "kb:b", "kb:c"], "the next decision's key follows both outputs")
        ScriptHandler.orderedKeySeen()
        pump()
        expect(decisions, ["kb:a", "kb:c"], "the stale gesture never reaches the input decision")
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
        expect(decide(front: 20, active: 10, said: "Mail", name: "Mail", closed: 1.5), .recoverActivation, "never arrived: recover the activation")
    }
    test("switcher close: destination focus alone does not end the activation watch") {
        expect(decide(front: 20, closed: 0.8, switcherFocused: false, focusedPid: 20), .keepWaiting,
               "the workspace notification still has time to arrive")
        expect(decide(front: 20, closed: 1.5, switcherFocused: false, focusedPid: 20), .recoverActivation,
               "focus arrived but activation did not")
        expect(decide(front: 20, active: 20, closed: 1.5, switcherFocused: false, focusedPid: 20), .stop,
               "the workspace notification already handled this activation")
        expect(decide(front: 30, closed: 1.5, switcherFocused: false, focusedPid: 20), .stop,
               "the foreground changed again")
        expect(decide(front: 20, closed: 1.5, switcherFocused: false, focusedPid: 40), .stop,
               "a different process has the focus")
    }
    test("switcher close: no app in front stops the watcher after the wait") {
        expect(decide(front: nil, closed: 0.5), .keepWaiting, "not yet")
        expect(decide(front: nil, closed: 1.5), .stop, "gave up")
    }
    test("switcher close: Command held with another app in front still waits for Command") {
        expect(decide(held: true, front: 20, active: 10, closed: 5), .keepWaiting, "nothing read while Command is held")
        expect(decide(front: 20, active: 10, closed: 5), .recoverActivation, "let go, and no activation came: recover it")
    }

    test("switcher close: reopening cancels the previous fallback over the same app") {
        var finishes = 0
        W.start()
        let oldFallback = W.unlessReopened { finishes += 1 }
        W.start()
        let newFallback = W.unlessReopened { finishes += 1 }
        oldFallback()
        expect(finishes, 0, "the old callback leaves the new switcher alone")
        newFallback()
        expect(finishes, 1, "the current callback still runs")
    }

    test("switcher close: activation recovery keeps real destination focus and replaces an app placeholder") {
        guard AXReplay.isAvailable else { return }
        AXReplay.load(.init(app: "Fixture", bundle: "org.example.fixture", recorded: "synthetic", root: 0,
                            application: 0, focus: 1, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXApplication")]),
            .init(id: 1, attrs: ["AXRole": .string("AXButton")]),
        ]))
        defer { AXReplay.unload() }
        let app = AXReplay.element(0)
        let placeholder = TurnOverObject(element: app)
        let control = TurnOverObject(element: AXReplay.element(1))
        let replacement = TurnOverObject(element: control.element)
        let pid = control.pid
        check(AXHandler.keepsObservedActivationFocus(pid: pid, observed: control, current: control, app: app),
              "the destination focus already arrived")
        check(!AXHandler.keepsObservedActivationFocus(pid: placeholder.pid, observed: placeholder, current: placeholder, app: app),
              "the application object still needs its first real focus")
        check(!AXHandler.keepsObservedActivationFocus(pid: pid + 1, observed: control, current: control, app: app),
              "the focus belongs to a different process")
        check(!AXHandler.keepsObservedActivationFocus(pid: pid, observed: control, current: replacement, app: app),
              "the captured focus no longer matches the current object")
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
        defer { AXReplay.unload() }
        let nav = ObjectNavigator()
        let a = AXReplay.element(2), b = AXReplay.element(3), c = AXReplay.element(4)
        nav.focusMoved(to: a, pid: 10)
        nav.followed = (a, Date())
        nav.focusMoved(to: b, pid: 10)
        check(nav.reviewElement.map { CFEqual($0, a) } ?? false, "the same app: the bounce is kept off the cursor")
        nav.focusMoved(to: c, pid: 20)
        check(nav.reviewElement.map { CFEqual($0, c) } ?? false, "another app: the cursor moves with the focus")
        nav.focusMoved(to: b, pid: 20)
        check(nav.reviewElement.map { CFEqual($0, b) } ?? false, "the next control in that app is followed too")
    }
}
