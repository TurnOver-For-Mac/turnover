// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverAX

extension BrowseModeDocument {
    /// When "nothing on this page yet" was last said.
    static var nothingYetSaidAt = Date.distantPast
    /// Whether it may be said again: not within two seconds. Pure.
    public nonisolated static func nothingYetDue(last: Date, now: Date) -> Bool { now.timeIntervalSince(last) >= 2 }
    /// "Nothing on this page yet", said once for a run of keys: three keys that had queued behind a page that was
    /// not answering each said it, in the same millisecond, and six times in twelve seconds (11 Nov 2026).
    func sayNothingOnPageYet() {
        guard Self.nothingYetDue(last: Self.nothingYetSaidAt, now: Date()) else {
            Log.io("browse mode: \"nothing on this page yet\" was said a moment ago; not said again")
            return
        }
        Self.nothingYetSaidAt = Date()
        Speech.speakMessage(String(localized: "nothing on this page yet; it may still be loading", comment: "Spoken message"))
    }

    /// A command that arrived during the first collection runs once its content is available. A later key,
    /// navigation or focus departure retires it; the event-tap decision still returns immediately.
    package func deferInitialContent(_ action: @escaping () -> Void) -> Bool {
        guard buffer.lines.isEmpty, buffer.isLoading else { return false }
        let epoch = pageGeneration, intent = bufferIntent, keys = ScriptHandler.keysArrivedCount
        buffer.build { [weak self] in
            guard let self, pageGeneration == epoch, bufferIntent == intent, ScriptHandler.keysArrivedCount == keys, API.focusTreeInterceptor === self, !passThrough else { return }
            if !buffer.lines.isEmpty { action() }
            else {
                sayNothingOnPageYet()
                watchForContent()
            }
        }
        return true
    }

    func contentScript(_ script: Script) -> Script {
        if !passThrough, pageSilent, !buffer.lines.isEmpty { return copyOnlyScript(script) }
        guard !passThrough, buffer.lines.isEmpty, buffer.isLoading else { return script }
        let deferred = Script(name: script.name, description: script.description, category: script.category, owner: self) { [weak self] gesture in
            guard let self else { return }
            if !deferInitialContent({ script.handler(gesture) }) { script.handler(gesture) }
        }
        deferred.canPropagate = script.canPropagate
        deferred.bypassInputHelp = script.bypassInputHelp
        deferred.resumesSayAll = script.resumesSayAll
        deferred.isAvailable = script.isAvailable
        return deferred
    }

    /// A browse mode command on a page that is not answering: it runs inside the copy (readFromCopyIfSilent), so a
    /// command that reads goes on reading what was read, and nothing is asked of the page.
    func copyOnlyScript(_ script: Script) -> Script {
        let fromCopy = Script(name: script.name, description: script.description, category: script.category, owner: self) { [weak self] gesture in
            guard let self else { return }
            if !readFromCopyIfSilent({ script.handler(gesture) }) { script.handler(gesture) }
        }
        fromCopy.canPropagate = script.canPropagate
        fromCopy.bypassInputHelp = script.bypassInputHelp
        fromCopy.resumesSayAll = script.resumesSayAll
        fromCopy.isAvailable = script.isAvailable
        return fromCopy
    }

    func configureBuffer() {
        buffer.acceptsSnapshot = { [weak self] snapshot in
            guard let self else { return false }
            // A navigation can complete after the request but before its first AX read. Comparing only the
            // worker's start/end URL would miss that case and publish a new page under the old caret/address.
            guard let value = snapshot.nodes[ElementKey(webArea)]?.attributes["AXURL"]?.value else { return true }
            let address = (value as? URL)?.absoluteString ?? (value as? String) ?? ""
            return address == lastURL
        }
        buffer.didInvalidate = { [weak self] in
            guard let self, API.focusTreeInterceptor === self else { return }
            refreshIfNavigated()
            buffer.build()
        }
        buffer.didFail = { [weak self] in
            guard let self, API.focusTreeInterceptor === self else { return }
        }
        buffer.willPublish = { [weak self] in
            guard let self else { return }
            publicationWasEmpty = buffer.lines.isEmpty
            publicationAnchor = buffer.lines.isEmpty ? nil : BrowseModeHandler.Saved(offset: position, text: lineText(at: position))
        }
        buffer.didPublish = { [weak self] in
            guard let self else { return }
            let movedAt = positionMovedAt
            if let anchor = publicationAnchor { position = resumeOffset(anchor) }
            else { position = resumeOffset(BrowseModeHandler.cameBackByHistory ? BrowseModeHandler.shared.savedPosition(for: lastURL) : nil) }
            positionMovedAt = movedAt
            publicationAnchor = nil
            guard API.focusTreeInterceptor === self else { return }
            if Core.active, publicationWasEmpty, !buffer.lines.isEmpty { VoiceOverSounds.play("WebAreaLoaded.aiff") }
            // Nothing is said of a long page as it arrives: its rest is read on by itself (WebBuffer.fillOnIfWanted),
            // and "read in part" is for the reader who gets to the end of what there is first (reportBufferEnd).
            if buffer.rootFailed { followAfterRootFailure() }
            if !buffer.lines.isEmpty, !passThrough, (announceWhenReady || announcedURL != lastURL) {
                announceWhenReady = false
                announcePage()
            }
        }
    }

    func followFocusAfterBuild(_ element: AXUIElement, requiresFocus: Bool = true) {
        let epoch = pageGeneration
        let movedAt = positionMovedAt
        let intent = bufferIntent
        buffer.build { [weak self] in
            guard let self, pageGeneration == epoch, bufferIntent == intent, API.focusTreeInterceptor === self,
                  positionMovedAt == movedAt,
                  !requiresFocus || API.focusObject?.element.isSame(element) == true else { return }
            if let at = buffer.offset(of: element) { position = at }
        }
    }

    func reportBufferEnd(forward: Bool) {
        if !forward { Speech.speakMessage(String(localized: "top", comment: "Spoken message")) }
        else if buffer.isLoading { Speech.speakMessage(String(localized: "loading page", comment: "Spoken message")) }
        else if buffer.stoppedAtLimit { Speech.speakMessage(String(localized: "page read in part, it is very long", comment: "Spoken message")) }
        else if buffer.lines.isEmpty { sayNothingOnPageYet() }
        else { Speech.speakMessage(String(localized: "bottom", comment: "Spoken message")) }
    }

    func cancelBuffer() {
        pageGeneration += 1
        rootRunner.cancel(); discoveringRoot = false; followingRootFailure = false
        watchingFor = nil
        buffer.cancel()
    }
}
