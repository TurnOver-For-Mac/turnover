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

func claudeNavigationTests() {
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
            expect(sent.value, [shortcut], "the app's shortcut is delivered once")
            check(buffer.lines.isEmpty, "the previous conversation is retired before another key")

            let tab = KeyboardGesture(identifier: "kb:tab")!
            page.script(for: tab)?.handler(tab)
            check(said.isEmpty, "Tab cannot announce an offset in the old page")
            expect(sent.value, [shortcut], "Tab waits instead of reaching the old page")
            // A newer browse key supersedes that Tab, just as initial-content deferral does elsewhere.
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
            expect(said.filter { $0 == "New conversation" }.count, 1, "publication does not repeat the title")
            check(!said.contains { $0.contains("Old conversation") }, "no old text or control is read")
            expect(sent.value, [shortcut], "the superseded Tab is not replayed after the newer key")
            check(page.position > 0, "the latest movement runs on the new copy")
        }
    }

    test("Claude navigation: completed content waits for its late title without repeating the old title") {
        AXReplay.load(conversationPage("Old conversation", address: "https://example.com/old"))
        let root = AXReplay.element(0)
        let buffer = WebBuffer(webArea: root)
        let page = BrowseModeDocument(webArea: root, buffer: buffer)
        BrowseModeHandler.shared.adopt(page)
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
        expect(sent.value, ["kb:command+2"], "the superseded Tab never reaches the app")
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

    test("Claude navigation: focus departure retires the held key and returning can navigate") {
        AXReplay.load(conversationPage("Old conversation", address: "https://example.com/old"))
        let root = AXReplay.element(0)
        let buffer = WebBuffer(webArea: root)
        let page = BrowseModeDocument(webArea: root, buffer: buffer)
        BrowseModeHandler.shared.adopt(page)
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
        let shortcut = KeyboardGesture(identifier: "kb:command+3")!
        module.script(for: shortcut)?.handler(shortcut)
        let tab = KeyboardGesture(identifier: "kb:tab")!
        page.script(for: tab)?.handler(tab)
        API.setFocusObject(nil, ancestors: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        expect(sent.value, ["kb:command+3"], "departure discards the waiting Tab")
        check(said.isEmpty, "the watcher says nothing after focus leaves")

        AXReplay.load(conversationPage("Returned conversation", address: "https://example.com/returned"))
        API.setFocusObject(ObjectFactory.make(root), ancestors: [], interceptor: page)
        page.refreshIfNavigated()
        waitForBuffer(buffer)
        page.position = 0
        let right = KeyboardGesture(identifier: "kb:rightArrow")!
        page.script(for: right)?.handler(right)
        check(page.position > 0, "returning to the cached page does not leave navigation permanently deferred")
        expect(sent.value, ["kb:command+3"], "the departed Tab is not replayed on return")
    }

    test("Claude navigation: other modules retain native session keys") {
        let ordinary = AppModule(pid: 0, bundleIdentifier: "test.other", appName: "Other")
        for key in ["kb:command+1", "kb:command+4", "kb:command+n"] {
            check(ordinary.script(for: KeyboardGesture(identifier: key)!) == nil, "ordinary apps do not opt into the wait")
        }
    }
}
