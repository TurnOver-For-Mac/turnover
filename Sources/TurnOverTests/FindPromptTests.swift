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

    test("A key Find's prompt does not take closes it, so the keys after it work again") {
        let savedPoster = KeyboardGesture.poster
        let sent = Locked<[String]>([])
        KeyboardGesture.poster = { g in sent.value.append(g.identifier) }
        defer { KeyboardGesture.poster = savedPoster }

        FindPrompt.shared.open()
        check(FindPrompt.shared.isOpen, "the prompt opened")
        // A letter typed into it: taken, and the prompt stays open.
        check(InputManager.handleKeyDown(key("kb:b")), "the letter went to the prompt")
        check(FindPrompt.shared.isOpen, "still open after a letter")
        // Tab: leaves the prompt at once, on the keyboard's way in.
        _ = InputManager.handleKeyDown(key("kb:tab"))
        check(!FindPrompt.shared.isOpen, "Tab left the prompt")
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check(!FindPrompt.shared.isOpen, "the queued letter did not reopen it")

        // Command Tab: the prompt closes too (it stayed open in Finder and back in Safari).
        FindPrompt.shared.open()
        _ = InputManager.handleKeyDown(key("kb:command+tab"))
        check(!FindPrompt.shared.isOpen, "Command Tab left the prompt")

        // Escape still cancels, through the prompt.
        FindPrompt.shared.open()
        check(InputManager.handleKeyDown(key("kb:escape")), "Escape went to the prompt")
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check(!FindPrompt.shared.isOpen, "Escape closed the prompt")
    }
}
