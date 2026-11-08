// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreGraphics
import TurnOverCore

extension KeyboardHandler {
    /// Command Tab did nothing eight times running, then worked once TurnOver was turned off and on (20 Oct
    /// 2026): the Mac's view of the modifiers had drifted from the keyboard's, most likely a modifier TurnOver had
    /// lifted or put back (post) that the hand no longer held. Before a Command Tab passes, any modifier the session
    /// thinks is held but the keyboard doesn't is released, and both states go in the log for the next time.
    nonisolated func clearLeftoverModifiers(before what: String) {
        let hid = CGEventSource.flagsState(.hidSystemState), session = CGEventSource.flagsState(.combinedSessionState)
        let watched: [(CGEventFlags, Int64, String)] = [(.maskControl, 59, "Control"), (.maskAlternate, 58, "Option"), (.maskShift, 56, "Shift"), (.maskSecondaryFn, 63, "Fn")]
        let leftover = watched.filter { session.contains($0.0) && !hid.contains($0.0) }
        Log.io("\(what): modifiers held by the keyboard \(hid.rawValue & 0xFFFF0000), by the session \(session.rawValue & 0xFFFF0000)\(leftover.isEmpty ? "" : "; releasing \(leftover.map(\.2).joined(separator: ", "))")")
        guard !leftover.isEmpty else { return }
        let src = CGEventSource(stateID: .combinedSessionState)
        var state = session
        for (f, code, _) in leftover {
            state.remove(f)
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: false) else { continue }
            e.type = .flagsChanged
            e.flags = state
            e.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            e.post(tap: .cghidEventTap)
        }
    }

    /// Text typed as key events carrying the characters themselves (braille input), marked so the tap ignores them.
    nonisolated static func postText(_ s: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        for unit in s.utf16 {
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
                var u = unit
                e.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
                // No modifiers: the text rides on the A key, and a modifier the system still thought held went with
                // it. Fn left over from an arrow key made "few" typed on the display Fn A, macOS's "focus the Dock"
                // (7 Oct 2026).
                e.flags = .maskNonCoalesced
                e.setIntegerValueField(.eventSourceUserData, value: marker)
                e.post(tap: .cghidEventTap)
            }
        }
    }

    /// A key as if typed, for an AI trying a plugin: the tap handles it (scripts, plugins, echo) like the owner's own.
    nonisolated static func postTyped(_ g: KeyboardGesture) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(g.keyCode), keyDown: down) else { continue }
            e.flags = g.flags.union(.maskNonCoalesced)
            e.setIntegerValueField(.eventSourceUserData, value: g.modifiers.contains(.turnover) ? typedTurnOverMarker : typedMarker)
            e.post(tap: .cghidEventTap)
            usleep(20_000)
        }
    }

    /// Keys down together, then up: a chord VoiceOver recognises (Left and Right for Quick Nav), marked so the tap ignores them.
    nonisolated static func postChord(_ codes: [Int64]) {
        let src = CGEventSource(stateID: .hidSystemState)
        var held: CGEventFlags = [.maskSecondaryFn, .maskNumericPad]
        for down in [true, false] {
            for code in (down ? codes : codes.reversed()) {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: down) else { continue }
                e.flags = held
                e.setIntegerValueField(.eventSourceUserData, value: marker)
                e.post(tap: .cghidEventTap)
                usleep(15_000)
            }
            held = [.maskSecondaryFn, .maskNumericPad]
        }
    }

    /// NVDA's gesture.send: the key down and up, marked so the tap ignores them.
    nonisolated static func post(_ g: KeyboardGesture) {
        let src = CGEventSource(stateID: .hidSystemState)
        // Modifiers the hand still holds that the key sent must not carry (Control and Option under VO-Left, when the
        // key sent is a bare Left): Word asked the keyboard itself and saw them held, and did nothing with the arrow
        // (17 Oct 2026: "VO Left wasn't behaving"; the key driver, holding nothing, had it working). They are
        // lifted around the key and put back after, as events the tap lets through.
        let held = CGEventSource.flagsState(.hidSystemState)
        let lift: [(CGEventFlags, Int64)] = [(.maskControl, 59), (.maskAlternate, 58), (.maskCommand, 55), (.maskShift, 56)].filter { held.contains($0.0) && !g.flags.contains($0.0) }
        var state = held
        func modifier(_ code: Int64, down: Bool, flags: CGEventFlags) {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: down) else { return }
            e.type = .flagsChanged
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: marker)
            e.post(tap: .cghidEventTap)
        }
        for (f, code) in lift { state.remove(f); modifier(code, down: false, flags: state) }
        let toApp = arrowTarget(code: Int64(g.keyCode), flags: g.flags)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(g.keyCode), keyDown: down) else { continue }
            e.flags = g.flags
            e.setIntegerValueField(.eventSourceUserData, value: marker)
            if let toApp { e.postToPid(toApp) } else { e.post(tap: .cghidEventTap) }
        }
        // Put back only what the hand still holds: a release in between was overwritten by a synthetic press, and
        // every key after carried Control until the next tap of it (the code review, 17 Oct 2026).
        let stillHeld = CGEventSource.flagsState(.hidSystemState)
        for (f, code) in lift.reversed() where stillHeld.contains(f) { state.insert(f); modifier(code, down: true, flags: state) }
        if !lift.isEmpty {
            let gone = lift.filter { !stillHeld.contains($0.0) }.count
            Log.io("key sent with \(lift.count) held modifier\(lift.count == 1 ? "" : "s") lifted around it\(gone > 0 ? "; \(gone) released meanwhile, left up" : "")")
        }
    }
}
