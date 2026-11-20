// SPDX-License-Identifier: GPL-3.0-or-later
// VO-Space on a line of text (17 Nov 2026): the one link on the line pressed, several named, a label's field acted on,
// plain text refused at once. Synthetic fixtures shaped like the pages in the log: logic evidence only, not Safari's
// or Mail's own trees.
import Foundation
import ApplicationServices
import TurnOverCore
import TurnOverAX
import AXFixtures

private func linePage(staleUnsubscribe: Bool = false, textSurvives: Bool = false) -> AXFixture {
    func text(_ id: Int, _ v: String, _ parent: Int, extra: [String: AXFixture.Value] = [:]) -> AXFixture.Node {
        .init(id: id, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string(v), "AXParent": .element(parent)].merging(extra) { $1 })
    }
    func group(_ id: Int, _ kids: [Int], role: String = "AXGroup") -> AXFixture.Node {
        .init(id: id, attrs: ["AXRole": .string(role), "AXParent": .element(0), "AXChildren": .elements(kids)])
    }
    func link(_ id: Int, _ kid: Int, _ parent: Int) -> AXFixture.Node {
        .init(id: id, attrs: ["AXRole": .string("AXLink"), "AXParent": .element(parent), "AXChildren": .elements([kid])], actions: ["AXPress"])
    }
    // (The web area is given no parent: a press walking up from plain text stops at the page, where a real one
    // meets the scroll area around it.)
    // Mail's message body: "To stop these, Unsubscribe." with the link in the middle. A stale copy: the page has since
    // made the link anew (7), so the copy's 4 is gone, and its text (8) too unless `textSurvives`.
    let unsubscribe = staleUnsubscribe ? 7 : 4
    let label = staleUnsubscribe && !textSurvives ? 8 : 5
    var nodes: [AXFixture.Node] = [
        .init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.com/line"),
                             "AXChildren": .elements([2, 10, 20, 30, 40, 50, 53, 60])]),
        .init(id: 1, attrs: ["AXRole": .string("AXApplication"), "AXFocusedUIElement": .element(0)]),
        group(2, [3, unsubscribe, 6]), text(3, "To stop these, ", 2), link(unsubscribe, label, 2), text(label, "Unsubscribe", unsubscribe), text(6, ".", 2),
        // Two links on one line.
        group(10, [11, 12, 14, 15]), text(11, "See the ", 10), link(12, 13, 10), text(13, "Terms", 12), text(14, " and the ", 10), link(15, 16, 10), text(16, "Privacy notice", 15),
        // A heading that is itself a link.
        .init(id: 20, attrs: ["AXRole": .string("AXHeading"), "AXParent": .element(0), "AXChildren": .elements([21])]), link(21, 22, 20), text(22, "News today", 21),
        // A line whose first piece is already the link.
        group(30, [31, 33]), link(31, 32, 30), text(32, "Home", 31), text(33, " page and more", 30),
        // Plain text.
        group(40, [41]), text(41, "Just some plain words here", 40),
        // A label the page pairs with one field, and one it pairs with two.
        group(50, [51, 52]), text(51, "Date of birth", 50, extra: ["AXServesAsTitleForUIElements": .elements([52])]),
        .init(id: 52, attrs: ["AXRole": .string("AXTextField"), "AXTitle": .string("Birth date"), "AXParent": .element(50)]),
        group(53, [54, 55, 56]), text(54, "Start of term", 53, extra: ["AXServesAsTitleForUIElements": .elements([55, 56])]),
        .init(id: 55, attrs: ["AXRole": .string("AXPopUpButton"), "AXTitle": .string("Day"), "AXParent": .element(53)], actions: ["AXPress"]),
        .init(id: 56, attrs: ["AXRole": .string("AXPopUpButton"), "AXTitle": .string("Month"), "AXParent": .element(53)], actions: ["AXPress"]),
        // The Claude app's "Copy code": a button line of its own.
        group(60, [61]), .init(id: 61, attrs: ["AXRole": .string("AXButton"), "AXTitle": .string("Copy code"), "AXParent": .element(60)], actions: ["AXPress"]),
    ]
    nodes.sort { $0.id < $1.id }
    return .init(app: "Public line trial", bundle: "test.activation.line", recorded: "synthetic", root: 0, application: 1, focus: 0, nodes: nodes)
}

/// The page read into a copy, the reading position put on `at`, and (for a stale copy) the page then changed under it.
private func withLinePage(at: String, stale: Bool = false, textSurvives: Bool = false, _ body: (BrowseModeDocument, () -> [String]) -> Void) {
    let previousConfig = config, previousSink = Speech.sink
    let previousPid = AXHandler.shared.activePid
    AXReplay.load(linePage())
    let root = AXReplay.element(0)
    let buffer = WebBuffer(webArea: root)
    let page = BrowseModeDocument(webArea: root, buffer: buffer)
    waitForBuffer(buffer)
    BrowseModeHandler.shared.adopt(page)
    API.setFocusObject(ObjectFactory.make(root), ancestors: [], interceptor: page)
    AXHandler.shared.activePid = root.pid
    config.general.navigationSounds = false
    var words: [String] = []
    Speech.sink = { words.append($0) }
    page.position = buffer.text.range(of: at).location
    check(page.position != NSNotFound, "the copy holds \"\(at)\"")
    if stale { AXReplay.load(linePage(staleUnsubscribe: true, textSurvives: textSurvives)) }
    defer {
        API.setFocusObject(nil, ancestors: [])
        BrowseModeHandler.shared.forget(pid: root.pid)
        waitForBuffer(buffer)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        Speech.sink = previousSink
        config = previousConfig
        AXHandler.shared.activePid = previousPid
        AXReplay.unload()
    }
    body(page, { words })
}

private func press(_ page: BrowseModeDocument, vo: Bool = true) {
    let key = KeyboardGesture(identifier: vo ? "kb:turnover+space" : "kb:enter")!
    if vo { VoiceOverKeysPlugin().script(for: key)?.handler(key) } else { page.script(for: key)?.handler(key) }
}

private var pressed: [Int] { AXReplay.actions.filter { $0.action == "AXPress" }.map(\.id) }

/// Waits (up to 10 s, however slow the machine) for recovery's deadline to say "nothing to activate", then lets a wrong extra
/// word or late press arrive so the checks after it still catch one.
private func awaitFailure(_ words: () -> [String]) {
    let limit = Date().addingTimeInterval(10)
    while !words().contains("nothing to activate"), Date() < limit { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    RunLoop.current.run(until: Date().addingTimeInterval(0.18))
}

func activationLineTests() {
    test("VO-Space on a line: Mail's one link in a line of text is pressed") {
        withLinePage(at: "To stop these") { page, words in
            press(page)
            expect(pressed, [4], "the line's one link, and nothing else")
            check(!words().contains("nothing to activate"), "not refused")
        }
    }
    test("VO-Space on a line: two links are named, neither pressed") {
        withLinePage(at: "See the") { page, words in
            press(page)
            expect(pressed, [], "a guess could act unwanted")
            expect(words(), ["2 links: Terms, Privacy notice"])
        }
    }
    test("VO-Space on a line: a heading that is itself a link is pressed once, as before") {
        withLinePage(at: "News today") { page, _ in
            press(page)
            expect(pressed, [21])
        }
    }
    test("VO-Space on a line: a line whose first piece is the link presses that link, as before") {
        withLinePage(at: "Home") { page, _ in
            press(page)
            expect(pressed, [31])
        }
    }
    test("VO-Space on a line: plain text says nothing to activate at once, with no recovery wait") {
        withLinePage(at: "Just some plain") { page, words in
            press(page)
            expect(words(), ["nothing to activate"], "said before any run loop turn")
            expect(pressed, [])
        }
    }
    test("VO-Space on a line: a label the page pairs with one field puts the keyboard in it") {
        withLinePage(at: "Date of birth") { page, _ in
            press(page)
            check(AXReplay.sets.contains { $0.id == 52 && $0.attribute == kAXFocusedAttribute }, "the labelled field is focused")
            expect(pressed, [])
        }
    }
    test("VO-Space on a line: a label for two fields names them and acts on neither") {
        withLinePage(at: "Start of term") { page, words in
            press(page)
            expect(pressed, [])
            expect(words(), ["2 fields: Day, Month"])
        }
    }
    test("VO-Space on a line: a stale copy's link still goes to recovery, and is not named or guessed") {
        withLinePage(at: "To stop these", stale: true) { page, words in
            press(page)
            expect(words(), [], "recovery is under way, nothing said yet")
            awaitFailure(words)
            expect(pressed, [], "the whole line's text names no live control")
            expect(words().filter { $0 == "nothing to activate" }.count, 1, "refused once, by recovery's deadline")
        }
    }
    test("VO-Space on a line: a link the page remade around its surviving text is the one pressed") {
        withLinePage(at: "To stop these", stale: true, textSurvives: true) { page, _ in
            press(page)
            expect(pressed, [7], "the live link that holds the copy's text")
        }
    }
    test("VO-Space on a line: the Claude app's Copy code button line is pressed") {
        withLinePage(at: "Copy code") { page, _ in
            press(page)
            expect(pressed, [61])
        }
    }
    test("VO-Space on a line: Enter on the link's line is unchanged: the text under the caret, then recovery") {
        withLinePage(at: "To stop these") { page, words in
            press(page, vo: false)
            expect(words(), [], "Enter still waits for recovery")
            awaitFailure(words)
            expect(pressed, [], "Enter does not reach along the line")
        }
    }
}
