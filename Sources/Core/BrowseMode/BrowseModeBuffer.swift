// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverAX

extension BrowseModeDocument {
    /// A command that arrived during the first collection runs once its content is available. A later key,
    /// navigation or focus departure retires it, except Claude's explicit switch queue, which drains every key.
    /// The event-tap decision still returns immediately.
    package func deferInitialContent(_ action: @escaping () -> Void) -> Bool {
        if navigationReplaying { return false }
        if navigationWaiting {
            // 14 Nov 2026 review: neither a newer key nor the switch ceiling may throw a held key away.
            navigationHadCommand = true
            navigationRetries.append(action)
            return true
        }
        guard buffer.lines.isEmpty, buffer.isLoading else { return false }
        if earlyTitleURL == lastURL { navigationHadCommand = true }
        let epoch = pageGeneration, intent = bufferIntent, keys = ScriptHandler.keysArrivedCount
        buffer.build { [weak self] in
            guard let self, pageGeneration == epoch, bufferIntent == intent, ScriptHandler.keysArrivedCount == keys, API.focusTreeInterceptor === self, !passThrough else { return }
            if !buffer.lines.isEmpty { action() }
            else {
                Speech.speakMessage(String(localized: "nothing on this page yet; it may still be loading", comment: "Spoken message"))
                watchForContent()
            }
        }
        return true
    }

    func contentScript(_ script: Script) -> Script {
        let firstContentIsLoading = !passThrough &&
            buffer.lines.isEmpty &&
            buffer.isLoading
        guard navigationWaiting ||
              firstContentIsLoading else { return script }
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

    /// Only Claude opts in. Preserve the copy until its address changes: choosing the current conversation
    /// must keep its reading position. refreshIfNavigated retires the copy when a new address is observed.
    package func beginNavigationWait() {
        bufferIntent += 1
        navigationWaiting = true
        if navigationRetries.isEmpty { navigationHadCommand = false }
        earlyTitleURL = nil
        lastQuickNavTarget = nil
        lastChain = []
        passThrough = false
    }

    package func finishNavigationWait(title: String?, announce: Bool = true) {
        guard navigationWaiting else { return }
        navigationWaiting = false
        earlyTitleURL = lastURL
        if let title,
           !title.isEmpty { announceNavigationTitle(title) }
        let retries = navigationRetries
        navigationRetries = []
        if announce,
           !buffer.lines.isEmpty { announcePage() }
        // Drain once on every exit, including the ceiling and focus departure. Replayed commands cannot
        // fall back into first-content deferral and silently expire behind a later key (14 Nov 2026 review).
        navigationReplaying = true
        defer { navigationReplaying = false }
        for retry in retries { retry() }
    }

    func announceNavigationTitle(_ title: String) {
        earlyTitleURL = lastURL
        Speech.speakMessage(title)
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

    func reportBufferEnd(forward: Bool, fromCopy: Bool = false) {
        if !forward { Speech.speakMessage(String(localized: "top", comment: "Spoken message")) }
        else if buffer.isLoading &&
                !fromCopy { Speech.speakMessage(String(localized: "loading page", comment: "Spoken message")) }
        else if buffer.stoppedAtLimit { Speech.speakMessage(String(localized: "page read in part, it is very long", comment: "Spoken message")) }
        else if buffer.lines.isEmpty { Speech.speakMessage(String(localized: "nothing on this page yet; it may still be loading", comment: "Spoken message")) }
        else { Speech.speakMessage(String(localized: "bottom", comment: "Spoken message")) }
    }

    func cancelBuffer() {
        pageGeneration += 1
        rootRunner.cancel(); discoveringRoot = false; followingRootFailure = false
        watchingFor = nil
        buffer.cancel()
    }
}
