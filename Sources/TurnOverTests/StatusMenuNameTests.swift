// SPDX-License-Identifier: GPL-3.0-or-later
// 22 Nov 2026, issue 298: a status item says its value after its name (the battery's level and charging state).
import Foundation
import ApplicationServices
import AppKit
import TurnOverCore
import AXFixtures

func statusMenuNameTests() {
    func item(_ attrs: [String: AXFixture.Value]) -> AXUIElement {
        var a = attrs; a["AXRole"] = .string("AXMenuBarItem"); a["AXSubrole"] = .string("AXMenuExtra")
        AXReplay.load(.init(app: "Control Center", bundle: "com.apple.controlcenter", recorded: "synthetic", root: 0, application: nil, focus: nil, nodes: [.init(id: 0, attrs: a)]))
        return AXReplay.element(0)
    }
    let app = NSRunningApplication.current
    test("Status items: the battery item says its level and charging state") {
        defer { AXReplay.unload() }
        let e = item(["AXIdentifier": .string("com.apple.menuextra.battery"), "AXDescription": .string("Battery"), "AXValue": .string("100%, charging")])
        // On a charged Mac on mains the item's own "charging" is replaced (25 Nov 2026), so the expectation follows the power source.
        let words = StatusMenus.batteryPowerState().chargedOnPower ? "Battery, 100%, charged, on power" : "Battery, 100%, charging"
        expect(StatusMenus.name(of: e, app: app), words, "label then value")
    }
    test("Status items: a battery item with no value falls back to the power source's words") {
        defer { AXReplay.unload() }
        let e = item(["AXIdentifier": .string("com.apple.menuextra.battery"), "AXDescription": .string("Battery")])
        expect(StatusMenus.name(of: e, app: app), "Battery, " + GlobalCommands.batteryText(), "no value: the shared battery words")
    }
    test("Status items: any item says its value; one without a value, or whose name has it, is unchanged") {
        defer { AXReplay.unload() }
        expect(StatusMenus.name(of: item(["AXDescription": .string("Focus"), "AXValue": .string("Do Not Disturb")]), app: app), "Focus, Do Not Disturb")
        expect(StatusMenus.name(of: item(["AXDescription": .string("Wi-Fi")]), app: app), "Wi-Fi", "no value")
        expect(StatusMenus.name(of: item(["AXDescription": .string("Wi-Fi"), "AXValue": .string("")]), app: app), "Wi-Fi", "empty value")
        expect(StatusMenus.name(of: item(["AXDescription": .string("Bluetooth"), "AXValue": .string("Bluetooth")]), app: app), "Bluetooth", "value already in the name")
    }
    test("Status items: a battery that is charged on mains says charged, not the item's own state (issue 298)") {
        let words = "charged, on power"
        expect(StatusMenus.batteryItemValue(raw: "85%, charging", chargedOnPower: false, chargedWords: words), "85%, charging", "not charged: unchanged")
        expect(StatusMenus.batteryItemValue(raw: "100%, charging", chargedOnPower: true, chargedWords: words), "100%, charged, on power", "charged replaces charging")
        expect(StatusMenus.batteryItemValue(raw: "", chargedOnPower: true, chargedWords: words), "", "an empty value is left for the fallback")
        expect(StatusMenus.batteryItemValue(raw: "Charging, soon", chargedOnPower: true, chargedWords: words), "Charging, soon", "no level anywhere: unchanged")
        expect(StatusMenus.batteryItemValue(raw: "100 %, charging", chargedOnPower: true, chargedWords: words), "100 %, charged, on power", "a localized level is kept")
    }
}
