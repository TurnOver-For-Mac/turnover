// SPDX-License-Identifier: GPL-3.0-or-later
// The Windows keyboard style's translations (WINDOWS-MODE.md): Windows keys rewritten, as they are typed, into the
// Mac keys that do the same, matched by position (the PC's Alt is where the Mac's Command is; its Control is the Mac's
// Control). Used by TurnOver's own key layer where TurnOver leads, and, with "NVDA and JAWS keys where VoiceOver reads too", by a small
// layer of its own while VoiceOver leads, so the whole Mac answers to Windows keys (6 Oct 2026).
//
// Never touched: anything with Control and Option together (VoiceOver's keys), anything already with Command (Mac
// shortcuts), and Terminal's keys (Control C and the rest belong to the shell there).
import Foundation
import AppKit
import CoreGraphics
import IOKit
import IOKit.hid
import Carbon
import TurnOverCore

// The remap and the layer run on the key tap's own thread: nothing here is the main actor's.
nonisolated enum WindowsRemap {
    // The application in front, kept up to date from the main thread; read on the key threads.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _front = ""   // under `lock`
    static var front: String { lock.lock(); defer { lock.unlock() }; return _front }
    nonisolated(unsafe) private static var token: NSObjectProtocol?   // main thread only

    static func watchFrontApp() {
        guard token == nil else { return }
        @Sendable func set(_ b: String?) { lock.lock(); _front = b ?? ""; lock.unlock() }
        set(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        token = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            set((n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier)
        }
    }

    static let browsers: Set<String> = ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.brave.Browser"]
    /// Apps whose grid already takes the Windows keys: Home, End and Control with the arrows or Home go to the row's
    /// start, A1 and the edge of the data, as on a PC. Translated, Control Home became Command Up and went to the top
    /// of the column (Excel, Day 2, 10 Oct 2026). The Control letters (copy, paste) are still translated.
    static let windowsGrid: Set<String> = ["com.microsoft.Excel"]
    static let keepControl: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "co.zeit.hyper", "net.kovidgoyal.kitty"]

    // Key codes.
    static let left: Int64 = 123, right: Int64 = 124, down: Int64 = 125, up: Int64 = 126
    static let home: Int64 = 115, end: Int64 = 119, backspace: Int64 = 51, forwardDelete: Int64 = 117, f4: Int64 = 118
    /// Control with these letters becomes Command with them (copy, cut, paste, select all, undo, save, open, new,
    /// print, find, close, new tab).
    static let commandLetters: Set<Int64> = [8, 7, 9, 0, 6, 1, 31, 45, 35, 3, 13, 17]
    static let letterY: Int64 = 16, letterZ: Int64 = 6, letterQ: Int64 = 12, letterW: Int64 = 13

    /// Rewrite a key down or up in place. True if it was changed.
    @discardableResult
    static func apply(_ type: CGEventType, _ event: CGEvent) -> Bool {
        guard type == .keyDown || type == .keyUp, KeySettings.current.windowsKeys else { return false }
        var flags = event.flags
        let ctrl = flags.contains(.maskControl), opt = flags.contains(.maskAlternate), cmd = flags.contains(.maskCommand)
        if ctrl && opt { return false }   // VoiceOver's keys
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        func set(_ newCode: Int64, add: CGEventFlags, remove: CGEventFlags) -> Bool {
            flags.remove(remove); flags.insert(add)
            if [left, right, up, down].contains(newCode) { flags.insert([.maskSecondaryFn, .maskNumericPad]) }
            event.setIntegerValueField(.keyboardEventKeycode, value: newCode)
            event.flags = flags
            return true
        }
        // Alt F4 (Command F4) quits; Control F4 closes the window.
        if code == f4, cmd, !ctrl { return set(letterQ, add: [], remove: [.maskSecondaryFn]) }
        if code == f4, ctrl, !cmd { return set(letterW, add: .maskCommand, remove: [.maskControl, .maskSecondaryFn]) }
        if cmd { return false }   // a Mac shortcut already
        let app = front
        let terminal = keepControl.contains(app)
        // Home and End: line start and end (Command Left, Right), with Control the document's (Command Up, Down). Not in
        // a browser: Command Left there is Back, and on a page Home and End already go to the top and bottom.
        let grid = windowsGrid.contains(app)
        if (code == home || code == end), !browsers.contains(app), !terminal, !grid {
            return set(code == home ? (ctrl ? up : left) : (ctrl ? down : right), add: .maskCommand, remove: .maskControl)
        }
        guard ctrl, !terminal else { return false }
        if [left, right, up, down, backspace, forwardDelete].contains(code) { return grid ? false : set(code, add: .maskAlternate, remove: .maskControl) }
        if commandLetters.contains(code) { return set(code, add: .maskCommand, remove: .maskControl) }
        if code == letterY { return set(letterZ, add: [.maskCommand, .maskShift], remove: .maskControl) }   // redo
        return false
    }
}

/// NVDA's keys where VoiceOver reads (docs/KEYBOARD-STYLES-PLAN.md step 2, 19 Oct 2026; Windy folded in).
/// In a Windows-family style, wherever VoiceOver is the reader, this layer turns the keys into VoiceOver's: Caps Lock
/// held is the NVDA key, and each NVDA command with a VoiceOver twin is sent as VoiceOver's own chord (NVDA+A is VO-A,
/// NVDA+Tab VO-F4, NVDA+F7 the rotor, and so on); Caps Lock and Space turn browse mode on and off, where NVDA's
/// single letters (H, K, T…) become VoiceOver's Quick Nav finds. The Windows key's chords are on Option (Option E
/// Finder, Option L lock…), the Windows editing keys are rewritten (Control C to Command C, Home and End), and the
/// lone taps open the menu bar, the Dock and the shortcut menu. VoiceOver does all the reading; words of the layer's
/// own (browse mode, the time) are said through VoiceOver.
///
/// A tap at the head of the HID level, so it sees keys before VoiceOver does (the finding of 16 Oct 2026); chords
/// are posted as a hand presses them, each modifier down in turn: VoiceOver ignored a key carrying the flags alone
/// (Windy, 17 Oct 2026). Caps Lock's presses are read from the HID manager and the system's caps state kept off.
/// Where TurnOver reads, TurnOver's own key tap has the keys and this layer is stopped.
nonisolated final class WindowsKeyLayer: @unchecked Sendable {   // its state belongs to the tap thread
    static let shared = WindowsKeyLayer()
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var manager: IOHIDManager?
    private var connect: io_connect_t = 0
    private var capsDown = false
    private var swallowedUps = Set<Int64>()
    private var browse = false
    private var passNext = false
    private var commandAlone = false, commandAt = Date.distantPast
    private var optionAlone = false, optionCode: Int64 = 0, optionAt = Date.distantPast

    var isOn: Bool { thread != nil }

    func start() {
        MainActor.assumeIsolated { Self.buildStyleChords() }   // start() is called on the main thread (refreshWindowsLayer); again on a style change while running
        guard thread == nil else { return }
        WindowsRemap.watchFrontApp()
        let t = Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
            if service != 0 { IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect); IOObjectRelease(service) }
            openHID()
            let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue | 1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue)
            guard let tp = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<WindowsKeyLayer>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                Log.error("NVDA keys where VoiceOver reads: no event tap"); return
            }
            tap = tp
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tp, 0), .defaultMode)
            Log.info("NVDA keys where VoiceOver reads: on")
            CFRunLoopRun()
            if let tp = tap { CGEvent.tapEnable(tap: tp, enable: false) }
            tap = nil
            if let m = manager { IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone)) }
            manager = nil
            if connect != 0 { IOServiceClose(connect); connect = 0 }
            capsDown = false; browse = false; swallowedUps.removeAll()
            Log.info("NVDA keys where VoiceOver reads: off")
        }
        t.name = "turnover.windowskeys"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() {
        guard let rl = runLoop else { thread = nil; return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) { CFRunLoopStop(rl) }
        CFRunLoopWakeUp(rl)
        thread = nil; runLoop = nil
    }

    private func openHID() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard] as CFDictionary)
        IOHIDManagerSetInputValueMatching(m, [kIOHIDElementUsagePageKey: kHIDPage_KeyboardOrKeypad, kIOHIDElementUsageKey: kHIDUsage_KeyboardCapsLock] as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(m, { context, _, _, value in
            guard let context else { return }
            Unmanaged<WindowsKeyLayer>.fromOpaque(context).takeUnretainedValue().caps(value)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
    }

    private func caps(_ value: IOHIDValue) {
        guard KeySettings.current.capsIsTurnOver else { capsDown = false; return }
        capsDown = IOHIDValueGetIntegerValue(value) != 0
        // The system's caps state stays off: Caps Lock is the NVDA key, not a lock.
        if connect != 0 { IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), false) }
    }

    // MARK: The keys

    struct Chord: Hashable { let code: Int64; let shift: Bool; let control: Bool }
    struct Target { let code: Int64; let flags: CGEventFlags; var times: Int = 1 }
    static let vo: CGEventFlags = [.maskControl, .maskAlternate]

    static let keyCodes: [String: Int64] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33,
        "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "forwardDelete": 117,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "home": 115, "end": 119, "pageUp": 116, "pageDown": 121, "left": 123, "right": 124, "down": 125, "up": 126,
    ]
    static func chord(_ s: String) -> Chord? {
        let parts = s.split(separator: "+").map(String.init)
        guard let key = parts.last, let code = keyCodes[key] else { return nil }
        return Chord(code: code, shift: parts.contains("shift"), control: parts.contains("control"))
    }
    static func target(_ s: String, times: Int = 1) -> Target? {
        let parts = s.split(separator: "+").map(String.init)
        guard let key = parts.last, let code = keyCodes[key] else { return nil }
        var f: CGEventFlags = []
        if parts.contains("vo") { f.formUnion(vo) }
        if parts.contains("shift") { f.insert(.maskShift) }
        if parts.contains("command") { f.insert(.maskCommand) }
        if parts.contains("control") { f.insert(.maskControl) }
        if parts.contains("option") { f.insert(.maskAlternate) }
        return Target(code: code, flags: f, times: times)
    }

    /// NVDA's chords (the NVDA key held; the laptop layout, with the rulings of 12 Oct 2026) and VoiceOver's key
    /// for each: Windy's table of 17 Oct 2026 (Windy's WINDY-KEYS.md lists the NVDA keys with no VoiceOver twin).
    static let chordTable: [(String, String, Int)] = [
        ("x", "vo+z", 1), ("1", "vo+k", 1), ("f12", "vo+f7", 1), ("shift+b", "vo+f7", 2),
        ("tab", "vo+f4", 1), ("t", "vo+f2", 1), ("b", "vo+shift+w", 1),
        ("a", "vo+a", 1), ("l", "vo+l", 1), ("shift+s", "vo+f6", 1), ("f", "vo+t", 1), ("shift+f", "vo+t", 1), ("k", "vo+shift+u", 1), ("delete", "vo+f3", 1),
        ("control+down", "vo+c", 2), ("control+right", "vo+r", 2), ("control+up", "vo+c", 1), ("control+left", "vo+r", 1),
        ("shift+o", "vo+f3", 1), ("shift+up", "vo+shift+up", 1), ("shift+down", "vo+shift+down", 1), ("shift+left", "vo+left", 1), ("shift+right", "vo+right", 1),
        ("shift+[", "vo+shift+left", 1), ("shift+]", "vo+shift+right", 1), ("return", "vo+space", 1), ("shift+delete", "vo+command+f3", 1),
        ("up", "vo+up", 1), ("down", "vo+down", 1), ("shift+.", "vo+l", 1), ("control+.", "vo+w", 1), (".", "vo+c", 1), ("left", "vo+left", 1), ("right", "vo+right", 1),
        ("control+home", "vo+command+home", 1), ("control+end", "vo+command+end", 1), ("shift+a", "vo+a", 1),
        ("[", "vo+shift+space", 1), ("]", "vo+shift+m", 1), ("shift+m", "vo+command+f5", 1), ("shift+n", "vo+shift+f5", 1),
        ("f7", "vo+u", 1), ("control+f", "vo+f", 1), ("f3", "vo+g", 1), ("shift+f3", "vo+shift+g", 1),
        ("control+escape", "vo+shift+f11", 1), ("control+g", "vo+f8", 1), ("control+v", "vo+f8", 1),
        ("shift+control+right", "vo+command+shift+right", 1), ("shift+control+left", "vo+command+shift+left", 1),
        ("shift+control+up", "vo+command+shift+up", 1), ("shift+control+down", "vo+command+shift+down", 1),
    ]
    /// A JAWS or Narrator table's own commands and VoiceOver's key for each. A key that names a command, rather than
    /// standing for an NVDA key, has no twin to take, so where VoiceOver reads it was swallowed (the maintainer, 29 Oct
    /// 2026). A command not listed here still has no key there.
    static let commandTable: [(String, String, Int)] = [
        // JAWS's lists of one kind: VoiceOver's rotor, as NVDA+F7's list.
        ("jaws_linksList", "vo+u", 1), ("jaws_headingsList", "vo+u", 1), ("jaws_formFieldsList", "vo+u", 1),
    ]
    /// A JAWS or Narrator table's keys that stand for an NVDA key ("=kb:turnover+…"), given that key's VoiceOver twin,
    /// and its keys that name a command of commandTable, given that command's; built on the main thread as the layer
    /// starts (28 Oct 2026: JAWS keys where VoiceOver reads too).
    nonisolated static let styleChords = Locked<[Chord: Target]>([:])
    @MainActor static func buildStyleChords() {
        var d: [Chord: Target] = [:]
        let style = config.general.style
        if style == .jaws || style == .narrator {
            func parse(_ id: String) -> Chord? {
                var p = normalizeGestureIdentifier(id)
                guard p.hasPrefix("kb:turnover+") else { return nil }
                p = String(p.dropFirst("kb:turnover+".count))
                // The layer's names: canonical "delete" is forward delete, "backspace" the key this layer calls delete.
                let names = ["leftArrow": "left", "rightArrow": "right", "upArrow": "up", "downArrow": "down", "enter": "return", "backspace": "delete", "delete": "forwardDelete"]
                let parts = p.split(separator: "+").map { names[String($0)] ?? String($0) }
                // Only Shift and Control are chord modifiers here: an alias with Command or Option would collapse onto
                // another chord (JAWS Shift Page Up, a review, 28 Oct 2026).
                guard !parts.contains("command"), !parts.contains("option") else { return nil }
                return chord(parts.joined(separator: "+"))
            }
            var commands: [String: Target] = [:]
            for (name, v, times) in commandTable { if let t = target(v, times: times) { commands[name] = t } }
            for (k, v) in StyleKeymap.keys(for: style) {
                guard let from = parse(k) else { continue }
                if v.hasPrefix("=") { if let to = parse(String(v.dropFirst())), let t = chords[to] { d[from] = t } }
                else if let t = commands[v] { d[from] = t }
            }
        }
        styleChords.value = d
        if !d.isEmpty { Log.info("NVDA keys where VoiceOver reads: \(d.count) \(style.rawValue) keys added") }
    }
    static let chords: [Chord: Target] = {
        var d: [Chord: Target] = [:]
        for (n, v, times) in chordTable { if let c = chord(n), let t = target(v, times: times) { d[c] = t } }
        return d
    }()
    /// Browse mode's single letters and VoiceOver's Quick Nav find for each (VO-Command with the letter; Shift goes
    /// back): heading, link, list, table, graphic, form control (F, E, B, X, C, R all as VoiceOver's control find).
    static let letters: [Int64: Int64] = {
        var d: [Int64: Int64] = [:]
        for (l, t) in [("h", "h"), ("k", "l"), ("l", "x"), ("t", "t"), ("g", "g"), ("f", "j"), ("e", "j"), ("b", "j"), ("x", "j"), ("c", "j"), ("r", "j"), ("v", "v"), ("i", "x")] {
            if let a = keyCodes[l], let b = keyCodes[t] { d[a] = b }
        }
        return d
    }()

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == KeyboardHandler.marker { return Unmanaged.passUnretained(event) }
        guard KeySettings.current.windowsKeys else { return Unmanaged.passUnretained(event) }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        if type == .flagsChanged {
            if code == 57, KeySettings.current.capsIsTurnOver { return nil }   // Caps Lock's own event: the NVDA key
            // The lone taps: Command alone the menu bar, left Option the Dock, right Option the shortcut menu.
            if code == 55 || code == 54 {
                if flags.contains(.maskCommand) { commandAlone = flags.intersection([.maskControl, .maskAlternate, .maskShift]).isEmpty && !capsDown; commandAt = Date() }
                else {
                    if commandAlone, Date().timeIntervalSince(commandAt) < 0.6 { Self.post(Target(code: 120, flags: .maskControl)) }
                    commandAlone = false
                }
            } else { commandAlone = false }
            if code == 58 || code == 61 {
                if flags.contains(.maskAlternate) {
                    optionAlone = flags.intersection([.maskControl, .maskCommand, .maskShift]).isEmpty && !capsDown && optionCode == 0
                    optionCode = code; optionAt = Date()
                } else {
                    if optionAlone, Date().timeIntervalSince(optionAt) < 0.6 {
                        Self.post(optionCode == 61 ? Target(code: 46, flags: Self.vo.union(.maskShift)) : Target(code: 99, flags: .maskControl))
                    }
                    optionAlone = false; optionCode = 0
                }
            } else { optionAlone = false }
            return Unmanaged.passUnretained(event)
        }
        commandAlone = false; optionAlone = false
        if type == .keyUp {
            if swallowedUps.contains(code) { swallowedUps.remove(code); return nil }
            WindowsRemap.apply(type, event)
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        if passNext { passNext = false; return Unmanaged.passUnretained(event) }
        let shift = flags.contains(.maskShift), control = flags.contains(.maskControl)
        let plain = !flags.contains(.maskCommand) && !flags.contains(.maskAlternate)
        if capsDown, plain {
            swallowedUps.insert(code)
            switch (code, shift, control) {
            case (49, false, false):   // NVDA+Space: browse mode on and off
                browse.toggle()
                Self.say(browse ? "browse mode" : "focus mode")
                return nil
            case (111, false, false):  // NVDA+F12: the time
                let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short
                Self.say(f.string(from: Date()))
                return nil
            case (120, false, false):  // NVDA+F2: the next key passes untouched
                passNext = true
                Self.say("pass next key through")
                return nil
            case (45, false, false):   // NVDA+N: TurnOver's menu
                DispatchQueue.main.async { MainActor.assumeIsolated { MenuAnywhere.shared.open() } }
                return nil
            case (15, false, false):   // NVDA+R: TurnOver's screen recognition, stepping in for the result (28 Oct 2026)
                DispatchQueue.main.async { MainActor.assumeIsolated { MenuAnywhere.shared.recognize() } }
                return nil
            case (15, true, false):    // NVDA+Shift+R: the screen interface (experimental)
                DispatchQueue.main.async { MainActor.assumeIsolated { MenuAnywhere.shared.recognizeInterface() } }
                return nil
            default: break
            }
            let c = Chord(code: code, shift: shift, control: control)
            if let t = Self.styleChords.value[c] ?? Self.chords[c] { Self.post(t); return nil }   // the style's own aliases first (a review, 28 Oct 2026)
            Log.io("NVDA keys where VoiceOver reads: key \(code) has no VoiceOver twin")
            return nil
        }
        if browse, !capsDown, plain, !control, let target = Self.letters[code] {
            swallowedUps.insert(code)
            Self.post(Target(code: target, flags: Self.vo.union(.maskCommand).union(shift ? .maskShift : [])))
            return nil
        }
        // The Windows key's own chords, on Option (where the PC's Windows key sits).
        if flags.contains(.maskAlternate), !flags.contains(.maskCommand), !control, !capsDown {
            var done = true
            switch code {
            case 14: DispatchQueue.main.async { NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"), configuration: NSWorkspace.OpenConfiguration()) }   // E: Finder
            case 37: Self.post(Target(code: 12, flags: [.maskControl, .maskCommand]))   // L: lock
            case 15: Self.post(Target(code: 49, flags: .maskCommand))                   // R: Spotlight
            case 2: Self.post(Target(code: 103, flags: []))                             // D: the desktop
            case 48: Self.post(Target(code: 126, flags: .maskControl))                  // Tab: Mission Control
            case 34: DispatchQueue.main.async { NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/System Settings.app"), configuration: NSWorkspace.OpenConfiguration()) }   // I: Settings
            case 125: Self.post(Target(code: 46, flags: .maskCommand))                  // Down: minimise
            case 47: Self.post(Target(code: 49, flags: [.maskControl, .maskCommand]))   // Period: emoji
            case 1 where shift: Self.post(Target(code: 21, flags: [.maskCommand, .maskShift]))   // Shift S: screenshot
            case 1: Self.post(Target(code: 49, flags: .maskCommand))                    // S: search
            case 11: Self.post(Target(code: 100, flags: .maskControl))                  // B: the status menus
            case 0: Self.post(Target(code: 31, flags: Self.vo.union(.maskShift)))        // A: Control Centre
            case 45: Self.post(Target(code: 31, flags: Self.vo))                         // N: Notification Centre
            case 46: Self.post(Target(code: 46, flags: [.maskCommand, .maskAlternate]))  // M: minimise all
            default: done = false
            }
            if done { swallowedUps.insert(code); return nil }
        }
        // Control Shift Escape (Task Manager) and Control Command Backspace (Control Alt Delete): Force Quit.
        if code == 53, control, shift, plain { swallowedUps.insert(code); Self.post(Target(code: 53, flags: [.maskCommand, .maskAlternate])); return nil }
        if code == 51, control, flags.contains(.maskCommand), !flags.contains(.maskAlternate) { swallowedUps.insert(code); Self.post(Target(code: 53, flags: [.maskCommand, .maskAlternate])); return nil }
        // F10 the menu bar; Shift F10 the shortcut menu; Control Escape the Dock.
        if code == 109, plain, !shift, !control { swallowedUps.insert(code); Self.post(Target(code: 120, flags: .maskControl)); return nil }
        if code == 109, shift, !control, plain { swallowedUps.insert(code); Self.post(Target(code: 46, flags: Self.vo.union(.maskShift))); return nil }
        if code == 53, control, !shift, plain { swallowedUps.insert(code); Self.post(Target(code: 99, flags: .maskControl)); return nil }
        let cmdOnly = flags.contains(.maskCommand) && !shift && !control && !flags.contains(.maskAlternate)
        let ctrlOnly = control && !shift && !flags.contains(.maskCommand) && !flags.contains(.maskAlternate)
        let front = WindowsRemap.front
        // Browsers: F5 and Control R reload; Control L, Alt D and F6 the address bar; Control H history; Control J
        // downloads; Control plus, minus and zero the zoom.
        if WindowsRemap.browsers.contains(front) {
            var t: Target?
            switch code {
            case 96 where plain && !shift && !control, 15 where ctrlOnly: t = Target(code: 15, flags: .maskCommand)
            case 37 where ctrlOnly, 2 where cmdOnly, 97 where plain && !shift && !control: t = Target(code: 37, flags: .maskCommand)
            case 4 where ctrlOnly: t = Target(code: 16, flags: .maskCommand)
            case 38 where ctrlOnly: t = Target(code: 37, flags: [.maskCommand, .maskAlternate])
            case 24 where ctrlOnly, 27 where ctrlOnly, 29 where ctrlOnly: t = Target(code: code, flags: .maskCommand)
            default: break
            }
            if let t { swallowedUps.insert(code); Self.post(t); return nil }
        }
        // Finder: Enter opens, F2 renames, Backspace and Alt Up go up, Alt Left and Right back and forward, Delete to
        // the Bin, Alt Enter Get Info.
        if front == "com.apple.finder" {
            var t: Target?
            switch code {
            case 36 where plain && !shift && !control: t = Target(code: 125, flags: .maskCommand)
            case 120 where plain && !shift && !control: t = Target(code: 36, flags: [])
            case 51 where plain && !shift && !control, 126 where cmdOnly: t = Target(code: 126, flags: .maskCommand)
            case 123 where cmdOnly: t = Target(code: 33, flags: .maskCommand)
            case 124 where cmdOnly: t = Target(code: 30, flags: .maskCommand)
            case 117 where plain && !shift && !control: t = Target(code: 51, flags: .maskCommand)
            case 36 where cmdOnly: t = Target(code: 34, flags: .maskCommand)
            default: break
            }
            if let t { swallowedUps.insert(code); Self.post(t); return nil }
        }
        WindowsRemap.apply(type, event)
        return Unmanaged.passUnretained(event)
    }

    /// Words said through VoiceOver, the reader here: its own `output` command, as a bare Apple event.
    static func say(_ text: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.VoiceOver")
            let event = NSAppleEventDescriptor(eventClass: 0x564F4153 /* VOAS */, eventID: 0x6F757470 /* outp */, targetDescriptor: target,
                                               returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            event.setParam(NSAppleEventDescriptor(string: text), forKeyword: AEKeyword(keyDirectObject))
            _ = try? event.sendEvent(options: [.noReply, .neverInteract, .dontRecord], timeout: 1)
        }
    }

    private static let posting = DispatchQueue(label: "turnover.windowskeys.post")
    /// Posted as a hand presses it: each modifier down as its own event, the key, then the modifiers up. VoiceOver
    /// follows the modifier keys themselves; a key carrying the flags alone was not a chord to it (Windy, 17 Oct 2026).
    static func post(_ t: Target) {
        posting.async {
            let src = CGEventSource(stateID: .hidSystemState)
            let fKeys: Set<Int64> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
            let mods: [(CGEventFlags, Int64)] = [(.maskControl, 59), (.maskAlternate, 58), (.maskShift, 56), (.maskCommand, 55)]
            let held = mods.filter { t.flags.contains($0.0) }
            var flags: CGEventFlags = [.maskNonCoalesced]
            func send(_ code: Int64, _ down: Bool, _ f: CGEventFlags) {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: down) else { return }
                e.flags = f
                e.setIntegerValueField(.eventSourceUserData, value: KeyboardHandler.marker)
                e.post(tap: .cghidEventTap)
            }
            for (flag, code) in held { flags.insert(flag); send(code, true, flags); usleep(8_000) }
            var keyFlags = flags
            if fKeys.contains(t.code) { keyFlags.insert(.maskSecondaryFn) }
            if [123, 124, 125, 126, 115, 119, 116, 121].contains(t.code) { keyFlags.insert([.maskSecondaryFn, .maskNumericPad]) }
            for _ in 0..<max(1, t.times) {
                send(t.code, true, keyFlags); usleep(8_000); send(t.code, false, keyFlags); usleep(30_000)
            }
            for (flag, code) in held.reversed() { flags.remove(flag); send(code, false, flags); usleep(8_000) }
        }
    }
}
