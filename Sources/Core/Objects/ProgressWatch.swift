// SPDX-License-Identifier: GPL-3.0-or-later
// A progress bar's news: once TurnOver has read a progress bar (by the focus, or moving to it), its climb is beeped or
// said (ProgressOutput, NVDA+U) while its app is in front, as NVDA reports progress bars (18 Oct 2026: an installer's
// download bar was read once, as "0.9", and never again). One bar at a time, for up to half an hour; it stops when the
// bar goes away, climbs to 100, or Progress bars is turned off.
import AppKit
import ApplicationServices

enum ProgressWatch {
    private static var watched: AXUIElement?
    private static var pid: pid_t = 0
    private static var output = ProgressOutput(at: 0)
    private static var timer: Timer?
    private static var since = Date()
    private static var lastLook = Date.distantPast

    /// The bar just read: watched from here (the percentage just said counts as said).
    static func watch(_ obj: TurnOverObject) {
        guard obj.role == .progressBar, config.presentation.progressBars != "off", let p = percent(of: obj.element) else { return }
        if let w = watched, w.isSame(obj.element) { return }
        watched = obj.element; pid = obj.pid; output = ProgressOutput(at: p); since = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
        Log.io("progress: watching a progress bar")
    }

    /// The watched bar's own AXValueChanged, while it beeps: looked at once (at most every 50 ms), so the beeps keep up
    /// with a fast bar between the once-a-second looks. Speak alone keeps to those looks, as before beeps: a fast bar
    /// queued a percentage for every ten (a review, 2 Nov 2026). Nothing while a script runs (its pump delivers
    /// notifications in the middle of it) or while the bar's app is behind.
    static func valueChanged(_ e: AXUIElement) {
        guard let w = watched, w.isSame(e) else { return }
        // A page's bar read again says its value now, not the one from when the page was made: made again at the next
        // move (a review, 2 Nov 2026).
        API.focusTreeInterceptor?.buffer.isDirty = true
        guard ProgressOutput.beeps, !ScriptHandler.isScriptRunning,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, Core.active, Date().timeIntervalSince(lastLook) >= 0.05 else { return }
        tick()
    }

    private static func tick() {
        lastLook = Date()
        guard config.presentation.progressBars != "off", let e = watched, Date().timeIntervalSince(since) < 1800, let p = percent(of: e) else { stop(); return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, Core.active else { return }
        if output.update(p) { stop() }
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
