// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverAX

/// Claude 5.1231.2, macOS 27.2, 15 Nov 2026: browser return reports the conversation's
/// web area, leaving letters trapped until punctuation gives its Prompt native focus.
/// Only this explicit return may restore the unique Prompt in the destination's copy.
package final class ClaudeBrowserReturn {
    private let pid: pid_t
    private var generation = 0
    private var armed = false
    private weak var page: BrowseModeDocument?
    private var prompt: AXUIElement?
    private var held: [KeyboardGesture] = []
    private var holdingSince: Date?
    private var latestKeys = 0
    private var searchUntil = Date.distantPast
    private let reader = AXWalkRunner<Bool>()
    package var now: () -> Date = Date.init
    package var confirm: (AXUIElement, @escaping (Bool) -> Void) -> Void = { element, done in
        BrowseModeDocument.confirmFocus(element, done: done)
    }

    package init(pid: pid_t) { self.pid = pid }

    private func isConversation(_ page: BrowseModeDocument) -> Bool {
        URL(string: page.lastURL)?.host?.lowercased() == "claude.ai"
    }

    package func cancel() {
        generation += 1
        armed = false
        page = nil
        prompt = nil
        held = []
        holdingSince = nil
        reader.cancel()
    }

    package func script(for key: KeyboardGesture, owner: ScriptableObject) -> Script? {
        if key.identifier == normalizeGestureIdentifier("kb:command+shift+b") {
            return Script(name: "claude_browserReturn", description: String(localized: "Shows or hides Claude's browser", comment: "Keyboard command"), category: "Claude", owner: owner) { [weak self] key in
                guard let self else { key.send(); return }
                cancel()
                // Opening the browser must preserve its own controls and typing.
                if let source = API.focusTreeInterceptor, source.webArea.pid == pid, !isConversation(source) {
                    armed = true
                    latestKeys = ScriptHandler.keysArrivedCount
                    searchUntil = now().addingTimeInterval(0.5)
                    let request = generation
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.findPrompt(request) }
                }
                key.send()
            }
        }
        guard armed else { return nil }
        // Plugins and user bindings resolve ahead of this module. Their intervening command
        // still advances the tap count, so a later letter cannot revive this return.
        let arrived = ScriptHandler.keysArrivedCount
        guard arrived == latestKeys || arrived == latestKeys + 1 else { cancel(); return nil }
        latestKeys = arrived
        let typing = key.modifiers.subtracting(.shift).isEmpty && key.typedCharacter.map { !$0.isNewline && $0 != "\t" && $0 != "\u{8}" } == true
        guard typing else { cancel(); return nil }
        guard let current = API.focusTreeInterceptor, current.webArea.pid == pid, isConversation(current) else {
            cancel()
            return nil
        }
        if current.passThrough && held.isEmpty { cancel(); return nil }
        let request = generation
        return Script(name: "claude_holdBrowserReturnTyping", description: String(localized: "Waits for Claude's Prompt to receive the keyboard", comment: "Keyboard command"), category: "Claude", owner: owner) { [weak self] key in
            guard let self, armed, generation == request else { return }
            held.append(key)
            if holdingSince == nil {
                holdingSince = now()
                searchUntil = now().addingTimeInterval(0.5)
                let request = generation
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, armed, generation == request else { return }
                    let hadTyping = !held.isEmpty
                    cancel()
                    if hadTyping { Speech.speakMessage(String(localized: "Prompt did not receive the keyboard; the held text was not typed", comment: "Claude browser return could not safely deliver typing")) }
                }
            }
            findPrompt(generation)
        }
    }

    package func handleEvent(_ event: Event) {
        guard armed else { return }
        if event.kind == .appModuleLoseFocus { cancel(); return }
        guard event.kind == .gainFocus else { return }
        if let prompt, event.obj.element.isSame(prompt) { return }
        if let current = API.focusTreeInterceptor, current.webArea.pid == pid,
           isConversation(current), page == nil || page === current {
            let destinationRoot = event.obj.element.isSame(current.webArea)
            let destinationPrompt = event.obj.axRole == "AXTextArea" && event.obj.name == "Prompt"
            if destinationRoot || destinationPrompt {
                searchUntil = now().addingTimeInterval(0.5)
                let request = generation
                DispatchQueue.main.async { [weak self] in self?.findPrompt(request) }
                return
            }
        }
        cancel()
    }

    private func findPrompt(_ request: Int) {
        guard armed, generation == request, API.focusPid == pid else { return }
        // A return remains armed until a command/departure, but never spins indefinitely
        // while an ignored shortcut or an incomplete copy offers no destination.
        guard now() < searchUntil else {
            if !held.isEmpty { fail() }
            return
        }
        guard let current = API.focusTreeInterceptor, isConversation(current) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.findPrompt(request) }
            return
        }
        if let page, page !== current { cancel(); return }
        page = current
        guard prompt == nil else { return }
        let candidates = current.buffer.withSnapshot {
            var unique: [ElementKey: AXUIElement] = [:]
            for line in current.buffer.lines {
                guard let element = line.element, element.role == "AXTextArea", element.string(kAXTitleAttribute) == "Prompt" else { continue }
                unique[ElementKey(element)] = element
            }
            return Array(unique.values)
        }
        guard candidates.count == 1, let target = candidates.first else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.findPrompt(request) }
            return
        }
        prompt = target
        let root = current.webArea
        reader.submit(collect: { work in
            AXReadScope.with(while: { !work.isCancelled }) {
                AXUIElementSetMessagingTimeout(target, 0.03)
                guard target.role == "AXTextArea", target.string(kAXTitleAttribute) == "Prompt" else { return false }
                var ancestor = target.element(kAXParentAttribute)
                let deadline = Date().addingTimeInterval(0.15)
                for _ in 0..<20 {
                    guard !work.isCancelled, Date() < deadline, let element = ancestor else { return false }
                    if element.isSame(root) { return true }
                    AXUIElementSetMessagingTimeout(element, 0.03)
                    ancestor = element.element(kAXParentAttribute)
                }
                return false
            }
        }, publish: { [weak self, weak current] valid in
            guard let self, let current, armed, generation == request,
                  API.focusPid == pid, API.focusTreeInterceptor === current else { return }
            guard ScriptHandler.keysArrivedCount == latestKeys else { cancel(); return }
            guard valid else { fail(); return }
            confirm(target) { [weak self, weak current] focused in
                guard let self, let current, armed, generation == request,
                      API.focusPid == pid, API.focusTreeInterceptor === current else { return }
                guard ScriptHandler.keysArrivedCount == latestKeys else { cancel(); return }
                guard focused else { fail(); return }
                if let since = holdingSince, now().timeIntervalSince(since) >= 0.5 { fail(); return }
                current.setPassThrough(true, announce: true)
                let keys = held
                cancel()
                for key in keys {
                    guard API.focusPid == pid, API.focusTreeInterceptor === current else { break }
                    key.send()
                }
            }
        })
    }

    private func fail() {
        let hadTyping = !held.isEmpty
        cancel()
        if hadTyping { Speech.speakMessage(String(localized: "Prompt did not receive the keyboard; the held text was not typed", comment: "Claude browser return could not safely deliver typing")) }
    }
}
