// SPDX-License-Identifier: GPL-3.0-or-later
// The keyboard input source said as it changes (the Fn or Globe key, Control Space, the menu bar), as VoiceOver
// says it: "Arabic", "British" (a tester, : switching with Fn was silent). Wishlist 8, 13 Oct 2026.
import Foundation
import AppKit
import Carbon

public enum InputSourceAnnouncer {
    private static var last = ""
    private static var observer: NSObjectProtocol?
    private static var appSwitchAt = Date.distantPast
    private static var saidAt = Date.distantPast

    public static func start() {
        guard observer == nil else { return }
        last = current() ?? ""
        _ = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { appSwitchAt = Date() }
        }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                // Changes the Mac makes, not the person (code review, 13 Oct): a password field forces a Roman source
                // in and back out, and "automatically switch to a document's input source" changes it with the app
                // or window. Those follow a focus or app change at once; the person's own switch doesn't.
                let sinceApp = Date().timeIntervalSince(appSwitchAt)
                let theMacs = IsSecureEventInputEnabled() || sinceApp < 0.8 || Speech.sinceFocusSpoken < 0.8
                // Read a moment after the notice, not at it: on a tester's Mac (Arabic and ABC, switched with Fn or
                // Control Space, 15 Oct 2026) the read at the notice still gave the source just left, so
                // TurnOver said "ABC" as Arabic letters typed and the other way about, every time. The process's
                // own view of the selected source catches up on a later turn of the run loop.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { changed(theMacs: theMacs, attempt: 1) }
            }
        }
    }

    private static func changed(theMacs: Bool, attempt: Int) {
        guard let name = current() else { return }
        if name == last {
            // Still the old one: once more, later (the notice came before the process's view changed).
            if attempt == 1 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { changed(theMacs: theMacs, attempt: 2) } }
            else { Log.io("input source: still \(name) half a second after the notice; nothing said") }
            return
        }
        last = name
        if theMacs { Log.io("input source: \(name) (the Mac's change with the focus; not said)"); return }
        Log.io("input source: \(name)\(attempt == 2 ? " (read late)" : "")")
        // Going round with the Globe key: only the one landed on, not each on the way.
        guard Core.active else { Log.io("input source: \(name) (VoiceOver's app; not said)"); return }
        if Date().timeIntervalSince(saidAt) < 1.5 { Speech.cancel() }
        saidAt = Date()
        Speech.speakMessage(name)
    }

    /// The selected keyboard input source's name, as the menu bar shows it.
    static func current() -> String? {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyLocalizedName) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }
}
