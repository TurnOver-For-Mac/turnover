// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import AXFixtures
import os

nonisolated private final class SettingsTestGate: Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    func hold() { entered.signal(); _ = release.wait(timeout: .now() + 3) }
}
nonisolated private final class SettingsTestDeliveries: Sendable {
    private let jobs = OSAllocatedUnfairLock(initialState: [@MainActor @Sendable () -> Void]())
    func append(_ body: @escaping @MainActor @Sendable () -> Void) { jobs.withLock { $0.append(body) } }
    @MainActor func one() -> Bool {
        let job = jobs.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        guard let job else { return false }; job(); return true
    }
}
nonisolated private final class SettingsTestResolver: SystemSettingsPartResolving, Sendable {
    nonisolated struct State: Sendable {
        var result: SystemSettingsPartResolution? = .init(target: AXReplay.element(20), canFocus: true)
        var verification: SystemSettingsFocusVerification? = .init(focused: AXReplay.element(20))
        var gate: SettingsTestGate?
        var reads: [SystemSettingsPart] = []
        var onMain: [Bool] = []
        var cancelled = 0
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    func resolve(_ request: SystemSettingsPartRequest, current: @escaping @Sendable () -> Bool) -> SystemSettingsPartResolution? {
        let value = state.withLock { state in
            let value = (state.result, state.gate); state.gate = nil
            state.reads.append(request.part); state.onMain.append(Thread.isMainThread); return value
        }
        value.1?.hold()
        if !current() { state.withLock { $0.cancelled += 1 } }
        return value.0   // deliberately return late data; the module must independently reject delivery
    }
    func verify(_ request: SystemSettingsPartRequest, target: AXUIElement,
                current: @escaping @Sendable () -> Bool) -> SystemSettingsFocusVerification? {
        state.withLock { $0.verification }
    }
}
private final class SettingsTestState {
    var context: SystemSettingsAppModule.Context? = .init(window: AXReplay.element(1), focus: AXReplay.element(9), ancestors: [AXReplay.element(1)])
    var actualWindow = AXReplay.element(1), actualFocus = AXReplay.element(9)
    var hasSheet = false
    var writes: [Int] = [], reviewed: [Int] = [], reported: [Int] = [], spoken: [String] = []
}
private final class SettingsModuleRig {
    let resolver = SettingsTestResolver(), delivery = SettingsTestDeliveries()
    let worker = DispatchQueue(label: "turnover.tests.system-settings")
    let keys = OSAllocatedUnfairLock(initialState: 0)
    let state = SettingsTestState()
    let module: SystemSettingsAppModule

    init?(realResolver: Bool = false) {
        BuiltInModules.register()
        guard let type = AppModuleHandler.shared.moduleType(for: SystemSettingsAppModule.bundleID) as? SystemSettingsAppModule.Type else {
            Harness.fail("System Settings module is registered"); return nil
        }
        module = type.init(pid: AXReplay.floor, bundleIdentifier: SystemSettingsAppModule.bundleID, appName: "System Settings")
        let resolver = self.resolver, delivery = self.delivery, worker = self.worker, state = self.state, keys = self.keys
        module.useForTesting(.init(resolver: realResolver ? SystemSettingsAXParts() : resolver, context: { state.context },
                                   keys: { keys.withLock { $0 } }, schedule: { worker.async(execute: $0) },
                                   deliver: { delivery.append($0) },
                                   freshlyEligible: { request, focus, current in
                                       current() && !state.hasSheet && CFEqual(state.actualWindow, request.window) && CFEqual(state.actualFocus, focus)
                                   },
                                   setFocus: { state.writes.append(AXReplay.id(of: $0)!); state.actualFocus = $0; return .success },
                                   review: { state.reviewed.append(AXReplay.id(of: $0)!) },
                                   reportFocus: { state.reported.append(AXReplay.id(of: $0)!) }, speak: { state.spoken.append($0) }))
    }
    func command(_ part: String) {
        guard let script = module.script(named: "systemSettings_" + part), let gesture = KeyboardGesture(identifier: "kb:control+command+1") else {
            return Harness.fail("registered part command exists")
        }
        script.handler(gesture)
    }
    func settle() { worker.sync {}; while delivery.one() { worker.sync {} } }
    func stop() { module.terminate(); worker.sync {} }
    func gate() -> SettingsTestGate { let gate = SettingsTestGate(); resolver.state.withLock { $0.gate = gate }; return gate }
}

private func settingsControlFixture() -> AXFixture {
    .init(app: "System Settings public sample", bundle: "test.settings.parts", recorded: "", root: 1, application: nil, focus: 9, nodes: [
        .init(id: 1, attrs: ["AXRole": .string("AXWindow"), "AXSubrole": .string("AXStandardWindow")]),
        .init(id: 9, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("Current"), "AXWindow": .element(1)]),
        .init(id: 10, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("New focus"), "AXWindow": .element(1)]),
        .init(id: 20, attrs: ["AXRole": .string("AXOutline"), "AXWindow": .element(1)]),
        .init(id: 21, attrs: ["AXRole": .string("AXRow"), "AXParent": .element(20), "AXWindow": .element(1)]),
        .init(id: 30, attrs: ["AXRole": .string("AXTextField"), "AXSubrole": .string("AXSearchField"), "AXWindow": .element(1)]),
    ])
}

func systemSettingsModuleTests() {
    test("System Settings: registered part commands leave native Tab arrows and fields alone") {
        AXReplay.load(settingsControlFixture()); defer { AXReplay.unload() }
        guard let rig = SettingsModuleRig() else { return }; defer { rig.stop() }
        for part in ["sidebar", "pane", "search"] { check(rig.module.script(named: "systemSettings_" + part) != nil, "explicit part command") }
        for key in ["kb:tab", "kb:shift+tab", "kb:downArrow", "kb:upArrow", "kb:enter", "kb:space", "kb:command+f"] {
            check(rig.module.script(for: KeyboardGesture(identifier: key)!) == nil, "native command was not rebound: \(key)")
        }
    }
    test("System Settings: native focus is reported only after actual focus verification") {
        AXReplay.load(settingsControlFixture()); defer { AXReplay.unload() }
        guard let rig = SettingsModuleRig() else { return }; defer { rig.stop() }
        rig.command("sidebar"); rig.worker.sync {}
        check(rig.delivery.one(), "discovery is held before main applies it")
        expect(rig.state.writes, [20]); expect(rig.state.reported, []); expect(rig.state.spoken, [])
        rig.settle()
        expect(rig.state.reported, [20]); expect(rig.state.reviewed, [20]); expect(rig.state.spoken, ["sidebar"])
        check(rig.resolver.state.withLock { $0.onMain.allSatisfy { !$0 } }, "discovery leaves main free")
    }
    test("System Settings: a verified descendant may hold native keyboard focus") {
        AXReplay.load(settingsControlFixture()); defer { AXReplay.unload() }
        guard let rig = SettingsModuleRig() else { return }; defer { rig.stop() }
        rig.resolver.state.withLock { $0.verification = .init(focused: AXReplay.element(21)) }
        rig.command("sidebar"); rig.worker.sync {}; _ = rig.delivery.one(); rig.worker.sync {}
        rig.state.actualFocus = AXReplay.element(21)
        rig.state.context = .init(window: AXReplay.element(1), focus: AXReplay.element(21), ancestors: [AXReplay.element(20), AXReplay.element(1)])
        rig.module.handleEvent(Event(.gainFocus, TurnOverObject(element: AXReplay.element(21))), next: {})
        rig.settle()
        expect(rig.state.reported, [21], "own focus news does not cancel verification of the containing part")
    }
    test("System Settings: unavailable native focus uses an honest review cursor") {
        AXReplay.load(settingsControlFixture()); defer { AXReplay.unload() }
        guard let rig = SettingsModuleRig() else { return }; defer { rig.stop() }
        rig.resolver.state.withLock {
            $0.result = .init(target: AXReplay.element(20), canFocus: false)
            $0.verification = .init(focused: AXReplay.element(9), inside: false)
        }
        rig.command("sidebar"); rig.settle()
        expect(rig.state.writes, []); expect(rig.state.reported, []); expect(rig.state.reviewed, [20])
        check(rig.state.spoken.last?.contains("Keyboard focus is elsewhere") == true, "do not claim keyboard movement")
    }
    test("System Settings: a rebuilt part is not used as a stale review fallback") {
        AXReplay.load(settingsControlFixture()); defer { AXReplay.unload() }
        guard let rig = SettingsModuleRig() else { return }; defer { rig.stop() }
        rig.resolver.state.withLock { $0.result = .init(target: AXReplay.element(20), canFocus: false); $0.verification = nil }
        rig.command("sidebar"); rig.settle()
        expect(rig.state.reviewed, []); expect(rig.state.reported, [])
        expect(rig.state.spoken, ["could not reach the sidebar"])
    }
    test("System Settings: new input focus window and eligibility reject held discovery") {
        for change in 0..<4 {
            AXReplay.load(settingsControlFixture())
            guard let rig = SettingsModuleRig() else { AXReplay.unload(); return }
            rig.command("sidebar"); rig.worker.sync {}
            switch change {
            case 0: rig.keys.withLock { $0 += 1 }
            case 1: rig.state.context = .init(window: AXReplay.element(1), focus: AXReplay.element(10))
            case 2: rig.state.context = .init(window: AXReplay.element(2), focus: AXReplay.element(9))
            default: rig.state.context = nil   // inactive reader, other foreground app, menu or dialog
            }
            rig.settle()
            check(rig.state.writes.isEmpty && rig.state.reviewed.isEmpty && rig.state.spoken.isEmpty, "stale discovery produced no effect: \(change)")
            rig.stop(); AXReplay.unload()
        }
    }
    test("System Settings: latest part command cancels old provider and cannot clear the new request") {
        AXReplay.load(settingsControlFixture()); defer { AXReplay.unload() }
        guard let rig = SettingsModuleRig() else { return }; defer { rig.stop() }
        let gate = rig.gate(); defer { gate.release.signal() }
        rig.command("sidebar")
        check(gate.entered.wait(timeout: .now() + 3) == .success, "old resolver reached controlled gate")
        rig.resolver.state.withLock { $0.result = .init(target: AXReplay.element(30), canFocus: true); $0.verification = .init(focused: AXReplay.element(30)) }
        rig.command("search"); gate.release.signal(); rig.settle()
        expect(rig.state.writes, [30]); expect(rig.state.reported, [30]); expect(rig.state.spoken, ["search"])
        expect(rig.resolver.state.withLock { $0.cancelled }, 1)
    }
    test("System Settings: new intent while focus verification is held suppresses cursor and speech effects") {
        AXReplay.load(settingsControlFixture()); defer { AXReplay.unload() }
        guard let rig = SettingsModuleRig() else { return }; defer { rig.stop() }
        rig.command("sidebar"); rig.worker.sync {}
        check(rig.delivery.one(), "discovery requests native focus and starts verification")
        rig.worker.sync {}   // actual verification delivery is now held
        rig.keys.withLock { $0 += 1 }
        rig.settle()
        expect(rig.state.writes, [20], "the earlier focus request happened before the newer key")
        check(rig.state.reported.isEmpty && rig.state.reviewed.isEmpty && rig.state.spoken.isEmpty,
              "a late verification cannot claim focus or move the reading cursor after new input")
    }
    test("System Settings: a newer focused descendant cannot be overwritten by an older verified row") {
        AXReplay.load(settingsControlFixture()); defer { AXReplay.unload() }
        guard let rig = SettingsModuleRig() else { return }; defer { rig.stop() }
        rig.resolver.state.withLock { $0.verification = .init(focused: AXReplay.element(21)) }
        rig.command("sidebar"); rig.worker.sync {}; _ = rig.delivery.one(); rig.worker.sync {}
        rig.state.actualFocus = AXReplay.element(22)
        rig.state.context = .init(window: AXReplay.element(1), focus: AXReplay.element(22), ancestors: [AXReplay.element(20), AXReplay.element(1)])
        rig.settle()
        check(rig.state.reported.isEmpty && rig.state.reviewed.isEmpty && rig.state.spoken.isEmpty,
              "same outline is insufficient when the focused leaf changed")
    }
    test("System Settings: fresh delivery eligibility rejects changed windows sheets and actual focus before effects") {
        for change in 0..<3 {
            AXReplay.load(settingsControlFixture())
            guard let rig = SettingsModuleRig() else { AXReplay.unload(); return }
            rig.command("sidebar"); rig.worker.sync {}
            switch change {
            case 0: rig.state.actualWindow = AXReplay.element(2)
            case 1: rig.state.hasSheet = true
            default: rig.state.actualFocus = AXReplay.element(10)
            }
            // Deliberately leave cached API Context unchanged, as before queued AX notifications arrive.
            rig.settle()
            check(rig.state.writes.isEmpty && rig.state.reviewed.isEmpty && rig.state.spoken.isEmpty,
                  "fresh window/focus/modal guard precedes effects: \(change)")
            rig.stop(); AXReplay.unload()
        }
    }
    test("System Settings: reader termination and focus loss retire delayed work") {
        for terminated in [false, true] {
            AXReplay.load(settingsControlFixture())
            guard let rig = SettingsModuleRig() else { AXReplay.unload(); return }
            rig.command("sidebar"); rig.worker.sync {}
            if terminated { rig.module.terminate() } else { rig.module.event_appModuleLoseFocus() }
            rig.settle()
            check(rig.state.writes.isEmpty && rig.state.spoken.isEmpty, "retired module did not move or announce")
            if terminated { rig.module.event_appModuleGainFocus(); rig.command("search"); rig.settle(); expect(rig.resolver.state.withLock { $0.reads.count }, 1) }
            rig.stop(); AXReplay.unload()
        }
    }
    test("System Settings: actual bounded resolver identifies recorded public parts without changing a setting") {
        AXReplay.load(try AXFixture.load(fixtureURL("settings-general"))); defer { AXReplay.unload() }
        let worker = DispatchQueue(label: "turnover.tests.settings-public-parts"), result = OSAllocatedUnfairLock(initialState: [Int?]())
        worker.sync {
            let resolver = SystemSettingsAXParts()
            for part in SystemSettingsPart.allCases {
                let found = resolver.resolve(.init(pid: AXReplay.floor, window: AXReplay.root!, part: part), current: { true })
                result.withLock { $0.append(AXReplay.id(of: found?.target)) }
            }
        }
        expect(result.withLock { $0 }, [20, 23, 16], "known sidebar and search branches anchor the unique detail scroller")
        check(AXReplay.actions.isEmpty && AXReplay.sets.isEmpty, "discovery never selected, pressed or changed settings")
    }
    test("System Settings: modal windows and ambiguous pane roots fail closed") {
        var fixture = try AXFixture.load(fixtureURL("settings-general"))
        fixture.nodes[0].attrs["AXSheets"] = .elements([190])
        AXReplay.load(fixture); defer { AXReplay.unload() }
        let resolver = SystemSettingsAXParts()
        check(resolver.resolve(.init(pid: AXReplay.floor, window: AXReplay.root!, part: .sidebar), current: { true }) == nil, "main window behind a sheet is not a target")
        fixture.nodes[0].attrs["AXSheets"] = nil
        let split = fixture.nodes.firstIndex { $0.id == 7 }!
        fixture.nodes[split].attrs["AXChildrenInNavigationOrder"] = .elements([11, 10, 12, 13, 200])
        fixture.nodes.append(.init(id: 200, attrs: ["AXRole": .string("AXScrollArea"), "AXChildrenInNavigationOrder": .elements([])]))
        AXReplay.load(fixture)
        check(resolver.resolve(.init(pid: AXReplay.floor, window: AXReplay.root!, part: .pane), current: { true }) == nil, "never guess the first scroll area from ambiguous branches")
    }
    test("System Settings: incomplete focus ancestry cannot authorize review-only fallback") {
        let original = try AXFixture.load(fixtureURL("settings-general"))
        let resolver = SystemSettingsAXParts()
        AXReplay.load(original); defer { AXReplay.unload() }
        let request = SystemSettingsPartRequest(pid: AXReplay.floor, window: AXReplay.root!, part: .sidebar)
        let outside = resolver.verify(request, target: AXReplay.element(20), current: { true })
        check(outside?.inside == false, "normal ancestry reaches the captured window outside the requested part")
        for missing in [false, true] {
            var fixture = original
            let app = fixture.nodes.firstIndex { $0.id == fixture.application }!
            fixture.nodes[app].attrs["AXFocusedUIElement"] = .element(200)
            for id in 200...215 {
                var attrs: [String: AXFixture.Value] = ["AXRole": .string("AXGroup")]
                if !missing { attrs["AXParent"] = .element(id == 215 ? 0 : id + 1) }
                fixture.nodes.append(.init(id: id, attrs: attrs))
            }
            AXReplay.load(fixture)
            check(resolver.verify(request, target: AXReplay.element(20), current: { true }) == nil,
                  "missing/clipped ancestry is incomplete, not proof of unchanged keyboard focus")
        }
    }
    test("System Settings: production effect guard refreshes actual window focus and sheets") {
        var fixture = try AXFixture.load(fixtureURL("settings-general"))
        AXReplay.load(fixture); defer { AXReplay.unload() }
        let request = SystemSettingsPartRequest(pid: AXReplay.floor, window: AXReplay.root!, part: .sidebar)
        check(SystemSettingsAXParts.eligible(request, focus: AXReplay.element(123), current: { true }), "recorded nonmodal focus matches")
        fixture.nodes[0].attrs["AXSheets"] = .elements([190]); AXReplay.load(fixture)
        check(!SystemSettingsAXParts.eligible(request, focus: AXReplay.element(123), current: { true }), "sheet on same window blocks focus")
        fixture.nodes[0].attrs["AXSheets"] = .string("malformed"); AXReplay.load(fixture)
        check(!SystemSettingsAXParts.eligible(request, focus: AXReplay.element(123), current: { true }), "malformed sheets are not empty")
        fixture.nodes[0].attrs["AXSheets"] = nil
        let app = fixture.nodes.firstIndex { $0.id == fixture.application }!
        fixture.nodes[app].attrs["AXFocusedUIElement"] = .element(124); AXReplay.load(fixture)
        check(!SystemSettingsAXParts.eligible(request, focus: AXReplay.element(123), current: { true }), "queued API focus cannot authorize an old target")
    }
    test("System Settings labels: the registered overlay uses recorded attributed descriptions") {
        AXReplay.load(try AXFixture.load(fixtureURL("settings-general"))); defer { AXReplay.unload() }
        guard let rig = SettingsModuleRig() else { return }; defer { rig.stop() }
        guard let type = rig.module.objectClass(for: AXReplay.element(120), role: .button, subrole: nil) else { return Harness.fail("Settings label overlay") }
        expect(type.init(element: AXReplay.element(120)).name, "Aaaaa", "fixture preserves the provider's attributed text as a string")
    }
    test("System Settings labels: optional attributed values are typed and bounded in UTF16") {
        expect(SystemSettingsLabelledButton.label(NSAttributedString(string: "About") as CFTypeRef), "About")
        expect(SystemSettingsLabelledButton.label("  Public label\nPublic label  " as CFString), "Public label")
        check(SystemSettingsLabelledButton.label(NSNumber(value: 4)) == nil, "wrong type is not a label")
        check(SystemSettingsLabelledButton.label(String(repeating: "😀", count: 257) as CFString) == nil, "cap is UTF16 units, before string bridging")
        check(SystemSettingsLabelledButton.label(NSAttributedString(string: String(repeating: "x", count: 513)) as CFTypeRef) == nil, "oversized attributed strings are refused")
    }
    test("System Settings labels: standard names take precedence and optional malformed labels fall back") {
        var fixture = settingsControlFixture()
        fixture.nodes.append(.init(id: 40, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("Native title"), "AXAttributedDescription": .string("Alternative")]))
        fixture.nodes.append(.init(id: 41, attrs: ["AXRole": .string("AXButton"), "AXHelp": .string("Help label"), "AXAttributedDescription": .number(3)]))
        AXReplay.load(fixture); defer { AXReplay.unload() }
        guard let rig = SettingsModuleRig() else { return }; defer { rig.stop() }
        for (id, expected) in [(40, "Native title"), (41, "Help label")] {
            guard let type = rig.module.objectClass(for: AXReplay.element(id), role: .button, subrole: nil) else { return Harness.fail("Settings label overlay") }
            expect(type.init(element: AXReplay.element(id)).name, expected)
        }
    }
}
