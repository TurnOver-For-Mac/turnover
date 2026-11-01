// SPDX-License-Identifier: GPL-3.0-or-later
// The catalog results (docs/FLAT-VIEW-PLAN.md, 27 Oct 2026): a search in one of Apple's store apps answered from
// Apple's public catalog rather than from the app's results page. The App Store's results page names recycled cells
// after a scroll on macOS 27.2 and so cannot be clicked on reliably; Music, Podcasts and TV got the same route the
// next night (28 Oct 2026) because it is one plain list for all of them. The term the person typed goes to the
// catalog's search service (it goes to Apple through the app either way), the answers are a plain list spoken by
// name, and Return opens the page by its link through the app's own URL scheme, which each app follows from any
// page (measured: macappstore://, music://, podcasts://). Behind the developer switch `flatView`.
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

    /// Where the store is: the Apple Account's storefront is not readable here, so the system region stands in.
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
            let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
                let parsed: Result<[Entry], Failure>
                if let error { parsed = .failure(Failure(why: (error as NSError).code == NSURLErrorCancelled ? "cancelled" : error.localizedDescription)) }
                else if let http = response as? HTTPURLResponse, http.statusCode != 200 { parsed = .failure(Failure(why: "the catalog answered \(http.statusCode)")) }
                else if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = json["results"] as? [[String: Any]] {
                    parsed = .success(rows.compactMap { Self.entry(kind, $0) })
                } else { parsed = .failure(Failure(why: "the catalog's answer could not be read")) }
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
        func stars(_ r: Double) -> String {
            let whole = Int(r); let frac = r - Double(whole)
            let word = ["zero", "one", "two", "three", "four", "five"][min(5, max(0, whole))]
            if frac >= 0.75 { return "\(word) and three quarter stars" }
            if frac >= 0.5 { return "\(word) and a half stars" }
            if frac >= 0.25 { return "\(word) and a quarter stars" }
            return whole == 1 ? "one star" : "\(word) stars"
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
            parts.append(price.lowercased() == "free" ? "free" : price)
            if let rating = r["averageUserRating"] as? Double, let n = r["userRatingCount"] as? Int, n > 0 { parts.append("\(stars(rating)), \(n) ratings") }
            let devices = r["supportedDevices"] as? [String] ?? []
            if !(r["kind"] as? String == "mac-software" || devices.contains { $0.hasPrefix("MacDesktop") }) { parts.append("iPhone or iPad app") }
            return Entry(name: name, label: parts.joined(separator: ", "), url: url)
        case .music:
            switch r["wrapperType"] as? String {
            case "artist":
                guard let name = r["artistName"] as? String, let url = link(["artistLinkUrl"], scheme: "music") else { return nil }
                return Entry(name: name, label: "\(name), artist", url: url)
            case "collection":
                guard let name = r["collectionName"] as? String, let url = link(["collectionViewUrl"], scheme: "music") else { return nil }
                let year = (r["releaseDate"] as? String ?? "").prefix(4)
                return Entry(name: name, label: "\(name), album by \(by)\(year.isEmpty ? "" : ", \(year)")", url: url)
            default:
                guard let name = r["trackName"] as? String, let url = link(["trackViewUrl"], scheme: "music") else { return nil }
                let album = r["collectionName"] as? String ?? ""
                return Entry(name: name, label: "\(name), song by \(by)\(album.isEmpty ? "" : ", on \(album)")", url: url)
            }
        case .podcasts:
            guard let name = r["collectionName"] as? String ?? r["trackName"] as? String, let url = link(["collectionViewUrl", "trackViewUrl"], scheme: "podcasts") else { return nil }
            let genre = r["primaryGenreName"] as? String ?? ""
            return Entry(name: name, label: "\(name), by \(by)\(genre.isEmpty ? "" : ", \(genre)")", url: url)
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
            if list.isEmpty { Speech.speakMessage("No catalog results for \(term); reading the page."); fallBack("nothing found"); return }
            Speech.speakMessage("\(list.count) catalog results for \(term)")
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
        guard ready else { Speech.speakMessage(failed == nil ? "asking the catalog; a moment" : "the catalog did not answer"); return }
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
        guard ready, entries.indices.contains(index) else { Speech.speakMessage("nothing to open yet"); return }
        open(entries[index])
    }
}
