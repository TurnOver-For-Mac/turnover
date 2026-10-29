// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import TurnOverAX
import AXFixtures

/// Replay PIDs do not identify a real Word process. Supply its registered production module while exercising
/// EditableText's actual native caret scripts and AXTextInfo, with all key posts intercepted below.
private final class WordBoundaryField: EditableText {
    private var owner: AppModule?
    required init(element: AXUIElement) { super.init(element: element) }
    convenience init(element: AXUIElement, module: AppModule) { self.init(element: element); owner = module }
    override var appModule: AppModule { owner ?? super.appModule }
    override var caretMoveTimeout: TimeInterval { 0 }
}

private final class WordBoundaryOutput {
    let posted = Locked(0)
    var sounds: [Bool] = []
    var haptics = 0
    var spoken: [String] = []
}

func wordCaretBoundaryTests() {
    func withField(word: Bool = true, caret: Int, moveOnFirstKey: Int? = nil,
                   _ body: (WordBoundaryField, AppModule, WordBoundaryOutput) -> Void) {
        let sample = "alpha\n"
        AXReplay.load(.init(app: "Public Word boundary sample", bundle: "test.word.boundary", recorded: "synthetic", root: 1,
                            application: nil, focus: 10, nodes: [
            .init(id: 1, attrs: ["AXRole": .string("AXWindow"), "AXChildren": .elements([10, 23])]),
            .init(id: 10, attrs: ["AXRole": .string("AXTextArea"), "AXDescription": .string("Page 1 content"),
                                 "AXValue": .string(sample), "AXNumberOfCharacters": .number(Double(sample.utf16.count)),
                                 "AXSelectedTextRange": .range(caret, 0), "AXFocused": .bool(true),
                                 "AXParent": .element(1), "AXWindow": .element(1)],
                  params: [kAXStringForRangeParameterizedAttribute, kAXLineForIndexParameterizedAttribute, kAXRangeForLineParameterizedAttribute]),
            .init(id: 20, attrs: ["AXRole": .string("AXTextArea"), "AXValue": .string("Public cell"), "AXParent": .element(21)]),
            .init(id: 21, attrs: ["AXRole": .string("AXCell"), "AXRowIndexRange": .range(0, 1), "AXColumnIndexRange": .range(0, 1),
                                 "AXParent": .element(22), "AXChildren": .elements([20])]),
            .init(id: 22, attrs: ["AXRole": .string("AXRow"), "AXParent": .element(23), "AXChildren": .elements([21])]),
            .init(id: 23, attrs: ["AXRole": .string("AXTable"), "AXParent": .element(1), "AXRows": .elements([22]), "AXChildren": .elements([22])]),
        ]))
        let savedConfig = config, savedPoster = KeyboardGesture.poster, savedSound = Tones.edgeSound
        let savedHaptic = Tones.onEdge, savedSink = Speech.sink
        let savedFocus = API.focusObject, savedAncestors = API.focusAncestors, savedInterceptor = API.focusTreeInterceptor
        let savedReview = ObjectNavigator.shared.reviewElement
        let output = WordBoundaryOutput(), posted = output.posted, element = AXReplay.element(10)
        KeyboardGesture.poster = { _ in
            posted.lock.lock(); posted.unsafeValue += 1; let count = posted.unsafeValue; posted.lock.unlock()
            if count == 1, let moveOnFirstKey {
                _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRangeValue(moveOnFirstKey, 0))
            }
        }
        Tones.edgeSound = { output.sounds.append($0) }
        Tones.onEdge = { output.haptics += 1 }
        Speech.sink = { output.spoken.append($0) }
        config.general.keyboardStyle = "mac"
        config.documentFormatting.tables = .off
        config.speech.sayCapForCapitals = false
        config.speech.capitalPitch = 0
        BuiltInModules.register()
        guard let type = AppModuleHandler.shared.moduleType(for: "com.microsoft.Word") else {
            Harness.fail("the production Word module is registered")
            KeyboardGesture.poster = savedPoster; Tones.edgeSound = savedSound; Tones.onEdge = savedHaptic
            Speech.sink = savedSink; config = savedConfig; AXReplay.unload(); return
        }
        let module = word ? type.init(pid: element.pid, bundleIdentifier: "com.microsoft.Word", appName: "Public Word sample")
            : AppModule(pid: element.pid, bundleIdentifier: "test.other", appName: "Public other app")
        let field = WordBoundaryField(element: element, module: module)
        API.setFocusObject(field, ancestors: [])
        defer {
            module.terminate()
            API.setFocusObject(savedFocus, ancestors: savedAncestors, interceptor: savedInterceptor)
            if let savedReview { ObjectNavigator.shared.place(savedReview) }
            KeyboardGesture.poster = savedPoster; Tones.edgeSound = savedSound; Tones.onEdge = savedHaptic
            Speech.sink = savedSink; config = savedConfig; AXReplay.unload()
        }
        body(field, module, output)
    }
    func invoke(_ field: WordBoundaryField, _ name: String, _ gesture: String) {
        guard let script = field.script(named: name), let key = KeyboardGesture(identifier: gesture) else {
            return Harness.fail("actual caret script and gesture exist")
        }
        script.handler(key)
    }

    test("Word boundary: known native caret edge delivers the key and keeps only haptic feedback") {
        withField(caret: 0) { field, module, output in
            check(!module.playsNativeCaretBoundarySound, "registered Word module owns the exception")
            invoke(field, "caret_moveByLine", "kb:upArrow")
            expect(output.posted.value, 1)
            expect(output.sounds, [], "Word/macOS supplies this native boundary sound")
            expect(output.haptics, 1, "sound-only suppression preserves the trackpad edge")
        }
    }
    test("Word boundary: same-line retry preserves both native keys without an extra boundary sound") {
        withField(caret: 2, moveOnFirstKey: 3) { field, _, output in
            invoke(field, "caret_moveByLine", "kb:downArrow")
            expect(output.posted.value, 2, "existing same-line retry still goes to Word")
            expect(output.sounds, [])
            expect(output.haptics, 1)
        }
    }
    test("Word boundary: unchanged character movement keeps its native key and late check quiet") {
        withField(caret: 2) { field, _, output in
            invoke(field, "caret_moveByCharacter", "kb:rightArrow")
            expect(output.posted.value, 1)
            expect(output.sounds, [])
            expect(output.haptics, 1)
        }
    }
    test("Word boundary: successful native movement still reads the character and has no edge") {
        withField(caret: 2, moveOnFirstKey: 3) { field, _, output in
            invoke(field, "caret_moveByCharacter", "kb:rightArrow")
            expect(output.posted.value, 1)
            expect(output.spoken, ["p"], "Mac character reading still says the character just passed")
            expect(output.sounds, [])
            expect(output.haptics, 0)
        }
    }
    test("caret boundary: other apps retain sound on all three native edge paths") {
        let cases: [(Int, Int?, String, String, Int)] = [
            (0, nil, "caret_moveByLine", "kb:upArrow", 1),
            (2, 3, "caret_moveByLine", "kb:downArrow", 2),
            (2, nil, "caret_moveByCharacter", "kb:rightArrow", 1),
        ]
        for (caret, target, script, gesture, posts) in cases {
            withField(word: false, caret: caret, moveOnFirstKey: target) { field, module, output in
                check(module.playsNativeCaretBoundarySound, "default app policy is unchanged")
                invoke(field, script, gesture)
                expect(output.posted.value, posts)
                expect(output.sounds, [true], "native-key context still reaches the existing sound decision")
                expect(output.haptics, 1)
            }
        }
    }
    test("Word boundary: TurnOver-owned table navigation keeps its boundary sound and posts no native key") {
        withField(caret: 0) { _, module, output in
            let element = AXReplay.element(20)
            guard let type = module.objectClass(for: element, role: .editableText, subrole: nil) else { return Harness.fail("Word table overlay") }
            let cell = type.init(element: element)
            guard let script = cell.script(named: "table_nextRow") else { return Harness.fail("Word-owned table script") }
            script.handler(KeyboardGesture(identifier: "kb:turnover+downArrow")!)
            expect(output.posted.value, 0)
            expect(output.sounds, [false], "no native key was forwarded, so TurnOver supplies the edge")
            expect(output.haptics, 1)
            expect(output.spoken, ["edge of table"])
        }
    }
    test("Word boundary: TurnOver-owned object review keeps its edge without a native caret key") {
        withField(caret: 0) { _, _, output in
            let navigator = ObjectNavigator.shared
            navigator.place(AXReplay.element(1))
            navigator.parent()
            expect(output.posted.value, 0)
            expect(output.sounds, [false])
            expect(output.haptics, 1)
        }
    }
}
