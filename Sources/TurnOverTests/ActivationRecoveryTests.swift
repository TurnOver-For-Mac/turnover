// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import TurnOverAX
import AXFixtures
import os

private func activationPage(live: Bool, near: Bool = false, tail: Int = 0, duplicate: Bool = false, nativeFocus: Int = 0) -> AXFixture {
    let fillers = Array(100..<3300)
    let button = live ? 20 : 10
    var children = near ? [2] + fillers : fillers + [button]
    if tail > 0 { children = [button] + Array(fillers.prefix(tail)) }
    if duplicate { children.append(30) }
    var nodes: [AXFixture.Node] = [
        .init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.com/activation"), "AXChildren": .elements(children), "AXParent": .element(1)]),
        .init(id: 1, attrs: ["AXRole": .string("AXApplication"), "AXFocusedUIElement": .element(nativeFocus)]),
        .init(id: 2, attrs: ["AXRole": .string("AXGroup"), "AXParent": .element(0), "AXChildren": .elements([button])]),
    ]
    nodes += fillers.map { .init(id: $0, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("Public older message \($0)"), "AXParent": .element(0)]) }
    if live {
        nodes += [
            .init(id: 20, attrs: ["AXRole": .string("AXButton"), "AXParent": .element(near ? 2 : 0), "AXChildren": .elements([21])], actions: ["AXPress"]),
            .init(id: 21, attrs: ["AXRole": .string("AXGroup"), "AXParent": .element(20), "AXChildren": .elements([22])]),
            .init(id: 22, attrs: ["AXRole": .string("AXGroup"), "AXParent": .element(21), "AXChildren": .elements([23, 24])]),
            .init(id: 23, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("Yes, delete"), "AXParent": .element(22)]),
            .init(id: 24, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("them"), "AXParent": .element(22)]),
        ]
    } else {
        nodes.append(.init(id: 10, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("Yes, delete them"), "AXParent": .element(near ? 2 : 0)], actions: ["AXPress"]))
    }
    if duplicate {
        nodes.append(.init(id: 30, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("Yes, delete them"), "AXParent": .element(0)], actions: ["AXPress"]))
    }
    return .init(app: "Public activation trial", bundle: "test.activation", recorded: "synthetic", root: 0, application: 1, focus: 0, nodes: nodes)
}

private func withActivationPage(near: Bool = false, tail: Int = 0, duplicate: Bool = false,
                                collect: (@Sendable (AXUIElement, AXUIElement?, AXWalkRequest) -> WebBufferCollection)? = nil,
                                _ body: (BrowseModeDocument, () -> [String]) -> Void) {
    let previousConfig = config, previousSink = Speech.sink
    let previousPid = AXHandler.shared.activePid
    AXReplay.load(activationPage(live: false, near: near, tail: tail, duplicate: duplicate))
    let root = AXReplay.element(0)
    let buffer = collect.map { WebBuffer(webArea: root, collect: $0) } ?? WebBuffer(webArea: root)
    let page = BrowseModeDocument(webArea: root, buffer: buffer)
    waitForBuffer(buffer)
    BrowseModeHandler.shared.adopt(page)
    API.setFocusObject(ObjectFactory.make(root), ancestors: [], interceptor: page)
    AXHandler.shared.activePid = root.pid
    config.general.navigationSounds = false
    var words: [String] = []
    Speech.sink = { words.append($0) }
    page.position = buffer.text.range(of: "Yes, delete them").location
    check(page.position != NSNotFound, "old copy has the button's spoken name")
    AXReplay.load(activationPage(live: true, near: near, tail: tail, duplicate: duplicate))
    defer {
        API.setFocusObject(nil, ancestors: [])
        BrowseModeHandler.shared.forget(pid: root.pid)
        waitForBuffer(buffer)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        Speech.sink = previousSink
        config = previousConfig
        AXHandler.shared.activePid = previousPid
        AXReplay.unload()
    }
    body(page, { words })
}

private func pressDeadButton(_ page: BrowseModeDocument, vo: Bool = false) {
    let key = KeyboardGesture(identifier: vo ? "kb:turnover+space" : "kb:enter")!
    if vo { VoiceOverKeysPlugin().script(for: key)?.handler(key) }
    else { page.script(for: key)?.handler(key) }
}

private func awaitRecovery() {
    RunLoop.current.run(until: Date().addingTimeInterval(0.18))
}

func activationRecoveryTests() {
    for vo in [false, true] {
        test("activation recovery: \(vo ? "VO-Space" : "Return") finds deeply labelled replacement after 3200 elements") {
            withActivationPage { page, words in
                let started = Date()
                pressDeadButton(page, vo: vo)
                check(Date().timeIntervalSince(started) < 0.1, "the key does not walk the long page on main")
                awaitRecovery()
                expect(AXReplay.actions.filter { $0.action == "AXPress" }.map(\.id), [20], "exactly the live replacement is pressed")
                check(!words().contains("nothing to activate"), "the successful repair is not reported as failure")
            }
        }
    }
    test("activation recovery: Claude keyboard confirmation completes before recovery succeeds") {
        withActivationPage { page, words in
            let moduleID = "pid.900020"
            let previousType = AppModuleHandler.shared.moduleType(for: moduleID)
            let previousPoster = KeyboardGesture.poster
            AppModuleHandler.shared.register(ClaudeAppModule.self, for: moduleID)
            let sent = Locked<[String]>([])
            KeyboardGesture.poster = { sent.value.append($0.identifier) }
            defer {
                KeyboardGesture.poster = previousPoster
                if let previousType { AppModuleHandler.shared.register(previousType, for: moduleID) }
                else { AppModuleHandler.shared.unregister(bundleIdentifier: moduleID) }
            }
            let revision = page.buffer.revision
            pressDeadButton(page, vo: true)
            RunLoop.current.run(until: Date().addingTimeInterval(0.06))
            check(AXReplay.sets.contains { $0.id == 20 && $0.attribute == kAXFocusedAttribute }, "Claude's keyboard path requested the recovered button")
            expect(sent.value, [], "no Return before native focus confirms")
            expect(page.buffer.revision, revision, "recovery cannot publish success while its press is pending")
            AXReplay.load(activationPage(live: true, nativeFocus: 20))
            awaitRecovery()
            expect(sent.value, ["kb:enter"], "exactly one Return after native focus confirms within the shared deadline")
            check(AXReplay.actions.filter { $0.action == "AXPress" }.isEmpty, "the keyboard path never also presses through AX")
            check(!words().contains("nothing to activate"), "a completed key cancels the failure announcement")
        }
    }
    test("activation recovery: Claude keyboard deadline reports failure and never presses late") {
        withActivationPage { page, words in
            let moduleID = "pid.900020"
            let previousType = AppModuleHandler.shared.moduleType(for: moduleID)
            let previousPoster = KeyboardGesture.poster
            AppModuleHandler.shared.register(ClaudeAppModule.self, for: moduleID)
            let sent = Locked<[String]>([])
            KeyboardGesture.poster = { sent.value.append($0.identifier) }
            defer {
                KeyboardGesture.poster = previousPoster
                if let previousType { AppModuleHandler.shared.register(previousType, for: moduleID) }
                else { AppModuleHandler.shared.unregister(bundleIdentifier: moduleID) }
            }
            pressDeadButton(page)
            awaitRecovery()
            check(AXReplay.sets.contains { $0.id == 20 && $0.attribute == kAXFocusedAttribute }, "the real keyboard confirmation was attempted")
            expect(words().filter { $0 == "nothing to activate" }.count, 1, "a missing keyboard confirmation gives one failure by the recovery deadline")
            expect(sent.value, [], "no unconfirmed Return")
            AXReplay.load(activationPage(live: true, nativeFocus: 20))
            awaitRecovery()
            expect(sent.value, [], "focus arriving after the shared deadline cannot press")
            check(AXReplay.actions.filter { $0.action == "AXPress" }.isEmpty, "no late AX fallback either")
            expect(words().filter { $0 == "nothing to activate" }.count, 1, "failure is announced only once")
        }
    }
    test("activation recovery: cached surviving ancestor finds a replacement far from the page end") {
        withActivationPage(near: true) { page, _ in
            pressDeadButton(page)
            awaitRecovery()
            expect(AXReplay.actions.filter { $0.action == "AXPress" }.map(\.id), [20], "dead element's cached parent takes priority")
        }
    }
    test("activation recovery: one fresh-copy retry resolves the same name nearest the old position") {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        withActivationPage(tail: 700, collect: { root, focus, request in
            reads.withLock { $0 += 1 }
            return WebBufferCollection.collect(root: root, focus: focus, request: request)
        }) { page, words in
            let before = reads.withLock { $0 }
            pressDeadButton(page)
            awaitRecovery()
            check(reads.withLock { $0 } > before, "the capped reverse search requests a fresh copy")
            expect(AXReplay.actions.filter { $0.action == "AXPress" }.map(\.id), [20], "fresh publication retries the named position once")
            check(!words().contains("nothing to activate"), "fresh-copy success completes the press")
        }
    }
    test("activation recovery: repeated labels use the old position rather than the last matching button") {
        withActivationPage(tail: 100, duplicate: true) { page, _ in
            pressDeadButton(page)
            awaitRecovery()
            expect(AXReplay.actions.filter { $0.action == "AXPress" }.map(\.id), [20], "the distant identical button is never pressed")
        }
    }
    test("activation recovery: app departure rejects a result even before the focus interceptor catches up") {
        withActivationPage { page, words in
            pressDeadButton(page)
            AXHandler.shared.activePid = -1
            awaitRecovery()
            check(AXReplay.actions.filter { $0.action == "AXPress" }.isEmpty, "native app departure retires the action")
            check(words().isEmpty, "no old-page speech after departure")
            AXHandler.shared.activePid = page.webArea.pid
            pressDeadButton(page)
            awaitRecovery()
            expect(AXReplay.actions.filter { $0.action == "AXPress" }.map(\.id), [20], "a new press on return still works")
        }
    }
    test("activation recovery: moving on retires the pending press") {
        withActivationPage { page, words in
            pressDeadButton(page)
            page.position = 0
            awaitRecovery()
            check(AXReplay.actions.filter { $0.action == "AXPress" }.isEmpty, "an old result cannot press after the reading position moves")
            check(!words().contains("nothing to activate"), "an obsolete request cannot speak over the next item")
            page.position = page.buffer.text.range(of: "Yes, delete them").location
            pressDeadButton(page)
            awaitRecovery()
            expect(AXReplay.actions.filter { $0.action == "AXPress" }.map(\.id), [20], "a fresh key still reaches the same live target")
        }
    }
    test("activation recovery: a held rebuild expires without a late press or another retry") {
        let hold = OSAllocatedUnfairLock(initialState: false)
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let release = DispatchSemaphore(value: 0)
        withActivationPage(tail: 700, collect: { root, focus, request in
            reads.withLock { $0 += 1 }
            if hold.withLock({ $0 }) { _ = release.wait(timeout: .now() + 2) }
            return WebBufferCollection.collect(root: root, focus: focus, request: request)
        }) { page, words in
            let before = reads.withLock { $0 }
            hold.withLock { $0 = true }
            pressDeadButton(page)
            awaitRecovery()
            expect(words().filter { $0 == "nothing to activate" }.count, 1, "the short deadline gives one answer while AX collection is held")
            hold.withLock { $0 = false }
            release.signal()
            waitForBuffer(page.buffer)
            check(AXReplay.actions.filter { $0.action == "AXPress" }.isEmpty, "the late rebuild cannot activate a destructive control")
            expect(reads.withLock { $0 }, before + 1, "only one rebuild was requested")
        }
    }
}
