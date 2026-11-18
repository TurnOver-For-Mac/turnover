// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

// Find's prompt (TurnOver+F) and the keys it takes (18 Nov 2026). On 17 Nov at 20:42 Oliver left Find with Tab, without
// Return: the prompt stayed open, took Tab, the arrows and TurnOver's keys and said nothing, through Command Tab and in
// the next app, until he turned TurnOver off. Logic evidence only: the keys are made from their names, not pressed.
func findPromptTests() {
    func key(_ identifier: String) -> KeyboardGesture { KeyboardGesture(identifier: identifier)! }

    test("Find's prompt takes typing, Backspace, Return and Escape, and the Mac's Control keys") {
        for id in ["kb:b", "kb:shift+b", "kb:space", "kb:1", "kb:backspace", "kb:enter", "kb:numpadEnter", "kb:escape",
                   "kb:control+space", "kb:option+e"] {
            check(FindPrompt.keeps(key(id)), "\(id) is the prompt's")
        }
    }

    test("Find's prompt lets Tab, the arrows, Command and TurnOver keys go on") {
        for id in ["kb:tab", "kb:shift+tab", "kb:leftArrow", "kb:downArrow", "kb:home", "kb:f5", "kb:command+tab",
                   "kb:command+v", "kb:turnover+leftArrow", "kb:turnover+f", "kb:turnover+command+shift+h"] {
            check(!FindPrompt.keeps(key(id)), "\(id) leaves the prompt")
        }
    }

    test("Find's prompt types a key's character, and nothing for an arrow or Tab") {
        expect(FindPrompt.typedText(key("kb:b")), "b")
        expect(FindPrompt.typedText(key("kb:space")), " ")
        // An arrow's character is a private-use one, not a control character: it was typed into the search before.
        let arrow = KeyboardGesture(keyCode: 123, modifiers: [], characters: "\u{F702}", timestamp: 0, isRepeat: false, flags: [])
        expect(FindPrompt.typedText(arrow), "")
        let tab = KeyboardGesture(keyCode: 48, modifiers: [], characters: "\t", timestamp: 0, isRepeat: false, flags: [])
        expect(FindPrompt.typedText(tab), "")
    }

    test("Find's prompt: what is typed is searched, other keys close it and go on, queued keys of a closed prompt do nothing") {
        let savedPoster = KeyboardGesture.poster, savedObserver = Log.observer, savedLevel = Log.level
        let sent = Locked<[String]>([]), lines = Locked<[String]>([])
        KeyboardGesture.poster = { g in sent.value.append(g.identifier) }
        Log.level = .io
        Log.observer = { line in lines.value.append(line) }
        defer {
            if FindPrompt.shared.isOpen { FindPrompt.shared.close(because: "the test is over") }
            if TurnOverMenu.shared.isOpen { TurnOverMenu.shared.close() }
            KeyboardGesture.poster = savedPoster; Log.observer = savedObserver; Log.level = savedLevel
        }
        func drain() { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        func searches() -> [String] { lines.value.filter { $0.contains("find next:") || $0.contains("find previous:") } }

        // Typed, then Return: the typed text is what is searched for.
        FindPrompt.shared.open()
        for id in ["kb:b", "kb:u", "kb:y"] { check(InputManager.handleKeyDown(key(id)), "\(id) taken for the prompt") }
        drain()
        expect(FindPrompt.shared.typedSoFar, "buy", "the letters went into the prompt")
        check(InputManager.handleKeyDown(key("kb:enter")), "Return taken for the prompt")
        drain()
        expect(FindPrompt.shared.lastSearch, "buy", "Return searched for what was typed")
        check(!FindPrompt.shared.isOpen, "Return closed the prompt")
        expect(sent.value, [], "nothing typed into the prompt was posted to the app")

        // A letter and Return decided, then the prompt closed (Command Tab, an app switch) before the main thread got
        // to them: the queued Return does not search, and the letter is not typed.
        FindPrompt.shared.open()
        check(InputManager.handleKeyDown(key("kb:x")), "x taken for the prompt")
        check(InputManager.handleKeyDown(key("kb:enter")), "Return taken for the prompt")
        let before = searches().count
        FindPrompt.shared.close(because: "the test: an app switch")
        drain()
        expect(searches().count, before, "the queued Return of a closed prompt searched nothing")
        expect(FindPrompt.shared.lastSearch, "buy", "the last search is unchanged")

        // A key queued for one opening is not typed into the next.
        FindPrompt.shared.open()
        check(InputManager.handleKeyDown(key("kb:z")), "z taken for the prompt")
        FindPrompt.shared.open()
        drain()
        expect(FindPrompt.shared.typedSoFar, "", "the letter for the replaced opening was dropped")

        // Tab: the prompt closes on the keyboard's way in; Tab is not typed and not posted by the prompt.
        sent.value = []
        _ = InputManager.handleKeyDown(key("kb:tab"))
        check(!FindPrompt.shared.isOpen, "Tab closed the prompt")
        drain()
        expect(FindPrompt.shared.typedSoFar, "", "Tab typed nothing")
        check(!sent.value.contains("kb:tab"), "the prompt did not post Tab")

        // Control Space is the Mac's: posted, and the prompt stays open for the letters in the new language.
        FindPrompt.shared.open()
        sent.value = []
        check(InputManager.handleKeyDown(key("kb:control+space")), "Control Space kept from the app for the prompt")
        drain()
        expect(sent.value, ["kb:control+space"], "Control Space posted on to the Mac")
        check(FindPrompt.shared.isOpen, "the prompt stays open after Control Space")

        // Command Tab: not taken, so the Mac's switcher gets it; the prompt is closed.
        sent.value = []
        check(!InputManager.handleKeyDown(key("kb:command+tab")), "Command Tab goes on to the Mac")
        check(!FindPrompt.shared.isOpen, "Command Tab closed the prompt")
        drain()
        expect(sent.value, [], "Command Tab was not posted again by the prompt")

        // TurnOver's menu opening closes it.
        FindPrompt.shared.open()
        TurnOverMenu.shared.open()
        check(!FindPrompt.shared.isOpen, "the menu opening closed the prompt")
        TurnOverMenu.shared.close()
    }
}
