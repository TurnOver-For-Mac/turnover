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
// and it answers on standard output: "on", "off", or "error <what>". While no muting tap is up, "off" is answered at
// once from the reading thread, even with the main thread waiting on macOS's audio-permission question; and an "on"
// whose start TurnOver called off meanwhile is answered "off". So an "on" may be answered "off", and TurnOver may
// read two "off"s in a row.
// When TurnOver goes, for any reason, its end of the pipe closes, the helper ends, the tap ends with it, and
// VoiceOver is heard. When TurnOver is still there but stuck (frozen, stopped in a debugger) the "still" stops
// coming: after 3 seconds without it VoiceOver is heard, until the next word. A helper can never leave VoiceOver
// silent on its own.
//
// voiceover-quiet --self-test checks it can find its way round Core Audio, without silencing anything, and that a
// "quit" ends it within a second while its main thread is held up.
//
// MIT licence. Copyright (c) 2026 Oliver Kennett.
import Foundation
import CoreAudio
import AudioToolbox
import AppKit

let voiceOverID = "com.apple.VoiceOver"

/// What TurnOver last asked for, noted on the reading thread the moment the word arrives. The first start can be held
/// up for as long as macOS's audio-permission question is open (90 s if nobody answers); this lets it see an "off"
/// sent meanwhile, instead of silencing VoiceOver after TurnOver has asked for it back.
final class TurnOverWord: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false, mutingNow = false
    var wantsSilent: Bool { lock.lock(); defer { lock.unlock() }; return on }
    func note(_ silent: Bool) { lock.lock(); on = silent; lock.unlock() }
    /// A muting tap is running (set on the main thread). Without one an "off" is answered at once from the reading
    /// thread, so TurnOver, which ends a helper that doesn't answer, leaves one waiting on macOS's question alone.
    var isMuting: Bool { lock.lock(); defer { lock.unlock() }; return mutingNow }
    func setMuting(_ m: Bool) { lock.lock(); mutingNow = m; lock.unlock() }
}
let turnOverWord = TurnOverWord()

final class Quiet {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private var tappedPid: pid_t = 0
    private(set) var wanted = false
    /// Silent was wanted, but TurnOver has said nothing for too long: heard until it speaks again.
    private(set) var lapsed = false
    private var lastWord = Date()
    /// macOS's permission to tap audio, asked with VoiceOver still heard (once a run).
    private var allowed = false

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
        // The first tap of a run can bring up macOS's question about recording audio, and the start waits for the
        // answer. Asked with a tap that doesn't mute, so VoiceOver can read the question out (21 Oct 2026: a re-signed
        // TurnOver asked it with VoiceOver already muted, and there was no speech until macOS gave up 90 s later).
        if !allowed {
            switch tapAndStart(process, muted: false) {
            case .failure(let error): return error.text
            case .success(let running): end(running)
            }
            allowed = true
            guard turnOverWord.wantsSilent else { return "off" }   // TurnOver asked for VoiceOver back while macOS asked
        }
        // Counted as muting from before the start, so an "off" read meanwhile isn't answered as done; checked again
        // after it, so VoiceOver isn't kept muted once TurnOver has asked for it back.
        turnOverWord.setMuting(true)
        switch tapAndStart(process, muted: true) {
        case .failure(let error): turnOverWord.setMuting(false); return error.text
        case .success(let running):
            guard turnOverWord.wantsSilent else { end(running); turnOverWord.setMuting(false); return "off" }
            tap = running.tap; device = running.device; proc = running.proc; tappedPid = pid
        }
        return "on"
    }

    private typealias Running = (tap: AudioObjectID, device: AudioObjectID, proc: AudioDeviceIOProcID?)
    private struct Failed: Error { let text: String }

    private func tapAndStart(_ process: AudioObjectID, muted: Bool) -> Result<Running, Failed> {
        let description = CATapDescription(stereoMixdownOfProcesses: [process])
        description.muteBehavior = muted ? .muted : .unmuted
        description.isPrivate = true
        description.name = "TurnOver: VoiceOver quiet"
        var t = AudioObjectID(kAudioObjectUnknown)
        var r = AudioHardwareCreateProcessTap(description, &t)
        guard r == noErr else { return .failure(Failed(text: "error tap \(r)")) }
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
        guard r == noErr else { AudioHardwareDestroyProcessTap(t); return .failure(Failed(text: "error device \(r)")) }
        var p: AudioDeviceIOProcID?
        r = AudioDeviceCreateIOProcIDWithBlock(&p, d, nil) { _, _, _, _, _ in }   // the audio is thrown away
        if r == noErr { r = AudioDeviceStart(d, p) }
        guard r == noErr else {
            if let p { AudioDeviceDestroyIOProcID(d, p) }
            AudioHardwareDestroyAggregateDevice(d); AudioHardwareDestroyProcessTap(t)
            return .failure(Failed(text: "error start \(r)"))
        }
        return .success((tap: t, device: d, proc: p))
    }

    private func end(_ running: Running) {
        if let proc = running.proc { AudioDeviceStop(running.device, proc); AudioDeviceDestroyIOProcID(running.device, proc) }
        if running.device != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(running.device) }
        AudioHardwareDestroyProcessTap(running.tap)
    }

    func stop() {
        guard silencing else { return }
        end((tap: tap, device: device, proc: proc))
        turnOverWord.setMuting(false)
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
    guard r == noErr else { print("voiceover-quiet self-test: Core Audio said \(r)"); exit(1) }
    // A quit with the main thread held (as by a start waiting on macOS's question) ends the helper within a second.
    let held = Process()
    held.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    held.arguments = ["--hold-main-for-test"]
    let input = Pipe()
    held.standardInput = input; held.standardOutput = FileHandle.nullDevice
    do { try held.run() } catch { print("voiceover-quiet self-test: couldn't start itself: \(error)"); exit(1) }
    Thread.sleep(forTimeInterval: 0.3)
    let asked = Date()
    try? input.fileHandleForWriting.write(contentsOf: Data("quit\n".utf8))
    while held.isRunning, Date().timeIntervalSince(asked) < 2 { Thread.sleep(forTimeInterval: 0.02) }
    let took = Date().timeIntervalSince(asked)
    if held.isRunning { held.terminate() }
    guard took < 1 else { print(String(format: "voiceover-quiet self-test: quit with the main thread held took %.2f s", took)); exit(1) }
    print("voiceover-quiet self-test: all passed")
    exit(0)
}

let quiet = Quiet()
/// The helper's end with the main thread busy (a start waiting on macOS's question): ending the process ends the tap.
/// _exit, not exit: exit runs the exit handlers, which can wait behind a main thread stuck in Core Audio, leaving
/// VoiceOver muted with nothing to end the helper (review, 21 Oct 2026).
func endSoon() { DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { _exit(0) } }

// Commands from TurnOver, read off the main thread and acted on on it.
Thread.detachNewThread {
    while let line = readLine() {
        let word = line.trimmingCharacters(in: .whitespaces).lowercased()
        if word == "on" { turnOverWord.note(true) } else if word == "off" || word == "quit" { turnOverWord.note(false) }
        if word == "quit" { endSoon() }
        if word == "off", !turnOverWord.isMuting { say("off") }
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
    // TurnOver has gone (its end of the pipe closed): VoiceOver heard, and the helper ends, at once even when the
    // main thread is held up.
    turnOverWord.note(false)
    endSoon()
    DispatchQueue.main.async { quiet.stop(); exit(0) }
}
// VoiceOver restarting followed, and TurnOver's word checked, once a second.
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in quiet.follow(); quiet.checkLease() }
// The self-test's second helper: its main thread held, as a start waiting on macOS's question holds it.
if CommandLine.arguments.contains("--hold-main-for-test") { Thread.sleep(forTimeInterval: 10); exit(1) }
RunLoop.main.run()
