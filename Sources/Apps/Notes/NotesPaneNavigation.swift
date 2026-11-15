// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices

/// Notes' view switches replace whole panes. Observed 14 November 2026: Command 1/2 in the attachment
/// browser left its list focused, and cached panes still answered after disappearing. Keep this policy in Notes.
/// Native keys: https://support.apple.com/guide/notes/keyboard-shortcuts-and-gestures-apd46c25187e/mac
public final class NotesPaneNavigation {
    private let view: PanesView
    private let pid: pid_t
    private var generation = 0

    public init(view: PanesView) { self.view = view; pid = view.pid }

    private func browser() -> AXUIElement? {
        var match = ElementMatch()
        match.role = "AXGroup"
        match.description = "attachment browser"
        return PanesView.find(match, pid: pid, budget: 0.15)
    }

    private func window() -> AXUIElement? {
        AXUIElementCreateApplication(pid).element(kAXFocusedWindowAttribute)
    }

    /// Tab leaves the attachments browser before traversing the ordinary Folders / Notes / Note cycle.
    public func step(forward: Bool) {
        generation += 1
        view.invalidate()
        guard browser() != nil else { view.step(forward: forward); return }
        ObjectNavigator.shared.releaseHold()
        KeyboardGesture(identifier: "kb:command+3")?.send()
        settle(ready: { [weak self] in self?.browser() == nil }) { [weak self] ready in
            guard let self else { return }
            if ready { self.view.step(forward: forward, from: forward ? self.view.parts.count - 1 : 2) }
            else { Speech.speakMessage(String(localized: "cannot leave the attachments browser", comment: "Spoken message")) }
        }
    }

    public func changeView(_ key: KeyboardGesture) {
        generation += 1
        ObjectNavigator.shared.releaseHold()
        view.invalidate()
        let hadBrowser = browser() != nil
        let hadFolders = view.element(of: 0) != nil
        // Apple's list/gallery shortcuts do not dismiss the attachments browser in the trial log.
        if hadBrowser, ["1", "2"].contains(key.keyName) {
            KeyboardGesture(identifier: "kb:command+3")?.send()
            settle(ready: { [weak self] in self?.browser() == nil }) { [weak self] ready in
                guard let self else { return }
                if ready { self.sendAndReport(key, hadBrowser: false, hadFolders: hadFolders) }
                else { Speech.speakMessage(String(localized: "cannot leave the attachments browser", comment: "Spoken message")) }
            }
            return
        }
        sendAndReport(key, hadBrowser: hadBrowser, hadFolders: hadFolders)
    }

    private func sendAndReport(_ key: KeyboardGesture, hadBrowser: Bool, hadFolders: Bool) {
        key.send()
        settle(ready: { [weak self] in
            guard let self else { return false }
            switch key.keyName {
            case "0": return (self.view.element(of: 0) != nil) != hadFolders
            case "1": return self.browser() == nil && self.view.element(of: 1)?.role == "AXTable"
            case "2": return self.browser() == nil && self.view.element(of: 1)?.role == "AXList"
            case "3": return (self.browser() != nil) != hadBrowser
            default: return false
            }
        }) { [weak self] ready in
            guard let self else { return }
            let name: String
            switch key.keyName {
            case "0": name = self.view.element(of: 0) == nil
                ? String(localized: "folders hidden", comment: "Notes view change")
                : String(localized: "folders shown", comment: "Notes view change")
            case "1": name = String(localized: "list view", comment: "Notes view change")
            case "2": name = String(localized: "gallery view", comment: "Notes view change")
            default: name = self.browser() != nil
                ? String(localized: "attachments browser", comment: "Notes view change")
                : String(localized: "notes view", comment: "Notes view change")
            }
            if ready { Speech.speakOnly(name) }
            else { Speech.speakMessage(String(localized: "\(name): the view did not change", comment: "Notes did not confirm the requested view")) }
            if let focused = AXUIElementCreateApplication(self.pid).element(kAXFocusedUIElementAttribute) {
                Speech.speakObject(ObjectFactory.make(focused), reason: .query)
            }
        }
    }

    /// Bounded asynchronous checks; a later key, window or application retires the old announcement.
    private func settle(ready: @escaping () -> Bool, completion: @escaping (Bool) -> Void) {
        let request = generation
        let keys = ScriptHandler.keysArrivedCount
        let originalWindow = window()
        let deadline = Date().addingTimeInterval(0.7)
        func look() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self, self.generation == request, API.focusPid == self.pid,
                      ScriptHandler.keysArrivedCount == keys,
                      let originalWindow, let currentWindow = self.window(), originalWindow.isSame(currentWindow) else { return }
                self.view.invalidate()
                if ready() { completion(true) }
                else if Date() >= deadline { completion(false) }
                else { look() }
            }
        }
        look()
    }
}
