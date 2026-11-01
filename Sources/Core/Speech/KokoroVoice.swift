// SPDX-License-Identifier: GPL-3.0-or-later
// Kokoro, natural voices made on this Mac (12 Oct 2026: "something super good like the Microsoft ones").
// Personal, like Games: only on a Mac with the "kokoro" default set and the helper present in
// ~/Library/Developer/TurnOver/kokoro: kokoro-helper, the Swift one (plugins/kokoro/helper: FluidAudio, Core ML;
// about 0.1 s for a short phrase), or else server.py (Python, MLX; 0.12 to 0.24 s). Nothing is sent anywhere: the
// model runs here, on Apple silicon.
//
// TurnOver starts the helper and talks to it through pipes: a JSON line per utterance in; frames of id, sample count and
// float32 samples (24 kHz mono) out, a count of 0 ending each. The speech player asks for "external:<voice>" voices
// through SpeechPlayer.externalRenderer; anything that fails or is slow is said with the Mac's own voice instead.
// The helper ends by itself when TurnOver goes (its input closes).
import Foundation
import AVFoundation

public enum KokoroVoice {
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/TurnOver/kokoro")

    /// This Mac has it: the default set and the helper there.
    public static var available: Bool {
        Edition.devDefault("kokoro") && (FileManager.default.fileExists(atPath: swiftHelper.path)
            || FileManager.default.fileExists(atPath: folder.appendingPathComponent("server.py").path))
    }
    static var swiftHelper: URL { folder.appendingPathComponent("kokoro-helper") }

    // Settings, kept in this Mac's defaults (personal): "off" or "reading" (say all). "Everything" was tried twice
    // and dropped twice (12 Oct 2026): even at 0.1 s a phrase, moving around wants the Mac voice's speed, and
    // making the next items in advance was "a bit messy". "just the speak all will have to be the only option".
    public static var mode: String {
        get { UserDefaults.standard.string(forKey: "kokoroMode") == "off" ? "off" : "reading" }
        set { UserDefaults.standard.set(newValue, forKey: "kokoroMode"); if newValue != "off" { start() } }
    }

    /// A sample in a voice, at the speed set: after the menu's own words, so they don't cut it off (they did: the
    /// sample was cancelled and only the menu was heard, in the Mac voice).
    public static func preview(_ v: String, text: String? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            Speech.player.speak(text ?? "This is \(displayName(v).components(separatedBy: ",")[0]). The harbour opens at nine.", interrupt: true, voice: "external:" + v)
        }
    }
    public static var voice: String {
        get { UserDefaults.standard.string(forKey: "kokoroVoice") ?? "bf_emma" }
        set { UserDefaults.standard.set(newValue, forKey: "kokoroVoice") }
    }
    public static var speed: Double {
        get { let s = UserDefaults.standard.double(forKey: "kokoroSpeed"); return s > 0 ? s : 1.1 }
        set { UserDefaults.standard.set(newValue, forKey: "kokoroSpeed") }
    }

    /// The English voices (US and UK): Kokoro v1.0's, which both helpers have.
    public static let englishVoices = [
        "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore", "af_nicole", "af_nova", "af_river",
        "af_sarah", "af_sky", "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael", "am_onyx",
        "am_puck", "am_santa", "bf_alice", "bf_emma", "bf_isabella", "bf_lily", "bm_daniel", "bm_fable", "bm_george",
        "bm_lewis",
    ]

    /// "bf_emma" → "Emma, British"
    public static func displayName(_ v: String) -> String {
        let name = v.dropFirst(3).capitalized
        let accent = v.hasPrefix("b") ? "British" : "American"
        return "\(name), \(accent)"
    }

    /// Whether this utterance goes to Kokoro: on, and say all.
    static func wanted(reading: Bool) -> Bool {
        guard available, ready.value else { return false }
        return mode == "reading" && reading
    }

    // MARK: The helper

    /// The running helper, kept: its pipes close when it goes (dropping it ended the helper at once, 13 Oct 2026).
    private static var process: DisclaimedSpawn.Child?
    nonisolated private static let input = Locked<FileHandle?>(nil)   // read from the speech queue too
    nonisolated private static let ready = Locked(false)
    nonisolated private static let parse = Locked(Data())
    nonisolated private static let handlers = Locked([UInt32: @Sendable (AVAudioPCMBuffer?) -> Void]())
    nonisolated private static let nextID = Locked(UInt32(1))
    private static var restarts = 0
    private static var startedAt = Date()
    nonisolated private static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!

    /// Start the helper (once), and give the speech player the way to it.
    public static func start() {
        guard available, mode != "off", process == nil else { return }
        let path: String, args: [String]
        if FileManager.default.isExecutableFile(atPath: swiftHelper.path) {
            path = swiftHelper.path
            args = [voice]   // loaded before "ready", so the first words in it don't wait
        } else {
            path = folder.appendingPathComponent("venv312/bin/python").path
            args = [folder.appendingPathComponent("server.py").path]
        }
        // Started so it doesn't inherit TurnOver's Accessibility and Input Monitoring (it did, with Process: probed
        // 13 Oct 2026; the plugin design notes 12). It needs neither: it only turns text into sound.
        let started = Locked<DisclaimedSpawn.Child?>(nil)   // for `ended`, which is made before the child is
        let ended: @Sendable (Int32) -> Void = { _ in
            ready.value = false
            // The pipes' handlers end with the helper: at end of file Foundation calls them for ever with no data,
            // one spinning thread per crash (a code review, 14 Oct 2026).
            started.value?.stdout.readabilityHandler = nil
            started.value?.stderr.readabilityHandler = nil
            // Every waiting utterance ends now (the speech player says them with the Mac's voice).
            let waiting = handlers.value; handlers.value = [:]
            for (_, h) in waiting { h(nil) }
            DispatchQueue.main.async {
                Log.warning("kokoro: the helper ended")
                process = nil; input.value = nil
                // A rare crash after long use is known in the engine on macOS 27 (FluidAudio #889): a helper that ran
                // a minute or more gets its restarts back; one that dies at once three times stays off.
                if Date().timeIntervalSince(startedAt) > 60 { restarts = 0 }
                if restarts < 3 { restarts += 1; DispatchQueue.main.asyncAfter(deadline: .now() + 2) { start() } }
            }
        }
        guard let (child, disclaimed) = DisclaimedSpawn.run(path, arguments: args, directory: folder.path, exited: ended) else {
            Log.warning("kokoro: couldn't start the helper"); return
        }
        started.value = child
        child.stdout.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            received(d)
        }
        child.stderr.readabilityHandler = { h in
            let d = h.availableData
            guard let s = String(data: d, encoding: .utf8) else { return }
            if s.contains("kokoro: ready") {
                ready.value = true
                let l = s.split(separator: "\n").first { $0.contains("kokoro: ready") }.map(String.init) ?? ""
                DispatchQueue.main.async { Log.info("\(l) (\(voice), \(mode))") }
            }
            for line in s.split(separator: "\n") where line.hasPrefix("kokoro: ") && !line.contains("kokoro: ready") {
                let l = String(line); DispatchQueue.main.async { Log.io(l) }   // timings and errors only, never the text
            }
        }
        process = child; startedAt = Date()
        input.value = child.stdin
        Log.info("kokoro: helper starting (pid \(child.pid)\(disclaimed ? ", without TurnOver's permissions" : "; WARNING: it may have TurnOver's permissions"))")
        Speech.player.fallbackVoiceIdentifier = config.speech.voice
        Speech.player.externalRenderer = { text, voice, deliver in render(text, voice: voice, deliver: deliver) }
    }

    /// One utterance to the helper (any thread). Nil when it isn't ready: the speech player uses the Mac voice.
    nonisolated static let writer = DispatchQueue(label: "turnover.kokoro.write")
    nonisolated static func render(_ text: String, voice: String, deliver: @escaping @Sendable (AVAudioPCMBuffer?) -> Void) -> (@Sendable () -> Void)? {
        guard ready.value else { return nil }
        let id: UInt32 = { nextID.lock.lock(); defer { nextID.lock.unlock() }; let i = nextID.unsafeValue; nextID.unsafeValue &+= 1; return i }()
        handlers.lock.lock(); handlers.unsafeValue[id] = deliver; handlers.lock.unlock()
        let speed = UserDefaults.standard.double(forKey: "kokoroSpeed")
        let request: [String: Any] = ["id": id, "text": text, "voice": voice, "speed": speed > 0 ? speed : 1.1]
        guard let json = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        guard let handle = input.value else { return nil }
        // Written on a queue of its own, never the speech queue's: with say all handing over paragraph after paragraph
        // (and cancels), the helper's pipe filled while it was busy, the write waited, and the speech queue with it,
        // then the main thread, and TurnOver was restarted (19 Oct 2026, say all and arrows). A failed write is the
        // voice not answering: the Mac's voice says it (deliver nil).
        let pipe = handle
        writer.async {
            do { try pipe.write(contentsOf: json + Data([0x0A])) }
            catch {
                handlers.lock.lock(); let h = handlers.unsafeValue.removeValue(forKey: id); handlers.lock.unlock()
                h?(nil)
            }
        }
        return { @Sendable in
            handlers.lock.lock(); let h = handlers.unsafeValue.removeValue(forKey: id); handlers.lock.unlock()
            if h != nil, let c = try? JSONSerialization.data(withJSONObject: ["cancel": id]) {
                writer.async { try? input.value?.write(contentsOf: c + Data([0x0A])) }
            }
        }
    }

    /// For the tests: frames chopped at awkward places (as a pipe delivers them) come out whole. Returns the samples
    /// received for one request and whether its end arrived.
    public static func selfTest() -> (samples: Int, ended: Bool) {
        let got = Locked((0, false))
        handlers.lock.lock(); handlers.unsafeValue[4242] = { b in got.lock.lock(); if let b { got.unsafeValue.0 += Int(b.frameLength) } else { got.unsafeValue.1 = true }; got.lock.unlock() }; handlers.lock.unlock()
        var stream = Data()
        for n in [100, 333, 7] {
            var h = UInt32(4242), c = Int32(n)
            stream.append(Data(bytes: &h, count: 4)); stream.append(Data(bytes: &c, count: 4))
            stream.append([Float](repeating: 0.25, count: n).withUnsafeBufferPointer { Data(buffer: $0) })
        }
        var end = (UInt32(4242), Int32(0)); stream.append(Data(bytes: &end.0, count: 4)); stream.append(Data(bytes: &end.1, count: 4))
        var i = 0
        for size in [3, 7, 1, 500, 2, 9, 1000, 4096] where i < stream.count {
            let j = min(stream.count, i + size); received(stream.subdata(in: i..<j)); i = j
        }
        if i < stream.count { received(stream.subdata(in: i..<stream.count)) }
        return got.value
    }

    /// The helper's output: frames of id, count and samples.
    nonisolated private static func received(_ d: Data) {
        guard !d.isEmpty else { return }
        // Always a fresh buffer counted from zero: a trimmed Data keeps its old indices, and reading it from 0 crashed
        // TurnOver three times (12 Oct 2026). A frame that doesn't add up ends the stream, never TurnOver.
        parse.lock.lock(); parse.unsafeValue.append(d); let buf = Data(parse.unsafeValue); parse.lock.unlock()
        var consumed = 0
        var frames: [(UInt32, [Float]?)] = []
        while buf.count - consumed >= 8 {
            let id = buf.subdata(in: consumed..<consumed + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            let n = Int(buf.subdata(in: consumed + 4..<consumed + 8).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
            if n <= 0 { frames.append((id, nil)); consumed += 8; continue }
            guard n < 10_000_000 else { consumed = buf.count; break }   // garbage: drop it all
            guard buf.count - consumed >= 8 + n * 4 else { break }
            let body = buf.subdata(in: consumed + 8..<consumed + 8 + n * 4)
            frames.append((id, body.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }))
            consumed += 8 + n * 4
        }
        parse.lock.lock(); parse.unsafeValue = consumed >= buf.count ? Data() : Data(buf.subdata(in: consumed..<buf.count)); parse.lock.unlock()
        for (id, samples) in frames {
            handlers.lock.lock(); let h = handlers.unsafeValue[id]; if samples == nil { handlers.unsafeValue[id] = nil }; handlers.lock.unlock()
            guard let h else { continue }
            guard let samples else { h(nil); continue }
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { continue }
            pcm.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { src in pcm.floatChannelData![0].update(from: src.baseAddress!, count: samples.count) }
            h(pcm)
        }
    }
}
