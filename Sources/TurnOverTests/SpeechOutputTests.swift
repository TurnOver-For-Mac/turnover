// SPDX-License-Identifier: GPL-3.0-or-later
// Fake lifecycle and audio clock: no AVAudioEngine, sound, VoiceOver or keyboard changes.
import TurnOverSpeech
import TurnOverCore

func speechOutputTests() {
    test("speech output: zero-frame completion and renderer timeout keep the independent deadline") {
        let health = SpeechOutputHealth()
        let first = health.request(hasWords: true, now: 0)
        check(first != nil, "armed before rendering")
        // Neither the renderer's 1.5/3-second timeout nor an empty didFinish is evidence of output. Further
        // render attempts after either path share the original incident and cannot postpone its deadline.
        let second = health.request(hasWords: true, now: 3)
        check(first === second, "the next renderer cannot consume the zero-frame incident")
        check(health.poll(now: 3.99, sampleTime: nil, hasQueuedAudio: false) == nil, "wait for the independent deadline")
        let failure = health.poll(now: 4, sampleTime: nil, hasQueuedAudio: false)
        check(failure?.stage == .rendering, "zero-frame render reported after its renderer has completed")
        check(failure?.claim() == true, "the owner can hand back")
    }

    test("speech output: converted frames need playback progress, and a long buffer need not finish first") {
        let health = SpeechOutputHealth()
        let request = health.request(hasWords: true, now: 0)
        health.scheduledFrames(for: request, sampleTime: 100)
        check(health.poll(now: 0.25, sampleTime: 100, hasQueuedAudio: true) == nil, "scheduling alone is not playback")
        check(health.poll(now: 0.5, sampleTime: 200, hasQueuedAudio: true) == nil, "advancing node clock proves pipeline progress")
        check(health.poll(now: 10, sampleTime: 300, hasQueuedAudio: true) == nil, "one long playing buffer is healthy without a completion yet")

        let stalled = SpeechOutputHealth()
        let next = stalled.request(hasWords: true, now: 0)
        stalled.scheduledFrames(for: next, sampleTime: 100)
        _ = stalled.poll(now: 1, sampleTime: 100, hasQueuedAudio: true)
        check(stalled.poll(now: 4, sampleTime: 100, hasQueuedAudio: true)?.stage == .playback, "scheduled frames with no clock movement are a playback failure")
    }

    test("speech output: actual playback completion invalidates a failure already waiting on main") {
        let health = SpeechOutputHealth()
        let request = health.request(hasWords: true, now: 0)
        health.scheduledFrames(for: request, sampleTime: nil)
        let delayed = health.poll(now: 4, sampleTime: nil, hasQueuedAudio: true)
        health.playbackProgress(for: request)
        check(delayed?.claim() == false, "recovered output prevents stale handback")
        check(health.poll(now: 8, sampleTime: nil, hasQueuedAudio: false) == nil, "completed output retired the incident")
    }

    test("speech output: earlier queued speech defers a failed next render until output stops") {
        let health = SpeechOutputHealth()
        _ = health.request(hasWords: true, now: 0)
        _ = health.poll(now: 1, sampleTime: 100, hasQueuedAudio: true)
        _ = health.poll(now: 3, sampleTime: 200, hasQueuedAudio: true)
        check(health.poll(now: 5, sampleTime: 300, hasQueuedAudio: true) == nil, "previous paragraph is still playing")
        check(health.poll(now: 8.99, sampleTime: 300, hasQueuedAudio: false) == nil, "allow four seconds after prior output")
        check(health.poll(now: 9, sampleTime: 300, hasQueuedAudio: false)?.stage == .rendering, "unresolved render eventually hands back once output has stopped")
    }

    test("speech output: cancellation and replaced utterances reject late audio and stale handback") {
        let health = SpeechOutputHealth()
        let old = health.request(hasWords: true, now: 0)
        let delayed = health.poll(now: 4, sampleTime: nil, hasQueuedAudio: false)
        health.cancel()
        let next = health.request(hasWords: true, now: 5)
        health.scheduledFrames(for: old, sampleTime: 0)
        health.playbackProgress(for: old)
        check(delayed?.claim() == false, "cancel invalidated delivery before main handled it")
        check(health.poll(now: 8, sampleTime: nil, hasQueuedAudio: false) == nil, "new utterance gets its own deadline")
        check(next !== old, "replacement has a separate incident")
        check(health.poll(now: 9, sampleTime: nil, hasQueuedAudio: false)?.claim() == true, "old audio cannot hide replacement failure")
    }

    test("speech output: deliberate pause off and beeps never trigger handback") {
        let health = SpeechOutputHealth()
        _ = health.request(hasWords: true, now: 0)
        let beforePause = health.poll(now: 4, sampleTime: nil, hasQueuedAudio: false)
        health.setPaused(true)
        check(beforePause?.claim() == false, "pause invalidated an already posted failure")
        check(health.request(hasWords: true, now: 5) == nil, "paused output is not required")
        health.setPaused(false)
        _ = health.request(hasWords: true, now: 10)
        check(health.poll(now: 13, sampleTime: nil, hasQueuedAudio: false) == nil, "resume has fresh timing")
        let beforeOff = health.poll(now: 14, sampleTime: nil, hasQueuedAudio: false)
        health.setEnabled(false)
        check(beforeOff?.claim() == false, "off/beeps invalidated posted failure")
        check(health.request(hasWords: true, now: 20) == nil, "off/beeps does not arm")
        check(health.poll(now: 100, sampleTime: nil, hasQueuedAudio: false) == nil, "silence by choice is not a fault")
        health.setEnabled(true)
        check(health.request(hasWords: false, now: 100) == nil, "a blank or non-word utterance does not arm")
    }

    test("speech output: deferred wake recovery and duplicate deliveries hand back once") {
        let health = SpeechOutputHealth()
        _ = health.request(hasWords: true, now: 0)
        // During wake grace the owner declines to claim. The incident must be offered again after grace,
        // rather than consumed by its first notification. The effects here stand for releasing the mute lease,
        // stopping interception and starting VoiceOver; no real reader is touched by this test.
        let duringWake = health.poll(now: 4, sampleTime: nil, hasQueuedAudio: false)
        check(duringWake != nil, "failure available for a live owner to defer")
        let afterWake = health.poll(now: 30, sampleTime: nil, hasQueuedAudio: false)
        var voiceOverMuted = true
        var interceptingKeys = true
        var handbacks = 0
        guard let duringWake, let afterWake else { check(false, "both deliveries available"); return }
        let deferredStates: [SpeechOutputRecovery.ReaderState] = [.inactive, .intentionallyQuiet, .waking]
        for state in deferredStates {
            check(!SpeechOutputRecovery.receive(duringWake, isCurrent: true, state: state) { handbacks += 1 }, "reader intent/wake state defers recovery")
        }
        check(!SpeechOutputRecovery.receive(duringWake, isCurrent: false, state: .required) { handbacks += 1 }, "a new reader choice or player rejects stale delivery")
        for delivery in [afterWake, duringWake, afterWake] {
            SpeechOutputRecovery.receive(delivery, isCurrent: true, state: .required) {
                voiceOverMuted = false
                interceptingKeys = false
                handbacks += 1
            }
        }
        expect(handbacks, 1, "one handback across delayed and duplicate callbacks")
        check(!voiceOverMuted && !interceptingKeys, "accepted failure releases output and input together")
        check(health.poll(now: 40, sampleTime: nil, hasQueuedAudio: false) == nil, "claimed incident is not delivered again")
    }
}
