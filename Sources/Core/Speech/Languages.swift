// SPDX-License-Identifier: GPL-3.0-or-later
// Automatic language switching (NVDA: speech's LangChangeCommand, "Automatic language switching" in its voice
// settings). Text the document marks as another language (a web page's lang, Word's proofing language) is read
// with a voice for that language: the one chosen for it in the TurnOver menu, or else the best installed. Only a
// different language switches; a different dialect of the voice's own language (en-US under an en-GB voice) does
// not, as NVDA's dialect switching is off by default. Asked by a tester (5 Oct 2026).
import Foundation
import AVFoundation
import NaturalLanguage

public enum Languages {
    /// "ar-SA" → "ar".
    public static func base(_ code: String) -> String {
        String(code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
    }

    private static var chosen: [String: String?] = [:]
    private static let lock = NSLock()

    /// The voice to read text in `language` with, or nil for the current voice.
    public static func voice(for language: String?) -> String? {
        guard config.speech.autoLanguageSwitching, let language, !language.isEmpty else { return nil }
        let wanted = base(language)
        guard !wanted.isEmpty, let current = AVSpeechSynthesisVoice(identifier: config.speech.voice) else { return nil }
        if base(current.language) == wanted { return nil }
        if let id = config.speech.languageVoices[wanted], AVSpeechSynthesisVoice(identifier: id) != nil { return id }
        lock.lock(); defer { lock.unlock() }
        if let known = chosen[language] { return known }
        let pick = best(for: language)?.identifier
        chosen[language] = pick
        if pick == nil { Log.info("speech: no voice installed for \(language); reading it with the current voice") }
        return pick
    }

    /// Languages not written in the Latin alphabet: for these, text in another script is the sign of another language.
    static let nonLatin: Set<String> = ["ar", "fa", "ur", "he", "yi", "ru", "uk", "be", "bg", "sr", "mk", "kk", "el", "zh", "ja", "ko",
                                        "hi", "mr", "ne", "bn", "pa", "gu", "ta", "te", "kn", "ml", "si", "th", "lo", "km", "my", "ka", "hy", "am"]

    /// The language of unmarked text, when its letters are mostly in another script than the main voice's language
    /// (an Arabic paragraph under an English voice, English under an Arabic voice). Same-script languages (French in
    /// an English page) are left to the page's own marking: guessing those misfires on names and short phrases.
    public static func detectUnmarked(_ text: String) -> String? {
        guard config.speech.autoLanguageSwitching, let main = AVSpeechSynthesisVoice(identifier: config.speech.voice)?.language else { return nil }
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let latin = letters.filter { $0.value <= 0x024F || (0x1E00...0x1EFF).contains($0.value) }.count
        let mainIsLatin = !nonLatin.contains(base(main))
        // A letter or two (moving by character, a short word): too little to recognise, so its script decides. One
        // Arabic letter went to the English voice, which named it ("Arabic letter alef": a tester, 13 Oct 2026, in
        // screen recognition; the same anywhere a character is read).
        if letters.count < 4 {
            guard !letters.isEmpty, mainIsLatin, latin == 0, let script = forCharacter(text, marked: nil), base(script) != base(main) else { return nil }
            return script
        }
        let otherScript = mainIsLatin ? letters.count - latin : latin
        guard Double(otherScript) / Double(letters.count) > 0.5 else { return nil }
        let r = NLLanguageRecognizer()
        r.processString(text)
        guard let (lang, p) = r.languageHypotheses(withMaximum: 1).first, p > 0.6, base(lang.rawValue) != base(main) else { return nil }
        return lang.rawValue
    }

    /// Speech made of parts joined by commas ("row 2, column 3, <Arabic text>"): each part's language (nil for the
    /// main voice's), neighbours in the same language joined again.
    public static func splitByLanguage(_ text: String) -> [(text: String, language: String?)] {
        var out: [(text: String, language: String?)] = []
        for part in text.components(separatedBy: ", ") {
            let lang = detectUnmarked(part)
            if let last = out.last, last.language == lang { out[out.count - 1].text += ", " + part }
            else { out.append((part, lang)) }
        }
        return out
    }

    /// The language a single character belongs to by its script, for a letter not in the main voice's script: an
    /// Arabic letter read by character under an English voice was silence, as Eloquence English has no sound for it
    /// (a tester, 8 Oct 2026). Latin-script letters answer nil (the main voice, or the text's own marking).
    public static func forCharacter(_ text: String, marked: String?) -> String? {
        guard config.speech.autoLanguageSwitching, let c = text.unicodeScalars.first(where: { CharacterSet.letters.contains($0) }) else { return nil }
        let v = c.value
        let script: String?
        switch v {
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: script = "ar"
        case 0x0590...0x05FF: script = "he"
        case 0x0400...0x04FF: script = "ru"
        case 0x0370...0x03FF: script = "el"
        case 0x0530...0x058F: script = "hy"
        case 0x10A0...0x10FF: script = "ka"
        case 0x0900...0x097F: script = "hi"
        case 0x0980...0x09FF: script = "bn"
        case 0x0A00...0x0A7F: script = "pa"
        case 0x0A80...0x0AFF: script = "gu"
        case 0x0B80...0x0BFF: script = "ta"
        case 0x0C00...0x0C7F: script = "te"
        case 0x0C80...0x0CFF: script = "kn"
        case 0x0D00...0x0D7F: script = "ml"
        case 0x0E00...0x0E7F: script = "th"
        case 0x1100...0x11FF, 0xAC00...0xD7AF: script = "ko"
        case 0x3040...0x30FF: script = "ja"
        case 0x4E00...0x9FFF: script = "zh"
        default: script = nil
        }
        guard let script else { return nil }
        // The text's own marking wins when it names a language of that script (Persian or Urdu over "ar").
        if let marked, nonLatin.contains(base(marked)) { return marked }
        guard let main = AVSpeechSynthesisVoice(identifier: config.speech.voice)?.language, base(main) != script else { return nil }
        // An ideograph is Chinese, Japanese or Korean alike: a reader whose voice is one of those keeps their voice.
        if script == "zh", ["zh", "ja", "ko"].contains(base(main)) { return nil }
        return script
    }

    /// Whether a language label cannot fit the text: a Latin-alphabet language on text mostly in another script, or
    /// the other way round.
    public static func contradicts(_ language: String, _ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 4 else { return false }
        let latin = letters.filter { $0.value <= 0x024F || (0x1E00...0x1EFF).contains($0.value) }.count
        let mostlyLatin = Double(latin) / Double(letters.count) > 0.5
        return nonLatin.contains(base(language)) == mostlyLatin
    }

    /// The rate set for a language, if one is (Preferences, Speech, Languages, the language, Rate).
    public static func rate(for language: String?) -> Float? {
        guard let language else { return nil }
        return config.speech.languageRates[base(language)]
    }

    /// Settings changed (a voice chosen, voices installed): look again.
    public static func forget() { lock.lock(); chosen.removeAll(); lock.unlock() }

    /// The installed voices for a language, the likeliest first: the same region, then Eloquence (the voice family
    /// screen reader users know), then the highest quality; novelty voices last.
    /// `from`: the system's voices, asked for once by a caller that needs several languages (the Settings window's
    /// list asked once per language, 25 Oct 2026).
    public static func voices(for language: String, from all: [AVSpeechSynthesisVoice]? = nil) -> [AVSpeechSynthesisVoice] {
        let wanted = base(language), region = language.lowercased().replacingOccurrences(of: "_", with: "-")
        return (all ?? AVSpeechSynthesisVoice.speechVoices()).filter { base($0.language) == wanted }.sorted { a, b in
            func score(_ v: AVSpeechSynthesisVoice) -> Int {
                var s = 0
                if v.language.lowercased() == region { s += 100 }
                if v.identifier.contains("eloquence") { s += 50 }
                switch v.quality { case .premium: s += 30; case .enhanced: s += 20; default: break }
                if v.voiceTraits.contains(.isNoveltyVoice) { s -= 200 }
                return s
            }
            let sa = score(a), sb = score(b)
            return sa != sb ? sa > sb : a.name < b.name
        }
    }

    static func best(for language: String) -> AVSpeechSynthesisVoice? { voices(for: language).first }

    /// Every language with an installed voice, other than the current voice's, as (code, name in English), by name.
    public static func otherLanguages(from all: [AVSpeechSynthesisVoice]? = nil) -> [(code: String, name: String)] {
        let current = AVSpeechSynthesisVoice(identifier: config.speech.voice).map { base($0.language) }
        var seen = Set<String>()
        var out: [(String, String)] = []
        for v in all ?? AVSpeechSynthesisVoice.speechVoices() {
            let b = base(v.language)
            guard b != current, seen.insert(b).inserted else { continue }
            out.append((b, Locale(identifier: "en").localizedString(forLanguageCode: b) ?? b))
        }
        return out.sorted { $0.1 < $1.1 }
    }
}
