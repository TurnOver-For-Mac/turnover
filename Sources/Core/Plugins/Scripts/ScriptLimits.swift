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
    /// What one `find` may return, whatever the script asks for, and the time one may take on the main thread (a search
    /// walks the app's windows through Accessibility: the same share of main as the second's whole allowance above, so a
    /// slow app costs the script its turn, not the reader its voice).
    public var findLimit: Int = 50
    public var findBudget: TimeInterval = 0.15
    /// Lines the host may write to TurnOver in a second, counted before any is parsed: past it they are thrown away unread, so
    /// a flood costs TurnOver a count and not a parse, a log line and a queue entry each. Five times the requests a second a
    /// script may make, which leaves room for the answers to events and commands.
    public var messagesPerSecond: Int = 500
    /// Lines thrown away for being past that rate, in `floodWindow` seconds, after which the host is stopped as abusive.
    public var floodDropsAllowed: Int = 2_000
    public var floodWindow: TimeInterval = 10
    /// Requests accepted and waiting for TurnOver's main thread. Each is at most one message (256 KB), so this bounds what a
    /// slow main thread can be made to hold for a script that asks faster than main answers.
    public var mainQueueLimit: Int = 64
    /// How often the same kind of refusal or complaint from the host is written to the log: once, then a count of the rest.
    public var logInterval: TimeInterval = 1
    /// What a glob (a `*` pattern in a match) may be and be matched against, in characters. Longer matches nothing. The work
    /// is the two multiplied, so this is at most two million steps for one comparison: a long page's text is not a name,
    /// and a pattern longer than a sentence is not one either. Fixed for a match in any plugin, a script's or not.
    public static let globPatternCharacters = 200
    public static let globTextCharacters = 10_000
    /// Strikes (a kill, a crash or a late answer) within `strikeWindow` that turn the script off for this run of
    /// TurnOver. Counting them is the next stage's; the numbers live here with the rest.
    public var strikesAllowed: Int = 3
    public var strikeWindow: TimeInterval = 600
    /// How often the watchdog looks. Fine enough that the limits above hold to a few hundredths of a second.
    public var watchdogInterval: TimeInterval = 0.025

    public static let standard = ScriptLimits()

    public init() {}
}
