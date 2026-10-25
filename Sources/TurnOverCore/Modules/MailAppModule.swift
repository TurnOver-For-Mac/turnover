// SPDX-License-Identifier: GPL-3.0-or-later
// Mail. The message list says which messages are unread (Mail shows it only as a dot; its row offers
// the action "Read" while unread and "Unread" once read), Shift+Command+U says which way it went, and
// the compose body has a name.
import Foundation
import ApplicationServices

package final class MailAppModule: AppModule {
    static let bundleID = "com.apple.mail"

    required init(pid: pid_t, bundleIdentifier: String, appName: String) {
        super.init(pid: pid, bundleIdentifier: bundleIdentifier, appName: appName)
        script("mail_composeNext", String(localized: "Writing a message: the next field, including the Priority, From and Signature pop-ups", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:tab"], category: "Mail") { [weak self] g in
            guard let self, let f = API.focusObject?.element else { g.send(); return }
            self.composeMove(forward: true, from: f, g)
        }.isAvailable = { Self.place.hasPrefix("compose:") && Self.place != "compose:body" }   // Tab in the message is the message's
        script("mail_composePrevious", String(localized: "Writing a message: the previous field, including the pop-ups", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+tab"], category: "Mail") { [weak self] g in
            guard let self, let f = API.focusObject?.element else { g.send(); return }
            self.composeMove(forward: false, from: f, g)
        }.isAvailable = { Self.place.hasPrefix("compose:") }
        script("mail_toMailboxes", String(localized: "From the message list: the mailbox list (Shift Tab)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+tab"], category: "Mail") { [weak self] g in
            guard let self, let f = API.focusObject?.element else { g.send(); return }
            self.focusList("mailboxes", from: f)
        }.isAvailable = { Self.place == "messages" }
        // Return in the search field: Mail searches and says nothing; the keys stayed in the field and Tab went to the
        // toolbar (8 Oct 2026). Say how many results, and go to them.
        script("mail_submitSearch", String(localized: "Searching: Return searches, says how many results, and goes to them", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:enter"], category: "Mail") { [weak self] g in
            guard let self else { g.send(); return }
            g.send()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                let title = AXUIElementCreateApplication(self.pid).element(kAXFocusedWindowAttribute)?.string(kAXTitleAttribute) ?? ""
                if let r = title.range(of: #"\d[\d,]* results?"#, options: .regularExpression) { Speech.speakMessage(String(title[r])) }
                else if title.lowercased().contains("search") { Speech.speakMessage(String(localized: "no results", comment: "Spoken message")) }
                if let f = API.focusObject?.element { self.focusList("messages", from: f) }
            }
        }.isAvailable = { API.focusObject?.role == .searchField }
        // Command Shift D sends: say so once the compose window has gone (nothing confirmed it; a tester, 8 Oct 2026).
        script("mail_send", String(localized: "Writing a message: Command Shift D sends it, and says so", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+shift+d"], category: "Mail") { g in
            g.send()
            // Said as the compose window goes, before the window behind it is read: said 1.2 s later, it queued behind
            // that window and its message list, and the next key cut it off (12 Oct 2026: "it's not saying sent").
            Self.sending = API.focusObject.flatMap { SettingsPanePlugin.windowOf($0.element) }.map { ($0, Date()) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Self.saySentIfGone() }
        }.isAvailable = { Self.place.hasPrefix("compose:") }
        // Command ' and Command Option ' change the quote level of what is being written: say the level it is now
        // (nothing was said; a tester, 12 Oct 2026).
        for (name, desc, key) in [("mail_quoteMore", "Writing a message: increases the quote level, and says it", "kb:command+'"),
                                  ("mail_quoteLess", "Writing a message: decreases the quote level, and says it", "kb:command+option+'")] {
            script(name, desc, gestures: [key], category: "Mail") { g in
                g.send()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    guard let f = API.focusObject, let info = try? f.makeTextInfo(.caret) as? WebTextInfo else { return }
                    let lvl = (info.elementsAtStart().first?.attr("AXBlockQuoteLevel") as? NSNumber)?.intValue ?? 0
                    BufferTextInfo.lastQuoteLevel = lvl
                    Speech.speakMessage(lvl > 0 ? String(localized: "quote level \(String(lvl))", comment: "How deep a quote is in a Mail message") : String(localized: "no quote", comment: "Spoken message"))
                }
            }.isAvailable = { Self.place.hasPrefix("compose:") }
        }
        script("mail_toMessages", String(localized: "From the mailbox list: the message list (Tab)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:tab"], category: "Mail") { [weak self] g in
            guard let self, let f = API.focusObject?.element else { g.send(); return }
            self.focusList("messages", from: f)
        }.isAvailable = { Self.place == "mailboxes" }
        // Escape leaves the message being read, as in Outlook on Windows (7 Oct 2026): a message in its own
        // window closes, and the keys go back to the message list; in the main window, the list takes the keys.
        // Only while reading (browse mode): in focus mode Escape first goes back to browse mode, and in a message
        // being written it is Mail's own.
        script("mail_leaveMessage", String(localized: "Reading a message: back to the message list (closes the message's own window)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:escape"], category: "Mail") { [weak self] g in
            guard let self, let d = API.focusTreeInterceptor else { g.send(); return }
            self.leaveMessage(from: d.webArea, g)
        }.isAvailable = {
            guard let d = API.focusTreeInterceptor, !d.passThrough, d.webArea.pid == pid else { return false }
            return !Self.place.hasPrefix("compose:") && !AXHandler.shared.isMenuOpen
        }
        script("mail_getNewMail", String(localized: "Checks for new mail and says so", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+shift+n"], category: "Mail") { g in
            g.send()
            Speech.speakMessage(String(localized: "checking for new mail", comment: "Spoken message"))
        }
        script("mail_toggleRead", String(localized: "Marks the message read or unread, and says which", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+shift+u"], category: "Mail") { g in
            g.send()
            // The focus is the message list (its rows are read as its selection) or, rarely, a row.
            guard let f = API.focusObject else { return }
            let rows = f.element.string(kAXDescriptionAttribute) == "messages" ? f.element.elements(kAXSelectedRowsAttribute) : MailMessageRow.isMessageRow(f.element) ? [f.element] : []
            guard !rows.isEmpty else { return }
            // Mail changes the rows' action a moment after the key.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let unread = rows.filter(MailMessageRow.isUnread).count
                let said = rows.count == 1 ? (unread == 1 ? String(localized: "unread", comment: "A Mail message not yet read") : String(localized: "read", comment: "A Mail message marked read"))
                    : unread == rows.count ? String(localized: "\(String(rows.count)) messages marked unread", comment: "Mail messages marked unread: how many") : String(localized: "\(String(rows.count)) messages marked read", comment: "Mail messages marked read: how many")
                Speech.speakMessage(said)
            }
        }
    }

    // Tab between the mailbox list and the message list. Mail puts its mailbox list in the Tab order only while
    // VoiceOver runs: with TurnOver, Shift Tab from the messages went to the favourites bar and the toolbar, and the
    // mailboxes could not be reached (5 Oct 2026). Worked out as the focus moves; read by the keyboard thread.
    private static let placeLock = NSLock()
    private static var _place = ""   // "messages", "mailboxes" or ""
    static var place: String { placeLock.lock(); defer { placeLock.unlock() }; return _place }

    /// A message being written: its header in the order a person expects. Mail's own Tab skips the three pop-ups
    /// (Priority, From, Signature), so the From address could not be changed from the keyboard (5 Oct 2026).
    static let composeOrder = ["Mail.toField", "Mail.ccField", "Mail.bccField", "Mail.replyToField", "Mail.subjectField",
                               "popup_priority", "popup_from", "popup_signature", "body"]

    private func notePlace(_ e: AXUIElement) {
        var p = ""
        let id = e.string(kAXIdentifierAttribute) ?? ""
        if Self.composeOrder.contains(id) { p = "compose:" + id }
        // Mail names the body "message body" both when writing and when reading: only an editable one is writing.
        else if e.role == "AXWebArea", e.string(kAXDescriptionAttribute) == "message body", EditableWebArea.isEditable(e) { p = "compose:body" }
        else if e.role == "AXWebArea" { p = "reading" }
        else if e.string(kAXDescriptionAttribute) == "messages" || MailMessageRow.isMessageRow(e) { p = "messages" }
        else if e.role == "AXOutline" || e.element(kAXParentAttribute)?.role == "AXOutline" { p = "mailboxes" }
        Self.placeLock.lock(); Self._place = p; Self.placeLock.unlock()
    }

    private func composeMove(forward: Bool, from: AXUIElement, _ g: KeyboardGesture) {
        guard let w = SettingsPanePlugin.windowOf(from) else { g.send(); return }
        var byId: [String: AXUIElement] = [:]
        var queue = [w]; var seen = 0
        while !queue.isEmpty, seen < 300 {
            let e = queue.removeFirst(); seen += 1
            if let id = e.string(kAXIdentifierAttribute), Self.composeOrder.contains(id), byId[id] == nil { byId[id] = e }
            if e.role == "AXWebArea", e.string(kAXDescriptionAttribute) == "message body" { byId["body"] = e; continue }
            if e.role == "AXToolbar" { continue }
            queue.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
        // Only what is showing (Cc, Bcc, Reply To and Priority come and go with View, Header Fields).
        let present = Self.composeOrder.filter { id in
            guard let e = byId[id] else { return false }
            return id == "body" || ((e.attr(kAXSizeAttribute)).map { v -> Bool in var z = CGSize.zero; axValue(v, .cgSize, &z); return z.height > 1 } ?? false)
        }
        let here = String(Self.place.dropFirst("compose:".count))
        guard let i = present.firstIndex(of: here) else { g.send(); return }
        let n = forward ? i + 1 : i - 1
        guard present.indices.contains(n), let target = byId[present[n]] else { g.send(); return }   // the ends: Mail's own
        Log.io("mail: \(forward ? "Tab" : "Shift+Tab") from \(here) to \(present[n])")
        SettingsPanePlugin.focus(target)
    }

    /// The message being read inside a scroll area: the first web area that isn't being written in. Mail's "message
    /// content" holds it four levels down (group, scroll area, web area; measured 13 Oct 2026); the message list's
    /// scroll area holds none.
    package static func messageIn(_ scroll: AXUIElement,
                                  isEditable: @MainActor (AXUIElement) -> Bool = EditableWebArea.isEditable) -> AXUIElement? {
        var level = scroll.elements(kAXChildrenAttribute)
        for _ in 0..<6 {
            guard level.count <= 200 else { return nil }
            // An editable web area beside the message is a compose body, not the end of the search. Never
            // descend into it and mistake one of its nested web areas for received mail (issue 179, 29 Oct 2026).
            if let web = level.first(where: { $0.role == "AXWebArea" && !isEditable($0) }) { return web }
            level = level.filter { !["AXTable", "AXOutline", "AXScrollBar", "AXWebArea"].contains($0.role) }.flatMap { $0.elements(kAXChildrenAttribute) }
            if level.isEmpty || level.count > 200 { return nil }
        }
        return nil
    }

    private func landInMessage(_ window: AXUIElement) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, API.focusPid == self.pid else { return }
            // Already reading a page, or typing: leave it.
            if API.focusTreeInterceptor != nil || Self.place.hasPrefix("compose:") { return }
            var queue = [window]; var seen = 0; var hasList = false; var web: AXUIElement?
            while !queue.isEmpty, seen < 400 {
                let e = queue.removeFirst(); seen += 1
                if e.role == "AXTable", e.string(kAXDescriptionAttribute) == "messages" { hasList = true; break }
                if e.role == "AXWebArea" { if web == nil, !EditableWebArea.isEditable(e) { web = e }; continue }
                if e.role == "AXToolbar" { continue }
                queue.append(contentsOf: e.elements(kAXChildrenAttribute))
            }
            guard !hasList, let web else { return }
            Log.io("mail: a message in its own window; reading starts in the message")
            AXHandler.shared.focusChanged(web, pid: self.pid)
        }
    }

    private func leaveMessage(from: AXUIElement, _ g: KeyboardGesture) {
        guard let w = SettingsPanePlugin.windowOf(from) else { g.send(); return }
        // The main viewer has the message list; a message opened on its own (Return with the preview hidden) does not.
        var queue = [w]; var seen = 0; var hasList = false
        while !queue.isEmpty, seen < 400, !hasList {
            let e = queue.removeFirst(); seen += 1
            if e.role == "AXTable", e.string(kAXDescriptionAttribute) == "messages" { hasList = true }
            if e.role == "AXToolbar" || e.role == "AXWebArea" { continue }
            queue.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
        if hasList {
            Log.io("mail: Escape from the message to the list")
            focusList("messages", from: from)
        } else {
            Log.io("mail: Escape closes the message window")
            KeyboardGesture(identifier: "kb:command+w")?.send()
            // Mail brings the main window back; read the list where it is.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                let app = AXUIElementCreateApplication(self.pid)
                if let main = app.element(kAXFocusedWindowAttribute) ?? app.element(kAXMainWindowAttribute) { self.focusList("messages", from: main) }
            }
        }
    }

    private func focusList(_ wanted: String, from: AXUIElement) {
        guard let w = from.role == "AXWindow" ? from : SettingsPanePlugin.windowOf(from) else { return }
        var queue = [w]; var seen = 0; var target: AXUIElement?
        while !queue.isEmpty, seen < 400, target == nil {
            let e = queue.removeFirst(); seen += 1
            if wanted == "mailboxes", e.role == "AXOutline" { target = e }
            if wanted == "messages", e.role == "AXTable", e.string(kAXDescriptionAttribute) == "messages" { target = e }
            if e.role == "AXToolbar" { continue }
            queue.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
        guard let t = target else { Tones.edge(); return }
        _ = t.set(kAXFocusedAttribute, kCFBooleanTrue)
        // Mail reports the move itself, and that is read; only if it stays quiet does TurnOver read the list.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, let f = API.focusObject?.element else { return }
            var p: AXUIElement? = f; var hops = 0; var inside = false
            while let x = p, hops < 4 { if x.isSame(t) { inside = true; break }; p = x.element(kAXParentAttribute); hops += 1 }
            if !inside { AXHandler.shared.focusChanged(t.elements(kAXSelectedRowsAttribute).first ?? t, pid: self.pid) }
        }
    }

    /// The window a message was being written in when Command Shift D was pressed, and when, until "sent" is said.
    static var sending: (window: AXUIElement, at: Date)?
    /// "Sent" once that window has gone (Mail closes it as the message goes; a missing address leaves it open with
    /// an alert, and nothing is said).
    static func saySentIfGone() {
        guard let s = sending else { return }
        guard Date().timeIntervalSince(s.at) < 3 else { sending = nil; return }
        let windows = AXUIElementCreateApplication(s.window.pid).elements(kAXWindowsAttribute)
        guard !windows.contains(where: { $0.isSame(s.window) }) else { return }
        sending = nil
        Speech.speakMessage(String(localized: "sent", comment: "Spoken message"))
    }

    package override func handleEvent(_ event: Event, next: () -> Void) {
        // After Command Shift D: "sent" before the window and focus behind the compose window are read.
        if Self.sending != nil, [.foreground, .gainFocus].contains(event.kind) { Self.saySentIfGone() }
        if event.kind == .gainFocus { notePlace(event.obj.element) }
        // The focus on the scroll area around a message (Mail can come back to it after Command Tab; nothing in it is
        // TurnOver's to read, and the arrows only scrolled, 13 Oct 2026): reading starts in the message, as
        // when a message opens in its own window.
        if event.kind == .gainFocus, event.obj.element.role == "AXScrollArea", let web = Self.messageIn(event.obj.element) {
            Log.io("mail: focus on the message's scroll area; reading starts in the message")
            DispatchQueue.main.async { [pid] in AXHandler.shared.focusChanged(web, pid: pid) }
            return
        }
        next()
        // A message opened in its own window (Return with the preview pane hidden, a tester): the reading starts in
        // the message, not on the window's toolbar.
        if event.kind == .foreground, event.obj.element.role == "AXWindow" { landInMessage(event.obj.element) }
        // Mail marks a message read the moment it is selected, before TurnOver can ask: note which of the rows
        // the next key can reach are unread, while they still are.
        if event.kind == .selection || event.kind == .gainFocus {
            let el = event.obj.element
            let table = MailMessageRow.isMessageRow(el) ? el.element(kAXParentAttribute) : (el.string(kAXDescriptionAttribute) == "messages" ? el : nil)
            if let table { MailUnread.snapshot(table) }
        }
    }

    package override func objectClass(for element: AXUIElement, role: Role, subrole: String?) -> TurnOverObject.Type? {
        if role == .tableRow, MailMessageRow.isMessageRow(element) { return MailMessageRow.self }
        if role == .webArea, EditableWebArea.isEditable(element) { return MailMessageBody.self }
        if element.string(kAXIdentifierAttribute) == "popup_priority" { return MailPriorityPopup.self }
        return nil
    }
}

/// The message window's priority pop-up, which Mail describes by its icon ("Exclamation mark").
final class MailPriorityPopup: TurnOverObject {
    override var name: String { "Priority" }
}

final class MailMessageRow: TurnOverObject {
    override var name: String {
        let n = super.name
        let unread = String(localized: "unread", comment: "A Mail message not yet read")
        if n.hasPrefix(unread) { return n }
        return Self.isUnread(element) || MailUnread.wasUnread(element) ? "\(unread), \(n)" : n
    }

    static func isMessageRow(_ e: AXUIElement) -> Bool {
        e.element(kAXParentAttribute)?.string(kAXDescriptionAttribute) == "messages"
    }

    nonisolated static func isUnread(_ e: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(e, &names) == .success, let list = names as? [String] else { return false }
        return list.contains { $0.components(separatedBy: "\n").first == "Name:Read" }
    }
}

final class MailMessageBody: EditableWebArea {
    override var name: String { let n = super.name; return n.isEmpty ? String(localized: "message body", comment: "A Mail message's text, when it has no name") : n }

    /// Mail corrects a word as you finish it ("teh" becomes "the"); VoiceOver says so, and so does TurnOver now:
    /// the word as typed is compared with the word in the message a moment later (a tester, ; wishlist 5).
    override func event_typedCharacter(_ ch: Character) {
        let typed = Speech.typedWordSoFar
        // After a Backspace in the word, TurnOver holds only the letters typed since: no comparison is possible.
        let edited = Speech.typedWordWasEdited
        // A key held back while the word before waits for the field comes here again when it is echoed.
        let held = TurnOverObject.waitingForField
        super.event_typedCharacter(ch)
        guard !held, typed.count >= 2, !edited, ch == " " || ".,;:!?".contains(ch) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, API.focusObject?.isSameElement(as: self) == true,
                  let caret = try? self.makeTextInfo(.caret), caret.start > 1 else { return }
            // The word just before the character that ended it.
            let before = caret.copy(); before.start = max(0, caret.start - typed.count - 12); before.end = caret.start
            // Still just after the character that ended the word: a key typed since moves on, and the word being
            // typed now would be mistaken for a correction.
            guard before.text.last == ch || (ch == " " && before.text.last == "\u{a0}") else { return }
            let words = before.text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" })
            // Smart quotes aren't corrections: don't and don’t are the same word.
            func plain(_ w: String) -> String { w.lowercased().replacingOccurrences(of: "’", with: "'") }
            guard let now = words.last.map(String.init), !now.isEmpty, plain(now) != plain(typed),
                  !plain(now).hasPrefix(plain(typed)) else { return }
            // The typed word was read from the field after Mail had corrected it: already said as corrected.
            if let said = Speech.lastTypedWordSpoken, plain(said) == plain(now) { return }
            Log.io("autocorrect: a word was changed (\(typed.count) to \(now.count) characters)")
            Speech.speakMessage(String(localized: "corrected to \(now)", comment: "Mail corrected a typed word: %@ is the new word"))
        }
    }
}

/// Which messages near the selection were unread, by sender, subject and time.
enum MailUnread {
    nonisolated(unsafe) private static var unread = Set<String>()   // under `lock`
    nonisolated private static let lock = NSLock()
    private static let queue = DispatchQueue(label: "turnover.mail.unread")

    nonisolated static func key(_ row: AXUIElement) -> String {
        let cell = row.elements(kAXChildrenAttribute).first ?? row
        // The texts (sender, subject, time); the images before them come and go (unread, replied).
        return cell.elements(kAXChildrenAttribute).lazy.compactMap { $0.string(kAXValueAttribute) }.prefix(3).joined(separator: "|")
    }

    static func wasUnread(_ row: AXUIElement) -> Bool {
        let k = key(row)
        lock.lock(); defer { lock.unlock() }
        return !k.isEmpty && unread.contains(k)
    }

    /// The first row and the rows either side of the selection.
    static func snapshot(_ table: AXUIElement) {
        queue.async {
            let rows = table.elements(kAXRowsAttribute)
            guard !rows.isEmpty else { return }
            let selected = table.elements(kAXSelectedRowsAttribute).first.flatMap { s in rows.firstIndex(where: { $0.isSame(s) }) }
            var indices: Set<Int> = [0]
            if let i = selected { indices.formUnion([i - 1, i + 1].filter { rows.indices.contains($0) }) }
            for i in indices {
                let k = key(rows[i])
                guard !k.isEmpty else { continue }
                let isUnread = MailMessageRow.isUnread(rows[i])
                lock.lock(); if isUnread { unread.insert(k) } else if i != selected { unread.remove(k) }; lock.unlock()
                if isUnread { Log.io("mail: row \(i) is unread") }
            }
            // The row just read is read now.
            if let i = selected, !MailMessageRow.isUnread(rows[i]) {
                let k = key(rows[i]); lock.lock(); unread.remove(k); lock.unlock()
            }
        }
    }
}
