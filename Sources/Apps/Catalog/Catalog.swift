// SPDX-License-Identifier: GPL-3.0-or-later
// The catalog results (docs/FLAT-VIEW-PLAN.md, 27 Oct 2026): a search in one of Apple's store apps answered from
// Apple's public catalog rather than from the app's results page. The App Store's results page names recycled cells
// after a scroll on macOS 27.2 and so cannot be clicked on reliably; Music, Podcasts and TV got the same route the
// next night (28 Oct 2026) because it is one plain list for all of them. The term the person typed goes to the
// catalog's search service (it goes to Apple through the app either way), the answers are a plain list spoken by
// name, and Return opens the page by its link through the app's own URL scheme, which each app follows from any
// page (measured: macappstore://, music://, podcasts://). On for everyone from build 23 (Oliver, 2 Nov 2026), after a
// week behind the developer switch `flatView`.
import Foundation
import AppKit

@MainActor final class Catalog {
    enum Kind { case apps, music, podcasts, tv }

    struct Entry {
        let name: String
        let label: String
        let url: URL
    }

    nonisolated struct Failure: Error { let why: String }

    let kind: Kind
    let term: String
    private(set) var entries: [Entry] = []
    private(set) var index = 0
    private(set) var ready = false
    private(set) var failed: String?
    private var tasks: [URLSessionDataTask] = []
    /// Opens an entry's page (the app follows its URL scheme and waits for the page).
    private let open: (Entry) -> Void
    /// The catalog could not answer: the app's own page is read instead.
    private let fallBack: (String) -> Void

    init(kind: Kind, term: String, open: @escaping (Entry) -> Void, fallBack: @escaping (String) -> Void) {
        self.kind = kind; self.term = term; self.open = open; self.fallBack = fallBack
    }

    static func kind(for bundle: String?) -> Kind? {
        switch bundle {
        case "com.apple.AppStore": return .apps
        case "com.apple.Music": return .music
        case "com.apple.podcasts": return .podcasts
        // TV is left out: Apple TV+ shows are not in the public catalog (a search for "severance" found nothing,
        // 28 Oct 2026), and the app's own results page reads well enough.
        default: return nil
        }
    }

    /// Where the store is: the Apple Account's storefront is not readable here, so the system region stands in. A Mac
    /// set to one region with an Apple Account in another hears the other store's apps and prices (a known limit).
    static var country: String { (Locale.current.region?.identifier ?? "us").lowercased() }

    /// The queries for a kind, in the order their answers are listed: (media, entity, limit).
    private var queries: [(media: String, entity: String, limit: Int)] {
        switch kind {
        case .apps: return [("software", "macSoftware", 50)]
        case .music: return [("music", "musicArtist", 3), ("music", "album", 12), ("music", "song", 30)]
        case .podcasts: return [("podcast", "podcast", 40)]
        case .tv: return [("tvShow", "tvSeason", 30)]
        }
    }

    private var what: String {
        switch kind { case .apps: return "apps"; case .music: return "music"; case .podcasts: return "podcasts"; case .tv: return "TV" }
    }

    func search() {
        let start = Date()
        let qs = queries
        var answers: [Result<[Entry], Failure>?] = Array(repeating: nil, count: qs.count)
        let lock = NSLock()
        for (i, q) in qs.enumerated() {
            var c = URLComponents(string: "https://itunes.apple.com/search")!
            c.queryItems = [.init(name: "term", value: term), .init(name: "country", value: Self.country),
                            .init(name: "media", value: q.media), .init(name: "entity", value: q.entity), .init(name: "limit", value: "\(q.limit)")]
            guard let url = c.url else { continue }
            let kind = self.kind
            // Eight seconds, not the system's sixty: while the catalog is asked the results page stands down, so a
            // stalled network left the App Store silent for a minute (a review, 2 Nov 2026; answers took 0.1 to 2.5 s).
            let task = URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 8)) { [weak self] data, response, error in
                let parsed: Result<[Entry], Failure>
                if let error { parsed = .failure(Failure(why: (error as NSError).code == NSURLErrorCancelled ? "cancelled" : error.localizedDescription)) }
                else if let http = response as? HTTPURLResponse, http.statusCode != 200 { parsed = .failure(Failure(why: String(localized: "the catalog answered \(String(http.statusCode))", comment: "Why the catalog gave no results: %@ is an HTTP status"))) }
                else if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = json["results"] as? [[String: Any]] {
                    parsed = .success(rows.compactMap { Self.entry(kind, $0) })
                } else { parsed = .failure(Failure(why: String(localized: "the catalog's answer could not be read", comment: "Why the catalog gave no results"))) }
                lock.lock(); answers[i] = parsed; let done = answers.allSatisfy { $0 != nil }; let all = answers; lock.unlock()
                guard done else { return }
                // Every query answered: the lists in order; a failure counts only when nothing answered.
                var list: [Entry] = []; var why: String?
                for a in all { switch a! { case .success(let l): list += l; case .failure(let f): why = f.why } }
                let result: Result<[Entry], Failure> = list.isEmpty && why != nil ? .failure(Failure(why: why!)) : .success(list)
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.answered(result, ms: ms) } }
            }
            tasks.append(task)
            task.resume()
        }
    }

    /// One answer as an entry: its name, what is said, and the link the app follows.
    nonisolated private static func entry(_ kind: Kind, _ r: [String: Any]) -> Entry? {
        let by = r["artistName"] as? String ?? ""
        // In TurnOver's own language, numbers in words too: English labels were spoken inside Turkish speech (a review,
        // 2 Nov 2026).
        func stars(_ r: Double) -> String {
            let whole = min(5, max(0, Int(r))); let frac = r - Double(whole)
            let f = NumberFormatter(); f.numberStyle = .spellOut; f.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
            let word = f.string(from: NSNumber(value: whole)) ?? String(whole)
            if frac >= 0.75 { return String(localized: "\(word) and three quarter stars", comment: "An app's rating in the catalog: %@ is the whole number of stars, in words") }
            if frac >= 0.5 { return String(localized: "\(word) and a half stars", comment: "An app's rating in the catalog: %@ is the whole number of stars, in words") }
            if frac >= 0.25 { return String(localized: "\(word) and a quarter stars", comment: "An app's rating in the catalog: %@ is the whole number of stars, in words") }
            return whole == 1 ? String(localized: "one star", comment: "An app's rating in the catalog") : String(localized: "\(word) stars", comment: "An app's rating in the catalog: %@ is the number of stars, in words")
        }
        func link(_ keys: [String], scheme: String) -> URL? {
            for k in keys {
                if let s = r[k] as? String, let u = URL(string: s), var c = URLComponents(url: u, resolvingAgainstBaseURL: false) {
                    c.scheme = scheme; c.queryItems = nil
                    return c.url
                }
            }
            return nil
        }
        switch kind {
        case .apps:
            guard let id = r["trackId"] as? Int, let name = r["trackName"] as? String, let url = URL(string: "macappstore://apps.apple.com/app/id\(id)") else { return nil }
            var parts = [name, by]
            let price = r["formattedPrice"] as? String ?? ""
            parts.append(price.lowercased() == "free" ? String(localized: "free", comment: "An app's price in the catalog") : price)
            if let rating = r["averageUserRating"] as? Double, let n = r["userRatingCount"] as? Int, n > 0 {
                parts.append(String(localized: "\(stars(rating)), \(String(n)) ratings", comment: "An app's rating in the catalog: %1$@ the stars, %2$@ how many ratings"))
            }
            let devices = r["supportedDevices"] as? [String] ?? []
            if !(r["kind"] as? String == "mac-software" || devices.contains { $0.hasPrefix("MacDesktop") }) {
                parts.append(String(localized: "iPhone or iPad app", comment: "An app in the catalog made for iPhone or iPad"))
            }
            return Entry(name: name, label: parts.joined(separator: ", "), url: url)
        case .music:
            switch r["wrapperType"] as? String {
            case "artist":
                guard let name = r["artistName"] as? String, let url = link(["artistLinkUrl"], scheme: "music") else { return nil }
                return Entry(name: name, label: [name, String(localized: "artist", comment: "A kind of result in Music's catalog")].joined(separator: ", "), url: url)
            case "collection":
                guard let name = r["collectionName"] as? String, let url = link(["collectionViewUrl"], scheme: "music") else { return nil }
                let year = (r["releaseDate"] as? String ?? "").prefix(4)
                let album = String(localized: "album by \(by)", comment: "A Music catalog result: %@ is the artist")
                return Entry(name: name, label: ([name, album] + (year.isEmpty ? [] : [String(year)])).joined(separator: ", "), url: url)
            default:
                guard let name = r["trackName"] as? String, let url = link(["trackViewUrl"], scheme: "music") else { return nil }
                let album = r["collectionName"] as? String ?? ""
                let song = String(localized: "song by \(by)", comment: "A Music catalog result: %@ is the artist")
                let on = album.isEmpty ? [] : [String(localized: "on \(album)", comment: "A Music catalog song: %@ is its album")]
                return Entry(name: name, label: ([name, song] + on).joined(separator: ", "), url: url)
            }
        case .podcasts:
            guard let name = r["collectionName"] as? String ?? r["trackName"] as? String, let url = link(["collectionViewUrl", "trackViewUrl"], scheme: "podcasts") else { return nil }
            let genre = r["primaryGenreName"] as? String ?? ""
            let host = String(localized: "by \(by)", comment: "A Podcasts catalog result: %@ is who makes the show")
            return Entry(name: name, label: ([name, host] + (genre.isEmpty ? [] : [genre])).joined(separator: ", "), url: url)
        case .tv:
            guard let name = r["collectionName"] as? String ?? r["trackName"] as? String, let url = link(["collectionViewUrl", "trackViewUrl"], scheme: "itms") else { return nil }
            let price = r["collectionPrice"].map { "\($0)" } ?? ""
            return Entry(name: name, label: "\(name), \(by)\(price.isEmpty ? "" : ", \(price)")", url: url)
        }
    }

    private func answered(_ result: Result<[Entry], Failure>, ms: Int) {
        switch result {
        case .failure(let f):
            let why = f.why
            guard why != "cancelled" else { return }
            failed = why
            Log.io("catalog (\(what)): \"\(Log.words(term))\" failed in \(ms) ms: \(why)")
            fallBack(why)
        case .success(let list):
            entries = list; ready = true; index = 0
            Log.io("catalog (\(what)): \"\(Log.words(term))\": \(list.count) results in \(ms) ms (\(Self.country))")
            if list.isEmpty { Speech.speakMessage(String(localized: "No catalog results for \(term); reading the page.", comment: "Spoken message")); fallBack("nothing found"); return }
            Speech.speakMessage(String(localized: "\(String(list.count)) catalog results for \(term)", comment: "Spoken message"))
            speak(0)
            Hints.schedule("Up and Down move through the catalog's results; Return opens one. Command F searches again.")
        }
    }

    func cancel() { tasks.forEach { $0.cancel() }; tasks = [] }

    private func speak(_ i: Int) {
        guard entries.indices.contains(i) else { return }
        Speech.speakItem(entries[i].label)
    }

    func move(_ d: Int) {
        guard ready else { Speech.speakMessage(failed == nil ? String(localized: "asking the catalog; a moment", comment: "Spoken message") : String(localized: "the catalog did not answer", comment: "Spoken message")); return }
        let j = index + d
        guard entries.indices.contains(j) else { Tones.edge(); speak(index); return }
        index = j; speak(j)
    }
    func toEnd(_ last: Bool) {
        guard ready, !entries.isEmpty else { return }
        index = last ? entries.count - 1 : 0; speak(index)
    }
    func letter(_ ch: Character) {
        guard ready, !entries.isEmpty else { return }
        for k in 1...entries.count {
            let j = (index + k) % entries.count
            if entries[j].name.lowercased().first == ch { index = j; speak(j); return }
        }
        Tones.edge()
    }
    func openCurrent() {
        guard ready, entries.indices.contains(index) else { Speech.speakMessage(String(localized: "nothing to open yet", comment: "Spoken message")); return }
        open(entries[index])
    }
}
