// SPDX-License-Identifier: GPL-3.0-or-later
// The Claude app's "Copy code" press, TurnOver's own (17 Nov 2026): the keyboard it puts on the button is not
// announced, and the page's "Copied" is said at once. Logic evidence only: the real timing, with Command Tab after
// the press, is for the owner's ear.
import Foundation
import ApplicationServices
import TurnOverCore
import AXFixtures

func claudeCopyPressTests() {
    test("Claude copy press: the result is one short word, soon after the press") {
        check(ClaudeAppModule.isCopyResult(text: "Copied", sincePress: 0.2), "Copied, 200 ms after")
        check(!ClaudeAppModule.isCopyResult(text: "Copied", sincePress: 1.6), "too late: ordinary progress")
        check(!ClaudeAppModule.isCopyResult(text: "Copied", sincePress: nil), "no press of ours")
        check(!ClaudeAppModule.isCopyResult(text: "Claude is thinking about it", sincePress: 0.2), "a sentence is progress")
        check(!ClaudeAppModule.isCopyResult(text: "", sincePress: 0.2), "nothing")
    }
    test("Claude copy press: the focus on the button TurnOver pressed is not said, and Copied is said at once") {
        let savedFocus = API.focusObject, savedAncestors = API.focusAncestors, savedPage = API.focusTreeInterceptor
        let sink = Speech.sink
        AXReplay.load(.init(app: "Public copy trial", bundle: "test.claude-trial", recorded: "synthetic", root: 0, application: 1, focus: 2, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.com/copy"), "AXParent": .element(1), "AXChildren": .elements([2, 3, 4])]),
            .init(id: 1, attrs: ["AXRole": .string("AXApplication")]),
            .init(id: 2, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("Copy code"), "AXParent": .element(0)]),
            .init(id: 3, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("Share"), "AXParent": .element(0)]),
            .init(id: 4, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("Copied"), "AXARIALive": .string("polite"), "AXParent": .element(0)]),
        ]))
        let root = AXReplay.element(0), page = BrowseModeDocument(webArea: AXReplay.element(0))
        page.buffer.buildForInspection()
        waitForBuffer(page.buffer)
        API.setFocusObject(ObjectFactory.make(AXReplay.element(2)), ancestors: [], interceptor: page)
        let module = ClaudeAppModule(pid: root.pid, bundleIdentifier: "com.anthropic.claudefordesktop", appName: "Claude")
        module.progressSpeechBusy = { true }
        module.progressScheduler = { _, _ in }
        defer {
            Speech.sink = sink
            API.setFocusObject(savedFocus, ancestors: savedAncestors, interceptor: savedPage)
            AXReplay.unload()
        }
        var said: [String] = [], forwarded = 0
        Speech.sink = { said.append($0) }
        let copy = ObjectFactory.make(AXReplay.element(2)), share = ObjectFactory.make(AXReplay.element(3))
        module.ownPressWatching = { _ in false }
        check(!module.ignoresFocus(Event(.gainFocus, copy)), "a Copy button the reader did not press is announced as usual")
        module.ownPressWatching = { _ in true }
        check(!module.ignoresFocus(Event(.gainFocus, share)), "another button is announced as usual")
        check(module.ignoresFocus(Event(.gainFocus, copy)), "the Copy button TurnOver pressed is not announced")
        module.handleEvent(Event(.gainFocus, copy)) { forwarded += 1 }
        expect(forwarded, 0, "its focus event goes no further")
        module.handleEvent(Event(.gainFocus, share)) { forwarded += 1 }
        expect(forwarded, 1, "another button's focus event does")
        module.handleEvent(Event(.liveRegionChange, ObjectFactory.make(AXReplay.element(4)))) { forwarded += 1 }
        check(said.contains("Copied"), "Copied is said at once, though speech is busy: \(said)")
        check(module.progressHeldSince(session: "https://example.com/copy") == nil, "and not held")
    }
}
