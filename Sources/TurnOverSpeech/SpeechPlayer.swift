// SPDX-License-Identifier: GPL-3.0-or-later
// SpeechPlayer — the reader's own speech path.
//
// Why not let AVSpeechSynthesizer play: measured 30 Sep 2026, synthesis through
// write() runs far faster than real time (100 short utterances rendered in
// 1.2 s; Eloquence to first buffer in 2–4 ms warm), and stopSpeaking() neither
// reports a cancel nor stops already-rendered buffers arriving. So the
// synthesizer is used only as a renderer. Its PCM is converted to the output
// device's rate and scheduled on one AVAudioPlayerNode with a small hardware
// buffer; cancelling is player.stop(), which is immediate and sub-buffer, and a
// generation counter drops any buffers still arriving for the cancelled text.
// Earcons will be mixed on the same engine.
//
// All state lives on one serial queue. write() delivers its buffers on an
// arbitrary thread; they are hopped onto the queue before anything is touched.
import Foundation
import TurnOverObjC
@preconcurrency import AVFoundation   // AVAudioPCMBuffer and AVSpeechUtterance cross to the speech queue, never back
import AudioToolbox
import os

public struct SpeechTiming: Sendable {
    /// mach_absolute_time when speak() was called (or the caller's earlier stamp,
    /// e.g. the key event's, so the whole path can be measured).
    public var requestedAt: UInt64
    /// mach_absolute_time when the first non-empty buffer was scheduled.
    public var firstBufferAt: UInt64?
    public var text: String
    /// The voice that made the sound ("external:…" for Kokoro), so the main voice is only counted when it spoke.
    public var voice: String = ""

    public var requestToFirstBufferMs: Double? {
        guard let f = firstBufferAt else { return nil }
        return Double(f &- requestedAt) * SpeechPlayer.machToNs / 1_000_000
    }
}

/// Playback state is the speech queue's (`queue`): playback calls and framework callbacks hop onto it. Swift 6
/// cannot express that queue ownership, so the class says so here (10 Oct 2026). Shared settings, the current-player
/// snapshot and recovery claims/callbacks use their explicit locks instead of the playback queue.
public final class SpeechPlayer: @unchecked Sendable {
    /// The watchdog cannot ask main for the current player: main may be stuck too. The slot is locked for setup,
    /// replacement and off-main recovery checks; retiring a replaced watch never calls the old audio queue (#155).
    private static let currentSlot = OSAllocatedUnfairLock<SpeechPlayer?>(initialState: nil)
    public static var current: SpeechPlayer? {
        get { currentSlot.withLock { $0 } }
        set {
            let previous = currentSlot.withLock { current -> SpeechPlayer? in
                let previous = current
                current = newValue
                return previous
            }
            if previous !== newValue { previous?.queueWatch.retire() }
        }
    }
    public static let machToNs: Double = {
        var info = mach_timebase_info(numer: 0, denom: 0)
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    public enum Error: Swift.Error { case noOutputFormat, bufferSize(OSStatus) }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let toneNode = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "turnover.speech", qos: .userInteractive)
    private var synth = AVSpeechSynthesizer()   // the speech queue's; replaced when it stops giving sound (freshSynth)
    /// Every call into a synthesizer runs on that synthesizer's own queue, never on the speech queue: its write and its
    /// stop could both stick for good (19 Oct 2026, say all and arrows: "synthesizer stop", then "synthesizer write"),
    /// and the speech queue, then the main thread, stuck with them. A stuck synthesizer and its queue are left behind.
    private var synthQueue = DispatchQueue(label: "turnover.synth")
    private let finishWatch = FinishWatch()
    private let format: AVAudioFormat
    private var converters: [String: AVAudioConverter] = [:]
    private var generation: UInt64 = 0

    // Set on the main thread, read on the speech queue as each utterance is made: kept behind a lock (a voice name
    // is a heap string; a torn read could crash, E6 audit, 4 Oct 2026).
    private let settingsLock = NSLock()
    private var _voiceIdentifier: String
    private var _rate: Float
    public var voiceIdentifier: String {
        get { settingsLock.lock(); defer { settingsLock.unlock() }; return _voiceIdentifier }
        set { settingsLock.lock(); _voiceIdentifier = newValue; settingsLock.unlock() }
    }
    public var rate: Float {
        get { settingsLock.lock(); defer { settingsLock.unlock() }; return _rate }
        set { settingsLock.lock(); _rate = newValue; settingsLock.unlock() }
    }
    /// The voice's pitch, as a multiplier (1 is the voice's own; 0.5 to 2). A capital's raise multiplies it.
    private var _pitch: Float = 1
    public var pitch: Float {
        get { settingsLock.lock(); defer { settingsLock.unlock() }; return _pitch }
        set { settingsLock.lock(); _pitch = max(0.5, min(2, newValue)); settingsLock.unlock() }
    }
    /// Speech volume, 0.1 to 2. 1 is the voice as the synthesiser renders it, which is what VoiceOver plays: the
    /// engine's mixer sends mono to both sides at full level (measured offline, 15 Oct 2026: a 0.5 sine comes out
    /// at 0.5 on each side), so the √2 make-up added on 5 Oct made every voice 3 dB louder than VoiceOver and
    /// pushed Alex into the soft knee (15 Oct: Alex quite a bit louder on TurnOver). Samples are held
    /// within ±1 for settings above 1.
    private var _volume: Float = 1
    public var volume: Float {
        get { settingsLock.lock(); defer { settingsLock.unlock() }; return _volume }
        set { settingsLock.lock(); _volume = max(0.1, min(2, newValue)); settingsLock.unlock() }
    }
    private func applyVolume(_ b: AVAudioPCMBuffer) {
        let gain = volume
        guard abs(gain - 1) > 0.01, let data = b.floatChannelData else { return }
        for ch in 0..<Int(b.format.channelCount) {
            let p = data[ch]
            for i in 0..<Int(b.frameLength) {
                // A soft knee above 0.9 instead of a hard clip: Alex and Reed peak at about 0.75, so settings above
                // 120% round the peaks off rather than crackle.
                let y = p[i] * gain, a = abs(y)
                p[i] = a <= 0.9 ? y : (y < 0 ? -1 : 1) * (0.9 + 0.1 * tanhf((a - 0.9) / 0.1))
            }
        }
    }
    /// Called on the speech queue when an utterance's first audio is scheduled.
    public var onFirstAudio: ((SpeechTiming) -> Void)?
    /// The voice gave no sound for two utterances running (a voice that can't render to TurnOver's audio: a tester
    /// chose one and TurnOver went silent, with no way back to the menu, 7 Oct 2026). Called on the speech queue with
    /// the voice's identifier; the owner picks a voice that works.
    public var onVoiceSilent: ((String) -> Void)?
    private var silentRuns = 0

    /// Hardware buffer size in frames, as requested; see `outputLatencySeconds`.
    public let bufferFrames: UInt32
    public var sampleRate: Double { format.sampleRate }
    /// The device's reported presentation latency plus one hardware buffer: the
    /// time between a buffer being scheduled and its first sample leaving.
    public var outputLatencySeconds: Double {
        engine.outputNode.presentationLatency + Double(bufferFrames) / format.sampleRate
    }

    public init(voice: String, rate: Float = 0.55, bufferFrames: UInt32 = 128) throws {
        self._voiceIdentifier = voice
        self._rate = rate
        self.bufferFrames = bufferFrames
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        guard let f = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: 1) else { throw Error.noOutputFormat }
        format = f
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.attach(toneNode)
        engine.connect(toneNode, to: engine.mainMixerNode, format: format)
        if let unit = engine.outputNode.audioUnit {
            var frames = bufferFrames
            let status = AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frames, UInt32(MemoryLayout<UInt32>.size))
            if status != noErr { throw Error.bufferSize(status) }
        }
        try engine.start()
        play(player)
        play(toneNode)
        engineDevice = Self.defaultOutputDevice()
        watchDefaultOutput()
        // The engine stops itself when the output changes (AirPods or a USB headset connect, a sample-rate change):
        // start it again, or every utterance queues for ever and the next play() traps (8 Oct 2026).
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.ensureRunning(reason: "the output changed"); self.freshSynth(because: "the audio configuration changed") }
        }
        watchQueue()
        synth.delegate = finishWatch
        finishWatch.finished = { [weak self] u in
            guard let self else { return }
            nonisolated(unsafe) let u = u   // handed to the speech queue; the synthesizer is done with it
            self.queue.async { self.synthFinished(u) }
        }
    }

    // MARK: Following the Mac's output device

    /// The engine's output unit is bound to the device that was the default when the engine started, and macOS does
    /// not always post a configuration change when the default moves (headphones became the default and TurnOver
    /// stayed on the speakers; 9 Oct 2026). So the default output is watched through CoreAudio itself, and on
    /// a change the engine is stopped, pointed at the new device, reconnected for its format, and started again.
    private var outputListener: AudioObjectPropertyListenerBlock?
    private static let defaultOutputAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                                         mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private static let devicesAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private var devicesListener: AudioObjectPropertyListenerBlock?
    /// A device chosen for speech (VoiceOver Utility's Sound, NVDA's output device), by CoreAudio UID; nil follows
    /// the Mac's default output. A chosen device that is not present falls back to the default until it appears.
    public var outputDeviceUID: String? {
        get { chosenUID }
        set { settingsLock.lock(); _outputDeviceUID = newValue; settingsLock.unlock(); queue.async { [self] in followOutputChoice() } }
    }
    private var _outputDeviceUID: String?   // under settingsLock: read from main and the speech queue
    private var chosenUID: String? { settingsLock.lock(); defer { settingsLock.unlock() }; return _outputDeviceUID }
    private var engineDevice: AudioDeviceID = 0
    /// Where speech plays now, for a spoken confirmation: "the built-in speakers (the Mac's default)".
    public var outputDescription: String {
        // Asked on the speech queue, waited for briefly: main waited on this for ever while the queue was stuck in
        // CoreAudio (98 s on 20 Oct 2026), which stopped the fresh player that would have rescued it.
        let answer = Guarded<String?>(nil)
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            doing("output description")
            let name = Self.stringProperty(engineDevice, kAudioObjectPropertyName) ?? "device \(engineDevice)"
            let chosen = chosenUID.flatMap(Self.device(withUID:))
            answer.value = "\(name)\(chosen == engineDevice ? "" : " (the Mac's default)")"
            done.signal()
        }
        return done.wait(timeout: .now() + 0.3) == .success ? (answer.value ?? "the current output") : "the current output (the audio system is slow to answer)"
    }
    /// A line for the reader's log each time the engine moves to another device (which, and why).
    public var onOutputChange: (@Sendable (String) -> Void)?

    /// One output device the Mac has, for a settings list.
    public struct OutputDevice: Sendable, Equatable { public let uid: String; public let name: String }

    /// Every real device with an output stream, in CoreAudio's order. Virtual devices (Microsoft Teams Audio,
    /// BlackHole, Loopback) are left out: Teams' driver hung CoreAudio's call for ever while Teams was not
    /// running, and the stuck thread stopped every sound in the process, the synthesizer included (10 Oct 2026).
    public static func outputDevices() -> [OutputDevice] { outputDeviceIDs().map { OutputDevice(uid: $0.uid, name: $0.name) } }

    /// The device list is read on a queue of its own and kept: a driver that hangs (Teams', 10 Oct 2026) then hangs
    /// only that queue, never the speech queue or the main thread (20 Oct 2026). The first ask waits briefly for a
    /// scan; after that the kept list is answered at once and refreshed whenever the Mac's device list changes.
    private static let scanQueue = DispatchQueue(label: "turnover.speech.devices", qos: .utility)
    private static let scanned = Guarded<[(id: AudioDeviceID, uid: String, name: String)]?>(nil)
    private static func outputDeviceIDs() -> [(id: AudioDeviceID, uid: String, name: String)] {
        if let list = scanned.value { return list }
        let done = DispatchSemaphore(value: 0)
        refreshDevices { done.signal() }
        _ = done.wait(timeout: .now() + 0.5)
        return scanned.value ?? []
    }
    static func refreshDevices(then: (@Sendable () -> Void)? = nil) {
        scanQueue.async {
            let list = scanDevices()
            scanned.value = list
            then?()
        }
    }
    private static func scanDevices() -> [(id: AudioDeviceID, uid: String, name: String)] {
        var size = UInt32(0); var address = devicesAddress
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            // Virtual devices first and by the cheapest question, before anything is asked of their driver.
            var transportAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var transport = UInt32(0); var tSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &tSize, &transport) == noErr, transport == kAudioDeviceTransportTypeVirtual { return nil }
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var n = UInt32(0)
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &n) == noErr, n > 0 else { return nil }
            guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID), let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return (id, uid, name)
        }
    }
    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>? = nil; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }
    /// The output device with this UID, if it is present (a scan of the list: TranslateUIDToDevice's qualifier call
    /// answered nothing for a present device, 10 Oct 2026).
    private static func device(withUID uid: String) -> AudioDeviceID? { outputDeviceIDs().first { $0.uid == uid }?.id }

    private func watchDefaultOutput() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.queue.async { self.followOutputChoice() }
            // The kept device list refreshed on its own queue; the choice looked at again once it has (a chosen
            // device that just arrived is then found).
            Self.refreshDevices { [weak self] in self?.queue.async { [weak self] in self?.followOutputChoice() } }
        }
        var defaultAddress = Self.defaultOutputAddress, devicesAddress = Self.devicesAddress
        let r = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, queue, block)
        if r == noErr { outputListener = block } else { NSLog("speech: could not watch the default output device (%d)", r) }
        // The chosen device arriving (headphones switched on) or leaving: the same check.
        let r2 = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, queue, block)
        if r2 == noErr { devicesListener = block } else { NSLog("speech: could not watch the device list (%d)", r2) }
    }
    private static func defaultOutputDevice() -> AudioDeviceID {
        var dev = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size); var address = defaultOutputAddress
        let r = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &dev)
        return r == noErr ? dev : 0
    }
    /// Points the engine at the chosen device when it is present, else at the Mac's default output; no change, no work.
    private func followOutputChoice() {
        doing("reading the output devices")
        let uidChoice = chosenUID
        let chosen = uidChoice.flatMap(Self.device(withUID:))
        if let uid = uidChoice, chosen == nil { onOutputChange?("speech: the chosen output \(uid) is not present (or virtual); the Mac's default output for now") }
        let dev = chosen ?? Self.defaultOutputDevice()
        guard dev != 0, dev != engineDevice else { return }
        engineDevice = dev
        doing("engine stop for a new output")
        engine.stop()
        var r: OSStatus = -1
        if let unit = engine.outputNode.audioUnit {
            var d = dev
            r = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &d, UInt32(MemoryLayout<AudioDeviceID>.size))
            var frames = bufferFrames
            _ = AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frames, UInt32(MemoryLayout<UInt32>.size))
        }
        let name = Self.stringProperty(dev, kAudioObjectPropertyName) ?? "device \(dev)"
        let line = "speech: output now \(name)\(chosen == nil ? " (the Mac's default)" : " (chosen)")\(r == noErr ? "" : ", error \(r)")"
        NSLog("%@", line); onOutputChange?(line)
        // The output's format may differ (a Bluetooth device's sample rate): the mixer is connected again for it.
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        ensureRunning(reason: "the output device changed")
        freshSynth(because: "the output device changed")
    }

    /// A new synthesizer in place of the one in use. Switching to AirPods, the Mac's synthesizer spoke once more and
    /// then gave no sound at all, and later held up the speech queue (a tester, ; headphones here too, 19 Oct
    /// 2026: TurnOver's own engine was running; the synthesizer's writes simply never answered). A fresh one is a new
    /// connection to the Mac's speech service. The old one is stopped off this queue, in case that call is what sticks.
    /// Whatever was being said is cut, as a cancel would (not when called from a cancel or the end of an utterance).
    private func freshSynth(because reason: String, cut: Bool = true) {
        let old = synth, oldQueue = synthQueue
        synth = AVSpeechSynthesizer()
        synth.delegate = finishWatch
        synthQueue = DispatchQueue(label: "turnover.synth")
        idleSynths.removeAll()   // a fresh start: the idle ones may share whatever went wrong
        nonisolated(unsafe) let stale = old
        oldQueue.async { stale.delegate = nil; stale.stopSpeaking(at: .immediate) }
        onOutputChange?("speech: a fresh synthesizer (\(reason))")
        if cut { cancelOnQueue() }
    }

    /// Stopping the synthesizer is done off this queue, on one that's then put aside: its stop call sometimes never
    /// returned (a tester, build 20, 19 Oct 2026: say all, then an arrow; five times in a few hours, each with this
    /// queue and then the main thread stuck, and TurnOver restarted by the watch: "synthesizer stop" was the last call).
    /// A synthesizer that was speaking is swapped for an idle one at once, and stopped elsewhere; it rejoins the idle
    /// ones when its stop returns, and is simply left behind if it never does. Nothing here waits on it.
    private var idleSynths: [(AVSpeechSynthesizer, DispatchQueue)] = []
    private func retireSynth() {
        guard current != nil || rendering else { return }
        let old = synth, oldQueue = synthQueue
        if let (s, q) = idleSynths.popLast() { synth = s; synthQueue = q }
        else { synth = AVSpeechSynthesizer(); synth.delegate = finishWatch; synthQueue = DispatchQueue(label: "turnover.synth") }
        nonisolated(unsafe) let stopping = old
        oldQueue.async { [weak self] in
            stopping.stopSpeaking(at: .immediate)
            self?.queue.async { [weak self] in
                guard let self, self.idleSynths.count < 2, stopping !== self.synth else { return }
                self.idleSynths.append((stopping, oldQueue))
            }
        }
    }

    /// The synthesizer's own word that an utterance is done. write() also sends an empty buffer between the parts it
    /// renders a long text in (after the first sentence or so, every voice, measured 6 Oct 2026): taken as the end,
    /// the next paragraph's write cut the rest off, and Say All skipped most of each long paragraph ().
    private final class FinishWatch: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
        var finished: (@Sendable (AVSpeechUtterance) -> Void)?   // set once, before the first utterance
        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { finished?(utterance) }
    }
    private var current: (utterance: AVSpeechUtterance, state: UtteranceState, gen: UInt64)?

    private func synthFinished(_ u: AVSpeechUtterance) {
        guard let c = current, c.utterance === u else { return }
        endRender(c.state, gen: c.gen)
    }

    private func endRender(_ state: UtteranceState, gen: UInt64) {
        guard !state.renderFinished else { return }
        state.renderFinished = true
        if state.hasWords, gen == generation {
            if state.scheduled == 0 {
                silentRuns += 1
                if silentRuns >= 2 { silentRuns = 0; freshSynth(because: "two requests gave no sound", cut: false); onVoiceSilent?(state.voice) }
            } else { silentRuns = 0 }
        }
        if current?.state === state { current = nil }
        finishIfDone(state)
        if gen == generation { renderNext() }
    }

    /// A short tone, mixed with speech rather than queued behind it (NVDA: tones.beep). 5 ms fades.
    /// A small bell: each note struck and left to fade (a quick attack, an exponential decay, a soft octave above for
    /// warmth), the next note starting while the last still rings. One buffer, so the notes never stutter.
    public func playBell(frequencies: [Double], spacingMs: Int, ringMs: Int, volume: Float = 0.12) {
        queue.async { [self] in
            let sr = format.sampleRate
            let spacing = Int(sr * Double(spacingMs) / 1000), ring = Int(sr * Double(ringMs) / 1000)
            let total = spacing * max(0, frequencies.count - 1) + ring
            guard total > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)), let data = buf.floatChannelData?[0] else { return }
            buf.frameLength = AVAudioFrameCount(total)
            for i in 0..<total { data[i] = 0 }
            let attack = Int(sr * 0.004)
            let tau = Double(ring) / 4.5   // decays to about 1% by the end of the ring
            for (n, f) in frequencies.enumerated() {
                let start = n * spacing
                for j in 0..<ring where start + j < total {
                    let t = Double(j) / sr
                    var env = exp(-Double(j) / tau)
                    if j < attack { env *= Double(j) / Double(attack) }
                    let wave = sin(2 * Double.pi * f * t) + 0.25 * sin(4 * Double.pi * f * t) * exp(-Double(j) / (tau / 2))
                    data[start + j] += Float(env * wave / 1.25) * volume
                }
            }
            doing("tone buffer")
            toneNode.scheduleBuffer(buf, completionHandler: nil)
            play(toneNode)
        }
    }

    public func playTone(frequency: Double, durationMs: Int, volume: Float = 0.25) {
        queue.async { [self] in
            let frames = AVAudioFrameCount(format.sampleRate * Double(durationMs) / 1000)
            guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let data = buf.floatChannelData?[0] else { return }
            buf.frameLength = frames
            let fade = min(Int(format.sampleRate * 0.005), Int(frames) / 2)
            for i in 0..<Int(frames) {
                var a = volume
                if i < fade { a *= Float(i) / Float(fade) }
                if i > Int(frames) - fade { a *= Float(Int(frames) - i) / Float(fade) }
                data[i] = a * Float(sin(2 * Double.pi * frequency * Double(i) / format.sampleRate))
            }
            toneNode.scheduleBuffer(buf, completionHandler: nil)
            play(toneNode)
        }
    }

    /// Speak `text`. With `interrupt`, whatever is playing or queued is dropped
    /// first. `requestedAt` lets the caller pass the originating event's time.
    /// `voice`: this utterance only (another language's voice); nil is the current voice.
    public func speak(_ text: String, interrupt: Bool = true, requestedAt: UInt64 = mach_absolute_time(), voice: String? = nil, rate rateOverride: Float? = nil,
                      pitch: Float? = nil,
                      onStart: (@Sendable () -> Void)? = nil,
                      completion: (@Sendable (_ finished: Bool) -> Void)? = nil) {
        queue.async { [self] in
            if interrupt { cancelOnQueue() }
            // One utterance renders at a time, in order: a second write while the first was rendering played their
            // buffers interleaved (a typed word and its punctuation queued together).
            let job = { [self] in render(text, requestedAt: requestedAt, voice: voice, rate: rateOverride, pitch: pitch, onStart: onStart, completion: completion) }
            if rendering { waiting.append((job, completion)) } else { job() }
        }
    }

    private var rendering = false
    private var waiting: [(() -> Void, (@Sendable (Bool) -> Void)?)] = []

    /// A voice from outside the Mac's speech (Kokoro, on the maintainer's Mac, 12 Oct 2026): a voice identifier starting
    /// "external:" is rendered by this, which delivers its audio buffers and then nil, and returns a way to cancel; nil
    /// when it can't take the utterance now. Anything that fails, or gives nothing within a second, is said with the
    /// Mac's own voice instead, so speech never stops.
    public typealias ExternalRenderer = (_ text: String, _ voice: String, _ deliver: @escaping @Sendable (AVAudioPCMBuffer?) -> Void) -> (@Sendable () -> Void)?
    public var externalRenderer: ExternalRenderer?
    /// The Mac voice used when the external voice can't speak.
    public var fallbackVoiceIdentifier = ""

    /// Start the next utterance waiting to render (queue).
    private func renderNext() {
        rendering = false
        guard !waiting.isEmpty else { return }
        let (job, _) = waiting.removeFirst()
        job()
    }

    private func render(_ text: String, requestedAt: UInt64, voice: String?, rate rateOverride: Float? = nil, pitch: Float? = nil, onStart: (@Sendable () -> Void)?, completion: (@Sendable (Bool) -> Void)?) {
        do {
            ensureRunning(reason: "before a render")   // an utterance with no cancel before it waited on a stopped engine (the code review, 17 Oct 2026)
            rendering = true
            // Only a cancel moves the generation on. Moving it for every utterance dropped the buffers of one still
            // rendering when the next was queued: "there," was heard as "comma" alone.
            let gen = generation
            var made = SpeechTiming(requestedAt: requestedAt, firstBufferAt: nil, text: text)
            made.voice = voice ?? voiceIdentifier
            let timing = TimingBox(made)   // the speech queue's
            let state = UtteranceState(completion: completion)
            state.startedAt = Date()
            pending.append(state); noteBusy()
            heartbeat(state)
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? AVSpeechSynthesisVoice(identifier: voiceIdentifier) ?? AVSpeechSynthesisVoice(language: nil) ?? AVSpeechSynthesisVoice(language: "en-GB")   // (language nil: the system language's voice; a Spanish tester heard English: code review, 16 Oct 2026)
            state.voice = utterance.voice?.identifier ?? ""
            state.hasWords = text.contains { $0.isLetter || $0.isNumber }
            // A voice that never answers would hold every utterance behind it: after 3 s with nothing, it is done.
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, state.buffers == 0, !state.renderFinished else { return }
                self.endRender(state, gen: gen)
            }
            utterance.rate = rateOverride ?? rate
            let base = self.pitch
            if let pitch { utterance.pitchMultiplier = max(0.5, min(2, pitch * base)) }   // a capital letter, raised (NVDA)
            else if abs(base - 1) > 0.001 { utterance.pitchMultiplier = base }
            current = (utterance, state, gen)
            // An external voice (Kokoro): its buffers go through the same path; if it can't, or is silent for a second,
            // the Mac's voice says it.
            let wanted = voice ?? voiceIdentifier
            if wanted.hasPrefix("external:"), let external = externalRenderer {
                let fallback: @Sendable () -> Void = { [weak self] in
                    guard let self else { return }
                    self.queue.async {
                        guard gen == self.generation, state.buffers == 0, !state.renderFinished else { return }
                        state.renderFinished = true
                        self.pending.removeAll { $0 === state }; self.noteBusy()
                        self.rendering = false
                        let mac = self.fallbackVoiceIdentifier.isEmpty ? nil : self.fallbackVoiceIdentifier
                        self.render(text, requestedAt: requestedAt, voice: mac ?? AVSpeechSynthesisVoice(language: nil)?.identifier ?? "com.apple.voice.compact.en-GB.Daniel", rate: rateOverride, pitch: pitch, onStart: onStart, completion: completion)
                    }
                }
                doing("external voice render")
                let cancel = external(text, String(wanted.dropFirst("external:".count))) { [weak self] pcm in
                    guard let self else { return }
                    guard let pcm else { self.queue.async { if state.buffers == 0 { fallback() } else { self.endRender(state, gen: gen) } }; return }
                    self.deliver(pcm, state: state, gen: gen, timing: timing, onStart: onStart)
                }
                guard let cancel else { fallback(); return }
                externalCancel = cancel
                // A second to start when nothing else is playing; while reading goes on ahead of it, longer, so a long
                // paragraph isn't said in the Mac's voice in the middle of the natural one (18 Oct 2026).
                let ahead = pending.contains { $0 !== state && !$0.done && $0.scheduled > $0.played }
                queue.asyncAfter(deadline: .now() + (ahead ? 8.0 : 1.0)) { [weak self] in
                    guard self != nil, state.buffers == 0, !state.renderFinished else { return }
                    cancel(); fallback()   // the external voice's own cancel, then the Mac voice
                }
                return
            }
            let started = Flag(), onQueue = synthQueue
            nonisolated(unsafe) let writer = synth
            nonisolated(unsafe) let toWrite = utterance
            queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, !started.isSet, gen == self.generation, self.synth === writer else { return }
                self.onOutputChange?("speech: a synthesizer didn't start writing in 1.5 s; left behind")
                self.freshSynth(because: "a write didn't start", cut: false)
                self.endRender(state, gen: gen)
            }
            onQueue.async { [weak self] in started.set(); writer.write(toWrite) { [weak self] buffer in
                guard let self, let pcm = buffer as? AVAudioPCMBuffer else { return }
                self.queue.async {
                    guard gen == self.generation else { return }
                    state.buffers += 1
                    if pcm.frameLength == 0 {
                        // An empty buffer ends a part, not always the utterance: the delegate says when it is done.
                        // Should a voice never say, nothing more arriving within 2 s ends it.
                        let seen = state.buffers
                        self.queue.asyncAfter(deadline: .now() + 2) {
                            guard state.buffers == seen else { return }
                            self.endRender(state, gen: gen)
                        }
                        return
                    }
                    guard let out = self.convert(pcm) else { return }
                    self.applyVolume(out)
                    if timing.value.firstBufferAt == nil {
                        timing.value.firstBufferAt = mach_absolute_time()
                        self.onFirstAudio?(timing.value)
                    }
                    state.scheduled += 1
                    state.frames += AVAudioFramePosition(out.frameLength)
                    if state.scheduled == 1, let onStart {
                        // The utterance's first buffer: report when it is rendered (about to leave), so
                        // Say All can move the caret to the chunk as it starts, NVDA's lineReached.
                        let length = AVAudioFramePosition(out.frameLength)
                        self.player.scheduleBuffer(out, completionCallbackType: .dataRendered) { _ in
                            self.noteStart(state, length: length)
                            onStart()
                            self.queue.async {
                                state.played += 1
                                self.finishIfDone(state)
                            }
                        }
                    } else {
                        self.player.scheduleBuffer(out, completionCallbackType: .dataPlayedBack) { _ in
                            self.queue.async {
                                state.played += 1
                                self.finishIfDone(state)
                            }
                        }
                    }
                }
            } }
        }
    }

    private var externalCancel: (@Sendable () -> Void)?

    /// An external voice's buffer, on its way through the same steps as the Mac voice's: converted, volume, scheduled.
    private func deliver(_ pcm: AVAudioPCMBuffer, state: UtteranceState, gen: UInt64, timing: TimingBox, onStart: (@Sendable () -> Void)?) {
        queue.async {
            guard gen == self.generation, !state.renderFinished || state.buffers > 0 else { return }
            state.buffers += 1
            guard pcm.frameLength > 0, let out = self.convert(pcm) else { return }
            self.applyVolume(out)
            if timing.value.firstBufferAt == nil {
                timing.value.firstBufferAt = mach_absolute_time()
                self.onFirstAudio?(timing.value)
            }
            state.scheduled += 1
            state.frames += AVAudioFramePosition(out.frameLength)
            let first = state.scheduled == 1 && onStart != nil
            let length = AVAudioFramePosition(out.frameLength)
            self.doing("schedule a buffer")
            self.player.scheduleBuffer(out, completionCallbackType: first ? .dataRendered : .dataPlayedBack) { _ in
                if first { self.noteStart(state, length: length); onStart?() }
                self.queue.async {
                    state.played += 1
                    self.finishIfDone(state)
                }
            }
        }
    }

    /// The player's sample time as an utterance's first buffer finished rendering: where that utterance began.
    /// Called from the player's own completion callback: it must not touch the player there. AVAudioPlayerNode.stop()
    /// waits for its callbacks to finish while holding the node, and this callback asked the node for its time:
    /// each waited for the other for ever (19 Oct 2026: the stress test of say all and arrows, "player stop" the
    /// speech queue's last call; a tester's five restarts on build 20). The player is asked on the speech queue.
    private func noteStart(_ state: UtteranceState, length: AVAudioFramePosition) {
        queue.async { [self] in
            doing("render time (start)")
            guard let t = player.lastRenderTime, let p = player.playerTime(forNodeTime: t) else { return }
            state.startSample = max(0, p.sampleTime - length)
        }
    }

    /// How far through the utterance now playing the reading is, 0 to 1 (nil if nothing is): asked before a cancel,
    /// so say all can leave the caret on the word it stopped at.
    public func progressOfCurrent() -> Double? {
        // Asked on the main thread: never waits more than a fifth of a second for this queue (it waited for ever behind
        // a synthesizer that didn't stop, and took the main thread with it: 19 Oct 2026).
        final class Answer: @unchecked Sendable { var value: Double? }
        let answer = Answer(), done = DispatchSemaphore(value: 0)
        queue.async { [self] in answer.value = progressOnQueue(); done.signal() }
        return done.wait(timeout: .now() + 0.2) == .success ? answer.value : nil
    }
    private func progressOnQueue() -> Double? {
        do {
            doing("render time (progress)")
            guard let t = player.lastRenderTime, let p = player.playerTime(forNodeTime: t) else { return nil }
            let now = p.sampleTime
            let playing = pending.filter { !$0.done && $0.startSample != nil && $0.frames > 0 }
                .last { now >= ($0.startSample ?? 0) }
            guard let u = playing, let start = u.startSample else { return nil }
            return min(1, max(0, Double(now - start) / Double(u.frames)))
        }
    }

    private final class UtteranceState: @unchecked Sendable {   // the speech queue's
        var startedAt: Date?
        var scheduled = 0
        var played = 0
        var buffers = 0
        var renderFinished = false
        var done = false
        var voice = ""
        var hasWords = false
        /// For where the reading has got to (say all stopping on a word): the frames scheduled, and the player's
        /// sample time as the first of them started.
        var frames: AVAudioFramePosition = 0
        var startSample: AVAudioFramePosition?
        let completion: (@Sendable (Bool) -> Void)?
        init(completion: (@Sendable (Bool) -> Void)?) { self.completion = completion }
    }
    private var pending: [UtteranceState] = []

    private func finishIfDone(_ state: UtteranceState) {
        guard !state.done, state.renderFinished, state.played >= state.scheduled else { return }
        state.done = true
        pending.removeAll { $0 === state }; noteBusy()
        state.completion?(true)
    }

    /// Pause where it is, and carry on from there (VoiceOver's Control; 6 Oct 2026). A cancel ends the pause.
    public var isPaused: Bool { busyLock.lock(); defer { busyLock.unlock() }; return paused }
    private var paused = false
    public func pause() {
        queue.async { [self] in player.pause(); busyLock.lock(); paused = true; busyLock.unlock() }
    }
    public func resume() {
        queue.async { [self] in ensureRunning(reason: "resuming"); play(player); busyLock.lock(); paused = false; busyLock.unlock() }
    }

    /// Stop now. Sub-buffer: the player node drops what it holds.
    public func cancel() {
        queue.async { [self] in cancelOnQueue() }
    }

    /// How long the last cancel took (stopping the synthesizer mid-render can be slow): read for the timing log.
    public private(set) var lastCancelMs: Double = 0

    private var configObserver: NSObjectProtocol?

    /// A node set playing, only while the engine runs: AVAudioPlayerNode.play() on a stopped engine raises an
    /// Objective-C exception Swift can't catch, and TurnOver ended. It did, the Mac locking and sleeping on 18 Oct
    /// 2026: the engine stopped with the audio device, a cancel played the node, and TurnOver was gone until restarted by hand. The next
    /// speech starts the engine again (ensureRunning) and plays it then.
    /// The check alone wasn't enough: the engine said it was running and the device went a moment later (the lid closed,
    /// 19 Oct 2026, the same crash): the play is also run inside TOCatch, which catches the exception.
    private func play(_ node: AVAudioPlayerNode) {
        guard engine.isRunning, node.engine != nil else { NSLog("speech: not playing a node while the audio engine is stopped"); return }
        guard !node.isPlaying else { return }
        var reason: NSString?
        doing("node play")
        if !TOCatch({ node.play() }, &reason) { NSLog("speech: the audio device went as a node was played (%@); the next speech starts it again", (reason ?? "") as String) }
    }

    /// A new player with this one's voice, settings and callbacks, for when this one's queue is stuck in Apple's audio
    /// code (its stop or play calls, 19 Oct 2026): TurnOver carries on with the new one and leaves this one behind,
    /// instead of restarting. Reads nothing through the stuck queue.
    public func freshCopy() throws -> SpeechPlayer {
        let p = try SpeechPlayer(voice: voiceIdentifier, rate: rate, bufferFrames: bufferFrames)
        p.volume = volume; p.pitch = pitch; p.fallbackVoiceIdentifier = fallbackVoiceIdentifier
        p.onFirstAudio = onFirstAudio; p.onVoiceSilent = onVoiceSilent; p.onOutputChange = onOutputChange
        p.onQueueStuck = onQueueStuck; p.externalRenderer = externalRenderer
        if let uid = chosenUID { p.outputDeviceUID = uid }
        return p
    }

    /// A claim on one stalled heartbeat generation. Recovery checks it again after building a replacement, so
    /// a resumed queue, a newer claim or an installed player cannot accept an obsolete result (#155, 28 Oct 2026).
    public struct QueueStall: Sendable {
        public let player: SpeechPlayer
        private let stall: SpeechQueueWatch.Stall
        public var seconds: TimeInterval { stall.seconds }
        public var isStillStalled: Bool { player.queueWatch.isCurrent(stall) }

        fileprivate init(player: SpeechPlayer, stall: SpeechQueueWatch.Stall) {
            self.player = player
            self.stall = stall
        }
    }

    /// Called from the watch thread when the speech queue hasn't run for 4 s. Return true once recovery accepts
    /// the claim; false defers it to the next poll (for example during sleep/wake grace). A tester switched to AirPods
    /// and TurnOver stopped speaking without crashing, until he quit and started it (19 Oct 2026): the log's
    /// last speech line was the switch to the AirPods, then words asked for and no audio, and not even the 4-second
    /// silence check, which runs on the same queue. The likeliest cause is a CoreAudio call on that queue stuck on a
    /// Bluetooth device still connecting (a stuck driver call has stopped every sound before: Teams, 10 Oct 2026).
    /// Nothing can unstick the call; the owner replaces the player or restarts TurnOver.
    private let queueStuckCallback = OSAllocatedUnfairLock<(@Sendable (QueueStall) -> Bool)?>(initialState: nil)
    public var onQueueStuck: (@Sendable (QueueStall) -> Bool)? {
        get { queueStuckCallback.withLock { $0 } }
        set { queueStuckCallback.withLock { $0 = newValue } }
    }
    private let queueWatch = SpeechQueueWatch()
    private func doing(_ what: String) { queueWatch.noteDoing(what) }
    private func watchQueue() {
        let watch = queueWatch, queue = queue
        let t = Thread { [weak self] in
            while true {
                Thread.sleep(forTimeInterval: 2)
                guard let self, !watch.isRetired else { return }
                queue.async { watch.heartbeat() }
                guard let stall = watch.claim() else { continue }
                let request = QueueStall(player: self, stall: stall)
                guard let callback = self.onQueueStuck else {
                    watch.complete(stall, accepted: false)
                    continue
                }
                guard request.isStillStalled else { continue }
                self.onOutputChange?("speech: the speech queue has not run for \(Int(stall.seconds)) s; its last call that waits on the system: \(stall.doing)")
                let accepted = callback(request)
                watch.complete(stall, accepted: accepted)
            }
        }
        t.name = "turnover.speech.watch"
        t.qualityOfService = .utility
        t.start()
    }

    /// The engine running, started again if it stopped (speech queue).
    private func ensureRunning(reason: String) {
        if engine.isRunning { return }
        doing("engine start (\(reason))")
        do {
            try engine.start()
            play(player)
            play(toneNode)
            NSLog("speech: audio engine restarted (%@)", reason)
        } catch {
            NSLog("speech: audio engine would not restart (%@): %@", reason, "\(error)")
            // Once in 30 s: every key restarts the engine, and a Mac whose only output device went got two alerts a
            // keystroke (a code review, 14 Oct 2026).
            guard Date().timeIntervalSince(lastAlertAt) > 30 else { return }
            lastAlertAt = Date()
            // No speech to say it with: the system alert sound, twice, so the silence is at least explained as a
            // fault (the team review: failures that leave the user without speech are told, 8 Oct 2026).
            AudioServicesPlaySystemSound(kSystemSoundID_UserPreferredAlert)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { AudioServicesPlaySystemSound(kSystemSoundID_UserPreferredAlert) }
        }
    }

    private var lastAlertAt = Date.distantPast
    /// Four seconds after a request with words, no buffer and no cancel: said once a minute with the system's own
    /// voice, which needs no engine, and logged with the engine's state (a code review on 17 Oct 2026: silence must
    /// be told, not just suffered).
    private var lastSilenceTold = Date.distantPast
    private func heartbeat(_ state: UtteranceState) {
        guard state.hasWords else { return }
        queue.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, !state.renderFinished, state.scheduled == 0, self.current?.state === state else { return }
            let line = "speech: no audio 4 s after a request (engine running \(self.engine.isRunning), paused \(self.paused), voice \(state.voice))"
            self.onOutputChange?(line)
            guard Date().timeIntervalSince(self.lastSilenceTold) > 60 else { return }
            self.lastSilenceTold = Date()
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/say"); p.arguments = ["TurnOver's voice is not sounding. Press Command Control Period twice to restart it."]
            try? p.run()
        }
    }

    private func cancelOnQueue() {
        ensureRunning(reason: "before a cancel")
        let t0 = DispatchTime.now().uptimeNanoseconds
        defer { lastCancelMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000 }
        // A run with words that produced no buffer in a third of a second before being cut counts as silent: a user
        // hearing nothing presses keys, and each key cancelled the count (the code review, 17 Oct 2026).
        if let c = current, c.state.hasWords, c.state.scheduled == 0, let at = c.state.startedAt, Date().timeIntervalSince(at) > 0.33 {
            silentRuns += 1
            if silentRuns >= 2 { silentRuns = 0; freshSynth(because: "two requests gave no sound", cut: false); onVoiceSilent?(c.state.voice) }
        }
        retireSynth()   // while `current` still says whether something was being rendered
        generation &+= 1
        current = nil
        let dropped = waiting
        waiting.removeAll()
        rendering = false
        for (_, completion) in dropped { completion?(false) }
        doing("external voice cancel")
        externalCancel?(); externalCancel = nil   // the external voice stops making what won't be heard
        doing("player stop")
        player.stop()
        doing("player play")
        play(player)
        doing("converter reset")
        converters.values.forEach { $0.reset() }
        doing("cancel done")   // the resampler's held frames from the cut utterance (code review, 16 Oct 2026)
        busyLock.lock(); paused = false; busyLock.unlock()
        let cancelled = pending
        pending.removeAll(); noteBusy()
        for s in cancelled where !s.done { s.done = true; s.completion?(false) }
    }

    /// True while anything is rendering or playing.
    /// Read on the main thread for every typed word: a locked count, not a hop onto the speech queue (which waited
    /// behind the synthesizer: E6 audit, 4 Oct 2026).
    public var isBusy: Bool { busyLock.lock(); defer { busyLock.unlock() }; return busyCount > 0 }
    private let busyLock = NSLock()
    private var busyCount = 0
    private func noteBusy() { busyLock.lock(); busyCount = pending.count; busyLock.unlock() }

    private func convert(_ pcm: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let inFormat = pcm.format
        if inFormat.sampleRate == format.sampleRate && inFormat.channelCount == 1 && inFormat.commonFormat == .pcmFormatFloat32 && !inFormat.isInterleaved {
            return pcm
        }
        let key = "\(inFormat.sampleRate)/\(inFormat.channelCount)/\(inFormat.commonFormat.rawValue)"
        let converter: AVAudioConverter
        if let c = converters[key] { converter = c } else {
            guard let c = AVAudioConverter(from: inFormat, to: format) else { return nil }
            converters[key] = c
            converter = c
        }
        let ratio = format.sampleRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return pcm
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }
}

/// A value the speech queue changes from inside its own callbacks.
private final class TimingBox: @unchecked Sendable {
    var value: SpeechTiming
    init(_ value: SpeechTiming) { self.value = value }
}

/// A yes/no set on one queue and read on another.
/// A value shared between threads, behind a lock (TurnOverCore's Locked, which this target can't see).
final class Guarded<T>: @unchecked Sendable {
    private let lock = NSLock(); private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
