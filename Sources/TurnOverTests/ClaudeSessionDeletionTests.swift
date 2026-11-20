// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore
import TurnOverAX
import AXFixtures

func claudeSessionDeletionTests() {
    func fixture(_ body: (ClaudeSessionDeletion, (Int, Bool) -> Void, () -> [String], Locked<[String]>) -> Void) {
        let savedFocus = API.focusObject, savedAncestors = API.focusAncestors, savedPage = API.focusTreeInterceptor
        let savedPoster = KeyboardGesture.poster
        AXReplay.load(.init(app: "Public deletion trial", bundle: "test.claude-deletion", recorded: "synthetic", root: 0, application: 1, focus: 2, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXParent": .element(1)]),
            .init(id: 1, attrs: ["AXRole": .string("AXApplication")]),
            .init(id: 2, attrs: ["AXRole": .string("AXPopUpButton"), "AXTitle": .string("More options for Public session"), "AXParent": .element(0)]),
            .init(id: 3, attrs: ["AXRole": .string("AXGroup"), "AXSubrole": .string("AXApplicationDialog"), "AXTitle": .string("Delete session?"), "AXParent": .element(0)]),
            .init(id: 4, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("Delete this session"), "AXParent": .element(3)]),
            .init(id: 5, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("Delete 2 sessions"), "AXParent": .element(3)]),
            .init(id: 6, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("Cancel"), "AXParent": .element(3)]),
            .init(id: 7, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("Another public session"), "AXParent": .element(0)]),
            .init(id: 8, attrs: ["AXRole": .string("AXMenuItem"), "AXTitle": .string("Delete"), "AXParent": .element(0)]),
            .init(id: 9, attrs: ["AXRole": .string("AXTextArea"), "AXTitle": .string("Prompt"), "AXParent": .element(0)]),
            .init(id: 10, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("Delete"), "AXParent": .element(3)]),
            .init(id: 11, attrs: ["AXRole": .string("AXGroup"), "AXTitle": .string("More options for Public session"), "AXParent": .element(0)]),
            .init(id: 12, attrs: ["AXRole": .string("AXGroup"), "AXTitle": .string("More options for Another public session"), "AXParent": .element(0)])
        ]))
        let page = BrowseModeDocument(webArea: AXReplay.element(0))
        let owner = ClaudeSessionDeletion()
        var words: [String] = []
        owner.say = { words.append($0) }
        let sent = Locked<[String]>([])
        KeyboardGesture.poster = { sent.value.append($0.identifier) }
        func focus(_ id: Int, _ inDialog: Bool) {
            let object = ObjectFactory.make(AXReplay.element(id))
            API.setFocusObject(object, ancestors: inDialog ? [ObjectFactory.make(AXReplay.element(3))] : [], interceptor: page)
            owner.observe(Event(.gainFocus, object))
        }
        defer {
            owner.cancel()
            KeyboardGesture.poster = savedPoster
            API.setFocusObject(savedFocus, ancestors: savedAncestors, interceptor: savedPage)
            AXReplay.unload()
        }
        body(owner, focus, { words }, sent)
    }

    test("Claude deletion: single-session Delete survives menu and dialog navigation and acknowledges once") {
        fixture { owner, focus, words, sent in
            focus(2, false)
            focus(11, false)
            focus(8, false)
            focus(10, true)
            focus(6, true)
            check(!owner.canActivate, "Cancel retains its native action")
            focus(10, true)
            let key = KeyboardGesture(identifier: "kb:enter")!
            check(owner.activate(key), "the single-session Delete button is recognized")
            check(!owner.activate(key), "a repeated Return cannot reuse the submitted subject")
            expect(sent.value, ["kb:enter"], "the deletion sends one native Return")
            expect(words(), ["Deleting Public session"], "one acknowledgement names the requested session")
            check(AXReplay.actions.isEmpty, "there is no destructive AXPress retry")
        }
    }

    test("Claude deletion: both confirmation scopes send one native key and name the requested session") {
        fixture { owner, focus, words, sent in
            for (id, key, expected) in [(4, "kb:enter", "Deleting Public session"),
                                        (5, "kb:space", "Deleting Public session, 2 sessions")] {
                focus(2, false)
                focus(8, false)
                focus(id, true)
                check(owner.canActivate, "the recognized confirmation retains the session menu's subject")
                check(owner.activate(KeyboardGesture(identifier: key)!), "the confirmation is handled")
                expect(words().last, expected, "feedback names the request without claiming completed deletion")
                check(!owner.activate(KeyboardGesture(identifier: key)!), "the submitted subject cannot be reused")
            }
            expect(sent.value, ["kb:enter", "kb:space"], "each physical confirmation is posted once")
            check(AXReplay.actions.isEmpty, "no AXPress fallback can repeat the destructive operation")
        }
    }

    test("Claude deletion: Cancel, unrelated controls and missing subjects cannot claim deletion") {
        fixture { owner, focus, words, sent in
            focus(4, true)
            check(!owner.canActivate, "a dialog without a known session subject is left native")
            focus(2, false)
            focus(6, true)
            check(!owner.canActivate, "Cancel is never treated as a deletion")
            focus(4, false)
            check(!owner.canActivate, "a similarly named button outside the confirmation is left native")
            focus(2, false)
            focus(7, false)
            focus(4, true)
            check(!owner.canActivate, "moving to another session invalidates the captured subject")
            focus(2, false)
            focus(9, false)
            focus(4, true)
            check(!owner.canActivate, "returning to Prompt invalidates the captured subject")
            focus(2, false)
            focus(10, false)
            check(!owner.canActivate, "Delete outside the confirmation is left native")
            focus(2, false)
            focus(12, false)
            focus(10, true)
            check(!owner.canActivate, "another session's menu group invalidates the captured subject")
            expect(words(), [], "observing focus alone never claims success")
            expect(sent.value, [], "guards do not send keys")
        }
    }

    test("Claude deletion: VO-Space uses one Return and departure cancels the subject") {
        fixture { owner, focus, words, sent in
            focus(2, false)
            focus(5, true)
            check(owner.activate(KeyboardGesture(identifier: "kb:turnover+space")!, useReturn: true), "VO-Space is handled by native Return")
            expect(sent.value, ["kb:enter"], "VO-Space posts exactly one Return")
            expect(words(), ["Deleting Public session, 2 sessions"], "scope is acknowledged without inventing a child name")
            focus(2, false)
            owner.observe(Event(.appModuleLoseFocus, ObjectFactory.make(AXReplay.element(2))))
            focus(4, true)
            check(!owner.canActivate, "leaving Claude clears the operation context")
        }
    }

    test("Claude deletion: the real module routes VO-Space confirmation before menu activation") {
        fixture { _, focus, _, sent in
            let module = ClaudeAppModule(pid: AXReplay.element(0).pid, bundleIdentifier: "com.anthropic.claudefordesktop", appName: "Claude")
            let savedSink = Speech.sink
            var words: [String] = []
            Speech.sink = { words.append($0) }
            defer { Speech.sink = savedSink }
            focus(2, false)
            module.handleEvent(Event(.gainFocus, API.focusObject!)) {}
            focus(5, true)
            module.handleEvent(Event(.gainFocus, API.focusObject!)) {}
            let key = KeyboardGesture(identifier: "kb:turnover+space")!
            let command = module.script(named: "vo_defaultAction")
            check(command?.isAvailable?() == true, "VoiceOver's named app action accepts the confirmation")
            command?.handler(key)
            expect(sent.value, ["kb:enter"], "the module sends exactly one native Return")
            expect(words, ["Deleting Public session, 2 sessions"], "the module supplies scoped request feedback")
        }
    }

    test("Claude deletion: its script overrides browse activation only for the confirmation") {
        fixture { owner, focus, words, sent in
            let module = AppModule(pid: AXReplay.element(0).pid, bundleIdentifier: "test.claude-deletion", appName: "Public trial")
            owner.installScripts(on: module)
            let key = KeyboardGesture(identifier: "kb:numpadEnter")!
            focus(2, false)
            check(module.script(for: key) == nil, "ordinary session controls retain existing routing")
            focus(11, false)
            focus(8, false)
            focus(10, true)
            guard let script = module.script(for: key) else { Harness.fail("the confirmation script is available"); return }
            script.handler(key)
            expect(sent.value, ["kb:numpadEnter"], "numpad Return is preserved")
            expect(words(), ["Deleting Public session"], "the registered script supplies request feedback")
        }
    }
}
