// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import TurnOverAX
import AXFixtures

func ulyssesFormattingProviderTests() {
    test("Ulysses formatting: bounded complete paragraph keeps UTF16 selection") {
        let text = "before\n**😀 sample**\nafter"
        let slice = UlyssesFormatting.paragraph(in: text, chunkStart: 0, storyLength: (text as NSString).length,
                                                selection: NSRange(location: 9, length: 2))
        expect(slice?.text, "**😀 sample**")
        expect(slice?.selection, NSRange(location: 2, length: 2))
        let empty = UlyssesFormatting.paragraph(in: "", chunkStart: 0, storyLength: 0, selection: NSRange(location: 0, length: 0))
        expect(empty?.text, "")
    }
    test("Ulysses formatting: clipped or cross-paragraph input is unknown") {
        check(UlyssesFormatting.paragraph(in: "sample**", chunkStart: 2, storyLength: 10,
                                         selection: NSRange(location: 4, length: 0)) == nil, "missing opening text must not be parsed")
        check(UlyssesFormatting.paragraph(in: "**sample", chunkStart: 0, storyLength: 20,
                                         selection: NSRange(location: 4, length: 0)) == nil, "missing paragraph end must not be parsed")
        check(UlyssesFormatting.paragraph(in: "a\nb", chunkStart: 0, storyLength: 3,
                                         selection: NSRange(location: 0, length: 3)) == nil, "selection across paragraphs remains unknown")
        check(UlyssesFormatting.paragraph(in: "abc", chunkStart: 0, storyLength: 3,
                                         selection: NSRange(location: 2, length: 2)) == nil, "invalid range rejected")
        let bounded = UlyssesFormatting.paragraph(in: "tail\n**sample**\nhead", chunkStart: 200, storyLength: 500,
                                                  selection: NSRange(location: 207, length: 6))
        expect(bounded?.text, "**sample**")
        expect(bounded?.selection, NSRange(location: 2, length: 6))
    }
    ulyssesFormattingCollectorTests()
}

private func ulyssesFormattingCollectorTests() {
    func fixture(_ text: String = "_sample", selection: NSRange = NSRange(location: 1, length: 0)) -> AXFixture {
        AXFixture(app: "Public Ulysses sample", bundle: "com.ulyssesapp.mac", recorded: "synthetic", root: 1,
                  application: 0, focus: 2, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXApplication"), "AXFocusedWindow": .element(1),
                                "AXFocusedUIElement": .element(2), "AXMenuBar": .element(10)]),
            .init(id: 1, attrs: ["AXRole": .string("AXWindow"), "AXChildren": .elements([2])]),
            .init(id: 2, attrs: ["AXRole": .string("AXTextArea"), "AXWindow": .element(1), "AXValue": .string(text),
                                "AXNumberOfCharacters": .number(Double(text.utf16.count)),
                                "AXSelectedTextRange": .range(selection.location, selection.length)],
                  params: [kAXStringForRangeParameterizedAttribute]),
            .init(id: 3, attrs: ["AXRole": .string("AXTextArea"), "AXWindow": .element(1)]),
            .init(id: 6, attrs: ["AXRole": .string("AXWindow"), "AXChildren": .elements([])]),
            .init(id: 10, attrs: ["AXRole": .string("AXMenuBar"), "AXChildren": .elements([11, 20])]),
            .init(id: 11, attrs: ["AXRole": .string("AXMenuBarItem"), "AXTitle": .string("Edit"), "AXChildren": .elements([12])]),
            .init(id: 12, attrs: ["AXRole": .string("AXMenu"), "AXChildren": .elements([13])]),
            .init(id: 13, attrs: ["AXRole": .string("AXMenuItem"), "AXTitle": .string("Convert Markup"), "AXChildren": .elements([14])]),
            .init(id: 14, attrs: ["AXRole": .string("AXMenu"), "AXChildren": .elements([15, 16, 17])]),
            .init(id: 15, attrs: ["AXRole": .string("AXMenuItem"), "AXTitle": .string("Markdown XL"), "AXMenuItemMarkChar": .string("✓")]),
            .init(id: 16, attrs: ["AXRole": .string("AXMenuItem"), "AXTitle": .string("Markdown")]),
            .init(id: 17, attrs: ["AXRole": .string("AXMenuItem"), "AXTitle": .string("Public custom markup")]),
            .init(id: 20, attrs: ["AXRole": .string("AXMenuBarItem"), "AXTitle": .string("Markup"), "AXChildren": .elements([21])]),
            .init(id: 21, attrs: ["AXRole": .string("AXMenu"), "AXChildren": .elements([22, 23])]),
            .init(id: 22, attrs: ["AXRole": .string("AXMenuItem"), "AXTitle": .string("Strong"), "AXEnabled": .bool(true),
                                "AXMenuItemCmdChar": .string("b"), "AXMenuItemCmdModifiers": .number(0)]),
            .init(id: 23, attrs: ["AXRole": .string("AXMenuItem"), "AXTitle": .string("Emphasis"), "AXEnabled": .bool(true),
                                "AXMenuItemCmdChar": .string("i"), "AXMenuItemCmdModifiers": .number(0)]),
        ])
    }
    func set(_ fixture: inout AXFixture, _ id: Int, _ name: String, _ value: AXFixture.Value?) {
        guard let index = fixture.nodes.firstIndex(where: { $0.id == id }) else { return }
        fixture.nodes[index].attrs[name] = value
    }
    func context(_ bundle: String = "com.ulyssesapp.mac") -> FormattingFeedback.Context {
        let focus = AXReplay.element(2)
        return .init(focus: focus, foreground: AXReplay.element(1), pid: focus.pid, bundleIdentifier: bundle, keys: 0)
    }
    func read(_ fixture: AXFixture, _ kind: FormattingFeedback.Kind = .italic,
              budget: AXWalkBudget? = nil, bundle: String = "com.ulyssesapp.mac",
              prepare: @escaping (AXUIElement) -> AXError = { _ in .success }) -> FormattingFeedback.State {
        AXReplay.load(fixture)
        defer { AXReplay.unload() }
        let limit = budget ?? AXWalkBudget(request: AXWalkRequest(), duration: 500_000_000,
                                           maxVisits: 160, maxQueries: 800, maxAXQueries: 800, maxDepth: 12)
        let result = AXReadScope.with(while: { limit.check() }, onQuery: { limit.admitAXQuery() },
                                      onResult: { limit.record($0) }) {
            UlyssesFormatting.collect(context(bundle), kind, limit, setTimeout: prepare)
        }
        check(limit.queries <= 800 && limit.axQueries <= 800 && limit.visits <= 160, "collector stays inside production query budgets")
        return result
    }
    test("Ulysses collector: verified scheme and shortcut produce pending and selected formatting states") {
        AXReplay.reads = []
        defer { AXReplay.reads = nil }
        expect(read(fixture()), .on)
        expect(read(fixture("**", selection: NSRange(location: 2, length: 0)), .bold), .on)
        expect(read(fixture("sampl_e text", selection: NSRange(location: 6, length: 0))), .on)
        let nested = fixture("**_sample_**", selection: NSRange(location: 3, length: 6))
        expect(read(nested, .bold), .on)
        expect(read(nested), .on)
        expect(read(fixture("sample", selection: NSRange(location: 6, length: 0))), .off)
        expect(read(fixture("", selection: NSRange(location: 0, length: 0))), .off)
        check(!(AXReplay.reads ?? []).contains { ["AXValue", "AXSelectedText"].contains($0.attribute) },
              "the provider requests a bounded string range, never the whole-sheet value")
        check(AXReplay.actions.isEmpty && AXReplay.sets.isEmpty, "collector never opens menus or edits text")
    }
    test("Ulysses collector: text and final validation use worker-owned focus references") {
        AXReplay.load(fixture())
        defer { AXReplay.unload() }
        let original = context()
        let identities = [ObjectIdentifier(original.focus), ObjectIdentifier(original.foreground!)]
        var configured: [ObjectIdentifier] = []
        let result = UlyssesFormatting.collect(original, .italic, AXWalkBudget(request: AXWalkRequest())) { element in
            let identity = ObjectIdentifier(element)
            check(!identities.contains(identity), "text reads never configure the captured focus or foreground handle")
            configured.append(identity)
            return .success
        }
        expect(result, .on, "fresh focus references preserve complete-paragraph state and final validation")
        check(!configured.isEmpty, "the collector prepares its own AX references")
    }
    test("Ulysses collector: unverified schemes disabled commands and remapped shortcuts stay unknown") {
        for variant in 0..<7 {
            var sample = fixture()
            switch variant {
            case 0: set(&sample, 15, "AXMenuItemMarkChar", nil); set(&sample, 17, "AXMenuItemMarkChar", .string("✓"))
            case 1: set(&sample, 17, "AXMenuItemMarkChar", .string("✓"))
            case 2: set(&sample, 15, "AXMenuItemMarkChar", .string("•"))
            case 3: set(&sample, 23, "AXMenuItemCmdChar", .string("x"))
            case 4: set(&sample, 23, "AXMenuItemCmdModifiers", .number(1))
            case 5: set(&sample, 23, "AXEnabled", .bool(false))
            default: set(&sample, 13, "AXTitle", .string("Localized conversion menu"))
            }
            AXReplay.reads = []
            expect(read(sample), .unknown)
            check(!(AXReplay.reads ?? []).contains { $0.attribute == "AXNumberOfCharacters" }, "unverified menus never admit a document read")
            AXReplay.reads = nil
        }
    }
    test("Ulysses collector: stale app focus window and another app reject the original context") {
        for variant in 0..<3 {
            var sample = fixture()
            if variant == 0 { set(&sample, 0, "AXFocusedUIElement", .element(3)) }
            if variant == 1 { set(&sample, 0, "AXFocusedWindow", .element(6)) }
            AXReplay.reads = []
            expect(read(sample, bundle: variant == 2 ? "org.turnover.other-public-app" : "com.ulyssesapp.mac"), .unknown)
            check(!(AXReplay.reads ?? []).contains { $0.attribute == "AXMenuItemMarkChar" }, "wrong context never inspects formatting marks")
            AXReplay.reads = nil
        }
    }
    test("Ulysses collector: missing truncated and overlong text do not produce a guessed state") {
        var missing = fixture(); set(&missing, 2, "AXValue", nil)
        expect(read(missing), .unknown)
        var partial = fixture(); set(&partial, 2, "AXNumberOfCharacters", .number(8))
        expect(read(partial), .unknown, "provider cannot return the advertised complete range")
        let long = fixture(String(repeating: "a", count: 10_000), selection: NSRange(location: 5000, length: 0))
        expect(read(long), .unknown, "a clipped paragraph has no trusted start or end")
        let selection = fixture(String(repeating: "a", count: 5000), selection: NSRange(location: 0, length: 4097))
        expect(read(selection), .unknown, "selection beyond the bounded provider scope is rejected")
    }
    test("Ulysses collector: changing selection count or focus during reads invalidates the result") {
        for variant in 0..<3 {
            var sample = fixture()
            AXReplay.load(sample); AXReplay.reads = []
            let original = context()
            var changed = false
            let limit = AXWalkBudget(request: AXWalkRequest(), duration: 500_000_000,
                                     maxVisits: 160, maxQueries: 800, maxAXQueries: 800, maxDepth: 12)
            let result = AXReadScope.with(while: { limit.check() }, onQuery: { limit.admitAXQuery() }, onResult: { status in
                limit.record(status)
                guard !changed, AXReplay.reads?.last?.attribute == kAXSelectedTextRangeAttribute else { return }
                changed = true
                if variant == 0 { set(&sample, 2, "AXSelectedTextRange", .range(2, 0)) }
                if variant == 1 { set(&sample, 2, "AXNumberOfCharacters", .number(8)) }
                if variant == 2 { set(&sample, 0, "AXFocusedUIElement", .element(3)) }
                // Swap synthetic data after the first range reply; no extra AX calls are made in this callback.
                AXReplay.load(sample)
            }) {
                UlyssesFormatting.collect(original, .italic, limit, setTimeout: { _ in .success })
            }
            check(changed, "the fixture changed after the initial selection was returned")
            expect(result, .unknown)
            check(limit.queries <= 800 && limit.axQueries <= 800 && limit.visits <= 160, "changed providers remain bounded")
            AXReplay.reads = nil; AXReplay.unload()
        }
    }
    test("Ulysses collector: cancellation query exhaustion and timeout setup failure perform no stale work") {
        let cancelled = AXWalkRequest(); cancelled.cancel()
        expect(read(fixture(), budget: AXWalkBudget(request: cancelled)), .unknown)
        expect(read(fixture(), budget: AXWalkBudget(request: AXWalkRequest(), duration: 0)), .unknown)
        let limited = AXWalkBudget(request: AXWalkRequest(), maxQueries: 10)
        expect(read(fixture(), budget: limited), .unknown)
        expect(limited.queries, 10)
        AXReplay.reads = []
        expect(read(fixture(), prepare: { _ in .failure }), .unknown)
        expect(AXReplay.reads?.count, 0, "an unprepared handle is never queried")
        AXReplay.reads = nil
    }
}
