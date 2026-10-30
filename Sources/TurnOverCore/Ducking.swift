// SPDX-License-Identifier: GPL-3.0-or-later
// Audio ducking (NVDA's NVDA+Shift+D; VoiceOver Utility's "audio ducking"): other apps' sound is lowered while
// TurnOver speaks (12 Oct 2026: "build it").
//
// How (13 Oct 2026): Core Audio's own ducking call, AudioDeviceDuck, the one macOS uses for its voices. It lowers
// every other client of the output device and spares the caller, so TurnOver's voice stays at full volume. Tried by
// ear on the maintainer's Mac before it went in: the music dropped, the test voice didn't, all back afterwards. It replaced a
// process tap that played every app's sound back through TurnOver and made macOS ask to "record system audio"
// (someone on AppleVis: the permission worried people, and the replay cost battery).
//
// The call isn't in the public headers any more, so it is looked up by name; where it's missing, ducking says it
// isn't available and nothing else changes.
//
// Safety: a duck is always undone: when speech ends, when ducking is turned off, when VoiceOver takes over, when the
// output device changes (the old one is undone first), and when TurnOver exits (atexit).
import Foundation
import CoreAudio

public enum Ducking {
    /// "off" (NVDA's no ducking), "speech" (while TurnOver speaks), "always" (while TurnOver runs).
    public static let modes = ["off", "speech", "always"]
    public static func name(_ mode: String) -> String {
        ["off": String(localized: "No ducking", comment: "An audio ducking mode"), "speech": String(localized: "Duck when outputting speech", comment: "An audio ducking mode"),
         "always": String(localized: "Always duck", comment: "An audio ducking mode")][mode] ?? mode
    }
    nonisolated static let ducked: Float32 = 0.3

    private typealias DuckCall = @convention(c) (AudioObjectID, Float32, UnsafePointer<AudioTimeStamp>?, Float32) -> OSStatus
    nonisolated private static let duckCall: DuckCall? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "AudioDeviceDuck").map { unsafeBitCast($0, to: DuckCall.self) }
    public static var isAvailable: Bool { duckCall != nil }

    private static var timer: Timer?
    private static var running = false
    /// The devices ducked now (undone before anything else is ducked). Written on the main thread and read at exit,
    /// so behind a lock.
    nonisolated private static let duckedDevices = Locked<[AudioObjectID]>([])
    /// A device the call refused: not tried again for 10 s, and said once in the log (it was 20 lines a second).
    private static var refusedUntil: [AudioObjectID: Date] = [:]
    private static var quietSince: Date?
    private static var registeredExit = false

    /// Applies the setting: starts or stops as TurnOver reads and the mode says.
    public static func apply() {
        let want = Core.active && config.speech.ducking != "off"
        if want && !running { start() } else if !want && running { stop() }
    }

    /// NVDA+Shift+D, and the menu: the next mode, said.
    public static func cycle() {
        let next = modes[((modes.firstIndex(of: config.speech.ducking) ?? 0) + 1) % modes.count]
        config.speech.ducking = next; config.save()
        Speech.speakMessage(next != "off" && !isAvailable ? String(localized: "Audio ducking isn't available on this Mac", comment: "Spoken message") : name(next))
        apply()
    }

    private static func start() {
        guard isAvailable else { Log.warning("ducking: AudioDeviceDuck not found"); return }
        running = true
        if !registeredExit { registeredExit = true; atexit { Ducking.undoNow() } }
        watchOutput()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        Log.info("ducking: on (\(config.speech.ducking)), Core Audio's own")
    }

    /// Every 50 ms: duck as speech starts, undo 0.4 s after it ends (so the gaps between phrases don't pump).
    private static func tick() {
        guard running else { return }
        let speaking = Speech.player.isBusy && !Speech.player.isPaused
        if config.speech.ducking == "always" || speaking {
            quietSince = nil
            if duckedDevices.value.isEmpty { for dev in devicesToDuck() { duck(dev) } }
        } else if !duckedDevices.value.isEmpty {
            if quietSince == nil { quietSince = Date() }
            if let q = quietSince, Date().timeIntervalSince(q) > 0.4 { undoNow(); quietSince = nil }
        }
    }

    private static func duck(_ dev: AudioObjectID) {
        guard let call = duckCall else { return }
        if let until = refusedUntil[dev], Date() < until { return }
        let r = call(dev, ducked, nil, 0.15)
        if r == 0 { duckedDevices.value.append(dev); refusedUntil[dev] = nil }
        else {
            if refusedUntil[dev] == nil { Log.warning("ducking: AudioDeviceDuck said \(r) for device \(dev); trying again every 10 s") }
            refusedUntil[dev] = Date().addingTimeInterval(10)
        }
    }

    /// Undo the duck, wherever it is.
    nonisolated static func undoNow() {
        guard let call = duckCall else { return }
        let devs = duckedDevices.value
        duckedDevices.value = []
        for dev in devs { _ = call(dev, 1.0, nil, 0.3) }
    }

    /// TurnOver's own output, and the Mac's default output if that is another device: with speech on headphones and
    /// music on the speakers, the music is on the default (code review, 13 Oct: only the headphones were ducked).
    private static func devicesToDuck() -> [AudioObjectID] {
        var out: [AudioObjectID] = []
        if let d = outputDevice() { out.append(d) }
        if let d = defaultOutput(), !out.contains(d) { out.append(d) }
        return out
    }

    public static func stop() {
        running = false
        timer?.invalidate(); timer = nil
        undoNow()
    }

    /// The device TurnOver speaks through: the one chosen in Settings, or the Mac's default output.
    private static func outputDevice() -> AudioObjectID? {
        if !config.speech.outputDevice.isEmpty, let d = device(uid: config.speech.outputDevice) { return d }
        return defaultOutput()
    }

    private static func defaultOutput() -> AudioObjectID? {
        var dev = AudioObjectID(0); var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev) == 0 && dev != 0 ? dev : nil
    }

    private static func device(uid: String) -> AudioObjectID? {
        var dev = AudioObjectID(0); var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var cf = uid as CFString
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let r = withUnsafeMutablePointer(to: &cf) { p in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<CFString>.size), p, &size, &dev)
        }
        return r == 0 && dev != 0 ? dev : nil
    }

    /// Headphones in or out: the old device is undone, and the next speech ducks the new one.
    private static var watchingOutput = false
    private static func watchOutput() {
        guard !watchingOutput else { return }
        watchingOutput = true
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, DispatchQueue.main) { _, _ in
            MainActor.assumeIsolated {
                guard running else { return }
                Log.info("ducking: the output device changed")
                undoNow()
            }
        }
    }
}
