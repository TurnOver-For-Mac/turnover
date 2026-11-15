// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import TurnOverAX
import AXFixtures

func claudeBrowserReturnTests() {
    func withReturn(promptCount: Int = 1, _ body: (ClaudeBrowserReturn, BrowseModeDocument, Locked<[String]>, Locked<[String]>, ScriptableObject) -> Void) {
        let focus = API.focusObject, ancestors = API.focusAncestors, before = API.focusTreeInterceptor
        let sink = Speech.sink, poster = KeyboardGesture.poster
        var fixture = AXFixture(app: "Public browser return", bundle: "test.claude-return", recorded: "synthetic", root: 0, application: 1, focus: 0, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.com/browser"), "AXParent": .element(1), "AXChildren": .elements([3])]),
            .init(id: 1, attrs: ["AXRole": .string("AXApplication"), "AXChildren": .elements([0, 2])]),
            .init(id: 2, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://claude.ai/epitaxy/public"), "AXParent": .element(1), "AXChildren": .elements([3])]),
            .init(id: 3, attrs: ["AXRole": .string("AXTextArea"), "AXTitle": .string("Prompt"), "AXParent": .element(0)]),
            .init(id: 4, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("Other control"), "AXParent": .element(0)])
        ])
        if let root = fixture.nodes.firstIndex(where: { $0.id == 0 }) {
            fixture.nodes[root].attrs["AXChildren"] = .elements(promptCount == 0 ? [] : promptCount == 2 ? [3, 4] : [3])
        }
        if promptCount == 2, let duplicate = fixture.nodes.firstIndex(where: { $0.id == 4 }) {
            fixture.nodes[duplicate].attrs["AXRole"] = .string("AXTextArea")
            fixture.nodes[duplicate].attrs["AXTitle"] = .string("Prompt")
        }
        AXReplay.load(fixture)
        let source = BrowseModeDocument(webArea: AXReplay.element(0))
        // Replay assigns a separate fake pid to each node. Reuse the root identity across
        // the two pages so the fixture preserves the production same-process boundary.
        _ = AXReplay.element(0).set("AXURL", "https://claude.ai/epitaxy/public" as CFString)
        let destination = BrowseModeDocument(webArea: AXReplay.element(0))
        waitForBuffer(source.buffer)
        waitForBuffer(destination.buffer)
        API.setFocusObject(ObjectFactory.make(AXReplay.element(0)), ancestors: [], interceptor: source)
        let owner = ScriptableObject()
        let state = ClaudeBrowserReturn(pid: AXReplay.element(0).pid)
        let sent = Locked<[String]>([]), said = Locked<[String]>([])
        KeyboardGesture.poster = { sent.value.append($0.identifier) }
        Speech.sink = { said.value.append($0) }
        let shortcut = KeyboardGesture(identifier: "kb:command+shift+b")!
        state.script(for: shortcut, owner: owner)?.handler(shortcut)
        API.setFocusObject(ObjectFactory.make(AXReplay.element(0)), ancestors: [], interceptor: destination)
        destination.passThrough = false
        defer {
            state.cancel()
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
            Speech.sink = sink; KeyboardGesture.poster = poster
            API.setFocusObject(focus, ancestors: ancestors, interceptor: before)
            AXReplay.unload()
        }
        body(state, destination, sent, said, owner)
    }
    func waitForConfirmation(_ ready: () -> Bool) {
        let deadline = Date().addingTimeInterval(1)
        while !ready(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        check(ready(), "the destination Prompt was validated on the worker")
    }
    func type(_ text: String, state: ClaudeBrowserReturn, owner: ScriptableObject) {
        for letter in text {
            let key = KeyboardGesture(identifier: "kb:\(letter)")!
            let script = state.script(for: key, owner: owner)
            check(script != nil, "return typing is held ahead of browse commands")
            script?.handler(key)
        }
    }

    test("Claude browser return: delayed first typing waits for verified native Prompt and replays in order") {
        withReturn { state, page, sent, _, owner in
            var time = Date()
            state.now = { time }
            var completion: ((Bool) -> Void)?
            state.confirm = { target, done in
                check(target.isSame(AXReplay.element(3)), "only the exact cached destination Prompt is focused")
                completion = done
            }
            time = time.addingTimeInterval(1.7)   // inside the two second arming window
            type("okay", state: state, owner: owner)
            waitForConfirmation { completion != nil }
            expect(sent.value, ["kb:command+shift+b"], "no letter reaches an unverified target")
            completion?(true)
            expect(sent.value, ["kb:command+shift+b", "kb:o", "kb:k", "kb:a", "kb:y"], "held letters reach the verified Prompt once and in order")
            check(page.passThrough, "native Prompt verification restores focus mode")
        }
    }
    test("Claude browser return: a letter after the two second arming window is not held") {
        withReturn { state, _, sent, _, owner in
            var time = Date()
            state.now = { time }
            state.confirm = { _, _ in Harness.fail("a lapsed arming never focuses the Prompt") }
            time = time.addingTimeInterval(2.2)
            check(state.script(for: KeyboardGesture(identifier: "kb:o")!, owner: owner) == nil, "a late letter keeps its browse mode meaning")
            time = time.addingTimeInterval(-1)
            check(state.script(for: KeyboardGesture(identifier: "kb:o")!, owner: owner) == nil, "the lapse retired the arming for good")
            expect(sent.value, ["kb:command+shift+b"], "nothing is typed")
        }
    }
    test("Claude browser return: a letter just inside the arming window is held and replayed") {
        withReturn { state, _, sent, _, owner in
            var time = Date()
            state.now = { time }
            var completion: ((Bool) -> Void)?
            state.confirm = { _, done in completion = done }
            time = time.addingTimeInterval(1.8)
            type("o", state: state, owner: owner)
            waitForConfirmation { completion != nil }
            completion?(true)
            expect(sent.value, ["kb:command+shift+b", "kb:o"], "the held letter is replayed")
        }
    }
    test("Claude browser return: Prompt focus news preserves held letters before confirmation") {
        withReturn { state, page, sent, _, owner in
            var completion: ((Bool) -> Void)?
            state.confirm = { _, done in completion = done }
            type("o", state: state, owner: owner)
            state.handleEvent(Event(.gainFocus, ObjectFactory.make(AXReplay.element(3))))
            waitForConfirmation { completion != nil }
            page.passThrough = true
            type("k", state: state, owner: owner)
            completion?(true)
            expect(sent.value, ["kb:command+shift+b", "kb:o", "kb:k"], "native focus news cannot drop or reorder held letters")
        }
    }
    test("Claude browser return: opening the browser does not own ordinary typing") {
        withReturn { state, _, sent, _, owner in
            var confirmations = 0
            state.confirm = { _, _ in confirmations += 1 }
            let shortcut = KeyboardGesture(identifier: "kb:command+shift+b")!
            state.script(for: shortcut, owner: owner)?.handler(shortcut)
            check(state.script(for: KeyboardGesture(identifier: "kb:o")!, owner: owner) == nil, "the opening direction leaves typing alone")
            expect(confirmations, 0, "opening the browser never focuses the conversation Prompt")
            expect(sent.value, ["kb:command+shift+b", "kb:command+shift+b"], "each browser toggle is sent once")
        }
    }
    for count in [0, 2] {
        test("Claude browser return: \(count) matching Prompts cannot receive held typing") {
            withReturn(promptCount: count) { state, _, sent, said, owner in
                var time = Date()
                state.now = { time }
                var confirmations = 0
                state.confirm = { _, _ in confirmations += 1 }
                type("o", state: state, owner: owner)
                time = time.addingTimeInterval(0.501)
                RunLoop.current.run(until: Date().addingTimeInterval(0.06))
                expect(confirmations, 0, "a missing or ambiguous target is never focused")
                expect(sent.value, ["kb:command+shift+b"], "held text is never sent to a guessed target")
                check(said.value.contains { $0.contains("held text was not typed") }, "expired ambiguous typing is explained")
            }
        }
    }
    test("Claude browser return: ignored shortcut search becomes inert after half a second") {
        withReturn { state, destination, _, _, owner in
            var confirmations = 0
            state.confirm = { _, _ in confirmations += 1 }
            let source = BrowseModeDocument(webArea: AXReplay.element(0))
            API.setFocusObject(ObjectFactory.make(AXReplay.element(0)), ancestors: [], interceptor: source)
            state.now = { Date().addingTimeInterval(1) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.06))
            API.setFocusObject(ObjectFactory.make(AXReplay.element(0)), ancestors: [], interceptor: destination)
            RunLoop.current.run(until: Date().addingTimeInterval(0.06))
            expect(confirmations, 0, "an expired search has no timer left to focus a later page")
            check(state.script(for: KeyboardGesture(identifier: "kb:escape")!, owner: owner) == nil, "the next ordinary command retires the inert arm")
        }
    }
    test("Claude browser return: a newer command retires held text and late confirmation") {
        withReturn { state, page, sent, _, owner in
            var completion: ((Bool) -> Void)?
            state.confirm = { _, done in completion = done }
            type("o", state: state, owner: owner)
            waitForConfirmation { completion != nil }
            check(state.script(for: KeyboardGesture(identifier: "kb:escape")!, owner: owner) == nil, "Escape retains its ordinary command")
            completion?(true)
            expect(sent.value, ["kb:command+shift+b"], "late confirmation cannot type after Escape")
            check(!page.passThrough, "late confirmation cannot undo browse mode")
        }
    }
    test("Claude browser return: focus departure retires held text") {
        withReturn { state, _, sent, _, owner in
            var completion: ((Bool) -> Void)?
            state.confirm = { _, done in completion = done }
            type("o", state: state, owner: owner)
            waitForConfirmation { completion != nil }
            state.handleEvent(Event(.gainFocus, ObjectFactory.make(AXReplay.element(4))))
            completion?(true)
            expect(sent.value, ["kb:command+shift+b"], "no held text is sent to another focused control")
        }
    }
    test("Claude browser return: half second typing deadline rejects late native focus truthfully") {
        withReturn { state, page, sent, said, owner in
            var time = Date()
            state.now = { time }
            var completion: ((Bool) -> Void)?
            state.confirm = { _, done in completion = done }
            type("o", state: state, owner: owner)
            waitForConfirmation { completion != nil }
            time = time.addingTimeInterval(0.501)
            completion?(true)
            expect(sent.value, ["kb:command+shift+b"], "expired typing is never sent")
            check(!page.passThrough, "expired confirmation cannot change the reader mode")
            check(said.value.contains { $0.contains("held text was not typed") }, "failure says that typing was not delivered")
        }
    }
}
