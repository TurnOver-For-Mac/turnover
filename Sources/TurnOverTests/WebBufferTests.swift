// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import TurnOverAX
import AXFixtures
import os

func waitForBuffer(_ buffer: WebBuffer, file: String = #fileID, line: Int = #line) {
    let deadline = Date().addingTimeInterval(3)
    while buffer.isLoading, Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    check(!buffer.isLoading, "buffer collection completed", file: file, line: line)
}

nonisolated private func sampleCollection(_ root: AXUIElement, text: String, stop: AXWalkStop? = nil) -> WebBufferCollection {
    let child = AXUIElementCreateApplication(910_001)
    return WebBufferCollection(snapshot: AXSnapshot(nodes: [
        ElementKey(root): .init(attributes: ["AXRole": .string("AXWebArea"), "AXChildren": .array([.element(child)])]),
        ElementKey(child): .init(attributes: ["AXRole": .string("AXStaticText"), "AXValue": .string(text), "AXParent": .element(root)]),
    ]), documentText: text, focusedPart: nil, stop: stop, elapsedMs: 10)
}

func webBufferTests() {
    test("document snapshot: interpretation and navigation never fall back to live AX") {
        let root = AXUIElementCreateApplication(910_000)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), collected = DispatchSemaphore(value: 0)
        let worker = OSAllocatedUnfairLock(initialState: false)
        let buffer = WebBuffer(webArea: root, collect: { root, _, _ in
            worker.withLock { $0 = !Thread.isMainThread }
            entered.signal(); _ = release.wait(timeout: .now() + 3)
            defer { collected.signal() }
            return sampleCollection(root, text: "A public sample paragraph.")
        })
        let before = AXStats.calls
        var complete = false
        buffer.build { complete = true }
        check(entered.wait(timeout: .now() + 2) == .success, "collection started on worker")
        expect(buffer.status, .loading)
        check(!complete && buffer.text.length == 0, "request returns before a blocked provider completes")
        var heartbeat = false
        DispatchQueue.main.async { heartbeat = true }
        let deadline = Date().addingTimeInterval(1)
        while !heartbeat, Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        check(heartbeat && worker.withLock { $0 }, "main handles another event while provider is held")
        release.signal(); check(collected.wait(timeout: .now() + 2) == .success, "provider released")
        waitForBuffer(buffer)
        check(complete, "completion follows publication")
        expect(buffer.text as String, "A public sample paragraph.\n")
        expect(buffer.status, .complete)
        expect(buffer.offset(of: AXUIElementCreateApplication(910_001)), 0)
        check(buffer.find(from: -1, forward: true, roles: ["AXHeading"]) == nil, "complete snapshot has no heading")
        expect(AXStats.calls, before, "layout and snapshot searches made no live AX requests")
    }

    test("document snapshot: refresh retains old text and coalesces requests") {
        let root = AXUIElementCreateApplication(910_000)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), collected = DispatchSemaphore(value: 0)
        let buffer = WebBuffer(webArea: root, collect: { root, _, _ in
            let n = calls.withLock { $0 += 1; return $0 }
            if n == 2 { entered.signal(); _ = release.wait(timeout: .now() + 3) }
            defer { collected.signal() }
            return sampleCollection(root, text: n == 1 ? "First page text." : "Updated page text.")
        })
        buffer.build(); waitForBuffer(buffer)
        _ = collected.wait(timeout: .now() + 1)
        let reading = buffer.frozen()
        buffer.build()
        check(entered.wait(timeout: .now() + 2) == .success, "refresh is held")
        for _ in 0..<20 { buffer.build() }
        expect(buffer.text as String, "First page text.\n", "last valid same-page snapshot stays readable")
        expect(calls.withLock { $0 }, 2, "refresh requests do not restart or multiply the running walk")
        release.signal(); check(collected.wait(timeout: .now() + 2) == .success, "refresh released")
        waitForBuffer(buffer)
        expect(buffer.text as String, "Updated page text.\n")
        expect(reading.text as String, "First page text.\n", "an existing reading range retains the text its offsets describe")
        expect(buffer.lines.last?.endWithBreak, buffer.text.length, "text and offsets publish together")
    }

    test("document snapshot: navigation cancels old results and their callbacks") {
        let root = AXUIElementCreateApplication(910_000)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), collected = DispatchSemaphore(value: 0)
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let buffer = WebBuffer(webArea: root, collect: { root, _, request in
            let n = calls.withLock { $0 += 1; return $0 }
            if n == 1 {
                entered.signal(); _ = release.wait(timeout: .now() + 3)
                cancelled.withLock { $0 = request.isCancelled }
            }
            defer { collected.signal() }
            return sampleCollection(root, text: n == 1 ? "Obsolete page." : "Current page.")
        })
        var obsolete = false, current = false
        buffer.build { obsolete = true }
        check(entered.wait(timeout: .now() + 2) == .success, "first generation held")
        buffer.newPage()
        check(buffer.text.length == 0 && buffer.status == .idle, "navigation immediately removes the previous document")
        buffer.build { current = true }
        release.signal()
        check(collected.wait(timeout: .now() + 2) == .success, "old collection unwound without waiting on main")
        waitForBuffer(buffer)
        expect(buffer.text as String, "Current page.\n")
        check(current && !obsolete && cancelled.withLock { $0 }, "only current generation publishes or completes")
    }

    test("document snapshot: cancellation rejects a result already waiting for main delivery") {
        let root = AXUIElementCreateApplication(910_000)
        let returned = DispatchSemaphore(value: 0)
        let buffer = WebBuffer(webArea: root, collect: { root, _, _ in
            defer { returned.signal() }
            return sampleCollection(root, text: "Too late.")
        })
        var completed = false
        buffer.build { completed = true }
        check(returned.wait(timeout: .now() + 2) == .success, "result ready while main has not run delivery")
        buffer.cancel()
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        expect(buffer.status, .cancelled)
        check(buffer.text.length == 0 && !completed, "deactivation cannot publish or call a stale continuation")
    }

    test("document snapshot: every collection limit remains incomplete") {
        let root = AXUIElementCreateApplication(910_000)
        for reason in [AXWalkStop.deadline, .visits, .queries, .axQueries, .depth, .cycle, .providerFailure, .backoff] {
            let buffer = WebBuffer(webArea: root, collect: { root, _, _ in sampleCollection(root, text: "Available prefix.", stop: reason) })
            buffer.build(); waitForBuffer(buffer)
            expect(buffer.status, .partial, reason.rawValue)
            check(buffer.isPartial, "a limited walk cannot report a complete page")
        }
        let empty = WebBuffer(webArea: root, collect: { _, _, _ in
            WebBufferCollection(snapshot: AXSnapshot(nodes: [:]), documentText: "", focusedPart: nil, stop: .providerFailure, elapsedMs: 0)
        })
        empty.build(); waitForBuffer(empty)
        expect(empty.status, .unavailable, "provider failure before any content is distinct from an empty complete page")
    }

    test("document snapshot: control names states values and verbosity use existing presentation") {
        let fixture = AXFixture(app: "Public sample", bundle: "test.buffer", recorded: "", root: 0, application: nil, focus: nil, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXChildren": .elements([1, 2, 3])]),
            .init(id: 1, attrs: ["AXRole": .string("AXCheckBox"), "AXTitle": .string("Enable captions"), "AXValue": .number(1), "AXParent": .element(0)]),
            .init(id: 2, attrs: ["AXRole": .string("AXTextField"), "AXPlaceholderValue": .string("Search public examples"), "AXValue": .string("sample"), "AXParent": .element(0)]),
            .init(id: 3, attrs: ["AXRole": .string("AXSlider"), "AXTitle": .string("Volume"), "AXValue": .number(0.5), "AXMinValue": .number(0), "AXMaxValue": .number(1), "AXParent": .element(0)]),
        ])
        AXReplay.load(fixture); defer { AXReplay.unload() }
        guard let root = AXReplay.root else { return check(false, "fixture root") }
        let expected = (1...3).map { id -> (String, [String]) in
            let obj = ObjectFactory.make(AXReplay.element(id))
            let label = obj.name.isEmpty ? (obj.value ?? "") : obj.name
            return (label, Speech.objectPropertiesSpeech(obj, reason: .focus).filter { $0 != label })
        }
        let buffer = WebBuffer(webArea: root)
        buffer.build(); waitForBuffer(buffer)
        expect(buffer.lines.count, 3)
        for (index, entry) in expected.enumerated() where index < buffer.lines.count {
            let line = buffer.lines[index]
            expect(buffer.text.substring(with: NSRange(location: line.start, length: line.end - line.start)), entry.0)
            expect(line.fields, entry.1, "control presentation matches the live object rules")
        }
    }

    test("document snapshot: refresh anchors the caret at publication and focus departure cancels work") {
        let root = AXUIElementCreateApplication(910_000)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let buffer = WebBuffer(webArea: root, collect: { root, _, _ in
            let n = calls.withLock { $0 += 1; return $0 }
            if n == 2 { entered.signal(); _ = release.wait(timeout: .now() + 3) }
            return sampleCollection(root, text: "A public sample paragraph.")
        })
        let page = BrowseModeDocument(webArea: root, buffer: buffer)
        page.passThrough = true   // This test exercises publication ownership without automatic speech.
        API.setFocusObject(nil, ancestors: [], interceptor: page)
        defer { API.setFocusObject(nil, ancestors: []) }
        waitForBuffer(buffer)
        page.position = 2
        buffer.build()
        check(entered.wait(timeout: .now() + 2) == .success, "refresh held while the user continues reading")
        page.position = 14
        release.signal(); waitForBuffer(buffer)
        expect(page.position, 14, "publication must not restore the position from request time")
        API.setFocusObject(nil, ancestors: [])
        expect(buffer.status, .cancelled, "leaving the document retires collection and deferred actions")
        API.setFocusObject(nil, ancestors: [], interceptor: page)
        waitForBuffer(buffer)
        expect(buffer.status, .complete, "returning resumes collection rather than retaining a cancelled loading state")
        expect(page.position, 14)
        buffer.cancel()
        API.setFocusObject(nil, ancestors: [], interceptor: page)
        waitForBuffer(buffer)
        expect(buffer.status, .complete, "reactivation resumes even when the interceptor identity is unchanged")
    }

    test("document snapshot: read scopes restore nested snapshots and never admit live fallback") {
        let element = AXUIElementCreateApplication(910_000)
        let outer = AXSnapshot(nodes: [ElementKey(element): .init(attributes: ["AXRole": .string("AXButton"), "AXChildren": .array([.element(element)])], actions: ["AXPress"])])
        let inner = AXSnapshot(nodes: [ElementKey(element): .init(attributes: ["AXRole": .string("AXHeading")])])
        let before = AXStats.calls
        enum Sample: Error { case stop }
        outer.with {
            expect(element.role, "AXButton")
            expect(element.attributeResult("AXRole").value as? String, "AXButton")
            expect(element.attributeValueCountResult("AXChildren").value, 1)
            expect(element.attributesResult(["AXRole"]).attributes["AXRole"]?.value as? String, "AXButton")
            expect(element.actionNamesResult().value as? [String], ["AXPress"])
            do { try inner.with { expect(element.role, "AXHeading"); throw Sample.stop } } catch {}
            expect(element.role, "AXButton", "throwing restored the parent snapshot")
            check(element.attr("AXTitle") == nil, "missing snapshot attributes stay absent")
            check(element.parameterizedResult("AXStringForRange", axRangeValue(0, 1)).value == nil, "uncaptured parameter reads cannot make a native call")
            check(element.set("AXFocused", kCFBooleanTrue) != .success, "interpretation cannot write through the read scope")
        }
        expect(AXStats.calls, before, "all snapshot reads and the rejected write stayed local")
    }

    test("document collection: depth cycles and cancellation are reported by the actual collector") {
        var nodes = (0..<62).map { id in
            AXFixture.Node(id: id, attrs: ["AXRole": .string("AXGroup"), "AXChildren": .elements(id < 61 ? [id + 1] : [])])
        }
        nodes[0].attrs["AXRole"] = .string("AXWebArea")
        AXReplay.load(AXFixture(app: "Public sample", bundle: "test.buffer", recorded: "", root: 0, application: nil, focus: nil, nodes: nodes))
        defer { AXReplay.unload() }
        guard let root = AXReplay.root else { return check(false, "fixture root") }
        expect(WebBufferCollection.collect(root: root, focus: nil, request: AXWalkRequest()).stop, .depth)
        let request = AXWalkRequest(); request.cancel()
        let before = AXStats.calls
        expect(WebBufferCollection.collect(root: root, focus: nil, request: request).stop, .cancelled)
        expect(AXStats.calls, before, "cancelled work is rejected before its first provider query")
        nodes[1].attrs["AXChildren"] = .elements([0])
        AXReplay.load(AXFixture(app: "Public sample", bundle: "test.buffer", recorded: "", root: 0, application: nil, focus: nil, nodes: nodes))
        expect(WebBufferCollection.collect(root: AXReplay.root!, focus: nil, request: AXWalkRequest()).stop, .cycle)
    }

    test("document snapshot: text ranges and their copies retain offsets across publication") {
        var fixture = AXFixture(app: "Public sample", bundle: "test.ranges", recorded: "", root: 80, application: nil, focus: nil, nodes: [
            .init(id: 80, attrs: ["AXRole": .string("AXWebArea"), "AXChildren": .elements([81])]),
            .init(id: 81, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("The original public paragraph."), "AXParent": .element(80)]),
        ])
        AXReplay.load(fixture)
        defer { BrowseModeHandler.shared.forget(pid: 900_080); AXReplay.unload() }
        let page = BrowseModeHandler.shared.document(root: AXReplay.root!)
        waitForBuffer(page.buffer)
        guard let range = page.makeTextInfo(.all) as? BufferTextInfo else { return check(false, "buffer text range") }
        let copy = range.copy()
        fixture.nodes[1].attrs["AXValue"] = .string("Replacement text.")
        AXReplay.load(fixture)
        page.buffer.build(); waitForBuffer(page.buffer)
        expect(range.text, "The original public paragraph.\n")
        expect(copy.text, range.text, "copy preserves the same publication")
        expect(page.makeTextInfo(.all)?.text, "Replacement text.\n", "new ranges use the current publication")
        page.position = 4
        range.updateCaret()
        expect(page.position, 4, "a stale range cannot apply old offsets to the new document")
    }

    test("document collection: password values are excluded before attributes are copied") {
        let fixture = AXFixture(app: "Public sample", bundle: "test.secure-buffer", recorded: "", root: 82, application: nil, focus: nil, nodes: [
            .init(id: 82, attrs: ["AXRole": .string("AXWebArea"), "AXChildren": .elements([83])]),
            .init(id: 83, attrs: ["AXRole": .string("AXTextField"), "AXSubrole": .string("AXSecureTextField"), "AXTitle": .string("Access code"), "AXValue": .string("public dummy secret"), "AXSelectedText": .string("dummy"), "AXParent": .element(82)]),
        ])
        AXReplay.load(fixture); defer { AXReplay.unload() }
        AXReplay.reads = []
        defer { AXReplay.reads = nil }
        let collection = WebBufferCollection.collect(root: AXReplay.root!, focus: nil, request: AXWalkRequest())
        check(!(AXReplay.reads ?? []).contains { $0.id == 83 && ["AXValue", "AXSelectedText"].contains($0.attribute) },
              "the provider is never asked for the password value or selection")
        collection.snapshot.with {
            let field = AXReplay.element(83)
            expect(field.string("AXTitle"), "Access code", "the safe label remains available")
            check(field.attr("AXValue") == nil && field.attr("AXSelectedText") == nil, "neither password value is retained in the snapshot")
        }
    }

    test("document snapshot: failed refresh preserves the last valid document and its caret") {
        let root = AXUIElementCreateApplication(910_000)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let buffer = WebBuffer(webArea: root, collect: { root, _, _ in
            let n = calls.withLock { $0 += 1; return $0 }
            if n == 1 { return sampleCollection(root, text: "Still available public text.") }
            return WebBufferCollection(snapshot: AXSnapshot(nodes: [:]), documentText: "", focusedPart: nil, stop: .providerFailure, elapsedMs: 0)
        })
        let page = BrowseModeDocument(webArea: root, buffer: buffer)
        page.passThrough = true
        waitForBuffer(buffer)
        page.position = 7
        let revision = buffer.revision
        buffer.build(); waitForBuffer(buffer)
        expect(buffer.text as String, "Still available public text.\n")
        expect(buffer.revision, revision, "failure does not replace the readable publication")
        expect(page.position, 7, "failure does not reset or re-anchor the caret")
        expect(buffer.status, .partial)
        check(buffer.isPartial && buffer.isDirty, "failed refresh stays incomplete and eligible for retry")
    }

    test("document snapshot: notifications during collection are not cleared by publication") {
        let root = AXUIElementCreateApplication(910_000)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let buffer = WebBuffer(webArea: root, collect: { root, _, _ in
            let n = calls.withLock { $0 += 1; return $0 }
            if n == 1 { entered.signal(); _ = release.wait(timeout: .now() + 3) }
            return sampleCollection(root, text: "Public content.")
        })
        buffer.build()
        check(entered.wait(timeout: .now() + 2) == .success, "collection is held")
        buffer.isDirty = true
        release.signal(); waitForBuffer(buffer)
        check(buffer.isDirty, "publication did not acknowledge a notification newer than its request")
        buffer.build(); waitForBuffer(buffer)
        check(!buffer.isDirty, "a subsequent collection acknowledges that dirty generation")
    }

    test("document snapshot: a page changed before the first provider read cannot publish under the old address") {
        let root = AXUIElementCreateApplication(910_000)
        let buffer = WebBuffer(webArea: root, collect: { root, _, _ in sampleCollection(root, text: "Another page.") })
        var invalidated = false, completed = false
        buffer.acceptsSnapshot = { _ in false }
        buffer.build { completed = true }
        // The document's invalidation hook normally requests its new URL; this test retains the retired state.
        buffer.didInvalidate = { invalidated = true }
        waitForBuffer(buffer)
        check(invalidated && !completed, "a different address retires the old continuation")
        check(buffer.text.length == 0 && buffer.status == .idle, "none of that page was published as the old document")
    }

    test("document snapshot: one heading command cannot scroll an infinite feed indefinitely") {
        let root = AXUIElementCreateApplication(910_000)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let buffer = WebBuffer(webArea: root, collect: { root, _, _ in
            let n = calls.withLock { $0 += 1; return $0 }
            return sampleCollection(root, text: String(repeating: "Public feed text. ", count: n), stop: .visits)
        })
        let saved = config, sink = Speech.sink
        var said = ""
        Speech.sink = { said += $0 + " " }
        config.general.keyboardStyle = "windows"
        let page = BrowseModeDocument(webArea: root, buffer: buffer)
        page.passThrough = true
        API.setFocusObject(nil, ancestors: [], interceptor: page)
        defer { API.setFocusObject(nil, ancestors: []); config = saved; Speech.sink = sink }
        waitForBuffer(buffer)
        page.passThrough = false
        said = ""
        let key = KeyboardGesture(identifier: "kb:h")!
        guard let command = page.script(for: key) else { return check(false, "next-heading command") }
        command.handler(key)
        waitForBuffer(buffer)
        expect(calls.withLock { $0 }, 2, "the initial collection and one edge refresh, despite the feed growing every time")
        check(said.contains("read in part") && !said.contains("no next heading"), "incomplete search reports available content, not a definitive missing heading")
    }

    test("document collection: a disappearing element and oversized attributes do not discard later siblings") {
        var many: [String: AXFixture.Value] = ["AXRole": .string("AXGroup"), "AXChildren": .elements([3])]
        for i in 0..<200 { many["Custom\(i)"] = .string("public metadata") }
        AXReplay.load(.init(app: "Public changing page", bundle: "test.changing-buffer", recorded: "", root: 0, application: nil, focus: nil, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXChildren": .elements([1, 404, 2, 4])]),
            .init(id: 1, attrs: many),
            .init(id: 2, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string(String(repeating: "x", count: 131_073))]),
            .init(id: 3, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("Inside the large metadata element.")]),
            .init(id: 4, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("The surviving last sibling.")]),
        ]))
        defer { AXReplay.unload() }
        let result = WebBufferCollection.collect(root: AXReplay.root!, focus: nil, request: AXWalkRequest())
        expect(result.stop, nil, "local omissions do not make a changing page globally incomplete")
        expect(result.skippedElements, 1)
        result.snapshot.with {
            expect(AXReplay.element(3).string("AXValue"), "Inside the large metadata element.")
            expect(AXReplay.element(4).string("AXValue"), "The surviving last sibling.")
            check(AXReplay.element(2).attr("AXValue") == nil, "the oversized value alone was omitted")
        }
    }

    test("document collection: a real tree larger than the element cap remains bounded") {
        var nodes = [AXFixture.Node(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXChildren": .elements(Array(1...6005))])]
        nodes += (1...6005).map { .init(id: $0, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("Public row \($0).")]) }
        AXReplay.load(.init(app: "Public large page", bundle: "test.large-buffer", recorded: "", root: 0, application: nil, focus: nil, nodes: nodes))
        defer { AXReplay.unload() }
        let result = WebBufferCollection.collect(root: AXReplay.root!, focus: nil, request: AXWalkRequest())
        check(result.stop.map { [AXWalkStop.visits, .axQueries, .deadline].contains($0) } == true, "the actual large traversal reports its cap")
        check(result.snapshot.nodes.count <= 6000, "the safety cap is retained, not presented as a solution to long-page reachability")
        result.snapshot.with {
            expect(AXReplay.element(1).string("AXValue"), "Public row 1.")
            check(AXReplay.element(6005).attr("AXValue") == nil, "a tail beyond the cap is not claimed to be available")
        }
    }

    test("document collection: app exit during the provider read remains a failed read") {
        AXReplay.load(.init(app: "Public exiting app", bundle: "test.exiting-buffer", recorded: "", root: 0, application: nil, focus: nil, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXChildren": .elements([1, 2])]),
            .init(id: 1, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("First public row.")]),
            .init(id: 2, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("Second public row.")]),
        ]))
        defer { AXReplay.unload() }
        let root = AXReplay.root!
        var queries = 0
        let result = AXReadScope.with(while: { true }, onQuery: {
            queries += 1
            if queries == 10 { AXReplay.unload() }   // every handle becomes invalid, like process exit
            return true
        }) { WebBufferCollection.collect(root: root, focus: nil, request: AXWalkRequest()) }
        expect(result.stop, .providerFailure, "a dead root is not mistaken for isolated disappearing children")
    }

    test("document collection: queued time does not consume the actual read deadline") {
        AXReplay.load(.init(app: "Public delayed read", bundle: "test.queued-buffer", recorded: "", root: 0, application: nil, focus: nil, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXChildren": .elements([1])]),
            .init(id: 1, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("Read after queueing.")]),
        ]))
        defer { AXReplay.unload() }
        let result = WebBufferCollection.collect(root: AXReplay.root!, focus: nil, request: AXWalkRequest(startedAt: 0))
        expect(result.stop, nil, "an arbitrarily old submission still receives its own collection budget")
        result.snapshot.with { expect(AXReplay.element(1).string("AXValue"), "Read after queueing.") }
    }

    test("document snapshot: the first browse key waits for initial content") {
        let root = AXUIElementCreateApplication(910_000)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let buffer = WebBuffer(webArea: root, collect: { root, _, _ in
            entered.signal(); _ = release.wait(timeout: .now() + 3)
            return sampleCollection(root, text: "The page has arrived.")
        })
        let page = BrowseModeDocument(webArea: root, buffer: buffer)
        API.setFocusObject(nil, ancestors: [], interceptor: page)
        defer { API.setFocusObject(nil, ancestors: []) }
        check(entered.wait(timeout: .now() + 2) == .success, "initial read is held")
        var ran = false
        check(page.deferInitialContent { ran = true }, "the command is accepted for deferred execution")
        check(!ran, "no command searches an empty pending snapshot")
        release.signal(); waitForBuffer(buffer)
        check(ran, "the same command executes after initial publication")
        let arrow = KeyboardGesture(identifier: "kb:downArrow")!
        let first = page.script(for: arrow), second = page.script(for: arrow)
        check(first != nil && first === second, "loaded commands retain identity for ScriptHandler repeat tracking")
    }

    test("Say All: an existing reading snapshot continues through page refresh") {
        var nodes = [AXFixture.Node(id: 80, attrs: ["AXRole": .string("AXWebArea"), "AXChildren": .elements([81, 83, 85, 87, 89])])]
        for i in 0..<5 {
            nodes.append(.init(id: 81 + i * 2, attrs: ["AXRole": .string("AXGroup"), "AXChildren": .elements([82 + i * 2])]))
            nodes.append(.init(id: 82 + i * 2, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("Original public line \(i + 1).")]))
        }
        AXReplay.load(.init(app: "Public reading", bundle: "test.sayall-buffer", recorded: "", root: 80, application: nil, focus: nil, nodes: nodes))
        let driver = Speech.enqueueTestDriver, saved = config
        var queued: [(String, (@Sendable () -> Void)?)] = []
        Speech.enqueueTestDriver = { text, start, _ in queued.append((text, start)) }
        defer {
            SayAll.stop(); Speech.enqueueTestDriver = driver; config = saved
            BrowseModeHandler.shared.forget(pid: 900_080); AXReplay.unload()
        }
        let page = BrowseModeHandler.shared.document(root: AXReplay.root!)
        waitForBuffer(page.buffer)
        guard let reading = page.makeTextInfo(.first) else { return check(false, "initial reading range") }
        SayAll.readText(info: reading)
        nodes[0].attrs["AXChildren"] = .elements([100, 81, 83, 85, 87, 89])
        nodes.append(.init(id: 100, attrs: ["AXRole": .string("AXGroup"), "AXChildren": .elements([101])]))
        nodes.append(.init(id: 101, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("Inserted above the reader.")]))
        if let replaced = nodes.firstIndex(where: { $0.id == 88 }) { nodes[replaced].attrs["AXValue"] = .string("Replacement public text.") }
        AXReplay.load(.init(app: "Public reading", bundle: "test.sayall-buffer", recorded: "", root: 80, application: nil, focus: nil, nodes: nodes))
        page.buffer.build(); waitForBuffer(page.buffer)
        check(SayAll.isRunning, "publishing a new copy does not stop the existing reader")
        guard let start = queued.first?.1 else { return check(false, "queued speech start") }
        start()
        let until = Date().addingTimeInterval(2)
        while queued.count < 4, Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        expect(page.position, page.buffer.text.range(of: "Original public line 1").location, "the caret follows the spoken line after text is inserted above it")
        check(queued.contains { $0.0.contains("Original public line 4") }, "subsequent chunks still read the old snapshot")
        check(!queued.contains { $0.0.contains("Replacement public text") }, "a refresh cannot substitute new text under old reading offsets")
    }

    test("VoiceOver find: a dirty page is searched after its refreshed heading arrives") {
        let root = AXUIElementCreateApplication(910_000), heading = AXUIElementCreateApplication(910_002), text = AXUIElementCreateApplication(910_003)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let buffer = WebBuffer(webArea: root, collect: { root, _, _ in
            let n = calls.withLock { $0 += 1; return $0 }
            if n == 1 { return sampleCollection(root, text: "Public introduction.") }
            entered.signal(); _ = release.wait(timeout: .now() + 3)
            let ordinary = AXUIElementCreateApplication(910_001)
            return WebBufferCollection(snapshot: AXSnapshot(nodes: [
                ElementKey(root): .init(attributes: ["AXRole": .string("AXWebArea"), "AXChildren": .array([.element(ordinary), .element(heading)])]),
                ElementKey(ordinary): .init(attributes: ["AXRole": .string("AXStaticText"), "AXValue": .string("Public introduction.")]),
                ElementKey(heading): .init(attributes: ["AXRole": .string("AXHeading"), "AXValue": .number(2), "AXChildren": .array([.element(text)])]),
                ElementKey(text): .init(attributes: ["AXRole": .string("AXStaticText"), "AXValue": .string("New public heading.")]),
            ]), documentText: "", focusedPart: nil, stop: nil, elapsedMs: 0)
        })
        let page = BrowseModeDocument(webArea: root, buffer: buffer)
        API.setFocusObject(nil, ancestors: [], interceptor: page)
        let sink = Speech.sink; var heard = ""
        Speech.sink = { heard += $0 }
        defer { API.setFocusObject(nil, ancestors: []); Speech.sink = sink }
        waitForBuffer(buffer)
        buffer.isDirty = true
        page.searchKey("AXHeadingSearchKey", spoken: "heading", forward: true)
        check(entered.wait(timeout: .now() + 2) == .success, "VoiceOver find requested its refresh")
        expect(page.position, 0, "the old copy is not searched while collection is held")
        check(!heard.contains("no next heading"), "no premature missing-heading announcement")
        release.signal(); waitForBuffer(buffer)
        expect(page.position, buffer.find(from: -1, forward: true, roles: ["AXHeading"])?.offset ?? -1)
        check(page.position > 0 && !heard.contains("no next heading"), "find lands on the refreshed heading")
    }

    test("document refresh: scrolling shares AX health and cancellation admission") {
        AXReplay.load(.init(app: "Public scroll", bundle: "test.scroll-buffer", recorded: "", root: 0, application: nil, focus: nil, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXWebArea")]),
            .init(id: 1, attrs: ["AXRole": .string("AXStaticText")], actions: ["AXScrollToVisible"]),
        ]))
        defer { AXReplay.unload() }
        let before = AXStats.calls
        let buffer = WebBuffer(webArea: AXReplay.root!, collect: { root, _, _ in sampleCollection(root, text: "After scrolling.") })
        buffer.build(scrollTo: AXReplay.element(1)); waitForBuffer(buffer)
        expect(AXStats.calls, before + 1, "the actual scroll action is timed and counted by AXHealth")
        expect(AXReplay.actions.count, 1)
        let request = AXWalkRequest(); request.cancel()
        let budget = AXWalkBudget(request: request)
        let result = AXReadScope.with(while: { budget.check() }, onQuery: { budget.admitAXQuery() }) { AXReplay.element(1).actionResult("AXScrollToVisible") }
        expect(result.status, .clientWorkStopped)
        check(!result.wasAttempted, "cancelled scroll never reaches the provider")
        expect(AXReplay.actions.count, 1)
    }
}
