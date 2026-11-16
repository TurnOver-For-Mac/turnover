// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
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
}
