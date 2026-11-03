// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverAX

extension BrowseModeDocument {
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
            reportPartialBuffer()
        }
        buffer.willPublish = { [weak self] in
            guard let self else { return }
            SayAll.stopReading(buffer: buffer, preservingPageTurn: true)
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
            reportPartialBuffer()
            if !buffer.lines.isEmpty, !passThrough, (announceWhenReady || announcedURL != lastURL) {
                announceWhenReady = false
                announcePage()
            }
        }
    }

    private func reportPartialBuffer() {
        guard buffer.isPartial, !saidPartial else { return }
        saidPartial = true
        Speech.speakMessage(String(localized: "page read in part; more content may be missing", comment: "Spoken when document collection stops before the entire page is available"))
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
        if buffer.isLoading { Speech.speakMessage(String(localized: "loading page", comment: "Spoken message")) }
        else if buffer.isPartial { Speech.speakMessage(String(localized: "end of the available content; the page was read in part", comment: "Spoken instead of a complete-page boundary when document collection was incomplete")) }
        else { Speech.speakMessage(forward ? String(localized: "bottom", comment: "Spoken message") : String(localized: "top", comment: "Spoken message")) }
    }

    func cancelBuffer() {
        SayAll.stopReading(buffer: buffer)
        pageGeneration += 1
        rootRunner.cancel(); discoveringRoot = false
        watchingFor = nil
        buffer.cancel()
    }
}
