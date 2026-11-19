// SPDX-License-Identifier: GPL-3.0-or-later
// turnover-plugin-host: runs one plugin's script for TurnOver (docs/PLUGIN-SCRIPTS-PLAN.md, 15 Nov 2026).
// Started by TurnOver with its permissions disclaimed. It locks itself in a sandbox first, then reads messages from
// standard input and answers on standard output; it ends when its input closes or it is told `bye`. It depends on
// nothing of TurnOver's but the wire definitions.
//
//   turnover-plugin-host              serve TurnOver (exit status 3: the sandbox could not be applied)
//   turnover-plugin-host --self-test  apply the sandbox and check it refuses what it must; exit 0 if all is well
import Foundation
import TurnOverPluginWire

if CommandLine.arguments.dropFirst().contains("--self-test") { exit(SelfTest.run()) }

signal(SIGPIPE, SIG_IGN)
if let reason = Sandbox.apply() {
    Output.complain("turnover-plugin-host: the sandbox could not be applied: \(reason)")
    exit(3)
}

InputReader.start()
// Not dispatchMain(): under it MainActor.assumeIsolated failed its main-thread check in blocks run from the main queue
// (observed 15 Nov 2026, macOS 27.2). The run loop serves the main queue and the main-queue timers alike.
RunLoop.main.run()
