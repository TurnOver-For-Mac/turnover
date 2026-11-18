// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

/// Secure input on, no key heard (18 Nov 2026): a field's own news read as the key would have been, and the episode's
/// two log lines. Text and caret are given by hand; nothing touches the Mac's secure input. Logic evidence only.
func keylessCaretTests() {
    test("keyless: a letter typed at the caret is that letter, and its late caret news is not read again") {
        var k = KeylessCaret(text: "Olive", caret: 5)
        expect(k.next(text: "Oliver", caret: 5), .typed("r"))       // WebKit: the value first, the caret after
        expect(k.next(text: "Oliver", caret: 6), .nothing)           // the caret's own news for that letter
        expect(k.next(text: "Oliver", caret: 5), .moved(.character)) // then Left Arrow
    }
    test("keyless: a letter typed beside the same letter is placed at the caret") {
        let e = KeylessCaret.edit(from: Array("aa".utf16), to: Array("aaa".utf16), caret: 1)
        expect(e.inserted, Array("a".utf16)); expect(e.caretAfter, 2)
    }
    test("keyless: Backspace and forward Delete say what went") {
        var k = KeylessCaret(text: "cats", caret: 4)
        expect(k.next(text: "cat", caret: 3), .deleted("s"))
        var d = KeylessCaret(text: "cats", caret: 0)
        expect(d.next(text: "ats", caret: 0), .deleted("c"))
    }
    test("keyless: AutoFill or a paste is what came, once") {
        var k = KeylessCaret(text: "", caret: 0)
        expect(k.next(text: "oliver@example.com", caret: 18), .typed("oliver@example.com"))
        expect(k.next(text: "oliver@example.com", caret: 18), .nothing)
    }
    test("keyless: the caret moved by one is a character, further on the line a word, to another line a line") {
        var k = KeylessCaret(text: "one two\nthree", caret: 0)
        expect(k.next(text: "one two\nthree", caret: 1), .moved(.character))
        expect(k.next(text: "one two\nthree", caret: 4), .moved(.word))
        expect(k.next(text: "one two\nthree", caret: 9), .moved(.line))
        expect(k.next(text: "one two\nthree", caret: 9), .nothing)
    }
    test("keyless: a caret where a text change did not put it is a move of its own") {
        var k = KeylessCaret(text: "ab", caret: 2)
        expect(k.next(text: "abc", caret: 2), .typed("c"))
        expect(k.next(text: "abc", caret: 0), .moved(.word))   // Home, not the letter's caret
    }
    test("keyless: a change in the middle away from the caret is read by its common ends") {
        let e = KeylessCaret.edit(from: Array("hello world".utf16), to: Array("hello there world".utf16), caret: 0)
        expect(KeylessCaret.string(e.inserted), "there ")
        expect(e.removed.isEmpty, true)
    }
    test("keyless: lines are counted by their breaks") {
        expect(KeylessCaret.line(at: 0, in: Array("a\nb".utf16)), 0)
        expect(KeylessCaret.line(at: 2, in: Array("a\nb".utf16)), 1)
        expect(KeylessCaret.line(at: 99, in: Array("a\nb".utf16)), 1)
    }
    test("secure input episode: one line as it comes on, one as it goes off, with the keyboard watch's count") {
        var ep = SecureInputEpisode()
        let t0 = Date(timeIntervalSince1970: 1000)
        let on = ep.look(on: true, now: t0, inPasswordField: true, hidKeyReports: 10)
        check(on?.hasPrefix("secure input: on, the focus in a password field") == true, "the start is logged")
        expect(ep.look(on: true, now: t0 + 1, inPasswordField: false, hidKeyReports: 12), nil)   // no line while it stays on
        expect(ep.since, t0)
        expect(ep.look(on: false, now: t0 + 4.2, inPasswordField: false, hidKeyReports: 18),
               "secure input: off after 4.2 s, the keyboard watch saw 8 key reports meanwhile")
        expect(ep.look(on: false, now: t0 + 5, inPasswordField: false, hidKeyReports: 18), nil)
        expect(ep.since, nil)
    }
    test("secure input episode: no keyboard watch, no count; stood aside mid-episode, said so") {
        var ep = SecureInputEpisode()
        let t0 = Date(timeIntervalSince1970: 1000)
        _ = ep.look(on: true, now: t0, inPasswordField: false, hidKeyReports: nil)
        expect(ep.look(on: true, now: t0 + 2, inPasswordField: false, hidKeyReports: nil, watched: false),
               "secure input: no longer watched after 2.0 s (TurnOver stood aside)")
        expect(ep.look(on: false, now: t0 + 3, inPasswordField: false, hidKeyReports: nil, watched: false), nil)
    }
}
