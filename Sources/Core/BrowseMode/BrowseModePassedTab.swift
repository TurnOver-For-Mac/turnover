// SPDX-License-Identifier: GPL-3.0-or-later
// A Tab or Shift Tab that went to a web page as a plain key, not through browse mode's own Tab (27 Nov 2026).
//
// Browse mode's Tab (tabFromCaret) asks the page for its focus when the browser posts no news of a move
// (askFocusIfNoNews). A Tab that went to the page as a plain key did not: in focus mode with no hidden control
// recorded, or with no browse mode document for the focus at all. On 27 Nov 2026 (06:05 log, 168 to 196 s), tabbing
// through a busy page in Safari, every other Tab went as a plain key, and seven of those were silent with no event of
// any kind after them: Safari had moved the keyboard (an ordinary link sat there) and posted no focus news. Now every
// Tab or Shift Tab that reaches a page gets the same check, whichever way it went.
import Foundation
import ApplicationServices
import TurnOverAX

extension BrowseModeDocument {
    /// Which check a Tab that went to the application as a plain key gets.
    package enum PassedTabCheck: Equatable {
        /// Not a Tab, or not in a page: nothing is asked.
        case none
        /// Focus mode with a hidden control recorded: tabInFocusMode's own check (24 Nov 2026), as before.
        case hiddenFocus
        /// The page's document has the focus: its own no-news check (askFocusIfNoNews), with the hidden-control check.
        case document
        /// No document has the focus, but a page is known in the focus's process: the app is asked for its focus.
        case process
    }

    /// The rule (27 Nov 2026). One condition a line, in the order they are asked.
    package nonisolated static func passedTabCheck(isPlainTab: Bool,
                                                   documentHasFocus: Bool,
                                                   passThrough: Bool,
                                                   hiddenFocusRecorded: Bool,
                                                   pageKnownInFocusProcess: Bool,
                                                   pageSilent: Bool) -> PassedTabCheck {
        // Only Tab and Shift Tab; Control Tab and Command Tab change tabs or apps.
        guard isPlainTab else { return .none }
        // A page that is not answering is not asked: the question would wait out its timeout with every Tab.
        guard !pageSilent else { return .none }
        if documentHasFocus {
            let hiddenCheckRuns = passThrough && hiddenFocusRecorded
            if hiddenCheckRuns { return .hiddenFocus }
            return .document
        }
        if pageKnownInFocusProcess { return .process }
        return .none
    }

    /// One step of the no-news check for a Tab with no document (27 Nov 2026), decided from what is known so far.
    package enum NoNewsStep: Equatable {
        /// The browser posted news, or another key came: the check ends without a word.
        case stop
        /// The app's focus is where it was, and there is time: ask again.
        case askAgain
        /// The app's focus is where it was at the end of the time: logged, nothing said.
        case reportSame
        /// The app's focus moved with no news: it is presented.
        case present
        /// No answer (a timeout, a resting app): nothing is known, and nothing is done.
        case noAnswer
    }

    package nonisolated static func noNewsStep(newsSinceTab: Bool,
                                               anotherKeySince: Bool,
                                               answered: Bool,
                                               answerIsWhereItWas: Bool,
                                               elapsed: TimeInterval,
                                               interval: TimeInterval,
                                               ceiling: TimeInterval) -> NoNewsStep {
        if newsSinceTab { return .stop }
        if anotherKeySince { return .stop }
        guard answered else { return .noAnswer }
        guard answerIsWhereItWas else { return .present }
        let timeLeft = elapsed + interval < ceiling
        if timeLeft { return .askAgain }
        return .reportSame
    }

    /// Called from the key's pass-through, on the main thread, after keyPassedToPage has done what it did before.
    static func checkPassedTab(_ gesture: KeyboardGesture) {
        let isPlainTab = gesture.keyName == "tab" && gesture.modifiers.subtracting([.shift]).isEmpty
        guard isPlainTab else { return }
        guard let focus = API.focusObject else { return }
        let pid = focus.pid
        let d = API.focusTreeInterceptor
        let documentHasFocus = d.map { $0.webArea.pid == pid } ?? false
        let knownPage = documentHasFocus ? nil : BrowseModeHandler.shared.keptDocument(inProcess: pid)
        let silent = documentHasFocus ? (d?.pageSilent ?? false) : (knownPage?.pageSilent ?? false)
        let check = passedTabCheck(isPlainTab: isPlainTab,
                                   documentHasFocus: documentHasFocus,
                                   passThrough: d?.passThrough ?? false,
                                   hiddenFocusRecorded: d?.currentHiddenFocus != nil,
                                   pageKnownInFocusProcess: knownPage != nil,
                                   pageSilent: silent)
        switch check {
        case .none, .hiddenFocus:
            return   // nothing to ask, or tabInFocusMode has asked already
        case .document:
            guard let d else { return }
            Log.io("browse mode: \(gesture.identifier) went to the page as a plain key (\(d.passThrough ? "focus mode" : "browse mode")); its focus is asked for if no news comes")
            BrowseModeDocument.lastPageTabAt = Date()
            BrowseModeDocument.lastPageTabPid = pid
            d.noteFocusBeforeTab()
            d.askFocusIfNoNews()
        case .process:
            // SHORTCOMINGS rule 3: this is the case whose cause is not known (the focus in a page with no document).
            Log.io("browse mode: \(gesture.identifier) went to a page as a plain key with no page document for the \(focus.axRole) that has the focus; its focus is asked for if no news comes")
            pollProcessFocusAfterTab(sentAt: Date(), pid: pid, keys: ScriptHandler.keysArrivedCount, was: focus.element)
        }
    }

    /// The no-news check with no document: the app is asked for its focus every 25 ms, up to the same third of a
    /// second as askFocusIfNoNews, and a focus that moved is presented through the ordinary focus path.
    private static func pollProcessFocusAfterTab(sentAt: Date, pid: pid_t, keys: Int, was: AXUIElement) {
        DispatchQueue.main.asyncAfter(deadline: .now() + focusPollInterval) {
            let newsSinceTab = AXHandler.shared.lastBrowserFocusNewsAt >= sentAt
            let anotherKeySince = ScriptHandler.keysArrivedCount != keys
            // Nothing is asked once the answer can no longer be used.
            if newsSinceTab || anotherKeySince { return }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.25)   // a page that has stopped answering must not hold the keys
            let answer = app.attributeResult(kAXFocusedUIElementAttribute)
            PageWatch.focusQueryReturned(answer.status, by: pid)
            let f = axElement(answer.value)
            let elapsed = Date().timeIntervalSince(sentAt)
            // Where it was: the element TurnOver had when the key went, and still has (the focus may have come meanwhile).
            let current = API.focusObject?.element
            let whereItWas = f.map { $0.isSame(was) || (current.map($0.isSame) ?? false) } ?? false
            let step = noNewsStep(newsSinceTab: AXHandler.shared.lastBrowserFocusNewsAt >= sentAt,
                                  anotherKeySince: ScriptHandler.keysArrivedCount != keys,
                                  answered: f != nil,
                                  answerIsWhereItWas: whereItWas,
                                  elapsed: elapsed,
                                  interval: focusPollInterval,
                                  ceiling: focusPollCeiling)
            switch step {
            case .stop:
                return
            case .noAnswer:
                Log.io("browse mode: Tab brought no news of the focus, and the app did not say where its focus is (no page document)")
            case .askAgain:
                pollProcessFocusAfterTab(sentAt: sentAt, pid: pid, keys: keys, was: was)
            case .reportSame:
                Log.io("browse mode: Tab brought no news of the focus, and the app reports it where it was, on \(f?.role ?? "?") (no page document)")
            case .present:
                guard let f else { return }
                AXHandler.shared.lastNewsAt[pid] = Date()
                Log.io("browse mode: Tab brought no news of the focus; the app's focus is on \(f.role) (no page document), read from there (\(Int(elapsed * 1000)) ms)")
                AXHandler.shared.focusChanged(f, pid: f.pid)
            }
        }
    }
}

extension BrowseModeHandler {
    /// A page known in this process that the handler keeps (by identity and liveness; nothing else is asked).
    func keptDocument(inProcess pid: pid_t) -> BrowseModeDocument? {
        lock.lock()
        let mine = documents.filter { $0.webArea.pid == pid }
        lock.unlock()
        return mine.last { $0.isKept }
    }

    /// Whether any page is known in this process, by its process alone (nothing is asked of the app).
    func hasDocument(inProcess pid: pid_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return documents.contains { $0.webArea.pid == pid }
    }
}

extension BrowseModeHandler {
    /// Why `document(for:ancestors:)` gave no document for a focus, in words for the log (27 Nov 2026, SHORTCOMINGS rule
    /// 3): on a busy page in Safari about every other focus had none, so the Tab after it went to the page as a plain key,
    /// and nothing said why. Asks only what `document(for:)` asked (the roles already read, the web area's liveness).
    func whyNoDocument(for obj: TurnOverObject, ancestors: [TurnOverObject]) -> String {
        let chain = [obj] + ancestors
        guard let w = chain.last(where: { $0.axRole == "AXWebArea" }) else {
            let top = ancestors.last?.axRole ?? "none"
            return "no web area among its \(ancestors.count) ancestors (the last one \(top))"
        }
        if EditableWebArea.isEditable(w.element) { return "its web area is editable" }
        lock.lock()
        let known = documents.first(where: { $0.webArea.isSame(w.element) })
        let samePid = documents.filter { $0.webArea.pid == w.pid }.count
        lock.unlock()
        if let known { return known.isKept ? "its page's document is kept (raced)" : "its page's document is not kept: its web area answers role \(known.webArea.role)" }
        return "its web area is not a known page (\(samePid) known in the process)"
    }
}
