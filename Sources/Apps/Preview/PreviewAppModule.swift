// SPDX-License-Identifier: GPL-3.0-or-later
// Preview (17 Oct 2026, the first of the Apple apps sweep: the roadmap "Apple apps: all of them"). VoiceOver reads a
// PDF in Preview a text run at a time; TurnOver reads it as a document, as it reads a web page: the arrows by line
// across every page, the headings by H (and VO-Command-H), say all, and the page said as a line crosses onto it.
// Preview gives the document area the keyboard focus as one element (a group, subrole AXSharedDocumentContainer)
// holding an AXPage per page (AXPageIndex, AXPageIndexDescription), each with its text and headings; TurnOver's
// web buffer reads it unchanged (probe: 5 pages, 119 lines in 6 ms).
import Foundation
import ApplicationServices
import PDFKit

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

    /// Preview shows a PDF's highlights, underlines, strike-throughs, notes and text boxes but gives accessibility none
    /// of them (probe, 17 Oct 2026: no elements, no text attributes; VoiceOver can't read them either). TurnOver opens
    /// the file itself with PDFKit and says each where it sits: after the line it marks, or the line beside a note.
    struct Mark { let page: Int; let anchor: String; let words: String }

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
    private static var cache: (path: String, modified: Date, marks: [Mark])?

    static func marks(for root: AXUIElement) -> [Mark] {
        guard let doc = root.element(kAXWindowAttribute)?.string("AXDocument"), let url = URL(string: doc), url.isFileURL,
              url.pathExtension.lowercased() == "pdf" else { return [] }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if let c = cache, c.path == url.path, c.modified == modified { return c.marks }
        var out: [Mark] = []
        if let pdf = PDFDocument(url: url) {
            for i in 0..<pdf.pageCount {
                guard let page = pdf.page(at: i) else { continue }
                let width = page.bounds(for: .mediaBox).width
                for a in page.annotations {
                    let type = a.type ?? ""
                    let contents = (a.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let covered = (page.selection(for: a.bounds)?.string ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    // The line beside a note or a text box: the page's text across its whole width at that height.
                    let besideRect = CGRect(x: 0, y: a.bounds.minY, width: width, height: max(a.bounds.height, 12))
                    var beside = (page.selection(for: besideRect)?.string ?? "").components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
                    if beside.isEmpty {
                        // Nothing level with it (a text box in a margin or a gap): the nearest line above it.
                        let pageHeight = page.bounds(for: .mediaBox).height
                        let above = CGRect(x: 0, y: a.bounds.maxY, width: width, height: max(1, pageHeight - a.bounds.maxY))
                        beside = (page.selection(for: above)?.string ?? "").components(separatedBy: .newlines).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
                    }
                    let note = contents.isEmpty ? "" : ", note: \(contents)"
                    switch type {
                    case "Highlight": if !covered.isEmpty { out.append(Mark(page: i, anchor: covered, words: "highlighted: \(covered)\(note)")) }
                    case "Underline": if !covered.isEmpty { out.append(Mark(page: i, anchor: covered, words: "underlined: \(covered)\(note)")) }
                    case "StrikeOut": if !covered.isEmpty { out.append(Mark(page: i, anchor: covered, words: "struck through: \(covered)\(note)")) }
                    case "Squiggly": if !covered.isEmpty { out.append(Mark(page: i, anchor: covered, words: "marked: \(covered)\(note)")) }
                    case "Text": if !contents.isEmpty { out.append(Mark(page: i, anchor: beside, words: "note: \(contents)")) }
                    case "FreeText": if !contents.isEmpty { out.append(Mark(page: i, anchor: beside, words: "text box: \(contents)")) }
                    case "Ink": out.append(Mark(page: i, anchor: beside, words: "drawing\(note)"))
                    case "Square", "Circle", "Line": out.append(Mark(page: i, anchor: covered.isEmpty ? beside : covered, words: "\(type == "Square" ? "rectangle" : type.lowercased())\(covered.isEmpty ? "" : " around: \(covered)")\(note)"))
                    case "Stamp": out.append(Mark(page: i, anchor: beside, words: "stamp\(note)"))
                    default: break   // links and form fields are read already; popups belong to their note
                    }
                }
            }
        }
        cache = (url.path, modified, out)
        Log.info("preview: \(out.count) comments and highlights read from the file")
        return out
    }

    /// What marks the line just read: each mark on this page whose text starts on it (a highlight running onto the
    /// next line is said once, where it begins).
    static func marks(for root: AXUIElement, page: Int, line: String) -> [String] {
        let flat = line.replacingOccurrences(of: "\n", with: " ")
        guard !flat.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return marks(for: root).filter { m in
            Self.starts(m, on: flat, page: page)
        }.map { m in wholeWords(m, in: flat) }
    }

    /// A mark's words with its covered text widened to whole words as they stand in the line ("h has a highlighted"
    /// is "with a highlighted phrase" cut by the mark's edges, which fall between letters).
    static func wholeWords(_ m: Mark, in line: String) -> String {
        let ns = line as NSString
        let r = ns.range(of: String(m.anchor.prefix(24)))
        guard r.location != NSNotFound, m.words.contains(m.anchor) else { return m.words }
        var start = r.location, end = min(ns.length, r.location + m.anchor.count)
        let letters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'’-"))
        func isLetter(_ i: Int) -> Bool { i >= 0 && i < ns.length && (ns.substring(with: NSRange(location: i, length: 1)).unicodeScalars.first.map { letters.contains($0) } ?? false) }
        while isLetter(start - 1) { start -= 1 }
        while isLetter(end) { end += 1 }
        let widened = ns.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespaces)
        return m.words.replacingOccurrences(of: m.anchor, with: widened)
    }

    private static func starts(_ m: Mark, on flat: String, page: Int) -> Bool {
        return [m].contains { m in
            guard m.page == page, !m.anchor.isEmpty else { return false }
            let head = String(m.anchor.prefix(24))
            return flat.contains(head) || (m.anchor.count > 24 && flat.hasSuffix(String(m.anchor.prefix(min(m.anchor.count, flat.count)))))
                || m.anchor.contains(flat.trimmingCharacters(in: .whitespaces)) && flat.count > 12 && m.anchor.hasPrefix(String(flat.prefix(12)))
        }
    }
}

