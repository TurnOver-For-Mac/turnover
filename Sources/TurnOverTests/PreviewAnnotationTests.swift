// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import PDFKit
import TurnOverCore

func previewAnnotationTests() {
    func writePDF(to url: URL, notes: [[String]], modified: Date) throws {
        let image = NSImage(size: NSSize(width: 100, height: 100), flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(rect: rect).fill()
            return true
        }
        let document = PDFDocument()
        for (index, pageNotes) in notes.enumerated() {
            guard let page = PDFPage(image: image) else { throw CocoaError(.fileWriteUnknown) }
            for note in pageNotes {
                let annotation = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 10, height: 10), forType: .text, withProperties: nil)
                annotation.contents = note
                page.addAnnotation(annotation)
            }
            document.insert(page, at: index)
        }
        guard document.write(to: url) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    func withSample(_ run: (URL) throws -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: folder) }
            try run(folder.appendingPathComponent("public-annotation-sample.pdf"))
        } catch { Harness.fail("could not prepare the public PDF sample: \(error)") }
    }

    func budget(queries: Int = 1000) -> AXWalkBudget {
        AXWalkBudget(request: AXWalkRequest(), duration: 5_000_000_000, maxQueries: queries)
    }

    test("preview annotations: scan only the requested page and revalidate the cached file date") {
        withSample { url in
            let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
            try writePDF(to: url, notes: [["first page"], ["second page"]], modified: firstDate)
            guard let second = PreviewAnnotations.read(file: url, page: 1, cache: [], budget: budget()) else {
                return Harness.fail("read the second PDF page")
            }
            expect(second.marks.map(\.words), ["note: second page"])
            let hit = PreviewAnnotations.read(file: url, page: 1, cache: [second], budget: budget(queries: 1))
            expect(hit?.marks.map(\.words), ["note: second page"], "the cache hit uses only the file metadata query")
            let first = PreviewAnnotations.read(file: url, page: 0, cache: [second], budget: budget())
            expect(first?.marks.map(\.words), ["note: first page"], "a cached page does not stand in for another page")

            try writePDF(to: url, notes: [["first page"], ["edited page"]], modified: firstDate.addingTimeInterval(10))
            let updated = PreviewAnnotations.read(file: url, page: 1, cache: [second], budget: budget())
            expect(updated?.marks.map(\.words), ["note: edited page"], "an edit to the same file replaces old annotations")
        }
    }

    test("preview annotations: expired work is silent and crowded pages are capped") {
        withSample { url in
            try writePDF(to: url, notes: [Array(repeating: "public note", count: 140)], modified: Date())
            let expired = AXWalkBudget(request: AXWalkRequest(startedAt: 0), duration: 1, now: { 1 })
            check(PreviewAnnotations.read(file: url, page: 0, cache: [], budget: expired) == nil,
                  "a deadline never publishes an empty success")
            expect(expired.stopped, .deadline)
            guard let sample = PDFDocument(url: url)?.page(at: 0) else { return Harness.fail("open the crowded page") }
            let annotations = sample.annotations
            check(annotations.filter { $0.type == "Text" }.count > 128, "sample exceeds the visit limit")
            // PDFKit may serialize each note alongside a Popup. Both count towards the bounded work.
            let expected = annotations.prefix(128).filter { $0.type == "Text" }.count
            let page = PreviewAnnotations.read(file: url, page: 0, cache: [], budget: budget())
            expect(page?.marks.count, expected, "visit at most the first 128 annotations, including popups")
        }
    }
}
