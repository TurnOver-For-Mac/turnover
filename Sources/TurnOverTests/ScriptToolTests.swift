// SPDX-License-Identifier: GPL-3.0-or-later
// The turnover-plugin tool's script parts (docs/PLUGIN-SCRIPTS-PLAN.md, stage 2, 15 Nov 2026): the scenario runner that
// `turnover-plugin test` and this runner share, the script check, the starting plugin from `new`, and the sample plugin.
// They use the real sandboxed host program, which must be built beside this runner (--product turnover-plugin-host).
import Foundation
import TurnOverCore
import PluginTestKit

private let toolHostPath: String? = ScriptScenarioRunner.hostPath()
private let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

func scriptToolTests() {
    let fm = FileManager.default
    guard let host = toolHostPath else {
        test("script tool: the host program is built beside the test runner") { check(false, "no turnover-plugin-host beside the runner: build --product turnover-plugin-host into the same folder") }
        return
    }
    let sample = repositoryRoot.appendingPathComponent("plugins/examples/sample-script-calculator")

    /// A copy of a folder that the test may change, removed afterwards.
    func copy(of source: URL) -> URL {
        let folder = fm.temporaryDirectory.appendingPathComponent("turnover-tool-test-\(UUID().uuidString)")
        try? fm.copyItem(at: source, to: folder)
        return folder
    }
    func write(_ text: String, to path: String, in folder: URL) {
        let url = folder.appendingPathComponent(path)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
    /// Run one scenario file's text against a copy of the sample plugin (optionally with a changed main.js).
    func run(_ scenario: String, script: String? = nil) -> ScriptScenarioRunner.Outcome {
        let folder = copy(of: sample); defer { try? fm.removeItem(at: folder) }
        for old in ScriptScenarioRunner.scenarioFiles(in: folder) { try? fm.removeItem(at: old) }
        write(scenario, to: "tests/script/test.json", in: folder)
        if let script { write(script, to: "main.js", in: folder) }
        return ScriptScenarioRunner.run(folder: folder, hostPath: host)
    }

    func report(script: String) -> ScriptChecker.Report {
        let folder = copy(of: sample); defer { try? fm.removeItem(at: folder) }
        write(script, to: "main.js", in: folder)
        return ScriptChecker.check(ProfileStore.load(folder: folder), hostPath: host)
    }

    test("script tool: the sample plugin loads, lists as ready, and its own tests pass") {
        let plugin = ProfileStore.load(folder: sample)
        expect(plugin.error, nil, "loads")
        expect(plugin.warnings, [], "no warnings")
        let listing = PluginListing.check(plugin, others: [])
        expect(listing.problems, 0, "ready to list: \(listing.lines)")
        let outcome = ScriptScenarioRunner.run(folder: sample, hostPath: host)
        expect(outcome.failed, 0, "the sample's tests: \(outcome.lines)")
        expect(outcome.passed, 1, "one test file, one test")
    }
    test("script tool: every plugin the repository carries with script tests passes them") {
        for dir in ["plugins/examples", "Tests/Plugins", "Resources/plugins"] {
            for folder in ScriptScenarioRunner.folders(under: repositoryRoot.appendingPathComponent(dir)) {
                let outcome = ScriptScenarioRunner.run(folder: folder, hostPath: host)
                for line in outcome.lines where line.hasPrefix("FAIL") || line.hasPrefix("     ") { print("   \(folder.lastPathComponent): \(line)") }
                expect(outcome.failed, 0, "\(folder.lastPathComponent)'s script tests")
                check(outcome.passed > 0, "\(folder.lastPathComponent) ran at least one")
            }
        }
    }
    test("script tool: a wrong expected answer fails and says what differed") {
        let outcome = run(#"{ "name": "wrong", "steps": [ { "event": "focus", "item": { "role": "button", "name": "Divide", "identifier": "Divide" }, "expect": { "say": "Delete, button" } } ] }"#)
        expect(outcome.failed, 1, "fails")
        let message = outcome.lines.joined(separator: "\n")
        check(message.contains("FAIL wrong: step 1 (focus)"), "says which test and step: \(message)")
        check(message.contains("\"Divided by, button\"") && message.contains("\"Delete, button\""), "says what it was and what was expected: \(message)")
    }
    test("script tool: silence and neither are told apart") {
        let item = #"{ "role": "button", "name": "Divide", "identifier": "Divide" }"#
        let silent = run(#"{ "steps": [ { "event": "focus", "item": \#(item), "expect": { "say": "" } } ] }"#)
        check(silent.lines.joined().contains("expected silence"), "silence expected, words given: \(silent.lines)")
        let neither = run(#"{ "steps": [ { "event": "focus", "item": \#(item), "expect": { "say": null } } ] }"#)
        check(neither.lines.joined().contains("nothing (TurnOver would read it as usual)"), "neither expected, words given: \(neither.lines)")
        let silence = run(#"{ "steps": [ { "event": "focus", "item": { "role": "button" }, "expect": { "say": "" } } ] }"#,
                          script: "turnover.on('focus', function (e) { e.silence(); });")
        expect(silence.passed, 1, "event.silence() is silence: \(silence.lines)")
    }
    test("script tool: a wrong list of things said fails and says what was said") {
        let outcome = run(#"{ "steps": [ { "command": "readResult", "answers": { "find": [ { "role": "text", "value": "42" } ] }, "expect": { "said": ["41"] } } ] }"#)
        expect(outcome.failed, 1, "fails")
        let message = outcome.lines.joined(separator: "\n")
        check(message.contains("the script said [\"42\"], but the test expected [\"41\"]"), message)
    }
    test("script tool: a request with no answer fails the test and says which") {
        let outcome = run(#"{ "steps": [ { "command": "readResult", "expect": { "said": ["There is no result to read"] } } ] }"#)
        expect(outcome.failed, 1, "fails")
        let message = outcome.lines.joined(separator: "\n")
        check(message.contains("the script asked for find, and the step has no answer for it"), message)
    }
    test("script tool: an answer can be an error, and a command's error can be expected") {
        let script = "turnover.command('readResult', async function () { try { await turnover.find({}); } catch (e) { turnover.say('failed: ' + e.message); } });\nturnover.on('focus', function () {});"
        let outcome = run(#"{ "steps": [ { "command": "readResult", "answers": { "find": { "error": "no window" } }, "expect": { "said": ["failed: no window"] } } ] }"#, script: script)
        expect(outcome.passed, 1, "the error reaches the script: \(outcome.lines)")
        let throws_ = "turnover.command('readResult', function () { throw new Error('boom'); });"
        let expected = run(#"{ "steps": [ { "command": "readResult", "expect": { "error": "boom" } } ] }"#, script: throws_)
        expect(expected.passed, 1, "an expected failure passes: \(expected.lines)")
        let unexpected = run(#"{ "steps": [ { "command": "readResult" } ] }"#, script: throws_)
        check(unexpected.lines.joined().contains("the command failed: boom"), "an unexpected one fails: \(unexpected.lines)")
        let missing = run(#"{ "steps": [ { "command": "readResult", "expect": { "error": "boom" } } ] }"#, script: "turnover.command('readResult', function () {});")
        check(missing.lines.joined().contains("finished without an error"), "an expected error that did not come: \(missing.lines)")
    }
    test("script tool: storage carries from one step to the next, and a script asking for more than its abilities is refused as in TurnOver") {
        let script = """
            turnover.on('focus', function () {});
            turnover.command('readResult', async function () {
              const n = (await turnover.storage.get('n')) || 0;
              await turnover.storage.set('n', n + 1);
              turnover.say('count ' + (n + 1));
              try { await turnover.keys('command+k'); } catch (e) { turnover.say(e.message.slice(0, 22)); }
            });
            """
        let outcome = run(#"{ "steps": [ { "command": "readResult", "expect": { "said": ["count 1", "This needs the keys ab"] } }, { "command": "readResult", "expect": { "said": ["count 2", "This needs the keys ab"] } } ] }"#, script: script)
        expect(outcome.passed, 1, "\(outcome.lines)")
    }
    test("script tool: a script that does not load, an unknown event and an unknown command fail the test in words") {
        let broken = run(#"{ "steps": [ { "event": "focus", "item": {} } ] }"#, script: "turnover.on('focus', function (e) {});\nvar x = ;\n")
        check(broken.lines.joined().contains("did not load") && broken.lines.joined().contains("main.js, line 2"), "\(broken.lines)")
        let event = run(#"{ "steps": [ { "event": "typing", "item": {} } ] }"#)
        check(event.lines.joined().contains("\"typing\" is not an event"), "\(event.lines)")
        let command = run(#"{ "steps": [ { "command": "nope" } ] }"#)
        check(command.lines.joined().contains("no handler for the command \"nope\""), "\(command.lines)")
        let neither = run(#"{ "steps": [ { "item": {} } ] }"#)
        check(neither.lines.joined().contains("needs an \"event\" or a \"command\""), "\(neither.lines)")
        let junk = run("not json")
        check(junk.failed == 1 && junk.lines.joined().contains("is not valid JSON"), "\(junk.lines)")
    }
    test("script tool: events that nothing replaces are told, and comments in a test file are allowed") {
        let outcome = run("""
            // a comment
            [ { "name": "told", "steps": [ { "event": "appFocus", "item": {}, /* more */ "expect": { "said": [] } } ] },
              { "name": "second", "steps": [ { "event": "appFocus", "expect": { "say": "x" } } ] }, ]
            """, script: "turnover.on('appFocus', function () {});")
        expect(outcome.passed, 1, "the first passes")
        expect(outcome.failed, 1, "the second expects an answer where there is nothing to replace: \(outcome.lines)")
    }

    // MARK: Checking

    test("script tool: check reads what the real host reports ready, and passes the sample") {
        let report = ScriptChecker.check(ProfileStore.load(folder: sample), hostPath: host)
        expect(report.problems, [], "no problems")
        expect(report.warnings, [], "no warnings")
        expect(report.events, ["focus"], "the events")
        expect(report.commands, ["readResult"], "the commands")
    }
    test("script tool: check finds a syntax error, a command declared but not handled, one handled but not declared, and an unknown event") {
        let syntax = report(script: "turnover.on('focus', function (e) {});\nvar x = ;\n")
        check(syntax.problems.contains { $0.contains("main.js, line 2") }, "a syntax error with its line: \(syntax.problems)")
        let unhandled = report(script: "turnover.on('focus', function (e) {});")
        check(unhandled.problems.contains { $0.contains("command readResult is in manifest.json, but the script never handles it") }, "declared, not handled: \(unhandled.problems)")
        let undeclared = report(script: "turnover.command('readResult', function () {});\nturnover.command('extra', function () {});")
        check(undeclared.problems.contains { $0.contains("extra") && $0.contains("manifest.json") }, "handled, not declared: \(undeclared.problems)")
        let event = report(script: "turnover.on('typing', function (e) {});\nturnover.command('readResult', function () {});")
        check(event.problems.contains { $0.contains("Unknown event \"typing\"") }, "an event the interface does not have: \(event.problems)")
        let missingHost = ScriptChecker.check(ProfileStore.load(folder: sample), hostPath: nil)
        check(missingHost.problems.contains { $0.contains("turnover-plugin-host") }, "no host program is a problem in words")
    }
    test("script tool: check warns, as a guess, when the script seems to use what its abilities do not cover") {
        let folder = copy(of: sample); defer { try? fm.removeItem(at: folder) }
        write("""
            // turnover.keys("command+k") in a comment does not count
            turnover.on('focus', function (e) {});
            turnover.command('readResult', async function (c) {
              const list = [1, 2].find(function (x) { return x > 1; });   // an array's find is not turnover.find
              await turnover.menu(["Edit", "Copy"]);
              const item = await turnover.focused();
              await item.press();
              await item.setValue("x");
              await turnover.copy("y");
            });
            """, to: "main.js", in: folder)
        let report = ScriptChecker.check(ProfileStore.load(folder: folder), hostPath: host)
        expect(report.problems, [], "warnings are not errors")
        let text = report.warnings.joined(separator: "\n")
        for member in ["turnover.menu", "press(", "setValue", "turnover.copy"] { check(text.contains(member), "warns about \(member): \(text)") }
        for quiet in ["turnover.keys", "turnover.find", "turnover.focused"] { check(!text.contains(quiet), "does not warn about \(quiet): \(text)") }
        check(text.contains("a guess"), "says it is a guess: \(text)")
    }

    // MARK: Starting a plugin, and what consent says

    test("script tool: new makes a working script plugin whose check and test pass") {
        let folder = fm.temporaryDirectory.appendingPathComponent("My Cool Plugin-\(UUID().uuidString.prefix(6))")
        defer { try? fm.removeItem(at: folder) }
        let written = try PluginScaffold.make(folder: folder, app: "com.apple.calculator", script: true)
        expect(written.sorted(), ["main.js", "manifest.json", "profile.json", "tests/script/first.json"], "the files")
        let plugin = ProfileStore.load(folder: folder)
        expect(plugin.error, nil, "it loads: \(plugin.error ?? "")")
        expect(plugin.manifest?.formatVersion, 2, "format 2")
        expect(plugin.manifest?.apps, ["com.apple.calculator"], "its app")
        check(PluginManifest.isValidID(plugin.manifest?.id ?? ""), "a good id: \(plugin.manifest?.id ?? "")")
        let report = ScriptChecker.check(plugin, hostPath: host)
        expect(report.problems, [], "the check passes")
        expect(report.warnings, [], "with no warnings")
        let outcome = ScriptScenarioRunner.run(folder: folder, hostPath: host)
        expect(outcome.failed, 0, "its first test passes: \(outcome.lines)")
        expect(outcome.passed, 1, "and runs")
        for file in written { check((try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8))?.contains("//") ?? false, "\(file) teaches in comments") }
        var again = false
        do { _ = try PluginScaffold.make(folder: folder, app: "com.apple.calculator", script: true) } catch { again = true }
        check(again, "it does not write into a folder that has files")
        var badApp = false
        do { _ = try PluginScaffold.make(folder: folder.appendingPathExtension("2"), app: "Calculator", script: true) } catch { badApp = true }
        check(badApp, "an app name that is not a bundle identifier is refused")
    }
    test("script tool: new without --script makes a data plugin that loads in format 1 style") {
        let folder = fm.temporaryDirectory.appendingPathComponent("data-plugin-\(UUID().uuidString.prefix(6))")
        defer { try? fm.removeItem(at: folder) }
        let written = try PluginScaffold.make(folder: folder, app: "com.apple.calculator", script: false)
        expect(written.sorted(), ["manifest.json", "profile.json", "tests/expect.json"], "the files")
        let plugin = ProfileStore.load(folder: folder)
        expect(plugin.error, nil, "it loads: \(plugin.error ?? "")")
        expect(plugin.manifest?.script, nil, "no script")
        expect(plugin.manifest?.formatVersion, nil, "and no format 2")
        expect(PluginScaffold.identifier(from: "My Cool_Plugin!"), "my-cool-plugin", "ids from folder names")
    }
    test("script tool: consent prints the plan's words for the sample, with its hash") {
        let plugin = ProfileStore.load(folder: sample)
        let lines = ScriptAbilities.approvalLines(for: plugin, appName: { _ in "Calculator" }).map(\.text)
        check(lines[0].contains("Calculator, scripted") && lines[0].contains("Calculator"), "names the plugin and the app: \(lines[0])")
        check(lines.contains { $0.contains("The author's own words about it") && $0.contains("Divide and Multiply buttons") }, "the author's words, marked: \(lines)")
        check(lines.contains { $0.contains("read what is on the screen") } && lines.contains { $0.contains("speak") }, "read and say")
        check(!lines.contains { $0.contains("clipboard") && $0.hasPrefix("It can put") }, "and nothing it did not ask for")
        check(lines.last?.contains("Nobody has checked this script") ?? false, "unchecked, last")
        expect(plugin.scriptHash, ScriptTrust.hash(folder: sample), "the hash consent prints")
    }
}
