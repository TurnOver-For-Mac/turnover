// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices

/// Main owns one document's listening state. Worker replies must still own its activation and focused editor.
package final class GoogleDocsSession: DocumentAdapter {
    package typealias Read = (DocumentContext, GoogleDocsRead, @escaping @MainActor @Sendable (GoogleDocsResult) -> Void) -> Void
    package typealias Repeating = (@escaping @MainActor @Sendable () -> Void) -> @MainActor () -> Void
    package typealias After = (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void
    private let context: DocumentContext
    private let read: Read?
    private let repeating: Repeating
    private let after: After
    private let keyCount: @Sendable () -> Int
    private let hint: (String, @escaping @MainActor () -> Bool) -> Void
    private let pollWorker = AXWalkRunner<GoogleDocsResult>()
    private let supportWorker = AXWalkRunner<GoogleDocsResult>()
    private var current: @MainActor () -> Bool = { false }
    private var active = false
    private var lifetime = UUID()
    private var editorGeneration = UUID()
    private var editor: AXUIElement?
    private var region: AXUIElement?
    private var lastHeard: String?
    private var keysAtFocus = 0
    private var pending: UUID?
    private var cancelTimer: (@MainActor () -> Void)?
    private var warned = false

    package init(context: DocumentContext, read: Read? = nil,
                 repeating: @escaping Repeating = { tick in
                     // Created on main's run loop; Timer delivers this callback on that same run loop.
                     let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
                     return { timer.invalidate() }
                 },
                 after: @escaping After = { delay, callback in onMain(after: delay, callback) },
                 keyCount: @escaping @Sendable () -> Int = { ScriptHandler.keysArrivedCount },
                 hint: @escaping (String, @escaping @MainActor () -> Bool) -> Void = { text, current in Hints.schedule(text, while: current) }) {
        self.context = context; self.read = read; self.repeating = repeating
        self.after = after; self.keyCount = keyCount; self.hint = hint
    }

    package var usesNativeTextFeedback: Bool { active && editor != nil }

    package func activate(isCurrent: @escaping @MainActor () -> Bool) {
        current = isCurrent
        guard !active, current() else { return }
        active = true; lifetime = UUID()
        let activation = lifetime
        guard !warned else { return }
        after(3) { [weak self] in
            guard let self, self.valid(activation) else { return }
            self.collect(.support) { [weak self] result in
                guard let self, self.valid(activation) else { return }
                if case .differentDocument = result { self.deactivate(); return }
                guard case .support(false) = result, !self.warned else { return }
                self.warned = true
                self.hint(String(localized: "Google's screen reader support is off for this document, so its text can't be read. Press Command Option Z to turn it on; Google remembers it.", comment: "Spoken message")) { [weak self] in
                    self?.valid(activation) == true
                }
            }
        }
    }

    package func focusChanged(_ focus: DocumentFocus) {
        guard active else { return }
        guard !focus.isSecure, ["AXTextArea", "AXTextField"].contains(focus.role) else { stopPolling(); return }
        if editor?.isSame(focus.element) == true, cancelTimer != nil { return }
        stopPolling()
        editor = focus.element
        keysAtFocus = keyCount()
        cancelTimer = repeating { [weak self] in self?.poll() }
        poll()
    }

    private func valid(_ activation: UUID) -> Bool { active && lifetime == activation && current() }

    private func poll() {
        guard active, current() else { deactivate(); return }
        guard pending == nil, let editor else { return }
        let request = UUID()
        pending = request
        let activation = lifetime, generation = editorGeneration
        collect(.announcements(editor: editor, region: region)) { [weak self] result in
            guard let self, self.valid(activation), self.editorGeneration == generation, self.pending == request else { return }
            self.pending = nil
            switch result {
            case .differentDocument: self.deactivate()
            case .announcements(let region, let text):
                self.region = region
                let previous = self.lastHeard
                self.lastHeard = text
                // The initial region is a baseline, unless a key has already asked Google for new feedback.
                // Collection leaves main, so that first key must not disappear while the baseline is in flight.
                if previous == nil, self.keyCount() == self.keysAtFocus { return }
                let news = previous.flatMap { before in
                    !before.isEmpty && text.hasPrefix(before) ? String(text.dropFirst(before.count)).trimmingCharacters(in: .whitespaces) : nil
                } ?? text
                guard text != previous, !news.isEmpty else { return }
                Speech.asPrivate { Speech.cancel(); Speech.speakText(news) }
            default: break   // absence, timeout and provider backoff cannot replace the last complete sample
            }
        }
    }

    private func collect(_ kind: GoogleDocsRead, publish: @escaping @MainActor @Sendable (GoogleDocsResult) -> Void) {
        if let read { read(context, kind, publish); return }
        let context = self.context
        let worker: AXWalkRunner<GoogleDocsResult>
        if case .support = kind { worker = supportWorker } else { worker = pollWorker }
        worker.submit { request in GoogleDocsQuery.read(context, kind, request: request) } publish: { result in publish(result) }
    }

    private func stopPolling() {
        cancelTimer?(); cancelTimer = nil
        pollWorker.cancel()
        editorGeneration = UUID()
        editor = nil; region = nil; lastHeard = nil; pending = nil
    }

    package func deactivate() {
        active = false; lifetime = UUID()
        stopPolling(); supportWorker.cancel()
    }
}
