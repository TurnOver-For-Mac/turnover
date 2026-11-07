// SPDX-License-Identifier: GPL-3.0-or-later
// The welcome pages as little pages you read with the arrows (7 Nov 2026, Oliver: "you should be able to move up and
// down them with cursor keys, more like little web pages"). They were alerts: each page's text was one block, read
// once as the alert opened and hard to go back over. Now each page is a window with its text in a read-only text area
// that has the keyboard, one point a line: Up and Down read it a line at a time, under VoiceOver (which reads the
// welcome, before TurnOver takes over) or TurnOver. Tab reaches the buttons; Return is Next, Escape is Skip.
import AppKit
import TurnOverCore

@MainActor
final class WelcomeWindow: NSObject, NSWindowDelegate {
    private let pages: [(String, String)]
    private var index = 0
    private let window: NSWindow
    private let text = NSTextView()
    private let next = NSButton(), back = NSButton(), skip = NSButton()
    private var openGuide = false

    /// Shows the pages, one window, until Done, Skip, Escape or the window is closed. Returns when finished.
    static func run(_ pages: [(String, String)]) {
        guard !pages.isEmpty else { return }
        let w = WelcomeWindow(pages: pages)
        w.show(0)
        NSApp.runModal(for: w.window)
        w.window.orderOut(nil)
        if w.openGuide, let guide = Bundle.main.url(forResource: Edition.guideName, withExtension: "txt") { NSWorkspace.shared.open(guide) }
    }

    private init(pages: [(String, String)]) {
        self.pages = pages
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.delegate = self
        window.isReleasedWhenClosed = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        text.isEditable = false
        text.isSelectable = true   // the caret, so the arrows move and the reader reads each line
        text.font = .systemFont(ofSize: 16)
        text.textContainerInset = NSSize(width: 16, height: 16)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text

        for (b, sel) in [(next, #selector(nextPressed)), (back, #selector(backPressed)), (skip, #selector(skipPressed))] {
            b.bezelStyle = .rounded; b.target = self; b.action = sel
        }
        next.keyEquivalent = "\r"
        skip.keyEquivalent = "\u{1b}"
        back.title = String(localized: "Back", comment: "A welcome page's button")

        let buttons = NSStackView(views: [back, skip, next])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        let column = NSStackView(views: [scroll, buttons])
        column.orientation = .vertical
        column.alignment = .trailing
        column.spacing = 12
        column.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 16, right: 16)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = column
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: column.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        window.center()
    }

    /// Page `i`: its title as the window's and the text's first line, the points one a line beneath, the caret at
    /// the start, and the reader told the page changed.
    private func show(_ i: Int) {
        index = i
        let (title, body) = pages[i]
        let last = i == pages.count - 1
        let heading = title + " (" + Phrases.position(i + 1, of: pages.count) + ")"
        window.title = heading
        text.string = heading + "\n\n" + body
        text.setSelectedRange(NSRange(location: 0, length: 0))
        text.scrollRangeToVisible(NSRange(location: 0, length: 0))
        text.setAccessibilityLabel(title)
        next.title = last ? String(localized: "Done", comment: "A welcome page's button") : String(localized: "Next", comment: "A welcome page's button")
        skip.title = last ? String(localized: "Read the guide", comment: "A welcome page's button") : String(localized: "Skip", comment: "A welcome page's button")
        back.isHidden = i == 0
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(text)
        // A new page in the same window: say its title, as a new web page's would be.
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: heading, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    @objc private func nextPressed() {
        if index == pages.count - 1 { NSApp.stopModal(); return }
        show(index + 1)
    }
    @objc private func backPressed() { if index > 0 { show(index - 1) } }
    @objc private func skipPressed() {
        // On the last page this button reads the guide (by its place, as before).
        openGuide = index == pages.count - 1
        NSApp.stopModal()
    }
    func windowWillClose(_ notification: Notification) { NSApp.stopModal() }
}
