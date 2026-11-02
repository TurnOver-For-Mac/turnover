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
import Security

public enum KokoroVoice {
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/TurnOver/kokoro")

    /// This Mac has it: the default set and a helper there. Not a developer build's switch since 2 Nov 2026 (the
    /// maintainer runs release builds), but outside one a helper is started only if it is signed as TurnOver is
    /// (trusted), so a program that sets the default and leaves its own helper there hears nothing.
    public static var available: Bool {
        UserDefaults.standard.bool(forKey: "kokoro") && (hasPhonon || FileManager.default.fileExists(atPath: swiftHelper.path)
            || FileManager.default.fileExists(atPath: folder.appendingPathComponent("server.py").path))
    }
    static var swiftHelper: URL { folder.appendingPathComponent("kokoro-helper") }
    /// Phonon's helper (plugins/phonon/helper, 2 Nov 2026): heard as quickly as the Mac voice, so it can be the voice
    /// for everything (Oliver: "I want to be able to use these voices instead of alex"). Where it is, its voices are
    /// the ones offered; Kokoro's helper stays for a Mac without it.
    static var phononHelper: URL { folder.appendingPathComponent("phonon-helper") }
    static var hasPhonon: Bool { FileManager.default.isExecutableFile(atPath: phononHelper.path) }

    // Settings, kept in this Mac's defaults (personal): "off", "reading" (say all) or "everything". Everything was
    // tried twice with Kokoro and dropped twice (12 Oct 2026): even at 0.1 s a phrase, moving around wanted the Mac
    // voice's speed. Back with Phonon (2 Nov 2026), whose speech is ready in 9 to 25 ms, as the Mac voice's is.
    public static var mode: String {
        get { ["off", "everything"].first { $0 == UserDefaults.standard.string(forKey: "kokoroMode") } ?? "reading" }
        set { UserDefaults.standard.set(newValue, forKey: "kokoroMode"); if newValue != "off" { start() } }
    }

    /// A sample in a voice, at the speed set: after the menu's own words, so they don't cut it off (they did: the
    /// sample was cancelled and only the menu was heard, in the Mac voice).
    public static func preview(_ v: String, text: String? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            Speech.player.speak(text ?? "This is \(displayName(v).components(separatedBy: ",")[0]). The harbour opens at nine.", interrupt: true, voice: "external:" + v)
        }
    }
    /// A Kokoro voice chosen before is Phonon's Maeve where Phonon's helper is (Kokoro's voices can go: Oliver).
    public static var voice: String {
        get {
            let v = UserDefaults.standard.string(forKey: "kokoroVoice") ?? "bf_emma"
            // Both ways: a Phonon voice kept after Phonon's helper went is Kokoro's Emma (a review, 2 Nov 2026).
            if hasPhonon { return phononVoices.contains(v) ? v : "en_gb_Maeve" }
            return phononVoices.contains(v) ? "bf_emma" : v
        }
        set { UserDefaults.standard.set(newValue, forKey: "kokoroVoice") }
    }
    /// A natural voice's speed from the speech rate, as the Mac voices take it (0.1 to 1, 0.5 their own pace): the same
    /// slider and keys for both (Oliver, 2 Nov 2026: "all the same settings whereever the voice comes from"). Doubled
    /// each 0.31 above 0.5 and halved each 0.31 below, kept from 0.5 to 3 times the voice's own pace.
    nonisolated package static func speed(forRate rate: Float) -> Double { min(3, max(0.5, pow(2, (Double(rate) - 0.5) * 3.2))) }

    /// The English voices (US and UK): Kokoro v1.0's, which both helpers have.
    public static let englishVoices = [
        "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore", "af_nicole", "af_nova", "af_river",
        "af_sarah", "af_sky", "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael", "am_onyx",
        "am_puck", "am_santa", "bf_alice", "bf_emma", "bf_isabella", "bf_lily", "bm_daniel", "bm_fable", "bm_george",
        "bm_lewis",
    ]

    /// Phonon 31m's English voices, as its helper listed them (2 Nov 2026).
    public static let phononVoices = [
        "en_gb_Alfie", "en_gb_Bryony", "en_gb_Edwin", "en_gb_Elodie-Rose", "en_gb_Freya", "en_gb_Hugh", "en_gb_Imogen",
        "en_gb_Lottie", "en_gb_Maeve", "en_gb_Pippa", "en_gb_Spencer", "en_gb_Teddy", "en_gb_Toby", "en_us_Delia",
        "en_us_Easton", "en_us_Everly", "en_us_Hadley", "en_us_Harper", "en_us_Juniper", "en_us_Micah", "en_us_Miles",
        "en_us_Preston", "en_us_Russell", "en_us_Trevor", "en_us_Zoey",
    ]
    /// The voices this Mac offers: Phonon's where its helper is, otherwise Kokoro's.
    public static var voices: [String] { hasPhonon ? phononVoices : englishVoices }

    /// The speech voice as the Voice list and the speech settings ring show it: the natural voice ("external:…") while it
    /// speaks everything, otherwise the Mac voice. Underneath, the Mac voice stays the speech voice: other languages,
    /// raised capitals and a slow moment are said with it (Oliver, 2 Nov 2026: natural voices chosen "in the same way
    /// I do with the normal voices", and ticked for the rotor).
    public static var speechVoiceID: String { available && mode == "everything" ? "external:" + voice : config.speech.voice }
    /// The natural voices as entries of the Voice list and the rotor.
    public static var voiceEntries: [(id: String, name: String)] {
        available ? voices.map { ("external:" + $0, String(localized: "\(displayName($0)), natural", comment: "A natural voice in the voice list: its name and accent")) } : []
    }
    /// A voice chosen from the ring (or the Voice list): a natural one speaks everything; a Mac one is the speech voice,
    /// and the natural voice no longer speaks everything.
    public static func choose(_ id: String) {
        if id.hasPrefix("external:") {
            let v = String(id.dropFirst("external:".count))
            guard voices.contains(v) else { return }
            voice = v; mode = "everything"
        } else {
            config.speech.voice = id
            Speech.player.voiceIdentifier = id
            Speech.player.fallbackVoiceIdentifier = id
            Languages.forget()
            if mode == "everything" { mode = "off" }
        }
    }

    /// "bf_emma" → "Emma, British"; "en_gb_Maeve" → "Maeve, British"
    public static func displayName(_ v: String) -> String {
        let phonon = v.hasPrefix("en_")
        let name = phonon ? String(v.dropFirst(6)).replacingOccurrences(of: "-", with: " ") : v.dropFirst(3).capitalized
        return (phonon ? v.hasPrefix("en_gb") : v.hasPrefix("b"))
            ? String(localized: "\(name), British", comment: "A natural voice: its name and accent")
            : String(localized: "\(name), American", comment: "A natural voice: its name and accent")
    }

    /// Whether this utterance goes to the natural voice: on, and everything or say all.
    static func wanted(reading: Bool) -> Bool {
        guard available, ready.value else { return false }
        return mode == "everything" || (mode == "reading" && reading)
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
        let helper = hasPhonon && voice.hasPrefix("en_") ? phononHelper : swiftHelper
        let signed = trusted(helper)
        helperTrusted.value = signed
        guard Edition.isDevBuild || signed else {
            Log.warning("kokoro: \(helper.lastPathComponent) isn't signed by TurnOver's developer; not started"); return
        }
        if hasPhonon, voice.hasPrefix("en_") {
            path = phononHelper.path
            args = [voice]
        } else if FileManager.default.isExecutableFile(atPath: swiftHelper.path) {
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
        Speech.player.externalRenderer = { text, voice, rate, deliver in render(text, voice: voice, rate: rate, deliver: deliver) }
        Speech.player.onExternalFallback = { fellBack() }
    }

    /// The helper running is signed by TurnOver's own developer, so private speech may go to it as to the Mac's voices.
    /// (Private speech is also everything typed, kept out of the log: with it kept from the helper too, typing was in
    /// the Mac voice while everything else was natural, Oliver, 2 Nov 2026.)
    nonisolated static let helperTrusted = Locked(false)

    /// Whether a helper is signed by the developer team that signed this TurnOver: Developer ID, the same team (a
    /// review, 2 Nov 2026: with the default alone, a planted helper would have been handed everything TurnOver says,
    /// two-factor codes and copied passwords included). A TurnOver signed ad hoc trusts no helper this way.
    static func trusted(_ helper: URL) -> Bool {
        var me: SecCode?, mine: SecStaticCode?, info: CFDictionary?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me, SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine,
              SecCodeCopySigningInformation(mine, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String else { return false }
        var code: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(helper as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString, [], &requirement) == errSecSuccess
        else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
    }

    /// The helper gave nothing in time twice running: it is stuck, not just slow, so it is started again (a review,
    /// 2 Nov 2026: with everything in the natural voice, every key would otherwise wait a second for the Mac voice).
    nonisolated private static let fallbacks = Locked(0)
    nonisolated static func fellBack() {
        let n: Int = { fallbacks.lock.lock(); defer { fallbacks.lock.unlock() }; fallbacks.unsafeValue += 1; return fallbacks.unsafeValue }()
        guard n >= 2 else { return }
        fallbacks.value = 0
        DispatchQueue.main.async {
            guard let p = process else { return }
            Log.warning("kokoro: the helper gave nothing twice running; starting it again")
            ready.value = false
            kill(p.pid, SIGTERM)   // `ended` starts it again
        }
    }

    /// One utterance to the helper (any thread). Nil when it isn't ready: the speech player uses the Mac voice.
    nonisolated static let writer = DispatchQueue(label: "turnover.kokoro.write")
    nonisolated static func render(_ text: String, voice: String, rate: Float, deliver: @escaping @Sendable (AVAudioPCMBuffer?) -> Void) -> (@Sendable () -> Void)? {
        guard ready.value else { return nil }
        let id: UInt32 = { nextID.lock.lock(); defer { nextID.lock.unlock() }; let i = nextID.unsafeValue; nextID.unsafeValue &+= 1; return i }()
        handlers.lock.lock(); handlers.unsafeValue[id] = deliver; handlers.lock.unlock()
        // The speed from the speech rate; the EQ and the volume are the speech player's, as for any voice.
        let request: [String: Any] = ["id": id, "text": text, "voice": voice, "speed": speed(forRate: rate)]
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
            fallbacks.value = 0
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { continue }
            pcm.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { src in pcm.floatChannelData![0].update(from: src.baseAddress!, count: samples.count) }
            h(pcm)
        }
    }
}
