// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import TurnOverAX
import AXFixtures
import os

private func conversationPage(_ name: String, address: String, body: String? = nil, recents: [String]? = nil, claude6Layout: Bool = false) -> AXFixture {
    var fixture = AXFixture(app: "Public conversations", bundle: "test.claude-navigation", recorded: "", root: 0, application: 1, focus: 0, nodes: [
        .init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXTitle": .string(name), "AXDescription": .string(""),
                             "AXURL": .url(address), "AXParent": .element(1), "AXChildren": .elements([2, 3])]),
        .init(id: 1, attrs: ["AXRole": .string("AXApplication"), "AXChildren": .elements([0])]),
        .init(id: 2, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string(String(repeating: (body ?? name) + " public text. ", count: 100)), "AXParent": .element(0)]),
        .init(id: 3, attrs: ["AXRole": .string("AXTextArea"), "AXTitle": .string(name + " prompt"), "AXParent": .element(0)]),
    ])
    if let recents {
        fixture.nodes[0].attrs["AXChildren"] = .elements([10, 2, 3])
        fixture.nodes += [
            .init(id: 10, attrs: ["AXRole": .string("AXGroup"), "AXSubrole": .string("AXLandmarkComplementary"), "AXParent": .element(0), "AXChildren": .elements([11])]),
            .init(id: 11, attrs: ["AXRole": .string("AXGroup"), "AXParent": .element(10), "AXChildren": .elements([12] + recents.indices.map { 20 + $0 * 10 })]),
            .init(id: 12, attrs: ["AXRole": .string("AXGroup"), "AXParent": .element(11), "AXChildren": .elements([13])]),
            .init(id: 13, attrs: ["AXRole": .string("AXHeading"), "AXParent": .element(12), "AXChildren": .elements([14])]),
            .init(id: 14, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("Recents"), "AXExpanded": .bool(true), "AXParent": .element(13)]),
        ]
        for (index, title) in recents.enumerated() {
            let row = 20 + index * 10
            if claude6Layout {
                // 19 Nov 2026, Claude 6.6395.1: the row's button is titled name plus state and holds no static
                // text; the first row holds a second button; a hint line with no button follows the first row.
                fixture.nodes += [
                    .init(id: row, attrs: ["AXRole": .string("AXGroup"), "AXParent": .element(11), "AXChildren": .elements(index == 0 ? [row + 1, row + 6, row + 8] : [row + 1, row + 6])]),
                    .init(id: row + 1, attrs: ["AXRole": .string("AXGroup"), "AXParent": .element(row), "AXChildren": .elements([row + 2])]),
                    .init(id: row + 2, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string(title + " Unread response"), "AXParent": .element(row + 1), "AXChildren": .elements(index == 0 ? [row + 3] : [])]),
                    .init(id: row + 3, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("Hide nested sessions " + title), "AXParent": .element(row + 2)]),
                    .init(id: row + 6, attrs: ["AXRole": .string("AXGroup"), "AXParent": .element(row), "AXChildren": .elements([row + 7])]),
                    .init(id: row + 7, attrs: ["AXRole": .string("AXPopUpButton"), "AXTitle": .string("…"), "AXDescription": .string("More options for " + title), "AXParent": .element(row + 6)]),
                    .init(id: row + 8, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("Quick reply controls available"), "AXParent": .element(row)]),
                ]
                continue
            }
            fixture.nodes += [
                .init(id: row, attrs: ["AXRole": .string("AXGroup"), "AXParent": .element(11), "AXChildren": .elements([row + 1, row + 6])]),
                .init(id: row + 1, attrs: ["AXRole": .string("AXGroup"), "AXParent": .element(row), "AXChildren": .elements([row + 2])]),
                .init(id: row + 2, attrs: ["AXRole": .string("AXButton"), "AXParent": .element(row + 1), "AXChildren": .elements([row + 3])]),
                .init(id: row + 3, attrs: ["AXRole": .string("AXGroup"), "AXParent": .element(row + 2), "AXChildren": .elements([row + 4, row + 5])]),
                .init(id: row + 4, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string(title), "AXParent": .element(row + 3)]),
                .init(id: row + 5, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("Idle"), "AXParent": .element(row + 3)]),
                .init(id: row + 6, attrs: ["AXRole": .string("AXGroup"), "AXParent": .element(row), "AXChildren": .elements([row + 7])]),
                .init(id: row + 7, attrs: ["AXRole": .string("AXPopUpButton"), "AXTitle": .string("More options for session"), "AXParent": .element(row + 6)]),
            ]
        }
    }
    return fixture
}


private func withConversationTest(recents: [String]? = nil, truncatedRecents: Bool = false, collapsedRecents: Bool = false, claude6Layout: Bool = false, _ body: (BrowseModeDocument, ClaudeAppModule, Locked<[String]>) -> Void) {
    let savedPid = AXHandler.shared.activePid
    defer { AXHandler.shared.activePid = savedPid }
    var fixture = conversationPage("Old conversation", address: "https://example.com/old", recents: recents, claude6Layout: claude6Layout)
    if truncatedRecents, let index = fixture.nodes.firstIndex(where: { $0.id == 42 }) {
        fixture.nodes[index].attrs["AXChildren"] = .elements([])
    }
    if collapsedRecents, let index = fixture.nodes.firstIndex(where: { $0.id == 14 }) {
        fixture.nodes[index].attrs["AXExpanded"] = .bool(false)
    }
    AXReplay.load(fixture)
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
    for initialFocusMode in [false, true] {
        for focusInPrompt in [false, true] {
            test("Claude navigation: changed page restores Prompt focus \(initialFocusMode) \(focusInPrompt) without focus news") {
                withConversationTest { page, module, _ in
                    page.passThrough = initialFocusMode
                    let key = KeyboardGesture(identifier: "kb:command+3")!
                    module.script(for: key)?.handler(key)
                    var destination = conversationPage("Public destination", address: "https://example.com/destination")
                    destination.nodes[3].attrs["AXTitle"] = .string("Prompt")
                    destination.nodes[1].attrs["AXFocusedUIElement"] = .element(focusInPrompt ? 3 : 0)
                    AXReplay.load(destination)
                    // No gainFocus event: the native field retained focus across the URL reset.
                    waitForConversation { !page.navigationTitleOwned }
                    expect(page.passThrough, focusInPrompt, "only a natively focused Prompt receives typing after the reset")
                    if focusInPrompt {
                        let letter = KeyboardGesture(identifier: "kb:s")!
                        check(page.script(for: letter) == nil, "typing is no longer trapped by browse mode")
                    } else {
                        let field = ObjectFactory.make(AXReplay.element(3))
                        API.setFocusObject(field, ancestors: field.ancestors, interceptor: page)
                        page.handleEvent(Event(.gainFocus, field)) {}
                        check(page.passThrough, "Prompt focus landing after the switch enters focus mode too")
                    }
                }
            }
        }
    }
    test("Claude navigation: queued browse intent survives Prompt mode restoration") {
        withConversationTest { page, module, _ in
            let key = KeyboardGesture(identifier: "kb:command+3")!
            module.script(for: key)?.handler(key)
            check(page.deferInitialContent { page.setPassThrough(false, announce: false) }, "browse command waits for the destination")
            var destination = conversationPage("Public destination", address: "https://example.com/destination")
            destination.nodes[3].attrs["AXTitle"] = .string("Prompt")
            destination.nodes[1].attrs["AXFocusedUIElement"] = .element(3)
            AXReplay.load(destination)
            waitForConversation { !page.navigationTitleOwned }
            check(!page.passThrough, "finishing the switch cannot override a replayed browse command")
        }
    }
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

    test("Claude navigation: completed content waits for its known late title without repeating the old title") {
        AXReplay.load(conversationPage("Old conversation", address: "https://example.com/old", recents: ["Old conversation", "Late new title"]))
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
        AXReplay.load(conversationPage("Old conversation", address: "https://example.com/new", body: "New public body", recents: ["Old conversation", "Late new title"]))
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        waitForBuffer(buffer)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        check(!buffer.lines.isEmpty, "the new conversation has been collected before its title arrives")
        check(!said.contains("Old conversation"), "the stale snapshot title is not announced")
        expect(sent.value, ["kb:command+2"], "the queued Tab focuses the new copy rather than posting into the departed page")
        check(page.position > 0, "the latest waiting movement runs on the completed new content")

        AXReplay.load(conversationPage("Late new title", address: "https://example.com/new", body: "New public body", recents: ["Old conversation", "Late new title"]))
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
            module.conversationRead = { root, recents in
                let snapshot = read(root, recents)
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

    test("Claude switch: a press that changed nothing is said so, and a changed value is never pressed again") {
        withConversationTest { page, module, sent in
            let savedSink = Speech.sink
            var said: [String] = []
            Speech.sink = { said.append($0) }
            defer { Speech.sink = savedSink }
            for attempt in [1, 2] { module.recoverUnchangedToggle(page.webArea, attempt: attempt, stillUnchanged: { false }) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            expect(sent.value, [], "a value that has changed gets no second key")
            expect(said, [], "and nothing is said by the recovery")
            module.toggleStayedUnchanged(page.webArea)
            expect(said, ["did not change"], "when no way worked, it is said")
        }
    }

    test("Claude prompt: Return that sends the message says sent at once, in the prompt only") {
        withConversationTest { _, module, _ in
            let savedSink = Speech.sink
            var said: [String] = []
            Speech.sink = { said.append($0) }
            defer { Speech.sink = savedSink }
            module.returnSentText(inField: "Search")
            expect(said, [], "another field says nothing")
            module.returnSentText(inField: "Prompt")
            expect(said, ["sent"], "the prompt says sent once, as a queued message that cuts nothing off")
        }
    }

    test("Claude navigation: Recents in Claude 6's layout are read, so the row is named at once") {
        withConversationTest(recents: ["Public first", "Public second", "Public third", "Old conversation"], claude6Layout: true) { page, module, sent in
            let savedSink = Speech.sink
            var said: [String] = []
            Speech.sink = { said.append($0) }
            defer { Speech.sink = savedSink }
            page.position = page.buffer.text.length - 1
            let shortcut = KeyboardGesture(identifier: "kb:command+4")!
            module.script(for: shortcut)?.handler(shortcut)
            waitForConversation { said == ["Old conversation"] }
            expect(said, ["Old conversation"], "the open conversation is said once, from the row read")
        }
    }

    test("Claude navigation: the open conversation at row 4, read fresh, keeps the copy and is said after the settle") {
        withConversationTest(recents: ["Public first", "Public second", "Public third", "Old conversation"]) { page, module, sent in
            let savedSink = Speech.sink
            var said: [String] = []
            Speech.sink = { said.append($0) }
            defer { Speech.sink = savedSink }
            page.position = page.buffer.text.length - 1
            let position = page.position
            let text = page.buffer.text as String
            let shortcut = KeyboardGesture(identifier: "kb:command+4")!
            let before = AXStats.calls
            module.script(for: shortcut)?.handler(shortcut)
            expect(AXStats.calls, before, "the key makes no provider call on main")
            expect(said, [], "nothing is said from the published copy at the key")
            waitForConversation { said == ["Old conversation"] }
            check(!page.navigationTitleOwned, "already here ends the switch")
            check(!page.deferInitialContent({}), "no wait is left behind")
            expect(page.buffer.text as String, text, "the existing copy survives")
            expect(page.position, position, "the existing reading position survives")
            expect(sent.value, ["kb:command+4"])
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            expect(said, ["Old conversation"], "there is no delayed duplicate")
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
            module.conversationRead = { root, recents in
                offMain.withLock { $0 = !Thread.isMainThread }
                let snapshot = read(root, recents)
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
            module.conversationRead = { root, recents in
                let snapshot = read(root, recents)
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

    test("Claude navigation: shortcut during rebuilding keeps the starting title and says only the final destination") {
        withConversationTest { page, module, sent in
            let savedSink = Speech.sink
            var said: [String] = []
            Speech.sink = { said.append($0) }
            defer { Speech.sink = savedSink }
            let first = KeyboardGesture(identifier: "kb:command+1")!
            module.script(for: first)?.handler(first)
            // Reproduce newPage clearing the snapshot between shortcuts, before the provider title changes.
            page.buffer.newPage()
            page.buffer.build()
            check(page.buffer.isLoading, "collection has started between the two shortcuts")
            check(page.buffer.lines.isEmpty, "the rebuild has emptied the captured title before the second key")
            let second = KeyboardGesture(identifier: "kb:command+2")!
            module.script(for: second)?.handler(second)
            RunLoop.current.run(until: Date().addingTimeInterval(0.34))
            expect(said, [], "an unchanged provider title cannot announce the conversation being left")
            AXReplay.load(conversationPage("Final public destination", address: "https://example.com/final"))
            waitForConversation { said.contains("Final public destination") }
            waitForBuffer(page.buffer)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            expect(said, ["Final public destination"], "only the last shortcut's destination is announced")
            expect(sent.value, ["kb:command+1", "kb:command+2"])
        }
    }

    // 17 Nov 2026: a shortcut pressed while a long copy is still read in, after the earlier switch has said its title.
    // With the sidebar hidden, the first fresh answer at the old address names the conversation being left.
    test("Claude navigation: a shortcut pressed after arrival but before the copy is complete leaves silently") {
        withConversationTest { page, module, sent in
            let savedSink = Speech.sink
            var said: [String] = []
            Speech.sink = { said.append($0) }
            defer { Speech.sink = savedSink }
            let first = KeyboardGesture(identifier: "kb:command+3")!
            module.script(for: first)?.handler(first)
            AXReplay.load(conversationPage("Arrived public conversation", address: "https://example.com/arrived"))
            waitForConversation { said.contains("Arrived public conversation") }
            // The earlier switch has spoken and still owns the page while its copy is being read in.
            page.buffer.newPage()
            page.buffer.build()
            check(page.buffer.isLoading, "the arrived conversation's copy is still being read in")
            check(page.navigationTitleOwned, "the earlier switch still owns the page")
            let second = KeyboardGesture(identifier: "kb:command+4")!
            module.script(for: second)?.handler(second)
            RunLoop.current.run(until: Date().addingTimeInterval(0.34))
            expect(said, ["Arrived public conversation"], "the conversation being left is not said again")
            AXReplay.load(conversationPage("Next public destination", address: "https://example.com/next"))
            waitForConversation { said.contains("Next public destination") }
            waitForBuffer(page.buffer)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            expect(said, ["Arrived public conversation", "Next public destination"], "the destination is said exactly once")
            expect(sent.value, ["kb:command+3", "kb:command+4"])
        }
    }

    // 17 Nov 2026 (log): the destination's Prompt took the keyboard after the unchanged settle had released
    // the wait, and its own announcement was said just before the title.
    test("Claude navigation: the destination's Prompt focus is not said during a numbered switch") {
        withConversationTest { page, module, _ in
            let savedSink = Speech.sink
            var said: [String] = []
            Speech.sink = { said.append($0) }
            defer { Speech.sink = savedSink }
            let key = KeyboardGesture(identifier: "kb:command+2")!
            module.script(for: key)?.handler(key)
            RunLoop.current.run(until: Date().addingTimeInterval(0.34))
            check(!page.deferInitialContent({}), "the unchanged settle has released the wait")
            check(page.navigationTitleOwned, "the switch is still waiting for its destination")
            var destination = conversationPage("Prompt public destination", address: "https://example.com/prompt")
            destination.nodes[3].attrs["AXTitle"] = .string("Prompt")
            destination.nodes[1].attrs["AXFocusedUIElement"] = .element(3)
            AXReplay.load(destination)
            let field = ObjectFactory.make(AXReplay.element(3))
            API.setFocusObject(field, ancestors: field.ancestors, interceptor: page)
            let focus = Event(.gainFocus, field)
            check(module.ignoresFocus(focus), "the Prompt's focus does not cut off speech during the switch")
            var passedOn = false
            module.handleEvent(focus) { passedOn = true }
            check(!passedOn, "the Prompt's own announcement is not made during the switch")
            check(page.passThrough, "the Prompt is still in focus mode for typing")
            waitForConversation { said.contains("Prompt public destination") }
            waitForBuffer(page.buffer)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            expect(said, ["Prompt public destination"], "only the title is said")
            check(page.passThrough, "focus mode stays on in the Prompt after the switch")
            check(!module.ignoresFocus(focus), "after the switch the Prompt's focus is said as usual")
        }
    }

    // 17 Nov 2026: a second shortcut before the first has said anything, with the sidebar hidden. The later shortcut
    // supersedes the first, and the conversation the first reached is the one being left.
    test("Claude navigation: a second shortcut before the first has said anything does not say the first's destination") {
        withConversationTest { page, module, sent in
            let savedSink = Speech.sink
            var said: [String] = []
            Speech.sink = { said.append($0) }
            defer { Speech.sink = savedSink }
            let first = KeyboardGesture(identifier: "kb:command+3")!
            module.script(for: first)?.handler(first)
            // The first switch has reached its conversation, which is still busy: nothing said yet.
            var busyPage = conversationPage("Intermediate public conversation", address: "https://example.com/intermediate")
            busyPage.nodes[0].attrs["AXElementBusy"] = .bool(true)
            AXReplay.load(busyPage)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            expect(said, [], "the first switch has said nothing")
            check(page.navigationTitleOwned, "the first switch still owns the page")
            page.buffer.newPage()
            page.buffer.build()
            check(page.buffer.isLoading, "the copy is being read in at the second key")
            let second = KeyboardGesture(identifier: "kb:command+4")!
            module.script(for: second)?.handler(second)
            // The first conversation settles: it is the one being left, not the destination.
            AXReplay.load(conversationPage("Intermediate public conversation", address: "https://example.com/intermediate"))
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            expect(said, [], "the conversation the first switch reached is not said as the second's destination")
            AXReplay.load(conversationPage("Final public destination", address: "https://example.com/final"))
            waitForConversation { said.contains("Final public destination") }
            waitForBuffer(page.buffer)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            expect(said, ["Final public destination"], "only the final destination is said, once")
            expect(sent.value, ["kb:command+3", "kb:command+4"])
        }
    }

    test("Claude navigation: an unknown starting title is taken from the first unchanged answer, silently") {
        withConversationTest { page, module, sent in
            let savedSink = Speech.sink
            var said: [String] = []
            Speech.sink = { said.append($0) }
            defer { Speech.sink = savedSink }
            // No switch owns the page and its copy is being read in: the title is unknown at the key.
            page.buffer.newPage()
            page.buffer.build()
            check(page.buffer.isLoading, "the copy is being read in at the key")
            check(!page.navigationTitleOwned, "no earlier switch owns the page")
            let key = KeyboardGesture(identifier: "kb:command+2")!
            module.script(for: key)?.handler(key)
            RunLoop.current.run(until: Date().addingTimeInterval(0.34))
            expect(said, [], "the conversation being left is not announced as the destination")
            AXReplay.load(conversationPage("Later public destination", address: "https://example.com/later"))
            waitForConversation { said.contains("Later public destination") }
            waitForBuffer(page.buffer)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            expect(said, ["Later public destination"], "only the destination is said, once")
            expect(sent.value, ["kb:command+2"])
        }
    }

    test("Claude navigation: Command 2 keeps watching beyond the unchanged settle without old speech") {
        withConversationTest { page, module, sent in
            let savedSink = Speech.sink
            var said: [String] = []
            Speech.sink = { said.append($0) }
            defer { Speech.sink = savedSink }
            let key = KeyboardGesture(identifier: "kb:command+2")!
            module.script(for: key)?.handler(key)
            RunLoop.current.run(until: Date().addingTimeInterval(0.34))
            expect(said, [], "the unchanged pre-switch title stays silent beyond the settle")
            AXReplay.load(conversationPage("Delayed public destination", address: "https://example.com/delayed"))
            waitForConversation { said.contains("Delayed public destination") }
            waitForBuffer(page.buffer)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            expect(said, ["Delayed public destination"], "only the destination is spoken, exactly once after collection")
            expect(sent.value, ["kb:command+2"], "the real script posts the shortcut once")
        }
    }

    for shortcut in ["kb:command+3", "kb:command+4", "kb:command+5", "kb:command+6"] {
        for missingURL in [false, true] {
            test("Claude navigation: \(shortcut) announces a changed title with \(missingURL ? "missing" : "unchanged") URL") {
                withConversationTest { page, module, sent in
                    let savedSink = Speech.sink
                    var said: [String] = []
                    Speech.sink = { said.append($0) }
                    defer { Speech.sink = savedSink }
                    let key = KeyboardGesture(identifier: shortcut)!
                    module.script(for: key)?.handler(key)
                    RunLoop.current.run(until: Date().addingTimeInterval(0.34))
                    expect(said, [], "unchanged old title stays silent before the title-only destination arrives")
                    var destination = conversationPage("Title-only public destination", address: "https://example.com/old")
                    if missingURL { destination.nodes[0].attrs.removeValue(forKey: "AXURL") }
                    AXReplay.load(destination)
                    waitForConversation { said.contains("Title-only public destination") }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.35))
                    expect(said, ["Title-only public destination"], "title evidence announces once independently of the URL")
                    expect(sent.value, [shortcut], "the real conversation script delivers its native key once")
                    check(!page.buffer.isLoading, "the copy is settled before the final speech assertion")
                }
            }
        }
    }

    for knownSidebar in [false, true] {
        test("Claude navigation: equal destination titles announce after loading with \(knownSidebar ? "duplicate sidebar rows" : "a hidden sidebar")") {
            withConversationTest(recents: knownSidebar ? ["Old conversation", "Old conversation"] : nil) { page, module, sent in
                let savedSink = Speech.sink
                var said: [String] = []
                Speech.sink = { said.append($0) }
                defer { Speech.sink = savedSink }
                let key = KeyboardGesture(identifier: "kb:command+2")!
                module.script(for: key)?.handler(key)
                expect(said, [], "duplicate labels cannot prove that the selected conversation is already open")
                var destination = conversationPage("Old conversation", address: "https://example.com/equal-title", body: "Different public destination body")
                destination.nodes[0].attrs["AXElementBusy"] = .bool(true)
                AXReplay.load(destination)
                waitForConversation { (page.buffer.text as String).contains("Different public destination body") }
                waitForBuffer(page.buffer)
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                expect(said, [], "a busy destination with the old label must not announce early")
                destination.nodes[0].attrs["AXElementBusy"] = .bool(false)
                AXReplay.load(destination)
                waitForConversation { said == ["Old conversation"] }
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                expect(said, ["Old conversation"], "the loaded destination is heard once, before the eight-second ceiling")
                check(!page.navigationTitleOwned, "arrival has completed rather than waiting for the ceiling")
                expect(sent.value, ["kb:command+2"])
            }
        }
    }

    test("Claude navigation: repeated Claude Code title suffixes and first body line do not add speech") {
        withConversationTest { page, module, sent in
            let savedSink = Speech.sink
            var said: [String] = []
            Speech.sink = { said.append($0) }
            defer { Speech.sink = savedSink }
            let key = KeyboardGesture(identifier: "kb:command+2")!
            module.script(for: key)?.handler(key)
            var destination = conversationPage("Public destination - Claude Code - Claude Code", address: "https://example.com/clean")
            destination.nodes[2].attrs["AXValue"] = .string("Claude Code\n" + String(repeating: "Public destination body. ", count: 100))
            AXReplay.load(destination)
            waitForConversation { said.contains("Public destination") }
            waitForBuffer(page.buffer)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            expect(said, ["Public destination"], "the exact speech after collection contains just the cleaned title")
            expect(sent.value, ["kb:command+2"])
        }
    }

    test("Claude navigation: ceiling speaks a fresh provider read and ignores the held stale result") {
        withConversationTest { page, module, sent in
            page.position = page.buffer.text.length - 1
            let savedSink = Speech.sink
            var said: [String] = []
            Speech.sink = { said.append($0) }
            defer { Speech.sink = savedSink }
            let entered = OSAllocatedUnfairLock(initialState: 0)
            let returned = OSAllocatedUnfairLock(initialState: false)
            let release = DispatchSemaphore(value: 0)
            let read = module.conversationRead
            module.conversationRead = { root, recents in
                let index = entered.withLock { value in let old = value; value += 1; return old }
                let snapshot = read(root, recents)
                if index == 0 {
                    _ = release.wait(timeout: .now() + 2)
                    returned.withLock { $0 = true }
                }
                return snapshot
            }
            module.conversationWaitLimit = 0.15
            defer {
                release.signal()
                waitForConversation { returned.withLock { $0 } }
            }
            let key = KeyboardGesture(identifier: "kb:command+5")!
            module.script(for: key)?.handler(key)
            var completed: [Int] = []
            check(page.deferInitialContent { completed.append(1) }, "the first command queues behind the real script")
            check(page.deferInitialContent { completed.append(2) }, "the second command queues in order")
            let tab = KeyboardGesture(identifier: "kb:tab")!
            page.script(for: tab)?.handler(tab)
            waitForConversation { entered.withLock { $0 } == 1 }
            waitForConversation { completed.count == 2 }
            expect(completed, [1, 2], "the ceiling releases commands while the provider remains held")
            expect(sent.value, ["kb:command+5", "kb:tab"], "the queued native key is delivered once independently of speech")
            AXReplay.load(conversationPage("Fresh ceiling destination", address: "https://example.com/fresh"))
            release.signal()
            waitForConversation { said.contains("Fresh ceiling destination") }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            check(entered.withLock { $0 } >= 2, "the deadline submits a new provider read")
            expect(said, ["Fresh ceiling destination"], "the stale pre-deadline answer is ignored and fresh speech occurs once")
            expect(completed, [1, 2], "the late worker cannot replay queued commands")
            expect(sent.value, ["kb:command+5", "kb:tab"], "the late worker cannot repost Tab")
        }
    }

    for number in 4...9 {
        test("Claude navigation: verified three-row sidebar rejects missing conversation \(number) without changing mode") {
            withConversationTest(recents: ["Public first", "Public second", "Old conversation"]) { page, module, sent in
                let savedSink = Speech.sink
                var said: [String] = []
                Speech.sink = { said.append($0) }
                defer { Speech.sink = savedSink }
                page.passThrough = true
                let key = KeyboardGesture(identifier: "kb:command+\(number)")!
                module.script(for: key)?.handler(key)
                waitForConversation { !said.isEmpty }
                expect(said, ["no conversation \(number)"], "the first fresh read of Recents answers with the number")
                check(page.passThrough, "focus mode remains unchanged, avoiding a mode sound")
                check(!page.deferInitialContent({}), "a missing target does not begin a wait")
                expect(sent.value, ["kb:command+\(number)"])
            }
        }
    }

    test("Claude navigation: collapsed Recents with captured rows rejects a missing number immediately") {
        withConversationTest(recents: ["Public first", "Public second", "Old conversation"], collapsedRecents: true) { page, module, sent in
            let savedSink = Speech.sink
            var said: [String] = []
            Speech.sink = { said.append($0) }
            defer { Speech.sink = savedSink }
            page.passThrough = true
            let key = KeyboardGesture(identifier: "kb:command+9")!
            module.script(for: key)?.handler(key)
            waitForConversation { !said.isEmpty }
            expect(said, ["no conversation 9"], "known missing numbers do not wait for a ceiling")
            check(page.passThrough, "the Prompt stays in focus mode")
            check(!page.deferInitialContent({}), "a known missing number never starts a navigation wait")
            expect(sent.value, ["kb:command+9"])
        }
    }

    for collapsed in [false, true] {
        for focusMode in [false, true] {
            test("Claude navigation: \(collapsed ? "collapsed" : "hidden") unknown number preserves \(focusMode ? "focus" : "browse") mode and reports missing only at the ceiling") {
                withConversationTest(recents: collapsed ? [] : nil, collapsedRecents: collapsed) { page, module, sent in
                    let savedSink = Speech.sink
                    var said: [String] = []
                    Speech.sink = { said.append($0) }
                    defer { Speech.sink = savedSink }
                    page.passThrough = focusMode
                    module.conversationWaitLimit = 0.45
                    let key = KeyboardGesture(identifier: "kb:command+9")!
                    module.script(for: key)?.handler(key)
                    expect(said, [], "the unavailable count cannot immediately prove a missing number")
                    expect(page.passThrough, focusMode, "the shortcut preserves the Prompt's current mode")
                    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                    expect(said, [], "unchanged early polls cannot speak the old title or claim a missing number")
                    expect(page.passThrough, focusMode, "the unchanged settle preserves mode too")
                    waitForConversation { said.contains("no conversation 9") }
                    expect(said, ["no conversation 9"], "the unchanged URL at the ceiling reports only the missing number")
                    expect(page.passThrough, focusMode, "the ceiling leaves the Prompt's mode unchanged")
                    expect(sent.value, ["kb:command+9"])
                }
            }
        }
        test("Claude navigation: \(collapsed ? "collapsed" : "hidden") unknown number with a changed URL announces its destination") {
            withConversationTest(recents: collapsed ? [] : nil, collapsedRecents: collapsed) { page, module, _ in
                let savedSink = Speech.sink
                var said: [String] = []
                Speech.sink = { said.append($0) }
                defer { Speech.sink = savedSink }
                page.passThrough = true
                module.conversationWaitLimit = 0.7
                let key = KeyboardGesture(identifier: "kb:command+9")!
                module.script(for: key)?.handler(key)
                check(page.passThrough, "an unknown target keeps the Prompt in focus mode until its URL changes")
                AXReplay.load(conversationPage("Public hidden-sidebar destination", address: "https://example.com/hidden-destination"))
                waitForConversation { said.contains("Public hidden-sidebar destination") }
                waitForBuffer(page.buffer)
                RunLoop.current.run(until: Date().addingTimeInterval(0.75))
                expect(said, ["Public hidden-sidebar destination"], "a changed URL must never be reported as a missing number")
            }
        }
    }

    test("Claude navigation: the open conversation at row 3 is said once, without a wait") {
        withConversationTest(recents: ["Public first", "Public second", "Old conversation"]) { page, module, _ in
            let savedSink = Speech.sink
            var said: [String] = []
            Speech.sink = { said.append($0) }
            defer { Speech.sink = savedSink }
            page.passThrough = true
            let key = KeyboardGesture(identifier: "kb:command+3")!
            module.script(for: key)?.handler(key)
            check(!page.deferInitialContent({}), "in the Prompt, the key starts no wait")
            waitForConversation { !said.isEmpty }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            expect(said, ["Old conversation"])
            check(page.passThrough, "the Prompt stays in focus mode")
        }
    }

    test("Claude navigation: an existing second row still waits for a delayed destination") {
        withConversationTest(recents: ["Public first", "New public destination", "Old conversation"]) { page, module, _ in
            let savedSink = Speech.sink
            var said: [String] = []
            Speech.sink = { said.append($0) }
            defer { Speech.sink = savedSink }
            let key = KeyboardGesture(identifier: "kb:command+2")!
            module.script(for: key)?.handler(key)
            RunLoop.current.run(until: Date().addingTimeInterval(0.34))
            expect(said, [], "an existing different row cannot announce the current title or claim to be missing")
            AXReplay.load(conversationPage("New public destination", address: "https://example.com/new"))
            waitForConversation { said.contains("New public destination") }
            waitForBuffer(page.buffer)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            expect(said, ["New public destination"])
        }
    }

    for truncated in [false, true] {
        test("Claude navigation: \(truncated ? "truncated" : "absent") sidebar cannot prove a missing target") {
            withConversationTest(recents: truncated ? ["Public first", "Public second", "Old conversation"] : nil, truncatedRecents: truncated) { _, module, _ in
                let savedSink = Speech.sink
                var said: [String] = []
                Speech.sink = { said.append($0) }
                defer { Speech.sink = savedSink }
                let key = KeyboardGesture(identifier: "kb:command+9")!
                module.script(for: key)?.handler(key)
                expect(said, [], "an unknown sidebar cannot claim no conversation 9")
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                check(!said.contains("no conversation 9"), "unchanged provider answers do not turn unknown structure into missing-target evidence")
            }
        }
    }

    test("Claude navigation: title preceding a late URL stays the sole announcement after publication") {
        withConversationTest { page, module, _ in
            let savedSink = Speech.sink
            var said: [String] = []
            Speech.sink = { said.append($0) }
            defer { Speech.sink = savedSink }
            let key = KeyboardGesture(identifier: "kb:command+2")!
            module.script(for: key)?.handler(key)
            var destination = conversationPage("Public early title - Claude Code - Claude Code", address: "https://example.com/old")
            destination.nodes[2].attrs["AXValue"] = .string("Claude Code\n" + String(repeating: "Public destination text. ", count: 100))
            AXReplay.load(destination)
            waitForConversation { said.contains("Public early title") }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            expect(said, ["Public early title"], "the title alone is spoken before the delayed URL")
            destination.nodes[0].attrs["AXURL"] = .url("https://example.com/early-title")
            AXReplay.load(destination)
            waitForConversation { (page.buffer.text as String).contains("Public destination text.") }
            waitForBuffer(page.buffer)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            expect(said, ["Public early title"], "late URL collection cannot repeat the title or announce the Claude Code body line")
        }
    }

    test("Claude navigation: external publication before a watcher reply leaves destination speech to the watcher") {
        withConversationTest { page, module, _ in
            let savedSink = Speech.sink
            var said: [String] = []
            Speech.sink = { said.append($0) }
            defer { Speech.sink = savedSink }
            let key = KeyboardGesture(identifier: "kb:command+2")!
            module.script(for: key)?.handler(key)
            RunLoop.current.run(until: Date().addingTimeInterval(0.34))
            expect(said, [], "the old copy remains silent through the unchanged settle")
            let entered = OSAllocatedUnfairLock(initialState: false)
            let returned = OSAllocatedUnfairLock(initialState: false)
            let release = DispatchSemaphore(value: 0)
            let read = module.conversationRead
            module.conversationRead = { root, recents in
                entered.withLock { $0 = true }
                _ = release.wait(timeout: .now() + 2)
                let snapshot = read(root, recents)
                returned.withLock { $0 = true }
                return snapshot
            }
            defer {
                release.signal()
                waitForConversation { returned.withLock { $0 } }
            }
            waitForConversation { entered.withLock { $0 } }
            var destination = conversationPage("Public external destination - Claude Code", address: "https://example.com/external")
            destination.nodes[2].attrs["AXValue"] = .string("Claude Code\n" + String(repeating: "Public external body. ", count: 100))
            AXReplay.load(destination)
            check(page.refreshIfNavigated(), "an external navigation event starts destination collection before the watcher returns")
            waitForBuffer(page.buffer)
            expect(said, [], "natural buffer publication cannot speak the title or first body line while the watcher owns speech")
            module.conversationRead = read
            release.signal()
            waitForConversation { said.contains("Public external destination") }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            expect(said, ["Public external destination"], "the released watcher supplies exactly the cleaned destination title")
        }
    }

    test("Claude navigation: a provider stuck beyond the ceiling grace relinquishes speech ownership") {
        withConversationTest { page, module, sent in
            let savedSink = Speech.sink
            var said: [String] = []
            Speech.sink = { said.append($0) }
            defer { Speech.sink = savedSink }
            let entered = OSAllocatedUnfairLock(initialState: false)
            let returned = OSAllocatedUnfairLock(initialState: false)
            let release = DispatchSemaphore(value: 0)
            let read = module.conversationRead
            module.conversationRead = { root, recents in
                let snapshot = read(root, recents)
                entered.withLock { $0 = true }
                _ = release.wait(timeout: .now() + 2)
                returned.withLock { $0 = true }
                return snapshot
            }
            module.conversationWaitLimit = 0.1
            defer {
                release.signal()
                waitForConversation { returned.withLock { $0 } }
            }
            let key = KeyboardGesture(identifier: "kb:command+2")!
            module.script(for: key)?.handler(key)
            var completed = 0
            check(page.deferInitialContent { completed += 1 }, "the command initially waits behind the switch")
            waitForConversation { entered.withLock { $0 } }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            check(!page.navigationTitleOwned, "the independent grace ends speech ownership even while the provider is stuck")
            check(!page.deferInitialContent({}), "the ceiling has released the command queue")
            expect(completed, 1, "the original queued command was released exactly once")
            expect(said, [], "neither the stale title nor a fabricated destination is spoken")
            AXReplay.load(conversationPage("Public too-late destination", address: "https://example.com/too-late"))
            module.conversationRead = read
            release.signal()
            waitForConversation { returned.withLock { $0 } }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            expect(said, [], "a result after the grace cannot revive switch speech")
            expect(completed, 1, "a late result cannot replay commands")
            expect(sent.value, ["kb:command+2"])
        }
    }

    test("Claude navigation: an expanded empty Recents section proves conversation 1 is missing") {
        withConversationTest(recents: []) { page, module, _ in
            let savedSink = Speech.sink
            var said: [String] = []
            Speech.sink = { said.append($0) }
            defer { Speech.sink = savedSink }
            page.passThrough = true
            let key = KeyboardGesture(identifier: "kb:command+1")!
            module.script(for: key)?.handler(key)
            waitForConversation { !said.isEmpty }
            expect(said, ["no conversation 1"])
            check(page.passThrough, "the empty section leaves focus mode unchanged")
            check(!page.deferInitialContent({}), "a proven absent first row does not wait")
        }
    }

    // 17 Nov 2026 (log review): the target is row N of Recents read fresh after the key, never the published copy's.
    test("Claude navigation: a message just sent reorders Recents; the fresh row is the destination") {
        withConversationTest(recents: ["Public first", "Old conversation", "Public third"]) { page, module, sent in
            let savedSink = Speech.sink
            var said: [String] = []
            Speech.sink = { said.append($0) }
            defer { Speech.sink = savedSink }
            let fresh = ["Old conversation", "Public first", "Public third"]
            AXReplay.load(conversationPage("Old conversation", address: "https://example.com/old", recents: fresh))
            let key = KeyboardGesture(identifier: "kb:command+2")!
            module.script(for: key)?.handler(key)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            expect(said, [], "the stale row 2 (the open conversation) is not said")
            AXReplay.load(conversationPage("Public first", address: "https://example.com/first", recents: fresh))
            waitForConversation { said.contains("Public first") }
            waitForBuffer(page.buffer)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            expect(said, ["Public first"], "only the fresh row's conversation is said")
            expect(sent.value, ["kb:command+2"])
        }
    }

    test("Claude navigation: two quick presses say only the second press's arrival") {
        let rows = ["Old conversation", "Public second", "Public third"]
        withConversationTest(recents: rows) { page, module, sent in
            let savedSink = Speech.sink
            var said: [String] = []
            Speech.sink = { said.append($0) }
            defer { Speech.sink = savedSink }
            let first = KeyboardGesture(identifier: "kb:command+2")!
            module.script(for: first)?.handler(first)
            let second = KeyboardGesture(identifier: "kb:command+3")!
            module.script(for: second)?.handler(second)
            AXReplay.load(conversationPage("Public second", address: "https://example.com/second", recents: rows))
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            expect(said, [], "the first press's arrival is not said")
            AXReplay.load(conversationPage("Public third", address: "https://example.com/third", recents: rows))
            waitForConversation { said.contains("Public third") }
            waitForBuffer(page.buffer)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            expect(said, ["Public third"], "only the last press's arrival is said, once")
            expect(sent.value, ["kb:command+2", "kb:command+3"])
        }
    }

    test("Claude navigation: a generic title arriving first is not said; the conversation's own title is") {
        let rows = ["Old conversation", "Public second"]
        withConversationTest(recents: rows) { page, module, _ in
            let savedSink = Speech.sink
            var said: [String] = []
            Speech.sink = { said.append($0) }
            defer { Speech.sink = savedSink }
            let key = KeyboardGesture(identifier: "kb:command+2")!
            module.script(for: key)?.handler(key)
            AXReplay.load(conversationPage("Claude", address: "https://example.com/second", recents: rows))
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            expect(said, [], "Claude's generic title is not the destination")
            AXReplay.load(conversationPage("Public second - Claude", address: "https://example.com/second", recents: rows))
            waitForConversation { said.contains("Public second") }
            waitForBuffer(page.buffer)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            expect(said, ["Public second"], "the title is said once, without \" - Claude\"")
        }
    }

    test("Claude navigation: a page still generic at the ceiling says the row's own name once") {
        let rows = ["Old conversation", "Public slow"]
        withConversationTest(recents: rows) { page, module, _ in
            let savedSink = Speech.sink
            var said: [String] = []
            Speech.sink = { said.append($0) }
            defer { Speech.sink = savedSink }
            module.conversationWaitLimit = 0.5
            let key = KeyboardGesture(identifier: "kb:command+2")!
            module.script(for: key)?.handler(key)
            AXReplay.load(conversationPage("Claude", address: "https://example.com/slow", recents: rows))
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            expect(said, [], "nothing is guessed before the ceiling")
            waitForConversation { !said.isEmpty }
            AXReplay.load(conversationPage("Public slow", address: "https://example.com/slow", recents: rows))
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            expect(said, ["Public slow"], "the row's name is said once at the ceiling, and the late title adds nothing")
            check(!page.navigationTitleOwned, "the ceiling ends the switch")
        }
    }

    test("Claude navigation: the decision rule, step by step") {
        var arrival = ClaudeConversationSwitch(number: 2, titleAtKey: "")
        arrival.recents(["Open", "Next"])
        expect(arrival.answer(title: "Open", busy: false, changed: false, loaded: false, settled: true), .wait, "the open conversation is being left")
        expect(arrival.answer(title: "Claude", busy: false, changed: true, loaded: false, settled: true), .wait, "a generic title is skipped")
        expect(arrival.answer(title: "Other", busy: false, changed: true, loaded: true, settled: true), .wait, "a title that is not row 2 is skipped")
        expect(arrival.answer(title: "Next", busy: false, changed: true, loaded: false, settled: true), .say("Next"))
        var here = ClaudeConversationSwitch(number: 1, titleAtKey: "")
        here.recents(["Open", "Next"])
        for _ in 0..<2 { expect(here.answer(title: "Open", busy: false, changed: false, loaded: false, settled: true), .wait) }
        expect(here.answer(title: "Open", busy: false, changed: false, loaded: false, settled: true), .alreadyHere("Open"))
        var missing = ClaudeConversationSwitch(number: 7, titleAtKey: "")
        missing.recents(["Open", "Next"])
        expect(missing.answer(title: "Open", busy: false, changed: false, loaded: false, settled: false), .noConversation(7))
        var slow = ClaudeConversationSwitch(number: 2, titleAtKey: "Open")
        slow.recents(["Open", "Next"])
        expect(slow.ceiling(title: "Claude", changed: true), .say("Next"), "the row's own name at the ceiling")
        check(ClaudeConversationSwitch.isGeneric("Claude Code"), "Claude Code is generic")
    }

    // 17 Nov 2026 (log): returning to Claude said "Claude, window" and then "Claude, grouping".
    test("Claude: the group named as the window is not said when the focus enters it") {
        AXReplay.load(AXFixture(app: "Claude", bundle: "test.claude-group", recorded: "", root: 0, application: 1, focus: 0, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXGroup"), "AXTitle": .string("Claude"), "AXParent": .element(1), "AXChildren": .elements([2])]),
            .init(id: 1, attrs: ["AXRole": .string("AXApplication"), "AXChildren": .elements([0])]),
            .init(id: 2, attrs: ["AXRole": .string("AXGroup"), "AXTitle": .string("Side chat"), "AXParent": .element(0)]),
        ]))
        defer { AXReplay.unload() }
        let module = ClaudeAppModule(pid: AXReplay.element(0).pid, bundleIdentifier: "com.anthropic.claudefordesktop", appName: "Claude")
        let wrapper = Event(.focusEntered, ObjectFactory.make(AXReplay.element(0)))
        var passedOn = false
        module.handleEvent(wrapper) { passedOn = true }
        check(!passedOn, "\"Claude, grouping\" is not said after the window")
        let sideChat = Event(.focusEntered, ObjectFactory.make(AXReplay.element(2)))
        passedOn = false
        module.handleEvent(sideChat) { passedOn = true }
        check(passedOn, "another named group entered is still said")
        check(!module.isWindowNamedGroup(Event(.gainFocus, ObjectFactory.make(AXReplay.element(0)))), "only entering, not focus on the group itself")
    }

    test("Claude navigation: other modules retain native session keys") {
        let ordinary = AppModule(pid: 0, bundleIdentifier: "test.other", appName: "Other")
        for key in ["kb:command+1", "kb:command+4", "kb:command+n"] {
            check(ordinary.script(for: KeyboardGesture(identifier: key)!) == nil, "ordinary apps do not opt into the wait")
        }
    }
}
