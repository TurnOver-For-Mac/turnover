// SPDX-License-Identifier: GPL-3.0-or-later
// The system's own prompts over an application: Touch ID ("Safari is trying to use AutoFill"), and the password
// prompt for an administrator. They are drawn by agents (coreautha, SecurityAgent) that never become the active
// application, so TurnOver never looked at them and they went unspoken (3 Oct 2026; VoiceOver reads them).
// While TurnOver leads, a prompt's text is read when it appears and the focus goes into it (its buttons, its
// password field); when it goes, the focus goes back to the application.
import Foundation
import AppKit
import ApplicationServices

public final class SystemPrompts {
    public static let shared = SystemPrompts()
    /// The agents that draw the system's own prompts. UserNotificationCenter ("would like access to record your system
    /// audio") and CoreLocationAgent ("would like to use your current location") were not watched, so a prompt that
    /// came up behind Claude was never said (12 Oct 2026: VoiceOver says there is a system request).
    static let agents = ["com.apple.LocalAuthentication.UIAgent", "com.apple.SecurityAgent", "com.apple.UserNotificationCenter",
                         "com.apple.CoreLocationAgent", "com.apple.coreservices.uiagent"]

    /// Prompts macOS protects: an Accessibility press from TurnOver is refused (CoreLocationAgent put its focus back on
    /// "Don't Allow" and drew the prompt again, twice, 12 Oct 2026); the user's own keys always work.
    public static func isProtected(_ pid: pid_t) -> Bool {
        guard let b = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
        return agents.contains(b)
    }

    /// After TurnOver pressed a button in a protected prompt: if the prompt is still there a moment later, macOS
    /// refused the press. The focus goes back onto the button and the user is asked for a real Space, which macOS takes.
    public static func checkPress(of button: AXUIElement, name: String) {
        guard isProtected(button.pid), let window = button.element(kAXWindowAttribute) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let r = window.role
            guard !r.isEmpty, r != "?" else { Log.io("protected prompt: the press of \(Log.words(name)) was taken"); return }
            _ = button.set(kAXFocusedAttribute, kCFBooleanTrue)
            Log.io("protected prompt: macOS refused TurnOver's press of \(Log.words(name)); focus put back on it, Space asked for")
            Speech.speakMessage("macOS only takes a real key here. \(name) has the focus: press Space.")
        }
    }
    private var timer: Timer?
    private var shown: [AXUIElement] = []
    /// What each prompt said first, for the reminder and the application chooser.
    private var summaries: [(window: AXUIElement, pid: pid_t, text: String)] = []

    /// The prompts open now, with their first line: a prompt read once while the user was away stayed open with
    /// nothing pointing to it (Command Tab and the application chooser left it out; the keychain's password prompt
    /// at build 18's publish, 14 Oct 2026, was found only by turning VoiceOver on).
    public var waiting: [(window: AXUIElement, pid: pid_t, text: String)] {
        summaries.filter { p in shown.contains { $0.isSame(p.window) } && p.window.role != "?" && !p.window.role.isEmpty }
    }
    private var lastReminder = Date.distantPast

    /// Another application came to the front while a prompt waits: say so, after the application, with the way to it.
    public func remindIfWaiting(activated pid: pid_t) {
        guard let p = waiting.first, p.pid != pid, Date().timeIntervalSince(lastReminder) > 5 else { return }
        lastReminder = Date()
        let key = config.general.windowsKeys ? "Option Tab" : "VO-F1 twice"
        Log.io("system prompt still open (pid \(p.pid)); reminded")
        Speech.speakMessage("system dialog waiting: \(p.text). \(key) to go to it")
    }

    func start() {
        // The agents start when first needed and may go again: look twice a second (a list of running
        // applications and, for an agent that is running, its windows: cheap).
        timer?.invalidate()   // (one timer, however many hand-overs: they piled up, 8 Oct 2026)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.check() } }
    }

    private func check() {
        var windows: [(AXUIElement, pid_t)] = []
        for bundle in Self.agents {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundle) {
                let pid = app.processIdentifier
                AXHandler.shared.observe(pid)
                let ax = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(ax, 0.5)
                windows += ax.elements(kAXWindowsAttribute).map { ($0, pid) }
            }
        }
        let gone = !shown.isEmpty && !shown.allSatisfy { w in windows.contains { $0.0.isSame(w) } }
        shown.removeAll { w in !windows.contains { $0.0.isSame(w) } }
        summaries.removeAll { p in !shown.contains { $0.isSame(p.window) } }
        if gone, shown.isEmpty, let front = NSWorkspace.shared.frontmostApplication {
            Log.io("system prompt closed; focus back to \(front.localizedName ?? "?")")
            AXHandler.shared.refocus(pid: front.processIdentifier)
        }
        for (w, pid) in windows where !shown.contains(where: { $0.isSame(w) }) {
            shown.append(w)
            announce(w, pid: pid)
        }
    }

    /// The agent came to the front: read its window now (the regular look comes every half second, after the focus
    /// had already been read).
    func announceFront(pid: pid_t) {
        let ax = AXUIElementCreateApplication(pid)
        guard let w = ax.element(kAXFocusedWindowAttribute) ?? ax.elements(kAXWindowsAttribute).first else { return }
        if shown.contains(where: { $0.isSame(w) }), Date().timeIntervalSince(lastAnnounced) < 2 { return }
        if !shown.contains(where: { $0.isSame(w) }) { shown.append(w) }
        announce(w, pid: pid)
    }
    private var lastAnnounced = Date.distantPast

    private func announce(_ window: AXUIElement, pid: pid_t) {
        lastAnnounced = Date()
        var texts: [String] = []
        var stack = [window]; var visited = 0
        while let e = stack.popLast(), visited < 200 {
            visited += 1
            if e.role == "AXStaticText", let v = e.string(kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { texts.append(v) }
            stack.append(contentsOf: e.elements(kAXChildrenAttribute).reversed())
        }
        guard !texts.isEmpty || window.element(kAXFocusedUIElementAttribute) != nil else { return }
        Log.io("system prompt from pid \(pid): \(texts.count) lines")
        summaries.removeAll { $0.window.isSame(window) }
        summaries.append((window, pid, texts.first.map { String($0.prefix(120)) } ?? "untitled"))
        Speech.cancel()
        Speech.speakMessage(([Self.isProtected(pid) ? "system dialog" : "dialog"] + texts).joined(separator: ", "))
        let ax = AXUIElementCreateApplication(pid)
        if let f = ax.element(kAXFocusedUIElementAttribute) {
            giveKeyboard(to: f)
            AXHandler.shared.focusChanged(f, pid: pid)
        }
        // After the button's own hint: what to do with the prompt as a whole.
        let all = texts.joined(separator: " ").lowercased()
        DispatchQueue.main.async {
            Hints.schedule(all.contains("touch id") ? "Touch the Touch ID sensor, or Tab to Enter Password or Cancel."
                           : Self.isProtected(pid) ? "Tab moves between the choices; Space presses the one you are on." : "Tab moves between the choices; Return presses.")
        }
    }

    /// Make a prompt's control really have the keyboard, not only TurnOver's attention: the agent's window can open
    /// without becoming the key window, and typing then goes to the application behind it (5 Oct 2026). Bring the
    /// agent forward, raise its window and focus the control.
    public func giveKeyboard(to control: AXUIElement) {
        let pid = control.pid
        NSRunningApplication(processIdentifier: pid)?.activate()
        let app = AXUIElementCreateApplication(pid)
        _ = app.set(kAXFrontmostAttribute, kCFBooleanTrue)
        if let w = control.element(kAXWindowAttribute) {
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            _ = w.set(kAXMainAttribute, kCFBooleanTrue)
        }
        _ = control.set(kAXFocusedAttribute, kCFBooleanTrue)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            Log.io("system prompt: keyboard \(front == pid ? "is with the prompt" : "still with pid \(front ?? -1)")")
        }
    }
}
