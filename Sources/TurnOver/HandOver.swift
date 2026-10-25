// SPDX-License-Identifier: GPL-3.0-or-later
// The hand-over: turning VoiceOver on or off the way the owner does.
//
// Measured 30 Sep 2026 (gate 10): `tell application "VoiceOver" to quit` only
// restarts it (launchd keepalive), and System Events key codes do nothing. What
// works is posting the owner's own toggle shortcut as a HID-level event. The
// shortcut is read from the system's hotkey table (symbolic hotkey 59), so it
// follows whatever the owner has set: the user's VoiceOver toggle.
import Foundation
import AppKit
import CoreGraphics
import TurnOverCore

enum HandOver {
    struct Shortcut { let keyCode: CGKeyCode; let flags: CGEventFlags; let modifierCodes: [CGKeyCode] }

    nonisolated static func toggleShortcut() -> Shortcut {
        // Default is Command F5 (key code 96). As macOS stores it, the modifiers include the function-key bit (1 << 23):
        // a posted F5 without it is not the shortcut, and VoiceOver did not come on (a tester's Mac, 5 Oct 2026).
        var keyCode: CGKeyCode = 96
        var mods = 1 << 20 | 1 << 23
        if let hotkeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys"),
           let entry = hotkeys["59"] as? [String: Any],
           let value = entry["value"] as? [String: Any],
           let params = value["parameters"] as? [Int], params.count == 3 {
            keyCode = CGKeyCode(params[1]); mods = params[2]
        }
        var flags: CGEventFlags = []
        var codes: [CGKeyCode] = []
        if mods & (1 << 17) != 0 { flags.insert(.maskShift); codes.append(56) }
        if mods & (1 << 18) != 0 { flags.insert(.maskControl); codes.append(59) }
        if mods & (1 << 19) != 0 { flags.insert(.maskAlternate); codes.append(58) }
        if mods & (1 << 20) != 0 { flags.insert(.maskCommand); codes.append(55) }
        let functionKeys: Set<CGKeyCode> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]   // F1 to F12
        if mods & (1 << 23) != 0 || functionKeys.contains(keyCode) {
            flags.insert(.maskSecondaryFn)   // a function key (F1 to F12) as the keyboard sends it
        }
        return Shortcut(keyCode: keyCode, flags: flags, modifierCodes: codes)
    }

    /// VoiceOver reading, from any thread, without waiting: toggled on when macOS's flag is off, opened when the flag is
    /// on but VoiceOver isn't running (quit by script, or crashed: the toggle would turn the flag off). Nothing when it
    /// is reading already. Said in the log as `why`. (A code review, 25 Oct 2026: the flag alone left both readers off.)
    /// `waitUpTo`: seconds to wait for VoiceOver's process after opening it, for a caller about to exit (the quit), so
    /// TurnOver doesn't go before VoiceOver has come (the same review). Polled, as turnVoiceOverOn waits.
    nonisolated static func bringVoiceOverBack(_ why: String, waitUpTo: Double = 0) {
        if voiceOverReading { return }
        // Opened, not toggled, whichever way the flag stands: the shortcut can stop working (turnVoiceOverOn), and with
        // the flag on but VoiceOver gone the toggle would turn the flag off.
        Log.info("\(why): \(NSWorkspace.shared.isVoiceOverEnabled ? "VoiceOver's flag is on but it isn't running" : "VoiceOver off"); opening VoiceOver")
        let mine = newChoice()
        openVoiceOver(why)
        // VoiceOver.app failed to bring it: the shortcut, only once VoiceOver is wholly off (flag and process both), so
        // a slow start isn't toggled back off (a code review, 25 Oct 2026). Waited for here when asked, else later.
        // And only if no newer choice of reader came meanwhile: the user turning VoiceOver off in those seconds must not
        // find it turned back on (the same review).
        func fallBack() {
            guard choice.value == mine, !NSWorkspace.shared.isVoiceOverEnabled, !voiceOverRunning else { return }
            Log.error("\(why): VoiceOver.app didn't bring VoiceOver; its shortcut")
            postToggle()
        }
        if waitUpTo > 0 {
            let end = Date().addingTimeInterval(waitUpTo)
            while Date() < end, !voiceOverReading { usleep(100_000) }
            Log.info("\(why): VoiceOver \(voiceOverReading ? "reading" : "still not reading after \(waitUpTo) s")")
            if !voiceOverReading { fallBack() }
        } else {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 3) { fallBack() }
        }
    }

    nonisolated static func postToggle() {
        let s = toggleShortcut()
        let src = CGEventSource(stateID: .hidSystemState)
        func post(_ code: CGKeyCode, _ down: Bool, _ flags: CGEventFlags) {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { return }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: KeyboardHandler.marker)   // not typing: the tap lets it by unspoken
            e.post(tap: .cghidEventTap)
            usleep(20_000)
        }
        for m in s.modifierCodes { post(m, true, s.flags) }
        post(s.keyCode, true, s.flags)
        post(s.keyCode, false, s.flags)
        for m in s.modifierCodes.reversed() { post(m, false, []) }
        Log.info("hand-over: posted toggle shortcut key \(s.keyCode) flags 0x\(String(s.flags.rawValue, radix: 16))")
    }

    /// VoiceOver's process (it stays a moment after the flag goes off, and appears a moment before it comes on).
    nonisolated static var voiceOverRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.VoiceOver").isEmpty }
    /// VoiceOver on and actually reading: macOS's flag alone stays on when VoiceOver was quit by script or crashed (19 Oct
    /// 2026: quit by AppleScript, the flag stayed on, and TurnOver left every app but its own to a VoiceOver not there).
    nonisolated static var voiceOverReading: Bool { NSWorkspace.shared.isVoiceOverEnabled && voiceOverRunning }

    /// Wait (up to `seconds`) until VoiceOver is wholly on or wholly off: the toggle is only safe then. Quitting while
    /// VoiceOver was still shutting down, the toggle could leave it off (3 Oct 2026). Any thread.
    nonisolated static func waitForVoiceOverToSettle(_ seconds: Double = 3) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            let on = NSWorkspace.shared.isVoiceOverEnabled
            if on == voiceOverRunning { return }
            usleep(50_000)
        }
    }

    /// VoiceOver on, safely: never the toggle while VoiceOver is changing, never when it is on; checked after, and
    /// toggled once more only if VoiceOver is wholly off. (Opening VoiceOver.app does not start it, measured.) Any thread.
    nonisolated static func turnVoiceOverOn() {
        waitForVoiceOverToSettle()
        // Reading, not just its flag: the flag alone stays on after VoiceOver crashed (a code review, 25 Oct 2026).
        if voiceOverReading { return }
        // VoiceOver.app opened first, the shortcut only if that fails: on the maintainer's Mac the shortcut (his own,
        // Option Apostrophe) stopped reaching macOS on 23 Oct 2026, by hand as well as from TurnOver, and every
        // hand-back since was silent, while opening VoiceOver.app started it at once (25 Oct 2026; it did on 8 Oct too).
        openVoiceOver("hand-over")
        let end = Date().addingTimeInterval(3)
        while Date() < end {
            if voiceOverReading { Log.info("hand-over: VoiceOver on"); return }
            usleep(50_000)
        }
        // Only when VoiceOver is wholly off: a start that is merely slow must not be toggled back off.
        guard !NSWorkspace.shared.isVoiceOverEnabled, !voiceOverRunning else { Log.info("hand-over: VoiceOver still starting after 3 s; left to come"); return }
        Log.error("hand-over: VoiceOver.app didn't bring VoiceOver on in 3 s; trying its shortcut")
        postToggle()
        let again = Date().addingTimeInterval(2)
        while Date() < again { if NSWorkspace.shared.isVoiceOverEnabled { Log.info("hand-over: VoiceOver on (shortcut)"); return }; usleep(100_000) }
    }

    /// Counts choices of reader (a hand-over, a recovery): a late fallback for an older one stands down. Any thread.
    nonisolated static let choice = Locked(0)
    /// A new choice of reader, counted and returned in one step under the lock.
    @discardableResult nonisolated static func newChoice() -> Int {
        choice.lock.lock(); defer { choice.lock.unlock() }
        choice.unsafeValue += 1
        return choice.unsafeValue
    }

    /// VoiceOver.app opened, which turns VoiceOver on (macOS 14 to 27): from any thread, without waiting.
    nonisolated static func openVoiceOver(_ why: String) {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Library/CoreServices/VoiceOver.app"), configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { Log.error("\(why): VoiceOver didn't open: \(error.localizedDescription)") }
        }
    }
}
