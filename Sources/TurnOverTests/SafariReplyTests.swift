// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import AXFixtures

private final class SafariHeldReplies {
    struct PollReply {
        let condition: @Sendable () -> Bool
        let reply: @MainActor (Bool) -> Void
    }
    var delayed: [@MainActor () -> Void] = []
    var polls: [PollReply] = []
    var current = true
    let keys = Locked(0)
    let delivered = Locked(0)
}

func safariReplyTests() {
    func withSafari(_ body: (SafariAppModule, SafariHeldReplies, () -> [String], (String, Int) -> Void) -> Void) {
        BuiltInModules.register()
        guard let registered = AppModuleHandler.shared.moduleType(for: "com.apple.Safari") else {
            return Harness.fail("Safari's production module is registered")
        }
        expect(ObjectIdentifier(registered), ObjectIdentifier(SafariAppModule.self), "tests use the registered production module class")
        var fixture = AXFixture(app: "Public Safari sample", bundle: "com.apple.Safari", recorded: "synthetic", root: 1,
                                application: 0, focus: 3, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXApplication"), "AXFocusedWindow": .element(1), "AXMainWindow": .element(1), "AXFocusedUIElement": .element(3)]),
            .init(id: 1, attrs: ["AXRole": .string("AXWindow"), "AXTitle": .string("First public tab"), "AXChildren": .elements([2]), "AXParent": .element(0)]),
            .init(id: 2, attrs: ["AXRole": .string("AXWebArea"), "AXParent": .element(1), "AXWindow": .element(1), "AXChildren": .elements([])]),
            .init(id: 3, attrs: ["AXRole": .string("AXTextField"), "AXValue": .string("public"), "AXParent": .element(4), "AXWindow": .element(1)]),
            .init(id: 4, attrs: ["AXRole": .string("AXGroup"), "AXDescription": .string("Find Banner"), "AXWindow": .element(1)]),
            .init(id: 5, attrs: ["AXRole": .string("AXWindow"), "AXTitle": .string("Second public window"), "AXChildren": .elements([6])]),
            .init(id: 6, attrs: ["AXRole": .string("AXWebArea"), "AXChildren": .elements([])]),
        ])
        AXReplay.load(fixture)
        let savedSink = Speech.sink, savedPoster = KeyboardGesture.poster, savedWatchers = InputManager.passThroughWatchers
        let savedFocus = API.focusObject, savedAncestors = API.focusAncestors, savedInterceptor = API.focusTreeInterceptor
        var said: [String] = []
        let held = SafariHeldReplies(), keys = held.keys, delivered = held.delivered
        Speech.sink = { said.append($0) }
        KeyboardGesture.poster = { _ in delivered.lock.lock(); delivered.unsafeValue += 1; delivered.lock.unlock() }
        let environment = SafariReplyEnvironment(isCurrent: { _ in held.current }, keyCount: { keys.value },
            after: { _, reply in held.delayed.append(reply) }, poll: { condition, reply in held.polls.append(.init(condition: condition, reply: reply)) })
        let focus = TurnOverObject(element: AXReplay.element(3))
        API.setFocusObject(focus, ancestors: [])
        let module = SafariAppModule(pid: focus.pid, bundleIdentifier: "com.apple.Safari", appName: "Public Safari sample", replies: environment)
        defer {
            module.terminate()
            API.setFocusObject(savedFocus, ancestors: savedAncestors, interceptor: savedInterceptor)
            Speech.sink = savedSink; KeyboardGesture.poster = savedPoster; InputManager.passThroughWatchers = savedWatchers
            AXReplay.unload()
        }
        body(module, held, { said }) { title, window in
            fixture.nodes[1].attrs["AXTitle"] = .string(title)
            fixture.nodes[0].attrs["AXFocusedWindow"] = .element(window)
            AXReplay.load(fixture)
        }
    }
    func invoke(_ module: SafariAppModule, _ name: String, _ gesture: String) {
        guard let script = module.script(named: name) else { return Harness.fail("registered Safari script \(name) exists") }
        script.handler(KeyboardGesture(identifier: gesture)!)
    }

    test("Safari: actual tab script discards an older held reply and announces the latest tab once") {
        withSafari { module, held, said, update in
            invoke(module, "safari_switchTab", "kb:control+tab")
            update("Second public tab", 1)
            invoke(module, "safari_switchTab", "kb:control+tab")
            expect(held.polls.count, 2)
            guard held.polls.count == 2 else { return }
            let before = AXStats.calls
            check(held.polls[0].condition(), "a superseded worker finishes without another provider read")
            held.polls[0].reply(true)
            expect(AXStats.calls, before)
            expect(said(), [])
            update("Third public tab", 1)
            check(held.polls[1].condition(), "the actual current title changed")
            held.polls[1].reply(true)
            expect(said(), ["Third public tab, tab"])
            held.polls[1].reply(true)
            expect(said().count, 1, "a completion cannot apply twice")
            expect(held.delivered.value, 2, "both switching keys still go to Safari")
        }
    }
    test("Safari: actual Find scripts supersede held matches and retain the current not-found reply") {
        withSafari { module, held, said, _ in
            let focus = TurnOverObject(element: AXReplay.element(3))
            module.handleEvent(Event(.gainFocus, focus), next: {})
            check(module.script(for: KeyboardGesture(identifier: "kb:enter")!)?.name == "safari_findInBar", "real Find Banner event enables the script")
            invoke(module, "safari_findInBar", "kb:enter")
            invoke(module, "safari_findAgain", "kb:command+g")
            expect(held.delayed.count, 2)
            guard held.delayed.count == 2 else { return }
            let before = AXStats.calls
            held.delayed[0]()
            expect(AXStats.calls, before, "superseded find does no more AX work")
            expect(said(), [])
            held.delayed[1]()
            expect(said(), ["not found"], "the current reply still follows the actual WebKit selection path")
            expect(held.delivered.value, 2)
        }
    }
    test("Safari: lose-focus event and termination invalidate actual queued Find callbacks") {
        for terminate in [false, true] {
            withSafari { module, held, said, _ in
                invoke(module, "safari_findAgain", "kb:command+g")
                guard held.delayed.count == 1 else { return Harness.fail("Find callback was held") }
                if terminate { module.terminate() }
                else { module.handleEvent(Event(.appModuleLoseFocus, TurnOverObject(element: AXReplay.element(3))), next: {}) }
                // Even a subsequent return to the same app cannot revive this request.
                held.current = true
                let before = AXStats.calls
                held.delayed[0]()
                expect(AXStats.calls, before)
                expect(said(), [])
                if terminate {
                    invoke(module, "safari_findAgain", "kb:command+g")
                    expect(held.delayed.count, 1, "a terminated module cannot create a new reply")
                }
            }
        }
    }
    test("Safari: changed reader context or a newly arrived key suppresses held replies before AX reads") {
        for newKey in [false, true] {
            withSafari { module, held, said, _ in
                invoke(module, "safari_switchTab", "kb:control+tab")
                guard held.polls.count == 1 else { return Harness.fail("tab callback was held") }
                if newKey { held.keys.value += 1 } else { held.current = false }
                let before = AXStats.calls
                if newKey { check(held.polls[0].condition(), "worker notices a new physical key before more AX calls") }
                held.polls[0].reply(true)
                expect(AXStats.calls, before)
                expect(said(), [])
            }
        }
    }
    test("Safari: a new focused window cannot receive an older tab or Find reply") {
        for tab in [false, true] {
            withSafari { module, held, said, update in
                invoke(module, tab ? "safari_switchTab" : "safari_findAgain", tab ? "kb:control+tab" : "kb:command+g")
                update("New public title", 5)
                if tab {
                    guard held.polls.count == 1 else { return Harness.fail("tab callback was held") }
                    held.polls[0].reply(true)
                } else {
                    guard held.delayed.count == 1 else { return Harness.fail("Find callback was held") }
                    held.delayed[0]()
                }
                expect(said(), [], "window CF identity is rechecked before feedback")
            }
        }
    }
    test("Safari: actual reload and history scripts cancel earlier deferred feedback") {
        for reload in [false, true] {
            withSafari { module, held, said, _ in
                invoke(module, "safari_findAgain", "kb:command+g")
                invoke(module, reload ? "safari_reload" : "safari_backForward", reload ? "kb:command+r" : "kb:command+[")
                guard held.delayed.count == 1 else { return Harness.fail("Find callback was held") }
                let before = AXStats.calls
                held.delayed[0]()
                expect(AXStats.calls, before)
                expect(said(), reload ? ["reload page"] : [])
                expect(held.delivered.value, 2)
            }
        }
    }
}
