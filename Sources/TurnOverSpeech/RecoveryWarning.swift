// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import os

/// The system voice used while TurnOver's own player is unavailable. Recovery must not depend on that voice
/// finishing: `say` can be stuck in the same audio service (speech recovery review, 28 Oct 2026).
package final class RecoveryWarning: Sendable {
    private final class Completion: Sendable {
        let group = DispatchGroup()
        private let finished = OSAllocatedUnfairLock(initialState: false)

        init() { group.enter() }

        func finish() {
            let first = finished.withLock { done in
                guard !done else { return false }
                done = true
                return true
            }
            if first { group.leave() }
        }
    }

    private struct Run {
        let process: Process
        let completion: Completion
    }

    // Process setup, isRunning checks, replacement and cancellation all belong to this lock. The termination
    // callback touches only its immutable Completion, so waiting never holds the process-owner lock.
    private let state = OSAllocatedUnfairLock<Run?>(initialState: nil)

    package init() {}

    /// False if an earlier warning is still running or the system voice could not be started.
    @discardableResult
    package func say(_ text: String) -> Bool {
        start(executable: URL(fileURLWithPath: "/usr/bin/say"), arguments: [text])
    }

    /// The test executable supplies silent system tools; production starts only the system voice above.
    @discardableResult
    package func start(executable: URL, arguments: [String], input: FileHandle? = nil) -> Bool {
        state.withLock { current in
            guard current?.process.isRunning != true else { return false }
            let process = Process(), completion = Completion()
            process.executableURL = executable
            process.arguments = arguments
            process.standardInput = input ?? FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in completion.finish() }
            do {
                try process.run()
                current = Run(process: process, completion: completion)
                return true
            } catch {
                completion.finish()
                return false
            }
        }
    }

    /// Wait only for the warning observed on entry. The completion group is reusable: an already-finished warning
    /// and later waits return immediately. A timeout kills this owned child, without another blocking wait.
    @discardableResult
    package func wait(timeout: TimeInterval = 2) -> Bool {
        guard let run = state.withLock({ $0 }) else { return true }
        let seconds = timeout.isFinite ? max(0, timeout) : 0
        if run.completion.group.wait(timeout: .now() + seconds) == .success { return true }
        state.withLock { current in
            // A completed warning can have been replaced while this caller waited; never stop its successor.
            guard let current, current.process === run.process else { return }
            stop(current.process)
        }
        return false
    }

    /// Also used by teardown. SIGKILL is limited to our still-running child: a stuck voice can ignore SIGTERM,
    /// and waiting for it again would defeat the restart deadline (28 Oct 2026).
    package func cancel() {
        state.withLock { current in
            if let current { stop(current.process) }
        }
    }

    private func stop(_ process: Process) {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    package var isRunning: Bool { state.withLock { $0?.process.isRunning == true } }

    /// Test failure context, read only once the owned child has stopped.
    package var terminationDescription: String {
        state.withLock { current in
            guard let process = current?.process else { return "no warning child" }
            guard !process.isRunning else { return "warning child is still running" }
            let reason = process.terminationReason == .exit ? "exit" : "signal"
            return "warning child ended: \(reason) \(process.terminationStatus)"
        }
    }

    deinit { cancel() }
}
