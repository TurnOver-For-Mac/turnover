// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import AppKit
import CoreServices

/// Consent survives module replacement. Worker queues and delayed main-actor reminders share this owner;
/// every transition uses storage.lock, and no lock is held while an Apple Event is in flight.
nonisolated package final class WordAutomationState: Sendable {
    package struct Request: Sendable {
        let id = UUID()
        package let isFirst: Bool
    }
    private struct State {
        var lastRefusalSpoken = Date.distantPast
        var wordAnswered = false
        var pendingQuestions: Set<UUID> = []
    }
    private let storage = Locked(State())

    package init() {}

    package func begin() -> Request {
        storage.lock.lock(); defer { storage.lock.unlock() }
        let request = Request(isFirst: !storage.unsafeValue.wordAnswered)
        if request.isFirst { storage.unsafeValue.pendingQuestions.insert(request.id) }
        return request
    }

    package func isPending(_ request: Request) -> Bool { storage.value.pendingQuestions.contains(request.id) }

    /// Whether this refusal needs an explanation. Other outstanding requests retain their own reminders.
    package func finish(_ request: Request, succeeded: Bool, refused: Bool, at now: Date = Date()) -> Bool {
        storage.lock.lock(); defer { storage.lock.unlock() }
        storage.unsafeValue.pendingQuestions.remove(request.id)
        if succeeded { storage.unsafeValue.wordAnswered = true }
        guard refused, now.timeIntervalSince(storage.unsafeValue.lastRefusalSpoken) > 30 else { return false }
        storage.unsafeValue.lastRefusalSpoken = now
        return true
    }
}

final class WordScript {
    private let queue = DispatchQueue(label: "turnover.wordscript", qos: .userInitiated)

    struct Landing { let moved: Bool; let level: Int?; let text: String }

    /// Move the selection with `go to next/previous … what <item>`, collapse it to the start, and report where it landed.
    func goTo(item: String, forward: Bool, completion: @escaping @MainActor (Landing) -> Void) {
        queue.async {
            let r = self.run("""
            tell application "Microsoft Word"
                set s to selection start of selection
                set r to \(forward ? "go to next" : "go to previous") (text object of selection) what \(item)
                select r
                set selection end of selection to selection start of selection
                set p to paragraph 1 of selection
                return (s as text) & "|" & ((selection start of selection) as text) & "|" & ((outline level of p) as text) & "|" & (content of text object of p)
            end tell
            """)
            let parts = (r ?? "").components(separatedBy: "|")
            guard parts.count >= 4 else { DispatchQueue.main.async { completion(Landing(moved: false, level: nil, text: "")) }; return }
            let landing = Landing(moved: parts[0] != parts[1], level: Int(parts[2].filter(\.isNumber)),
                                  text: parts[3...].joined(separator: "|").trimmingCharacters(in: .whitespacesAndNewlines))
            DispatchQueue.main.async { completion(landing) }
        }
    }

    /// The caret to the start of the document's nth heading (1 is the first), by stepping from the top: the rotor's
    /// choice. (Pressing the row in the sidebar failed once TurnOver had closed the sidebar again, 7 Oct 2026.)
    func goToHeading(number n: Int, completion: @escaping @MainActor (Landing) -> Void) {
        queue.async {
            let r = self.run("""
            tell application "Microsoft Word"
                set selection start of selection to 0
                set selection end of selection to 0
                set k to \(n)
                if ((outline level of paragraph 1 of selection) as text) does not contain "body" then set k to k - 1
                repeat k times
                    set r to go to next (text object of selection) what goto a heading item
                    select r
                    set selection end of selection to selection start of selection
                end repeat
                set p to paragraph 1 of selection
                return "1|1|" & ((outline level of p) as text) & "|" & (content of text object of p)
            end tell
            """)
            let parts = (r ?? "").components(separatedBy: "|")
            guard parts.count >= 4 else { DispatchQueue.main.async { completion(Landing(moved: false, level: nil, text: "")) }; return }
            let landing = Landing(moved: true, level: Int(parts[2].filter(\.isNumber)),
                                  text: parts[3...].joined(separator: "|").trimmingCharacters(in: .whitespacesAndNewlines))
            DispatchQueue.main.async { completion(landing) }
        }
    }

    func selectionInformation(_ completion: @escaping @MainActor (Int?, Int?) -> Void) {
        let menuOpen = AXHandler.shared.isMenuOpen
        queue.async { let (p, l) = self.selectionInformationSync(menuOpen: menuOpen); DispatchQueue.main.async { completion(p, l) } }
    }

    nonisolated func selectionInformationSync(menuOpen: Bool) -> (Int?, Int?) {
        if menuOpen { return (nil, nil) }   // Word does not answer Apple Events while a menu is open (measured: -1712 after 5 s)
        let page = run("tell application \"Microsoft Word\" to return get selection information selection information type (active end adjusted page number)")
        let line = run("tell application \"Microsoft Word\" to return get selection information selection information type (first character line number)")
        return (page.flatMap(Int.init), line.flatMap(Int.init))
    }

    /// The comment whose scope contains the selection, as "author: text".
    func commentAtSelection(_ completion: @escaping @MainActor (String?) -> Void) {
        queue.async {
            let r = self.run("""
            tell application "Microsoft Word"
                set s to selection start of selection
                set n to count Word comments of active document
                repeat with i from 1 to n
                    set c to Word comment i of active document
                    set sc to scope of c
                    if (start of content of sc) ≤ (s + 1) and (end of content of sc) ≥ s then
                        return (author of c) & ": " & (content of comment text of c)
                    end if
                end repeat
                return ""
            end tell
            """)
            let answer = r?.isEmpty == false ? r : nil
            DispatchQueue.main.async { completion(answer) }
        }
    }

    func nextRevision(forward: Bool, completion: @escaping @MainActor (String?) -> Void) {
        queue.async {
            let r = self.run("""
            tell application "Microsoft Word"
                try
                    set r to \(forward ? "next revision" : "previous revision") selection with wrap
                    return ((revision type of r) as text) & "|" & (author of r) & "|" & (content of text object of r)
                on error
                    return ""
                end try
            end tell
            """)
            guard let r, !r.isEmpty else { DispatchQueue.main.async { completion(nil) }; return }
            let parts = r.components(separatedBy: "|")
            let kind = parts[0].replacingOccurrences(of: "revision ", with: "")
            let author = parts.count > 1 ? parts[1] : ""
            let text = parts.count > 2 ? parts[2...].joined(separator: "|") : ""
            let answer = author.isEmpty ? "\(kind): \(text.prefix(400))" : String(localized: "\(kind) by \(author): \(String(text.prefix(400)))", comment: "A tracked change: its kind (from Word), author and text")
            DispatchQueue.main.async { completion(answer) }
        }
    }

    /// The next spelling error after the selection (searching from its END, or the same word is found again), or the previous one.
    func nextSpellingError(forward: Bool, from: Int? = nil, completion: @escaping @MainActor (String?) -> Void) {
        queue.async {
            let r = self.run("""
            tell application "Microsoft Word"
                set d to active document
                if \(forward ? "true" : "false") then
                    set rg to create range d start \(from.map(String.init) ?? "((selection end of selection) + 1)") end (end of content of text object of d)
                    if (count of spelling errors of rg) = 0 then return ""
                    set e to first spelling error of rg
                else
                    set s to selection start of selection
                    if s = 0 then return ""
                    set rg to create range d start 0 end s
                    if (count of spelling errors of rg) = 0 then return ""
                    set e to last spelling error of rg
                end if
                select e
                set selection end of selection to selection start of selection
                return content of e
            end tell
            """)
            let answer = r?.isEmpty == false ? r : nil
            DispatchQueue.main.async { completion(answer) }
        }
    }

    struct FontState { let bold: Bool; let italic: Bool; let underline: Bool; let size: Int }
    func fontState(_ report: @escaping @MainActor (FontState) -> String) {
        queue.async {
            let r = self.run("""
            tell application "Microsoft Word"
                set f to font object of selection
                return ((bold of f) as text) & "|" & ((italic of f) as text) & "|" & ((underline of f) as text) & "|" & ((font size of f) as text)
            end tell
            """)
            let p = (r ?? "").components(separatedBy: "|")
            guard p.count >= 4 else { return }
            let state = FontState(bold: p[0] == "true", italic: p[1] == "true", underline: !(p[2].contains("none") || p[2] == "false"), size: Int(Double(p[3]) ?? 0))
            DispatchQueue.main.async { Speech.speakMessage(report(state)) }
        }
    }
    func alignment() {
        queue.async {
            let r = self.run("tell application \"Microsoft Word\" to return (alignment of paragraph format of selection) as text") ?? ""
            let words = r.contains("center") ? TextFormat.word("centred") : r.contains("right") ? TextFormat.word("right aligned") : r.contains("justify") ? TextFormat.word("justified") : TextFormat.word("left aligned")
            DispatchQueue.main.async { Speech.speakMessage(words) }
        }
    }
    func lineSpacing() {
        queue.async {
            let r = self.run("tell application \"Microsoft Word\" to return (line spacing rule of paragraph format of selection) as text") ?? ""
            let words = r.contains("double") ? TextFormat.word("double spacing") : r.contains("1pt5") || r.contains("one and a half") ? TextFormat.word("1.5 line spacing")
                : r.contains("single") ? TextFormat.word("single spacing") : String(localized: "line spacing \(r)", comment: "Word's line spacing rule, as Word names it")
            DispatchQueue.main.async { Speech.speakMessage(words) }
        }
    }
    /// Alignment and line spacing in words, for the detailed formatting report (VO-T twice; a tester): Word
    /// doesn't give them to accessibility.
    func paragraphFormat(_ completion: @escaping @MainActor (String) -> Void) {
        queue.async {
            let a = self.run("tell application \"Microsoft Word\" to return (alignment of paragraph format of selection) as text") ?? ""
            let l = self.run("tell application \"Microsoft Word\" to return (line spacing rule of paragraph format of selection) as text") ?? ""
            let pts = self.run("tell application \"Microsoft Word\" to return (line spacing of paragraph format of selection) as text") ?? ""
            // Word's words, spaces taken out ("line space1 pt5" and "line space 1pt5" both seen); a selection of
            // paragraphs that differ comes back as missing value or 9999999 (code review, 13 Oct: raw values were said).
            let aw = a.lowercased().replacingOccurrences(of: " ", with: ""), lw = l.lowercased().replacingOccurrences(of: " ", with: "")
            func mixed(_ v: String) -> Bool { v.isEmpty || v.contains("missing") || v.contains("9999999") }
            let align = mixed(aw) ? "" : aw.contains("center") ? TextFormat.word("centred") : aw.contains("right") ? TextFormat.word("right aligned")
                : aw.contains("distribute") ? TextFormat.word("distributed") : aw.contains("justify") ? TextFormat.word("justified") : aw.contains("left") ? TextFormat.word("left aligned") : ""
            let points = Double(pts.replacingOccurrences(of: ",", with: ".")).map { $0 == $0.rounded() ? String(Int($0)) : String(format: "%.1f", $0) }
            let space: String
            if mixed(lw) { space = "" }
            else if lw.contains("double") { space = TextFormat.word("double spacing") }
            else if lw.contains("1pt5") || lw.contains("onepointfive") { space = TextFormat.word("1.5 line spacing") }
            else if lw.contains("single") { space = TextFormat.word("single spacing") }
            else if lw.contains("atleast") { space = points.map { String(localized: "line spacing at least \($0) points", comment: "Paragraph line spacing: %@ is the size") } ?? TextFormat.word("line spacing at least") }
            else if lw.contains("exactly") { space = points.map { String(localized: "line spacing exactly \($0) points", comment: "Paragraph line spacing: %@ is the size") } ?? TextFormat.word("exact line spacing") }
            else if lw.contains("multiple"), let p = Double(pts.replacingOccurrences(of: ",", with: ".")) {
                let lines = p / 12; space = String(localized: "line spacing \(lines == lines.rounded() ? String(Int(lines)) : String(format: "%.2g", lines)) lines", comment: "Paragraph line spacing in lines: %@ is how many")
            } else { space = "" }
            let words = [align, space].filter { !$0.isEmpty }.joined(separator: ", ")
            DispatchQueue.main.async { completion(words) }
        }
    }
    func trackChanges() {
        queue.async {
            let r = self.run("tell application \"Microsoft Word\" to return (track revisions of active document) as text") ?? ""
            DispatchQueue.main.async { Speech.speakMessage(r == "true" ? String(localized: "track changes on", comment: "Spoken message") : String(localized: "track changes off", comment: "Spoken message")) }
        }
    }
    struct Comment { let author: String; let text: String; let start: Int }
    func comments(_ completion: @escaping @MainActor ([Comment]) -> Void) {
        queue.async {
            let r = self.run("""
            tell application "Microsoft Word"
                set out to ""
                set n to count Word comments of active document
                if n > 100 then set n to 100
                repeat with i from 1 to n
                    set c to Word comment i of active document
                    set out to out & (author of c) & tab & (content of comment text of c) & tab & ((start of content of scope of c) as text) & linefeed
                end repeat
                return out
            end tell
            """) ?? ""
            let list = r.split(separator: "\n").compactMap { line -> Comment? in
                let p = line.components(separatedBy: "\t")
                guard p.count >= 3, let start = Int(p[2]) else { return nil }
                return Comment(author: p[0], text: p[1], start: start)
            }
            DispatchQueue.main.async { completion(list) }
        }
    }
    func goToOffset(_ offset: Int, completion: @escaping @MainActor () -> Void) {
        queue.async {
            _ = self.run("tell application \"Microsoft Word\" to select (create range active document start \(offset) end \(offset))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { completion() }
        }
    }

    nonisolated private static let automation = WordAutomationState()

    nonisolated private func run(_ source: String) -> String? {
        // No AEDeterminePermissionToAutomateTarget: on this Mac it never returned, even when told not to wait (it sat on a
        // semaphore inside AE), and every Word command hung behind it (4 Oct 2026). The script itself brings up macOS's
        // question the first time; a refusal (-1743) is explained below.
        // The first script brings up macOS's question, "TurnOver wants to control Microsoft Word", and the question
        // lasts only as long as the script waits: at 5 s it vanished while a tester arrowed to Allow (
        // 5 Oct 2026). Until Word has answered once, wait as long as the user needs, and say what is being asked.
        let request = Self.automation.begin()
        let first = request.isFirst
        if first {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                guard Self.automation.isPending(request), NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.UserNotificationCenter").contains(where: { !$0.isTerminated }) else { return }
                Speech.speakMessage(String(localized: "macOS is asking whether TurnOver may control Microsoft Word. Choose Allow; there is no hurry.", comment: "Spoken message"))
            }
        }
        var error: NSDictionary?
        let result = NSAppleScript(source: "with timeout of \(first ? 300 : 5) seconds\n\(source)\nend timeout")?.executeAndReturnError(&error)
        let refused = Self.automation.finish(request, succeeded: error == nil,
                                             refused: (error?[NSAppleScript.errorNumber] as? Int) == -1743)
        if let error {
            // The number only: the message can quote the document's own text (a code review on 18 Oct 2026).
            Log.warning("Word script error \(error[NSAppleScript.errorNumber] ?? "?")")
            // Refused (errAEEventNotPermitted, -1743): say why, once in a while, not fail in silence.
            if refused {
                DispatchQueue.main.async {
                    Speech.speakMessage(String(localized: "TurnOver needs permission to control Word. In System Settings, Privacy and Security, Automation, turn on Microsoft Word under TurnOver.", comment: "Spoken message"))
                }
            }
            return nil
        }
        return result?.stringValue
    }
}
