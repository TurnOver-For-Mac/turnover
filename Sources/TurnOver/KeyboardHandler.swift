// SPDX-License-Identifier: GPL-3.0-or-later
// The keyboard handler (NVDA: keyboardHandler + winInputHook), Mac-specific.
//
// Measured 30 Sep 2026 (gate 4): a non-seizing IOHIDManager reports the physical
// Caps Lock down and up even with Karabiner seizing the keyboard; an active
// session tap swallows the key's own flagsChanged events so no app sees caps
// toggle; IOHIDSetModifierLockState keeps the system's caps state where the
// owner left it; a double tap toggles real caps lock.
//
// Every other key down becomes a KeyboardGesture (Caps held = the TurnOver
// modifier) and goes to the input manager on this thread, which answers at
// once: swallow (a script will run, and may re-post the key itself, NVDA's
// gesture.send) or pass through (typing). Re-posted keys carry a marker in the
// event's user data so the tap lets them by.
//
// The tap and the HID manager live on their own thread with their own run loop,
// so a blocked main thread can never delay a keystroke or disable the tap.
import Foundation
import IOKit
import IOKit.hid
import CoreGraphics
import AppKit
import Carbon.HIToolbox
import TurnOverCore

// The tap, HID manager and key state belong to one worker at a time, through teardown. Lifecycle and its run-loop
// reference are read/written only under lifecycle.lock, including setup, stop and replacement. Callbacks are set on
// main before the first worker starts and invoked only on main via onMain; reader state stays there (28 Oct 2026).
nonisolated final class KeyboardHandler: @unchecked Sendable {
    static let marker: Int64 = 0xB05A
    /// Caps Lock held as the TurnOver key, for the trackpad's on and off (read off the keyboard thread).
    static let capsHeld = Locked(false)
    /// Keys TurnOver presses for an AI trying a plugin (PluginTry): handled as if typed, not let through like
    /// `marker`; the second also means the TurnOver key is held (Caps Lock is read from the hardware, so a posted
    /// key can't hold it; 14 Oct 2026).
    static let typedMarker: Int64 = 0xB05B
    static let typedTurnOverMarker: Int64 = 0xB05C

    var onCapsLockToggled: (@MainActor (Bool) -> Void)?
    var onReadinessChanged: (@MainActor (UInt64, Bool) -> Void)?

    private struct Lifecycle {
        var session = KeyboardSessionState()
        var runLoop: CFRunLoop?
    }
    private let lifecycle = Locked(Lifecycle())
    /// What one keyboard thread set up: torn down by that thread, whatever came after it. (Stopping and starting
    /// again at once, a double toggle, had the old thread's tear-down clear the new thread's tap, 8 Oct 2026.)
    private final class Layer {
        let generation: UInt64
        var manager: IOHIDManager?
        var tap: CFMachPort?
        var connect: io_connect_t = 0
        init(generation: UInt64) { self.generation = generation }
    }
    private var layer: Layer?
    private var manager: IOHIDManager? { layer?.manager }
    private var tap: CFMachPort? { layer?.tap }
    private var connect: io_connect_t { layer?.connect ?? 0 }

    // Tap-thread state.
    private var capsDown = false
    private var chordFired = false
    private var lastCapsUp: UInt64 = 0
    private var realCapsOn = false
    private var quarantined = Set<Int64>()
    /// Keys translated on the way down (the Windows style): their release is translated too.
    private var remapped = Set<Int64>()
    private var echoCode: Int64 = -1
    private var echoAt: UInt64 = 0
    private var echoCount = 0
    private var controlAlone = false
    private var shiftAlone = false
    private var shiftDownAt = Date.distantPast
    /// Option pressed and released with nothing else, quickly: left Option is the Windows key (the Dock),
    /// right Option the Applications key (Control+Return, the context menu).
    private var optionAlone = false
    /// Arrow-key Quick Nav (VoiceOver's): the arrow held, waiting to see whether a second joins it (a chord).
    private var arrowHeld: Int64?
    private var arrowChorded = false
    private var arrowRepeated = false
    /// With Quick Nav off: the bare arrow physically held (passed to the app as usual), so Left and Right pressed
    /// together can turn Quick Nav on, as VoiceOver's do (13 Oct 2026: they turned it off, never on).
    private var arrowDownWhileOff: Int64?
    private static let arrowNames: [Int64: String] = [123: "leftArrow", 124: "rightArrow", 125: "downArrow", 126: "upArrow"]
    private var optionCode: Int64 = 0
    /// Keyboard help: the name of a modifier key as it goes down (keyboard thread; spoken on the main thread).
    private var lastModifierNamed: (code: Int64, at: Date) = (0, .distantPast)
    private func announceModifier(code: Int64, flags: CGEventFlags, capsIsTurnOver: Bool) {
        let names: [Int64: (String, CGEventFlags?)] = [
            55: ("command", .maskCommand), 54: ("right command", .maskCommand),
            56: ("shift", .maskShift), 60: ("right shift", .maskShift),
            58: ("option", .maskAlternate), 61: ("right option", .maskAlternate),
            59: ("control", .maskControl), 62: ("right control", .maskControl),
            63: ("function", .maskSecondaryFn),
            57: (capsIsTurnOver ? "caps lock, the TurnOver key" : "caps lock", nil),
        ]
        guard let (name, mask) = names[code] else { return }
        if let mask, !flags.contains(mask) { return }   // the key going up
        // Caps Lock has no held flag: named once a press, not again as it comes up.
        if Date().timeIntervalSince(lastModifierNamed.at) < 0.35, lastModifierNamed.code == code { return }
        lastModifierNamed = (code, Date())
        onMain { Speech.speakMessage(name) }
    }

    /// Command pressed and released alone: Alt in Windows, the menus.
    private var disabledAt: [Date] = []
    private var lastDisableSpoken = Date.distantPast
    private var commandAlone = false
    private var commandDownAt = Date.distantPast
    private var optionDownAt = Date.distantPast

    private static let machToNs: Double = {
        var info = mach_timebase_info(numer: 0, denom: 0)
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    init() {
        KeyboardGesture.poster = { g in KeyboardHandler.post(g) }
        KeyboardGesture.typedPoster = { g in KeyboardHandler.postTyped(g) }
        KeyboardGesture.chordPoster = { codes in KeyboardHandler.postChord(codes) }
        KeyboardGesture.turnOverHeld = {
            if KeyboardHandler.capsHeld.value { return true }
            let f = CGEventSource.flagsState(.hidSystemState)
            return KeySettings.current.controlOptionIsTurnOver && f.contains(.maskControl) && f.contains(.maskAlternate)
        }
        KeyboardGesture.textPoster = { s in KeyboardHandler.postText(s) }
    }

    @discardableResult
    func start() -> UInt64 {
        lifecycle.lock.lock()
        let request = lifecycle.unsafeValue.session.requestStart()
        let worker = lifecycle.unsafeValue.session.beginWorker()
        lifecycle.lock.unlock()
        if let worker { startWorker(worker) }
        return request
    }

    func isReady(_ generation: UInt64) -> Bool {
        lifecycle.lock.lock(); defer { lifecycle.lock.unlock() }
        return lifecycle.unsafeValue.session.isReady(generation)
    }

    private func isRequested(_ generation: UInt64) -> Bool {
        lifecycle.lock.lock(); defer { lifecycle.lock.unlock() }
        return lifecycle.unsafeValue.session.isRequested(generation)
    }

    private func report(_ generation: UInt64, ready: Bool) {
        lifecycle.lock.lock()
        let accepted = lifecycle.unsafeValue.session.report(generation, ready: ready)
        lifecycle.lock.unlock()
        guard accepted else { return }
        onMain { [self] in onReadinessChanged?(generation, ready) }
    }

    private func startWorker(_ generation: UInt64) {
        let t = Thread { [self] in
            lifecycle.lock.lock()
            lifecycle.unsafeValue.runLoop = CFRunLoopGetCurrent()
            lifecycle.lock.unlock()
            if isRequested(generation) {
                let mine = setUp(generation)
                let ready = mine.tap.map { CFMachPortIsValid($0) && CGEvent.tapIsEnabled(tap: $0) } ?? false
                if ready, isRequested(generation) {
                    // A created tap is insufficient: acknowledge from the run loop once it is serving work.
                    CFRunLoopPerformBlock(CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue) { [self, weak mine] in
                        guard isRequested(generation), let t = mine?.tap else { return }
                        report(generation, ready: CFMachPortIsValid(t) && CGEvent.tapIsEnabled(tap: t))
                    }
                    CFRunLoopRun()
                }
                // An unexpected run-loop exit is also a loss of input, not a successful active reader.
                report(generation, ready: false)
                tearDown(mine)
            }
            lifecycle.lock.lock()
            lifecycle.unsafeValue.runLoop = nil
            lifecycle.unsafeValue.session.finished(generation)
            let next = lifecycle.unsafeValue.session.beginWorker()
            lifecycle.lock.unlock()
            if let next { startWorker(next) }
        }
        t.name = "turnover.keyboard"
        t.qualityOfService = .userInteractive
        t.start()
    }

    func stop() {
        lifecycle.lock.lock()
        lifecycle.unsafeValue.session.requestStop()
        let rl = lifecycle.unsafeValue.runLoop
        lifecycle.lock.unlock()
        Self.capsHeld.value = false
        guard let rl else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) { CFRunLoopStop(CFRunLoopGetCurrent()) }
        CFRunLoopWakeUp(rl)
        // Keys pass as soon as the request is retired. Replacement waits for actual teardown on the worker,
        // without blocking main or trusting a shared semaphore left over from an earlier stop (28 Oct 2026).
    }

    private func setUp(_ generation: UInt64) -> Layer {
        let mine = Layer(generation: generation)
        layer = mine
        // Nothing carried over from the tap before (a restart after the watchdog): a code still in `quarantined`
        // would swallow the next real key-up, and the app would see a key held down (a code review, 14 Oct 2026).
        quarantined.removeAll(); remapped.removeAll(); capsDown = false; chordFired = false; keypadZeroDown = false
        Self.capsHeld.value = false
        controlAlone = false; shiftAlone = false; optionAlone = false; commandAlone = false
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        if service != 0 {
            let r = IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &mine.connect)
            IOObjectRelease(service)
            Log.info("keyboard: IOHIDSystem connection \(r == KERN_SUCCESS ? "open" : "failed \(r)")")
        }
        realCapsOn = lockState()

        openHIDManager(into: mine)

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue | 1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue)
        // Coexisting with VoiceOver: at the head of the HID level, before VoiceOver sees a chord (TapProbe, 16 Oct 2026).
        guard let t = CGEvent.tapCreate(tap: Coexist.on ? .cghidEventTap : .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            return Unmanaged<KeyboardHandler>.fromOpaque(refcon).takeUnretainedValue().tapEvent(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Log.error("keyboard: could not create the event tap — Accessibility not granted?")
            return mine
        }
        mine.tap = t
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, t, 0), .defaultMode)
        Log.info("keyboard: active session tap up on its own thread")
        return mine
    }

    /// The physical keyboard watch (Caps Lock as the TurnOver key): needs Input Monitoring.
    private func openHIDManager(into mine: Layer) {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(m, [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keypad],
        ] as CFArray)
        IOHIDManagerRegisterInputValueCallback(m, { context, _, _, value in
            guard let context else { return }
            Unmanaged<KeyboardHandler>.fromOpaque(context).takeUnretainedValue().hidValue(value)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let open = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        Log.info("keyboard: IOHIDManagerOpen 0x\(String(UInt32(bitPattern: open), radix: 16)) (0xe00002c5 with delivery is the Karabiner case)")
        mine.manager = m
    }

    /// Input Monitoring granted while the layer was up: open the keyboard watch again, on the keyboard's own thread.
    func reopenKeyboardWatch() {
        lifecycle.lock.lock()
        let rl = lifecycle.unsafeValue.runLoop
        let generation = lifecycle.unsafeValue.session.requested
        lifecycle.lock.unlock()
        guard let rl, let generation else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) { [self] in
            guard isRequested(generation), let mine = layer, mine.generation == generation else { return }
            if let m = mine.manager { IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone)) }
            openHIDManager(into: mine)
        }
        CFRunLoopWakeUp(rl)
    }

    private func tearDown(_ mine: Layer) {
        if let t = mine.tap {
            CGEvent.tapEnable(tap: t, enable: false)
            CFMachPortInvalidate(t)
        }
        mine.tap = nil
        if let m = mine.manager { IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone)) }
        mine.manager = nil
        if mine.connect != 0 { IOServiceClose(mine.connect); mine.connect = 0 }
        if layer === mine { layer = nil }
        Log.info("keyboard: layer down")
    }

    private func lockState() -> Bool {
        guard connect != 0 else { return false }
        var on = false
        IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &on)
        return on
    }
    private func setLock(_ on: Bool) {
        guard connect != 0 else { return }
        IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), on)
    }

    private func hidValue(_ value: IOHIDValue) {
        guard let generation = layer?.generation, isReady(generation), !Self.bypass else { return }
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_KeyboardOrKeypad),
              IOHIDElementGetUsage(element) == UInt32(kHIDUsage_KeyboardCapsLock) else { return }
        // Caps Lock is an ordinary key when the TurnOver key is Control+Option alone.
        guard KeySettings.current.capsIsTurnOver else { capsDown = false; return }
        let pressed = IOHIDValueGetIntegerValue(value) != 0
        let stamp = IOHIDValueGetTimeStamp(value)
        if pressed {
            capsDown = true; chordFired = false; Self.capsHeld.value = true
            setLock(realCapsOn)
        } else {
            capsDown = false; Self.capsHeld.value = false
            setLock(realCapsOn)
            let sinceLastUp = Double(stamp &- lastCapsUp) * Self.machToNs / 1_000_000
            lastCapsUp = stamp
            if !chordFired && sinceLastUp < 350 {
                realCapsOn.toggle()
                setLock(realCapsOn)
                let on = realCapsOn
                let toggled = onCapsLockToggled
                onMain { toggled?(on) }
            }
        }
    }

    /// Set by the watchdog while the main thread is stuck: every key goes through untouched.
    private static let bypassLock = NSLock()
    nonisolated(unsafe) private static var _bypass = false   // under `bypassLock`
    static var bypass: Bool {
        get { bypassLock.lock(); defer { bypassLock.unlock() }; return _bypass }
        set { bypassLock.lock(); _bypass = newValue; bypassLock.unlock() }
    }

    /// VoiceOver's toggle shortcut as macOS has it (Keyboard Shortcuts, Accessibility), read once at launch.
    nonisolated static let voiceOverToggle = HandOver.toggleShortcut()
    nonisolated static func isVoiceOverToggle(code: Int64, flags: CGEventFlags) -> Bool {
        let s = voiceOverToggle
        guard code == Int64(s.keyCode) else { return false }
        let mods: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        return flags.intersection(mods) == s.flags.intersection(mods)
    }

    /// Coexisting, a game TurnOver leads in front (Steam's Big Picture): keys that pass go to the game's process alone,
    /// so VoiceOver's own tap never sees them. VoiceOver took the arrows as Quick Nav, found nothing in Big Picture,
    /// landed its cursor in Finder and brought Finder forward: "it slides off the app" (16 Oct 2026).
    nonisolated(unsafe) static var redirectPid: pid_t?
    /// Coexisting: the app TurnOver reads in front. The arrows TurnOver lets through or sends go to it alone while
    /// VoiceOver's Quick Nav may be on, so VoiceOver never takes them: it did, and every list in TurnOver's apps went
    /// dead, VoiceOver's cursor moving silently instead (19 Oct 2026). Arrows only, and never with Command:
    /// Command Tab and the rest stay the system's (keys to the process alone broke Command Tab in a game, 16 Oct 2026).
    nonisolated(unsafe) static var frontPid: pid_t = 0
    nonisolated static func arrowTarget(code: Int64, flags: CGEventFlags) -> pid_t? {
        guard Coexist.on, (123...126).contains(code), !flags.contains(.maskCommand), frontPid > 0,
              ArrowQuickNav.voiceOverMayBeOn.value, !TurnOverMenu.anyOpen.value else { return nil }
        // Only while the focus is in the app in front: in the Dock (Control F3) the arrows went to Claude's prompt
        // behind it, and the Dock didn't move (19 Oct 2026). Status menus and Spotlight are the same case.
        let focused = API.focusedPid
        guard focused == 0 || focused == frontPid else { return nil }
        // Not into an app's menu: a menu tracks its keys in a loop of its own, and an arrow posted to the process
        // closed Finder's context menu instead of opening Open With (a tester, 19 Oct 2026).
        guard !AXHandler.anyMenuOpen.value else { return nil }
        return frontPid
    }

    private func passOrRedirect(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        if Self.redirectPid == nil, let pid = Self.arrowTarget(code: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags) {
            event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            event.postToPid(pid)
            return nil
        }
        guard let pid = Self.redirectPid else { return Unmanaged.passUnretained(event) }
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        event.postToPid(pid)
        return nil
    }

    private func tapEvent(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let generation = layer?.generation, isRequested(generation) else { return Unmanaged.passUnretained(event) }
        if Self.bypass, type != .tapDisabledByTimeout, type != .tapDisabledByUserInput {
            if !quarantined.isEmpty { quarantined.removeAll() }   // their key-ups pass now; none must be swallowed later
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.warning("keyboard: tap disabled (\(type.rawValue)), re-enabling")
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            guard let t = tap, CGEvent.tapIsEnabled(tap: t) else {
                Log.error("keyboard: tap could not be re-enabled; handing input back")
                report(generation, ready: false)
                CFRunLoopStop(CFRunLoopGetCurrent())
                return Unmanaged.passUnretained(event)
            }
            // Three times in ten seconds: say so, once a minute (the team review: a failure that leaves the user
            // without keys is told, not only logged, 8 Oct 2026).
            let now = Date()
            disabledAt = disabledAt.filter { now.timeIntervalSince($0) < 10 } + [now]
            if disabledAt.count >= 3, now.timeIntervalSince(lastDisableSpoken) > 60 {
                lastDisableSpoken = now
                onMain { Speech.speakMessage("The system keeps switching TurnOver's keyboard off; TurnOver turns it back on each time. If keys are being missed, quit and start TurnOver again.") }
            }
            return Unmanaged.passUnretained(event)
        }
        // Our own re-posted keys (gesture.send) pass untouched.
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return Unmanaged.passUnretained(event) }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        // VoiceOver's own on-and-off shortcut goes straight on, never held for TurnOver's decision: held for a main
        // thread that was busy, Option Apostrophe (the maintainer's) reached macOS a second late, or not at all, and
        // VoiceOver seemed not to answer its key (25 Oct 2026). TurnOver has no command on it.
        if (type == .keyDown || type == .keyUp), Self.isVoiceOverToggle(code: code, flags: event.flags) {
            // A modifier pressed with it isn't a modifier pressed alone: no Dock or menu when it is let go.
            controlAlone = false; shiftAlone = false; optionAlone = false; commandAlone = false
            return Unmanaged.passUnretained(event)
        }
        // A direct app in front (Command Control Comma, D): every key goes to it alone, before TurnOver's commands and
        // without VoiceOver ever seeing it, as a game wants (18 Oct 2026: "like a direct touch"). Command and
        // its chords stay the system's, so Command Tab, Command Q and Command Control Comma (to leave) still work.
        // Not while TurnOver's layer waits for its letter (D, to leave) or its menu is open.
        if let direct = InputManager.directPid, type == .keyDown || type == .keyUp || type == .flagsChanged,
           !event.flags.contains(.maskCommand), code != 54, code != 55, !InputManager.isCapturing, !TurnOverMenu.anyOpen.value {
            event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            event.postToPid(direct)
            return nil
        }
        let settings = KeySettings.current   // a snapshot: never `config` itself on this thread
        if type == .flagsChanged {
            // Keyboard help names a modifier key pressed on its own, as NVDA's input help does: it heard only keys
            // that type or run something (12 Oct 2026: "it isn't reading command, control, option").
            if InputManager.isInputHelpActive { announceModifier(code: code, flags: event.flags, capsIsTurnOver: settings.capsIsTurnOver) }
            if code == 57 { return settings.capsIsTurnOver ? nil : Unmanaged.passUnretained(event) }   // caps lock's own event: nobody sees it while it is the TurnOver key
            // Control pressed and released alone stops speech (NVDA: the control key cancels).
            let ctrl = event.flags.contains(.maskControl)
            if code == 59 || code == 62 {
                if ctrl { controlAlone = true }
                else if controlAlone {
                    // In keyboard help, Control is only named. Mac style: VoiceOver's pause and resume. Windows style:
                    // NVDA's stop (Shift pauses there, below) (12 Oct 2026).
                    controlAlone = false
                    let stop = settings.windowsKeys
                    if !InputManager.isInputHelpActive { onMain { if stop { SayAll.stop(); Speech.cancel() } else { Speech.togglePause() } } }
                }
            } else { controlAlone = false }
            // Shift pressed and released alone, Windows style: NVDA's pause and resume.
            if code == 56 || code == 60 {
                if event.flags.contains(.maskShift) {
                    shiftAlone = event.flags.intersection([.maskControl, .maskAlternate, .maskCommand]).isEmpty && !capsDown
                    shiftDownAt = Date()
                } else {
                    let tapped = shiftAlone && Date().timeIntervalSince(shiftDownAt) < 0.6
                    shiftAlone = false
                    if tapped, settings.windowsKeys, !InputManager.isInputHelpActive { onMain { Speech.togglePause() } }
                }
            } else { shiftAlone = false }
            if code == 55 || code == 54 {
                let others: CGEventFlags = [.maskControl, .maskAlternate, .maskShift]
                if event.flags.contains(.maskCommand) {
                    commandAlone = event.flags.intersection(others).isEmpty && !capsDown
                    commandDownAt = Date()
                } else {
                    let tapped = commandAlone && Date().timeIntervalSince(commandDownAt) < 0.6
                    commandAlone = false
                    if tapped, settings.windowsKeys {
                        Log.io("command released alone")
                        onMain {
                            guard !TurnOverMenu.shared.isOpen else { return }
                            if InputManager.isInputHelpActive, let s = GlobalCommands.shared.script(named: "openMenus") {
                                InputManager.handleInputHelp(KeyboardGesture(keyCode: 55, modifiers: .command, characters: "", timestamp: 0, isRepeat: false, flags: []), script: s)
                            } else { GlobalCommands.toggleMenus() }
                        }
                    }
                }
            } else { commandAlone = false }
            if code == 58 || code == 61 {
                let others: CGEventFlags = [.maskControl, .maskCommand, .maskShift]
                if event.flags.contains(.maskAlternate) {
                    // Down. (Both Options down at once is not a tap of either.)
                    optionAlone = event.flags.intersection(others).isEmpty && !capsDown && optionCode == 0
                    optionCode = code
                    optionDownAt = Date()
                } else {
                    let tapped = optionAlone && Date().timeIntervalSince(optionDownAt) < 0.6
                    let which = optionCode
                    optionAlone = false; optionCode = 0
                    Log.io("option \(which == 61 ? "right" : "left") released\(tapped ? " alone" : "")")
                    if tapped, settings.windowsKeys {
                        let name = which == 61 ? "contextMenu" : "focusDock"
                        let g = KeyboardGesture(keyCode: which, modifiers: .option, characters: "", timestamp: 0, isRepeat: false, flags: [])
                        onMain {
                            guard !TurnOverMenu.shared.isOpen, let s = GlobalCommands.shared.script(named: name) else { return }
                            if InputManager.isInputHelpActive { InputManager.handleInputHelp(g, script: s) } else { ScriptHandler.queueScript(s, gesture: g) }
                        }
                    }
                }
            } else { optionAlone = false }
            if !event.flags.contains(.maskAlternate) { optionCode = 0 }
            return Unmanaged.passUnretained(event)
        }
        controlAlone = false
        shiftAlone = false
        optionAlone = false
        commandAlone = false
        if let r = keypad(type, event, code, settings) { return r }
        if let r = quickNavArrow(type, event, code, settings) { return r }
        if type == .keyUp {
            if quarantined.contains(code) { quarantined.remove(code); return nil }
            if remapped.contains(code) { remapped.remove(code); WindowsRemap.apply(.keyUp, event) }
            return passOrRedirect(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        // An echo loop: the same key again within 8 ms, three times running. No hand or key repeat is that fast
        // (macOS's fastest repeat is about 30 ms). On 4 Oct 2026 Left Arrow came back 394 times in a second while
        // VoiceOver was still shutting down after the hand-over (TurnOver's own re-posted key, its marker gone), and
        // the edge sound played for each. Drop the copies: that breaks the loop.
        let nowNs = DispatchTime.now().uptimeNanoseconds
        if code == echoCode, nowNs &- echoAt < 8_000_000 { echoCount += 1 } else { echoCount = 0 }
        echoCode = code; echoAt = nowNs
        if echoCount >= 2 {
            if echoCount == 2 {
                // Who posted the copy (E18): the process behind the event, and whether TurnOver's marker survived.
                let src = pid_t(event.getIntegerValueField(.eventSourceUnixProcessID))
                let name = NSRunningApplication(processIdentifier: src)?.bundleIdentifier ?? "pid \(src)"
                let state = event.getIntegerValueField(.eventSourceStateID)
                Log.error("keyboard: key \(code) arriving every few milliseconds (an echo loop); dropping the copies. Posted by \(name) (TurnOver is \(getpid())), source state \(state), user data \(event.getIntegerValueField(.eventSourceUserData))")
            }
            return nil
        }
        // Right Option+T: the date and time, as the owner has it under VoiceOver (4 Oct 2026). Right Option only, so
        // left Option+T still types its character.
        if code == 17, optionCode == 61, settings.optionCommander, event.flags.intersection([.maskControl, .maskCommand, .maskShift]).isEmpty, event.flags.contains(.maskAlternate) {
            let g = KeyboardGesture(keyCode: code, modifiers: .option, characters: "", timestamp: 0, isRepeat: false, flags: event.flags)
            // Through the user's keys, where right Option T is the time and date unless they gave it something else
            // (UserGestures.defaults). It asked for "vo_dateTime", a name no command has had since, so it did nothing
            // (12 Oct 2026).
            onMain {
                Log.io("input kb:rightoption+t")
                Speech.cancel()   // as every key does: the second press (the date) no longer waits for the time to be said
                switch UserGestures.lookup(g) {
                case .script(let s): ScriptHandler.queueScript(s, gesture: g)
                case .removed: Log.io("right Option T taken away by the user: nothing to do")
                case nil: if let s = ScriptHandler.findScript(named: "dateTime") { ScriptHandler.queueScript(s, gesture: g) }
                }
            }
            quarantined.insert(code)
            return nil
        }
        var mods = Modifiers()
        if event.flags.contains(.maskShift) { mods.insert(.shift) }
        if event.flags.contains(.maskControl) { mods.insert(.control) }
        if event.flags.contains(.maskAlternate) { mods.insert(.option) }
        if event.flags.contains(.maskCommand) { mods.insert(.command) }
        if capsDown { mods.insert(.turnover); chordFired = true }
        if event.getIntegerValueField(.eventSourceUserData) == Self.typedTurnOverMarker { mods.insert(.turnover) }
        // VO-Semicolon locked the TurnOver key: every key is a TurnOver key until it is unlocked (VoiceOver's own).
        if InputManager.turnOverKeyLocked, !mods.contains(.turnover) { mods.insert(.turnover) }
        // VoiceOver's VO keys as the TurnOver key: Control+Option together become it (and are no longer themselves).
        if settings.controlOptionIsTurnOver, mods.contains(.control), mods.contains(.option) {
            mods.remove(.control); mods.remove(.option); mods.insert(.turnover)
        }
        var gesture = KeyboardGesture(keyCode: code, modifiers: mods, characters: Self.characters(of: event),
                                      timestamp: UInt64(Double(event.timestamp) / Self.machToNs),
                                      isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0, flags: event.flags)
        // The Windows style: a Windows key TurnOver has no command of its own for becomes the Mac key that does the
        // same (Control C to Command C, Control Left to Option Left). TurnOver's own bindings (browse mode's Home,
        // Control Home) keep their keys. The key's release is translated to match.
        // The lookup happens once, here, and is handed on; a TurnOver chord is not looked up on this thread at all.
        if settings.windowsKeys, !mods.contains(.turnover), ScriptHandler.mainHasScript(for: gesture) == false, WindowsRemap.apply(.keyDown, event) {
            remapped.insert(code)
            let c2 = event.getIntegerValueField(.keyboardEventKeycode)
            var m2 = Modifiers()
            if event.flags.contains(.maskShift) { m2.insert(.shift) }
            if event.flags.contains(.maskControl) { m2.insert(.control) }
            if event.flags.contains(.maskAlternate) { m2.insert(.option) }
            if event.flags.contains(.maskCommand) { m2.insert(.command) }
            gesture = KeyboardGesture(keyCode: c2, modifiers: m2, characters: Self.characters(of: event), timestamp: gesture.timestamp, isRepeat: gesture.isRepeat, flags: event.flags)
        }
        switch ScriptHandler.askMain(gesture) {
        case .taken, .deferred:
            quarantined.insert(code)
            return nil
        case .passed:
            if code == 48, event.flags.contains(.maskCommand) { clearLeftoverModifiers(before: "Command Tab") }
            return passOrRedirect(event)
        }
    }

    /// Command Tab did nothing eight times running, then worked once TurnOver was turned off and on (20 Oct
    /// 2026): the Mac's view of the modifiers had drifted from the keyboard's, most likely a modifier TurnOver had
    /// lifted or put back (post) that the hand no longer held. Before a Command Tab passes, any modifier the session
    /// thinks is held but the keyboard doesn't is released, and both states go in the log for the next time.
    private func clearLeftoverModifiers(before what: String) {
        let hid = CGEventSource.flagsState(.hidSystemState), session = CGEventSource.flagsState(.combinedSessionState)
        let watched: [(CGEventFlags, Int64, String)] = [(.maskControl, 59, "Control"), (.maskAlternate, 58, "Option"), (.maskShift, 56, "Shift"), (.maskSecondaryFn, 63, "Fn")]
        let leftover = watched.filter { session.contains($0.0) && !hid.contains($0.0) }
        Log.io("\(what): modifiers held by the keyboard \(hid.rawValue & 0xFFFF0000), by the session \(session.rawValue & 0xFFFF0000)\(leftover.isEmpty ? "" : "; releasing \(leftover.map(\.2).joined(separator: ", "))")")
        guard !leftover.isEmpty else { return }
        let src = CGEventSource(stateID: .combinedSessionState)
        var state = session
        for (f, code, _) in leftover {
            state.remove(f)
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: false) else { continue }
            e.type = .flagsChanged
            e.flags = state
            e.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            e.post(tap: .cghidEventTap)
        }
    }

    /// VoiceOver's arrow-key Quick Nav: while it is on and the arrows are its (ArrowQuickNav.applies), a bare arrow
    /// is held until it is let go, so a second arrow pressed with it makes a chord (Up and Down: the default action,
    /// and so on) instead of two moves. Held keys repeat as moves. nil: not Quick Nav's; otherwise swallowed.
    private func quickNavArrow(_ type: CGEventType, _ event: CGEvent, _ code: Int64, _ settings: KeySettings) -> Unmanaged<CGEvent>?? {
        guard let name = Self.arrowNames[code], type == .keyDown || type == .keyUp else { return nil }
        if type == .keyUp {
            if code == arrowDownWhileOff { arrowDownWhileOff = nil }
            guard code == arrowHeld else { return nil }   // the chord's second arrow is let go through `quarantined`
            arrowHeld = nil
            if !arrowChorded && !arrowRepeated { onMain { ArrowQuickNav.single(name) } }
            return .some(nil)
        }
        let bare = !capsDown && event.flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand]).isEmpty
        // Quick Nav off: arrows go to the app as always; Left and Right together turn Quick Nav on (Mac style).
        if !ArrowQuickNav.applies.value {
            guard bare, !settings.windowsKeys, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return nil }
            if let first = arrowDownWhileOff, first != code, Set([first, code]) == Set<Int64>([123, 124]) {
                arrowDownWhileOff = nil
                quarantined.insert(code)
                onMain { Log.io("input chord leftArrow+rightArrow (Quick Nav off)"); ArrowQuickNav.turnOnFromChord() }
                return .some(nil)
            }
            arrowDownWhileOff = code
            return nil
        }
        guard bare else { return nil }
        if let first = arrowHeld, first != code, let firstName = Self.arrowNames[first] {
            arrowChorded = true
            quarantined.insert(code)
            onMain { Log.io("input chord \(firstName)+\(name)"); ArrowQuickNav.chord(firstName, name) }
            return .some(nil)
        }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            guard !arrowChorded else { return .some(nil) }
            arrowRepeated = true
            onMain { ArrowQuickNav.single(name) }
            return .some(nil)
        }
        arrowHeld = code; arrowChorded = false; arrowRepeated = false
        return .some(nil)
    }

    /// The keypad (Keypad.swift): nil when it is not the keypad's to handle; otherwise the answer (nil inside: swallowed).
    private var keypadZeroDown = false
    private func keypad(_ type: CGEventType, _ event: CGEvent, _ code: Int64, _ s: KeySettings) -> Unmanaged<CGEvent>?? {
        guard Keypad.codes.contains(code), type == .keyDown || type == .keyUp else { return nil }
        let f = event.flags
        let vo = f.contains(.maskControl) && f.contains(.maskAlternate)
        let windows = s.windowsKeys
        let repeatKey = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        // Windows style: Clear, where Num Lock is on a PC, switches the keypad between NVDA's commands and numbers.
        if windows, code == Keypad.clear, f.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift]).isEmpty, !capsDown {
            if type == .keyDown, !repeatKey { onMain { Keypad.toggleWindows() } }
            return .some(nil)
        }
        guard windows ? s.keypadCommands : s.numpadCommander else { keypadZeroDown = false; return nil }
        // Pass next key, sleep mode and TurnOver's own screens take the keypad as any other key (the code review).
        if InputManager.passNextKey || InputManager.isAsleep(bundle: WindowsRemap.front) { keypadZeroDown = false; return nil }
        if !windows, vo { return nil }   // VO-Clear and other VO keys: the usual way
        // Keypad 0 held is the keypad's modifier (VoiceOver's 0 layer; NVDA's numpad Insert).
        if code == Keypad.zero { keypadZeroDown = type == .keyDown; return .some(nil) }
        var mods = Modifiers()
        if f.contains(.maskShift) { mods.insert(.shift) }
        if f.contains(.maskCommand) { mods.insert(.command) }
        if vo && windows { mods.insert(.turnover) } else {
            if f.contains(.maskControl) { mods.insert(.control) }
            if f.contains(.maskAlternate) { mods.insert(.option) }
        }
        if capsDown || keypadZeroDown { mods.insert(.turnover); chordFired = true }
        let g = KeyboardGesture(keyCode: code, modifiers: mods, characters: "", timestamp: UInt64(Double(event.timestamp) / Self.machToNs), isRepeat: repeatKey, flags: f)
        // A key with nothing assigned goes to the application (numpad Enter, Equals: typing still works).
        guard Keypad.action(for: g, windows: windows) != nil else { return nil }
        if type == .keyDown { onMain { Keypad.run(g, windows: windows) } }
        return .some(nil)
    }

    private static func characters(of event: CGEvent) -> String {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &chars)
        return String(utf16CodeUnits: chars, count: length)
    }

    /// Text typed as key events carrying the characters themselves (braille input), marked so the tap ignores them.
    static func postText(_ s: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        for unit in s.utf16 {
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
                var u = unit
                e.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
                // No modifiers: the text rides on the A key, and a modifier the system still thought held went with
                // it. Fn left over from an arrow key made "few" typed on the display Fn A, macOS's "focus the Dock"
                // (7 Oct 2026).
                e.flags = .maskNonCoalesced
                e.setIntegerValueField(.eventSourceUserData, value: marker)
                e.post(tap: .cghidEventTap)
            }
        }
    }

    /// A key as if typed, for an AI trying a plugin: the tap handles it (scripts, plugins, echo) like the owner's own.
    static func postTyped(_ g: KeyboardGesture) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(g.keyCode), keyDown: down) else { continue }
            e.flags = g.flags.union(.maskNonCoalesced)
            e.setIntegerValueField(.eventSourceUserData, value: g.modifiers.contains(.turnover) ? typedTurnOverMarker : typedMarker)
            e.post(tap: .cghidEventTap)
            usleep(20_000)
        }
    }

    /// Keys down together, then up: a chord VoiceOver recognises (Left and Right for Quick Nav), marked so the tap ignores them.
    static func postChord(_ codes: [Int64]) {
        let src = CGEventSource(stateID: .hidSystemState)
        var held: CGEventFlags = [.maskSecondaryFn, .maskNumericPad]
        for down in [true, false] {
            for code in (down ? codes : codes.reversed()) {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: down) else { continue }
                e.flags = held
                e.setIntegerValueField(.eventSourceUserData, value: marker)
                e.post(tap: .cghidEventTap)
                usleep(15_000)
            }
            held = [.maskSecondaryFn, .maskNumericPad]
        }
    }

    /// NVDA's gesture.send: the key down and up, marked so the tap ignores them.
    static func post(_ g: KeyboardGesture) {
        let src = CGEventSource(stateID: .hidSystemState)
        // Modifiers the hand still holds that the key sent must not carry (Control and Option under VO-Left, when the
        // key sent is a bare Left): Word asked the keyboard itself and saw them held, and did nothing with the arrow
        // (17 Oct 2026: "VO Left wasn't behaving"; the key driver, holding nothing, had it working). They are
        // lifted around the key and put back after, as events the tap lets through.
        let held = CGEventSource.flagsState(.hidSystemState)
        let lift: [(CGEventFlags, Int64)] = [(.maskControl, 59), (.maskAlternate, 58), (.maskCommand, 55), (.maskShift, 56)].filter { held.contains($0.0) && !g.flags.contains($0.0) }
        var state = held
        func modifier(_ code: Int64, down: Bool, flags: CGEventFlags) {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: down) else { return }
            e.type = .flagsChanged
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: marker)
            e.post(tap: .cghidEventTap)
        }
        for (f, code) in lift { state.remove(f); modifier(code, down: false, flags: state) }
        let toApp = arrowTarget(code: Int64(g.keyCode), flags: g.flags)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(g.keyCode), keyDown: down) else { continue }
            e.flags = g.flags
            e.setIntegerValueField(.eventSourceUserData, value: marker)
            if let toApp { e.postToPid(toApp) } else { e.post(tap: .cghidEventTap) }
        }
        // Put back only what the hand still holds: a release in between was overwritten by a synthetic press, and
        // every key after carried Control until the next tap of it (the code review, 17 Oct 2026).
        let stillHeld = CGEventSource.flagsState(.hidSystemState)
        for (f, code) in lift.reversed() where stillHeld.contains(f) { state.insert(f); modifier(code, down: true, flags: state) }
        if !lift.isEmpty {
            let gone = lift.filter { !stillHeld.contains($0.0) }.count
            Log.io("key sent with \(lift.count) held modifier\(lift.count == 1 ? "" : "s") lifted around it\(gone > 0 ? "; \(gone) released meanwhile, left up" : "")")
        }
    }
}
