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
    public enum Decision: Equatable { case wait, release }
    public static let quietInterval: TimeInterval = 1.5
    public static let maximumHold: TimeInterval = 60

    public static func decision(keyQuietFor: TimeInterval, speechBusy: Bool) -> Decision {
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
        script("claude_switchConversation", String(localized: "Switches to a recent or new Claude conversation", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+1", "kb:command+2", "kb:command+3", "kb:command+4", "kb:command+5", "kb:command+6", "kb:command+7", "kb:command+8", "kb:command+9", "kb:command+n"], category: "Claude") { [weak self] gesture in
            self?.prepareConversationSwitch(gesture)
            gesture.send()
        }
        // 14 Nov 2026: focused session menu items exposed no AXPress/AXConfirm; VO-Space
        // only refocused them. Native Return opened the confirmation dialog in the same log.
        script("vo_defaultAction", String(localized: "Activates Claude's focused menu item", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+space"], category: "Claude") { [weak self] _ in
            guard self?.canActivateFocusedMenuItem == true else { return }
            KeyboardGesture(identifier: "kb:enter")?.send()
        }.isAvailable = { [weak self] in self?.canActivateFocusedMenuItem == true }
        script("claude_readLatest", String(localized: "Reads Claude's latest reply", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+shift+r"], category: "Claude") { [weak self] _ in
            guard let self, let chat = ClaudeTranscript.chat(pid: self.pid) else { Speech.speakMessage(String(localized: "no conversation", comment: "Spoken message")); return }
            let reply = ClaudeTranscript.latestReply(chat: chat)
            Speech.speakText(reply.isEmpty ? String(localized: "no reply yet", comment: "Spoken message") : reply)
        }
    }

    private var canActivateFocusedMenuItem: Bool {
        guard API.focusPid == pid,
              API.focusObject?.element.role == "AXMenuItem",
              API.focusTreeInterceptor?.passThrough != false else { return false }
        if let review = ObjectNavigator.shared.reviewElement {
            return API.focusObject?.element.isSame(review) == true
        }
        return true
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

    /// Only the destination owns switch speech. An unchanged poll can release queued keys after the
    /// existing settle, but cannot establish that the shortcut chose the already-open conversation.
    package func prepareConversationSwitch(_ gesture: KeyboardGesture) {
        guard let page = API.focusTreeInterceptor,
              page.webArea.pid == pid else { return }
        if let previous = conversationPage,
           previous !== page {
            previous.navigationTitleOwned = false
            previous.finishNavigationWait(title: nil, announce: false)
        }
        conversationPage = page
        conversationSwitch += 1
        conversationReader.cancel()
        let request = conversationSwitch
        let root = page.webArea
        let address = page.lastURL
        let title = page.buffer.withSnapshot { Self.switchTitle(root.string(kAXTitleAttribute) ?? "") }
        let number = Int(gesture.identifier.components(separatedBy: "+").last ?? "")
        let target = page.buffer.withSnapshot { () -> SwitchTarget in
            guard page.url == address, !address.isEmpty else { return .unknown }
            return Self.switchTarget(number: number, root: root, title: title)
        }
        // Resolve a verified no-op before beginning the wait: beginNavigationWait changes mode, which
        // would add a sound to a missing shortcut and disturb the already-open conversation's position.
        if target == .missing || target == .current {
            page.navigationTitleOwned = false
            page.finishNavigationWait(title: nil, announce: false)
            if target == .missing, let number {
                Speech.speakMessage(String(localized: "no conversation \(number)", comment: "Spoken when Claude has no conversation at this shortcut number"))
            } else {
                page.announceNavigationTitle(title)
            }
            return
        }
        var titleAnnounced = false
        var ceilingReached = false
        var releasedContent = false
        var unchangedAnswers = 0
        var observedAddressChange = false
        let settleUntil = ProcessInfo.processInfo.systemUptime + 0.25
        page.navigationTitleOwned = true
        page.beginNavigationWait()

        func releaseContent() {
            page.announcedURL = page.lastURL
            page.announceWhenReady = false
            page.finishNavigationWait(title: nil, announce: false)
        }
        func finish() {
            guard conversationSwitch == request else { return }
            conversationSwitch += 1
            conversationReader.cancel()
            page.navigationTitleOwned = false
            releaseContent()
        }
        // The deadline releases keys independently of the provider. Its announcement comes from a NEW
        // worker read, never the captured pre-key title or an in-flight answer from before the deadline.
        DispatchQueue.main.asyncAfter(deadline: .now() + conversationWaitLimit) { [weak self, weak page] in
            guard let self,
                  let page,
                  conversationSwitch == request else { return }
            ceilingReached = true
            Log.io("claude: conversation switch ceiling; addressChanged=\(observedAddressChange), titleAnnounced=\(titleAnnounced)")
            conversationReader.cancel()
            releaseContent()
            guard conversationSwitch == request else { return }
            guard API.focusTreeInterceptor === page,
                  AXHandler.shared.activePid == pid,
                  !titleAnnounced else { finish(); return }
            // A timed-out provider may also block this serial lane. The final read gets a bounded
            // grace period; it must never leave automatic page speech owned by a dead switch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, conversationSwitch == request else { return }
                Log.io("claude: no current title reply at switch ceiling")
                finish()
            }
            let read = conversationRead
            conversationReader.submit(collect: { _ in read(root) }, publish: { [weak self, weak page] snapshot in
                guard let self,
                      let page,
                      conversationSwitch == request else { return }
                if API.focusTreeInterceptor === page,
                   AXHandler.shared.activePid == pid {
                    let name = snapshot.with { Self.switchTitle(root.string(kAXTitleAttribute) ?? "") }
                    if !name.isEmpty { page.announceNavigationTitle(name) }
                }
                finish()
            })
        }
        func look() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak page] in
                guard let self,
                      let page,
                      conversationSwitch == request,
                      !ceilingReached else { return }
                guard API.focusTreeInterceptor === page,
                      AXHandler.shared.activePid == pid else { finish(); return }
                let read = conversationRead
                conversationReader.submit(collect: { _ in read(root) }, publish: { [weak self, weak page] snapshot in
                    guard let self,
                          let page,
                          conversationSwitch == request,
                          !ceilingReached else { return }
                    guard API.focusTreeInterceptor === page,
                          AXHandler.shared.activePid == pid else { finish(); return }
                    let now = snapshot.with { page.url }
                    let changed = !now.isEmpty && now != address
                    let busy = snapshot.with { root.attr("AXElementBusy") as? Bool == true }
                    let name = snapshot.with { Self.switchTitle(root.string(kAXTitleAttribute) ?? "") }
                    let titleIsReady = !busy && !name.isEmpty && name != title
                    if changed {
                        observedAddressChange = true
                        if releasedContent,
                           page.lastURL != now {
                            page.beginNavigationWait()
                            releasedContent = false
                        }
                        // The scope covers URL/role reads too; no provider query is made on main.
                        _ = snapshot.with { page.refreshIfNavigated() }
                    }
                    // Claude can change AXTitle while keeping AXURL (or temporarily omitting it).
                    // Do not gate that evidence on a changed address, or speak a pre-switch title.
                    if titleIsReady,
                       !titleAnnounced {
                        titleAnnounced = true
                        page.announceNavigationTitle(name)
                    }
                    if !changed,
                       !observedAddressChange {
                        unchangedAnswers = busy ? 0 : unchangedAnswers + 1
                        if unchangedAnswers >= 3,
                           ProcessInfo.processInfo.systemUptime >= settleUntil,
                           !releasedContent {
                            releaseContent()
                            releasedContent = true
                        }
                    } else if !page.buffer.isLoading,
                              !page.buffer.lines.isEmpty,
                              !releasedContent {
                        releasedContent = true
                        // A switch says just its title, not the page's first "Claude Code" line as well.
                        releaseContent()
                    }
                    if titleAnnounced,
                       releasedContent,
                       observedAddressChange { finish(); return }
                    look()
                })
            }
        }
        look()
    }

    private enum SwitchTarget { case current, other, missing, unknown }

    /// Claude 5.1231.2, macOS 27.2, 14 Nov 2026: the complementary sidebar's Recents section has
    /// a heading group followed by session groups, each with a title button and a popup menu. Use
    /// only the captured tree; an absent, collapsed, clipped or unfamiliar section proves nothing.
    private static func switchTarget(number: Int?, root: AXUIElement, title: String) -> SwitchTarget {
        guard let number, (1...9).contains(number) else { return .unknown }
        var remaining = 512
        var complete = true
        var seen: Set<ElementKey> = []
        func descendants(_ element: AXUIElement) -> [AXUIElement] {
            var result: [AXUIElement] = []
            func walk(_ node: AXUIElement) {
                guard remaining > 0,
                      AXSnapshot.holds(node),
                      seen.insert(ElementKey(node)).inserted else { complete = false; return }
                remaining -= 1
                result.append(node)
                for child in node.elements(kAXChildrenAttribute) { walk(child) }
            }
            walk(element)
            return result
        }
        // Find the sidebar without traversing the transcript, then work only inside that landmark.
        var pending = [root]
        var sidebar: AXUIElement?
        var searched: Set<ElementKey> = []
        while let node = pending.popLast(), searched.count < 256 {
            guard AXSnapshot.holds(node), searched.insert(ElementKey(node)).inserted else { continue }
            if node.string(kAXSubroleAttribute) == "AXLandmarkComplementary" {
                sidebar = node
                break
            }
            pending.append(contentsOf: node.elements(kAXChildrenAttribute).reversed())
        }
        guard let sidebar else { return .unknown }
        let nodes = descendants(sidebar)
        guard complete else { return .unknown }
        func label(_ node: AXUIElement) -> String {
            for attribute in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
                if let text = node.string(attribute), !text.isEmpty { return text }
            }
            return ""
        }
        func subtree(_ node: AXUIElement) -> [AXUIElement] {
            // Already validated and bounded above. Fresh local visited sets also reject malformed cycles.
            var result: [AXUIElement] = [], queue = [node]
            var visited: Set<ElementKey> = []
            while let next = queue.popLast(), visited.insert(ElementKey(next)).inserted {
                result.append(next)
                queue.append(contentsOf: next.elements(kAXChildrenAttribute).reversed())
            }
            return result
        }
        for section in nodes where section.role == "AXGroup" {
            let children = section.elements(kAXChildrenAttribute)
            guard let header = children.first else { continue }
            let headerNodes = subtree(header)
            let headings = headerNodes.filter { $0.role == "AXHeading" }
            let headerButtons = headerNodes.filter { $0.role == "AXButton" }
            // The actual header has one heading/button. An outer wrapper containing all of Recents
            // also contains its session buttons, and must not be mistaken for the row container.
            guard headings.count == 1,
                  headerButtons.count == 1,
                  subtree(headings[0]).contains(where: { label($0) == "Recents" }) else { continue }
            if headerNodes.contains(where: { ($0.attr("AXExpanded") as? Bool) == false }) { return .unknown }
            var titles: [String] = []
            for row in children.dropFirst() {
                let rowNodes = subtree(row)
                let buttons = rowNodes.filter { $0.role == "AXButton" }
                guard buttons.count == 1,
                      rowNodes.contains(where: { $0.role == "AXPopUpButton" }),
                      let text = subtree(buttons[0]).first(where: { $0.role == "AXStaticText" }),
                      !label(text).isEmpty else { return .unknown }
                titles.append(label(text))
            }
            // With no rows, require explicit expansion rather than guessing about a collapsed list.
            if titles.isEmpty {
                return headerNodes.contains(where: { ($0.attr("AXExpanded") as? Bool) == true }) ? .missing : .unknown
            }
            if number > titles.count { return .missing }
            let target = switchTitle(titles[number - 1])
            if target == title,
               titles.filter({ switchTitle($0) == title }).count == 1 { return .current }
            return .other
        }
        return .unknown
    }

    private static func switchTitle(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: #"(?:\s+- Claude Code)+(?:\s+Claude Code)*$"#,
                                 with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    package override func menuItems() -> [MenuItem] {
        [MenuItem("Read replies when they finish", .toggle(
            get: { [weak self] in self?.readReplies ?? true },
            set: { config.setAppSetting(ClaudeTranscript.bundleID, "readReplies", $0 ? "on" : "off") }))]
    }

    /// Buttons are pressed by the keyboard. Accessibility's press reported success and did nothing on the answer
    /// buttons under a reply ("Post all five" twice and "Yes, approve them" eight times, 11 Nov 2026, Claude
    /// 5.1231.2, macOS 27.2) and on the sidebar's session rows (8 and 9 Nov 2026). Return on the same button, once
    /// Tab had put the keyboard on it, worked at once each time. Other presses of the same kind of button went
    /// through the same day ("Yes, add it"), so the press is ignored some of the time; why is not known.
    // The session menu's AXPress likewise reported success without an observable effect on
    // 14 Nov 2026; native Return opened its dialog. Use one confirmed key, with no action retry.
    package override var rolesPressedByKeyboard: Set<String> { ["AXButton", "AXMenuItem"] }

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
            // 14 Nov 2026 review: locate the session structurally before reading descendants.
            // Ordinary assertive events reach the object's handler with no preliminary text walk.
            let isSidebarStatus = [". Running", ". Awaiting input", ". Unread response"].contains { suffix in
                t.hasSuffix(suffix) && !t.dropLast(suffix.count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let sidebarSession = isSidebarStatus ? capturedSidebarStatusSession(event.obj.element) : nil
            if sidebarSession == nil,
               event.obj.element.string("AXARIALive") == "assertive" {
                heldProgress.removeValue(forKey: currentConversation())
                next()
                startWatching()
                return
            }
            // Dialog notices are immediate news, never background task progress (14 Nov 2026).
            // Chromium exposes these as AXGroup with AXApplicationDialog subrole, including descendants.
            if sidebarSession == nil,
               Self.isDialogNotice(event.obj.element) {
                heldProgress.removeValue(forKey: currentConversation())
                next()
                return
            }
            // Match the ordinary live-region reader: a named group can contain several static text
            // descendants. Its name/value is useful for status filtering, not a replacement for those words.
            let text = ClaudeTranscript.text(of: event.obj.element, skipHidden: false)
            let session = sidebarSession ?? currentConversation()
            guard !text.isEmpty else { return }
            if deliveredProgress[session] == String(text.prefix(500)) {
                // 14 Nov 2026 (third review): the line already said is the newest again, so a held,
                // older line is out of date. Drop it rather than say it later.
                heldProgress.removeValue(forKey: session)
                return
            }
            let progressReadiness = ClaudeProgressReadiness.decision(
                keyQuietFor: progressNow().timeIntervalSince(InputManager.lastKeyDownAt),
                speechBusy: progressSpeechBusy())
            if progressReadiness == .wait {
                holdProgress(text, session: session)
                startWatching()
                return
            }
            heldProgress.removeValue(forKey: session)   // only this conversation has a newer line
            deliverProgress(text, session: session)
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

    private static func isDialogNotice(_ element: AXUIElement) -> Bool {
        var ancestor: AXUIElement? = element
        var seen: Set<ElementKey> = []
        for _ in 0..<16 {
            guard let current = ancestor, seen.insert(ElementKey(current)).inserted else { return false }
            let role = Role.from(axRole: current.role, subrole: current.string(kAXSubroleAttribute))
            if role == .dialog || role == .sheet { return true }
            if current.role == "AXWebArea" || current.role == "AXApplication" { return false }
            ancestor = current.element(kAXParentAttribute)
        }
        return false
    }

    private static let sidebarSessionPrefix = "claude-sidebar-status:"

    private var sidebarSessions: [ElementKey: String] = [:]

    /// Interpret only the already collected page. A status-like conversation notice must not
    /// perform up to twelve provider parent queries on the main actor (review, 14 Nov 2026).
    /// A missing or incomplete copy leaves ordinary assertive delivery in charge.
    private func capturedSidebarStatusSession(_ element: AXUIElement) -> String? {
        guard let page = API.focusTreeInterceptor,
              page.webArea.pid == pid else { return nil }
        return page.buffer.withSnapshot { sidebarStatusSession(element) }
    }

    /// 14 Nov 2026 review: a session link/row inside navigation owns the status, never its title.
    /// Unknown structures fall through to ordinary delivery. The bounded parent chain cannot walk a
    /// conversation's descendants, even if its words happen to end in a sidebar status suffix.
    private func sidebarStatusSession(_ element: AXUIElement) -> String? {
        var node: AXUIElement? = element
        var owner: AXUIElement?
        var seen = Set<ElementKey>()
        for _ in 0..<12 {
            guard let current = node,
                  AXSnapshot.holds(current),
                  seen.insert(ElementKey(current)).inserted else { return nil }
            let role = current.role
            if role == "AXWebArea" || role == "AXWindow" || role == "AXApplication" { return nil }
            if owner == nil,
               role == "AXLink" || role == "AXRow" { owner = current }
            if current.string(kAXSubroleAttribute) == "AXLandmarkNavigation"
                || current.string("AXARIARole") == "navigation" {
                guard let owner else { return nil }
                let rawAddress = owner.attr("AXURL")
                let address = (rawAddress as? URL)?.absoluteString ?? (rawAddress as? String) ?? ""
                if !address.isEmpty { return Self.sidebarSessionPrefix + address }
                let key = ElementKey(owner)
                if let session = sidebarSessions[key] { return session }
                let session = Self.sidebarSessionPrefix + "element:\(sidebarSessions.count)"
                sidebarSessions[key] = session
                return session
            }
            node = current.element(kAXParentAttribute)
        }
        return nil
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

    private struct PendingProgress {
        let text: String
        let since: Date
        var reachedCeiling = false
    }
    /// 14 Nov 2026: one clock per conversation; a switch must not age or discard another conversation's notice.
    private var heldProgress: [String: PendingProgress] = [:]
    private var deliveredProgress: [String: String] = [:]
    private var progressReleaseScheduled = false
    /// Tests advance the real event/release path without waiting a minute or running Claude.
    package var progressSpeechBusy: () -> Bool = { Speech.player?.isBusy ?? false }
    package var progressNow: () -> Date = Date.init
    package var progressScheduler: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, action in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { action() }
    }
    package func progressHeldSince(session: String) -> Date? { heldProgress[session]?.since }

    /// The conversation open now, by its page address: one attribute rather than a window walk.
    private func currentConversation() -> String {
        guard let page = API.focusTreeInterceptor, page.webArea.pid == pid else { return "" }
        return page.url
    }

    /// 14 Nov 2026: quiet keys released progress over a long spoken line in the trial log. Both keys and
    /// SpeechPlayer's locked busy count must be quiet. The minute ceiling is logged once, but the notice
    /// stays pending: neither elapsed time nor switching conversations permits interruption or loss.
    private func holdProgress(_ text: String, session: String) {
        // Keep the words received with the event: Claude can remove or reuse this region before speech is idle.
        guard !text.isEmpty else { return }
        guard deliveredProgress[session] != String(text.prefix(500)) else { return }
        if let pending = heldProgress[session] {
            heldProgress[session] = PendingProgress(text: text, since: pending.since, reachedCeiling: pending.reachedCeiling)
        } else {
            heldProgress[session] = PendingProgress(text: text, since: progressNow())
            Log.io("claude: a progress line waits for quiet keys and idle speech")
        }
        releaseProgressWhenQuiet()
    }

    private func releaseProgressWhenQuiet() {
        guard !progressReleaseScheduled, !heldProgress.isEmpty else { return }
        progressReleaseScheduled = true
        progressScheduler(0.5) { [weak self] in
            guard let self else { return }
            progressReleaseScheduled = false
            releaseHeldProgress()
            releaseProgressWhenQuiet()
        }
    }

    private func releaseHeldProgress() {
        let now = progressNow()
        for session in Array(heldProgress.keys) {
            guard var pending = heldProgress[session] else { continue }
            if !pending.reachedCeiling, now.timeIntervalSince(pending.since) >= ClaudeProgressReadiness.maximumHold {
                pending.reachedCeiling = true
                heldProgress[session] = pending
                Log.io("claude: progress waited a minute; retained until keys and speech are idle")
            }
        }
        // Keep Claude's notices pending while another app is active.
        guard AXHandler.shared.activePid == pid else { return }
        let openSession = currentConversation()
        // 14 Nov 2026: sidebar status belongs to another session and is eligible without opening it.
        // Open-conversation progress retains its existing page-address ownership rule.
        let sidebarSession = heldProgress.keys
            .filter { $0.hasPrefix(Self.sidebarSessionPrefix) }
            .sorted { (heldProgress[$0]?.since ?? .distantFuture) < (heldProgress[$1]?.since ?? .distantFuture) }
            .first
        let session = heldProgress[openSession] == nil ? sidebarSession : openSession
        guard let session else { return }
        guard let pending = heldProgress[session] else { return }
        let readiness = ClaudeProgressReadiness.decision(
            keyQuietFor: now.timeIntervalSince(InputManager.lastKeyDownAt),
            speechBusy: progressSpeechBusy())
        guard readiness == .release else { return }
        guard config.presentation.reportDynamicContentChanges else { return }
        heldProgress.removeValue(forKey: session)
        deliverProgress(pending.text, session: session)
    }

    private func deliverProgress(_ text: String, session: String) {
        let spoken = String(text.prefix(500))
        guard !spoken.isEmpty,
              config.presentation.reportDynamicContentChanges,
              deliveredProgress[session] != spoken else { return }
        deliveredProgress[session] = spoken
        // Conversation-local deduplication applies equally to immediate and held notices; global
        // live-region suppression could otherwise discard another conversation's identical words.
        Speech.speakNews(spoken)
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
            let reply = ClaudeTranscript.latestReply(chat: live)
            Log.io("claude: reply finished, \(reply.count) characters")
            guard !reply.isEmpty else { return }
            self.sayReply(reply, session: ClaudeTranscript.session(of: live), tries: 0)
        }
    }
}
