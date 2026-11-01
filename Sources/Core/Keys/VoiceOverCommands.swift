// SPDX-License-Identifier: GPL-3.0-or-later
// VoiceOver's customisations, cloned (17 Oct 2026: "I want TurnOver to clone VoiceOver, down to all
// customisations"). The export carries the Keyboard Commander's letters (right Option with a letter: a VoiceOver
// command, a Shortcut, or an AppleScript file), the custom key bindings (a VO key given to a command, or taken
// away), and whether the Keyboard and NumPad Commanders are on. The settings copy puts each into TurnOver's own
// keys (UserGestures): a VoiceOver command runs the TurnOver command that answers it, a Shortcut runs by name through
// the shortcuts tool, a script file runs through osascript (it is the person's own).
import Foundation
import CryptoKit

public enum VoiceOverCommands {
    /// VoiceOver's command identifiers by their English names, from VoiceOver's own map.
    nonisolated(unsafe) private static var namesById: [String: String] = {
        var out: [String: String] = [:]
        let url = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/ScreenReader.framework/Versions/A/Resources/SCRStringsToCommandsMap.scrconfig")
        if let data = try? Data(contentsOf: url), let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for (name, id) in dict { if let id = id as? String, out[id] == nil { out[id] = name } }
        }
        return out
    }()
    public static func englishName(of id: String) -> String { namesById[id] ?? id.components(separatedBy: ".").last ?? id }

    /// TurnOver's command for a VoiceOver command, by VoiceOver's English name: the scripts TurnOver answers on the
    /// same VO key, and a few of its own for what has no key.
    static let byEnglish: [String: String] = [
        "describe item in voiceover cursor": "vo_describeItem", "describe item in mouse pointer": "vo_pointerItem",
        "copy last phrase to clipboard": "vo_copyLast", "read last phrase": "vo_repeatLast", "repeat last phrase": "vo_repeatLast",
        "mute speech toggle": "voiceOverMuteSpeech", "pause or resume speaking": "voiceOverPauseSpeech",
        "increase rate": "speechRateUp", "decrease rate": "speechRateDown", "increase volume": "speechVolumeUp", "decrease volume": "speechVolumeDown",
        "increase pitch": "speechPitchUp", "decrease pitch": "speechPitchDown",
        "open notifications guide": "vo_notifications", "open help menu": "vo_helpMenu", "open commands menu": "vo_helpMenu",
        "open item chooser": "vo_itemChooser", "open rotor": "vo_rotor", "open application chooser": "vo_appSummary", "open window chooser": "vo_windowSummary",
        "move keyboard focus to voiceover cursor": "vo_focusToCursor", "move voiceover cursor to keyboard focus": "vo_cursorToFocus",
        "move mouse pointer to voiceover cursor": "vo_mouseToCursor", "move voiceover cursor to mouse pointer": "vo_cursorToMouse",
        "describe position of item in voiceover cursor": "vo_itemGeometry", "describe size of item in voiceover cursor": "vo_itemGeometry",
        "describe position of window": "vo_windowGeometry", "describe size of window": "vo_windowGeometry",
        "read current line": "vo_line", "read current word": "vo_word", "read current sentence": "vo_sentence", "read current paragraph": "vo_paragraph",
        "read everything from voiceover cursor": "vo_readContents", "read everything in window": "vo_readWindow", "read everything to voiceover cursor": "vo_readToHere",
        "speak the time": "dateTime", "speak date": "dateTime", "toggle screen curtain": "vo_screenCurtain", "toggle keyboard help": "vo_keyboardHelp",
        "go to dock": "vo_dock", "go to desktop": "vo_desktop", "go to menu bar": "vo_menuBar", "open shortcut menu": "vo_shortcutMenu",
        "toggle quick nav": "vo_arrowQuickNav", "report text attributes": "vo_attributes",
    ]

    /// The key TurnOver gives a VoiceOver command string from the export.
    public static func target(for command: String) -> UserGestures.Target {
        if command.hasPrefix("SCRWorkspace.customRunShortcut:") { return .shortcut(String(command.dropFirst("SCRWorkspace.customRunShortcut:".count))) }
        if command.hasPrefix("SCRWorkspace.customOpenScript:") { return .file(String(command.dropFirst("SCRWorkspace.customOpenScript:".count))) }
        if let name = namesById[command], let script = byEnglish[name] { return .script(script) }
        return .voiceOver(command)
    }

    /// A Shortcut by its identifier, run by name through the shortcuts tool.
    public static func runShortcut(_ id: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let list = Process(); list.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts"); list.arguments = ["list", "--show-identifiers"]
            let pipe = Pipe(); list.standardOutput = pipe; list.standardError = FileHandle.nullDevice
            try? list.run(); list.waitUntilExit()
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard let line = text.split(separator: "\n").first(where: { $0.contains(id) }), let open = line.lastIndex(of: "(") else {
                onMain { Speech.speakMessage("That shortcut isn't on this Mac") }; return
            }
            let name = line[..<open].trimmingCharacters(in: .whitespaces)
            Log.info("user keys: running the shortcut \"\(name)\"")
            // Disclaimed: a shortcut answers for its own permissions, as when run from the Shortcuts app, rather than
            // borrowing TurnOver's (a code review on 20 Oct 2026).
            onMain {
                if DisclaimedSpawn.run("/usr/bin/shortcuts", arguments: ["run", name], directory: nil, exited: { _ in }) == nil {
                    Log.warning("user keys: the shortcut \"\(name)\" could not be started")
                }
            }
        }
    }

    /// The person's own AppleScript file, run as VoiceOver would run it: with TurnOver's permissions, so a script
    /// that needs them (a Bluetooth toggle) works. Because of that, a script runs only once the person has said yes to
    /// it, and again whenever the file changes: another program could otherwise add a key to TurnOver's settings, or
    /// change a script, and borrow TurnOver's permissions (a code review on 20 Oct 2026).
    public static func runScriptFile(_ path: String) {
        let full = (path as NSString).expandingTildeInPath
        let name = (path as NSString).lastPathComponent
        guard FileManager.default.fileExists(atPath: full), let data = FileManager.default.contents(atPath: full) else { Speech.speakMessage("The script \(name) isn't there"); return }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var approved = UserDefaults.standard.dictionary(forKey: "approvedScripts") as? [String: String] ?? [:]
        guard approved[full] == digest else {
            let changed = approved[full] != nil
            Log.info("user keys: the script \(full) needs a yes first (\(changed ? "changed" : "new"))")
            TurnOverMenu.shared.openList("\(changed ? "The script \(name) has changed since you allowed it" : "Run the script \(name)?"). It runs with TurnOver's permissions", items: [
                MenuItem("Run it, and allow it from now on", .action {
                    approved[full] = digest
                    UserDefaults.standard.set(approved, forKey: "approvedScripts")
                    VoiceOverCommands.startScript(full)
                }),
                MenuItem("Don't run it", .action { Speech.speakMessage("not run") }),
            ])
            return
        }
        startScript(full)
    }

    private static func startScript(_ full: String) {
        Log.info("user keys: running the script \(full)")
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript"); p.arguments = [full]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run()
        }
    }
}
