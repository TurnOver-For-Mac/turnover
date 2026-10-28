// SPDX-License-Identifier: GPL-3.0-or-later
// Input (NVDA: inputCore.InputManager). Every key down comes here from the
// keyboard handler, on the keyboard thread, and gets an answer at once: swallow
// it (a script will run, and may send the key on itself) or let it through
// (typing). Every gesture cancels speech first, NVDA's way. Input help turns
// every key into its description.
import Foundation
import AppKit

public enum InputManager {
    nonisolated private static let lock = NSLock()
    nonisolated(unsafe) private static var _inputHelp = false   // under `lock`
    /// VoiceOver's VO-Semicolon: the TurnOver key is held for every key until it is pressed again. Any thread.
    nonisolated(unsafe) private static var _turnOverLocked = false   // under `lock`
    nonisolated public static var turnOverKeyLocked: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _turnOverLocked }
        set { lock.lock(); _turnOverLocked = newValue; lock.unlock() }
    }
    /// Read on the keyboard thread too (keyboard help names modifier keys there).
    nonisolated public static var isInputHelpActive: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _inputHelp }
        set { lock.lock(); _inputHelp = newValue; lock.unlock() }
    }
    /// Installed by the app: how to say "input help on" through the keyboard layer, etc.
    public static var onInputHelpChanged: ((Bool) -> Void)?
    /// A key that went to the application untouched (main thread): menus watch for Return and Escape this way.
    /// Set by the keyboard commands editor: the next key is handed here, not run (nil: Escape, cancelled).
    public static var captureNext: ((KeyboardGesture?) -> Void)? {
        get { _captureNext }
        set { _captureNext = newValue; _capturing.value = newValue != nil }
    }
    private static var _captureNext: ((KeyboardGesture?) -> Void)?
    nonisolated private static let _capturing = Locked(false)
    /// Something of TurnOver's waits for the next key (the layer after Command Control Comma): read on the keyboard
    /// thread, so a direct app's keys don't go past it.
    nonisolated public static var isCapturing: Bool { _capturing.value }
    public static var onPassThrough: ((KeyboardGesture) -> Void)?
    /// More watchers of keys that went to the application (main thread).
    public static var passThroughWatchers: [(KeyboardGesture) -> Void] = []

    /// Called on the keyboard thread for a key down. Returns true when the key is swallowed.
    /// VO-Tab: the next key goes to the application untouched.
    nonisolated public static var passNextKey: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _passNext }
        set { lock.lock(); _passNext = newValue; lock.unlock() }
    }
    nonisolated(unsafe) private static var _passNext = false   // under `lock`

    /// NVDA's sleep mode (NVDA+Shift+Z, Windows style): for these processes TurnOver says nothing and passes every key
    /// on, but the one that wakes it (12 Oct 2026). Not saved: as NVDA, until pressed again or TurnOver quits.
    nonisolated(unsafe) private static var _asleep: Set<pid_t> = []        // under `lock`
    nonisolated(unsafe) private static var _asleepBundles: Set<String> = []  // under `lock`: the key tap knows the front app by bundle
    nonisolated public static func isAsleep(_ pid: pid_t) -> Bool {
        guard KeySettings.current.windowsKeys else { return false }
        lock.lock(); defer { lock.unlock() }; return _asleep.contains(pid)
    }
    nonisolated public static func isAsleep(bundle: String) -> Bool {
        guard KeySettings.current.windowsKeys, !bundle.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }; return _asleepBundles.contains(bundle)
    }
    /// True when the process is now asleep.
    public static func toggleSleep(_ pid: pid_t) -> Bool {
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        lock.lock(); defer { lock.unlock() }
        if _asleep.remove(pid) != nil { _asleepBundles.remove(bundle); return false }
        _asleep.insert(pid); _asleepBundles.insert(bundle); return true
    }
    static let sleepKey = normalizeGestureIdentifier("kb:turnover+shift+z")

    /// The app in front when it is a direct app (Config.Applications.directApps): its keys go to it alone, straight
    /// from the key tap, and nothing of it is said. Set by the lead watcher as apps come forward; read on the keyboard
    /// thread.
    nonisolated(unsafe) private static var _directPid: pid_t?   // under `lock`
    nonisolated public static var directPid: pid_t? {
        get { lock.lock(); defer { lock.unlock() }; return _directPid }
        set { lock.lock(); _directPid = newValue; lock.unlock() }
    }
    /// The key a direct app is listed by: its bundle identifier, or "process:<name>" for a program without one.
    nonisolated public static func directKey(bundle: String?, name: String?) -> String { bundle ?? "process:\(name ?? "")" }

    /// When the last key went down (a terminal tells its own echo of a key from new output this way).
    public static var lastKeyDownAt: Date {
        get { lock.lock(); defer { lock.unlock() }; return _lastKeyDownAt }
        set { lock.lock(); _lastKeyDownAt = newValue; lock.unlock() }
    }
    private static var _lastKeyDownAt = Date.distantPast
    /// The last key pressed (its gesture identifier), for focus rules that depend on how focus came.
    public static var lastKeyIdentifier: String {
        get { lock.lock(); defer { lock.unlock() }; return _lastKeyIdentifier }
        set { lock.lock(); _lastKeyIdentifier = newValue; lock.unlock() }
    }
    private static var _lastKeyIdentifier = ""

    public static func handleKeyDown(_ gesture: KeyboardGesture) -> Bool {
        Hints.cancel()
        ObjectNavigator.shared.cancelWindowSearch()
        lastKeyDownAt = Date()
        // The keyboard commands editor is waiting for a key: this one is it (Escape cancels). Nothing else runs.
        if let capture = captureNext, !gesture.isRepeat {
            captureNext = nil
            DispatchQueue.main.async { capture(gesture.keyName == "escape" && gesture.modifiers.isEmpty ? nil : gesture) }
            return true
        }
        lastKeyIdentifier = gesture.identifier
        // A browser's Back or Forward: the page coming back resumes where it was read (BrowseModeDocument).
        if ["kb:command+[", "kb:command+]"].contains(gesture.identifier) { BrowseModeHandler.historyKeyAt = Date() }
        if passNextKey, !gesture.isRepeat {
            passNextKey = false
            Log.io("input \(gesture.logDescription()) passed through")
            return false
        }
        // Every key stops speech (NVDA) — except a typed key while only the echo of earlier typing is speaking:
        // typing fast must not cut off the word or the "period" just typed.
        let typing = gesture.typedCharacter != nil
        // Any other key (Escape, Command+L, an arrow) ends the word being typed (NVDA clears its typed-word
        // buffer): "Higgs", Escape, then "en." was echoed as "Higgsen".
        let endsWord = !typing && gesture.keyName != "backspace"
        let saysWord = ["enter", "numpadEnter", "tab"].contains(gesture.keyName) && gesture.modifiers.isEmpty
        SayAll.keyArrivedDuringSayAll.value = SayAll.isRunning
        DispatchQueue.main.async {
            // Where say all had got to, before the cancel forgets it (the caret goes to that word: 18 Oct 2026).
            SayAll.noteStopPoint()
            // NVDA's "interrupt speech for typed characters": every key cuts what is being said, so the echo keeps
            // up with fast typing (letting each echo finish first left it seconds behind an e-mail address, 3 Oct).
            Speech.cancel()
            if saysWord { Speech.finishTypedWord() } else if endsWord { Speech.clearTypedWordBuffer() }
            SayAll.stop(byGesture: true)
        }
        // On the main thread since Swift 6 (10 Oct 2026): the keyboard thread waits for this answer, bounded
        // (ScriptHandler.askMain), so the availability checks may talk to the application freely.
        let script = ScriptHandler.findScript(for: gesture)
        // What the user types is never written down: a password typed where TurnOver thought a password field was
        // went into the log character by character (5 Oct 2026), and every e-mail typed was there too. A typed key
        // is logged as just that; a key that runs a script (browse mode's single letters) by its name.
        Log.io("input \(gesture.logDescription(commandName: script?.name, secure: API.focusObject?.role == .passwordEdit))")

        // Never type into one place while saying another. TurnOver had put its focus on a system dialog's password
        // field ("Password, password edit") while macOS left the keyboard in Mail: the password went into an e-mail
        // (5 Oct 2026). A typed key, Backspace or Return while TurnOver's focus is a password field in an application
        // that does not have the keyboard is held back, and TurnOver tries again to give that field the keyboard.
        if typing || ["backspace", "enter", "numpadEnter"].contains(gesture.keyName), gesture.modifiers.subtracting(.shift).isEmpty,
           let f = API.focusObject, f.role == .passwordEdit, let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           front != f.element.pid {
            Log.io("input held back: TurnOver's focus is a password field in pid \(f.element.pid), the keyboard is with pid \(front)")
            DispatchQueue.main.async {
                Tones.edge()
                Speech.speakMessage("Not typed. The keyboard is not in this password field yet. Trying again; then type.")
                SystemPrompts.shared.giveKeyboard(to: f.element)
            }
            return true
        }

        if gesture.modifiers == [.command], gesture.keyName == "w", let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { AXHandler.shared.afterWindowClose(pid: pid) }
        }
        if ScreenRecognition.shared.isOpen {
            // A Command key (Command Tab, Command Space): the result closes and the key does what it always does.
            if gesture.modifiers.contains(.command), !["upArrow", "downArrow", "home", "end"].contains(gesture.keyName) {
                DispatchQueue.main.async { ScreenRecognition.shared.close(silently: true) }
                return false
            }
            DispatchQueue.main.async { ScreenRecognition.shared.handle(gesture) }
            return true
        }
        if FindPrompt.shared.isOpen {
            DispatchQueue.main.async { FindPrompt.shared.handle(gesture) }
            return true
        }
        if TurnOverMenu.shared.isOpen {
            // A Command key (Command Tab, Command Space): the menu closes and the key does what it always does
            // (Command Tab stayed in the menu, 6 Oct 2026).
            if gesture.modifiers.contains(.command) {
                DispatchQueue.main.async { TurnOverMenu.shared.close() }
                return false
            }
            DispatchQueue.main.async { TurnOverMenu.shared.handle(gesture) }
            return true
        }
        if isInputHelpActive {
            DispatchQueue.main.async {
                if let script, script.bypassInputHelp { ScriptHandler.queueScript(script, gesture: gesture) } else { handleInputHelp(gesture, script: script) }
            }
            return true
        }

        // Sleep mode: the app has the key, but only after TurnOver's own screens above (its menu opened over a sleeping
        // app could not be closed, the code review, 12 Oct 2026).
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, isAsleep(front),
           !gesture.identifiers.map(normalizeGestureIdentifier).contains(sleepKey) {
            return false
        }

        if KeySettings.current.speakCommandKeys, gesture.shouldReportAsCommand {
            DispatchQueue.main.async { Speech.speakMessage(gesture.displayName) }
        }

        if let script {
            ScriptHandler.queueScript(script, gesture: gesture)
            return true
        }
        // A clipboard key going to the application: say what it did (TurnOver's own copy speaks for itself).
        ClipboardAnnouncer.keyDown(gesture)
        DispatchQueue.main.async {
            ScriptHandler.clearLastScript()
            onPassThrough?(gesture)
            for w in passThroughWatchers { w(gesture) }
            if let c = gesture.typedCharacter, let focus = API.focusObject {
                EventHandler.queue(Event(.typedCharacter, focus, character: c))
            }
        }
        // An unbound TurnOver chord does nothing; the letter must not reach the document.
        return gesture.isTurnOverModifier
    }

    /// NVDA: _handleInputHelp — the key's name, then what it does.
    private static var lastHelpEscape = Date.distantPast
    public static func handleInputHelp(_ gesture: KeyboardGesture, script: Script?) {
        // Escape twice leaves input help (6 Oct 2026), as well as TurnOver 1.
        if gesture.keyName == "escape", gesture.modifiers.isEmpty {
            if Date().timeIntervalSince(lastHelpEscape) < 0.8 { lastHelpEscape = .distantPast; toggleInputHelp(); return }
            lastHelpEscape = Date()
            Speech.speakMessage("escape; press again to leave input help")
            return
        }
        // The key, then what it does in a few words (as VoiceOver's keyboard help and NVDA's input help).
        Speech.speakText(gesture.displayName, symbolLevel: .all)
        if let s = script { Speech.speakMessage(s.brief) }
    }

    public static func toggleInputHelp() {
        isInputHelpActive.toggle()
        onInputHelpChanged?(isInputHelpActive)
        Speech.speakMessage(isInputHelpActive ? "input help on" : "input help off")
    }
}
