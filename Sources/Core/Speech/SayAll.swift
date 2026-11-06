// SPDX-License-Identifier: GPL-3.0-or-later
// Say All (NVDA: speech.sayAll). Reads from the caret to the end, a reading
// chunk (paragraph) at a time, keeping a few chunks queued in the player. As
// each chunk starts to play, the caret is moved to it, so stopping leaves the
// caret where the reading was.
import Foundation

public enum SayAll {
    private static var reader: TextInfo? {
        didSet { runningLock.lock(); running = reader != nil; runningLock.unlock() }
    }
    // Read on the keyboard thread; the reader itself is only touched on main (E6 audit, 4 Oct 2026).
    private static let runningLock = NSLock()
    private static var running = false
    private static var buffered = 0
    private static var blanks = 0
    private static let maxBuffered = 3
    /// The stretch of the story being heard now, for stopping on the word reached (18 Oct 2026).
    private static var hearing: (obj: TurnOverObject, start: Int, end: Int)?
    private static var stopPoint: (obj: TurnOverObject, offset: Int)?
    private static var firstChunk = true
    private static var generation = 0
    public static var isRunning: Bool { runningLock.lock(); defer { runningLock.unlock() }; return running }
    /// Set on the keyboard thread as each key arrives: whether say all was reading when it was pressed. The key stops
    /// say all (on main) before its command is looked up, so a style's say-all keys (JAWS: Left and Right go back and
    /// on, Page Up and Down change the speed) ask this instead of isRunning.
    nonisolated public static let keyArrivedDuringSayAll = Locked(false)
    /// JAWS: Page Up and Page Down during say all change the speed for this say all only. Nil when unchanged.
    private static var sayAllRate: Float?
    private static var continuing = false

    /// NVDA: readText with CURSOR.CARET.
    public static func readText(from obj: TurnOverObject) {
        guard let info = try? obj.makeTextInfo(.caret) else { stop(); Speech.speakMessage(String(localized: "no text", comment: "Spoken message")); return }
        readText(info: info)
    }

    /// Where each chunk read is reported: nil moves the caret (NVDA's CURSOR.CARET); the review cursor passes its own
    /// (NVDA's CURSOR.REVIEW, NVDA+Shift+A), so the caret stays put.
    private static var lineReached: ((TextInfo) -> Void)?

    public static func readText(info: TextInfo, lineReached reached: ((TextInfo) -> Void)? = nil) {
        stop()
        // A new say all reads at the usual speed; one carried on by the say-all keys keeps the speed they set.
        if !continuing, sayAllRate != nil { sayAllRate = nil; Speech.player.rate = config.speech.rate }
        if let r = sayAllRate { Speech.player.rate = r }
        lineReached = reached
        reader = info
        buffered = 0
        generation += 1
        firstChunk = true
        hearing = nil
        Log.io("say all from \(info.start)")
        nextLine(generation)
    }

    private static func nextLine(_ gen: Int) {
        guard gen == generation, let r = reader else { return }
        let delta = r.move(.readingChunk, 1, endPoint: .end)
        if delta <= 0 { finish(gen); return }
        let bookmark = r.bookmark
        let obj = r.obj
        let chunk = r.copy()
        r.collapse(toEnd: true)
        var blank = false
        let text = Speech.textInfoSpeech(chunk, unit: .readingChunk, reason: .sayAll, onlyBlank: &blank)
        nonisolated(unsafe) let tones = Speech.takeSayAllTones()   // sounded as this chunk starts, below (run on main there)
        // By TurnOver's own mark for an empty range, not by the words: a paragraph that is just "blank" is read.
        if blank || Speech.cleaned(text).isEmpty {
            // Empty paragraphs are skipped, but not endlessly without yielding. (They never counted as queued speech:
            // counting them left "end of document" unsaid and the next arrow resuming say all, 8 Oct 2026.)
            blanks += 1
            if blanks < 50 { nextLine(gen) } else { blanks = 0; DispatchQueue.main.async { nextLine(gen) } }
            return
        }
        blanks = 0
        buffered += 1
        Speech.readingNow = true
        defer { Speech.readingNow = false }
        let language = chunk.language()
        // The natural voice's first words come sooner from a first sentence than from a whole paragraph: the opening
        // paragraph is read as its first sentence, then the rest (18 Oct 2026).
        var parts = [text]
        if firstChunk, KokoroVoice.wanted(reading: true), text.count > 160, let cut = firstSentenceEnd(text) {
            parts = [String(text[..<cut]), String(text[cut...])].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        firstChunk = false
        let total = max(1, parts.reduce(0) { $0 + $1.count })
        var before = 0
        for (i, part) in parts.enumerated() {
            let from = bookmark.start + (bookmark.end - bookmark.start) * before / total
            before += part.count
            let to = bookmark.start + (bookmark.end - bookmark.start) * before / total
            let isFirst = i == 0, isLast = i == parts.count - 1
            Speech.enqueue(part, language: language, onStart: {
                DispatchQueue.main.async {
                    guard gen == generation else { return }
                    hearing = (obj, from, to)
                    guard isFirst else { return }
                    tones.forEach { $0() }
                    // NVDA: lineReached — move the caret to the chunk now being spoken.
                    if let at = try? obj.makeTextInfo(.bookmark(bookmark)) { if let r = lineReached { r(at) } else { at.updateCaret() } }
                    buffered -= 1
                    nextLine(gen)
                }
            }, completion: { finished in
                if !finished, isLast { DispatchQueue.main.async { if gen == generation { stop() } } }
            })
        }
        if buffered < maxBuffered { DispatchQueue.main.async { nextLine(gen) } }
    }

    private static func finish(_ gen: Int) {
        guard gen == generation else { return }
        // The app may go on (Kindle's next page): reader is kept, so a key still stops say all while it turns.
        if buffered == 0, let obj = reader?.obj,
           AppModuleHandler.shared.appModule(for: obj.pid).sayAllReachedEnd(obj, resume: { info in
               guard gen == generation else { return }
               readText(info: info)
           }) {
            Log.io("say all: the app carries on"); return
        }
        if buffered == 0 { reader = nil; restoreRate(); Speech.speakOnly(String(localized: "end of document", comment: "Spoken message")); Log.io("say all finished") }   // (queued as the last line starts: on the display it hid that line)
        // Otherwise the last chunk's onStart will call nextLine again and land here with buffered 0.
    }

    /// The end of the first sentence (after its full stop, question or exclamation mark and the space after).
    private static func firstSentenceEnd(_ text: String) -> String.Index? {
        guard let re = try? NSRegularExpression(pattern: #"[.!?…]["'”’)]?\s+"#),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.range.location > 20, let r = Range(m.range, in: text) else { return nil }
        return r.upperBound
    }

    /// Asked just before a key cancels speech: where in the story the reading had got to, by how far through the
    /// part being heard the voice was (the speech player's progress), back to the start of that word.
    public static func noteStopPoint() {
        guard isRunning else { stopPoint = nil; return }
        let progress = Speech.player?.progressOfCurrent()
        Log.io("say all: stop point: hearing \(hearing.map { "\($0.start)-\($0.end)" } ?? "none"), progress \(progress.map { String(format: "%.2f", $0) } ?? "none")")
        guard lineReached == nil, let h = hearing, let p = progress else { stopPoint = nil; return }
        var at = h.start + Int(Double(h.end - h.start) * p)
        if let info = try? h.obj.makeTextInfo(.bookmark(Bookmark(start: h.start, end: h.end))) {
            let text = info.text as NSString
            var i = min(max(0, at - h.start), text.length)
            while i > 0, let u = Unicode.Scalar(text.character(at: i - 1)), !CharacterSet.whitespacesAndNewlines.contains(u) { i -= 1 }
            at = h.start + i
        }
        stopPoint = (h.obj, at)
    }

    public static func stop(byGesture: Bool = false) {
        guard reader != nil else { return }
        generation += 1
        reader = nil
        restoreRate()
        buffered = 0
        hearing = nil
        // A key stopped it: the caret goes to the word the voice had reached, not the start of its paragraph.
        if byGesture, let s = stopPoint, let at = try? s.obj.makeTextInfo(.bookmark(Bookmark(start: s.offset, end: s.offset))) {
            at.updateCaret()
            Log.io("say all stopped at \(s.offset)")
        } else { Log.io("say all stopped") }
        stopPoint = nil
    }

    /// NVDA: willSayAllResume — a script that resumes Say All should not speak its unit.
    /// Set by the script handler while a key that resumes say all runs (the arrows in a page during say all): the
    /// line is read once, by say all as it carries on, not by the key too (it was said twice, in two voices with
    /// Kokoro, 12 Oct 2026).
    public static var resuming = false
    public static func willResume(_ gesture: KeyboardGesture) -> Bool { resuming }

    /// The user's own speed back once say all ends; the say-all speed is kept for carrying on.
    private static func restoreRate() {
        if sayAllRate != nil { Speech.player.rate = config.speech.rate }
    }

    /// JAWS's say-all keys: Left and Right go back or on a sentence from where the reading had got to (the key put the
    /// caret there as it stopped say all), and say all carries on from there.
    public static func carryOn(bySentences direction: Int) {
        guard let obj = API.caretObject, let at = try? obj.makeTextInfo(.caret) else { return }
        at.collapse()
        if direction != 0 {
            // Back: to the start of this sentence first, then one more if already there (as rewinding feels).
            if direction < 0 {
                let start = at.copy(); start.expand(.sentence); start.collapse()
                if start.compareEndPoints(at, .startToStart) < 0 { at.setEndPoint(start, .startToStart); at.collapse() } else { _ = at.move(.sentence, -1) }
            } else { _ = at.move(.sentence, 1) }
        }
        continuing = true
        readText(info: at)
        continuing = false
    }

    /// JAWS's Page Up and Page Down during say all: faster or slower for this say all only, carrying on from where it
    /// had got to.
    public static func changeRate(by delta: Float) {
        let r = min(1.0, max(0.1, (sayAllRate ?? config.speech.rate) + delta))
        sayAllRate = r
        Speech.player.rate = r
        Log.io("say all: rate \(Int((r * 100).rounded())) for this say all")
        carryOn(bySentences: 0)
    }
}
