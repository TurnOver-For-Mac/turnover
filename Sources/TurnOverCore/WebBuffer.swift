// SPDX-License-Identifier: GPL-3.0-or-later
// The virtual buffer (NVDA: virtualBuffers): TurnOver's own flat copy of a web
// document, built from the accessibility tree, navigated without asking WebKit
// about text positions at all.
//
// Why: WebKit's character indices and text markers disagree on pages with
// replaced elements (measured on YouTube, 2 Oct 2026: a one-index range came
// back as half a page), so an index-based TextInfo over markers reads lines
// twice, skips lines, or reads the whole page as one line. NVDA's answer on
// Windows is the same as this: walk the tree once, lay it out as lines, keep
// the element behind every stretch of text.
//
// Layout rules (NVDA's): block elements start a new line; each control is a
// line of its own ("Create, button"); headings, lists, tables and landmarks
// announce themselves on the first line inside them; links are inline and
// marked; images are inline by their description; long lines wrap at the
// configured length.
import Foundation
import ApplicationServices
import TurnOverAX
import AppKit

public final class WebBuffer {
    public struct Segment {
        public let start: Int; public let end: Int; public let element: AXUIElement; public let isLink: Bool
        public init(start: Int, end: Int, element: AXUIElement, isLink: Bool) { self.start = start; self.end = end; self.element = element; self.isLink = isLink }
    }
    public struct Line {
        public let start: Int
        public let end: Int
        /// The element this line is (a control, a heading) or the block it is in.
        public let element: AXUIElement?
        /// Containers entered with this line (outermost first), for "list with 5 items", "heading level 2".
        public let entering: [AXUIElement]
        /// A control line: spoken as the control, activated as one.
        public let isControl: Bool
        /// For a control line: what to say besides the label (role, states, value), role first.
        public let fields: [String]
        /// The last piece of a wrapped line owns the break after it; earlier pieces end at a space.
        public let hasBreak: Bool
        public init(start: Int, end: Int, element: AXUIElement?, entering: [AXUIElement], isControl: Bool, fields: [String], hasBreak: Bool) {
            self.start = start; self.end = end; self.element = element; self.entering = entering; self.isControl = isControl; self.fields = fields; self.hasBreak = hasBreak
        }
        public var endWithBreak: Int { end + (hasBreak ? 1 : 0) }
    }

    public let webArea: AXUIElement
    public private(set) var text = "" as NSString
    public private(set) var lines: [Line] = []
    public private(set) var segments: [Segment] = []
    /// Lists, tables, block quotes and landmarks, by the text they span: NVDA's comma and Shift comma.
    public private(set) var containers: [(start: Int, end: Int, element: AXUIElement)] = []
    public private(set) var builtAt = Date.distantPast
    public var isDirty = true
    /// How long the last build took: a page slow to read is not read again on every arrow.
    public private(set) var lastBuildMs = 0
    private var elementCount = 0

    public init(webArea: AXUIElement) {
        self.webArea = webArea; iosContent = webArea.string(kAXSubroleAttribute) == "iOSContentGroup"
        decorativeImages = NSRunningApplication(processIdentifier: webArea.pid)?.bundleIdentifier.map { Self.decorativeImageApps.contains($0) } ?? false
    }
    /// Apps (set by their modules) whose pictures are icons only, left out of the copy.
    nonisolated(unsafe) public static var decorativeImageApps: Set<String> = []
    private let decorativeImages: Bool
    /// Subroles of an iOS screen's parts left out of its copy (set by app modules).
    nonisolated(unsafe) public static var iosSkippedSubroles: Set<String> = []
    /// Identifiers of an iOS screen's parts read before their siblings (set by app modules).
    nonisolated(unsafe) public static var iosLeadingIdentifiers: Set<String> = []
    /// The root is an iPad app's window content (Kindle), not a page.
    private let iosContent: Bool

    // MARK: Building

    private var out = ""                       // the text so far
    private var outLength = 0                  // its length in UTF-16 units (measuring `out` each line made a build quadratic on a non-ASCII page, 8 Oct 2026)
    private var current: [(String, AXUIElement, Bool)] = []   // pieces of the line being built: text, element, isLink
    private var currentElement: AXUIElement?
    private var pendingEntering: [AXUIElement] = []
    private var containerStack: [AXUIElement] = []
    private var linkDepth = 0
    private var newLines: [Line] = []
    private var newSegments: [Segment] = []
    private var newContainers: [(start: Int, end: Int, element: AXUIElement)] = []
    private var visited = 0
    static let maxElements = 6000
    private var buildDeadline = Date.distantFuture
    /// The last read stopped at its time limit: the end of a very long page is missing.
    public private(set) var isPartial = false
    private var saidPartial = false
    private var loggedPartial = false
    /// A new page in the same web area: the partial-page notice is due again (code review, 16 Oct 2026, item 29).
    public func newPage() { saidPartial = false; loggedPartial = false }
    private var docText = "" as NSString
    private var docCursor = 0
    private var lastTextEnd: Int?

    public func build() {
        let t0 = Date()
        out = ""; outLength = 0; current = []; currentElement = nil; pendingEntering = []; containerStack = []; linkDepth = 0
        newLines = []; newSegments = []; newContainers = []; visited = 0
        // At most 2 s on the main thread (the watchdog trips at 4): a huge page is read only in part, rather than
        // TurnOver freezing (E6 audit, 4 Oct 2026). Reading such a page off the main thread is the full answer.
        buildDeadline = Date().addingTimeInterval(2)
        profiled = !ProfileStore.shared.profiles(for: ProfileStore.shared.bundle(of: webArea.pid)).isEmpty
        consumed = []
        // WebKit's own text of the page has a line break wherever a <br> is; the elements do not (a plain
        // e-mail is sibling texts separated by <br>: "Hi there," and the paragraph after it read as one line).
        let bridge = WebDocumentBridge(webArea: webArea)
        docText = (bridge.documentRange().map { bridge.string($0) } ?? "") as NSString
        docCursor = 0; lastTextEnd = nil
        visit(webArea, depth: 0)
        flush()
        // A modal dialog up (Squarespace's Cancel domain registration, 22 Oct 2026): Safari's web area reports a
        // single child with nothing to read in it, while the focused buttons are inside the dialog. Then the dialog
        // is read instead: the focused element's outermost ancestor below the web area.
        if newLines.isEmpty, let dialog = focusedPartOfPage() {
            Log.info("virtual buffer: the web area gave nothing; reading the focused element's part of the page (\(dialog.role))")
            visit(dialog, depth: 1)
            flush()
        }
        text = out as NSString
        lines = newLines
        segments = newSegments
        containers = newContainers
        elementCount = visited
        builtAt = Date()
        isDirty = false
        isPartial = Date() >= buildDeadline
        // Said once per page: nothing read the flag, so K said "no next link" and "bottom" mid-page without a word
        // (a code review, 14 Oct 2026).
        if isPartial, !saidPartial { saidPartial = true; DispatchQueue.main.async { MainActor.assumeIsolated { Speech.speakMessage("page read in part, it is very long") } } }
        if isPartial, !loggedPartial { loggedPartial = true; Log.error("virtual buffer: stopped at 2 s after \(visited) elements; the page is read only in part") }
        lastBuildMs = Int(Date().timeIntervalSince(t0) * 1000)
        Log.info("virtual buffer: \(lines.count) lines, \(text.length) characters from \(visited) elements in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
    }

    /// The focused element's outermost ancestor below the web area, if the focus is inside this web area.
    private func focusedPartOfPage() -> AXUIElement? {
        guard let focus = API.focusObject?.element, focus.pid == webArea.pid, !focus.isSame(webArea) else { return nil }
        var part = focus
        var steps = 0
        while steps < 60 {
            guard let parent = part.element(kAXParentAttribute) else { return nil }   // no web area above: not this page
            if parent.isSame(webArea) { return part }
            part = parent
            steps += 1
        }
        return nil
    }

    static let controlRoles: Set<String> = ["AXButton", "AXPopUpButton", "AXComboBox", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXMenuItem", "AXSlider", "AXMenuButton", "AXIncrementor", "AXDisclosureTriangle", "AXColorWell", "AXDateField", "AXTimeField"]
    static let blockRoles: Set<String> = ["AXGroup", "AXWebArea", "AXHeading", "AXList", "AXTable", "AXRow", "AXOutline", "AXScrollArea", "AXSplitGroup", "AXTabGroup", "AXToolbar", "AXLayoutArea", "AXGrid", "AXLandmark", "AXBlockQuote", "AXDocument", "AXCell"]
    static let skipRoles: Set<String> = ["AXScrollBar", "AXSplitter", "AXValueIndicator", "AXRuler", "AXHelpTag"]
    static let announcedContainers: Set<String> = ["AXHeading", "AXList", "AXTable", "AXBlockQuote", "AXMenuBar", "AXToolbar"]
    /// Group subroles announced on entering, as landmarks are: Chromium's dialogs and alerts (Day 3, 10 Oct 2026).
    static let announcedSubroles: Set<String> = ["AXApplicationDialog", "AXApplicationAlertDialog", "AXApplicationAlert"]

    /// Whether a plugin profile applies to this page's application (checked once per build).
    private var profiled = false
    /// Siblings whose text a plugin label took (so "Open Project" is not read twice).
    private var consumed: [AXUIElement] = []

    private func visit(_ el: AXUIElement, depth: Int) {
        guard visited < Self.maxElements, depth < 60, Date() < buildDeadline else { return }
        visited += 1
        let role = el.role
        // A separator (a page's <hr>, WebKit's AXSplitter) is a line of its own, as NVDA shows it: S finds it.
        if role == "AXSplitter", depth > 0, el.string(kAXRoleDescriptionAttribute)?.lowercased().contains("separator") ?? true {
            flush(); currentElement = el; append("separator", el); flush()
            return
        }
        if Self.skipRoles.contains(role) { return }
        // An iOS screen's parts a module leaves out (Maps' map: dozens of dots beside the panel being read).
        if iosContent, !Self.iosSkippedSubroles.isEmpty, Self.iosSkippedSubroles.contains(el.string(kAXSubroleAttribute) ?? "") { return }
        if profiled, depth > 0 {
            // A plugin's rules: silenced elements are left out; a labelled one is a line of its own, read as the
            // plugin names it ("Open Project, button" for Bambu Studio's unnamed pressable image).
            if ProfileStore.shared.isSilenced(el, pid: webArea.pid) { return }
            if consumed.contains(where: { $0.isSame(el) }) { return }   // its text became a label already
            if let d = ProfileStore.shared.labelDetail(for: el, pid: webArea.pid), let name = d.name, !name.isEmpty {
                let roleText = d.role
                if let src = d.source { consumed.append(src) }
                flush()
                currentElement = el
                current.append((name, el, false))
                flush(control: true, fields: [roleText ?? Role.from(axRole: role, subrole: el.string(kAXSubroleAttribute)).displayString])
                return
            }
        }
        let sub = el.string(kAXSubroleAttribute) ?? ""
        switch role {
        case "AXStaticText":
            // An iOS app's text (Kindle's own screens, read as a document) carries its words as the description.
            if let v = el.string(kAXValueAttribute).flatMap({ $0.isEmpty ? nil : $0 }) ?? (iosContent ? el.string(kAXDescriptionAttribute) : nil), !v.isEmpty {
                // Where this text is in WebKit's text: a line break between it and the text before means a <br>.
                let window = NSRange(location: docCursor, length: min(docText.length - docCursor, 2000 + (v as NSString).length))
                let r = window.length > 0 ? docText.range(of: v, options: .literal, range: window) : NSRange(location: NSNotFound, length: 0)
                var space: Bool? = nil
                if r.location != NSNotFound {
                    if let p = lastTextEnd, !current.isEmpty, r.location >= p {
                        let between = docText.substring(with: NSRange(location: p, length: r.location - p))
                        if between.contains("\n") { flush() }
                        // Pieces that touch on the page touch in the buffer: "(" + "Stop squark" + ")" is not "( Stop squark )".
                        space = between.contains { $0.isWhitespace }
                    }
                    docCursor = r.location + r.length
                }
                // Each of an iOS screen's texts is a line of its own: nothing there says where its lines break, and
                // Kindle's welcome ran its headings into their paragraphs.
                if iosContent { flush() }
                append(v, el, space: space)
                if iosContent { flush() }
                lastTextEnd = r.location != NSNotFound ? r.location + r.length : nil
            }
        case "AXGenericElement" where iosContent:
            // A book's page in Kindle: the whole page as one value, with no lines or paragraphs given (probe, 18 Oct
            // 2026: 2,164 characters, no line breaks, no line ranges). Each sentence is a line; long ones wrap.
            guard let v = el.string(kAXValueAttribute), !v.isEmpty else { break }
            flush()
            v.enumerateSubstrings(in: v.startIndex..<v.endIndex, options: .bySentences) { sentence, _, _, _ in
                guard let t = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return }
                self.currentElement = el
                self.append(t, el)
                self.flush()
            }
        case "AXImage" where decorativeImages:
            break   // an app whose pictures are only icons (Shortcuts: "graphic Stack of rectangles" before every folder)
        case "AXImage":
            var d = el.string(kAXDescriptionAttribute) ?? el.string(kAXTitleAttribute) ?? ""
            if d.isEmpty, config.virtualBuffers.imageFileNames { d = ImageNames.fromFile(el) }
            if !d.isEmpty || linkDepth == 0 { append(d.isEmpty ? "graphic" : "graphic \(d)", el) }
        case "AXLink":
            // Screen layout off (NVDA): each link on a line of its own.
            let ownLine = !config.virtualBuffers.screenLayout
            if ownLine { flush() }
            linkDepth += 1
            let before = current.count
            for k in el.elements(kAXChildrenAttribute) { visit(k, depth: depth + 1) }
            if current.count == before, let t = el.string(kAXTitleAttribute) ?? el.string(kAXDescriptionAttribute), !t.isEmpty { append(t, el) }
            linkDepth -= 1
            if ownLine { flush() }
        case _ where Self.controlRoles.contains(role):
            flush()
            let obj = ObjectFactory.make(el)
            let label = obj.name.isEmpty ? (obj.value ?? "") : obj.name
            let fields = Speech.objectPropertiesSpeech(obj, reason: .focus).filter { $0 != label }
            currentElement = el
            current.append((label.isEmpty ? obj.role.displayString : label, el, false))
            flush(control: true, fields: fields)
        case "AXHeading" where el.elements(kAXChildrenAttribute).isEmpty:
            // A heading with no text children (SwiftUI content in Music) is its own title.
            flush()
            pendingEntering.append(el)
            if let t = el.string(kAXDescriptionAttribute) ?? el.string(kAXTitleAttribute) ?? el.string(kAXValueAttribute), !t.isEmpty { currentElement = el; append(t, el) }
            flush()
            pendingEntering.removeAll { $0.isSame(el) }
        default:
            let isLandmark = sub.hasPrefix("AXLandmark") || sub == "AXDocumentArticle" || sub == "AXBlockQuote"
            let announced = Self.announcedContainers.contains(role) || isLandmark || Self.announcedSubroles.contains(sub)
            let block = Self.blockRoles.contains(role) || isLandmark || sub == "AXListItem" || role == "AXMenuBar" || Self.announcedSubroles.contains(sub)
            if block { flush() }
            if announced { pendingEntering.append(el); containerStack.append(el) }
            if block, currentElement == nil { currentElement = el }
            let containerStart = outLength
            var kids = el.elements(kAXChildrenAttribute)
            // A table is read by its rows. Chromium also lists it by columns and repeats its header row in a group
            // of cells: Google Sheets' grid was read three times over (Day 3, 10 Oct 2026).
            if role == "AXTable" || role == "AXGrid" {
                kids.removeAll { k in k.role == "AXColumn" || (k.role == "AXGroup" && { let c = k.elements(kAXChildrenAttribute); return !c.isEmpty && c.allSatisfy { $0.role == "AXCell" } }()) }
            }
            // Each item of a list is a line of its own: Chromium's listbox options are bare texts, and with no line
            // break between them on the page they ran together ("Google DocsExample Doc"; Google Drive's file list).
            // An iOS screen's parts that a module puts first (Kindle's Add Bookmark, after the page's words in the tree,
            // was read by say all at the foot of every page before it turned).
            if iosContent, !Self.iosLeadingIdentifiers.isEmpty {
                let lead = kids.filter { Self.iosLeadingIdentifiers.contains($0.string(kAXIdentifierAttribute) ?? "") }
                if !lead.isEmpty { kids = lead + kids.filter { k in !lead.contains { $0.isSame(k) } } }
            }
            let eachOnALine = role == "AXList" || role == "AXOutline"
            for k in kids { if eachOnALine { flush() }; visit(k, depth: depth + 1) }
            if block { flush() }
            if announced { containerStack.removeLast(); pendingEntering.removeAll { $0.isSame(el) } }
            if announced, role != "AXHeading", outLength > containerStart { newContainers.append((containerStart, outLength, el)) }
        }
    }

    /// `space`: whether the page has white space between this piece and the last (nil: not known, so add one).
    private func append(_ s: String, _ el: AXUIElement, space: Bool? = nil) {
        lastTextEnd = nil
        let t = s.replacingOccurrences(of: "\n", with: " ")
        if current.isEmpty { currentElement = currentElement ?? el }
        if !current.isEmpty, space ?? true, let last = current.last?.0.last, !last.isWhitespace, !(t.first?.isWhitespace ?? true) { current.append((" ", el, linkDepth > 0)) }
        current.append((t, el, linkDepth > 0))
    }

    /// Emit the line being built, wrapped, with its segments.
    private func flush(control: Bool = false, fields: [String] = []) {
        guard !current.isEmpty else { return }
        let full = current.map(\.0).joined()
        guard !full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { current = []; return }
        let entering = pendingEntering; pendingEntering = []
        var lineStart = outLength
        // Segments in absolute offsets.
        var cursor = lineStart
        var segs: [Segment] = []
        for (piece, el, link) in current {
            let len = (piece as NSString).length
            if len > 0 { segs.append(Segment(start: cursor, end: cursor + len, element: el, isLink: link)) }
            cursor += len
        }
        out += full + "\n"
        outLength += (full as NSString).length + 1
        let totalEnd = cursor
        newSegments.append(contentsOf: segs)
        // Wrap at the configured length, breaking at spaces.
        let maxLen = max(20, config.virtualBuffers.maxLineLength)
        var first = true
        for (a, b) in Self.wrapPieces(full as NSString, maxLen: maxLen) {
            newLines.append(Line(start: lineStart + a, end: lineStart + b, element: currentElement, entering: first ? entering : [], isControl: control, fields: first ? fields : [], hasBreak: b == (full as NSString).length))
            first = false
        }
        _ = totalEnd
        current = []
        currentElement = nil
        lineStart = 0
    }

    /// Where a line's text breaks into pieces of at most `maxLen` UTF-16 units, at a space when one falls in the
    /// second half of a piece, else hard. Pure, so the tests can see it (8 Oct 2026). Local offsets, half-open.
    public static func wrapPieces(_ ns: NSString, maxLen: Int) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        var local = 0
        while local < ns.length {
            var end = min(local + maxLen, ns.length)
            if end < ns.length {
                var cut = end
                while cut > local + maxLen / 2, ns.character(at: cut - 1) != 32 { cut -= 1 }
                if cut > local + maxLen / 2 { end = cut }
            }
            out.append((local, end))
            local = end
        }
        return out
    }

    /// Whether line j of `lines` carries on the element of the line before (pure; `lineContinues` uses it).
    public static func continues(_ lines: [Line], _ j: Int) -> Bool {
        guard j > 0, j < lines.count, let el = lines[j].element, let prev = lines[j - 1].element else { return false }
        return prev.isSame(el) && lines[j].entering.isEmpty
    }

    // MARK: Lookup

    /// The line holding an offset: the last line that starts at or before it.
    public func lineIndex(at offset: Int) -> Int? {
        guard !lines.isEmpty else { return nil }
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].start <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    // MARK: The line under the caret, against the page as it is now
    // VoiceOver keeps no copy of a page and asks at every move, so it reads what the page says now; this copy is
    // rebuilt only when Safari reports a change, and a page can change without one. fast.com swapped its speed's
    // text eight times a second with no notification at all, and every arrow said the copy's "38" while the page
    // climbed to 65 (29 Oct 2026). The line just reached is asked again, briefly: a copy that no longer matches is
    // made again by the caller.

    /// What the page says now for one of a line's text runs, against the copy.
    nonisolated public enum RunCheck: Equatable, Sendable { case same, changed, gone, unknown }
    /// A line's copy against the page: changed when a run changed or went; unknown when a run could not be asked.
    nonisolated public enum LineCheck: Equatable, Sendable { case unchanged, changed, unknown }

    nonisolated public static func lineCheck(_ runs: [RunCheck]) -> LineCheck {
        if runs.contains(where: { $0 == .changed || $0 == .gone }) { return .changed }
        return runs.contains(.unknown) ? .unknown : .unchanged
    }

    /// The copy's text and the page's compared as the copy was made: line breaks became spaces, a long line wrapped
    /// at a space, and runs of white space say nothing.
    nonisolated public static func sameText(_ copied: String, _ live: String) -> Bool {
        func words(_ s: String) -> String { s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
        return words(copied) == words(live)
    }

    /// The plain text runs of line `index` asked for their value again. Bounded so a busy page can't hold a key up
    /// (the "Safari not responding" VoiceOver gives, asking at every move): at most `maxRuns` runs, each question
    /// with a 50 ms messaging timeout and under AXHealth, so an app resting after a timeout is not asked at all, and
    /// `budgetMs` for the whole line. Control lines (a field's value is not its line's words) and runs that are not
    /// static text (an image's description) are not compared.
    public func check(line index: Int, maxRuns: Int = 8, budgetMs: UInt64 = 60) -> LineCheck {
        guard lines.indices.contains(index), !lines[index].isControl else { return .unknown }
        let line = lines[index]
        let started = DispatchTime.now().uptimeNanoseconds
        var runs: [RunCheck] = [], asked = 0
        func ask(_ e: AXUIElement, _ name: String) -> AXQueryResult<CFTypeRef> {
            AXUIElementSetMessagingTimeout(e, 0.05)
            defer { AXUIElementSetMessagingTimeout(e, 0) }   // back to the app's own timeout for later questions
            return e.attributeResult(name)
        }
        for seg in segments where seg.end > line.start && seg.start < line.end {
            guard asked < maxRuns else { break }
            if DispatchTime.now().uptimeNanoseconds &- started > budgetMs * 1_000_000 { runs.append(.unknown); break }
            guard seg.start >= 0, seg.end <= text.length, seg.end > seg.start else { continue }
            let copied = text.substring(with: NSRange(location: seg.start, length: seg.end - seg.start))
            guard !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            asked += 1
            let role = ask(seg.element, kAXRoleAttribute)
            if role.error == .invalidUIElement { runs.append(.gone); continue }
            guard let r = role.value as? String else { runs.append(.unknown); continue }
            guard r == "AXStaticText" else { continue }
            let value = ask(seg.element, kAXValueAttribute)
            switch value.status {
            case .returned(.success): runs.append((value.value as? String).map { Self.sameText(copied, $0) ? .same : .changed } ?? .unknown)
            case .returned(.invalidUIElement): runs.append(.gone)
            default: runs.append(.unknown)
            }
        }
        return Self.lineCheck(runs)
    }

    public func segment(at offset: Int) -> Segment? {
        segments.first { offset >= $0.start && offset < $0.end }
    }

    /// Quick navigation without WebKit: the next or previous line whose element has one of the roles.
    public func findLine(from offset: Int, forward: Bool, roles: Set<String>, headingLevel: Int? = nil) -> Int? {
        find(from: offset, forward: forward, roles: roles, headingLevel: headingLevel)?.offset
    }

    /// The next or previous element of these roles: a line that is one, a container a line enters, or (for links)
    /// a link's text inside a line, so "k" finds the link in a heading or a paragraph. Looked at lazily, in order.
    /// Where the link text at an offset ends: its pieces run on while they are link pieces and touch.
    public func linkEnd(at offset: Int) -> Int? {
        var lo = 0, hi = segments.count
        while lo < hi { let m = (lo + hi) / 2; if segments[m].end <= offset { lo = m + 1 } else { hi = m } }
        guard lo < segments.count, segments[lo].isLink, segments[lo].start <= offset else { return nil }
        var end = segments[lo].end
        var k = lo + 1
        while k < segments.count, segments[k].isLink, segments[k].start == end { end = segments[k].end; k += 1 }
        return end
    }

    /// NVDA's P and N in browse mode (a tester, 13 Oct 2026): the next paragraph of text, and the next text after a
    /// block of links. A block is a line with the lines that carry it on (a wrapped paragraph).
    public enum TextKind { case paragraph, afterLinks }

    public func findText(from offset: Int, forward: Bool, kind: TextKind) -> (offset: Int, element: AXUIElement?)? {
        Self.findText(lines: lines, segments: segments, text: text, from: offset, forward: forward, kind: kind)
    }

    /// The search itself, on plain values, so the tests can give it lines of their own.
    public static func findText(lines: [Line], segments: [Segment], text: NSString, from offset: Int, forward: Bool, kind: TextKind) -> (offset: Int, element: AXUIElement?)? {
        guard !lines.isEmpty else { return nil }
        func lineContinues(_ j: Int) -> Bool { continues(lines, j) }
        struct Block { let first: Int; let start: Int; let end: Int }
        var blocks: [Block] = []
        var j = 0
        while j < lines.count {
            var k = j
            while k + 1 < lines.count, lineContinues(k + 1) { k += 1 }
            blocks.append(Block(first: j, start: lines[j].start, end: lines[k].end))
            j = k + 1
        }
        func content(_ b: Block) -> (chars: Int, linked: Int, text: String) {
            let t = text.substring(with: NSRange(location: b.start, length: max(0, b.end - b.start)))
            let chars = t.filter { !$0.isWhitespace }.count
            var linked = 0
            for sg in segments where sg.isLink && sg.end > b.start && sg.start < b.end {
                let a = max(sg.start, b.start), z = min(sg.end, b.end)
                linked += text.substring(with: NSRange(location: a, length: max(0, z - a))).filter { !$0.isWhitespace }.count
            }
            return (chars, linked, t)
        }
        func isHeading(_ b: Block) -> Bool {
            let l = lines[b.first]
            return l.element?.role == "AXHeading" || l.entering.contains { $0.role == "AXHeading" }
        }
        /// Mostly links, or a control: what N skips over.
        func linkish(_ b: Block) -> Bool { let c = content(b); return lines[b.first].isControl || (c.chars > 0 && c.linked * 2 >= c.chars) }
        func plain(_ b: Block) -> Bool { let c = content(b); return !lines[b.first].isControl && c.chars > 0 && c.linked * 2 < c.chars }
        /// A paragraph, as NVDA's default: text, not a heading, of a few words, ending as a sentence ends.
        func paragraph(_ b: Block) -> Bool {
            guard plain(b), !isHeading(b) else { return false }
            let t = content(b).text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.split(whereSeparator: \.isWhitespace).count >= 3
                && t.range(of: #"[.!?…:;][\"'”’)\]]*$"#, options: .regularExpression) != nil
        }
        let here = blocks.lastIndex { $0.start <= offset } ?? 0
        let order = forward ? Array(blocks.indices.dropFirst(here + 1)) : Array(blocks.indices.prefix(here).reversed())
        switch kind {
        case .paragraph:
            guard let i = order.first(where: { paragraph(blocks[$0]) }) else { return nil }
            return (blocks[i].start, lines[blocks[i].first].element)
        case .afterLinks:
            if forward {
                var passedLinks = linkish(blocks[here])
                for i in order {
                    if linkish(blocks[i]) { passedLinks = true } else if passedLinks, plain(blocks[i]) { return (blocks[i].start, lines[blocks[i].first].element) }
                }
            } else {
                // Back: the start of the text before here that comes straight after links.
                for i in order where i > 0 && plain(blocks[i]) && linkish(blocks[i - 1]) { return (blocks[i].start, lines[blocks[i].first].element) }
            }
            return nil
        }
    }

    public func find(from offset: Int, forward: Bool, roles: Set<String>, headingLevel: Int? = nil) -> (offset: Int, element: AXUIElement)? {
        guard !lines.isEmpty else { return nil }
        // Past either end (a search wrapping round): the last line, or the first.
        let i = lineIndex(at: offset) ?? (offset >= text.length ? lines.count - 1 : 0)
        let wantsLinks = roles.contains("AXLink")
        func matches(_ el: AXUIElement) -> Bool {
            let role = el.role
            if roles.contains("AXLandmark"), role == "AXGroup", (el.string(kAXSubroleAttribute) ?? "").hasPrefix("AXLandmark") { return true }
            if roles.contains("AXBlockQuote"), role == "AXGroup", el.string(kAXSubroleAttribute) == "AXBlockQuote" || el.string(kAXRoleDescriptionAttribute) == "blockquote" { return true }
            if roles.contains("AXListItem"), el.string(kAXSubroleAttribute) == "AXListItem" { return true }
            if roles.contains("Annotation") {
                // NVDA's A: comments and revisions (insertions, deletions, highlights) the page marks as such.
                let sub = el.string(kAXSubroleAttribute) ?? "", desc = (el.string(kAXRoleDescriptionAttribute) ?? "").lowercased()
                if ["AXInsertStyleGroup", "AXDeleteStyleGroup"].contains(sub) || ["comment", "suggestion", "insertion", "deletion", "highlight", "mark"].contains(desc) { return true }
            }
            if roles.contains("EmbeddedObject") {
                // NVDA's O: audio and video players, embedded applications, dialogs.
                let sub = el.string(kAXSubroleAttribute) ?? "", desc = (el.string(kAXRoleDescriptionAttribute) ?? "").lowercased()
                if ["AXWebApplication", "AXApplicationDialog", "AXApplicationAlertDialog"].contains(sub) || desc.contains("video") || desc.contains("audio") { return true }
            }
            guard roles.contains(role) else { return false }
            if let level = headingLevel, (el.attr(kAXValueAttribute) as? NSNumber)?.intValue != level { return false }
            return true
        }
        /// What line j offers, in reading order.
        func hits(_ j: Int) -> [(Int, AXUIElement)] {
            let l = lines[j]
            var out: [(Int, AXUIElement)] = []
            var seen: [AXUIElement] = []
            for c in l.entering where matches(c) { out.append((l.start, c)); seen.append(c) }
            // A line that carries on the element of the line before (a heading wrapped over two lines) is not a
            // second hit: H landed on "closed beta" after the whole heading (8 Oct 2026).
            if let el = l.element, !lineContinues(j), !seen.contains(where: { $0.isSame(el) }), matches(el) { out.append((l.start, el)) }
            if wantsLinks, out.isEmpty {
                // Link text inside the line; a link split over several pieces counts once.
                var lo = 0, hi = segments.count
                while lo < hi { let m = (lo + hi) / 2; if segments[m].end <= l.start { lo = m + 1 } else { hi = m } }
                var prevLinkEnd = -2
                var k = lo
                while k < segments.count, segments[k].start < l.end {
                    let sg = segments[k]
                    // A link that began on an earlier piece of a wrapped line was counted there.
                    if sg.isLink, sg.start >= l.start, sg.start > prevLinkEnd + 1 { out.append((sg.start, sg.element)) }
                    prevLinkEnd = sg.isLink ? sg.end : -2
                    k += 1
                }
            }
            return out
        }
        if forward {
            for j in i..<lines.count { if let h = hits(j).first(where: { $0.0 > offset }) { return h } }
        } else {
            for j in stride(from: i, through: 0, by: -1) { if let h = hits(j).last(where: { $0.0 < offset }) { return h } }
        }
        return nil
    }

    /// The first offset of an element, or of text inside it (a quick-nav target, a focused control).
    /// Whether line j carries on the element of the line before it (a long heading wrapped at the line length):
    /// one element, several lines. Anything that judges lines one by one must treat them as one (8 Oct 2026).
    public func lineContinues(_ j: Int) -> Bool { Self.continues(lines, j) }
    /// The range of the whole element starting on line i: through its continuation lines.
    public func elementRange(fromLine i: Int) -> (Int, Int) {
        var j = i
        while j + 1 < lines.count, lineContinues(j + 1) { j += 1 }
        return (lines[i].start, lines[j].end)
    }

    public func offset(of element: AXUIElement) -> Int? {
        if let s = segments.first(where: { $0.element.isSame(element) }) { return s.start }
        if let l = lines.first(where: { $0.element.map { $0.isSame(element) } ?? false }) { return l.start }
        // Text inside it: the first segment (in reading order) under it. Found by walking down from the element
        // over a few hundred children at most; walking up from every segment asked the page eight questions a
        // segment, seconds a Tab on a big page (Gmail, YouTube; 8 Oct 2026).
        var starts: [ElementKey: Int] = [:]
        for s in segments where starts[ElementKey(s.element)] == nil { starts[ElementKey(s.element)] = s.start }
        var best: Int?
        var queue: [(AXUIElement, Int)] = [(element, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 400 {
            let (e, depth) = queue.removeFirst()
            visited += 1
            if let st = starts[ElementKey(e)] { best = best.map { min($0, st) } ?? st; continue }   // nothing under a segment is needed
            guard depth < 8 else { continue }
            for c in e.elements(kAXChildrenAttribute) { queue.append((c, depth + 1)) }
        }
        return best
    }
}

/// A TextInfo over the buffer: offsets in its text; lines from its table; the element behind any offset.
public final class BufferTextInfo: TextInfo {
    // The page's buffer; an empty one if the browse document has gone meanwhile (a say all outliving its page), so
    // nothing reads rather than a crash.
    var buffer: WebBuffer { (obj as? WebArea)?.document?.buffer ?? WebBuffer(webArea: obj.element) }
    public var previousChain: [AXUIElement]?
    public private(set) var chain: [AXUIElement] = []

    public override func storyLength() -> Int { buffer.text.length }
    public override func characterOffsets(_ offset: Int) -> (Int, Int) {
        CharacterBoundaries.offsets(in: buffer.text, at: offset) ?? (offset, offset)
    }
    public override func textRange(_ s: Int, _ e: Int) -> String {
        let n = buffer.text.length
        let a = max(0, min(s, n)), b = max(a, min(e, n))
        return buffer.text.substring(with: NSRange(location: a, length: b - a))
    }
    public override func caretOffset() -> Int? { (obj as? WebArea)?.document?.position }
    public override func selectionOffsets() -> (Int, Int)? { caretOffset().map { ($0, $0) } }
    public override func setCaretOffset(_ o: Int) { (obj as? WebArea)?.document?.position = o }
    public override func lineOffsets(_ offset: Int) -> (Int, Int)? {
        guard let i = buffer.lineIndex(at: offset) else { return nil }
        let l = buffer.lines[i]
        return (l.start, l.endWithBreak)
    }
    public override func paragraphOffsets(_ offset: Int) -> (Int, Int) { lineOffsets(offset) ?? characterOffsets(offset) }
    /// Say all reads a line at a time, as NVDA does; a long paragraph is wrapped into 100-character lines. Kokoro says
    /// each piece as a whole sentence, so "users of" ended like a full stop (12 Oct 2026: "the say all went a
    /// bit weird"). For Kokoro the pieces of one wrapped line are read together, up to about 600 characters.
    public override func readingChunkOffsets(_ offset: Int) -> (Int, Int) {
        guard KokoroVoice.wanted(reading: true), var i = buffer.lineIndex(at: offset) else { return paragraphOffsets(offset) }
        let start = buffer.lines[i].start
        while !buffer.lines[i].hasBreak, i + 1 < buffer.lines.count, buffer.lines[i + 1].start == buffer.lines[i].end,
              buffer.lines[i + 1].end - start <= 600 { i += 1 }
        return (start, buffer.lines[i].endWithBreak)
    }
    public override func sentenceOffsets(_ offset: Int) -> (Int, Int) {
        guard let (ls, le) = lineOffsets(offset) else { return characterOffsets(offset) }
        let line = textRange(ls, le) as NSString
        var found: (Int, Int)?
        let local = offset - ls
        line.enumerateSubstrings(in: NSRange(location: 0, length: line.length), options: [.bySentences, .substringNotRequired]) { _, r, _, stop in
            if NSLocationInRange(local, r) || r.location > local { found = (ls + r.location, ls + r.location + r.length); stop.pointee = true }
        }
        return found ?? (ls, le)
    }
    public override func formatField(at offset: Int) -> FormatField? {
        var f = FormatField()
        if let s = buffer.segment(at: offset), s.isLink { f.link = true }
        return f
    }
    /// WebKit puts the lang attribute on each element (AXLanguage), not in the text's attributes (measured 6 Oct 2026).
    public override func language(at offset: Int) -> String? { element(at: offset)?.string("AXLanguage") }
    public func element(at offset: Int) -> AXUIElement? {
        buffer.segment(at: offset)?.element ?? buffer.lineIndex(at: offset).flatMap { buffer.lines[$0].element }
    }

    /// The quote level last said, so it is said only when it changes.
    static var lastQuoteLevel = 0

    public override func controlFieldSpeech() -> (prefix: [String], text: String?) {
        pendingTones.removeAll()
        guard let i = buffer.lineIndex(at: start) else { return ([], nil) }
        let line = buffer.lines[i]
        var prefix: [String] = []
        // Containers entered by any line inside the range (a heading's line carries "heading level 2").
        var entering: [AXUIElement] = []
        var j = i
        while j < buffer.lines.count, buffer.lines[j].start < end { entering.append(contentsOf: buffer.lines[j].entering); j += 1 }
        chain = entering
        for el in entering {
            if let prev = previousChain, prev.contains(where: { $0.isSame(el) }) { continue }
            let (mode, tone) = WebTextInfo.reporting(for: el)
            switch mode {
            case .off: continue
            case .tone: if let tone { pendingTones.append(tone) }
            case .speech: if let s = WebTextInfo.describe(el, forEntering: true), prefix.last != s { prefix.append(s) }
            }
        }
        // Quote levels (Mail's quoted replies): WebKit gives each piece of text its level, AXBlockQuoteLevel, which is
        // what VoiceOver reads; Mail's quotes carry no container TurnOver could see (a tester, 7 Oct 2026: none said).
        // Said as the level changes, as VoiceOver does.
        if let lvl = (element(at: start)?.attr("AXBlockQuoteLevel") as? NSNumber)?.intValue, lvl != Self.lastQuoteLevel {
            if lvl > 0 {
                switch config.documentFormatting.blockQuotes {
                case .speech: prefix.append("quote level \(lvl)")
                case .tone: pendingTones.append { Tones.blockQuote() }
                case .off: break
                }
            }
            Self.lastQuoteLevel = lvl
        }
        if line.isControl {
            // "button Create", then its states and value (NVDA's control field, role first).
            let role = line.fields.first.map { [$0] } ?? []
            let rest = Array(line.fields.dropFirst())
            let name = textRange(start, end).trimmingCharacters(in: .whitespacesAndNewlines)
            // VoiceOver's order: "Create, button", then its states.
            if config.documentFormatting.rolesAfterText {
                return (prefix, ([name] + role.map { Speech.ui($0) } + rest).filter { !$0.isEmpty }.joined(separator: ", "))
            }
            return (prefix + role, (name + (rest.isEmpty ? "" : ", " + rest.joined(separator: ", "))))
        }
        // Links inline.
        let linkMode = config.documentFormatting.links
        var pieces: [String] = []
        var lastLink: AXUIElement?
        var cursor = start
        for s in buffer.segments where s.end > start && s.start < end {
            if s.start > cursor { pieces.append(textRange(cursor, s.start)) }
            let a = max(s.start, start), b = min(s.end, end)
            // A word or character inside a link that began before it (reading "about us" word by word): the link was
            // said on its first word, not again on each (a tester, 7 Oct 2026). A line that starts part way through a
            // link still says it.
            let insideEarlierLink = s.start < start && start > line.start
            let after = config.documentFormatting.rolesAfterText
            if s.isLink, !insideEarlierLink, lastLink.map({ !$0.isSame(s.element) }) ?? true {
                switch linkMode {
                case .speech: if !after { pieces.append(" " + Speech.ui("link") + " ") }
                case .tone: pendingTones.append { Tones.link() }
                case .off: break
                }
            }
            lastLink = s.isLink ? s.element : nil
            pieces.append(textRange(a, b))
            // VoiceOver's order: "About us, link", where the link ends (once, on the piece that ends it).
            if after, s.isLink, linkMode == .speech, s.end <= end, !(s.start < start && start > line.start && s.end > end) {
                pieces.append(", " + Speech.ui("link") + " ")
            }
            cursor = b
        }
        if cursor < end { pieces.append(textRange(cursor, end)) }
        return (prefix, pieces.joined().replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces))
    }
}
