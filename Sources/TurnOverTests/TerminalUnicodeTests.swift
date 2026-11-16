// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import AXFixtures

func terminalUnicodeTests() {
    func withTerminal(_ text: String, cursor: Int, knownLength: Bool = true,
                      _ body: (TurnOverObject, Locked<Int>, () -> [String]) -> Void) {
        BuiltInModules.register()
        guard let type = AppModuleHandler.shared.moduleType(for: "com.apple.Terminal") else {
            return Harness.fail("the production Terminal module is registered")
        }
        var attrs: [String: AXFixture.Value] = ["AXRole": .string("AXTextArea"), "AXSubrole": .string("AXTerminalTextArea"),
            "AXDescription": .string("shell"), "AXValue": .string(text), "AXSelectedTextRange": .range(cursor, 0)]
        if knownLength { attrs["AXNumberOfCharacters"] = .number(Double(text.utf16.count)) }
        let fixture = AXFixture(app: "Public Terminal sample", bundle: "com.apple.Terminal", recorded: "synthetic", root: 1,
                                application: nil, focus: 1, nodes: [.init(id: 1, attrs: attrs,
                                params: [kAXStringForRangeParameterizedAttribute, kAXLineForIndexParameterizedAttribute, kAXRangeForLineParameterizedAttribute])])
        AXReplay.load(fixture)
        let savedSink = Speech.sink, savedPoster = KeyboardGesture.poster, savedConfig = config
        var said: [String] = []
        let delivered = Locked(0)
        Speech.sink = { said.append($0) }
        KeyboardGesture.poster = { _ in delivered.lock.lock(); delivered.unsafeValue += 1; delivered.lock.unlock() }
        config.speech.sayCapForCapitals = false
        config.speech.capitalPitch = 0
        defer { Speech.sink = savedSink; KeyboardGesture.poster = savedPoster; config = savedConfig; AXReplay.unload() }
        let element = AXReplay.element(1)
        let module = type.init(pid: element.pid, bundleIdentifier: "com.apple.Terminal", appName: "Public Terminal sample")
        guard let overlay = module.objectClass(for: element, role: .editableText, subrole: "AXTerminalTextArea") else {
            return Harness.fail("the registered module selects its actual terminal overlay")
        }
        let object = overlay.init(element: element)
        body(object, delivered, { said })
    }

    test("Terminal: registered Backspace script reads complete Unicode characters and still delivers the key") {
        for character in ["😀", "e\u{301}", "👩🏽‍💻", "🇬🇧"] {
            let text = "prompt " + character
            withTerminal(text, cursor: text.utf16.count) { object, delivered, said in
                guard let script = object.script(named: "terminal_backspace") else { return Harness.fail("actual Backspace script exists") }
                script.handler(KeyboardGesture(identifier: "kb:backspace")!)
                expect(delivered.value, 1, "one Backspace still goes to the shell")
                let expected = Symbols.name(of: character.first!)
                // lastRaw is the actual input to speakText. The sink observes later shared cleanup, which
                // intentionally strips zero-width joiners; it cannot alone establish the selected character.
                expect(Speech.lastRaw, expected, "Terminal passes the complete grapheme to speech before cleanup")
                expect(said(), [Speech.cleaned(expected)], "the existing speech cleanup policy still applies")
                check(!said().joined().contains("\u{fffd}"), "no surrogate repair character is spoken")
            }
        }
    }
    test("Terminal: registered forward Delete script reads a complete character at the caret") {
        for character in ["😀", "e\u{301}", "👩🏽‍💻"] {
            withTerminal("prompt " + character + " tail", cursor: 7) { object, delivered, said in
                guard let script = object.script(named: "terminal_deleteForward") else { return Harness.fail("actual Delete script exists") }
                script.handler(KeyboardGesture(identifier: "kb:delete")!)
                expect(delivered.value, 1)
                let expected = Symbols.name(of: character.first!)
                expect(Speech.lastRaw, expected, "forward Delete passes one complete grapheme before cleanup")
                expect(said(), [Speech.cleaned(expected)])
            }
        }
    }
    test("Terminal: unavailable character length does not fall back to scrollback or invent blank feedback") {
        withTerminal("prompt 😀", cursor: 9, knownLength: false) { object, delivered, said in
            object.script(named: "terminal_backspace")?.handler(KeyboardGesture(identifier: "kb:backspace")!)
            expect(delivered.value, 1, "key delivery survives unavailable text metadata")
            expect(said(), [], "no unproven character or blank is announced")
        }
    }
    test("Terminal: a character exceeding the bounded context is left unspoken while the key is delivered") {
        let cluster = "a" + String(repeating: "\u{301}", count: CharacterBoundaries.maximumContextLength + 8)
        let text = "prompt " + cluster
        withTerminal(text, cursor: text.utf16.count) { object, delivered, said in
            object.script(named: "terminal_backspace")?.handler(KeyboardGesture(identifier: "kb:backspace")!)
            expect(delivered.value, 1)
            expect(said(), [], "an incomplete context is not presented as a complete character")
        }
    }

    // The text area as Terminal gives it now, without the subrole: only its description says it is the shell.
    func terminalOverlay(bundle: String, description: String) -> TurnOverObject? {
        BuiltInModules.register()
        guard let type = AppModuleHandler.shared.moduleType(for: bundle) else {
            Harness.fail("a module is registered for \(bundle)"); return nil
        }
        AXReplay.load(AXFixture(app: "Public Terminal sample", bundle: bundle, recorded: "synthetic", root: 1, application: nil, focus: 1,
                                nodes: [.init(id: 1, attrs: ["AXRole": .string("AXTextArea"), "AXDescription": .string(description)])]))
        defer { AXReplay.unload() }
        let element = AXReplay.element(1)
        let module = type.init(pid: element.pid, bundleIdentifier: bundle, appName: "Public Terminal sample")
        return module.objectClass(for: element, role: .editableText, subrole: nil)?.init(element: element)
    }
    test("Terminal: the text area is the terminal when Terminal says \"shell\" in the Mac's language") {
        // A Turkish Mac (7 Nov 2026, macOS 27.2, Terminal 2.15): no subrole, described "kabuk". Return went to the edit
        // field's caret_newLine and new output was never read.
        guard let object = terminalOverlay(bundle: "com.apple.Terminal", description: "kabuk") else {
            return Harness.fail("a text area Terminal describes as \"kabuk\" is the terminal")
        }
        check(object.script(named: "terminal_enter") != nil, "Return goes to the terminal's script")
    }
    test("Terminal: a text area described otherwise stays an edit field; iTerm2 still needs \"shell\"") {
        check(terminalOverlay(bundle: "com.apple.Terminal", description: "shell") != nil, "Terminal in English")
        check(terminalOverlay(bundle: "com.apple.Terminal", description: "notes") == nil, "not a word of Terminal's for the shell")
        check(terminalOverlay(bundle: "com.googlecode.iterm2", description: "shell") != nil, "iTerm2, as before")
    }
}
