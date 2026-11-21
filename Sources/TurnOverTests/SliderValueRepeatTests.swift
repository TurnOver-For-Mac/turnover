// SPDX-License-Identifier: GPL-3.0-or-later
// One value change sent twice within a few milliseconds is said once (17 Nov 2026). Logic evidence only: whether
// Safari's own pair of notifications is caught live is for the owner's ear.
import Foundation
import ApplicationServices
import TurnOverCore
import AXFixtures

func sliderValueRepeatTests() {
    test("slider value: the same value twice within 150 ms is said once, and a changed value is said") {
        let sink = Speech.sink
        defer { Speech.sink = sink; API.setFocusObject(nil, ancestors: []); AXReplay.unload() }
        AXReplay.load(.init(app: "Safari", bundle: "com.apple.Safari", recorded: "synthetic", root: 0, application: nil, focus: 0, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXSlider"), "AXTitle": .string("Seek"), "AXValue": .string("32")]),
        ]))
        let slider = AXReplay.element(0)
        API.setFocusObject(ObjectFactory.make(slider), ancestors: [])
        var said: [String] = []
        Speech.sink = { said.append($0) }
        TurnOverObject.lastValueSaid = nil
        let change = { EventHandler.execute(.valueChange, on: API.focusObject!) }
        change(); change()
        expect(said.count, 1, "two identical changes together: \(said)")
        _ = slider.set(kAXValueAttribute, "33" as CFString)
        change()
        expect(said.count, 2, "a different value is news: \(said)")
    }
    test("slider value: a control that is not a slider says every change, as before") {
        let sink = Speech.sink
        defer { Speech.sink = sink; API.setFocusObject(nil, ancestors: []); AXReplay.unload() }
        AXReplay.load(.init(app: "Safari", bundle: "com.apple.Safari", recorded: "synthetic", root: 0, application: nil, focus: 0, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXIncrementor"), "AXTitle": .string("Amount"), "AXValue": .string("75")]),
        ]))
        API.setFocusObject(ObjectFactory.make(AXReplay.element(0)), ancestors: [])
        var said: [String] = []
        Speech.sink = { said.append($0) }
        TurnOverObject.lastValueSaid = nil
        let change = { EventHandler.execute(.valueChange, on: API.focusObject!) }
        change(); change()
        expect(said.count, 2, "a spin button's repeated value is said each time: \(said)")
    }
    test("slider value: the repeat check is the same element, the same words, within the window") {
        let a = AXReplay.element(0), b = AXReplay.element(1)
        let t = Date()
        let last = (element: a, text: "5", at: t)
        check(TurnOverObject.repeatsValueJustSaid(last: last, element: a, text: "5", now: t.addingTimeInterval(0.01)), "the same, 10 ms later")
        check(!TurnOverObject.repeatsValueJustSaid(last: last, element: a, text: "5", now: t.addingTimeInterval(0.4)), "the same, 400 ms later")
        check(!TurnOverObject.repeatsValueJustSaid(last: last, element: a, text: "6", now: t.addingTimeInterval(0.01)), "another value")
        check(!TurnOverObject.repeatsValueJustSaid(last: last, element: b, text: "5", now: t.addingTimeInterval(0.01)), "another control")
        check(!TurnOverObject.repeatsValueJustSaid(last: nil, element: a, text: "5", now: t), "nothing said before")
    }
}
