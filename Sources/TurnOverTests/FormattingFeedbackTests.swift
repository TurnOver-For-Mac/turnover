// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import TurnOverAX
import AXFixtures

private final class FormattingTestText: EditableText {
    var testBundle = "org.turnover.public-formatting-sample"
    override var appModule: AppModule { AppModule(pid: pid, bundleIdentifier: testBundle, appName: "Public formatting sample") }
}

private final class FormattingHeldReplies {
    var delayed: [@MainActor () -> Void] = []
    var replies: [@MainActor (FormattingFeedback.State) -> Void] = []
    var contexts: [FormattingFeedback.Context] = []
    var current = true
    let keys = Locked(0)
    let now = Locked<UInt64>(0)
    let mouse = Locked(FormattingFeedback.MouseClicks(left: 0, right: 0, other: 0))
    let delivered = Locked(0)
}

func formattingFeedbackTests() {
    func drainMain() {
        var done = false
        DispatchQueue.main.async { done = true }
        let until = Date().addingTimeInterval(1)
        while !done, Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
        check(done, "queued input callbacks finish")
    }
    func withFeedback(_ body: (FormattingTestText, FormattingHeldReplies, () -> [String], (String) -> Bool) -> Void) {
        let fixture = AXFixture(app: "Public formatting sample", bundle: "org.turnover.public-formatting-sample",
                                recorded: "synthetic", root: 1, application: 0, focus: 2, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXApplication"), "AXFocusedWindow": .element(1), "AXFocusedUIElement": .element(2)]),
            .init(id: 1, attrs: ["AXRole": .string("AXWindow"), "AXChildren": .elements([2]), "AXParent": .element(0)]),
            .init(id: 2, attrs: ["AXRole": .string("AXTextArea"), "AXValue": .string("public sample"), "AXWindow": .element(1), "AXParent": .element(1)]),
            .init(id: 3, attrs: ["AXRole": .string("AXTextArea"), "AXValue": .string("second public sample"), "AXWindow": .element(1)]),
            .init(id: 4, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("Public button"), "AXWindow": .element(1)]),
            .init(id: 5, attrs: ["AXRole": .string("AXTextField"), "AXSubrole": .string("AXSecureTextField"), "AXWindow": .element(1)]),
            .init(id: 6, attrs: ["AXRole": .string("AXWindow"), "AXChildren": .elements([])]),
        ])
        AXReplay.load(fixture)
        let saved = FormattingFeedback.shared, savedSink = Speech.sink, savedPoster = KeyboardGesture.poster
        let savedFocus = API.focusObject, savedAncestors = API.focusAncestors, savedInterceptor = API.focusTreeInterceptor
        let savedForeground = API.foregroundObject, savedPass = InputManager.passNextKey
        let savedHelp = InputManager.isInputHelpActive, savedCapture = InputManager.captureNext
        let savedWatchers = InputManager.passThroughWatchers, savedPassHandler = InputManager.onPassThrough
        var said: [String] = []
        let held = FormattingHeldReplies(), keys = held.keys, delivered = held.delivered, clock = held.now, clicks = held.mouse
        Speech.sink = { said.append($0) }
        KeyboardGesture.poster = { _ in delivered.lock.lock(); delivered.unsafeValue += 1; delivered.lock.unlock() }
        InputManager.passNextKey = false; InputManager.isInputHelpActive = false; InputManager.captureNext = nil
        InputManager.passThroughWatchers = []; InputManager.onPassThrough = nil
        FormattingFeedback.shared = FormattingFeedback(provider: { _, _, _ in .unknown },
            isCurrent: { _ in held.current }, keyCount: { keys.value }, now: { clock.value }, mouseClicks: { clicks.value },
            after: { held.delayed.append($0) }, read: { context, _, _, reply in
                held.contexts.append(context); held.replies.append(reply)
            })
        let focus = FormattingTestText(element: AXReplay.element(2))
        API.setFocusObject(focus, ancestors: [])
        API.setForegroundObject(TurnOverObject(element: AXReplay.element(1)))
        defer {
            FormattingFeedback.shared.cancel()
            drainMain()
            FormattingFeedback.shared = saved
            API.setFocusObject(savedFocus, ancestors: savedAncestors, interceptor: savedInterceptor)
            API.setForegroundObject(savedForeground)
            Speech.sink = savedSink; KeyboardGesture.poster = savedPoster
            InputManager.passNextKey = savedPass; InputManager.isInputHelpActive = savedHelp; InputManager.captureNext = savedCapture
            InputManager.passThroughWatchers = savedWatchers; InputManager.onPassThrough = savedPassHandler
            AXReplay.unload()
        }
        body(focus, held, { said }) { identifier in
            let gesture = KeyboardGesture(identifier: identifier)!
            keys.value += 1
            let taken = InputManager.handleKeyDown(gesture)
            // The caller's actual pass decision controls delivery; the feedback owner never resends the shortcut.
            if !taken { gesture.send() }
            return taken
        }
    }

    test("formatting feedback: unhandled native shortcuts keep delivery and speak one verified result") {
        withFeedback { _, held, said, key in
            check(!key("kb:command+b"), "native bold remains unhandled by TurnOver")
            expect(held.delivered.value, 1)
            expect(held.delayed.count, 1)
            guard let delayed = held.delayed.first else { return }
            delayed()
            guard let reply = held.replies.first else { return Harness.fail("native shortcut starts a provider read") }
            reply(.on); reply(.off)
            expect(said(), ["bold on"], "a duplicate provider completion cannot speak twice")
            check(!key("kb:command+i"), "native italic remains unhandled")
            held.delayed.last?(); held.replies.last?(.off)
            expect(said(), ["bold on", "italic off"])
            expect(held.delivered.value, 2, "no replay or swallowed native key")
        }
    }
    test("formatting feedback: unknown is silent and mixed is not converted into on or off") {
        withFeedback { _, held, said, key in
            _ = key("kb:command+b"); held.delayed.last?(); held.replies.last?(.unknown)
            expect(said(), [])
            _ = key("kb:command+i"); held.delayed.last?(); held.replies.last?(.mixed)
            expect(said(), ["italic mixed"])
        }
    }
    test("formatting feedback: a newer key cancels both scheduled reads and held completion") {
        withFeedback { _, held, said, key in
            _ = key("kb:command+b")
            _ = key("kb:command+i")
            held.delayed[0]()
            expect(held.replies.count, 0, "superseded scheduling performs no provider read")
            held.delayed[1]()
            expect(held.replies.count, 1)
            _ = key("kb:command+l")
            held.replies.first?(.on)
            expect(said(), [])
            expect(held.delivered.value, 3)
        }
    }
    test("formatting feedback: focus foreground and reader handover retire replies even after returning") {
        for change in 0..<3 {
            withFeedback { focus, held, said, key in
                _ = key("kb:command+b"); held.delayed.last?()
                if change == 0 {
                    API.setFocusObject(FormattingTestText(element: AXReplay.element(3)), ancestors: [])
                    API.setFocusObject(focus, ancestors: [])
                } else if change == 1 {
                    API.setForegroundObject(TurnOverObject(element: AXReplay.element(6)))
                    API.setForegroundObject(TurnOverObject(element: AXReplay.element(1)))
                } else {
                    Core.deactivate()   // must retire work even if the reader is already inactive
                    held.current = true
                }
                held.replies.first?(.on)
                expect(said(), [])
            }
        }
    }
    test("formatting feedback: a same-editor mouse click cancels scheduled and completed replies") {
        for button in 0..<3 {
            for beforeRead in [true, false] {
                withFeedback { _, held, said, key in
                    _ = key("kb:command+b")
                    if !beforeRead { held.delayed.first?() }
                    var clicks = held.mouse.value
                    switch button {
                    case 0: clicks.left += 1
                    case 1: clicks.right += 1
                    default: clicks.other += 1
                    }
                    held.mouse.value = clicks
                    if beforeRead {
                        held.delayed.first?()
                        expect(held.replies.count, 0, "a mouse-retargeted request never starts provider work")
                    } else { held.replies.first?(.on) }
                    expect(said(), [], "unchanged AX focus cannot make a pre-click reply current")
                }
            }
        }
    }
    test("formatting feedback: request age includes scheduling and a completed result held on main") {
        for beforeRead in [true, false] {
            withFeedback { _, held, said, key in
                held.now.value = 5_000_000_000
                _ = key("kb:command+i")
                if !beforeRead { held.delayed.first?() }
                held.now.value += 1_000_000_000
                if beforeRead {
                    held.delayed.first?()
                    expect(held.replies.count, 0, "a late scheduler cannot start a fresh worker deadline")
                } else { held.replies.first?(.off) }
                expect(said(), [], "an answer held on main past the total deadline stays silent")
            }
        }
        withFeedback { _, held, said, key in
            _ = key("kb:command+b"); held.delayed.first?()
            held.now.value = 999_999_999
            held.replies.first?(.on)
            expect(said(), ["bold on"], "a current verified result before expiry still speaks")
        }
    }
    test("formatting feedback: original focus is captured before deferred work") {
        withFeedback { focus, held, said, key in
            _ = key("kb:command+b")
            API.setFocusObject(FormattingTestText(element: AXReplay.element(3)), ancestors: [])
            held.delayed.first?()
            expect(held.replies.count, 0)
            expect(said(), [])
            API.setFocusObject(focus, ancestors: [])
            _ = key("kb:command+i"); held.delayed.last?()
            check(held.contexts.last?.focus.isSame(focus.element) == true, "provider receives the original keyboard target")
        }
    }
    test("formatting feedback: noneditable secure Word and unavailable contexts never request state") {
        for kind in 0..<4 {
            withFeedback { focus, held, _, key in
                switch kind {
                case 0: API.setFocusObject(TurnOverObject(element: AXReplay.element(4)), ancestors: [])
                case 1: API.setFocusObject(FormattingTestText(element: AXReplay.element(5)), ancestors: [])
                case 2: focus.testBundle = "com.microsoft.Word"
                default: held.current = false
                }
                _ = key("kb:command+b")
                expect(held.delayed.count, 0)
                expect(held.delivered.value, 1, "eligibility cannot swallow the app shortcut")
            }
        }
    }
    test("formatting feedback: exact modifiers repeats and pass-next retain native behavior") {
        withFeedback { _, held, _, key in
            _ = key("kb:command+shift+b"); _ = key("kb:control+b"); _ = key("kb:command+option+i")
            let original = KeyboardGesture(identifier: "kb:command+b")!
            let repeated = KeyboardGesture(keyCode: original.keyCode, modifiers: original.modifiers,
                characters: original.characters, timestamp: 0, isRepeat: true, flags: original.flags)
            check(!InputManager.handleKeyDown(repeated), "repeat still passes through")
            InputManager.passNextKey = true
            _ = key("kb:command+b")
            expect(held.delayed.count, 0)
        }
    }
    test("formatting feedback: an existing focused script keeps precedence") {
        withFeedback { focus, held, _, key in
            var ran = 0
            focus.script("sampleOwnBold", "Public sample command", gestures: ["kb:command+b"], category: "Test") { _ in ran += 1 }
            check(key("kb:command+b"), "the existing script owns its key")
            expect(held.delayed.count, 0)
            expect(held.delivered.value, 0)
            drainMain()
            expect(ran, 1)
        }
    }
}
