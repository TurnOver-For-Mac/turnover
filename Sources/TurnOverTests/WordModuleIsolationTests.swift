// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import TurnOverAX
import AXFixtures

private final class IsolationModule: AppModule {
    var ownSpellingMenu = false
    var hintText: String?
    var formatRequests = 0
    var formatReply: (@MainActor (String) -> Void)?
    override var usesNativeSpellingMenu: Bool { ownSpellingMenu }
    override func hint(for object: TurnOverObject) -> String? { hintText }
    override func paragraphFormatting(_ completion: @escaping @MainActor (String) -> Void) {
        formatRequests += 1
        formatReply = completion
    }
}

private final class IsolationText: EditableText {
    var owner: AppModule?
    var formatting = FormatField()
    var testRole: Role?
    var storyReads = 0
    override var role: Role { testRole ?? super.role }
    override var appModule: AppModule { owner ?? super.appModule }
    override var textInfoClass: TextInfo.Type { IsolationTextInfo.self }
}

private final class IsolationTextInfo: TextInfo {
    override func storyLength() -> Int {
        (obj as? IsolationText)?.storyReads += 1
        return 0
    }
    override func caretOffset() -> Int? { 0 }
    override func selectionOffsets() -> (Int, Int)? { (0, 0) }
    override func formatField(at offset: Int) -> FormatField? { (obj as? IsolationText)?.formatting }
}

func wordModuleIsolationTests() {
    func wordModule(pid: pid_t = 0) -> AppModule? {
        BuiltInModules.register()
        guard let type = AppModuleHandler.shared.moduleType(for: "com.microsoft.Word") else {
            Harness.fail("Word's production module is registered"); return nil
        }
        return type.init(pid: pid, bundleIdentifier: "com.microsoft.Word", appName: "Public Word sample")
    }
    func withText(_ body: (IsolationText, IsolationModule, () -> [String]) -> Void) {
        AXReplay.load(.init(app: "Public module sample", bundle: "test.module-policy", recorded: "synthetic", root: 1,
                            application: nil, focus: 2, nodes: [
            .init(id: 1, attrs: ["AXRole": .string("AXWindow"), "AXChildren": .elements([2])]),
            .init(id: 2, attrs: ["AXRole": .string("AXTextArea"), "AXParent": .element(1), "AXWindow": .element(1)]),
        ]))
        let savedConfig = config, savedSink = Speech.sink
        let savedFocus = API.focusObject, savedAncestors = API.focusAncestors, savedInterceptor = API.focusTreeInterceptor
        let text = IsolationText(element: AXReplay.element(2))
        let module = IsolationModule(pid: text.pid, bundleIdentifier: "test.module-policy", appName: "Public editor")
        text.owner = module
        text.formatting.bold = true
        var spoken: [String] = []
        Speech.sink = { spoken.append($0) }
        config.keyboard.multiPressTimeoutMs = 5000
        API.setFocusObject(text, ancestors: [])
        ScriptHandler.clearLastScript()
        defer {
            ScriptHandler.clearLastScript()
            API.setFocusObject(savedFocus, ancestors: savedAncestors, interceptor: savedInterceptor)
            Speech.sink = savedSink; config = savedConfig
            module.terminate(); AXReplay.unload()
        }
        body(text, module, { spoken })
    }

    test("Word module: dictionary and native formatting policies belong to the registered implementation") {
        guard let word = wordModule() else { return }
        defer { word.terminate() }
        check(word.usesNativeSpellingMenu, "Word retains its own corrections and dictionary")
        check(word.handlesNativeFormattingShortcuts, "Word retains its automation feedback")
        let base = AppModule(pid: 0, bundleIdentifier: "com.microsoft.Word", appName: "Public sample")
        check(!base.usesNativeSpellingMenu && !base.handlesNativeFormattingShortcuts,
              "the bundle identifier alone does not change shared policy")
    }
    test("Word module: native formatting announcements retain the shortcut and time boundaries") {
        guard let word = wordModule() else { return }
        defer { word.terminate() }
        for key in ["kb:command+b", "kb:command+i", "kb:command+u"] {
            check(word.ignoresAnnouncement("Public native announcement", after: key, elapsed: 0.79), "the module owns recent shortcut news")
            check(!word.ignoresAnnouncement("Public native announcement", after: key, elapsed: 0.8), "later app announcements remain audible")
        }
        check(!word.ignoresAnnouncement("Public native announcement", after: "kb:command+s", elapsed: 0.1), "other app news remains audible")
        let other = AppModule(pid: 0, bundleIdentifier: "test.other", appName: "Public editor")
        check(!other.ignoresAnnouncement("Public native announcement", after: "kb:command+b", elapsed: 0.1), "other apps keep native news")
    }
    test("app hints: module hints and suppression precede generic control hints") {
        withText { text, module, _ in
            text.testRole = .button
            module.hintText = "Public editor hint"
            expect(Hints.forObject(text), "Public editor hint")
            module.hintText = ""
            expect(Hints.forObject(text), "", "an explicit empty hint suppresses fallback")
            module.hintText = nil
            expect(Hints.forObject(text), "Space presses it.", "nil retains the ordinary control hint")
            text.testRole = .editableText
            guard let word = wordModule(pid: text.pid) else { return }
            defer { word.terminate() }
            text.owner = word
            expect(Hints.forObject(text), "TurnOver Down reads from here; TurnOver H moves by heading.")
        }
    }
    test("spelling menu: another app can retain its native corrections through module policy") {
        withText { text, module, spoken in
            module.ownSpellingMenu = true
            check(!SpellingCorrections.offer(), "native corrections are left to the app's context menu")
            expect(text.storyReads, 0, "the shared checker must not inspect words owned by the app's dictionary")
            expect(spoken(), [], "no replacement menu or spelling announcement is produced")
        }
    }
    test("paragraph formatting: the real report command asks the app only for missing detail") {
        withText { text, module, spoken in
            guard let report = GlobalCommands.shared.script(named: "reportFormatting"),
                  let gesture = KeyboardGesture(identifier: "kb:turnover+f") else { return Harness.fail("format report command") }
            ScriptHandler.executeScript(report, gesture: gesture)
            expect(module.formatRequests, 0, "the first report uses the text's formatting")
            ScriptHandler.executeScript(report, gesture: gesture)
            expect(module.formatRequests, 1, "the repeated report requests supplemental paragraph information")
            expect(spoken(), ["bold", "bold"])
            module.formatReply?("Public paragraph detail")
            expect(spoken().last, "Public paragraph detail", "the returned detail follows the ordinary format report")
            text.formatting.alignment = "left aligned"
            ScriptHandler.executeScript(report, gesture: gesture)
            expect(module.formatRequests, 1, "native alignment keeps the existing no-supplement rule")
        }
    }
    test("paragraph formatting: ordinary modules complete an unsupported request without extra speech") {
        withText { text, _, spoken in
            text.owner = AppModule(pid: text.pid, bundleIdentifier: "test.other", appName: "Public editor")
            guard let report = GlobalCommands.shared.script(named: "reportFormatting"),
                  let gesture = KeyboardGesture(identifier: "kb:turnover+f") else { return Harness.fail("format report command") }
            ScriptHandler.executeScript(report, gesture: gesture)
            ScriptHandler.executeScript(report, gesture: gesture)
            expect(spoken(), ["bold", "bold"])
        }
    }
    test("Word automation: completing one request cannot dismiss another request's permission reminder") {
        let state = WordAutomationState()
        let first = state.begin(), second = state.begin()
        check(first.isFirst && second.isFirst, "unanswered Word requests retain the first-use timeout")
        check(!state.finish(first, succeeded: true, refused: false), "success needs no refusal warning")
        check(!state.isPending(first) && state.isPending(second), "reminders belong to individual pending requests")
        let settled = state.begin()
        check(!settled.isFirst && !state.isPending(settled), "an answered script settles Automation for later requests")
        _ = state.finish(second, succeeded: false, refused: false)
        check(!state.isPending(second), "an error also retires its reminder")
    }
    test("Word automation: a refused script retains first-use handling and throttles refusal explanations") {
        let state = WordAutomationState(), start = Date(timeIntervalSince1970: 100)
        let first = state.begin()
        check(state.finish(first, succeeded: false, refused: true, at: start), "first refusal is explained")
        check(!state.isPending(first), "a refused request no longer waits for consent")
        let second = state.begin()
        check(second.isFirst, "a refusal is not a successful Word answer")
        check(!state.finish(second, succeeded: false, refused: true, at: start.addingTimeInterval(30)), "the existing 30-second limit is retained")
        check(state.finish(state.begin(), succeeded: false, refused: true, at: start.addingTimeInterval(31)), "a later refusal can be explained")
    }
}
