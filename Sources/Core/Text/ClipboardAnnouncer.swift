// SPDX-License-Identifier: GPL-3.0-or-later
// Saying what the clipboard keys did: Command+C "copied", Command+X "cut", Command+V "pasted",
// Command+Option+C (Finder's Copy as Pathname) "copied path". Copy and cut are only announced when
// the clipboard really changed, so Command+C with nothing selected stays quiet, as it does nothing.
import Foundation
import AppKit

public enum ClipboardAnnouncer {
    /// Called on the keyboard thread for every key down, before the key reaches the application.
    static func keyDown(_ g: KeyboardGesture) {
        guard !g.isTurnOverModifier, !g.isRepeat else { return }
        let key = g.keyName
        let mods = g.modifiers
        let kind: String?
        switch (key, mods) {
        case ("c", [.command]): kind = "copied"
        case ("x", [.command]): kind = "cut"
        case ("v", [.command]): kind = "pasted"
        case ("v", [.command, .option, .shift]), ("v", [.command, .shift]): kind = "pasted"   // paste and match style
        case ("c", [.command, .option]): kind = "copied path"
        default: kind = nil
        }
        guard let kind else { return }
        let before = NSPasteboard.general.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + (kind == "pasted" ? 0.15 : 0.3)) {
            if kind != "pasted", NSPasteboard.general.changeCount == before { return }   // nothing was copied
            guard kind == "pasted" else { Speech.speakMessage(spoken(kind), remember: false); return }
            Speech.asPrivate { Speech.speakMessage(pastedSpeech(), remember: false) }   // a pasted token or password never reaches the history (code review, 16 Oct 2026)
        }
    }

    /// "pasted, " and the text (VoiceOver reads it; it was silent in Safari's fields, 3 Oct 2026). Terminal echoes a
    /// paste as output, which its module reads, so there it stays "pasted". A password field: the count only.
    /// The kind ("copied", "cut", "copied path") as said: the kind itself stays English, as it is compared.
    static func spoken(_ kind: String) -> String {
        switch kind {
        case "copied": return String(localized: "copied", comment: "Command C pressed")
        case "cut": return String(localized: "cut", comment: "Command X pressed")
        case "copied path": return String(localized: "copied path", comment: "Command Option C pressed in Finder")
        default: return String(localized: "pasted", comment: "Command V pressed")
        }
    }

    static func pastedSpeech() -> String {
        if let f = API.focusObject, f.role == .passwordEdit {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { Speech.speakMessage(Speech.secureCount(f), remember: false) }
            return spoken("pasted")
        }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Terminal" { return spoken("pasted") }
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return spoken("pasted") }
        if text.count <= 400 { return String(localized: "pasted, \(text)", comment: "Pasted text: the text") }
        return String(localized: "pasted, \(String(text.prefix(200))), and \(String(text.count - 200)) more characters", comment: "Pasted text: its start, then how many characters more")
    }
}
