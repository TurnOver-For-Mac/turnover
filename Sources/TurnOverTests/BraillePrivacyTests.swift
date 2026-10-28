// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import AXFixtures

func braillePrivacyTests() {
    test("braille privacy: mixed display-key diagnostics never contain typed dot values") {
        for name in ["dot1", "dot1+dot2+thumb2", "joystickUp+dot8", "dot3+space+thumb4"] {
            expect(Braille.diagnosticKeyName(name), "(a braille input chord)")
        }
        for name in ["SCRBraille.panLeft", "joystickUp", "d1+d2", "thumb2", "routing4"] {
            expect(Braille.diagnosticKeyName(name), name, "non-typing command names remain useful")
        }
    }

    test("braille privacy: contracted words are typed and echoed privately") {
        withBrailleInput { output in
            BrailleInput.chord(dots: [1], space: false)
            BrailleInput.chord(dots: [1, 2], space: false)
            expect(BrailleInput.pending, [1, 3])
            check(output.spoken.isEmpty, "word echo waits for the word to end")
            BrailleInput.chord(dots: [], space: true)
            expect(output.typed.value, ["ab", " "])
            expect(output.spoken.map(\.text), ["ab"])
            check(output.spoken.allSatisfy(\.isPrivate), "typed words are excluded from logs and speech history")
            expect(BrailleInput.pending, [])
            Speech.speakText("public notice")
            expect(output.spoken.last?.isPrivate, false, "typing does not make later speech private")
        }
    }

    test("braille privacy: contracted characters and deleted cells are echoed privately") {
        withBrailleInput { output in
            config.braille.inputEcho = "characters"
            BrailleInput.chord(dots: [1], space: false)
            BrailleInput.chord(dots: [7], space: false)
            expect(output.spoken.map(\.text), ["a", "deleted a"])
            check(output.spoken.allSatisfy(\.isPrivate), "characters and deleted cells are private")
            expect(output.typed.value, [])
            expect(BrailleInput.pending, [])
        }
    }

    test("braille privacy: uncontracted character and word echo is private") {
        withBrailleInput { output in
            config.braille.contractedInput = false
            config.braille.inputEcho = "both"
            BrailleInput.chord(dots: [1], space: false)
            BrailleInput.chord(dots: [1, 2], space: false)
            BrailleInput.chord(dots: [], space: true)
            expect(output.typed.value, ["a", "b", " "])
            expect(output.spoken.map(\.text), ["a", "b", "ab"])
            check(output.spoken.allSatisfy(\.isPrivate), "every part of typing echo is private")
        }
    }

    test("braille privacy: deleting a pending password cell never translates or speaks it") {
        for echo in ["both", "off"] {
            withBrailleInput(secure: true) { output in
                config.braille.inputEcho = echo
                BrailleInput.chord(dots: [1], space: false)
                BrailleInput.chord(dots: [1, 2], space: false)
                BrailleInput.chord(dots: [7], space: false)
                expect(BrailleInput.pending, [1], "only the last cell was removed")
                check(output.translations.isEmpty, "password cells are not translated for echo or deletion")
                check(output.spoken.isEmpty, "password deletion is silent even with echo set to \(echo)")
                BrailleInput.chord(dots: [], space: true)
                expect(output.typed.value, ["a", " "], "the surviving cell is still typed")
                check(output.spoken.isEmpty, "committing a password word does not echo it")
                expect(BrailleInput.pending, [])
            }
        }
    }

    test("braille privacy: uncontracted password typing remains silent") {
        withBrailleInput(secure: true) { output in
            config.braille.contractedInput = false
            config.braille.inputEcho = "both"
            BrailleInput.chord(dots: [1], space: false)
            BrailleInput.chord(dots: [1, 2], space: false)
            BrailleInput.chord(dots: [], space: true)
            expect(output.typed.value, ["a", "b", " "])
            check(output.spoken.isEmpty, "neither password letters nor the word are echoed")
        }
    }

    test("braille privacy: an unrecognised space chord still types without public echo") {
        for secure in [false, true] {
            withBrailleInput(secure: secure) { output in
                BrailleInput.chord(dots: [2, 3, 4, 6], space: true)
                expect(output.typed.value, ["x", " "])
                expect(output.spoken.map(\.text), secure ? [] : ["x"])
                check(output.spoken.allSatisfy(\.isPrivate), "fallback typing uses the private echo path")
                expect(BrailleInput.pending, [])
            }
        }
    }

    test("braille privacy: a late space still finishes the typed word without public echo") {
        for secure in [false, true] {
            withBrailleInput(secure: secure) { output in
                BrailleInput.chord(dots: [1], space: false)
                // Space with dot 1 normally navigates. Once typing has started, a late space finishes the word.
                BrailleInput.chord(dots: [1], space: true, spaceLate: true)
                expect(output.typed.value, ["aa", " "])
                expect(output.spoken.map(\.text), secure ? [] : ["aa"])
                check(output.spoken.allSatisfy(\.isPrivate), "late-space typing uses the private echo path")
                expect(output.keys.value, [], "the navigation command was not sent")
            }
        }
    }
}

private final class BraillePrivacyCapture {
    struct Utterance {
        let text: String
        let isPrivate: Bool
    }
    var spoken: [Utterance] = []
    var translations: [[UInt8]] = []
    let typed = Locked<[String]>([])
    let keys = Locked<[String]>([])
}

private func withBrailleInput(secure: Bool = false, _ body: (BraillePrivacyCapture) -> Void) {
    let savedConfig = config, savedSink = Speech.sink, savedMode = Speech.mode
    let savedFocus = API.focusObject, savedAncestors = API.focusAncestors, savedInterceptor = API.focusTreeInterceptor
    let savedTextPoster = KeyboardGesture.textPoster, savedPoster = KeyboardGesture.poster
    let savedTranslator = BrailleInput.backTranslate, savedHelp = InputManager.isInputHelpActive
    let output = BraillePrivacyCapture()
    let typed = output.typed, keys = output.keys
    // No test can type into a real app, even when an uncontracted correction sends Backspace.
    KeyboardGesture.textPoster = { typed.value.append($0) }
    KeyboardGesture.poster = { keys.value.append($0.identifier) }
    Speech.mode = .off
    InputManager.isInputHelpActive = false
    config.braille.contractedInput = true
    config.braille.inputEcho = "words"
    BrailleInput.backTranslate = { cells, _ in
        output.translations.append(cells)
        let letters: [UInt8: String] = [1: "a", 3: "b", 46: "x"]
        return cells.map { letters[$0] ?? "?" }.joined()
    }
    Speech.sink = { _ in }
    API.setFocusObject(nil, ancestors: [])
    BrailleInput.focusChanged()
    BrailleInput.chord(dots: [], space: true)
    typed.value = []; keys.value = []; output.translations = []

    let fieldAttrs: [String: AXFixture.Value] = [
        "AXRole": .string("AXTextField"), "AXSubrole": .string(secure ? "AXSecureTextField" : "AXTextField"),
        "AXValue": .string(""), "AXFocused": .bool(true), "AXParent": .element(0), "AXWindow": .element(0),
    ]
    let fixture = AXFixture(app: "Braille privacy test", bundle: "test.braille.privacy", recorded: "", root: 0, application: nil, focus: 1, nodes: [
        .init(id: 0, attrs: ["AXRole": .string("AXWindow"), "AXChildren": .elements([1])]),
        .init(id: 1, attrs: fieldAttrs),
    ])
    AXReplay.load(fixture)
    defer {
        // Empty both pending and already-typed state while all output still goes to the test's sinks.
        API.setFocusObject(nil, ancestors: [])
        BrailleInput.focusChanged()
        config.braille.inputEcho = "off"
        BrailleInput.chord(dots: [], space: true)
        AXReplay.unload()
        API.setFocusObject(savedFocus, ancestors: savedAncestors, interceptor: savedInterceptor)
        config = savedConfig; Speech.sink = savedSink; Speech.mode = savedMode
        KeyboardGesture.textPoster = savedTextPoster; KeyboardGesture.poster = savedPoster
        BrailleInput.backTranslate = savedTranslator; InputManager.isInputHelpActive = savedHelp
    }
    guard let field = AXReplay.focus else { return Harness.fail("the braille fixture has no focus") }
    let object = ObjectFactory.make(field)
    API.setFocusObject(object, ancestors: [])
    expect(object.role, secure ? .passwordEdit : .editableText)
    // The sink precedes speech mode and VoiceOver checks. Inspecting its private flag tests the real echo
    // boundary without disabling VoiceOver; an empty-history assertion with speech off would pass unfixed.
    Speech.sink = { output.spoken.append(.init(text: $0, isPrivate: Speech.isPrivateNow)) }
    body(output)
}
