// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

func ulyssesFormattingTests() {
    func state(_ text: String, _ range: NSRange, _ kind: FormattingFeedback.Kind = .bold,
               complete: Bool = true) -> FormattingFeedback.State {
        UlyssesFormattingSyntax.state(in: text, selection: range, kind: kind, isCompleteParagraph: complete)
    }
    func caret(_ text: String, _ kind: FormattingFeedback.Kind = .bold) -> FormattingFeedback.State {
        state(text, NSRange(location: text.utf16.count, length: 0), kind)
    }
    test("Ulysses formatting: observed empty and end caret markers report on then off") {
        expect(caret(""), .off)
        expect(caret("**"), .on)
        expect(caret("_", .italic), .on)
        expect(caret("Public sample. **"), .on)
        expect(caret("Public sample. _", .italic), .on)
        expect(caret("Public sample. "), .off)
        expect(caret("Public sample. ", .italic), .off)
        expect(caret("**", .italic), .off)
    }
    test("Ulysses formatting: midpoint opening spans continue right and support intraword markers") {
        expect(state("sampl_e public text", NSRange(location: 6, length: 0), .italic), .on)
        expect(state("sampl**e public text", NSRange(location: 7, length: 0)), .on)
        expect(state("sampl_e public text", NSRange(location: 3, length: 0), .italic), .off)
        expect(caret("**unclosed"), .on)
        expect(state("word_inside_word", NSRange(location: 5, length: 6), .italic), .on)
        expect(caret("word_inside_word", .italic), .off)
    }
    test("Ulysses formatting: native markers style spaces and a caret can exit an existing closer") {
        let italic = "TurnOver_ formatting sample"
        expect(state(italic, NSRange(location: 8, length: 0), .italic), .off)
        expect(state(italic, NSRange(location: 9, length: 0), .italic), .on, "opening before a space styles that space")
        expect(state(italic, NSRange(location: 9, length: 1), .italic), .on)
        let bold = "TurnOver formatting sample** sample **"
        expect(state(bold, NSRange(location: 28, length: 0)), .on, "leading space follows the opening marker")
        expect(state(bold, NSRange(location: 28, length: 8)), .on, "both surrounding spaces remain styled")
        expect(state(bold, NSRange(location: 36, length: 0)), .on, "caret before the existing closing marker")
        expect(state(bold, NSRange(location: 38, length: 0)), .off, "shortcut moved the caret beyond the closer")
        expect(caret(bold + "x"), .off, "typing after the closing marker stays plain")
        expect(caret("** spaced**"), .off)
        expect(caret("**space **"), .off)
    }
    test("Ulysses formatting: selected interior and closed delimiters have distinct states") {
        expect(state("**sample**", NSRange(location: 2, length: 6)), .on)
        expect(state("_sample_", NSRange(location: 1, length: 6), .italic), .on)
        expect(state("**sample**", NSRange(location: 0, length: 0)), .off)
        expect(state("**sample**", NSRange(location: 2, length: 0)), .on)
        expect(state("**sample**", NSRange(location: 8, length: 0)), .on)
        expect(caret("**sample**"), .off)
        expect(caret("_sample_", .italic), .off)
        expect(state("**sample**", NSRange(location: 0, length: 10)), .on)
    }
    test("Ulysses formatting: balanced nested styles and mixed selections remain separate") {
        let nested = "**bold _both_ bold**"
        let both = (nested as NSString).range(of: "both")
        expect(state(nested, both), .on)
        expect(state(nested, both, .italic), .on)
        expect(state(nested, NSRange(location: 2, length: nested.utf16.count - 4)), .on)
        expect(state(nested, NSRange(location: 2, length: nested.utf16.count - 4), .italic), .mixed)
        let tight = "**_sample_**"
        expect(state(tight, NSRange(location: 3, length: 6)), .on, "a shortcut can retain existing bold")
        expect(state(tight, NSRange(location: 3, length: 6), .italic), .on)
        let reverse = "_italic **both** italic_"
        expect(state(reverse, (reverse as NSString).range(of: "both")), .on)
        expect(state(reverse, (reverse as NSString).range(of: "both"), .italic), .on)
        let mixed = "plain **bold**"
        expect(state(mixed, NSRange(location: 0, length: mixed.utf16.count)), .mixed)
    }
    test("Ulysses formatting: escaped delimiters are literal and UTF16 ranges are preserved") {
        let escaped = #"\_plain\_"#
        expect(state(escaped, NSRange(location: 0, length: escaped.utf16.count), .italic), .off)
        let escapedBold = #"\*\*plain\*\*"#
        expect(state(escapedBold, NSRange(location: 0, length: escapedBold.utf16.count)), .off)
        let bold = #"**a \_literal\_ word**"#
        expect(state(bold, (bold as NSString).range(of: "literal")), .on)
        expect(state(bold, (bold as NSString).range(of: "literal"), .italic), .off)
        let unicode = "**😀 café**"
        expect(state(unicode, NSRange(location: 2, length: 7)), .on)
        expect(state(unicode, NSRange(location: 3, length: 0)), .unknown)
    }
    test("Ulysses formatting: ambiguous and unsupported markup never becomes off") {
        for text in ["*alternate*", "__alternate__", "***combined***",
                     "**cross _spans**_", "`**code**`", "[link](target)",
                     "++comment++", "%%comment%%", "~~deleted~~", "    **code**", "sample\\"] {
            expect(caret(text), .unknown, text)
        }
        expect(state("**sample**", NSRange(location: 1, length: 0)), .unknown)
        expect(state("**sample**", NSRange(location: 0, length: 2)), .unknown)
        expect(state("**", NSRange(location: 0, length: 2)), .unknown)
    }
    test("Ulysses formatting: partial oversized multi-paragraph and invalid ranges are unknown") {
        expect(state("plain", NSRange(location: 5, length: 0), complete: false), .unknown)
        expect(caret(String(repeating: "a", count: UlyssesFormattingSyntax.maximumLength + 1)), .unknown)
        expect(caret("plain\n**sample**"), .unknown)
        expect(state("plain", NSRange(location: 6, length: 0)), .unknown)
        expect(state("plain", NSRange(location: 0, length: Int.max)), .unknown)
        expect(state("plain", NSRange(location: -1, length: 0)), .unknown)
    }
}
