// SPDX-License-Identifier: GPL-3.0-or-later
// Synthetic controls only: no live Settings window, speech engine or settings file is changed.
import Foundation
import ApplicationServices
import TurnOverCore
import AXFixtures

private final class TurnOverSettingsRig {
    var fixture: AXFixture
    let object: TurnOverObject
    var spoken: [String] = []

    init?(role: String) {
        BuiltInModules.register()
        guard let type = AppModuleHandler.shared.moduleType(for: "com.turnover.settings") else {
            Harness.fail("TurnOver Settings module is registered"); return nil
        }
        fixture = .init(app: "TurnOver Settings sample", bundle: "com.turnover.settings", recorded: "", root: 0, application: nil, focus: 1, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXWindow"), "AXChildren": .elements([1, 2])]),
            .init(id: 1, attrs: ["AXRole": .string(role), "AXTitle": .string("Rate"), "AXValue": .number(70),
                                 "AXValueDescription": .string("70 percent"), "AXParent": .element(0), "AXWindow": .element(0)]),
            .init(id: 2, attrs: ["AXRole": .string("AXSlider"), "AXTitle": .string("Pitch"), "AXValue": .number(75),
                                 "AXValueDescription": .string("75 percent"), "AXParent": .element(0), "AXWindow": .element(0)]),
        ])
        AXReplay.load(fixture)
        let module = type.init(pid: AXReplay.floor + 1, bundleIdentifier: "com.turnover.settings", appName: "TurnOver Settings")
        guard let cls = module.objectClass(for: AXReplay.element(1), role: Role.from(axRole: role, subrole: nil), subrole: nil) else {
            AXReplay.unload(); Harness.fail("Settings supplies its labelled object"); return nil
        }
        object = cls.init(element: AXReplay.element(1))
    }

    func update(_ number: Double?, _ description: String?) {
        fixture.nodes[1].attrs["AXValue"] = number.map { .number($0) }
        fixture.nodes[1].attrs["AXValueDescription"] = description.map { .string($0) }
        AXReplay.load(fixture)
    }

    func notify(_ count: Int = 1) { for _ in 0..<count { object.event_valueChange() } }
}

private func withTurnOverSettings(role: String = "AXSlider", _ body: (TurnOverSettingsRig) -> Void) {
    let focus = API.focusObject, ancestors = API.focusAncestors, interceptor = API.focusTreeInterceptor
    let sink = Speech.sink, mode = Speech.mode, saved = config
    guard let rig = TurnOverSettingsRig(role: role) else { return }
    defer {
        API.setFocusObject(focus, ancestors: ancestors, interceptor: interceptor)
        Speech.sink = sink; Speech.mode = mode; config = saved; AXReplay.unload()
    }
    Speech.mode = .off
    config.presentation.speakHints = false
    Speech.sink = { if !$0.isEmpty { rig.spoken.append($0) } }
    API.setFocusObject(rig.object, ancestors: [])
    body(rig)
}

func turnOverSettingsTests() {
    test("TurnOver Settings: three slider notifications announce the new value once") {
        withTurnOverSettings { rig in
            expect(rig.object.value, "70 percent", "prime the focus object's cached value")
            rig.update(75, "75 percent"); rig.notify(3)
            expect(rig.spoken, ["75 percent"])
            rig.notify()
            expect(rig.spoken, ["75 percent"], "an unchanged endpoint is not another change")
        }
    }
    test("TurnOver Settings: rapid slider steps and returning to a previous value are all announced") {
        withTurnOverSettings { rig in
            for value in [75, 80, 75, 70] { rig.update(Double(value), "\(value) percent"); rig.notify(3) }
            expect(rig.spoken, ["75 percent", "80 percent", "75 percent", "70 percent"])
        }
    }
    test("TurnOver Settings: numeric changes are retained even when their descriptions match") {
        withTurnOverSettings { rig in
            rig.update(70.1, "70 percent"); rig.notify(2)
            rig.update(70.2, "70 percent"); rig.notify(2)
            expect(rig.spoken, ["70 percent", "70 percent"])
        }
    }
    test("TurnOver Settings: a settled value description is announced without parsing its language") {
        withTurnOverSettings { rig in
            rig.update(75, "70 Prozent"); rig.notify(2)
            rig.update(75, "75 Prozent"); rig.notify(2)
            expect(rig.spoken, ["70 Prozent", "75 Prozent"])
        }
    }
    test("TurnOver Settings: leaving and reentering a slider resets duplicate tracking") {
        withTurnOverSettings { rig in
            rig.update(75, "75 percent"); rig.notify(3)
            rig.object.event_loseFocus()
            rig.spoken = []; rig.notify(3)
            expect(rig.spoken, ["75 percent"], "losing focus retires the remembered value")
            rig.spoken = []; rig.object.event_gainFocus()
            check(!rig.spoken.isEmpty, "focus still reads the control")
            rig.spoken = []; rig.notify(3)
            expect(rig.spoken, ["75 percent"], "gaining focus starts a new value-change sequence")
        }
    }
    test("TurnOver Settings: an unfocused slider event does not speak or consume its next change") {
        withTurnOverSettings { rig in
            API.setFocusObject(nil, ancestors: [])
            rig.update(75, "75 percent"); rig.notify(3)
            expect(rig.spoken, [])
            API.setFocusObject(rig.object, ancestors: []); rig.notify(3)
            expect(rig.spoken, ["75 percent"])
        }
    }
    test("TurnOver Settings: two sliders can announce the same value") {
        withTurnOverSettings { rig in
            rig.update(75, "75 percent"); rig.notify(3)
            let other = type(of: rig.object).init(element: AXReplay.element(2))
            API.setFocusObject(other, ancestors: [])
            for _ in 0..<3 { other.event_valueChange() }
            expect(rig.spoken, ["75 percent", "75 percent"])
        }
    }
    test("TurnOver Settings: a missing value read does not suppress the next valid report") {
        withTurnOverSettings { rig in
            rig.update(75, "75 percent"); rig.notify(3)
            rig.update(nil, nil); rig.notify()
            rig.update(75, "75 percent"); rig.notify(3)
            expect(rig.spoken, ["75 percent", "75 percent"])
        }
    }
    test("TurnOver Settings: non-slider value changes keep their normal behavior") {
        withTurnOverSettings(role: "AXTextField") { rig in
            rig.update(75, nil); rig.notify(3)
            expect(rig.spoken, ["75", "75", "75"])
        }
    }
}
