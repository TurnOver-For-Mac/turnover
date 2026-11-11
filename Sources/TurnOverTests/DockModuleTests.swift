// SPDX-License-Identifier: GPL-3.0-or-later
import ApplicationServices
import AXFixtures
import TurnOverCore

func dockModuleTests() {
    // Issue #290: at the bottom of the screen the Dock moves with Left and Right, not Up and Down.
    test("dock: the hint names the arrows that move along the Dock") {
        let across = DockAppModule.listHint(orientation: kAXHorizontalOrientationValue as String)
        check(across.hasPrefix("Left and Right"), "a horizontal Dock: Left and Right")
        check(!across.contains("Up and Down"), "a horizontal Dock: not Up and Down")
        check(DockAppModule.listHint(orientation: nil) == across, "no orientation: the bottom, the default")
        check(DockAppModule.listHint(orientation: kAXVerticalOrientationValue as String).hasPrefix("Up and Down"), "a Dock on a side: Up and Down")
    }

    test("dock: the Dock's list gets the Dock hint, other objects the general one") {
        guard AXReplay.isAvailable else { return }
        AXReplay.load(.init(app: "Dock", bundle: "com.apple.dock", recorded: "synthetic Dock at the bottom", root: 1,
                            application: nil, focus: 1, nodes: [
            .init(id: 1, attrs: ["AXRole": .string("AXList"), "AXOrientation": .string("AXHorizontalOrientation")]),
        ]))
        defer { AXReplay.unload() }
        let module = DockAppModule(pid: 0, bundleIdentifier: "com.apple.dock", appName: "Dock")
        let list = DockList(element: AXReplay.element(1))
        check(module.hint(for: list)?.hasPrefix("Left and Right") == true, "the bottom Dock's list: Left and Right")
        check(module.hint(for: TurnOverObject(element: AXReplay.element(1))) == nil, "not the Dock's list: no Dock hint")
    }
}
