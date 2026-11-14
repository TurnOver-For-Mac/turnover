// SPDX-License-Identifier: GPL-3.0-or-later
// The Claude desktop app: replies are read when they finish (NVDA users get
// nothing from the web app by default), and a message reached with the app's own
// Up and Down keys is read as its text, not as "Message 106, article".
// Browse mode covers the rest (arrows, H between "You said" and "Claude
// responded"). See ClaudeTranscript for the measured structure.
import Foundation
import ApplicationServices
import TurnOverAX

/// Claude's nonassertive progress must not cut off a line still being read.
public enum ClaudeProgressReadiness {
    public enum Decision: Equatable { case wait, release, expired }
    public static let quietInterval: TimeInterval = 1.5
    public static let maximumHold: TimeInterval = 60

    public static func decision(keyQuietFor: TimeInterval, speechBusy: Bool, heldFor: TimeInterval) -> Decision {
        let holdExpired = heldFor >= maximumHold
        if holdExpired { return .expired }
        let keysAreQuiet = keyQuietFor >= quietInterval
        guard keysAreQuiet else { return .wait }
        guard !speechBusy else { return .wait }
        return .release
    }
}

package final class ClaudeAppModule: AppModule {
    private var watching = false
    private var readReplies: Bool { config.appSetting(ClaudeTranscript.bundleID, "readReplies", default: "on") == "on" }

    package required init(pid: pid_t, bundleIdentifier: String, appName: String) {
        super.init(pid: pid, bundleIdentifier: bundleIdentifier, appName: appName)
        WebBuffer.statusEchoApps.insert(ClaudeTranscript.bundleID)   // its tool rows' status repeats the row's button
        script("claude_switchConversation", String(localized: "Switches to a recent or new Claude conversation", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+1", "kb:command+2", "kb:command+3", "kb:command+4", "kb:command+n"], category: "Claude") { [weak self] gesture in
            self?.prepareConversationSwitch()
            gesture.send()
        }
        script("claude_readLatest", String(localized: "Reads Claude's latest reply", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+shift+r"], category: "Claude") { [weak self] _ in
            guard let self, let chat = ClaudeTranscript.chat(pid: self.pid) else { Speech.speakMessage(String(localized: "no conversation", comment: "Spoken message")); return }
            let reply = ClaudeTranscript.latestReply(chat: chat)
            Speech.speakText(reply.isEmpty ? String(localized: "no reply yet", comment: "Spoken message") : reply)
        }
    }

    private var conversationSwitch = 0
    private weak var conversationPage: BrowseModeDocument?
    private let conversationReader = AXWalkRunner<AXSnapshot>()
    /// The production reader is replaceable so a held provider can be tested without opening Claude.
    package var conversationRead: @Sendable (AXUIElement) -> AXSnapshot = ClaudeAppModule.readConversation
    package var conversationWaitLimit: TimeInterval = 8

    nonisolated private static func readConversation(_ root: AXUIElement) -> AXSnapshot {
        // 14 Nov 2026 review: timer callbacks still queried Claude on main. Every provider read now runs
        // on the AX worker, with a timeout on this exact reference, and returns only captured values.
        AXUIElementSetMessagingTimeout(root, 0.05)
        let names = ["AXURL", kAXTitleAttribute, kAXRoleAttribute, "AXElementBusy"]
        let values = root.attrs(names).compactMapValues { AXSnapshotValue($0) }
        return AXSnapshot(nodes: [ElementKey(root): .init(attributes: values)])
    }

    /// Claude's native conversation keys hold page commands until a reply identifies the page. An unchanged,
    /// non-busy address releases immediately, keeping its copy and reading position (review, 14 Nov 2026).
    package func prepareConversationSwitch() {
        guard let page = API.focusTreeInterceptor,
              page.webArea.pid == pid else { return }
        if let previous = conversationPage,
           previous !== page { previous.finishNavigationWait(title: nil, announce: false) }
        conversationPage = page
        conversationSwitch += 1
        conversationReader.cancel()
        let request = conversationSwitch
        let root = page.webArea
        let address = page.lastURL
        let title = page.buffer.withSnapshot { root.string(kAXTitleAttribute) ?? "" }
        var titleAnnounced = false
        var releasedContent = false
        page.beginNavigationWait()

        func finish() {
            conversationSwitch += 1
            conversationReader.cancel()
            page.finishNavigationWait(title: nil, announce: false)
        }
        // Independent of the provider: even a call that fails to respect its timeout cannot hold a key.
        DispatchQueue.main.asyncAfter(deadline: .now() + conversationWaitLimit) { [weak self, weak page] in
            guard let self,
                  let page,
                  conversationSwitch == request else { return }
            Log.io("claude: conversation switch wait ended at its ceiling; waiting commands run once")
            conversationSwitch += 1
            conversationReader.cancel()
            page.finishNavigationWait(title: nil, announce: false)
        }
        func look() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak page] in
                guard let self,
                      let page,
                      conversationSwitch == request else { return }
                guard API.focusTreeInterceptor === page else { finish(); return }
                let read = conversationRead
                conversationReader.submit(collect: { _ in read(root) }, publish: { [weak self, weak page] snapshot in
                    guard let self,
                          let page,
                          conversationSwitch == request else { return }
                    guard API.focusTreeInterceptor === page else { finish(); return }
                    let now = snapshot.with { page.url }
                    guard !now.isEmpty else { look(); return }
                    let changed = now != address
                    let busy = snapshot.with { root.attr("AXElementBusy") as? Bool == true }
                    if !changed,
                       !busy {
                        // Keep watching for a delayed address change, but the answered, unchanged page is usable now.
                        page.finishNavigationWait(title: nil, announce: false)
                        releasedContent = true
                        look()
                        return
                    }
                    if changed {
                        if releasedContent,
                           page.lastURL != now {
                            page.beginNavigationWait()
                            releasedContent = false
                        }
                        // refreshIfNavigated also asks for URL/role. The captured scope prevents any live main read.
                        _ = snapshot.with { page.refreshIfNavigated() }
                    }
                    let name = snapshot.with { (root.string(kAXTitleAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
                    let titleIsReady = !name.isEmpty && name != title
                    if changed,
                       titleIsReady,
                       !titleAnnounced {
                        titleAnnounced = true
                        page.announceNavigationTitle(name)
                    }
                    let copyIsReady = !page.buffer.isLoading && !page.buffer.lines.isEmpty
                    if changed,
                       copyIsReady,
                       !releasedContent {
                        releasedContent = true
                        page.finishNavigationWait(title: nil)
                    }
                    if titleAnnounced,
                       releasedContent { finish(); return }
                    look()
                })
            }
        }
        look()
    }

    package override func menuItems() -> [MenuItem] {
        [MenuItem("Read replies when they finish", .toggle(
            get: { [weak self] in self?.readReplies ?? true },
            set: { config.setAppSetting(ClaudeTranscript.bundleID, "readReplies", $0 ? "on" : "off") }))]
    }

    package override func handleEvent(_ event: Event, next: () -> Void) {
        if event.kind == .gainFocus,
           API.focusTreeInterceptor?.navigationWaiting == true { return }
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
            // Assertive notices retain their immediate delivery.
            let isAssertive = event.obj.element.string("AXARIALive") == "assertive"
            let progressReadiness = ClaudeProgressReadiness.decision(
                keyQuietFor: Date().timeIntervalSince(InputManager.lastKeyDownAt),
                speechBusy: Speech.player?.isBusy ?? false,
                heldFor: 0)
            if !isAssertive,
               progressReadiness == .wait {
                holdProgress(event.obj.element)
                startWatching()
                return
            }
            heldProgress = nil   // a newer line is said now: the one waiting is out of date
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

    /// The live region whose newest line waits for quiet keys and idle speech.
    private var heldProgress: AXUIElement?
    /// First hold time survives newer progress lines so a busy reader cannot keep this pending forever.
    private var heldProgressSince = Date.distantPast

    /// Claude's progress lines ("Running a command", "Ran 2 commands") wait while keys are being pressed. Said straight
    /// after a line Oliver had just moved to, they sounded like part of it, and he went back to read the line again:
    /// ten in 38 s, three lines read twice (14 Nov 2026); eight more fell between the words he typed. The newest line
    /// waits for both quiet keys and idle speech; older lines are out of date by then, and are not said.
    /// 14 Nov 2026: the trial log showed held progress released after 1.5 seconds of key quiet while a long
    /// line was still being read. SpeechPlayer's locked isBusy includes queued speech, not just current audio.
    /// Reuse the finished-reply minute ceiling: drop progress rather than interrupt reading or retry forever.
    /// The conversation open now, by its page's address, from the page browse mode already has: asked once, not by a
    /// search of the window (a search of up to 3,000 elements on the main thread, every second; Codex's third review).
    private func currentConversation() -> String {
        guard let page = API.focusTreeInterceptor, page.webArea.pid == pid else { return "" }
        return page.url
    }

    /// The conversation the waiting line belongs to (a line from another one, after a switch, is not said).
    private var heldProgressSession = ""

    private func holdProgress(_ region: AXUIElement) {
        let first = heldProgress == nil
        heldProgress = region
        heldProgressSession = currentConversation()
        if first {
            heldProgressSince = Date()
            Log.io("claude: a progress line waits for quiet keys and idle speech")
        }
        if first { releaseProgressWhenQuiet() }
    }

    private func releaseProgressWhenQuiet() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let region = heldProgress else { return }
            // Left the app: the line is not said over another app.
            guard AXHandler.shared.activePid == pid else { heldProgress = nil; return }
            let readiness = ClaudeProgressReadiness.decision(
                keyQuietFor: Date().timeIntervalSince(InputManager.lastKeyDownAt),
                speechBusy: Speech.player?.isBusy ?? false,
                heldFor: Date().timeIntervalSince(heldProgressSince))
            switch readiness {
            case .wait:
                releaseProgressWhenQuiet()
                return
            case .expired:
                heldProgress = nil
                Log.io("claude: progress waited a minute; the waiting line is dropped")
                return
            case .release:
                heldProgress = nil
            }
            // Another conversation now: its line is not this one's.
            let session = currentConversation()
            guard session == heldProgressSession else { Log.io("claude: another conversation now; the waiting line is dropped"); return }
            guard config.presentation.reportDynamicContentChanges else { return }
            let t = ClaudeTranscript.text(of: region, skipHidden: false)
            guard !t.isEmpty else { return }
            LiveRegions.speak(t, from: region, assertive: false)
        }
    }

    /// A finished reply, read unless Oliver is reading it already. The reading position on a line of the reply itself
    /// is reading it: it is not read again from its top over him (twice on 14 Nov 2026). Moving about elsewhere is
    /// not: the reply waits until the reading has been still for two seconds, then it is read (Codex's review: it was
    /// dropped for good). Claude's own "finished" notice still says it is done either way.
    /// Only in its own conversation (`session`, its address): after a switch it is not said (Codex's second review).
    private func sayReply(_ reply: String, session: String, tries: Int) {
        if !session.isEmpty {
            let now = currentConversation()
            guard now == session else { Log.io("claude: another conversation now; the finished reply is not read"); return }
        }
        guard let page = API.focusTreeInterceptor, page.webArea.pid == pid,
              Date().timeIntervalSince(page.positionMovedAt) < 2 else { Speech.speakNews(reply); return }
        let line = page.lineText(at: page.position).trimmingCharacters(in: .whitespacesAndNewlines)
        // A line of some length, so a short line found in many replies ("Done.") is not taken for this one.
        if line.count >= 24, reply.contains(line) {
            Log.io("claude: the reply is being read already; not read from its start")
            return
        }
        guard tries < 60 else { Log.io("claude: the reading did not settle for a minute; the finished reply is not read"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, AXHandler.shared.activePid == pid else { return }
            sayReply(reply, session: session, tries: tries + 1)
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
            self.heldProgress = nil   // the reply is done, whatever it holds: a waiting "Running…" is out of date
            let reply = ClaudeTranscript.latestReply(chat: live)
            Log.io("claude: reply finished, \(reply.count) characters")
            guard !reply.isEmpty else { return }
            self.sayReply(reply, session: ClaudeTranscript.session(of: live), tries: 0)
        }
    }
}
