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
                    check(trial.words.dropFirst(before).allSatisfy { $0 == "browse mode" }, "a kept key says nothing but the words for a letter")
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

    // Decided 16 Nov 2026, evening: a kept punctuation key says "browse mode" as a letter does, once a run.
    test("browse typing trap: a kept slash and comma say browse mode once, as a letter does") {
        withPage { _, _, trial, _ in
            for (label, keys) in [("letter", [key(6, [], "z"), key(6, [], "z")]),
                                  ("slash and comma", [key(44, [], "/"), key(43, [], ","), key(44, [], "/")]),
                                  ("Option symbol", [key(1, .option, "ß")])] {
                // (Setting up the replayed page can say something of its own; only what the keys say counts.)
                trial.drain()
                BrowseModeDocument.lastLetterKeptAt = .distantPast
                let before = trial.words.count
                for gesture in keys { check(InputManager.handleKeyDown(gesture), "\(label) is kept") }
                trial.drain()
                RunLoop.current.run(until: Date().addingTimeInterval(1.2))
                trial.drain()
                expect(trial.words.dropFirst(before).filter { $0 == "browse mode" }.count, 1, "\(label): said once for the run")
            }
        }
    }

    // 17 Nov 2026: Backspace, Delete and their kin edited the Claude app's Prompt while browse mode read on. Unhappy cases
    // first: a page or app with its own use for the key (the focus has no delete command: a link, Mail's message), a
    // field with browse mode off (focus mode, or single-letter navigation off), and the Windows styles beside the Mac's.
    let deleteKeys: [(String, String)] = [
        ("kb:backspace", "caret_backspaceCharacter"), ("kb:shift+backspace", "caret_backspaceCharacter"),
        ("kb:option+backspace", "caret_backspaceWord"), ("kb:command+backspace", "caret_backspaceLine"),
        ("kb:delete", "caret_deleteCharacter"), ("kb:option+delete", "caret_deleteWord"),
    ]
    test("browse typing trap: delete keys are kept from a field in browse mode and say browse mode once") {
        withPage { page, field, trial, sent in
            for style in styles {
                config.general.keyboardStyle = style
                KeySettings.refresh()
                trial.drain()
                BrowseModeDocument.lastLetterKeptAt = .distantPast
                let before = trial.words.count
                for (identifier, fieldCommand) in deleteKeys {
                    let gesture = KeyboardGesture(identifier: identifier)!
                    expect(field.script(for: gesture)?.name, fieldCommand, "\(style): the field's own command for \(identifier)")
                    expect(ScriptHandler.findScript(for: gesture)?.name, "browseModeTrap", "\(style): \(identifier) is kept")
                    check(InputManager.handleKeyDown(gesture), "\(style): \(identifier) is taken, not passed to the field")
                }
                trial.drain()
                RunLoop.current.run(until: Date().addingTimeInterval(0.6))
                trial.drain()
                expect(trial.words.dropFirst(before).filter { $0 == "browse mode" }.count, 1, "\(style): the word once for the run")
                check(trial.words.dropFirst(before).allSatisfy { $0 == "browse mode" }, "\(style): nothing else is said")
            }
            check(sent.value.isEmpty, "no delete key is posted to the application")
            check(!page.passThrough, "still in browse mode")
        }
    }

    test("browse typing trap: delete keys still edit in focus mode and with single-letter navigation off") {
        withPage { page, _, _, _ in
            page.passThrough = true
            for (identifier, fieldCommand) in deleteKeys {
                expect(ScriptHandler.findScript(for: KeyboardGesture(identifier: identifier)!)?.name, fieldCommand, "focus mode: \(identifier)")
            }
            page.passThrough = false
            page.singleLetterNavigation = false
            for (identifier, fieldCommand) in deleteKeys {
                expect(ScriptHandler.findScript(for: KeyboardGesture(identifier: identifier)!)?.name, fieldCommand, "letters off: \(identifier)")
            }
        }
    }

    test("browse typing trap: delete keys with no field focused go to the page as before") {
        withPage { page, _, _, _ in
            // The focus on the page itself, as on a link or Mail's message: no delete command, so the page keeps its key.
            API.setFocusObject(TurnOverObject(element: page.webArea), ancestors: [], interceptor: page)
            for (identifier, _) in deleteKeys {
                let gesture = KeyboardGesture(identifier: identifier)!
                check(page.script(for: gesture) == nil, "\(identifier): the page asks for no trap")
                check(ScriptHandler.findScript(for: gesture)?.name != "browseModeTrap", "\(identifier) is not kept")
            }
        }
    }

    // 17 Nov 2026: the word came about 470 ms after a lone kept key. It is said at once, and a kept key soon after
    // neither cuts it nor says it again; a command key still cuts it. Logic only: the voice here is the test driver.
    test("browse typing trap: the word for a kept key is said at once, and a second kept key leaves it alone") {
        withPage { _, _, trial, _ in
            trial.drain()
            BrowseModeDocument.lastLetterKeptAt = .distantPast
            trial.finish = false   // the word is still being said until the test ends it
            let before = trial.words.count
            let z = key(6, [], "z")
            check(InputManager.handleKeyDown(z), "z is kept")
            trial.drain()
            expect(Array(trial.words.dropFirst(before)), ["browse mode"], "said at once, without waiting for the keys to stop")
            check(BrowseModeDocument.keptKeyWordIsSpeaking, "the word is being said")
            check(BrowseModeDocument.keptKeySparesSpeech(ScriptHandler.findScript(for: z)), "a second kept key leaves it alone")
            for _ in 0..<4 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                check(InputManager.handleKeyDown(z), "each kept key is kept")
            }
            trial.drain()
            expect(trial.words.dropFirst(before).filter { $0 == "browse mode" }.count, 1, "five kept keys 100 ms apart: one word")
            let heading = KeyboardGesture(identifier: "kb:h")!
            check(!BrowseModeDocument.keptKeySparesSpeech(ScriptHandler.findScript(for: heading)), "a command key cuts the word")
            trial.queued.last?.1?(true)
            trial.drain()
            check(!BrowseModeDocument.keptKeyWordIsSpeaking, "the word has ended")
            check(!BrowseModeDocument.keptKeySparesSpeech(ScriptHandler.findScript(for: z)), "once it has ended, a kept key cuts speech as any key does")
            BrowseModeDocument.keptKeyWordSince = Date().addingTimeInterval(-2.5)
            check(!BrowseModeDocument.keptKeyWordIsSpeaking, "a word never reported finished frees the keys after two seconds")
            BrowseModeDocument.keptKeyWordSince = nil
            BrowseModeDocument.lastLetterKeptAt = Date().addingTimeInterval(-3.5)
            let again = trial.words.count
            check(InputManager.handleKeyDown(z), "a kept key after three seconds")
            trial.drain()
            expect(Array(trial.words.dropFirst(again)), ["browse mode"], "says the word again")
            trial.finish = true
            trial.queued.last?.1?(true)
            trial.drain()
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
