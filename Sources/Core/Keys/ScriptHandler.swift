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
import AppKit
import TurnOverAX

public enum ScriptHandler {
    private static let lock = NSLock()
    /// A queued key: a script to run, or (16 Nov 2026, review) a key in the ordered lane, looked up when its turn
    /// comes or sent on to the application in its turn (`queueInOrder`).
    private struct Queued {
        enum Kind { case script(Script), lookUp, send, input(isCurrent: () -> Bool, route: (KeyboardGesture) -> Void) }
        let kind: Kind
        let gesture: KeyboardGesture
        let wasInSayAll: Bool
        /// In the ordered lane: the keys the script sends are sent in order too (`sendInOrder`).
        var inOrder = false
        var fromDeferredInput = false
        /// A key typed for a field: the log names its command, never the key.
        var masked = false
        /// After it is sent: the watchers and the typed character's echo (a key that was not noted on its way in).
        var notes = false
        /// Why the key may no longer go anywhere (nil: it may), asked when its turn comes with the command it would run
        /// (nil: it is to be sent on).
        var refusal: ((Script?) -> String?)?
    }
    private static var queued: [Queued] = []
    /// An entry of the ordered lane is running (a script that waits for the caret lets keys in meanwhile).
    private static var runningInOrder = false
    /// A normal input decision in the lane can enqueue its own script or pass-through ahead of the next input.
    private struct InputRoute {
        let isCurrent: () -> Bool
        var nextInsertion = 0
    }
    private static var routingInput: InputRoute?
    nonisolated package static let hasDeferredInput = Locked(false)
    private static var _running = false
    private static var lastScript: Script?
    private static var lastScriptTime = Date.distantPast
    private static var lastScriptCount = 0

    /// Find the script for a gesture (NVDA: findScript). Any thread.
    public static func findScript(for gesture: KeyboardGesture, styleTable: Bool = true) -> Script? {
        findScript(for: gesture, styleTable: styleTable) { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    }

    package static func findScript(for gesture: KeyboardGesture, styleTable: Bool = true,
                                   frontmostBundle: () -> String?) -> Script? {
        // A protected prompt can ignore an Accessibility press even when it reports success (issue 352).
        // Give its plain action keys back to macOS even when TurnOver still reports focus in another app.
        if SystemPrompts.keepsActionKey(gesture, frontmostBundle: frontmostBundle) { return nil }

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
        // Browse mode's trap for a typing key with no command is the last resort, not an answer: every handler asked
        // after the page still gets the key first. Asked in the page's turn, it took Option D (Show Desktop) and
        // Option B (Status Menus) from the global commands in the Windows and JAWS styles (review, 16 Nov 2026).
        var browseModeTrap: Script?
        if let d = API.focusTreeInterceptor, let s = d.script(for: gesture) {
            let isTrap = s.name == BrowseModeDocument.trapScriptName
            if !isTrap { return s }
            browseModeTrap = s
        }
        if let focus = API.focusObject {
            if let s = focus.script(for: gesture) {
                // In browse mode the trap comes before the field's own delete commands (17 Nov 2026): Backspace and
                // Delete reached a field that kept the keyboard while the page was being read. The page asked for the
                // trap only when browse mode is on and the field's command deletes.
                let deletesInBrowseMode = browseModeTrap != nil && BrowseModeDocument.deletingScriptNames.contains(s.name)
                if deletesInBrowseMode { return browseModeTrap }
                return s
            }
            for a in API.focusAncestors { if let s = a.script(for: gesture), s.canPropagate { return s } }
        }
        if let s = GlobalCommands.shared.script(for: gesture) { return s }
        return browseModeTrap
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

    public enum KeyDecision: Equatable {
        case taken, passed, deferred
        /// Passed, but as another key, by its key code (a system prompt's Return as Space, 26 Nov 2026): the key tap
        /// rewrites the real key in place, and its release to match.
        case passedAs(Int64)
    }
    private enum Wait { case waiting, answered(KeyDecision), timedOut }

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

    /// The keys that can end a request for a field's focus, counted on the keyboard thread with the count above
    /// (16 Nov 2026). A typing key that may be held for the field (see `setCaretHoldGate`) is not counted: the main
    /// thread holds it, or, if the focus event came first, the field takes it. Counted at the tap, so a key still on its
    /// way to the main thread when the focus event is handled is never mistaken for one that ended the request.
    nonisolated private static let supersedingKeys = Locked(0)
    nonisolated public static var supersedingKeysCount: Int { supersedingKeys.value }
    private struct CaretHoldGate: Sendable {
        var holding = false
        var navigationKeyCode: Int64 = -1
    }
    nonisolated private static let caretHoldGate = Locked(CaretHoldGate())
    /// Set when a request for the focus of an editable field is made (`holding`), with the quick navigation key that
    /// made it: that key, pressed again, with Shift or without, is a command and is never held.
    nonisolated public static func setCaretHoldGate(holding: Bool, navigation: KeyboardGesture?) {
        caretHoldGate.value = CaretHoldGate(holding: holding, navigationKeyCode: navigation?.keyCode ?? -1)
    }
    /// The tap's own accounting for a key that has arrived (askMain; a hook for tests, which do not go through it).
    nonisolated package static func noteKeyArrived(_ gesture: KeyboardGesture) {
        keysArrived.lock.lock(); keysArrived.unsafeValue &+= 1; keysArrived.lock.unlock()
        let gate = caretHoldGate.value
        // The key itself, Shift or not (16 Nov 2026, review): Shift F after F is the previous field, a command.
        let sameNavigationKey = gesture.keyCode == gate.navigationKeyCode
        if gate.holding, gesture.isTypingKeyForCaretFocus, !sameNavigationKey { return }
        supersedingKeys.lock.lock(); supersedingKeys.unsafeValue &+= 1; supersedingKeys.lock.unlock()
    }

    nonisolated public static func askMain(
        _ gesture: KeyboardGesture,
        prepareAfterSwitcher: (@MainActor @Sendable (KeyboardGesture) -> KeyboardGesture)? = nil
    ) -> KeyDecision {
        noteKeyArrived(gesture)
        guard !(mainStuck?() ?? false) else { Log.warning("keyboard: the main thread is not beating; \(gesture.logDescription()) goes through"); return .passed }
        let state = Locked(Wait.waiting); let done = DispatchSemaphore(value: 0)
        let started = DispatchTime.now()
        DispatchQueue.main.async { MainActor.assumeIsolated {
            // What the main thread had begun before this key got its turn: the likely cause of a late answer (17 Nov 2026,
            // WhatsApp's first activation held two keys for 0.8 and 1.0 s with nothing in the log to say what).
            let busyWith = Core.mainWork.value, turnCameAt = DispatchTime.now().uptimeNanoseconds   // formatted only if it is late
            let routeLater = {
                let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
                let opening = SwitcherCloseWatcher.generation
                queueInput(gesture, isCurrent: {
                    opening == SwitcherCloseWatcher.generation &&
                        pid == NSWorkspace.shared.frontmostApplication?.processIdentifier
                }) { original in
                    let key = prepareAfterSwitcher?(original) ?? original
                    _ = InputManager.handleKeyDown(key)
                }
            }
            let taken: Bool
            // The key it goes to the application as, when not as itself (InputManager.sentOnAs).
            var other: KeyboardGesture?
            if SwitcherCloseWatcher.holdInput(gesture, run: routeLater) {
                taken = true
            } else if prepareAfterSwitcher != nil || hasDeferredInput.value {
                // Keep subsequent key decisions behind the deferred keys, including pass-next, capture and Find.
                routeLater()
                taken = true
            } else {
                taken = InputManager.handleKeyDown(gesture)
                if !taken {
                    other = InputManager.sentOnAs
                    SwitcherCloseWatcher.passedThrough(gesture)
                    // Tab in focus mode went to the page for real (24 Nov 2026): the hidden control it reaches is looked for.
                    BrowseModeDocument.keyPassedToPage(gesture)
                }
            }
            let decision: KeyDecision
            if taken { decision = .taken } else if let other { decision = .passedAs(other.keyCode) } else { decision = .passed }
            var late = false
            state.lock.lock()
            if case .timedOut = state.unsafeValue { late = true } else { state.unsafeValue = .answered(decision) }
            state.lock.unlock()
            if late {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
                Log.warning("keyboard: \(gesture.logDescription()) answered after \(Int(ms)) ms: \(taken ? "its script runs now" : "sent on to the application now"); before it the main thread had begun: \(Core.describe(busyWith, now: turnCameAt))")
                // The key pressed was swallowed while the answer was awaited: TurnOver sends it on, as the key it goes as.
                if !taken { (other ?? gesture).send() }
            } else { done.signal() }
        } }
        if done.wait(timeout: .now() + lookupLimit) == .timedOut {
            state.lock.lock(); defer { state.lock.unlock() }
            if case .answered(let decision) = state.unsafeValue { return decision }
            state.unsafeValue = .timedOut
            return .deferred
        }
        if case .answered(let decision) = state.value { return decision }
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
        return GlobalCommands.shared.script(named: name)
    }

    /// Queue a script for the main thread (NVDA: queueScript). Any thread.
    public static func queueScript(_ script: Script, gesture: KeyboardGesture) {
        let wasInSayAll = SayAll.isRunning
        lock.lock()
        // Queued while the ordered lane is busy: in it, so that what the script sends keeps its place (16 Nov 2026, review).
        let inOrder = laneBusyLocked
        enqueue(Queued(kind: .script(script), gesture: gesture, wasInSayAll: wasInSayAll, inOrder: inOrder))
        lock.unlock()
        DispatchQueue.main.async { runQueued() }
    }

    /// True while a script runs (main thread).
    public static var isScriptRunning: Bool { _running }
    /// NVDA: isScriptWaiting — another gesture's script is queued behind the running one.
    public static var isScriptWaiting: Bool { lock.lock(); defer { lock.unlock() }; return !queued.isEmpty }

    // The ordered lane (16 Nov 2026, review of the caret-focus hold). A key TurnOver sends on later, as the keys held for
    // a field's focus are, is posted into the keyboard's stream behind any real key already waiting at the tap for the
    // main thread; let through, that real key reached the app first ("lhe" for "hel"). So keys sent on later go into the
    // lane: one at a time, each only once the keys sent before it have passed the tap (`orderedKeySeen`), and any key
    // that comes while the lane is busy joins it at the back, whether it runs a script or would have gone straight to the
    // application. The scripts in the lane send their keys the same way. A key sent while the tap does not see it (the
    // tap switched off, TurnOver handing over) is given up on after `orderedKeyLimit`, so nothing waits longer.
    private struct OrderedKeys: Sendable {
        var onTheirWay = 0
        var lastSentNs: UInt64 = 0
    }
    nonisolated private static let orderedKeys = Locked(OrderedKeys())
    /// The longest the lane waits for a key it sent to pass the tap.
    nonisolated(unsafe) package static var orderedKeyLimit: TimeInterval = 0.3
    /// While an entry of the ordered lane runs, `KeyboardGesture.send` sends in order (main thread only).
    nonisolated(unsafe) static var sendingInOrder = false

    /// Sends a key on to the application so that it reaches it after every key sent this way before it. Any thread.
    nonisolated public static func sendInOrder(_ gesture: KeyboardGesture) {
        orderedKeys.lock.lock()
        orderedKeys.unsafeValue.onTheirWay += 1
        orderedKeys.unsafeValue.lastSentNs = DispatchTime.now().uptimeNanoseconds
        orderedKeys.lock.unlock()
        if let poster = KeyboardGesture.orderedPoster { poster(gesture) } else { KeyboardGesture.poster?(gesture) }
        // Should the tap never see it, the lane goes on after the limit.
        DispatchQueue.main.asyncAfter(deadline: .now() + orderedKeyLimit + 0.01) { MainActor.assumeIsolated { runQueued() } }
    }

    /// The keyboard thread: a key sent by `sendInOrder` has passed the tap, so keys typed after it are behind it now.
    nonisolated public static func orderedKeySeen() {
        orderedKeys.lock.lock()
        orderedKeys.unsafeValue.onTheirWay = max(0, orderedKeys.unsafeValue.onTheirWay - 1)
        let none = orderedKeys.unsafeValue.onTheirWay == 0
        orderedKeys.lock.unlock()
        if none { DispatchQueue.main.async { MainActor.assumeIsolated { runQueued() } } }
    }

    /// Keys sent in order that have not yet passed the tap, within the limit (main thread).
    private static var keysOnTheirWay: Bool {
        orderedKeys.lock.lock(); defer { orderedKeys.lock.unlock() }
        guard orderedKeys.unsafeValue.onTheirWay > 0 else { return false }
        let waited = Double(DispatchTime.now().uptimeNanoseconds &- orderedKeys.unsafeValue.lastSentNs) / 1e9
        if waited < orderedKeyLimit { return true }
        Log.warning("keyboard: \(orderedKeys.unsafeValue.onTheirWay) key(s) sent in order were not seen at the tap in \(Int(orderedKeyLimit * 1000)) ms; the keys behind them go on")
        orderedKeys.unsafeValue.onTheirWay = 0
        return false
    }
    /// Under `lock`.
    private static var laneBusyLocked: Bool { runningInOrder || queued.contains { $0.inOrder } || keysOnTheirWay }

    /// Whether a key that would go straight to the application must take its turn in the ordered lane (main thread).
    public static var keysMustWaitTheirTurn: Bool { lock.lock(); defer { lock.unlock() }; return laneBusyLocked }

    /// A key into the ordered lane (main thread). `lookUp`: its command is found when its turn comes and runs, or the
    /// key is sent on if it has none, as a key typed then would; otherwise it is sent on. `refusal` is asked first.
    package static func queueInOrder(_ gesture: KeyboardGesture, lookUp: Bool, notes: Bool, masked: Bool,
                                     refusal: ((Script?) -> String?)? = nil) {
        lock.lock()
        enqueue(Queued(kind: lookUp ? .lookUp : .send, gesture: gesture, wasInSayAll: SayAll.isRunning,
                       inOrder: true, masked: masked, notes: notes, refusal: refusal))
        lock.unlock()
        DispatchQueue.main.async { runQueued() }
    }

    /// Under lock. Work created by this input on main precedes later queued input.
    private static func enqueue(_ entry: Queued) {
        guard Thread.isMainThread, var route = routingInput else {
            queued.append(entry)
            return
        }
        var routed = entry
        routed.fromDeferredInput = true
        let isCurrent = route.isCurrent
        routed.refusal = { script in
            guard isCurrent() else { return "the switcher's destination changed" }
            return entry.refusal?(script)
        }
        queued.insert(routed, at: route.nextInsertion)
        route.nextInsertion += 1
        routingInput = route
    }

    package static func queueInput(_ gesture: KeyboardGesture, isCurrent: @escaping () -> Bool,
                                   route: @escaping (KeyboardGesture) -> Void) {
        lock.lock()
        queued.append(Queued(kind: .input(isCurrent: isCurrent, route: route), gesture: gesture,
                             wasInSayAll: false, inOrder: true, fromDeferredInput: true))
        hasDeferredInput.value = true
        lock.unlock()
        DispatchQueue.main.async { runQueued() }
    }

    /// Tests: the lane forgets keys still on their way and empties.
    package static func resetOrderedLane() {
        orderedKeys.value = OrderedKeys()
        lock.lock(); queued.removeAll { $0.inOrder }; runningInOrder = false; lock.unlock()
        hasDeferredInput.value = false
    }

    private static var lastRefusalEdge = Date.distantPast

    private static func runQueued() {
        guard !_running, routingInput == nil else { return }
        while true {
            // Keys sent in order still on their way: whatever is queued waits for them (`orderedKeySeen` or the limit).
            if keysOnTheirWay { break }
            lock.lock()
            hasDeferredInput.value = queued.contains(where: \.fromDeferredInput)
            guard !queued.isEmpty else { lock.unlock(); break }
            let entry = queued.removeFirst()
            runningInOrder = entry.inOrder
            lock.unlock()
            if case .input(let isCurrent, let route) = entry.kind {
                lock.lock(); routingInput = InputRoute(isCurrent: isCurrent); lock.unlock()
                if isCurrent() { route(entry.gesture) }
                lock.lock(); routingInput = nil; runningInOrder = false; lock.unlock()
                // The normal input decision scheduled its speech and menu handling before its script.
                DispatchQueue.main.async { runQueued() }
                return
            }
            run(entry)
            lock.lock(); runningInOrder = false; lock.unlock()
        }
        EventHandler.drain()
    }

    private static func run(_ entry: Queued) {
        let gesture = entry.gesture
        var script: Script?
        switch entry.kind {
        case .script(let s): script = s
        case .lookUp: script = findScript(for: gesture)
        case .send: script = nil
        case .input: return
        }
        if let why = entry.refusal?(script) {
            // Never typed into another application or field, nor run on another page: dropped, with the edge sound.
            Log.io("input \(entry.masked ? "(a typed key)" : gesture.logDescription()) dropped: \(why)")
            if Date().timeIntervalSince(lastRefusalEdge) > 0.5 { lastRefusalEdge = Date(); Tones.edge() }
            return
        }
        if let script {
            let before = sendingInOrder
            sendingInOrder = entry.inOrder
            defer { sendingInOrder = before }
            executeScript(script, gesture: gesture, wasInSayAll: entry.wasInSayAll, maskKey: entry.masked)
        } else {
            sendInOrder(gesture)
            if entry.notes { InputManager.notePassedThrough(gesture) }
        }
    }

    /// NVDA: executeScript, with the repeat count for "press twice". `maskKey`: a key typed for a field (held for its
    /// focus), which the log does not name.
    public static func executeScript(_ script: Script, gesture: KeyboardGesture, wasInSayAll: Bool = false, maskKey: Bool = false) {
        BrailleInput.flushForKey()   // a word half typed on the display goes in before any command runs
        if _running, lastScript === script { gesture.send(); return }
        _running = true
        let now = Date()
        if now.timeIntervalSince(lastScriptTime) * 1000 <= Double(config.keyboard.multiPressTimeoutMs), lastScript === script { lastScriptCount += 1 } else { lastScriptCount = 0 }
        lastScript = script
        lastScriptTime = now
        Core.noteMainWork("script \(script.name)")   // for the watchdog's trip line (17 Nov 2026)
        Log.io("script \(script.name) for \(maskKey ? "(a typed key)" : gesture.identifier)\(lastScriptCount > 0 ? " (repeat \(lastScriptCount))" : "")")
        let resume = wasInSayAll && script.resumesSayAll
        let (calls0, ms0, t0) = (AXStats.calls, AXStats.ms, DispatchTime.now().uptimeNanoseconds)
        SayAll.resuming = resume
        // NVDA's on-demand speech mode: a reporting command may speak (the time, the line, the title …).
        if Speech.mode == .onDemand, Self.speaksOnDemand(script.name) { Speech.demandedUntil = Date().addingTimeInterval(2) }
        ModeAnnouncement.begin()
        defer { ModeAnnouncement.end() }
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

    /// The commands that speak in on-demand mode: those that report something asked for, as NVDA marks its own. JAWS's
    /// reading keys too (Caps Lock U, O, J, L, M, Period): they move as the arrows do, but read as the review keys on
    /// their letters did, which spoke (the review of pull request 144, 28 Oct 2026).
    static func speaksOnDemand(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["report", "sayall", "readcontents", "speak", "describe", "datetime", "time", "title", "spell", "review",
                "navigatorobject", "where", "battery", "statusbar", "selecteditem", "readwindow", "readline", "currentline",
                "jaws_sayprior", "jaws_saynext"].contains { n.contains($0) }
    }
}
