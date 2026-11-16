// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import TurnOverAX
import AXFixtures

/// Browse mode keeps every key that would type and has no command (16 Nov 2026: a comma and a dash reached the
/// Claude app's Prompt in browse mode, 15 Nov 2026). Unhappy cases: a punctuation key that has a command, focus mode,
/// a password field, the Windows styles beside the Mac style, the mode changing while the key is on its way, and a
/// TurnOver chord with no command.
private final class BrowseTypingField: EditableText {
    var typed: [Character] = []
    override func event_typedCharacter(_ character: Character) { typed.append(character) }
}

func browseTypingTrapTests() {
    func key(_ code: Int64, _ modifiers: Modifiers = [], _ characters: String = "") -> KeyboardGesture {
        KeyboardGesture(keyCode: code, modifiers: modifiers, characters: characters, timestamp: 0, isRepeat: false, flags: [])
    }
    // Public sample keys only.
    let symbolKeys: [(String, KeyboardGesture)] = [
        ("comma", key(43, [], ",")),
        ("dash", key(27, [], "-")),
        ("apostrophe", key(39, [], "'")),
        ("shifted symbol", key(27, .shift, "_")),
        ("Option symbol", key(1, .option, "ß")),
        ("Option Shift symbol", key(2, [.option, .shift], "Î")),
        ("Option dead key", key(14, .option)),
        ("keypad symbol", key(69, [], "+")),
    ]
    let letterKeys: [(String, KeyboardGesture)] = [
        ("unbound letter", key(6, [], "z")),
        ("digit", key(29, [], "0")),
    ]
    let textKeys = letterKeys + symbolKeys
    let styles = ["mac", "windows", "jaws"]

    func withPage(secure: Bool = false, _ body: (BrowseModeDocument, BrowseTypingField, ModeWordsTrial, Locked<[String]>) -> Void) {
        let savedFocus = API.focusObject, savedAncestors = API.focusAncestors, savedPage = API.focusTreeInterceptor
        let savedPid = AXHandler.shared.activePid, savedPoster = KeyboardGesture.poster
        let savedHelp = InputManager.isInputHelpActive, savedPass = InputManager.passNextKey, savedCapture = InputManager.captureNext
        let savedPlugins = GlobalPluginHandler.shared.plugins.map { type(of: $0) }
        let trial = ModeWordsTrial()
        AXReplay.load(.init(app: "Public typing sample", bundle: "test.browse-typing", recorded: "synthetic", root: 0, application: 1, focus: 2, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.com/form"), "AXParent": .element(1), "AXChildren": .elements([2])]),
            .init(id: 1, attrs: ["AXRole": .string("AXApplication"), "AXFocusedUIElement": .element(2)]),
            .init(id: 2, attrs: ["AXRole": .string("AXTextField"), "AXSubrole": .string(secure ? "AXSecureTextField" : "AXTextField"), "AXTitle": .string("Public field"), "AXValue": .string(""), "AXSelectedTextRange": .range(0, 0), "AXParent": .element(0)])
        ]))
        let page = BrowseModeDocument(webArea: AXReplay.element(0))
        let field = BrowseTypingField(element: AXReplay.element(2))
        let sent = Locked<[String]>([])
        KeyboardGesture.poster = { sent.value.append($0.identifier) }
        GlobalPluginHandler.shared.terminateAll()
        InputManager.isInputHelpActive = false
        InputManager.passNextKey = false
        InputManager.captureNext = nil
        config.general.keyboardStyle = "mac"
        config.keyboard.userGestures = [:]
        config.keyboard.speakCommandKeys = false
        config.keyboard.speakTypedCharacters = .off
        config.keyboard.speakTypedWords = .off
        Speech.clearTypedWordBuffer()
        KeySettings.refresh()
        AXHandler.shared.activePid = page.webArea.pid
        API.setFocusObject(field, ancestors: [], interceptor: page)
        page.passThrough = false
        defer {
            trial.drain()
            Speech.clearTypedWordBuffer()
            API.setFocusObject(savedFocus, ancestors: savedAncestors, interceptor: savedPage)
            AXHandler.shared.activePid = savedPid
            KeyboardGesture.poster = savedPoster
            InputManager.isInputHelpActive = savedHelp
            InputManager.passNextKey = savedPass
            InputManager.captureNext = savedCapture
            GlobalPluginHandler.shared.terminateAll()
            for plugin in savedPlugins { GlobalPluginHandler.shared.register(plugin) }
            AXReplay.unload()
            trial.restore()
            KeySettings.refresh()
        }
        body(page, field, trial, sent)
    }

    test("browse typing trap: which keys would type") {
        for (name, gesture) in textKeys { check(gesture.wouldTypeTextInBrowseMode, name) }
        for identifier in ["kb:enter", "kb:numpadEnter", "kb:space", "kb:shift+space", "kb:tab", "kb:escape", "kb:upArrow",
                           "kb:downArrow", "kb:leftArrow", "kb:rightArrow", "kb:backspace", "kb:delete", "kb:f1", "kb:shift+f12",
                           "kb:function", "kb:volumeUp", "kb:numpadClear", "kb:option+rightArrow", "kb:command+a",
                           "kb:command+,", "kb:control+a", "kb:control+-", "kb:turnover+-", "kb:turnover+a"] {
            check(!KeyboardGesture(identifier: identifier)!.wouldTypeTextInBrowseMode, identifier)
        }
        for code in 54...62 { check(!key(Int64(code)).wouldTypeTextInBrowseMode, "a modifier key alone") }
        check(!key(102, [], "").wouldTypeTextInBrowseMode, "an unknown key with no characters (an input-mode switch)")
    }

    test("browse typing trap: a punctuation key with a command still runs it") {
        withPage { page, _, _, _ in
            for style in ["windows", "jaws"] {
                config.general.keyboardStyle = style
                expect(page.script(for: key(43, [], ","))?.name, "pastEndOfContainer", "\(style): comma")
                expect(page.script(for: key(43, .shift, "<"))?.name, "startOfContainer", "\(style): Shift comma")
                expect(page.script(for: key(18, .shift, "!"))?.name, "previousHeading1", "\(style): Shift 1")
            }
            config.general.keyboardStyle = "mac"
            expect(page.script(for: key(43, [], ","))?.name, "browseModeTrap", "mac: comma has no command, so it is kept")
        }
    }

    test("browse typing trap: focus mode changes nothing, every character reaches the field") {
        withPage { page, field, trial, sent in
            page.passThrough = true
            var expected: [Character] = []
            for style in styles {
                config.general.keyboardStyle = style
                KeySettings.refresh()
                for (name, gesture) in textKeys {
                    check(page.script(for: gesture) == nil, "\(style): \(name) has no browse-mode script")
                    check(!InputManager.handleKeyDown(gesture), "\(style): \(name) goes to the application")
                    if let c = gesture.typedCharacter { expected.append(c) }
                }
            }
            trial.drain()
            expect(field.typed, expected, "every typed character is echoed as typed, in order")
            check(sent.value.isEmpty, "keys going to the application are not posted again")
        }
    }

    for secure in [false, true] {
        test("browse typing trap: browse mode keeps every typing key with no command, password field \(secure)") {
            withPage(secure: secure) { page, field, trial, sent in
                trial.drain()
                let before = trial.words.count
                for style in styles {
                    config.general.keyboardStyle = style
                    KeySettings.refresh()
                    for (name, gesture) in textKeys {
                        let commaHasCommand = gesture.keyCode == 43 && style != "mac"
                        if commaHasCommand { continue }
                        expect(ScriptHandler.findScript(for: gesture)?.name, "browseModeTrap", "\(style): \(name)")
                        check(InputManager.handleKeyDown(gesture), "\(style): \(name) is kept from the page")
                    }
                }
                trial.drain()
                RunLoop.current.run(until: Date().addingTimeInterval(0.4))
                check(field.typed.isEmpty, "a kept key is not counted by the typing echo")
                check(sent.value.isEmpty, "a kept key is never posted to the application")
                check(trial.sound.isEmpty, "keeping a key does not change the mode")
                check(!page.passThrough, "still in browse mode")
                if secure {
                    // (The test runner has the keyboard, so the existing "not typed" hold-back for a password field in
                    // another application may speak; what matters is that nothing is typed and the log names no key.)
                    let logged = key(43, [], ",").logDescription(commandName: "browseModeTrap", secure: true)
                    expect(logged, "(a typed key)", "a kept key in a password field is not named in the log")
                } else {
                    check(trial.words.dropFirst(before).allSatisfy { $0 == "browse mode" }, "nothing is said for a kept key but the existing words for letters")
                }
            }
        }
    }

    // The trap is the last resort: a key that a handler asked after the page would run is not kept (review, 16 Nov
    // 2026: Option D and Option B did nothing on a web page in browse mode). The scripts are found, not run, so no
    // Finder window or status menu list opens.
    test("browse typing trap: a global command on a typing key reaches its command") {
        withPage { page, _, _, _ in
            let optionD = key(2, .option, "∂")
            let optionB = key(11, .option, "∫")
            let unbound = key(6, [], "z")
            for style in ["windows", "jaws"] {
                config.general.keyboardStyle = style
                KeySettings.refresh()
                expect(page.script(for: optionD)?.name, "browseModeTrap", "\(style): the page alone would keep Option D")
                expect(ScriptHandler.findScript(for: optionD)?.name, "showDesktop", "\(style): Option D is Show Desktop")
                expect(ScriptHandler.findScript(for: optionB)?.name, "focusStatusMenus", "\(style): Option B is Status Menus")
                expect(ScriptHandler.findScript(for: unbound)?.name, "browseModeTrap", "\(style): a key with no command anywhere is still kept")
            }
            config.general.keyboardStyle = "mac"
            KeySettings.refresh()
            expect(ScriptHandler.findScript(for: optionD)?.name, "browseModeTrap", "mac: Option D has no command, so it is kept")
            page.passThrough = true
            check(ScriptHandler.findScript(for: unbound) == nil, "focus mode: a key with no command goes to the field")
            check(ScriptHandler.findScript(for: optionD) == nil, "focus mode, mac: Option D goes to the field")
        }
    }

    // Kept keys are what the user meant to type, so the log does not name them (review, 16 Nov 2026).
    test("browse typing trap: a kept key is logged without its name, a command key with it") {
        for (name, gesture) in textKeys {
            expect(gesture.logDescription(commandName: "browseModeTrap"), "(a kept key) → browseModeTrap", "\(name) is not named")
            expect(gesture.logDescription(commandName: "browseModeTrap", secure: true), "(a typed key)", "\(name) in a password field")
        }
        expect(key(43, [], ",").logDescription(commandName: "pastEndOfContainer"), "kb:, → pastEndOfContainer", "a command on comma is named")
        expect(key(2, .option, "∂").logDescription(commandName: "showDesktop"), "kb:option+d → showDesktop", "Option D's command is named")
        expect(key(4, [], "h").logDescription(commandName: "nextHeading"), "kb:h → nextHeading", "a letter command is named")
    }

    test("browse typing trap: a kept symbol on its own says nothing") {
        withPage { _, _, trial, _ in
            // (Setting up the replayed page can say something of its own; only what the keys say counts.)
            trial.drain()
            let before = trial.words.count
            for (name, gesture) in symbolKeys {
                check(InputManager.handleKeyDown(gesture), "\(name) is kept")
            }
            trial.drain()
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            expect(Array(trial.words.dropFirst(before)), [], "no new speech for a kept symbol")
        }
    }

    test("browse typing trap: single-letter navigation off leaves punctuation to the page") {
        withPage { page, field, trial, _ in
            page.singleLetterNavigation = false
            check(!InputManager.handleKeyDown(key(27, [], "-")), "the page's own keys are wanted")
            trial.drain()
            expect(field.typed, ["-"], "the dash is typed and echoed")
        }
    }

    test("browse typing trap: the mode changing while the key is on its way") {
        withPage { page, field, trial, sent in
            check(InputManager.handleKeyDown(key(27, [], "-")), "browse mode at the key's lookup: kept")
            page.passThrough = true
            trial.drain()
            check(field.typed.isEmpty, "focus mode coming on after the lookup does not type the kept key")
            check(sent.value.isEmpty, "nor post it")
            check(!InputManager.handleKeyDown(key(27, [], "-")), "the next dash, in focus mode, goes to the field")
            trial.drain()
            expect(field.typed, ["-"], "and is echoed")
        }
    }

    test("browse typing trap: a TurnOver chord with no command passes nothing to the application") {
        withPage { _, field, trial, sent in
            let gesture = key(27, .turnover, "-")
            check(ScriptHandler.findScript(for: gesture) == nil, "TurnOver dash has no command")
            check(InputManager.handleKeyDown(gesture), "the chord is kept from the application")
            trial.drain()
            check(field.typed.isEmpty, "nothing is echoed as typed")
            check(sent.value.isEmpty, "nothing is posted")
        }
    }
}
