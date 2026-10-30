// SPDX-License-Identifier: GPL-3.0-or-later
// Sliders: the arrows change the value and the new value is read.
// Behaviours (NVDA: NVDAObjects.behaviors): the object classes every application shares; app modules subclass them.
import Foundation
import ApplicationServices
import AppKit
import TurnOverAX

/// A slider: the arrows and Page keys change it, and the new value is said even when the app announces nothing
/// (SwiftUI's sliders post no value change: TurnOver Settings' Pitch moved in silence, 18 Oct 2026).
open class Slider: TurnOverObject {
    open override func initOverlay() {
        super.initOverlay()
        script("slider_change", String(localized: "Changes the slider and says its new value", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:leftArrow", "kb:rightArrow", "kb:upArrow", "kb:downArrow", "kb:pageUp", "kb:pageDown", "kb:home", "kb:end"], category: "Sliders") { [weak self] g in
            guard let self else { g.send(); return }
            let before = self.element.attr(kAXValueAttribute).map { "\($0)" }
            let spokenBefore = Speech.lastSpoken
            g.send()
            _ = Poll.pumping(every: 0.02, limit: 0.4) { self.element.attr(kAXValueAttribute).map { "\($0)" } != before }
            let now = self.element.string(kAXValueDescriptionAttribute).flatMap { $0.isEmpty ? nil : $0 } ?? self.element.attr(kAXValueAttribute).map { v -> String in
                if let n = v as? NSNumber { let d = n.doubleValue; return d == d.rounded() ? String(Int(d)) : String(format: "%.1f", d) }
                return "\(v)"
            }
            guard let now else { return }
            if now == before { Tones.edge(); return }
            // The app may say it itself (a value change it posts, read as "67 percent"): a moment for that, then
            // only if nothing was said.
            _ = Poll.pumping(every: 0.02, limit: 0.15) { Speech.lastSpoken != spokenBefore }
            if Speech.lastSpoken != spokenBefore { return }
            Speech.cancel()
            Speech.speakMessage(now)
        }
    }
}
