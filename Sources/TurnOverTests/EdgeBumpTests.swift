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
    test("edge bump: Mail's lists say top and bottom at their ends, other apps' lists keep the bump alone (18 Nov 2026)") {
        expect(SelectableList.edgeWords(bundle: "com.apple.mail", key: "upArrow"), String(localized: "top", comment: "Spoken message"), "Mail, Up")
        expect(SelectableList.edgeWords(bundle: "com.apple.mail", key: "downArrow"), String(localized: "bottom", comment: "Spoken message"), "Mail, Down")
        check(SelectableList.edgeWords(bundle: "com.apple.notes", key: "upArrow") == nil, "another app")
        check(SelectableList.edgeWords(bundle: "com.apple.mail", key: "leftArrow") == nil, "not an up or down key")
    }
    test("browse mode: a pop-up button's list is no page; a page with an address or with more than a list is (18 Nov 2026)") {
        let options = Array(repeating: "AXStaticText", count: 31)
        check(BrowseModeHandler.isPopUpButtonsList(address: nil, children: [("AXList", options)]), "no address, one list of static text")
        check(BrowseModeHandler.isPopUpButtonsList(address: "", children: [("AXList", options)]), "an empty address")
        check(!BrowseModeHandler.isPopUpButtonsList(address: "https://www.amazon.co.uk/", children: [("AXList", options)]), "a page with an address")
        check(!BrowseModeHandler.isPopUpButtonsList(address: nil, children: [("AXList", options + ["AXLink"])]), "a list holding a link")
        check(!BrowseModeHandler.isPopUpButtonsList(address: nil, children: [("AXList", options), ("AXGroup", [])]), "more than the list")
        check(!BrowseModeHandler.isPopUpButtonsList(address: nil, children: []), "an empty web area")
        check(!BrowseModeHandler.isPopUpButtonsList(address: nil, children: [("AXList", [])]), "a list with nothing in it")
    }
}
