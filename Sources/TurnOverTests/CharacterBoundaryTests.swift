// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore
import AXFixtures

private final class BoundaryTextInfo: TextInfo {
    var source = "" as NSString
    var reads: [NSRange] = []
    var unavailable = false
    var visibleRange: NSRange?
    var selection: (Int, Int)?
    var hasBoundedLength = true
    var lengthReads = 0

    override func storyLength() -> Int { lengthReads += 1; return source.length }
    override func characterStoryLength() -> Int? { hasBoundedLength ? source.length : nil }
    override func characterTextRange(_ s: Int, _ e: Int) -> String {
        let range = NSRange(location: s, length: e - s)
        reads.append(range)
        guard !unavailable else { return "" }
        if let visibleRange, NSIntersectionRange(range, visibleRange) != range { return "" }
        return source.substring(with: range)
    }
    override func textRange(_ s: Int, _ e: Int) -> String {
        source.substring(with: NSRange(location: s, length: e - s))
            .replacingOccurrences(of: "\u{FFFC}", with: "attachment name")
    }
    override func setSelectionOffsets(_ s: Int, _ e: Int) { selection = (s, e) }
}

func characterBoundaryTests() {
    // The replay element holds no text. Every text read below comes from public sample strings.
    func info(_ text: String, at offset: Int = 0) -> BoundaryTextInfo {
        let i = BoundaryTextInfo(obj: TurnOverObject(element: AXReplay.element(99_900)), start: offset, end: offset)
        i.source = text as NSString
        return i
    }
    func ranges(_ text: String) -> [NSRange] {
        var offset = 0
        return text.map { character in
            let length = String(character).utf16.count
            defer { offset += length }
            return NSRange(location: offset, length: length)
        }
    }
    func checkRange(_ got: (Int, Int)?, _ expected: NSRange, _ message: String) {
        check(got?.0 == expected.location && got?.1 == NSMaxRange(expected),
              "\(message): got \(String(describing: got)), wanted \(expected)")
    }
    func scalarContext(_ text: String) -> String {
        text.unicodeScalars.map { "U+" + String($0.value, radix: 16, uppercase: true) }.joined(separator: " ")
    }

    test("characters: cached and ranged providers keep entire Unicode graphemes at every UTF-16 position") {
        let samples = ["A👨‍👩‍👧‍👦X", "A👩🏽‍💻X", "Ae\u{301}\u{323}X", "A𝄞X", "A🇬🇧🇫🇷X",
                       "Aक्‍षX", "A각X", "A\r\nX", "A\u{0600}بX"]
        for text in samples {
            let i = info(text)
            let context = scalarContext(text)
            for range in ranges(text) {
                for offset in range.location..<NSMaxRange(range) {
                    checkRange(i.characterOffsets(offset), range, "ranged position \(offset) in \(context)")
                    checkRange(CharacterBoundaries.offsets(in: i.source, at: offset), range, "cached position \(offset) in \(context)")
                }
            }
        }
    }
    test("characters: cropped ZWJ, combining and flag runs expand context without changing RI parity") {
        let samples = [String(repeating: "👨‍👩‍👧‍👦", count: 8) + "X",
                       "A👩" + String(repeating: "\u{200D}👩", count: 40) + "X",
                       "Ae" + String(repeating: "\u{301}", count: 100) + "X",
                       "Ae" + String(repeating: "\u{301}", count: 14) + "\u{E0100}X",
                       String(repeating: "a", count: 33) + String(repeating: "🇦", count: 25) + "X",
                       String(repeating: "字", count: 80) + "👩🏽‍💻X"]
        for text in samples {
            let i = info(text)
            let context = scalarContext(text)
            for range in ranges(text) {
                for offset in range.location..<NSMaxRange(range) {
                    checkRange(i.characterOffsets(offset), range, "cropped position \(offset) in \(context)")
                }
            }
            check(i.reads.allSatisfy { $0.length <= CharacterBoundaries.maximumContextLength }, "each context read stays bounded")
        }
    }
    test("characters: forward, backward and selection endpoints use whole graphemes in AX UTF-16 positions") {
        let text = "A👨‍👩‍👧‍👦e\u{301}𝄞क्‍षZ"
        let expected = ranges(text)
        let i = info(text)
        expect(i.move(.character, expected.count - 1), expected.count - 1)
        expect(i.start, expected.last!.location, "forward reaches the final character")
        expect(i.move(.character, -(expected.count - 1)), -(expected.count - 1))
        expect(i.start, 0, "backward returns to the first character")
        let emoji = expected[1]
        i.start = emoji.location + 5; i.end = i.start
        i.expand(.character)
        checkRange((i.start, i.end), emoji, "expand from inside the emoji")
        i.updateSelection()
        checkRange(i.selection, emoji, "selection sent to the provider")
        i.start = emoji.location; i.end = emoji.location
        expect(i.move(.character, 1, endPoint: .end), 1)
        checkRange((i.start, i.end), emoji, "extend selection by one character")
        i.start = i.source.length; i.end = i.start
        expect(i.move(.character, -1), -1)
        expect(i.start, expected.last!.location, "back from document end")
    }
    test("characters: attachment speech expansion does not alter source positions") {
        let i = info("A\u{FFFC}👨‍👩‍👧‍👦X", at: 1)
        i.expand(.character)
        checkRange((i.start, i.end), NSRange(location: 1, length: 1), "one source placeholder")
        expect(i.text, "attachment name", "the complete attachment label remains spoken")
        expect(i.move(.character, 1), 1)
        expect(i.start, 2, "the next character begins after one source unit")
    }
    test("characters: an unavailable or offscreen slice leaves both movement directions unchanged") {
        let i = info("A👨‍👩‍👧‍👦X", at: 5)
        i.unavailable = true
        expect(i.move(.character, 1), 0)
        expect(i.start, 5)
        expect(i.move(.character, -1), 0)
        expect(i.start, 5, "backward must not use an empty range as a one-unit step")
        i.end = 8
        expect(i.move(.character, 1), 0)
        expect(i.move(.character, -1), 0)
        check(i.start == 5 && i.end == 8, "an unavailable range must not collapse an existing selection")
        i.end = i.start
        i.unavailable = false
        i.visibleRange = NSRange(location: 4, length: 4)
        i.expand(.character)
        check(i.start == 5 && i.end == 5, "partial context is not a complete character")
        let changed = CharacterBoundaries.offsets(at: 1, length: 3) { _, _ in "expanded attachment label" }
        check(changed == nil, "a slice with changed UTF-16 length is refused")
    }
    test("characters: a missing bounded length does not fetch text or move selection") {
        let i = info("A👨‍👩‍👧‍👦X", at: 5)
        i.hasBoundedLength = false
        expect(i.move(.character, 1), 0)
        expect(i.move(.character, -1), 0)
        i.expand(.character)
        check(i.start == 5 && i.end == 5, "unknown length leaves the range collapsed at its original position")
        check(i.reads.isEmpty, "no context query without a bounded length")
        expect(i.lengthReads, 0, "no unbounded story-length fallback")
    }
    test("characters: excessive context stops ranged movement while the existing full buffer remains exact") {
        let text = "e" + String(repeating: "\u{301}", count: 5000) + "X"
        let i = info(text, at: 2500)
        expect(i.move(.character, 1), 0)
        expect(i.start, 2500)
        check(i.reads.count <= 8, "at most eight context reads per query")
        check(i.reads.allSatisfy { $0.length <= CharacterBoundaries.maximumContextLength }, "no whole-document probe")
        i.reads = []
        expect(i.move(.character, -1), 0)
        expect(i.start, 2500)
        check(i.reads.count <= 8, "backward has the same read budget")
        checkRange(CharacterBoundaries.offsets(in: i.source, at: 2500), NSRange(location: 0, length: 5001), "cached long cluster")
    }
    test("characters: document edges and empty text are safe") {
        let i = info("👨‍👩‍👧‍👦")
        checkRange(i.characterOffsets(0), NSRange(location: 0, length: 11), "single character occupies eleven UTF-16 units")
        check(i.characterOffsets(-1).0 == -1 && i.characterOffsets(-1).1 == -1, "negative offset has no range")
        check(i.characterOffsets(11).0 == 11 && i.characterOffsets(11).1 == 11, "document end has no character")
        expect(i.move(.character, -1), 0)
        expect(i.move(.character, 1, endPoint: .end), 1)
        expect(i.end, 11, "selection may reach the document end")
        check(CharacterBoundaries.offsets(in: "", at: 0) == nil, "empty cached text")
        check(info("").characterOffsets(0).1 == 0, "empty ranged text")
    }
}
