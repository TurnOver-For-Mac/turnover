// SPDX-License-Identifier: GPL-3.0-or-later
// Zoom Workplace 7.1.9 (88375), macOS 27.2.1, 13 Nov 2026, in a running meeting and in a test meeting alone as
// host, probed with turnover-plugin snapshot, menus and try, and the log.
//
// Zoom's own keys that said nothing:
// - Command Shift A and Command Shift V (mute, video) changed Zoom's state and nothing was said: Zoom sent no
//   announcement and no other notification (log: the key, then silence). The state is in the Meeting menu, whose
//   item for the key is titled with the next action ("Unmute audio" while muted, "Start video" while off). The
//   module sends the key on and says the new state once that title has changed.
// - Option Y raised and lowered the hand and Option Command 4 to 9 sent reactions, all silently. Zoom shows
//   either in a small extra window of its own with one thing in it: a "Lower hand" button while the hand is up,
//   or the reaction's picture for a few seconds. The module says "hand raised" or "hand lowered" and the reaction
//   after those keys.
// - Command Shift 2, Zoom's own key for reading the active speaker's name, said nothing. The speaker is in the
//   window: the tile whose description ends ", active speaker". The module answers the key in the meeting window
//   with that name. (Command 2 is Zoom's key for another view of the Zoom Workplace window and is left alone;
//   13 Nov 2026.)
// - Zoom's own alerts (Settings, Accessibility, Screen reader alerts) never arrive. Its interface framework
//   (Prism) holds "speakStringIfVoiceOverOn:" and watches the system's VoiceOver state, so the alerts appear to be
//   made only while VoiceOver itself is on (names read from the program file, 13 Nov 2026; not traced running).
//   TurnOver turns VoiceOver off, so a module cannot receive them.
//
// The titles and descriptions matched are Zoom's English ones as observed, kept together in ZoomWords.swift. In
// another language the keys still go to Zoom and the module stays quiet or says Zoom's own words, rather than
// guessing.
import AppKit
import Foundation
import ApplicationServices

package final class ZoomAppModule: AppModule {
    package static let bundleID = "us.zoom.xos"
    static let meetingWindowIdentifier = "zm.meeting.window.main"

    /// The Meeting menu's items for the two keys, kept once found: walking the closed menus costs about a hundred
    /// questions to Zoom, and the items stay the same elements for the life of the app.
    private var menuItems: [String: AXUIElement] = [:]
    /// Counts key presses, so a late check for an earlier press says nothing after a newer one.
    private var generation = 0

    package required init(pid: pid_t, bundleIdentifier: String, appName: String) {
        super.init(pid: pid, bundleIdentifier: bundleIdentifier, appName: appName)
        script("zoom_toggleAudio", String(localized: "Mutes or unmutes your microphone in the meeting, and says which", comment: "A command, as the key list and keyboard help say it"),
               gestures: ["kb:command+shift+a"], category: "Zoom") { [weak self] gesture in
            self?.toggle(gesture, shortcut: "A", words: ZoomWords.audio)
        }
        script("zoom_toggleVideo", String(localized: "Starts or stops your video in the meeting, and says which", comment: "A command, as the key list and keyboard help say it"),
               gestures: ["kb:command+shift+v"], category: "Zoom") { [weak self] gesture in
            self?.toggle(gesture, shortcut: "V", words: ZoomWords.video)
        }
        script("zoom_toggleHand", String(localized: "Raises or lowers your hand in the meeting, and says which", comment: "A command, as the key list and keyboard help say it"),
               gestures: ["kb:option+y"], category: "Zoom") { [weak self] gesture in
            self?.toggleHand(gesture)
        }
        script("zoom_react", String(localized: "Sends a reaction in the meeting, and says it", comment: "A command, as the key list and keyboard help say it"),
               gestures: (4...9).map { "kb:option+command+\($0)" }, category: "Zoom") { [weak self] gesture in
            self?.react(gesture)
        }
        script("zoom_activeSpeaker", String(localized: "Says who is speaking in the meeting", comment: "A command, as the key list and keyboard help say it"),
               gestures: ["kb:command+shift+2"], category: "Zoom") { [weak self] gesture in
            self?.sayActiveSpeaker(gesture)
        }
    }

    // MARK: Mute and video

    /// Sends the key to Zoom, then says the state once the menu item's title has changed. Zoom took under half a
    /// second (13 Nov 2026); at the last look the state is said even if unchanged, so the key is never silent.
    private func toggle(_ gesture: KeyboardGesture, shortcut: String, words: @escaping (String) -> String?) {
        let before = menuTitle(shortcut: shortcut)
        gesture.send()
        guard Core.active, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
        generation += 1
        let mine = generation
        check(after: [0.25, 0.35, 0.6], shortcut: shortcut, before: before, generation: mine, words: words)
    }

    private func check(after delays: [TimeInterval], shortcut: String, before: String?, generation mine: Int,
                       words: @escaping (String) -> String?) {
        guard let delay = delays.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == mine else { return }
            let now = self.menuTitle(shortcut: shortcut)
            let last = delays.count == 1
            if let now, now != before || last {
                Speech.speakMessage(words(now) ?? now)
            } else if !last {
                self.check(after: Array(delays.dropFirst()), shortcut: shortcut, before: before, generation: mine, words: words)
            }
        }
    }

    /// The title of the menu item whose key is Command Shift and this letter. Found by its key, not its words.
    private func menuTitle(shortcut: String) -> String? {
        if let item = menuItems[shortcut], let title = item.string(kAXTitleAttribute) { return title }
        let app = AXUIElementCreateApplication(pid)
        guard let bar = app.element(kAXMenuBarAttribute) else { return nil }
        for barItem in bar.elements(kAXChildrenAttribute) {
            for menu in barItem.elements(kAXChildrenAttribute) {
                for item in menu.elements(kAXChildrenAttribute)
                where item.string(kAXMenuItemCmdCharAttribute) == shortcut && item.int(kAXMenuItemCmdModifiersAttribute) == 1 {
                    // Modifiers 1 is Shift with Command; Edit's Select all is Command A alone (0).
                    menuItems[shortcut] = item
                    return item.string(kAXTitleAttribute)
                }
            }
        }
        return nil
    }

    // MARK: Hand and reactions

    /// What Zoom's small feedback window holds now: the "Lower hand" button while your hand is up, or the picture
    /// of the reaction just sent. The window is told by its shape, not its title: one of the app's windows that is
    /// neither a standard window nor a dialog and has exactly one thing in it.
    private func feedback() -> (handRaised: Bool, reaction: String?) {
        var hand = false, reaction: String?
        for window in AXUIElementCreateApplication(pid).elements(kAXWindowsAttribute) {
            let children = window.elements(kAXChildrenAttribute)
            guard let only = ZoomWords.feedbackChild(windowSubrole: window.string(kAXSubroleAttribute), childRoles: children.map(\.role)) else { continue }
            if only == "AXButton" { hand = true } else { reaction = children.first?.string(kAXDescriptionAttribute) }
        }
        return (hand, reaction)
    }

    private func toggleHand(_ gesture: KeyboardGesture) {
        let was = feedback().handRaised
        gesture.send()
        guard Core.active, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
        generation += 1
        let mine = generation
        // Zoom took about a quarter of a second (13 Nov 2026). Nothing is said if nothing changed: in a text field
        // the key may have typed a letter instead.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.generation == mine else { return }
            let now = self.feedback().handRaised
            guard now != was else { Log.io("zoom: hand: no change after the key"); return }
            Speech.speakMessage(now ? String(localized: "hand raised", comment: "Zoom: your hand after the raise hand key, and in the state command")
                                    : String(localized: "hand lowered", comment: "Zoom: your hand after the raise hand key"))
        }
    }

    private func react(_ gesture: KeyboardGesture) {
        gesture.send()
        guard Core.active, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
        generation += 1
        let mine = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.generation == mine, let reaction = self.feedback().reaction, !reaction.isEmpty else { return }
            Speech.speakMessage(String(localized: "sent \(reaction)", comment: "Zoom: a reaction was sent; the value is the reaction, such as a thumbs up"))
        }
    }

    // MARK: Who is speaking

    private func sayActiveSpeaker(_ gesture: KeyboardGesture) {
        // The app's focused window, not the focus object's: a toolbar button there gave no window (installed build,
        // 13 Nov 2026: the key ran this and nothing was said).
        guard let window = AXUIElementCreateApplication(pid).element(kAXFocusedWindowAttribute),
              window.string(kAXIdentifierAttribute) == Self.meetingWindowIdentifier else {
            Log.io("zoom: who is speaking outside the meeting window; the key goes to Zoom")
            gesture.send(); return
        }
        // The tiles are tab groups in the window, and in the "grid view" tab group one level down.
        var descriptions: [String] = []
        for child in window.elements(kAXChildrenAttribute) where child.role == "AXTabGroup" {
            if let d = child.string(kAXDescriptionAttribute) { descriptions.append(d) }
            for tile in child.elements(kAXChildrenAttribute) where tile.role == "AXTabGroup" {
                if let d = tile.string(kAXDescriptionAttribute) { descriptions.append(d) }
            }
        }
        Log.io("zoom: who is speaking: \(descriptions.count) tiles")
        if let name = ZoomWords.activeSpeaker(in: descriptions) {
            Speech.speakMessage(String(localized: "\(name) is speaking", comment: "Zoom: the answer to who is speaking; the value is a person's name"))
        } else {
            Speech.speakMessage(String(localized: "No one is speaking", comment: "Zoom: the answer to who is speaking, when Zoom marks nobody"))
        }
    }
}
