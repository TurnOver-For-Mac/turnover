// SPDX-License-Identifier: GPL-3.0-or-later
// What TurnOver and the plugin host program (turnover-plugin-host) must agree on: the message names, the operation
// names and the sizes (docs/PLUGIN-SCRIPTS-PLAN.md, "The wire", 15 Nov 2026). Foundation only, no actor isolation,
// so both sides link it. The messages themselves are one JSON object per line over the host's standard input and output.
import Foundation

public enum PluginWire {
    /// The script interface's version (`turnover.api`).
    public static let apiVersion = 1

    /// The `t` field of a message, TurnOver to host.
    public enum ToHost {
        public static let hello = "hello"
        public static let event = "event"
        public static let command = "command"
        public static let reply = "reply"
        public static let pause = "pause"
        public static let resume = "resume"
        public static let bye = "bye"
        /// The current values of the plugin's options (stage B, 16 Nov 2026): sent whenever one changes, even while the script is
        /// paused, so `turnover.options.get` is always current. Carries no code and runs none.
        public static let options = "options"
    }

    /// The `t` field of a message, host to TurnOver.
    public enum FromHost {
        public static let ready = "ready"
        public static let failed = "failed"
        public static let eventDone = "eventDone"
        public static let commandDone = "commandDone"
        public static let request = "request"
        public static let notify = "notify"
    }

    /// What a script may ask TurnOver for. `request` messages carry an id and are answered by a `reply`;
    /// `notify` messages (say, sound, log) are one way.
    public enum Operation: String, CaseIterable, Sendable {
        case say, sound, log
        case focused, find
        case itemRefresh = "item.refresh"
        case itemParent = "item.parent"
        case itemChildren = "item.children"
        case itemRead = "item.read"
        case itemPress = "item.press"
        case itemFocus = "item.focus"
        case itemSetValue = "item.setValue"
        case menu, keys, copy
        /// Stage B (16 Nov 2026): TurnOver's own list and text prompt (answered when the person answers), a tone, an item's
        /// text and caret, and the clipboard's text.
        case choose, ask, tone
        case itemText = "item.text"
        case itemSetCaret = "item.setCaret"
        case itemSelect = "item.select"
        case clipboard
        case storageGet = "storage.get"
        case storageSet = "storage.set"
        case storageRemove = "storage.remove"

        /// Said, played or logged: sent as a `notify`, never answered.
        public var isNotification: Bool { self == .say || self == .sound || self == .log || self == .tone }
        /// Answered later, when the person has chosen or typed: TurnOver's reply is not an immediate one.
        public var isDeferred: Bool { self == .choose || self == .ask }
    }

    /// The events a script can handle (`turnover.on`).
    public static let eventNames = ["focus", "valueChange", "appFocus", "appBlur", "windowChange", "optionsChange", "speech"]
    /// The events whose handler may replace what TurnOver says (`event.say`, `event.silence`).
    public static let replaceableEvents: Set<String> = ["focus", "valueChange"]

    /// Sizes both sides use. The ones only TurnOver enforces (rates, memory, deadlines) are in ScriptLimits.
    public enum Limits {
        /// A message, either way (the plan's 256 KB).
        public static let messageBytes = 256 * 1024
        /// The script's text.
        public static let scriptBytes = 256 * 1024
        /// The plugin's stored data.
        public static let storageBytes = 256 * 1024
        /// The hello line carries the whole script, and JSON can double or sextuple its size in the worst case
        /// (control characters), so it has its own, larger bound.
        public static let helloBytes = 2 * 1024 * 1024
        /// Characters in one thing said.
        public static let sayCharacters = 500
        /// A tone's pitch and length (stage B).
        public static let toneHertz: ClosedRange<Double> = 100...4000
        public static let toneMilliseconds: ClosedRange<Double> = 10...500
        /// A list's items and their length, a prompt's and a title's length, and the text a prompt may give back.
        public static let choiceItems = 200
        public static let choiceCharacters = 200
        public static let answerCharacters = 1000
        /// The text of an item or of the clipboard that a script is given.
        public static let textCharacters = 10_000
        /// What the script is told TurnOver said (stage B, `hearSpeech`).
        public static let heardCharacters = 1000
        /// Timers a script may have at once.
        public static let timers = 20
        /// The fastest a timer may run.
        public static let minimumTimerMilliseconds = 50
    }

    /// One message as a line of JSON ending in a newline, or nil if it cannot be written as JSON.
    public static func line(for object: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return nil }
        data.append(0x0A)
        return data
    }
}

/// Cuts a byte stream into lines, whatever the pipe's reads do to them, and refuses a line longer than `maxBytes`
/// without ever holding more than that: the limit is checked before each piece is added, and the rest of an over-long line is
/// thrown away up to its newline. (What a single read hands in is the reader's to bound.)
public struct LineFramer: Sendable {
    public enum Piece: Equatable, Sendable {
        case line(Data)
        /// A line passed the limit and was dropped (reported once per line).
        case tooLong
    }

    public let maxBytes: Int
    private var pending = Data()
    private var skipping = false

    public init(maxBytes: Int) { self.maxBytes = maxBytes }

    public mutating func add(_ data: Data) -> [Piece] {
        var out: [Piece] = []
        var start = data.startIndex
        while start < data.endIndex, let newline = data[start...].firstIndex(of: 0x0A) {
            if skipping {
                skipping = false
            } else if pending.count + (newline - start) > maxBytes {
                // Checked before anything is added, so what is held never passes the limit.
                pending.removeAll(keepingCapacity: true)
                out.append(.tooLong)
            } else {
                pending.append(data[start..<newline])
                out.append(.line(pending))
                pending.removeAll(keepingCapacity: true)
            }
            start = data.index(after: newline)
        }
        if start < data.endIndex, !skipping {
            if pending.count + (data.endIndex - start) > maxBytes {
                pending.removeAll()
                skipping = true
                out.append(.tooLong)
            } else {
                pending.append(data[start...])
            }
        }
        return out
    }
}
