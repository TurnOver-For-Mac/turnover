// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import AXFixtures
import TurnOverCore

/// The switcher's log line (16 Nov 2026). Unhappy cases: two apps with the same name, an item with no URL, an item
/// that matches no running app (it quit), no item reported as selected, and nothing announced yet.
func appSwitcherDiagnosticsTests() {
    let first = URL(fileURLWithPath: "/Applications/Public One.app")
    let second = URL(fileURLWithPath: "/Applications/Public Two.app")
    let apps = [
        AppSwitcherDiagnostics.RunningApp(name: "Public One", pid: 101, bundleURL: first),
        AppSwitcherDiagnostics.RunningApp(name: "Public Two", pid: 202, bundleURL: second),
        AppSwitcherDiagnostics.RunningApp(name: "Twin", pid: 303, bundleURL: nil),
        AppSwitcherDiagnostics.RunningApp(name: "Twin", pid: 404, bundleURL: nil),
    ]

    test("app switcher diagnostics: the selected item's process, by URL or by name") {
        expect(AppSwitcherDiagnostics.process(name: "Public Two", url: second, among: apps), "pid 202 by its URL")
        expect(AppSwitcherDiagnostics.process(name: "Public One", url: nil, among: apps), "pid 101 by its name")
        check(AppSwitcherDiagnostics.process(name: "Twin", url: nil, among: apps) == nil, "two apps of one name: unknown, not a guess")
        let gone = URL(fileURLWithPath: "/Applications/Quit Already.app")
        check(AppSwitcherDiagnostics.process(name: "Quit Already", url: gone, among: apps) == nil, "an app that has quit: unknown")
        check(AppSwitcherDiagnostics.process(name: "Public One", url: gone, among: apps) == nil,
              "a URL that matches nothing is not replaced by a name match")
    }

    test("app switcher diagnostics: the line puts the selection beside the name last announced") {
        let line = AppSwitcherDiagnostics.line(key: "kb:command+q", selectedName: "Public Two", process: "pid 202 by its URL",
                                               lastAnnounced: "Public One")
        expect(line, "switcher key kb:command+q: selected \"Public Two\", pid 202 by its URL; last announced \"Public One\"")
        let unknown = AppSwitcherDiagnostics.line(key: "kb:command+q", selectedName: nil, process: nil, lastAnnounced: nil)
        expect(unknown, "switcher key kb:command+q: selected unknown, pid unknown; last announced nothing")
    }

    // 18 Nov 2026, 07:32:56: "selected unknown" for five keys, the switcher already closed with Safari's activation.
    test("app switcher diagnostics: nothing selected says whether the switcher still lists any apps") {
        let closed = AppSwitcherDiagnostics.line(key: "kb:escape", selectedName: nil, process: nil, lastAnnounced: "Safari", items: 0)
        expect(closed, "switcher key kb:escape: selected unknown (the switcher lists no apps: it has closed), pid unknown; last announced \"Safari\"")
        let open = AppSwitcherDiagnostics.line(key: "kb:escape", selectedName: nil, process: nil, lastAnnounced: "Safari", items: 7)
        expect(open, "switcher key kb:escape: selected unknown (the switcher lists 7 apps), pid unknown; last announced \"Safari\"")
        let chosen = AppSwitcherDiagnostics.line(key: "kb:command+q", selectedName: "Mail", process: "pid 1 by its name", lastAnnounced: "Mail", items: 7)
        expect(chosen, "switcher key kb:command+q: selected \"Mail\", pid 1 by its name; last announced \"Mail\"")
    }

    // Review, 16 Nov 2026: the Dock sends a selection for every Tab, so the name last announced follows it; and Tab and
    // Shift-Tab, which only move the selection, do not ask the Dock about every item.
    test("app switcher diagnostics: a selection event updates the name last announced") {
        guard AXReplay.isAvailable else { return }
        AXReplay.load(.init(app: "Dock", bundle: "com.apple.dock", recorded: "synthetic switcher", root: 1,
                            application: nil, focus: 2, nodes: [
            .init(id: 1, attrs: ["AXRole": .string("AXList"), "AXSubrole": .string("AXProcessSwitcherList"), "AXChildren": .elements([2, 3])]),
            .init(id: 2, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("Public One"), "AXParent": .element(1)]),
            .init(id: 3, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("Public Two"), "AXParent": .element(1)]),
        ]))
        let saved = AppSwitcherDiagnostics.lastAnnounced
        defer { AppSwitcherDiagnostics.lastAnnounced = saved; AXReplay.unload() }
        let module = DockAppModule(pid: 0, bundleIdentifier: "com.apple.dock", appName: "Dock")
        @MainActor func item(_ id: Int) -> TurnOverObject? {
            let element = AXReplay.element(id)
            return module.objectClass(for: element, role: .button, subrole: nil).map { $0.init(element: element) }
        }
        guard let one = item(2), let two = item(3) else { check(false, "the switcher's buttons are switcher items"); return }
        AppSwitcherDiagnostics.lastAnnounced = nil
        module.handleEvent(Event(.gainFocus, one)) {}
        expect(AppSwitcherDiagnostics.lastAnnounced, "Public One", "a focus sets it")
        module.handleEvent(Event(.selection, two)) {}
        expect(AppSwitcherDiagnostics.lastAnnounced, "Public Two", "a selection (one Tab) sets it")
    }

    test("app switcher diagnostics: Tab and Shift-Tab write no line, other keys do") {
        for identifier in ["kb:command+tab", "kb:command+shift+tab", "kb:tab", "kb:shift+tab"] {
            check(!AppSwitcherDiagnostics.logsLine(for: KeyboardGesture(identifier: identifier)!), "\(identifier): no line")
        }
        for identifier in ["kb:command+q", "kb:command+h", "kb:command+escape", "kb:command+option+tab", "kb:command+grave"] {
            guard let gesture = KeyboardGesture(identifier: identifier) else { continue }
            check(AppSwitcherDiagnostics.logsLine(for: gesture), "\(identifier): a line")
        }
    }
}
