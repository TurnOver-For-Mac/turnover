// SPDX-License-Identifier: GPL-3.0-or-later
// Pages longer than one pass of the browse mode copy (issue 227): a long chat in the ChatGPT app was read only to its
// first 6,000 elements, and reading it again from the top gave the same part back, so its end was never reached.
// The pages here are made up, and the limit is lowered so they need several passes.
import Foundation
import ApplicationServices
import TurnOverCore
import TurnOverAX
import AXFixtures
import os

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
        b.buildForInspection()
        var n = 0
        while b.isPartial, n < passes, b.buildMoreAtOnce() { n += 1 }
        return b
    }
    func ids(_ es: [AXUIElement]) -> [Int] { es.compactMap { AXReplay.id(of: $0) } }
    func spans(_ b: WebBuffer) -> [[Int]] { b.lines.map { [$0.start, $0.end] } }

    test("long page: an omitted element before the collection limit does not become the frontier") {
        var fixture = page(headings: 8)
        if let missing = fixture.nodes.firstIndex(where: { $0.id == 104 }) { fixture.nodes[missing].attrs["AXRole"] = nil }
        AXReplay.load(fixture)
        defer { AXReplay.unload() }
        let buffer = WebBuffer(webArea: AXReplay.root!) { root, focus, request in
            var limits = WebBufferCollection.Limits()
            limits.elements = 6
            return WebBufferCollection.collect(root: root, focus: focus, request: request, limits: limits)
        }
        buffer.build()
        waitForBuffer(buffer)
        expect(buffer.text as String, "Heading 1\nHeading 3\n", "the first pass skips the missing heading")
        check(buffer.canReadOn, "the collection stops at the later element limit")
        check(buffer.buildMoreAtOnce(), "reading on starts after the first pass")
        check((buffer.text as String).hasSuffix("End of page\n") && !buffer.isPartial, "the surviving page reaches its end")
    }

    test("long page: refreshes requested during read-on keep their callbacks") {
        AXReplay.load(page(headings: 8))
        let limit = WebBuffer.maxElements
        WebBuffer.maxElements = 3
        defer { WebBuffer.maxElements = limit; AXReplay.unload() }
        let buffer = WebBuffer(webArea: AXReplay.root!)
        buffer.buildForInspection()
        check(buffer.canReadOn, "the first publication has a frontier")
        AXReplay.load(page(headings: 8, firstText: "Updated first heading"))
        var finished: [String] = []
        buffer.buildMore { more in
            check(more, "the continuation added text")
            check((buffer.text as String).hasPrefix("Heading 1\n"), "continuation preserves the published prefix")
            finished.append("read on")
        }
        buffer.build { finished.append("first refresh") }
        buffer.build { finished.append("second refresh") }
        waitForBuffer(buffer)
        expect(finished, ["read on", "first refresh", "second refresh"])
        check((buffer.text as String).hasPrefix("Updated first heading\n"), "the refresh reread the changed prefix")
    }

    test("long page: losing the provider during read-on retains the partial publication") {
        AXReplay.load(page(headings: 8))
        let limit = WebBuffer.maxElements
        WebBuffer.maxElements = 3
        defer { WebBuffer.maxElements = limit; AXReplay.unload() }
        let buffer = WebBuffer(webArea: AXReplay.root!)
        buffer.buildForInspection()
        let before = buffer.text, revision = buffer.revision
        check(buffer.canReadOn, "the first publication has a frontier")
        AXReplay.unload()
        check(!buffer.buildMoreAtOnce(), "no text came back from the departed provider")
        expect(buffer.text as String, before as String)
        expect(buffer.revision, revision, "failure does not publish a replacement")
        check(buffer.isPartial && buffer.isDirty, "the cached page remains partial and due for refresh")
        check(!buffer.canReadOn, "the same failed request is not retried in a loop")
    }

    test("long page: read-on refuses a reused web area showing a different address") {
        var fixture = page(headings: 8)
        AXReplay.load(fixture)
        let limit = WebBuffer.maxElements
        WebBuffer.maxElements = 3
        defer { WebBuffer.maxElements = limit; AXReplay.unload() }
        let buffer = WebBuffer(webArea: AXReplay.root!)
        buffer.buildForInspection()
        check(buffer.canReadOn, "the first publication has a frontier")
        if let root = fixture.nodes.firstIndex(where: { $0.id == 0 }) { fixture.nodes[root].attrs["AXURL"] = .url("https://example.com/other") }
        AXReplay.load(fixture)
        var invalidated = false
        buffer.didInvalidate = { invalidated = true }
        check(!buffer.buildMoreAtOnce(), "nothing is appended across the address change")
        check(invalidated && buffer.lines.isEmpty, "the old publication is retired")
    }

    test("long page: a page longer than a pass is read on to its end, its first part where it was (issue 227)") {
        AXReplay.load(page(headings: 300))
        defer { AXReplay.unload() }
        let was = WebBuffer.maxElements
        WebBuffer.maxElements = 100
        defer { WebBuffer.maxElements = was }
        let b = WebBuffer(webArea: AXReplay.root!)
        b.buildForInspection()
        check(b.isPartial, "the first pass stops at the limit")
        check(!(b.text as String).contains("End of page"), "the end is not in the first part")
        let first = b.text as String, firstSpans = spans(b)
        var n = 0
        while b.isPartial, n < 20, b.buildMoreAtOnce() { n += 1 }
        check(!b.isPartial, "read on to the end")
        check((b.text as String).hasPrefix(first), "the first part's text is where it was")
        expect(Array(spans(b).prefix(firstSpans.count)), firstSpans, "the first part's lines are where they were")
        expect((b.text as String).split(separator: "\n").map(String.init), (1...300).map { "Heading \($0)" } + ["End of page"], "every heading once, in order, and the end")
        expect(b.passes, n + 1)
        check(!b.buildMoreAtOnce(), "nothing after the end")
    }

    test("long page: read on, the copy is the one a single read makes, wherever the passes stop") {
        AXReplay.load(page(headings: 300))
        defer { AXReplay.unload() }
        let whole = WebBuffer(webArea: AXReplay.root!)
        whole.buildForInspection()
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
        whole.buildForInspection()
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
        whole.buildForInspection()
        // The web area, One, Two and the link: the link's own text is the first element the limit turns away.
        let was = WebBuffer.maxElements
        WebBuffer.maxElements = 4
        defer { WebBuffer.maxElements = was }
        let parts = WebBuffer(webArea: AXReplay.root!)
        parts.buildForInspection()
        check(parts.isPartial, "stopped inside the link")
        check(!(parts.text as String).contains("Docs"), "the link's title is not read for it at the stop")
        var n = 0
        while parts.isPartial, n < 10, parts.buildMoreAtOnce() { n += 1 }
        expect(whole.text as String, "One. Two. Docs End of page\n", "read at once, one line")
        // The line being built at a stop ends there (its first part was in the copy already); the rest is a line of its own.
        expect(parts.text as String, "One. Two.\nDocs End of page\n", "read on, the same text, a line break where the pass stopped")
        expect((parts.text as String).components(separatedBy: "Docs").count - 1, 1, "the link read once")
        let at = (parts.text as NSString).range(of: "Docs").location
        check(parts.segment(at: at)?.isLink == true, "and read as a link")
    }

    test("long page: a page read to its end takes what has come after it (a chat's new reply) when it is read again") {
        // Merging #219 (10 Nov 2026): what came after the end of a page read whole comes with its next collection, in
        // the background, as any change does; reading on is for a page that stopped short.
        AXReplay.load(page(headings: 5))
        defer { AXReplay.unload() }
        let b = WebBuffer(webArea: AXReplay.root!)
        b.buildForInspection()
        check(!b.isPartial, "read to its end")
        let before = b.text as String
        check(!b.buildMoreAtOnce(), "nothing to read on from a page read whole")
        AXReplay.load(page(headings: 5, after: 2))
        b.isDirty = true
        b.buildForInspection()
        expect(b.text as String, before + "Heading 6\nHeading 7\n", "added at the end, the rest where it was")
        check(!b.isDirty, "and taken as read")
    }

    test("long page: read again, a page read on keeps the reader's place, and takes a changed page as it now is") {
        AXReplay.load(page(headings: 300))
        defer { AXReplay.unload() }
        let was = (WebBuffer.maxElements, WebBuffer.passesPerBuild)
        WebBuffer.maxElements = 100
        defer { WebBuffer.maxElements = was.0; WebBuffer.passesPerBuild = was.1 }
        let b = WebBuffer(webArea: AXReplay.root!)
        b.buildForInspection()
        var n = 0
        while b.isPartial, n < 20, b.buildMoreAtOnce() { n += 1 }
        let whole = b.text as String
        let deep = b.text.range(of: "Heading 280").location
        b.readingAt = deep
        // Read again: the page is read on, in the background as its first part is, as far as the reader before it is
        // published (merging #219, 10 Nov 2026: no longer one pass's time on main, so the reader's part is always
        // reached); the rest is let go, to be read on fresh.
        b.buildForInspection()
        check(whole.hasPrefix(b.text as String), "the copy as it was, as far as it goes")
        check((b.text as String).contains("Heading 280\n"), "past the reader")
        check(!b.isDirty, "and taken as read")
        var m = 0
        while b.isPartial, m < 20, b.buildMoreAtOnce() { m += 1 }
        expect(b.text as String, whole, "read on, the whole page again")
        // Said to have changed, with the time it needs: the reader's part is read again, here on to the end.
        WebBuffer.passesPerBuild = 50
        b.isDirty = true
        b.buildForInspection()
        expect(b.text as String, whole, "the reader's part read again, the same, to the end")
        check(b.passes > 1, "the copy of several passes")
        check(!b.isPartial, "to its end")
        check(!b.isDirty, "and taken as read")
        // A page changed at its top is taken as it now is, even short of the reader.
        AXReplay.load(page(headings: 300, firstText: "Heading one, renamed"))
        WebBuffer.passesPerBuild = 1
        b.buildForInspection()
        check((b.text as String).hasPrefix("Heading one, renamed\n"), "the changed page read again")
        check(b.isPartial, "as far as one pass goes")
        // A read that stops before it has anything keeps the copy it had (a page that has stopped answering), even
        // when the page said it changed.
        let had = b.text as String
        let seconds = WebBuffer.layoutSeconds
        WebBuffer.layoutSeconds = 0
        defer { WebBuffer.layoutSeconds = seconds }
        b.buildForInspection()
        expect(b.text as String, had, "a read with nothing in it keeps the copy")
        b.isDirty = true
        b.buildForInspection()
        expect(b.text as String, had, "and so does one after the page said it changed")
        // Another page in the same web area is never kept for: its copy is the new page's.
        b.newPage()
        b.buildForInspection()
        expect(b.text as String, "", "a new page read with nothing in it is empty")
    }

    test("long page: read again, the reader's part is read fresh: a heading changed near them, a reply added before the end") {
        AXReplay.load(page(headings: 300))
        defer { AXReplay.unload() }
        let was = WebBuffer.maxElements
        WebBuffer.maxElements = 100
        defer { WebBuffer.maxElements = was }
        let b = WebBuffer(webArea: AXReplay.root!)
        b.buildForInspection()
        var n = 0
        while b.isPartial, n < 20, b.buildMoreAtOnce() { n += 1 }
        let whole = b.text as String
        // A heading near the reader changes, with nothing said: read again, the copy has it, the rest where it was.
        var edited = page(headings: 300)
        if let i = edited.nodes.firstIndex(where: { $0.id == 100 + 2 * 290 + 1 }) { edited.nodes[i].attrs["AXValue"] = .string("Heading 290, edited") }
        AXReplay.load(edited)
        b.readingAt = b.text.range(of: "Heading 285").location
        b.buildForInspection()
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
        check(!b.buildMoreAtOnce(), "nothing after the end itself")
        b.buildForInspection()
        check((b.text as String).hasSuffix("Heading 300\nA new reply\nEnd of page\n"), "the reply read where it is, before the end")
    }

    test("long page: read again with the end of the page taken away, the copy ends where the page now does") {
        AXReplay.load(page(headings: 300))
        defer { AXReplay.unload() }
        let was = WebBuffer.maxElements
        WebBuffer.maxElements = 100
        defer { WebBuffer.maxElements = was }
        let b = WebBuffer(webArea: AXReplay.root!)
        b.buildForInspection()
        var n = 0
        while b.isPartial, n < 20, b.buildMoreAtOnce() { n += 1 }
        b.readingAt = b.text.range(of: "Heading 280").location
        // Headings 296 to 300 gone, the rest as it was.
        AXReplay.load(page(headings: 295))
        b.buildForInspection()
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
        b.buildForInspection()
        var n = 0
        while b.isPartial, n < 40, b.buildMoreAtOnce() { n += 1 }
        check(!b.isPartial && (b.text as String).hasSuffix("Heading 1000\nEnd of page\n"), "read to the end")
        b.readingAt = b.text.range(of: "Heading 120\n").location
        var edited = page(headings: 1000)
        if let i = edited.nodes.firstIndex(where: { $0.id == 100 + 2 * 800 + 1 }) { edited.nodes[i].attrs["AXValue"] = .string("Heading 800, edited") }
        AXReplay.load(edited)
        b.isDirty = true
        b.buildForInspection()
        check((b.text as String).contains("Heading 120\n"), "the reader's part read again")
        check(!(b.text as String).contains("Heading 800\n"), "what was past it, not read again, is not kept")
        check(b.isPartial, "the rest to read on")
        var m = 0
        while b.isPartial, m < 40, b.buildMoreAtOnce() { m += 1 }
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
        b.buildForInspection()
        check(b.isPartial, "stopped among the empty containers")
        check(!b.buildMoreAtOnce(), "a pass with no text")
        check(b.isPartial && b.canReadOn, "and still somewhere to read on from")
        var n = 0
        while b.isPartial, n < 10, !b.buildMoreAtOnce() { n += 1 }
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
        b.buildForInspection()
        check((b.text as String).contains("Docs"), "the link's title read")
    }

    // MARK: Plain elements read short, and a long page filled in quietly (10 Nov 2026)

    /// A page with every kind of thing on it: a heading, a paragraph in a plain group with a link, a landmark, a button,
    /// a tick box, a list of two, and a table of one row.
    func mixedPage() -> AXFixture {
        var f = AXFixture(app: "T", bundle: "t", recorded: "", root: 0, application: 1, focus: 0, nodes: [])
        func n(_ id: Int, _ role: String, _ parent: Int, _ children: [Int] = [], _ extra: [String: AXFixture.Value] = [:]) -> AXFixture.Node {
            var a: [String: AXFixture.Value] = ["AXRole": .string(role), "AXParent": .element(parent)]
            if !children.isEmpty { a["AXChildren"] = .elements(children) }
            for (k, v) in extra { a[k] = v }
            return .init(id: id, attrs: a)
        }
        f.nodes = [n(0, "AXWebArea", 1, [10, 20, 25, 30, 31, 40, 50], ["AXURL": .url("https://example.com/mixed")]),
                   .init(id: 1, attrs: ["AXRole": .string("AXApplication"), "AXTitle": .string("T"), "AXChildren": .elements([0])]),
                   n(10, "AXHeading", 0, [11], ["AXValue": .number(1)]), n(11, "AXStaticText", 10, [], ["AXValue": .string("Sample page")]),
                   n(20, "AXGroup", 0, [21, 22]), n(21, "AXStaticText", 20, [], ["AXValue": .string("Read the")]),
                   n(22, "AXLink", 20, [23], ["AXURL": .url("https://example.com/guide")]), n(23, "AXStaticText", 22, [], ["AXValue": .string("guide")]),
                   n(25, "AXGroup", 0, [26], ["AXSubrole": .string("AXLandmarkNavigation"), "AXDescription": .string("Site")]),
                   n(26, "AXStaticText", 25, [], ["AXValue": .string("Home")]),
                   n(30, "AXButton", 0, [], ["AXTitle": .string("Save"), "AXEnabled": .bool(true)]),
                   n(31, "AXCheckBox", 0, [], ["AXTitle": .string("Remember me"), "AXValue": .number(1), "AXEnabled": .bool(true)]),
                   n(40, "AXList", 0, [41, 43]),
                   n(41, "AXGroup", 40, [42], ["AXSubrole": .string("AXListItem")]), n(42, "AXStaticText", 41, [], ["AXValue": .string("First")]),
                   n(43, "AXGroup", 40, [44], ["AXSubrole": .string("AXListItem")]), n(44, "AXStaticText", 43, [], ["AXValue": .string("Second")]),
                   n(50, "AXTable", 0, [51]), n(51, "AXRow", 50, [52]), n(52, "AXCell", 51, [53]),
                   n(53, "AXStaticText", 52, [], ["AXValue": .string("Cell")])]
        return f
    }

    test("page collection: plain text and plain groups read short give the same page, with fewer questions") {
        AXReplay.load(mixedPage())
        defer { AXReplay.unload() }
        @MainActor func read(short: Bool) -> (buffer: WebBuffer, plain: Int, total: Int, questions: Int) {
            var limits = WebBufferCollection.Limits()
            limits.plainElementsShort = short
            let fixed = limits
            let counts = OSAllocatedUnfairLock(initialState: (0, 0))
            let b = WebBuffer(webArea: AXReplay.root!) { root, focus, request in
                let c = WebBufferCollection.collect(root: root, focus: focus, request: request, limits: fixed)
                counts.withLock { $0 = (c.plainElements, c.snapshot.nodes.count) }
                return c
            }
            b.collectionLimits = fixed
            let before = AXStats.calls
            b.build(); waitForBuffer(b)
            let c = counts.withLock { $0 }
            return (b, c.0, c.1, AXStats.calls - before)
        }
        let full = read(short: false), short = read(short: true)
        check(full.buffer.lines.count >= 8, "the page was read (\(full.buffer.lines.count) lines)")
        expect(short.buffer.text as String, full.buffer.text as String, "the same text")
        expect(short.buffer.lines.map { [$0.start, $0.end] }, full.buffer.lines.map { [$0.start, $0.end] }, "the same lines")
        expect(short.buffer.lines.map { $0.fields.joined(separator: "/") }, full.buffer.lines.map { $0.fields.joined(separator: "/") }, "the same words for each control")
        expect(short.buffer.lines.map { $0.entering.count }, full.buffer.lines.map { $0.entering.count }, "the same containers announced")
        expect(short.buffer.containers.count, full.buffer.containers.count, "the same containers")
        expect(full.plain, 0, "nothing read short with it off")
        // The seven texts, the group with no subrole, the two list items, the row and the cell; not the heading, the
        // link, the landmark, the list, the table or the controls.
        expect(short.plain, 12, "the texts, the plain group, the list items, the row and the cell")
        check(short.questions + short.plain <= full.questions, "the short path still saves provider calls (\(short.questions) against \(full.questions))")
        expect(AXSnapshot.takeMissed().count, 0, "and nothing asked of them that was not collected")
    }

    test("page collection: an attribute asked of a plain element that was not collected is counted, for the log") {
        let text = AXUIElementCreateApplication(910_010)
        let snapshot = AXSnapshot(nodes: [ElementKey(text): .init(attributes: ["AXRole": .string("AXStaticText"), "AXValue": .string("Hello")], isPlain: true)])
        _ = AXSnapshot.takeMissed()
        snapshot.with {
            expect(text.string(kAXValueAttribute), "Hello")
            check(text.attr("AXVisited") == nil, "absent")
            check(text.attr("AXVisited") == nil, "absent again")
        }
        expect(AXSnapshot.takeMissed(), ["AXVisited": 2])
        expect(AXSnapshot.takeMissed().count, 0, "taken once")
    }

    test("long page: its first reading carries on to the end by itself, and nothing is said about its length") {
        AXReplay.load(page(headings: 300))
        let was = (WebBuffer.maxElements, WebBuffer.fillsOn), sink = Speech.sink
        WebBuffer.maxElements = 100; WebBuffer.fillsOn = true
        var said = ""
        Speech.sink = { said += $0 + " " }
        defer { AXReplay.unload(); WebBuffer.maxElements = was.0; WebBuffer.fillsOn = was.1; Speech.sink = sink }
        let b = WebBuffer(webArea: AXReplay.root!)
        b.build()
        waitForBuffer(b)
        check((b.text as String).hasPrefix("Heading 1\n"), "its first part is there at once")
        let until = Date().addingTimeInterval(5)
        while b.isPartial || b.canReadOn, Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        check(!b.isPartial, "read on to the end by itself")
        expect((b.text as String).split(separator: "\n").map(String.init), (1...300).map { "Heading \($0)" } + ["End of page"], "every heading once, in order, and the end")
        check(b.passes > 2, "in several passes (\(b.passes))")
        check(!said.contains("read in part"), "nothing said about its length: \(said)")
    }
}
