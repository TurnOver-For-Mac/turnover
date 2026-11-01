// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The small, verified subset of Ulysses' built-in Markdown XL used by its formatting shortcuts.
/// On 1 Nov 2026, Strong wrapped selections in ** and Emphasis in _; at an empty/end caret each
/// inserted an opening marker, and a second shortcut removed it. The same markers also opened a span
/// inside a word through the rest of the paragraph. Ulysses 42 (84473), macOS 27.2 also styled
/// following spaces and accepted a closing marker after trailing spaces. This is not a general Markdown parser.
/// The provider must verify the active markup and supply the entire paragraph without its terminator.
/// Unsupported/ambiguous syntax stays unknown rather than reporting an invented off state.
nonisolated package enum UlyssesFormattingSyntax {
    package static let maximumLength = 8192

    package static func state(in paragraph: String, selection: NSRange, kind: FormattingFeedback.Kind,
                              isCompleteParagraph: Bool) -> FormattingFeedback.State {
        guard isCompleteParagraph else { return .unknown }
        let text = Array(paragraph.utf16.prefix(maximumLength + 1)), n = text.count
        guard n <= maximumLength, selection.location >= 0, selection.length >= 0,
              selection.location <= n, selection.length <= n - selection.location,
              !text.contains(where: { [10, 13, 0x2028, 0x2029].contains($0) }),
              !paragraph.hasPrefix("    "), !paragraph.hasPrefix("\t") else { return .unknown }
        let end = selection.location + selection.length, wanted = kind == .bold ? 1 : 2
        // Positions inside delimiter/escape tokens have no established insertion semantics. Content masks
        // omit the syntax itself so a selection spanning marked and plain words can be reported as mixed.
        var positions = [Int?](repeating: nil, count: n + 1)
        var content = [Int?](repeating: nil, count: n)
        var stack: [Int] = [], active = 0, i = 0
        positions[0] = 0
        func splitsSurrogate(_ offset: Int) -> Bool {
            offset > 0 && offset < n && (0xD800...0xDBFF).contains(text[offset - 1])
                && (0xDC00...0xDFFF).contains(text[offset])
        }
        guard !splitsSurrogate(selection.location), !splitsSurrogate(end) else { return .unknown }
        while i < n {
            let unit = text[i]
            if unit == 92 { // An escaped punctuation character is literal, never a formatting marker.
                guard i + 1 < n, let scalar = UnicodeScalar(text[i + 1]),
                      CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar)
                else { return .unknown }
                content[i + 1] = active
                i += 2; positions[i] = active
                continue
            }
            // Links/images, code, annotations/comments and other markup have different parsing rules.
            if [91, 93, 96, 60, 62, 123, 125].contains(unit)
                || (i + 1 < n && unit == text[i + 1] && [37, 43, 45, 126, 124, 36].contains(unit)) {
                return .unknown
            }
            if unit == 42 || unit == 95 {
                var limit = i + 1
                while limit < n && text[limit] == unit { limit += 1 }
                let count = limit - i
                // * and __ alternatives, runs such as ***, and custom schemes are not verified.
                guard (unit == 42 && count == 2) || (unit == 95 && count == 1) else { return .unknown }
                let bit = unit == 42 ? 1 : 2
                if stack.last == bit {
                    stack.removeLast(); active &= ~bit
                } else {
                    // Crossing spans are ambiguous. The live midpoint shortcut check established
                    // intraword markers in Ulysses (1 Nov 2026).
                    guard active & bit == 0 else { return .unknown }
                    stack.append(bit); active |= bit
                }
                i = limit; positions[i] = active
            } else {
                content[i] = active
                i += 1; positions[i] = active
            }
        }
        // An opening marker without a closer continues to the end of this complete paragraph.
        // The midpoint probe confirmed the following character's rendered trait after each shortcut.
        guard let startState = positions[selection.location], positions[end] != nil else { return .unknown }
        if selection.length == 0 { return startState & wanted == 0 ? .off : .on }
        var sawOn = false, sawOff = false
        for index in selection.location..<end {
            guard let state = content[index] else { continue }
            if state & wanted == 0 { sawOff = true } else { sawOn = true }
        }
        if sawOn && sawOff { return .mixed }
        if sawOn { return .on }
        return sawOff ? .off : .unknown
    }
}
