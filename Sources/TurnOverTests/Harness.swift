// SPDX-License-Identifier: GPL-3.0-or-later
// turnover-tests: TurnOver's unit tests (8 Oct 2026, from the team review). No XCTest: a plain executable that
// build.sh runs before installing, so a failing test stops a build going out. Pure functions first; then the
// views against recorded accessibility trees (Tests/Fixtures) replayed through AXReplayShim.
//
//   turnover-tests [name-filter] [-v]
import Foundation

enum Harness {
    static var passed = 0
    static var failed = 0
    static var current = ""
    static var verbose = CommandLine.arguments.contains("-v")
    static var filter: String? = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-") }
    static var failures: [String] = []

    static var quiet = false
    static var passedOnSecondTry: [String] = []

    // 20 Nov 2026: on GitHub's shared machines a few tests, timed against a real clock or a Mac service, failed about
    // one run in six for no fault of TurnOver's. There (GITHUB_ACTIONS=true) a failing test gets one second try and
    // counts as failed only if it fails again; the pass is still listed. On a developer's Mac every test is strict, because
    // every test is run before an install. TURNOVER_TEST_SECOND_TRY=1 or 0 forces it on or off.
    static func secondTryAllowed(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        switch env["TURNOVER_TEST_SECOND_TRY"] {
        case "1": return true
        case "0": return false
        default: return env["GITHUB_ACTIONS"] == "true"
        }
    }
    enum Outcome: Equatable { case passed, passedOnSecondTry, failed }

    /// Runs one body, with one more try if allowed. Leaves `failed` and `failures` holding only the last try's failures.
    static func attempt(_ name: String, secondTry: Bool, _ body: () throws -> Void) -> Outcome {
        current = name
        let before = failed, linesBefore = failures.count
        do { try body() } catch { fail("threw \(error)") }
        if failed == before { return .passed }
        guard secondTry else { return .failed }
        if !quiet { print("AGAIN \(name)") }
        failed = before
        failures.removeSubrange(linesBefore...)
        current = name
        do { try body() } catch { fail("threw \(error)") }
        return failed == before ? .passedOnSecondTry : .failed
    }

    static func test(_ name: String, _ body: () throws -> Void) {
        if let f = filter, !name.localizedCaseInsensitiveContains(f) { return }
        switch attempt(name, secondTry: secondTryAllowed(), body) {
        case .passed: passed += 1; if verbose { print("ok   \(name)") }
        case .passedOnSecondTry: passed += 1; passedOnSecondTry.append(name); print("ok   \(name) (on the second try)")
        case .failed: print("FAIL \(name)")
        }
    }
    static func fail(_ what: String, file: String = #fileID, line: Int = #line) {
        failed += 1
        failures.append("\(current): \(what) (\(file):\(line))")
        if !quiet { print("     \(what) (\(file):\(line))") }
    }
    static func finish() -> Never {
        if !passedOnSecondTry.isEmpty {
            print("\(passedOnSecondTry.count) passed only on a second try: \(passedOnSecondTry.joined(separator: ", "))")
        }
        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

func check(_ condition: @autoclosure () -> Bool, _ what: String, file: String = #fileID, line: Int = #line) {
    if !condition() { Harness.fail(what, file: file, line: line) }
}
func expect<T: Equatable>(_ got: T, _ want: T, _ what: String = "", file: String = #fileID, line: Int = #line) {
    if got != want { Harness.fail("\(what)\(what.isEmpty ? "" : ": ")got \(String(reflecting: got)), wanted \(String(reflecting: want))", file: file, line: line) }
}
func test(_ name: String, _ body: () throws -> Void) { Harness.test(name, body) }

/// A fixture by name, from Tests/Fixtures beside the sources.
func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures/\(name).json")
}
