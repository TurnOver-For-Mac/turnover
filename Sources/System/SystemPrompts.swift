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
    nonisolated static let agents = ["com.apple.LocalAuthentication.UIAgent", "com.apple.SecurityAgent", "com.apple.UserNotificationCenter",
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

    /// Return in a prompt presses the default button wherever the focus is, and TurnOver's own press of the button in
    /// hand is not to be had here: `keepsActionKey` gives the key back to macOS, which can refuse a press TurnOver
    /// makes (issue 352). So a plain Return on a button that is not the default goes to the prompt as Space, which
    /// presses the button the focus is on (26 Nov 2026: eleven times running, Return on Ignore in a crash dialog
    /// pressed Report… instead, and eleven problem reports were left waiting to be sent). The key tap rewrites the
    /// real key in place, so it stays the person's own key press.
    /// A prompt that does not say where its focus is gets no Return at all, with the edge sound: sent, it would press
    /// the default button, which may not be the one in hand. Pressed again within three seconds, the prompt is asked
    /// again, and if it still does not say, Return goes on as it is, so nobody is left unable to answer a prompt
    /// (a review, 26 Nov 2026).
    static func returnGoesOn(_ gesture: KeyboardGesture) -> KeyOnward {
        guard !gesture.isRepeat, gesture.modifiers.isEmpty, ["enter", "numpadEnter"].contains(gesture.keyName),
              !shared.handsToVoiceOver,
              let front = NSWorkspace.shared.frontmostApplication, let bundle = front.bundleIdentifier,
              agents.contains(bundle) else { return .asItIs }
        // The agent's own focus, not TurnOver's: TurnOver can still report its focus in the application behind.
        let look = lookAtFocus(pid: front.processIdentifier)
        let now = ProcessInfo.processInfo.systemUptime
        let justBefore = now - unansweredAt < 3
        if look.focus != .unanswered { unansweredAt = -.infinity }
        switch returnGoes(from: look.focus, unansweredJustBefore: justBefore) {
        case .asItIs:
            switch look.focus {
            case .unanswered:
                unansweredAt = -.infinity
                Log.io("system prompt: the prompt did not say where its focus is, twice running; Return goes on as it is")
            case .nothing:
                Log.io("system prompt: Return goes on as it is (nothing has the focus)")
            case .control(let role, let isDefault):
                Log.io("system prompt: Return goes on as it is (the focus is on \(isDefault == true ? "the default button" : role))")
            }
            return .asItIs
        case .nowhere:
            unansweredAt = now
            Log.io("system prompt: the prompt did not say where its focus is; Return is not sent, since it would press the default button whatever is in hand. Pressed again, the prompt is asked again")
            Tones.edge()
            return .nowhere
        case .asSpace:
            // The button's title is asked for the log once the key has gone on: asked now, it could keep the key waiting
            // (a second review, 26 Nov 2026).
            let button = look.element
            DispatchQueue.main.async {
                Log.io("system prompt: Return on \(Log.words(button?.string(kAXTitleAttribute) ?? "")), a button that is not the default, went on as Space, which presses it")
            }
            if let window = look.window {
                // For the log only: whether the prompt took it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    let r = window.role
                    Log.io("system prompt: a second after Return went on as Space the prompt \(r.isEmpty || r == "?" ? "has gone" : "is still open")")
                }
            }
            var flags = gesture.flags
            flags.remove(.maskNumericPad)   // numpad Enter carries the number pad's flag; Space is not on the pad
            return .asAnother(KeyboardGesture(keyCode: 49, modifiers: [], characters: " ", timestamp: gesture.timestamp, isRepeat: false, flags: flags))
        }
    }
    /// When a prompt last did not say where its focus is (the system's uptime).
    private static var unansweredAt: TimeInterval = -.infinity

    /// What one look at a prompt found where its keyboard focus is.
    nonisolated package enum PromptFocus: Equatable {
        /// A control, by its role, and for a button whether it is the window's default button (nil: the window names
        /// none, or did not say).
        case control(role: String, isDefault: Bool?)
        /// Nothing has the focus.
        case nothing
        /// The agent did not answer.
        case unanswered
    }
    nonisolated package enum ReturnGoes: Equatable { case asItIs, asSpace, nowhere }

    /// The rule alone (tests). `unansweredJustBefore`: the prompt did not answer the Return before this one either.
    nonisolated package static func returnGoes(from focus: PromptFocus, unansweredJustBefore: Bool) -> ReturnGoes {
        switch focus {
        case .control(let role, let isDefault): return returnGoesAsSpace(role: role, isDefault: isDefault) ? .asSpace : .asItIs
        case .nothing: return .asItIs
        case .unanswered: return unansweredJustBefore ? .asItIs : .nowhere
        }
    }

    /// Only from a plain button, and not from the one Return presses anyway. A window that does not say which button
    /// is its default (nil) counts as not that one: Space presses the button in hand either way. A text field keeps
    /// Return, and so do a checkbox and a pop-up button, where Space would do something else.
    nonisolated package static func returnGoesAsSpace(role: String, isDefault: Bool?) -> Bool {
        role == "AXButton" && isDefault != true
    }

    /// One press of Return presses one button: while a system prompt's agent is in front, the repeats of a plain Return
    /// or numpad Enter held down go nowhere (the key tap asks). Held, it pressed the default button of the prompt that
    /// came up behind the one just answered, and of each one after it (a review, 26 Nov 2026).
    nonisolated package static func dropsHeldReturn(keyCode: Int64, isRepeat: Bool, plain: Bool, frontBundle: String) -> Bool {
        isRepeat && plain && (keyCode == 36 || keyCode == 76) && agents.contains(frontBundle)
    }

    /// The longest each question to the prompt may take here. The keyboard thread waits 0.15 s for the whole answer
    /// (ScriptHandler.lookupLimit); a later answer costs the real key, and TurnOver then has to post one of its own.
    private static let lookLimit: Float = 0.1

    private struct Look {
        var focus: PromptFocus
        var element: AXUIElement?
        var window: AXUIElement?
    }

    private static func lookAtFocus(pid: pid_t) -> Look {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, lookLimit)
        let (found, error) = app.attrError(kAXFocusedUIElementAttribute)
        guard let found, CFGetTypeID(found) == AXUIElementGetTypeID() else {
            return Look(focus: answered(error) ? .nothing : .unanswered)
        }
        let focus = found as! AXUIElement
        // A limit set on one element covers that element alone: each one asked gets its own.
        AXUIElementSetMessagingTimeout(focus, lookLimit)
        let (roleValue, roleError) = focus.attrError(kAXRoleAttribute)
        guard let role = roleValue as? String else {
            return Look(focus: answered(roleError) ? .nothing : .unanswered, element: focus)
        }
        guard role == "AXButton" else { return Look(focus: .control(role: role, isDefault: nil), element: focus) }
        // Whether it is the default button. Not knowing counts as not: Space presses the button in hand either way.
        var isDefault: Bool?
        let window = focus.element(kAXWindowAttribute)
        if let window {
            AXUIElementSetMessagingTimeout(window, lookLimit)
            if let def = window.element(kAXDefaultButtonAttribute) { isDefault = CFEqual(def, focus) }
        }
        return Look(focus: .control(role: role, isDefault: isDefault), element: focus, window: window)
    }

    /// Whether the agent answered: "no value" and "not supported" are answers, there is nothing there.
    nonisolated private static func answered(_ error: AXError) -> Bool {
        error == .success || error == .noValue || error == .attributeUnsupported
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
        /// When it was last read aloud, or a reading was last tried: each prompt has its own two seconds in which it
        /// is not read again (a review, 26 Nov 2026: one clock for them all kept a prompt that had come to the front
        /// unread, because another had just been read).
        var announcedAt: Date?
        /// Its words have been said (false: listed without them, as one back after a lock behind another application).
        var wasRead = false
    }

    private var timer: Timer?
    private var shown: [OpenPrompt] = []
    private var continuity = SystemPromptContinuity()
    /// The prompt whose words were said last (its id): the one that has the keyboard is read whenever it is not this one.
    private var spokenLast: Int?
    /// How many looks running each agent has failed to say what windows it has.
    private var unansweredLooks: [pid_t: Int] = [:]

    /// A new prompt is read as soon as it is seen, unless its agent is in front and the keyboard is in another of the
    /// agent's windows: the person is answering that one, and this one is read when it gets the keyboard (a second
    /// review, 26 Nov 2026: three crash dialogs open at once were each read over the one before, and the next was not
    /// read when the one in hand was answered).
    nonisolated package static func readsNewPromptAtOnce(agentInFront: Bool, hasKeyboard: Bool) -> Bool {
        !agentInFront || hasKeyboard
    }

    /// The prompt that has the keyboard is read when its words were never said, or were not the last ones said (another
    /// prompt was read since, or it has just got the keyboard from one that was answered). Not within two seconds of
    /// the last time it was read or tried (`sinceLastTry`; nil: never).
    nonisolated package static func readsPromptWithKeyboard(wasRead: Bool, saidLast: Bool, sinceLastTry: TimeInterval?) -> Bool {
        (!wasRead || !saidLast) && (sinceLastTry.map { $0 >= 2 } ?? true)
    }

    /// How many looks running an agent may fail to say what windows it has before its prompts count as closed (three
    /// seconds): one that never answers again must not keep a prompt listed for good (a second review, 26 Nov 2026).
    nonisolated package static let unansweredLooksLimit = 6
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
        // An agent that does not answer has not closed its prompts: a question that timed out looked like every one of
        // them closing, and each was read again as new when the agent answered (a review, 26 Nov 2026).
        var unanswered = Set<pid_t>()
        for bundle in Self.agents {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundle) {
                let pid = app.processIdentifier
                AXHandler.shared.observe(pid)
                let ax = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(ax, 0.5)
                let (value, error) = ax.attrError(kAXWindowsAttribute)
                if let found = value as? [AXUIElement] { windows += found.map { ($0, pid) } }
                else if !Self.answered(error) { unanswered.insert(pid) }
            }
        }
        // But not for ever: after three seconds without an answer its prompts count as closed, as they did at once before.
        unansweredLooks = unansweredLooks.filter { unanswered.contains($0.key) }
        for pid in unanswered { unansweredLooks[pid, default: 0] += 1 }
        unanswered = unanswered.filter { (unansweredLooks[$0] ?? 0) < Self.unansweredLooksLimit }
        let now = ProcessInfo.processInfo.systemUptime
        updateScreenLock(now: now)
        let disappeared = shown.filter { p in !unanswered.contains(p.pid) && !windows.contains { $0.0.isSame(p.window) } }
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
        // Which of the front agent's windows the keys go to: asked once, and only when something turns on it.
        var asked = false, key: AXUIElement?
        func hasKeyboard(_ window: AXUIElement, _ pid: pid_t) -> Bool {
            guard front == pid, !unanswered.contains(pid) else { return false }
            if !asked { asked = true; key = keyWindow(of: pid, among: windows.filter { $0.1 == pid }.map { $0.0 }) }
            return key.map { $0.isSame(window) } ?? false
        }
        for (w, pid) in windows where !shown.contains(where: { $0.window.isSame(w) }) {
            show(w, pid: pid, now: now, hasKeyboard: hasKeyboard(w, pid), agentInFront: front == pid)
        }
        // The prompt that has the keyboard, when its words were never said or were not the last ones said: back after a
        // lock, listed behind another prompt, or just given the keyboard because the prompt in front of it was answered,
        // with no activation to say so. Read like any place the person lands in.
        if !handsToVoiceOver, let index = shown.firstIndex(where: { hasKeyboard($0.window, $0.pid) }) {
            let p = shown[index]
            if Self.readsPromptWithKeyboard(wasRead: p.wasRead, saidLast: spokenLast == p.id,
                                            sinceLastTry: p.announcedAt.map { Date().timeIntervalSince($0) }) {
                Log.io("system prompt from pid \(p.pid): it has the keyboard now and \(p.wasRead ? "its words were not the last said" : "was never read")")
                read(at: index)
            }
        }
    }

    /// The window of an agent that the keys go to while the agent is in front, of the windows it lists: the one its
    /// focus is in, else its focused window, else its first (UserNotificationCenter's prompts have a window but no
    /// focused window). Where the focus is says where the keys go, which the order of the windows does not.
    private func keyWindow(of pid: pid_t, among listed: [AXUIElement]) -> AXUIElement? {
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, 0.5)
        var candidates: [AXUIElement] = []
        if let focus = ax.element(kAXFocusedUIElementAttribute) {
            AXUIElementSetMessagingTimeout(focus, 0.5)
            if let w = focus.element(kAXWindowAttribute) { candidates.append(w) }
        }
        if let w = ax.element(kAXFocusedWindowAttribute) { candidates.append(w) }
        // Listing none (its windows not said), where its focus is, as before.
        return candidates.first { c in listed.contains { $0.isSame(c) } } ?? listed.first ?? candidates.first
    }

    /// `hasKeyboard`: the prompt's agent is the application in front and this is the window its keys go to. Another
    /// window of the same agent does not have it (a review, 26 Nov 2026).
    private func show(_ window: AXUIElement, pid: pid_t, now: TimeInterval, hasKeyboard: Bool, agentInFront: Bool) {
        let first = shown.isEmpty
        let voiceOver = handsToVoiceOver
        let text = voiceOver ? nil : readPrompt(window, pid: pid)
        let appearance = continuity.appear(pid: pid, lines: text?.matchingLines, now: now)
        var prompt = OpenPrompt(window: window, pid: pid, id: appearance.id, text: text)
        // The same prompt back after a lock keeps its reminder history, and behind another application it is not read
        // again or given the keyboard (25 Nov 2026: one crash dialog was read in full five times in a day, at each
        // unlock). With the keyboard it is read like any place the person lands in: silence there would leave them in
        // a dialog without knowing it (a review, 26 Nov 2026). Should it get the keyboard later, it is read then
        // (`check`, `announceFront`).
        if appearance.quietUntil != nil, !hasKeyboard {
            shown.append(prompt)
            Log.io("system prompt from pid \(pid): the same one back after a lock; not read again")
            return
        }
        if voiceOver {
            shown.append(prompt)
            // The prompt can open without the keyboard. Give it to VoiceOver and step aside.
            Log.io("system prompt from pid \(pid): VoiceOver's")
            if first { onPromptChange?(true) }
            if let f = AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute) { giveKeyboard(to: f) }
        } else if !Self.readsNewPromptAtOnce(agentInFront: agentInFront, hasKeyboard: hasKeyboard) {
            // The person is in another of this agent's prompts. Read over it, this one's words were heard with that
            // one's button in hand, and it was not read again when its turn came.
            shown.append(prompt)
            Log.io("system prompt from pid \(pid): behind the one the keyboard is in; read when it gets the keyboard")
        } else {
            prompt.announcedAt = Date()
            prompt.wasRead = text != nil
            shown.append(prompt)
            announce(text, window: window, pid: pid, id: prompt.id)
        }
    }

    /// The agent came to the front: read its window now (the regular look comes every half second, after the focus
    /// had already been read).
    func announceFront(pid: pid_t) {
        let now = ProcessInfo.processInfo.systemUptime
        updateScreenLock(now: now)
        guard !continuity.locked, !handsToVoiceOver else { return }
        let agentApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(agentApp, 0.5)
        guard let w = keyWindow(of: pid, among: agentApp.elements(kAXWindowsAttribute)) else { return }
        // In front, a prompt is always read, one that came back after a lock too: the keys go to it now. (The tone is
        // played by the caller, for every agent that comes to the front.)
        guard let index = shown.firstIndex(where: { $0.window.isSame(w) }) else {
            show(w, pid: pid, now: now, hasKeyboard: true, agentInFront: true)
            return
        }
        // Not twice in two seconds, each prompt by its own clock.
        if let at = shown[index].announcedAt, Date().timeIntervalSince(at) < 2 { return }
        read(at: index)
    }

    /// Reads a prompt already listed, with its words as they are now. A reading that fails says nothing again, and
    /// leaves the reminder its last known summary; but a prompt never said is said from the words it was listed with.
    private func read(at index: Int) {
        var prompt = shown.remove(at: index)
        let fresh = readPrompt(prompt.window, pid: prompt.pid)
        if let fresh { prompt.text = fresh }
        prompt.announcedAt = Date()
        let say = fresh ?? (prompt.wasRead ? nil : prompt.text)
        if say != nil { prompt.wasRead = true }
        shown.append(prompt)
        if let say { announce(say, window: prompt.window, pid: prompt.pid, id: prompt.id) }
    }

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

    private func announce(_ text: PromptText?, window: AXUIElement, pid: pid_t, id: Int) {
        guard let texts = text?.lines else { return }
        Log.io("system prompt from pid \(pid): \(texts.count) lines")
        Speech.cancel()
        Speech.speakMessage(([Self.isProtected(pid) ? String(localized: "system dialog", comment: "A role: a macOS system dialog") : Role.dialog.displayString] + texts).joined(separator: ", "))
        spokenLast = id
        let ax = AXUIElementCreateApplication(pid)
        if let f = ax.element(kAXFocusedUIElementAttribute) {
            // Into the prompt just read, never into another: with two of an agent's prompts open the focus can be in the
            // other one, and its button was read after this one's words as if it were this one's (a review, 26 Nov 2026).
            let home = f.element(kAXWindowAttribute)
            if let home, !home.isSame(window), shown.contains(where: { $0.window.isSame(home) }) {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                    // The person is in that other prompt.
                    Log.io("system prompt from pid \(pid): the focus is in another of its prompts; the keyboard stays there")
                } else if let own = window.element(kAXDefaultButtonAttribute) ?? window.element(kAXCancelButtonAttribute) {
                    // The agent is behind another application: a new prompt brings it forward, as it always did, into
                    // the prompt just read, on its default button as when a prompt opens (a second review, 26 Nov
                    // 2026: the person was left in the application, having heard a dialog).
                    giveKeyboard(to: own)
                    AXHandler.shared.focusChanged(own, pid: pid)
                } else {
                    // This prompt names no control of its own: the agent comes forward where its focus is, and the
                    // regular look reads the prompt the keyboard is then in.
                    giveKeyboard(to: f)
                }
            } else {
                giveKeyboard(to: f)
                AXHandler.shared.focusChanged(f, pid: pid)
            }
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
