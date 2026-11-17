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
    private let sessionDeletion = ClaudeSessionDeletion()
    private lazy var browserReturn = ClaudeBrowserReturn(pid: pid)
    private var readReplies: Bool { config.appSetting(ClaudeTranscript.bundleID, "readReplies", default: "on") == "on" }

    /// The Prompt reads its line after Up or Down at its edge recall a message (ClaudePromptText, 16 Nov 2026).
    package override func objectClass(for element: AXUIElement, role: Role, subrole: String?) -> TurnOverObject.Type? {
        guard role == .editableText else { return nil }
        guard element.role == "AXTextArea" else { return nil }
        guard element.string(kAXTitleAttribute) == "Prompt" else { return nil }
        return ClaudePromptText.self
    }

    package required init(pid: pid_t, bundleIdentifier: String, appName: String) {
        super.init(pid: pid, bundleIdentifier: bundleIdentifier, appName: appName)
        sessionDeletion.installScripts(on: self)
        WebBuffer.statusEchoApps.insert(ClaudeTranscript.bundleID)   // its tool rows' status repeats the row's button
        script("claude_switchConversation", String(localized: "Switches to a recent or new Claude conversation", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+1", "kb:command+2", "kb:command+3", "kb:command+4", "kb:command+5", "kb:command+6", "kb:command+7", "kb:command+8", "kb:command+9", "kb:command+n"], category: "Claude") { [weak self] gesture in
            self?.prepareConversationSwitch(gesture)
            gesture.send()
        }
        for arrow in ["upArrow", "downArrow"] {
            script("claude_popup_" + arrow, String(localized: "Reads the selected Claude command", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:" + arrow], category: "Claude") { [weak self] key in
                // The availability check is pure and cheap; a popup gone stale (slash erased, no news yet)
                // is found and retired here, and the key still does what an arrow does in the Prompt.
                let stale = self?.retireStalePromptPopup() ?? false
                key.send()
                if !stale { self?.refreshPopup(after: 0.04) }
            }.isAvailable = { [weak self] in self?.hasPromptPopup == true }
        }
        script("claude_chooseMenuItem", String(localized: "Chooses a Claude menu item", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:enter", "kb:space"], category: "Claude") { [weak self] key in
            guard let self, let focus = API.focusObject else { return }
            rememberChoice(focus)
            key.send()
        }.isAvailable = { [weak self] in self?.popup != nil && API.focusObject?.axRole == "AXMenuItem" }
        // 14 Nov 2026: focused session menu items exposed no AXPress/AXConfirm; VO-Space
        // only refocused them. Native Return opened the confirmation dialog in the same log.
        script("vo_defaultAction", String(localized: "Activates Claude's focused menu item", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+space"], category: "Claude") { [weak self] key in
            guard let self else { return }
            if sessionDeletion.activate(key, useReturn: true) { return }
            guard canActivateFocusedMenuItem else { return }
            if let focus = API.focusObject { rememberChoice(focus) }
            KeyboardGesture(identifier: "kb:enter")?.send()
        }.isAvailable = { [weak self] in
            self?.sessionDeletion.canActivate == true || self?.canActivateFocusedMenuItem == true
        }
        script("claude_readLatest", String(localized: "Reads Claude's latest reply", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+shift+r"], category: "Claude") { [weak self] _ in
            guard let self, let chat = ClaudeTranscript.chat(pid: self.pid) else { Speech.speakMessage(String(localized: "no conversation", comment: "Spoken message")); return }
            let reply = ClaudeTranscript.latestReply(chat: chat)
            Speech.speakText(reply.isEmpty ? String(localized: "no reply yet", comment: "Spoken message") : reply)
        }
    }

    package override func script(for gesture: KeyboardGesture) -> Script? {
        browserReturn.script(for: gesture, owner: self) ?? super.script(for: gesture)
    }

    package override var handlesGroupMenus: Bool { true }
    private var popup: AXUIElement?
    private var popupField: AXUIElement?
    private var popupGeneration = 0
    private var popupSpoken = ""
    private var pendingChoice: (String, Date)?
    private let popupReader = AXWalkRunner<PopupReading>()
    package struct PopupReading: Sendable {
        let selected: String
        let first: String
        var closed = false
    }

    // The log proves AXGroup menu notifications, but does not record descendants. Accept only
    // semantic options/menu items; unfamiliar groups stay silent rather than reading a transcript.
    // All provider reads run off main, bounded by nodes, time, depth and the worker cancellation.
    private func rememberChoice(_ focus: TurnOverObject) {
        guard popup != nil else { return }
        pendingChoice = (focus.name, Date())
    }

    private func clearPopup() {
        popup = nil
        popupField = nil
        popupGeneration += 1
        popupReader.cancel()
    }

    /// The availability check for the popup's arrows. Pure and cheap: no Accessibility read of the value, and no
    /// change of state. Staleness (the slash erased) is retired by `retireStalePromptPopup`, from the events and
    /// from the arrow script itself.
    private var hasPromptPopup: Bool {
        guard popup != nil,
              let field = API.focusObject,
              let origin = popupField,
              field.axRole == "AXTextArea",
              field.element.isSame(origin) else { return false }
        return API.focusTreeInterceptor?.passThrough == true
    }

    /// Retires the popup if the Prompt no longer starts with a slash. Returns true if it did.
    /// 15 Nov 2026, Claude/macOS 27.2: group menus posted no menuEnd after the slash was erased; their cached
    /// reference still took arrows while ordinary text was read. Read the current value: the focus object's lazy
    /// value predates these edits.
    @discardableResult
    private func retireStalePromptPopup() -> Bool {
        guard popup != nil, let field = API.focusObject, let origin = popupField, field.element.isSame(origin) else { return false }
        if field.name == "Prompt", (origin.string(kAXValueAttribute) ?? "").hasPrefix("/") { return false }
        clearPopup()
        return true
    }

    nonisolated private static func readPopup(_ root: AXUIElement, field: AXUIElement?, request: AXWalkRequest) -> PopupReading {
        let deadline = Date().addingTimeInterval(0.15)
        AXUIElementSetMessagingTimeout(root, 0.03)
        let role = root.attributeResult(kAXRoleAttribute)
        if role.error == .invalidUIElement || root.attr("AXHidden") as? Bool == true {
            return PopupReading(selected: "", first: "", closed: true)
        }
        var pending = [(root, 0)], seen = Set<ElementKey>()
        var first = "", selected = ""
        var selectedElements = Set<ElementKey>()
        if let field {
            AXUIElementSetMessagingTimeout(field, 0.03)
            if let active = field.element("AXActiveDescendant") { selectedElements.insert(ElementKey(active)) }
        }
        while let (node, depth) = pending.popLast(), seen.count < 96, Date() < deadline {
            guard !request.isCancelled else { break }
            guard seen.insert(ElementKey(node)).inserted else { continue }
            AXUIElementSetMessagingTimeout(node, 0.03)
            let attrs = node.attrs([kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                                    kAXValueAttribute, kAXChildrenAttribute, kAXSelectedAttribute, kAXFocusedAttribute,
                                    "AXSelectedChildren", "AXActiveDescendant"])
            let role = attrs[kAXRoleAttribute] as? String ?? ""
            let subrole = attrs[kAXSubroleAttribute] as? String ?? ""
            for choice in attrs["AXSelectedChildren"] as? [AXUIElement] ?? [] { selectedElements.insert(ElementKey(choice)) }
            if let choice = axElement(attrs["AXActiveDescendant"]) { selectedElements.insert(ElementKey(choice)) }
            if role == "AXMenuItem" || role == "AXOption" || subrole == "AXListBoxOption" || role == "AXButton" {
                var label = (attrs[kAXTitleAttribute] as? String) ?? (attrs[kAXDescriptionAttribute] as? String) ?? ""
                if label.isEmpty { label = attrs[kAXValueAttribute] as? String ?? "" }
                if label.isEmpty {
                    // Chromium often places an option's name in its static-text child.
                    label = (attrs[kAXChildrenAttribute] as? [AXUIElement] ?? []).prefix(4).compactMap {
                        $0.string(kAXValueAttribute) ?? $0.string(kAXTitleAttribute)
                    }.filter { !$0.isEmpty }.joined(separator: " ")
                }
                if first.isEmpty { first = label }
                if selectedElements.contains(ElementKey(node)) || attrs[kAXSelectedAttribute] as? Bool == true || attrs[kAXFocusedAttribute] as? Bool == true { selected = label }
            }
            if depth < 6 { pending.append(contentsOf: (attrs[kAXChildrenAttribute] as? [AXUIElement] ?? []).reversed().map { ($0, depth + 1) }) }
        }
        return PopupReading(selected: selected, first: first)
    }

    private func refreshPopup(after delay: TimeInterval = 0) {
        guard let root = popup, API.focusObject?.axRole == "AXTextArea" else { return }
        guard hasPromptPopup, !retireStalePromptPopup() else { return }
        popupGeneration += 1
        let generation = popupGeneration
        let field = API.focusObject?.axRole == "AXTextArea" ? API.focusObject?.element : nil
        popupReader.cancel()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, popupGeneration == generation, popup != nil else { return }
            popupReader.submit(collect: { request in AXReadScope.with(while: { !request.isCancelled }) { Self.readPopup(root, field: field, request: request) } }, publish: { [weak self] reading in
                guard let self, popupGeneration == generation, popup != nil,
                      API.focusTreeInterceptor?.webArea.pid == pid,
                      hasPromptPopup, !retireStalePromptPopup() else { return }
                if reading.closed { clearPopup(); return }
                let label = reading.selected.isEmpty ? reading.first : reading.selected
                guard !label.isEmpty else {
                    Log.io("claude: group popup has no named semantic selection; awaiting focus or selection news")
                    return
                }
                guard label != popupSpoken else { return }
                popupSpoken = label
                Speech.speakMessage(label)
            })
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

    private var conversationStartingTitle = ""
    /// The destination title the pending switch has said, or empty before it has said one (17 Nov 2026).
    private var conversationAnnouncedTitle = ""
    /// Keys counted when the pending switch's shortcut arrived; a later key means the user moved on (17 Nov 2026).
    private var conversationSwitchKeys = 0
    /// Command and a number, not Command N: a new conversation's Prompt is still said (17 Nov 2026).
    private var conversationSwitchIsNumbered = false
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
        var nodes: [ElementKey: AXSnapshot.Node] = [ElementKey(root): .init(attributes: values)]
        let app = AXUIElementCreateApplication(root.pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        if let focus = app.element(kAXFocusedUIElementAttribute) {
            // 14 Nov 2026: Claude can retain Prompt focus without posting focus news after a switch.
            // Capture it on the worker, bounded to this page; the new-page reset runs before it is applied.
            var appValues = nodes[ElementKey(app)]?.attributes ?? [:]
            appValues[kAXFocusedUIElementAttribute] = .element(focus)
            nodes[ElementKey(app)] = .init(attributes: appValues)
            var current: AXUIElement? = focus
            for _ in 0..<20 {
                guard let element = current, !element.isSame(root) else { break }
                AXUIElementSetMessagingTimeout(element, 0.05)
                let attrs = element.attrs([kAXRoleAttribute, kAXTitleAttribute, kAXParentAttribute])
                nodes[ElementKey(element)] = .init(attributes: attrs.compactMapValues { AXSnapshotValue($0) })
                current = element.element(kAXParentAttribute)
            }
        }
        return AXSnapshot(nodes: nodes)
    }

    /// Only the destination owns switch speech. An unchanged poll can release queued keys after the
    /// existing settle, but cannot establish that the shortcut chose the already-open conversation.
    package func prepareConversationSwitch(_ gesture: KeyboardGesture) {
        sessionDeletion.cancel()
        guard let page = API.focusTreeInterceptor,
              page.webArea.pid == pid else { return }
        let earlierSwitchOwnsPage = conversationPage === page && page.navigationTitleOwned
        let earlierSwitchHasArrived = earlierSwitchOwnsPage && !conversationAnnouncedTitle.isEmpty
        // 17 Nov 2026 (log, five wrong titles): a switch that has said its destination has arrived there,
        // although it owns the page until a long copy is read in. A shortcut pressed then starts from the
        // conversation it is leaving, the one just announced, not the earlier switch's own starting title.
        let arrivedTitle = earlierSwitchHasArrived ? conversationAnnouncedTitle : ""
        conversationAnnouncedTitle = ""
        conversationSwitchKeys = ScriptHandler.keysArrivedCount
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
        let capturedTitle = page.buffer.withSnapshot { Self.switchTitle(root.string(kAXTitleAttribute) ?? "") }
        // newPage empties the snapshot while collecting. A repeated shortcut still starts from the
        // title owned by the pending switch, never that temporarily empty copy (14 Nov 2026 review).
        let title: String
        if !arrivedTitle.isEmpty {
            title = arrivedTitle
            Log.io("claude: switch starts from the title the earlier switch announced")
        } else if !capturedTitle.isEmpty {
            title = capturedTitle
        } else {
            // Nothing captured and no earlier switch has said where it arrived (17 Nov 2026): the earlier switch's own
            // starting title is the conversation before that one, so any conversation it had reached since would differ
            // from it and be said as the destination of this switch. Unknown: the first answer whose address has not
            // changed names the conversation being left, silently (below).
            if earlierSwitchOwnsPage { Log.io("claude: an earlier switch has said nothing yet; the starting title is taken from the first unchanged answer") }
            title = ""
        }
        conversationStartingTitle = title
        let number = Int(gesture.identifier.components(separatedBy: "+").last ?? "")
        conversationSwitchIsNumbered = number != nil
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
        let unresolvedNumber = target == .unknown ? number : nil
        var titleAnnounced = false
        var ceilingReached = false
        var releasedContent = false
        var unchangedAnswers = 0
        var observedAddressChange = false
        var latestSnapshot: AXSnapshot?
        var latestFocus: TurnOverObject?
        var latestKeys = 0
        var restoredFocusURL: String?
        // The title of the conversation being left. It can be unknown at the key (17 Nov 2026): a copy
        // still being read in has an empty snapshot, and no earlier switch owns the page.
        var baselineTitle = title
        let settleUntil = ProcessInfo.processInfo.systemUptime + 0.25
        page.navigationTitleOwned = true
        // An unavailable sidebar cannot prove that a numbered shortcut will navigate. Keep typing
        // in the Prompt until navigation is observed; an ignored key must not enable browse commands.
        if unresolvedNumber == nil || !page.passThrough { page.beginNavigationWait() }

        func releaseContent() {
            page.announcedURL = page.lastURL
            page.announceWhenReady = false
            // Restore after the URL reset, once per destination and before queued commands run.
            // A later key/focus change supersedes the worker's captured keyboard focus.
            if observedAddressChange,
               restoredFocusURL != page.lastURL,
               API.focusObject === latestFocus,
               ScriptHandler.keysArrivedCount == latestKeys,
               API.focusTreeInterceptor === page,
               AXHandler.shared.activePid == pid,
               let snapshot = latestSnapshot {
                restoredFocusURL = page.lastURL
                snapshot.with {
                    let app = AXUIElementCreateApplication(root.pid)
                    if let focus = app.element(kAXFocusedUIElementAttribute),
                       focus.role == "AXTextArea",
                       focus.string(kAXTitleAttribute) == "Prompt" {
                        var ancestor = focus.element(kAXParentAttribute)
                        for _ in 0..<20 {
                            guard let element = ancestor else { break }
                            if element.isSame(root) {
                                page.setPassThrough(true, announce: true)
                                break
                            }
                            ancestor = element.element(kAXParentAttribute)
                        }
                    }
                }
            }
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
                    let now = snapshot.with { page.url }
                    let name = snapshot.with { Self.switchTitle(root.string(kAXTitleAttribute) ?? "") }
                    if let number = unresolvedNumber,
                       !observedAddressChange,
                       now == address {
                        Speech.speakMessage(String(localized: "no conversation \(number)", comment: "Spoken when Claude has no conversation at this shortcut number"))
                    } else if !name.isEmpty {
                        // A missing URL is not evidence that an unknown numbered target was reached.
                        let destinationKnown = unresolvedNumber == nil || observedAddressChange || (!now.isEmpty && now != address)
                        if destinationKnown { page.announceNavigationTitle(name) }
                    }
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
                let focus = API.focusObject
                let keys = ScriptHandler.keysArrivedCount
                conversationReader.submit(collect: { _ in read(root) }, publish: { [weak self, weak page] snapshot in
                    guard let self,
                          let page,
                          conversationSwitch == request,
                          !ceilingReached else { return }
                    guard API.focusTreeInterceptor === page,
                          AXHandler.shared.activePid == pid else { finish(); return }
                    latestSnapshot = snapshot
                    latestFocus = focus
                    latestKeys = keys
                    let now = snapshot.with { page.url }
                    let changed = !now.isEmpty && now != address
                    let busy = snapshot.with { root.attr("AXElementBusy") as? Bool == true }
                    let name = snapshot.with { Self.switchTitle(root.string(kAXTitleAttribute) ?? "") }
                    if changed {
                        observedAddressChange = true
                        let needsNavigationWait = releasedContent || !page.navigationWaiting
                        if page.lastURL != now,
                           needsNavigationWait {
                            page.beginNavigationWait()
                            releasedContent = false
                        }
                        // The scope covers URL/role reads too; no provider query is made on main.
                        _ = snapshot.with { page.refreshIfNavigated() }
                    }
                    let destinationLoaded = changed && page.lastURL == now && !page.buffer.isLoading && !page.buffer.lines.isEmpty
                    let matchesTarget: Bool
                    if case .other(let expectedTitle) = target {
                        matchesTarget = name == expectedTitle
                    } else {
                        matchesTarget = true
                    }
                    // 17 Nov 2026: with no known title at the key, the first answer whose address has not
                    // changed names the conversation being left. It becomes the baseline and is not said.
                    let baselineUnknown = baselineTitle.isEmpty
                    let addressStillTheSame = !changed && !observedAddressChange
                    let answerNamesTheConversationLeft = baselineUnknown && addressStillTheSame && !busy && !name.isEmpty
                    if answerNamesTheConversationLeft {
                        baselineTitle = name
                        Log.io("claude: switch baseline taken from the first unchanged answer")
                    }
                    // A changed URL and its completed copy establish arrival even for equal titles.
                    // If the sidebar named a different destination, its old title is still stale.
                    let arrivalIsProven = destinationLoaded && matchesTarget
                    // A changed title counts only against a known baseline (17 Nov 2026): against an
                    // unknown one, the title of the conversation being left looked like a new one.
                    let titleHasChanged = !baselineTitle.isEmpty && name != baselineTitle
                    let titleIsReady = !busy && !name.isEmpty && (titleHasChanged || arrivalIsProven)
                    // Claude can change AXTitle while keeping AXURL (or temporarily omitting it).
                    // Do not gate that evidence on a changed address, or speak a pre-switch title.
                    if titleIsReady,
                       !titleAnnounced {
                        titleAnnounced = true
                        // A shortcut pressed before this switch finishes starts from here (17 Nov 2026).
                        conversationAnnouncedTitle = name
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

    private enum SwitchTarget: Equatable { case current, other(String), missing, unknown }

    /// Claude 5.1231.2, macOS 27.2, 14 Nov 2026: the complementary sidebar's Recents section has
    /// a heading group followed by session groups, each with a title button and a popup menu. Use
    /// only the captured tree; an absent, clipped or unfamiliar section proves nothing. A collapsed
    /// section can still expose its complete rows; without those rows its count is unknown.
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
            let collapsed = headerNodes.contains(where: { ($0.attr("AXExpanded") as? Bool) == false })
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
                if collapsed { return .unknown }
                return headerNodes.contains(where: { ($0.attr("AXExpanded") as? Bool) == true }) ? .missing : .unknown
            }
            if number > titles.count { return .missing }
            let target = switchTitle(titles[number - 1])
            if target == title,
               titles.filter({ switchTitle($0) == title }).count == 1 { return .current }
            return .other(target)
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

    /// 17 Nov 2026 (log, three switches): Claude puts the keyboard in the destination's Prompt as it
    /// arrives. When that focus came after the unchanged-address settle had released the wait, its own
    /// announcement was said just before the title, though a switch says only the destination's title.
    private func isSwitchPromptFocus(_ event: Event) -> Bool {
        guard event.kind == .gainFocus else { return false }
        let isPrompt = event.obj.axRole == "AXTextArea" && event.obj.name == "Prompt"
        guard isPrompt else { return false }
        guard let page = conversationPage,
              API.focusTreeInterceptor === page else { return false }
        let switchStillPending = page.navigationTitleOwned
        let noKeySinceShortcut = ScriptHandler.keysArrivedCount == conversationSwitchKeys
        return switchStillPending && noKeySinceShortcut && conversationSwitchIsNumbered
    }

    package override func ignoresFocus(_ event: Event) -> Bool {
        // Not said, so it must not cut off speech either, such as a title already being said.
        isSwitchPromptFocus(event) || isOwnCopyPressFocus(event)
    }

    /// 17 Nov 2026 (log, two presses of "Copy code"): TurnOver puts the keyboard on the button itself before it
    /// presses it, and the focus announcement said the three groups round it ("Side chat, grouping; Chat messages,
    /// grouping; bash code, grouping; Copy code, button"). Only the page's "Copied" is news. Claude's module only.
    package var ownPressWatching: (AXUIElement) -> Bool = { element in BrowseModeDocument.watches.contains { $0.element.isSame(element) } }
    /// When TurnOver last put the keyboard on a Copy button to press it.
    private var ownCopyPressAt: Date?
    private func isOwnCopyPressFocus(_ event: Event) -> Bool {
        guard event.kind == .gainFocus, event.obj.axRole == "AXButton", event.obj.name.hasPrefix("Copy"),
              ownPressWatching(event.obj.element) else { return false }
        ownCopyPressAt = progressNow()
        return true
    }
    /// The page's word for the copy ("Copied"), a single short word soon after TurnOver's own press of the button:
    /// said at once, not held for quiet keys (it was held, then lost to Command Tab, and said 1.5 s or 35 s late).
    package static func isCopyResult(text: String, sincePress: TimeInterval?) -> Bool {
        guard let sincePress, sincePress >= 0, sincePress < 1.5 else { return false }
        return !text.isEmpty && text.count <= 16 && !text.contains(where: \.isWhitespace)
    }

    package override func handleEvent(_ event: Event, next: () -> Void) {
        browserReturn.handleEvent(event)
        sessionDeletion.observe(event)
        if event.kind == .gainFocus,
           API.focusTreeInterceptor?.navigationWaiting == true { return }
        if isOwnCopyPressFocus(event) {
            Log.io("claude: the keyboard TurnOver put on a Copy button is not announced")
            return
        }
        if isSwitchPromptFocus(event),
           let page = conversationPage {
            // The wait was already released, so nothing else will put the Prompt in focus mode.
            // Do it here, with the usual sound, and leave the words to the title.
            Log.io("claude: Prompt focus during a conversation switch is not said")
            if page.shouldPassThrough(event.obj) {
                page.setPassThrough(true, announce: true)
            }
            return
        }
        // A menu may disappear without a close notification. A different field/page owns
        // subsequent keys; a native menu item can still own its own focus and confirmation.
        if event.kind == .gainFocus, popup != nil,
           event.obj.axRole != "AXMenuItem",
           popup?.isSame(event.obj.element) != true,
           popupField?.isSame(event.obj.element) != true {
            clearPopup()
        }
        switch event.kind {
        case .menuStart where event.obj.axRole == "AXGroup":
            popup = event.obj.element
            popupField = API.focusObject?.axRole == "AXTextArea" ? API.focusObject?.element : nil
            popupSpoken = ""
            refreshPopup()
            return
        case .menuEnd where event.obj.axRole == "AXGroup":
            if popup?.isSame(event.obj.element) == true {
                clearPopup()
            }
            return
        case .gainFocus where pendingChoice != nil && event.obj.axRole == "AXTextArea":
            let choice = pendingChoice!
            pendingChoice = nil
            next()
            if Date().timeIntervalSince(choice.1) < 1 { Speech.speakMessage(choice.0) }
            return
        case .selection where popup != nil, .valueChange where popup != nil, .caret where popup != nil:
            refreshPopup()
            next()
        case .appModuleLoseFocus:
            clearPopup()
            pendingChoice = nil
            next()
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
            if Self.isCopyResult(text: text, sincePress: ownCopyPressAt.map { progressNow().timeIntervalSince($0) }) {
                // Said again for each copy, though the words are the same ones: a press is news every time.
                Log.io("claude: the result of TurnOver's own Copy press is said at once")
                heldProgress.removeValue(forKey: session)
                deliveredProgress.removeValue(forKey: session)
                deliverProgress(text, session: session)
                startWatching()
                return
            }
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
