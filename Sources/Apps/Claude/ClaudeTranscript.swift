// SPDX-License-Identifier: GPL-3.0-or-later
// The Claude desktop app's conversation, read through accessibility.
//
// Measured 1 Oct 2026 (Claude for Mac, Electron): the transcript is the group
// described "Chat messages" inside the claude.ai web area. Each user message and
// the first part of each reply is an article ("Message 105", or "Currently
// streaming message" while it streams) holding a hidden heading, "You said: …"
// or "Claude responded: …". The rest of a reply follows as sibling rows: text,
// lists, tables, tool calls ("Ran 3 commands", a button) and a "Message actions"
// toolbar. Before "Chat messages" sit hidden polite live regions; the first says
// "Claude is responding" while a reply streams. Only messages near the end are
// rendered; earlier ones load as the view scrolls.
import Foundation
import ApplicationServices

public enum ClaudeTranscript {
    public static let bundleID = "com.anthropic.claudefordesktop"

    /// The "Chat messages" group of the front window.
    public static func chat(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        guard let window = app.element(kAXFocusedWindowAttribute) ?? app.elements(kAXWindowsAttribute).first else { return nil }
        var queue = [window]
        var visited = 0
        while !queue.isEmpty, visited < 3000 {
            let e = queue.removeFirst(); visited += 1
            if e.string(kAXDescriptionAttribute) == "Chat messages" { return e }
            queue.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
        return nil
    }

    /// The hidden status regions before the transcript ("Claude is responding").
    public static func status(chat: AXUIElement) -> String {
        guard let parent = chat.element(kAXParentAttribute) else { return "" }
        var parts: [String] = []
        for c in parent.elements(kAXChildrenAttribute) {
            if c.isSame(chat) { break }
            if let live = c.string("AXARIALive"), live != "off" { let t = text(of: c, skipHidden: false); if !t.isEmpty { parts.append(t) } }
        }
        return parts.joined(separator: ". ")
    }

    public static func isResponding(chat: AXUIElement) -> Bool {
        status(chat: chat).lowercased().contains("is responding")
            || rows(chat: chat).suffix(8).contains(where: containsStreaming)
    }

    private static func containsStreaming(_ row: AXUIElement) -> Bool {
        var queue = [row]; var n = 0
        while !queue.isEmpty, n < 40 {
            let e = queue.removeFirst(); n += 1
            if e.string(kAXDescriptionAttribute) == "Currently streaming message" { return true }
            queue.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
        return false
    }

    /// The rows of the transcript: the children of its one content group.
    static func rows(chat: AXUIElement) -> [AXUIElement] {
        let kids = chat.elements(kAXChildrenAttribute)
        // An instruction line ("Use the up and down arrow keys…"), then the group holding the rows.
        if let holder = kids.last(where: { !$0.elements(kAXChildrenAttribute).isEmpty }), holder.elements(kAXChildrenAttribute).count > 1 { return holder.elements(kAXChildrenAttribute) }
        return kids
    }

    /// Whether a row holds the user's own message (its article's hidden heading starts "You said").
    static func isUserRow(_ row: AXUIElement) -> Bool {
        var queue = [row]; var n = 0
        while !queue.isEmpty, n < 30 {
            let e = queue.removeFirst(); n += 1
            if e.role == "AXHeading" { return text(of: e, skipHidden: false).hasPrefix("You said") }
            queue.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
        return false
    }

    /// The latest reply: every row after the user's last message, as reading text.
    public static func latestReply(chat: AXUIElement) -> String {
        let all = rows(chat: chat)
        guard let lastUser = all.lastIndex(where: isUserRow) else { return "" }
        var paragraphs: [String] = []
        for row in all[(lastUser + 1)...] {
            for p in paragraphsOf(row) where paragraphs.last != p { paragraphs.append(p) }
        }
        // The streaming footer: elapsed time and tokens ("3m 14s·5.1k tokens··"), "Running tools…", "Thinking…".
        let noise = paragraphs.filter { p in
            p.contains("tokens") && p.contains("·") || ["Running tools…", "Thinking…", "Running tools...", "Thinking..."].contains(p)
        }
        return paragraphs.filter { !noise.contains($0) }.joined(separator: "\n")
    }

    /// A row's text as paragraphs, in reading order: hidden headings, toolbars and tool-call buttons left out.
    static func paragraphsOf(_ row: AXUIElement) -> [String] {
        var out: [String] = []
        var current = ""
        func flush() { let t = current.trimmingCharacters(in: .whitespacesAndNewlines); if !t.isEmpty { out.append(t) }; current = "" }
        var budget = 3000
        func walk(_ e: AXUIElement) {
            guard budget > 0 else { return }
            budget -= 1
            let r = e.role
            if r == "AXToolbar" || r == "AXButton" || r == "AXCheckBox" || r == "AXPopUpButton" { return }
            if r == "AXHeading", (e.attr("AXDOMClassList") as? [String] ?? []).contains("sr-only") { return }
            if r == "AXStaticText" { current += e.string(kAXValueAttribute) ?? ""; return }
            let block = ["AXGroup", "AXHeading", "AXList", "AXRow", "AXTable", "AXCell"].contains(r)
            if block && r != "AXCell" { flush() }
            if r == "AXListMarker" { current += (e.string(kAXValueAttribute) ?? "") + " "; return }
            if r == "AXTable" {
                // A table reads row by row, cells joined.
                for tr in e.elements(kAXRowsAttribute) {
                    let cells = tr.elements(kAXChildrenAttribute).map { text(of: $0, skipHidden: true) }.filter { !$0.isEmpty }
                    if !cells.isEmpty { out.append(cells.joined(separator: ", ")) }
                }
                return
            }
            for c in e.elements(kAXChildrenAttribute) { walk(c) }
            if block { flush() } else if r == "AXCell" { current += ", " }
        }
        walk(row)
        flush()
        return out
    }

    /// All the text inside an element, in order.
    nonisolated public static func text(of e: AXUIElement, skipHidden: Bool) -> String {
        var parts: [String] = []
        var budget = 2000
        func walk(_ x: AXUIElement) {
            guard budget > 0 else { return }
            budget -= 1
            if x.role == "AXStaticText" { if let v = x.string(kAXValueAttribute), !v.isEmpty { parts.append(v) }; return }
            if skipHidden, x.role == "AXHeading", (x.attr("AXDOMClassList") as? [String] ?? []).contains("sr-only") { return }
            for c in x.elements(kAXChildrenAttribute) { walk(c) }
        }
        walk(e)
        return parts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
