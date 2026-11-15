// SPDX-License-Identifier: GPL-3.0-or-later
// The plugin script engine (docs/PLUGIN-SCRIPTS-PLAN.md, stage 1, 15 Nov 2026): the real sandboxed host program,
// started the way TurnOver starts it, against a fake broker. The host program (turnover-plugin-host) must be built
// beside this runner: `swift build --product turnover-plugin-host` into the same folder.
import Foundation
import TurnOverCore
import TurnOverPluginWire

private final class FakeBroker: ScriptBroker {
    var calls: [(operation: ScriptOperation, arguments: ScriptValue)] = []
    var answers: [ScriptOperation: ScriptValue] = [:]
    var said: [String] = []
    var delay: TimeInterval = 0
    func perform(_ operation: ScriptOperation, _ arguments: ScriptValue) throws -> ScriptValue {
        calls.append((operation, arguments))
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if operation == .say, let text = arguments["text"]?.stringValue { said.append(text) }
        return answers[operation] ?? .null
    }
}

private let scriptHostPath: String = {
    let runner = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    return runner.deletingLastPathComponent().appendingPathComponent("turnover-plugin-host").path
}()

/// Run the main run loop until `condition` holds or the time is up (the way the other tests wait for what arrives later).
private func waitFor(_ seconds: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let until = Date().addingTimeInterval(seconds)
    while !condition(), Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    return condition()
}
private func settle(_ seconds: TimeInterval) { _ = waitFor(seconds) { false } }

private final class Strikes: @unchecked Sendable {   // appended and read on the main thread only
    var list: [ScriptStrike] = []
}

private struct Rig {
    let host: ScriptHost
    let broker: FakeBroker
    let strikes: Strikes
    init(_ source: String, abilities: Set<ScriptAbility> = [.say], commands: [String] = [], limits: ScriptLimits = fastLimits(), broker: FakeBroker = FakeBroker(),
         sounds: [String] = [], hostPath: String = scriptHostPath) {
        let strikes = Strikes()
        host = ScriptHost(plugin: ScriptPluginInfo(id: "test-plugin", name: "Test", version: "1.0"), abilities: abilities, commands: commands,
                          source: source, hostPath: hostPath, broker: broker, limits: limits, sounds: sounds)
        host.onStrike = { strikes.list.append($0) }
        self.broker = broker; self.strikes = strikes
    }
    /// Start and wait until the script has loaded (or failed).
    @discardableResult func start() -> ScriptHostState {
        host.start()
        _ = waitFor(5) { if case .starting = host.state { return false } else { return true } }
        return host.state
    }
    func ask(_ event: String = "focus", _ item: ScriptValue = .object([:])) -> ScriptAnswer { host.ask(event, item: item) }
}

private func fastLimits() -> ScriptLimits {
    var limits = ScriptLimits()
    limits.watchdogInterval = 0.01
    return limits
}

func scriptHostTests() {
    guard FileManager.default.isExecutableFile(atPath: scriptHostPath) else {
        test("script host: the host program is built beside the test runner") { check(false, "no \(scriptHostPath): build --product turnover-plugin-host into the same folder") }
        return
    }

    test("script host: the self-test passes") {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: scriptHostPath)
        process.arguments = ["--self-test"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        expect(process.terminationStatus, 0, "the self-test's exit status (output: \(output))")
        expect(output.split(separator: "\n").filter { $0.hasPrefix("ok") }.count, 7, "seven checks passed")
        check(!output.contains("FAIL"), "no check failed: \(output)")
    }

    test("script host: every operation has an entry in the ability table") {
        for operation in ScriptOperation.allCases {
            let needs = ScriptAbilities.required(for: operation)
            check(ScriptAbilities.missing(for: operation, granted: Set(ScriptAbility.allCases)).isEmpty, "\(operation) is allowed with every ability")
            if !needs.isEmpty { check(!ScriptAbilities.missing(for: operation, granted: []).isEmpty, "\(operation) needs something") }
        }
        expect(ScriptAbilities.required(for: .itemRead), [.read, .say], "item.read reads and says")
        expect(ScriptAbilities.required(for: .itemSetValue), [.edit], "setValue is edit")
        expect(ScriptAbilities.required(for: .copy), [.clipboard], "copy is clipboard")
        expect(ScriptAbilities.required(for: .log), [], "log needs nothing")
    }

    test("script host: lines longer than the limit are dropped whole, however the pipe cuts them") {
        var framer = LineFramer(maxBytes: 10)
        expect(framer.add(Data("ab\ncd".utf8)), [.line(Data("ab".utf8))], "a whole line, and a part")
        expect(framer.add(Data("e\n".utf8)), [.line(Data("cde".utf8))], "the part finishes")
        expect(framer.add(Data("0123456789AB".utf8)), [.tooLong], "too long is reported once, as soon as it is known")
        expect(framer.add(Data("more and more".utf8)), [], "the rest is thrown away")
        expect(framer.add(Data("end\nok\n".utf8)), [.line(Data("ok".utf8))], "the next line after the long one is whole")
        expect(framer.add(Data("0123456789AB\nx\n".utf8)), [.tooLong, .line(Data("x".utf8))], "a long line that ends in the same read")
    }

    test("script host: a script that registers handlers becomes ready with its events and commands") {
        let rig = Rig("""
            turnover.on('focus', function (e) {});
            turnover.on('valueChange', function (e) {});
            turnover.command('readResult', function () {});
            """, commands: ["readResult", "other"])
        defer { rig.host.stop() }
        expect(rig.start(), .ready(events: ["focus", "valueChange"], commands: ["readResult"]), "the host's state")
        expect(rig.host.events, ["focus", "valueChange"], "events")
        expect(rig.host.commands, ["readResult"], "commands")
    }

    test("script host: a script's syntax error fails with the line number") {
        let rig = Rig("turnover.say('fine');\nvar x = ;\n")
        defer { rig.host.stop() }
        guard case .failed(let message) = rig.start() else { return check(false, "expected a failure, got \(rig.host.state)") }
        check(message.contains("main.js, line 2"), "the message names the file and line: \(message)")
        check(waitFor(3) { !rig.host.isRunning }, "the host program is ended after a failure")
        expect(rig.strikes.list, [], "a script that does not load is not a strike")
    }

    test("script host: an undeclared command fails the load, in words") {
        let rig = Rig("turnover.command('nope', function () {});", commands: ["other"])
        defer { rig.host.stop() }
        guard case .failed(let message) = rig.start() else { return check(false, "expected a failure") }
        check(message.contains("nope") && message.contains("manifest.json"), "the message names the command: \(message)")
    }

    test("script host: a focus question is answered with words, with silence, and unhandled") {
        let words = Rig("turnover.on('focus', function (e) { e.say('Item ' + e.item.name); });")
        defer { words.host.stop() }
        words.start()
        expect(words.ask("focus", .object(["name": .string("Clear"), "handle": .number(1)])), .say("Item Clear"), "words, with the item's name")

        let silence = Rig("turnover.on('focus', function (e) { e.silence(); });")
        defer { silence.host.stop() }
        silence.start()
        expect(silence.ask(), .say(""), "silence")

        let neither = Rig("turnover.on('focus', function (e) { var x = e.item; });")
        defer { neither.host.stop() }
        neither.start()
        expect(neither.ask(), .unhandled, "a handler that decides nothing")

        let none = Rig("turnover.on('valueChange', function (e) { e.say('v'); });")
        defer { none.host.stop() }
        none.start()
        expect(none.ask(), .unhandled, "no handler for the event")
        expect(none.ask("valueChange"), .say("v"), "the value event's handler")
    }

    test("script host: say or silence after the handler returned throws and tells the author to use turnover.say") {
        let broker = FakeBroker()
        let rig = Rig("""
            turnover.on('focus', function (e) {
              setTimeout(function () {
                try { e.say('late'); turnover.say('no error'); }
                catch (err) { turnover.say(err.message); }
              }, 60);
              e.say('first');
            });
            """, broker: broker)
        defer { rig.host.stop() }
        rig.start()
        expect(rig.ask(), .say("first"), "the words before the handler returned")
        check(waitFor(3) { !broker.said.isEmpty }, "the late call was reported")
        check(broker.said.first?.contains("turnover.say") ?? false, "the error names turnover.say: \(broker.said)")
        expect(broker.said.count, 1, "the late words were not spoken")
    }

    test("script host: a slow handler answers late, is struck once, and the host works again after it") {
        var limits = fastLimits()
        limits.eventDeadline = 0.05
        let rig = Rig("""
            var calls = 0;
            turnover.on('focus', function (e) {
              calls++;
              if (calls === 1) { var t = Date.now(); while (Date.now() - t < 300) {} }
              e.say('call ' + calls);
            });
            """, limits: limits)
        defer { rig.host.stop() }
        rig.start()
        var began = Date()
        expect(rig.ask(), .late, "the slow handler's answer is late")
        check(Date().timeIntervalSince(began) < 0.2, "the question came back within the deadline, not the handler's 300 ms")
        check(waitFor(2) { !rig.strikes.list.isEmpty }, "a strike was reported")
        expect(rig.strikes.list, [.lateAnswer], "one late answer")
        began = Date()
        expect(rig.ask(), .late, "while the host is busy, the next question is late at once")
        check(Date().timeIntervalSince(began) < 0.02, "and did not wait")
        var answer = ScriptAnswer.late
        let until = Date().addingTimeInterval(3)
        while answer == .late, Date() < until { answer = rig.ask(); settle(0.005) }   // asked once per turn: waitFor would ask twice
        check(answer != .late, "questions work again after the handler finishes")
        expect(answer, .say("call 2"), "the handler ran once more, so the skipped question never reached it")
        expect(rig.strikes.list, [.lateAnswer], "no further strike")
    }

    test("script host: an endless loop is killed after the limit and struck") {
        var limits = fastLimits()
        limits.eventDeadline = 0.05
        limits.killLimit = 0.4
        let rig = Rig("turnover.on('focus', function (e) { while (true) {} });", limits: limits)
        defer { rig.host.stop() }
        rig.start()
        let pid = rig.host.processID
        expect(rig.ask(), .late, "the loop never answers")
        check(waitFor(3) { !rig.host.isRunning }, "the host program was ended")
        if case .failed = rig.host.state {} else { check(false, "the state is failed: \(rig.host.state)") }
        check(waitFor(1) { rig.strikes.list.count == 2 }, "two strikes: \(rig.strikes.list)")
        expect(rig.strikes.list.first, .lateAnswer, "first the late answer")
        if case .killed? = rig.strikes.list.last {} else { check(false, "then a kill: \(rig.strikes.list)") }
        if let pid { check(Darwin.kill(pid, 0) != 0, "the process is gone") }
        expect(rig.ask(), .unhandled, "a dead host is not asked")
    }

    test("script host: a script that never finishes loading is killed after the start limit") {
        var limits = fastLimits()
        limits.startLimit = 0.4
        let rig = Rig("while (true) {}", limits: limits)
        defer { rig.host.stop() }
        guard case .failed = rig.start() else { return check(false, "expected a failure, got \(rig.host.state)") }
        check(waitFor(3) { !rig.host.isRunning }, "the host program was ended")
        check(waitFor(1) { rig.strikes.list.count == 1 }, "one strike: \(rig.strikes.list)")
    }

    test("script host: a script that burns the processor is killed") {
        var limits = fastLimits()
        limits.cpuWindow = 0.6
        let rig = Rig("setInterval(function () { var t = Date.now(); while (Date.now() - t < 45) {} }, 50);", limits: limits)
        defer { rig.host.stop() }
        rig.start()
        check(waitFor(5) { !rig.host.isRunning }, "the host program was ended")
        if case .killed(let why)? = rig.strikes.list.last { check(why.contains("processor"), "the reason names the processor: \(why)") } else { check(false, "a kill was reported: \(rig.strikes.list)") }
    }

    test("script host: a script that takes too much memory is killed") {
        var limits = fastLimits()
        limits.memoryBytes = 60 * 1024 * 1024
        let rig = Rig("turnover.on('focus', function () { var a = new Array(15000000).fill(1); globalThis.keep = a; });", limits: limits)
        defer { rig.host.stop() }
        guard case .ready = rig.start() else { return check(false, "expected ready, got \(rig.host.state)") }
        _ = rig.ask()
        check(waitFor(5) { !rig.host.isRunning }, "the host program was ended")
        if case .killed(let why)? = rig.strikes.list.last { check(why.contains("memory"), "the reason names memory: \(why)") } else { check(false, "a kill was reported: \(rig.strikes.list)") }
    }

    test("script host: a host that crashes is struck and reported failed") {
        let rig = Rig("turnover.on('focus', function () {});")
        defer { rig.host.stop() }
        rig.start()
        if let pid = rig.host.processID { Darwin.kill(pid, SIGSEGV) }
        check(waitFor(3) { !rig.host.isRunning }, "the host program ended")
        check(waitFor(1) { !rig.strikes.list.isEmpty }, "a strike was reported")
        if case .crashed? = rig.strikes.list.last {} else { check(false, "the strike is a crash: \(rig.strikes.list)") }
        if case .failed = rig.host.state {} else { check(false, "the state is failed: \(rig.host.state)") }
    }

    test("script host: a request without its ability is rejected naming the ability, and the broker is not called") {
        let broker = FakeBroker()
        let rig = Rig("""
            turnover.on('focus', function (e) {
              turnover.find({ role: 'button' }).then(function () { turnover.say('found'); },
                function (err) { turnover.say('refused: ' + err.message); });
            });
            """, abilities: [.say], broker: broker)
        defer { rig.host.stop() }
        rig.start()
        _ = rig.ask()
        check(waitFor(3) { !broker.said.isEmpty }, "the script heard the refusal")
        check(broker.said.first?.contains("read") ?? false, "the message names the missing ability: \(broker.said)")
        check(!broker.calls.contains { $0.operation == .find }, "the broker never saw the request")
    }

    test("script host: an allowed request reaches the broker and its answer reaches the script") {
        let broker = FakeBroker()
        broker.answers[.focused] = .object(["name": .string("OK"), "role": .string("button"), "handle": .number(7)])
        let rig = Rig("""
            turnover.on('focus', function (e) {
              turnover.focused().then(function (item) { turnover.say('Focused ' + item.name + ' ' + item.role); return item.press(); })
                .then(function () { turnover.say('pressed'); });
            });
            """, abilities: [.say, .read, .press], broker: broker)
        defer { rig.host.stop() }
        rig.start()
        _ = rig.ask()
        check(waitFor(3) { broker.said.count == 2 }, "both things were said: \(broker.said)")
        expect(broker.said, ["Focused OK button", "pressed"], "what the script said")
        let press = broker.calls.first { $0.operation == .itemPress }
        expect(press?.arguments["handle"], .number(7), "the press carried the item's handle")
    }

    test("script host: a command runs and reports done, or the script's error") {
        let broker = FakeBroker()
        broker.answers[.focused] = .object(["name": .string("Seven")])
        let rig = Rig("""
            turnover.command('go', async function (ctx) { var i = await turnover.focused(); turnover.say('went ' + i.name); });
            turnover.command('fail', function () { throw new Error('boom'); });
            """, abilities: [.say, .read], commands: ["go", "fail"], broker: broker)
        defer { rig.host.stop() }
        rig.start()
        var result: ScriptCommandResult?
        rig.host.run(command: "go") { result = $0 }
        check(waitFor(3) { result != nil }, "the command finished")
        expect(result, .done, "the command's result")
        check(waitFor(3) { broker.said == ["went Seven"] }, "what it said: \(broker.said)")
        result = nil
        rig.host.run(command: "fail") { result = $0 }
        check(waitFor(3) { result != nil }, "the failing command finished")
        expect(result, .failed("boom"), "the error reaches TurnOver")
    }

    test("script host: more things said than the limit allows are dropped, and each is cut to the character limit") {
        var limits = fastLimits()
        limits.saysPerWindow = 3
        let broker = FakeBroker()
        let rig = Rig("""
            turnover.on('focus', function (e) {
              turnover.say('x'.repeat(600));
              for (var i = 0; i < 9; i++) turnover.say('n' + i);
            });
            """, limits: limits, broker: broker)
        defer { rig.host.stop() }
        rig.start()
        _ = rig.ask()
        check(waitFor(3) { broker.said.count >= 3 }, "some things were said")
        settle(0.3)
        expect(broker.said.count, 3, "only three were let through")
        expect(broker.said.first?.count, 500, "the long one was cut to 500 characters")
    }

    test("script host: requests beyond the rate are refused") {
        var limits = fastLimits()
        limits.requestsPerSecond = 5
        let broker = FakeBroker()
        let rig = Rig("""
            turnover.on('focus', function (e) {
              var refused = 0, done = 0;
              function finished() { if (done + refused === 20) setTimeout(function () { turnover.say(refused + ' refused'); }, 1100); }
              for (var i = 0; i < 20; i++) turnover.focused().then(function () { done++; finished(); }, function (err) { refused++; finished(); });
            });
            """, abilities: [.say, .read], limits: limits, broker: broker)
        defer { rig.host.stop() }
        rig.start()
        _ = rig.ask()
        check(waitFor(4) { !broker.said.isEmpty }, "the script saw every answer")
        expect(broker.calls.filter { $0.operation == .focused }.count, 5, "five requests were let through")
        expect(broker.said.first, "15 refused", "the rest were refused")
    }

    test("script host: requests that take too much of the main thread are refused") {
        var limits = fastLimits()
        limits.mainThreadSecondsPerSecond = 0.05
        let broker = FakeBroker()
        broker.delay = 0.04
        let rig = Rig("""
            turnover.on('focus', function (e) {
              var results = [];
              var next = function (n) {
                if (n === 5) { setTimeout(function () { turnover.say(results.join(',')); }, 1100); return; }
                turnover.focused().then(function () { results.push('ok'); next(n + 1); }, function (err) { results.push('refused'); next(n + 1); });
              };
              next(0);
            });
            """, abilities: [.say, .read], limits: limits, broker: broker)
        defer { rig.host.stop() }
        rig.start()
        _ = rig.ask()
        check(waitFor(6) { !broker.said.isEmpty }, "the script saw every answer")
        check(broker.said.first?.contains("refused") ?? false, "later requests were refused: \(broker.said)")
        // 15 Nov 2026: only the first is certain. On a busy Mac the first answer can take the whole
        // budget by itself, so the second is refused; "ok,ok" failed a full build that way.
        check(broker.said.first?.hasPrefix("ok") ?? false, "the first request, within the budget, was let through: \(broker.said)")
    }

    test("script host: a timer fires, does not fire while paused, and fires after resume") {
        let broker = FakeBroker()
        let rig = Rig("setInterval(function () { turnover.say('tick'); }, 50); setTimeout(function () { turnover.say('once'); }, 60);", broker: broker)
        defer { rig.host.stop() }
        rig.start()
        check(waitFor(3) { broker.said.filter { $0 == "tick" }.count >= 2 && broker.said.contains("once") }, "timers fired: \(broker.said)")
        rig.host.pause()
        expect(rig.host.state, .paused, "the state while paused")
        settle(0.3)   // what was already on its way arrives
        let ticks = broker.said.count
        settle(0.4)
        expect(broker.said.count, ticks, "nothing fired while paused")
        rig.host.resume()
        check(waitFor(3) { broker.said.count > ticks }, "a timer fired after resume")
        expect(broker.said.filter { $0 == "once" }.count, 1, "the one-shot fired once")
    }

    test("script host: a timer that came due while paused fires once on resume") {
        let broker = FakeBroker()
        let rig = Rig("setTimeout(function () { turnover.say('late timer'); }, 100);", broker: broker)
        defer { rig.host.stop() }
        rig.host.start()
        rig.host.pause()
        settle(0.5)
        expect(broker.said, [], "nothing while paused")
        rig.host.resume()
        check(waitFor(3) { broker.said == ["late timer"] }, "it fired after resume: \(broker.said)")
    }

    test("script host: fetch, require, process, XMLHttpRequest, WebSocket and importScripts are all undefined in the script") {
        let rig = Rig("""
            turnover.on('focus', function (e) {
              e.say([typeof fetch, typeof require, typeof process, typeof XMLHttpRequest, typeof WebSocket, typeof importScripts,
                     typeof module, typeof native, typeof print].join(','));
            });
            """)
        defer { rig.host.stop() }
        rig.start()
        expect(rig.ask(), .say("undefined,undefined,undefined,undefined,undefined,undefined,undefined,undefined,undefined"), "every one is undefined")
    }

    test("script host: the script sees turnover, console and the timers, and nothing else of the interface") {
        let rig = Rig("""
            var own = Object.getOwnPropertyNames(globalThis).filter(function (n) { return ['turnover','console','setTimeout','setInterval','clearTimeout','clearInterval'].indexOf(n) >= 0; }).sort();
            turnover.on('focus', function (e) { e.say(own.join(',') + ' ' + turnover.api + ' ' + turnover.plugin.id + ' ' + turnover.language); });
            """)
        defer { rig.host.stop() }
        rig.start()
        expect(rig.ask(), .say("clearInterval,clearTimeout,console,setInterval,setTimeout,turnover 1 test-plugin en"), "the interface")
    }

    test("script host: stopping the host ends its process") {
        let rig = Rig("turnover.on('focus', function () {});")
        rig.start()
        guard let pid = rig.host.processID else { return check(false, "no process") }
        rig.host.stop()
        check(waitFor(3) { !rig.host.isRunning }, "the host stopped")
        check(Darwin.kill(pid, 0) != 0, "the process is gone")
        expect(rig.host.state, .ended, "the state")
        expect(rig.strikes.list, [], "an ordinary stop is not a strike")
    }

    test("script host: a host stuck in a loop still ends when stopped") {
        var limits = fastLimits()
        limits.eventDeadline = 0.05
        let rig = Rig("turnover.on('focus', function (e) { while (true) {} });", limits: limits)
        rig.start()
        guard let pid = rig.host.processID else { return check(false, "no process") }
        expect(rig.ask(), .late, "the loop does not answer")
        rig.host.stop()
        check(waitFor(3) { !rig.host.isRunning }, "the host stopped")
        check(Darwin.kill(pid, 0) != 0, "the process is gone")
    }

    test("script host: an over-long message is refused") {
        let broker = FakeBroker()
        let rig = Rig("""
            turnover.on('focus', function (e) {
              turnover.storage.set('big', 'x'.repeat(300000)).then(function () { turnover.say('stored'); },
                function (err) { turnover.say('refused: ' + err.name); });
            });
            """, broker: broker)
        defer { rig.host.stop() }
        rig.start()
        _ = rig.ask()
        check(waitFor(3) { !broker.said.isEmpty }, "the script heard the refusal")
        expect(broker.said, ["refused: RangeError"], "the host would not send it")
        check(!broker.calls.contains { $0.operation == .storageSet }, "the broker never saw it")
    }

    test("script host: a question too large to send is not sent") {
        let rig = Rig("turnover.on('focus', function (e) { e.say('x'); });")
        defer { rig.host.stop() }
        rig.start()
        expect(rig.ask("focus", .object(["name": .string(String(repeating: "y", count: 300_000))])), .unhandled, "an item over the message limit")
        expect(rig.ask("focus", .object(["name": .string("small")])), .say("x"), "and the host is still fine")
    }

    // MARK: The fix pass after the independent review (16 Nov 2026)

    /// A program standing in for the host: a shell script that answers TurnOver's hello as the test says, so a host that
    /// misbehaves in ways the real one never would can be met. The caller removes it.
    func fakeHost(_ body: String) -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("turnover-fake-host-\(UUID().uuidString).sh")
        try? ("#!/bin/bash\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    test("script host: event.say and event.silence need the say ability in the code, not only in the checker") {
        let source = "turnover.on('focus', function (e) { e.say('hello'); }); turnover.on('valueChange', function (e) { e.silence(); });"
        let without = Rig(source, abilities: [.read])
        defer { without.host.stop() }
        without.start()
        expect(without.ask("focus"), .unhandled, "words from a script that may not say are not used")
        expect(without.ask("valueChange"), .unhandled, "nor is its silence")
        let with = Rig(source, abilities: [.read, .say])
        defer { with.host.stop() }
        with.start()
        expect(with.ask("focus"), .say("hello"), "with the ability the words are used")
        expect(with.ask("valueChange"), .say(""), "and so is the silence")
    }

    test("script host: replacement words are cut to the character limit and count toward the rate; silence does not") {
        var limits = fastLimits()
        limits.saysPerWindow = 3
        limits.sayCharacters = 10
        let rig = Rig("turnover.on('focus', function (e) { e.say('0123456789ABCDEF'); }); turnover.on('valueChange', function (e) { e.silence(); });", limits: limits)
        defer { rig.host.stop() }
        rig.start()
        expect(rig.ask("focus"), .say("0123456789"), "cut to ten characters")
        _ = rig.ask("focus"); _ = rig.ask("focus")
        expect(rig.ask("focus"), .unhandled, "a fourth in the window is not used")
        for _ in 0..<5 { expect(rig.ask("valueChange"), .say(""), "silence is never counted") }
    }

    test("script host: item.read shares the speech budget") {
        var limits = fastLimits()
        limits.saysPerWindow = 4
        limits.requestsPerSecond = 1000
        let broker = FakeBroker()
        broker.answers[.focused] = .object(["handle": .string("h1")])
        let rig = Rig("""
            turnover.on('focus', function (e) {
              turnover.focused().then(function (item) { for (let i = 0; i < 12; i++) item.read().catch(function () {}); });
            });
            """, abilities: [.read, .say], limits: limits, broker: broker)
        defer { rig.host.stop() }
        rig.start()
        _ = rig.ask()
        check(waitFor(3) { broker.calls.filter { $0.operation == .itemRead }.count >= 4 }, "the first readings arrived")
        settle(0.4)
        expect(broker.calls.filter { $0.operation == .itemRead }.count, 4, "no more than the limit were read in the window")
    }

    test("script host: an answer of the wrong kind changes nothing, so a question still has its deadline") {
        // A host that, asked a question (id 1), answers it with a command's answer. The question must stay open, so the host is
        // killed for not answering it; before, the forged answer closed it and nothing was ever watching it again.
        let path = fakeHost("""
            read hello
            echo '{"t":"ready","events":["focus"],"commands":[]}'
            read question
            echo '{"t":"commandDone","id":1}'
            sleep 20
            """)
        defer { try? FileManager.default.removeItem(atPath: path) }
        var limits = fastLimits()
        limits.killLimit = 0.4
        let rig = Rig("", limits: limits, hostPath: path)
        rig.host.start()
        check(waitFor(3) { if case .ready = rig.host.state { return true } else { return false } }, "the stand-in is ready")
        expect(rig.ask(), .late, "it never answered the question")
        check(waitFor(3) { if case .failed = rig.host.state { return true } else { return false } }, "and it was stopped for it: \(rig.host.state)")
        check(rig.strikes.list.contains { if case .killed = $0 { return true } else { return false } }, "as a kill: \(rig.strikes.list)")
    }

    test("script host: a host that floods TurnOver with lines is thrown away unread, then stopped") {
        let path = fakeHost("""
            read hello
            echo '{"t":"ready","events":[],"commands":[]}'
            yes '{"t":"notify","op":"nonsense","args":{}}' | head -n 30000
            sleep 20
            """)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let rig = Rig("", hostPath: path)
        rig.host.start()
        check(waitFor(5) { if case .failed = rig.host.state { return true } else { return false } }, "the flood stopped the host: \(rig.host.state)")
        check(rig.strikes.list.contains { if case .killed(let why) = $0 { return why.contains("far more messages") } else { return false } }, "as a kill for sending too many: \(rig.strikes.list)")
        check(waitFor(3) { !rig.host.isRunning }, "and the host is gone")
    }

    test("script host: a host that ends at once is known to have ended, and a held child is not heard from until it is released") {
        for _ in 0..<20 {
            let rig = Rig("", hostPath: "/usr/bin/true")
            rig.host.start()
            check(waitFor(3) { !rig.host.isRunning }, "the host that ended at once is not running")
            if case .failed = rig.host.state {} else { check(false, "it is reported as ended on its own: \(rig.host.state)") }
        }
        final class Flag: @unchecked Sendable { var heard = false }
        let flag = Flag()
        guard let (child, _) = DisclaimedSpawn.run("/usr/bin/true", arguments: [], directory: "/", environment: [], hold: true, exited: { _ in flag.heard = true }) else { return check(false, "no child") }
        settle(0.4)
        expect(flag.heard, false, "a held child that has ended is not reported until it is released")
        check(Darwin.kill(child.pid, 0) == 0, "and its process id is still its own (it has not been reaped)")
        child.releaseExit?()
        check(waitFor(3) { flag.heard }, "released, the end is reported")
        settle(0.2)
        check(Darwin.kill(child.pid, 0) != 0, "and the child is reaped after")
    }

    test("script host: timers are limited in Swift, whatever the script does to its own bookkeeping") {
        let broker = FakeBroker()
        let rig = Rig("""
            Object.defineProperty(Map.prototype, 'size', { get: function () { return 0; } });   // blinds the script's own count
            for (let i = 0; i < 40; i++) setTimeout(function () { console.log('x'); }, 50);
            Number = function () { return 1e100; };   // and a delay no number of milliseconds can be
            setTimeout(function () { console.log('far'); }, 5);
            turnover.on('focus', function (e) { e.say('alive'); });
            """, broker: broker)
        defer { rig.host.stop() }
        rig.start()
        settle(0.8)
        expect(broker.calls.filter { $0.operation == .log && $0.arguments["text"]?.stringValue == "x" }.count, PluginWire.Limits.timers, "no more timers ran than may exist")
        expect(rig.ask(), .say("alive"), "and the host did not trap on the impossible delay")
    }

    test("script host: a message with a line break in it is refused by the host, so a script cannot send two") {
        let broker = FakeBroker()
        let rig = Rig("""
            JSON.stringify = function () { return '{"t":"notify","op":"log","args":{"text":"one"}}\\n{"t":"notify","op":"log","args":{"text":"two"}}'; };
            turnover.say('x');
            turnover.on('focus', function (e) { e.say('alive'); });
            """, broker: broker)
        defer { rig.host.stop() }
        rig.start()
        settle(0.3)
        check(!broker.calls.contains { $0.operation == .log && $0.arguments["text"]?.stringValue == "two" }, "no second message got through: \(broker.calls)")
        expect(rig.ask(), .say("alive"), "the host is fine")
    }

    test("script host: turnover.sound rejects a name TurnOver does not have, and passes one it has") {
        let broker = FakeBroker()
        let rig = Rig("""
            turnover.on('focus', function (e) {
              try { turnover.sound('nope'); turnover.say('no error'); } catch (err) { turnover.say(err.message); }
              turnover.sound('link');
            });
            """, broker: broker, sounds: ["link", "tick"])
        defer { rig.host.stop() }
        rig.start()
        _ = rig.ask()
        check(waitFor(3) { broker.calls.contains { $0.operation == .sound } && !broker.said.isEmpty }, "both happened: \(broker.calls)")
        check(broker.said.first?.contains("nope") ?? false, "the error names the sound: \(broker.said)")
        expect(broker.calls.filter { $0.operation == .sound }.map { $0.arguments["name"]?.stringValue }, ["link"], "only the real sound reached TurnOver")
    }

    test("script host: while paused, everything but the log and the plugin's own data is refused on TurnOver's side") {
        let broker = FakeBroker()
        let rig = Rig("""
            turnover.command('go', function () {
              turnover.find({}).then(function () { console.log('found'); }, function (err) { console.log('refused: ' + err.message); });
              turnover.copy('x').then(function () { console.log('copied'); }, function (err) { console.log('refused copy'); });
            });
            """, abilities: [.read, .clipboard], commands: ["go"], broker: broker)
        defer { rig.host.stop() }
        rig.start()
        // The command is sent first and the pause straight after: TurnOver's side is paused before the script's requests arrive.
        rig.host.run(command: "go") { _ in }
        rig.host.pause()
        check(waitFor(3) { broker.calls.filter { $0.operation == .log }.count >= 2 }, "the script heard both refusals: \(broker.calls)")
        check(!broker.calls.contains { $0.operation == .find || $0.operation == .copy }, "the broker saw neither request")
        check(broker.calls.contains { $0.operation == .log && ($0.arguments["text"]?.stringValue ?? "").contains("paused") }, "and the reason is said: \(broker.calls)")
        rig.host.resume()
        rig.host.run(command: "go") { _ in }
        check(waitFor(3) { broker.calls.contains { $0.operation == .find } && broker.calls.contains { $0.operation == .copy } }, "resumed, both go through")
    }

    test("script host: requests waiting for main are limited, and the rest are refused") {
        var limits = fastLimits()
        limits.mainQueueLimit = 5
        limits.requestsPerSecond = 10_000
        let broker = FakeBroker()
        let rig = Rig("""
            turnover.on('focus', function (e) { for (let i = 0; i < 40; i++) turnover.storage.get('k').catch(function () {}); });
            """, limits: limits, broker: broker)
        defer { rig.host.stop() }
        rig.start()
        _ = rig.ask()
        Thread.sleep(forTimeInterval: 0.5)   // main does not run, so every accepted request waits
        settle(0.5)
        expect(broker.calls.filter { $0.operation == .storageGet }.count, 5, "no more than five were taken up")
    }

    test("script host: a call that runs longer than the window still counts against the next one") {
        var limits = fastLimits()
        limits.mainThreadSecondsPerSecond = 0.1
        limits.requestsPerSecond = 1000
        let broker = FakeBroker()
        broker.delay = 1.2   // longer than the window the time is counted in
        let rig = Rig("""
            turnover.on('focus', function (e) {
              turnover.storage.get('a').then(function () { console.log('first done'); });
              turnover.storage.get('b').then(function () { console.log('second done'); }, function (err) { console.log('second refused'); });
            });
            """, limits: limits, broker: broker)
        defer { rig.host.stop() }
        rig.start()
        _ = rig.ask()
        check(waitFor(5) { broker.calls.contains { $0.operation == .storageGet } }, "the first was taken up")
        settle(0.6)
        expect(broker.calls.filter { $0.operation == .storageGet }.count, 1, "the second never reached the broker: the first's whole time counts against it")
    }

    test("script host: the host's environment is empty") {
        // A stand-in that reports what it was given, through the only way it can speak: its ready message's event list.
        let path = fakeHost("""
            read hello
            n=$(env | grep -c . )
            echo "{\\"t\\":\\"ready\\",\\"events\\":[],\\"commands\\":[\\"env$n\\"]}"
            sleep 20
            """)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let rig = Rig("", commands: ["env0", "env1", "env2", "env3", "env4"], hostPath: path)
        defer { rig.host.stop() }
        rig.host.start()
        check(waitFor(3) { if case .ready = rig.host.state { return true } else { return false } }, "ready")
        // bash adds a few variables of its own (PWD, SHLVL, _); TurnOver's own PATH, HOME and the rest must not be among them.
        check(rig.host.commands.first.map { Int($0.dropFirst(3)) ?? 99 }.map { $0 <= 4 } ?? false, "only the shell's own few variables: \(rig.host.commands)")
    }
}
