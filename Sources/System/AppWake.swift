// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import ApplicationServices

/// Waking an application's accessibility. Word started cold (a document opened from Finder or Spotlight) builds no
/// page for accessibility until it becomes the active application again: the focus sat in its sidebar, the page had
/// no text area, and TurnOver could read nothing (5 Oct 2026). Switching to another app and back built it,
/// with VoiceOver off throughout, so it is the activation itself, which a cold start misses.
///
/// TurnOver makes that switch invisibly: it makes its own (windowless, menu-bar) process frontmost for a moment and
/// the application frontmost again. The lead watcher ignores both activations, so VoiceOver is not woken by it.
public enum AppWake {
    /// Until when activations are TurnOver's own nudge, not the user's (main thread).
    public static var nudgingUntil = Date.distantPast
    private static var lastNudge: [pid_t: Date] = [:]

    /// Once per application every 30 s at most (`minimumGap`: Steam's menu asks more often, 14 Oct 2026).
    public static func nudge(pid: pid_t, reason: String, minimumGap: TimeInterval = 30, then: (@MainActor () -> Void)? = nil) {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
        if let last = lastNudge[pid], Date().timeIntervalSince(last) < minimumGap { return }
        lastNudge[pid] = Date()
        Log.io("wake: \(app.localizedName ?? "pid \(pid)") (\(reason)); switching to TurnOver and back")
        nudgingUntil = Date().addingTimeInterval(5)
        // Off the main thread: the app answers slowly while it builds what it held back (Word took 3 s), and
        // TurnOver must go on speaking meanwhile.
        DispatchQueue.global(qos: .userInitiated).async {
            _ = AXUIElementSetAttributeValue(AXUIElementCreateApplication(getpid()), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            usleep(250_000)
            let target = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(target, 4)
            _ = AXUIElementSetAttributeValue(target, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            DispatchQueue.main.async {
                app.activate()
                nudgingUntil = Date().addingTimeInterval(0.8)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    Log.io("wake: \(front == pid ? "back in \(app.localizedName ?? "the app")" : "the app did not come back (pid \(front ?? -1) in front)")")
                    then?()
                }
            }
        }
    }
}
