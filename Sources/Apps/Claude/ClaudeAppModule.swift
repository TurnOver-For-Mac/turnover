// SPDX-License-Identifier: GPL-3.0-or-later
// The Claude desktop app: replies are read when they finish (NVDA users get
// nothing from the web app by default), and a message reached with the app's own
// Up and Down keys is read as its text, not as "Message 106, article".
// Browse mode covers the rest (arrows, H between "You said" and "Claude
// responded"). See ClaudeTranscript for the measured structure.
import Foundation
import ApplicationServices

final class ClaudeAppModule: AppModule {
    private var watching = false
    private var readReplies: Bool { config.appSetting(ClaudeTranscript.bundleID, "readReplies", default: "on") == "on" }

    required init(pid: pid_t, bundleIdentifier: String, appName: String) {
        super.init(pid: pid, bundleIdentifier: bundleIdentifier, appName: appName)
        script("claude_readLatest", String(localized: "Reads Claude's latest reply", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+shift+r"], category: "Claude") { [weak self] _ in
            guard let self, let chat = ClaudeTranscript.chat(pid: self.pid) else { Speech.speakMessage(String(localized: "no conversation", comment: "Spoken message")); return }
            let reply = ClaudeTranscript.latestReply(chat: chat)
            Speech.speakText(reply.isEmpty ? String(localized: "no reply yet", comment: "Spoken message") : reply)
        }
    }

    override func menuItems() -> [MenuItem] {
        [MenuItem("Read replies when they finish", .toggle(
            get: { [weak self] in self?.readReplies ?? true },
            set: { config.setAppSetting(ClaudeTranscript.bundleID, "readReplies", $0 ? "on" : "off") }))]
    }

    override func handleEvent(_ event: Event, next: () -> Void) {
        switch event.kind {
        case .gainFocus where event.obj.element.string(kAXRoleDescriptionAttribute) == "article":
            // A message: its text, with "You said" or "Claude responded" from its hidden heading.
            let t = ClaudeTranscript.text(of: event.obj.element, skipHidden: false)
            if !t.isEmpty { Speech.speakNews(String(t.prefix(4000))); return }
            next()
        case .liveRegionChange:
            // Claude's own status counters ("History 518/518", "Running", "Running agent") are noise, not news (the code review, 17 Oct 2026).
            let t = (event.obj.value ?? event.obj.name).trimmingCharacters(in: .whitespacesAndNewlines)
            if t.range(of: #"^(History \d+/\d+|Running( agent)?|Working…?)$"#, options: .regularExpression) != nil { Log.io("Claude: status \"\(t)\" not said"); startWatching(); return }
            // A progress line while keys are being pressed waits (holdProgress).
            if Date().timeIntervalSince(InputManager.lastKeyDownAt) < Self.quietForProgress, event.obj.element.string("AXARIALive") != "assertive" {
                holdProgress(event.obj.element)
                startWatching()
                return
            }
            next()
            startWatching()
        case .valueChange where event.obj.role == .editableText && event.obj.name == "Prompt":
            // The prompt emptied: a message was sent. Look for the reply starting shortly.
            next()
            if (event.obj.value ?? "").isEmpty {
                sentAt = Date()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.startWatching() }
            }
        default:
            next()
        }
    }

    /// When the prompt last emptied: a message was sent.
    private var sentAt = Date.distantPast
    /// The conversation a watch is for, by its page's title ("Monster Racer debugging - Claude Code").
    private var watchedSession = ""

    /// While a reply streams, look once a second; when it stops, read it.
    private func startWatching() {
        guard !watching, readReplies, let chat = ClaudeTranscript.chat(pid: pid), ClaudeTranscript.isResponding(chat: chat) else { return }
        watching = true
        watchedSession = ClaudeTranscript.session(of: chat)
        Log.io("claude: a reply is streaming")
        tick(chat: chat, quietTicks: 0)
    }

    /// How long the keys must have been quiet before a held progress line is said.
    static let quietForProgress: TimeInterval = 1.5
    /// The live region whose newest line waits for the keys to be quiet.
    private var heldProgress: AXUIElement?

    /// Claude's progress lines ("Running a command", "Ran 2 commands") wait while keys are being pressed. Said straight
    /// after a line Oliver had just moved to, they sounded like part of it, and he went back to read the line again:
    /// ten in 38 s, three lines read twice (14 Nov 2026); eight more fell between the words he typed. The newest line
    /// is said once the keys have been quiet for a moment; older ones are out of date by then, and are not said.
    private func holdProgress(_ region: AXUIElement) {
        let first = heldProgress == nil
        heldProgress = region
        if first { Log.io("claude: a progress line waits while keys are pressed") }
        if first { releaseProgressWhenQuiet() }
    }

    private func releaseProgressWhenQuiet() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let region = heldProgress else { return }
            // Left the app: the line is not said over another app.
            guard AXHandler.shared.activePid == pid else { heldProgress = nil; return }
            guard Date().timeIntervalSince(InputManager.lastKeyDownAt) >= Self.quietForProgress else { releaseProgressWhenQuiet(); return }
            heldProgress = nil
            guard config.presentation.reportDynamicContentChanges else { return }
            let t = ClaudeTranscript.text(of: region, skipHidden: false)
            guard !t.isEmpty else { return }
            LiveRegions.speak(t, from: region, assertive: false)
        }
    }

    private func tick(chat: AXUIElement, quietTicks: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            guard AXHandler.shared.activePid == self.pid else { self.watching = false; return }   // left the app: say nothing
            let live = (chat.role == "?" ? ClaudeTranscript.chat(pid: self.pid) : chat) ?? chat
            // Another conversation now (Command 2 or 3): its last reply is not this watch's. Read from its start after a
            // switch, it was an old reply, twice on 13 Nov 2026.
            if !self.watchedSession.isEmpty, ClaudeTranscript.session(of: live) != self.watchedSession {
                self.watching = false
                Log.io("claude: another conversation is open now; its reply is not read")
                return
            }
            if ClaudeTranscript.isResponding(chat: live) { self.tick(chat: live, quietTicks: 0); return }
            // Just after a message was sent, Claude may not show yet that it is answering: what came before was taken for
            // the finished reply, and its plan was read out 1.5 to 1.9 s after the message went (four times, 13 Nov 2026).
            if Date().timeIntervalSince(self.sentAt) < 6 { self.tick(chat: live, quietTicks: 0); return }
            // Two quiet looks in a row, so a pause between tool calls is not the end.
            if quietTicks < 1 { self.tick(chat: live, quietTicks: quietTicks + 1); return }
            self.watching = false
            let reply = ClaudeTranscript.latestReply(chat: live)
            Log.io("claude: reply finished, \(reply.count) characters")
            guard !reply.isEmpty else { return }
            // Oliver already reading it (the reading position moved in the last 3 s): not read again from its top over
            // him (twice on 14 Nov 2026). Claude's own "finished" notice still says it is done.
            if let page = API.focusTreeInterceptor, Date().timeIntervalSince(page.positionMovedAt) < 3 {
                Log.io("claude: the reply is being read already; not read from its start")
                return
            }
            Speech.speakNews(reply)
        }
    }
}
