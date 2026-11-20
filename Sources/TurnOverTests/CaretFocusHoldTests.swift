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
        press(KeyboardGesture(identifier: identifier)!)
    }
    func press(_ key: KeyboardGesture) -> Bool {
        ScriptHandler.noteKeyArrived(key)
        return InputManager.handleKeyDown(key)
    }
    func focusEvent(_ id: Int, page: BrowseModeDocument) {
        let field = ObjectFactory.make(AXReplay.element(id))
        API.setFocusObject(field, ancestors: [], interceptor: page)
        EventHandler.execute(.gainFocus, on: field)
        // The held keys go one at a time, each once the one before has passed the (simulated) tap: a few turns.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    /// What the app and the log see while a hold is tried (16 Nov 2026, review).
    final class Seen: @unchecked Sendable {
        let trial: ModeWordsTrial
        let page: BrowseModeDocument
        /// Every key sent on to the application, in order, by either poster.
        let sent = Locked<[String]>([])
        let gestures = Locked<[KeyboardGesture]>([])
        /// Whether the simulated tap sees each key sent in order pass it at once. False: it is busy with a real key.
        let tapSees = Locked(true)
        let lines = Locked<[String]>([])
        var edges = 0
        init(trial: ModeWordsTrial, page: BrowseModeDocument) { self.trial = trial; self.page = page }
        func linesSince(_ count: Int) -> [String] { Array(lines.value.dropFirst(count)) }
    }

    /// F has been pressed and the Prompt's focus has been asked for; the focus event has not come. The page has, after
    /// the Prompt, an unrelated field (5); the Prompt holds an inner field (4).
    func withPendingFocus(_ body: (Seen) -> Void) {
        let savedFocus = API.focusObject, savedAncestors = API.focusAncestors, savedPage = API.focusTreeInterceptor
        let savedPid = AXHandler.shared.activePid, savedPoster = KeyboardGesture.poster, savedOrdered = KeyboardGesture.orderedPoster
        let savedPluginTypes = GlobalPluginHandler.shared.plugins.map { type(of: $0) }
        let savedStyle = config.general.keyboardStyle, savedHelp = InputManager.isInputHelpActive
        let savedObserver = Log.observer, savedLevel = Log.level, savedOnEdge = Tones.onEdge, savedEdgeSound = Tones.edgeSound
        let trial = ModeWordsTrial()
        AXReplay.load(.init(app: "Public hold trial", bundle: "test.claude-hold", recorded: "synthetic", root: 0, application: 1, focus: 2, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.com/hold"), "AXParent": .element(1), "AXChildren": .elements([2, 3, 5])]),
            .init(id: 1, attrs: ["AXRole": .string("AXApplication"), "AXFocusedUIElement": .element(2)]),
            .init(id: 2, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("Copy"), "AXParent": .element(0)]),
            .init(id: 3, attrs: ["AXRole": .string("AXTextArea"), "AXTitle": .string("Prompt"), "AXValue": .string(""), "AXSelectedTextRange": .range(0, 0), "AXParent": .element(0), "AXChildren": .elements([4])]),
            .init(id: 4, attrs: ["AXRole": .string("AXTextField"), "AXValue": .string(""), "AXSelectedTextRange": .range(0, 0), "AXParent": .element(3)]),
            .init(id: 5, attrs: ["AXRole": .string("AXTextField"), "AXTitle": .string("Search"), "AXValue": .string(""), "AXSelectedTextRange": .range(0, 0), "AXParent": .element(0)])
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
        let seen = Seen(trial: trial, page: page)
        KeyboardGesture.poster = { g in seen.sent.value.append(g.identifier); seen.gestures.value.append(g) }
        // The tap: a key sent in order passes it a moment later, unless it is busy with a real key.
        KeyboardGesture.orderedPoster = { g in
            seen.sent.value.append(g.identifier); seen.gestures.value.append(g)
            if seen.tapSees.value { DispatchQueue.main.async { ScriptHandler.orderedKeySeen() } }
        }
        Log.level = .io
        Log.observer = { line in seen.lines.value.append(line) }
        Tones.onEdge = { seen.edges += 1 }
        Tones.edgeSound = { _ in }
        defer {
            BrowseModeDocument.releaseCaretHold(because: "the test is over")
            ScriptHandler.setCaretHoldGate(holding: false, navigation: nil)
            ScriptHandler.resetOrderedLane()
            API.setFocusObject(savedFocus, ancestors: savedAncestors, interceptor: savedPage)
            AXHandler.shared.activePid = savedPid
            KeyboardGesture.poster = savedPoster
            KeyboardGesture.orderedPoster = savedOrdered
            Log.observer = savedObserver
            Log.level = savedLevel
            Tones.onEdge = savedOnEdge
            Tones.edgeSound = savedEdgeSound
            config.general.keyboardStyle = savedStyle
            InputManager.isInputHelpActive = savedHelp
            if TurnOverMenu.shared.isOpen { TurnOverMenu.shared.close() }   // VO-H, tried below, opens the help menu
            GlobalPluginHandler.shared.terminateAll()
            for pluginType in savedPluginTypes { GlobalPluginHandler.shared.register(pluginType) }
            AXReplay.unload()
            trial.restore()
        }
        check(press("kb:f"), "F is handled as field navigation")
        trial.drain()
        check(AXReplay.sets.contains { $0.id == 3 && $0.attribute == kAXFocusedAttribute }, "F asked the app for the Prompt's focus")
        check(!page.passThrough, "the focus event has not come, so browse mode is still on")
        body(seen)
    }
    func withPendingFocus(_ body: (ModeWordsTrial, BrowseModeDocument, Locked<[String]>) -> Void) {
        withPendingFocus { seen in body(seen.trial, seen.page, seen.sent) }
    }
    func heldLine(_ line: String) -> Bool { line.contains("held until the field takes the focus") }

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

    // The review of 16 Nov 2026 (S7): this test called offerKeyToCaretFocus, so it showed only the count. Now each key
    // goes in as a key does, and the test checks what it then does: never held, its command runs or it goes straight to
    // the application, and the request is over. (What each command then does on the page is its own tests' business:
    // Tab or Return onto the field rightly turns focus mode on by the ordinary rule.)
    test("caret focus hold: Return, Tab, the arrows, Escape and VoiceOver's keys are never held") {
        let never = ["kb:enter", "kb:tab", "kb:shift+tab", "kb:downArrow", "kb:upArrow", "kb:leftArrow", "kb:rightArrow", "kb:escape",
                     "kb:turnover+rightArrow", "kb:turnover+h", "kb:control+option+space", "kb:command+a", "kb:option+a", "kb:numpadEnter"]
        for identifier in never {
            withPendingFocus { seen in
                let key = KeyboardGesture(identifier: identifier)!
                check(!key.isTypingKeyForCaretFocus, "\(identifier) is not a typing key")
                guard let request = seen.page.newestCaretRequest else { Harness.fail("a request is pending"); return }
                let before = seen.lines.value.count
                let taken = press(key)
                seen.trial.drain()
                let lines = seen.linesSince(before)
                check(!lines.contains(where: heldLine), "\(identifier) is not held")
                let ranCommand = lines.contains { $0.hasPrefix("script ") }
                check(taken ? (ranCommand || key.isTurnOverModifier) : !ranCommand,
                      "\(identifier) runs its command, or goes straight to the application (taken \(taken))")
                check(seen.page.caretFocusFailure(request) != nil, "\(identifier) ends the request, as before")
                // The key's own work (a press, a focus move) settles before the next key is tried.
                RunLoop.current.run(until: Date().addingTimeInterval(0.6))
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

    // S6: Shift F straight after F is the previous field, never a capital F typed into the field.
    test("caret focus hold: Shift with the quick navigation key is a command, not a capital held for the field") {
        withPendingFocus { seen in
            check(press("kb:x"), "a letter is held")
            let before = seen.lines.value.count
            check(press("kb:shift+f"), "Shift F is taken, as the command it is")
            seen.trial.drain()
            let lines = seen.linesSince(before)
            check(!lines.contains(where: heldLine), "Shift F is not held")
            check(lines.contains { $0.hasPrefix("script ") && $0.hasSuffix("for kb:shift+f") }, "Shift F ran its command")
            focusEvent(3, page: seen.page)
            check(!seen.page.passThrough, "Shift F superseded the request")
            check(!seen.sent.value.contains("kb:shift+f") && !seen.sent.value.contains("kb:x"), "nothing was typed into the field")
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

    // S7: this test called offerKeyToCaretFocus for the arrow and never ran it. Now the arrow goes in as a key does, and
    // the log shows the held letter's command ran before the arrow's.
    test("caret focus hold: a key that is not typing sends the held ones on first, as commands") {
        withPendingFocus { seen in
            let words = seen.trial.words.count
            check(press("kb:x"), "a letter is held")
            let before = seen.lines.value.count
            _ = press("kb:downArrow")
            seen.trial.drain()
            let scripts = seen.linesSince(before).filter { $0.hasPrefix("script ") }
            check(scripts.count >= 2, "the held letter and the arrow both ran their commands (\(scripts.count))")
            check(scripts.first?.hasSuffix("for (a typed key)") == true, "the held letter's command ran first")
            check(scripts.dropFirst().contains { $0.hasSuffix("for kb:downArrow") }, "the arrow's command ran after it")
            check(seen.trial.words.count > words, "the held letter's command was heard")
            focusEvent(3, page: seen.page)
            expect(seen.sent.value, [], "nothing was typed into the field")
            check(!seen.page.passThrough, "the arrow superseded the request")
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

    // M1: the keys held are sent while a real key may already be waiting at the tap. That key, let through, would reach
    // the field before them ("lhe" for "hel"); it is taken and sent behind them instead.
    test("caret focus hold: a key typed while the held keys are on their way reaches the field after them") {
        withPendingFocus { seen in
            check(press("kb:h"), "h is held")
            check(press("kb:e"), "e is held")
            seen.tapSees.value = false   // the tap is busy with the next key, so what is sent has not passed it yet
            focusEvent(3, page: seen.page)
            check(seen.page.passThrough, "focus mode is on")
            expect(seen.sent.value, ["kb:h"], "one held key is sent; the next waits until it has passed the tap")
            check(press("kb:l"), "l, typed meanwhile, is taken, not let through ahead of the held keys")
            expect(seen.sent.value, ["kb:h"], "l is not sent ahead of e")
            for _ in 0..<3 { ScriptHandler.orderedKeySeen(); seen.trial.drain() }
            expect(seen.sent.value, ["kb:h", "kb:e", "kb:l"], "the field gets the keys in the order they were typed")
            seen.tapSees.value = true
            check(!press("kb:o"), "once they have all passed the tap, keys go straight to the application again")
            expect(seen.sent.value, ["kb:h", "kb:e", "kb:l"], "and are not sent again")
        }
    }

    // M1, the release path: a Backspace held, then Tab. The Backspace goes before the Tab, not after it into the control
    // the Tab reaches.
    test("caret focus hold: a key that frees the hold goes after the held keys") {
        withPendingFocus { seen in
            check(press("kb:backspace"), "Backspace is held")
            seen.tapSees.value = false
            let before = seen.lines.value.count
            check(press("kb:tab"), "Tab is taken while the held Backspace is sent ahead of it")
            seen.trial.drain()
            expect(seen.sent.value, ["kb:backspace"], "the held Backspace is sent first, to the control that had the focus")
            for _ in 0..<2 { ScriptHandler.orderedKeySeen(); seen.trial.drain() }
            let tabRanOrSent = seen.sent.value == ["kb:backspace", "kb:tab"] ||
                seen.linesSince(before).contains { $0.hasPrefix("script ") && $0.hasSuffix("for kb:tab") }
            check(tabRanOrSent, "Tab comes after it (sent \(seen.sent.value))")
            check(seen.sent.value.first == "kb:backspace", "nothing went ahead of the Backspace")
        }
    }

    // S1: a held Backspace is a Backspace typed in the field: its command runs, with the edge sound in an empty field.
    test("caret focus hold: a held Backspace runs the field's own command when it is delivered") {
        withPendingFocus { seen in
            check(press("kb:backspace"), "Backspace is held")
            let edges = seen.edges, before = seen.lines.value.count
            focusEvent(3, page: seen.page)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            let lines = seen.linesSince(before)
            check(lines.contains { $0.hasPrefix("script caret_backspaceCharacter for (a typed key)") }, "the field's Backspace command ran")
            check(lines.contains { $0.contains("an empty field, nothing to delete") }, "it found the field empty")
            check(seen.edges > edges, "the edge sound for an empty field")
            expect(seen.sent.value, ["kb:backspace"], "and the key reached the field, once")
        }
    }

    // A capital typed before the focus event is still a capital when it is sent: its Shift and its text go with it.
    test("caret focus hold: a held capital keeps its Shift when it is sent") {
        withPendingFocus { seen in
            let capital = KeyboardGesture(keyCode: 0, modifiers: .shift, characters: "A", timestamp: 0, isRepeat: false, flags: .maskShift)
            check(press(capital), "a capital is held")
            focusEvent(3, page: seen.page)
            guard let sent = seen.gestures.value.first else { Harness.fail("the capital was sent"); return }
            check(sent.flags.contains(.maskShift), "it carries Shift")
            check(sent.modifiers == .shift, "it is still Shift A")
            expect(sent.characters, "A", "its text is the capital")
        }
    }

    // S2: the focus comes on the Prompt's inner field, not the Prompt itself.
    test("caret focus hold: the focus on a part of the field asked for takes the held keys") {
        withPendingFocus { seen in
            check(press("kb:x"), "a letter is held")
            focusEvent(4, page: seen.page)
            check(seen.page.passThrough, "focus mode is on for the inner field")
            expect(seen.sent.value, ["kb:x"], "the held letter went to it at once, not after the request ran out")
            check(!press("kb:y"), "the next letter goes straight to the application")
        }
    }

    // S2 and S3: the focus comes on another field. The held keys are never typed into it.
    test("caret focus hold: the focus on another field drops the held keys, with the edge sound") {
        withPendingFocus { seen in
            let words = seen.trial.words.count
            check(press("kb:x"), "a letter is held")
            let edges = seen.edges
            focusEvent(5, page: seen.page)
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            expect(seen.sent.value, [], "nothing was typed into the other field")
            check(seen.edges > edges, "the edge sound says the keys were not typed")
            check(seen.lines.value.contains { $0.contains("held typing key(s) dropped") }, "the log says they were dropped")
            check(!seen.lines.value.contains { $0.hasPrefix("script ") && $0.hasSuffix("for (a typed key)") }, "the letter did not run as a command either")
            _ = words
        }
    }

    // S3: the page and the application go away while keys are held. Nothing is typed anywhere, nothing runs.
    test("caret focus hold: keys held when the page goes away are dropped, not typed into what is in front") {
        withPendingFocus { seen in
            let words = seen.trial.words.count
            check(press("kb:x"), "a letter is held")
            check(press("kb:backspace"), "Backspace is held")
            let edges = seen.edges
            API.setFocusObject(nil, ancestors: [], interceptor: nil)
            AXHandler.shared.activePid = 4242
            RunLoop.current.run(until: Date().addingTimeInterval(0.65))
            expect(seen.sent.value, [], "nothing was sent to the application now in front")
            expect(seen.trial.words.count, words, "the letter did not run as a command anywhere")
            check(seen.edges > edges, "the edge sound says the keys were not typed")
            check(seen.lines.value.contains { $0.contains("2 held typing key(s) dropped") }, "the log says both were dropped")
        }
    }

    // S5: once focus mode is on (the confirmation path turns it on before the focus event is handled), typing keys go
    // straight to the field, never held again for the request still pending.
    test("caret focus hold: once focus mode is on, typing keys are not held again") {
        withPendingFocus { seen in
            seen.page.passThrough = true
            let before = seen.lines.value.count
            check(!press("kb:x"), "a letter goes straight to the application")
            check(!seen.linesSince(before).contains(where: heldLine), "it was not held")
        }
    }

    // The log never says which key was typed, held or delivered.
    test("caret focus hold: the log names no key typed for the field") {
        withPendingFocus { seen in
            let before = seen.lines.value.count
            check(press("kb:x"), "a letter is held")
            check(press("kb:backspace"), "Backspace is held")
            focusEvent(3, page: seen.page)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            let lines = seen.linesSince(before)
            check(!lines.isEmpty, "the hold and the delivery are logged")
            check(lines.contains { $0.contains("(a typed key)") }, "the keys appear as typed keys")
            for line in lines { check(!line.contains("kb:x") && !line.contains("kb:backspace"), "no line names the key: \(line.prefix(60))") }
        }
    }
}
