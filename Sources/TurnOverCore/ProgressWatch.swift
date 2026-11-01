// SPDX-License-Identifier: GPL-3.0-or-later
// A progress bar's news: once TurnOver has read a progress bar (by the focus, or moving to it), its percentage is said
// as it climbs, every 10 percent and at the end, while its app is in front, as NVDA reports progress bars (// 18 Oct 2026: an installer's download bar was read once, as "0.9", and never again). One bar at a time, for up to
// half an hour; it stops when the bar goes away.
import AppKit
import ApplicationServices

enum ProgressWatch {
    private static var watched: AXUIElement?
    private static var pid: pid_t = 0
    private static var lastSaid = -1
    private static var timer: Timer?
    private static var since = Date()

    /// The bar just read: watched from here (the percentage just said counts as said).
    static func watch(_ obj: TurnOverObject) {
        guard obj.role == .progressBar, let p = percent(of: obj.element) else { return }
        if let w = watched, w.isSame(obj.element) { return }
        watched = obj.element; pid = obj.pid; lastSaid = p; since = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
        Log.io("progress: watching a progress bar")
    }

    private static func tick() {
        guard let e = watched, Date().timeIntervalSince(since) < 1800, let p = percent(of: e) else { stop(); return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, Core.active else { return }
        if p >= 100, lastSaid < 100 { lastSaid = 100; Speech.speakMessage(String(localized: "100 percent", comment: "Spoken message")); stop(); return }
        if p / 10 != lastSaid / 10 { lastSaid = p; Speech.speakMessage(Phrases.percent(p)) }
    }

    private static func stop() { timer?.invalidate(); timer = nil; watched = nil }

    /// The bar's place in its range, 0 to 100; nil once it's gone.
    private static func percent(of e: AXUIElement) -> Int? {
        guard let n = e.attr(kAXValueAttribute) as? NSNumber else { return nil }
        let lo = (e.attr(kAXMinValueAttribute) as? NSNumber)?.doubleValue ?? 0
        let hi = (e.attr(kAXMaxValueAttribute) as? NSNumber)?.doubleValue ?? (n.doubleValue <= 1 ? 1 : 100)
        guard hi > lo else { return nil }
        // Clamped as a Double first: a page's ARIA values can be huge or NaN, and Int() of those traps (code review, 20 Oct 2026).
        let percent = (n.doubleValue - lo) / (hi - lo) * 100
        guard percent.isFinite else { return nil }
        return Int(max(0, min(100, percent)).rounded())
    }
}
