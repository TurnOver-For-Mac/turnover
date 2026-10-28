// SPDX-License-Identifier: GPL-3.0-or-later
// voiceover-quiet: keeps VoiceOver's sound from the speakers while TurnOver reads.
//
// How: macOS (14.2 and later) lets a program "tap" another program's audio. A tap can be set to mute that program's
// sound for as long as the tap runs. This helper taps one program, VoiceOver (com.apple.VoiceOver), sets the tap to
// mute, and runs it through a private audio device whose only job is to throw the audio away. Nothing is recorded,
// saved, analysed or sent: the audio callback below is empty.
//
// TurnOver talks to it on standard input, one word a line:
//   on     VoiceOver silent (VoiceOver keeps running, so it's ready the moment it's needed)
//   still  TurnOver is still there and still wants it silent (sent every second; not answered)
//   off    VoiceOver heard
//   quit   VoiceOver heard, and the helper ends
// and it answers on standard output: "on", "off", or "error <what>".
// When TurnOver goes, for any reason, its end of the pipe closes, the helper ends, the tap ends with it, and
// VoiceOver is heard. When TurnOver is still there but stuck (frozen, stopped in a debugger) the "still" stops
// coming: after 3 seconds without it VoiceOver is heard, until the next word. A helper can never leave VoiceOver
// silent on its own.
//
// voiceover-quiet --self-test checks it can find its way round Core Audio, without silencing anything.
//
// MIT licence. Copyright (c) 2026 Oliver Kennett.
import Foundation
import CoreAudio
import AudioToolbox
import AppKit

let voiceOverID = "com.apple.VoiceOver"

final class Quiet {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private var tappedPid: pid_t = 0
    private(set) var wanted = false
    /// Silent was wanted, but TurnOver has said nothing for too long: heard until it speaks again.
    private(set) var lapsed = false
    private var lastWord = Date()

    var silencing: Bool { tap != kAudioObjectUnknown }

    func set(_ on: Bool) -> String {
        wanted = on; lapsed = false; lastWord = Date()
        if on { return start() } else { stop(); return "off" }
    }

    /// TurnOver's "still": the silence goes on (back on, if it had lapsed).
    func still() {
        lastWord = Date()
        if lapsed, wanted { lapsed = false; _ = start() }
    }

    /// Every second: no word from TurnOver for 3 seconds while silent, and VoiceOver is heard.
    func checkLease() {
        guard wanted, !lapsed, Date().timeIntervalSince(lastWord) > 3 else { return }
        lapsed = true
        stop()
        say("off")
    }

    /// VoiceOver restarted (a new process): the old tap is on a program that's gone, so a new one.
    func follow() {
        guard wanted, !lapsed else { return }
        let pid = voiceOverPid()
        if pid != tappedPid { stop(); _ = start() }
    }

    private func voiceOverPid() -> pid_t {
        NSRunningApplication.runningApplications(withBundleIdentifier: voiceOverID).first?.processIdentifier ?? 0
    }

    private func start() -> String {
        let pid = voiceOverPid()
        if silencing, pid == tappedPid { return "on" }
        stop()
        guard pid != 0 else { return "error VoiceOver isn't running" }
        guard let process = audioProcess(pid) else { return "error VoiceOver has no sound yet" }
        let description = CATapDescription(stereoMixdownOfProcesses: [process])
        description.muteBehavior = .muted
        description.isPrivate = true
        description.name = "TurnOver: VoiceOver quiet"
        var t = AudioObjectID(kAudioObjectUnknown)
        var r = AudioHardwareCreateProcessTap(description, &t)
        guard r == noErr else { return "error tap \(r)" }
        // The tap mutes only while it runs: a private device holding it, with a callback that does nothing.
        var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        _ = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(t, &uidAddress, 0, nil, &size, $0) }
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "TurnOver: VoiceOver quiet",
            kAudioAggregateDeviceUIDKey: "com.turnover.voiceover-quiet." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: uid as String, kAudioSubTapDriftCompensationKey: true]],
        ]
        var d = AudioObjectID(kAudioObjectUnknown)
        r = AudioHardwareCreateAggregateDevice(settings as CFDictionary, &d)
        guard r == noErr else { AudioHardwareDestroyProcessTap(t); return "error device \(r)" }
        var p: AudioDeviceIOProcID?
        r = AudioDeviceCreateIOProcIDWithBlock(&p, d, nil) { _, _, _, _, _ in }   // the audio is thrown away
        if r == noErr { r = AudioDeviceStart(d, p) }
        guard r == noErr else {
            if let p { AudioDeviceDestroyIOProcID(d, p) }
            AudioHardwareDestroyAggregateDevice(d); AudioHardwareDestroyProcessTap(t)
            return "error start \(r)"
        }
        tap = t; device = d; proc = p; tappedPid = pid
        return "on"
    }

    func stop() {
        guard silencing else { return }
        if let proc { AudioDeviceStop(device, proc); AudioDeviceDestroyIOProcID(device, proc) }
        if device != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(device) }
        AudioHardwareDestroyProcessTap(tap)
        tap = kAudioObjectUnknown; device = kAudioObjectUnknown; proc = nil; tappedPid = 0
    }

    /// VoiceOver's Core Audio process, by its process id.
    private func audioProcess(_ pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var p = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let r = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &p, &size, &object)
        return r == noErr && object != kAudioObjectUnknown ? object : nil
    }
}

func say(_ s: String) { try? FileHandle.standardOutput.write(contentsOf: Data((s + "\n").utf8)) }   // never the raising write: TurnOver may have gone

if CommandLine.arguments.contains("--self-test") {
    // Core Audio answers, and a process lookup works (this helper's own), without silencing anything.
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var p = getpid(); var object = AudioObjectID(kAudioObjectUnknown); var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let r = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &p, &size, &object)
    print(r == noErr ? "voiceover-quiet self-test: all passed" : "voiceover-quiet self-test: Core Audio said \(r)")
    exit(r == noErr ? 0 : 1)
}

let quiet = Quiet()
// Commands from TurnOver, read off the main thread and acted on on it.
Thread.detachNewThread {
    while let line = readLine() {
        let word = line.trimmingCharacters(in: .whitespaces).lowercased()
        DispatchQueue.main.async {
            switch word {
            case "on": say(quiet.set(true))
            case "still": quiet.still()
            case "off": say(quiet.set(false))
            case "quit": quiet.stop(); say("off"); exit(0)
            default: say("error unknown \(word)")
            }
        }
    }
    // TurnOver has gone (its end of the pipe closed): VoiceOver heard, and the helper ends.
    DispatchQueue.main.async { quiet.stop(); exit(0) }
}
// VoiceOver restarting followed, and TurnOver's word checked, once a second.
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in quiet.follow(); quiet.checkLease() }
RunLoop.main.run()
