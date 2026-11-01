// SPDX-License-Identifier: GPL-3.0-or-later
// The core (NVDA: core.main): loads the configuration, brings up speech, the
// add-ons and the accessibility handler, and takes them down again. The app
// decides when (VoiceOver off: on; VoiceOver on: off) and owns the keyboard.
import Foundation
import AVFoundation
import AppKit
import TurnOverSpeech
import ApplicationServices
@_exported import TurnOverAX

public enum Core {
    /// The main voice last heard making sound (set as speech starts, from the speech queue).
    nonisolated static let voiceHeard = Locked("")
    /// Lend the app in front to VoiceOver for some seconds, then take it back (set by the app: its LeadWatcher). For
    /// apps that build their accessibility only for VoiceOver: Excel's grid (Day 3, 10 Oct 2026).
    nonisolated(unsafe) public static var lendToVoiceOver: ((TimeInterval) -> Void)?   // main thread only
    /// When "please wait" was last said for an app that stopped answering (main thread).
    static var lastWaitSpoken = Date.distantPast
    /// Written once, on the main thread, as the start ends; read by the start watchdog's own thread (a single flag).
    nonisolated(unsafe) public private(set) static var started = false
    public private(set) static var active = false

    /// The step the start is at, for the startup watchdog (the app): a start that hung in the audio engine or the
    /// voices left TurnOver silent for five hours on 17 Oct 2026 (the log stopped at "recipes loaded").
    nonisolated(unsafe) public static var startStep = "not started"

    public static func start() throws {
        guard !started else { return }
        startStep = "settings"
        config = Config.load()
        KeySettings.refresh()
        Recipes.load(plugins: [])
        // Every accessibility question waits at most 2 s (macOS's default is about 6): a page that stops answering
        // (Safari's web content, 2 Oct 2026) froze TurnOver call after call until the watchdog relaunched it.
        startStep = "accessibility"
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 2.0)
        // E12: an application that stops answering is left alone for a few seconds; say so, for the one in front.
        AXHealth.onSlowRest = { pid in DispatchQueue.main.async { Log.info("pid \(pid) slow to answer; resting it 1.5 s") } }
        AXHealth.onUnresponsive = { pid in
            DispatchQueue.main.async {
                guard let app = NSRunningApplication(processIdentifier: pid) ?? NSWorkspace.shared.frontmostApplication,
                      NSWorkspace.shared.frontmostApplication.map({ $0.processIdentifier == pid || app.bundleIdentifier?.hasPrefix("com.apple.WebKit") == true }) ?? false else {
                    Log.info("pid \(pid) not answering (in the background)"); return
                }
                let name = app.bundleIdentifier?.hasPrefix("com.apple.WebKit") == true ? (NSWorkspace.shared.frontmostApplication?.localizedName ?? "the page") : (app.localizedName ?? "the application")
                Log.error("\(name) (pid \(pid)) not answering; leaving it for 3 s")
                // "Please wait", not "not responding": a slow answer is usually the app busy (a page loading), and
                // "not responding" alarmed for something that came right a moment later (5 Oct 2026). Once in 10 s.
                // When it answers again, look at the focus afresh: the stall can leave TurnOver on a focus that went
                // nowhere (Safari, 6 Oct 2026: after "please wait" the arrows said nothing until an app switch).
                if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier {
                    for delay in [4.0, 8.0] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            guard Core.active, NSWorkspace.shared.frontmostApplication?.processIdentifier == front else { return }
                            // Only when TurnOver was left with nothing: no page, an empty one, or a nameless group.
                            let lost = API.focusTreeInterceptor.map { $0.buffer.lines.isEmpty } ?? (API.focusObject.map { $0.axRole == "AXGroup" && $0.name.isEmpty } ?? true)
                            if lost { AXHandler.shared.refocus(pid: front) }
                        }
                    }
                }
                guard Date().timeIntervalSince(Core.lastWaitSpoken) > 10 else { return }
                // A direct app speaks for itself: TurnOver says nothing there, "please wait" included.
                guard InputManager.directPid != pid else { return }
                Core.lastWaitSpoken = Date()
                Speech.speakMessage(String(localized: "please wait", comment: "Spoken message"))
            }
        }
        startStep = "the audio engine"
        Speech.player = try SpeechPlayer(voice: config.speech.voice, rate: config.speech.rate)
        startStep = "the voice"
        Speech.player.volume = Float(config.speech.volume) / 100
        Speech.player.pitch = config.speech.pitchMultiplier
        Speech.player.onOutputChange = { line in Log.io(line) }
        if !config.speech.outputDevice.isEmpty {
            Log.info("speech: output chosen in settings: \(config.speech.outputDevice)")
            Speech.player.outputDeviceUID = config.speech.outputDevice
        }
        // How long from the key to the first sound (the owner found Safari's settings sluggish, 4 Oct 2026): logged, no text.
        Speech.player.onFirstAudio = { t in
            let render = t.requestToFirstBufferMs ?? -1
            let sinceKey = Date().timeIntervalSince(InputManager.lastKeyDownAt) * 1000
            // (No key yet since the start: the figure was the age of the universe in ms, 8 Oct 2026.)
            let key = sinceKey > 3_600_000 ? "no key yet" : String(format: "%.0f ms after the last key", sinceKey)
            Log.io(String(format: "speech: first audio %.0f ms after the request, %@ (last cancel %.0f ms)", render, key, Speech.player.lastCancelMs))
            if t.voice == config.speech.voice { Core.voiceHeard.value = t.voice }
        }
        // A voice that gives no sound: back to one that does, and say so (a tester, AppleVis, 7 Oct 2026: a voice chosen
        // in the menu left TurnOver silent, with no way to hear the menu to change it back).
        Speech.player.onVoiceSilent = { silent in
            DispatchQueue.main.async {
                // A language's own voice: that language goes back to automatic; the main voice stays.
                if silent != config.speech.voice {
                    Log.warning("speech: \(silent) gave no sound twice; its language goes back to automatic")
                    config.speech.languageVoices = config.speech.languageVoices.filter { $0.value != silent }
                    config.save(); Languages.forget()
                    return
                }
                // A voice already heard in this session does speak in TurnOver: silence now is something else (the
                // main thread stalled 12 s and a tester's Alex was swapped for Reed, for good;, 12 Oct 2026).
                if Core.voiceHeard.value == silent { Log.warning("speech: \(silent) was silent twice, but it has spoken this session; kept"); return }
                let fallbacks = ["com.apple.eloquence.en-GB.Reed", "com.apple.eloquence.en-US.Reed"]
                let fallback = fallbacks.first { $0 != silent && AVSpeechSynthesisVoice(identifier: $0) != nil }
                    ?? AVSpeechSynthesisVoice(language: nil)?.identifier ?? AVSpeechSynthesisVoice(language: "en-GB")?.identifier ?? AVSpeechSynthesisVoice(language: "en-US")?.identifier
                guard let fallback, fallback != silent else { return }
                let name = AVSpeechSynthesisVoice(identifier: silent)?.name ?? String(localized: "That voice", comment: "A voice with no name")
                Log.warning("speech: \(silent) gave no sound twice; back to \(fallback)")
                config.speech.voice = fallback
                config.speech.languageVoices = config.speech.languageVoices.filter { $0.value != silent }
                config.save(); Languages.forget()
                Speech.player.voiceIdentifier = fallback
                Speech.cancel()
                Speech.speakMessage(String(localized: "\(name) doesn't speak in TurnOver, so TurnOver is back to \(AVSpeechSynthesisVoice(identifier: fallback)?.name ?? String(localized: "its usual voice", comment: "TurnOver's usual voice, when it has no name")). Choose another in the TurnOver menu, Settings, Speech.", comment: "A silent voice replaced: the voice, then the one used instead"))
            }
        }
        startStep = "the commands"
        Log.info("speech: \(config.speech.voice) rate \(config.speech.rate), \(Int(Speech.player.sampleRate)) Hz, output latency \(String(format: "%.1f", Speech.player.outputLatencySeconds * 1000)) ms")
        _ = GlobalCommands.shared
        if Edition.includesPlugins { GlobalPluginHandler.shared.register(ProfilesPlugin.self) }   // first: the user's own fixes
        GlobalPluginHandler.shared.register(MenuNavigationPlugin.self)
        GlobalPluginHandler.shared.register(VoiceOverKeysPlugin.self)
        GlobalPluginHandler.shared.register(HeldListPlugin.self)
        GlobalPluginHandler.shared.register(SettingsPanePlugin.self)
        started = true
    }

    /// The reader is reading: watch the applications and speak.
    public static func activate() {
        guard started, !active else { return }
        active = true
        // Speech switched off by the trackpad's three-finger double-tap ends with the app: nothing else resets it, and
        // coexisting that was both readers silent (a code review on 17 Oct 2026).
        if Speech.mode == .off { Speech.mode = .talk; Log.info("speech: on again (it was off by gesture)") }
        AXHandler.shared.start()
        // Coexisting, VoiceOver's braille server has the display; two drivers on one display is a fight (17 Oct 2026).
        if Coexist.on { Log.info("braille: off while VoiceOver stays on (its braille server has the display)") } else { BrailleDisplays.shared.start() }
        NewToTry.announceIfUpdated()
        Ducking.apply()
        KokoroVoice.start()   // only where the "kokoro" default is set
        SettingsBridge.start()   // TurnOver Settings, the window (18 Oct 2026)
        SpeechPort.shared.start(port: config.games.bridgePort)   // apps that speak through TurnOver, with the user's say-so
        InputSourceAnnouncer.start()   // the keyboard input source said as it changes ()
        SettingsProfiles.start()   // VO-X Activities / NVDA's configuration profiles, by app
        PluginLibrary.startDailyChecks()   // the withdrawn line acted on (once per run, however often TurnOver activates)
    }

    /// The reader is quiet (VoiceOver has the keyboard).
    public static func deactivate() {
        ObjectNavigator.shared.cancelWindowSearch()
        guard active else { return }
        active = false
        InputManager.isInputHelpActive = false
        SayAll.stop()
        AXHandler.shared.stop()
        BrailleDisplays.shared.stop()   // VoiceOver drives the display again
        Speech.cancel()
        Ducking.stop()   // VoiceOver reads now: other apps' sound goes back to them, unmuted
    }

    public static func stop() {
        deactivate()
        GlobalPluginHandler.shared.terminateAll()
        started = false
    }
}
