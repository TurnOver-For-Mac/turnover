// SPDX-License-Identifier: GPL-3.0-or-later
// The runner's second try (20 Nov 2026): tested through Harness.attempt, with the global counts put back afterwards.
import Foundation

/// Runs `f` with the harness quiet, then restores its counts, so a deliberate failure inside does not count.
private func isolated<T>(_ f: () -> T) -> T {
    let (failed, lines, current, quiet) = (Harness.failed, Harness.failures, Harness.current, Harness.quiet)
    Harness.quiet = true
    defer { Harness.failed = failed; Harness.failures = lines; Harness.current = current; Harness.quiet = quiet }
    return f()
}

func harnessSecondTryTests() {
    test("runner: a test that fails once and passes on the second try counts as passed") {
        var tries = 0
        let (outcome, failedAfter, linesAfter) = isolated { () -> (Harness.Outcome, Int, Int) in
            let o = Harness.attempt("x", secondTry: true) { tries += 1; if tries == 1 { Harness.fail("first") } }
            return (o, Harness.failed, Harness.failures.count)
        }
        expect(outcome, .passedOnSecondTry)
        expect(tries, 2)
        expect(failedAfter, Harness.failed, "the first try's failure is not left in the count")
        expect(linesAfter, Harness.failures.count)
    }
    test("runner: a test that fails twice counts once as failed") {
        var tries = 0
        let (outcome, delta) = isolated { () -> (Harness.Outcome, Int) in
            let base = Harness.failed
            let o = Harness.attempt("x", secondTry: true) { tries += 1; Harness.fail("always") }
            return (o, Harness.failed - base)
        }
        expect(outcome, .failed)
        expect(tries, 2)
        expect(delta, 1)
    }
    test("runner: with no second try one failure fails") {
        var tries = 0
        let (outcome, delta) = isolated { () -> (Harness.Outcome, Int) in
            let base = Harness.failed
            let o = Harness.attempt("x", secondTry: false) { tries += 1; Harness.fail("once") }
            return (o, Harness.failed - base)
        }
        expect(outcome, .failed)
        expect(tries, 1)
        expect(delta, 1)
    }
    test("runner: a passing test runs once") {
        var tries = 0
        let outcome = isolated { Harness.attempt("x", secondTry: true) { tries += 1 } }
        expect(outcome, .passed)
        expect(tries, 1)
    }
    test("runner: the second try is on only on GitHub's machines or when forced") {
        expect(Harness.secondTryAllowed([:]), false)
        expect(Harness.secondTryAllowed(["GITHUB_ACTIONS": "true"]), true)
        expect(Harness.secondTryAllowed(["GITHUB_ACTIONS": "true", "TURNOVER_TEST_SECOND_TRY": "0"]), false)
        expect(Harness.secondTryAllowed(["TURNOVER_TEST_SECOND_TRY": "1"]), true)
    }
}
