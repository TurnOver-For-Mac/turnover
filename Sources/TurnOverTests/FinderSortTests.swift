// SPDX-License-Identifier: GPL-3.0-or-later
// Finder, View > Sort By (17 Nov 2026): choosing an order says "sorted by <its name>" once the menu has closed.
// Logic evidence only (a made-up menu; Finder's real Sort By submenu was not recorded, so the parent item's title and
// the highlighted item's attribute are as guessed from the menu bar's usual shape, and no re-sort sign exists).
import Foundation
import ApplicationServices
import TurnOverCore
import AXFixtures

func finderSortTests() {
    func tree(parentTitle: String) -> AXFixture {
        .init(app: "Finder", bundle: "com.apple.finder", recorded: "synthetic", root: 0, application: 8, focus: nil, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXMenu"), "AXParent": .element(1), "AXChildren": .elements([2, 3]), "AXSelectedChildren": .elements([3])]),
            .init(id: 1, attrs: ["AXRole": .string("AXMenuItem"), "AXTitle": .string(parentTitle), "AXChildren": .elements([0])]),
            .init(id: 2, attrs: ["AXRole": .string("AXMenuItem"), "AXTitle": .string("Name"), "AXParent": .element(0)]),
            .init(id: 3, attrs: ["AXRole": .string("AXMenuItem"), "AXTitle": .string("Date Created"), "AXParent": .element(0)]),
            .init(id: 8, attrs: ["AXRole": .string("AXApplication"), "AXChildren": .elements([0])]),
        ])
    }
    test("Finder Sort By: the highlighted order is named in the Sort By menu only") {
        AXReplay.load(tree(parentTitle: "Sort By")); defer { AXReplay.unload() }
        expect(FinderAppModule.sortOrder(inMenu: AXReplay.element(0)), "Date Created")
        AXReplay.load(tree(parentTitle: "Group By"))
        expect(FinderAppModule.sortOrder(inMenu: AXReplay.element(0)), nil, "Group By is not a sort")
    }
    test("Finder Sort By: Return on an order says sorted by it once the menu has closed, and nothing in another menu") {
        let sink = Speech.sink
        defer { Speech.sink = sink; AXReplay.unload() }
        AXReplay.load(tree(parentTitle: "Sort By"))
        let type = AppModuleHandler.shared.moduleType(for: "com.apple.finder")!
        let module = type.init(pid: 900_009, bundleIdentifier: "com.apple.finder", appName: "Finder")
        guard let finder = module as? FinderAppModule else { return Harness.fail("not the Finder module") }
        finder.sortSayDelay = 0.05
        var open = true
        var menuElement = AXReplay.element(0)
        finder.openMenu = { open ? menuElement : nil }
        var said: [String] = []
        Speech.sink = { said.append($0) }
        func wait(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
        guard let enter = KeyboardGesture(identifier: "kb:enter") else { return Harness.fail("no enter") }
        _ = finder.script(for: enter)
        wait(0.5)
        expect(said, [], "nothing while the menu is still open")
        open = false
        wait(0.6)
        expect(said, ["sorted by Date Created"])
        said = []
        // A repeat of the same lookup (the Windows style asks twice) while open says it once.
        open = true
        _ = finder.script(for: enter); _ = finder.script(for: enter)
        open = false
        wait(0.6)
        expect(said, ["sorted by Date Created"], "once for one choice")
        said = []
        AXReplay.load(tree(parentTitle: "Group By"))
        menuElement = AXReplay.element(0)
        open = true
        _ = finder.script(for: enter)
        open = false
        wait(0.6)
        expect(said, [], "Group By says nothing")
    }
}
