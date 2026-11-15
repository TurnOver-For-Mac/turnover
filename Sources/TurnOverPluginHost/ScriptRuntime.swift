// SPDX-License-Identifier: GPL-3.0-or-later
// The script's JSContext and everything that touches it. All of it runs on the main thread: messages from TurnOver
// are handed here by the input thread (main.swift), and timers fire on the main queue. Only `bye` and the input
// closing are handled on the input thread, so a script stuck in a loop on the main thread cannot keep the host
// alive (docs/PLUGIN-SCRIPTS-PLAN.md, "The wire").
import Foundation
import JavaScriptCore
import TurnOverPluginWire

/// Standard output, written from the main thread only; a failed write means TurnOver has gone.
enum Output {
    static func write(_ data: Data) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
            while offset < bytes.count {
                let n = Darwin.write(1, bytes.baseAddress! + offset, bytes.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    _exit(0)   // TurnOver's end of the pipe is closed: nothing left to serve
                }
                offset += n
            }
            return true
        }
    }
    static func send(_ object: Any) { if let line = PluginWire.line(for: object) { _ = write(line) } }
    static func complain(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
}

final class ScriptRuntime {
    static let shared = ScriptRuntime()
    private var context: JSContext?
    private var entry: JSValue?
    private var started = false
    private var paused = false
    private var timers: [Int: DispatchSourceTimer] = [:]
    private var repeating: Set<Int> = []
    private var dueWhilePaused: [Int] = []
    private var lastException: JSValue?

    func handle(line: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let type = object["t"] as? String else { return }
        switch type {
        case PluginWire.ToHost.hello: hello(object)
        case PluginWire.ToHost.event: if !paused { call("event", line) }
        case PluginWire.ToHost.command: if !paused { call("command", line) }
        case PluginWire.ToHost.reply: call("reply", line)
        case PluginWire.ToHost.pause: paused = true
        case PluginWire.ToHost.resume:
            paused = false
            let due = dueWhilePaused
            dueWhilePaused = []
            for id in due { fire(id) }
        default: break
        }
    }

    private func call(_ name: String, _ line: Data) {
        guard let function = entry?.forProperty(name) else { return }
        function.call(withArguments: [String(decoding: line, as: UTF8.self)])
    }

    private func hello(_ object: [String: Any]) {
        guard !started else { return }
        started = true
        let plugin = object["plugin"] as? [String: Any] ?? [:]
        let limits = object["limits"] as? [String: Any] ?? [:]
        let source = object["source"] as? String ?? ""
        let commands = (object["commands"] as? [Any])?.compactMap { $0 as? String } ?? []
        guard let context = JSContext() else { fail("The script engine could not start."); return }
        self.context = context
        context.exceptionHandler = { [weak self] _, exception in self?.lastException = exception }

        let native = JSValue(newObjectIn: context)!
        let send: @convention(block) (String) -> Bool = { text in
            let data = Data(text.utf8)
            guard data.count < PluginWire.Limits.messageBytes else { return false }
            return Output.write(data + Data([0x0A]))
        }
        let timer: @convention(block) (Int, Double, Bool) -> Void = { [weak self] id, milliseconds, repeats in
            self?.startTimer(id, milliseconds: milliseconds, repeats: repeats)
        }
        let clearTimer: @convention(block) (Int) -> Void = { [weak self] id in self?.stopTimer(id) }
        native.setValue(send, forProperty: "send")
        native.setValue(timer, forProperty: "timer")
        native.setValue(clearTimer, forProperty: "clearTimer")

        let config = JSValue(object: [
            "api": PluginWire.apiVersion,
            "language": object["language"] as? String ?? "en",
            "plugin": [
                "id": plugin["id"] as? String ?? "",
                "name": plugin["name"] as? String ?? "",
                "version": plugin["version"] as? String ?? "",
            ],
            "commands": commands,
            "eventNames": PluginWire.eventNames,
            "replaceableEvents": Array(PluginWire.replaceableEvents),
            "messageBytes": PluginWire.Limits.messageBytes,
            "timers": (limits["timers"] as? Int) ?? PluginWire.Limits.timers,
            "minimumTimerMilliseconds": (limits["minimumTimerMilliseconds"] as? Int) ?? PluginWire.Limits.minimumTimerMilliseconds,
        ] as [String: Any], in: context)!

        guard let make = context.evaluateScript(Prelude.source, withSourceURL: URL(string: "turnover-prelude.js")), make.isObject else {
            fail("The script interface could not be set up: \(lastException?.toString() ?? "unknown error")."); return
        }
        guard let built = make.call(withArguments: [native, config]), built.isObject else {
            fail("The script interface could not be set up: \(lastException?.toString() ?? "unknown error")."); return
        }
        entry = built

        lastException = nil
        context.evaluateScript(source, withSourceURL: URL(string: "main.js"))
        if let exception = lastException {
            let line = exception.forProperty("line")
            let place = (line?.isNumber ?? false) ? "main.js, line \(line!.toInt32()): " : "main.js: "
            fail(place + (exception.toString() ?? "an error"))
            return
        }
        guard let summary = entry?.forProperty("summary")?.call(withArguments: [])?.toString(),
              let parsed = (try? JSONSerialization.jsonObject(with: Data(summary.utf8))) as? [String: Any] else {
            fail("The script's handlers could not be listed."); return
        }
        Output.send([
            "t": PluginWire.FromHost.ready,
            "events": parsed["events"] ?? [],
            "commands": parsed["commands"] ?? [],
        ] as [String: Any])
    }

    private func fail(_ message: String) {
        Output.send(["t": PluginWire.FromHost.failed, "error": message])
    }

    // Timers: JavaScript keeps the callbacks; here only the clock. A timer that comes due while paused waits, and fires
    // once when the script resumes.
    private func startTimer(_ id: Int, milliseconds: Double, repeats: Bool) {
        let source = DispatchSource.makeTimerSource(queue: .main)
        let interval = DispatchTimeInterval.milliseconds(Int(milliseconds))
        source.schedule(deadline: .now() + interval, repeating: repeats ? interval : .never)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.timerDue(id) } }
        timers[id] = source
        if repeats { repeating.insert(id) }
        source.resume()
    }

    private func stopTimer(_ id: Int) {
        timers.removeValue(forKey: id)?.cancel()
        repeating.remove(id)
        dueWhilePaused.removeAll { $0 == id }
    }

    private func timerDue(_ id: Int) {
        if paused {
            if !dueWhilePaused.contains(id) { dueWhilePaused.append(id) }
            if !repeating.contains(id) { timers.removeValue(forKey: id)?.cancel() }
            return
        }
        if !repeating.contains(id) { timers.removeValue(forKey: id)?.cancel() }
        fire(id)
    }

    private func fire(_ id: Int) {
        entry?.forProperty("fire")?.call(withArguments: [id])
    }
}
