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
        func isList(_ address: String?, _ kids: [(String, [String])]) -> Bool {
            BrowseModeHandler.isPopUpButtonsList(address: { address }, children: { kids }, role: { $0.0 }, childRoles: { $0.1 })
        }
        check(isList(nil, [("AXList", options)]), "no address, one list of static text")
        check(isList("", [("AXList", options)]), "an empty address")
        check(!isList("https://www.amazon.co.uk/", [("AXList", options)]), "a page with an address")
        check(!isList(nil, [("AXList", options + ["AXLink"])]), "a list holding a link")
        check(!isList(nil, [("AXList", options), ("AXGroup", [])]), "more than the list")
        check(!isList(nil, []), "an empty web area")
        check(!isList(nil, [("AXList", [])]), "a list with nothing in it")
    }
    test("browse mode: the pop-up test asks nothing of the children of a page with an address or with several children (18 Nov 2026)") {
        var roleAsked = 0, grandchildrenAsked = 0, childrenAsked = 0
        func run(_ address: String?, count: Int) -> Bool {
            roleAsked = 0; grandchildrenAsked = 0; childrenAsked = 0
            return BrowseModeHandler.isPopUpButtonsList(address: { address }, children: { childrenAsked += 1; return Array(0..<count) },
                                                        role: { _ in roleAsked += 1; return "AXList" }, childRoles: { _ in grandchildrenAsked += 1; return ["AXStaticText"] })
        }
        check(!run("https://example.com/", count: 300), "a page with an address")
        check(childrenAsked == 0, "an address: the children are not asked for")
        check(!run(nil, count: 300), "300 children")
        check(roleAsked == 0 && grandchildrenAsked == 0, "several children: no role and no grandchild asked")
        check(run(nil, count: 1), "one child that is a list")
        check(roleAsked == 1 && grandchildrenAsked == 1, "one child: its role and its children's roles, once each")
    }
    test("edge bump: Up and Down are at once an edge in a web box of one character, whichever side the caret is (18 Nov 2026)") {
        check(EditableText.isOneCharacterBox(length: 1, isTextField: true, inWebContent: true, key: "downArrow"), "Down")
        check(EditableText.isOneCharacterBox(length: 1, isTextField: true, inWebContent: true, key: "upArrow"), "Up")
        check(!EditableText.isOneCharacterBox(length: 1, isTextField: true, inWebContent: true, key: "home"), "Home moves the caret")
        check(!EditableText.isOneCharacterBox(length: 2, isTextField: true, inWebContent: true, key: "downArrow"), "two characters")
        check(!EditableText.isOneCharacterBox(length: 0, isTextField: true, inWebContent: true, key: "downArrow"), "empty")
        check(!EditableText.isOneCharacterBox(length: 1, isTextField: false, inWebContent: true, key: "downArrow"), "a text area")
        check(!EditableText.isOneCharacterBox(length: 1, isTextField: true, inWebContent: false, key: "downArrow"), "not on the web")
    }
    test("edge bump: an empty field is empty whether it has an empty value or none at all (Messages, 25 Nov 2026)") {
        check(EditableText.isEmptyField(value: "", characterCount: 0), "an empty value")
        check(EditableText.isEmptyField(value: "\n", characterCount: 1), "a line break alone (Claude's empty prompt)")
        check(EditableText.isEmptyField(value: nil, characterCount: 0), "no value, no characters: Messages' empty message box")
        check(!EditableText.isEmptyField(value: nil, characterCount: 4), "no value, but characters")
        check(!EditableText.isEmptyField(value: nil, characterCount: nil), "nothing readable is not taken for empty")
        check(!EditableText.isEmptyField(value: "hi", characterCount: 2), "text")
    }
    test("speech: a text field whose whole value is one space is blank; a space inside text is still named (18 Nov 2026)") {
        check(Speech.wholeValueIsWhitespace(lineText: " ", storyLength: 1, isField: true), "a field holding one space")
        check(!Speech.wholeValueIsWhitespace(lineText: " ", storyLength: 5, isField: true), "a space that is a line of longer text")
        check(!Speech.wholeValueIsWhitespace(lineText: " ", storyLength: 1, isField: false), "not a field")
        check(!Speech.wholeValueIsWhitespace(lineText: "", storyLength: 0, isField: true), "empty is the old rule's")
        check(!Speech.wholeValueIsWhitespace(lineText: "a", storyLength: 1, isField: true), "a letter")
    }
}
