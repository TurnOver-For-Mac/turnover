// SPDX-License-Identifier: GPL-3.0-or-later
// Phonon for TurnOver (2 Nov 2026, Oliver: "I'd really like to get some good voices working"): Gradium's Phonon 31m
// through FluidAudio's Pocket TTS, on the Kokoro helper's pipes (plugins/kokoro/helper), so TurnOver speaks with
// either. Measured on an M4 (2 Nov 2026): the first frame 9 to 11 ms after a request, speech in it 9 to 25 ms once
// the silence before it is cut; Kokoro's helper is heard 40 to 120 ms after.
// In:  one JSON line per request: {"id": 7, "text": "...", "voice": "en_gb_Maeve", "speed": 1.3}, or {"cancel": 7}.
// Out: frames of a 4-byte id, a 4-byte sample count and that many float32 samples (24 kHz mono), a count of 0 ending
//      the request. Logs go to stderr as "kokoro: ..." lines, the prefix TurnOver reads for both helpers: timings and
//      errors, never the text.
// Ends when its input closes (TurnOver went). The voice files come from Hugging Face once (172 MB, FluidAudio's
// cache); after that nothing is sent anywhere.
import Foundation
import FluidAudio

// The audio goes out on a copy of stdout; anything a library prints goes to stderr, never into the audio stream.
let audioFD = dup(1)
dup2(2, 1)
let audioOut = FileHandle(fileDescriptor: audioFD, closeOnDealloc: false)
let outLock = NSLock()
let rate = 24000

func log(_ s: String) { FileHandle.standardError.write(Data("kokoro: \(s)\n".utf8)) }

func send(_ id: UInt32, _ samples: [Float]) {
    var h = id, n = Int32(samples.count)
    var d = Data(bytes: &h, count: 4); d.append(Data(bytes: &n, count: 4))
    if !samples.isEmpty { samples.withUnsafeBufferPointer { d.append(Data(buffer: $0)) } }
    outLock.lock(); defer { outLock.unlock() }
    do { try audioOut.write(contentsOf: d) } catch { exit(0) }   // TurnOver went
}

struct Request: Sendable { let id: UInt32; let text: String; let voice: String; let speed: Double }

final class Cancelled: @unchecked Sendable {
    private var ids = Set<UInt32>(); private let lock = NSLock()
    func add(_ id: UInt32) { lock.lock(); ids.insert(id); lock.unlock() }
    func has(_ id: UInt32) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.contains(id) }
    func done(_ id: UInt32) { lock.lock(); ids.remove(id); lock.unlock() }
}
let cancelled = Cancelled()

let (requests, continuation) = AsyncStream<Request>.makeStream()

// Reading on its own thread, so a cancel is seen while an utterance is being made.
Thread.detachNewThread {
    while let line = readLine() {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
        if let c = obj["cancel"] as? NSNumber { cancelled.add(c.uint32Value); continue }
        guard let id = (obj["id"] as? NSNumber)?.uint32Value, let text = obj["text"] as? String else { continue }
        let speed = min(3, max(0.5, (obj["speed"] as? NSNumber)?.doubleValue ?? 1.1))
        continuation.yield(Request(id: id, text: text, voice: obj["voice"] as? String ?? "en_gb_Maeve", speed: speed))
    }
    continuation.finish()
    exit(0)
}

/// Phonon starts each sound with 10 to 220 ms of silence and ends a short one with a second or more (measured
/// 2 Nov 2026): cut to 25 ms before the first sound and 60 ms after the last. A quiet stretch inside the speech is
/// held back until sound follows it, so pauses between words stay. The threshold is low, as Kokoro's helper's is, so a
/// soft first sound (the s of "Send") isn't cut.
struct Trim {
    let threshold: Float = 0.004
    var started = false
    var lead: [Float] = []      // before the first sound: the last 25 ms are kept
    var quiet: [Float] = []     // since the last sound
    mutating func add(_ s: [Float]) -> [Float] {
        var out: [Float] = []
        for x in s {
            if abs(x) > threshold {
                if !started { started = true; out += lead.suffix(rate * 25 / 1000); lead = [] }
                out += quiet; quiet = []
                out.append(x)
            } else if started { quiet.append(x) } else { lead.append(x) }
        }
        return out
    }
    mutating func finish() -> [Float] { started ? Array(quiet.prefix(rate * 60 / 1000)) : [] }
}

/// Faster or slower speech at the same pitch (Phonon has no speed of its own; TurnOver sends one from its speech rate): WSOLA,
/// pieces of 20 ms overlapped by half, each taken where it best continues the piece before, within 5 ms of where the
/// speed puts it. Streaming: samples go in as they come and out as soon as a piece can be placed.
struct Stretch {
    let speed: Double
    let n = 480, hop = 240, search = 120
    let window: [Float] = (0..<480).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / 480)) }
    var input: [Float] = []
    var base = 0                 // the input index input[0] stands for
    var piece = 0                // pieces placed
    var last = 0                 // where the last piece was taken from
    var tail = [Float](repeating: 0, count: 240)   // the last piece's second half, waiting to be overlapped

    init(speed: Double) { self.speed = speed }

    /// The next piece's place: near where the speed puts it, matching the last piece's natural continuation.
    private func place(_ nominal: Int) -> Int {
        guard piece > 0 else { return nominal }
        let follow = last + hop
        var best = nominal, bestScore = -Float.infinity
        for p in max(base, nominal - search)...(nominal + search) {
            var score: Float = 0
            for k in 0..<n { score += input[p - base + k] * input[follow - base + k] }
            if score > bestScore { bestScore = score; best = p }
        }
        return best
    }

    private mutating func lay(_ at: Int) -> [Float] {
        var out = [Float](repeating: 0, count: hop)
        for k in 0..<hop { out[k] = tail[k] + window[k] * input[at - base + k] }
        for k in 0..<hop { tail[k] = window[hop + k] * input[at - base + hop + k] }
        last = at; piece += 1
        // What no later piece can reach is let go.
        let keep = min(last + hop, Int(Double(piece * hop) * speed) - search)
        if keep - base > 4096 { input.removeFirst(keep - base); base = keep }
        return out
    }

    mutating func add(_ s: [Float]) -> [Float] {
        guard abs(speed - 1) > 0.01 else { return s }
        input += s
        var out: [Float] = []
        while true {
            let nominal = Int(Double(piece * hop) * speed)
            let need = max(nominal + search, last + hop) + n
            guard need <= base + input.count else { break }
            out += lay(place(nominal))
        }
        return out
    }

    mutating func finish() -> [Float] {
        // Nothing was ever given: nothing, not a tail of silence, so TurnOver's Mac voice says it (a review, 2 Nov 2026).
        guard abs(speed - 1) > 0.01, piece > 0 || !input.isEmpty else { return [] }
        // The last pieces from what there is, padded with silence, then the tail.
        let end = base + input.count
        var out: [Float] = []
        input += [Float](repeating: 0, count: n + 2 * search + hop)   // enough for the last search and continuation
        while Int(Double(piece * hop) * speed) < end { out += lay(place(Int(Double(piece * hop) * speed))) }
        return out + tail
    }
}

/// Phonon, cleared up (Oliver, 2 Nov 2026: "they're kinda muffled"; he has a little hearing loss and finds Microsoft's
/// natural voices clear). Measured against Alex on the same paragraph: Phonon puts far more of its sound between 500 Hz
/// and 1 kHz (-3.4 against -9.5 dB of the whole) and less between 2 and 4 kHz (-20 against -17 dB), where consonants
/// are heard. So a broad cut at 600 Hz, a lift at 3 kHz and a little air above 7 kHz, as the advice for clear speech
/// goes (a small cut low in the middle, a gentle lift at 2 to 4 kHz). The listener's own EQ is TurnOver's player's.
struct Voicing {
    struct Biquad {
        let b0, b1, b2, a1, a2: Float
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
        mutating func run(_ x: Float) -> Float {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }
    /// The Audio EQ Cookbook's peak (Robert Bristow-Johnson).
    static func peak(_ f: Double, q: Double, gain: Double) -> Biquad {
        let a = pow(10, gain / 40), w = 2 * Double.pi * f / Double(rate), alpha = sin(w) / (2 * q), c = cos(w), a0 = 1 + alpha / a
        return Biquad(b0: Float((1 + alpha * a) / a0), b1: Float(-2 * c / a0), b2: Float((1 - alpha * a) / a0), a1: Float(-2 * c / a0), a2: Float((1 - alpha / a) / a0))
    }
    /// And its high shelf, of slope 1.
    static func highShelf(_ f: Double, gain: Double) -> Biquad {
        let a = pow(10, gain / 40), w = 2 * Double.pi * f / Double(rate), c = cos(w), k = 2 * sqrt(a) * sin(w) / 2 * sqrt(2.0)
        let a0 = (a + 1) - (a - 1) * c + k
        return Biquad(b0: Float(a * ((a + 1) + (a - 1) * c + k) / a0), b1: Float(-2 * a * ((a - 1) + (a + 1) * c) / a0), b2: Float(a * ((a + 1) + (a - 1) * c - k) / a0),
                      a1: Float(2 * ((a - 1) - (a + 1) * c) / a0), a2: Float(((a + 1) - (a - 1) * c - k) / a0))
    }
    var bands = [peak(600, q: 0.8, gain: -3), peak(3000, q: 0.9, gain: 3.5), highShelf(7000, gain: 2)]
    mutating func run(_ s: [Float]) -> [Float] {
        s.map { x in
            var y = x
            for k in bands.indices { y = bands[k].run(y) }
            // A soft knee above 0.9, as TurnOver's volume has, so the raised level rounds the loudest peaks off.
            y *= level
            let a = abs(y)
            return a <= 0.9 ? y : (y < 0 ? -1 : 1) * (0.9 + 0.1 * tanhf((a - 0.9) / 0.1))
        }
    }
}
/// Then brought to the Mac voices' loudness (Phonon measured 4.5 dB quieter than Alex, and the cut takes a little more:
/// 2 Nov 2026, "the volume of the voices you've added are slightly lower than system voices").
let level: Float = 2.0

/// Short things said again and again (menu items, "button", a letter) come from here, at once.
var cache: [String: [Float]] = [:], cacheOrder: [String] = []
@MainActor func remember(_ key: String, _ s: [Float]) {
    cache[key] = s; cacheOrder.append(key)
    if cacheOrder.count > 400 { cache[cacheOrder.removeFirst()] = nil }
}

// The voice TurnOver will ask for first (its argument), loaded before "ready".
let firstVoice = CommandLine.arguments.dropFirst().first ?? "en_gb_Maeve"
let tts = PocketTtsSmallManager(model: .phonon31m)
let t0 = Date()
do {
    try await tts.initialize()
    for try await _ in try await tts.synthesizeStreaming(text: "Ready.", voice: firstVoice) {}
} catch { log("error couldn't load the model or the voice \(firstVoice): \(error)"); exit(1) }
log("ready in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")

for await r in requests {
    if cancelled.has(r.id) { send(r.id, []); cancelled.done(r.id); continue }
    let t = Date()
    let key = "\(r.voice)|\(r.speed)|\(r.text)"
    if let samples = cache[key] {
        if !samples.isEmpty { send(r.id, samples) }
        log("\(r.id) first audio \(Int(Date().timeIntervalSince(t) * 1000)) ms, \(r.voice), remembered")
        send(r.id, []); cancelled.done(r.id); continue
    }
    var trim = Trim(), stretch = Stretch(speed: r.speed), voicing = Voicing(), all: [Float] = [], first = true
    func out(_ raw: [Float]) {
        guard !raw.isEmpty else { return }
        let s = voicing.run(raw)
        send(r.id, s); all += s
        if first { first = false; log("\(r.id) first audio \(Int(Date().timeIntervalSince(t) * 1000)) ms, \(r.voice)") }
    }
    do {
        let session = try await tts.makeSession(voice: r.voice)
        session.enqueue(r.text)
        session.finish()
        for try await frame in session.frames {
            if cancelled.has(r.id) { await session.cancel(); break }
            out(stretch.add(trim.add(frame.samples)))
        }
        if !cancelled.has(r.id) {
            out(stretch.add(trim.finish()))
            out(stretch.finish())
            if r.text.count <= 60, !all.isEmpty { remember(key, all) }
        }
    } catch { log("error \(r.id): \(error)") }
    send(r.id, [])
    cancelled.done(r.id)
}
