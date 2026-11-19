// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverPluginWire

nonisolated enum InputReader {
    static func start() { Thread.detachNewThread { loop() } }

    /// Reads standard input on a thread of its own. `bye` and the end of the input stop the process here, on this thread,
    /// with _exit: the main thread may be stuck in the script's loop, and exit() would wait for it.
    static func loop() {
        var framer = LineFramer(maxBytes: PluginWire.Limits.helloBytes)
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(0, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { _exit(0) }
            for piece in framer.add(Data(buffer[0..<count])) {
                guard case .line(let line) = piece, !line.isEmpty else { continue }
                if line.count < 64,
                   let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                   object["t"] as? String == PluginWire.ToHost.bye { _exit(0) }
                // Only the hello may be longer than an ordinary message: it carries the script.
                if line.count > PluginWire.Limits.messageBytes {
                    let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
                    if object?["t"] as? String != PluginWire.ToHost.hello { continue }
                }
                DispatchQueue.main.async { MainActor.assumeIsolated { ScriptRuntime.shared.handle(line: line) } }
            }
        }
    }
}
