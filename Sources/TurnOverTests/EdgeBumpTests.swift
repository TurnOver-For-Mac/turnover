// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

func edgeBumpTests() {
    test("edge bump: right-to-left text is told from left-to-right, so only the latter bumps at once at an edge") {
        check(!EditableText.hasRightToLeft("Hello, world 123"), "English")
        check(EditableText.hasRightToLeft("שלום"), "Hebrew")
        check(EditableText.hasRightToLeft("hello مرحبا"), "Arabic in a line of English")
        check(!EditableText.hasRightToLeft(""), "nothing")
    }
    test("edge bump: Left and Right bump at once only when the caret and its line both reach the edge") {
        func edge(_ key: String, caret: Int, lineStart: Int = 0, lineEnd: Int = 10, length: Int = 10, empty: Bool = false) -> Bool {
            EditableText.sidewaysEdge(key: key, caret: caret, lineStart: lineStart, lineEnd: lineEnd, length: length, fieldIsEmpty: empty)
        }
        check(edge("leftArrow", caret: 0), "Left at the start")
        check(!edge("leftArrow", caret: 0, lineStart: 4), "an app that reports caret 0 while the line starts later")
        check(!edge("leftArrow", caret: 3), "Left in the middle")
        check(edge("rightArrow", caret: 10), "Right at the end")
        check(!edge("rightArrow", caret: 10, lineEnd: 6), "Right when the line ends before the end")
        check(!edge("rightArrow", caret: 0, lineEnd: 0, length: 0), "length 0 not confirmed by the field")
        check(edge("rightArrow", caret: 0, lineEnd: 0, length: 0, empty: true), "an empty field")
        check(!edge("upArrow", caret: 0), "other keys are not sideways")
    }
}
