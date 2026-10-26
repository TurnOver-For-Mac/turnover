// SPDX-License-Identifier: GPL-3.0-or-later
// Screen recognition (NVDA: NVDA+R, contentRecog and recogUi; VOCR on the Mac): TurnOver+R reads the front window's
// pixels with Apple's text recognition and opens what it found as a document to move through, as NVDA's result is.
// For what accessibility leaves out: an app that draws its own controls (games, Steam, Java and Qt apps, a video,
// a picture of text, a remote desktop).
//
// Keys while the result is open (TurnOver's own key handling has them, as its menu does; the app keeps its focus):
//   Up, Down                   rows of text, top to bottom (text side by side on screen is one row, left to right)
//   Left, Right                characters; with Option or Control, words
//   Home, End                  start and end of the row; with Command or Control, the top and the bottom
//   Tab, Shift Tab             the next and previous block: a column or section (the sidebar, the main text)
//   Return or Space            clicks the word at the cursor, then puts the mouse back (NVDA: activatePosition)
//   Shift Return               right-clicks it; Option Return double-clicks it
//   M                          moves the mouse there and leaves it (for a tooltip or a menu that opens on hover)
//   TurnOver Down, TurnOver A  reads from here to the end
//   TurnOver R                 recognises again, staying where you were
//   Escape                     closes the result
// A Command key closes it and goes to the app as usual. After a click the result closes; TurnOver R reads again.
//
// Reading order: Vision gives lines of text with their boxes; layout() puts them in the order a page is read,
// columns one after another, rows that line up (a list, a table) left to right, pieces two spaces apart. Each word keeps its box, so a click lands
// on the middle of the word, in screen points.
import Foundation
import AppKit
import ApplicationServices
import Vision
import ScreenCaptureKit

public final class ScreenRecognition {
    public static let shared = ScreenRecognition()
    /// Read on the keyboard thread as well; written here, on the main thread.
    private let _isOpen = Locked(false)
    public private(set) var isOpen: Bool { get { _isOpen.value } set { _isOpen.value = newValue } }
    /// Called once when the result closes, or when recognition ends with nothing to show (MenuAnywhere hands the
    /// lead back to VoiceOver then).
    public var onClose: (() -> Void)?
    private func finished() { let c = onClose; onClose = nil; c?() }

    // MARK: The result

    nonisolated public struct Word: @unchecked Sendable { public let range: NSRange; public let rect: CGRect }
    nonisolated public struct Item: @unchecked Sendable { public let range: NSRange; public let rect: CGRect; public let words: [Word] }
    nonisolated public struct Row: @unchecked Sendable { public let range: NSRange; public let items: [Item]; public let block: Int }
    nonisolated public struct Result: @unchecked Sendable {
        public let text: NSString
        public let rows: [Row]
        public let title: String
        public let pid: pid_t
        public let window: CGRect
        public var items: [Item] { rows.flatMap { $0.items } }
    }

    private var result: Result?
    private var caret = 0
    private var working = false
    private var refreshTimer: Timer?

    // MARK: Opening

    /// TurnOver+R: recognise the front window. While the result is open: recognise again, keeping the place.
    public func recognize() {
        guard !working else { Speech.speakMessage(String(localized: "still recognising", comment: "Spoken message")); return }
        guard ScreenCapturePermission.ensure() else { finished(); return }
        let reopen = isOpen
        let keepRow = reopen ? currentRowText() : nil
        guard let target = Self.target() else { Speech.speakMessage(String(localized: "no window to recognise", comment: "Spoken message")); finished(); return }
        working = true
        let started = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            if self?.working == true { Speech.speakMessage(String(localized: "recognising", comment: "Spoken message")) }
        }
        Task.detached(priority: .userInitiated) {
            let outcome = await Self.run(target)
            await MainActor.run {
                self.working = false
                switch outcome {
                case .failure(let message):
                    Log.error("screen recognition: \(message)")
                    Speech.speakMessage(message)
                    if !self.isOpen { self.finished() }
                case .success(let r):
                    self.showingInterface = false
                    Log.io("screen recognition: \(r.rows.count) rows, \(r.items.count) pieces of text, \(r.text.length) characters in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                    self.show(r, reopen: reopen, keepRow: keepRow)
                }
            }
        }
    }

    /// The layer's E (developer switch `flatView`): the window's controls from its pixels (ScreenInterface), opened as
    /// a recognition result whose rows are the controls: "Save, button". Return clicks the control.
    public func recognizeInterface() {
        guard Edition.devDefault("flatView") else { recognize(); return }
        guard #available(macOS 26.0, *) else { Speech.speakMessage("the screen interface needs macOS 26 or later"); return }
        guard !working else { Speech.speakMessage("still recognising"); return }
        guard ScreenCapturePermission.ensure() else { finished(); return }
        guard let target = Self.target() else { Speech.speakMessage("no window to recognise"); finished(); return }
        working = true
        let started = Date()
        Speech.speakMessage("reading the screen's controls")
        Task.detached(priority: .userInitiated) {
            let image: CGImage
            do { image = try await Self.capture(target) } catch {
                await MainActor.run { self.working = false; Speech.speakMessage("could not see the window"); if !self.isOpen { self.finished() } }
                return
            }
            let d = await ScreenInterface.detect(image, frame: target.frame)
            let r = Self.interfaceResult(d.elements, title: target.title, pid: target.pid, window: target.frame)
            await MainActor.run {
                self.working = false
                Log.io("screen interface: \(d.elements.count) elements in \(Int(Date().timeIntervalSince(started) * 1000)) ms (\(d.note))")
                for e in d.elements.prefix(60) { Log.io("screen interface:   \(e.kind.rawValue) \"\(Log.words(e.label.prefix(40).description))\" at \(Int(e.rect.midX)),\(Int(e.rect.midY)) (\(e.from))") }
                self.showingInterface = true
                self.show(r, reopen: false, keepRow: nil)
            }
        }
    }

    /// The controls as rows: one each, "label, kind", the whole row clickable at the control's centre.
    @available(macOS 26.0, *)
    nonisolated static func interfaceResult(_ elements: [ScreenInterface.Element], title: String, pid: pid_t, window: CGRect) -> Result {
        let text = NSMutableString()
        var rows: [Row] = []
        for e in elements {
            let label = e.label.isEmpty ? (e.kind == .icon ? "icon" : e.kind.rawValue) : e.label
            let spoken = e.kind.spoken.isEmpty || e.label.isEmpty ? label : "\(label), \(e.kind.spoken)"
            let start = text.length
            text.append(spoken); text.append("\n")
            let labelRange = NSRange(location: start, length: (label as NSString).length)
            let word = Word(range: labelRange, rect: e.rect)
            let item = Item(range: NSRange(location: start, length: (spoken as NSString).length), rect: e.rect, words: [word])
            rows.append(Row(range: NSRange(location: start, length: (spoken as NSString).length + 1), items: [item], block: 0))
        }
        return Result(text: text, rows: rows, title: title, pid: pid, window: window)
    }

    private func show(_ r: Result, reopen: Bool, keepRow: String?) {
        guard r.text.length > 0 else {
            if !reopen { Speech.speakMessage(String(localized: "no text found", comment: "Spoken message")); finished() } else { Speech.speakMessage(String(localized: "no text now", comment: "Spoken message")) }
            return
        }
        result = r
        isOpen = true
        if let keepRow, let row = r.rows.first(where: { r.text.substring(with: $0.range) == keepRow }) {
            caret = row.range.location
            Speech.speakMessage(String(localized: "recognised again", comment: "Spoken message"))
        } else {
            caret = 0
            let rows = r.rows.count
            let count = rows == 1 ? String(localized: "1 row", comment: "A table's size") : String(localized: "\(String(rows)) rows", comment: "A table's size")
            Speech.speakMessage(reopen ? String(localized: "recognised again, \(count)", comment: "Screen recognition again: how many rows") : "\(r.title.isEmpty ? "" : r.title + ", ")" + String(localized: "recognised text, \(count)", comment: "Screen recognition: how many rows"))
        }
        if config.recognition.autoSayAll, keepRow == nil { sayAll() } else { speakRow() }
        Braille.modalLine = { [weak self] in self?.brailleLine() }
        Braille.modalKey = { [weak self] key in self?.brailleKey(key) }
        Braille.refreshSoon()
        startRefreshing()
    }

    public func close(silently: Bool = false) {
        guard isOpen else { return }
        isOpen = false
        refreshTimer?.invalidate(); refreshTimer = nil
        Braille.modalLine = nil; Braille.modalKey = nil
        Braille.refreshSoon()
        if !silently { Speech.speakMessage(String(localized: "closed recognition", comment: "Spoken message")) }
        finished()
        result = nil   // the screen's text isn't kept once the view is closed (code review, 14 Oct 2026)
    }

    // MARK: Keys

    /// Every key while the result is open (InputManager routes them here, on the main thread).
    public func handle(_ g: KeyboardGesture) {
        guard let r = result else { close(silently: true); return }
        let m = g.modifiers
        let word = m.contains(.option) || m.contains(.control)
        let whole = m.contains(.command) || m.contains(.control)
        SayAll.stop(byGesture: true)
        switch g.keyName {
        case "escape":
            close()
        case "upArrow", "downArrow":
            let down = g.keyName == "downArrow"
            if whole { caret = down ? max(0, r.text.length - 1) : 0; speakRow(); break }
            guard let i = rowIndex(caret) else { return }
            let j = i + (down ? 1 : -1)
            guard r.rows.indices.contains(j) else { Tones.edge(); speakRow(); return }
            caret = r.rows[j].range.location
            speakRow()
        case "leftArrow", "rightArrow":
            let forward = g.keyName == "rightArrow"
            if word { moveWord(forward) } else { moveCharacter(forward) }
        case "home", "end":
            if whole { caret = g.keyName == "home" ? 0 : max(0, r.text.length - 1); speakRow(); break }
            guard let row = rowIndex(caret).map({ r.rows[$0] }) else { return }
            caret = g.keyName == "home" ? row.range.location : max(row.range.location, NSMaxRange(row.range) - 1)
            speakCharacter()
        case "tab":
            // The next or previous block: a column or section of the window (the sidebar, the main text).
            guard let i = rowIndex(caret) else { return }
            let back = m.contains(.shift)
            let block = r.rows[i].block
            let target: Int? = back
                ? (r.rows.firstIndex { $0.block == block } != i ? r.rows.firstIndex { $0.block == block } : r.rows.firstIndex { $0.block == block - 1 })
                : r.rows.firstIndex { $0.block > block }
            guard let j = target else { Tones.edge(); return }
            caret = r.rows[j].range.location
            speakRow()
        case "enter", "numpadEnter", "space":
            click(m.contains(.shift) ? .right : m.contains(.option) ? .double : .left)
        case "m" where m.isEmpty:
            click(.hover)
        case "a" where m.contains(.turnover), "downArrow" where m.contains(.turnover):
            sayAll()
        case "r" where m.contains(.turnover):
            recognize()
        default:
            if m.contains(.turnover) { return }   // TurnOver's other keys: nothing here
            Tones.edge()
        }
        Braille.refreshSoon()
    }

    // MARK: Moving

    private func rowIndex(_ offset: Int) -> Int? {
        guard let r = result else { return nil }
        return r.rows.firstIndex { offset >= $0.range.location && offset <= NSMaxRange($0.range) } ?? (r.rows.isEmpty ? nil : r.rows.count - 1)
    }

    private func currentRowText() -> String? {
        guard let r = result, let i = rowIndex(caret) else { return nil }
        return r.text.substring(with: r.rows[i].range)
    }

    private func speakRow() {
        guard let r = result, let i = rowIndex(caret) else { return }
        let t = r.text.substring(with: r.rows[i].range)
        Speech.speakText(t.trimmingCharacters(in: .whitespaces).isEmpty ? Phrases.blank : t)
    }

    private func speakCharacter() {
        guard let r = result else { return }
        guard caret < r.text.length else { Speech.speakMessage(String(localized: "blank", comment: "Spoken message")); return }
        let c = r.text.substring(with: r.text.rangeOfComposedCharacterSequence(at: caret))
        if c == "\n" { Speech.speakMessage(String(localized: "line break", comment: "Spoken message")) } else { Speech.speakSpelling(c) }
    }

    private func moveCharacter(_ forward: Bool) {
        guard let r = result else { return }
        if forward {
            let next = NSMaxRange(r.text.rangeOfComposedCharacterSequence(at: min(caret, r.text.length - 1)))
            guard next < r.text.length else { Tones.edge(); speakCharacter(); return }
            let crossed = rowIndex(next) != rowIndex(caret)
            caret = next
            if crossed { speakRow() } else { speakCharacter() }
        } else {
            guard caret > 0 else { Tones.edge(); speakCharacter(); return }
            let prev = r.text.rangeOfComposedCharacterSequence(at: caret - 1).location
            let crossed = rowIndex(prev) != rowIndex(caret)
            caret = prev
            if crossed { speakRow() } else { speakCharacter() }
        }
    }

    private func allWords() -> [Word] { result?.items.flatMap { $0.words } ?? [] }

    private func moveWord(_ forward: Bool) {
        guard let r = result else { return }
        let words = allWords()
        let j: Int?
        if forward { j = words.firstIndex { $0.range.location > caret } }
        else { j = words.lastIndex { $0.range.location < caret && !NSLocationInRange(caret, $0.range) } ?? words.lastIndex { $0.range.location < caret } }
        guard let j else { Tones.edge(); return }
        caret = words[j].range.location
        Speech.speakText(r.text.substring(with: words[j].range))
    }

    private func sayAll() {
        guard let r = result else { return }
        let rest = r.text.substring(from: min(caret, r.text.length))
        Speech.speakText(rest)
    }

    // MARK: Clicking

    enum Click { case left, right, double, hover }

    /// The word at the cursor (or its piece of text, or the nearest word), in screen points.
    private func targetRect() -> CGRect? {
        guard let r = result else { return nil }
        let words = allWords()
        if let w = words.first(where: { NSLocationInRange(caret, $0.range) }) { return w.rect }
        if let it = r.items.first(where: { NSLocationInRange(caret, $0.range) }) { return it.rect }
        return words.min { abs($0.range.location - caret) < abs($1.range.location - caret) }?.rect
    }

    private func click(_ kind: Click) {
        guard let r = result, let rect = targetRect() else { Speech.speakMessage(String(localized: "nothing to click", comment: "Spoken message")); return }
        let point = CGPoint(x: rect.midX, y: rect.midY)
        // The window must still be where it was read: a click elsewhere would land on something else.
        if let now = Self.windowFrame(pid: r.pid), abs(now.minX - r.window.minX) > 4 || abs(now.minY - r.window.minY) > 4 {
            Speech.speakMessage(String(localized: "the window has moved; recognising again", comment: "Spoken message"))
            recognize(); return
        }
        Log.io("screen recognition: \(kind) at \(Int(point.x)), \(Int(point.y))")
        NSRunningApplication(processIdentifier: r.pid)?.activate()
        let home = CGEvent(source: nil)?.location
        Mouse.move(to: point)
        switch kind {
        case .hover:
            Speech.speakMessage(String(localized: "mouse moved here", comment: "Spoken message"))
            return
        case .left: Mouse.click(at: point, button: .left, count: 1)
        case .double: Mouse.click(at: point, button: .left, count: 2)
        case .right: Mouse.click(at: point, button: .right, count: 1)
        }
        // NVDA puts the mouse back after the click; a right-click's menu stays where it opened.
        if kind != .right, let home { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { Mouse.move(to: home) } }
        Speech.speakMessage(kind == .right ? String(localized: "right clicked", comment: "Spoken message") : kind == .double ? String(localized: "double clicked", comment: "Spoken message") : String(localized: "clicked", comment: "Spoken message"))
        // The screen changes after a click: the result is out of date. Recognised again after a moment (the setting;
        // the screen interface again where that was open), else TurnOver follows the app's focus from here.
        // (Developer builds only: a feature for a whole build. A setting saved as on by an earlier build is not
        // honoured in a public one, where its toggle is hidden; a code review, 29 Oct 2026.)
        if Edition.isDevBuild, config.recognition.refreshAfterClick, kind != .right {
            let interface = showingInterface
            close(silently: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self, !self.isOpen, !self.working else { return }
                if interface { self.recognizeInterface() } else { self.recognize() }
            }
            return
        }
        close(silently: true)
    }
    /// The result open is the screen interface's (controls), not plain text: recognised again the same way.
    private var showingInterface = false

    // MARK: Refreshing while open (NVDA: "periodically refresh recognized content")

    private func startRefreshing() {
        refreshTimer?.invalidate(); refreshTimer = nil
        guard config.recognition.autoRefresh else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshQuietly() } }
    }

    /// Recognise again without a word; speak only the rows that are new.
    private func refreshQuietly() {
        guard isOpen, !working, let old = result, let target = Self.target(pid: old.pid) else { return }
        working = true
        Task.detached(priority: .utility) {
            let outcome = await Self.run(target)
            await MainActor.run {
                self.working = false
                guard self.isOpen, case .success(let r) = outcome, r.text.length > 0 else { return }
                let before = Set(old.rows.map { old.text.substring(with: $0.range) })
                // NVDA's live text: new rows only, and not a row that changed by one character (a clock's seconds).
                let fresh = r.rows.map { r.text.substring(with: $0.range) }.filter { row in
                    !before.contains(row) && !row.trimmingCharacters(in: .whitespaces).isEmpty && !before.contains { Self.oneCharacterApart($0, row) }
                }
                let keep = self.currentRowText()
                self.result = r
                if let keep, let row = r.rows.first(where: { r.text.substring(with: $0.range) == keep }) { self.caret = row.range.location }
                else { self.caret = min(self.caret, max(0, r.text.length - 1)) }
                if !fresh.isEmpty, fresh.count <= 6 { Speech.speakNews(fresh.joined(separator: "\n")) }
                Braille.refreshSoon()
            }
        }
    }

    static func oneCharacterApart(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        if x.count == y.count { return zip(x, y).filter { $0 != $1 }.count <= 1 }
        guard abs(x.count - y.count) == 1 else { return false }
        let (long, short) = x.count > y.count ? (x, y) : (y, x)
        var i = 0
        while i < short.count, long[i] == short[i] { i += 1 }
        return Array(long[(i + 1)...]) == Array(short[i...])
    }

    // MARK: Braille

    private func brailleLine() -> (String, Int?)? {
        guard let r = result, let i = rowIndex(caret) else { return nil }
        let row = r.rows[i]
        return (r.text.substring(with: row.range), caret - row.range.location)
    }

    /// Display keys while open: lines move by row; a routing key moves the cursor there, and pressed again on the
    /// same place clicks it.
    private var lastRouting: (Int, Date)?
    private func brailleKey(_ key: String) {
        if key.hasPrefix("route:"), let cell = Int(key.dropFirst(6)), let r = result, let i = rowIndex(caret) {
            let row = r.rows[i]
            let at = min(row.range.location + cell, max(row.range.location, NSMaxRange(row.range) - 1))
            if let (last, when) = lastRouting, last == at, Date().timeIntervalSince(when) < 2 { lastRouting = nil; caret = at; click(.left); return }
            lastRouting = (at, Date())
            caret = at
            speakCharacter()
            Braille.refreshSoon()
            return
        }
        if let g = KeyboardGesture(identifier: "kb:\(key)") { handle(g) }
    }

    // MARK: Capture and recognition

    /// The first recognition in a new TurnOver takes Vision up to 40 s to get ready (measured 6 Oct 2026; after that,
    /// 0.2 to 0.4 s a window). Done once in the background soon after launch, on a picture with words in it.
    public static func warmUp() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8) {
            let size = NSSize(width: 400, height: 80)
            let image = NSImage(size: size, flipped: false) { r in
                NSColor.white.setFill(); r.fill()
                ("TurnOver reads the screen" as NSString).draw(at: NSPoint(x: 10, y: 25), withAttributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black])
                return true
            }
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let start = Date()
            _ = try? recognizeLines(cg, frame: CGRect(origin: .zero, size: size))
            Log.info("screen recognition ready (\(Int(Date().timeIntervalSince(start) * 1000)) ms)")
        }
    }

    nonisolated public struct Target: @unchecked Sendable { public let pid: pid_t; public let frame: CGRect; public let title: String }

    /// The front app's focused window, in screen points (top left origin, as accessibility and CGEvent use).
    public static func target(pid: pid_t? = nil) -> Target? {
        guard let pid = pid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        guard let w = app.element(kAXFocusedWindowAttribute) ?? app.element(kAXMainWindowAttribute), let f = TurnOverObject.frame(w),
              f.width > 20, f.height > 20 else {
            // No window (a full-screen game): the main display.
            return Target(pid: pid, frame: CGDisplayBounds(CGMainDisplayID()), title: NSRunningApplication(processIdentifier: pid)?.localizedName ?? "")
        }
        return Target(pid: pid, frame: f, title: w.string(kAXTitleAttribute) ?? "")
    }

    static func windowFrame(pid: pid_t) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        return (app.element(kAXFocusedWindowAttribute) ?? app.element(kAXMainWindowAttribute)).flatMap { TurnOverObject.frame($0) }
    }

    public enum Outcome { case success(Result), failure(String) }

    /// Off the main thread, whoever calls it: Vision's recognition can take seconds (14.7 s on 20 Oct 2026), and run on
    /// the main actor (the target's default isolation) it froze TurnOver until the watchdog restarted it, again with
    /// each auto-refresh. The capture and the layout are quick and stay on the main actor.
    @concurrent public nonisolated static func run(_ t: Target) async -> Outcome {
        let image: CGImage
        do { image = try await capture(t) } catch { return .failure("could not see the window: \(error.localizedDescription)") }
        let lines: [(String, CGRect, [(String, CGRect)])]
        let started = Date()
        do { lines = try recognizeLines(image, frame: t.frame) } catch { return .failure("recognition failed: \(error.localizedDescription)") }
        Log.io("screen recognition: Vision took \(Int(Date().timeIntervalSince(started) * 1000)) ms, main thread \(Thread.isMainThread ? "BLOCKED" : "free")")
        return await .success(layout(lines, title: t.title, pid: t.pid, window: t.frame))
    }

    /// The window's pixels at the screen's full resolution, through ScreenCaptureKit (the only way left on macOS 15
    /// and later). The window is found by its owner and frame; failing that, the region of the display it is on.
    static func capture(_ t: Target) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let scale = NSScreen.screens.first { $0.frame.intersects(Self.appKitRect(t.frame)) }?.backingScaleFactor ?? 2
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        let windows = content.windows.filter { $0.owningApplication?.processID == t.pid && $0.isOnScreen && $0.windowLayer == 0 }
        if let w = windows.min(by: { distance($0.frame, t.frame) < distance($1.frame, t.frame) }), distance(w.frame, t.frame) < 40 {
            config.width = Int(w.frame.width * scale); config.height = Int(w.frame.height * scale)
            return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: config)
        }
        // A window ScreenCaptureKit does not list on its own (a game's full-screen surface): that part of the display.
        guard let display = content.displays.first(where: { CGRect(x: CGFloat($0.frame.minX), y: CGFloat($0.frame.minY), width: CGFloat($0.width), height: CGFloat($0.height)).intersects(t.frame) }) ?? content.displays.first else {
            throw NSError(domain: "TurnOver", code: 1, userInfo: [NSLocalizedDescriptionKey: "no display"])
        }
        let local = t.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY).intersection(CGRect(x: 0, y: 0, width: display.frame.width, height: display.frame.height))
        config.sourceRect = local
        config.width = Int(local.width * scale); config.height = Int(local.height * scale)
        // TurnOver's own windows (an alert, the update window) are left out of the picture.
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingApplications: own, exceptingWindows: []), configuration: config)
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat { abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height) }

    /// Screen points with a top left origin to AppKit's bottom left.
    static func appKitRect(_ r: CGRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    /// Vision's lines, each with its words, in screen points. Small text is read better larger: an image under two
    /// pixels a point is doubled first.
    nonisolated static func recognizeLines(_ image: CGImage, frame: CGRect) throws -> [(String, CGRect, [(String, CGRect)])] {
        var img = image
        if CGFloat(image.width) < frame.width * 1.9, let up = scaled(image, by: 2) { img = up }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.minimumTextHeight = 0
        if #available(macOS 14, *) { request.revision = VNRecognizeTextRequestRevision3 }
        let handler = VNImageRequestHandler(cgImage: img, options: [:])
        try handler.perform([request])
        var out: [(String, CGRect, [(String, CGRect)])] = []
        for obs in request.results ?? [] {
            guard let cand = obs.topCandidates(1).first else { continue }
            let s = cand.string
            guard !s.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let lineRect = toScreen(obs.boundingBox, frame)
            var words: [(String, CGRect)] = []
            s.enumerateSubstrings(in: s.startIndex..<s.endIndex, options: .byWords) { w, range, _, _ in
                guard let w else { return }
                if let box = try? cand.boundingBox(for: range) { words.append((w, toScreen(box.boundingBox, frame))) }
            }
            out.append((s, lineRect, words))
        }
        return out
    }

    /// Vision's normalised box (bottom left origin) to screen points in the window.
    nonisolated private static func toScreen(_ r: CGRect, _ frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + r.minX * frame.width, y: frame.minY + (1 - r.maxY) * frame.height, width: r.width * frame.width, height: r.height * frame.height)
    }

    nonisolated private static func scaled(_ image: CGImage, by k: CGFloat) -> CGImage? {
        let w = Int(CGFloat(image.width) * k), h = Int(CGFloat(image.height) * k)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Lines into rows: a line joins a row when they share most of the smaller one's height; rows top to bottom,
    /// each left to right. The text: rows on their own lines, pieces in a row two spaces apart.
    public typealias Line = (String, CGRect, [(String, CGRect)])

    /// Lines into reading order, as a page is read: the window is cut where a gap runs right across it (top to
    /// bottom) or right down it (left to right), again and again (an XY cut). Side-by-side columns (a sidebar, a
    /// chat, a browser pane: VOCR's common complaint is these read as one line) become separate blocks, read one
    /// after the other. A cut down the middle of rows that line up (a list or table: sender and date) is not a column:
    /// those stay rows, read left to right, the pieces two spaces apart.
    public static func layout(_ lines: [Line], title: String, pid: pid_t, window: CGRect) -> Result {
        let heights = lines.map { $0.1.height }.sorted()
        let unit = heights.isEmpty ? 10 : max(6, heights[heights.count / 2])
        var blocks: [[[Line]]] = []
        let gutter = max(unit * 2, 14)
        func order(_ ls: [Line]) {
            guard ls.count > 1 else { if !ls.isEmpty { blocks.append(rows(ls)) }; return }
            // The gaps that run right across this region (between bands of text) and right down it (gutters).
            let byY = ls.sorted { $0.1.minY < $1.1.minY }
            var hCuts: [(Int, CGFloat)] = []; var bottom = byY[0].1.maxY
            for (i, l) in byY.enumerated().dropFirst() { if l.1.minY > bottom { hCuts.append((i, l.1.minY - bottom)) }; bottom = max(bottom, l.1.maxY) }
            let byX = ls.sorted { $0.1.minX < $1.1.minX }
            var vCuts: [(Int, CGFloat)] = []; var right = byX[0].1.maxX
            for (i, l) in byX.enumerated().dropFirst() { if l.1.minX > right { vCuts.append((i, l.1.minX - right)) }; right = max(right, l.1.maxX) }
            let bestH = hCuts.map { $0.1 }.max() ?? 0, bestV = vCuts.map { $0.1 }.max() ?? 0
            // Columns first where a gutter runs the full height: a sidebar, the main text, a side pane.
            if bestV >= gutter, bestV >= bestH {
                let cols = split(byX, at: vCuts.filter { $0.1 >= gutter }.map { $0.0 })
                // Neighbouring columns whose rows line up are one table (Finder's name, date, size and kind); the
                // others (its sidebar) are separate.
                var groups: [[[Line]]] = []
                for col in cols {
                    if let last = groups.last?.last, rowsLineUp([last, col]) { groups[groups.count - 1].append(col) } else { groups.append([col]) }
                }
                if groups.count > 1 {
                    for g in groups { if g.count > 1 { blocks.append(rows(g.flatMap { $0 })) } else { order(g[0]) } }
                    return
                }
                if cols.count > 1, bestH < unit * 0.9 { blocks.append(rows(ls)); return }   // a table: its rows
            }
            // Then sections: a gap of a line or more across the region.
            if bestH >= unit * 0.9 {
                let parts = split(byY, at: hCuts.filter { $0.1 >= unit * 0.9 }.map { $0.0 })
                if parts.count > 1 { parts.forEach(order); return }
            }
            blocks.append(rows(ls))
        }
        func split(_ sorted: [Line], at cuts: [Int]) -> [[Line]] {
            var out: [[Line]] = []; var from = 0
            for c in cuts.sorted() { out.append(Array(sorted[from..<c])); from = c }
            out.append(Array(sorted[from...]))
            return out.filter { !$0.isEmpty }
        }
        /// Columns whose lines sit level with each other, line for line, are a table's cells (sender and date), not
        /// columns: both sides about as many lines, and most lines on each side level with one on the other. A
        /// sidebar beside dense text is not: its few lines always meet some line of the text, but not the reverse.
        func rowsLineUp(_ cols: [[Line]]) -> Bool {
            func level(_ l: Line, _ o: Line) -> Bool { abs(l.1.midY - o.1.midY) < 0.35 * min(l.1.height, o.1.height) + 1 }
            var votes = 0, pairs = 0
            for (x, y) in zip(cols, cols.dropFirst()) {
                pairs += 1
                let (rx, ry) = (rows(x).count, rows(y).count)
                let ratio = Double(min(rx, ry)) / Double(max(rx, ry))
                let a = Double(x.filter { l in y.contains { level(l, $0) } }.count) / Double(x.count)
                let b = Double(y.filter { l in x.contains { level(l, $0) } }.count) / Double(y.count)
                if ratio >= 0.5, a >= 0.6, b >= 0.6 { votes += 1 }
            }
            return pairs > 0 && votes * 2 >= pairs
        }
        /// Lines level with each other are one row, left to right.
        func rows(_ ls: [Line]) -> [[Line]] {
            var out: [[Line]] = []
            for line in ls.sorted(by: { $0.1.midY < $1.1.midY }) {
                if let i = out.indices.last(where: { idx in
                    let band = out[idx].reduce(CGRect.null) { $0.union($1.1) }
                    let overlap = min(band.maxY, line.1.maxY) - max(band.minY, line.1.minY)
                    return overlap > 0.5 * min(band.height, line.1.height)
                }) { out[i].append(line) } else { out.append([line]) }
            }
            return out.map { $0.sorted { $0.1.minX < $1.1.minX } }
        }
        order(lines)

        let text = NSMutableString()
        var outRows: [Row] = []
        for (b, block) in blocks.enumerated() {
            for row in block {
                if text.length > 0 { text.append("\n") }
                let rowStart = text.length
                var items: [Item] = []
                for (k, line) in row.enumerated() {
                    if k > 0 { text.append("  ") }
                    let start = text.length
                    text.append(line.0)
                    let lineNS = line.0 as NSString
                    var words: [Word] = []
                    var from = 0
                    for (w, rect) in line.2 {
                        let r = lineNS.range(of: w, options: .literal, range: NSRange(location: from, length: lineNS.length - from))
                        guard r.location != NSNotFound else { continue }
                        words.append(Word(range: NSRange(location: start + r.location, length: r.length), rect: rect))
                        from = NSMaxRange(r)
                    }
                    items.append(Item(range: NSRange(location: start, length: lineNS.length), rect: line.1, words: words))
                }
                outRows.append(Row(range: NSRange(location: rowStart, length: text.length - rowStart), items: items, block: b))
            }
        }
        return Result(text: text, rows: outRows, title: title, pid: pid, window: window)
    }
}

// MARK: The mouse

public enum Mouse {
    public static func move(to p: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    /// As a hand clicks: the pointer there first and a moment to be noticed, then the button held for a moment. A
    /// 12 ms tap straight after the move was ignored by Bambu Studio's dialog (wxWidgets), while a click with 80 ms
    /// before it and 60 ms held pressed its OK (28 Oct 2026).
    public static func click(at p: CGPoint, button: CGMouseButton, count: Int) {
        let (down, up): (CGEventType, CGEventType) = button == .right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
        move(to: p)
        usleep(80_000)
        for n in 1...max(1, count) {
            for type in [down, up] {
                guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { continue }
                e.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                e.post(tap: .cghidEventTap)
                usleep(type == down ? 60_000 : 40_000)
            }
        }
    }
}

// MARK: Screen Recording

/// Seeing the screen needs Screen Recording. The first time, macOS lists TurnOver there; TurnOver says what to do
/// and opens the pane (it is the user's to switch on).
public enum ScreenCapturePermission {
    private static var asked = false
    public static func ensure() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if !asked { asked = true; _ = CGRequestScreenCaptureAccess() }
        Speech.speakMessage(String(localized: "TurnOver needs Screen Recording to read the screen. Opening Privacy and Security, Screen and System Audio Recording: switch on TurnOver, then quit and reopen TurnOver.", comment: "Spoken message"))
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSWorkspace.shared.open(url) }
        }
        return false
    }
}
