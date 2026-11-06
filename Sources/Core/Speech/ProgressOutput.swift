// SPDX-License-Identifier: GPL-3.0-or-later
// A progress heard as NVDA reports one (NVDA+U; Oliver, 27 Oct and 2 Nov 2026): a beep for each percent that rises
// in pitch, the percentage said each 10 percent, both, or nothing. ProgressWatch keeps one for an accessibility
// progress bar; an app module that knows a progress of its own (a download, a command's output) can keep one too.
import Foundation

public struct ProgressOutput {
    /// The Progress bars setting's choices, in Settings' order.
    public static let modes = ["beep", "speak", "both", "off"]
    private var beeped: Int
    private var said: Int
    private var last: Int
    /// What the progress is of, said before the percentage ("WhatsApp, 30 percent") when it isn't the item being read:
    /// an App Store download carries on while the person reads other pages.
    private let itemName: String?

    /// `percent`: where the progress is now. It is already known (the bar was just read), so it isn't played or said.
    public init(at percent: Int, name: String? = nil) { beeped = percent; said = percent; last = percent; itemName = name }

    /// Whether the Progress bars setting beeps: a module that looks at a progress itself looks more often then.
    public static var beeps: Bool { ["beep", "both"].contains(config.presentation.progressBars) }

    /// A new percentage, 0 to 100, beeped and said as the Progress bars setting asks. True once it climbs to 100: the
    /// progress is over ("100 percent" is said).
    @discardableResult
    public mutating func update(_ percent: Int) -> Bool {
        let s = Self.step(percent, beeped: beeped, said: said, last: last, mode: config.presentation.progressBars)
        last = percent
        if s.beep { beeped = percent; Tones.progress(percent) }
        if var words = s.say {
            said = percent
            if let itemName, !s.done { words = String(localized: "\(itemName), \(String(percent)) percent", comment: "A download's progress: the app, then the percentage") }
            Speech.speakMessage(words)
        }
        return s.done
    }

    package struct Step: Equatable {
        package var beep = false
        package var say: String?
        package var done = false
        package init(beep: Bool = false, say: String? = nil, done: Bool = false) { self.beep = beep; self.say = say; self.done = done }
    }

    /// NVDA's steps: a beep for each change of 1 percent. The words come as the percentage enters another ten, as
    /// TurnOver said them before there were beeps (18 Oct 2026), and "100 percent" as it climbs to the end. A bar read
    /// at 100 isn't over: it may fall back for the next stage and climb again.
    package static func step(_ percent: Int, beeped: Int, said: Int, last: Int, mode: String) -> Step {
        let beeps = mode == "beep" || mode == "both", words = mode == "speak" || mode == "both"
        var s = Step(beep: beeps && percent != beeped)
        if percent >= 100, last < 100 {
            s.done = true
            if words { s.say = String(localized: "100 percent", comment: "Spoken message") }
        } else if words, percent / 10 != said / 10 {
            s.say = Phrases.percent(percent)
        }
        return s
    }

    /// NVDA+U's order: off, speak, beep, both, and round again.
    package static func mode(after mode: String) -> String {
        let order = ["off", "speak", "beep", "both"]
        return order[((order.firstIndex(of: mode) ?? 0) + 1) % order.count]
    }

    /// NVDA+U: the next mode, said in NVDA's words.
    public static func cycleMode() {
        let next = mode(after: config.presentation.progressBars)
        config.presentation.progressBars = next; config.save()
        Speech.speakMessage(name(next))
    }

    public static func name(_ mode: String) -> String {
        switch mode {
        case "off": return String(localized: "No progress bar updates", comment: "The progress bar setting (NVDA+U): nothing")
        case "beep": return String(localized: "Beep for progress bar updates", comment: "The progress bar setting (NVDA+U): beeps that rise in pitch")
        case "both": return String(localized: "Beep and speak progress bar updates", comment: "The progress bar setting (NVDA+U): beeps and the percentage")
        default: return String(localized: "Speak progress bar updates", comment: "The progress bar setting (NVDA+U): the percentage spoken")
        }
    }
}
