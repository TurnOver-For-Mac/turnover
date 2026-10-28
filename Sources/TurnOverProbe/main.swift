// SPDX-License-Identifier: GPL-3.0-or-later
// turnover-probe — the Phase 0 gate harness.
//
// Usage: turnover-probe <gate> [options]
//
// Every gate writes what it measures to stdout and to a log file under
// ~/Library/Application Support/TurnOver/logs/. The harness never speaks: it is
// meant to run with VoiceOver on or off, and the log is read afterwards.
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

let gates: [String: (name: String, help: String, run: ([String]) -> Void)] = [
    "capslock": ("capslock",
                 "Observe Caps Lock at the HID layer and in an event tap. Does not swallow or alter anything. --seconds N (default 30)",
                 runCapsLockGate),
    "speech":   ("speech",
                 "Speech engine soak through AVSpeechSynthesizer.write(). Silent: no audio is played. --voice <id substring> --count N --sayall",
                 runSpeechGate),
    "inspect":  ("inspect",
                 "Read-only look at an app's focused window and element: roles, attributes, text queries. --app Name | --bundle id | --pid N [--value]",
                 runInspectGate),
    "appstore-ax": ("appstore-ax",
                 "Bounded read-only App Store structural sample; no labels, UI actions or activation. Existing app only. [--direct] explicitly bypasses this probe's AXHealth rest.",
                 runAppStoreAXGate),
    "text":     ("text",
                 "Gate 7: 200 simulated arrow presses on a 5 MB file in TextEdit, bounded reads only. Takes the front. --lines N --mb N --keep",
                 runTextGate),
    "webread":  ("webread",
                 "Gate 1: whole-page string, structural queries and word stepping through text markers. --app Safari --repeat N --words N",
                 runWebReadGate),
    "wordmap":  ("wordmap",
                 "Map Word's text areas, find the caret, time the bounded line reads. Read-only. --bundle com.microsoft.Word",
                 runWordMapGate),
    "watch":    ("watch",
                 "Log accessibility notifications from an app while you use it. --app Name --seconds N",
                 runWatchGate),
    "wordload": ("wordload",
                 "Time the Word reader's reads while VoiceOver speaks, is muted by script, and is off. Beeps between phases. --phase-seconds N --lead N",
                 runWordLoadGate),
    "capsactive": ("capsactive",
                 "Gate 4 for real: Caps Lock swallowed and reset, chords, double tap; speaks with its own voice; needs VoiceOver OFF. Escape ends. --seconds N",
                 runCapsLockActiveGate),
    "latency":  ("latency",
                 "Gate 5: key to first audio through the reader's own SpeechPlayer; swallows and echoes typed keys; needs VoiceOver OFF. --voice id --frames N",
                 runLatencyGate),
    "handover": ("handover",
                 "Gate 10: turn VoiceOver off and back on by script, timed; narrated in the reader's voice. --keycode N (the owner's toggle key)",
                 runHandoverGate),
    "keys":     ("keys",
                 "Post key combos to an app by pid without activating it. --bundle id --keys \"cmd+f,escape\" --gap seconds",
                 runKeysGate),
    "tree":     ("tree",
                 "Print the focused window's element tree. --bundle id [--focused] [--depth N] [--max N] [--all]",
                 runTreeGate),
    "voices":   ("voices",
                 "List the voices available to this process.",
                 runVoicesGate),
]

let args = Array(CommandLine.arguments.dropFirst())
guard let gateName = args.first, let gate = gates[gateName] else {
    print("turnover-probe <gate> [options]\n")
    for key in gates.keys.sorted() {
        print("  \(key.padding(toLength: 10, withPad: " ", startingAt: 0)) \(gates[key]!.help)")
    }
    exit(2)
}

Log.open(gate: gate.name)
// The structural App Store gate accepts no content arguments. Do not persist even rejected argument text.
Log.line(gateName == "appstore-ax" ? "turnover-probe appstore-ax" : "turnover-probe \(gate.name) \(args.dropFirst().joined(separator: " "))")
Log.line("macOS \(ProcessInfo.processInfo.operatingSystemVersionString), pid \(getpid()), VoiceOver enabled flag: \(voiceOverRunning())")
gate.run(Array(args.dropFirst()))
Log.close()
