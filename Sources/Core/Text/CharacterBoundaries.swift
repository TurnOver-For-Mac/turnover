// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Extended grapheme ranges use the same UTF-16 positions as accessibility.
public enum CharacterBoundaries {
    public static let maximumContextLength = 4096

    /// Already-cached text needs no accessibility reads or artificial context edges.
    public static func offsets(in text: NSString, at offset: Int) -> (Int, Int)? {
        guard offset >= 0, offset < text.length else { return nil }
        return offsets(in: text as String, at: offset)
    }

    private static func offsets(in text: String, at offset: Int) -> (Int, Int) {
        // Swift accepts indices interchanged from UTF-16 and rounds an interior position
        // down to its Character before advancing. Recover the start from that exact end.
        // Unlike NSString's composed sequences this also joins CR LF and Unicode Prepend
        // (regressions observed on macOS, 28 Oct 2026, #159). No whole-string character walk.
        let position = String.Index(utf16Offset: offset, in: text)
        let end = text.index(after: position)
        let start = text.index(before: end)
        return (start.utf16Offset(in: text), end.utf16Offset(in: text))
    }

    /// Grow context only when a complete range cannot yet be established. A missing or changed
    /// slice is no answer; in particular, never replace it with a one-code-unit character.
    public static func offsets(at offset: Int, length: Int, read: (Int, Int) -> String) -> (Int, Int)? {
        guard offset >= 0, offset < length else { return nil }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(50))
        var radius = 16
        while radius <= maximumContextLength / 2 {
            let lower = max(0, offset - radius)
            let upper = offset + min(radius, length - offset)
            let text = read(lower, upper) as NSString
            guard text.length == upper - lower, ContinuousClock.now < deadline else { return nil }

            // A slice may start inside a ZWJ/combining sequence or a run of flag indicators.
            // Start at a complete base, excluding RI (whose pairing needs the entire preceding
            // run) and emoji modifiers. Its first cluster may attach to the omitted prefix, so
            // only subsequent clusters have a proven start. Swift still does segmentation.
            // The fixed-window family-emoji reproduction is recorded in #159, 28 Oct 2026.
            var anchor: Int? = lower == 0 ? 0 : nil
            if anchor == nil {
                var index = 0
                for scalar in (text as String).unicodeScalars {
                    if index >= offset - lower { break }
                    if index > 0, scalar.properties.isGraphemeBase,
                       !scalar.properties.isEmojiModifier, !(0x1F1E6...0x1F1FF).contains(scalar.value) {
                        anchor = index
                        break
                    }
                    index += scalar.utf16.count
                }
            }
            if let anchor {
                let context = text.substring(from: anchor)
                let local = offset - lower - anchor
                let firstEnd = context.index(after: context.startIndex).utf16Offset(in: context)
                let r = offsets(in: context, at: local)
                let startsInsideContext = lower == 0 || r.0 >= firstEnd
                // Three following units include a complete scalar even if the final unit is
                // half a surrogate pair repaired to U+FFFD by the String bridge. Otherwise an
                // unseen supplementary combining mark could make this end a false boundary.
                let endsInsideContext = upper == length || r.1 <= context.utf16.count - 3
                if startsInsideContext, endsInsideContext {
                    return (lower + anchor + r.0, lower + anchor + r.1)
                }
            }
            radius *= 2
        }
        return nil
    }
}
