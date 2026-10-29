// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverSpeech

private func warningWait(_ condition: () -> Bool) -> Bool {
    let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(3))
    while !condition(), clock.now < deadline { Thread.sleep(forTimeInterval: 0.005) }
    return condition()
}

private func startBlockedWarning(_ warning: RecoveryWarning, ready: URL, input: Pipe) -> Bool {
    // The test keeps the pipe's write end open until cleanup. The shell's own read then stays blocked, without
    // relying on a timed external command or leaving descendants behind (CI failure, 28 Oct 2026).
    let script = "trap '' TERM\nprintf ready > \"$1\"\nIFS= read -r line"
    return warning.start(executable: URL(fileURLWithPath: "/bin/sh"),
                         arguments: ["-c", script, "warning-test", ready.path], input: input.fileHandleForReading)
}

func recoveryWarningTests() {
    test("speech recovery: no warning and a failed launch never delay recovery") {
        let warning = RecoveryWarning()
        defer { warning.cancel() }
        check(warning.wait(timeout: 0), "no warning has nothing to wait for")
        check(!warning.start(executable: URL(fileURLWithPath: "/no-such-turnover-warning"), arguments: []), "failed launch reported")
        check(warning.wait(timeout: 0), "failed launch has no pending completion")
        check(!warning.isRunning, "failed launch leaves no child")
    }

    test("speech recovery: an exited warning can be waited for repeatedly") {
        let warning = RecoveryWarning()
        defer { warning.cancel() }
        check(warning.start(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: []), "silent warning starts")
        check(warningWait { !warning.isRunning }, "child exits before the wait")
        check(warning.wait(timeout: 1), "completed warning is observed")
        check(warning.wait(timeout: 0), "completion remains available to later waits")
        check(warning.start(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: []), "a later warning can start")
        check(warning.wait(timeout: 1), "later warning has its own completion")
    }

    test("speech recovery: a warning ignoring SIGTERM cannot hold up restart") {
        let warning = RecoveryWarning()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("turnover-warning-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let input = Pipe()
        defer {
            warning.cancel()
            try? input.fileHandleForWriting.close(); try? input.fileHandleForReading.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let ready = directory.appendingPathComponent("ready")
        guard startBlockedWarning(warning, ready: ready, input: input) else {
            return Harness.fail("silent hanging warning could not start")
        }
        guard warningWait({ FileManager.default.fileExists(atPath: ready.path) }) else {
            return Harness.fail("child did not confirm it ignores SIGTERM: \(warning.terminationDescription)")
        }
        check(!warning.start(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: []), "a second warning cannot overlap")
        // A broken unbounded wait is released by this test-only backstop, so the regression fails rather than
        // leaving the test executable and its child hung. It is not the production timeout under test.
        // WorkItem does not infer a Sendable closure: keep this off main even when the test inherits MainActor.
        let backstop = DispatchWorkItem { @Sendable in warning.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: backstop)
        defer { backstop.cancel() }
        let clock = ContinuousClock(), began = clock.now
        let completed = warning.wait(timeout: 0.05)
        check(!completed, "deadline expiration is reported: \(warning.terminationDescription)")
        check(began.duration(to: clock.now) < .seconds(1), "restart is released by its deadline, not the test backstop")
        check(warningWait { !warning.isRunning }, "timed-out child is stopped")
        check(warning.wait(timeout: 1), "child termination can still be observed after a timeout")
    }

    test("speech recovery: cancelling an old warning does not complete its replacement") {
        let warning = RecoveryWarning()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("turnover-warning-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let oldInput = Pipe(), newInput = Pipe()
        defer {
            warning.cancel()
            for input in [oldInput, newInput] {
                try? input.fileHandleForWriting.close(); try? input.fileHandleForReading.close()
            }
            try? FileManager.default.removeItem(at: directory)
        }
        let oldReady = directory.appendingPathComponent("old-ready"), newReady = directory.appendingPathComponent("new-ready")
        guard startBlockedWarning(warning, ready: oldReady, input: oldInput) else {
            return Harness.fail("first silent warning could not start")
        }
        guard warningWait({ FileManager.default.fileExists(atPath: oldReady.path) }) else {
            return Harness.fail("first warning did not become ready: \(warning.terminationDescription)")
        }
        warning.cancel()
        check(warningWait { !warning.isRunning }, "old child exits")
        guard startBlockedWarning(warning, ready: newReady, input: newInput) else {
            return Harness.fail("replacement silent warning could not start")
        }
        guard warningWait({ FileManager.default.fileExists(atPath: newReady.path) }) else {
            return Harness.fail("replacement warning did not become ready: \(warning.terminationDescription)")
        }
        let backstop = DispatchWorkItem { @Sendable in warning.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: backstop)
        defer { backstop.cancel() }
        let completed = warning.wait(timeout: 0.05)
        check(!completed, "the replacement still needs its own termination: \(warning.terminationDescription)")
        check(warningWait { !warning.isRunning }, "replacement child is stopped on timeout")
    }
}
