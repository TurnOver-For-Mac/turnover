// SPDX-License-Identifier: GPL-3.0-or-later
// Browse mode (NVDA: browseMode.BrowseModeDocumentTreeInterceptor + cursorManager).
//
// In a web document the reader owns a virtual caret: arrows read by line, word
// and character without the page seeing the keys; single letters jump to the
// next heading, link, button, list…; Enter activates what the caret is on. A
// focusable control that gains focus (an edit field) switches to focus mode,
// where keys pass through again; Caps+Space switches by hand; Escape returns.
//
// A browse mode document is a tree interceptor: it answers scripts and sees
// events for every object inside its web area, before the object itself.
import Foundation
import ApplicationServices
import AppKit
import TurnOverAX

// Browse mode: selecting and copying text (NVDA: Shift with the movement keys).
extension BrowseModeDocument {
    // MARK: Selection (NVDA: Shift with the movement keys selects in browse mode; Command+C copies it)

    public var selectedRange: (Int, Int)? {
        guard let a = selectionAnchor, a != position else { return nil }
        return (min(a, position), max(a, position))
    }

    func text(_ lo: Int, _ hi: Int) -> String {
        let n = buffer.text.length
        let a = max(0, min(lo, n)), b = max(a, min(hi, n))
        return buffer.text.substring(with: NSRange(location: a, length: b - a))
    }

    /// Extend the selection by a unit (or to a place), and say what was selected or unselected.
    func select(_ unit: TextUnit?, _ direction: Int, to target: Int? = nil) {
        refreshIfNavigated()
        let anchor = selectionAnchor ?? position
        let old = position
        var new = old
        if let target { new = max(0, min(target, buffer.text.length)) }
        else if let unit, let info = caretInfo() {
            if info.move(unit, direction) == 0 {
                // At the end, a line selection takes the rest of the last line.
                if unit == .line, direction > 0 { new = buffer.text.length } else { Tones.edge(); return }
            } else { new = info.start }
        }
        guard new != old else { Tones.edge(); return }
        selectionAnchor = anchor
        position = new
        let changed = text(min(old, new), max(old, new))
        let growing = (new - anchor).signum() == (old - anchor).signum() || old == anchor ? abs(new - anchor) > abs(old - anchor) : false
        let said = changed.trimmingCharacters(in: .whitespacesAndNewlines)
        let spoken = said.isEmpty ? (changed.contains("\n") ? Symbols.name(of: "\u{2028}") : Symbols.name(of: " ")) : (said.count == 1 ? Symbols.name(of: said.first!) : said)
        Speech.speakText(growing ? String(localized: "\(spoken), selected", comment: "Text selected in browse mode: %@ is the text") : String(localized: "\(spoken), unselected", comment: "Text no longer selected in browse mode: %@ is the text"))
    }

    func clearSelection() { selectionAnchor = nil }

    func copySelection(_ g: KeyboardGesture) {
        guard let (lo, hi) = selectedRange else { g.send(); return }   // nothing selected here: the app's own copy
        let t = text(lo, hi)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
        Log.io("browse mode: copied \(t.count) characters")
        Speech.speakMessage(String(localized: "copied", comment: "Spoken message"), remember: false)
    }

    func edgeOfLine(start: Bool) {
        clearSelection()
        guard let info = caretInfo() else { return }
        info.expand(.line)
        position = start ? info.start : max(info.start, info.end - 1)
        speakUnit(.character)
    }

}
