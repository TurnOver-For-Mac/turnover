// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

func feedbackPrivacyTests() {
    test("privacy: old delayed and passed typing is removed without losing timings or commands") {
        let log = """
        [  1.000] WARN keyboard: the main thread is not beating; kb:a goes through
        [  1.001] WARN keyboard: kb:option+shift+b answered after 211 ms: sent on to the application now
        [  1.002] IO input kb:numpad1 passed through
        [  1.003] IO input kb:shift+c
        [  1.004] WARN keyboard: kb:key999 answered after 212 ms: sent on to the application now
        [  1.005] IO input kb:turnover+t → vo_title
        [  1.006] IO input kb:h → browse_heading
        [  1.007] WARN keyboard: kb:leftArrow answered after 213 ms: its script runs now
        """
        let redacted = Feedback.redact(log)
        for key in ["kb:a", "kb:option+shift+b", "kb:numpad1", "kb:shift+c", "kb:key999"] {
            check(!redacted.contains(key), "typed identifier removed: \(key)")
        }
        check(redacted.contains("kb:[a key] answered after 211 ms"), "late timing retained")
        check(redacted.contains("kb:[a key] goes through"), "watchdog decision retained")
        check(redacted.contains("kb:[a key] passed through"), "pass-through decision retained")
        check(redacted.contains("kb:turnover+t → vo_title"), "modified command retained")
        check(redacted.contains("kb:h → browse_heading"), "known browse command retained")
        check(redacted.contains("kb:leftArrow answered after 213 ms"), "navigation diagnostic retained")
    }

    test("privacy: old braille input reports are removed from diagnostic logs") {
        let log = """
        [  2.000] IO braille input: space pressed after dots 123 while typing; typed as the cell, then a space
        [  2.001] IO braille input: no command for space with dots [2, 3, 4, 6]; typed as the cell, then a space
        [  2.002] braille: Example Display report 24 3f 00
        [  2.003] braille: Example Display report 33 01 2a 00
        [  2.004] braille: Example Display report command 0x24, 3 bytes
        [  2.005] braille: 40 cells
        [  2.006] IO braille: no command for dot1+dot2+thumb2
        [  2.007] IO braille key key("dot3+thumb2")
        """
        let redacted = Feedback.redact(log)
        for privateText in ["dots 123", "[2, 3, 4, 6]", "24 3f 00", "33 01 2a 00", "dot1+dot2", "dot3+thumb2"] {
            check(!redacted.contains(privateText), "input removed: \(privateText)")
        }
        check(redacted.contains("report [input omitted]"), "old report identified")
        check(redacted.contains("report command 0x24, 3 bytes"), "safe report metadata retained")
        check(redacted.contains("braille: 40 cells"), "display size retained")
    }

    test("privacy: old helper titles and multiline errors are removed from diagnostic logs") {
        let log = """
        [  3.000] steam speech: Steam: attached to PRIVATE_TITLE
        [  3.001] steam speech: observer in PRIVATE_PAGE: PRIVATE_ELEMENT
        [  3.002] steam speech (errors): PRIVATE_ERROR
        PRIVATE_CONTINUATION
        [  3.003] trackpad-gestures: PRIVATE_HELPER
        [  3.004] trackpad-gestures (errors): PRIVATE_OTHER_ERROR
        [  3.005] IO games (Steam, PRIVATE_GAME_TITLE): [24 characters]
        [  3.006] WARN games: couldn't reach the Steam program: PRIVATE_EXCEPTION
        [  3.007] IO event gainFocus: AXButton
        """
        let redacted = Feedback.redact(log)
        check(!redacted.contains("PRIVATE_"), "helper content removed")
        check(redacted.contains("steam speech:"), "helper identity retained")
        check(redacted.contains("event gainFocus: AXButton"), "following event survives multiline redaction")
    }

    test("privacy: diagnostic logs omit old speech as well as typed keys and braille cells") {
        let log = """
        [  4.000] IO say: Public example sentence
        [  4.001] typed word: PRIVATE_TYPED_WORD
        [  4.002] IO event typedCharacter PRIVATE_TYPED_CHARACTER
        [  4.003] IO braille input: dots 145
        """
        let redacted = Feedback.redact(log)
        check(!redacted.contains("Public example sentence"), "old speech cannot smuggle unmarked braille typing into a report")
        check(!redacted.contains("PRIVATE_") && !redacted.contains("dots 145"), "typing private by default")
    }

    test("privacy: multiline speech and quoted fields stay redacted until the next record") {
        let log = """
        [  5.000] IO say: PRIVATE_FIRST_LINE
        PRIVATE_SECOND_LINE
        [  5.001] IO event gainFocus: AXTextArea "PRIVATE_FIELD_LINE
        PRIVATE_FIELD_CONTINUATION"
        [  5.002] IO braille input: PRIVATE_INPUT_LINE
        PRIVATE_INPUT_CONTINUATION
        [  5.003] IO event valueChange: AXSlider
        """
        let redacted = Feedback.redact(log)
        check(!redacted.contains("PRIVATE_"), "all lines of sensitive values are removed")
        check(redacted.contains("event gainFocus: AXTextArea"), "field type retained")
        check(redacted.contains("event valueChange: AXSlider"), "next record retained")
    }

    test("privacy: embedded quotes cannot expose the middle or continuation of a field name") {
        let log = """
        [  6.000] IO event gainFocus: AXTextArea "My "PRIVATE_TOKEN" notes"
        [  6.001] IO event gainFocus: AXTextArea "My "PRIVATE_FIRST_LINE
        PRIVATE_CONTINUATION" notes"
        [  6.002] IO event valueChange: AXSlider
        """
        let redacted = Feedback.redact(log)
        check(!redacted.contains("PRIVATE_"), "embedded quotes and following lines cannot escape redaction")
        check(redacted.contains("event gainFocus: AXTextArea"), "event and role remain useful")
        check(redacted.contains("event valueChange: AXSlider"), "following record retained")
    }
}
