// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import TurnOverAX
import AXFixtures

// Return in Safari's address field: until the new page's document has the focus, a key meant for the page's content is
// refused on the page being left (16 Nov 2026: a Space 0.3 s before the new page came pressed a link on the old page).
func pageOnItsWayTests() {
    /// A page in browse mode, and a second page that stands for the document that comes with the new address.
    func withPageLeft(_ body: (BrowseModeDocument, BrowseModeDocument, Locked<[String]>, Locked<[String]>) -> Void) {
        let savedFocus = API.focusObject, savedAncestors = API.focusAncestors, savedPage = API.focusTreeInterceptor
        let savedPid = AXHandler.shared.activePid, savedPoster = KeyboardGesture.poster, savedSink = Speech.sink
        let savedStyle = config.general.keyboardStyle
        let savedLimit = BrowseModeDocument.pageOnItsWayLimit, savedRepeat = BrowseModeDocument.pageOnItsWayRepeat
        AXReplay.load(.init(app: "Public page trial", bundle: "test.page-on-its-way", recorded: "synthetic", root: 0, application: 1, focus: 2, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.com/old"), "AXParent": .element(1), "AXChildren": .elements([2, 3])]),
            .init(id: 1, attrs: ["AXRole": .string("AXApplication"), "AXFocusedUIElement": .element(2)]),
            .init(id: 2, attrs: ["AXRole": .string("AXLink"), "AXTitle": .string("First link"), "AXParent": .element(0)], actions: ["AXPress"]),
            .init(id: 3, attrs: ["AXRole": .string("AXLink"), "AXTitle": .string("Second link"), "AXParent": .element(0)], actions: ["AXPress"]),
            .init(id: 4, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.com/new"), "AXParent": .element(1), "AXChildren": .elements([5])]),
            .init(id: 5, attrs: ["AXRole": .string("AXLink"), "AXTitle": .string("New link"), "AXParent": .element(4)], actions: ["AXPress"])
        ]))
        let root = AXReplay.element(0)
        let old = BrowseModeDocument(webArea: root), new = BrowseModeDocument(webArea: AXReplay.element(4))
        for page in [old, new] {
            page.buffer.buildForInspection()
            waitForBuffer(page.buffer)
            _ = page.refreshIfNavigated()
            waitForBuffer(page.buffer)
            page.announcedURL = page.url
        }
        config.general.keyboardStyle = "mac"
        AXHandler.shared.activePid = root.pid
        let said = Locked<[String]>([]), sent = Locked<[String]>([])
        Speech.sink = { said.value.append($0) }
        KeyboardGesture.poster = { sent.value.append($0.identifier) }
        defer {
            BrowseModeHandler.backFromAddressField = nil
            BrowseModeDocument.pageOnItsWayLimit = savedLimit
            BrowseModeDocument.pageOnItsWayRepeat = savedRepeat
            old.endPageOnItsWay(because: "the test is over")
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            API.setFocusObject(savedFocus, ancestors: savedAncestors, interceptor: savedPage)
            AXHandler.shared.activePid = savedPid
            KeyboardGesture.poster = savedPoster
            Speech.sink = savedSink
            config.general.keyboardStyle = savedStyle
            AXReplay.unload()
        }
        body(old, new, said, sent)
    }
    /// Return in the address field gave the page the focus: the event the branch answers.
    func backOnPage(_ page: BrowseModeDocument) {
        let web = ObjectFactory.make(page.webArea)
        API.setFocusObject(web, ancestors: [], interceptor: page)
        BrowseModeHandler.backFromAddressField = (Date(), page.webArea)
        page.passThrough = false
        page.handleEvent(Event(.gainFocus, web), next: {})
    }
    func press(_ page: BrowseModeDocument, _ identifier: String) -> Bool {
        let key = KeyboardGesture(identifier: identifier)!
        ScriptHandler.noteKeyArrived(key)
        guard let script = page.script(for: key) else { return false }
        script.handler(key)
        return true
    }
    func loadingCount(_ said: Locked<[String]>) -> Int { said.value.filter { $0 == "loading page" }.count }
    func pressed() -> Int { AXReplay.actions.filter { $0.action == "AXPress" }.count }

    test("page on its way: Space, a quick navigation letter and Tab are refused, and nothing is pressed or moved") {
        withPageLeft { old, _, said, sent in
            old.position = old.buffer.offset(of: AXReplay.element(3)) ?? 0
            let at = old.position
            backOnPage(old)
            check(old.pageIsOnItsWay, "Return in the address field marks the page being left")
            for identifier in ["kb:space", "kb:enter", "kb:k", "kb:h", "kb:tab"] {
                check(press(old, identifier), "\(identifier) has a command, which is the refusing one")
            }
            expect(pressed(), 0, "nothing is pressed on the old page")
            expect(sent.value, [], "no key is sent on to the old page")
            expect(old.position, at, "the reading position does not move")
            expect(loadingCount(said), 1, "\"loading page\" is said once for five refused keys")
        }
    }
    test("page on its way: VO-Space is refused too") {
        withPageLeft { old, _, said, sent in
            backOnPage(old)
            old.activate(KeyboardGesture(identifier: "kb:turnover+space")!, byAccessibility: true)
            expect(pressed(), 0, "VO-Space presses nothing on the old page")
            expect(sent.value, [], "VO-Space sends nothing")
            expect(loadingCount(said), 1, "VO-Space says the page is loading")
        }
    }
    test("page on its way: the phrase is said again only after the repeat time") {
        withPageLeft { old, _, said, _ in
            BrowseModeDocument.pageOnItsWayRepeat = 0.3
            backOnPage(old)
            _ = press(old, "kb:space"); _ = press(old, "kb:space")
            expect(loadingCount(said), 1, "two quick keys, one phrase")
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            _ = press(old, "kb:space")
            expect(loadingCount(said), 2, "a key after the repeat time says it again")
        }
    }
    test("page on its way: the new document taking the focus ends it, and keys act on the new document") {
        withPageLeft { old, new, said, sent in
            backOnPage(old)
            _ = press(old, "kb:space")
            new.position = new.buffer.offset(of: AXReplay.element(5)) ?? 0
            API.setFocusObject(ObjectFactory.make(new.webArea), ancestors: [], interceptor: new)
            check(!old.pageIsOnItsWay, "the old document is let go")
            let before = loadingCount(said)
            check(press(new, "kb:space"), "Space has a command on the new document")
            expect(loadingCount(said), before, "the new document refuses nothing")
            check(pressed() + sent.value.count > 0, "Space acted on the new document")
            // If the old document has the focus again later, its keys are its own.
            API.setFocusObject(ObjectFactory.make(old.webArea), ancestors: [], interceptor: old)
            check(!old.pageIsOnItsWay, "it stays cleared")
        }
    }
    test("page on its way: a new address in the same web area ends it") {
        withPageLeft { old, _, _, _ in
            backOnPage(old)
            check(old.pageIsOnItsWay, "marked")
            old.lastURL = "https://example.com/before"   // the replay cannot change the address; the copy was made for another
            _ = old.refreshIfNavigated()
            check(!old.pageIsOnItsWay, "a new address in this web area ends it")
            waitForBuffer(old.buffer)
        }
    }
    test("page on its way: the focus moving elsewhere on the page ends it") {
        withPageLeft { old, _, _, _ in
            backOnPage(old)
            API.setFocusObject(ObjectFactory.make(AXReplay.element(2)), ancestors: [], interceptor: old)
            check(!old.pageIsOnItsWay, "a field or link taking the focus ends it")
        }
    }
    test("page on its way: the focus leaving the document ends it") {
        withPageLeft { old, _, _, _ in
            backOnPage(old)
            API.setFocusObject(ObjectFactory.make(AXReplay.element(1)), ancestors: [], interceptor: nil)
            check(!old.pageIsOnItsWay, "the address field or another app taking the focus ends it")
        }
    }
    test("page on its way: the limit ends it") {
        withPageLeft { old, _, said, _ in
            BrowseModeDocument.pageOnItsWayLimit = 0.4
            backOnPage(old)
            _ = press(old, "kb:space")
            check(old.pageIsOnItsWay, "marked at first")
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            check(!old.pageIsOnItsWay, "cleared by the limit")
            let before = loadingCount(said)
            _ = press(old, "kb:space")
            expect(loadingCount(said), before, "the page is not locked after the limit")
        }
    }
    test("page on its way: the stay check without a key gives the page its keys back") {
        withPageLeft { old, _, _, _ in
            old.position = old.buffer.offset(of: AXReplay.element(3)) ?? 0
            backOnPage(old)
            RunLoop.current.run(until: Date().addingTimeInterval(2.3))
            check(!old.pageIsOnItsWay, "the page stayed, so the keys are its own again")
        }
    }
    test("page on its way: the stay check after a key still clears it, but only once it has decided") {
        withPageLeft { old, _, _, _ in
            backOnPage(old)
            _ = press(old, "kb:space")
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            check(old.pageIsOnItsWay, "a refused key does not hand the old page its keys back at the next check")
            RunLoop.current.run(until: Date().addingTimeInterval(1.3))
            check(!old.pageIsOnItsWay, "the page stayed, so it is not locked")
        }
    }
    test("page on its way: Escape and a typing key with no command are not refused") {
        withPageLeft { old, _, said, _ in
            backOnPage(old)
            check(old.script(named: "disablePassThrough") != nil, "Escape's command is there")
            let before = loadingCount(said)
            _ = press(old, "kb:z")
            expect(loadingCount(said), before, "a typed key kept from the page says nothing about loading")
        }
    }
    test("page on its way: the Claude navigation wait is separate and unchanged") {
        withPageLeft { old, _, _, _ in
            old.beginNavigationWait()
            check(!old.pageIsOnItsWay, "the navigation wait does not mark the page")
            var ran = false
            check(old.deferInitialContent { ran = true }, "a following command is still queued")
            check(!ran, "and does not run on the old copy")
            old.finishNavigationWait(title: nil, announce: false)
        }
    }
}
