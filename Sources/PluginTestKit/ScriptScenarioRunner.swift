// SPDX-License-Identifier: GPL-3.0-or-later
// Tests that travel with a plugin's script (docs/PLUGIN-SCRIPTS-PLAN.md, "Tools and tests for authors"; 15 Nov 2026).
//
// A plugin with a script may carry tests/script/*.json. Each file is one scenario (or a list of them), run against the
// real sandboxed host program with no app and no permissions: the test supplies what the app would have answered.
// Comments and trailing commas are allowed, as in the plugin's other files.
//
//   { "name": "reads the result",
//     "steps": [
//       { "event": "focus", "item": { "role": "button", "name": "", "identifier": "clear" },
//         "expect": { "say": "Clear, button" } },
//       { "command": "readResult",
//         "answers": { "find": [ { "role": "staticText", "value": "42", "description": "Edit field" } ] },
//         "expect": { "said": ["42"] } } ] }
//
// A scenario starts the script fresh (a new host program) and runs its steps in order; the script's own memory and
// turnover.storage carry from one step to the next. A step is one of:
//
//   "event":   one of focus, valueChange, appFocus, appBlur, windowChange, optionsChange, speech. "item" is the item the
//              event carries: an object with whatever the script reads (role, name, value, identifier, states …). An
//              optionsChange step gives "id" and "value" (the option's new value, which the option must allow: it is also what
//              turnover.options.get gives from then on); a speech step gives "text" (what TurnOver said), and the plugin
//              needs hearSpeech to be sent it.
//   "command": one of the commands in manifest.json. "item" is optional: it is context.item, the item with the focus
//              when the command was chosen.
//
// and may have:
//
//   "answers": what TurnOver answers when the script asks it something in this step, by operation: focused, find,
//              item.refresh, item.parent, item.children, item.read, item.press, item.focus, item.setValue, item.text,
//              item.setCaret, item.select, menu, keys, copy, clipboard, choose, ask. The answer is the JSON the script gets
//              back: for choose, the text of the item the person chose (one of the script's items) or null if they dismissed
//              the list; for ask, the text typed or null; for item.text and clipboard, the text. An item (or a list of them) is written like
//              the step's "item", and TurnOver gives each one a handle. An answer {"error": "…"} makes the request
//              fail with that message. The same answer serves every time the script asks in that step. A question with
//              no answer fails the test and says which. turnover.storage needs no answer: it keeps what is stored.
//   "expect":  "say"   what the event's answer was, for focus and valueChange: text; "" for silence (the script called
//                      event.silence()); null for neither (TurnOver would read as usual). Left out: not checked.
//              "said"  the texts turnover.say was called with in this step, in order. Left out: not checked.
//              "tones" the tones turnover.tone played in this step, as [hertz, milliseconds], in order. Left out: not checked.
//              "asked" the questions the script put in this step, in order: {"choose": "title", "items": [...]} or
//                      {"ask": "prompt"}. Left out: not checked.
//
// A scenario may also have "options": {"id": value}, the values its options start with (the manifest's defaults otherwise).
//              "error" for a command: some words the command's failure message must contain. Left out: the
//                      command must finish without an error.
//
// Requests are ability-checked as in TurnOver, against the abilities the plugin really has (its manifest and its
// profile.json together), so a script that asks for more than its manifest says fails here as it would there.
import Foundation
import TurnOverCore
import TurnOverPluginWire

public enum ScriptScenarioRunner {
    public struct Outcome {
        public var passed = 0
        public var failed = 0
        public var lines: [String] = []
    }

    /// The test files of a plugin folder.
    public static func scenarioFiles(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("tests/script"), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
    }

    /// Every plugin folder under `root` whose tests/script holds a test file.
    public static func folders(under root: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { !scenarioFiles(in: $0).isEmpty }.sorted { $0.path < $1.path }
    }

    /// The host program: beside this program, or in ../Helpers/ when this program is inside TurnOver.app (Contents/MacOS).
    public static func hostPath(besides executable: String = CommandLine.arguments[0]) -> String? {
        let directory = URL(fileURLWithPath: executable).resolvingSymlinksInPath().deletingLastPathComponent()
        let candidates = [directory.appendingPathComponent("turnover-plugin-host"),
                          directory.deletingLastPathComponent().appendingPathComponent("Helpers/turnover-plugin-host")]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }?.path
    }

    /// Run every script test of a plugin folder.
    public static func run(folder: URL, hostPath: String) -> Outcome {
        var outcome = Outcome()
        let plugin = ProfileStore.load(folder: folder)
        guard plugin.error == nil, let manifest = plugin.manifest else {
            outcome.failed = 1; outcome.lines = ["FAIL the plugin does not load: \(plugin.error ?? "?")"]; return outcome
        }
        guard let source = plugin.script else {
            outcome.lines = ["\(manifest.name): no script, so no script tests"]; return outcome
        }
        let files = scenarioFiles(in: folder)
        if files.isEmpty { outcome.lines = ["\(manifest.name): no script tests (tests/script/*.json)"]; return outcome }
        for file in files {
            let scenarios: [[String: Any]]
            do { scenarios = try read(file) } catch {
                outcome.failed += 1; outcome.lines.append("FAIL \(file.lastPathComponent): \(error)"); continue
            }
            for (i, scenario) in scenarios.enumerated() {
                let label = scenario["name"] as? String ?? (scenarios.count == 1 ? file.lastPathComponent : "\(file.lastPathComponent), test \(i + 1)")
                let failures = Scenario(plugin: plugin, source: source, hostPath: hostPath).run(scenario)
                if failures.isEmpty { outcome.passed += 1; outcome.lines.append("ok   \(label)") }
                else {
                    outcome.failed += 1
                    outcome.lines.append("FAIL \(label): \(failures[0])")
                    for more in failures.dropFirst() { outcome.lines.append("     \(more)") }
                }
            }
        }
        return outcome
    }

    private struct FileProblem: Error, CustomStringConvertible { var description: String }

    private static func read(_ file: URL) throws -> [[String: Any]] {
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { throw FileProblem(description: "cannot be read as UTF-8 text") }
        do {
            let object = try JSONSerialization.jsonObject(with: Data(PluginFormat.clean(raw).utf8))
            if let one = object as? [String: Any] { return [one] }
            if let many = object as? [[String: Any]] { return many }
        } catch { throw FileProblem(description: "is not valid JSON (\(error.localizedDescription))") }
        throw FileProblem(description: "should be one test in { } or a list of tests in [ ]")
    }

    // MARK: One scenario

    /// What the script asks TurnOver for, answered from the step's "answers". Main actor, like every broker.
    private final class ScenarioBroker: ScriptBroker {
        var answers: [String: ScriptValue] = [:]
        var said: [String] = []
        var tones: [[Double]] = []
        var asked: [ScriptValue] = []
        var failures: [String] = []
        var storage: [String: ScriptValue] = [:]
        var lastActivity = Date()
        var step = ""
        var handles = 0

        func perform(_ operation: ScriptOperation, _ arguments: ScriptValue) throws -> ScriptValue {
            lastActivity = Date()
            switch operation {
            case .say: said.append(arguments["text"]?.stringValue ?? ""); return .null
            case .sound, .log: return .null
            case .tone: tones.append([arguments["hertz"]?.numberValue ?? 0, arguments["milliseconds"]?.numberValue ?? 0]); return .null
            case .storageGet: return storage[arguments["key"]?.stringValue ?? ""] ?? .null
            case .storageSet: storage[arguments["key"]?.stringValue ?? ""] = arguments["value"] ?? .null; return .null
            case .storageRemove: storage[arguments["key"]?.stringValue ?? ""] = nil; return .null
            default:
                guard let answer = answers[operation.rawValue] else {
                    failures.append("\(step): the script asked for \(operation.rawValue), and the step has no answer for it: add \"\(operation.rawValue)\" to its \"answers\"")
                    throw ScriptBrokerError.failed("The test gave no answer for \(operation.rawValue).")
                }
                if case .object(let fields) = answer, fields.count == 1, let message = fields["error"]?.stringValue { throw ScriptBrokerError.refused(message) }
                return answer
            }
        }

        /// A question to the person, answered from the step's answers: the item chosen, the text typed, or null (dismissed).
        func perform(deferred operation: ScriptOperation, _ arguments: ScriptValue, completion: @escaping @MainActor (Result<ScriptValue, any Error>) -> Void) {
            guard operation == .choose || operation == .ask else { return completion(Result { try perform(operation, arguments) }) }
            lastActivity = Date()
            var items: [String] = []
            if operation == .choose {
                if case .array(let list)? = arguments["items"] { items = list.compactMap(\.stringValue) }
                asked.append(.object(["choose": .string(arguments["title"]?.stringValue ?? ""), "items": .array(items.map { .string($0) })]))
            } else {
                asked.append(.object(["ask": .string(arguments["prompt"]?.stringValue ?? "")]))
            }
            guard let answer = answers[operation.rawValue] else {
                failures.append("\(step): the script asked for \(operation.rawValue), and the step has no answer for it: add \"\(operation.rawValue)\" to its \"answers\" (the item chosen or the text typed, or null for dismissed)")
                return completion(.failure(ScriptBrokerError.failed("The test gave no answer for \(operation.rawValue).")))
            }
            if case .object(let fields) = answer, fields.count == 1, let message = fields["error"]?.stringValue { return completion(.failure(ScriptBrokerError.refused(message))) }
            if operation == .choose, case .string(let chosen) = answer, !items.contains(chosen) {
                failures.append("\(step): the test chose \"\(chosen)\", which is not one of the items the script offered (\(items.joined(separator: ", ")))")
                return completion(.success(.null))
            }
            if case .string = answer { return completion(.success(answer)) }
            completion(.success(.null))
        }

        /// Give each item in a value (an object with a role) the handle TurnOver would have given it.
        func withHandles(_ value: ScriptValue) -> ScriptValue {
            switch value {
            case .array(let list): return .array(list.map(withHandles))
            case .object(var fields):
                for (key, inner) in fields { fields[key] = withHandles(inner) }
                if fields["role"] != nil, fields["handle"] == nil { handles += 1; fields["handle"] = .number(Double(handles)) }
                return .object(fields)
            default: return value
            }
        }
    }

    private final class CommandOutcome { var result: ScriptCommandResult? }

    private struct Scenario {
        let plugin: LoadedPlugin
        let source: String
        let hostPath: String

        func run(_ scenario: [String: Any]) -> [String] {
            guard let manifest = plugin.manifest else { return ["the plugin does not load"] }
            guard let steps = scenario["steps"] as? [[String: Any]], !steps.isEmpty else { return ["the test has no \"steps\""] }
            let broker = ScenarioBroker()
            // The options start at the manifest's defaults, or the scenario's own values (which the option must allow).
            var values: [String: PluginOptionValue] = [:]
            var failures: [String] = []
            let declaredOptions = manifest.options ?? []
            for option in declaredOptions { values[option.id] = option.defaultValue }
            for (id, raw) in scenario["options"] as? [String: Any] ?? [:] {
                guard let option = declaredOptions.first(where: { $0.id == id }) else { failures.append("the test sets the option \"\(id)\", which manifest.json does not declare"); continue }
                guard let given = PluginOptionValue(any: raw), let ok = option.accepting(given) else { failures.append("the test gives the option \"\(id)\" a value it does not allow"); continue }
                values[id] = ok
            }
            if !failures.isEmpty { return failures }
            var limits = ScriptLimits()
            limits.eventDeadline = 2   // a test is not in the middle of speech; the real 25 ms is TurnOver's to keep
            limits.watchdogInterval = 0.02
            let host = ScriptHost(plugin: ScriptPluginInfo(id: manifest.id, name: manifest.name, version: manifest.version),
                                  abilities: ScriptAbilities.effective(for: plugin), commands: (manifest.commands ?? []).map(\.id),
                                  source: source, hostPath: hostPath, broker: broker, limits: limits, options: values.mapValues(\.scriptValue))
            defer { host.stop(); pumpRunLoop(1) { !host.isRunning } }
            host.start()
            pumpRunLoop(5) { if case .starting = host.state { return false } else { return true } }
            switch host.state {
            case .failed(let message): return ["the script did not load: \(message)"]
            case .starting: return ["the script did not start within 5 seconds"]
            default: break
            }
            for (i, step) in steps.enumerated() {
                let name = step["event"] as? String ?? step["command"] as? String ?? "?"
                broker.step = "step \(i + 1) (\(name))"
                broker.said = []; broker.tones = []; broker.asked = []; broker.failures = []
                broker.answers = (step["answers"] as? [String: Any] ?? [:]).mapValues { broker.withHandles(ScriptValue(json: $0)) }
                let expect = step["expect"] as? [String: Any] ?? [:]
                func fail(_ message: String) { failures.append("\(broker.step): \(message)") }
                if case .failed(let message) = host.state { fail("the script's program had stopped: \(message)"); break }
                let item = (step["item"]).map { broker.withHandles(ScriptValue(json: $0)) }
                broker.lastActivity = Date()
                let started = Date()
                if let event = step["event"] as? String {
                    guard PluginWire.eventNames.contains(event) else {
                        fail("\"\(event)\" is not an event (\(PluginWire.eventNames.joined(separator: ", ")))"); continue
                    }
                    if PluginWire.replaceableEvents.contains(event) {
                        let answer = host.ask(event, item: item)
                        if answer == .late { fail("the script did not answer within \(Int(limits.eventDeadline)) seconds") }
                        else if let want = expect["say"] {
                            let wanted: ScriptAnswer = (want as? String).map { .say($0) } ?? .unhandled
                            if answer != wanted { fail("the event was answered with \(describe(answer)), but the test expected \(describe(wanted))") }
                        }
                    } else {
                        if expect["say"] != nil { fail("\(event) has nothing to replace, so it has no \"say\" to expect") }
                        var data: ScriptValue?
                        if event == "optionsChange" {
                            guard let id = step["id"] as? String, let option = declaredOptions.first(where: { $0.id == id }) else { fail("an optionsChange step needs the \"id\" of an option manifest.json declares"); continue }
                            guard let given = PluginOptionValue(any: step["value"]), let ok = option.accepting(given) else { fail("the option \"\(id)\" does not allow that value"); continue }
                            values[id] = ok
                            host.setOptions(values.mapValues(\.scriptValue))
                            data = .object(["id": .string(id), "value": ok.scriptValue])
                        } else if event == "speech" {
                            guard let text = step["text"] as? String else { fail("a speech step needs the \"text\" TurnOver said"); continue }
                            data = .object(["text": .string(text)])
                        }
                        host.tell(event, item: item, data: data)
                    }
                    pumpRunLoop(3) { Date().timeIntervalSince(broker.lastActivity) > 0.08 && Date().timeIntervalSince(started) > 0.08 }
                } else if let command = step["command"] as? String {
                    let outcome = CommandOutcome()
                    host.run(command: command, item: item) { outcome.result = $0 }
                    pumpRunLoop(6) { outcome.result != nil }
                    pumpRunLoop(0.2) { Date().timeIntervalSince(broker.lastActivity) > 0.05 }
                    switch outcome.result {
                    case nil: fail("the command did not finish within 6 seconds")
                    case .done?:
                        if let want = expect["error"] as? String { fail("the command finished without an error, but the test expected one with \"\(want)\"") }
                    case .failed(let message)?:
                        if let want = expect["error"] as? String {
                            if !message.localizedCaseInsensitiveContains(want) { fail("the command failed with \"\(message)\", but the test expected an error with \"\(want)\"") }
                        } else { fail("the command failed: \(message)") }
                    }
                } else {
                    fail("a step needs an \"event\" or a \"command\"")
                    continue
                }
                failures += broker.failures
                if let want = expect["said"] as? [String], broker.said != want {
                    fail("the script said \(quoted(broker.said)), but the test expected \(quoted(want))")
                }
                if let want = expect["tones"] as? [[Double]], broker.tones != want {
                    fail("the script played the tones \(broker.tones), but the test expected \(want)")
                }
                if let want = expect["asked"] {
                    let wanted = ScriptValue(json: want)
                    if wanted != .array(broker.asked) { fail("the script asked \(broker.asked.map { String(describing: $0.json) }), but the test expected a different question") }
                }
            }
            return failures
        }

        private func quoted(_ list: [String]) -> String { "[" + list.map { "\"\($0)\"" }.joined(separator: ", ") + "]" }

        private func describe(_ answer: ScriptAnswer) -> String {
            switch answer {
            case .say(""): return "silence"
            case .say(let text): return "\"\(text)\""
            case .unhandled: return "nothing (TurnOver would read it as usual)"
            case .late: return "nothing in time"
            }
        }
    }
}

/// Run the main run loop until `condition` holds or the time is up: the host's answers arrive on it.
func pumpRunLoop(_ seconds: TimeInterval, until condition: () -> Bool) {
    let end = Date().addingTimeInterval(seconds)
    while !condition(), Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
}
