// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import TurnOverAX
import AXFixtures

/// Supplies one real Word module to the actual overlay's TextInfo across replayed document windows. The replay
/// gives each element a synthetic PID, so its normal process lookup cannot establish their common application.
private final class WordPageReadingObject: TurnOverObject {
    private var owner: AppModule?
    private var provider: TextInfo.Type?
    required init(element: AXUIElement) { super.init(element: element) }
    convenience init(element: AXUIElement, module: AppModule, provider: TextInfo.Type) {
        self.init(element: element); owner = module; self.provider = provider
    }
    override var appModule: AppModule { owner ?? super.appModule }
    override var textInfoClass: TextInfo.Type { provider ?? super.textInfoClass }
}

private func wordPageNode(_ id: Int, window: Int, start: Int, length: Int, text: String,
                          shared: [Int], characters: Int? = nil) -> AXFixture.Node {
    .init(id: id, attrs: [
        "AXRole": .string("AXTextArea"), "AXDescription": .string("Page 1 content"), "AXWindow": .element(window),
        "AXSharedCharacterRange": .range(start, length), "AXSharedTextUIElements": .elements(shared),
        // AXReplay uses this synthetic value to answer bounded parameterized queries; these tests never open Word.
        "AXValue": .string(text), "AXNumberOfCharacters": .number(Double(characters ?? text.utf16.count)),
    ])
}

private func wordPageFixture() -> AXFixture {
    let first = "0123456789\nAAAAA\nold page line\nend"
    let second = "tiny\nB1\nnew document row\nend"
    return .init(app: "Word public samples", bundle: "test.word.pages", recorded: "", root: 1, application: nil, focus: nil, nodes: [
        .init(id: 1, attrs: ["AXRole": .string("AXWindow"), "AXChildren": .elements([11, 12])]),
        .init(id: 2, attrs: ["AXRole": .string("AXWindow"), "AXChildren": .elements([21, 22])]),
        wordPageNode(11, window: 1, start: 0, length: 10, text: first, shared: [11, 12]),
        wordPageNode(12, window: 1, start: 11, length: first.utf16.count - 11, text: first, shared: [11, 12]),
        wordPageNode(21, window: 2, start: 0, length: 7, text: second, shared: [21, 22]),
        wordPageNode(22, window: 2, start: 8, length: second.utf16.count - 8, text: second, shared: [21, 22]),
    ])
}

func wordPageReadingTests() {
    func module() -> AppModule? {
        BuiltInModules.register()
        return AppModuleHandler.shared.moduleType(for: "com.microsoft.Word")?.init(pid: AXReplay.floor, bundleIdentifier: "com.microsoft.Word", appName: "Word")
    }
    func info(_ id: Int, module: AppModule, at offset: Int) -> TextInfo? {
        let element = AXReplay.element(id)
        guard let overlay = module.objectClass(for: element, role: .editableText, subrole: nil)?.init(element: element) else {
            Harness.fail("Word selected its page overlay"); return nil
        }
        expect(overlay.role, .document)
        let object = WordPageReadingObject(element: element, module: module, provider: overlay.textInfoClass)
        return object.textInfoClass.init(obj: object, start: offset, end: offset)
    }
    func line(_ info: TextInfo, at offset: Int) -> [Int]? { info.lineOffsets(offset).map { [$0.0, $0.1] } }
    func range(_ text: String, in value: String) -> [Int] {
        let r = (value as NSString).range(of: text); return [r.location, r.location + r.length]
    }

    test("Word pages: current-page line reading does not map hundreds of other pages") {
        let text = "Public first line\nPublic second line\n"
        let shared = [11] + Array(1000..<1200)
        var fixture = wordPageFixture()
        fixture.nodes[2] = wordPageNode(11, window: 1, start: 0, length: text.utf16.count, text: text, shared: shared)
        for id in 1000..<1200 { fixture.nodes.append(wordPageNode(id, window: 1, start: id, length: 1, text: text, shared: shared)) }
        AXReplay.load(fixture); defer { AXReplay.unload() }
        guard let module = module(), let textInfo = info(11, module: module, at: 3) else { return Harness.fail("Word text provider") }
        defer { module.terminate() }
        let before = AXStats.calls
        expect(line(textInfo, at: 3), range("Public first line\n", in: text))
        check(AXStats.calls - before < 20, "current-page read stays bounded independently of the shared page count")
        check(AXReplay.actions.isEmpty && AXReplay.sets.isEmpty, "reading did not move or edit Word")
    }
    test("Word pages: a cached map from another document cannot choose its line") {
        AXReplay.load(wordPageFixture()); defer { AXReplay.unload() }
        guard let module = module(), let a = info(11, module: module, at: 20), let b = info(21, module: module, at: 20) else { return Harness.fail("Word text providers") }
        defer { module.terminate() }
        expect(line(a, at: 20), range("old page line\n", in: "0123456789\nAAAAA\nold page line\nend"))
        expect(line(b, at: 20), range("new document row\n", in: "tiny\nB1\nnew document row\nend"), "same offsets belong to the second document's page")
    }
    test("Word pages: reflow onto the nearby page ignores an old cached page") {
        var fixture = wordPageFixture()
        AXReplay.load(fixture); defer { AXReplay.unload() }
        guard let module = module(), let textInfo = info(11, module: module, at: 20) else { return Harness.fail("Word text provider") }
        defer { module.terminate() }
        check(line(textInfo, at: 20) != nil, "seeded the old cross-page map")
        let text = "Expanded current page line\nNext page\n"
        fixture.nodes[2] = wordPageNode(11, window: 1, start: 0, length: 25, text: text, shared: [11, 12])
        // Word's wrong-page query returns that page's last line. A short replay backing value models that reply.
        fixture.nodes[3] = wordPageNode(12, window: 1, start: 26, length: 10, text: "old\npage", shared: [11, 12], characters: text.utf16.count)
        AXReplay.load(fixture)
        expect(line(textInfo, at: 20), range("Expanded current page line\n", in: text))
    }
    test("Word pages: live cached bounds are checked before a cross-page read") {
        var fixture = wordPageFixture()
        AXReplay.load(fixture); defer { AXReplay.unload() }
        guard let module = module(), let textInfo = info(11, module: module, at: 20) else { return Harness.fail("Word text provider") }
        defer { module.terminate() }
        check(line(textInfo, at: 20) != nil, "seeded the original cached candidate")
        let text = "short page\nReplacement page row\nend"
        fixture.nodes[2] = wordPageNode(11, window: 1, start: 0, length: 10, text: text, shared: [11, 12, 13])
        fixture.nodes[3] = wordPageNode(12, window: 1, start: 40, length: 2, text: "old\npage", shared: [11, 12, 13], characters: text.utf16.count)
        fixture.nodes.append(wordPageNode(13, window: 1, start: 11, length: text.utf16.count - 11, text: text, shared: [11, 12, 13]))
        AXReplay.load(fixture)
        expect(line(textInfo, at: 20), range("Replacement page row\n", in: text), "moved old candidate is refused and current shared pages are remapped")
    }
    test("Word pages: a provider line outside the requested position is refused") {
        var fixture = wordPageFixture()
        fixture.nodes[2] = wordPageNode(11, window: 1, start: 0, length: 40, text: "old\npage", shared: [11], characters: 40)
        AXReplay.load(fixture); defer { AXReplay.unload() }
        guard let module = module(), let textInfo = info(11, module: module, at: 20) else { return Harness.fail("Word text provider") }
        defer { module.terminate() }
        check(line(textInfo, at: 20) == nil, "wrong page's last line must not become a visual line for this position")
    }
    test("Word pages: malformed shared ranges do not overflow page mapping") {
        var fixture = wordPageFixture()
        let text = "Public line\n"
        fixture.nodes[2] = wordPageNode(11, window: 1, start: Int.max - 4, length: 16, text: text, shared: [11, 12])
        fixture.nodes[3] = wordPageNode(12, window: 1, start: -1, length: 20, text: text, shared: [11, 12])
        AXReplay.load(fixture); defer { AXReplay.unload() }
        guard let module = module(), let textInfo = info(11, module: module, at: 3) else { return Harness.fail("Word text provider") }
        defer { module.terminate() }
        expect(line(textInfo, at: 3), range(text, in: text), "usable direct line query remains a fallback when no shared range is valid")
    }
    test("Word pages: empty paragraphs and final paragraph marks keep their existing lines") {
        let text = "alpha\n\nomega\n"
        var fixture = wordPageFixture()
        fixture.nodes[2] = wordPageNode(11, window: 1, start: 0, length: text.utf16.count, text: text, shared: [11])
        AXReplay.load(fixture); defer { AXReplay.unload() }
        guard let module = module(), let textInfo = info(11, module: module, at: 6) else { return Harness.fail("Word text provider") }
        defer { module.terminate() }
        expect(line(textInfo, at: 6), [6, 7])
        expect(line(textInfo, at: text.utf16.count), [text.utf16.count, text.utf16.count])
    }
}
