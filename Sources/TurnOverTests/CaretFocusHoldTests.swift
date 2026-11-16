// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import TurnOverAX
import AXFixtures

// Keys typed while the focus of an editable field, just asked for by quick navigation, has not yet arrived (16 Nov 2026:
// a Backspace 8 ms after the Prompt's focus event left browse mode on, and the log showed no line for the request).
// The fixture is the real F routing test's page, with the native focus on the Copy button, so that F asks for the
// Prompt's focus and waits for the event instead of finding it already there.
func caretFocusHoldTests() {
    /// What a key does on its way in: the tap counts it, then the main thread handles it (tests do not go through askMain).
    func press(_ identifier: String) -> Bool {
        let key = KeyboardGesture(identifier: identifier)!
        ScriptHandler.noteKeyArrived(key)
        return InputManager.handleKeyDown(key)
    }
    func focusEvent(_ id: Int, page: BrowseModeDocument) {
        let field = ObjectFactory.make(AXReplay.element(id))
        API.setFocusObject(field, ancestors: [], interceptor: page)
        EventHandler.execute(.gainFocus, on: field)
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }

    /// F has been pressed and the Prompt's focus has been asked for; the focus event has not come.
    func withPendingFocus(_ body: (ModeWordsTrial, BrowseModeDocument, Locked<[String]>) -> Void) {
        let savedFocus = API.focusObject, savedAncestors = API.focusAncestors, savedPage = API.focusTreeInterceptor
        let savedPid = AXHandler.shared.activePid, savedPoster = KeyboardGesture.poster
        let savedPluginTypes = GlobalPluginHandler.shared.plugins.map { type(of: $0) }
        let savedStyle = config.general.keyboardStyle
        let trial = ModeWordsTrial()
        AXReplay.load(.init(app: "Public hold trial", bundle: "test.claude-hold", recorded: "synthetic", root: 0, application: 1, focus: 2, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.com/hold"), "AXParent": .element(1), "AXChildren": .elements([2, 3])]),
            .init(id: 1, attrs: ["AXRole": .string("AXApplication"), "AXFocusedUIElement": .element(2)]),
            .init(id: 2, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("Copy"), "AXParent": .element(0)]),
            .init(id: 3, attrs: ["AXRole": .string("AXTextArea"), "AXTitle": .string("Prompt"), "AXValue": .string(""), "AXSelectedTextRange": .range(0, 0), "AXParent": .element(0)])
        ]))
        let root = AXReplay.element(0)
        let page = BrowseModeDocument(webArea: root)
        page.buffer.buildForInspection()
        waitForBuffer(page.buffer)
        config.general.keyboardStyle = "mac"
        config.virtualBuffers.autoPassThroughOnCaretMove = true
        GlobalPluginHandler.shared.terminateAll()
        GlobalPluginHandler.shared.register(VoiceOverKeysPlugin.self)
        AXHandler.shared.activePid = root.pid
        API.setFocusObject(ObjectFactory.make(AXReplay.element(2)), ancestors: [], interceptor: page)
        page.position = page.buffer.offset(of: AXReplay.element(2)) ?? 0
        page.passThrough = false
        let sent = Locked<[String]>([])
        KeyboardGesture.poster = { sent.value.append($0.identifier) }
        defer {
            BrowseModeDocument.releaseCaretHold(because: "the test is over")
            ScriptHandler.setCaretHoldGate(holding: false, navigation: nil)
            API.setFocusObject(savedFocus, ancestors: savedAncestors, interceptor: savedPage)
            AXHandler.shared.activePid = savedPid
            KeyboardGesture.poster = savedPoster
            config.general.keyboardStyle = savedStyle
            GlobalPluginHandler.shared.terminateAll()
            for pluginType in savedPluginTypes { GlobalPluginHandler.shared.register(pluginType) }
            AXReplay.unload()
            trial.restore()
        }
        check(press("kb:f"), "F is handled as field navigation")
        trial.drain()
        check(AXReplay.sets.contains { $0.id == 3 && $0.attribute == kAXFocusedAttribute }, "F asked the app for the Prompt's focus")
        check(!page.passThrough, "the focus event has not come, so browse mode is still on")
        body(trial, page, sent)
    }

    test("caret focus hold: a letter and Backspace typed before the focus event go into the field once, in order") {
        withPendingFocus { trial, page, sent in
            let words = trial.words.count
            check(press("kb:x"), "a letter is handled, not passed on, while the focus is awaited")
            check(press("kb:backspace"), "Backspace is handled, not passed on, while the focus is awaited")
            check(press("kb:space"), "Space is handled, not passed on, while the focus is awaited")
            trial.drain()
            expect(sent.value, [], "nothing reaches the app before its focus is on the field")
            expect(trial.words.count, words, "none of the held keys ran as a browse command")
            check(!AXReplay.actions.contains { $0.action == "AXPress" }, "Space did not press anything")
            focusEvent(3, page: page)
            check(page.passThrough, "the focus event is accepted and focus mode goes on")
            expect(sent.value, ["kb:x", "kb:backspace", "kb:space"], "the held keys are sent to the field in order")
            // Nothing is delivered twice: a second event for the field, and the request's whole lifetime.
            focusEvent(3, page: page)
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            expect(sent.value, ["kb:x", "kb:backspace", "kb:space"], "the held keys are sent once")
            // As in the real F routing test: after the field has the focus, letters and Space go straight to the app.
            for identifier in ["kb:i", "kb:t", "kb:f", "kb:space"] {
                check(!press(identifier), "\(identifier) goes directly to the application")
            }
        }
    }

    test("caret focus hold: Backspace alone is held and delivered, and focus mode stays on") {
        withPendingFocus { _, page, sent in
            check(press("kb:backspace"), "Backspace is held")
            expect(sent.value, [], "not yet sent")
            focusEvent(3, page: page)
            check(page.passThrough, "focus mode is on after the focus event, as the log of 16 Nov 2026 needed")
            expect(sent.value, ["kb:backspace"], "Backspace reaches the field")
        }
    }

    test("caret focus hold: Return, Tab, the arrows, Escape and VoiceOver's keys are never held") {
        let never = ["kb:enter", "kb:tab", "kb:shift+tab", "kb:downArrow", "kb:upArrow", "kb:leftArrow", "kb:rightArrow", "kb:escape",
                     "kb:turnover+rightArrow", "kb:turnover+h", "kb:control+option+space", "kb:command+a", "kb:option+a", "kb:numpadEnter"]
        for identifier in never {
            withPendingFocus { _, page, sent in
                let key = KeyboardGesture(identifier: identifier)!
                check(!key.isTypingKeyForCaretFocus, "\(identifier) is not a typing key")
                ScriptHandler.noteKeyArrived(key)
                check(!BrowseModeDocument.offerKeyToCaretFocus(key), "\(identifier) is not held")
                focusEvent(3, page: page)
                check(!page.passThrough, "\(identifier) supersedes the request, as before")
                expect(sent.value, [], "\(identifier): nothing is sent to the field")
            }
        }
        for identifier in ["kb:a", "kb:shift+a", "kb:space", "kb:backspace", "kb:delete", "kb:1", "kb:,"] {
            check(KeyboardGesture(identifier: identifier)!.isTypingKeyForCaretFocus, "\(identifier) can be held")
        }
        check(!KeyboardGesture(identifier: "kb:shift+backspace")!.isTypingKeyForCaretFocus, "only plain Backspace is held")
    }

    test("caret focus hold: the same quick navigation key again is a command, not held") {
        withPendingFocus { _, page, sent in
            check(press("kb:x"), "another letter is held")
            let again = KeyboardGesture(identifier: "kb:f")!
            ScriptHandler.noteKeyArrived(again)
            check(!BrowseModeDocument.offerKeyToCaretFocus(again), "F again is not held")
            focusEvent(3, page: page)
            check(!page.passThrough, "F again supersedes the request, as before")
            expect(sent.value, [], "the letter held before F again was not typed into a field that did not take the focus")
        }
    }

    test("caret focus hold: a request that fails runs the held keys as they would have run, once") {
        withPendingFocus { trial, page, sent in
            let words = trial.words.count
            check(press("kb:x"), "a letter is held")
            check(press("kb:i"), "a second letter is held")
            expect(sent.value, [], "nothing sent yet")
            // The field never takes the focus: the request runs out and the keys run as browse commands.
            RunLoop.current.run(until: Date().addingTimeInterval(0.65))
            expect(sent.value, [], "nothing is sent to a field that did not take the focus")
            check(trial.words.count > words, "the held keys ran as the commands they would have been")
            check(!page.passThrough, "browse mode stays on")
            let spoken = trial.words.count
            // A late event for the field neither delivers nor repeats anything.
            focusEvent(3, page: page)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            expect(sent.value, [], "a late focus event delivers nothing")
            expect(trial.words.count, spoken, "the keys do not run a second time")
        }
    }

    test("caret focus hold: a key that is not typing sends the held ones on first, as commands") {
        withPendingFocus { trial, page, sent in
            let words = trial.words.count
            check(press("kb:x"), "a letter is held")
            let down = KeyboardGesture(identifier: "kb:downArrow")!
            ScriptHandler.noteKeyArrived(down)
            check(!BrowseModeDocument.offerKeyToCaretFocus(down), "an arrow is not held")
            trial.drain()
            check(trial.words.count > words, "the held letter ran as its command, before the arrow")
            focusEvent(3, page: page)
            expect(sent.value, [], "nothing was typed into the field")
            check(!page.passThrough, "the arrow superseded the request")
        }
    }

    test("caret focus hold: a request that is thrown away has a reason the log can name") {
        withPendingFocus { _, page, _ in
            guard let request = page.newestCaretRequest else { Harness.fail("a request is pending"); return }
            check(page.caretFocusFailure(request) == nil, "the request is current while nothing has ended it")
            let down = KeyboardGesture(identifier: "kb:downArrow")!
            ScriptHandler.noteKeyArrived(down)
            expect(page.caretFocusFailure(request), "a key that is not typing came after it", "the condition that failed is named")
            page.position += 1
            expect(page.caretFocusFailure(request), "the reading position moved", "the first condition to fail is named")
        }
    }
}
