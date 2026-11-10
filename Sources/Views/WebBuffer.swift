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
    /// The publication's elements, answered from its collection.
    private func inPublication<Value>(_ body: () -> Value) -> Value { snapshot.accessibility.with(body) }
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
    /// What waits for the reading under way, each caller its own (review of #219, point 3: with one, a focus event
    /// could drop a key's, and Kindle's page turn never finish). Each checks for itself that it is still wanted.
    private var pendingCompletions: [() -> Void] = []
    private var readOnCompletion: ((Bool) -> Void)?
    private var refreshAfterReadOn: (() -> Void)?
    /// Both hooks run on main, immediately around the atomic replacement. The owner anchors the *current*
    /// caret here, rather than restoring a position captured before the user continued reading.
    var willPublish: (() -> Void)?
    var didPublish: (() -> Void)?
    package var didInvalidate: (() -> Void)?
    var didFail: (() -> Void)?
    package var acceptsSnapshot: ((AXSnapshot) -> Bool)?

    public convenience init(webArea: AXUIElement) {
        self.init(webArea: webArea) { root, focus, request in WebBufferCollection.collect(root: root, focus: focus, request: request) }
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
    private var elementCount = 0
    /// The elements one pass reads (a test sets it lower).
    nonisolated(unsafe) package static var maxElements = 6000
    /// How long one read may take on the main thread, its passes together (a test sets it lower).
    nonisolated(unsafe) package static var buildSeconds: TimeInterval = 2
    /// The passes one `build` may make to get back to the reader (a test sets it lower).
    nonisolated(unsafe) package static var passesPerBuild = 50
    private var buildDeadline = Date.distantFuture
    /// A new page in the same web area: the partial-page notice is due again (code review, 16 Oct 2026, item 29),
    /// and the reading position was in the page before.
    public func newPage() {
        cancel()
        revision += 1
        snapshot = Snapshot(text: "", lines: [], segments: [], containers: [], accessibility: AXSnapshot(nodes: [:]))
        lastStop = nil; builtAt = .distantPast; isDirty = true; status = .idle
        loggedPartial = false; readingAt = 0; samePage = false
        resumeFrames = []; checkpoints = []; stopped = false; passes = 1
    }
    private var loggedPartial = false
    /// The copy is of the page the web area shows (no new page since it was read): one read again may keep it.
    private var samePage = false

    public func cancel() {
        let readOn = readOnCompletion
        readOnCompletion = nil
        refreshAfterReadOn = nil
        generation += 1; runner.cancel(); pendingCompletions = []; status = .cancelled
        if let readOn { DispatchQueue.main.async { readOn(false) } }
    }

    /// Coalesce refreshes while a collection is in flight. A page change calls newPage first, cancelling the
    /// old generation. Keeping the previous snapshot makes arrows usable during a same-page refresh.
    public func build(scrollTo: AXUIElement? = nil, completion: (() -> Void)? = nil) {
        // Every caller's action waits; each checks on completion that it is still the latest of its kind (its key's
        // intent, the document's generation), so a burst of keys does not replay as a burst of moves.
        if let completion { pendingCompletions.append(completion) }
        if readOnCompletion != nil {
            // Reading on extends the old copy. A caller asking to refresh needs a new collection from the root.
            if refreshAfterReadOn == nil { refreshAfterReadOn = { [weak self] in self?.build(scrollTo: scrollTo) } }
            return
        }
        guard !isLoading else { return }
        status = .loading
        collectingDirtyRevision = dirtyRevision
        let current = generation
        let root = webArea
        let focus = API.focusObject?.element
        let collector = collect
        runner.submit(collect: { request in
            if let scrollTo {
                let budget = AXWalkBudget(request: request, startedAt: DispatchTime.now().uptimeNanoseconds)
                AXReadScope.with(while: { budget.check() }, onQuery: { budget.admitAXQuery() }, onResult: { budget.record($0) }) {
                    _ = scrollTo.actionResult("AXScrollToVisible")
                }
            }
            return collector(root, focus, request)
        }, publish: { [weak self] result in
            guard let self, generation == current else { return }
            publish(result)
        })
    }

    /// Explicit synchronous path for the command-line plugin inspector and recorded-tree layout tests.
    /// Interactive reader callers must use build(completion:).
    package func buildForInspection() {
        let was = collectsAtOnce; collectsAtOnce = true; defer { collectsAtOnce = was }
        collectingDirtyRevision = dirtyRevision
        publish(WebBufferCollection.collect(root: webArea, focus: API.focusObject?.element, request: AXWalkRequest()))
    }
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
    public var canReadOn: Bool { status != .cancelled && stopped && !resumeFrames.isEmpty }

    /// How long the walk over a collection may take on main. Ashley's 100 ms (#219) is kept: past it the walk stops
    /// as at any limit, and the rest is read on.
    nonisolated(unsafe) package static var layoutSeconds: TimeInterval = 0.1   // a test sets it; main thread only
    /// The collection the walk is reading: an element it did not collect, because the collection stopped at a limit,
    /// is where the walk stops too, and reading on goes on from there (merging #219 with #281, 10 Nov 2026).
    private var collectionWasCut = false

    private func publish(_ collection: WebBufferCollection) {
        if collection.navigationChanged || acceptsSnapshot?(collection.snapshot) == false {
            newPage()
            didInvalidate?()
            return
        }
        let t0 = Date()
        // The copy being replaced, kept if this read is cut short and is the same as far as it goes (below).
        let old = saved()
        walkOmissions = collection.omittedElements
        collectionWasCut = [.visits, .deadline, .queries, .axQueries].contains(collection.stop)
        collection.snapshot.with {
            out = ""; outLength = 0; current = []; currentElement = nil; pendingEntering = []; containerStack = []; linkDepth = 0
            newLines = []; newSegments = []; newContainers = []; visited = 0
            frames = []; resumeFrames = []; stopped = false; resumeElement = nil; resumePending = []; edgeChain = []; textPieces = 0; passes = 1
            checkpoints = []
            // This deadline bounds local interpretation, not a provider wait. Every AX convenience read is served
            // from the immutable collection, including those made by existing object and app presentation rules.
            buildDeadline = Date().addingTimeInterval(Self.layoutSeconds)
            iosContent = webArea.string(kAXSubroleAttribute) == "iOSContentGroup"
            profiled = !ProfileStore.shared.profiles(for: ProfileStore.shared.bundle(of: webArea.pid)).isEmpty
            consumed = []
            docText = collection.documentText as NSString
            docCursor = 0; lastTextEnd = nil
            visit(webArea, depth: 0)
            flush()
            if newLines.isEmpty, !stopped, let dialog = collection.focusedPart {
                visit(dialog, depth: 1); flush()
            }
            endPass()
        }
        collectionWasCut = false
        elementCount = visited
        // A transient provider failure is not an empty new document. Keep the last valid publication and its
        // caret/ranges available, while marking the refresh incomplete and leaving it due for retry.
        let failed = collection.stop.map { [.providerFailure, .backoff, .cancelled, .cycle].contains($0) } ?? false
        // Likewise a read of the same page that stopped before it had anything (a page that has stopped answering in
        // time; #281's rule): the copy it had is kept, still due for reading again.
        if newLines.isEmpty, failed || stopped, samePage, !old.publication.lines.isEmpty {
            restore(old)
            lastStop = collection.stop ?? .deadline
            isDirty = true
            finish(since: t0, collectedMs: collection.elapsedMs, published: false)
            return
        }
        walkAccessibility = collection.snapshot
        // Every stop of the collection leaves the page incomplete (#219), even where the walk had all it reached.
        lastStop = stopped ? (collection.stop ?? .deadline) : collection.stop
        // The same page, read on past its first part before (a long chat, issue 227), with the reader past what this
        // reading reached: the rest is read on, in the background as the first part was, as far as the reader, before
        // anything is published. Until then the copy as it was stays readable.
        let wanted = min(readingAt + 2000, old.publication.text.length)
        if stopped, samePage, outLength <= wanted, readingAt >= outLength {
            status = .loading
            catchUp(through: old.publication.text.length, passesLeft: Self.passesPerBuild) { [weak self] success in
                guard let self else { return }
                if !success {
                    let stop = self.lastStop
                    self.restore(old)
                    self.lastStop = stop
                    self.isDirty = true
                    self.finish(since: t0, collectedMs: collection.elapsedMs, published: false)
                    return
                }
                self.samePage = true
                self.isDirty = self.dirtyRevision != self.collectingDirtyRevision
                self.publishCopy()
                self.finish(since: t0, collectedMs: collection.elapsedMs, published: true)
            }
            return
        }
        samePage = true
        isDirty = dirtyRevision != collectingDirtyRevision
        publishCopy()
        finish(since: t0, collectedMs: collection.elapsedMs, published: true)
    }

    /// The end of every reading of the page, published or not: status, the notice for a page read in part, the log,
    /// and the action waiting for it.
    private func finish(since t0: Date, collectedMs: Int, published: Bool) {
        if published { builtAt = Date() }
        status = lastStop == nil ? .complete : (lines.isEmpty ? .unavailable : .partial)
        // (The notice for a page read in part is browse mode's, once a page: reportPartialBuffer.)
        if stopped, !loggedPartial { loggedPartial = true; Log.error("virtual buffer: stopped at \(visited >= Self.maxElements ? "\(Self.maxElements) elements" : "a limit"), \(lastStop.map(\.rawValue) ?? "the walk's time"); the rest is read on") }
        lastBuildMs = collectedMs + Int(Date().timeIntervalSince(t0) * 1000)
        Log.info("virtual buffer: \(lines.count) lines, \(text.length) characters from \(elementCount) elements in \(lastBuildMs) ms (\(status)\(lastStop.map { ": " + $0.rawValue } ?? "")\(passes > 1 ? ", \(passes) passes" : ""))")
        let ready = pendingCompletions; pendingCompletions = []
        let current = generation
        if published { didPublish?() } else { didFail?() }
        for completion in ready where generation == current { completion() }
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

    // MARK: Reading on in the background (merging #219 with #281, 10 Nov 2026)
    // Where the walk stopped at a limit, the rest of the page is collected as the first part was, on the worker, from
    // the elements the walk did not reach (`frontier`), and the walk goes on over that on main, its text added at the
    // end of the copy so every offset before it stays as it was. Nothing in it asks the app on main.

    /// The collections the walk has read so far, together: what the next publication answers from.
    private var walkAccessibility = AXSnapshot(nodes: [:])
    private var walkOmissions: Set<ElementKey> = []
    /// Tests and the inspector collect at once, on the calling thread; the reader in the background.
    package var collectsAtOnce = false

    /// The elements the walk did not reach, in reading order: the rest of the deepest container from the one it
    /// stopped at, then the rest of each container round it.
    private func frontier() -> [AXUIElement] {
        guard stopped else { return [] }
        var out: [AXUIElement] = []
        for (k, f) in resumeFrames.enumerated().reversed() {
            let from = k == resumeFrames.count - 1 ? f.next : f.next + 1
            if from < f.kids.count { out += f.kids[max(0, from)...] }
        }
        return out
    }

    private func collectFrontier(_ then: @escaping (WebBufferCollection?) -> Void) {
        let roots = frontier()
        guard !roots.isEmpty else { then(nil); return }
        let area = webArea
        let expectedURL = walkAccessibility.nodes[ElementKey(area)]?.attributes["AXURL"]
        let job: @Sendable (AXWalkRequest) -> WebBufferCollection = { request in
            WebBufferCollection.collect(root: area, focus: nil, request: request, continuing: roots, expectedURL: expectedURL)
        }
        if collectsAtOnce { then(job(AXWalkRequest())); return }
        let current = generation
        runner.submit(collect: job, publish: { [weak self] result in
            guard let self, generation == current else { return }
            then(result)
        })
    }

    /// One pass of the walk over a collection of the rest of the page, added to the copy (not yet published).
    private func readOn(from collection: WebBufferCollection) -> Bool? {
        let cut = [.visits, .deadline, .queries, .axQueries].contains(collection.stop)
        if let stop = collection.stop, !cut || collection.snapshot.nodes.isEmpty {
            // Backoff, a dead provider or a pass that could not collect even one element cannot mean end of page.
            lastStop = stop
            stopped = false
            isDirty = true
            return nil
        }
        walkAccessibility = walkAccessibility.merging(collection.snapshot)
        walkOmissions.formUnion(collection.omittedElements)
        collectionWasCut = cut
        let more = walkAccessibility.with { readOn(deadline: Date().addingTimeInterval(Self.layoutSeconds)) }
        collectionWasCut = false
        lastStop = stopped ? (collection.stop ?? .deadline) : collection.stop
        return more
    }

    /// Reads on from where the walk stopped, in the background, and publishes what it added. `completion` (on main)
    /// says whether there was text in it; false at once when there is nothing to read on, or a reading is under way.
    public func buildMore(completion: ((Bool) -> Void)? = nil) {
        guard canReadOn, !isLoading else { completion?(false); return }
        readOnCompletion = completion ?? { _ in }
        status = .loading
        let t0 = Date(), linesBefore = newLines.count, lengthBefore = outLength
        collectFrontier { [weak self] collection in
            guard let self else { return }
            if collection?.navigationChanged == true {
                self.newPage()
                self.didInvalidate?()
                return
            }
            let more = collection.flatMap { self.readOn(from: $0) }
            if collection == nil { self.stopped = false; self.isDirty = true }
            let readOn = self.readOnCompletion
            let refresh = self.refreshAfterReadOn
            self.readOnCompletion = nil
            self.refreshAfterReadOn = nil
            if more != nil { self.publishCopy() }
            self.status = self.lastStop == nil ? .complete : .partial
            Log.info("virtual buffer: read on from where it stopped: \(self.newLines.count - linesBefore) lines, \(self.outLength - lengthBefore) characters from \(self.visited) elements in \(Int(Date().timeIntervalSince(t0) * 1000)) ms\(self.stopped ? "; more to read on" : ", to the end")")
            let current = self.generation
            if more != nil { self.didPublish?() } else { self.didFail?() }
            if self.generation == current { refresh?() }
            readOn?(more == true && self.generation == current)
        }
    }

    /// For the tests: reads on at once and says whether there was text.
    @discardableResult
    package func buildMoreAtOnce() -> Bool {
        let was = collectsAtOnce; collectsAtOnce = true; defer { collectsAtOnce = was }
        var more = false
        buildMore { more = $0 }
        return more
    }

    /// Recheck the reader's position after each pass while the old publication is still available.
    private func catchUp(through oldLength: Int, passesLeft: Int, then done: @escaping (Bool) -> Void) {
        let wanted = min(readingAt + 2000, oldLength)
        guard canReadOn, outLength <= wanted, passesLeft > 0 else { done(true); return }
        collectFrontier { [weak self] collection in
            guard let self else { return }
            guard let collection else { done(false); return }
            if collection.navigationChanged {
                self.newPage()
                self.didInvalidate?()
                return
            }
            guard self.readOn(from: collection) != nil else { done(false); return }
            self.catchUp(through: oldLength, passesLeft: passesLeft - 1, then: done)
        }
    }

    /// The copy as published, in one replacement, with the collections its elements are answered from.
    private func publishCopy() {
        willPublish?()
        revision += 1
        snapshot = Snapshot(text: out as NSString, lines: newLines, segments: newSegments, containers: newContainers,
                            accessibility: walkAccessibility)
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
        let publication: Snapshot; let lastStop: AXWalkStop?
        let omissions: Set<ElementKey>
        let out: String; let outLength: Int
        let resumeFrames: [Frame]; let stopped: Bool; let resumeElement: AXUIElement?; let resumePending: [AXUIElement]
        let checkpoints: [Checkpoint]
        let passes: Int; let textPieces: Int; let elementCount: Int
        let docText: NSString; let docCursor: Int; let lastTextEnd: Int?
    }
    private func saved() -> Copy {
        Copy(publication: snapshot, lastStop: lastStop, omissions: walkOmissions, out: out, outLength: outLength,
             resumeFrames: resumeFrames, stopped: stopped, resumeElement: resumeElement, resumePending: resumePending,
             checkpoints: checkpoints, passes: passes, textPieces: textPieces, elementCount: elementCount,
             docText: docText, docCursor: docCursor, lastTextEnd: lastTextEnd)
    }
    private func restore(_ c: Copy) {
        snapshot = c.publication; lastStop = c.lastStop
        walkAccessibility = c.publication.accessibility; walkOmissions = c.omissions
        out = c.out; outLength = c.outLength
        newLines = c.publication.lines; newSegments = c.publication.segments; newContainers = c.publication.containers
        resumeFrames = c.resumeFrames; stopped = c.stopped
        resumeElement = c.resumeElement; resumePending = c.resumePending; checkpoints = c.checkpoints
        passes = c.passes; textPieces = c.textPieces; elementCount = c.elementCount
        docText = c.docText; docCursor = c.docCursor; lastTextEnd = c.lastTextEnd
        frames = []; edgeChain = []; current = []; currentElement = nil; pendingEntering = []; containerStack = []; linkDepth = 0
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
        // An element the collection did not reach, because it stopped at a limit, is where the walk stops too.
        guard visited < Self.maxElements, Date() < buildDeadline,
              !(collectionWasCut && !AXSnapshot.holds(el) && !walkOmissions.contains(ElementKey(el))) else {
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

    private init(copying source: WebBuffer) {
        webArea = source.webArea; collect = source.collect; decorativeImages = source.decorativeImages
        snapshot = source.snapshot; revision = source.revision; lastStop = source.lastStop
        builtAt = source.builtAt; status = source.status; isDirty = source.isDirty; lastBuildMs = source.lastBuildMs
    }
    /// Text ranges retain the publication their offsets describe, including copies queued for speech.
    package func frozen() -> WebBuffer { WebBuffer(copying: self) }

    package func withSnapshot<Value>(_ body: () -> Value) -> Value { inPublication(body) }

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
        inPublication { Self.findText(lines: lines, segments: segments, text: text, from: offset, forward: forward, kind: kind) }
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
        inPublication { findInSnapshot(from: offset, forward: forward, roles: roles, headingLevel: headingLevel) }
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
        inPublication { offsetInSnapshot(of: element) }
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
