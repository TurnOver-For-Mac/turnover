// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import TurnOverAX
import AXFixtures
import os

private func conversationPage(_ name: String, address: String, body: String? = nil) -> AXFixture {
    .init(app: "Public conversations", bundle: "test.claude-navigation", recorded: "", root: 0, application: 1, focus: 0, nodes: [
        .init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXTitle": .string(name), "AXDescription": .string(""),
                             "AXURL": .url(address), "AXParent": .element(1), "AXChildren": .elements([2, 3])]),
        .init(id: 1, attrs: ["AXRole": .string("AXApplication"), "AXChildren": .elements([0])]),
        .init(id: 2, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string(String(repeating: (body ?? name) + " public text. ", count: 100)), "AXParent": .element(0)]),
        .init(id: 3, attrs: ["AXRole": .string("AXTextArea"), "AXTitle": .string(name + " prompt"), "AXParent": .element(0)]),
    ])
}


private func withConversationTest(_ body: (BrowseModeDocument, ClaudeAppModule, Locked<[String]>) -> Void) {
    let savedPid = AXHandler.shared.activePid
    defer { AXHandler.shared.activePid = savedPid }
    AXReplay.load(conversationPage("Old conversation", address: "https://example.com/old"))
    let root = AXReplay.element(0)
    let page = BrowseModeDocument(webArea: root)
    waitForBuffer(page.buffer)
    BrowseModeHandler.shared.adopt(page)
    AXHandler.shared.activePid = root.pid
    API.setFocusObject(ObjectFactory.make(root), ancestors: [], interceptor: page)
    let module = ClaudeAppModule(pid: root.pid, bundleIdentifier: "com.anthropic.claudefordesktop", appName: "Claude")
    let savedSink = Speech.sink
    let savedPoster = KeyboardGesture.poster
    let sent = Locked<[String]>([])
    Speech.sink = { _ in }
    KeyboardGesture.poster = { sent.value.append($0.identifier) }
    defer {
        API.setFocusObject(nil, ancestors: [])
        BrowseModeHandler.shared.forget(pid: root.pid)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        Speech.sink = savedSink
        KeyboardGesture.poster = savedPoster
        AXReplay.unload()
    }
    body(page, module, sent)
}

private func waitForConversation(_ condition: () -> Bool) {
    let until = Date().addingTimeInterval(2)
    while !condition(), Date() < until {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
    check(condition(), "the bounded conversation callback completed")
}

func claudeNavigationTests() {
    let savedPid = AXHandler.shared.activePid
    defer { AXHandler.shared.activePid = savedPid }
    for shortcut in ["kb:command+4", "kb:command+n"] {
        test("Claude navigation: \(shortcut) announces before collection and defers old-page keys") {
            AXReplay.load(conversationPage("Old conversation", address: "https://example.com/old"))
            let root = AXReplay.element(0)
            let held = OSAllocatedUnfairLock(initialState: false)
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let buffer = WebBuffer(webArea: root, collect: { root, focus, request in
                if held.withLock({ $0 }) {
                    entered.signal()
                    _ = release.wait(timeout: .now() + 3)
                }
                return WebBufferCollection.collect(root: root, focus: focus, request: request)
            })
            let page = BrowseModeDocument(webArea: root, buffer: buffer)
            BrowseModeHandler.shared.adopt(page)
            AXHandler.shared.activePid = root.pid
            API.setFocusObject(ObjectFactory.make(root), ancestors: [], interceptor: page)
            let module = ClaudeAppModule(pid: root.pid, bundleIdentifier: "com.anthropic.claudefordesktop", appName: "Claude")
            let savedSink = Speech.sink
            let savedPoster = KeyboardGesture.poster
            var said: [String] = []
            let sent = Locked<[String]>([])
            Speech.sink = { said.append($0) }
            KeyboardGesture.poster = { sent.value.append($0.identifier) }
            defer {
                held.withLock { $0 = false }
                release.signal()
                API.setFocusObject(nil, ancestors: [])
                BrowseModeHandler.shared.forget(pid: root.pid)
                Speech.sink = savedSink
                KeyboardGesture.poster = savedPoster
                AXReplay.unload()
            }
            page.refreshIfNavigated()
            waitForBuffer(buffer)
            page.position = buffer.text.length - 1
            said = []
            let key = KeyboardGesture(identifier: shortcut)!
            module.script(for: key)?.handler(key)
            var completed: [Int] = []
            check(page.deferInitialContent { completed.append(1) }, "first command waits")
            check(page.deferInitialContent { completed.append(2) }, "second command also waits")
            expect(sent.value, [shortcut], "the app's shortcut is delivered once")
            check(!buffer.lines.isEmpty, "the previous copy is preserved until a changed address is observed")

            let tab = KeyboardGesture(identifier: "kb:tab")!
            page.script(for: tab)?.handler(tab)
            check(said.isEmpty, "Tab cannot announce an offset in the old page")
            expect(sent.value, [shortcut], "Tab waits instead of reaching the old page")
            // Both commands remain queued until the new content is ready.
            let right = KeyboardGesture(identifier: "kb:rightArrow")!
            if shortcut == "kb:command+4" {
                // VoiceOver-style navigation resolves this command by name, rather than by its gesture.
                page.script(named: "moveByCharacter_forward")?.handler(right)
            } else {
                page.script(for: right)?.handler(right)
            }
            held.withLock { $0 = true }
            AXReplay.load(conversationPage("New conversation", address: "https://example.com/new"))
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
            check(entered.wait(timeout: .now() + 1) == .success, "the new copy is collecting off main")
            expect(said, ["New conversation"], "the name is heard before the whole-page read finishes")
            check(buffer.lines.isEmpty, "no old content is exposed during collection")
            held.withLock { $0 = false }
            release.signal()
            waitForBuffer(buffer)
            waitForConversation { completed.count == 2 }
            expect(said.filter { $0 == "New conversation" }.count, 1, "publication does not repeat the title")
            check(!said.contains { $0.contains("Old conversation") }, "no old text or control is read")
            expect(sent.value, [shortcut], "the queued Tab focuses a control in the new copy rather than posting into the old page")
            check(page.position > 0, "the waiting movement runs on the new copy")
            expect(completed, [1, 2], "both waiting commands run exactly once and in order")
        }
    }

    test("Claude navigation: completed content waits for its late title without repeating the old title") {
        AXReplay.load(conversationPage("Old conversation", address: "https://example.com/old"))
        let root = AXReplay.element(0)
        let buffer = WebBuffer(webArea: root)
        let page = BrowseModeDocument(webArea: root, buffer: buffer)
        BrowseModeHandler.shared.adopt(page)
        AXHandler.shared.activePid = root.pid
        API.setFocusObject(ObjectFactory.make(root), ancestors: [], interceptor: page)
        let module = ClaudeAppModule(pid: root.pid, bundleIdentifier: "com.anthropic.claudefordesktop", appName: "Claude")
        let savedSink = Speech.sink
        let savedPoster = KeyboardGesture.poster
        var said: [String] = []
        let sent = Locked<[String]>([])
        Speech.sink = { said.append($0) }
        KeyboardGesture.poster = { sent.value.append($0.identifier) }
        defer {
            API.setFocusObject(nil, ancestors: [])
            BrowseModeHandler.shared.forget(pid: root.pid)
            Speech.sink = savedSink
            KeyboardGesture.poster = savedPoster
            AXReplay.unload()
        }
        page.refreshIfNavigated()
        waitForBuffer(buffer)
        said = []
        let shortcut = KeyboardGesture(identifier: "kb:command+2")!
        module.script(for: shortcut)?.handler(shortcut)
        let tab = KeyboardGesture(identifier: "kb:tab")!
        page.script(for: tab)?.handler(tab)
        let right = KeyboardGesture(identifier: "kb:rightArrow")!
        page.script(for: right)?.handler(right)
        // The address and complete body arrive first; AXTitle still describes the departed conversation.
        AXReplay.load(conversationPage("Old conversation", address: "https://example.com/new", body: "New public body"))
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        waitForBuffer(buffer)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        check(!buffer.lines.isEmpty, "the new conversation has been collected before its title arrives")
        check(!said.contains("Old conversation"), "the stale snapshot title is not announced")
        expect(sent.value, ["kb:command+2"], "the queued Tab focuses the new copy rather than posting into the departed page")
        check(page.position > 0, "the latest waiting movement runs on the completed new content")

        AXReplay.load(conversationPage("Late new title", address: "https://example.com/new", body: "New public body"))
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        expect(said.filter { $0 == "Late new title" }.count, 1, "the late title is announced once")
        buffer.build()
        waitForBuffer(buffer)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        expect(said.filter { $0 == "Late new title" }.count, 1, "later publication does not repeat the title")
        check(!said.contains("Old conversation"), "the old title was never announced during the switch")
    }

    test("Claude navigation: focus departure discards held commands and returning can navigate") {
        AXReplay.load(conversationPage("Old conversation", address: "https://example.com/old"))
        let root = AXReplay.element(0)
        let buffer = WebBuffer(webArea: root)
        let page = BrowseModeDocument(webArea: root, buffer: buffer)
        BrowseModeHandler.shared.adopt(page)
        AXHandler.shared.activePid = root.pid
        API.setFocusObject(ObjectFactory.make(root), ancestors: [], interceptor: page)
        let module = ClaudeAppModule(pid: root.pid, bundleIdentifier: "com.anthropic.claudefordesktop", appName: "Claude")
        let savedSink = Speech.sink
        let savedPoster = KeyboardGesture.poster
        var said: [String] = []
        let sent = Locked<[String]>([])
        Speech.sink = { said.append($0) }
        KeyboardGesture.poster = { sent.value.append($0.identifier) }
        defer {
            API.setFocusObject(nil, ancestors: [])
            BrowseModeHandler.shared.forget(pid: root.pid)
            Speech.sink = savedSink
            KeyboardGesture.poster = savedPoster
            AXReplay.unload()
        }
        page.refreshIfNavigated()
        waitForBuffer(buffer)
        said = []
        page.position = buffer.text.length - 1
        let shortcut = KeyboardGesture(identifier: "kb:command+3")!
        module.script(for: shortcut)?.handler(shortcut)
        let tab = KeyboardGesture(identifier: "kb:tab")!
        page.script(for: tab)?.handler(tab)
        API.setFocusObject(nil, ancestors: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        expect(sent.value, ["kb:command+3"], "departure must not post the waiting Tab into another app")
        check(!said.contains("Old conversation"), "the watcher does not announce a stale title after focus leaves")

        AXReplay.load(conversationPage("Returned conversation", address: "https://example.com/returned"))
        AXHandler.shared.activePid = root.pid
        API.setFocusObject(ObjectFactory.make(root), ancestors: [], interceptor: page)
        page.refreshIfNavigated()
        waitForBuffer(buffer)
        page.position = 0
        let right = KeyboardGesture(identifier: "kb:rightArrow")!
        page.script(for: right)?.handler(right)
        check(page.position > 0, "returning to the cached page does not leave navigation permanently deferred")
        expect(sent.value, ["kb:command+3"], "return does not replay the discarded Tab")
    }

    test("Claude navigation: an address change during settle keeps commands for the new copy") {
        withConversationTest { page, module, _ in
            let shortcut = KeyboardGesture(identifier: "kb:command+2")!
            module.script(for: shortcut)?.handler(shortcut)
            var completed: [String] = []
            check(page.deferInitialContent { completed.append(page.buffer.text as String) }, "navigation waits")
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
            expect(completed, [], "old-page polls do not consume navigation")
            AXReplay.load(conversationPage("New settled conversation", address: "https://example.com/new-settled"))
            waitForConversation { completed.count == 1 }
            check(completed.first?.contains("New settled conversation") == true, "the queued command reads the new copy")
            check(completed.first?.contains("Old conversation") == false, "the old copy never receives the command")
        }
    }

    test("Claude navigation: departure before a held provider ceiling discards queued keys") {
        withConversationTest { page, module, sent in
            let entered = OSAllocatedUnfairLock(initialState: false)
            let returned = OSAllocatedUnfairLock(initialState: false)
            let release = DispatchSemaphore(value: 0)
            let read = module.conversationRead
            module.conversationRead = { root in
                let snapshot = read(root)
                entered.withLock { $0 = true }
                _ = release.wait(timeout: .now() + 2)
                returned.withLock { $0 = true }
                return snapshot
            }
            module.conversationWaitLimit = 0.2
            defer { release.signal(); waitForConversation { returned.withLock { $0 } } }
            page.position = page.buffer.text.length - 1
            let shortcut = KeyboardGesture(identifier: "kb:command+1")!
            module.script(for: shortcut)?.handler(shortcut)
            var completed = 0
            check(page.deferInitialContent { completed += 1 }, "the command is queued")
            let tab = KeyboardGesture(identifier: "kb:tab")!
            page.script(for: tab)?.handler(tab)
            waitForConversation { entered.withLock { $0 } }
            AXHandler.shared.activePid = -1   // The interceptor can lag native app activation.
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            expect(completed, 0, "the independent ceiling discards departed-page commands")
            expect(sent.value, ["kb:command+1"], "the deadline cannot send Tab to another app")
            release.signal()
            waitForConversation { returned.withLock { $0 } }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            expect(completed, 0, "a late worker cannot revive discarded commands")
            expect(sent.value, ["kb:command+1"])
        }
    }

    test("Claude navigation: unchanged answered address preserves the copy and releases every queued command") {
        withConversationTest { page, module, sent in
            page.position = page.buffer.text.length - 1
            let position = page.position
            let text = (page.buffer.text as String)
            let shortcut = KeyboardGesture(identifier: "kb:command+4")!
            let before = AXStats.calls
            module.script(for: shortcut)?.handler(shortcut)
            expect(AXStats.calls, before, "the initial shortcut does no live accessibility work on main")
            var completed: [Int] = []
            check(page.deferInitialContent { completed.append(1) }, "first command waits for a provider answer")
            check(page.deferInitialContent { completed.append(2) }, "a newer command preserves the first")
            let tab = KeyboardGesture(identifier: "kb:tab")!
            page.script(for: tab)?.handler(tab)
            expect(sent.value, ["kb:command+4"], "the intercepted Tab is initially held")
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
            expect(completed, [], "early old-page answers cannot release commands")
            expect(sent.value, ["kb:command+4"], "Tab stays queued during the settle")
            waitForConversation { completed.count == 2 }
            expect(completed, [1, 2], "the unchanged answer releases both commands in order")
            expect(sent.value, ["kb:command+4", "kb:tab"], "the actual queued Tab is posted once")
            expect((page.buffer.text as String), text, "the existing copy survives an unchanged address")
            expect(page.position, position, "the existing reading position survives")
        }
    }

    test("Claude navigation: a held provider cannot delay the ceiling and its late reply is ignored") {
        withConversationTest { page, module, sent in
            page.position = page.buffer.text.length - 1
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let returned = OSAllocatedUnfairLock(initialState: false)
            let offMain = OSAllocatedUnfairLock(initialState: false)
            let read = module.conversationRead
            module.conversationRead = { root in
                offMain.withLock { $0 = !Thread.isMainThread }
                let snapshot = read(root)
                entered.signal()
                _ = release.wait(timeout: .now() + 2)
                returned.withLock { $0 = true }
                return snapshot
            }
            module.conversationWaitLimit = 0.15
            defer { release.signal(); waitForConversation { returned.withLock { $0 } } }
            let shortcut = KeyboardGesture(identifier: "kb:command+n")!
            let before = AXStats.calls
            module.script(for: shortcut)?.handler(shortcut)
            expect(AXStats.calls, before, "sending the shortcut makes zero synchronous provider calls")
            var completed: [Int] = []
            check(page.deferInitialContent { completed.append(1) }, "first command is queued")
            check(page.deferInitialContent { completed.append(2) }, "second command is also queued")
            let tab = KeyboardGesture(identifier: "kb:tab")!
            page.script(for: tab)?.handler(tab)
            AXReplay.load(conversationPage("Late ignored conversation", address: "https://example.com/late"))
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            check(entered.wait(timeout: .now() + 0.1) == .success, "the actual production reader has entered its held worker")
            check(offMain.withLock { $0 }, "the provider callback executes off main")
            expect(completed, [], "the worker remains held before the ceiling")
            waitForConversation { completed.count == 2 }
            expect(completed, [1, 2], "the ceiling drains both commands once despite the blocked worker")
            expect(sent.value, ["kb:command+n", "kb:tab"], "the ceiling delivers the actual intercepted Tab once")
            let position = page.position
            release.signal()
            waitForConversation { returned.withLock { $0 } }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            expect(completed, [1, 2], "the late reply cannot replay drained commands")
            expect(page.position, position, "the late reply cannot move the reading position")
        }
    }

    test("Claude navigation: repeated shortcuts preserve the queue and reject an obsolete worker reply") {
        withConversationTest { page, module, sent in
            let entered = OSAllocatedUnfairLock(initialState: 0)
            let releases = [DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)]
            let returned = OSAllocatedUnfairLock(initialState: 0)
            let read = module.conversationRead
            module.conversationRead = { root in
                let snapshot = read(root)
                let index = entered.withLock { value in let old = value; value += 1; return old }
                if index < releases.count { _ = releases[index].wait(timeout: .now() + 2) }
                returned.withLock { $0 += 1 }
                return snapshot
            }
            module.conversationWaitLimit = 1
            defer {
                for release in releases { release.signal() }
                waitForConversation { returned.withLock { $0 } >= min(2, entered.withLock { $0 }) }
            }
            let first = KeyboardGesture(identifier: "kb:command+1")!
            module.script(for: first)?.handler(first)
            var completed: [Int] = []
            check(page.deferInitialContent { completed.append(1) }, "first switch holds its command")
            waitForConversation { entered.withLock { $0 } == 1 }
            let second = KeyboardGesture(identifier: "kb:command+2")!
            module.script(for: second)?.handler(second)
            check(page.deferInitialContent { completed.append(2) }, "the repeated switch appends its command")
            AXReplay.load(conversationPage("Latest conversation", address: "https://example.com/latest"))
            releases[0].signal()
            waitForConversation { entered.withLock { $0 } == 2 }
            expect(completed, [], "an obsolete unchanged-address reply cannot release the new switch's queue")
            releases[1].signal()
            waitForConversation { completed.count == 2 }
            expect(completed, [1, 2], "the latest reply drains commands from both shortcuts exactly once")
            expect(sent.value, ["kb:command+1", "kb:command+2"], "both native shortcuts were posted once")
            check((page.buffer.text as String).contains("Latest conversation"), "the current provider result selects the final conversation copy")
        }
    }

    test("Claude navigation: other modules retain native session keys") {
        let ordinary = AppModule(pid: 0, bundleIdentifier: "test.other", appName: "Other")
        for key in ["kb:command+1", "kb:command+4", "kb:command+n"] {
            check(ordinary.script(for: KeyboardGesture(identifier: key)!) == nil, "ordinary apps do not opt into the wait")
        }
    }
}
