// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

/// Runs the real Speech.enqueue mode and VoiceOver gates; replaces only its final audio handoff.
final class ModeWordsTrial {
    var now = Date(timeIntervalSince1970: 1000)
    var scheduled: [(Date, @MainActor () -> Void)] = []
    var queued: [(String, (@Sendable (Bool) -> Void)?)] = []
    var sound: [Bool] = []
    var finish = true
    var events: [String] = []
    let configBefore = config
    let modeBefore = Speech.mode
    let gateBefore = Speech.voiceOverEnabledForOutput
    let coexistBefore = Speech.coexistingForOutput
    let enqueueBefore = Speech.enqueueTestDriver
    let outputBefore = Speech.outputTestDriver
    let soundBefore = BrowseModeDocument.modeSound
    let clockBefore = ModeAnnouncement.now
    let schedulerBefore = ModeAnnouncement.schedule
    let processBefore = EventHandler.sameDocumentProcess

    init() {
        ModeAnnouncement.reset()
        EventHandler.sameDocumentProcess = { $0 >= 900_000 && $1 >= 900_000 }
        Speech.testResetFocusTiming()
        Speech.mode = .talk
        Speech.voiceOverEnabledForOutput = { false }
        Speech.coexistingForOutput = { false }
        Speech.enqueueTestDriver = nil
        Speech.outputTestDriver = { [weak self] text, _, completion in
            guard let self else { return }
            queued.append((text, completion))
            events.append(text)
            if finish { completion?(true) }
        }
        BrowseModeDocument.modeSound = { [weak self] focus in
            self?.sound.append(focus)
            self?.events.append(focus ? "focus sound" : "browse sound")
        }
        config.general.navigationSounds = false
        config.virtualBuffers.autoFocusMode = true
        config.virtualBuffers.autoPassThroughOnCaretMove = false
        // 20 Nov 2026: hints run on the real clock (1.2 seconds after a focus) and this trial has a clock of its own. On a
        // slow machine the menu button's hint from one mode-cue test was spoken into a later one and became its last
        // event. So no hint is said while a trial runs, and restore() cancels any that was waiting from before.
        config.presentation.speakHints = false
        ModeAnnouncement.now = { [weak self] in self?.now ?? .distantPast }
        ModeAnnouncement.schedule = { [weak self] delay, action in
            guard let self else { return }
            scheduled.append((now.addingTimeInterval(delay), action))
        }
    }
    var words: [String] { queued.map(\.0) }
    func drain() { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    func advance(_ seconds: Double) {
        let until = now.addingTimeInterval(seconds)
        while let next = scheduled.indices.min(by: { scheduled[$0].0 < scheduled[$1].0 }), scheduled[next].0 <= until {
            let (at, action) = scheduled.remove(at: next)
            now = at
            action()
            drain()
        }
        now = until
        drain()
    }
    func restore() {
        ModeAnnouncement.reset()
        for entry in queued { entry.1?(false) }
        Hints.cancel()
        drain()
        scheduled = []
        config = configBefore
        Speech.mode = modeBefore
        Speech.voiceOverEnabledForOutput = gateBefore
        Speech.coexistingForOutput = coexistBefore
        Speech.enqueueTestDriver = enqueueBefore
        Speech.outputTestDriver = outputBefore
        BrowseModeDocument.modeSound = soundBefore
        ModeAnnouncement.now = clockBefore
        ModeAnnouncement.schedule = schedulerBefore
        EventHandler.sameDocumentProcess = processBefore
    }
}
