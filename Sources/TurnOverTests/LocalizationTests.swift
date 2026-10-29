// SPDX-License-Identifier: GPL-3.0-or-later
// The translations (Resources/Localizable.xcstrings, make-strings.py, 23 Oct 2026): the tests hear English on a Mac in
// any language, and no translation can break a sentence by losing or changing the English string's placeholders.
import Foundation
import TurnOverCore

func localizationTests() {
    test("localization: the tests run in English, whatever the Mac's language") {
        // The tests are a bare program with no .lproj beside them: String(localized:) gives the English in the code,
        // so their expected words hold on a Turkish Mac too. Translations live only in the app bundles (build.sh).
        expect(Bundle.main.preferredLocalizations.first, "en", "the tests' language")
        expect(String(localized: "3 of 9, a test string never translated"), "3 of 9, a test string never translated", "an untranslated string")
    }
    test("localization: letters are lowered and raised by the language's rules (Turkish I is ı, İ is i, i is İ)") {
        let tr = Locale(identifier: "tr"), en = Locale(identifier: "en")
        expect(Symbols.lowered("I", locale: tr), "ı", "Turkish I")
        expect(Symbols.lowered("İ", locale: tr), "i", "Turkish İ")
        expect(Symbols.lowered("I", locale: en), "i", "English I")
        expect(Symbols.name(of: "I", sayCap: true), "cap i", "a capital in the tests' language, English")
        // The Keyboard Commander's letters, raised: Turkish i is İ; and an App Store count, lowered: I is ı, İ is i.
        expect(Symbols.raised("i", locale: tr), "İ", "Turkish i raised")
        expect(Symbols.raised("i", locale: en), "I", "English i raised")
        expect(Symbols.lowered("1,2 B DEĞERLENDİRME", locale: tr), "1,2 b değerlendirme", "a Turkish App Store count")
        expect(Symbols.lowered("IŞIK", locale: tr), "ışık", "Turkish I in a word")
    }
    test("localization: braille short forms follow the role, the same at every launch") {
        // Turkish says "tablo" for a table and a tree view: each keeps its own short form by its role.
        expect(Braille.roleShortForms[.table], "tbl", "table")
        expect(Braille.roleShortForms[.treeView], "tv", "tree view")
        expect(Braille.brailleText(["Files", "tree view"], role: .treeView), "Files tv", "an item's own role")
        expect(Braille.brailleText(["Mail", "table"], role: .table), "Mail tbl", "an item's own role")
        // From words alone, a word two short forms share is left as said, whatever order the words come in.
        let words: [(spoken: String, short: String)] = [("tablo", "tv"), ("düğme", "btn"), ("tablo", "tbl")]
        let a = Braille.spokenShortForms(base: [:], words: words), b = Braille.spokenShortForms(base: [:], words: words.reversed())
        expect(a["tablo"], nil, "a shared word")
        expect(a["düğme"], "btn", "a word of its own")
        expect(a, b, "the same whatever the order")
    }
    test("localization: a Mail row's own unread is recognised in English and in TurnOver's language") {
        expect(MailRowWords.saysUnread("unread, Ann, Hello", word: "okunmamış"), true, "Mail in English")
        expect(MailRowWords.saysUnread("Unread, Ann", word: "okunmamış"), true, "a capital")
        expect(MailRowWords.saysUnread("okunmamış, Ayşe, Merhaba", word: "okunmamış"), true, "Mail in Turkish")
        expect(MailRowWords.saysUnread("Ann, Hello", word: "okunmamış"), false, "a read row")
        expect(MailRowWords.saysUnread("Ann, unread messages", word: "okunmamış"), false, "unread later in the words")
    }
    test("localization: every translation keeps the English string's placeholders") {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: url),
              let catalog = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = catalog["strings"] as? [String: Any] else { Harness.fail("no catalog at \(url.path)"); return }
        expect(catalog["sourceLanguage"] as? String, "en", "the catalog's source language")
        for (key, value) in strings {
            let entry = value as? [String: Any] ?? [:]
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            let english = localizations["en"].map(stringUnits) ?? []
            let wanted = placeholders(english.first ?? key)
            for (language, localization) in localizations where language != "en" {
                for text in stringUnits(localization) where !text.isEmpty {   // empty: the words deliberately left unsaid
                    check(placeholders(text) == wanted, "\(language) \"\(text)\" for \"\(key)\" has placeholders \(placeholders(text)), English \(wanted)")
                }
            }
        }
    }
}

/// Every string a localization holds, plural and device variations included.
private func stringUnits(_ node: Any) -> [String] {
    guard let d = node as? [String: Any] else { return [] }
    var out: [String] = []
    if let unit = d["stringUnit"] as? [String: Any], let v = unit["value"] as? String { out.append(v) }
    for (k, v) in d where k != "stringUnit" { out += stringUnits(v) }
    return out
}

/// A string's placeholders by position ("%2$@ zemin" → [2: "@"]), so a translation may reorder but not change them.
private func placeholders(_ s: String) -> [Int: String] {
    let pattern = /%(?:(\d+)\$)?[-+ 0#']*\d*(?:\.\d+)?(hh|h|ll|l|q|z|t|j)?([@dDuUxXoOfFeEgGcCsSpaA%])/
    var out: [Int: String] = [:]
    var next = 1
    for m in s.matches(of: pattern) where m.output.3 != "%" {
        let position = m.output.1.flatMap { Int($0) } ?? next
        next = position + 1
        out[position] = String(m.output.2 ?? "") + String(m.output.3)
    }
    return out
}
