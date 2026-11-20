// SPDX-License-Identifier: GPL-3.0-or-later
import TurnOverCore
import Foundation

func quickNavChordTests() {
    let t0 = Date(timeIntervalSince1970: 1000)
    test("quick nav chord: Left then Right 40 ms apart fires") {
        var chord = QuickNavChord()
        check(chord.down(code: 123, at: t0) == .first, "the first arrow waits")
        check(chord.down(code: 124, at: t0.addingTimeInterval(0.040)) == .chord(gapMilliseconds: 40), "40 ms is a chord")
    }
    test("quick nav chord: Right then Left 40 ms apart fires too") {
        var chord = QuickNavChord()
        _ = chord.down(code: 124, at: t0)
        check(chord.down(code: 123, at: t0.addingTimeInterval(0.040)) == .chord(gapMilliseconds: 40), "either order")
    }
    test("quick nav chord: a 400 ms gap does not fire, and the second key becomes the first") {
        var chord = QuickNavChord()
        _ = chord.down(code: 123, at: t0)
        check(chord.down(code: 124, at: t0.addingTimeInterval(0.400)) == .tooSlow(gapMilliseconds: 400), "too slow")
        // The Right key now waits, so a Left soon after it is a real chord.
        check(chord.down(code: 123, at: t0.addingTimeInterval(0.450)) == .chord(gapMilliseconds: 50), "the rejected key waits as the new first")
    }
    test("quick nav chord: the limit is 150 ms") {
        var inside = QuickNavChord()
        _ = inside.down(code: 123, at: t0)
        check(inside.down(code: 124, at: t0.addingTimeInterval(0.150)) == .chord(gapMilliseconds: 150), "150 ms still counts")
        var outside = QuickNavChord()
        _ = outside.down(code: 123, at: t0)
        check(outside.down(code: 124, at: t0.addingTimeInterval(0.151)) == .tooSlow(gapMilliseconds: 151), "151 ms does not")
    }
    test("quick nav chord: a stale first key after a clear does not fire") {
        var chord = QuickNavChord()
        _ = chord.down(code: 123, at: t0)
        chord.clear()   // the tap was disabled, or the app changed
        check(chord.down(code: 124, at: t0.addingTimeInterval(0.040)) == .first, "nothing was waiting")
    }
    test("quick nav chord: a first key let go no longer waits; the same key twice is not a chord") {
        var chord = QuickNavChord()
        _ = chord.down(code: 123, at: t0)
        chord.up(code: 123)
        check(chord.down(code: 124, at: t0.addingTimeInterval(0.040)) == .first, "let go, so it is not held")
        var same = QuickNavChord()
        _ = same.down(code: 123, at: t0)
        check(same.down(code: 123, at: t0.addingTimeInterval(0.040)) == .first, "two Lefts are not a chord")
    }
}
