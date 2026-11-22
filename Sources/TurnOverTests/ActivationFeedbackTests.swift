// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import TurnOverAX
import AXFixtures

func activationFeedbackTests() {
    test("activation feedback: recovery uses the app's reported focus after OK") {
        func load(focused: Int, window: Int) {
            AXReplay.load(.init(app: "Public sample", bundle: "test.activation-feedback", recorded: "synthetic",
                                root: 0, application: 0, focus: focused, nodes: [
                .init(id: 0, attrs: ["AXRole": .string("AXApplication"), "AXFocusedWindow": .element(window),
                                     "AXFocusedUIElement": .element(focused)]),
                .init(id: 1, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("OK"), "AXWindow": .element(2)]),
                .init(id: 2, attrs: ["AXRole": .string("AXWindow")]),
                .init(id: 3, attrs: ["AXRole": .string("AXWindow")]),
                .init(id: 4, attrs: ["AXRole": .string("AXTextField"), "AXWindow": .element(3)]),
            ]))
        }
        defer { AXReplay.unload() }

        load(focused: 4, window: 3)
        let replacement = AXHandler.browseButtonReplacement(in: AXReplay.element(0), oldButton: AXReplay.element(1),
                                                            oldWindow: AXReplay.element(2))
        check(replacement?.focus.isSame(AXReplay.element(4)) == true, "adopt the control the app actually focused")
        check(replacement?.window?.isSame(AXReplay.element(3)) == true, "update the foreground for the new window")

        load(focused: 1, window: 3)
        let window = AXHandler.browseButtonReplacement(in: AXReplay.element(0), oldButton: AXReplay.element(1),
                                                       oldWindow: AXReplay.element(2))
        check(window?.focus.isSame(AXReplay.element(3)) == true, "use the app's focused window if the button is stale")

        load(focused: 1, window: 2)
        let unchanged = AXHandler.browseButtonReplacement(in: AXReplay.element(0), oldButton: AXReplay.element(1),
                                                          oldWindow: AXReplay.element(2))
        check(unchanged == nil, "a background window creation does not move focus")
    }

    test("activation feedback: return from Drive only when it confirms there are no windows") {
        func load(_ windows: AXFixture.Value?) {
            var attrs: [String: AXFixture.Value] = ["AXRole": .string("AXApplication")]
            attrs["AXWindows"] = windows
            AXReplay.load(.init(app: "Public sample", bundle: "test.activation-feedback", recorded: "synthetic",
                                root: 0, application: 0, focus: 0, nodes: [
                .init(id: 0, attrs: attrs),
                .init(id: 1, attrs: ["AXRole": .string("AXWindow")]),
            ]))
        }
        defer { AXReplay.unload() }
        load(.elements([]))
        check(AXHandler.driveAlertEnded(in: AXReplay.element(0)), "a successful empty windows list confirms closure")
        load(.elements([1]))
        check(!AXHandler.driveAlertEnded(in: AXReplay.element(0)), "an open window keeps the reader in Drive")
        load(nil)
        check(!AXHandler.driveAlertEnded(in: AXReplay.element(0)), "missing window data cannot switch apps")
    }

    for scenario in ["silent button", "changed state", "later key", "focus departure", "new activation", "non-button"] {
        test("activation feedback integration: \(scenario)") {
            let savedFocus = API.focusObject, savedAncestors = API.focusAncestors
            let savedPage = API.focusTreeInterceptor, savedSink = Speech.sink
            let savedPoster = KeyboardGesture.poster, savedKey = InputManager.lastKeyDownAt
            let role = scenario == "non-button" ? "AXMenuItem" : "AXButton"
            AXReplay.load(.init(app: "Public sample", bundle: "test.activation-feedback", recorded: "synthetic",
                                root: 0, application: 2, focus: 1, nodes: [
                .init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXParent": .element(2),
                                     "AXURL": .url("https://example.com/form"), "AXChildren": .elements([1])]),
                .init(id: 1, attrs: ["AXRole": .string(role), "AXTitle": .string("Submit"), "AXParent": .element(0),
                                     "AXExpanded": .bool(false)], actions: ["AXPress"]),
                .init(id: 2, attrs: ["AXRole": .string("AXApplication"), "AXFocusedUIElement": .element(1)])
            ]))
            let button = AXReplay.element(1)
            let moduleID = "pid.\(button.pid)"
            let previousType = AppModuleHandler.shared.moduleType(for: moduleID)
            AppModuleHandler.shared.register(ClaudeAppModule.self, for: moduleID)
            let page = BrowseModeDocument(webArea: AXReplay.element(0))
            page.buffer.buildForInspection()
            waitForBuffer(page.buffer)
            page.position = page.buffer.offset(of: button) ?? 0
            API.setFocusObject(ObjectFactory.make(button), ancestors: [], interceptor: page)
            var said: [String] = []
            let sent = Locked<[String]>([])
            Speech.sink = { said.append($0) }
            KeyboardGesture.poster = { sent.value.append($0.identifier) }
            defer {
                API.setFocusObject(savedFocus, ancestors: savedAncestors, interceptor: savedPage)
                Speech.sink = savedSink
                KeyboardGesture.poster = savedPoster
                InputManager.lastKeyDownAt = savedKey
                if let previousType { AppModuleHandler.shared.register(previousType, for: moduleID) }
                else { AppModuleHandler.shared.unregister(bundleIdentifier: moduleID) }
                AXReplay.unload()
            }
            let gesture = KeyboardGesture(identifier: "kb:enter")!
            guard let activation = page.script(named: "activatePosition") else {
                Harness.fail("production activation script is available")
                return
            }
            activation.handler(gesture)
            expect(sent.value, ["kb:enter"], "the activation sends one native key")
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            switch scenario {
            case "changed state": _ = button.set("AXExpanded", kCFBooleanTrue)
            case "later key": InputManager.lastKeyDownAt = Date()
            case "focus departure": API.setFocusObject(ObjectFactory.make(AXReplay.element(0)), ancestors: [], interceptor: page)
            case "new activation": activation.handler(gesture)
            default: break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            if scenario == "new activation" {
                check(!said.contains("pressed"), "the obsolete first activation is not acknowledged")
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            }
            let acknowledgements = said.filter { $0 == "pressed" }
            expect(acknowledgements.count, ["silent button", "new activation"].contains(scenario) ? 1 : 0,
                   "only a current silent button receives the one-second acknowledgement")
            expect(sent.value.count, scenario == "new activation" ? 2 : 1,
                   "feedback never retries a native activation")
            // Let the unchanged three-second state watch drain before restoring the shared replay and speech sink.
            RunLoop.current.run(until: Date().addingTimeInterval(2.1))
            waitForBuffer(page.buffer)
        }
    }
}
