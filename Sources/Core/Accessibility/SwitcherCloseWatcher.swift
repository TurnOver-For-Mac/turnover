// SPDX-License-Identifier: GPL-3.0-or-later
// Command Tab's application switcher closing without the news TurnOver relies on (issue 351, 22 Nov 2026).
// The switcher's list is TurnOver's focus while it is up. When the user lets go on the app already in front, or
// presses Escape, macOS posts no activation and the app posts no focus, so the list stayed the focus: every key was
// logged as a switcher key, a heading search said "application switcher is open" and the review keys said
// "nothing to review", until another app came forward. Seen in build 25's log, with an app that was not answering too.
import Foundation
import AppKit
import ApplicationServices
import TurnOverAX

/// What the watcher does next, decided from plain facts so that it can be tested without a Mac's accessibility.
package enum SwitcherCloseStep: Equatable {
    case keepWaiting
    /// Read the focus of the app that is active again (the app chosen is the one already in front).
    case refocusActive
    /// Recover the app activation that macOS has not reported.
    case recoverActivation
    case stop
}

package enum SwitcherCloseWatcher {
    /// The app is given this long, once the switcher is seen closed, to say it was chosen before it is read anyway.
    nonisolated package static let settleSeconds = 0.6
    /// An activation on its way is waited for this long, once the switcher is seen closed.
    nonisolated package static let activationSeconds = 1.5

    /// `closedFor`: seconds since the switcher was first seen closed (Command let go, or the list gone); nil while it is
    /// still open. `frontName` and `lastAnnounced` are compared as the names of the app in front and of the switcher
    /// item last said.
    nonisolated package static func decide(commandHeld: Bool, frontPid: pid_t?, activePid: pid_t,
                                           lastAnnounced: String?, frontName: String?, closedFor: Double?,
                                           switcherFocused: Bool = true, focusedPid: pid_t? = nil) -> SwitcherCloseStep {
        let frontPid = frontPid.flatMap { $0 > 0 ? $0 : nil }
        // Focus can arrive without the workspace notification. Keep watching that destination, even when its
        // focus has already replaced the list, but leave any other focus change alone.
        if !switcherFocused {
            guard let frontPid, frontPid != activePid, focusedPid == frontPid else { return .stop }
        }
        // Nothing is read while Command is held, even with the list gone (Escape): the focus rules set the app's focus
        // aside until Command is let go (ruleBehindTheSwitcher), so a read then would be lost and the app itself made
        // the focus in its place (review, 22 Nov 2026). No limit is needed: the watcher ends once anything else is the focus.
        if commandHeld { return .keepWaiting }
        let waited = closedFor ?? 0
        guard let frontPid else { return waited >= activationSeconds ? .stop : .keepWaiting }
        if frontPid == activePid {
            // The chosen app is the one in front when the item last said is its name; if not, a moment is given for
            // another app to come forward. After Escape the list went while Command was held, so by the time Command
            // is let go that moment has usually passed.
            let chosen = lastAnnounced.map { !$0.isEmpty && $0 == frontName } ?? false
            if chosen || waited >= settleSeconds { return .refocusActive }
            return .keepWaiting
        }
        // The front app is not the active one: an activation is on its way, and brings its own focus.
        return waited >= activationSeconds ? .recoverActivation : .keepWaiting
    }

    private static var generation = 0   // main actor, like the rest of Core: start, the polls and reconcile all run there

    static var commandHeld: Bool { CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand) }

    /// Called when the switcher's list gains the focus. A newer opening replaces an older watcher.
    package static func start() {
        generation &+= 1
        poll(generation: generation, firstClosedAt: nil)
    }

    private static func poll(generation gen: Int, firstClosedAt: Date?, destinationFocusPid: pid_t? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let handler = AXHandler.shared
            guard gen == generation, handler.running else { return }
            let focus = API.focusObject
            let list = focus as? AppSwitcherList
            let held = commandHeld
            let role = held ? list?.element.role : nil
            let open = role.map { !$0.isEmpty && $0 != "?" } ?? false
            let closedAt = open ? nil : (firstClosedAt ?? Date())
            let front = NSWorkspace.shared.frontmostApplication
            if let destinationFocusPid, front?.processIdentifier != destinationFocusPid { return }
            let step = decide(commandHeld: held, frontPid: front?.processIdentifier,
                              activePid: handler.activePid, lastAnnounced: AppSwitcherDiagnostics.lastAnnounced,
                              frontName: front?.localizedName, closedFor: closedAt.map { Date().timeIntervalSince($0) },
                              switcherFocused: list != nil, focusedPid: focus?.pid)
            switch step {
            case .keepWaiting:
                poll(generation: gen, firstClosedAt: closedAt, destinationFocusPid: list == nil ? focus?.pid : nil)
            case .stop:
                if list != nil { Log.io("application switcher closed; no app in front to read") }
            case .refocusActive:
                generation &+= 1
                reconcile(pid: front?.processIdentifier ?? 0, why: "the app switcher went without news")
            case .recoverActivation:
                guard let front, front.processIdentifier != getpid() else { return }
                generation &+= 1
                let pid = front.processIdentifier
                Log.io("focus: the app switcher went without activation; recovering pid \(pid)")
                let finish = fallbackFocus(pid: pid)
                handler.appActivated(front, preservingFocus: list == nil ? focus : nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { finish() }
            }
        }
    }

    /// The second line of defence, from the key decision (InputManager): a list still the focus with Command not held
    /// and the key not a Command key means the switcher has gone, so the app in front is read before the key is handled.
    static func reconcileBeforeKey(_ gesture: KeyboardGesture) {
        guard API.focusObject is AppSwitcherList, !commandHeld, !gesture.modifiers.contains(.command),
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        // A different front app still needs the workspace activation, even if this read recovers its focus.
        if pid == AXHandler.shared.activePid { generation &+= 1 }
        reconcile(pid: pid, why: "a key came after the app switcher went", immediate: true)
    }

    /// A second Command Tab can open the same list over the same app before the old close finishes.
    package static func unlessReopened(_ action: @escaping () -> Void) -> () -> Void {
        let opening = generation
        let focusAtClose = API.focusObject
        return {
            guard generation == opening, API.focusObject === focusAtClose else { return }
            action()
        }
    }

    /// Reads the app's own focus again, quietly for the app switcher's sake: nothing extra is said unless the app's
    /// focus is something new, as for any refocus. If the app gives no focused element (it is not answering) the list
    /// must still stop being the focus: the app itself becomes the focus, quietly, as after its last window closes.
    private static func reconcile(pid: pid_t, why: String, immediate: Bool = false) {
        guard pid > 0 else { return }
        Log.io("focus: \(why); reading the app's own focus (pid \(pid))")
        // The focus change may be handled a moment later, so the check waits a little, except before a key, which
        // must act on the app now.
        let finish = fallbackFocus(pid: pid)
        AXHandler.shared.refocus(pid: pid)
        if immediate { finish() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { finish() } }
    }

    private static func fallbackFocus(pid: pid_t) -> () -> Void {
        unlessReopened {
            guard AXHandler.shared.running, API.focusObject is AppSwitcherList else { return }
            // The menu bar held by TurnOver is where the keys are: nothing is taken from it.
            guard MenuNavigationPlugin.heldBar == nil, MenuNavigationPlugin.heldStatus == nil else { return }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            Log.io("focus: pid \(pid) gave no focus; the app itself is the focus")
            let app = AXUIElementCreateApplication(pid)
            let obj = ObjectFactory.make(app)
            API.setFocusObject(obj, ancestors: [])
            ObjectNavigator.shared.focusMoved(to: app, pid: pid)
        }
    }
}
