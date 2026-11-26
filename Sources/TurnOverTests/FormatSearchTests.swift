// SPDX-License-Identifier: GPL-3.0-or-later
// Issue 201: moving back to the previous bold text in a long document said "no bold text found", for the search back
// stopped at a fixed number of characters. It now goes on chunk by chunk, as far as the search forward does.
import Foundation
import TurnOverCore

func formatSearchTests() {
    /// A document of `n` characters, bold only at the given starts (each 5 characters long), as a fake of the attributed string read.
    func document(_ n: Int, boldAt: [Int]) -> (Int, (Int, Int) -> NSAttributedString?) {
        func bold(_ i: Int) -> Bool { boldAt.contains { i >= $0 && i < $0 + 5 } }
        return (n, { lo, hi in
            let out = NSMutableAttributedString()
            for i in lo..<hi {
                out.append(NSAttributedString(string: "x", attributes: bold(i) ? [NSAttributedString.Key("AXFontBold"): NSNumber(value: true)] : [:]))
            }
            return out
        })
    }
    func start(_ o: FormatSearch.Outcome) -> Int? { if case .found(let s, _, _) = o { return s }; return nil }
    func isNone(_ o: FormatSearch.Outcome) -> Bool { if case .none = o { return true }; return false }
    test("Format search: backwards reaches the whole document, in chunks, as forwards does (issue 201)") {
        MainActor.assumeIsolated {
        let kind = FormatSearch.kinds["AXBoldFontSearchKey"]!
        let (n, fetch) = document(130_000, boldAt: [10, 70_000])
        expect(start(FormatSearch.search(kind: kind, n: n, caret: 129_000, forward: false, fetch: fetch)), 70_000, "the near bold one")
        expect(start(FormatSearch.search(kind: kind, n: n, caret: 60_000, forward: false, fetch: fetch)), 10, "a bold one 60,000 characters back, beyond the old limit of 50,000")
        expect(start(FormatSearch.search(kind: kind, n: n, caret: 129_000, forward: true, fetch: fetch)), nil, "nothing forward from the end")
        expect(start(FormatSearch.search(kind: kind, n: n, caret: 0, forward: true, fetch: fetch)), 10, "forward from the start")
        expect(start(FormatSearch.search(kind: kind, n: n, caret: 11, forward: true, fetch: fetch)), 70_000, "forward from inside bold finds the next, 70,000 on")
        expect(start(FormatSearch.search(kind: kind, n: n, caret: 70_002, forward: false, fetch: fetch)), 10, "backward from inside bold skips that bold")
        check(isNone(FormatSearch.search(kind: kind, n: n, caret: 5, forward: false, fetch: fetch)), "nothing before the first")
        let (m, fetch2) = document(130_000, boldAt: [19_998, 40_000])   // a bold word across a chunk edge
        expect(start(FormatSearch.search(kind: kind, n: m, caret: 100_000, forward: false, fetch: fetch2)), 40_000)
        expect(start(FormatSearch.search(kind: kind, n: m, caret: 39_000, forward: false, fetch: fetch2)), 19_998, "a run across a chunk edge is found at its true start")
        expect(start(FormatSearch.search(kind: kind, n: m, caret: 0, forward: true, fetch: fetch2)), 19_998, "and forwards")
        }
    }
}
