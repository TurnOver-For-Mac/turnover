// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

func webTableNewsTests() {
    func news(entering: Bool = true, rowChanged: Bool = false, row: Int? = 1, rows: Int = 3, columns: Int = 2,
              mode: ElementReport = .speech, coordinates: Bool = true) -> (tone: Bool, words: [String]) {
        WebTableNews.words(entering: entering, rowChanged: rowChanged, row: row, rows: rows, columns: columns, mode: mode, coordinates: coordinates)
    }
    test("web tables: entering says the size, then the row") {
        let n = news()
        check(!n.tone, "no tone with speech")
        expect(n.words, [WordTableWords.size(rows: 3, columns: 2), Phrases.row(1)], "size then row 1")
    }
    test("web tables: entering without cell coordinates says the size only") {
        expect(news(coordinates: false).words, [WordTableWords.size(rows: 3, columns: 2)], "size only")
    }
    test("web tables: one row and one column are singular") {
        expect(news(rows: 1, columns: 1).words.first ?? "", WordTableWords.size(rows: 1, columns: 1), "1 row and 1 column")
        check(WordTableWords.size(rows: 1, columns: 1) != WordTableWords.size(rows: 2, columns: 2), "singular differs")
    }
    test("web tables: entering with the tone plays the tone, then the row") {
        let n = news(mode: .tone)
        check(n.tone, "tone")
        expect(n.words, [Phrases.row(1)], "row 1 after the tone")
    }
    test("web tables: another row of the same table says the row") {
        expect(news(entering: false, rowChanged: true, row: 2).words, [Phrases.row(2)], "row 2")
    }
    test("web tables: the same row says nothing") {
        let n = news(entering: false, rowChanged: false, row: 2)
        check(n.words.isEmpty && !n.tone, "nothing")
    }
    test("web tables: cell coordinates off say no row number") {
        check(news(entering: false, rowChanged: true, row: 2, coordinates: false).words.isEmpty, "no row on a move")
        check(!news(coordinates: false).words.contains(Phrases.row(1)), "no row on entering")
    }
    test("web tables: tables off say nothing at all") {
        let a = news(mode: .off), b = news(entering: false, rowChanged: true, row: 2, mode: .off)
        check(a.words.isEmpty && !a.tone && b.words.isEmpty && !b.tone, "nothing")
    }
    test("web tables: an unknown size says the bare table") {
        expect(news(rows: 0).words, [Role.table.displayString, Phrases.row(1)], "table, then row 1")
        expect(news(rows: 0, coordinates: false).words, [Role.table.displayString], "bare table")
        expect(news(columns: 0, coordinates: false).words, [Role.table.displayString], "bare table, columns unknown")
    }
    test("web tables: with no last reading the table is said only where it begins") {
        let mid = WebTableNews.change(lastInTable: nil, lastInRow: true, beginsHere: false)
        check(!mid.entering && !mid.rowChanged, "say all's first piece in the middle of a table: nothing")
        let first = WebTableNews.change(lastInTable: nil, lastInRow: false, beginsHere: true)
        check(first.entering && !first.rowChanged, "the table's first line: entering")
    }
    test("web tables: against the last reading, entering and another row") {
        let a = WebTableNews.change(lastInTable: false, lastInRow: false, beginsHere: false)
        check(a.entering && !a.rowChanged, "from outside the table: entering, wherever it began")
        let b = WebTableNews.change(lastInTable: true, lastInRow: false, beginsHere: false)
        check(!b.entering && b.rowChanged, "another row")
        let c = WebTableNews.change(lastInTable: true, lastInRow: true, beginsHere: true)
        check(!c.entering && !c.rowChanged, "the same row")
    }
}
