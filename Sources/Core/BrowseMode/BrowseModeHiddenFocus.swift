// SPDX-License-Identifier: GPL-3.0-or-later
// The browse-mode side of controls that Safari hides inside a button-like container (24 Nov 2026; the search itself is
// in HiddenControlSearch.swift). The hidden control that has the keyboard becomes TurnOver's focus object through the
// ordinary focus path, so speech, braille, focus mode for a hidden field and Return all follow; what the copy of the
// page holds is the container, so everything that looks the focus up in the copy asks `focusPlace(of:)`.
//
// Every focus is presented at once, exactly as before. The check for a hidden control runs afterwards, in the background
// (after a Tab that brought no news, and after any focus presented in a page); if it finds a control that has the keyboard,
// that control is presented then. If it finds nothing, or a question fails, nothing changes.
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
    /// False from a Tab or Shift+Tab until a check shows the control still has the keyboard: nothing then presses it.
    var verified = true
}

/// What a hidden-control check answers, from the worker to the main thread.
struct HiddenSearchAnswer: Sendable {
    /// What to do, from what the recorded control and the container said.
    var next: HiddenFocusDecision.Next = .pollOn
    /// What the container said; nil when the question failed.
    var focused: Bool?
    /// What the recorded control said; nil when there is none or it did not answer.
    var recordedFocused: Bool?
    var result: HiddenSearchResult<AXUIElement>?
    var ms = 0
    var evidence = false
    /// Whether the app still reports the container as its focus; nil when it did not answer.
    var reported: Bool?
    /// A control found that says it has the keyboard and has the container as its parent, checked on the worker.
    var verified: AXUIElement?
}

/// What the hidden-control search found in a container, remembered for the page it was found on.
struct HiddenKnownControls {
    let generation: Int
    var containers: [(container: AXUIElement, controls: [AXUIElement])] = []
}

extension BrowseModeDocument {
    /// The words for a hidden control that has no name or cannot be reached. TurnOver had no phrase for an unnamed
    /// thing; the wording is Oliver's to change.
    static var unlabelledControlWords: String { String(localized: "unlabelled control", comment: "Spoken when the keyboard is on a control that the browser hides inside a button and that has no name TurnOver can read") }

    /// How long the search may take, off the main thread.
    static let hiddenSearchLimit = 0.25
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

    /// What `AXFocused` says. Always asked on the worker, with no change to the messaging timeout: the handle may be the
    /// document's own, shared with the main thread (Codex's review, 24 Nov 2026).
    nonisolated static func boundedFocused(_ e: AXUIElement) -> Bool? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXFocusedAttribute as CFString, &v) == .success else { return nil }
        return v as? Bool
    }
    /// The element the app reports as the focus; nil when it did not answer.
    nonisolated static func boundedReportedFocus(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(v as AnyObject, to: AXUIElement.self)
    }

    /// Any focus presented ends the record of where the keyboard was in a container, except the control hidden in it
    /// (a move to the container itself, or anywhere else, is a new place). What was found stays remembered, apart from it.
    func noteFocusArrived(at target: AXUIElement) {
        // A check that started before this focus was presented is out of date.
        hiddenToken &+= 1
        guard let h = currentHiddenFocus else { return }
        if let c = h.control, target.isSame(c) { return }
        hiddenFocus = nil
    }

    /// Before a Tab is sent: what the last check learned of the focus's place (evidence, design rule C). Nothing is asked
    /// of the page here: nothing waits on it before the key is sent (Codex's review, 24 Nov 2026). A record that was
    /// there is marked unverified, since the key may move the keyboard.
    func noteFocusBeforeTab() {
        focusedBeforeTab = nil
        hiddenFocus?.verified = false
        guard let f = API.focusObject, f.pid == webArea.pid, let l = hiddenLearned, l.generation == pageGeneration, l.element.isSame(f.element) else { return }
        focusedBeforeTab = (l.element, l.focused, ScriptHandler.keysArrivedCount)
    }

    /// What can be a container for hidden controls: a control role, or a group.
    static let arrivalRoles: Set<String> = tabRoles.union(["AXGroup"])

    /// After a focus was presented at `target` in this page: the background check for a hidden control that has the
    /// keyboard. Not for a page that is not answering, or for the web area itself.
    func checkAfterArrival(at target: AXUIElement, role: String) {
        guard !pageSilent, target.pid == webArea.pid, !target.isSame(webArea), Self.arrivalRoles.contains(role) else { return }
        if let c = currentHiddenFocus?.control, c.isSame(target) { return }
        startHiddenCheck(container: target, tab: nil)
    }

    /// What `pollFocusAfterTab` does when the app's answer is the element TurnOver already has (or the container it
    /// stands in for): the check goes to the worker; the poll itself carries on as before.
    func handleSameFocusAfterTab(reported f: AXUIElement, sentAt: Date, keys: Int) {
        // One check at a time, six at most for one Tab; the ordinary poll goes on beside it, exactly as before.
        guard Date() >= hiddenCheckUntil, hiddenTabChecks.keys != keys || hiddenTabChecks.count < 6 else { return }
        hiddenTabChecks = (keys, (hiddenTabChecks.keys == keys ? hiddenTabChecks.count : 0) + 1)
        startHiddenCheck(container: f, tab: keys)
    }

    /// One check, on the worker: what the recorded control and the container say, and if the keyboard is hidden inside the
    /// container, the search for it. The ordinary focus poll after a Tab goes on beside it, unchanged. The answer is
    /// applied only if no key arrived since, no newer check started and the presented focus is the same (`shouldApply`);
    /// a question that failed or a search that ran out of time is unknown, and an unknown answer changes nothing.
    /// `tab`: the key count of the Tab this check belongs to, nil for a check after an arrival.
    private func startHiddenCheck(container: AXUIElement, tab: Int?) {
        hiddenToken &+= 1
        hiddenCheckUntil = Date().addingTimeInterval(0.6)
        let token = hiddenToken
        let epoch = pageGeneration
        let keysThen = ScriptHandler.keysArrivedCount
        let focusThen = API.focusObject?.element
        let record = currentHiddenFocus.flatMap { $0.container.isSame(container) ? $0 : nil }
        let before = tab.flatMap { keys in focusedBeforeTab.flatMap { $0.element.isSame(container) && $0.keys == keys ? $0.focused : nil } }
        let known = knownControls(in: container)
        let web = webArea
        let limit = Self.hiddenSearchLimit
        let pid = webArea.pid
        hiddenRunner.submit(collect: { request in
            let started = Date()
            var answer = HiddenSearchAnswer()
            answer.recordedFocused = record?.control.flatMap { Self.boundedFocused($0) }
            answer.focused = Self.boundedFocused(container)
            // A recorded control that did not answer is unknown, not "moved".
            if record?.control != nil, answer.recordedFocused == nil { answer.next = .pollOn; return answer }
            answer.next = HiddenFocusDecision.afterTabStillReported(hasRecord: record != nil, recordedControlFocused: answer.recordedFocused, containerFocused: answer.focused)
            guard answer.next == .search else { return answer }
            answer.evidence = HiddenFocusDecision.hasEvidence(hasRecord: record != nil, focusedBeforeTab: before, containerFocusedNow: answer.focused)
            let page = WebHiddenControlPage(web: web)
            let result = HiddenControlSearch.search(in: container, page: page, known: known, includeGrid: answer.evidence,
                                                    timeIsUp: { request.isCancelled || Date().timeIntervalSince(started) > limit })
            answer.result = result
            // Settled here: Safari still reports the container, and the control found says it has the keyboard and
            // belongs to the container.
            answer.reported = Self.boundedReportedFocus(pid: pid).map { CFEqual($0, container) }
            if let x = result.focused, Self.boundedFocused(x) == true, page.parent(of: x).map({ CFEqual($0, container) }) == true { answer.verified = x }
            answer.ms = Int(Date().timeIntervalSince(started) * 1000)
            return answer
        }, publish: { [weak self] answer in
            guard let self else { return }
            if token == hiddenToken { hiddenCheckUntil = .distantPast }
            guard API.focusTreeInterceptor === self, pageGeneration == epoch else { return }
            if let f = answer.focused { hiddenLearned = (container, f, epoch) }
            let sameFocus = (focusThen == nil && API.focusObject == nil) || (focusThen != nil && API.focusObject?.element.isSame(focusThen!) == true)
            guard HiddenFocusDecision.shouldApply(keysThen: keysThen, keysNow: ScriptHandler.keysArrivedCount, token: token, latest: hiddenToken, focusUnchanged: sameFocus) else { return }
            switch answer.next {
            case .pollOn:
                // The control that had the keyboard still has it: the record is sound again.
                if answer.recordedFocused == true { hiddenFocus?.verified = true }
            case .backOnContainer:
                guard tab != nil else { return }
                Log.io("browse mode: Tab brought the keyboard back to the \(container.role) around the hidden controls; read from there")
                hiddenFocus = nil
                AXHandler.shared.lastNewsAt[pid] = Date()
                AXHandler.shared.focusChanged(container, pid: pid)
            case .search:
                guard let result = answer.result else { return }
                remember(result.controls, in: container)
                guard answer.reported == true else { return }
                let ranOut = answer.verified == nil && result.cutShort
                let decision = HiddenFocusDecision.afterSearch(foundFocusedControl: answer.verified != nil, hasRecord: record != nil, focusedBeforeTab: before, containerFocusedNow: answer.focused, ranOutOfTime: ranOut)
                // Design J: which step found it, how many controls are known, the time taken, and for a miss the role.
                Log.io("browse mode: hidden control search in a \(container.role)\(tab == nil ? " (after arrival)" : ""): \(decision), found by \(result.stage?.rawValue ?? "nothing"), \(result.controls.count) known, \(result.hops) text pieces, \(result.points) points, \(answer.ms) ms\(result.cutShort ? ", cut short" : ""), evidence \(answer.evidence)")
                switch decision {
                case .moved:
                    if let x = answer.verified { moveHiddenFocus(to: x, in: container, previous: currentHiddenFocus) }
                case .fallback:
                    // Only after a Tab: the unnamed stop is said when something shows the keyboard moved.
                    if tab != nil { enterUnnamedStop(in: container) }
                case .silent:
                    break
                }
            }
        })
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
        // The previous control's automatic focus mode ends; a mode chosen by hand stays.
        if passThrough, !disableAutoPassThrough { setPassThrough(false, announce: false, playSound: false) }
        Speech.speakMessage(Self.unlabelledControlWords, remember: false)
    }

    /// Tab went to the page for real in focus mode (a hidden text field took the keyboard): no browse-mode script runs
    /// there, so the next hidden stop would be silent again. Called from the key's pass-through, after it was not taken
    /// by Input Help or a menu.
    static func keyPassedToPage(_ gesture: KeyboardGesture) {
        guard gesture.keyName == "tab", gesture.modifiers.subtracting([.shift]).isEmpty, let d = API.focusTreeInterceptor as? BrowseModeDocument, d.passThrough else { return }
        d.tabInFocusMode()
    }
    func tabInFocusMode() {
        hiddenFocus?.verified = false
        guard currentHiddenFocus != nil, API.focusObject.map({ $0.pid == webArea.pid }) == true else { return }
        BrowseModeDocument.lastPageTabAt = Date()
        BrowseModeDocument.lastPageTabPid = webArea.pid
        askFocusIfNoNews()
    }
}
