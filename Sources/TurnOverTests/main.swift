// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore
import AXFixtures
import PluginTestKit

setvbuf(stdout, nil, _IONBF, 0)
// The replay shim must be loaded by dyld at launch: start again with it inserted, once.
if !AXReplay.isAvailable, ProcessInfo.processInfo.environment["TURNOVER_TESTS_RELAUNCHED"] == nil {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    let shim = AXReplay.shimPath(besides: exe)
    if FileManager.default.fileExists(atPath: shim) {
        setenv("DYLD_INSERT_LIBRARIES", shim, 1)
        setenv("TURNOVER_TESTS_RELAUNCHED", "1", 1)
        let argv = CommandLine.arguments.map { strdup($0) } + [nil]
        execv(exe, argv)
        print("could not start again with the shim: \(String(cString: strerror(errno)))")
    } else {
        print("(no \(shim): fixture tests will fail)")
    }
}
Log.level = .error
Speech.mode = .off
Speech.sink = { _ in }

pureTests()
speechQueueWatchTests()
speechRecoveryAttemptTests()
recoveryWarningTests()
speechOutputTests()
characterBoundaryTests()
keyboardPrivacyTests()
braillePrivacyTests()
feedbackPrivacyTests()
flatScreenTests()
controlChannelTests()
browseTextNavTests()
gamesTests()
fixtureTests()
focusRuleTests()
scaleTests()
pluginTests()
pluginLibraryTests()
pluginArchiveTests()
pluginPolicyTests()
policyTests()
keyboardSessionTests()
axQueryResultTests()
activityTests()
activityRealExportTest()
Harness.finish()
