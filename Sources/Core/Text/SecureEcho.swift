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
            else { Speech.speakMessage(String(localized: "star", comment: "Spoken message"), remember: false) }
        } else if single, delta == -1 {
            if lastSeen == 0 { Speech.speakMessage(String(localized: "blank", comment: "Spoken message"), remember: false) }
            else if VoiceOverSounds.play("SecureCharacter.aiff") { }
            else if config.general.navigationSounds { Speech.player?.playBell(frequencies: [900], spacingMs: 0, ringMs: 14, volume: 0.12) }
            else { Speech.speakMessage(String(localized: "deleted", comment: "Spoken message"), remember: false) }
        } else {
            Speech.speakMessage(lastSeen == 0 ? Phrases.blank : Phrases.characters(lastSeen), remember: false)
        }
    }

    /// A password field the application in front shows from another of its processes. In System Settings' password
    /// sheet (Users & Groups, Add User; macOS 27.2, 31 Oct 2026) the field is the pane's extension's, an XPC process:
    /// FocusChanges sets its focus aside (not an application), and it tells TurnOver nothing as it is typed into, so not
    /// a click was heard. Asked of the application, the focused element is that field, and its length goes 1, 2, 3, 4 as
    /// it is typed into and back to 0 (measured).
    public static func otherProcessField(of appPid: pid_t) -> AXUIElement? {
        guard appPid > 0, let f = AXUIElementCreateApplication(appPid).element(kAXFocusedUIElementAttribute), f.pid != appPid,
              Role.from(axRole: f.role, subrole: f.string(kAXSubroleAttribute)) == .passwordEdit else { return nil }
        return f
    }

    private static var watched: AXUIElement?
    private static var watchTimer: Timer?
    /// Such a field's length looked at every 50 ms while it has the keys, as its caret events would be heard
    /// (SecureInputWatch starts and stops it); nil stops. Its focus was set aside, so nothing said where the keys had
    /// gone (only silence told it was the password field, 31 Oct 2026): it is spoken as a focus is, its name and role.
    static func watch(_ e: AXUIElement?) {
        if let e, let w = watched, w.isSame(e) { return }
        watchTimer?.invalidate(); watchTimer = nil
        watched = e
        guard let e else { return }
        focused(e)
        Speech.cancel()
        Speech.speakObject(ObjectFactory.make(e), reason: .focus)
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in MainActor.assumeIsolated { if let w = watched { changed(w) } } }
    }
}


/// E17: Secure Input left on after a password field (Safari, 3 Oct 2026) hides every key from TurnOver, so its reading
/// keys silently stop. Checked four times a second while TurnOver leads: on, for ten seconds running, with the focus not
/// in a password field, TurnOver says so once and how to get the keys back, and logs which process holds it. (Two seconds
/// until 31 Oct 2026: Chrome keeps secure input on while the "Show password" box after its password field has the focus,
/// and each Tab out of the field brought the warning.) A password field the application shows from another process
/// (SecureEcho.otherProcessField) is one too: its length is looked at from the first quarter second, and it gives no
/// warning (System Settings' password sheet said "Press Command Tab twice" three times while the password was typed).
public enum SecureInputWatch {
    private static var timer: Timer?
    private static var looks = 0
    private static var warned = false
    /// Secure input came on or went off while TurnOver leads (the app lifts VoiceOver's mute for a password field).
    public static var onChange: ((Bool) -> Void)?
    private static var wasOn = false

    public static func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in MainActor.assumeIsolated { check() } }
    }
    public static func stop() { timer?.invalidate(); timer = nil; looks = 0; warned = false; SecureEcho.watch(nil) }

    private static func check() {
        let on = IsSecureEventInputEnabled()
        if on != wasOn { wasOn = on; onChange?(on) }
        let other = on ? SecureEcho.otherProcessField(of: AXHandler.shared.activePid) : nil
        SecureEcho.watch(other)
        let inPassword = API.focusObject?.role == .passwordEdit || other != nil
        guard on, !inPassword else { looks = 0; warned = false; return }
        looks += 1
        guard looks >= 40, !warned else { return }
        warned = true
        let holder = (CGSessionCopyCurrentDictionary() as? [String: Any])?["kCGSSessionSecureInputPID"] as? Int
        let name = holder.flatMap { NSRunningApplication(processIdentifier: pid_t($0))?.localizedName } ?? holder.map { "pid \($0)" } ?? "an application"
        // The session's "holder" is not reliable (a test program holding it was reported as Mail, 4 Oct 2026): logged,
        // not spoken.
        Log.error("secure input: on outside a password field (session names \(name)); TurnOver cannot hear the keys")
        Speech.speakMessage(String(localized: "Secure input is on, so TurnOver cannot hear your keys. Press Command Tab twice to get them back.", comment: "Spoken message"))
    }
}
