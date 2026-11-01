// SPDX-License-Identifier: GPL-3.0-or-later
// Feedback while typing a password. With a password field focused, macOS turns on Secure Input: the keys no longer
// reach TurnOver at all (VoiceOver has a privileged route), so there was no feedback (3 Oct 2026). What TurnOver can
// still see is the field's length changing (Safari: the end of the caret; the password itself is never given). So:
// one more character, a click (VoiceOver) or "star" (NVDA) with sounds off; one fewer, a lower click, "blank" when
// empty; many at once (AutoFill typing it in a character every 25 ms, a paste, a clear), the count once it settles.
import Foundation
import ApplicationServices
import AppKit
import Carbon

public enum SecureEcho {
    private static var field: AXUIElement?
    private static var baseline = 0
    private static var lastSeen = 0
    private static var changes = 0
    private static var pending: DispatchWorkItem?

    /// The password field's length: the count if given, its bullets, the end of the caret or selection.
    public static func length(_ e: AXUIElement) -> Int {
        let sel = cfRange(e.attr(kAXSelectedTextRangeAttribute)).map { $0.location + $0.length } ?? 0
        let vis = cfRange(e.attr(kAXVisibleCharacterRangeAttribute)).map { $0.length } ?? 0
        return max(e.int(kAXNumberOfCharactersAttribute) ?? 0, e.string(kAXValueAttribute)?.count ?? 0, sel, vis)
    }

    /// The field took the focus: what it holds now is the starting point. (A spoken hint that Tab leaves the field,
    /// added for issue 107 on 26 Oct 2026, got in the way of moving around and was dropped the next day; the guide
    /// says it instead.)
    public static func focused(_ e: AXUIElement) {
        pending?.cancel(); pending = nil
        field = e; baseline = length(e); lastSeen = baseline; changes = 0
    }

    /// A caret or value event while the field has the focus.
    public static func changed(_ e: AXUIElement) {
        if field.map({ !$0.isSame(e) }) ?? true { focused(e); return }
        let n = length(e)
        guard n != lastSeen else { return }
        lastSeen = n; changes += 1
        // Wait a moment: a second change within it means AutoFill or a paste, not a key.
        pending?.cancel()
        let w = DispatchWorkItem { settle() }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07, execute: w)
    }

    private static func settle() {
        let delta = lastSeen - baseline
        let single = changes == 1
        baseline = lastSeen; changes = 0; pending = nil
        if single, delta == 1 {
            if VoiceOverSounds.play("SecureCharacter.aiff") { }
            else if config.general.navigationSounds { Speech.player?.playBell(frequencies: [1900], spacingMs: 0, ringMs: 14, volume: 0.12) }
            else { Speech.speakMessage("star", remember: false) }
        } else if single, delta == -1 {
            if lastSeen == 0 { Speech.speakMessage("blank", remember: false) }
            else if VoiceOverSounds.play("SecureCharacter.aiff") { }
            else if config.general.navigationSounds { Speech.player?.playBell(frequencies: [900], spacingMs: 0, ringMs: 14, volume: 0.12) }
            else { Speech.speakMessage("deleted", remember: false) }
        } else {
            Speech.speakMessage(lastSeen == 0 ? "blank" : lastSeen == 1 ? "1 character" : "\(lastSeen) characters", remember: false)
        }
    }
}


/// E17: Secure Input left on after a password field (Safari, 3 Oct 2026) hides every key from TurnOver, so its reading
/// keys silently stop. Checked once a second while TurnOver leads: on, for two seconds running, with the focus not in
/// a password field, TurnOver says so once and how to get the keys back, and logs which process holds it.
public enum SecureInputWatch {
    private static var timer: Timer?
    private static var seconds = 0
    private static var warned = false
    /// Secure input came on or went off while TurnOver leads (the app lifts VoiceOver's mute for a password field).
    public static var onChange: ((Bool) -> Void)?
    private static var wasOn = false

    public static func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { check() } }
    }
    public static func stop() { timer?.invalidate(); timer = nil; seconds = 0; warned = false }

    private static func check() {
        let on = IsSecureEventInputEnabled()
        if on != wasOn { wasOn = on; onChange?(on) }
        let inPassword = API.focusObject?.role == .passwordEdit
        guard on, !inPassword else { seconds = 0; warned = false; return }
        seconds += 1
        guard seconds >= 2, !warned else { return }
        warned = true
        let holder = (CGSessionCopyCurrentDictionary() as? [String: Any])?["kCGSSessionSecureInputPID"] as? Int
        let name = holder.flatMap { NSRunningApplication(processIdentifier: pid_t($0))?.localizedName } ?? holder.map { "pid \($0)" } ?? "an application"
        // The session's "holder" is not reliable (a test program holding it was reported as Mail, 4 Oct 2026): logged,
        // not spoken.
        Log.error("secure input: on outside a password field (session names \(name)); TurnOver cannot hear the keys")
        Speech.speakMessage("Secure input is on, so TurnOver cannot hear your keys. Press Command Tab twice to get them back.")
    }
}
