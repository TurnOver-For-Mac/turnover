// SPDX-License-Identifier: GPL-3.0-or-later
// Left and Right pressed together where VoiceOver reads: VoiceOver's Quick Nav toggle. TurnOver's key tap is down
// there, so this small tap only listens (it can't hold up or change a key) and turns TurnOver's Quick Nav the same way,
// so the two stay one Quick Nav (19 Oct 2026: "we kinda need turnover and voiceover's quick nav to be in sync").
import AppKit
import TurnOverCore

@MainActor
final class QuickNavWatch {
    static let shared = QuickNavWatch()
    /// Whether TurnOver reads the app in front: its own key tap sees the chord then.
    var turnOverActive: () -> Bool = { false }
    private var tap: CFMachPort?
    private var held: Set<Int64> = []

    func start() {
        guard Coexist.on, tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
                                        callback: { _, type, event, _ in
            MainActor.assumeIsolated { QuickNavWatch.shared.saw(type, event) }
            return Unmanaged.passUnretained(event)
        }, userInfo: nil) else { Log.warning("Quick Nav watch: no tap"); return }
        tap = t
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    private func saw(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { held.removeAll(); if let tap { CGEvent.tapEnable(tap: tap, enable: true) }; return }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard code == 123 || code == 124 else { return }
        if type == .keyUp { held.remove(code); return }
        guard type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
              event.getIntegerValueField(.eventSourceUserData) != KeyboardHandler.marker,
              event.flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand]).isEmpty else { return }
        held.insert(code)
        guard held.count == 2, !turnOverActive(), config.general.macKeys else { return }
        ArrowQuickNav.voiceOverToggled()
    }
}
