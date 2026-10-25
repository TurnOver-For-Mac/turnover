// SPDX-License-Identifier: GPL-3.0-or-later
// The TurnOver menu from anywhere (a tester, 6 Oct 2026): in an app VoiceOver leads, TurnOver N is VoiceOver's
// (VO-N, notifications), and TurnOver's own keys are not listening, so the menu could not be reached at all, and the
// menu bar item "TurnOver menu" did nothing. Command Control N (a system-wide shortcut, like Command Control T) and
// that menu bar item now open it anywhere: where VoiceOver leads, TurnOver steps in for the menu and hands back to
// VoiceOver when it closes.
import AppKit
import Carbon.HIToolbox
import TurnOverCore

final class MenuAnywhere {
    static let shared = MenuAnywhere()
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    /// Steps the lead over and back (set by TurnOverApp: its LeadWatcher).
    var handOver: ((Bool) -> Void)?
    var shouldLead: ((String) -> Bool)?
    /// Gives the app in front to the other reader, for good (set by TurnOverApp: its LeadWatcher).
    var switchLead: ((Bool?) -> Void)?
    /// Command Control Comma, D: the app in front direct or not (the lead watcher's toggleDirect).
    var toggleDirect: (() -> Void)?
    /// Command Control Comma, A: the three reading modes in turn (LeadWatcher.cycleMode).
    var cycleLeadMode: (() -> Void)?

    func register() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            DispatchQueue.main.async {
                if hk.id == 10 { MenuAnywhere.shared.layer() }
                else if hk.id == 11 { MenuAnywhere.shared.switchDirect() }
                else if hk.id >= 60 { MenuAnywhere.shared.voiceOverListKey(Int(hk.id) - 60) }
                else if hk.id >= 20 { MenuAnywhere.shared.claimedLetter(Int(hk.id) - 20) }
            }
            return noErr
        }, 1, &type, nil, &handler)
        // TurnOver's own keys are one layer (12 Oct 2026): Command Control Comma, then a letter. Command Control
        // with a letter is taken in Apple's own apps (N in Finder, Safari, Terminal, Preview, Xcode; T, R, C, H, I, J, K,
        // M likewise, read from their menus), and "we shouldn't be stepping on toes of other apps". One key is taken.
        let id = EventHotKeyID(signature: OSType(0x544F4D4E), id: 10)
        let r = RegisterEventHotKey(UInt32(kVK_ANSI_Comma), UInt32(cmdKey | controlKey), id, GetApplicationEventTarget(), 0, &ref)
        Log.info("TurnOver layer key Command Control Comma \(r == noErr ? "registered" : "not registered (\(r))")")
        // The way back to VoiceOver, and to TurnOver again, as a key of its own (19 Oct 2026: with TurnOver
        // everywhere, "you can drop back to voiceover at any time… a straight shortcut rather than through the
        // layer"). Command Control Shift T: the layer's T with Shift; Command Control T is Finder's Add to Sidebar.
        let switchID = EventHotKeyID(signature: OSType(0x544F4D4E), id: 11)
        let r2 = RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(cmdKey | controlKey | shiftKey), switchID, GetApplicationEventTarget(), 0, &switchRef)
        Log.info("switch reader key Command Control Shift T \(r2 == noErr ? "registered" : "not registered (\(r2))")")
    }
    private var switchRef: EventHotKeyRef?

    /// Command Control Shift T: the app in front to the other reader, remembered, as the layer's T does.
    func switchDirect() {
        let voiceOverReading = !Core.active
        Log.info("switch reader key: \(voiceOverReading ? "VoiceOver was reading: to TurnOver" : "TurnOver was reading: to VoiceOver")")
        switchLead?(voiceOverReading)
    }
    /// The layer's letters: what each does, and whether it opens something that hands back when it closes (a list).
    enum Kind { case run, list }
    /// The layer's letters. Plugin commands (P), write a plugin (W) and the mode (E) left the layer (18 Oct 2026:
    /// "don't matter any more"); the plugin maker is still in the menu.
    static var letters: [String: (spoken: String, kind: Kind, action: @MainActor () -> Void)] {
        var l: [String: (spoken: String, kind: Kind, action: @MainActor () -> Void)] = [
        // M for the menu (14 Oct 2026: clearer than NVDA's N, and the layer is TurnOver's own); N still opens
        // it, unlisted, for hands used to it. The plugin maker moved from M to W ("write a plugin").
        "m": (String(localized: "menu", comment: "A letter's command in the TurnOver layer (Command Control Comma)"), .list, { TurnOverMenu.shared.open() }),
        "n": (String(localized: "menu", comment: "A letter's command in the TurnOver layer (Command Control Comma)"), .list, { TurnOverMenu.shared.open() }),
        "s": (String(localized: "settings window", comment: "A letter's command in the TurnOver layer (Command Control Comma)"), .run, { SettingsBridge.open() }),   // the window (18 Oct 2026); M, Settings is the spoken menu
        "/": (String(localized: "shortcuts here", comment: "A letter's command in the TurnOver layer (Command Control Comma)"), .list, { GlobalCommands.openShortcutsList() }),
        "r": (String(localized: "screen recognition", comment: "A letter's command in the TurnOver layer (Command Control Comma)"), .list, { MenuAnywhere.shared.recognize() }),
        "t": (String(localized: "switch reader", comment: "A letter's command in the TurnOver layer (Command Control Comma)"), .run, { MenuAnywhere.shared.switchLead?(MenuAnywhere.shared.voiceOverWasReading) }),
        "d": (String(localized: "direct: this app's keys straight to it, TurnOver quiet", comment: "A letter's command in the TurnOver layer (Command Control Comma)"), .run, { MenuAnywhere.shared.toggleDirect?() }),
        "a": (String(localized: "all apps: TurnOver in its apps, everywhere, or VoiceOver everywhere", comment: "A letter's command in the TurnOver layer (Command Control Comma)"), .run, { MenuAnywhere.shared.cycleLeadMode?() }),
        "k": (String(localized: "keyboard style: VoiceOver, NVDA or JAWS keys", comment: "A letter's command in the TurnOver layer (Command Control Comma)"), .run, { MenuAnywhere.runScript("toggleKeyboardStyle") }),
        "j": (String(localized: "that was wrong", comment: "A letter's command in the TurnOver layer (Command Control Comma)"), .run, { MenuAnywhere.runScript("markProblem") }),
        "h": (String(localized: "guide", comment: "A letter's command in the TurnOver layer (Command Control Comma)"), .run, { TurnOverGuide.open() }),
        "i": (String(localized: "describe image", comment: "A letter's command in the TurnOver layer (Command Control Comma)"), .run, { MenuAnywhere.runScript("describeImage") }),
        "c": (String(localized: "copy last spoken", comment: "A letter's command in the TurnOver layer (Command Control Comma)"), .run, { MenuAnywhere.runScript("copyLastSpoken") }),
        // G: gesture control (the trackpad) on and off (14 Oct 2026: in the layer as well as by a gesture and the menu).
        "g": (String(localized: "gesture control", comment: "A letter's command in the TurnOver layer (Command Control Comma)"), .run, { Trackpad.toggle() }),
        // V: copy VoiceOver's settings (15 Oct 2026: every TurnOver command through the layer, no direct keys;
        // direct keys clash with apps and will go).
        "v": (String(localized: "copy VoiceOver settings", comment: "A letter's command in the TurnOver layer (Command Control Comma)"), .run, { VoiceOverSettings.startFlow() }),
        ]
        // The screen interface (a window's controls from its pixels) is a feature for a whole build, so the layer
        // offers it only in developer builds (Oliver, 29 Oct 2026: "that's not a bug fix, it's a feature").
        if Edition.isDevBuild { l["e"] = (String(localized: "screen interface: the window's controls from its pixels (experimental)", comment: "A letter's command in the TurnOver layer (Command Control Comma)"), .list, { MenuAnywhere.shared.recognizeInterface() }) }
        return l
    }
    /// The letters in the list's order, as said when the layer is pressed twice.
    static var letterList: String {
        let names = ["m": String(localized: "M menu", comment: "A letter's command, as the TurnOver layer lists them"), "s": String(localized: "S settings", comment: "A letter's command, as the TurnOver layer lists them"), "t": String(localized: "T switch reader", comment: "A letter's command, as the TurnOver layer lists them"), "a": String(localized: "A ask for this app", comment: "A letter's command, as the TurnOver layer lists them"), "v": String(localized: "V copy VoiceOver settings", comment: "A letter's command, as the TurnOver layer lists them"), "k": String(localized: "K keyboard style", comment: "A letter's command, as the TurnOver layer lists them"), "j": String(localized: "J that was wrong", comment: "A letter's command, as the TurnOver layer lists them"),
                     "h": String(localized: "H guide", comment: "A letter's command, as the TurnOver layer lists them"), "i": String(localized: "I describe image", comment: "A letter's command, as the TurnOver layer lists them"), "c": String(localized: "C copy last spoken", comment: "A letter's command, as the TurnOver layer lists them"), "g": String(localized: "G gesture control", comment: "A letter's command, as the TurnOver layer lists them"), "r": String(localized: "R recognition", comment: "A letter's command, as the TurnOver layer lists them"), "e": String(localized: "E screen interface", comment: "A letter's command, as the TurnOver layer lists them"), "d": String(localized: "D direct", comment: "A letter's command, as the TurnOver layer lists them"), "/": String(localized: "Slash shortcuts", comment: "A letter's command, as the TurnOver layer lists them")]
        return String(localized: "\(listOrder.filter { letters[$0] != nil }.compactMap { names[$0] }.joined(separator: ", ")). Or Down Arrow for a list", comment: "The TurnOver layer's letters, then the list")
    }

    /// Said by whichever reader is talking: where VoiceOver leads, as an accessibility announcement VoiceOver reads
    /// (15 Oct 2026: the layer must work with VoiceOver in front, and VoiceOver should read it).
    static func say(_ text: String, tone: Bool = false) { VoiceOverSpeak.say(text, tone: tone) }

    /// The layer's commands as a list to arrow through, Return running one (15 Oct 2026: never read out in one
    /// go; Up and Down through them, hearing each, and Return on it).
    static let listOrder = ["m", "s", "t", "d", "a", "v", "k", "j", "h", "i", "c", "g", "r", "e", "/"]
    func openLayerList() {
        let items = Self.listOrder.compactMap { k -> MenuItem? in
            guard let l = Self.letters[k] else { return nil }
            return MenuItem(verbatim: "\(k == "/" ? KeyNames.slashName : k.uppercased()), \(l.spoken)", .action { DispatchQueue.main.async { l.action() } })
        }
        if steppedIn { TurnOverMenu.shared.onClose = { [weak self] in self?.handBack() } }
        TurnOverMenu.shared.openList("TurnOver commands", items: items)
    }

    static func runScript(_ name: String) {
        guard let s = GlobalCommands.shared.script(named: name) else { Log.warning("layer: no script \(name)"); Speech.speakMessage(String(localized: "not available", comment: "Spoken message")); return }
        ScriptHandler.queueScript(s, gesture: KeyboardGesture(keyCode: 0, modifiers: [], characters: "", timestamp: 0, isRepeat: false, flags: []))
    }

    private var layerTimeout: DispatchWorkItem?
    private(set) var steppedIn = false
    /// Who reads at this moment, as the layer key found it: VoiceOver, unless TurnOver was already leading (switch
    /// reader goes the other way; every path asks this, the code review, 13 Oct 2026).
    var turnOverActive: () -> Bool = { false }
    var voiceOverWasReading: Bool { steppedIn || (Coexist.on ? !turnOverActive() : NSWorkspace.shared.isVoiceOverEnabled) }

    /// Command Control Comma: "TurnOver", then a letter. Where VoiceOver leads, TurnOver steps in for it, and hands back
    /// when the job is done (12 Oct 2026).
    func layer() {
        Log.io("input layer key Command Control Comma")
        // Coexisting (VoiceOver silenced by the tap where TurnOver reads): the layer as everywhere else, "TurnOver" then a
        // letter (18 Oct 2026: "it's going straight to the menu"); where VoiceOver leads, the letters are claimed
        // for 3 s.
        if Coexist.on {
            if turnOverActive() { steppedIn = false; listen(); return }
            Log.info("layer key where VoiceOver leads: the letters claimed for 3 s")
            Self.say("TurnOver", tone: true)
            claimLetters()
            return
        }
        if Core.active { steppedIn = false; listen(); return }
        // Where VoiceOver leads, TurnOver's keys aren't listening yet, and stepping in takes a moment: a letter pressed
        // at once went to the app (Calculator, 12 Oct 2026). So the layer's letters are claimed for three seconds
        // straight away, as hot keys of their own; the chosen one steps in, runs and hands back.
        Log.info("layer key where VoiceOver leads: the letters claimed for 3 s")
        Self.say("TurnOver", tone: true)   // VoiceOver says it; the letters are listed only if nothing comes
        claimLetters()
    }

    /// The keys claimed while VoiceOver leads: the layer's letters, and Escape.
    private static let claimable: [(code: Int, key: String)] = [
        (kVK_ANSI_N, "n"), (kVK_ANSI_S, "s"), (kVK_ANSI_Slash, "/"), (kVK_ANSI_M, "m"), (kVK_ANSI_A, "a"), (kVK_ANSI_R, "r"), (kVK_ANSI_T, "t"), (kVK_ANSI_D, "d"),
        (kVK_ANSI_K, "k"), (kVK_ANSI_J, "j"), (kVK_ANSI_H, "h"), (kVK_ANSI_I, "i"), (kVK_ANSI_C, "c"), (kVK_ANSI_V, "v"),
        (kVK_ANSI_G, "g"), (kVK_DownArrow, "list"), (kVK_UpArrow, "list"), (kVK_Escape, "escape"),
    ]
    private var claimed: [EventHotKeyRef?] = []
    private var claimTimeout: DispatchWorkItem?

    private func claimLetters() {
        releaseLetters()
        // At the head of the HID level, ahead of VoiceOver: with VoiceOver's Quick Nav on, the hot keys below lost the
        // letters to it, and T went to VoiceOver as "next table" (18 Oct 2026: "the keys were passing through
        // to voiceover"). The hot keys stay as the fallback where the tap can't be made.
        startClaimTap()
        for (i, k) in Self.claimable.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x544F4D4E), id: UInt32(20 + i))
            if RegisterEventHotKey(UInt32(k.code), 0, id, GetApplicationEventTarget(), 0, &ref) == noErr { claimed.append(ref) }
        }
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.claimed.isEmpty else { return }
            self.releaseLetters()
            Log.io("layer: no letter in time (VoiceOver leads)")
            Self.say("cancelled")
        }
        claimTimeout = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
    }

    private func releaseLetters() {
        claimTimeout?.cancel()
        for r in claimed { if let r { UnregisterEventHotKey(r) } }
        claimed.removeAll()
        stopClaimTap()
    }

    // MARK: The claim's own tap

    private var claimTap: CFMachPort?
    private var claimSource: CFRunLoopSource?
    /// The claimed key whose key up is swallowed too (VoiceOver would otherwise see a lone key up).
    fileprivate var swallowUp: Int64?

    private func startClaimTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                          callback: { _, type, event, _ in
            // On the main run loop: the layer decides there; the event itself never leaves this thread.
            let code = event.getIntegerValueField(.keyboardEventKeycode), flags = event.flags
            let swallow = MainActor.assumeIsolated { MenuAnywhere.shared.claimTapTakes(type: type, code: code, flags: flags) }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }, userInfo: nil) else { Log.io("layer: the claim's tap couldn't be made; hot keys only"); return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        claimTap = tap; claimSource = source
    }

    private func stopClaimTap() {
        if let tap = claimTap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source = claimSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        claimTap = nil; claimSource = nil
    }

    /// The claim's tap: true takes the key (a claimable key with no modifier but Shift, and its key up) for the layer,
    /// away from VoiceOver and the app; anything else passes.
    fileprivate func claimTapTakes(type: CGEventType, code: Int64, flags: CGEventFlags) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { if let tap = claimTap { CGEvent.tapEnable(tap: tap, enable: true) }; return false }
        if type == .keyUp, swallowUp == code { swallowUp = nil; return true }
        guard type == .keyDown, flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty,
              let i = Self.claimable.firstIndex(where: { Int64($0.code) == code }) else { return false }
        swallowUp = code
        DispatchQueue.main.async { self.claimedLetter(i) }
        return true
    }

    func claimedLetter(_ i: Int) {
        releaseLetters()
        guard Self.claimable.indices.contains(i) else { return }
        let key = Self.claimable[i].key
        // Up or Down: the commands as a list VoiceOver reads, item by item (15 Oct 2026: VoiceOver stays on
        // and reads the layer; TurnOver steps in only for what's chosen).
        if key == "list" { voiceOverList(); return }
        guard key != "escape", let l = Self.letters[key] else { Log.io("layer: cancelled (VoiceOver leads)"); Self.say("cancelled"); return }
        runClaimed(key, l)
    }

    /// A letter chosen while VoiceOver leads: switch reader and the modes run as they are; the rest step TurnOver
    /// in, run, and hand back.
    private func runClaimed(_ key: String, _ l: (spoken: String, kind: Kind, action: @MainActor () -> Void)) {
        // Switch reader where VoiceOver is reading: TurnOver takes this app, no stepping in and handing back (that
        // read the list, not who was talking, and gave the app to VoiceOver;).
        if key == "t" { Log.io("layer: t → switch reader (VoiceOver was reading: to TurnOver)"); switchLead?(true); return }
        if key == "a" { Log.io("layer: a → the next reading mode"); cycleLeadMode?(); return }
        // The keyboard style changes without stepping in: stepping in read the window first and buried the style's
        // name under it ("wasn't properly reading the switching", Oliver, 28 Oct 2026). VoiceOver says the new style.
        if key == "k" {
            Log.io("layer: k → keyboard style (VoiceOver leads: no stepping in)")
            GlobalCommands.toggleKeyboardStyle(quietly: true)
            Self.say(config.general.style.spokenName)
            return
        }
        Log.io("layer: \(key) → \(l.spoken) (VoiceOver leads: stepping in)")
        steppedIn = true
        handOver?(false)
        let start = Date()
        func wait() {
            if Core.active {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if l.kind == .list {
                        TurnOverMenu.shared.onClose = { self.handBack() }   // the shared layer: lives as long as TurnOver
                        ScreenRecognition.shared.onClose = { self.handBack() }
                    }
                    l.action()
                    if l.kind == .run { self.handBack(after: 3) }
                }
                return
            }
            guard Date().timeIntervalSince(start) < 5 else { Log.warning("layer key: VoiceOver did not hand over"); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { wait() }
        }
        wait()
    }

    // MARK: The list VoiceOver reads (VoiceOver leads)

    private var voList: [String] = []
    private var voIndex = 0
    private var voKeys: [EventHotKeyRef?] = []
    private var voTimeout: DispatchWorkItem?

    /// The commands as a list read by VoiceOver: Up and Down move, Return runs, Escape cancels; the keys are claimed
    /// as hot keys for the list's life (20 s from the last key).
    private func voiceOverList() {
        voList = Self.listOrder.filter { Self.letters[$0] != nil }
        voIndex = 0
        releaseVOList()
        for (i, code) in [kVK_UpArrow, kVK_DownArrow, kVK_Return, kVK_Escape].enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x544F4D4E), id: UInt32(60 + i))
            if RegisterEventHotKey(UInt32(code), 0, id, GetApplicationEventTarget(), 0, &ref) == noErr { voKeys.append(ref) }
        }
        Log.io("layer: the commands as a list VoiceOver reads")
        Self.say(String(localized: "TurnOver commands, \(String(voList.count)).", comment: "The TurnOver layer as a list: how many") + " " + voItemText())
        voTouch()
    }

    private func voItemText() -> String {
        guard voList.indices.contains(voIndex), let l = Self.letters[voList[voIndex]] else { return "" }
        let k = voList[voIndex]
        return "\(k == "/" ? KeyNames.slashName : k.uppercased()), \(l.spoken), \(Phrases.position(voIndex + 1, of: voList.count))"
    }

    private func voTouch() {
        voTimeout?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.voKeys.isEmpty else { return }
            self.releaseVOList(); Log.io("layer: the list timed out (VoiceOver leads)"); Self.say("cancelled")
        }
        voTimeout = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: w)
    }

    private func releaseVOList() {
        voTimeout?.cancel()
        for r in voKeys { if let r { UnregisterEventHotKey(r) } }
        voKeys.removeAll()
    }

    func voiceOverListKey(_ i: Int) {
        guard !voKeys.isEmpty else { return }
        switch i {
        case 0: voIndex = max(0, voIndex - 1); Self.say(voItemText()); voTouch()
        case 1: voIndex = min(voList.count - 1, voIndex + 1); Self.say(voItemText()); voTouch()
        case 2:
            releaseVOList()
            guard voList.indices.contains(voIndex), let l = Self.letters[voList[voIndex]] else { return }
            runClaimed(voList[voIndex], l)
        default: releaseVOList(); Self.say("cancelled")
        }
    }

    private func listen(again: Bool = false) {
        Speech.cancel()
        Speech.speakMessage(again ? "TurnOver: " + Self.letterList : "TurnOver")
        InputManager.captureNext = { [weak self] g in self?.letter(g) }
        layerTimeout?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, InputManager.captureNext != nil else { return }
            InputManager.captureNext = nil
            Log.io("layer: no letter in time")
            Speech.speakMessage(String(localized: "cancelled", comment: "Spoken message"))
            if self.steppedIn { self.handBack() }
        }
        layerTimeout = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (again ? 8 : 3), execute: w)
    }

    private func letter(_ g: KeyboardGesture?) {
        layerTimeout?.cancel()
        guard let g else { Speech.speakMessage(String(localized: "cancelled", comment: "Spoken message")); if steppedIn { handBack() }; return }   // Escape
        let key = g.keyName.lowercased()
        // The arrows open the commands as a list to arrow through, Return running one (Down Arrow pressed
        // after the layer key twice, 12 Oct 2026, gave only the letters).
        if ["upArrow", "downArrow"].contains(g.keyName) {
            Log.io("layer: the commands as a list")
            openLayerList()
            return
        }
        guard let l = Self.letters[key], g.modifiers.subtracting(.shift).isEmpty else {
            Log.io("layer: \(g.identifier) is not a layer letter; the list instead")
            openLayerList()
            return
        }
        Log.io("layer: \(key) → \(l.spoken)")
        if key == "t", !steppedIn, Core.active { switchLead?(false); return }   // TurnOver was reading: to VoiceOver
        if key == "a", !steppedIn { cycleLeadMode?(); return }
        if steppedIn, l.kind == .list {
            TurnOverMenu.shared.onClose = { [weak self] in self?.handBack() }
            ScreenRecognition.shared.onClose = { [weak self] in self?.handBack() }
        }
        l.action()
        if steppedIn, l.kind == .run { handBack() }
    }

    /// Screen recognition from anywhere: where VoiceOver leads, TurnOver steps in for the result (its keys are
    /// TurnOver's) and hands back when it closes.
    func recognize() { recognize(interface: false) }
    func recognizeInterface() { recognize(interface: true) }
    private func recognize(interface: Bool) {
        let run = { interface ? ScreenRecognition.shared.recognizeInterface() : ScreenRecognition.shared.recognize() }
        if ScreenRecognition.shared.isOpen { run(); return }
        if Core.active { run(); return }
        Log.info("screen recognition asked for where VoiceOver leads: stepping in for it")
        handOver?(false)
        let start = Date()
        func waitForTurnOver() {
            if Core.active {
                ScreenRecognition.shared.onClose = { [weak self] in self?.handBack() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { run() }
                return
            }
            guard Date().timeIntervalSince(start) < 5 else { Log.warning("screen recognition: VoiceOver did not hand over"); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { waitForTurnOver() }
        }
        waitForTurnOver()
    }

    func open() {
        guard !TurnOverMenu.shared.isOpen else { return }
        if Core.active { TurnOverMenu.shared.open(); return }
        // VoiceOver leads here: TurnOver steps in for the menu.
        Log.info("TurnOver menu asked for where VoiceOver leads: stepping in for it")
        handOver?(false)
        let start = Date()
        func waitForTurnOver() {
            if Core.active {
                TurnOverMenu.shared.onClose = { [weak self] in self?.handBack() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { TurnOverMenu.shared.open() }
                return
            }
            guard Date().timeIntervalSince(start) < 5 else { Log.warning("TurnOver menu: VoiceOver did not hand over"); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { waitForTurnOver() }
        }
        waitForTurnOver()
    }

    /// The menu closed: back to VoiceOver, unless TurnOver leads in the app now in front (the menu may have changed
    /// that, or switched app). A moment's wait lets the chosen item speak first.
    private func handBack(after delay: Double = 1.5) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            // Another list opened from the menu (the shortcuts, a chooser): hand back when that one closes instead
            // (the hook was spent on the first close and TurnOver stayed in; a code review on 17 Oct 2026).
            if TurnOverMenu.shared.isOpen || ScreenRecognition.shared.isOpen { TurnOverMenu.shared.onClose = { [weak self] in self?.handBack() }; return }
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            if !(self.shouldLead?(front) ?? false) { self.handOver?(true) }
            self.steppedIn = false
        }
    }
}
