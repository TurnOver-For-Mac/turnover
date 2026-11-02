// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import AppKit

extension WordDocument {
    /// Word marks misspellings in the text it gives accessibility (AXMarkedMisspelled): the next or previous one on
    /// this page, the caret at its start. (The AppleScript search found the word it was on again.)
    /// Where Word's whole-document search should start when the laid-out pages have no misspelling beyond the caret:
    /// after the marked word the caret is on, or Word finds that word again.
    private func goToMisspelling(forward: Bool) -> Bool {
        misspellingSearchFrom = nil
        guard let info = try? makeTextInfo(.caret) as? AXTextInfo else { return false }
        let el = info.textElement
        let n = info.storyLength()
        if n == 0 { Tones.edge(); Speech.speakMessage(forward ? String(localized: "no next spelling error", comment: "Spoken message") : String(localized: "no previous spelling error", comment: "Spoken message")); return true }   // nothing to search: answered without Word's script (it errored -1728 each press)
        guard n > 0, let a = el.param(kAXAttributedStringForRangeParameterizedAttribute, axRangeValue(0, min(n, 50_000))) as? NSAttributedString else { return false }
        var words: [NSRange] = []
        let ns = a.string as NSString
        a.enumerateAttribute(NSAttributedString.Key("AXMarkedMisspelled"), in: NSRange(location: 0, length: a.length)) { val, range, _ in
            guard (val as? NSNumber)?.boolValue == true else { return }
            // Word marks the word and sometimes the space after it: the word.
            var r = range
            while r.length > 0, let c = ns.substring(with: NSRange(location: NSMaxRange(r) - 1, length: 1)).first, c.isWhitespace || c.isPunctuation { r.length -= 1 }
            if r.length > 0 { words.append(r) }
        }
        let caret = info.start
        let target = forward ? words.first { $0.location > caret } : words.last { $0.location < caret }
        guard let r = target else {
            // Word lays out only the pages near the view, so "none beyond the caret here" is not "none in the
            // document": the whole-document search runs. (It never did while any misspelling was on these pages,
            // and errors on page 7 of 21 went unfound, 's tester, 5 Oct 2026.)
            if forward, let here = words.first(where: { NSLocationInRange(caret, $0) }) { misspellingSearchFrom = NSMaxRange(here) }
            return false
        }
        info.setCaretOffset(r.location)
        initAutoSelectDetection()
        Speech.speakMessage(String(localized: "\(ns.substring(with: r)), misspelled", comment: "A misspelled word reached: %@ is the word"))
        return true
    }


    func goToSpellingError(forward: Bool) {
        if goToMisspelling(forward: forward) { return }
        guard let s = module?.script else { Log.io("Word: no script bridge for the spelling move"); Tones.edge(); Speech.speakMessage(forward ? String(localized: "no next spelling error", comment: "Spoken message") : String(localized: "no previous spelling error", comment: "Spoken message")); return }
        scripted(forward ? String(localized: "no next spelling error", comment: "Spoken message") : String(localized: "no previous spelling error", comment: "Spoken message")) { done in
            s.nextSpellingError(forward: forward, from: self.misspellingSearchFrom) { done($0.map { String(localized: "\($0), misspelled", comment: "A misspelled word reached: %@ is the word") }) }
        }
    }
}
