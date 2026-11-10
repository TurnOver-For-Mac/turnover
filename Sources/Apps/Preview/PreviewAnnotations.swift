// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import PDFKit
import TurnOverAX

/// PDFKit can wait on a protected file or an iCloud download (#259, 7 Nov 2026). This collector runs on
/// Preview's serial worker. The deadline is cooperative: a call already inside PDFKit can't be interrupted.
nonisolated package enum PreviewAnnotations {
    package struct Mark: Sendable {
        let anchor: String
        package let words: String
    }

    package struct FileStamp: Equatable, Sendable {
        let path: String
        let modified: Date
        let size: Int
    }

    package struct Page: Sendable {
        let file: FileStamp
        let index: Int
        package let marks: [Mark]
    }

    private static let annotationLimit = 128
    private static let textLimit = 4096

    static func read(root: AXUIElement, page: Int, cache: [Page], work: AXWalkRequest) -> Page? {
        let budget = AXWalkBudget(request: work, duration: 1_000_000_000, maxAXQueries: 6)
        guard let window = AXReadScope.with(while: budget.check, onQuery: budget.admitAXQuery, onResult: budget.record, {
            root.element(kAXWindowAttribute)
        }), let address = documentAddress(window, budget: budget), let url = URL(string: address),
              let result = read(file: url, page: page, cache: cache, budget: budget),
              documentAddress(window, budget: budget) == address, budget.check() else { return nil }
        return result
    }

    private static func documentAddress(_ window: AXUIElement, budget: AXWalkBudget) -> String? {
        AXReadScope.with(while: budget.check, onQuery: budget.admitAXQuery, onResult: budget.record) {
            window.string("AXDocument")
        }
    }

    package static func read(file url: URL, page index: Int, cache: [Page], budget: AXWalkBudget) -> Page? {
        guard index >= 0, url.isFileURL, url.host.map({ $0.isEmpty || $0 == "localhost" }) ?? true,
              url.pathExtension.lowercased() == "pdf",
              let stamp = budget.query({ fileStamp(url) }) ?? nil else { return nil }
        if let hit = cache.first(where: { $0.file == stamp && $0.index == index }) { return hit }
        guard let pdf = budget.query({ PDFDocument(url: url) }) ?? nil,
              let page = budget.query({ pdf.page(at: index) }) ?? nil,
              let annotations = budget.query({ page.annotations }) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        var marks: [Mark] = []
        for annotation in annotations.prefix(annotationLimit) {
            guard budget.check() else { return nil }
            if let mark = read(annotation, on: page, bounds: bounds, budget: budget) { marks.append(mark) }
        }
        guard let finished = budget.query({ fileStamp(url) }) ?? nil, finished == stamp else { return nil }
        if annotations.count > annotationLimit { Log.info("preview: annotation scan reached the page limit") }
        Log.info("preview: \(marks.count) comments and highlights read from the file")
        return Page(file: stamp, index: index, marks: marks)
    }

    private static func fileStamp(_ url: URL) -> FileStamp? {
        // Use a fresh file URL so Foundation does not reuse resource values from a previous read.
        let local = URL(fileURLWithPath: url.path)
        guard let values = try? local.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
              values.isRegularFile == true, let modified = values.contentModificationDate, let size = values.fileSize else { return nil }
        return FileStamp(path: local.path, modified: modified, size: size)
    }

    private static func read(_ annotation: PDFAnnotation, on page: PDFPage, bounds: CGRect, budget: AXWalkBudget) -> Mark? {
        let type = annotation.type ?? ""
        let rect = annotation.bounds
        let contents = String((annotation.contents ?? "").prefix(textLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
        let note = contents.isEmpty ? "" : ", note: \(contents)"

        func selection(_ region: CGRect) -> String {
            budget.query { page.selection(for: region)?.string ?? "" } ?? ""
        }

        func covered() -> String {
            String(selection(rect).prefix(textLimit)).replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func beside() -> String {
            // Read the line across the page at the annotation's height, or the closest line above it.
            let region = CGRect(x: 0, y: rect.minY, width: bounds.width, height: max(rect.height, 12))
            if let line = selection(region).prefix(textLimit).components(separatedBy: .newlines).first(where: hasWords) { return line }
            let above = CGRect(x: 0, y: rect.maxY, width: bounds.width, height: max(1, bounds.height - rect.maxY))
            return selection(above).suffix(textLimit).components(separatedBy: .newlines).last(where: hasWords) ?? ""
        }

        switch type {
        case "Highlight", "Underline", "StrikeOut", "Squiggly":
            let text = covered()
            guard !text.isEmpty else { return nil }
            let kind = ["Highlight": "highlighted", "Underline": "underlined", "StrikeOut": "struck through"][type] ?? "marked"
            return Mark(anchor: text, words: "\(kind): \(text)\(note)")
        case "Text" where !contents.isEmpty: return Mark(anchor: beside(), words: "note: \(contents)")
        case "FreeText" where !contents.isEmpty: return Mark(anchor: beside(), words: "text box: \(contents)")
        case "Ink": return Mark(anchor: beside(), words: "drawing\(note)")
        case "Square", "Circle", "Line":
            let text = covered()
            let kind = type == "Square" ? "rectangle" : type.lowercased()
            return Mark(anchor: text.isEmpty ? beside() : text, words: "\(kind)\(text.isEmpty ? "" : " around: \(text)")\(note)")
        case "Stamp": return Mark(anchor: beside(), words: "stamp\(note)")
        default: return nil   // links and form fields are read already; popups belong to their note
        }
    }

    private static func hasWords(_ line: String) -> Bool { !line.trimmingCharacters(in: .whitespaces).isEmpty }

    static func words(in marks: [Mark], on line: String) -> [String] {
        marks.filter { starts($0, on: line) }.map { wholeWords($0, in: line) }
    }

    private static func starts(_ mark: Mark, on line: String) -> Bool {
        let anchor = mark.anchor
        guard !anchor.isEmpty else { return false }
        let flat = line.trimmingCharacters(in: .whitespaces)
        return line.contains(anchor.prefix(24)) || (anchor.count > 24 && line.hasSuffix(anchor.prefix(min(anchor.count, line.count))))
            || anchor.contains(flat) && flat.count > 12 && anchor.hasPrefix(flat.prefix(12))
    }

    /// Widen the covered text to the complete words as they stand in the line.
    private static func wholeWords(_ mark: Mark, in line: String) -> String {
        guard let range = line.range(of: mark.anchor.prefix(24)), mark.words.contains(mark.anchor) else { return mark.words }
        var start = range.lowerBound
        var end = line.index(start, offsetBy: mark.anchor.count, limitedBy: line.endIndex) ?? line.endIndex
        func isWord(_ character: Character) -> Bool { character.isLetter || character.isNumber || "'’-".contains(character) }
        while start > line.startIndex, isWord(line[line.index(before: start)]) { line.formIndex(before: &start) }
        while end < line.endIndex, isWord(line[end]) { line.formIndex(after: &end) }
        return mark.words.replacingOccurrences(of: mark.anchor, with: String(line[start..<end]).trimmingCharacters(in: .whitespaces))
    }
}
