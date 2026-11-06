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
    /// A complete publication: text and offsets always belong to the same collection.
    private struct Snapshot {
        let text: NSString
        let lines: [Line]
        let segments: [Segment]
        let containers: [(start: Int, end: Int, element: AXUIElement)]
        let accessibility: AXSnapshot
    }
    private var snapshot = Snapshot(text: "", lines: [], segments: [], containers: [], accessibility: AXSnapshot(nodes: [:]))
    public var text: NSString { snapshot.text }
    public var lines: [Line] { snapshot.lines }
    public var segments: [Segment] { snapshot.segments }
    public var containers: [(start: Int, end: Int, element: AXUIElement)] { snapshot.containers }
    public private(set) var builtAt = Date.distantPast
    public var isDirty = true { didSet { if isDirty { dirtyRevision += 1 } } }
    private var dirtyRevision = 0
    private var collectingDirtyRevision = 0
    public private(set) var lastBuildMs = 0
    public enum Status: Equatable { case idle, loading, complete, partial, unavailable, cancelled }
    public private(set) var status: Status = .idle
    public var isLoading: Bool { status == .loading }
    public var isPartial: Bool { lastStop != nil }
    package private(set) var lastStop: AXWalkStop?
    private lazy var runner = AXWalkRunner<WebBufferCollection>()
    private let collect: @Sendable (AXUIElement, AXUIElement?, AXWalkRequest) -> WebBufferCollection
    private var generation = 0
    package private(set) var revision = 0
    private var pendingCompletion: (() -> Void)?
    /// Both hooks run on main, immediately around the atomic replacement. The owner anchors the *current*
    /// caret here, rather than restoring a position captured before the user continued reading.
    var willPublish: (() -> Void)?
    var didPublish: (() -> Void)?
    package var didInvalidate: (() -> Void)?
    var didFail: (() -> Void)?
    package var acceptsSnapshot: ((AXSnapshot) -> Bool)?

    public convenience init(webArea: AXUIElement) {
        self.init(webArea: webArea, collect: WebBufferCollection.collect)
    }
    package init(webArea: AXUIElement, collect: @escaping @Sendable (AXUIElement, AXUIElement?, AXWalkRequest) -> WebBufferCollection) {
        self.collect = collect
        self.webArea = webArea
        decorativeImages = NSRunningApplication(processIdentifier: webArea.pid)?.bundleIdentifier.map { Self.decorativeImageApps.contains($0) } ?? false
    }
    /// Apps (set by their modules) whose pictures are icons only, left out of the copy.
    public static var decorativeImageApps: Set<String> = []
    private let decorativeImages: Bool
    /// Subroles of an iOS screen's parts left out of its copy (set by app modules).
    public static var iosSkippedSubroles: Set<String> = []
    /// Identifiers of an iOS screen's parts read before their siblings (set by app modules).
    public static var iosLeadingIdentifiers: Set<String> = []
    /// The root is an iPad app's window content (Kindle), not a page.
    private var iosContent = false

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
    /// A new page in the same web area: the partial-page notice is due again (code review, 16 Oct 2026, item 29).
    public func newPage() {
        cancel()
        revision += 1
        snapshot = Snapshot(text: "", lines: [], segments: [], containers: [], accessibility: AXSnapshot(nodes: [:]))
        lastStop = nil; builtAt = .distantPast; isDirty = true; status = .idle
    }

    public func cancel() {
        generation += 1; runner.cancel(); pendingCompletion = nil; status = .cancelled
    }

    /// Coalesce refreshes while a collection is in flight. A page change calls newPage first, cancelling the
    /// old generation. Keeping the previous snapshot makes arrows usable during a same-page refresh.
    public func build(scrollTo: AXUIElement? = nil, completion: (() -> Void)? = nil) {
        // Only the latest deferred action survives a burst of keys; reading commands already answered from
        // the previous snapshot continue immediately. Do not replay a queue of old navigation on completion.
        if let completion { pendingCompletion = completion }
        guard !isLoading else { return }
        status = .loading
        collectingDirtyRevision = dirtyRevision
        let current = generation
        let root = webArea
        let focus = API.focusObject?.element
        let collector = collect
        runner.submit(collect: { request in
            if let scrollTo, !request.isCancelled { _ = AXUIElementPerformAction(scrollTo, "AXScrollToVisible" as CFString) }
            return collector(root, focus, request)
        }, publish: { [weak self] result in
            guard let self, generation == current else { return }
            publish(result)
        })
    }

    /// Explicit synchronous path for the command-line plugin inspector and recorded-tree layout tests.
    /// Interactive reader callers must use build(completion:).
    package func buildForInspection() {
        publish(WebBufferCollection.collect(root: webArea, focus: API.focusObject?.element, request: AXWalkRequest()))
    }
    private var docText = "" as NSString
    private var docCursor = 0
    private var lastTextEnd: Int?

    private func publish(_ collection: WebBufferCollection) {
        if collection.navigationChanged || acceptsSnapshot?(collection.snapshot) == false {
            newPage()
            didInvalidate?()
            return
        }
        let t0 = Date()
        collection.snapshot.with {
            out = ""; outLength = 0; current = []; currentElement = nil; pendingEntering = []; containerStack = []; linkDepth = 0
            newLines = []; newSegments = []; newContainers = []; visited = 0
            // This deadline bounds local interpretation, not a provider wait. Every AX convenience read is served
            // from the immutable collection, including those made by existing object and app presentation rules.
            buildDeadline = Date().addingTimeInterval(0.1)
            iosContent = webArea.string(kAXSubroleAttribute) == "iOSContentGroup"
            profiled = !ProfileStore.shared.profiles(for: ProfileStore.shared.bundle(of: webArea.pid)).isEmpty
            consumed = []
            docText = collection.documentText as NSString
            docCursor = 0; lastTextEnd = nil
            visit(webArea, depth: 0)
            flush()
            if newLines.isEmpty, let dialog = collection.focusedPart {
                visit(dialog, depth: 1); flush()
            }
        }
        lastStop = collection.stop ?? (Date() >= buildDeadline ? .deadline : nil)
        let retained = lastStop != nil && newLines.isEmpty && !snapshot.lines.isEmpty
        if retained {
            // A transient provider failure is not an empty new document. Keep the last valid publication and
            // its caret/ranges available, while marking the refresh incomplete and leaving it due for retry.
            isDirty = true
        } else {
            willPublish?()
            revision += 1
            snapshot = Snapshot(text: out as NSString, lines: newLines, segments: newSegments, containers: newContainers, accessibility: collection.snapshot)
            builtAt = Date(); isDirty = dirtyRevision != collectingDirtyRevision
        }
        status = lastStop == nil ? .complete : (lines.isEmpty ? .unavailable : .partial)
        lastBuildMs = collection.elapsedMs + Int(Date().timeIntervalSince(t0) * 1000)
        Log.info("virtual buffer: \(lines.count) lines, \(text.length) characters from \(visited) elements in \(lastBuildMs) ms (\(status)\(lastStop.map { ": " + $0.rawValue } ?? ""))")
        let ready = pendingCompletion; pendingCompletion = nil
        if retained { didFail?() } else { didPublish?() }
        ready?()
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
            flush(); currentElement = el; append(Role.separator.displayString, el); flush()
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
            if !d.isEmpty || linkDepth == 0 { append(d.isEmpty ? Role.graphic.displayString : "\(Role.graphic.displayString) \(d)", el) }
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
        case "AXProgressIndicator" where el.elements(kAXChildrenAttribute).isEmpty:
            // A line of its own, read as a control is ("Test progress, progress bar, 40 percent"): it had no text, so a
            // page's bar was missing from browse mode and could never be followed (2 Nov 2026). Not through
            // objectPropertiesSpeech, which starts following a bar: making the page isn't reading it. (A bar with
            // text inside, an ARIA one, is read by its text, as before.)
            flush()
            let obj = ObjectFactory.make(el)
            let label = obj.name.isEmpty ? (obj.value ?? obj.role.displayString) : obj.name
            currentElement = el
            current.append((label, el, false))
            flush(control: true, fields: [obj.role.displayString, obj.value].compactMap { $0 }.filter { $0 != label })
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

    private init(copying source: WebBuffer) {
        webArea = source.webArea; collect = source.collect; decorativeImages = source.decorativeImages
        snapshot = source.snapshot; revision = source.revision; lastStop = source.lastStop
        builtAt = source.builtAt; status = source.status; isDirty = source.isDirty; lastBuildMs = source.lastBuildMs
    }
    /// Text ranges retain the publication their offsets describe, including copies queued for speech.
    package func frozen() -> WebBuffer { WebBuffer(copying: self) }

    package func withSnapshot<Value>(_ body: () -> Value) -> Value { snapshot.accessibility.with(body) }

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
        snapshot.accessibility.with { Self.findText(lines: lines, segments: segments, text: text, from: offset, forward: forward, kind: kind) }
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
        snapshot.accessibility.with { findInSnapshot(from: offset, forward: forward, roles: roles, headingLevel: headingLevel) }
    }
    private func findInSnapshot(from offset: Int, forward: Bool, roles: Set<String>, headingLevel: Int?) -> (offset: Int, element: AXUIElement)? {
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
        snapshot.accessibility.with { offsetInSnapshot(of: element) }
    }
    private func offsetInSnapshot(of element: AXUIElement) -> Int? {
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
