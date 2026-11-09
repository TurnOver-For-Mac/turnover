// SPDX-License-Identifier: GPL-3.0-or-later
// Pages longer than one pass of the browse mode copy (issue 227): a long chat in the ChatGPT app was read only to its
// first 6,000 elements, and reading it again from the top gave the same part back, so its end was never reached.
// The pages here are made up, and the limit is lowered so they need several passes.
import Foundation
import ApplicationServices
import TurnOverCore
import AXFixtures

func longPageTests() {
    /// A page of `count` headings ("Heading 1" …), each with its text, then "End of page", then `after` more headings
    /// (what a chat adds after it was read). The web area is 0, the application 1.
    func page(headings count: Int, firstText: String = "Heading 1", after: Int = 0) -> AXFixture {
        var f = AXFixture(app: "T", bundle: "t", recorded: "", root: 0, application: 1, focus: 0, nodes: [])
        var kids: [Int] = []
        func heading(_ k: Int) {
            let h = 100 + 2 * k, t = h + 1
            kids.append(h)
            f.nodes.append(.init(id: h, attrs: ["AXRole": .string("AXHeading"), "AXValue": .number(2), "AXParent": .element(0), "AXChildren": .elements([t])]))
            f.nodes.append(.init(id: t, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string(k == 1 ? firstText : "Heading \(k)"), "AXParent": .element(h)]))
        }
        for k in 1...count { heading(k) }
        kids.append(50)
        f.nodes.append(.init(id: 50, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("End of page"), "AXParent": .element(0)]))
        if after > 0 { for k in (count + 1)...(count + after) { heading(k) } }
        f.nodes.append(.init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.com/long"), "AXParent": .element(1), "AXChildren": .elements(kids)]))
        f.nodes.append(.init(id: 1, attrs: ["AXRole": .string("AXApplication"), "AXTitle": .string("T"), "AXChildren": .elements([0])]))
        return f
    }
    /// A list of `count` items ("Item 1" …) and then "End of page": a list the passes stop inside.
    func list(items count: Int) -> AXFixture {
        var f = AXFixture(app: "T", bundle: "t", recorded: "", root: 0, application: 1, focus: 0, nodes: [])
        var items: [Int] = []
        for k in 1...count {
            let i = 100 + 2 * k, t = i + 1
            items.append(i)
            f.nodes.append(.init(id: i, attrs: ["AXRole": .string("AXGroup"), "AXSubrole": .string("AXListItem"), "AXParent": .element(2), "AXChildren": .elements([t])]))
            f.nodes.append(.init(id: t, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("Item \(k)"), "AXParent": .element(i)]))
        }
        f.nodes.append(.init(id: 2, attrs: ["AXRole": .string("AXList"), "AXParent": .element(0), "AXChildren": .elements(items)]))
        f.nodes.append(.init(id: 50, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("End of page"), "AXParent": .element(0)]))
        f.nodes.append(.init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.com/list"), "AXParent": .element(1), "AXChildren": .elements([2, 50])]))
        f.nodes.append(.init(id: 1, attrs: ["AXRole": .string("AXApplication"), "AXTitle": .string("T"), "AXChildren": .elements([0])]))
        return f
    }
    /// The buffer read with `limit` elements a pass, then read on until it ends (at most `passes` more).
    func readInParts(_ limit: Int, passes: Int = 40) -> WebBuffer {
        let was = WebBuffer.maxElements
        WebBuffer.maxElements = limit
        defer { WebBuffer.maxElements = was }
        let b = WebBuffer(webArea: AXReplay.root!)
        b.build()
        var n = 0
        while b.isPartial, n < passes, b.buildMore() { n += 1 }
        return b
    }
    func ids(_ es: [AXUIElement]) -> [Int] { es.compactMap { AXReplay.id(of: $0) } }
    func spans(_ b: WebBuffer) -> [[Int]] { b.lines.map { [$0.start, $0.end] } }

    test("long page: a page longer than a pass is read on to its end, its first part where it was (issue 227)") {
        AXReplay.load(page(headings: 300))
        defer { AXReplay.unload() }
        let was = WebBuffer.maxElements
        WebBuffer.maxElements = 100
        defer { WebBuffer.maxElements = was }
        let b = WebBuffer(webArea: AXReplay.root!)
        b.build()
        check(b.isPartial, "the first pass stops at the limit")
        check(!(b.text as String).contains("End of page"), "the end is not in the first part")
        let first = b.text as String, firstSpans = spans(b)
        var n = 0
        while b.isPartial, n < 20, b.buildMore() { n += 1 }
        check(!b.isPartial, "read on to the end")
        check((b.text as String).hasPrefix(first), "the first part's text is where it was")
        expect(Array(spans(b).prefix(firstSpans.count)), firstSpans, "the first part's lines are where they were")
        expect((b.text as String).split(separator: "\n").map(String.init), (1...300).map { "Heading \($0)" } + ["End of page"], "every heading once, in order, and the end")
        expect(b.passes, n + 1)
        check(!b.buildMore(), "nothing after the end")
    }

    test("long page: read on, the copy is the one a single read makes, wherever the passes stop") {
        AXReplay.load(page(headings: 300))
        defer { AXReplay.unload() }
        let whole = WebBuffer(webArea: AXReplay.root!)
        whole.build()
        check(!whole.isPartial, "the page fits one pass at the usual limit")
        // 100: each pass stops between a heading and its text; 77: between two headings.
        for limit in [100, 77] {
            let parts = readInParts(limit)
            check(!parts.isPartial, "\(limit) a pass: read to the end")
            expect(parts.text as String, whole.text as String, "\(limit) a pass: the text")
            expect(spans(parts), spans(whole), "\(limit) a pass: the lines")
            expect(parts.lines.map { ids($0.entering) }, whole.lines.map { ids($0.entering) }, "\(limit) a pass: each heading announced once, where it starts")
            expect(parts.lines.map { AXReplay.id(of: $0.element) ?? -1 }, whole.lines.map { AXReplay.id(of: $0.element) ?? -1 }, "\(limit) a pass: each line's element")
        }
    }

    test("long page: a list the passes stop inside has one span, its first item to its last, and is announced once") {
        AXReplay.load(list(items: 200))
        defer { AXReplay.unload() }
        let whole = WebBuffer(webArea: AXReplay.root!)
        whole.build()
        let parts = readInParts(64)
        check(parts.passes > 3, "several passes")
        expect(parts.text as String, whole.text as String, "the text")
        expect(parts.containers.map { [$0.start, $0.end, AXReplay.id(of: $0.element) ?? -1] }, whole.containers.map { [$0.start, $0.end, AXReplay.id(of: $0.element) ?? -1] }, "the list's span")
        expect(parts.containers.count, 1, "one span for the list")
        expect(parts.lines.filter { ids($0.entering).contains(2) }.count, 1, "the list announced once")
    }

    test("long page: a link a pass stops inside is read once, by its text, not by its title as well") {
        var f = AXFixture(app: "T", bundle: "t", recorded: "", root: 0, application: 1, focus: 0, nodes: [])
        f.nodes = [
            .init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.com/link"), "AXParent": .element(1), "AXChildren": .elements([10, 11, 20, 50])]),
            .init(id: 10, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("One."), "AXParent": .element(0)]),
            .init(id: 11, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("Two."), "AXParent": .element(0)]),
            .init(id: 20, attrs: ["AXRole": .string("AXLink"), "AXTitle": .string("Docs"), "AXParent": .element(0), "AXChildren": .elements([21])]),
            .init(id: 21, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("Docs"), "AXParent": .element(20)]),
            .init(id: 50, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("End of page"), "AXParent": .element(0)]),
            .init(id: 1, attrs: ["AXRole": .string("AXApplication"), "AXTitle": .string("T"), "AXChildren": .elements([0])]),
        ]
        AXReplay.load(f)
        defer { AXReplay.unload() }
        let whole = WebBuffer(webArea: AXReplay.root!)
        whole.build()
        // The web area, One, Two and the link: the link's own text is the first element the limit turns away.
        let was = WebBuffer.maxElements
        WebBuffer.maxElements = 4
        defer { WebBuffer.maxElements = was }
        let parts = WebBuffer(webArea: AXReplay.root!)
        parts.build()
        check(parts.isPartial, "stopped inside the link")
        check(!(parts.text as String).contains("Docs"), "the link's title is not read for it at the stop")
        var n = 0
        while parts.isPartial, n < 10, parts.buildMore() { n += 1 }
        expect(whole.text as String, "One. Two. Docs End of page\n", "read at once, one line")
        // The line being built at a stop ends there (its first part was in the copy already); the rest is a line of its own.
        expect(parts.text as String, "One. Two.\nDocs End of page\n", "read on, the same text, a line break where the pass stopped")
        expect((parts.text as String).components(separatedBy: "Docs").count - 1, 1, "the link read once")
        let at = (parts.text as NSString).range(of: "Docs").location
        check(parts.segment(at: at)?.isLink == true, "and read as a link")
    }

    test("long page: a page read to its end reads on from its end when more has come after it (a chat's new reply)") {
        AXReplay.load(page(headings: 5))
        defer { AXReplay.unload() }
        let b = WebBuffer(webArea: AXReplay.root!)
        b.build()
        check(!b.isPartial, "read to its end")
        let before = b.text as String
        check(!b.buildMore(), "nothing after its end yet")
        AXReplay.load(page(headings: 5, after: 2))
        check(b.buildMore(), "what came after the end is read on")
        expect(b.text as String, before + "Heading 6\nHeading 7\n", "added at the end, the rest where it was")
        check(!b.buildMore(), "and then nothing more")
    }

    test("long page: read again, a page read on keeps the reader's place, and takes a changed page as it now is") {
        AXReplay.load(page(headings: 300))
        defer { AXReplay.unload() }
        let was = (WebBuffer.maxElements, WebBuffer.passesPerBuild)
        WebBuffer.maxElements = 100
        defer { WebBuffer.maxElements = was.0; WebBuffer.passesPerBuild = was.1 }
        let b = WebBuffer(webArea: AXReplay.root!)
        b.build()
        var n = 0
        while b.isPartial, n < 20, b.buildMore() { n += 1 }
        let whole = b.text as String
        let deep = b.text.range(of: "Heading 280").location
        b.readingAt = deep
        // Read again with time for one pass after the first: the copy is kept up to the reader's part, which is read
        // again on past the reader; the rest is let go, to be read on fresh.
        WebBuffer.passesPerBuild = 1
        b.build()
        check(whole.hasPrefix(b.text as String), "the copy as it was, as far as it goes")
        check((b.text as String).contains("Heading 280\n"), "past the reader")
        check(b.isPartial, "the rest to read on")
        check(!b.isDirty, "and taken as read")
        var m = 0
        while b.isPartial, m < 20, b.buildMore() { m += 1 }
        expect(b.text as String, whole, "read on, the whole page again")
        // Said to have changed, with the time it needs: the reader's part is read again, here on to the end.
        WebBuffer.passesPerBuild = 50
        b.isDirty = true
        b.build()
        expect(b.text as String, whole, "the reader's part read again, the same, to the end")
        check(b.passes > 1, "the copy of several passes")
        check(!b.isPartial, "to its end")
        check(!b.isDirty, "and taken as read")
        // A page changed at its top is taken as it now is, even short of the reader.
        AXReplay.load(page(headings: 300, firstText: "Heading one, renamed"))
        WebBuffer.passesPerBuild = 1
        b.build()
        check((b.text as String).hasPrefix("Heading one, renamed\n"), "the changed page read again")
        check(b.isPartial, "as far as one pass goes")
        // A read that stops before it has anything keeps the copy it had (a page that has stopped answering), even
        // when the page said it changed.
        let had = b.text as String
        let seconds = WebBuffer.buildSeconds
        WebBuffer.buildSeconds = 0
        defer { WebBuffer.buildSeconds = seconds }
        b.build()
        expect(b.text as String, had, "a read with nothing in it keeps the copy")
        b.isDirty = true
        b.build()
        expect(b.text as String, had, "and so does one after the page said it changed")
        // Another page in the same web area is never kept for: its copy is the new page's.
        b.newPage()
        b.build()
        expect(b.text as String, "", "a new page read with nothing in it is empty")
    }

    test("long page: read again, the reader's part is read fresh: a heading changed near them, a reply added before the end") {
        AXReplay.load(page(headings: 300))
        defer { AXReplay.unload() }
        let was = WebBuffer.maxElements
        WebBuffer.maxElements = 100
        defer { WebBuffer.maxElements = was }
        let b = WebBuffer(webArea: AXReplay.root!)
        b.build()
        var n = 0
        while b.isPartial, n < 20, b.buildMore() { n += 1 }
        let whole = b.text as String
        // A heading near the reader changes, with nothing said: read again, the copy has it, the rest where it was.
        var edited = page(headings: 300)
        if let i = edited.nodes.firstIndex(where: { $0.id == 100 + 2 * 290 + 1 }) { edited.nodes[i].attrs["AXValue"] = .string("Heading 290, edited") }
        AXReplay.load(edited)
        b.readingAt = b.text.range(of: "Heading 285").location
        b.build()
        let now = b.text as String
        check(now.contains("Heading 290, edited\n"), "the change near the reader read")
        check(!now.contains("Heading 290\n"), "and the old text gone")
        let at = (whole as NSString).range(of: "Heading 250\n").location
        check(at != NSNotFound && now.hasPrefix((whole as NSString).substring(to: at)), "the copy before the reader's part kept as it was")
        check(now.hasSuffix("Heading 300\nEnd of page\n"), "on to the end")
        // A reply put in before the end marker (the message box stays last): read again with the reader at the end.
        var added = page(headings: 300)
        if let i = added.nodes.firstIndex(where: { $0.id == 0 }), case .elements(var kids) = added.nodes[i].attrs["AXChildren"] {
            kids.insert(900, at: kids.count - 1)
            added.nodes[i].attrs["AXChildren"] = .elements(kids)
            added.nodes.append(.init(id: 900, attrs: ["AXRole": .string("AXHeading"), "AXValue": .number(2), "AXParent": .element(0), "AXChildren": .elements([901])]))
            added.nodes.append(.init(id: 901, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("A new reply"), "AXParent": .element(900)]))
        }
        AXReplay.load(added)
        b.readingAt = b.text.length - 1
        check(!b.buildMore(), "nothing after the end itself")
        b.build()
        check((b.text as String).hasSuffix("Heading 300\nA new reply\nEnd of page\n"), "the reply read where it is, before the end")
    }

    test("long page: read again with the end of the page taken away, the copy ends where the page now does") {
        AXReplay.load(page(headings: 300))
        defer { AXReplay.unload() }
        let was = WebBuffer.maxElements
        WebBuffer.maxElements = 100
        defer { WebBuffer.maxElements = was }
        let b = WebBuffer(webArea: AXReplay.root!)
        b.build()
        var n = 0
        while b.isPartial, n < 20, b.buildMore() { n += 1 }
        b.readingAt = b.text.range(of: "Heading 280").location
        // Headings 296 to 300 gone, the rest as it was.
        AXReplay.load(page(headings: 295))
        b.build()
        let now = b.text as String
        check(now.hasSuffix("Heading 295\nEnd of page\n"), "the copy ends where the page now does")
        check(!now.contains("Heading 296"), "nothing taken away is left")
        check(!b.isPartial, "to its end")
    }

    test("long page: read again after a change past the reader's part, the change is read when the reader gets there") {
        AXReplay.load(page(headings: 1000))
        defer { AXReplay.unload() }
        let was = WebBuffer.maxElements
        WebBuffer.maxElements = 100
        defer { WebBuffer.maxElements = was }
        let b = WebBuffer(webArea: AXReplay.root!)
        b.build()
        var n = 0
        while b.isPartial, n < 40, b.buildMore() { n += 1 }
        check(!b.isPartial && (b.text as String).hasSuffix("Heading 1000\nEnd of page\n"), "read to the end")
        b.readingAt = b.text.range(of: "Heading 120\n").location
        var edited = page(headings: 1000)
        if let i = edited.nodes.firstIndex(where: { $0.id == 100 + 2 * 800 + 1 }) { edited.nodes[i].attrs["AXValue"] = .string("Heading 800, edited") }
        AXReplay.load(edited)
        b.isDirty = true
        b.build()
        check((b.text as String).contains("Heading 120\n"), "the reader's part read again")
        check(!(b.text as String).contains("Heading 800\n"), "what was past it, not read again, is not kept")
        check(b.isPartial, "the rest to read on")
        var m = 0
        while b.isPartial, m < 40, b.buildMore() { m += 1 }
        check((b.text as String).contains("Heading 800, edited\n"), "read on, the change is there")
        check((b.text as String).hasSuffix("Heading 1000\nEnd of page\n"), "to the end")
    }

    test("long page: a pass that finds no text leaves the rest to read on, past a stretch of empty containers") {
        var f = AXFixture(app: "T", bundle: "t", recorded: "", root: 0, application: 1, focus: 0, nodes: [])
        var kids = [10]
        f.nodes.append(.init(id: 10, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("Before."), "AXParent": .element(0)]))
        for k in 0..<120 { kids.append(1000 + k); f.nodes.append(.init(id: 1000 + k, attrs: ["AXRole": .string("AXGroup"), "AXParent": .element(0), "AXChildren": .elements([])])) }
        kids.append(20)
        f.nodes.append(.init(id: 20, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("After."), "AXParent": .element(0)]))
        f.nodes.append(.init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.com/empty"), "AXParent": .element(1), "AXChildren": .elements(kids)]))
        f.nodes.append(.init(id: 1, attrs: ["AXRole": .string("AXApplication"), "AXTitle": .string("T"), "AXChildren": .elements([0])]))
        AXReplay.load(f)
        defer { AXReplay.unload() }
        let was = WebBuffer.maxElements
        WebBuffer.maxElements = 50
        defer { WebBuffer.maxElements = was }
        let b = WebBuffer(webArea: AXReplay.root!)
        b.build()
        check(b.isPartial, "stopped among the empty containers")
        check(!b.buildMore(), "a pass with no text")
        check(b.isPartial && b.canReadOn, "and still somewhere to read on from")
        var n = 0
        while b.isPartial, n < 10, !b.buildMore() { n += 1 }
        check((b.text as String).contains("After."), "the text after them read")
        check(!b.isPartial, "to the end")
    }

    test("long page: a link with only white space inside is read by its title, as before") {
        var f = AXFixture(app: "T", bundle: "t", recorded: "", root: 0, application: 1, focus: 0, nodes: [])
        f.nodes = [
            .init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.com/space"), "AXParent": .element(1), "AXChildren": .elements([20])]),
            .init(id: 20, attrs: ["AXRole": .string("AXLink"), "AXTitle": .string("Docs"), "AXParent": .element(0), "AXChildren": .elements([21])]),
            .init(id: 21, attrs: ["AXRole": .string("AXGroup"), "AXParent": .element(20), "AXChildren": .elements([22])]),
            .init(id: 22, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string(" "), "AXParent": .element(21)]),
            .init(id: 1, attrs: ["AXRole": .string("AXApplication"), "AXTitle": .string("T"), "AXChildren": .elements([0])]),
        ]
        AXReplay.load(f)
        defer { AXReplay.unload() }
        let b = WebBuffer(webArea: AXReplay.root!)
        b.build()
        check((b.text as String).contains("Docs"), "the link's title read")
    }
}
