// SPDX-License-Identifier: GPL-3.0-or-later
// Script resolution and execution (NVDA: scriptHandler).
//
// A gesture is offered, in order, to: the global plugins, the focused app's
// module, the focused object, its ancestors (scripts marked canPropagate), and
// the global commands. Resolution runs on the keyboard thread with no
// accessibility calls, so the tap can answer in microseconds. Execution runs
// on the main thread, one script at a time; a script that is still waiting
// for the caret gives way when another gesture arrives.
import Foundation
import TurnOverAX

public enum ScriptHandler {
    private static let lock = NSLock()
    private static var queued: [(Script, KeyboardGesture, Bool)] = []
    private static var _running = false
    private static var lastScript: Script?
    private static var lastScriptTime = Date.distantPast
    private static var lastScriptCount = 0

    /// Find the script for a gesture (NVDA: findScript). Any thread.
    public static func findScript(for gesture: KeyboardGesture, styleTable: Bool = true) -> Script? {
        // The user's own keys first (the keyboard commands editor): a key given to a command or an app, or taken away.
        switch UserGestures.lookup(gesture) {
        case .script(let s)?: return s
        case .removed?: return nil
        case nil: break
        }
        // The style's own table (Narrator and JAWS keys over TurnOver's commands), before the built-in keys.
        if styleTable, let s = StyleKeymap.script(for: gesture) { return s }
        for p in GlobalPluginHandler.shared.plugins { if let s = p.script(for: gesture) { return s } }
        if let pid = API.focusPid, let s = AppModuleHandler.shared.appModule(for: pid).script(for: gesture) { return s }
        if let d = API.focusTreeInterceptor, let s = d.script(for: gesture) { return s }
        if let focus = API.focusObject {
            if let s = focus.script(for: gesture) { return s }
            for a in API.focusAncestors { if let s = a.script(for: gesture), s.canPropagate { return s } }
        }
        return GlobalCommands.shared.script(for: gesture)
    }

    /// How the keyboard thread asks (8 Oct 2026, from the team review; redone for Swift 6, 10 Oct 2026). The
    /// decision is made on the main thread, where the object model lives, and the keyboard thread waits for it, up
    /// to `lookupLimit`. A late answer is not thrown away: the key is swallowed now, and when the main thread gets
    /// to it, its script runs or the key is sent on to the application (re-posted, marked). Only a main thread that
    /// has stopped beating altogether lets keys straight through, as the watchdog would have it. (Before, the
    /// lookup ran on its own queue and read the object model while the main thread changed it.)
    public enum Lookup {
        case found(Script)
        case none
        /// The question was not answered in time: the key goes to the application, or a chord is dropped.
        case timedOut
        public var script: Script? { if case .found(let s) = self { return s } else { return nil } }
    }
    /// The main thread's own lookup (tests, the probe, chords already on the main thread).
    public static func lookup(_ gesture: KeyboardGesture) -> Lookup { findScript(for: gesture).map { .found($0) } ?? .none }

    /// The longest the keyboard thread waits for the main thread. Normal answers take microseconds.
    nonisolated(unsafe) public static var lookupLimit: TimeInterval = 0.15
    /// Whether the main thread has stopped beating (the app's watchdog says): then keys pass straight through.
    nonisolated(unsafe) public static var mainStuck: (@Sendable () -> Bool)?

    public enum KeyDecision: Equatable { case taken, passed, deferred }
    private enum Wait { case waiting, answered(Bool), timedOut }

    /// Whether TurnOver has a script for a gesture, asked of the main thread (the Windows style translates a key
    /// only when TurnOver has nothing of its own for it). nil: the main thread did not answer in time.
    nonisolated public static func mainHasScript(for gesture: KeyboardGesture) -> Bool? {
        guard !(mainStuck?() ?? false) else { return nil }
        let answer = Locked<Bool?>(nil); let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { MainActor.assumeIsolated { answer.value = findScript(for: gesture) != nil; done.signal() } }
        _ = done.wait(timeout: .now() + lookupLimit)
        return answer.value
    }

    /// The main thread handles the key down (InputManager.handleKeyDown) while the keyboard thread waits.
    /// Keys that have reached the tap, counted on the keyboard thread: a script waiting on the application (for the
    /// caret) gives way when the count moves, even while the main thread is too busy to look the new key up.
    nonisolated private static let keysArrived = Locked(0)
    nonisolated public static var keysArrivedCount: Int { keysArrived.value }

    nonisolated public static func askMain(_ gesture: KeyboardGesture) -> KeyDecision {
        keysArrived.lock.lock(); keysArrived.unsafeValue &+= 1; keysArrived.lock.unlock()
        guard !(mainStuck?() ?? false) else { Log.warning("keyboard: the main thread is not beating; \(gesture.identifier) goes through"); return .passed }
        let state = Locked(Wait.waiting); let done = DispatchSemaphore(value: 0)
        let started = DispatchTime.now()
        DispatchQueue.main.async { MainActor.assumeIsolated {
            let taken = InputManager.handleKeyDown(gesture)
            var late = false
            state.lock.lock()
            if case .timedOut = state.unsafeValue { late = true } else { state.unsafeValue = .answered(taken) }
            state.lock.unlock()
            if late {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
                Log.warning("keyboard: \(gesture.identifier) answered after \(Int(ms)) ms: \(taken ? "its script runs now" : "sent on to the application now")")
                if !taken { gesture.send() }
            } else { done.signal() }
        } }
        if done.wait(timeout: .now() + lookupLimit) == .timedOut {
            state.lock.lock(); defer { state.lock.unlock() }
            if case .answered(let taken) = state.unsafeValue { return taken ? .taken : .passed }
            state.unsafeValue = .timedOut
            return .deferred
        }
        if case .answered(let taken) = state.value { return taken ? .taken : .passed }
        return .passed
    }

    /// A script by name from whatever answers here: the app module, the document, the focus and its ancestors,
    /// then the global commands. (VoiceOver's VO-U finds Word's elements list this way.)
    public static func findScript(named name: String) -> Script? {
        if let pid = API.focusPid, let s = AppModuleHandler.shared.appModule(for: pid).script(named: name) { return s }
        if let d = API.focusTreeInterceptor, !d.passThrough, let s = d.script(named: name) { return s }
        if let f = API.focusObject {
            if let s = f.script(named: name) { return s }
            for a in API.focusAncestors { if let s = a.script(named: name) { return s } }
        }
        // The global plugins' commands too (VoiceOver's and NVDA's keys live there): a key the user gave to one of them
        // ("vo_nextParagraph") found nothing and did nothing (a tester, and 19 Oct 2026).
        for p in GlobalPluginHandler.shared.plugins { if let s = p.script(named: name) { return s } }
        if let s = KeypadCommands.shared.script(named: name) { return s }
        return GlobalCommands.shared.script(named: name)
    }

    /// Queue a script for the main thread (NVDA: queueScript). Any thread.
    public static func queueScript(_ script: Script, gesture: KeyboardGesture) {
        let wasInSayAll = SayAll.isRunning
        lock.lock(); queued.append((script, gesture, wasInSayAll)); lock.unlock()
        DispatchQueue.main.async { runQueued() }
    }

    /// True while a script runs (main thread).
    public static var isScriptRunning: Bool { _running }
    /// NVDA: isScriptWaiting — another gesture's script is queued behind the running one.
    public static var isScriptWaiting: Bool { lock.lock(); defer { lock.unlock() }; return !queued.isEmpty }

    private static func runQueued() {
        guard !_running else { return }
        while true {
            lock.lock()
            guard !queued.isEmpty else { lock.unlock(); break }
            let (script, gesture, wasInSayAll) = queued.removeFirst()
            lock.unlock()
            executeScript(script, gesture: gesture, wasInSayAll: wasInSayAll)
        }
        EventHandler.drain()
    }

    /// NVDA: executeScript, with the repeat count for "press twice".
    public static func executeScript(_ script: Script, gesture: KeyboardGesture, wasInSayAll: Bool = false) {
        BrailleInput.flushForKey()   // a word half typed on the display goes in before any command runs
        if _running, lastScript === script { gesture.send(); return }
        _running = true
        let now = Date()
        if now.timeIntervalSince(lastScriptTime) * 1000 <= Double(config.keyboard.multiPressTimeoutMs), lastScript === script { lastScriptCount += 1 } else { lastScriptCount = 0 }
        lastScript = script
        lastScriptTime = now
        Log.io("script \(script.name) for \(gesture.identifier)\(lastScriptCount > 0 ? " (repeat \(lastScriptCount))" : "")")
        let resume = wasInSayAll && script.resumesSayAll
        let (calls0, ms0, t0) = (AXStats.calls, AXStats.ms, DispatchTime.now().uptimeNanoseconds)
        SayAll.resuming = resume
        // NVDA's on-demand speech mode: a reporting command may speak (the time, the line, the title …).
        if Speech.mode == .onDemand, Self.speaksOnDemand(script.name) { Speech.demandedUntil = Date().addingTimeInterval(2) }
        script.handler(gesture)
        SayAll.resuming = false
        // The cost of a slow script, measured: how many questions it asked the application and how long they took.
        let took = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1e6
        if took > 100 { Log.warning(String(format: "script %@ took %.0f ms: %d accessibility calls, %.0f ms in them", script.name, took, AXStats.calls - calls0, AXStats.ms - ms0)) }
        // A key gives way to a message held on the display ("indefinitely"): browse mode's line moves change no
        // focus and no caret, and the display stayed on "nothing more" while speech read on (21 Oct 2026). A message the
        // script itself just put up stays.
        Braille.focusOrCaretMoved()
        Braille.refreshSoon()
        KeySettings.refresh()   // a script may have changed a setting the keyboard thread reads
        _running = false
        EventHandler.drain()
        if resume, let obj = API.caretObject { SayAll.readText(from: obj) }
    }

    /// NVDA: getLastScriptRepeatCount — 0 the first time, 1 for the second press within the timeout.
    public static var lastScriptRepeatCount: Int {
        Date().timeIntervalSince(lastScriptTime) * 1000 > Double(config.keyboard.multiPressTimeoutMs) ? 0 : lastScriptCount
    }

    public static func clearLastScript() { lastScript = nil; lastScriptTime = .distantPast; lastScriptCount = 0 }

    /// The commands that speak in on-demand mode: those that report something asked for, as NVDA marks its own.
    static func speaksOnDemand(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["report", "sayall", "readcontents", "speak", "describe", "datetime", "time", "title", "spell", "review",
                "navigatorobject", "where", "battery", "statusbar", "selecteditem", "readwindow", "readline", "currentline"].contains { n.contains($0) }
    }
}
