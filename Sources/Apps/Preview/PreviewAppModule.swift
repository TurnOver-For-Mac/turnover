// SPDX-License-Identifier: GPL-3.0-or-later
// Preview (17 Oct 2026, the first of the Apple apps sweep: the roadmap "Apple apps: all of them"). VoiceOver reads a
// PDF in Preview a text run at a time; TurnOver reads it as a document, as it reads a web page: the arrows by line
// across every page, the headings by H (and VO-Command-H), say all, and the page said as a line crosses onto it.
// Preview gives the document area the keyboard focus as one element (a group, subrole AXSharedDocumentContainer)
// holding an AXPage per page (AXPageIndex, AXPageIndexDescription), each with its text and headings; TurnOver's
// web buffer reads it unchanged (probe: 5 pages, 119 lines in 6 ms).
import Foundation
import AppKit
import ApplicationServices

final class PreviewAppModule: AppModule {
    static let bundleID = "com.apple.Preview"
    static let containerSubrole = "AXSharedDocumentContainer"

    /// The document's container when the focus is on it or inside it.
    override func browseRoot(for element: AXUIElement, ancestors: [TurnOverObject]) -> AXUIElement? {
        if element.string(kAXSubroleAttribute) == Self.containerSubrole { return element }
        if let a = ancestors.first(where: { $0.element.string(kAXSubroleAttribute) == Self.containerSubrole }) { return a.element }
        return nil
    }

    /// The page an element of the document sits on: its number, and Preview's own words for it ("Page 2 of 5").
    static func page(of element: AXUIElement) -> (index: Int, words: String)? {
        var e: AXUIElement? = element
        var hops = 0
        while let x = e, hops < 12 {
            if x.role == "AXPage" {
                let index = (x.attr("AXPageIndex") as? Int) ?? -1
                // Preview leaves AXPageIndexDescription empty; "page 2 of 5", as VoiceOver says it.
                let total = x.element(kAXParentAttribute)?.elements(kAXChildrenAttribute).filter { $0.role == "AXPage" }.count ?? 0
                let own = x.string("AXPageIndexDescription") ?? ""
                return (index, !own.isEmpty ? own : total > 1 ? "page \(index + 1) of \(total)" : "page \(index + 1)")
            }
            e = x.element(kAXParentAttribute); hops += 1
        }
        return nil
    }

    // MARK: Comments and highlights

    /// How a line's comments and highlights are told, as Word's comments are (18 Oct 2026: "should sounds be
    /// playing for annotations like it does in Word?"): a sound (the default), the words, or nothing. With the sound,
    /// a plain highlight is the sound alone (its words were just read in the line); a note's own words follow it.
    static var markReport: ElementReport { ElementReport(rawValue: config.appSetting(bundleID, "marks", default: "tone")) ?? .tone }
    override func menuItems() -> [MenuItem] {
        [MenuItem("Comments and highlights as you reach them", .cycle(options: ElementReport.allCases.map(\.name),
            get: { ElementReport.allCases.firstIndex(of: PreviewAppModule.markReport) ?? 1 },
            set: { config.setAppSetting(PreviewAppModule.bundleID, "marks", ElementReport.allCases[$0].rawValue); config.save() }),
            hint: "tone: a sound, and a note's own words; speech: what each mark is, in words; off: nothing")]
    }
    /// What's said after the sound for one mark: a note's or a text box's own words; nothing for a plain highlight.
    static func wordsWithTone(_ words: String) -> String? {
        if let r = words.range(of: "note: ") { return String(words[r.upperBound...]) }
        if words.hasPrefix("text box: ") { return words }
        return nil
    }
    private struct LineRequest {
        let document: BrowseModeDocument
        let page: Int
        let text: String
        let position: Int
        let movedAt: Date
        let builtAt: Date
        let keys: Int

        init(document: BrowseModeDocument, page: Int, text: String) {
            self.document = document
            self.page = page
            self.text = text
            position = document.position
            movedAt = document.positionMovedAt
            builtAt = document.buffer.builtAt
            keys = ScriptHandler.keysArrivedCount
        }

        var isCurrent: Bool {
            API.focusTreeInterceptor === document && !document.passThrough && !SayAll.isRunning
                && document.position == position && document.positionMovedAt == movedAt
                && document.buffer.builtAt == builtAt && ScriptHandler.keysArrivedCount == keys
        }
    }

    private let annotations = AXWalkRunner<PreviewAnnotations.Page?>()
    private var cachedPages: [PreviewAnnotations.Page] = []
    private var pendingLine: LineRequest?
    private var annotationRequest = 0

    /// The browse document has already queued the line. On 7 Nov 2026 (#259), opening a PDF for its marks here
    /// stopped the reader on the first Down Arrow. Leave that work on the collector and report only a current result.
    static func marks(for root: AXUIElement, page: Int, line: String) -> [String] {
        guard markReport != .off, page >= 0, let document = API.focusTreeInterceptor, document.webArea.isSame(root),
              let module = AppModuleHandler.shared.appModule(for: root.pid) as? PreviewAppModule else { return [] }
        let flat = line.replacingOccurrences(of: "\n", with: " ")
        guard !flat.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        module.readMarks(LineRequest(document: document, page: page, text: flat))
        return []
    }

    private func readMarks(_ line: LineRequest) {
        guard isReading, line.isCurrent else { return }
        let previous = pendingLine
        pendingLine = line
        // Coalesce line movements on this page while the file is being read. Only the latest line can speak.
        if previous?.document === line.document, previous?.page == line.page { return }
        annotationRequest &+= 1
        let request = annotationRequest
        let root = line.document.webArea, page = line.page, cache = cachedPages
        annotations.submit(collect: { work in
            PreviewAnnotations.read(root: root, page: page, cache: cache, work: work)
        }, publish: { [weak self] result in
            self?.finishMarks(result, request: request)
        })
    }

    private var isReading: Bool {
        Core.active && API.focusPid == pid && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            && !AXHandler.shared.isMenuOpen && !TurnOverMenu.shared.isOpen
            && InputManager.directPid != pid && !InputManager.isAsleep(pid)
    }

    private func finishMarks(_ result: PreviewAnnotations.Page?, request: Int) {
        guard annotationRequest == request, let line = pendingLine else { return }
        pendingLine = nil
        guard let result, isReading, Self.markReport != .off else { return }
        cachedPages.removeAll { $0.file != result.file || $0.index == result.index }
        cachedPages.append(result)
        if cachedPages.count > 4 { cachedPages.removeFirst() }
        guard line.isCurrent else { return }
        let words = PreviewAnnotations.words(in: result.marks, on: line.text)
        guard !words.isEmpty else { return }
        switch Self.markReport {
        case .off: return
        case .speech: words.forEach { Speech.speakMessage($0) }
        case .tone:
            Tones.comment()
            for mark in words { if let note = Self.wordsWithTone(mark) { Speech.speakMessage(note) } }
        }
    }

    override func event_appModuleLoseFocus() {
        annotationRequest &+= 1
        pendingLine = nil
        annotations.cancel()
    }

    override func terminate() { event_appModuleLoseFocus(); cachedPages.removeAll() }
}
