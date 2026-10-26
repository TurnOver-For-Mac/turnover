// SPDX-License-Identifier: GPL-3.0-or-later
// A report for the developers (beta feedback). TurnOver's logs record everything it says (the text of
// emails and web pages) and every key; a report leaves that out unless the tester chooses to include
// it. The report is a zip in TurnOver's reports folder; TurnOver then opens a new email to the developers with it attached,
// for the tester to write in and send (TurnOver never sends anything itself).
import Foundation
import AppKit

public enum Feedback {
    // MARK: Marked moments ("that was wrong", 6 Oct 2026)
    //
    // One key press when something goes wrong: the moment is marked in the log (when, and in which application; not
    // what was on screen), and the marks wait. Send feedback then sends them all in one report, so a tester never
    // has to stop and write an email in the middle of what they were doing.

    public struct Mark: Codable { public let time: Date; public let app: String }
    private static var marksFile: URL { AppPaths.file("marked moments.json") }

    public static var marks: [Mark] {
        guard let d = try? Data(contentsOf: marksFile), let m = try? JSONDecoder().decode([Mark].self, from: d) else { return [] }
        return m
    }

    /// Mark now. Returns how many marks are waiting.
    @discardableResult
    public static func mark() -> Int {
        let app = API.focusPid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName } ?? NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        var all = marks
        all.append(Mark(time: Date(), app: app))
        if let d = try? JSONEncoder().encode(all) { try? d.write(to: marksFile) }
        // The line a developer looks for. The focus's kind only, never its text.
        Log.info("MARK \(all.count): the tester marked a problem here, in \(app) (focus \(API.focusObject?.axRole ?? "none"))")
        return all.count
    }

    public static func clearMarks() { try? FileManager.default.removeItem(at: marksFile) }

    static func describe(_ marks: [Mark]) -> String {
        let f = DateFormatter(); f.dateFormat = "d MMM, HH:mm"
        return marks.enumerated().map { "\($0.offset + 1). \(f.string(from: $0.element.time)), in \($0.element.app)" }.joined(separator: "\n")
    }

    /// Save a report; returns the zip.
    public static func save(includeSpeech: Bool) throws -> URL {
        let fm = FileManager.default
        let stamp: String = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmm"; return f.string(from: Date()) }()
        let name = "TurnOver \(Edition.fullName.dropFirst("TurnOver ".count)) feedback, \(stamp)"
        let work = fm.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        // The newest three logs, made private unless the tester said otherwise.
        let logs = AppPaths.file("logs")
        let newest = ((try? fm.contentsOfDirectory(at: logs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("turnover-") || $0.lastPathComponent.hasPrefix("turnover-") }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        // The newest three, and any older ones back to the first marked moment (at most eight).
        let earliest = marks.map(\.time).min()
        let wanted = newest.enumerated().filter { i, url in
            i < 3 || earliest.map { e in ((try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >= e } ?? false
        }.map(\.element).prefix(8)
        for log in wanted {
            guard let text = try? String(contentsOf: log, encoding: .utf8) else { continue }
            let out = includeSpeech ? text : redact(text)
            try out.write(to: work.appendingPathComponent(log.lastPathComponent), atomically: true, encoding: .utf8)
        }
        // The TurnOver Key helper's own log (when it restarted TurnOver after a crash): nothing private in it.
        let keyLog = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/TurnOver Key.log")
        // What TurnOver said, from memory: the log on disk keeps only lengths (code review, 14 Oct 2026).
        if includeSpeech {
            // Not the whole day (up to 3,000 utterances of mail and messages: code review, 16 Oct 2026): the 15 minutes
            // before now, and 5 minutes either side of each marked moment.
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            let now = Date()
            let windows: [(Date, Date)] = [(now.addingTimeInterval(-15 * 60), now)] + marks.map { ($0.time.addingTimeInterval(-5 * 60), $0.time.addingTimeInterval(5 * 60)) }
            let kept = Speech.history.value.filter { e in windows.contains { e.at >= $0.0 && e.at <= $0.1 } }
            let said = "What TurnOver said in the 15 minutes before the report, and 5 minutes around each marked moment.\n" + kept.map { "\(f.string(from: $0.at))  \($0.text)" }.joined(separator: "\n")
            try? said.write(to: work.appendingPathComponent("what TurnOver said.txt"), atomically: true, encoding: .utf8)
        }
        try? fm.copyItem(at: keyLog, to: work.appendingPathComponent("turnover-key.log"))
        // Settings and the system, which say how TurnOver was set up.
        // Settings, without the list of the person's apps and their own keys (which name what they do with the
        // Mac; the report is about how TurnOver was set up, not what for).
        let settings = AppPaths.file("settings.json")
        if let data = try? Data(contentsOf: settings), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let out = try? JSONSerialization.data(withJSONObject: settingsForReport(object), options: [.prettyPrinted, .sortedKeys]) { try? out.write(to: work.appendingPathComponent("settings.json")) }
        }
        let info = """
        \(Edition.fullName)
        Mac: \(macModel)
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        VoiceOver on: \(NSWorkspace.shared.isVoiceOverEnabled)
        Keyboard style: \(config.general.keyboardStyle); TurnOver key: \(config.general.turnOverKey)
        Karabiner-Elements running: \(NSWorkspace.shared.runningApplications.contains { ($0.bundleIdentifier ?? "").contains("pqrs") })
        What TurnOver said is \(includeSpeech ? "included" : "left out").
        """
        try info.write(to: work.appendingPathComponent("about.txt"), atomically: true, encoding: .utf8)
        let waiting = marks
        if !waiting.isEmpty {
            try ("Marked moments (search the logs for MARK):\n" + describe(waiting) + "\n").write(to: work.appendingPathComponent("marked moments.txt"), atomically: true, encoding: .utf8)
        }
        try "What happened, and what you expected (write here, or in your message):\n".write(to: work.appendingPathComponent("what happened.txt"), atomically: true, encoding: .utf8)

        // In TurnOver's own folder, not on the Desktop: a synced Desktop sent every report to the cloud, and they piled
        // up (a tester, 10 Oct 2026). The newest ten are kept; the email carries the one that matters.
        let reports = AppPaths.file("reports")
        try? fm.createDirectory(at: reports, withIntermediateDirectories: true)
        let old = ((try? fm.contentsOfDirectory(at: reports, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "zip" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for f in old.dropFirst(9) { try? fm.removeItem(at: f) }
        let zip = reports.appendingPathComponent(name + ".zip")
        try? fm.removeItem(at: zip)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", work.path, zip.path]
        try p.run()
        p.waitUntilExit()
        try? fm.removeItem(at: work)
        guard p.terminationStatus == 0 else { throw NSError(domain: "TurnOver", code: 4, userInfo: [NSLocalizedDescriptionKey: "could not make the zip"]) }
        Log.info("feedback saved: \(zip.path) (speech \(includeSpeech ? "included" : "left out"))")
        return zip
    }

    /// TurnOver's problem form opens in the browser with the build, the Mac and macOS filled in; the person describes
    /// what happened and may drag the report in. Issues are public, so the report is attached by hand, never sent. A
    /// report without what TurnOver said goes on the Desktop; one with it (which may hold what was read, and the
    /// echo of typing) stays in TurnOver's reports folder, shown in Finder, off the Desktop that iCloud may sync
    /// (a code review on 20 Oct 2026). False if the form could not be opened.
    @discardableResult
    public static func compose(with zip: URL, includesSpeech: Bool) -> Bool {
        if includesSpeech {
            NSWorkspace.shared.activateFileViewerSelecting([zip])
        } else {
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].appendingPathComponent(zip.lastPathComponent)
            try? FileManager.default.removeItem(at: desktop); try? FileManager.default.copyItem(at: zip, to: desktop)
        }
        var c = URLComponents(string: Edition.issuesURL + "/new")!
        c.queryItems = [URLQueryItem(name: "template", value: "problem.yml"),
                        URLQueryItem(name: "versions", value: "\(Edition.fullName), \(macModel), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")]
        guard let url = c.url else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// The Mac's model identifier ("Mac15,12").
    static var macModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Key assignments and their undo records can name apps and script paths. Both live inside keyboard,
    /// rather than at the top level checked by older reports (keyboard editor review, 26 Oct 2026).
    public static func settingsForReport(_ settings: [String: Any]) -> [String: Any] {
        var out = settings
        out["applications"] = nil; out["userGestures"] = nil; out["keys"] = nil
        if var keyboard = out["keyboard"] as? [String: Any] {
            keyboard["userGestures"] = nil; keyboard["keyChanges"] = nil
            out["keyboard"] = keyboard
        }
        return out
    }

    /// A log with what was on screen and what was typed taken out: spoken text, quoted names, typed keys and words,
    /// and the paths and queries of web addresses. What TurnOver did (events, scripts, timings) stays.
    nonisolated public static func redact(_ log: String) -> String {
        let quoted = try! NSRegularExpression(pattern: "\"[^\"]*\"")
        let url = try! NSRegularExpression(pattern: "(https?|file|x-webdoc)://([^/\\s\"]*)[^\\s\"]*")
        let typedKey = try! NSRegularExpression(pattern: "input kb:(shift\\+)?[^+\\s]$")
        return log.split(separator: "\n", omittingEmptySubsequences: false).map { raw -> String in
            var line = String(raw).replacingOccurrences(of: NSHomeDirectory(), with: "~")
            // Lines whose remainder is what was on screen.
            for marker in ["copied the last spoken: ", "live region: ", "media: press ", "media: play ", "browse mode: press ", "dialog: pressed ",
                           "dialog: cancelled with ", "status menus: press ", "claude: ", "plugin: press ", "find next: ", "find previous: ",
                           // What the display showed, banners, page titles and spoken text in another language (8 Oct 2026).
                           "braille shows (", "braille input: ", "notification banner: ", "browse mode: page ", "Word's own formatting announcement; TurnOver says it: "] {
                if let r = line.range(of: marker) { return line[..<r.upperBound] + "[…]" }
            }
            if let r = line.range(of: " say: ") { return line[..<r.upperBound] + "[spoken, \(line[r.upperBound...].count) characters]" }
            if let r = line.range(of: " say ["), let close = line[r.upperBound...].firstIndex(of: "]") { return line[...close] + ": [spoken, \(line[close...].count) characters]" }
            if let r = line.range(of: "typed word: ") { return line[..<r.upperBound] + "[a word]" }
            if line.contains("typedCharacter") { return line.components(separatedBy: "typedCharacter").first! + "typedCharacter [a key]" }
            if typedKey.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil, let r = line.range(of: "input kb:") { return line[..<r.upperBound] + "[a key]" }
            line = url.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "$1://$2/…")
            line = quoted.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "\"…\"")
            return line
        }.joined(separator: "\n")
    }
}
