// SPDX-License-Identifier: GPL-3.0-or-later
// Only unrelated app ownership is replaced. The compiled extension, its output
// closure, the delivery loop and both real reader output gates are production code.
import Foundation
import TurnOverCore

@MainActor final class LeadWatcher {
    let modeDelivery = ModeSpeechDelivery()
    var spokenModeGeneration: Int?
    var choiceGeneration = 0
    static var nextTakeoverWords: String?
    var reader: ModeSpeechPolicy.Reader? = .turnOver
    var scheduled: [@MainActor () -> Void] = []
    func readyModeReader(generation: Int) -> ModeSpeechPolicy.Reader? {
        generation == choiceGeneration ? reader : nil
    }
    func scheduleModeSpeech(after delay: Double, action: @escaping @MainActor () -> Void) {
        scheduled.append(action)
    }
    func finish() {
        precondition(!scheduled.isEmpty, "production output was never scheduled")
        scheduled.removeFirst()()
    }
}

@main struct ModeWiringHarness {
    @MainActor static func main() {
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures += 1; print("FAIL: \(message)") }
        }
        Speech.mode = .talk
        Speech.voiceOverEnabledForOutput = { false }
        Speech.enqueueTestDriver = nil
        var spoken: [String] = []
        Speech.outputTestDriver = { text, _, completion in spoken.append(text); completion?(true) }
        var announcements: [String] = []
        var scripts: [String] = []
        VoiceOverSpeak.outputTestDriver = { text, route in
            switch route {
            case .announcement: announcements.append(text)
            case .appleScript: scripts.append(text)
            }
        }
        let turnOver = LeadWatcher()
        turnOver.sayModeWhenReady("TurnOver mode", generation: 0)
        check(spoken.isEmpty, "actual LeadWatcher output waits for settling")
        turnOver.finish()
        check(spoken == ["TurnOver mode"], "actual LeadWatcher output reaches real Speech gate")
        check(announcements.isEmpty && scripts.isEmpty, "TurnOver selection stays with TurnOver")
        let voiceOver = LeadWatcher()
        voiceOver.reader = .voiceOver
        voiceOver.sayModeWhenReady("VoiceOver mode", generation: 0)
        voiceOver.finish()
        check(announcements == ["VoiceOver mode"], "actual LeadWatcher output posts AX announcement")
        check(scripts == ["VoiceOver mode"], "actual LeadWatcher output retains VoiceOver AppleScript fallback")
        voiceOver.sayModeWhenReady("duplicate", generation: 0)
        check(voiceOver.scheduled.isEmpty, "delivered generation is consumed exactly once")
        let stale = LeadWatcher()
        stale.sayModeWhenReady("stale", generation: 0)
        stale.choiceGeneration = 1
        stale.finish()
        check(spoken == ["TurnOver mode"], "changed generation suppresses actual queued output")
        let switched = LeadWatcher()
        switched.reader = .voiceOver
        switched.sayModeWhenReady("switched", generation: 0)
        VoiceOverSpeak.outputTestDriver = { text, route in
            if route == .announcement { switched.choiceGeneration += 1 }
            else { scripts.append(text) }
        }
        switched.finish()
        check(scripts == ["VoiceOver mode"], "generation changing at AX submission prevents later script submission")
        let changedReader = LeadWatcher()
        changedReader.reader = .voiceOver
        changedReader.sayModeWhenReady("reader changed", generation: 0)
        VoiceOverSpeak.outputTestDriver = { text, route in
            if route == .announcement { changedReader.reader = .turnOver }
            else { scripts.append(text) }
        }
        changedReader.finish()
        check(scripts == ["VoiceOver mode"], "reader changing at AX submission prevents later script submission")
        check(VoiceOverTap.testAnnouncementInvalidation(), "actual mute getter reads confirmation after invalidation")
        print("mode wiring: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
