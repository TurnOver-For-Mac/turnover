// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import TurnOverAX
import AXFixtures

private func googleFixture() -> AXFixture {
    .init(app: "Public browser editor samples", bundle: "test.browser-editors", recorded: "synthetic", root: 1,
          application: nil, focus: 4, nodes: [
        .init(id: 1, attrs: ["AXRole": .string("AXWindow"), "AXChildren": .elements([2, 12, 22])]),
        .init(id: 2, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://docs.google.com/document/d/public-sample/edit"), "AXParent": .element(1), "AXChildren": .elements([3, 6, 8])]),
        .init(id: 3, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("about:blank"), "AXParent": .element(2), "AXChildren": .elements([4, 5])]),
        .init(id: 4, attrs: ["AXRole": .string("AXTextArea"), "AXValue": .string("Public sample"), "AXNumberOfCharacters": .number(13), "AXSelectedTextRange": .range(0, 0), "AXParent": .element(3)]),
        .init(id: 5, attrs: ["AXRole": .string("AXTextField"), "AXSubrole": .string("AXSecureTextField"), "AXParent": .element(3)]),
        .init(id: 6, attrs: ["AXRole": .string("AXGroup"), "AXDOMIdentifier": .string("docs-aria-speakable"), "AXParent": .element(2), "AXChildren": .elements([7, 9])]),
        .init(id: 7, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("Public"), "AXParent": .element(6)]),
        .init(id: 9, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("announcement"), "AXParent": .element(6)]),
        .init(id: 8, attrs: ["AXRole": .string("AXMenuItem"), "AXTitle": .string("Accessibility"), "AXParent": .element(2)]),
        .init(id: 12, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .string("https://docs.google.com/spreadsheets/d/public-sheet/edit"), "AXParent": .element(1), "AXChildren": .elements([14, 16])]),
        .init(id: 14, attrs: ["AXRole": .string("AXTextField"), "AXParent": .element(12)]),
        .init(id: 16, attrs: ["AXRole": .string("AXGroup"), "AXDOMIdentifier": .string("docs-aria-speakable"), "AXParent": .element(12), "AXChildren": .elements([17])]),
        .init(id: 17, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("Public sheet"), "AXParent": .element(16)]),
        .init(id: 22, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.test/public-editor"), "AXParent": .element(1), "AXChildren": .elements([24])]),
        .init(id: 24, attrs: ["AXRole": .string("AXTextArea"), "AXParent": .element(22)]),
    ])
}

private final class GoogleReads {
    var requests: [(GoogleDocsRead, @MainActor @Sendable (GoogleDocsResult) -> Void)] = []
    var ticks: [@MainActor @Sendable () -> Void] = []
    var later: [@MainActor @Sendable () -> Void] = []
    var hints: [(String, @MainActor () -> Bool)] = []
    var cancellations = 0
    let keys = Locked(0)
    func session(_ context: DocumentContext) -> GoogleDocsSession {
        let keys = self.keys
        return GoogleDocsSession(context: context, read: { [weak self] _, kind, reply in self?.requests.append((kind, reply)) },
            repeating: { [weak self] tick in self?.ticks.append(tick); return { self?.cancellations += 1 } },
            after: { [weak self] _, callback in self?.later.append(callback) }, keyCount: { keys.value },
            hint: { [weak self] text, current in self?.hints.append((text, current)) })
    }
}

func googleDocsTests() {
    func context(_ root: Int = 2, url: String = "https://docs.google.com/document/d/public-sample/edit") -> DocumentContext {
        .init(root: AXReplay.element(root), url: url, ownerPid: AXReplay.floor + 1)
    }
    func withFixture(_ body: (DocumentAdapters, () -> [(String, Bool)]) -> Void) {
        AXReplay.load(googleFixture())
        let saved = DocumentAdapters.shared, sink = Speech.sink, poster = KeyboardGesture.poster, reads = AXReplay.reads
        let focus = API.focusObject, ancestors = API.focusAncestors, document = API.focusTreeInterceptor, foreground = API.foregroundObject
        let adapters = DocumentAdapters(allowed: { true })
        DocumentAdapters.shared = adapters
        var spoken: [(String, Bool)] = []
        Speech.sink = { spoken.append(($0, Speech.isPrivateNow)) }
        defer {
            adapters.suspend()
            API.setFocusObject(focus, ancestors: ancestors, interceptor: document)
            API.setForegroundObject(foreground)
            DocumentAdapters.shared = saved; Speech.sink = sink; KeyboardGesture.poster = poster; AXReplay.reads = reads
            AXReplay.unload()
        }
        body(adapters, { spoken })
    }
    func setFocus(_ id: Int, web: Int = 2) -> EditableText {
        let field = EditableText(element: AXReplay.element(id))
        var ancestors = [TurnOverObject(element: AXReplay.element(web)), TurnOverObject(element: AXReplay.element(1))]
        if id == 4 || id == 5 { ancestors.insert(TurnOverObject(element: AXReplay.element(3)), at: 0) }
        API.setFocusObject(field, ancestors: ancestors)
        return field
    }
    func unavailable(_ result: GoogleDocsResult) -> Bool { if case .unavailable = result { return true }; return false }

    test("Google editors: URLs select document support independently of the browser") {
        for kind in ["document", "spreadsheets", "presentation"] {
            check(GoogleDocs.isGoogleEditor("https://docs.google.com/\(kind)/d/public-sample/edit"), "recognized editor family")
        }
        for url in ["https://example.test/document/d/public", "https://docs.google.com.evil.test/document/d/public", "https://docs.google.com/drive/", "about:blank"] {
            check(!GoogleDocs.isGoogleEditor(url), "unrelated documents are ordinary browser content")
        }
    }
    test("Google queries: nested editor feedback and support are read through the bounded provider") {
        withFixture { _, _ in
            let result = GoogleDocsQuery.read(context(), .announcements(editor: AXReplay.element(4), region: nil), request: AXWalkRequest())
            if case .announcements(let region, let text) = result {
                expect(AXReplay.id(of: region), 6); expect(text, "Public announcement")
            } else { Harness.fail("complete announcement sample") }
            if case .support(true) = GoogleDocsQuery.read(context(), .support, request: AXWalkRequest()) {} else { Harness.fail("observed Accessibility menu") }
            check(AXReplay.actions.isEmpty && AXReplay.sets.isEmpty, "collection performs no application action")
        }
    }
    test("Google queries: a region cached from another tab cannot supply text") {
        withFixture { _, _ in
            let result = GoogleDocsQuery.read(context(), .announcements(editor: AXReplay.element(4), region: AXReplay.element(16)), request: AXWalkRequest())
            if case .announcements(let region, let text) = result { expect(AXReplay.id(of: region), 6); expect(text, "Public announcement") }
            else { Harness.fail("cached region was resolved in the captured document") }
            let wrongEditor = GoogleDocsQuery.read(context(), .announcements(editor: AXReplay.element(14), region: nil), request: AXWalkRequest())
            if case .differentDocument = wrongEditor {} else { Harness.fail("another tab's editor was refused") }
            let secure = GoogleDocsQuery.read(context(), .announcements(editor: AXReplay.element(5), region: nil), request: AXWalkRequest())
            if case .differentDocument = secure {} else { Harness.fail("secure targets are checked again by the worker") }
        }
    }
    test("Google queries: reused roots refuse old addresses and accept Chromium string URLs") {
        withFixture { _, _ in
            if case .differentDocument = GoogleDocsQuery.read(context(url: "https://docs.google.com/document/d/old/edit"), .support, request: AXWalkRequest()) {} else { Harness.fail("old address refused") }
            let sheet = context(12, url: "https://docs.google.com/spreadsheets/d/public-sheet/edit")
            if case .announcements(_, "Public sheet") = GoogleDocsQuery.read(sheet, .announcements(editor: AXReplay.element(14), region: nil), request: AXWalkRequest()) {} else { Harness.fail("string URL provider") }
        }
    }
    test("Google queries: cancelled limited and failed reads never establish support is off") {
        withFixture { _, _ in
            let cancelled = AXWalkRequest(); cancelled.cancel()
            check(unavailable(GoogleDocsQuery.read(context(), .support, request: cancelled)), "cancelled before collection")
            let limit = AXWalkBudget(request: AXWalkRequest(), maxAXQueries: 2)
            check(unavailable(GoogleDocsQuery.read(context(), .support, budget: limit)), "AX query cap")
            let failure = AXWalkBudget(request: AXWalkRequest())
            failure.record(.returned(.cannotComplete))
            check(unavailable(GoogleDocsQuery.read(context(), .support, budget: failure)), "provider transport failure")
            let expired = AXWalkBudget(request: AXWalkRequest(), duration: 0)
            check(unavailable(GoogleDocsQuery.read(context(), .support, budget: expired)), "expired deadline")
        }
    }
    test("Google queries: complete absence is distinct from truncated or oversized content") {
        withFixture { _, _ in
            _ = AXUIElementSetAttributeValue(AXReplay.element(8), kAXTitleAttribute as CFString, "Public menu" as CFString)
            if case .support(false) = GoogleDocsQuery.read(context(), .support, request: AXWalkRequest()) {} else { Harness.fail("complete support check") }
            _ = AXUIElementSetAttributeValue(AXReplay.element(7), kAXValueAttribute as CFString, String(repeating: "x", count: 16_385) as CFString)
            check(unavailable(GoogleDocsQuery.read(context(), .announcements(editor: AXReplay.element(4), region: nil), request: AXWalkRequest())), "oversized text is not a partial announcement")
            let cap = AXWalkBudget(request: AXWalkRequest(), maxVisits: 1)
            check(unavailable(GoogleDocsQuery.read(context(), .support, budget: cap)), "a partial tree cannot prove absence")
        }
    }
    test("Google queries: production collection leaves main and returns its complete result to main") {
        withFixture { _, _ in
            let worker = AXWalkRunner<(GoogleDocsResult, Bool)>(), captured = context()
            var delivered = false
            worker.submit { request in
                (GoogleDocsQuery.read(captured, .support, request: request), Thread.isMainThread)
            } publish: { result, onMain in
                check(!onMain && Thread.isMainThread, "AX collection and publication have separate owners")
                if case .support(true) = result {} else { Harness.fail("complete provider result") }
                delivered = true
            }
            let deadline = Date().addingTimeInterval(2)
            while !delivered, Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
            check(delivered, "bounded worker completed")
            worker.cancel()
        }
    }
    test("Google queries: provider cycles cannot become a completed support-off search") {
        withFixture { _, _ in
            _ = AXUIElementSetAttributeValue(AXReplay.element(2), kAXChildrenAttribute as CFString, [AXReplay.element(2)] as CFArray)
            check(unavailable(GoogleDocsQuery.read(context(), .support, request: AXWalkRequest())), "cyclic tree is incomplete")
        }
    }
    test("Google queries: wide trees retain positive matches within the bounded queue") {
        withFixture { _, _ in
            let children = [AXReplay.element(3), AXReplay.element(6)] + Array(repeating: AXReplay.element(8), count: 4000)
            _ = AXUIElementSetAttributeValue(AXReplay.element(2), kAXChildrenAttribute as CFString, children as CFArray)
            if case .support(true) = GoogleDocsQuery.read(context(), .support, request: AXWalkRequest()) {} else { Harness.fail("positive menu match remains authoritative") }
            if case .announcements(_, "Public announcement") = GoogleDocsQuery.read(context(), .announcements(editor: AXReplay.element(4), region: nil), request: AXWalkRequest()) {} else { Harness.fail("positive region match remains usable") }
        }
    }
    test("Google sessions: baselines are silent and appended replaced and repeated feedback stays private") {
        withFixture { _, spoken in
            let reads = GoogleReads(), session = reads.session(context())
            session.activate { true }; session.focusChanged(.init(element: AXReplay.element(4), role: "AXTextArea"))
            defer { session.deactivate() }
            reads.requests[0].1(.announcements(region: AXReplay.element(6), text: "Public"))
            expect(spoken().count, 0)
            reads.ticks.last?(); reads.requests.last?.1(.announcements(region: AXReplay.element(6), text: "Public addition"))
            reads.ticks.last?(); reads.requests.last?.1(.announcements(region: AXReplay.element(6), text: "Public addition"))
            reads.ticks.last?(); reads.requests.last?.1(.announcements(region: AXReplay.element(6), text: "Replacement"))
            expect(spoken().map(\.0), ["addition", "Replacement"])
            check(spoken().allSatisfy(\.1), "document feedback keeps the private speech flag")
        }
    }
    test("Google sessions: the first key can produce feedback before the initial sample completes") {
        withFixture { _, spoken in
            let reads = GoogleReads(), session = reads.session(context())
            session.activate { true }; session.focusChanged(.init(element: AXReplay.element(4), role: "AXTextArea"))
            defer { session.deactivate() }
            reads.keys.value += 1
            reads.requests[0].1(.announcements(region: AXReplay.element(6), text: "First key feedback"))
            expect(spoken().map(\.0), ["First key feedback"])
        }
    }
    test("Google sessions: polls coalesce and old or duplicated replies cannot complete a newer request") {
        withFixture { _, spoken in
            let reads = GoogleReads(), session = reads.session(context())
            session.activate { true }; session.focusChanged(.init(element: AXReplay.element(4), role: "AXTextArea"))
            defer { session.deactivate() }
            reads.ticks.last?(); reads.ticks.last?()
            expect(reads.requests.count, 1, "slow reads never build a timer backlog")
            reads.requests[0].1(.announcements(region: nil, text: ""))
            reads.ticks.last?()
            reads.requests[0].1(.announcements(region: nil, text: "Stale duplicate"))
            reads.ticks.last?()
            expect(reads.requests.count, 2, "the old reply did not retire the current request")
            reads.requests[1].1(.announcements(region: AXReplay.element(6), text: "Current"))
            expect(spoken().map(\.0), ["Current"])
        }
    }
    test("Google sessions: loss of eligibility and focus changes retire pending announcements") {
        withFixture { _, spoken in
            let reads = GoogleReads(), session = reads.session(context())
            let current = Locked(true)
            session.activate { current.value }; session.focusChanged(.init(element: AXReplay.element(4), role: "AXTextArea"))
            current.value = false
            reads.requests[0].1(.announcements(region: nil, text: "Late"))
            reads.ticks.last?()
            check(!session.usesNativeTextFeedback, "loss of reader ownership stops the editor")
            current.value = true; session.activate { current.value }; session.focusChanged(.init(element: AXReplay.element(4), role: "AXTextArea"))
            let pending = reads.requests.last!.1
            session.focusChanged(.init(element: AXReplay.element(8), role: "AXMenuItem"))
            pending(.announcements(region: nil, text: "Old field"))
            expect(spoken().count, 0)
            session.deactivate()
        }
    }
    test("Google sessions: secure fields have no polling or native text-feedback ownership") {
        withFixture { _, _ in
            let reads = GoogleReads(), session = reads.session(context())
            session.activate { true }; session.focusChanged(.init(element: AXReplay.element(5), role: "AXTextField", isSecure: true))
            expect(reads.requests.count, 0); check(!session.usesNativeTextFeedback, "secure input stays outside the adapter")
            session.deactivate()
        }
    }
    test("Google support: stale checks and delayed hints cannot follow another document or reader") {
        withFixture { _, _ in
            let reads = GoogleReads(), session = reads.session(context())
            session.activate { true }; reads.later[0]()
            reads.requests[0].1(.unavailable)
            expect(reads.hints.count, 0, "an incomplete check produces no off warning")
            session.deactivate(); session.activate { true }; reads.later.last?()
            reads.requests.last?.1(.support(false))
            expect(reads.hints.count, 1); check(reads.hints[0].1(), "hint belongs to current activation")
            session.deactivate()
            check(!reads.hints[0].1(), "already scheduled hint is also retired")
            session.activate { true }
            expect(reads.later.count, 2, "the same document is warned only once")
            session.deactivate()
        }
    }
    test("document adapters: actual editing scripts deliver native keys once without caret queries") {
        withFixture { adapters, spoken in
            let reads = GoogleReads()
            adapters.register("google-editors", matches: GoogleDocs.isGoogleEditor, make: reads.session)
            let field = setFocus(4)
            let posted = Locked(0)
            KeyboardGesture.poster = { _ in posted.value += 1 }
            AXReplay.reads = []
            let cases = [("caret_moveByCharacter", "kb:rightArrow"), ("caret_moveByLine", "kb:downArrow"),
                         ("caret_changeSelection", "kb:shift+rightArrow"), ("caret_backspaceCharacter", "kb:backspace"),
                         ("caret_deleteCharacter", "kb:delete"), ("caret_newLine", "kb:enter")]
            for (name, key) in cases {
                guard let script = field.script(named: name), let gesture = KeyboardGesture(identifier: key) else { Harness.fail("editing script \(name)"); continue }
                script.handler(gesture)
            }
            expect(posted.value, cases.count)
            check(!(AXReplay.reads ?? []).contains(where: { [kAXSelectedTextRangeAttribute, kAXValueAttribute, kAXNumberOfCharactersAttribute].contains($0.attribute) }), "native feedback never starts an AX caret wait")
            expect(spoken().count, 0)
        }
    }
    test("document adapters: tab navigation reused roots foreground changes and suspend retire sessions") {
        withFixture { adapters, spoken in
            let first = GoogleReads(), second = GoogleReads()
            adapters.register("google-editors", matches: GoogleDocs.isGoogleEditor) { context in context.url.contains("spreadsheets") ? second.session(context) : first.session(context) }
            let field = setFocus(4)
            check(adapters.usesNativeTextFeedback(for: field.element), "document matching includes nested typing frames")
            let next = setFocus(14, web: 12)
            first.requests[0].1(.announcements(region: nil, text: "Old tab"))
            check(adapters.usesNativeTextFeedback(for: next.element), "another editor gets its own session")
            adapters.pageChanged(root: AXReplay.element(12), url: "https://example.test/new-page")
            second.requests[0].1(.announcements(region: nil, text: "Old URL"))
            check(!adapters.usesNativeTextFeedback(for: next.element), "reused AX root does not preserve site policy")
            _ = setFocus(4)
            API.setForegroundObject(TurnOverObject(element: AXReplay.element(22)))
            check(!adapters.usesNativeTextFeedback(for: field.element), "another foreground window retires ownership immediately")
            _ = setFocus(4); Core.deactivate()
            check(!adapters.usesNativeTextFeedback(for: field.element), "reader deactivation is wired to the adapter owner")
            adapters.resume(); check(!adapters.usesNativeTextFeedback(for: field.element), "resume waits for fresh focus")
            adapters.observe(Event(.caret, field))
            check(adapters.usesNativeTextFeedback(for: field.element), "fresh caret news restarts an already focused editor")
            _ = setFocus(24, web: 22)
            check(!adapters.usesNativeTextFeedback(for: AXReplay.element(24)), "ordinary fields retain core editing")
            expect(spoken().count, 0)
        }
    }
    test("document adapters: process removal retires the editor and its pending reply") {
        withFixture { adapters, spoken in
            let reads = GoogleReads()
            adapters.register("google-editors", matches: GoogleDocs.isGoogleEditor, make: reads.session)
            let field = setFocus(4)
            adapters.forget(pid: AXReplay.floor + 1)
            reads.requests[0].1(.announcements(region: nil, text: "Terminated document"))
            check(!adapters.usesNativeTextFeedback(for: field.element), "the document's owner has gone")
            expect(spoken().count, 0)
        }
    }
    test("document adapters: navigation can select an editor on a root that previously had no adapter") {
        withFixture { adapters, _ in
            let reads = GoogleReads()
            adapters.register("google-editors", matches: GoogleDocs.isGoogleEditor, make: reads.session)
            let field = setFocus(24, web: 22)
            check(!adapters.usesNativeTextFeedback(for: field.element), "ordinary initial document")
            let url = "https://docs.google.com/presentation/d/public-slides/edit"
            _ = AXUIElementSetAttributeValue(AXReplay.element(22), "AXURL" as CFString, url as CFString)
            adapters.pageChanged(root: AXReplay.element(22), url: url)
            check(adapters.usesNativeTextFeedback(for: field.element), "same root now selects its document provider")
        }
    }
    test("Google support: the actual hint queue checks eligibility at delivery") {
        withFixture { _, spoken in
            let savedConfig = config, delay = Hints.delay
            defer { config = savedConfig; Hints.delay = delay }
            config.presentation.speakHints = true; Hints.delay = 0
            _ = setFocus(4)
            let current = Locked(true)
            var drained = false
            Hints.schedule("Public support hint", while: { current.value })
            current.value = false
            DispatchQueue.main.async { drained = true }
            let deadline = Date().addingTimeInterval(1)
            while !drained, Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
            check(drained, "hint queue drained")
            expect(spoken().count, 0, "stale hint cannot speak even when the focus element stayed the same")
        }
    }
}
