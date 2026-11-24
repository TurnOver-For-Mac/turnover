// SPDX-License-Identifier: GPL-3.0-or-later
// The browse-mode side of controls that Safari hides inside a button-like container (24 Nov 2026; the search itself is
// in HiddenControlSearch.swift). The hidden control that has the keyboard becomes TurnOver's focus object through the
// ordinary focus path, so speech, braille, focus mode for a hidden field and Return all follow; what the copy of the
// page holds is the container, so everything that looks the focus up in the copy asks `focusPlace(of:)`.
import Foundation
import ApplicationServices
import TurnOverAX

/// Where the keyboard is when it is inside a container that WebKit shows as one element.
struct HiddenFocusRecord {
    /// The element the browser reports as the focus.
    let container: AXUIElement
    /// The hidden control that has the keyboard; nil when it cannot be reached (it is then said as "unlabelled control").
    var control: AXUIElement?
    let generation: Int
    /// The keyboard moved from inside the same container to another control in it: the reading position stays put.
    var movedInside: Bool
}

/// What the hidden-control search found in a container, remembered for the page it was found on.
struct HiddenKnownControls {
    let generation: Int
    var containers: [(container: AXUIElement, controls: [AXUIElement])] = []
    /// Containers that answered "not focused" and held nothing: arrow keys in a list must not pay for the search each time.
    var empty: [AXUIElement] = []
}

extension BrowseModeDocument {
    /// The words for a hidden control that has no name or cannot be reached. TurnOver had no phrase for an unnamed
    /// thing; the wording is Oliver's to change.
    static var unlabelledControlWords: String { String(localized: "unlabelled control", comment: "Spoken when the keyboard is on a control that the browser hides inside a button and that has no name TurnOver can read") }

    /// How long the search may take, off the main thread, and in line on arrival.
    static let hiddenSearchLimit = 0.25
    static let hiddenArrivalLimit = 0.08
    /// The most containers remembered per page.
    static let hiddenKnownCap = 60

    var currentHiddenFocus: HiddenFocusRecord? {
        guard let h = hiddenFocus, h.generation == pageGeneration else { return nil }
        return h
    }

    /// The element of the copy that stands for the focus: the container while the focus object is the control hidden in
    /// it, else the element itself.
    func focusPlace(of element: AXUIElement) -> AXUIElement {
        if let h = currentHiddenFocus, let c = h.control, c.isSame(element) { return h.container }
        return element
    }

    private func knownControls(in container: AXUIElement) -> [AXUIElement] {
        guard let k = hiddenKnown, k.generation == pageGeneration else { return [] }
        return k.containers.first { $0.container.isSame(container) }?.controls ?? []
    }
    private func remember(_ controls: [AXUIElement], in container: AXUIElement) {
        var k = hiddenKnown.flatMap { $0.generation == pageGeneration ? $0 : nil } ?? HiddenKnownControls(generation: pageGeneration)
        if let i = k.containers.firstIndex(where: { $0.container.isSame(container) }) { k.containers[i].controls = controls }
        else {
            if k.containers.count >= Self.hiddenKnownCap { k.containers.removeFirst() }
            k.containers.append((container, controls))
        }
        hiddenKnown = k
    }
    private func rememberEmpty(_ container: AXUIElement) {
        var k = hiddenKnown.flatMap { $0.generation == pageGeneration ? $0 : nil } ?? HiddenKnownControls(generation: pageGeneration)
        if k.empty.count >= Self.hiddenKnownCap { k.empty.removeFirst() }
        k.empty.append(container)
        hiddenKnown = k
    }

    private func isFocused(_ e: AXUIElement) -> Bool? { e.attr(kAXFocusedAttribute) as? Bool }

    /// Before a Tab is sent: whether the focus's place says it has the keyboard (evidence, design rule C). Nothing is
    /// asked of a page that is not answering, or when a hidden focus is recorded (the record is evidence already).
    func noteFocusBeforeTab() {
        focusedBeforeTab = nil
        guard !pageSilent, currentHiddenFocus == nil,
              let f = API.focusObject, f.pid == webArea.pid, !f.isSameElement(as: webArea) else { return }
        focusedBeforeTab = (f.element, isFocused(f.element), ScriptHandler.keysArrivedCount)
    }

    /// What `pollFocusAfterTab` does when the app's answer is the element TurnOver already has (or the container it
    /// stands in for). Returns true when it has taken over; false to poll on as before.
    func handleSameFocusAfterTab(reported f: AXUIElement, sentAt: Date, keys: Int, epoch: Int) -> Bool {
        let record = currentHiddenFocus
        let hasRecord = record.map { $0.container.isSame(f) } == true
        let controlFocused: Bool? = hasRecord ? record?.control.flatMap { isFocused($0) } : nil
        let containerFocused = isFocused(f)
        switch HiddenFocusDecision.afterTabStillReported(hasRecord: hasRecord, recordedControlFocused: controlFocused, containerFocused: containerFocused) {
        case .pollOn:
            return false
        case .backOnContainer:
            Log.io("browse mode: Tab brought the keyboard back to the \(f.role) around the hidden controls; read from there")
            hiddenFocus = nil
            AXHandler.shared.lastNewsAt[f.pid] = Date()
            AXHandler.shared.focusChanged(f, pid: f.pid)
            return true
        case .search:
            startHiddenSearch(container: f, hasRecord: hasRecord, containerFocused: containerFocused, sentAt: sentAt, keys: keys, epoch: epoch)
            return true
        }
    }

    private func startHiddenSearch(container: AXUIElement, hasRecord: Bool, containerFocused: Bool?, sentAt: Date, keys: Int, epoch: Int) {
        let before = focusedBeforeTab.flatMap { $0.element.isSame(container) && $0.keys == keys ? $0.focused : nil }
        let evidence = HiddenFocusDecision.hasEvidence(hasRecord: hasRecord, focusedBeforeTab: before, containerFocusedNow: containerFocused)
        let known = knownControls(in: container)
        let web = webArea
        let limit = Self.hiddenSearchLimit
        hiddenRunner.submit(collect: { request in
            let started = Date()
            let page = WebHiddenControlPage(web: web)
            let result = HiddenControlSearch.search(in: container, page: page, known: known, includeGrid: evidence,
                                                    timeIsUp: { request.isCancelled || Date().timeIntervalSince(started) > limit })
            return (result, Int(Date().timeIntervalSince(started) * 1000))
        }, publish: { [weak self] outcome in
            guard let self, API.focusTreeInterceptor === self, pageGeneration == epoch, ScriptHandler.keysArrivedCount == keys else { return }
            let (result, ms) = outcome
            remember(result.controls, in: container)
            let stillOnContainer = isFocused(container)
            let decision = HiddenFocusDecision.afterSearch(foundFocusedControl: result.focused != nil, hasRecord: hasRecord, focusedBeforeTab: before, containerFocusedNow: stillOnContainer)
            // Design J: which step found it, how many controls are known, the time taken, and for a miss the role.
            Log.io("browse mode: hidden control search in a \(container.role): \(decision), found by \(result.stage?.rawValue ?? "nothing"), \(result.controls.count) known, \(result.hops) text pieces, \(result.points) points, \(ms) ms\(result.cutShort ? ", cut short" : ""), evidence \(evidence)")
            switch decision {
            case .moved:
                guard let x = result.focused else { return }
                moveHiddenFocus(to: x, in: container)
            case .fallback:
                hiddenFocus = HiddenFocusRecord(container: container, control: nil, generation: pageGeneration, movedInside: true)
                Speech.speakMessage(Self.unlabelledControlWords, remember: false)
            case .silent:
                break
            }
        })
    }

    /// The control found inside `container` is the focus: recorded, then sent through the ordinary focus path.
    private func moveHiddenFocus(to x: AXUIElement, in container: AXUIElement) {
        hiddenFocus = HiddenFocusRecord(container: container, control: x, generation: pageGeneration, movedInside: true)
        AXHandler.shared.lastNewsAt[x.pid] = Date()
        AXHandler.shared.focusChanged(x, pid: x.pid)
    }

    /// The keyboard arrived at `target` from the browser's news (also when the browser repeats its news of a row while
    /// the keyboard is on a control inside it): if the target says it has no keyboard, the two cheap steps of the search
    /// are run in line, and the control found is the focus in its place. Nil: speak `target` as ever. Skipped while the
    /// page is silent, and for containers that held nothing before on this page.
    func hiddenControlOnArrival(at target: AXUIElement, old: TurnOverObject?) -> AXUIElement? {
        guard !pageSilent, target.pid == webArea.pid, !target.isSame(webArea),
              Self.arrivalRoles.contains(target.role) else { return nil }
        if let k = hiddenKnown, k.generation == pageGeneration, k.empty.contains(where: { $0.isSame(target) }) { return nil }
        guard isFocused(target) == false else { return nil }
        let started = Date()
        let limit = Self.hiddenArrivalLimit
        let result = HiddenControlSearch.search(in: target, page: WebHiddenControlPage(web: webArea), known: knownControls(in: target),
                                                includeGrid: false, timeIsUp: { Date().timeIntervalSince(started) > limit })
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        remember(result.controls, in: target)
        Log.io("browse mode: arrival at a \(target.role) that says it has no keyboard: found \(result.focused == nil ? "nothing" : "a control by \(result.stage?.rawValue ?? "?")"), \(result.controls.count) known, \(result.hops) text pieces, \(ms) ms\(result.cutShort ? ", cut short" : "")")
        guard let x = result.focused else {
            if result.controls.isEmpty, !result.cutShort { rememberEmpty(target) }
            return nil
        }
        let inside = old.map { o in (currentHiddenFocus?.container.isSame(target) == true) && (o.element.isSame(target) || currentHiddenFocus?.control.map { o.element.isSame($0) } == true) } ?? false
        hiddenFocus = HiddenFocusRecord(container: target, control: x, generation: pageGeneration, movedInside: inside)
        return x
    }
    /// What can be a container for hidden controls: a control role, or a group.
    static let arrivalRoles: Set<String> = tabRoles.union(["AXGroup"])

    /// Tab in focus mode (a hidden text field took the keyboard): no browse-mode script runs there, so the next hidden
    /// stop would be silent again. Called from `script(for:)` for Tab and Shift+Tab, with the key still to be sent.
    func tabInFocusMode() {
        guard currentHiddenFocus != nil, API.focusObject.map({ $0.pid == webArea.pid }) == true else { return }
        BrowseModeDocument.lastPageTabAt = Date()
        askFocusIfNoNews()
    }
}
