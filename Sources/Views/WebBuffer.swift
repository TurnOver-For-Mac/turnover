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
import os

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
    public var isDirty = true { didSet { if isDirty { markedDirty() } } }
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
    /// The elements one pass reads (a test sets it lower).
    nonisolated(unsafe) package static var maxElements = 6000
    /// How long one read may take on the main thread, its passes together (a test sets it lower).
    nonisolated(unsafe) package static var buildSeconds: TimeInterval = 2
    /// The passes one `build` may make to get back to the reader (a test sets it lower).
    nonisolated(unsafe) package static var passesPerBuild = 50
    private var buildDeadline = Date.distantFuture
    /// The last read stopped at its time or element limit: the end of a very long page is missing.
    public private(set) var isPartial = false
    private var saidPartial = false
    private var loggedPartial = false
    /// A new page in the same web area: the partial-page notice is due again (code review, 16 Oct 2026, item 29),
    /// and the reading position was in the page before.
    public func newPage() {
        saidPartial = false; loggedPartial = false; readingAt = 0; samePage = false
        dirtyAt = Date(); prefetched = nil; prefetchGeneration.withLock { $0 += 1 }
    }
    /// The copy is of the page the web area shows (no new page since it was read): one read again may keep it.
    private var samePage = false
    private var docText = "" as NSString
    private var docCursor = 0
    private var lastTextEnd: Int?

    // MARK: Reading on (issue 227)
    // A long chat in the ChatGPT app is more than one pass's 6,000 elements. Read again from the top, the same first
    // part came back and its end was never reached (eleganckidenis, 7 Nov 2026). So the walk keeps the containers it
    // is inside; where a pass stops at a limit, the next one starts, and its text goes on the end of the copy.

    /// A container the walk is inside: its children, the one reached, and what its close still owes.
    struct Frame {
        let element: AXUIElement
        let role: String
        var kids: [AXUIElement]
        /// The child being read; at a stop, the first one not read.
        var next = 0
        let depth: Int
        let isLink: Bool
        /// A link on a line of its own (screen layout off).
        let ownLine: Bool
        let isBlock: Bool
        let announced: Bool
        let eachOnALine: Bool
        /// Where its text starts in the copy: an announced container's span.
        let start: Int
        /// A link that adds no text is read by its title: what the line being built had when it opened (as always),
        /// and, for one a pass stopped inside, the pieces with words the copy had.
        let countAtOpen: Int
        let textPiecesAtOpen: Int
        /// Opened again by reading on: its span may be in the copy already, and is lengthened rather than added.
        var resumed = false
    }
    /// Where a pass stopped: the copy's length and counts then, and the walk's state, so the copy can be cut back to
    /// it and read again from there (the reader's part of a long page, when the page is read again).
    private struct Checkpoint {
        let offset: Int, lineCount: Int, segmentCount: Int
        let frames: [Frame], element: AXUIElement?, pending: [AXUIElement]
        let textPieces: Int, passes: Int, docCursor: Int, lastTextEnd: Int?
    }
    /// Every place a pass of this copy stopped, in order.
    private var checkpoints: [Checkpoint] = []
    /// The containers the walk is inside, outermost first.
    private var frames: [Frame] = []
    /// Where reading on starts: the containers a pass stopped inside (the deepest one's `next` is the first child not
    /// read), or, for a page read to its end, its last element at each level.
    private var resumeFrames: [Frame] = []
    /// The pass stopped at a limit.
    private var stopped = false
    /// At the stop: the element of the line being built, and the containers waiting to be announced by the next line
    /// (none if a line was being built: it took them as it was ended).
    private var resumeElement: AXUIElement?
    private var resumePending: [AXUIElement] = []
    /// The frame closed last and, inside it, the frames closed at its end: where a page read to its end ends.
    private var edgeChain: [Frame] = []
    /// Pieces of text with words in them added to this copy, ever.
    private var textPieces = 0
    /// The passes this copy took: more than one, it was read on past a limit.
    public private(set) var passes = 1
    /// Where the reader is (the browse mode document's position): a read of the page again goes this far.
    public var readingAt = 0
    /// There is somewhere to read on from (after a stop, or the end of a page read whole).
    public var canReadOn: Bool { !resumeFrames.isEmpty }

    // MARK: From a snapshot (trial, 10 Nov 2026)
    // The walk below asks each element several questions, one at a time: 0.24 ms an element over 9,716 builds in
    // Oliver's logs. With this on, the page is first copied with one batched question an element (AXSnapshot), and
    // the walk's questions are then answered from that copy (AXAttributeCache): the walk and its rules are untouched,
    // so the lines are the same. Measured the same day, the text identical: Safari, 349 elements, 55 ms to 22;
    // Claude (Electron), 462 elements, 77 ms to 58. What the copy does not hold is asked for as before.

    /// `defaults write com.turnover.reader bufferSnapshot -bool false` reads pages as they were read until build 24.
    /// A test sets `snapshotOverride`.
    nonisolated static var usesSnapshot: Bool { snapshotOverride ?? (UserDefaults.standard.object(forKey: "bufferSnapshot") as? Bool ?? true) }
    nonisolated(unsafe) package static var snapshotOverride: Bool?   // tests only, set and read on the main thread
    /// What the walk asks of most elements, by count over Safari and Claude pages (turnover-coretest --buffer).
    nonisolated package static let snapshotNames: [String] = [
        kAXChildrenAttribute, kAXRoleAttribute, kAXSubroleAttribute, kAXValueAttribute, kAXTitleAttribute, kAXParentAttribute,
        kAXFocusedAttribute, kAXDescriptionAttribute, kAXSelectedAttribute, "AXInvalid", kAXModalAttribute, kAXEnabledAttribute,
        kAXDisclosingAttribute, "AXRequired", kAXMenuItemMarkCharAttribute, kAXMenuItemCmdCharAttribute]
    /// The build under way began here, before its snapshot: the snapshot's time counts against the two seconds.
    private var buildStart: Date?
    private var snapshotLog = ""
    /// Questions the last build's snapshot answered, and those the walk still asked of the app (0 and 0 without one).
    public private(set) var lastSnapshotUse: (answered: Int, asked: Int) = (0, 0)

    // MARK: The snapshot taken ahead, in the background (trial, 10 Nov 2026)
    // Of a build from a snapshot, the snapshot is most of the time: 72 of 83 ms over the 19 builds of Oliver's first
    // trial, and all of it on the main thread, where keys wait. But a page is read again because it said it changed,
    // and the key that asks for the reading comes later. So when a page is marked changed, it is copied in the
    // background, and the build that follows uses that copy if the page has not been marked changed again since the
    // copy began. Only the walk over the copy, about 11 ms in that trial, is then on the main thread. With no such
    // copy to hand (a page's first reading, a refresh asked for by key, a change while it was being copied), the
    // snapshot is taken on the main thread, as before.

    /// `defaults write com.turnover.reader bufferSnapshotAhead -bool false` takes every snapshot on the main thread.
    nonisolated static var takesSnapshotAhead: Bool { aheadOverride ?? (UserDefaults.standard.object(forKey: "bufferSnapshotAhead") as? Bool ?? true) }
    nonisolated(unsafe) package static var aheadOverride: Bool?   // tests only, set and read on the main thread
    /// When the page was last marked changed.
    private var dirtyAt = Date.distantPast
    private var prefetched: (snapshot: AXSnapshot, startedAt: Date)?
    private var prefetchWork: DispatchWorkItem?
    private var lastPrefetchStart = Date.distantPast
    private var lastPrefetchMs = 0.0
    /// Counts the marks: a copy begun for an earlier one stops asking (AXReadScope) and is not kept.
    private let prefetchGeneration = OSAllocatedUnfairLock(initialState: 0)
    nonisolated private static let prefetchQueue = DispatchQueue(label: "turnover.buffer-snapshot", qos: .userInitiated)
    /// The last build's snapshot was one taken ahead.
    public private(set) var lastSnapshotWasAhead = false

    /// How a copy begun at `startedAt` may be used. `.current`: nothing has marked the page changed since it began, so
    /// it stands for the page as it is. `.recent`: the page was marked again, but the copy is under `recentSeconds`
    /// old; it is read from, and the page stays marked changed, as it is when a notice comes just after a reading.
    /// (The arrows already leave a changed page a second before reading it again: the same tolerance.) A page that
    /// keeps saying it has changed, a reply streaming into a chat, otherwise never has a current copy: in Oliver's
    /// trial in Claude one build in eight had one (10 Nov 2026).
    package enum AheadUse: Equatable { case current, recent, none }
    nonisolated static let recentSeconds = 1.5
    nonisolated package static func aheadUse(startedAt: Date, dirtyAt: Date, now: Date, mustBeCurrent: Bool = false) -> AheadUse {
        let age = now.timeIntervalSince(startedAt)
        if startedAt >= dirtyAt, age < 30 { return .current }   // (an app that never says it changed is not trusted for longer)
        return !mustBeCurrent && age < recentSeconds ? .recent : .none
    }

    private var copyInFlight = false
    /// Why the last build had no copy to use, for the log.
    private var aheadNote = ""

    private func markedDirty() {
        dirtyAt = Date()
        scheduleCopyAhead()
    }

    /// One copy at a time, begun a moment after the page settles and never back to back: a copy asks the app a question
    /// an element (92 ms of Claude's time for 600), so the next begins a second after the last at the earliest, six
    /// times its length for a long one. Only for the page being read, and only while its reader is at the keys.
    private func scheduleCopyAhead() {
        guard Self.usesSnapshot, Self.takesSnapshotAhead, prefetchWork == nil, !copyInFlight else { return }
        let earliest = lastPrefetchStart.addingTimeInterval(max(1.0, lastPrefetchMs / 1000 * 6))
        let work = DispatchWorkItem { [weak self] in self?.startPrefetch() }
        prefetchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.15, earliest.timeIntervalSinceNow), execute: work)
    }

    private func startPrefetch() {
        prefetchWork = nil
        guard isDirty, API.focusTreeInterceptor?.buffer === self, Date().timeIntervalSince(InputManager.lastKeyDownAt) < 30 else { return }
        let started = Date()
        lastPrefetchStart = started
        copyInFlight = true
        let counter = prefetchGeneration, generation = counter.withLock { $0 }
        let area = webArea, limit = Self.maxElements
        Self.prefetchQueue.async { [weak self] in
            let snapshot = AXReadScope.with(while: { counter.withLock { $0 } == generation }) {
                AXSnapshotCapture.capture(area, limits: AXSnapshotLimits(maxNodes: limit, maxDepth: 60, seconds: 0.8), names: Self.snapshotNames)
            }
            onMain { self?.prefetchArrived(snapshot, startedAt: started, generation: generation) }
        }
    }

    private func prefetchArrived(_ snapshot: AXSnapshot, startedAt: Date, generation: Int) {
        copyInFlight = false
        lastPrefetchMs = snapshot.milliseconds
        // For a page since replaced or refreshed, or the app is resting: no copy. One cut short by its limits is a copy.
        guard prefetchGeneration.withLock({ $0 }) == generation, !snapshot.nodes.isEmpty,
              snapshot.stop != .clientStopped, snapshot.stop != .appResting else { return }
        prefetched = (snapshot, startedAt)
        // Marked again while it was being taken: another, in its turn.
        if dirtyAt > startedAt { scheduleCopyAhead() }
    }

    /// Asked for by key (NVDA+F5, a change of layout): the page as it is this moment, never a copy from before.
    public func buildAfresh() {
        prefetched = nil
        prefetchGeneration.withLock { $0 += 1 }
        mustBeCurrent = true
        isDirty = true
        build()
    }
    private var mustBeCurrent = false

    /// For tests: the copy taken ahead, here and now, as the background would have.
    package func takeSnapshotAheadNow() {
        let started = Date()
        prefetched = (AXSnapshotCapture.capture(webArea, limits: AXSnapshotLimits(maxNodes: Self.maxElements, maxDepth: 60, seconds: 0.8),
                                                names: Self.snapshotNames), started)
    }

    /// Reads the page into the copy, in at most two seconds, done by `deadline` at the latest.
    public func build(until deadline: Date = .distantFuture) {
        guard Self.usesSnapshot else { snapshotLog = ""; lastSnapshotUse = (0, 0); lastSnapshotWasAhead = false; mustBeCurrent = false; prefetched = nil; buildByAsking(until: deadline); return }
        let t0 = Date()
        // At most two fifths of the time the build has, and never more than 0.8 s: a page that long is finished by
        // the walk asking for the rest itself, within the same two seconds.
        let ahead = prefetched
        prefetched = nil
        let use: AheadUse = !Self.takesSnapshotAhead ? .none
            : ahead.map { Self.aheadUse(startedAt: $0.startedAt, dirtyAt: dirtyAt, now: t0, mustBeCurrent: mustBeCurrent) } ?? .none
        mustBeCurrent = false
        let snapshot: AXSnapshot
        if use != .none, let ahead {
            snapshot = ahead.snapshot
            lastSnapshotWasAhead = true
        } else {
            let allowed = min(Self.buildSeconds, max(0, deadline.timeIntervalSince(t0)))
            snapshot = AXSnapshotCapture.capture(webArea, limits: AXSnapshotLimits(maxNodes: Self.maxElements, maxDepth: 60, seconds: min(0.8, allowed * 0.4)),
                                                 names: Self.snapshotNames)
            lastSnapshotWasAhead = false
        }
        buildStart = t0
        let answers = AXAttributeCache.with(snapshot) { buildByAsking(until: deadline) }.use
        lastSnapshotUse = (answers.hits, answers.misses)
        let age = ahead.map { Int(t0.timeIntervalSince($0.startedAt) * 1000) }
        let how: String
        switch use {
        case .current: how = "taken ahead in the background, \(age ?? 0) ms before"
        case .recent: how = "taken ahead in the background, \(age ?? 0) ms before, the page marked changed since"
        case .none: how = "taken now (\(!Self.takesSnapshotAhead ? "copies ahead are off" : age.map { "the copy to hand was \($0) ms old and the page marked changed since" } ?? (copyInFlight ? "a copy was still being taken" : "no copy to hand")))"
        }
        Log.info("virtual buffer: from a snapshot of \(snapshot.nodes.count) elements in \(Int(snapshot.milliseconds)) ms, \(how)\(snapshot.stop.map { " (stopped: \($0.rawValue))" } ?? ""); it answered \(answers.hits) questions, \(answers.misses) were asked")
        // Read from a copy the page has been marked changed since: it is still changed, and says so, which also
        // sets the next copy going.
        if use == .recent { isDirty = true }
    }

    private func buildByAsking(until deadline: Date) {
        let t0 = buildStart ?? Date()
        buildStart = nil
        // The copy being replaced, kept if this read is cut short and is the same as far as it goes (below).
        let old = saved(), wasDirty = isDirty
        out = ""; outLength = 0; current = []; currentElement = nil; pendingEntering = []; containerStack = []; linkDepth = 0
        newLines = []; newSegments = []; newContainers = []; visited = 0
        frames = []; resumeFrames = []; stopped = false; resumeElement = nil; resumePending = []; edgeChain = []; textPieces = 0; passes = 1
        checkpoints = []
        // At most 2 s on the main thread (the watchdog trips at 4): a huge page is read only in part, rather than
        // TurnOver freezing (E6 audit, 4 Oct 2026). Reading such a page off the main thread is the full answer.
        buildDeadline = min(t0.addingTimeInterval(Self.buildSeconds), deadline)
        let budget = buildDeadline
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
        if newLines.isEmpty, !stopped, let dialog = focusedPartOfPage() {
            Log.info("virtual buffer: the web area gave nothing; reading the focused element's part of the page (\(dialog.role))")
            visit(dialog, depth: 1)
            flush()
        }
        endPass()
        elementCount = visited
        // The same page, cut short by a limit and the same as far as it went, while the copy it replaces went further
        // and the reader is past what was read (a long chat read on, issue 227), or nothing was read at all (a page
        // that has stopped answering): the copy is kept as far as the reader's part, and that is read again
        // (keptOrReadAgain). With the reader within what was read, it is the new copy, and the rest is read on fresh.
        if stopped, samePage, outLength < old.text.length, (out as NSString).isEqual(to: old.text.substring(to: outLength)),
           outLength == 0 || readingAt >= outLength {
            keptOrReadAgain(old, wasDirty: wasDirty, deadline: budget, since: t0)
            return
        }
        // Read on, within the same two seconds, as far as the reader had read: a changed page longer than one pass keeps
        // the reader's place, rather than putting them back at the end of its first part.
        let wanted = min(readingAt + 2000, old.text.length)
        var more = 1
        while stopped, outLength <= wanted, Date() < budget, more < Self.passesPerBuild, readOn(deadline: budget) { more += 1 }
        publish()
        samePage = true
        builtAt = Date()
        isDirty = false
        // Said once per page: nothing read the flag, so K said "no next link" and "bottom" mid-page without a word
        // (a code review, 14 Oct 2026).
        if isPartial, !saidPartial { saidPartial = true; DispatchQueue.main.async { MainActor.assumeIsolated { Speech.speakMessage(String(localized: "page read in part, it is very long", comment: "Spoken message")) } } }
        if isPartial, !loggedPartial { loggedPartial = true; Log.error("virtual buffer: stopped at \(visited >= Self.maxElements ? "\(Self.maxElements) elements" : "the time limit, \(visited) elements"); the page is read only in part, and is read on at its end") }
        lastBuildMs = Int(Date().timeIntervalSince(t0) * 1000)
        Log.info("virtual buffer: \(lines.count) lines, \(text.length) characters from \(elementCount) elements in \(lastBuildMs) ms\(passes > 1 ? " (\(passes) passes)" : "")")
    }

    /// A read of the page again that was cut short, the same as far as it went, with the reader past it (`build`): the
    /// copy is kept up to the place before the reader where one of its passes stopped, and read again from there, on
    /// past the reader. What it had after that is let go, and is read on fresh as the reader gets there, so nothing
    /// is kept that wasn't read again past the reader's part (a reply added or changed, an end taken away). A read
    /// that got nothing, or had no time left for the reader's part, keeps the copy as it was.
    private func keptOrReadAgain(_ old: Copy, wasDirty: Bool, deadline: Date, since t0: Date) {
        let reread = outLength
        restore(old)
        var how = "nothing read; the copy kept"
        var sure = false
        if reread > 0 {
            if let k = checkpoints.lastIndex(where: { $0.offset >= reread && $0.offset <= readingAt }) {
                let from = checkpoints[k].offset
                truncate(to: k)
                var more = 0
                while stopped, outLength <= readingAt + 2000, Date() < deadline, more < Self.passesPerBuild, readOn(deadline: deadline) { more += 1 }
                if !stopped || outLength > readingAt {
                    publish()
                    sure = true
                    let same = outLength <= old.text.length
                        && (out as NSString).substring(from: from) == old.text.substring(with: NSRange(location: from, length: outLength - from))
                    how = "the reader's part read again from \(from), where a pass had stopped, \(same ? "the same" : "changed")\(stopped ? "; the rest to read on" : ", to the end")"
                } else {
                    restore(old)
                    how = "out of time before the reader's part; the copy kept"
                }
            } else {
                how = "short of the reader, with no stop of its own before them; the copy kept"
            }
        }
        samePage = true
        builtAt = Date()
        // Taken as read only once the reader's part has been read again; a read cut short leaves the page as changed as
        // it was.
        isDirty = sure ? false : wasDirty
        lastBuildMs = Int(Date().timeIntervalSince(t0) * 1000)
        Log.info("virtual buffer: read again to \(reread) of the \(old.text.length) characters it had, in \(lastBuildMs) ms: \(how)")
    }

    /// The end of a pass: after a stop, a place to read again from; after a whole read, its end to read on from.
    private func endPass() {
        if stopped {
            checkpoints.append(Checkpoint(offset: outLength, lineCount: newLines.count, segmentCount: newSegments.count,
                                          frames: resumeFrames, element: resumeElement, pending: resumePending,
                                          textPieces: textPieces, passes: passes, docCursor: docCursor, lastTextEnd: lastTextEnd))
        } else {
            resumeFrames = edgeChain
        }
    }

    /// The copy cut back to where pass `k` stopped, and the walk as it was there, to be read on again from it.
    private func truncate(to k: Int) {
        let cp = checkpoints[k]
        out = (out as NSString).substring(to: cp.offset)
        outLength = cp.offset
        newLines.removeLast(max(0, newLines.count - cp.lineCount))
        newSegments.removeLast(max(0, newSegments.count - cp.segmentCount))
        // A container open there ended there; one begun after it is gone.
        newContainers = newContainers.compactMap { c in c.start < cp.offset ? (start: c.start, end: min(c.end, cp.offset), element: c.element) : nil }
        resumeFrames = cp.frames; stopped = true; resumeElement = cp.element; resumePending = cp.pending
        textPieces = cp.textPieces; passes = cp.passes; docCursor = cp.docCursor; lastTextEnd = cp.lastTextEnd
        checkpoints.removeLast(checkpoints.count - k - 1)
        edgeChain = []
    }

    /// Reads on from where the copy ends: after a read that stopped at a limit (a long chat), from the first element
    /// not read, with fresh limits; after a page read to its end, what has come after its last element since (a reply
    /// added to a chat). The text goes on the end of the copy, so every offset before it stays as it was. One pass,
    /// done by `deadline` at the latest. False if nothing was added.
    @discardableResult
    public func buildMore(until deadline: Date = .distantFuture) -> Bool {
        guard !resumeFrames.isEmpty else { return false }
        let t0 = Date(), wasStopped = stopped, linesBefore = newLines.count, lengthBefore = outLength
        let more = readOn(deadline: deadline)
        publish()
        if more || wasStopped {
            Log.info("virtual buffer: read on from \(wasStopped ? "where it stopped" : "its end"): \(newLines.count - linesBefore) lines, \(outLength - lengthBefore) characters from \(visited) elements in \(Int(Date().timeIntervalSince(t0) * 1000)) ms\(stopped ? "; stopped again at a limit" : "; to the end")")
        }
        return more
    }

    /// The copy as published.
    private func publish() {
        text = out as NSString
        lines = newLines
        segments = newSegments
        containers = newContainers
        isPartial = stopped
    }

    /// One pass from `resumeFrames`, added to the copy (not yet published). Whether it added text.
    private func readOn(deadline: Date) -> Bool {
        let chain = resumeFrames
        guard !chain.isEmpty else { return false }
        let wasStopped = stopped
        let before = outLength
        visited = 0
        buildDeadline = min(Date().addingTimeInterval(Self.buildSeconds), deadline)
        stopped = false; edgeChain = []
        frames = reopened(chain, stopped: wasStopped)
        // Inside the containers as the walk was when it stopped: the next line's element, and the announcements still
        // owed (the rest were said where their containers began).
        current = []
        currentElement = wasStopped ? resumeElement : nil
        pendingEntering = wasStopped ? resumePending : []
        containerStack = frames.filter(\.announced).map(\.element)
        linkDepth = frames.filter(\.isLink).count
        // The deepest first: from the child not read (after a stop) or after its last; then each container around it,
        // from the child after the one it was in.
        var deepest = true
        while !frames.isEmpty {
            let f = frames.count - 1
            if !(deepest && wasStopped) { frames[f].next += 1 }
            deepest = false
            readChildren(of: f)
            close(frames.removeLast())
        }
        flush()
        if outLength > before { passes += 1 }
        endPass()
        elementCount += visited
        return outLength > before
    }

    /// The frames to read on from, with their children asked for again (a chat adds replies at its end). The child
    /// each was at is found among them; one gone from the page leaves the children as they were read.
    private func reopened(_ chain: [Frame], stopped wasStopped: Bool) -> [Frame] {
        chain.map { saved in
            var f = saved
            f.resumed = true
            // The child it was at: the one not read (a stop's deepest frame), the one it was inside, or its last.
            let at: AXUIElement? = wasStopped ? (saved.next < saved.kids.count ? saved.kids[saved.next] : nil) : saved.kids.last
            let fresh = childrenToRead(saved.element, role: saved.role)
            if let at, let k = fresh.firstIndex(where: { $0.isSame(at) }) {
                f.kids = fresh; f.next = k
            } else if at == nil {
                f.kids = fresh; f.next = -1   // it had no children when read: every one it has now is after its end
            } else {
                f.next = wasStopped ? saved.next : saved.kids.count - 1
            }
            return f
        }
    }

    /// What a copy is, kept while the page is read again.
    private struct Copy {
        let text: NSString; let lines: [Line]; let segments: [Segment]; let containers: [(start: Int, end: Int, element: AXUIElement)]
        let out: String; let outLength: Int
        let resumeFrames: [Frame]; let stopped: Bool; let resumeElement: AXUIElement?; let resumePending: [AXUIElement]
        let checkpoints: [Checkpoint]
        let passes: Int; let textPieces: Int; let elementCount: Int
        let docText: NSString; let docCursor: Int; let lastTextEnd: Int?
    }
    private func saved() -> Copy {
        Copy(text: text, lines: lines, segments: segments, containers: containers, out: out, outLength: outLength,
             resumeFrames: resumeFrames, stopped: stopped, resumeElement: resumeElement, resumePending: resumePending,
             checkpoints: checkpoints, passes: passes, textPieces: textPieces, elementCount: elementCount,
             docText: docText, docCursor: docCursor, lastTextEnd: lastTextEnd)
    }
    private func restore(_ c: Copy) {
        text = c.text; lines = c.lines; segments = c.segments; containers = c.containers
        out = c.out; outLength = c.outLength
        newLines = c.lines; newSegments = c.segments; newContainers = c.containers
        resumeFrames = c.resumeFrames; stopped = c.stopped; isPartial = c.stopped
        resumeElement = c.resumeElement; resumePending = c.resumePending; checkpoints = c.checkpoints
        passes = c.passes; textPieces = c.textPieces; elementCount = c.elementCount
        docText = c.docText; docCursor = c.docCursor; lastTextEnd = c.lastTextEnd
        frames = []; edgeChain = []; current = []; currentElement = nil; pendingEntering = []; containerStack = []; linkDepth = 0
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
        guard depth < 60 else { return }
        guard visited < Self.maxElements, Date() < buildDeadline else {
            // The first element a limit turns away: the next pass starts here (issue 227), as the walk was.
            if !stopped {
                stopped = true; resumeFrames = frames
                resumeElement = currentElement; resumePending = current.isEmpty ? pendingEntering : []
            }
            return
        }
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
                addPiece(name, el, false)
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
            // Its children, then its title if they gave no text (close).
            read(Frame(element: el, role: role, kids: childrenToRead(el, role: role), depth: depth, isLink: true, ownLine: ownLine,
                       isBlock: false, announced: false, eachOnALine: false, start: outLength, countAtOpen: current.count, textPiecesAtOpen: textPieces))
        case "AXProgressIndicator" where el.elements(kAXChildrenAttribute).isEmpty:
            // A line of its own, read as a control is ("Test progress, progress bar, 40 percent"): it had no text, so a
            // page's bar was missing from browse mode and could never be followed (2 Nov 2026). Not through
            // objectPropertiesSpeech, which starts following a bar: making the page isn't reading it. (A bar with
            // text inside, an ARIA one, is read by its text, as before.)
            flush()
            let obj = ObjectFactory.make(el)
            let label = obj.name.isEmpty ? (obj.value ?? obj.role.displayString) : obj.name
            currentElement = el
            addPiece(label, el, false)
            flush(control: true, fields: [obj.role.displayString, obj.value].compactMap { $0 }.filter { $0 != label })
        case _ where Self.controlRoles.contains(role):
            flush()
            let obj = ObjectFactory.make(el)
            let label = obj.name.isEmpty ? (obj.value ?? "") : obj.name
            let fields = Speech.objectPropertiesSpeech(obj, reason: .focus).filter { $0 != label }
            currentElement = el
            addPiece(label.isEmpty ? obj.role.displayString : label, el, false)
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
            // Each item of a list is a line of its own: Chromium's listbox options are bare texts, and with no line
            // break between them on the page they ran together ("Google DocsExample Doc"; Google Drive's file list).
            read(Frame(element: el, role: role, kids: childrenToRead(el, role: role), depth: depth, isLink: false, ownLine: false,
                       isBlock: block, announced: announced, eachOnALine: role == "AXList" || role == "AXOutline",
                       start: outLength, countAtOpen: current.count, textPiecesAtOpen: textPieces))
        }
    }

    /// The children a container is read by (asked for again when reading on).
    private func childrenToRead(_ el: AXUIElement, role: String) -> [AXUIElement] {
        var kids = el.elements(kAXChildrenAttribute)
        guard role != "AXLink" else { return kids }
        // A table is read by its rows. Chromium also lists it by columns and repeats its header row in a group
        // of cells: Google Sheets' grid was read three times over (Day 3, 10 Oct 2026).
        if role == "AXTable" || role == "AXGrid" {
            kids.removeAll { k in k.role == "AXColumn" || (k.role == "AXGroup" && { let c = k.elements(kAXChildrenAttribute); return !c.isEmpty && c.allSatisfy { $0.role == "AXCell" } }()) }
        }
        // An iOS screen's parts that a module puts first (Kindle's Add Bookmark, after the page's words in the tree,
        // was read by say all at the foot of every page before it turned).
        if iosContent, !Self.iosLeadingIdentifiers.isEmpty {
            let lead = kids.filter { Self.iosLeadingIdentifiers.contains($0.string(kAXIdentifierAttribute) ?? "") }
            if !lead.isEmpty { kids = lead + kids.filter { k in !lead.contains { $0.isSame(k) } } }
        }
        return kids
    }

    /// A container's children, then its close; on `frames` meanwhile, so a stop knows where it was.
    private func read(_ frame: Frame) {
        frames.append(frame)
        readChildren(of: frames.count - 1)
        close(frames.removeLast())
    }

    /// The children of `frames[f]` from its `next` on, until they end or a limit stops the walk.
    private func readChildren(of f: Int) {
        let kids = frames[f].kids, depth = frames[f].depth, each = frames[f].eachOnALine
        var i = max(0, frames[f].next)
        while i < kids.count, !stopped {
            frames[f].next = i
            if each { flush() }
            visit(kids[i], depth: depth + 1)
            i += 1
        }
    }

    /// What a container owes once its children are read: the end of its line, of its announcement and of its span,
    /// and for a link with no text of its own, its title. After a stop, the title waits for the children (read on).
    private func close(_ frame: Frame) {
        if frame.isLink {
            // Nothing from inside it: the line being built is as it was (as always); for a link a pass stopped inside,
            // no piece with words came in either part.
            let nothing = frame.resumed ? textPieces == frame.textPiecesAtOpen : current.count == frame.countAtOpen
            if nothing, !stopped,
               let t = frame.element.string(kAXTitleAttribute) ?? frame.element.string(kAXDescriptionAttribute), !t.isEmpty { append(t, frame.element) }
            linkDepth -= 1
            if frame.ownLine { flush() }
        } else {
            if frame.isBlock { flush() }
            if frame.announced { containerStack.removeLast(); pendingEntering.removeAll { $0.isSame(frame.element) } }
            if frame.announced, frame.role != "AXHeading", outLength > frame.start {
                // NVDA's comma; one opened again by reading on had its span cut where the pass stopped: lengthened.
                if frame.resumed, let k = newContainers.lastIndex(where: { $0.start == frame.start && $0.element.isSame(frame.element) }) {
                    newContainers[k].end = outLength
                } else {
                    newContainers.append((frame.start, outLength, frame.element))
                }
            }
        }
        // Where a page read to its end ends, for reading on later: this frame, with the frames closed at its end inside.
        if !stopped {
            if let inner = edgeChain.first, let last = frame.kids.last, inner.element.isSame(last) { edgeChain.insert(frame, at: 0) } else { edgeChain = [frame] }
        }
    }

    /// A piece of the line being built (one with words is counted, for a link a pass stops inside).
    private func addPiece(_ s: String, _ el: AXUIElement, _ link: Bool) {
        current.append((s, el, link))
        if s.contains(where: { !$0.isWhitespace }) { textPieces += 1 }
    }

    /// `space`: whether the page has white space between this piece and the last (nil: not known, so add one).
    private func append(_ s: String, _ el: AXUIElement, space: Bool? = nil) {
        lastTextEnd = nil
        let t = s.replacingOccurrences(of: "\n", with: " ")
        if current.isEmpty { currentElement = currentElement ?? el }
        if !current.isEmpty, space ?? true, let last = current.last?.0.last, !last.isWhitespace, !(t.first?.isWhitespace ?? true) { addPiece(" ", el, linkDepth > 0) }
        addPiece(t, el, linkDepth > 0)
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
                case .speech: prefix.append(String(localized: "quote level \(String(lvl))", comment: "How deep a quote is in a Mail message"))
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
                case .speech: if !after { pieces.append(" " + Speech.ui(Role.link.displayString) + " ") }
                case .tone: pendingTones.append { Tones.link() }
                case .off: break
                }
            }
            lastLink = s.isLink ? s.element : nil
            pieces.append(textRange(a, b))
            // VoiceOver's order: "About us, link", where the link ends (once, on the piece that ends it).
            if after, s.isLink, linkMode == .speech, s.end <= end, !(s.start < start && start > line.start && s.end > end) {
                pieces.append(", " + Speech.ui(Role.link.displayString) + " ")
            }
            cursor = b
        }
        if cursor < end { pieces.append(textRange(cursor, end)) }
        return (prefix, pieces.joined().replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces))
    }
}
