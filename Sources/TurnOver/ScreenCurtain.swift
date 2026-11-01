// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreGraphics
import TurnOverCore

/// Screen Curtain: the displays go black while the Mac carries on as normal (NVDA's screen curtain, VoiceOver's
/// VO-Shift-Fn-Underscore). VoiceOver's curtain ends when VoiceOver turns off for TurnOver, which left a tester's
/// screen showing their mail with the curtain on (raised on AppleVis, 5 Oct 2026). TurnOver keeps its own while it
/// leads.
///
/// The curtain sets every display's colour table to black, as VoiceOver does. macOS gives the tables back by itself
/// when TurnOver quits or crashes, so the screen can never be left dark by TurnOver. Screenshots still show the
/// screen's content (they did with VoiceOver's too).
enum ScreenCurtain {
    private(set) static var isOn = false
    /// VoiceOver's curtain was on when VoiceOver last handed over to TurnOver.
    private(set) static var voiceOverHadIt = false
    private static var watching = false

    /// Should the curtain be on while TurnOver leads? "follow" VoiceOver (the default), "on" or "off".
    static var wanted: Bool {
        if let o = override { return o }
        switch config.general.screenCurtain {
        case "on": return true
        case "off": return false
        default: return voiceOverHadIt
        }
    }

    /// Just before VoiceOver hands over: is the screen curtained now? (Every display's table near black.)
    static func noteVoiceOverCurtain() {
        guard !isOn else { return }   // TurnOver's own curtain, not VoiceOver's
        let dark = displays().allSatisfy { maxGamma($0) < 0.05 }
        if dark != voiceOverHadIt { Log.info("screen curtain: VoiceOver's was \(dark ? "on" : "off")") }
        voiceOverHadIt = dark && !displays().isEmpty
    }

    static func apply() { wanted ? on() : off() }

    static func on() {
        guard !isOn else { return }
        isOn = true
        for d in displays() { CGSetDisplayTransferByFormula(d, 0, 0, 1, 0, 0, 1, 0, 0, 1) }
        Log.info("screen curtain: on")
        if !watching {
            watching = true
            // A display connected (or woken) later gets the curtain too.
            CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
                guard !flags.contains(.beginConfigurationFlag) else { return }
                DispatchQueue.main.async { if ScreenCurtain.isOn { for d in ScreenCurtain.displays() { CGSetDisplayTransferByFormula(d, 0, 0, 1, 0, 0, 1, 0, 0, 1) } } }
            }, nil)
        }
    }

    static func off() {
        guard isOn else { return }
        isOn = false
        CGDisplayRestoreColorSyncSettings()
        Log.info("screen curtain: off")
    }

    /// The key's choice, until TurnOver quits (as NVDA's toggle is); the setting stays as it was.
    private static var override: Bool?
    /// TurnOver Control Escape (NVDA's NVDA+Control+Escape), or VoiceOver's VO Shift Underscore: on or off for now.
    static func toggle() {
        override = !isOn
        apply()
        Speech.speakMessage(isOn ? String(localized: "screen curtain on", comment: "Spoken message") : String(localized: "screen curtain off", comment: "Spoken message"))
    }

    static func displays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var list = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &list, &count)
        return Array(list.prefix(Int(count)))
    }

    private static func maxGamma(_ d: CGDirectDisplayID) -> Float {
        let size = CGDisplayGammaTableCapacity(d)
        guard size > 0 else { return 1 }
        var r = [CGGammaValue](repeating: 0, count: Int(size)), g = r, b = r
        var n: UInt32 = 0
        guard CGGetDisplayTransferByTable(d, size, &r, &g, &b, &n) == .success, n > 0 else { return 1 }
        return max(r.prefix(Int(n)).max() ?? 1, g.prefix(Int(n)).max() ?? 1, b.prefix(Int(n)).max() ?? 1)
    }
}
