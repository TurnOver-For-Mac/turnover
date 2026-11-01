// SPDX-License-Identifier: GPL-3.0-or-later
// New to try (6 Oct 2026): testers should know what a build brings for them to try (Screen Curtain, braille,
// a new app), apart from the fixes. Each build's "### New to try" list in CHANGELOG.md is bundled in the app
// (new-to-try.json, by build.sh). The first time TurnOver leads after an update, it says how many things are new,
// once; the TurnOver menu lists them under New to try, each read in full as you arrow to it.
import Foundation

public enum NewToTry {
    struct Build: Decodable { let build: Int; let items: [String]; let tests: [String]? }

    private static let all: [Build] = {
        guard let url = Bundle.main.url(forResource: "new-to-try", withExtension: "json"),
              let d = try? Data(contentsOf: url), let b = try? JSONDecoder().decode([Build].self, from: d) else { return [] }
        return b.sorted { $0.build > $1.build }
    }()

    /// The build running (a developer's Mac can pretend: `defaults write com.turnover.reader pretendBuild -int 17`).
    static var currentBuild: Int {
        let pretend = UserDefaults.standard.integer(forKey: "pretendBuild")
        // A point build ("20.1") counts as its whole build: Int("20.1") was nil, so a point build had no pages at all.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return pretend > 0 ? pretend : Int(version.split(separator: ".").first ?? "") ?? 0
    }
    private static let seenKey = "newToTrySeenBuild"
    /// Set at launch, before the welcome: TurnOver had been used before this launch. An update from a build without
    /// this list (build 7) has no record of what was seen; it is an update, not a first install.
    private static var usedBefore = false
    public static func noteLaunch() {
        // Welcomed by this version or by 1.0 (2.0's welcome shows again, but an update from 1.0 is still an update).
        usedBefore = UserDefaults.standard.bool(forKey: "welcomed-\(Edition.version)") || UserDefaults.standard.bool(forKey: "welcomed-1.0")
    }

    /// The newest build up to this one that has anything to try.
    public static var latest: (build: Int, items: [String])? {
        all.first { $0.build <= currentBuild }.map { ($0.build, $0.items) }
    }
    static var latestTests: [String] { all.first { $0.build <= currentBuild }?.tests ?? [] }

    /// The welcome pages for this build (12 Oct 2026: after each update, what's new and what to test, in
    /// pages with Next, Back and Skip). Each item's first sentence is its heading.
    public static func buildPages() -> [(String, String)] {
        guard let l = latest else { return [] }
        var pages: [(String, String)] = l.items.map(heading)
        let tests = latestTests
        if !tests.isEmpty { pages.append((whatToTest, tests.map { "• " + $0 }.joined(separator: "\n"))) }
        return pages
    }
    /// The page of things to test, by its title.
    static var whatToTest: String { String(localized: "What to test", comment: "A welcome page's title after an update") }

    /// An item's heading and the rest. Its first sentence when that is short; else what comes before its first colon,
    /// bracket or comma; else its first words. Items longer than a short sentence all came out as "New in build 20",
    /// twenty times over on build 20's welcome (19 Oct 2026).
    public static func heading(_ item: String) -> (String, String) {
        if let r = item.range(of: ". "), item.distance(from: item.startIndex, to: r.lowerBound) <= 60 {
            return (String(item[..<r.lowerBound]), String(item[r.upperBound...]))
        }
        if item.count <= 70 { return (item.hasSuffix(".") ? String(item.dropLast()) : item, item) }
        let cuts = [": ", " (", ", "].compactMap { item.range(of: $0)?.lowerBound }
            .filter { (3...60).contains(item.distance(from: item.startIndex, to: $0)) }
        if let cut = cuts.min() { return (String(item[..<cut]), item) }
        let words = item.split(separator: " ")
        return (words.prefix(6).joined(separator: " ").trimmingCharacters(in: .punctuationCharacters) + (words.count > 6 ? "…" : ""), item)
    }

    /// The welcome's short form (12 Oct 2026: "19 pages is a bit much"): one page naming what's new, one
    /// with what to test. The details stay in the menu, What to test in build N.
    public static func summaryPages() -> [(String, String)] {
        guard let l = latest else { return [] }
        let headings = buildPages().filter { $0.0 != whatToTest }.map { $0.0 }
        let build = String(describing: l.build)
        var pages = [(String(localized: "New in build \(build)", comment: "A welcome page's title after an update: the build"),
                      headings.joined(separator: ". ") + ".\n\n" + String(localized: "Each is explained in the TurnOver menu, What to test in build \(build).", comment: "A welcome page after an update: the build"))]
        let tests = latestTests
        if !tests.isEmpty { pages.append((whatToTest, tests.map { "• " + $0 }.joined(separator: "\n"))) }
        return pages
    }

    /// An update not yet welcomed: the pages are due (a first install has its own welcome).
    public static var pagesDue: Bool {
        let seen = UserDefaults.standard.object(forKey: seenKey) as? Int
        return usedBefore && currentBuild > (seen ?? currentBuild - 1) && latest?.build ?? 0 > (seen ?? 0)
    }

    /// The welcome has shown this build's pages: nothing more is announced for it.
    public static func markSeen() { UserDefaults.standard.set(currentBuild, forKey: seenKey) }


    /// Once, the first time TurnOver leads after an update: how much is new since the build last seen. A first
    /// install says nothing (the welcome does the talking) and starts counting from here.
    public static func announceIfUpdated() {
        let d = UserDefaults.standard
        let current = currentBuild
        guard current > 0 else { return }
        if d.object(forKey: seenKey) == nil {
            guard usedBefore else { d.set(current, forKey: seenKey); return }   // a first install: the welcome talks
            d.set(current - 1, forKey: seenKey)
        }
        let seen = d.integer(forKey: seenKey)
        guard current > seen else { return }
        d.set(current, forKey: seenKey)
        let count = all.filter { $0.build > seen && $0.build <= current }.reduce(0) { $0 + $1.items.count }
        guard count > 0 else { return }
        Log.info("new to try: build \(current), \(count) new since build \(seen)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            let build = String(describing: current)
            Speech.speakMessage(count == 1 ? String(localized: "TurnOver has been updated to build \(build), with 1 new thing to try: TurnOver menu, New in build \(build).", comment: "After an update: the build")
                : String(localized: "TurnOver has been updated to build \(build), with \(String(count)) new things to try: TurnOver menu, New in build \(build).", comment: "After an update: the build and how many new things"))
        }
    }

    /// For the TurnOver menu: each thing to try by its first sentence; Right opens it, one sentence a line, to arrow
    /// through (a tester, : screen recognition's keys were one long item, hard to keep in mind).
    public static func menuItems() -> [MenuItem] {
        guard let l = latest else { return [] }
        var out: [MenuItem] = []
        // The welcome's pages, read here as a list (TurnOver reads its menu itself; an alert of its own would be silent).
        out.append(MenuItem("The welcome pages", .submenu { buildPages().map { page in
            MenuItem(verbatim: page.0, .submenu { sentences(page.1.replacingOccurrences(of: "\n• ", with: ". ").replacingOccurrences(of: "• ", with: "")).map { s in MenuItem(verbatim: s, .action { Speech.speakMessage(s) }) } })
        } }))
        let tests = latestTests
        if !tests.isEmpty { out.append(MenuItem("What to test", .submenu { tests.map { t in MenuItem(verbatim: t, .action { Speech.speakMessage(t) }) } })) }
        return out + l.items.map { text in
            let lines = sentences(text)
            guard lines.count > 1 else { return MenuItem(verbatim: text, .action { Speech.speakMessage(text) }) }
            return MenuItem(verbatim: lines[0], .submenu { lines.map { line in MenuItem(verbatim: line, .action { Speech.speakMessage(line) }) } })
        }
    }

    /// A paragraph as its sentences and its "; "-separated parts, each read on its own.
    public static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            cur.append(ch)
            let next = i + 1 < chars.count ? chars[i + 1] : " "
            let after = i + 2 < chars.count ? chars[i + 2] : " "
            // A full stop, question mark or semicolon followed by a space and a capital or digit ends a line;
            // "e.g. this" and "2.76 GB" do not.
            if ".?!;".contains(ch), next == " ", after.isUppercase || after.isNumber || ch == ";" {
                let t = cur.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ";")))
                if !t.isEmpty { out.append(t) }
                cur = ""
            }
        }
        let t = cur.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { out.append(t) }
        return out
    }
}
