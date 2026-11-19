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

    test("An app coming to the front closes Find's prompt, but not TurnOver's own switch to wake an app") {
        let now = Date(), soon = now.addingTimeInterval(1)
        func closes(_ pid: pid_t, until: Date = .distantPast) -> Bool {
            AXHandler.activationClosesFind(pid: pid, activePid: 10, ownPid: 99, now: now, nudgingUntil: until, nudgedPid: 10)
        }
        check(closes(20), "another app closes it")
        check(!closes(10), "the same app does not")
        check(closes(99), "TurnOver's own app, outside a nudge, does")
        check(!closes(99, until: soon), "TurnOver coming forward for its nudge (AppWake) does not")
        check(!AXHandler.activationClosesFind(pid: 30, activePid: 10, ownPid: 99, now: now, nudgingUntil: soon, nudgedPid: 30),
              "the app being woken coming back does not")
        // 19 Nov 2026, Codex's review: any app was let through during the nudge.
        check(closes(20, until: soon), "another app clicked during the nudge does")
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

        // The reader stopping (VoiceOver takes the keyboard) between a Return's decision and its handling: no search.
        FindPrompt.shared.open()
        check(InputManager.handleKeyDown(key("kb:q")), "q taken for the prompt")
        check(InputManager.handleKeyDown(key("kb:enter")), "Return taken for the prompt")
        let beforeStop = searches().count
        Core.deactivate()
        check(!FindPrompt.shared.isOpen, "the reader stopping closed the prompt")
        drain()
        expect(searches().count, beforeStop, "the queued Return searched nothing after the reader stopped")
        expect(FindPrompt.shared.lastSearch, "buy", "the last search is unchanged after the reader stopped")

        // TurnOver's menu opening closes it.
        FindPrompt.shared.open()
        TurnOverMenu.shared.open()
        check(!FindPrompt.shared.isOpen, "the menu opening closed the prompt")
        TurnOverMenu.shared.close()
    }

    // 19 Nov 2026, Codex's review: TurnOver+F decided, then a Quick Nav arrow before the queued opening ran; the arrow
    // found the prompt closed, and the opening then stayed open and took the next letters.
    test("A Quick Nav arrow after TurnOver+F stops the opening still queued; a later TurnOver+F opens") {
        defer { if FindPrompt.shared.isOpen { FindPrompt.shared.close(because: "the test is over") } }
        let t = mach_absolute_time()
        FindPrompt.shared.close(because: "a Quick Nav arrow", arrowAt: t)
        FindPrompt.shared.open(pressedAt: t &- 1_000)
        check(!FindPrompt.shared.isOpen, "the opening asked for before the arrow did not happen")
        FindPrompt.shared.open(pressedAt: t &+ 1_000)
        check(FindPrompt.shared.isOpen, "TurnOver+F pressed after the arrow opens")
        FindPrompt.shared.close(because: "the test")
        FindPrompt.shared.open()
        check(FindPrompt.shared.isOpen, "an opening with no key time (the key list, the menu) opens")
    }

    // 19 Nov 2026, Codex's review: the close's log line was written on the keyboard's tap.
    test("Find's prompt closed off the main thread writes its log line on the main thread") {
        let savedObserver = Log.observer, savedLevel = Log.level
        let onMainThread = Locked<[Bool]>([])
        Log.level = .io
        Log.observer = { line in if line.contains("the prompt closed without a search (the test: off main)") { onMainThread.value.append(Thread.isMainThread) } }
        defer { Log.observer = savedObserver; Log.level = savedLevel }
        FindPrompt.shared.open()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { FindPrompt.shared.close(because: "the test: off main"); done.signal() }
        done.wait()
        check(!FindPrompt.shared.isOpen, "closed at once, on the calling thread")
        expect(onMainThread.value, [], "nothing written on the calling thread")
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        expect(onMainThread.value, [true], "the line written once, on the main thread")
    }

    // 19 Nov 2026, Codex's fourth review: only an arrow stopped a queued opening, so an app switch (or the menu, the lock,
    // secure input, the reader stopping) while TurnOver+F waited let the prompt open over the new app.
    test("Any close after TurnOver+F stops its queued opening; a TurnOver+F after the close opens") {
        defer { if FindPrompt.shared.isOpen { FindPrompt.shared.close(because: "the test is over") } }
        let pressed = mach_absolute_time()
        FindPrompt.shared.close(because: "the test: another app came to the front")
        FindPrompt.shared.open(pressedAt: pressed)
        check(!FindPrompt.shared.isOpen, "the opening asked for before the app switch did not happen")
        FindPrompt.shared.open(pressedAt: mach_absolute_time())
        check(FindPrompt.shared.isOpen, "TurnOver+F pressed after the switch opens")
    }

    // 19 Nov 2026, Codex's fifth review: with Find open, TurnOver+F closed it (recording now) and its own opening, asked
    // with the key's earlier time, was refused, so the key closed Find instead of reopening it.
    test("TurnOver+F with Find open leaves it open; a key before a later close is still refused") {
        defer { if FindPrompt.shared.isOpen { FindPrompt.shared.close(because: "the test is over") } }
        let t = mach_absolute_time()
        FindPrompt.shared.open(pressedAt: t &- 5_000)
        FindPrompt.shared.close(because: "a key it does not take", arrowAt: t)
        FindPrompt.shared.open(pressedAt: t)
        check(FindPrompt.shared.isOpen, "the key that closed the prompt opens it again")
        FindPrompt.shared.close(because: "the test: later close", arrowAt: t &+ 2_000)
        FindPrompt.shared.open(pressedAt: t &+ 1_000)
        check(!FindPrompt.shared.isOpen, "a key earlier than a later close does not open it")
    }

    // 19 Nov 2026, Codex's fourth review: the opening checked the last arrow and then, after letting go of the lock, set
    // the prompt open; an arrow in between saw it closed, and the opening went on. In either order the prompt ends closed.
    test("A Quick Nav arrow racing a queued opening leaves the prompt closed, whichever comes first") {
        defer { if FindPrompt.shared.isOpen { FindPrompt.shared.close(because: "the test is over") } }
        var leftOpen = 0
        for _ in 0..<300 {
            let pressed = mach_absolute_time()
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { FindPrompt.shared.close(because: "a Quick Nav arrow", arrowAt: pressed &+ 1); done.signal() }
            FindPrompt.shared.open(pressedAt: pressed)
            done.wait()
            if FindPrompt.shared.isOpen { leftOpen += 1; FindPrompt.shared.close(because: "the test") }
        }
        expect(leftOpen, 0, "openings left open after an arrow pressed after their key")
        // Opened first, then the arrow: closed, and keys queued for that opening are dropped.
        FindPrompt.shared.open(pressedAt: mach_absolute_time())
        let opening = FindPrompt.shared.generation
        FindPrompt.shared.close(because: "a Quick Nav arrow", arrowAt: mach_absolute_time())
        check(!FindPrompt.shared.isOpen && FindPrompt.shared.generation != opening, "the open prompt closed, its opening ended")
    }
}
