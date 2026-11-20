// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import TurnOverAX
import AXFixtures

func claudePopupTests() {
    func withPopup(activeDescendant: Int? = nil, _ body: (ClaudeAppModule, BrowseModeDocument, Locked<[String]>, Locked<[String]>) -> Void) {
        let focus = API.focusObject, ancestors = API.focusAncestors, pageBefore = API.focusTreeInterceptor
        let sink = Speech.sink, poster = KeyboardGesture.poster
        var fixture = AXFixture(app: "Public command popup", bundle: "test.claude-popup", recorded: "synthetic", root: 0, application: 1, focus: 2, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.com/commands"), "AXParent": .element(1)]),
            .init(id: 1, attrs: ["AXRole": .string("AXApplication")]),
            .init(id: 2, attrs: ["AXRole": .string("AXTextArea"), "AXTitle": .string("Prompt"), "AXValue": .string("/"), "AXParent": .element(0)]),
            .init(id: 3, attrs: ["AXRole": .string("AXGroup"), "AXParent": .element(0), "AXChildren": .elements([4, 5])]),
            .init(id: 4, attrs: ["AXRole": .string("AXMenuItem"), "AXTitle": .string("compact"), "AXSelected": .bool(true), "AXParent": .element(3)]),
            .init(id: 5, attrs: ["AXRole": .string("AXMenuItem"), "AXTitle": .string("help"), "AXSelected": .bool(false), "AXParent": .element(3)]),
            .init(id: 6, attrs: ["AXRole": .string("AXMenuItem"), "AXTitle": .string("Low"), "AXParent": .element(3)])
        ])
        if let activeDescendant, let index = fixture.nodes.firstIndex(where: { $0.id == 2 }) {
            fixture.nodes[index].attrs["AXActiveDescendant"] = .element(activeDescendant)
        }
        AXReplay.load(fixture)
        let page = BrowseModeDocument(webArea: AXReplay.element(0))
        page.passThrough = true
        API.setFocusObject(ObjectFactory.make(AXReplay.element(2)), ancestors: [], interceptor: page)
        let module = ClaudeAppModule(pid: AXReplay.element(0).pid, bundleIdentifier: "com.anthropic.claudefordesktop", appName: "Claude")
        let sent = Locked<[String]>([])
        let said = Locked<[String]>([])
        Speech.sink = { said.value.append($0) }
        KeyboardGesture.poster = { sent.value.append($0.identifier) }
        defer {
            module.handleEvent(Event(.appModuleLoseFocus, ObjectFactory.make(AXReplay.element(2)))) {}
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            Speech.sink = sink; KeyboardGesture.poster = poster
            API.setFocusObject(focus, ancestors: ancestors, interceptor: pageBefore)
            if let focus { ObjectNavigator.shared.focusMoved(to: focus.element, pid: focus.pid) }
            // Moving the focus back schedules a spoken hint 1.2 s ahead; it must not land in a later test on a slow machine.
            Hints.cancel(); RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            AXReplay.unload()
        }
        body(module, page, said, sent)
    }
    func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.18)) }
    /// Wait for the popup reader (a delayed read on a worker, then main) to say what is wanted, however slow the machine is; the
    /// short settle after it lets a wrong extra word arrive, so an extra word still fails the check that follows.
    func settle(until condition: () -> Bool) {
        let limit = Date().addingTimeInterval(10)
        while !condition(), Date() < limit { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
        settle()
    }

    test("Claude popup: production lookup gives suggestion arrows priority over editable caret commands") {
        withPopup { _, _, _, _ in
            let pid = AXReplay.element(2).pid, moduleID = "pid.\(AXReplay.element(2).pid)"
            let previousType = AppModuleHandler.shared.moduleType(for: moduleID)
            let savedConfig = config
            let pluginTypes = GlobalPluginHandler.shared.plugins.map { type(of: $0) }
            AppModuleHandler.shared.register(ClaudeAppModule.self, for: moduleID)
            config.general.keyboardStyle = "mac"
            GlobalPluginHandler.shared.terminateAll()
            GlobalPluginHandler.shared.register(VoiceOverKeysPlugin.self)
            let module = AppModuleHandler.shared.appModule(for: pid)
            defer {
                module.handleEvent(Event(.appModuleLoseFocus, ObjectFactory.make(AXReplay.element(2)))) {}
                config = savedConfig
                GlobalPluginHandler.shared.terminateAll()
                for pluginType in pluginTypes { GlobalPluginHandler.shared.register(pluginType) }
                if let previousType { AppModuleHandler.shared.register(previousType, for: moduleID) }
                else { AppModuleHandler.shared.unregister(bundleIdentifier: moduleID) }
            }
            module.handleEvent(Event(.menuStart, ObjectFactory.make(AXReplay.element(3)))) {}
            for arrow in ["upArrow", "downArrow"] {
                let key = KeyboardGesture(identifier: "kb:" + arrow)!
                guard let command = ScriptHandler.findScript(for: key) else { Harness.fail("suggestion arrow resolves"); continue }
                check(command.owner === module, "the Claude module wins ahead of the focused editable object")
                expect(command.name, "claude_popup_" + arrow, "native arrow reaches suggestion feedback")
            }
            module.handleEvent(Event(.menuEnd, ObjectFactory.make(AXReplay.element(3)))) {}
            for arrow in ["upArrow", "downArrow"] {
                let command = ScriptHandler.findScript(for: KeyboardGesture(identifier: "kb:" + arrow)!)
                check(command?.owner !== module, "closing restores normal production caret routing")
            }
        }
    }

    test("Claude popup: missing close news cannot take arrows after slash removal or browse intent") {
        withPopup { module, page, said, _ in
            let root = ObjectFactory.make(AXReplay.element(3))
            let down = KeyboardGesture(identifier: "kb:downArrow")!
            module.handleEvent(Event(.menuStart, root)) {}
            settle(until: { module.script(for: down) != nil })
            check(module.script(for: down) != nil, "an open slash popup owns focus-mode arrows")
            page.passThrough = false
            check(module.script(for: down) == nil, "browse arrows belong to the reading position")
            page.passThrough = true
            AXUIElementSetAttributeValue(AXReplay.element(2), kAXValueAttribute as CFString, "public text" as CFString)
            module.handleEvent(Event(.valueChange, ObjectFactory.make(AXReplay.element(2)))) {}
            check(module.script(for: down) == nil, "ordinary Prompt text retires the stale group without menuEnd")
            AXUIElementSetAttributeValue(AXReplay.element(2), kAXValueAttribute as CFString, "/" as CFString)
            check(module.script(for: down) == nil, "typing another slash requires fresh opening news")
            settle(until: { !said.value.isEmpty })
            expect(said.value, ["compact"], "retired refreshes cannot speak late")
        }
    }

    test("Claude popup: the availability check changes no state; the arrow script retires a stale popup and still sends the key") {
        withPopup { module, _, said, sent in
            let down = KeyboardGesture(identifier: "kb:downArrow")!
            module.handleEvent(Event(.menuStart, ObjectFactory.make(AXReplay.element(3)))) {}
            settle(until: { module.script(for: down) != nil })
            AXUIElementSetAttributeValue(AXReplay.element(2), kAXValueAttribute as CFString, "plain" as CFString)
            for _ in 0..<3 { check(module.script(for: down) != nil, "asking never retires the popup") }
            AXUIElementSetAttributeValue(AXReplay.element(2), kAXValueAttribute as CFString, "/" as CFString)
            let command = module.script(for: down)
            check(command != nil, "the popup was untouched by the checks")
            AXUIElementSetAttributeValue(AXReplay.element(2), kAXValueAttribute as CFString, "plain" as CFString)
            said.value.removeAll()
            command?.handler(down)
            settle(until: { !sent.value.isEmpty })
            expect(sent.value, ["kb:downArrow"], "the arrow still reaches the Prompt once")
            expect(said.value, [], "a stale popup says nothing")
            check(module.script(for: down) == nil, "running the script found the popup stale and retired it")
        }
    }

    test("Claude popup: focus leaving the field and a hidden root retire missing close news") {
        withPopup { module, page, _, _ in
            let down = KeyboardGesture(identifier: "kb:downArrow")!
            module.handleEvent(Event(.menuStart, ObjectFactory.make(AXReplay.element(3)))) {}
            let web = ObjectFactory.make(AXReplay.element(0))
            API.setFocusObject(web, ancestors: [], interceptor: page)
            module.handleEvent(Event(.gainFocus, web)) {}
            API.setFocusObject(ObjectFactory.make(AXReplay.element(2)), ancestors: [], interceptor: page)
            check(module.script(for: down) == nil, "returning to the Prompt cannot resurrect the old group")
            AXUIElementSetAttributeValue(AXReplay.element(3), "AXHidden" as CFString, kCFBooleanTrue)
            module.handleEvent(Event(.menuStart, ObjectFactory.make(AXReplay.element(3)))) {}
            settle(until: { module.script(for: down) == nil })
            check(module.script(for: down) == nil, "a hidden root closes even without focus or menuEnd news")
        }
    }

    test("Claude popup: narrowing without selection news reads the new first match once") {
        withPopup { module, _, said, _ in
            AXUIElementSetAttributeValue(AXReplay.element(4), kAXSelectedAttribute as CFString, kCFBooleanFalse)
            module.handleEvent(Event(.menuStart, ObjectFactory.make(AXReplay.element(3)))) {}
            settle(until: { !said.value.isEmpty })
            AXUIElementSetAttributeValue(AXReplay.element(3), kAXChildrenAttribute as CFString, [AXReplay.element(5)] as CFArray)
            module.handleEvent(Event(.valueChange, ObjectFactory.make(AXReplay.element(2)))) {}
            settle(until: { said.value.count >= 2 })
            module.handleEvent(Event(.caret, ObjectFactory.make(AXReplay.element(2)))) {}
            settle()
            expect(said.value, ["compact", "help"], "a changed first match is announced without repeating it")
        }
    }

    test("Claude popup: opening says the first option and native arrows say the highlighted option") {
        withPopup { module, page, said, sent in
            check(module.handlesGroupMenus, "Claude opts into group menu notifications")
            module.handleEvent(Event(.menuStart, ObjectFactory.make(AXReplay.element(3)))) {}
            settle(until: { !said.value.isEmpty })
            expect(said.value, ["compact"], "the opening item is spoken")
            for (key, selected, label) in [("downArrow", 5, "help"), ("upArrow", 4, "compact")] {
                AXUIElementSetAttributeValue(AXReplay.element(4), kAXSelectedAttribute as CFString, selected == 4 ? kCFBooleanTrue : kCFBooleanFalse)
                AXUIElementSetAttributeValue(AXReplay.element(5), kAXSelectedAttribute as CFString, selected == 5 ? kCFBooleanTrue : kCFBooleanFalse)
                let gesture = KeyboardGesture(identifier: "kb:" + key)!
                let command = module.script(for: gesture)
                check(command != nil, "the popup owns the native arrow")
                command?.handler(gesture)
                settle(until: { said.value.last == label })
                expect(said.value.last, label, "the highlighted option is spoken after the arrow")
            }
            expect(sent.value, ["kb:downArrow", "kb:upArrow"], "each arrow reaches Claude once")
            check(page.passThrough, "opening and navigating suggestions preserve typing mode")
            module.handleEvent(Event(.menuEnd, ObjectFactory.make(AXReplay.element(3)))) {}
            check(module.script(for: KeyboardGesture(identifier: "kb:downArrow")!) == nil, "closing restores ordinary caret arrows")
        }
    }
    test("Claude popup: opening without a selection marker still says the first option") {
        withPopup { module, _, said, _ in
            AXUIElementSetAttributeValue(AXReplay.element(4), kAXSelectedAttribute as CFString, kCFBooleanFalse)
            module.handleEvent(Event(.menuStart, ObjectFactory.make(AXReplay.element(3)))) {}
            settle(until: { !said.value.isEmpty })
            expect(said.value, ["compact"], "the first option is available before selection metadata arrives")
        }
    }

    test("Claude popup: native menu-item focus speaks once without a late suggestion repeat") {
        withPopup { module, page, said, _ in
            module.handleEvent(Event(.menuStart, ObjectFactory.make(AXReplay.element(3)))) {}
            let item = ObjectFactory.make(AXReplay.element(6))
            API.setFocusObject(item, ancestors: [], interceptor: page)
            module.handleEvent(Event(.gainFocus, item)) { Speech.speakMessage("Low") }
            settle(until: { !said.value.isEmpty })
            expect(said.value, ["Low"], "native focus owns menu-item speech")
        }
    }

    test("Claude popup: Prompt active descendant identifies the highlighted suggestion") {
        withPopup(activeDescendant: 5) { module, _, said, _ in
            AXUIElementSetAttributeValue(AXReplay.element(4), kAXSelectedAttribute as CFString, kCFBooleanFalse)
            module.handleEvent(Event(.menuStart, ObjectFactory.make(AXReplay.element(3)))) {}
            settle(until: { !said.value.isEmpty })
            expect(said.value, ["help"], "the field's active descendant wins over the first option")
        }
    }

    test("Claude popup: VO Space confirms the Effort item through the app action") {
        withPopup { _, page, said, sent in
            let item = AXReplay.element(6)
            let module = ClaudeAppModule(pid: item.pid, bundleIdentifier: "com.anthropic.claudefordesktop", appName: "Claude")
            module.handleEvent(Event(.menuStart, ObjectFactory.make(AXReplay.element(3)))) {}
            API.setFocusObject(ObjectFactory.make(item), ancestors: [], interceptor: page)
            ObjectNavigator.shared.focusMoved(to: item, pid: item.pid)
            defer {
                module.handleEvent(Event(.appModuleLoseFocus, ObjectFactory.make(item))) {}
                ObjectNavigator.shared.focusMoved(to: AXReplay.element(2), pid: AXReplay.element(2).pid)
            }
            let key = KeyboardGesture(identifier: "kb:turnover+space")!
            let command = module.script(named: "vo_defaultAction")
            check(command?.isAvailable?() == true, "the app action accepts the focused Effort choice")
            command?.handler(key)
            module.handleEvent(Event(.menuEnd, ObjectFactory.make(AXReplay.element(3)))) {}
            module.handleEvent(Event(.gainFocus, ObjectFactory.make(AXReplay.element(2)))) {}
            expect(sent.value, ["kb:enter"], "VO Space posts one Return")
            expect(said.value, ["Low"], "the chosen effort is confirmed on return to Prompt")
        }
    }

    test("Claude popup: Effort selection is spoken after the Prompt takes focus") {
        withPopup { module, _, said, sent in
            module.handleEvent(Event(.menuStart, ObjectFactory.make(AXReplay.element(3)))) {}
            settle(until: { !said.value.isEmpty })
            said.value.removeAll()
            API.setFocusObject(ObjectFactory.make(AXReplay.element(6)), ancestors: [], interceptor: API.focusTreeInterceptor)
            let enter = KeyboardGesture(identifier: "kb:enter")!
            module.script(for: enter)?.handler(enter)
            module.handleEvent(Event(.menuEnd, ObjectFactory.make(AXReplay.element(3)))) {}
            module.handleEvent(Event(.gainFocus, ObjectFactory.make(AXReplay.element(2)))) { Speech.speakMessage("Prompt, edit") }
            expect(sent.value, ["kb:enter"], "selection uses one native Return")
            expect(said.value, ["Prompt, edit", "Low"], "focus speech cannot replace the chosen effort")
        }
    }
    test("Claude popup: closing or leaving before the worker returns discards its speech") {
        withPopup { module, _, said, _ in
            module.handleEvent(Event(.menuStart, ObjectFactory.make(AXReplay.element(3)))) {}
            module.handleEvent(Event(.menuEnd, ObjectFactory.make(AXReplay.element(3)))) {}
            settle()
            check(said.value.isEmpty, "closed popup cannot speak late")
            module.handleEvent(Event(.menuStart, ObjectFactory.make(AXReplay.element(3)))) {}
            module.handleEvent(Event(.appModuleLoseFocus, ObjectFactory.make(AXReplay.element(2)))) {}
            settle()
            check(said.value.isEmpty, "background popup cannot speak late")
        }
    }

    // 20 Nov 2026: Space on a checkable item in a Claude menu that stays open ("Goal" in "Show") toggled it and said nothing.
    test("Claude menu: Space on a checkable item in a menu that stays open says its new state once; a closed menu says nothing extra") {
        func fixture(marked: Bool) -> AXFixture {
            var item: [String: AXFixture.Value] = ["AXRole": .string("AXMenuItem"), "AXTitle": .string("Goal"), "AXParent": .element(3)]
            if marked { item["AXMenuItemMarkChar"] = .string("\u{2713}") }
            return AXFixture(app: "Public show menu", bundle: "test.claude-show-menu", recorded: "synthetic", root: 0, application: 1, focus: 4, nodes: [
                .init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.com/show"), "AXParent": .element(1)]),
                .init(id: 1, attrs: ["AXRole": .string("AXApplication")]),
                .init(id: 3, attrs: ["AXRole": .string("AXGroup"), "AXParent": .element(0), "AXChildren": .elements([4])]),
                .init(id: 4, attrs: item)
            ])
        }
        for closes in [false, true] {
            let focus = API.focusObject, ancestors = API.focusAncestors, pageBefore = API.focusTreeInterceptor
            let sink = Speech.sink, poster = KeyboardGesture.poster
            nonisolated(unsafe) let markedFixture = fixture(marked: true)
            AXReplay.load(fixture(marked: false))
            let item = AXReplay.element(4)
            let said = Locked<[String]>([])
            Speech.sink = { said.value.append($0) }
            // The key reaches the app: the item is toggled there (marked now).
            KeyboardGesture.poster = { _ in AXReplay.load(markedFixture) }
            let module = ClaudeAppModule(pid: item.pid, bundleIdentifier: "com.anthropic.claudefordesktop", appName: "Claude")
            module.handleEvent(Event(.menuStart, ObjectFactory.make(AXReplay.element(3)))) {}
            API.setFocusObject(ObjectFactory.make(item), ancestors: [], interceptor: nil)
            let space = KeyboardGesture(identifier: "kb:space")!
            let command = module.script(named: "claude_chooseMenuItem")
            check(command?.isAvailable?() == true, "the script takes the item in the open menu")
            said.value.removeAll()
            command?.handler(space)
            if closes { module.handleEvent(Event(.menuEnd, ObjectFactory.make(AXReplay.element(3)))) {} }
            let limit = Date().addingTimeInterval(closes ? 0.8 : 5)
            while !(closes ? false : said.value.count >= 1), Date() < limit { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))   // a second, wrong word would arrive here
            expect(said.value, closes ? [] : ["Goal, checked"], closes ? "a menu that closed: nothing extra" : "the new state, once")
            module.handleEvent(Event(.appModuleLoseFocus, ObjectFactory.make(item))) {}
            Speech.sink = sink; KeyboardGesture.poster = poster
            API.setFocusObject(focus, ancestors: ancestors, interceptor: pageBefore)
            Hints.cancel(); AXReplay.unload()
        }
    }
}
