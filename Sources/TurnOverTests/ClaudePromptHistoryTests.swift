// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import TurnOverAX
import AXFixtures

private final class PromptHistoryTrial {
    var now = Date(timeIntervalSince1970: 100)
    var scheduled: [@MainActor () -> Void] = []
    var spoken: [String] = []
    var edges = 0
    let sent = Locked<[String]>([])
}

func claudePromptHistoryTests() {
    // Unhappy cases: unrelated/live value news, a late reply, another key, focus leaving and returning,
    // browse mode taking over, unchanged multiline edges, and other apps' history implementations.
    func withPrompt(_ value: String = "", caret: Int = 0,
                    _ body: (ClaudePromptText, BrowseModeDocument, ClaudeAppModule, PromptHistoryTrial) -> Void) {
        let focus = API.focusObject, ancestors = API.focusAncestors, pageBefore = API.focusTreeInterceptor
        let savedConfig = config, sink = Speech.sink, poster = KeyboardGesture.poster
        let sound = Tones.edgeSound, haptic = Tones.onEdge, keyAt = InputManager.lastKeyDownAt
        let trial = PromptHistoryTrial()
        AXReplay.load(.init(app: "Public prompt history", bundle: "test.prompt.history", recorded: "synthetic",
                            root: 0, application: 1, focus: 2, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXParent": .element(1)]),
            .init(id: 1, attrs: ["AXRole": .string("AXApplication")]),
            .init(id: 2, attrs: ["AXRole": .string("AXTextArea"), "AXTitle": .string("Prompt"),
                                 "AXValue": .string(value), "AXNumberOfCharacters": .number(Double(value.utf16.count)),
                                 "AXSelectedTextRange": .range(caret, 0), "AXFocused": .bool(true), "AXParent": .element(0)],
                  params: [kAXStringForRangeParameterizedAttribute, kAXLineForIndexParameterizedAttribute,
                           kAXRangeForLineParameterizedAttribute]),
            .init(id: 3, attrs: ["AXRole": .string("AXTextArea"), "AXTitle": .string("Search"),
                                 "AXValue": .string("Public live update"), "AXParent": .element(0)])
        ]))
        let module = ClaudeAppModule(pid: AXReplay.element(2).pid, bundleIdentifier: ClaudeTranscript.bundleID, appName: "Claude")
        let page = BrowseModeDocument(webArea: AXReplay.element(0))
        page.passThrough = true
        let field = ClaudePromptText(element: AXReplay.element(2))
        field.historyNow = { trial.now }
        field.historySchedule = { _, action in trial.scheduled.append(action) }
        Speech.sink = { trial.spoken.append($0) }
        let sent = trial.sent
        KeyboardGesture.poster = { sent.value.append($0.identifier) }
        Tones.edgeSound = { _ in trial.edges += 1 }
        Tones.onEdge = {}
        config.documentFormatting.tables = .off
        config.general.keyboardStyle = "mac"
        config.speech.sayCapForCapitals = false
        config.speech.capitalPitch = 0
        InputManager.lastKeyDownAt = trial.now
        API.setFocusObject(field, ancestors: [], interceptor: page)
        defer {
            module.terminate()
            API.setFocusObject(focus, ancestors: ancestors, interceptor: pageBefore)
            if let focus { ObjectNavigator.shared.focusMoved(to: focus.element, pid: focus.pid) }
            config = savedConfig
            Speech.sink = sink
            KeyboardGesture.poster = poster
            Tones.edgeSound = sound
            Tones.onEdge = haptic
            InputManager.lastKeyDownAt = keyAt
            AXReplay.unload()
        }
        body(field, page, module, trial)
    }
    func arrow(_ field: EditableText, _ name: String = "upArrow") {
        let key = KeyboardGesture(identifier: "kb:" + name)!
        field.script(named: "caret_moveByLine")?.handler(key)
    }
    func replace(_ value: String, caret: Int) {
        let field = AXReplay.element(2)
        _ = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, value as CFString)
        _ = AXUIElementSetAttributeValue(field, kAXNumberOfCharactersAttribute as CFString, NSNumber(value: value.utf16.count))
        _ = AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, axRangeValue(caret, 0))
    }
    func expire(_ trial: PromptHistoryTrial) {
        trial.now = trial.now.addingTimeInterval(ClaudePromptText.historyValueChangeWindow)
        let work = trial.scheduled
        trial.scheduled.removeAll()
        for action in work { action() }
    }

    test("Claude prompt history: Up reads the current caret line only after the value changes") {
        withPrompt { field, _, _, trial in
            arrow(field)
            expect(trial.sent.value, ["kb:upArrow"])
            expect(trial.edges, 1, "the unwaited edge sound remains immediate")
            expect(trial.spoken, [], "the pre-key line is not spoken")
            trial.now = trial.now.addingTimeInterval(0.04)
            replace("Public first line\nPublic recalled line", caret: 37)
            field.event_valueChange()
            expect(trial.spoken, ["Public recalled line"])
            field.event_valueChange()
            expire(trial)
            expect(trial.spoken, ["Public recalled line"], "duplicate news and expiry do not repeat the line")
        }
    }
    test("Claude prompt history: Down says blank instead of the line the key removed") {
        withPrompt("Public recalled line", caret: 20) { field, _, _, trial in
            arrow(field, "downArrow")
            expect(trial.spoken, [])
            trial.now = trial.now.addingTimeInterval(0.032)
            replace("", caret: 0)
            field.event_valueChange()
            expect(trial.spoken, [Phrases.blank])
            expect(trial.sent.value, ["kb:downArrow"])
        }
    }
    test("Claude prompt history: an unchanged multiline edge keeps its sound and does not read a line") {
        withPrompt("First line\nLast line") { field, _, _, trial in
            arrow(field)
            field.event_valueChange()
            expire(trial)
            expect(trial.edges, 1)
            expect(trial.spoken, [])
        }
    }
    test("Claude prompt history: unchanged one-line edge reading remains after the short window") {
        withPrompt("Public line") { field, _, _, trial in
            arrow(field)
            field.event_valueChange()
            expect(trial.spoken, [], "unchanged value news is not history recall")
            expire(trial)
            expect(trial.spoken, ["Public line"])
        }
    }
    test("Claude prompt history: live updates require this field and the recent edge key") {
        withPrompt { field, _, _, trial in
            replace("Live before a key", caret: 0)
            field.event_valueChange()
            expect(trial.spoken, [])
            arrow(field)
            EditableText(element: AXReplay.element(3)).event_valueChange()
            expect(trial.spoken, [], "another field's news cannot complete the pending edge")
            trial.now = trial.now.addingTimeInterval(ClaudePromptText.historyValueChangeWindow + 0.01)
            replace("Late live update", caret: 0)
            field.event_valueChange()
            expect(trial.spoken, [], "a notice after the window does not read the line itself")
            // Past the window the timer decides, as for a change with no notice: the line now at the caret (review,
            // 16 Nov 2026; until then this notice cancelled the read).
            expire(trial)
            expect(trial.spoken, ["Late live update"], "the timer reads the changed value's line")
        }
    }
    // Review, 16 Nov 2026: with the main thread busy, the value notice can be handled after the window but before the
    // timer fires. It used to drop the pending read, so the timer read nothing and the recalled message was silent.
    test("Claude prompt history: a notice handled after the window, before the timer, still reads the recall") {
        withPrompt { field, _, _, trial in
            arrow(field)
            trial.now = trial.now.addingTimeInterval(ClaudePromptText.historyValueChangeWindow + 0.05)
            replace("Public recalled line", caret: 20)
            field.event_valueChange()
            expect(trial.spoken, [], "the late notice leaves the decision to the timer")
            expire(trial)
            expect(trial.spoken, ["Public recalled line"], "the timer reads the recalled line once")
        }
    }
    test("Claude prompt history: an unreported replacement reads the new line, never the removed one") {
        withPrompt("Old public line") { field, _, _, trial in
            arrow(field)
            replace("New public line", caret: 0)
            expire(trial)
            expect(trial.spoken, ["New public line"], "the value changed without a notice: the line now at the caret")
        }
    }
    test("Claude prompt history: a simultaneous same-field update reads current text without assuming its cause") {
        withPrompt { field, _, _, trial in
            arrow(field)
            trial.now = trial.now.addingTimeInterval(0.04)
            replace("Public live replacement", caret: 0)
            field.event_valueChange()
            // AX value news has no cause identifier. Within the admitted window the honest result is
            // the current caret line, even if an independent update happened to replace this same field.
            expect(trial.spoken, ["Public live replacement"])
        }
    }
    test("Claude prompt history: later keys focus loss and browse mode retire pending speech") {
        for cancellation in ["key", "focus", "browse"] {
            withPrompt { field, page, _, trial in
                arrow(field)
                switch cancellation {
                case "key": InputManager.lastKeyDownAt = trial.now.addingTimeInterval(0.01)
                case "focus": field.event_loseFocus()
                default: page.passThrough = false
                }
                trial.now = trial.now.addingTimeInterval(0.04)
                replace("Public replacement", caret: 0)
                field.event_valueChange()
                expire(trial)
                expect(trial.spoken, [], cancellation)
            }
        }
    }
    test("Claude prompt history: a previous edge timer cannot consume a newer arrow") {
        withPrompt { field, _, _, trial in
            arrow(field)
            let firstExpiry = trial.scheduled.removeFirst()
            trial.now = trial.now.addingTimeInterval(0.02)
            InputManager.lastKeyDownAt = trial.now
            arrow(field)
            firstExpiry()
            replace("Public second recall", caret: 0)
            field.event_valueChange()
            expect(trial.spoken, ["Public second recall"])
        }
    }
    test("Claude prompt history: only Claude's editable Prompt receives the history overlay") {
        withPrompt("Public line") { field, _, module, trial in
            check(module.objectClass(for: field.element, role: .editableText, subrole: nil) == ClaudePromptText.self, "the Prompt receives the overlay")
            check(module.objectClass(for: field.element, role: .passwordEdit, subrole: nil) == nil, "a password field never receives the overlay")
            check(module.objectClass(for: AXReplay.element(3), role: .editableText, subrole: nil) == nil, "other Claude fields retain their class")
            BuiltInModules.register()
            if let terminalType = AppModuleHandler.shared.moduleType(for: "com.apple.Terminal") {
                let terminal = terminalType.init(pid: field.pid, bundleIdentifier: "com.apple.Terminal", appName: "Terminal")
                check(terminal.objectClass(for: field.element, role: .editableText, subrole: "AXTerminalTextArea") != ClaudePromptText.self, "Terminal retains its own history owner")
                terminal.terminate()
            } else { Harness.fail("Terminal's existing history owner remains registered") }
            let ordinary = EditableText(element: field.element)
            API.setFocusObject(ordinary, ancestors: [])
            arrow(ordinary)
            expect(trial.spoken, ["Public line"], "other apps keep their immediate edge reading")
            expect(trial.edges, 1)
        }
    }
    test("Claude prompt history: Say All resumption never adds delayed caret speech") {
        withPrompt("Public line") { field, _, _, trial in
            let resuming = SayAll.resuming
            defer { SayAll.resuming = resuming }
            SayAll.resuming = true
            arrow(field)
            SayAll.resuming = false
            replace("Public replacement", caret: 0)
            field.event_valueChange()
            expect(trial.scheduled.count, 0, "the resumed reader owns line output")
            expect(trial.spoken, [])
            expect(trial.edges, 1)
            expect(trial.sent.value, ["kb:upArrow"])
        }
    }
}
