// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverAX

/// Acknowledges the requested operation, not its completion. The 14 November 2026 log
/// shows the confirmation closing and focus moving, but no authoritative deletion result.
package final class ClaudeSessionDeletion {
    package init() {}

    private var target: (name: String, page: AXUIElement)?
    package var say: (String) -> Void = { Speech.speakMessage($0) }

    package func installScripts(on module: AppModule) {
        module.script("claude_confirmSessionDeletion", String(localized: "Confirms a Claude session deletion", comment: "A keyboard command"),
                      gestures: ["kb:enter", "kb:numpadEnter", "kb:space"], category: "Claude") { [weak self] key in
            _ = self?.activate(key)
        }.isAvailable = { [weak self] in self?.canActivate == true }
    }

    package func cancel() { target = nil }

    package func observe(_ event: Event) {
        if event.kind == .appModuleLoseFocus { cancel(); return }
        guard event.kind == .gainFocus else { return }
        let object = event.obj
        let prefix = "More options for "
        if object.axRole == "AXPopUpButton", object.name.hasPrefix(prefix),
           let page = API.focusTreeInterceptor?.webArea {
            let name = String(object.name.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            target = name.isEmpty ? nil : (name, page)
            return
        }
        // Menu navigation and the confirmation's own fields retain the known subject.
        // Another session, Prompt, or any unrelated control ends this operation's context.
        if object.axRole == "AXMenuItem" || isConfirmation(object) || insideConfirmation { return }
        cancel()
    }

    private func isConfirmation(_ object: TurnOverObject) -> Bool {
        object.role == .dialog && object.name == "Delete session?"
    }

    private var insideConfirmation: Bool { API.focusAncestors.contains { isConfirmation($0) } }

    private var scope: String? {
        guard let target, let page = API.focusTreeInterceptor?.webArea,
              target.page.isSame(page), insideConfirmation,
              let focus = API.focusObject, focus.axRole == "AXButton" else { return nil }
        switch focus.name {
        case "Delete this session": return "one"
        case "Delete 2 sessions": return "two"
        default: return nil
        }
    }

    package var canActivate: Bool { scope != nil }

    /// VO-Space delegates here using native Return; physical Enter/Space retain their key.
    @discardableResult
    package func activate(_ key: KeyboardGesture, useReturn: Bool = false) -> Bool {
        guard let scope, let target else { return false }
        cancel() // Repeated activation cannot reuse a subject from an already submitted operation.
        if useReturn { KeyboardGesture(identifier: "kb:enter")?.send() }
        else { key.send() }
        let message = scope == "two"
            ? String(localized: "Deleting \(target.name), 2 sessions", comment: "Acknowledges a requested deletion; does not claim success")
            : String(localized: "Deleting \(target.name)", comment: "Acknowledges a requested deletion; does not claim success")
        say(message)
        return true
    }
}
