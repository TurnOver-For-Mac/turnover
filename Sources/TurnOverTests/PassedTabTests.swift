// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

/// A plain Tab that reaches a page gets the no-news check, whichever way it went (27 Nov 2026).
func passedTabTests() {
    typealias D = BrowseModeDocument
    func check_(_ tab: Bool = true, doc: Bool = false, pass: Bool = false, hidden: Bool = false, known: Bool = false, silent: Bool = false) -> D.PassedTabCheck {
        D.passedTabCheck(isPlainTab: tab, documentHasFocus: doc, passThrough: pass, hiddenFocusRecorded: hidden,
                         pageKnownInFocusProcess: known, pageSilent: silent)
    }
    test("passed Tab: which no-news check a plain Tab gets, by where the focus is (27 Nov 2026)") {
        expect(check_(doc: true), .document, "browse mode with the page's document: its own check")
        expect(check_(doc: true, pass: true), .document, "focus mode with no hidden control recorded: the document's check (it had none)")
        expect(check_(doc: true, pass: true, hidden: true), .hiddenFocus, "focus mode with a hidden control: tabInFocusMode, not a second check")
        expect(check_(doc: true, hidden: true), .document, "browse mode with a record: the document's check")
        expect(check_(known: true), .process, "no document, a page known in the process: the app is asked")
        expect(check_(), .none, "no page anywhere: nothing asked")
        expect(check_(false, doc: true), .none, "not a plain Tab (Control Tab, Command Tab)")
        expect(check_(doc: true, silent: true), .none, "a page not answering is not asked")
        expect(check_(known: true, silent: true), .none, "a known page not answering is not asked")
    }
    test("passed Tab: each step of the no-news check with no document (27 Nov 2026)") {
        func step(news: Bool = false, key: Bool = false, answered: Bool = true, same: Bool = true, elapsed: Double = 0.03) -> D.NoNewsStep {
            D.noNewsStep(newsSinceTab: news, anotherKeySince: key, answered: answered, answerIsWhereItWas: same,
                         elapsed: elapsed, interval: 0.025, ceiling: 0.35)
        }
        expect(step(news: true, same: false), .stop, "the browser posted news: nothing new is said")
        expect(step(key: true, same: false), .stop, "another key came: its own focus follows")
        expect(step(answered: false), .noAnswer, "no answer: nothing is done")
        expect(step(same: false), .present, "the focus moved with no news: presented")
        expect(step(), .askAgain, "where it was, with time left: asked again")
        expect(step(elapsed: 0.33), .reportSame, "where it was at the ceiling: logged only")
        expect(step(news: true, answered: false), .stop, "news comes first, whatever the answer")
    }
    test("dead focus: looked past forward after Tab, back after Shift Tab, not at all otherwise (27 Nov 2026)") {
        expect(D.deadFocusDirection(lastKey: "kb:tab", secondsSinceKey: 0.1), true, "Tab")
        expect(D.deadFocusDirection(lastKey: "kb:shift+tab", secondsSinceKey: 0.1), false, "Shift Tab")
        expect(D.deadFocusDirection(lastKey: "kb:downArrow", secondsSinceKey: 0.1), nil, "another key")
        expect(D.deadFocusDirection(lastKey: "kb:tab", secondsSinceKey: 2), nil, "a Tab too long ago")
        expect(D.deadFocusDirection(lastKey: "kb:control+tab", secondsSinceKey: 0.1), nil, "Control Tab changes tabs")
    }
    test("cut-loose focus: keeps the page that had the focus only when cut loose and in the page's window (27 Nov 2026)") {
        func keeps(web: Bool = false, top: Bool = false, had: Bool = true, window: Bool = true) -> Bool {
            D.keepsPageForCutLoose(webAreaInChain: web, chainReachesWindowOrApp: top, pageHadFocusInProcess: had, pageWindowIsFocused: window)
        }
        check(keeps(), "no parents, the page had the focus, its window in front: kept")
        check(!keeps(web: true), "a web area in the chain: document(for:) decides")
        check(!keeps(top: true), "a whole chain up to the application (the address bar): outside the page")
        check(!keeps(had: false), "no page had the focus in the process")
        check(!keeps(window: false), "another window is the focused one")
    }
    test("menu log: whether an item is named, never its name (27 Nov 2026)") {
        expect(AXHandler.namedWord(true), "named", "a titled item")
        expect(AXHandler.namedWord(false), "nameless", "an untitled item")
    }
}
