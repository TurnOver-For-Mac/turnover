// SPDX-License-Identifier: GPL-3.0-or-later
// Controls that Safari (WebKit) hides inside a button-like container, and the search for the one that has the keyboard.
//
// 24 Nov 2026: on Steam's wishlist a row is one `div role=button tabindex=0` holding links and buttons. WebKit shows
// the row as one AXButton with no children, so the copy of the page holds one label for it, yet Tab stops on every
// hidden control, the browser reports the row as the focus at each stop, and TurnOver said nothing for seconds.
// Measured on a private test page (TODO-log-review-2026-11-24.md, facts 1 to 27): the row says AXFocused is false
// while a hidden control inside it has the keyboard, and that control gives the row as its parent and says AXFocused
// is true. The control is found by the text under the row (one piece after another), by the styled text of that
// stretch (placeholders for buttons and fields), and by a grid of points over the row.
//
// The search is written against `HiddenControlPage`, so that the tests use a made-up page and need no accessibility.
// Everything works with text markers, never with sums on the indexes WebKit hands back (an arithmetic trap in the first
// probe stopped it), and nothing is force-cast.
import Foundation
import ApplicationServices
import TurnOverAX

/// What the search needs to know of a page. `Element` is a thing on the page, `Marker` a place in its text.
nonisolated package protocol HiddenControlPage {
    associatedtype Element
    associatedtype Marker
    func isSame(_ a: Element, _ b: Element) -> Bool
    func isSameMarker(_ a: Marker, _ b: Marker) -> Bool
    /// The first and last place of an element's own text.
    func textRange(of element: Element) -> (start: Marker, end: Marker)?
    func element(at marker: Marker) -> Element?
    func parent(of element: Element) -> Element?
    func next(after marker: Marker) -> Marker?
    /// The elements the styled text between two places names: links, and the placeholders for buttons, fields and pictures.
    func styledElements(from start: Marker, to end: Marker, timeIsUp: () -> Bool) -> [Element]
    func canTakeFocus(_ element: Element) -> Bool
    func focusableAncestor(of element: Element) -> Element?
    /// What `AXFocused` says; nil when it cannot be asked.
    func isFocused(_ element: Element) -> Bool?
    /// A nameless group, which a field's inner editor shows as: a control with a real role is preferred over it.
    func isPlainGroup(_ element: Element) -> Bool
    /// The points of a grid over an element, in reading order.
    func gridPoints(over element: Element) -> [CGPoint]
    func element(atPoint point: CGPoint) -> Element?
}

/// Which step of the search found a control. Logged, so that the next pass over the logs can see how well it does.
nonisolated package enum HiddenSearchStage: String, Sendable {
    case remembered, text, styled, grid
}

nonisolated package struct HiddenSearchResult<Element> {
    /// Every control found inside the container, in the order found.
    package var controls: [Element] = []
    /// The one of them that says it has the keyboard.
    package var focused: Element?
    package var stage: HiddenSearchStage?
    /// How many pieces of text were stepped over, and how many points of the grid were asked.
    package var hops = 0
    package var points = 0
    /// Whether the time or the cap ran out before the search was done.
    package var cutShort = false
}

nonisolated package enum HiddenControlSearch {
    /// How many pieces of text one search steps over at most.
    package static let hopCap = 150

    /// A control that takes the keyboard, found from something inside the container: the thing itself if it takes the
    /// keyboard, else the nearest thing above it that does. Only what gives the container as its parent counts (that
    /// bounds the search, as the container's own text range can be wrong at its end), and never the container.
    package static func hiddenControl<P: HiddenControlPage>(from here: P.Element, in container: P.Element, page: P) -> P.Element? {
        if page.isSame(here, container) { return nil }
        if page.canTakeFocus(here) {
            guard let p = page.parent(of: here), page.isSame(p, container) else { return nil }
            return here
        }
        guard let above = page.focusableAncestor(of: here), !page.isSame(above, container),
              let p = page.parent(of: above), page.isSame(p, container) else { return nil }
        return above
    }

    /// The search. `known` are the controls found in this container before: they are asked first (nine take under a
    /// millisecond). `includeGrid` only with evidence that something hidden has the keyboard (design rule C), as the
    /// grid is the dear step (50 to 120 ms). `timeIsUp` is asked between requests.
    package static func search<P: HiddenControlPage>(in container: P.Element, page: P, known: [P.Element],
                                                    includeGrid: Bool, timeIsUp: () -> Bool) -> HiddenSearchResult<P.Element> {
        var result = HiddenSearchResult<P.Element>()
        var focusedOnes: [P.Element] = []
        func add(_ x: P.Element, stage: HiddenSearchStage) {
            guard !result.controls.contains(where: { page.isSame($0, x) }) else { return }
            result.controls.append(x)
            if page.isFocused(x) == true {
                focusedOnes.append(x)
                if result.stage == nil { result.stage = stage }
            }
        }
        /// Two controls saying focused (a field and its inner editor): the one with a real role.
        func finish() -> HiddenSearchResult<P.Element> {
            result.focused = focusedOnes.first(where: { !page.isPlainGroup($0) }) ?? focusedOnes.first
            return result
        }
        for x in known {
            if timeIsUp() { result.cutShort = true; return finish() }
            add(x, stage: .remembered)
        }
        if !focusedOnes.isEmpty { return finish() }
        // Text pieces, one after another from the container's first position, until a piece whose parent is not the
        // container (a piece that is the container itself is stepped over).
        guard let range = page.textRange(of: container) else { return finish() }
        var marker = range.start
        var stop = range.start
        var leftAt: P.Marker?
        while result.hops < hopCap {
            if timeIsUp() { result.cutShort = true; return finish() }
            guard let here = page.element(at: marker) else { break }
            let isContainer = page.isSame(here, container)
            let inside = isContainer || page.parent(of: here).map { page.isSame($0, container) } == true
            if !inside { leftAt = marker; break }
            if let x = hiddenControl(from: here, in: container, page: page) { add(x, stage: .text) }
            var from = marker
            if !isContainer {
                guard let own = page.textRange(of: here) else { break }
                stop = own.end
                from = own.end
            }
            guard let after = page.next(after: from), !page.isSameMarker(after, marker) else { break }
            marker = after
            result.hops += 1
        }
        if result.hops >= hopCap { result.cutShort = true }
        if !focusedOnes.isEmpty { return finish() }
        // The styled text of the same stretch. Its end is the place the walk left the container, as the container's
        // own range end can be wrong.
        if timeIsUp() { result.cutShort = true; return finish() }
        for named in page.styledElements(from: range.start, to: leftAt ?? stop, timeIsUp: timeIsUp) {
            if timeIsUp() { result.cutShort = true; return finish() }
            if let x = hiddenControl(from: named, in: container, page: page) { add(x, stage: .styled) }
        }
        if !focusedOnes.isEmpty || !includeGrid { return finish() }
        // A grid of points over the container: what the text position at each point belongs to. Stops at the first
        // control that says focused.
        var last: P.Element?
        for point in page.gridPoints(over: container) {
            if timeIsUp() { result.cutShort = true; return finish() }
            result.points += 1
            guard let here = page.element(atPoint: point) else { continue }
            if let l = last, page.isSame(l, here) { continue }
            last = here
            if let x = hiddenControl(from: here, in: container, page: page) {
                add(x, stage: .grid)
                if !focusedOnes.isEmpty { break }
            }
        }
        return finish()
    }
}

/// The decisions about a hidden focus, as pure functions of what was asked.
nonisolated package enum HiddenFocusDecision {
    /// What to do after a Tab when the browser still reports the container as the focus.
    package enum Next: Equatable { case pollOn, backOnContainer, search }

    /// - hasRecord: a hidden focus is recorded for this container.
    /// - recordedControlFocused: what the recorded control says, if there is one and it could be asked.
    /// - containerFocused: what the container says.
    package static func afterTabStillReported(hasRecord: Bool, recordedControlFocused: Bool?, containerFocused: Bool?) -> Next {
        if hasRecord {
            // An answer that did not come is unknown, not a move: ask again within the ceiling.
            if containerFocused == nil { return .pollOn }
            // Not moved yet: the control that had the keyboard still has it.
            if recordedControlFocused == true { return .pollOn }
            // The keyboard came back to the container itself.
            if containerFocused == true { return .backOnContainer }
            return .search
        }
        // Nothing hidden known: only a container that says it has no keyboard starts the search.
        return containerFocused == false ? .search : .pollOn
    }

    /// What to say when the search is over.
    package enum Outcome: Equatable {
        /// A found control says it has the keyboard: it is spoken as an ordinary focused object.
        case moved
        /// Something hidden has the keyboard and cannot be reached: a short true phrase.
        case fallback
        /// No evidence that anything hidden has the keyboard (an `aria-activedescendant` list may say it is not
        /// focused): nothing is said, as before.
        case silent
    }

    /// Evidence (design rule C): the container said focused before the Tab and does not now, or a hidden focus was
    /// already recorded for it.
    package static func hasEvidence(hasRecord: Bool, focusedBeforeTab: Bool?, containerFocusedNow: Bool?) -> Bool {
        hasRecord || (focusedBeforeTab == true && containerFocusedNow == false)
    }

    package static func afterSearch(foundFocusedControl: Bool, hasRecord: Bool, focusedBeforeTab: Bool?, containerFocusedNow: Bool?, ranOutOfTime: Bool = false) -> Outcome {
        if foundFocusedControl { return .moved }
        // A search that ran out of time has not shown that nothing is there: unknown, so nothing is said.
        if ranOutOfTime { return .silent }
        // A container that could not be asked, or says it has the keyboard, is no ground for saying anything.
        guard containerFocusedNow == false else { return .silent }
        return hasEvidence(hasRecord: hasRecord, focusedBeforeTab: focusedBeforeTab, containerFocusedNow: containerFocusedNow) ? .fallback : .silent
    }
}

extension HiddenFocusDecision {
    /// What Return, Space and VO-Space do at the reading position (24 Nov 2026). Only a recorded place that the focus
    /// object stands for, with the caret on the container's own item, is taken at all. After a Tab or Shift+Tab nothing
    /// shows yet where the keyboard went, so the record is unverified: the real key goes to the browser, which knows,
    /// and an accessibility press (VO-Space) does nothing rather than press the old control.
    package enum Activation: Equatable { case leaveAlone, pressRecordedControl, sendRealKey, doNothing }
    package static func activation(focusIsRecordedPlace: Bool, caretOnContainersOwnItem: Bool, verified: Bool, byAccessibility: Bool) -> Activation {
        guard focusIsRecordedPlace, caretOnContainersOwnItem else { return .leaveAlone }
        if byAccessibility { return verified ? .pressRecordedControl : .doNothing }
        return .sendRealKey
    }

    /// Whether an answer from a background check may be applied: no key since, no newer check, and the focus TurnOver
    /// presented is still the one the check started from.
    package static func shouldApply(keysThen: Int, keysNow: Int, token: Int, latest: Int, focusUnchanged: Bool) -> Bool {
        keysThen == keysNow && token == latest && focusUnchanged
    }
}

/// The real page: a web area's text markers and elements, asked through accessibility.
nonisolated package final class WebHiddenControlPage: HiddenControlPage {
    package let web: AXUIElement
    /// No messaging timeout is set here (Codex's review, 24 Nov 2026): the handles are shared with the main thread, and
    /// the questions are asked on the worker, so a slow answer only delays the search, whose own deadline caps it.
    package init(web: AXUIElement) { self.web = web }
    private func bounded(_ e: AXUIElement) -> AXUIElement { e }

    package func isSame(_ a: AXUIElement, _ b: AXUIElement) -> Bool { CFEqual(a, b) }
    package func isSameMarker(_ a: AXTextMarker, _ b: AXTextMarker) -> Bool { CFEqual(a, b) }
    private func markers(of range: CFTypeRef) -> (AXTextMarker, AXTextMarker)? {
        guard CFGetTypeID(range) == AXTextMarkerRangeGetTypeID() else { return nil }
        let r = unsafeDowncast(range as AnyObject, to: AXTextMarkerRange.self)
        return (AXTextMarkerRangeCopyStartMarker(r), AXTextMarkerRangeCopyEndMarker(r))
    }
    package func textRange(of element: AXUIElement) -> (start: AXTextMarker, end: AXTextMarker)? {
        guard let v = web.param("AXTextMarkerRangeForUIElement", element), let ends = markers(of: v) else { return nil }
        return (ends.0, ends.1)
    }
    package func element(at marker: AXTextMarker) -> AXUIElement? {
        guard let v = web.param("AXUIElementForTextMarker", marker), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return bounded(unsafeDowncast(v as AnyObject, to: AXUIElement.self))
    }
    package func parent(of element: AXUIElement) -> AXUIElement? { bounded(element).element(kAXParentAttribute) }
    package func next(after marker: AXTextMarker) -> AXTextMarker? {
        guard let v = web.param("AXNextTextMarkerForTextMarker", marker), CFGetTypeID(v) == AXTextMarkerGetTypeID() else { return nil }
        return unsafeDowncast(v as AnyObject, to: AXTextMarker.self)
    }
    package func styledElements(from start: AXTextMarker, to end: AXTextMarker, timeIsUp: () -> Bool) -> [AXUIElement] {
        let range = AXTextMarkerRangeCreate(kCFAllocatorDefault, start, end)
        guard let rich = web.param("AXAttributedStringForTextMarkerRange", range) as? NSAttributedString else { return [] }
        var named: [AXUIElement] = []
        rich.enumerateAttributes(in: NSRange(location: 0, length: rich.length)) { attrs, _, stop in
            if timeIsUp() || named.count > 60 { stop.pointee = true; return }
            for (_, value) in attrs where CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() {
                let x = unsafeDowncast(value as AnyObject, to: AXUIElement.self)
                if !named.contains(where: { CFEqual($0, x) }) { named.append(x) }
            }
        }
        return named
    }
    package func canTakeFocus(_ element: AXUIElement) -> Bool {
        bounded(element)
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString, &settable) == .success && settable.boolValue
    }
    package func focusableAncestor(of element: AXUIElement) -> AXUIElement? { bounded(element).element("AXFocusableAncestor") }
    package func isFocused(_ element: AXUIElement) -> Bool? { return BrowseModeDocument.boundedFocused(element) }
    package func isPlainGroup(_ element: AXUIElement) -> Bool { bounded(element).role == "AXGroup" || element.role == "AXUnknown" }
    package func gridPoints(over element: AXUIElement) -> [CGPoint] {
        guard let fv = bounded(element).attr("AXFrame"), CFGetTypeID(fv) == AXValueGetTypeID() else { return [] }
        var frame = CGRect.zero
        guard AXValueGetValue(unsafeDowncast(fv as AnyObject, to: AXValue.self), .cgRect, &frame), frame.width > 0, frame.height > 0 else { return [] }
        let step = max(8.0, (Double(frame.width * frame.height) / 800).squareRoot())
        var points: [CGPoint] = []
        var y = Double(frame.minY) + step / 2
        while y < Double(frame.maxY) {
            var x = Double(frame.minX) + step / 2
            while x < Double(frame.maxX) {
                points.append(CGPoint(x: x, y: y))
                x += step
            }
            y += step
        }
        return points
    }
    package func element(atPoint point: CGPoint) -> AXUIElement? {
        var p = point
        guard let pv = AXValueCreate(.cgPoint, &p), let m = web.param("AXTextMarkerForPosition", pv),
              CFGetTypeID(m) == AXTextMarkerGetTypeID() else { return nil }
        return element(at: unsafeDowncast(m as AnyObject, to: AXTextMarker.self))
    }
}

extension HiddenSearchResult: Sendable where Element: Sendable {}
