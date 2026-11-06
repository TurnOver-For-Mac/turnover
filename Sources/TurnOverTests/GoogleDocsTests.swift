// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import TurnOverAX
import AXFixtures

private final class BoundaryAdapter: DocumentAdapter {
    var owns = true
    var focused: [AXUIElement] = []
    func usesNativeTextFeedback(for element: AXUIElement) -> Bool { owns }
    func focusMoved(to element: AXUIElement) { focused.append(element) }
    func checkSoon(_ document: BrowseModeDocument) {}
}
private final class BoundaryTextInfo: TextInfo {
    static let caret = Locked(0)
    override func caretOffset() -> Int? { Self.caret.value }
    override func storyLength() -> Int { 2 }
    override func textRange(_ s: Int, _ e: Int) -> String { "" }
}
private final class BoundaryText: EditableText {
    override var textInfoClass: TextInfo.Type { BoundaryTextInfo.self }
}
func googleDocsTests() {
    func fixture() -> AXFixture {
        .init(app: "Public editor", bundle: "test.google-boundary", recorded: "", root: 0, application: nil, focus: 1, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://docs.google.com/document/d/public/edit"), "AXChildren": .elements([1])]),
            .init(id: 1, attrs: ["AXRole": .string("AXTextArea"), "AXParent": .element(0)]),
            .init(id: 2, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.test/editor"), "AXChildren": .elements([3])]),
            .init(id: 3, attrs: ["AXRole": .string("AXTextArea"), "AXParent": .element(2)]),
        ])
    }
    test("Google boundary: editor recognition delegates to the unchanged implementation") {
        AXReplay.load(fixture()); defer { AXReplay.unload() }
        let adapter = GoogleDocsDocumentAdapter()
        check(adapter.usesNativeTextFeedback(for: AXReplay.element(1)), "Google editor is recognized through the boundary")
        check(!adapter.usesNativeTextFeedback(for: AXReplay.element(3)), "ordinary editors retain ordinary feedback")
    }
    test("document adapters: existing focus and caret dispatch conditions are preserved") {
        AXReplay.load(fixture()); defer { AXReplay.unload() }
        let adapters = DocumentAdapters(), adapter = BoundaryAdapter()
        adapters.register(adapter)
        let object = TurnOverObject(element: AXReplay.element(1))
        adapters.observe(Event(.gainFocus, object))
        adapters.observe(Event(.caret, object))
        adapter.owns = false
        adapters.observe(Event(.caret, object))
        adapters.observe(Event(.valueChange, object))
        expect(adapter.focused.count, 2, "focus always dispatches; caret only dispatches for the owning adapter")
    }
    test("Google boundary: Return still flushes word echo") {
        AXReplay.load(fixture())
        let saved = config, sink = Speech.sink, poster = KeyboardGesture.poster
        let adapters = DocumentAdapters.shared
        defer {
            config = saved; Speech.sink = sink; KeyboardGesture.poster = poster; DocumentAdapters.shared = adapters
            AXReplay.unload()
        }
        DocumentAdapters.shared = DocumentAdapters()
        DocumentAdapters.shared.register(BoundaryAdapter())
        config.keyboard.speakTypedCharacters = .off
        config.keyboard.speakTypedWords = .off
        Speech.speakTypedCharacter("\r", inEditable: true)
        config.keyboard.speakTypedWords = .always
        config.keyboard.speakNewLine = false
        var heard: [String] = []
        Speech.sink = { heard.append($0) }
        let caret = BoundaryTextInfo.caret
        caret.value = 0
        KeyboardGesture.poster = { _ in caret.value = 1 }
        for character in "sample" { Speech.speakTypedCharacter(character, inEditable: true) }
        let field = BoundaryText(element: AXReplay.element(1)), key = KeyboardGesture(identifier: "kb:return")!
        guard let script = field.script(for: key) else { return check(false, "Return script") }
        script.handler(key)
        check(heard.contains("sample"), "Enter announces the completed word through speakTypedCharacter")
    }
}
