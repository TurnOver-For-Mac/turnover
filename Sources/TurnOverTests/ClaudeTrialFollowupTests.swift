// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import TurnOverAX
import AXFixtures

func claudeTrialFollowupTests() {
    test("Claude trial: recent shortcuts five through nine enter the production navigation wait") {
        let savedFocus = API.focusObject, savedAncestors = API.focusAncestors, savedPage = API.focusTreeInterceptor
        let savedPid = AXHandler.shared.activePid, savedPoster = KeyboardGesture.poster
        AXReplay.load(.init(app: "Public trial", bundle: "test.claude-trial", recorded: "synthetic", root: 0, application: 1, focus: 0, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.com/trial"), "AXParent": .element(1)]),
            .init(id: 1, attrs: ["AXRole": .string("AXApplication")])
        ]))
        let root = AXReplay.element(0), page = BrowseModeDocument(webArea: AXReplay.element(0))
        page.buffer.buildForInspection()
        waitForBuffer(page.buffer)
        let module = ClaudeAppModule(pid: root.pid, bundleIdentifier: "com.anthropic.claudefordesktop", appName: "Claude")
        let sent = Locked<[String]>([])
        KeyboardGesture.poster = { sent.value.append($0.identifier) }
        AXHandler.shared.activePid = root.pid
        API.setFocusObject(ObjectFactory.make(root), ancestors: [], interceptor: page)
        defer {
            API.setFocusObject(savedFocus, ancestors: savedAncestors, interceptor: savedPage)
            AXHandler.shared.activePid = -1
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
            page.finishNavigationWait(title: nil, announce: false)
            waitForBuffer(page.buffer)
            AXHandler.shared.activePid = savedPid
            KeyboardGesture.poster = savedPoster
            AXReplay.unload()
        }
        for number in 5...9 {
            let key = KeyboardGesture(identifier: "kb:command+\(number)")!
            guard let script = module.script(for: key) else { Harness.fail("conversation shortcut \(number) is registered"); continue }
            script.handler(key)
            var ran = false
            check(page.deferInitialContent { ran = true }, "a following command is queued")
            check(!ran, "the old conversation cannot receive the following command")
        }
        expect(sent.value, (5...9).map { "kb:command+\($0)" }, "each native switch is posted once")
    }

    test("Claude trial: real F routing leaves letters and Space native before and after Backspace") {
        let savedFocus = API.focusObject, savedAncestors = API.focusAncestors, savedPage = API.focusTreeInterceptor
        let savedPid = AXHandler.shared.activePid, savedPoster = KeyboardGesture.poster
        let savedPluginTypes = GlobalPluginHandler.shared.plugins.map { type(of: $0) }
        let trial = ModeWordsTrial()
        AXReplay.load(.init(app: "Public typing trial", bundle: "test.claude-typing", recorded: "synthetic", root: 0, application: 1, focus: 3, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.com/typing"), "AXParent": .element(1), "AXChildren": .elements([2, 3])]),
            .init(id: 1, attrs: ["AXRole": .string("AXApplication"), "AXFocusedUIElement": .element(3)]),
            .init(id: 2, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("Copy"), "AXParent": .element(0)]),
            .init(id: 3, attrs: ["AXRole": .string("AXTextArea"), "AXTitle": .string("Prompt"), "AXValue": .string(""), "AXSelectedTextRange": .range(0, 0), "AXParent": .element(0)])
        ]))
        let root = AXReplay.element(0), field = AXReplay.element(3)
        let page = BrowseModeDocument(webArea: root)
        page.buffer.buildForInspection()
        waitForBuffer(page.buffer)
        config.general.keyboardStyle = "mac"
        config.virtualBuffers.autoPassThroughOnCaretMove = true
        GlobalPluginHandler.shared.terminateAll()
        GlobalPluginHandler.shared.register(VoiceOverKeysPlugin.self)
        AXHandler.shared.activePid = root.pid
        // Claude can already have native focus in Prompt while the reader is still browsing the reply.
        API.setFocusObject(ObjectFactory.make(field), ancestors: [], interceptor: page)
        page.position = page.buffer.offset(of: AXReplay.element(2)) ?? 0
        page.passThrough = false
        let sent = Locked<[String]>([])
        KeyboardGesture.poster = { sent.value.append($0.identifier) }
        defer {
            API.setFocusObject(savedFocus, ancestors: savedAncestors, interceptor: savedPage)
            AXHandler.shared.activePid = savedPid
            KeyboardGesture.poster = savedPoster
            GlobalPluginHandler.shared.terminateAll()
            for pluginType in savedPluginTypes { GlobalPluginHandler.shared.register(pluginType) }
            AXReplay.unload()
            trial.restore()
        }
        let find = KeyboardGesture(identifier: "kb:f")!
        expect(ScriptHandler.findScript(for: find)?.name, "vo_nextTextField", "bare F resolves through production gesture lookup")
        check(InputManager.handleKeyDown(find), "F is handled as field navigation")
        trial.drain()
        check(page.passThrough, "F enters the field before the next key")
        check(trial.words.contains { $0.contains("Prompt") }, "F speaks the field")
        for stage in ["after F", "after Backspace"] {
            if stage == "after Backspace" {
                _ = InputManager.handleKeyDown(KeyboardGesture(identifier: "kb:backspace")!)
                trial.drain()
                check(page.passThrough, "Backspace preserves focus mode in the empty Prompt")
            }
            for identifier in ["kb:i", "kb:t", "kb:f", "kb:space"] {
                check(ScriptHandler.findScript(for: KeyboardGesture(identifier: identifier)!) == nil,
                      "\(identifier) has no browse trap, quick navigation or activation script \(stage)")
                check(!InputManager.handleKeyDown(KeyboardGesture(identifier: identifier)!),
                      "\(identifier) goes directly to the application \(stage)")
            }
        }
        check(!sent.value.contains("kb:space"), "Space is never reposted as control activation")
        check(!AXReplay.actions.contains { $0.action == "AXPress" }, "typing does not activate a page control")
    }

    test("Claude trial: dialog live regions and descendants bypass held progress immediately") {
        let savedFocus = API.focusObject, savedAncestors = API.focusAncestors, savedPage = API.focusTreeInterceptor
        AXReplay.load(.init(app: "Public dialog trial", bundle: "test.claude-trial", recorded: "synthetic", root: 0, application: 1, focus: 2, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.com/dialog"), "AXParent": .element(1)]),
            .init(id: 1, attrs: ["AXRole": .string("AXApplication")]),
            .init(id: 2, attrs: ["AXRole": .string("AXGroup"), "AXSubrole": .string("AXApplicationDialog"), "AXTitle": .string("Public confirmation"), "AXARIALive": .string("polite"), "AXParent": .element(0), "AXChildren": .elements([3])]),
            .init(id: 3, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("Public dialog message"), "AXARIALive": .string("polite"), "AXParent": .element(2)])
        ]))
        let root = AXReplay.element(0), page = BrowseModeDocument(webArea: AXReplay.element(0))
        page.buffer.buildForInspection()
        waitForBuffer(page.buffer)
        API.setFocusObject(ObjectFactory.make(AXReplay.element(2)), ancestors: [], interceptor: page)
        let module = ClaudeAppModule(pid: root.pid, bundleIdentifier: "com.anthropic.claudefordesktop", appName: "Claude")
        module.progressSpeechBusy = { true }
        var scheduled = 0, forwarded = 0
        module.progressScheduler = { _, _ in scheduled += 1 }
        defer {
            API.setFocusObject(savedFocus, ancestors: savedAncestors, interceptor: savedPage)
            AXReplay.unload()
        }
        for id in [2, 3] {
            module.handleEvent(Event(.liveRegionChange, ObjectFactory.make(AXReplay.element(id)))) { forwarded += 1 }
        }
        expect(forwarded, 2, "both events reach the normal live-region reader in the event call")
        expect(scheduled, 0, "no delayed dialog replay can be scheduled")
        check(module.progressHeldSince(session: "https://example.com/dialog") == nil, "dialog text is never stored as progress")
    }

    test("Claude trial: ScriptHandler activates focused Delete through the global VoiceOver plugin") {
        let savedFocus = API.focusObject, savedAncestors = API.focusAncestors, savedPage = API.focusTreeInterceptor
        let savedPoster = KeyboardGesture.poster, savedConfig = config
        let savedPluginTypes = GlobalPluginHandler.shared.plugins.map { type(of: $0) }
        AXReplay.load(.init(app: "Public menu trial", bundle: "test.claude-trial", recorded: "synthetic", root: 0, application: 1, focus: 2, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXWindow"), "AXParent": .element(1), "AXChildren": .elements([2, 3])]),
            .init(id: 1, attrs: ["AXRole": .string("AXApplication")]),
            .init(id: 2, attrs: ["AXRole": .string("AXMenuItem"), "AXTitle": .string("Delete"), "AXParent": .element(0)], actions: []),
            .init(id: 3, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("Public button"), "AXParent": .element(0)], actions: ["AXPress"])
        ]))
        let item = AXReplay.element(2)
        let moduleID = "pid.\(item.pid)"
        let previousType = AppModuleHandler.shared.moduleType(for: moduleID)
        AppModuleHandler.shared.register(ClaudeAppModule.self, for: moduleID)
        config.general.keyboardStyle = "mac"
        GlobalPluginHandler.shared.terminateAll()
        GlobalPluginHandler.shared.register(VoiceOverKeysPlugin.self)
        API.setFocusObject(ObjectFactory.make(item), ancestors: [], interceptor: nil)
        ObjectNavigator.shared.focusMoved(to: item, pid: item.pid)
        let module = AppModuleHandler.shared.appModule(for: item.pid)
        let sent = Locked<[String]>([])
        KeyboardGesture.poster = { sent.value.append($0.identifier) }
        defer {
            KeyboardGesture.poster = savedPoster
            config = savedConfig
            GlobalPluginHandler.shared.terminateAll()
            for pluginType in savedPluginTypes { GlobalPluginHandler.shared.register(pluginType) }
            if let previousType { AppModuleHandler.shared.register(previousType, for: moduleID) }
            else { AppModuleHandler.shared.unregister(bundleIdentifier: moduleID) }
            API.setFocusObject(savedFocus, ancestors: savedAncestors, interceptor: savedPage)
            if let focus = savedFocus { ObjectNavigator.shared.focusMoved(to: focus.element, pid: focus.element.pid) }
            AXReplay.unload()
        }
        let key = KeyboardGesture(identifier: "kb:turnover+space")!
        guard let command = ScriptHandler.findScript(for: key) else { Harness.fail("VO-Space resolves through ScriptHandler"); return }
        check(command.owner is VoiceOverKeysPlugin, "the production global plugin wins gesture lookup")
        ScriptHandler.executeScript(command, gesture: key)
        expect(sent.value, ["kb:enter"], "the winning global command sends exactly one native Return to Delete")
        expect(BrowseModeDocument.keyboardPress(role: "AXMenuItem", moduleRoles: module.rolesPressedByKeyboard), .returnKey,
               "browse activation uses the same existing confirmed-focus Return mechanism")

        let button = AXReplay.element(3)
        API.setFocusObject(ObjectFactory.make(button), ancestors: [], interceptor: nil)
        ObjectNavigator.shared.focusMoved(to: button, pid: button.pid)
        // A command resolved before the focus moved must recheck the app exception at execution.
        ScriptHandler.executeScript(command, gesture: key)
        expect(sent.value, ["kb:enter"], "a queued activation cannot send Return after focus moves")
        expect(AXReplay.actions.filter { $0.action == "AXPress" }.map(\.id), [3],
               "an unavailable app action falls back to the ordinary button press")
    }

    test("Claude trial: browse VO-Space routes a session menu item through confirmed native Return") {
        let savedFocus = API.focusObject, savedAncestors = API.focusAncestors, savedPage = API.focusTreeInterceptor
        let savedPoster = KeyboardGesture.poster
        AXReplay.load(.init(app: "Public browse menu", bundle: "test.claude-trial", recorded: "synthetic", root: 0, application: 1, focus: 2, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.com/menu"), "AXParent": .element(1), "AXChildren": .elements([2])]),
            .init(id: 1, attrs: ["AXRole": .string("AXApplication"), "AXFocusedUIElement": .element(2)]),
            .init(id: 2, attrs: ["AXRole": .string("AXMenuItem"), "AXTitle": .string("Delete"), "AXParent": .element(0), "AXFocused": .bool(true)], actions: ["AXPress"])
        ]))
        let item = AXReplay.element(2), root = AXReplay.element(0)
        let moduleID = "pid.\(item.pid)"
        let previousType = AppModuleHandler.shared.moduleType(for: moduleID)
        AppModuleHandler.shared.register(ClaudeAppModule.self, for: moduleID)
        let page = BrowseModeDocument(webArea: root)
        page.buffer.buildForInspection()
        waitForBuffer(page.buffer)
        page.passThrough = false
        API.setFocusObject(ObjectFactory.make(item), ancestors: [], interceptor: page)
        let sent = Locked<[String]>([])
        KeyboardGesture.poster = { sent.value.append($0.identifier) }
        defer {
            API.setFocusObject(savedFocus, ancestors: savedAncestors, interceptor: savedPage)
            waitForBuffer(page.buffer)
            if let previousType { AppModuleHandler.shared.register(previousType, for: moduleID) }
            else { AppModuleHandler.shared.unregister(bundleIdentifier: moduleID) }
            KeyboardGesture.poster = savedPoster
            AXReplay.unload()
        }
        let plugin = VoiceOverKeysPlugin(), key = KeyboardGesture(identifier: "kb:turnover+space")!
        plugin.script(for: key)?.handler(key)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        expect(sent.value, ["kb:enter"], "the real browse activation sends a single Return after confirming menu focus")
    }

    test("Claude trial: empty edit without character-count metadata leaves on the real VO-Right command") {
        let savedFocus = API.focusObject, savedAncestors = API.focusAncestors, savedPage = API.focusTreeInterceptor
        let savedConfig = config, savedPoster = KeyboardGesture.poster, savedSink = Speech.sink
        AXReplay.load(.init(app: "Public empty edit", bundle: "test.empty-edit", recorded: "synthetic", root: 0, application: 1, focus: 2, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXWindow"), "AXChildren": .elements([2, 3]), "AXParent": .element(1)]),
            .init(id: 1, attrs: ["AXRole": .string("AXApplication")]),
            .init(id: 2, attrs: ["AXRole": .string("AXTextArea"), "AXTitle": .string("Prompt"), "AXValue": .string(""), "AXSelectedTextRange": .range(0, 0), "AXParent": .element(0)]),
            .init(id: 3, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("Next public control"), "AXParent": .element(0)])
        ]))
        let field = AXReplay.element(2)
        API.setFocusObject(ObjectFactory.make(field), ancestors: [], interceptor: nil)
        ObjectNavigator.shared.focusMoved(to: field, pid: field.pid)
        config.general.navigateByGroups = false
        let sent = Locked<[String]>([])
        var said: [String] = []
        KeyboardGesture.poster = { sent.value.append($0.identifier) }
        Speech.sink = { said.append($0) }
        defer {
            config = savedConfig; KeyboardGesture.poster = savedPoster; Speech.sink = savedSink
            API.setFocusObject(savedFocus, ancestors: savedAncestors, interceptor: savedPage)
            if let focus = savedFocus { ObjectNavigator.shared.focusMoved(to: focus.element, pid: focus.element.pid) }
            AXReplay.unload()
        }
        let plugin = VoiceOverKeysPlugin(), key = KeyboardGesture(identifier: "kb:turnover+rightArrow")!
        plugin.script(for: key)?.handler(key)
        check(sent.value.isEmpty, "an empty field does not post a caret arrow and wait for an impossible move")
        check(said.contains { $0.contains("Next public control") }, "the next control is spoken")
    }
}
