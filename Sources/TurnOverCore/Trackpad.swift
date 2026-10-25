// SPDX-License-Identifier: GPL-3.0-or-later
// Gesture control: the trackpad (the roadmap core 1; named "gesture control" for people so the layer's G fits, 14 Oct; a tester, asked for again since). Where TurnOver leads, VoiceOver is off,
// and its Trackpad Commander goes with it. The fingers are read by Trackpad gestures' open program (helpers/
// trackpad-gestures in the plugins repository: Apple's private multitouch reading, kept out of TurnOver so a macOS
// change can't harm the reader); TurnOver turns its gestures into the same commands as the keys, so every app and
// both keyboard styles behave as they do from the keyboard.
//
// On and off as VoiceOver's: hold the TurnOver key and turn two fingers clockwise (on) or anticlockwise (off); in
// the Windows style also NVDA's NVDA+Control+Alt+T; the TurnOver layer's G; and the TurnOver menu. While on, the trackpad drives TurnOver only:
// pointer moves, clicks, scrolling and the Mac's trackpad gestures are held back (an event tap), and the pointer
// stays put. Measured 14 Oct 2026: 3,001 moves, 92 scrolls and every swipe held back; no desktop switched.
//
// The Windows style follows NVDA's touch gestures instead (its Commands Quick Reference, 2026.2): a three-finger tap
// switches object and text mode; object mode flicks right/left next/previous, up to the container, down into it;
// text mode flicks up/down by line, left/right by character, two-finger left/right by word, three-finger down reads
// all; double tap activates, two-finger tap stops speech, two-finger double tap opens the menu; on and off with
// NVDA+Control+Alt+T. Not yet: tap and hold (right click), two-finger flick up/down (review modes).
//
// The Mac style's gestures (VoiceOver's Trackpad Commander):
//   flick right / left            next / previous item
//   double tap                    activate (the item explored to, else the item)
//   one finger resting, moving    explore: what is under it, the trackpad standing for the window
//   two-finger turn               the rotor: characters, words, lines, headings, links, form controls, tables
//   flick down / up               next / previous by the rotor
//   two-finger flick down / up    read all / read the window
//   two-finger tap                stop speaking
//   two-finger scrub              Escape
//   three-finger flick down / up  page down / up
// Haptics (rhythm, since the waveforms feel alike): a tick per rotor step and per item crossed while exploring, a
// double tap for a heading, three at an edge.
import Foundation
import AppKit
import ApplicationServices

public enum Trackpad {
    static var ownSetup: Bool { UserDefaults.standard.bool(forKey: "trackpad") }
    public private(set) static var byPlugin = false
    /// The helper is in the bundle (Contents/Helpers) in the product: available without a default or a plugin.
    public static var available: Bool { ownSetup || byPlugin || bundled }
    static var bundled: Bool { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/trackpad-gestures").path.withCString { access($0, X_OK) == 0 } }
    public private(set) static var controlOn = false
    private static var helper: HelperProgram?

    // MARK: Switched on by the plugin

    public static func provides(_ plugins: [LoadedPlugin]) -> Bool {
        plugins.contains { p in
            guard p.manifest?.provides == "trackpad", let r = PluginLibrary.receipt(p.folder) else { return false }
            return r.level == "Official" && r.id == p.manifest?.id
        }
    }

    public static func pluginsChanged(_ plugins: [LoadedPlugin]) {
        let on = provides(plugins)
        guard on != byPlugin else { return }
        byPlugin = on
        Log.info("trackpad: \(on ? "available" : "removed") by the Trackpad gestures plugin")
        if on { startIfWanted() } else if !ownSetup { stop() }
    }

    public static func startIfWanted() {
        guard available, helper == nil else { return }
        let h = HelperProgram(name: "trackpad-gestures") { line in received(line) }
        h.onGiveUp = { setControl(false, announce: true) }
        helper = h
        h.start()
    }

    static func stop() {
        setControl(false, announce: false)
        helper?.stop(); helper = nil
    }

    // MARK: On and off

    public static func toggle() { setControl(!controlOn, announce: true) }
    public static func set(_ on: Bool) { setControl(on, announce: true) }

    static func setControl(_ on: Bool, announce: Bool) {
        // Said as VoiceOver says it (17 Oct 2026: "trackpad commands on, trackpad commands off, as it does in VoiceOver").
        // Coexisting, VoiceOver sees the same gesture and says it where it reads; TurnOver says it where it reads.
        let say = announce && (!Coexist.on || Core.active)
        guard on != controlOn else { if say { Speech.speakMessage(String(localized: "trackpad commands \(Phrases.onOff(on))", comment: "Gesture control turned on or off")) }; return }
        if on, helper?.isRunning != true { if announce { Speech.speakMessage(String(localized: "the trackpad can't be read now", comment: "Spoken message")) }; return }
        controlOn = on
        PointerHold.set(on)
        Log.info("trackpad: control \(on ? "on" : "off")")
        // VoiceOver's sound for it, then the words (the sound as VoiceOver's own; the file is the one it plays for its
        // keyboard toggles, to confirm by ear, 17 Oct 2026).
        if say { VoiceOverSounds.play(on ? "TrackingOn.aiff" : "TrackingOff.aiff"); Speech.speakMessage("trackpad commands \(on ? "on" : "off")") }   // VoiceOver's, by ear (17 Oct 2026)
    }

    // MARK: Gestures

    /// VoiceOver's rotor on the trackpad: what flick down and up move by.
    nonisolated static let rotor: [(name: String, next: String, previous: String, macOnly: Bool)] = [
        ("characters", "rightArrow", "leftArrow", false),
        ("words", "option+rightArrow", "option+leftArrow", false),
        ("lines", "downArrow", "upArrow", false),
        ("headings", "turnover+command+h", "turnover+command+shift+h", true),
        ("links", "turnover+command+l", "turnover+command+shift+l", true),
        ("form controls", "turnover+command+j", "turnover+command+shift+j", true),
        ("tables", "turnover+command+t", "turnover+command+shift+t", true),
    ]
    private static var rotorIndex = 2   // lines
    /// A rotor kind as spoken (the kinds stay English: they are the table's keys).
    static func rotorName(_ kind: String) -> String {
        switch kind {
        case "characters": return String(localized: "characters", comment: "A trackpad rotor kind")
        case "words": return String(localized: "words", comment: "A trackpad rotor kind")
        case "lines": return String(localized: "lines", comment: "A trackpad rotor kind")
        case "headings": return String(localized: "headings", comment: "A trackpad rotor kind")
        case "links": return String(localized: "links", comment: "A trackpad rotor kind")
        case "form controls": return String(localized: "form controls", comment: "A trackpad rotor kind")
        case "tables": return String(localized: "tables", comment: "A trackpad rotor kind")
        default: return kind
        }
    }

    /// NVDA's touch modes (the Windows style): what one-finger flicks move by.
    nonisolated(unsafe) static var textMode = false

    /// The key a gesture stands for, in this keyboard style (nil: handled here, or nothing). Pure.
    nonisolated public static func key(for gesture: String, windows: Bool, textMode: Bool = false) -> String? {
        if windows {
            switch gesture {
            case "G double-tap 1": return "turnover+enter"
            case "G flick-down 3": return "turnover+a"
            case "G flick-right 1": return textMode ? "rightArrow" : "turnover+shift+rightArrow"
            case "G flick-left 1": return textMode ? "leftArrow" : "turnover+shift+leftArrow"
            case "G flick-up 1": return textMode ? "upArrow" : "turnover+shift+upArrow"
            case "G flick-down 1": return textMode ? "downArrow" : "turnover+shift+downArrow"
            case "G flick-right 2": return textMode ? "option+rightArrow" : nil
            case "G flick-left 2": return textMode ? "option+leftArrow" : nil
            default: return nil
            }
        }
        // VoiceOver's standard trackpad gestures (Apple's guide, vo27992; rebuilt 17 Oct 2026).
        switch gesture {
        case "G flick-right 1": return "turnover+rightArrow"          // next item
        case "G flick-left 1": return "turnover+leftArrow"            // previous item
        case "G flick-right 2": return "turnover+shift+downArrow"     // start interacting
        case "G flick-left 2": return "turnover+shift+upArrow"        // stop interacting
        case "G flick-down 2": return "turnover+a"                    // read from the cursor to the end
        case "G scrub": return "escape"
        case "G flick-down 3": return "pageDown"                      // scroll a page
        case "G flick-up 3": return "pageUp"
        case "G double-tap 1": return "turnover+space"                // select
        case "G triple-tap 1": return "turnover+f3"                   // describe the item
        case "G triple-tap 3": return "turnover+shift+f11"            // screen curtain
        default: return nil
        }
    }

    private static var explored: AXUIElement?

    private static var toggledAt = Date.distantPast
    static func received(_ raw: String) {
        // The helper puts where a double-tap was after it; only the two-finger one is read by place.
        var line = raw
        if raw.hasPrefix("G double-tap "), !raw.hasPrefix("G double-tap 2") { line = raw.split(separator: " ").prefix(3).joined(separator: " ") }
        // The toggle works whether control is on or off: the TurnOver key held and a two-finger turn. One turn is one
        // toggle: the helper reports a step every 30 degrees, and each step toggled again ("flaky", 17 Oct 2026).
        if line.hasPrefix("R "), KeyboardGesture.turnOverHeld?() == true {
            if Date().timeIntervalSince(toggledAt) < 1.5 { return }
            toggledAt = Date()
            setControl(line == "R cw", announce: true); return
        }
        guard controlOn else { return }
        // VoiceOver reading this app: its own Trackpad Commander is there; TurnOver keeps out of it. Coexisting,
        // VoiceOver is always on: TurnOver being active for the app in front is the test.
        if Coexist.on ? !Core.active : NSWorkspace.shared.isVoiceOverEnabled { return }
        // Each gesture in the log (not the exploring finger's moves): the Mail session of 19 Oct 2026 could only be
        // read back from the keys the gestures pressed.
        if !line.hasPrefix("E ") { Log.io("trackpad: \(line)") }
        let windows = config.general.windowsKeys
        if windows {
            switch line {
            case "G tap 3":
                textMode.toggle()
                Speech.cancel(); Speech.speakMessage(textMode ? String(localized: "text mode", comment: "Spoken message") : String(localized: "object mode", comment: "Spoken message"))
            case "G tap 2": Speech.cancel()
            case "G double-tap 2": TurnOverMenu.shared.open()
            case "G double-tap 1" where explored != nil: ObjectNavigator.shared.activate()
            case "E end", "R cw", "R ccw": break
            default:
                if line.hasPrefix("E "), let p = point(line) { explore(p); return }
                if let k = key(for: line, windows: true, textMode: textMode) { press(k) }
                else { Log.io("trackpad: \(line) does nothing in the Windows style") }
            }
            return
        }
        switch line {
        case "R cw", "R ccw":
            let kinds = rotor.indices.filter { windows ? !rotor[$0].macOnly : true }
            guard let at = kinds.firstIndex(of: rotorIndex) ?? kinds.first.map({ _ in 0 }) else { return }
            rotorIndex = kinds[(at + (line == "R cw" ? 1 : kinds.count - 1)) % kinds.count]
            Speech.cancel()
            Speech.speakMessage(rotorName(rotor[rotorIndex].name))
        case "G flick-down 1", "G flick-up 1":
            let r = rotor[rotorIndex]
            press(line == "G flick-down 1" ? r.next : r.previous)
        case "G tap 2":
            Speech.togglePause()                                       // pause or resume speaking
        case "G flick-up 2", "G tap 3":
            ObjectNavigator.shared.readWindow()                        // the page from the top; the current scroll page
        case "G double-tap 3":
            let off = Speech.mode != .off                              // mute or unmute
            if off { Speech.speakMessage(String(localized: "speech off", comment: "Spoken message")); DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Speech.mode = .off } }
            else { Speech.mode = .talk; Speech.speakMessage(String(localized: "speech on", comment: "Spoken message")) }
        case "G double-tap 1" where explored != nil:
            ObjectNavigator.shared.activate()
        case "E end":
            break
        default:
            // A two-finger double-tap by where it was: near the top the menu bar, near the bottom the Dock, on the
            // left the Application Chooser, on the right the Window Chooser (VoiceOver's).
            if line.hasPrefix("G double-tap 2") {
                let parts = line.split(separator: " ")
                let x = parts.count >= 5 ? Double(parts[3]) ?? 0.5 : 0.5, y = parts.count >= 5 ? Double(parts[4]) ?? 0.5 : 0.5
                if y > 0.8 { press("turnover+m") }
                else if y < 0.2 { press("turnover+d") }
                else if x < 0.2 { press("turnover+f1"); press("turnover+f1") }
                else if x > 0.8 { press("turnover+f2"); press("turnover+f2") }
                else { Log.io("trackpad: a two-finger double-tap in the middle does nothing (VoiceOver's are by edge)") }
                return
            }
            if line.hasPrefix("E "), let p = point(line) { explore(p); return }
            if let k = key(for: line, windows: windows) { press(k) }
            else { Log.io("trackpad: \(line) does nothing yet") }
        }
    }

    private static func press(_ key: String) {
        guard let g = KeyboardGesture(identifier: normalizeGestureIdentifier("kb:" + key)) else { return }
        KeyboardGesture.typedPoster?(g)
    }

    /// Where haptics are felt (14 Oct 2026: "a bit much; they have a place, not sure where yet"): off, the
    /// rotor's steps only (the default), or everywhere (items crossed while exploring, headings, edges, on and off).
    public enum HapticLevel: String, CaseIterable, Sendable {
        case off, rotor, everywhere
        public var name: String { self == .off ? State.off.displayString : self == .rotor ? String(localized: "rotor only", comment: "Where haptics are felt") : String(localized: "everywhere", comment: "Where haptics are felt") }
    }
    /// Off for now (17 Oct 2026: "remove the haptic stuff, we don't want it for now"); the code stays.
    public static var hapticLevel: HapticLevel {
        get { .off }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "trackpadHaptics") }
    }

    // MARK: Exploring by touch

    private static func point(_ line: String) -> CGPoint? {
        let parts = line.split(separator: " ")
        guard parts.count == 3, let x = Double(parts[1]), let y = Double(parts[2]) else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// The trackpad stands for the front window: its left edge the window's, its top the window's top.
    private static func explore(_ p: CGPoint) {
        // The fingers that turned control on are still on the pad: their touch is not exploring, and must not cut
        // "trackpad commands on" short (the on was never heard, the off always, 17 Oct 2026).
        if Date().timeIntervalSince(toggledAt) < 1.2 { return }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        guard let w = ax.element(kAXFocusedWindowAttribute) ?? ax.element(kAXMainWindowAttribute),
              let frame = TurnOverObject.frame(w) else { return }
        let screen = CGPoint(x: frame.minX + p.x * frame.width, y: frame.minY + (1 - p.y) * frame.height)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(screen.x), Float(screen.y), &hit) == .success, let hit else {
            if explored != nil { explored = nil; VoiceOverSounds.play("EmptySpace.aiff") }   // a blank area, as VoiceOver marks it
            return
        }
        if let e = explored, CFEqual(e, hit) { return }
        explored = hit
        Speech.cancel()
        ObjectNavigator.shared.moveTo(hit)
    }
}

/// While trackpad control is on: the pointer, clicks, scrolling and the Mac's trackpad gestures held back, and the
/// pointer kept where it is. The keyboard is never touched. Everything returns the moment it's off (or TurnOver
/// quits: the tap and the hold go with the process).
enum PointerHold {
    nonisolated(unsafe) private static var tap: CFMachPort?
    nonisolated(unsafe) private static var source: CFRunLoopSource?

    static func set(_ on: Bool) {
        if on {
            if tap == nil {
                var mask: CGEventMask = 0
                for t: UInt32 in [1, 2, 3, 4, 5, 6, 7, 22, 25, 26, 27, 29, 30, 31] { mask |= CGEventMask(1) << CGEventMask(t) }
                let callback: CGEventTapCallBack = { _, type, event, _ in
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        if let t = PointerHold.tap { CGEvent.tapEnable(tap: t, enable: true) }
                        return Unmanaged.passUnretained(event)
                    }
                    // VoiceOver reading the app in front: its own trackpad, untouched. TurnOver's own clicks (the App
                    // Store opens an app by its icon) go through.
                    if PointerHold.voiceOverOn || event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) { return Unmanaged.passUnretained(event) }
                    return nil
                }
                tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: callback, userInfo: nil)
                guard let tap else { Log.warning("trackpad: the pointer couldn't be held (no event tap)"); return }
                source = CFMachPortCreateRunLoopSource(nil, tap, 0)
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            CGAssociateMouseAndMouseCursorPosition(0)
            watchVoiceOver()
        } else {
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
            CGAssociateMouseAndMouseCursorPosition(1)
            voiceOverTimer?.invalidate(); voiceOverTimer = nil
        }
    }

    nonisolated(unsafe) static var voiceOverOn = false
    private static var voiceOverTimer: Timer?
    private static func watchVoiceOver() {
        voiceOverOn = Coexist.on ? !Core.active : NSWorkspace.shared.isVoiceOverEnabled
        voiceOverTimer?.invalidate()
        voiceOverTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let vo = Coexist.on ? !Core.active : NSWorkspace.shared.isVoiceOverEnabled   // coexisting: VoiceOver's trackpad where TurnOver isn't reading
                if vo != voiceOverOn { voiceOverOn = vo; CGAssociateMouseAndMouseCursorPosition(vo ? 1 : 0) }
            }
        }
    }
}
