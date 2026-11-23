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

    private(set) static var generation = 0
    private static let focusRead = AXWalkRunner<AXUIElement?>()
    private static var recovery: Recovery?
    nonisolated package static let isWatching = Locked(false)

    @MainActor private final class Recovery {
        let pid: pid_t
        let opening: Int
        weak var list: AppSwitcherList?
        var keys: [() -> Void] = []

        init(pid: pid_t, opening: Int, list: AppSwitcherList) {
            self.pid = pid
            self.opening = opening
            self.list = list
        }
    }

    static var commandHeld: Bool { CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand) }

    /// Called when the switcher's list gains the focus. A newer opening replaces an older watcher.
    package static func start() {
        cancelRecovery()
        generation &+= 1
        isWatching.value = true
        poll(generation: generation, firstClosedAt: nil)
    }

    private static func poll(generation gen: Int, firstClosedAt: Date?, destinationFocusPid: pid_t? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let handler = AXHandler.shared
            guard gen == generation else { return }
            guard handler.running else { isWatching.value = recovery != nil; return }
            let focus = API.focusObject
            let list = focus as? AppSwitcherList
            let held = commandHeld
            let role = held ? list?.element.role : nil
            let open = role.map { !$0.isEmpty && $0 != "?" } ?? false
            let closedAt = open ? nil : (firstClosedAt ?? Date())
            let front = NSWorkspace.shared.frontmostApplication
            if let destinationFocusPid, front?.processIdentifier != destinationFocusPid {
                isWatching.value = recovery != nil
                return
            }
            let step = decide(commandHeld: held, frontPid: front?.processIdentifier,
                              activePid: handler.activePid, lastAnnounced: AppSwitcherDiagnostics.lastAnnounced,
                              frontName: front?.localizedName, closedFor: closedAt.map { Date().timeIntervalSince($0) },
                              switcherFocused: list != nil, focusedPid: focus?.pid)
            switch step {
            case .keepWaiting:
                poll(generation: gen, firstClosedAt: closedAt, destinationFocusPid: list == nil ? focus?.pid : nil)
            case .stop:
                isWatching.value = recovery != nil
                if list != nil { Log.io("application switcher closed; no app in front to read") }
            case .refocusActive:
                if let pid = front?.processIdentifier, let list {
                    beginRecovery(pid: pid, list: list)
                } else {
                    isWatching.value = recovery != nil
                }
            case .recoverActivation:
                isWatching.value = recovery != nil
                guard let front, front.processIdentifier != getpid() else { return }
                let pid = front.processIdentifier
                Log.io("focus: the app switcher went without activation; recovering pid \(pid)")
                let finish = fallbackFocus(pid: pid)
                handler.appActivated(front, preservingFocus: list == nil ? focus : nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { finish() }
            }
        }
    }

    /// Give the focus read a head start when the keyboard tap sees Command released.
    package static func commandReleased() {
        guard let list = API.focusObject as? AppSwitcherList, !commandHeld,
              let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier == AppSwitcherList.openedOver,
              let chosen = AppSwitcherDiagnostics.lastAnnounced, !chosen.isEmpty, chosen == front.localizedName,
              recovery == nil else { return }
        beginRecovery(pid: front.processIdentifier, list: list)
    }

    /// Retain the normal input decision until a destination is available. The tap returns before any AX work.
    static func holdInput(_ gesture: KeyboardGesture, run: @escaping () -> Void) -> Bool {
        // Decide Command-Tab normally so capture, input help and user bindings still take precedence.
        if isSwitcherGesture(gesture) { return false }
        guard (isWatching.value || recovery != nil), let front = NSWorkspace.shared.frontmostApplication else { return false }
        let pid = front.processIdentifier
        if let pending = recovery, pending.pid != pid { cancelRecovery() }
        if recovery == nil, !commandHeld, !gesture.modifiers.contains(.command), let list = API.focusObject as? AppSwitcherList {
            beginRecovery(pid: pid, list: list)
        }
        guard let recovery else { return false }
        recovery.keys.append(run)
        return true
    }

    static func passedThrough(_ gesture: KeyboardGesture) {
        if recovery != nil, isSwitcherGesture(gesture) { cancelRecovery() }
    }

    private static func isSwitcherGesture(_ gesture: KeyboardGesture) -> Bool {
        gesture.keyName == "tab" && gesture.modifiers.contains(.command)
    }

    private static func beginRecovery(pid: pid_t, list: AppSwitcherList) {
        guard pid > 0, AXHandler.shared.running, MenuNavigationPlugin.heldBar == nil,
              MenuNavigationPlugin.heldStatus == nil else { return }
        if let recovery, recovery.pid == pid { return }
        cancelRecovery()
        let pending = Recovery(pid: pid, opening: generation, list: list)
        recovery = pending
        isWatching.value = true
        focusRead.submit(collect: { _ in
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.12)
            return app.element(kAXFocusedUIElementAttribute)
        }, publish: { [weak pending] focus in
            if let pending { finishRecovery(pending, focus: focus) }
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) { [weak pending] in
            if let pending { finishRecovery(pending, focus: nil) }
        }
    }

    private static func cancelRecovery() {
        if recovery?.keys.isEmpty == false { Log.io("focus: superseded switcher input was discarded") }
        recovery = nil
        focusRead.cancel()
    }

    private static func finishRecovery(_ pending: Recovery, focus: AXUIElement?) {
        guard recovery === pending else { return }
        let handler = AXHandler.shared
        guard handler.running, pending.opening == generation,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pending.pid else {
            cancelRecovery()
            isWatching.value = handler.running && API.focusObject is AppSwitcherList
            return
        }
        // Command may have been pressed again while the read was on its way. A new Command-Tab cancels
        // this recovery; for another shortcut, wait for release before restoring the original app's focus.
        if commandHeld {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak pending] in
                if let pending { finishRecovery(pending, focus: focus) }
            }
            return
        }
        focusRead.cancel()
        defer {
            if recovery === pending { recovery = nil }
            if generation == pending.opening, recovery == nil {
                isWatching.value = API.focusObject is AppSwitcherList
            }
        }
        if let list = pending.list, API.focusObject === list,
           MenuNavigationPlugin.heldBar == nil, MenuNavigationPlugin.heldStatus == nil {
            if let focus { handler.focusChanged(focus, pid: pending.pid) }
            if API.focusObject === list { fallbackFocus(pid: pending.pid)() }
        }
        guard recovery === pending, pending.opening == generation,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pending.pid else { return }
        let keys = pending.keys
        recovery = nil
        for run in keys { run() }
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

    private static func fallbackFocus(pid: pid_t) -> () -> Void {
        unlessReopened {
            guard AXHandler.shared.running, API.focusObject is AppSwitcherList else { return }
            // The menu bar held by TurnOver is where the keys are: nothing is taken from it.
            guard MenuNavigationPlugin.heldBar == nil, MenuNavigationPlugin.heldStatus == nil else { return }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            Log.io("focus: pid \(pid) gave no focus; the app itself is the focus")
            let app = AXUIElementCreateApplication(pid)
            let obj = TurnOverObject(knownApplication: app, pid: pid)
            API.setFocusObject(obj, ancestors: [])
            ObjectNavigator.shared.focusMoved(to: app, pid: pid)
        }
    }
}
