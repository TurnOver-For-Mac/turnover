// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import TurnOverAX
import AXFixtures

func activationFeedbackTests() {
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
