// SPDX-License-Identifier: GPL-3.0-or-later
// The screen interface (28 Oct 2026, Oliver: "something more interesting with the OCR side... on-device AI or
// something faster to create a kind of pseudo-interface, a little how Apple's Screen Recognition does on iOS"):
// the front window's pixels read as controls, not only as lines of text. Three passes over one capture:
//   1. Vision's document reader: titles, paragraphs, lists and tables, each with its place on screen.
//   2. Vision's contours: boxes the size of a button, a field or a check box; text inside a box is a button.
//   3. The Mac's own on-device language model (macOS 27, Apple Intelligence on): shown the picture, it lists the
//      controls it sees with a kind, a label and a place; its kinds refine the first two passes, and controls with
//      no text (icons) come from it alone. Nothing leaves the Mac.
// The result opens as screen recognition's does (rows to arrow through, Return clicks), each row a control:
// "Save, button". Behind the developer switch `flatView`; reached from the TurnOver layer with E.
import Foundation
import AppKit
import Vision
#if canImport(FoundationModels)
import FoundationModels
#endif

@available(macOS 26.0, *)
public enum ScreenInterface {
    nonisolated public enum Kind: String, Sendable {
        case heading, text, listItem = "list item", cell, button, link, field = "text field", checkbox = "check box", toggle = "switch", tab, menu, slider, icon, image
        /// Said after the label; plain text says nothing.
        var spoken: String { self == .text ? "" : rawValue }
        /// How sure a kind is: the model's kinds for controls beat the geometry's guess, which beats plain text.
        var rank: Int {
            switch self { case .text: return 0; case .heading, .listItem, .cell: return 1; default: return 2 }
        }
    }

    nonisolated public struct Element: Sendable {
        public var kind: Kind
        public var label: String
        /// In screen points (top left origin).
        public var rect: CGRect
        public var from: String   // "document", "box", "model": for the log
    }

    nonisolated public struct Detection: Sendable {
        public var elements: [Element]
        public var note: String
    }

    /// The controls on the picture, in reading order (top to bottom, left to right within a band of 24 points).
    @concurrent nonisolated public static func detect(_ image: CGImage, frame: CGRect) async -> Detection {
        let t0 = Date()
        var notes: [String] = []
        let size = CGSize(width: image.width, height: image.height)
        func toScreen(_ r: CGRect) -> CGRect {   // image pixels (top left origin) to screen points
            let sx = frame.width / size.width, sy = frame.height / size.height
            return CGRect(x: frame.minX + r.minX * sx, y: frame.minY + r.minY * sy, width: r.width * sx, height: r.height * sy)
        }

        // 1. The document: text with structure.
        var elements: [Element] = []
        do {
            let request = RecognizeDocumentsRequest()
            let observations = try await request.perform(on: image)
            for obs in observations {
                let doc = obs.document
                if let title = doc.title, !title.transcript.isEmpty {
                    elements.append(Element(kind: .heading, label: title.transcript, rect: toScreen(title.boundingRegion.boundingBox.toImageCoordinates(size, origin: .upperLeft)), from: "document"))
                }
                for list in doc.lists {
                    for item in list.items {
                        let s = item.itemString.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !s.isEmpty else { continue }
                        elements.append(Element(kind: .listItem, label: s, rect: toScreen(item.content.boundingRegion.boundingBox.toImageCoordinates(size, origin: .upperLeft)), from: "document"))
                    }
                }
                for table in doc.tables {
                    for row in table.rows {
                        for cell in row {
                            let s = cell.content.text.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !s.isEmpty else { continue }
                            elements.append(Element(kind: .cell, label: s, rect: toScreen(cell.content.boundingRegion.boundingBox.toImageCoordinates(size, origin: .upperLeft)), from: "document"))
                        }
                    }
                }
                // Paragraph lines: each line its own element, so a column of short labels reads one by one.
                for para in doc.paragraphs {
                    for line in para.lines {
                        guard let best = line.topCandidates(1).first else { continue }
                        let s = best.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !s.isEmpty else { continue }
                        let r = toScreen(line.boundingBox.toImageCoordinates(size, origin: .upperLeft))
                        // Not twice: a line the title, a list or a table already gave.
                        if elements.contains(where: { $0.label == s && abs($0.rect.midY - r.midY) < 6 }) { continue }
                        elements.append(Element(kind: .text, label: s, rect: r, from: "document"))
                    }
                }
            }
            notes.append("document \(elements.count) in \(ms(t0))")
        } catch {
            notes.append("document failed: \(error.localizedDescription)")
        }

        // 2. Boxes: a button is text in a box the size of a button; a box with no text is an icon button; a small
        // square beside a line is a check box.
        let t1 = Date()
        do {
            var request = DetectContoursRequest()
            request.contrastAdjustment = 1.5
            request.detectsDarkOnLight = true
            let obs = try await request.perform(on: image)
            var boxes: [CGRect] = []
            func gather(_ c: ContoursObservation.Contour, depth: Int) {
                let b = toScreen(c.boundingBox.toImageCoordinates(size, origin: .upperLeft))
                let control = b.height >= 14 && b.height <= 64 && b.width >= 12 && b.width <= 420
                if control, c.pointCount >= 4 { boxes.append(b) }
                if depth < 6 { for k in c.childContours { gather(k, depth: depth + 1) } }
            }
            for c in obs.topLevelContours { gather(c, depth: 0) }
            var buttons = 0, checks = 0, icons = 0
            for b in boxes {
                let inside = elements.indices.filter { i in
                    let r = elements[i].rect
                    return b.intersection(r).width >= r.width * 0.8 && b.intersection(r).height >= r.height * 0.8 && b.width <= r.width * 4 + 40
                }
                if inside.count == 1, elements[inside[0]].kind.rank < 2, elements[inside[0]].label.split(separator: " ").count <= 5 {
                    elements[inside[0]].kind = .button; elements[inside[0]].from = "box"; buttons += 1
                } else if inside.isEmpty, b.width <= 44, b.height <= 44, abs(b.width - b.height) <= 6 {
                    // A square beside a line's start: its check box; alone: an icon.
                    if let i = elements.firstIndex(where: { abs($0.rect.midY - b.midY) < 8 && $0.rect.minX > b.maxX && $0.rect.minX - b.maxX < 24 && $0.kind.rank < 2 }) {
                        elements[i].kind = .checkbox; elements[i].from = "box"; checks += 1
                    } else if !elements.contains(where: { $0.rect.intersects(b) }) {
                        elements.append(Element(kind: .icon, label: "", rect: b, from: "box")); icons += 1
                    }
                }
            }
            notes.append("boxes \(boxes.count): \(buttons) buttons, \(checks) check boxes, \(icons) icons in \(ms(t1))")
        } catch {
            notes.append("contours failed: \(error.localizedDescription)")
        }

        // 3. The model's view of the screen.
        let t2 = Date()
        #if canImport(FoundationModels)
        if #available(macOS 27.0, *) {
            let model = SystemLanguageModel.default
            if case .available = model.availability, model.capabilities.contains(.vision) {
                do {
                    let session = LanguageModelSession(instructions: """
                        You read the user interface in a screenshot of a Mac window for a blind person's screen reader. List every control and every piece of text you can see, top to bottom then left to right. \
                        For each give its kind (one of: button, link, text field, check box, switch, tab, menu, slider, heading, text, list item, icon, image), its label exactly as written (an icon with no text: a short name for what it shows), \
                        and the position of its centre as a percentage of the window's width (x) and height (y). Do not invent controls that are not there.
                        """)
                    let r = try await session.respond(to: Prompt { "List the controls and text in this window."; Attachment(image) }, generating: Interface.self,
                                                      options: GenerationOptions(maximumResponseTokens: 2000))
                    var refined = 0, added = 0
                    for g in r.content.elements {
                        let kind = Kind(rawValue: g.kind.lowercased()) ?? .text
                        let p = CGPoint(x: frame.minX + frame.width * CGFloat(min(100, max(0, g.x))) / 100, y: frame.minY + frame.height * CGFloat(min(100, max(0, g.y))) / 100)
                        let label = g.label.trimmingCharacters(in: .whitespacesAndNewlines)
                        // The same thing seen by Vision: by label, or by place for an icon. The model's kind wins for a control.
                        if let i = elements.firstIndex(where: { e in
                            (!label.isEmpty && similar(e.label, label) && hypot(e.rect.midX - p.x, e.rect.midY - p.y) < frame.width * 0.12)
                            || (e.label.isEmpty && hypot(e.rect.midX - p.x, e.rect.midY - p.y) < 20)
                        }) {
                            if kind.rank > elements[i].kind.rank || (elements[i].kind == .icon && !label.isEmpty) {
                                elements[i].kind = kind == .text && elements[i].kind == .icon ? .icon : kind
                                if elements[i].label.isEmpty { elements[i].label = label }
                                elements[i].from = "model"; refined += 1
                            }
                        } else if kind.rank == 2 || kind == .icon || kind == .image {
                            elements.append(Element(kind: kind, label: label, rect: CGRect(x: p.x - 12, y: p.y - 12, width: 24, height: 24), from: "model")); added += 1
                        }
                    }
                    notes.append("model \(r.content.elements.count): \(refined) refined, \(added) added in \(ms(t2))")
                } catch {
                    notes.append("model failed in \(ms(t2)): \(error.localizedDescription)")
                }
            } else { notes.append("no model that sees") }
        }
        #endif

        // Reading order: bands 24 points tall, left to right within a band.
        elements.sort { a, b in
            let ba = Int(a.rect.midY / 24), bb = Int(b.rect.midY / 24)
            return ba != bb ? ba < bb : a.rect.minX < b.rect.minX
        }
        return Detection(elements: elements, note: notes.joined(separator: "; "))
    }

    nonisolated private static func ms(_ since: Date) -> String { "\(Int(Date().timeIntervalSince(since) * 1000)) ms" }

    /// The same label, allowing the model's tidying (case, trailing punctuation, an ellipsis).
    nonisolated static func similar(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let x = norm(a), y = norm(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x == y || (x.count >= 4 && (x.hasPrefix(y) || y.hasPrefix(x)))
    }

    #if canImport(FoundationModels)
    @available(macOS 27.0, *)
    @Generable(description: "The controls and text in a window, in reading order")
    nonisolated struct Interface {
        @Guide(description: "Every control and piece of text, top to bottom then left to right")
        var elements: [GeneratedElement]
    }
    @available(macOS 27.0, *)
    @Generable
    nonisolated struct GeneratedElement {
        @Guide(description: "One of: button, link, text field, check box, switch, tab, menu, slider, heading, text, list item, icon, image")
        var kind: String
        @Guide(description: "The label exactly as written; for an icon with no text, a short name for what it shows")
        var label: String
        @Guide(description: "Centre, percent of the window's width, 0 to 100", .range(0...100))
        var x: Int
        @Guide(description: "Centre, percent of the window's height, 0 to 100", .range(0...100))
        var y: Int
    }
    #endif
}
