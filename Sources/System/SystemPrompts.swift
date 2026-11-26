// SPDX-License-Identifier: GPL-3.0-or-later
// The system's own prompts over an application: Touch ID ("Safari is trying to use AutoFill"), and the password
// prompt for an administrator. They are drawn by agents (coreautha, SecurityAgent) that never become the active
// application, so TurnOver never looked at them and they went unspoken (3 Oct 2026; VoiceOver reads them).
// While TurnOver leads, a prompt's text is read when it appears and the focus goes into it (its buttons, its
// password field); when it goes, the focus goes back to the application. With CoExist, a prompt is VoiceOver's:
// TurnOver steps aside while it is open (onPromptChange) and comes back after.
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

    static func keepsActionKey(_ gesture: KeyboardGesture, frontmostBundle: () -> String?) -> Bool {
        guard gesture.modifiers.isEmpty, ["space", "enter", "numpadEnter", "escape"].contains(gesture.keyName),
              let bundle = frontmostBundle() else { return false }
        return agents.contains(bundle)
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
            Speech.speakMessage(String(localized: "macOS only takes a real key here. \(name) has the focus: press Space.", comment: "A protected macOS prompt: %@ is the button"))
        }
    }
    private struct PromptText {
        let lines: [String]
        let canRestore: Bool
        var matchingLines: [String]? { canRestore ? lines : nil }
        var summary: String { lines.first.map { String($0.prefix(120)) } ?? "untitled" }
    }

    private struct OpenPrompt {
        let window: AXUIElement
        let pid: pid_t
        let id: Int
        var text: PromptText?
    }

    private var timer: Timer?
    private var shown: [OpenPrompt] = []
    private var continuity = SystemPromptContinuity()
    /// With VoiceOver running (CoExist), macOS's own prompts are VoiceOver's entirely (18 Oct 2026: VoiceOver
    /// "could take over in higher security dialogues, which keeps TurnOver more secure"): TurnOver neither reads them
    /// nor takes their keys. The app is told when the first opens (true) and the last closes (false), and steps aside.
    public var onPromptChange: ((Bool) -> Void)?
    public var handsToVoiceOver: Bool { Coexist.on && NSWorkspace.shared.isVoiceOverEnabled && onPromptChange != nil }
    /// The prompts open now, with their first line: a prompt read once while the user was away stayed open with
    /// nothing pointing to it (Command Tab and the application chooser left it out; the keychain's password prompt
    /// at build 18's publish, 14 Oct 2026, was found only by turning VoiceOver on).
    public var waiting: [(window: AXUIElement, pid: pid_t, text: String)] {
        waitingPrompts.compactMap { p in p.text.map { (p.window, p.pid, $0.summary) } }
    }

    private var waitingPrompts: [OpenPrompt] {
        shown.filter { p in
            guard p.text != nil else { return false }
            let role = p.window.role
            return role != "?" && !role.isEmpty
        }
    }

    private func updateScreenLock(now: TimeInterval) {
        // LeadWatcher reads the same session flag in the app target. Sample even when no prompt is listed.
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return }
        let locked = (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
        continuity.observeLock(locked, now: now)
    }

    /// Another application came to the front while a prompt waits: say so, after the application, with the way to it.
    public func remindIfWaiting(activated pid: pid_t) {
        let now = ProcessInfo.processInfo.systemUptime
        updateScreenLock(now: now)
        guard !continuity.locked else { return }
        let prompts = waitingPrompts
        guard let index = continuity.nextReminder(in: prompts.map { ($0.id, $0.pid) }, activated: pid, now: now),
              let text = prompts[index].text else { return }
        let p = prompts[index]
        let key = config.general.windowsKeys ? String(localized: "Option Tab", comment: "Keys to reach a waiting system dialog") : String(localized: "VO-F1 twice", comment: "Keys to reach a waiting system dialog")
        Log.io("system prompt still open (pid \(p.pid)); reminded")
        Speech.speakMessage(String(localized: "system dialog waiting: \(text.summary). \(key) to go to it", comment: "A system dialog waiting: its words, then the keys to reach it"))
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
        let now = ProcessInfo.processInfo.systemUptime
        updateScreenLock(now: now)
        let disappeared = shown.filter { p in !windows.contains { $0.0.isSame(p.window) } }
        for p in disappeared {
            continuity.park(id: p.id, pid: p.pid, lines: p.text?.matchingLines, now: now)
        }
        shown.removeAll { p in disappeared.contains { $0.id == p.id } }
        // Housekeeping only: which parked prompts have run out of time, and the reminder history that goes with them.
        _ = continuity.discardExpired(open: shown.map(\.id), now: now)
        // The last prompt has gone: the focus goes back at once, as it always did. Holding this until a parked prompt
        // ran out of time (the 10 seconds it is given for a lock to follow) left the focus unread for 10 seconds after
        // every ordinary close, then read it out of nowhere (a review, 26 Nov 2026). A lock is usually reported after
        // the windows have gone, so this runs then too, as it did before.
        if !disappeared.isEmpty, shown.isEmpty {
            if handsToVoiceOver { onPromptChange?(false) }
            if !continuity.locked, let front = NSWorkspace.shared.frontmostApplication {
                Log.io("system prompt closed; focus back to \(front.localizedName ?? "?")")
                AXHandler.shared.refocus(pid: front.processIdentifier)
            }
        }
        guard !continuity.locked else { return }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for (w, pid) in windows where !shown.contains(where: { $0.window.isSame(w) }) {
            show(w, pid: pid, now: now, hasKeyboard: front == pid)
        }
    }

    /// `hasKeyboard`: the prompt's agent is the application in front, so the prompt is where the keys go.
    private func show(_ window: AXUIElement, pid: pid_t, now: TimeInterval, hasKeyboard: Bool) {
        let first = shown.isEmpty
        let voiceOver = handsToVoiceOver
        let text = voiceOver ? nil : readPrompt(window, pid: pid)
        let appearance = continuity.appear(pid: pid, lines: text?.matchingLines, now: now)
        shown.append(.init(window: window, pid: pid, id: appearance.id, text: text))
        // The same prompt back after a lock keeps its reminder history, and behind another application it is not read
        // again or given the keyboard (25 Nov 2026: one crash dialog was read in full five times in a day, at each
        // unlock). With the keyboard it is read like any place the person lands in: silence there would leave them in
        // a dialog without knowing it (a review, 26 Nov 2026).
        if appearance.quietUntil != nil, !hasKeyboard {
            Log.io("system prompt from pid \(pid): the same one back after a lock; not read again")
            return
        }
        if voiceOver {
            // The prompt can open without the keyboard. Give it to VoiceOver and step aside.
            Log.io("system prompt from pid \(pid): VoiceOver's")
            if first { onPromptChange?(true) }
            if let f = AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute) { giveKeyboard(to: f) }
        } else {
            announce(text, pid: pid)
        }
    }

    /// The agent came to the front: read its window now (the regular look comes every half second, after the focus
    /// had already been read).
    func announceFront(pid: pid_t) {
        let now = ProcessInfo.processInfo.systemUptime
        updateScreenLock(now: now)
        guard !continuity.locked, !handsToVoiceOver else { return }
        let ax = AXUIElementCreateApplication(pid)
        guard let w = ax.element(kAXFocusedWindowAttribute) ?? ax.elements(kAXWindowsAttribute).first else { return }
        // In front, a prompt is always read, one that came back after a lock too: the keys go to it now. (The tone is
        // played by the caller, for every agent that comes to the front.)
        guard let index = shown.firstIndex(where: { $0.window.isSame(w) }) else {
            show(w, pid: pid, now: now, hasKeyboard: true)
            return
        }
        guard Date().timeIntervalSince(lastAnnounced) >= 2 else { return }
        guard let text = readPrompt(w, pid: pid) else {
            // A failed reread leaves the reminder's last known summary available.
            lastAnnounced = Date()
            return
        }
        var prompt = shown.remove(at: index)
        prompt.text = text
        shown.append(prompt)
        announce(text, pid: pid)
    }
    private var lastAnnounced = Date.distantPast

    private func readPrompt(_ window: AXUIElement, pid: pid_t) -> PromptText? {
        var texts: [String] = []
        var stack = [window]
        var visited = 0
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        // Authentication agents and prompts with text entry must be read, even if their visible words match.
        var canRestore = bundle != nil && bundle != "com.apple.SecurityAgent" && bundle != "com.apple.LocalAuthentication.UIAgent"
        while visited < 200, let e = stack.popLast() {
            visited += 1
            switch e.role {
            case "AXStaticText":
                if let value = e.string(kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    if !value.isEmpty { texts.append(value) }
                } else {
                    canRestore = false
                }
            case "AXTextField", "AXTextArea", "AXComboBox", "AXSecureTextField", "?", "":
                canRestore = false
            default:
                break
            }
            let (children, error) = e.attrError(kAXChildrenAttribute)
            if let children = children as? [AXUIElement] {
                stack.append(contentsOf: children.reversed())
            } else if error != .attributeUnsupported, error != .noValue {
                canRestore = false
            }
        }
        guard !texts.isEmpty || window.element(kAXFocusedUIElementAttribute) != nil else { return nil }
        let asksForCredentials = texts.contains {
            $0.localizedCaseInsensitiveContains("password") || $0.localizedCaseInsensitiveContains("keychain")
        }
        return PromptText(lines: texts, canRestore: canRestore && stack.isEmpty && !texts.isEmpty && !asksForCredentials)
    }

    private func announce(_ text: PromptText?, pid: pid_t) {
        lastAnnounced = Date()
        guard let texts = text?.lines else { return }
        Log.io("system prompt from pid \(pid): \(texts.count) lines")
        Speech.cancel()
        Speech.speakMessage(([Self.isProtected(pid) ? String(localized: "system dialog", comment: "A role: a macOS system dialog") : Role.dialog.displayString] + texts).joined(separator: ", "))
        let ax = AXUIElementCreateApplication(pid)
        if let f = ax.element(kAXFocusedUIElementAttribute) {
            giveKeyboard(to: f)
            AXHandler.shared.focusChanged(f, pid: pid)
        }
        // After the button's own hint: what to do with the prompt as a whole.
        let all = texts.joined(separator: " ").lowercased()
        DispatchQueue.main.async {
            Hints.schedule(all.contains("touch id") ? String(localized: "Touch the Touch ID sensor, or Tab to Enter Password or Cancel.", comment: "A hint in a system dialog")
                           : Self.isProtected(pid) ? String(localized: "Tab moves between the choices; Space presses the one you are on.", comment: "A hint in a system dialog") : String(localized: "Tab moves between the choices; Return presses.", comment: "A hint in a system dialog"))
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

/// Reminder history belongs to the open dialog, independently of its summary being read again.
/// An application switch can remind once immediately and once more after five minutes (14 Nov 2026).
package struct SystemPromptReminders<Window> {
    private struct Reminder {
        var window: Window
        var first: TimeInterval
        var repeated = false
    }
    private var history: [Reminder] = []
    private let isSame: (Window, Window) -> Bool

    package init(isSame: @escaping (Window, Window) -> Bool) {
        self.isSame = isSame
    }

    package mutating func retainOpen(_ windows: [Window]) {
        let same = isSame
        history.removeAll { reminder in !windows.contains { same($0, reminder.window) } }
    }

    package mutating func next(in prompts: [(window: Window, pid: pid_t)], activated pid: pid_t,
                               now: TimeInterval) -> Int? {
        for (index, prompt) in prompts.enumerated() where prompt.pid != pid {
            if let previous = history.firstIndex(where: { isSame($0.window, prompt.window) }) {
                guard !history[previous].repeated, now - history[previous].first >= 300 else { continue }
                history[previous].repeated = true
            } else {
                history.append(Reminder(window: prompt.window, first: now))
            }
            return index
        }
        return nil
    }
}

/// A window can leave the agent's list just before the session reports the lock (25 Nov 2026).
/// An internal id follows the prompt across that gap, even if the agent returns a different AX window.
package struct SystemPromptContinuity {
    package struct Appearance {
        package let id: Int
        package let quietUntil: TimeInterval?
    }

    private enum Phase {
        case awaitingLock(until: TimeInterval)
        case hiddenByLock
        case awaitingReturn(until: TimeInterval)
    }

    private struct Parked {
        let id: Int
        let pid: pid_t
        let lines: [String]?
        var phase: Phase
    }

    private var parked: [Parked] = []
    private var nextID = 0
    private var reminders = SystemPromptReminders<Int>(isSame: ==)
    package private(set) var locked = false

    package init() {}

    package mutating func observeLock(_ locked: Bool, now: TimeInterval) {
        guard locked != self.locked else { return }
        self.locked = locked
        for index in parked.indices {
            switch parked[index].phase {
            case .awaitingLock(let until) where locked && now <= until:
                parked[index].phase = .hiddenByLock
            case .hiddenByLock where !locked:
                parked[index].phase = .awaitingReturn(until: now + 30)
            default:
                break
            }
        }
    }

    package mutating func park(id: Int, pid: pid_t, lines: [String]?, now: TimeInterval) {
        let phase: Phase = locked ? .hiddenByLock : .awaitingLock(until: now + 10)
        parked.append(Parked(id: id, pid: pid, lines: lines, phase: phase))
    }

    package mutating func appear(pid: pid_t, lines: [String]?, now: TimeInterval) -> Appearance {
        if !locked, let lines, !lines.isEmpty {
            let matches = parked.indices.filter { index in
                let prompt = parked[index]
                guard prompt.pid == pid, prompt.lines == lines,
                      case .awaitingReturn(let until) = prompt.phase else { return false }
                return now <= until
            }
            if matches.count == 1, let index = matches.first,
               case .awaitingReturn(let until) = parked[index].phase {
                let prompt = parked.remove(at: index)
                return Appearance(id: prompt.id, quietUntil: until)
            }
            // If the words come back before any lock, the earlier disappearance was an ordinary close.
            parked.removeAll { prompt in
                guard prompt.pid == pid, prompt.lines == lines, case .awaitingLock = prompt.phase else { return false }
                return true
            }
        }
        nextID += 1
        return Appearance(id: nextID, quietUntil: nil)
    }

    /// Returns whether an ordinary disappearance has been confirmed and none still await a lock.
    package mutating func discardExpired(open: [Int], now: TimeInterval) -> Bool {
        var closed = false
        var awaitingLock = false
        parked.removeAll { prompt in
            switch prompt.phase {
            case .awaitingLock(let until):
                if now > until {
                    closed = true
                    return true
                }
                awaitingLock = true
                return false
            case .hiddenByLock:
                return false
            case .awaitingReturn(let until):
                return now > until
            }
        }
        reminders.retainOpen(open + parked.map(\.id))
        return closed && !awaitingLock
    }

    package mutating func nextReminder(in prompts: [(window: Int, pid: pid_t)], activated pid: pid_t,
                                       now: TimeInterval) -> Int? {
        guard !locked else { return nil }
        return reminders.next(in: prompts, activated: pid, now: now)
    }
}
