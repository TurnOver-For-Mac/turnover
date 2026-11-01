// SPDX-License-Identifier: GPL-3.0-or-later
// Events (NVDA: eventHandler). Every accessibility notification becomes an
// event for an object and runs through the chain: global plugins, the app
// module, the object itself. A handler that does not call `next` stops it.
//
// Events are queued while a script runs (a caret script polls for up to
// 100 ms); the queue is drained when it finishes. While a script waits, the
// run loop is pumped in TurnOver's own mode so notifications keep arriving — the
// script can then see that a caret or focus event is pending, NVDA's way.
import Foundation
import CoreFoundation
import ApplicationServices

public enum EventKind: String {
    case gainFocus, loseFocus, focusEntered, focusExited, foreground
    case valueChange, nameChange, stateChange, descriptionChange, caret, selection, textChange, alert
    case menuStart, menuEnd, typedCharacter, appModuleGainFocus, appModuleLoseFocus
    /// An ARIA live region changed (NVDA: event_liveRegionChange, reported with "report dynamic content changes").
    case liveRegionChange
}

public struct Event {
    public let kind: EventKind
    public let obj: TurnOverObject
    public let character: Character?
    public init(_ kind: EventKind, _ obj: TurnOverObject, character: Character? = nil) { self.kind = kind; self.obj = obj; self.character = character }
}

public enum EventHandler {
    /// The run loop mode notifications are also delivered in, so a waiting script can pump them.
    public static let runLoopMode = CFRunLoopMode("turnover.events" as CFString)
    private static var pending: [Event] = []
    private static var draining = false

    /// Queue an event (main thread). Executed now unless a script or another event is running.
    public static func queue(_ event: Event) {
        pending.append(event)
        drain()
    }

    public static func isPending(_ kind: EventKind) -> Bool { pending.contains { $0.kind == kind } }

    /// Let notifications arrive without executing them (NVDA: api.processPendingEvents(processEventQueue=False)).
    public static func pumpPendingEvents() {
        CFRunLoopRunInMode(runLoopMode, 0.0005, true)
    }

    /// Execute queued events in order (main thread).
    public static func drain() {
        guard !draining, !ScriptHandler.isScriptRunning else { return }
        draining = true
        defer { draining = false }
        while !pending.isEmpty {
            let e = pending.removeFirst()
            execute(e)
        }
    }

    /// Run one event through the chain now (NVDA: executeEvent).
    public static func execute(_ event: Event) {
        if InputManager.isAsleep(event.obj.pid) { return }   // NVDA's sleep mode: nothing said for this app
        if InputManager.directPid == event.obj.pid { return }   // a direct app: nothing said (it speaks for itself)
        // Google Docs: a focus move starts or stops the reading of Google's announcements; a caret move in the editor
        // starts it too (after a restart the focus is already there, and no focus event comes, 12 Oct 2026).
        if event.kind == .gainFocus { GoogleDocs.focusMoved(to: event.obj.element) }
        else if event.kind == .caret, GoogleDocs.isEditor(event.obj.element) { GoogleDocs.focusMoved(to: event.obj.element) }
        Log.io("event \(event.kind.rawValue): \(event.obj.axRole) \"\(Log.words(String(event.obj.name.prefix(40))))\"")   // never the typed character
        if [.gainFocus, .foreground, .focusEntered, .valueChange, .menuEnd].contains(event.kind) { ObjectNavigator.forgetGroupItems() }
        // Not for a menu taking the focus as it opens: macOS moves the focus onto the menu a few milliseconds after its
        // name is said ("Edit menu, 4 of 8"), and that dropped the name (Finder, moving along the menu bar, 6 Oct 2026).
        // (A nameless group that takes the focus says nothing, so it doesn't cut off what was being said: WhatsApp
        // flicks its focus to one just after its message box, 7 Oct 2026.)
        let silentGroup = event.obj.axRole == "AXGroup" && event.obj.name.isEmpty && (event.obj.element.string(kAXDescriptionAttribute) ?? "").isEmpty
        // (Nor for a focus the app module is about to ignore: Word's page between a dialog's fields, .)
        if event.kind == .gainFocus, event.obj.axRole != "AXMenu", !AXHandler.shared.isMenuOpen, !silentGroup, !event.obj.appModule.ignoresFocus(event) { Speech.focusMoving() }
        let plugins = GlobalPluginHandler.shared.plugins
        var index = 0
        func next() {
            if index < plugins.count {
                let p = plugins[index]; index += 1
                p.handleEvent(event, next: next)
            } else if index == plugins.count {
                index += 1
                event.obj.appModule.handleEvent(event, next: next)
            } else if index == plugins.count + 1 {
                index += 1
                if let d = API.focusTreeInterceptor, event.obj.pid == d.webArea.pid { d.handleEvent(event, next: next) } else { next() }
            } else if index == plugins.count + 2 {
                index += 1
                event.obj.handleEvent(event)
            }
        }
        next()
        if event.kind == .gainFocus || event.kind == .caret { Braille.focusOrCaretMoved() }
        if event.kind == .gainFocus { BrailleInput.focusChanged() }
        Braille.refreshSoon()
    }

    public static func execute(_ kind: EventKind, on obj: TurnOverObject, character: Character? = nil) {
        execute(Event(kind, obj, character: character))
    }
}
