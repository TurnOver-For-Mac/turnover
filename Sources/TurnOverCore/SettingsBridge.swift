// SPDX-License-Identifier: GPL-3.0-or-later
// TurnOver Settings (18 Oct 2026: "why not a settings app now?"): a small app of its own inside TurnOver.app,
// read by TurnOver like any other app. (TurnOver can't read a window of its own process: its accessibility calls to
// itself would wait on its own main thread.) The app never writes the settings file: it sends each change here as a
// patch, part of the settings file's JSON ({"speech": {"rate": 0.6}}), TurnOver merges it into its settings, saves,
// puts it into effect, and answers with the whole settings so the app shows what is really set.
// A few settings live outside the file (the say all voice, CoExist): their patches start with "_".
// The talk goes through TurnOver's control channel (TurnOverControl), which only programs signed by TurnOver's own
// developer may use: before a code review on 18 Oct 2026 it was distributed notifications, which any program could
// post (and change TurnOver's settings with) or hear (and read them all).
import Foundation
import AppKit
import TurnOverControl
import TurnOverSpeech

public enum SettingsBridge {
    private static var started = false
    /// Restart TurnOver (set by the app): CoExist changes need it.
    public static var restart: (() -> Void)?

    /// The control channel up, and the settings' ops on it: "subscribe" (Settings opening: the settings now, and
    /// every change after), "ask" (the settings now), "patch" (a change).
    public static func start() {
        guard !started else { return }
        started = true
        let server = ControlServer.shared
        server.log = { Log.info($0) }
        server.start(path: AppPaths.file("control.sock").path)
        server.handlers["subscribe"] = { _, reply in Log.info("settings app: connected"); sendState(to: reply) }
        server.handlers["ask"] = { _, reply in sendState(to: reply) }
        server.handlers["patch"] = { message, _ in if let json = message["json"] as? String { apply(json) } }
    }

    /// The settings as they are now, and the ones kept outside the file, for the app to show: to the one that asked,
    /// or to every open Settings window.
    static func sendState(to reply: (@Sendable ([String: Any]) -> Void)? = nil) {
        guard let data = try? JSONEncoder().encode(config),
              var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        dict["_kokoroAvailable"] = KokoroVoice.available
        dict["_kokoroMode"] = KokoroVoice.mode
        dict["_kokoroVoice"] = KokoroVoice.voice
        dict["_kokoroSpeed"] = KokoroVoice.speed
        dict["_coexist"] = Coexist.wouldBeOn
        dict["_outputDevices"] = SpeechPlayer.outputDevices().map { ["uid": $0.uid, "name": $0.name] }
        dict["_speechPortApps"] = SpeechPort.shared.appDecisions.map { ["id": $0.id, "name": $0.name, "allowed": $0.allowed] }
        guard let out = try? JSONSerialization.data(withJSONObject: dict), let s = String(data: out, encoding: .utf8) else { return }
        if let reply { reply(["op": "state", "json": s]) } else { ControlServer.shared.broadcast(["op": "state", "json": s]) }
    }

    static func apply(_ json: String) {
        guard let data = json.data(using: .utf8), let patch = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        // Outside the file.
        if let m = patch["_kokoroMode"] as? String { KokoroVoice.mode = m == "off" ? "off" : "reading" }
        if let v = patch["_kokoroVoice"] as? String, KokoroVoice.englishVoices.contains(v) { KokoroVoice.voice = v; KokoroVoice.mode = "reading"; KokoroVoice.preview(v) }
        if let s = patch["_kokoroSpeed"] as? Double { KokoroVoice.speed = min(2, max(0.6, s)) }
        if let a = patch["_speechPortAllowed"] as? [String: Any], let id = a["id"] as? String, let on = a["allowed"] as? Bool { SpeechPort.shared.setAllowed(id, on) }
        if let on = patch["_coexist"] as? Bool, on != Coexist.wouldBeOn {
            UserDefaults.standard.set(on, forKey: "coexist")
            Speech.speakMessage(on ? "CoExist on. TurnOver restarts." : "CoExist off. TurnOver restarts.")
            Log.info("settings app: CoExist \(on ? "on" : "off"); restarting")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { (restart ?? TurnOverMenu.shared.relaunch)?() }
            return
        }
        // The file's settings: merged section by section, then read back through Config, so a value of the wrong kind
        // is simply left as it was.
        let filePatch = patch.filter { !$0.key.hasPrefix("_") }
        if !filePatch.isEmpty {
            guard let current = try? JSONEncoder().encode(config),
                  var dict = (try? JSONSerialization.jsonObject(with: current)) as? [String: Any] else { return }
            for (section, value) in filePatch {
                if var existing = dict[section] as? [String: Any], let changes = value as? [String: Any] {
                    for (k, v) in changes { existing[k] = v }
                    dict[section] = existing
                } else { dict[section] = value }
            }
            guard let merged = try? JSONSerialization.data(withJSONObject: dict), let next = try? JSONDecoder().decode(Config.self, from: merged) else {
                Log.warning("settings app: a change TurnOver couldn't read; nothing changed"); sendState(); return
            }
            let before = config
            config = next
            config.save()
            SettingsProfiles.applyLive()
            KeySettings.refresh()
            TurnOverMenu.shared.onGeneralChanged?()
            // The hooks the menu's own items run (the Settings window is the menu's equal since 21 Oct 2026).
            if before.general.screenCurtain != next.general.screenCurtain { TurnOverMenu.shared.onScreenCurtainChanged?() }
            if before.speech.outputDevice != next.speech.outputDevice {
                Speech.player.outputDeviceUID = next.speech.outputDevice.isEmpty ? nil : next.speech.outputDevice
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Speech.speakMessage("Speech on \(Speech.player.outputDescription)") }
            }
            if before.general.keyboardStyle != next.general.keyboardStyle { GlobalCommands.setKeyboardStyle(next.general.style) }
            if before.braille.bluetooth != next.braille.bluetooth, next.braille.bluetooth { BrailleDisplays.shared.lookNow() }
            if before.speech.voice != next.speech.voice { Languages.forget() }
            // The key layer where VoiceOver reads follows its own setting too (the style's change starts or stops it above).
            if before.general.keysWhereVoiceOverReads != next.general.keysWhereVoiceOverReads { GlobalCommands.onKeyboardStyleChanged?() }
            Log.info("settings app: \(filePatch.keys.sorted().joined(separator: ", ")) changed")
        }
        sendState()
    }

    /// Opens TurnOver Settings (inside TurnOver.app).
    public static func open() {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Applications/TurnOver Settings.app")
        guard FileManager.default.fileExists(atPath: url.path) else { Speech.speakMessage("TurnOver Settings isn't in this build"); return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { Log.warning("settings app: couldn't open: \(error)") }
        }
    }
}
