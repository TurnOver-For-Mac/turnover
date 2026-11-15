// SPDX-License-Identifier: GPL-3.0-or-later
// Every limit on a plugin script, in one place, with the reason beside it (docs/PLUGIN-SCRIPTS-PLAN.md,
// "Misbehaviour", 15 Nov 2026). A script that goes past one is refused, dropped, or its host program is killed, and
// TurnOver carries on reading. Tests pass smaller values through the memberwise initialiser.
import Foundation
import TurnOverPluginWire

nonisolated public struct ScriptLimits: Sendable {
    /// Time to answer a focus or value event. Speech starts as the focus lands, so TurnOver cannot wait longer than a
    /// person would notice; a late answer is dropped, TurnOver says what it would have said, and the host gets no
    /// further question until it has answered this one.
    public var eventDeadline: TimeInterval = 0.025
    /// Time from starting the host program to its `ready`. Measured start to first message on 14 Nov 2026: 13 to 35 ms,
    /// so three seconds only catches a script that loops or does heavy work as it loads.
    public var startLimit: TimeInterval = 3
    /// Time for a command to finish, or for an event to be answered at all. After it the host is killed: a script
    /// that cannot answer in five seconds is stuck, not slow.
    public var killLimit: TimeInterval = 5
    /// Memory (the footprint macOS reports). A host measured 16 to 18 MB on 14 Nov 2026; this leaves a script room
    /// and stops one from taking the Mac's memory.
    public var memoryBytes: UInt64 = 128 * 1024 * 1024
    /// More than this share of one processor for `cpuWindow` seconds: killed. A script that burns the processor
    /// starves the reader of the Mac's time even when each answer is quick.
    public var cpuShare: Double = 0.5
    public var cpuWindow: TimeInterval = 10
    /// Requests (including one-way messages) a script may make in a second. A script has no use for more, and a
    /// flood would fill TurnOver's main thread with its questions.
    public var requestsPerSecond: Int = 100
    /// Time the script's requests may take on TurnOver's main thread in any second. The main thread is the reader's
    /// speech and keyboard; a script's slow Accessibility questions must not hold it.
    public var mainThreadSecondsPerSecond: TimeInterval = 0.150
    /// Things said (speech and sounds) in a window, and the characters in each. A script that talks without end
    /// would bury what the person is reading.
    public var saysPerWindow: Int = 20
    public var sayWindow: TimeInterval = 2
    public var sayCharacters: Int = PluginWire.Limits.sayCharacters
    /// Timers at once and the fastest one, so timers cannot become a busy loop. Passed to the host in `hello`.
    public var timers: Int = PluginWire.Limits.timers
    public var minimumTimerMilliseconds: Int = PluginWire.Limits.minimumTimerMilliseconds
    /// The script's text, one message, and the plugin's stored data: bounded so no one message or file can exhaust
    /// memory. (The stored data's total is the broker's to count; the host refuses one value larger than this.)
    public var scriptBytes: Int = PluginWire.Limits.scriptBytes
    public var messageBytes: Int = PluginWire.Limits.messageBytes
    public var storageBytes: Int = PluginWire.Limits.storageBytes
    /// Strikes (a kill, a crash or a late answer) within `strikeWindow` that turn the script off for this run of
    /// TurnOver. Counting them is the next stage's; the numbers live here with the rest.
    public var strikesAllowed: Int = 3
    public var strikeWindow: TimeInterval = 600
    /// How often the watchdog looks. Fine enough that the limits above hold to a few hundredths of a second.
    public var watchdogInterval: TimeInterval = 0.025

    public static let standard = ScriptLimits()

    public init() {}
}
