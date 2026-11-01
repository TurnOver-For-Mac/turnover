// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import TurnOverAX
import AXFixtures

func textEditFormattingTests() {
    func fixture() -> AXFixture {
        AXFixture(app: "Public TextEdit sample", bundle: "com.apple.TextEdit", recorded: "synthetic", root: 1,
                  application: 0, focus: 2, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXApplication"), "AXFocusedWindow": .element(1), "AXFocusedUIElement": .element(2), "AXMenuBar": .element(10)]),
            .init(id: 1, attrs: ["AXRole": .string("AXWindow"), "AXChildren": .elements([2])]),
            .init(id: 2, attrs: ["AXRole": .string("AXTextArea"), "AXWindow": .element(1)]),
            .init(id: 3, attrs: ["AXRole": .string("AXTextArea"), "AXWindow": .element(1)]),
            .init(id: 6, attrs: ["AXRole": .string("AXWindow"), "AXChildren": .elements([])]),
            .init(id: 10, attrs: ["AXRole": .string("AXMenuBar"), "AXChildren": .elements([11])]),
            .init(id: 11, attrs: ["AXRole": .string("AXMenuBarItem"), "AXTitle": .string("Format"), "AXChildren": .elements([12])]),
            .init(id: 12, attrs: ["AXRole": .string("AXMenu"), "AXChildren": .elements([13])]),
            .init(id: 13, attrs: ["AXRole": .string("AXMenuItem"), "AXTitle": .string("Font"), "AXChildren": .elements([14])]),
            .init(id: 14, attrs: ["AXRole": .string("AXMenu"), "AXChildren": .elements([15, 16])]),
            .init(id: 15, attrs: ["AXRole": .string("AXMenuItem"), "AXTitle": .string("Bold"), "AXEnabled": .bool(true),
                                "AXMenuItemCmdChar": .string("b"), "AXMenuItemCmdModifiers": .number(0), "AXMenuItemMarkChar": .string("✓")]),
            .init(id: 16, attrs: ["AXRole": .string("AXMenuItem"), "AXTitle": .string("Italic"), "AXEnabled": .bool(true),
                                "AXMenuItemCmdChar": .string("i"), "AXMenuItemCmdModifiers": .number(0)]),
            .init(id: 17, attrs: ["AXRole": .string("AXMenuItem"), "AXTitle": .string("Other command"), "AXEnabled": .bool(true),
                                "AXMenuItemCmdChar": .string("b"), "AXMenuItemCmdModifiers": .number(0)]),
        ])
    }
    func context(bundle: String = "com.apple.TextEdit") -> FormattingFeedback.Context {
        let focus = AXReplay.element(2)
        return .init(focus: focus, foreground: AXReplay.element(1), pid: focus.pid, bundleIdentifier: bundle, keys: 0)
    }
    func set(_ fixture: inout AXFixture, _ id: Int, _ name: String, _ value: AXFixture.Value?) {
        guard let index = fixture.nodes.firstIndex(where: { $0.id == id }) else { return }
        fixture.nodes[index].attrs[name] = value
    }
    func read(_ fixture: AXFixture, _ kind: FormattingFeedback.Kind = .bold,
              budget: AXWalkBudget? = nil, prepare: @escaping (AXUIElement) -> AXError = { _ in .success }) -> FormattingFeedback.State {
        AXReplay.load(fixture)
        defer { AXReplay.unload() }
        return TextEditFormatting.collect(context(), kind, budget ?? AXWalkBudget(request: AXWalkRequest()), setTimeout: prepare)
    }

    test("TextEdit formatting: closed-menu checked and actual noValue states work without reading characters") {
        AXReplay.reads = []
        defer { AXReplay.reads = nil }
        expect(read(fixture()), .on)
        expect(read(fixture(), .italic), .off)
        check(!(AXReplay.reads ?? []).contains { ["AXValue", "AXSelectedText", "AXNumberOfCharacters"].contains($0.attribute) },
              "typing mode never comes from a neighbour character or private text")
        check(AXReplay.actions.isEmpty && AXReplay.sets.isEmpty, "reading the closed menu neither opens it nor modifies the document")
    }
    test("TextEdit formatting: captured reader handles stay identity-only while worker copies are queried") {
        AXReplay.load(fixture())
        defer { AXReplay.unload() }
        let original = context()
        let identities = [ObjectIdentifier(original.focus), ObjectIdentifier(original.foreground!)]
        var configured: [ObjectIdentifier] = []
        let state = TextEditFormatting.collect(original, .bold, AXWalkBudget(request: AXWalkRequest())) { element in
            let identity = ObjectIdentifier(element)
            check(!identities.contains(identity), "collector never changes a captured reader handle's timeout")
            configured.append(identity)
            return .success
        }
        expect(state, .on, "fresh worker references still read the verified state")
        check(!configured.isEmpty, "worker-owned handles were prepared")
        var attempted = 0
        let query = FormattingQuery(context: original, budget: AXWalkBudget(request: AXWalkRequest())) { _ in
            attempted += 1; return .success
        }
        check(!query.prepare(original.focus) && !query.prepare(original.foreground!), "defensive guard refuses shared reader references")
        expect(attempted, 0, "the timeout setter is never called for either captured reference")
    }
    test("TextEdit formatting: only the observed check mark and actual noValue have boolean meaning") {
        func result(_ value: CFTypeRef?, _ status: AXQueryStatus) -> AXQueryResult<CFTypeRef> {
            .init(value: value, status: status, elapsedNanoseconds: 0, wasAttempted: true)
        }
        expect(TextEditFormatting.markState(result(nil, .returned(.noValue))), .off)
        expect(TextEditFormatting.markState(result("✓" as CFString, .returned(.success))), .on)
        for status in [AXQueryStatus.returned(.attributeUnsupported), .returned(.cannotComplete), .returned(.invalidUIElement),
                       .returned(.apiDisabled), .batchNull, .invalidResponse, .clientWorkStopped,
                       .deferred(AXBackoff(reason: .timeout, remainingNanoseconds: 1))] {
            expect(TextEditFormatting.markState(result(nil, status)), .unknown)
        }
        for mark in ["", "-", "•", "✔", "✓✓"] {
            expect(TextEditFormatting.markState(result(mark as CFString, .returned(.success))), .unknown)
        }
        expect(TextEditFormatting.markState(result(nil, .returned(.success))), .unknown)
        expect(TextEditFormatting.markState(result(kCFBooleanTrue, .returned(.success))), .unknown)
    }
    test("TextEdit formatting: disabled missing remapped and duplicate commands stay unknown") {
        for variant in 0..<6 {
            var sample = fixture()
            switch variant {
            case 0: set(&sample, 15, "AXEnabled", .bool(false))
            case 1: set(&sample, 15, "AXEnabled", nil)
            case 2: set(&sample, 15, "AXMenuItemCmdModifiers", .number(1))
            case 3: set(&sample, 15, "AXMenuItemCmdChar", .string("x"))
            case 4: set(&sample, 14, "AXChildren", .elements([15, 16, 17]))
            default: set(&sample, 15, "AXTitle", .string("Other command"))
            }
            expect(read(sample), .unknown)
        }
    }
    test("TextEdit formatting: unobserved menu structure and duplicate identities remain unknown") {
        for variant in 0..<4 {
            var sample = fixture()
            switch variant {
            case 0: set(&sample, 11, "AXTitle", .string("Localized format menu"))
            case 1: set(&sample, 13, "AXChildren", .elements([]))
            case 2: set(&sample, 10, "AXChildren", .elements([11, 11]))
            default: set(&sample, 10, "AXChildren", .elements(Array(repeating: 11, count: 81)))
            }
            expect(read(sample), .unknown)
        }
    }
    test("TextEdit formatting: menus beyond eight children find and validate every candidate") {
        var sample = fixture()
        let fillers = Array(20..<30)
        for id in fillers {
            sample.nodes.append(.init(id: id, attrs: ["AXRole": .string("AXMenuItem"), "AXTitle": .string("Public menu item \(id)"),
                                                       "AXMenuItemCmdChar": .string("")]))
        }
        set(&sample, 14, "AXChildren", .elements(fillers + [15, 16]))
        expect(read(sample), .on, "Bold beyond the first eight-item page is read")
        expect(read(sample, .italic), .off, "Italic beyond the first page retains actual noValue semantics")
        set(&sample, 14, "AXChildren", .elements([15] + fillers + [16, 17]))
        expect(read(sample), .unknown, "a duplicate shortcut after the first page is not hidden by early success")
        set(&sample, 14, "AXChildren", .elements([15] + fillers + [16]))
        set(&sample, 29, "AXRole", .string("AXButton"))
        expect(read(sample), .unknown, "a malformed menu-item role on a later page prevents a claimed state")
    }
    test("TextEdit formatting: stale keyboard focus and window are rejected before reading menu state") {
        for variant in 0..<2 {
            var sample = fixture()
            set(&sample, 0, variant == 0 ? "AXFocusedUIElement" : "AXFocusedWindow", .element(variant == 0 ? 3 : 6))
            AXReplay.reads = []
            expect(read(sample), .unknown)
            check(!(AXReplay.reads ?? []).contains { $0.attribute == "AXMenuItemMarkChar" }, "stale context performs no formatting query")
            AXReplay.reads = nil
        }
    }
    test("TextEdit formatting: focus changing during the query cannot publish the earlier menu mark") {
        var sample = fixture()
        AXReplay.load(sample)
        defer { AXReplay.unload() }
        let original = context()
        let state = TextEditFormatting.collect(original, .bold, AXWalkBudget(request: AXWalkRequest())) { element in
            if CFEqual(element, AXReplay.element(15)) {
                set(&sample, 0, "AXFocusedUIElement", .element(3))
                AXReplay.load(sample)
            }
            return .success
        }
        expect(state, .unknown)
    }
    test("TextEdit formatting: cancellation deadline and failed timeout setup admit no stale state") {
        let cancelled = AXWalkRequest(); cancelled.cancel()
        expect(read(fixture(), budget: AXWalkBudget(request: cancelled)), .unknown)
        expect(read(fixture(), budget: AXWalkBudget(request: AXWalkRequest(), duration: 0)), .unknown)
        AXReplay.reads = []
        expect(read(fixture(), prepare: { _ in .failure }), .unknown)
        expect(AXReplay.reads?.count, 0, "an exact handle without its short timeout is never queried")
        AXReplay.reads = nil
    }
    test("TextEdit formatting: the app-specific noValue convention is never used for another app") {
        AXReplay.load(fixture())
        defer { AXReplay.unload() }
        var prepared = false
        let state = TextEditFormatting.collect(context(bundle: "org.turnover.other-public-app"), .italic,
                                               AXWalkBudget(request: AXWalkRequest())) { _ in prepared = true; return .success }
        expect(state, .unknown)
        check(!prepared, "unsupported apps do not start menu work")
    }
}
