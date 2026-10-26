// SPDX-License-Identifier: GPL-3.0-or-later
// Settings asks for metadata and explicit edits through the existing authenticated control channel.
import AppKit
import TurnOverControl

public enum KeyboardEditor {
    private static var context: [KeyboardMap.Source] = []
    private static var contextName = "Global commands"
    private static var contextStyle = ""
    private static var contextLayout = ""
    private static var globalSources: [KeyboardMap.Source]?
    private static var globalCommands: KeyboardMap.Source?
    private static var map: KeyboardMap?
    private static var mapSignature = ""

    private struct Edit {
        var request: String
        var owner: UUID
        var command: String
        var oldKey: String?
        var overrides: [String: String]
        var style: String
        var layout: String
        var signature: String
        var candidate: KeyboardEditing.Candidate?
        var reply: @Sendable ([String: Any]) -> Void
    }
    private static var edit: Edit?
    private static var timeout: Task<Void, Never>?

    /// Called before Settings takes focus. Only declarations and availability results are retained, not the
    /// application's accessibility objects or script closures (23 Oct 2026).
    public static func rememberContext() {
        guard let pid = API.focusPid,
              AppModuleHandler.shared.appModule(for: pid).bundleIdentifier != TurnOverSettingsAppModule.bundleID else { return }
        contextName = AppModuleHandler.shared.appModule(for: pid).appName
        context = [KeyboardMap.Source(AppModuleHandler.shared.appModule(for: pid))]
        if let document = API.focusTreeInterceptor { context.append(.init(document)) }
        if let focus = API.focusObject { context.append(.init(focus)) }
        context += API.focusAncestors.map { .init($0, ancestor: true) }
        contextStyle = config.general.keyboardStyle
        contextLayout = config.keyboard.layout
        globalSources = sourcesForGlobals()
        globalCommands = KeyboardMap.Source(GlobalCommands.shared, reference: "NVDA style")
        map = nil
        // An already-open Settings window does not recreate its view when another app sends it to the front.
        sendState { ControlServer.shared.broadcast($0) }
    }

    private static var configurationSignature: String {
        [config.general.keyboardStyle, config.keyboard.layout, config.general.turnOverKey,
         String(config.keyboard.optionCommander), String(config.keyboard.numpadCommander), String(config.keyboard.keypadCommands)].joined(separator: ":")
    }

    private static func sourcesForGlobals() -> [KeyboardMap.Source] {
        let plugins = GlobalPluginHandler.shared.plugins
        var sources = plugins.map { KeyboardMap.Source($0, reference: $0 is VoiceOverKeysPlugin ? "VoiceOver style" : nil) }
        if !plugins.contains(where: { $0 is VoiceOverKeysPlugin }) { sources.append(.init(VoiceOverKeysPlugin(), reference: "VoiceOver style")) }
        return sources
    }

    private static func catalogue() -> KeyboardMap {
        if let map, mapSignature == configurationSignature { return map }
        if contextStyle != config.general.keyboardStyle || contextLayout != config.keyboard.layout {
            context = []; globalSources = nil; globalCommands = nil; contextName = "Global commands"
        }
        let globals = globalCommands ?? KeyboardMap.Source(GlobalCommands.shared, reference: "NVDA style")
        var sources = globalSources ?? sourcesForGlobals()
        let vo = sources.first { $0.reference == "VoiceOver style" }
        sources += context
        sources += [globals, KeyboardMap.Source(KeypadCommands.shared)]
        func voCommand(_ key: String) -> String? {
            let id = normalizeGestureIdentifier(key)
            return vo?.bindings.first { $0.0 == id }?.1.first
                ?? globals.bindings.first { $0.0 == id }?.1.first { !$0.hasPrefix("nvda") }
        }
        let macPad = Keypad.bindings(windows: false, voiceOverCommand: voCommand)
        let windowsPad = Keypad.bindings(windows: true, voiceOverCommand: voCommand)
        let enabled = config.general.windowsKeys ? config.keyboard.keypadCommands : config.keyboard.numpadCommander
        let made = KeyboardMap(sources: sources, layout: config.keyboard.layout,
                               keypad: enabled ? (config.general.windowsKeys ? windowsPad : macPad) : [],
                               keypadReferences: macPad.map { ($0.0, $0.1, "VoiceOver keypad") } + windowsPad.map { ($0.0, $0.1, "NVDA keypad") },
                               styleKeys: StyleKeymap.keys(for: config.general.style),
                               sayAllKeys: StyleKeymap.sayAllKeys(for: config.general.style))
        map = made; mapSignature = configurationSignature
        return made
    }

    static func settingsChanged() {
        cancel(message: "Keyboard settings changed. Record the key again.")
        map = nil; globalSources = nil; globalCommands = nil
    }

    private static func sendState(to reply: @Sendable ([String: Any]) -> Void) {
        let state = catalogue().state(overrides: config.keyboard.userGestures, context: contextName,
                                      style: config.general.style.spokenName, history: config.keyboard.keyChanges)
        send(state, op: "keyboardState", to: reply)
    }

    private static func send<T: Encodable>(_ value: T, op: String, request: String = "", to reply: @Sendable ([String: Any]) -> Void) {
        guard let data = try? JSONEncoder().encode(value), let json = String(data: data, encoding: .utf8) else { return }
        reply(["op": op, "request": request, "json": json])
    }

    public static func handle(_ message: [String: Any], reply: @escaping @Sendable ([String: Any]) -> Void) {
        let request = message["request"] as? String ?? ""
        let action = message["action"] as? String ?? ""
        func result(_ text: String, saved: Bool = false) {
            reply(["op": "keyboardResult", "request": request, "message": text, "saved": saved])
            sendState(to: reply)
        }
        switch action {
        case "list": sendState(to: reply)
        case "cancel":
            if edit?.request == request { cancel(message: "Recording cancelled.") }
        case "capture":
            guard !request.isEmpty, settingsInFront,
                  let command = message["command"] as? String, catalogue().contains(command: command) else {
                result("Bring TurnOver Settings to the front and choose a command."); return
            }
            cancel(message: "Recording cancelled.")
            guard InputManager.captureNext == nil else { result("Another key prompt is open. Close it and try again."); return }
            let owner = UUID()
            edit = Edit(request: request, owner: owner, command: command, oldKey: message["oldKey"] as? String,
                        overrides: config.keyboard.userGestures, style: config.general.keyboardStyle,
                        layout: config.keyboard.layout, signature: configurationSignature, reply: reply)
            InputManager.beginCapture(owner: owner, while: { settingsInFront && edit?.owner == owner }) { gesture in
                guard var current = edit, current.owner == owner else { return }
                timeout?.cancel(); timeout = nil
                guard settingsInFront, let gesture else { cancel(message: "Recording cancelled."); return }
                let id = UserGestures.storedIdentifier(of: gesture)
                let candidate = catalogue().candidate(id, for: current.command, overrides: current.overrides)
                current.candidate = candidate; edit = current
                send(candidate, op: "keyboardCandidate", request: request, to: reply)
                Speech.speakMessage(([candidate.label] + (candidate.error.map { [$0] } ?? candidate.warnings)).joined(separator: ". "))
            }
            reply(["op": "keyboardRecording", "request": request])
            Speech.speakMessage("Press the new key. Escape cancels. Recording ends after 30 seconds.")
            timeout = Task {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard edit?.owner == owner else { return }
                cancel(message: "Recording timed out. No keys changed.")
            }
        case "save":
            guard let current = edit, current.request == request, settingsInFront,
                  current.style == config.general.keyboardStyle, current.layout == config.keyboard.layout,
                  current.signature == configurationSignature,
                  current.overrides == config.keyboard.userGestures,
                  let candidate = current.candidate, candidate.error == nil,
                  let next = catalogue().assigning(candidate.id, to: current.command, replacing: current.oldKey, in: current.overrides) else {
                cancel(message: "The assignment changed or is no longer available. Record the key again.")
                result("The assignment changed or is no longer available. Record the key again."); return
            }
            finish()
            if let oldKey = current.oldKey,
               let change = KeyboardChange(oldKey: oldKey, newKey: candidate.id, before: current.overrides, after: next) {
                config.keyboard.keyChanges = Array((config.keyboard.keyChanges + [change]).suffix(100))
            }
            config.keyboard.userGestures = next; config.save(); KeySettings.refresh()
            Log.info("keyboard editor: \(candidate.id) assigned to \(current.command)")
            result("\(candidate.label) assigned.", saved: true)
        case "remove":
            guard let key = message["key"] as? String, let command = message["command"] as? String,
                  let next = catalogue().removing(key, from: command, in: config.keyboard.userGestures) else {
                result("That assignment changed or is an essential key. Refresh the list and try again."); return
            }
            config.keyboard.userGestures = next; config.save(); KeySettings.refresh()
            Log.info("keyboard editor: \(key) removed from \(command)")
            result("\(UserGestures.spoken(key)) now goes to the application.", saved: true)
        case "restoreChange":
            guard let id = message["change"] as? String,
                  let change = config.keyboard.keyChanges.first(where: { $0.id == id }),
                  let restored = change.restoring(in: config.keyboard.userGestures) else {
                result("One of those assignments changed. Refresh the list before restoring it."); return
            }
            config.keyboard.userGestures = restored
            config.keyboard.keyChanges.removeAll { $0.id == id }
            config.save(); KeySettings.refresh()
            result("Both keys restored to their previous assignments.", saved: true)
        case "restore":
            guard let key = message["key"] as? String, let expected = message["target"] as? String,
                  config.keyboard.userGestures[key] == expected else { result("That assignment changed. Refresh the list and try again."); return }
            UserGestures.clear(key); KeySettings.refresh()
            Log.info("keyboard editor: \(key) restored")
            result("\(UserGestures.spoken(key)) restored to its default.", saved: true)
        default: result("Unknown keyboard edit.")
        }
    }

    private static var settingsInFront: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == TurnOverSettingsAppModule.bundleID
    }

    private static func finish() {
        if let edit { InputManager.cancelCapture(owner: edit.owner) }
        edit = nil; timeout?.cancel(); timeout = nil
    }

    private static func cancel(message: String) {
        guard let previous = edit else { return }
        finish()
        previous.reply(["op": "keyboardResult", "request": previous.request, "message": message, "saved": false])
    }
}
