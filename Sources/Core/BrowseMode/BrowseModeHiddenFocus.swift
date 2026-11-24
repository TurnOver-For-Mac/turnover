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
    /// TurnOver is not sure what has the keyboard (an arrival the search could not settle): Return and Space go to the
    /// browser as real keys, and this is no evidence that something hidden has it.
    var unresolved = false
}

/// What a hidden-control search answers, from the worker to the main thread.
struct HiddenSearchAnswer: Sendable {
    /// What the container said when asked (arrival only); nil when the question failed.
    var focused: Bool?
    var result: HiddenSearchResult<AXUIElement>?
    var ms = 0
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

    /// What `AXFocused` says, asked with a limit of a tenth of a second on this one element: the answer can come from a
    /// page that is busy, and this is asked on the main thread before a Tab (Codex's review, 24 Nov 2026).
    nonisolated static func boundedFocused(_ e: AXUIElement) -> Bool? {
        AXUIElementSetMessagingTimeout(e, WebHiddenControlPage.queryLimit)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXFocusedAttribute as CFString, &v) == .success else { return nil }
        return v as? Bool
    }
    /// The element the app reports as the focus, with the same limit; nil when it did not answer.
    nonisolated static func boundedReportedFocus(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, WebHiddenControlPage.queryLimit)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(v as AnyObject, to: AXUIElement.self)
    }

    /// The focus left the container (or its hidden control): the record of where the keyboard was in it ends. What was
    /// found in the container stays remembered, apart from it (Codex's review: a reused row inherited old evidence).
    func noteFocusArrived(at target: AXUIElement) {
        guard let h = currentHiddenFocus else { return }
        if target.isSame(h.container) || (h.control.map { target.isSame($0) } ?? false) { return }
        hiddenFocus = nil
    }

    /// Before a Tab is sent: whether the focus's place says it has the keyboard (evidence, design rule C). Nothing is
    /// asked of a page that is not answering, or when a hidden focus is recorded (the record is evidence already).
    func noteFocusBeforeTab() {
        focusedBeforeTab = nil
        guard !pageSilent, currentHiddenFocus == nil,
              let f = API.focusObject, f.pid == webArea.pid, !f.isSameElement(as: webArea) else { return }
        focusedBeforeTab = (f.element, Self.boundedFocused(f.element), ScriptHandler.keysArrivedCount)
    }

    /// What `pollFocusAfterTab` does when the app's answer is the element TurnOver already has (or the container it
    /// stands in for). Returns true when it has taken over; false to poll on as before.
    func handleSameFocusAfterTab(reported f: AXUIElement, sentAt: Date, keys: Int, epoch: Int, searches: Int) -> Bool {
        let record = currentHiddenFocus
        let hasRecord = record.map { $0.container.isSame(f) } == true
        let controlFocused: Bool? = hasRecord ? record?.control.flatMap { Self.boundedFocused($0) } : nil
        let containerFocused = Self.boundedFocused(f)
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
            // A few searches per Tab, then the poll goes on as before to its ceiling.
            guard searches < 6 else { return false }
            startHiddenSearch(container: f, hasRecord: hasRecord, evidenceRecord: hasRecord && record?.unresolved != true,
                              containerFocused: containerFocused, sentAt: sentAt, keys: keys, epoch: epoch, searches: searches)
            return true
        }
    }

    private func startHiddenSearch(container: AXUIElement, hasRecord: Bool, evidenceRecord: Bool, containerFocused: Bool?,
                                   sentAt: Date, keys: Int, epoch: Int, searches: Int) {
        let before = focusedBeforeTab.flatMap { $0.element.isSame(container) && $0.keys == keys ? $0.focused : nil }
        let evidence = HiddenFocusDecision.hasEvidence(hasRecord: evidenceRecord, focusedBeforeTab: before, containerFocusedNow: containerFocused)
        let known = knownControls(in: container)
        let web = webArea
        let limit = Self.hiddenSearchLimit
        let startFocus = API.focusObject?.element
        let pid = webArea.pid
        hiddenRunner.submit(collect: { request in
            let started = Date()
            let page = WebHiddenControlPage(web: web)
            let result = HiddenControlSearch.search(in: container, page: page, known: known, includeGrid: evidence,
                                                    timeIsUp: { request.isCancelled || Date().timeIntervalSince(started) > limit })
            return HiddenSearchAnswer(focused: nil, result: result, ms: Int(Date().timeIntervalSince(started) * 1000))
        }, publish: { [weak self] outcome in
            guard let self, API.focusTreeInterceptor === self, pageGeneration == epoch, ScriptHandler.keysArrivedCount == keys else { return }
            guard let result = outcome.result else { return }
            let ms = outcome.ms
            remember(result.controls, in: container)
            // Settled again on the main thread, with limits: a click or a script can have moved the focus while the
            // search ran, and a failed question leaves the answer unresolved (Codex's review, 24 Nov 2026).
            let stillThere = startFocus.map { s in API.focusObject.map { focusPlace(of: $0.element).isSame(s) || $0.element.isSame(s) } == true } ?? (API.focusObject == nil)
            guard stillThere else { Log.io("browse mode: hidden control search dropped: another focus came while it ran"); return }
            let reported = Self.boundedReportedFocus(pid: pid)
            guard let reported, reported.isSame(container) else {
                Log.io("browse mode: hidden control search dropped: the browser no longer reports the \(container.role)")
                resumePoll(sentAt: sentAt, pid: pid, keys: keys, epoch: epoch, searches: searches)
                return
            }
            let containerNow = Self.boundedFocused(container)
            if containerNow == true {
                Log.io("browse mode: hidden control search: the keyboard is back on the \(container.role); read from there")
                hiddenFocus = nil
                AXHandler.shared.focusChanged(container, pid: pid)
                return
            }
            let verified = result.focused.flatMap { Self.boundedFocused($0) == true ? $0 : nil }
            let decision = HiddenFocusDecision.afterSearch(foundFocusedControl: verified != nil, hasRecord: evidenceRecord, focusedBeforeTab: before, containerFocusedNow: containerNow)
            // Design J: which step found it, how many controls are known, the time taken, and for a miss the role.
            Log.io("browse mode: hidden control search in a \(container.role): \(decision), found by \(result.stage?.rawValue ?? "nothing"), \(result.controls.count) known, \(result.hops) text pieces, \(result.points) points, \(ms) ms\(result.cutShort ? ", cut short" : ""), evidence \(evidence)")
            switch decision {
            case .moved:
                if let x = verified { moveHiddenFocus(to: x, in: container, previous: currentHiddenFocus) }
            case .fallback:
                enterUnnamedStop(in: container)
            case .silent:
                // Inconclusive: the poll goes on, in case the page moves the keyboard later without news.
                resumePoll(sentAt: sentAt, pid: pid, keys: keys, epoch: epoch, searches: searches)
            }
        })
    }

    private func resumePoll(sentAt: Date, pid: pid_t, keys: Int, epoch: Int, searches: Int) {
        guard Date().timeIntervalSince(sentAt) + Self.focusPollInterval < Self.focusPollCeiling else { return }
        pollFocusAfterTab(sentAt: sentAt, pid: pid, keys: keys, epoch: epoch, searches: searches + 1)
    }

    /// The control found inside `container` is the focus: sent through the focus rules that matter for a verified
    /// move, and recorded as the keyboard's place only once the focus has been accepted.
    private func moveHiddenFocus(to x: AXUIElement, in container: AXUIElement, previous: HiddenFocusRecord?) {
        hiddenFocus = HiddenFocusRecord(container: container, control: x, generation: pageGeneration, movedInside: true)
        AXHandler.shared.lastNewsAt[x.pid] = Date()
        AXHandler.shared.focusChanged(x, pid: x.pid, verifiedHidden: true)
        if API.focusObject?.element.isSame(x) != true {
            // Refused (the app is not in front, say): TurnOver keeps its old focus, so no record says otherwise.
            Log.io("browse mode: the hidden \(x.role) was not accepted as the focus; the record is dropped")
            hiddenFocus = previous
        }
    }

    /// The keyboard is on a hidden control that could not be reached: the container is the focus object, quietly, so that
    /// nothing from the control before it (its press, its focus mode) stays; "unlabelled control" is said.
    private func enterUnnamedStop(in container: AXUIElement) {
        hiddenFocus = HiddenFocusRecord(container: container, control: nil, generation: pageGeneration, movedInside: true)
        if API.focusObject?.element.isSame(container) != true {
            let obj = ObjectFactory.make(container)
            if let old = API.focusObject { EventHandler.queue(Event(.loseFocus, old)) }
            API.setFocusObject(obj, ancestors: obj.ancestors, interceptor: self)
        }
        if passThrough { setPassThrough(false, announce: false, playSound: false) }
        Speech.speakMessage(Self.unlabelledControlWords, remember: false)
    }

    /// Whether arrival at `target` is looked into: a control role or a group in this page, not asked of a page that is not
    /// answering. A container that held nothing before is not searched again, but it is no longer presented as the
    /// keyboard's place without a record that says so (see `checkArrival`).
    func arrivalNeedsCheck(at target: AXUIElement) -> Bool {
        !pageSilent && target.pid == webArea.pid && !target.isSame(webArea) && Self.arrivalRoles.contains(target.role)
    }

    /// The keyboard arrived at `target` from the browser's news (also when the browser repeats its news of a row while the
    /// keyboard is on a control inside it). Off the main thread, the target is asked whether it has the keyboard, and if it
    /// says not, the two cheap steps of the search run; the focus is presented when that answers (the same checks as the
    /// search after a Tab). Found: the control is presented in the container's place. Not found: the target is presented as
    /// before, with a record that says what has the keyboard is not known, so that Return and Space go to the browser.
    func checkArrival(at target: AXUIElement, old: TurnOverObject?, pid: pid_t, serial: Int) {
        let epoch = pageGeneration
        let web = webArea
        let known = knownControls(in: target)
        let emptyBefore = (hiddenKnown.flatMap { $0.generation == pageGeneration ? $0 : nil })?.empty.contains { $0.isSame(target) } == true && known.isEmpty
        let limit = Self.hiddenArrivalLimit
        hiddenRunner.submit(collect: { request in
            let started = Date()
            guard let focused = Self.boundedFocused(target) else { return HiddenSearchAnswer(focused: nil, result: nil) }
            if focused || emptyBefore { return HiddenSearchAnswer(focused: focused, result: nil) }
            let result = HiddenControlSearch.search(in: target, page: WebHiddenControlPage(web: web), known: known, includeGrid: false,
                                                    timeIsUp: { request.isCancelled || Date().timeIntervalSince(started) > limit })
            return HiddenSearchAnswer(focused: false, result: result, ms: Int(Date().timeIntervalSince(started) * 1000))
        }, publish: { [weak self] answer in
            guard let self, API.focusTreeInterceptor != nil, pageGeneration == epoch, AXHandler.shared.presentSerial == serial else { return }
            @MainActor func presentTarget(unresolved: Bool) {
                if unresolved { hiddenFocus = HiddenFocusRecord(container: target, control: nil, generation: pageGeneration, movedInside: false, unresolved: true) }
                AXHandler.shared.present(target, pid: pid, arrivalChecked: true)
            }
            guard let focused = answer.focused else { presentTarget(unresolved: true); return }   // the question failed: not sure
            if focused { presentTarget(unresolved: false); return }
            guard let result = answer.result else { presentTarget(unresolved: true); return }   // a container that held nothing before
            remember(result.controls, in: target)
            Log.io("browse mode: arrival at a \(target.role) that says it has no keyboard: found \(result.focused == nil ? "nothing" : "a control by \(result.stage?.rawValue ?? "?")"), \(result.controls.count) known, \(result.hops) text pieces, \(answer.ms) ms\(result.cutShort ? ", cut short" : "")")
            guard let x = result.focused, Self.boundedFocused(x) == true else {
                // Only the cheap steps ran: an icon-only control is not found, so the container is not marked empty for
                // good, and the keyboard's place stays unresolved.
                if result.controls.isEmpty, !result.cutShort { rememberEmpty(target) }
                presentTarget(unresolved: true)
                return
            }
            let inside = old.map { o in (currentHiddenFocus?.container.isSame(target) == true) && (o.element.isSame(target) || currentHiddenFocus?.control.map { o.element.isSame($0) } == true) } ?? false
            if let old, old.element.isSame(x) {
                Log.io("focus: the browser repeated its news of a \(target.role) while the keyboard is on a control inside it; not spoken again")
                return
            }
            let previous = hiddenFocus
            hiddenFocus = HiddenFocusRecord(container: target, control: x, generation: pageGeneration, movedInside: inside)
            AXHandler.shared.present(x, pid: pid, arrivalChecked: true)
            if API.focusObject?.element.isSame(x) != true { hiddenFocus = previous }
        })
    }
    /// What can be a container for hidden controls: a control role, or a group.
    static let arrivalRoles: Set<String> = tabRoles.union(["AXGroup"])

    /// Tab went to the page for real in focus mode (a hidden text field took the keyboard): no browse-mode script runs
    /// there, so the next hidden stop would be silent again. Called from the key's pass-through, after it was not taken
    /// by Input Help or a menu.
    static func keyPassedToPage(_ gesture: KeyboardGesture) {
        guard gesture.keyName == "tab", let d = API.focusTreeInterceptor as? BrowseModeDocument, d.passThrough else { return }
        d.tabInFocusMode()
    }
    func tabInFocusMode() {
        guard currentHiddenFocus != nil, API.focusObject.map({ $0.pid == webArea.pid }) == true else { return }
        BrowseModeDocument.lastPageTabAt = Date()
        askFocusIfNoNews()
    }
}
