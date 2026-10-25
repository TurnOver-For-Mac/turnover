// SPDX-License-Identifier: GPL-3.0-or-later
// Global commands (NVDA: globalCommands.GlobalCommands): the scripts that work
// everywhere, bound to NVDA's keys — laptop layout first, since Macs are
// laptops, with the desktop keys too where they do not collide. The owner's
// additions (battery, help list, hand-over) sit beside them; the app adds the
// Mac-specific ones at launch.
import Foundation
import AppKit
import IOKit.ps

public final class GlobalCommands: ScriptableObject {
    public static let shared = GlobalCommands()

    private override init() {
        super.init()
        let sys = "System"
        let text = "Text review"
        let speechCat = "Speech"

        script("reportCurrentFocus", String(localized: "Reports the object with focus", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+tab"], category: sys) { _ in
            guard let f = API.focusObject else { Speech.speakMessage(String(localized: "no focus", comment: "Nothing has the keyboard focus")); return }
            Speech.speakObject(f, reason: .query)
        }
        script("title", String(localized: "Reports the title of the current window. Pressed twice, spells it", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+t"], category: sys) { _ in
            let front = NSWorkspace.shared.frontmostApplication
            let app = front?.localizedName ?? ""
            // The window's title as it is now, not as the window was when it came to the front: Safari's changes with
            // every tab, and Caps T said "Safari, Untitled" after a tab switch (a tester, 9 Oct 2026).
            let fresh = front.flatMap { AXUIElementCreateApplication($0.processIdentifier).element(kAXFocusedWindowAttribute)?.string(kAXTitleAttribute) }
            let title = (fresh?.isEmpty == false ? fresh : nil) ?? API.foregroundObject?.name ?? ""
            let t = [app, title].filter { !$0.isEmpty }.joined(separator: ", ")
            if ScriptHandler.lastScriptRepeatCount > 0 { Speech.speakSpelling(title.isEmpty ? app : title) } else { Speech.speakMessage(t.isEmpty ? String(localized: "no title", comment: "The window has no title") : t) }
        }
        // (Also TurnOver Shift T, for Macs without an Insert or function keys: a tester, 8 Oct 2026.)
        // Make a plugin by hand, on the item TurnOver is on (PluginMaker; VoiceOver's VO Shift Slash labels an item).
        // VoiceOver commands a Commander letter or a custom binding may name (VoiceOverCommands.swift): no keys of their own.
        script("voiceOverMuteSpeech", String(localized: "Speech off or on (VoiceOver's mute speech toggle)", comment: "A command, as the key list and keyboard help say it"), gestures: [], category: sys) { _ in
            if Speech.mode == .off { Speech.mode = .talk; Speech.speakMessage(String(localized: "speech on", comment: "Speech turned back on")) } else { Speech.speakMessage(String(localized: "speech off", comment: "Speech turned off")); DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Speech.mode = .off } }
        }
        script("voiceOverPauseSpeech", String(localized: "Pause or resume speaking", comment: "A command, as the key list and keyboard help say it"), gestures: [], category: sys) { _ in Speech.togglePause() }
        let ring = [
            ("speechRateUp", String(localized: "Faster (VoiceOver's faster speech rate)", comment: "A command, as the key list and keyboard help say it"), "rate", 1),
            ("speechRateDown", String(localized: "Slower (VoiceOver's slower speech rate)", comment: "A command, as the key list and keyboard help say it"), "rate", -1),
            ("speechVolumeUp", String(localized: "Louder (VoiceOver's louder speech volume)", comment: "A command, as the key list and keyboard help say it"), "volume", 1),
            ("speechVolumeDown", String(localized: "Quieter (VoiceOver's quieter speech volume)", comment: "A command, as the key list and keyboard help say it"), "volume", -1),
            ("speechPitchUp", String(localized: "Higher (VoiceOver's higher speech pitch)", comment: "A command, as the key list and keyboard help say it"), "pitch", 1),
            ("speechPitchDown", String(localized: "Lower (VoiceOver's lower speech pitch)", comment: "A command, as the key list and keyboard help say it"), "pitch", -1),
        ]
        for (name, description, setting, by) in ring {
            script(name, description, gestures: [], category: sys) { _ in SynthRing.change(setting, by: by) }
        }
        script("copyVoiceOverSettings", String(localized: "Copies VoiceOver's voice, rate, pitch, volume, verbosity and typing echo into TurnOver, through VoiceOver Utility's export", comment: "A command, as the key list and keyboard help say it"), gestures: [], category: sys) { _ in   // in the layer: Command Control Comma, then V
            VoiceOverSettings.startFlow()
        }
        // Steam's Big Picture menu open without the keyboard: these keys go into the menu's page (Games.swift).
        for k in Games.menuKeys {
            script("steamMenu_\(k.gesture)", String(localized: "In Steam's Big Picture menu: \(k.key)", comment: "A command, as the key list and keyboard help say it: %@ is the key"), gestures: ["kb:\(k.gesture)"], category: "Games") { _ in Games.forwardMenuKey(k.key, vk: k.vk) }
                .isAvailable = { Games.menuNeedsKeys && Games.active && Games.steamInFront }   // (never in another app: code review, 16 Oct 2026)
        }
        script("makePlugin", String(localized: "Make a plugin for this item; label, give a key to, watch or silence the item TurnOver is on, saved as your own plugin for the app", comment: "A command, as the key list and keyboard help say it"), gestures: [], category: "Plugins") { _ in
            PluginMaker.open()
        }.isAvailable = { Edition.includesPlugins }
        script("dateTime", String(localized: "Reports the time. Pressed twice, reports the date", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+f12"], category: sys) { _ in   // NVDA+F12; TurnOver Shift T (a tester's preference) removed, 12 Oct 2026
            let f = DateFormatter()
            if ScriptHandler.lastScriptRepeatCount > 0 { f.dateStyle = .full; f.timeStyle = .none } else { f.dateStyle = .none; f.timeStyle = .short }
            Speech.speakMessage(f.string(from: Date()))
        }
        script("describeImage", String(localized: "Describes the picture under TurnOver's cursor: what it shows and any text in it", comment: "A command, as the key list and keyboard help say it"), gestures: [], category: sys) { _ in
            ImageDescriber.describeCurrent()
        }
        // Windows style: Enter presses the focused button, as on a PC ("in windows mode enter should do things",
        // Reminders' Add Reminder, 10 Oct 2026). On the Mac, Return is kept for a window's default button.
        script("pressFocusedWithEnter", String(localized: "Windows style: Enter presses the focused button or link", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:enter", "kb:numpadEnter"], category: sys) { g in
            guard let f = API.focusObject else { g.send(); return }
            let r = AXUIElementPerformAction(f.element, kAXPressAction as CFString)
            Log.io("Enter pressed the focused \(f.axRole) → \(r.rawValue)")
            if r != .success { g.send() } else { Tones.press() }
        }.isAvailable = {
            guard config.general.windowsKeys, let f = API.focusObject, API.focusTreeInterceptor == nil || API.focusTreeInterceptor?.passThrough == true,
                  ["AXButton", "AXMenuButton", "AXLink", "AXPopUpButton"].contains(f.axRole),
                  (f.element.attr(kAXFocusedAttribute) as? Bool) == true else { return false }
            var names: CFArray?
            AXUIElementCopyActionNames(f.element, &names)
            return ((names as? [String]) ?? []).contains(kAXPressAction)
        }
        script("reportBattery", String(localized: "Reports the battery level", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+shift+b"], category: sys) { _ in
            Speech.speakMessage(GlobalCommands.batteryText())
        }
        // The Windows key's places, on Option: Option alone is the Start menu's nearest Mac neighbour, the Dock;
        // Option+B is Windows+B, the notification area: the status menus, where TurnOver's own item lives.
        // The Dock through the system's own focus shortcut (Control-F3); the status menus as TurnOver's own list,
        // because the system's Control-F8 moved nothing when measured.
        let win = "Windows keys"
        let windowsOn: () -> Bool = { config.general.windowsKeys }
        script("contextMenu", String(localized: "Opens the context menu, as Control+Return does (Windows: the Applications key, Shift+F10). Also right Option on its own", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+f10"], category: win) { _ in
            if GlobalCommands.openContextMenu() { return }
            if SpellingCorrections.offer() { return }
            if GlobalCommands.contextMenuAtCaret() { return }
            _ = GlobalCommands.contextMenuForItem()
        }.isAvailable = windowsOn
        script("focusDock", String(localized: "Moves to the Dock (Windows: the Windows key). Left Option on its own", comment: "A command, as the key list and keyboard help say it"), category: win) { _ in
            KeyboardGesture(identifier: "kb:control+f3")?.send()
            // Control F3 is macOS's "Move focus to the Dock", a shortcut the person can have turned off, and on a
            // MacBook it needs the Fn flag (sent above). A reader on AppleVis heard nothing at all (26 Oct 2026):
            // half a second on, if no Dock item is selected, say so and where the shortcut lives.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let selected = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first.map { dock -> Bool in
                    let app = AXUIElementCreateApplication(dock.processIdentifier)
                    return app.elements(kAXChildrenAttribute).contains { list in
                        list.role == "AXList" && list.elements(kAXChildrenAttribute).contains { ($0.attr(kAXSelectedAttribute) as? Bool) == true }
                    }
                } ?? false
                guard !selected else { return }
                Log.info("focus Dock: no Dock item selected half a second after Control F3")
                Speech.speakMessage(String(localized: "The Dock didn't take the focus. In System Settings, Keyboard, Keyboard Shortcuts, Keyboard, turn on Move focus to the Dock.", comment: "Spoken message"))
            }
        }.isAvailable = windowsOn
        script("trackpadControl", String(localized: "Gesture control on or off: the trackpad's gestures drive TurnOver (NVDA+Control+Alt+T, touch interaction)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+control+option+t"], category: win) { _ in
            Trackpad.toggle()
        }.isAvailable = { windowsOn() && Trackpad.available }
        script("applicationChooser", String(localized: "Application chooser; lists every application with a window, system alerts too, to switch to (Windows: Windows+Tab, Task View)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:option+tab"], category: win) { _ in
            DispatchQueue.main.async { ApplicationChooser.open() }
        }.isAvailable = windowsOn
        // Option+D is Windows+D, the desktop: Finder's Desktop folder in a window, its items under the arrow keys (an
        // AppleVis reader asked how to reach the desktop in the NVDA style, 25 Oct 2026). F11 only clears the screen.
        script("showDesktop", String(localized: "Opens the Desktop folder in Finder, its items under the arrows (Windows: Windows+D)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:option+d"], category: win) { _ in
            // Off the main thread: the open is TurnOver's own first touch of Desktop, a folder macOS protects, and macOS
            // asks for the Desktop folder permission while the call waits. On the main thread that held TurnOver silent
            // until the watchdog gave speech back to VoiceOver and then relaunched it (27 Oct 2026, macOS 27.0.1: the
            // prompt a second after Option D, the relaunch 24 s later). Off it, TurnOver goes on and reads the prompt.
            let desktop = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
            DispatchQueue.global(qos: .userInitiated).async { NSWorkspace.shared.open(desktop) }
        }.isAvailable = windowsOn
        script("focusStatusMenus", String(localized: "Status menus; lists the status menus at the right of the menu bar, TurnOver's own item last (Windows: Windows+B)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:option+b"], category: win) { _ in
            StatusMenus.openList()
        }.isAvailable = windowsOn
        script("openMenus", String(localized: "Opens the application's menus; closes them if open (Windows: Alt or F10). Also Command on its own", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:f10"], category: win) { _ in
            GlobalCommands.toggleMenus()
        }.isAvailable = windowsOn
        script("quitApplication", String(localized: "Quits the application (Windows: Alt+F4)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+f4"], category: win) { _ in
            KeyboardGesture(identifier: "kb:command+q")?.send()
        }.isAvailable = windowsOn
        script("forceQuit", String(localized: "Force quit an application; lists the running applications to force quit one, with a confirmation (the Mac's Force Quit window, spoken)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+option+escape"]) { _ in
            DispatchQueue.main.async { ForceQuit.open() }
        }
        script("forceQuitWindows", String(localized: "Force quit, as Task Manager's key (Windows: Control+Shift+Escape)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:control+shift+escape"], category: win) { _ in
            DispatchQueue.main.async { ForceQuit.open() }
        }.isAvailable = windowsOn
        script("closeWindow", String(localized: "Closes the window or tab (Windows: Control+F4)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:control+f4"], category: win) { _ in
            KeyboardGesture(identifier: "kb:command+w")?.send()
        }.isAvailable = windowsOn
        // NVDA+R: the front window's text, read from the screen, as a result to move through and click in.
        script("recognizeScreen", String(localized: "Recognises the text in the window from the screen (OCR), to read with the arrows and click with Return. Pressed again in the result, recognises again", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+r"], category: sys) { _ in
            DispatchQueue.main.async { ScreenRecognition.shared.recognize() }
        }
        // Command Control M, one key for the menu in every style, as NVDA N is (Oliver, 21 Oct 2026); Command Control Comma
        // then M is still the layer's way.
        script("turnOverMenu", String(localized: "Opens the TurnOver menu: settings, keys, tools, help, quit", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+n", "kb:command+control+m"], category: sys) { _ in
            TurnOverMenu.shared.open()
        }
        // Mac style (VoiceOver's keys, key for key) or Windows style (a Mac that feels like a Windows machine with NVDA).
        script("toggleKeyboardStyle", String(localized: "Switch keyboard style; goes round VoiceOver keys, NVDA keys and JAWS keys", comment: "A command, as the key list and keyboard help say it"), gestures: [], category: sys) { _ in
            GlobalCommands.toggleKeyboardStyle()
        }
        // "That was wrong" (6 Oct 2026): one key at the moment something goes wrong; the marks go in the next report.
        script("markProblem", String(localized: "Mark a problem; marks this moment as something TurnOver got wrong, for your next feedback report", comment: "A command, as the key list and keyboard help say it"), gestures: [], category: sys) { _ in
            // Only ever marks: a second press no longer sends a report (it carries recent speech, and a key pressed
            // twice by accident, in an app that uses it too, would have sent one; the code review, 12 Oct 2026).
            Feedback.mark()
            if !(Tones.own && TurnOverSounds.play("marked")) { Tones.beep(660, 60, volume: 0.2) }
            let hinted = UserDefaults.standard.bool(forKey: "markHintGiven")
            UserDefaults.standard.set(true, forKey: "markHintGiven")
            // Just "marked": the count climbing with each press read as something going wrong (two testers, 13 Oct
            // 2026). The number is in the TurnOver menu, Send feedback, where they are sent or forgotten.
            Speech.speakMessage(hinted ? String(localized: "marked", comment: "A moment marked for feedback")
                : String(localized: "Marked. Carry on; when you're ready, send your marked moments from the TurnOver menu, Send feedback, or forget them there.", comment: "The first moment marked for feedback"))
        }
        script("toggleInputHelp", String(localized: "Turns input help on or off: every key says what it does", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+1"], category: sys, bypassInputHelp: true) { _ in
            InputManager.toggleInputHelp()
        }
        script("toggleSpeakTypedCharacters", String(localized: "Cycles speaking of typed characters: off, only in edit controls, always", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+2"], category: speechCat) { _ in
            config.keyboard.speakTypedCharacters = TypingEcho(rawValue: (config.keyboard.speakTypedCharacters.rawValue + 1) % TypingEcho.allCases.count)!
            config.save()
            Speech.speakMessage(String(localized: "speak typed characters \(config.keyboard.speakTypedCharacters.name)", comment: "Typing echo changed: %@ is off, in edit controls or always"))
        }
        script("toggleSpeakTypedWords", String(localized: "Cycles speaking of typed words: off, only in edit controls, always", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+3"], category: speechCat) { _ in
            config.keyboard.speakTypedWords = TypingEcho(rawValue: (config.keyboard.speakTypedWords.rawValue + 1) % TypingEcho.allCases.count)!
            config.save()
            Speech.speakMessage(String(localized: "speak typed words \(config.keyboard.speakTypedWords.name)", comment: "Typing echo changed: %@ is off, in edit controls or always"))
        }
        script("toggleSpeakCommandKeys", String(localized: "Turns speaking of command keys on or off", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+4"], category: speechCat) { _ in
            config.keyboard.speakCommandKeys.toggle(); config.save()
            Speech.speakMessage(String(localized: "speak command keys \(Phrases.onOff(config.keyboard.speakCommandKeys))", comment: "A setting changed: %@ is on or off"))
        }
        script("toggleReportDynamicContent", String(localized: "Turns reporting of dynamic content changes on or off", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+5"], category: speechCat) { _ in
            config.presentation.reportDynamicContentChanges.toggle(); config.save()
            Speech.speakMessage(String(localized: "report dynamic content changes \(Phrases.onOff(config.presentation.reportDynamicContentChanges))", comment: "A setting changed: %@ is on or off"))
        }
        // NVDA+S: talk, beeps, off, on demand, in NVDA's order (the parity audit, 13 Oct 2026: only talk and off).
        // The Mac style's VO-S is VoiceOver's "read the sentence", so this is NVDA's key only there.
        script("speechMode", String(localized: "Cycles speech modes: talk, beeps, off, on demand (NVDA+S)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+s"], category: speechCat) { _ in
            let order: [(SpeechMode, String)] = [(.talk, String(localized: "speech mode talk", comment: "NVDA's speech modes")), (.beeps, String(localized: "speech mode beeps", comment: "NVDA's speech modes")),
                                                 (.off, String(localized: "speech mode off", comment: "NVDA's speech modes")), (.onDemand, String(localized: "speech mode on-demand", comment: "NVDA's speech modes"))]
            let i = order.firstIndex { $0.0 == Speech.mode } ?? 0
            let (next, words) = order[(i + 1) % order.count]
            // Said in the mode that's ending, or the new one if it can speak: off and beeps would swallow their own name.
            if next == .talk { Speech.mode = .talk; Speech.speakMessage(words) }
            else { Speech.mode = .talk; Speech.speakMessage(words); Speech.mode = next }
        }
        script("sayAll", String(localized: "Reads from the caret to the end of the text", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb(laptop):turnover+a", "kb(desktop):turnover+downArrow", "kb:turnover+a", "kb:turnover+downArrow"], category: text) { _ in
            guard let obj = API.caretObject else { return }
            SayAll.readText(from: obj)
        }
        script("reportCurrentLine", String(localized: "Reports the current line. Pressed twice, spells it", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb(laptop):turnover+l", "kb(desktop):turnover+upArrow", "kb:turnover+l", "kb:turnover+upArrow", "kb:turnover+shift+."], category: text) { _ in
            GlobalCommands.reportUnit(.line)
        }
        script("reportCurrentWord", String(localized: "Reports the current word. Pressed twice, spells it", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+control+.", "kb:turnover+w"], category: text) { _ in
            GlobalCommands.reportUnit(.word)
        }
        script("reportCurrentCharacter", String(localized: "Reports the current character. Pressed twice, says its name", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+.", "kb:turnover+c"], category: text) { _ in
            GlobalCommands.reportUnit(.character)
        }
        script("reportCurrentSentence", String(localized: "Reports the current sentence", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+control+s"], category: text) { _ in
            GlobalCommands.reportUnit(.sentence)
        }
        script("reportCurrentParagraph", String(localized: "Reports the current paragraph", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+shift+p"], category: text) { _ in
            GlobalCommands.reportUnit(.paragraph)
        }
        script("reportCurrentSelection", String(localized: "Reports the selected text", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb(laptop):turnover+shift+s", "kb(desktop):turnover+shift+upArrow", "kb:turnover+shift+s"], category: text) { _ in
            guard let obj = API.caretObject, let info = try? obj.makeTextInfo(.selection), !info.isCollapsed else { Speech.speakMessage(String(localized: "no selection", comment: "Nothing is selected")); return }
            let t = info.text
            Speech.speakMessage(t.count > 1000 ? String(localized: "\(Phrases.characters(t.count)) selected", comment: "A long selection: %@ is the count of characters")
                : String(localized: "selected \(Speech.processed(t))", comment: "Selected text, read: %@ is the text"))
        }
        // JAWS keys' own commands (docs/KEYBOARD-STYLES-PLAN.md step 3, 20 Oct 2026). No keys here: JAWS's table
        // (Resources/keymaps/jaws.json) gives them theirs; any style can give them one under My own keys.
        script("jaws_sayLineToCursor", String(localized: "Reads the line from its start to the cursor. Pressed twice, spells it (JAWS: Insert+Home)", comment: "A command, as the key list and keyboard help say it"), gestures: [], category: text) { _ in
            GlobalCommands.reportLinePart(toCursor: true)
        }
        script("jaws_sayCursorToLineEnd", String(localized: "Reads the line from the cursor to its end. Pressed twice, spells it (JAWS: Insert+Page Up)", comment: "A command, as the key list and keyboard help say it"), gestures: [], category: text) { _ in
            GlobalCommands.reportLinePart(toCursor: false)
        }
        script("jaws_sayCharacter", String(localized: "Reports the current character. Twice, its name; three times, its code (JAWS: Insert+Numpad 5)", comment: "A command, as the key list and keyboard help say it"), gestures: [], category: text) { _ in
            guard ScriptHandler.lastScriptRepeatCount >= 2 else { GlobalCommands.reportUnit(.character); return }
            guard let obj = API.caretObject, let info = try? obj.makeTextInfo(.caret) else { Speech.speakMessage(String(localized: "no character", comment: "No character at the cursor")); return }
            info.expand(.character)
            guard let scalar = info.text.unicodeScalars.first else { Speech.speakMessage(String(localized: "no character", comment: "No character at the cursor")); return }
            Speech.speakMessage(String(localized: "\(String(scalar.value)), hex \(String(scalar.value, radix: 16, uppercase: true))", comment: "A character's code: decimal, then hexadecimal"))
        }
        script("jaws_saySelection", String(localized: "Reports the selected text. Pressed twice, spells it (JAWS: Insert+Shift+Down)", comment: "A command, as the key list and keyboard help say it"), gestures: [], category: text) { _ in
            guard let obj = API.caretObject, let info = try? obj.makeTextInfo(.selection), !info.isCollapsed else { Speech.speakMessage(String(localized: "no selection", comment: "Nothing is selected")); return }
            let t = info.text
            if ScriptHandler.lastScriptRepeatCount > 0 { Speech.speakSpelling(String(t.prefix(500))); return }
            Speech.speakMessage(t.count > 1000 ? String(localized: "\(Phrases.characters(t.count)) selected", comment: "A long selection: %@ is the count of characters")
                : String(localized: "selected \(Speech.processed(t))", comment: "Selected text, read: %@ is the text"))
        }
        script("jaws_timeWithSeconds", String(localized: "Reports the time with seconds. Pressed twice, the week of the year (JAWS: Control+Insert+F12)", comment: "A command, as the key list and keyboard help say it"), gestures: [], category: sys) { _ in
            if ScriptHandler.lastScriptRepeatCount > 0 {
                Speech.speakMessage(String(localized: "week \(String(Calendar(identifier: .iso8601).component(.weekOfYear, from: Date())))", comment: "The week of the year: week 43"))
            } else {
                let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .medium
                Speech.speakMessage(f.string(from: Date()))
            }
        }
        script("jaws_appVersion", String(localized: "Reports the name and version of the app in front (JAWS: Insert+Control+V)", comment: "A command, as the key list and keyboard help say it"), gestures: [], category: sys) { _ in
            guard let app = NSWorkspace.shared.frontmostApplication else { Speech.speakMessage(String(localized: "no app", comment: "No application in front")); return }
            let b = app.bundleURL.flatMap { Bundle(url: $0) }
            let v = b?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            let n = b?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            let words = [app.localizedName ?? String(localized: "this app", comment: "An application with no name"),
                         v.isEmpty ? String(localized: "version unknown", comment: "An application's version") : String(localized: "version \(v)", comment: "An application's version: %@ is the version"),
                         n.isEmpty || n == v ? "" : String(localized: "build \(n)", comment: "An application's build number: %@ is the build")]
            Speech.speakMessage(words.filter { !$0.isEmpty }.joined(separator: ", "))
        }
        script("jaws_speechHistory", String(localized: "Lists what TurnOver said lately, newest first; Return says one again (JAWS: Insert+Space, H)", comment: "A command, as the key list and keyboard help say it"), gestures: [], category: sys) { _ in
            let recent = Speech.history.value.suffix(100).reversed().map(\.text).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !recent.isEmpty else { Speech.speakMessage(String(localized: "nothing said yet", comment: "The speech history is empty")); return }
            TurnOverMenu.shared.openList("Speech history", items: recent.map { t in MenuItem(verbatim: t, .action { Speech.speakMessage(t, remember: false) }) })
        }
        script("jaws_settings", String(localized: "Opens TurnOver's settings in its menu (JAWS: Insert+F2, Insert+6)", comment: "A command, as the key list and keyboard help say it"), gestures: [], category: sys) { _ in
            TurnOverMenu.shared.openSettings()
        }
        // JAWS's lists of one kind (issue 125): on a page in browse mode, its links, headings or form fields alone.
        // Elsewhere what NVDA+F7 does there (Word's and Excel's elements lists), and where that is nothing, the key's
        // own command (NVDA+F5 refreshes a page): what these keys did while JAWS's table sent them to NVDA+F7.
        let lists = [("jaws_linksList", "Links", "Links list; lists the page's links; Enter goes there. In Word and Excel, their elements list (JAWS: Insert+F7)"),
                     ("jaws_headingsList", "Headings", "Headings list; lists the page's headings; Enter goes there. In Word and Excel, their elements list (JAWS: Insert+F6)"),
                     ("jaws_formFieldsList", "Form controls", "Form fields list; lists the page's form fields and buttons; Enter goes there. In Word and Excel, their elements list (JAWS: Insert+F5)")]
        for (name, kind, description) in lists {
            script(name, description, gestures: [], category: "Browse mode") { g in
                if let d = API.focusTreeInterceptor, !d.passThrough { d.elementsList(only: kind); return }
                // Never one of these lists again: a key of the user's own may name one.
                let elsewhere = [KeyboardGesture(identifier: "kb:turnover+f7"), g].compactMap { $0.flatMap { ScriptHandler.findScript(for: $0, styleTable: false) } }
                elsewhere.first { s in !lists.contains { $0.0 == s.name } }?.handler(g)
            }
        }
        script("jaws_sayAllBack", String(localized: "During say all: back a sentence, and carries on reading (JAWS: Left Arrow)", comment: "A command, as the key list and keyboard help say it"), gestures: [], category: text) { _ in
            SayAll.carryOn(bySentences: -1)
        }
        script("jaws_sayAllOn", String(localized: "During say all: on a sentence, and carries on reading (JAWS: Right Arrow)", comment: "A command, as the key list and keyboard help say it"), gestures: [], category: text) { _ in
            SayAll.carryOn(bySentences: 1)
        }
        script("jaws_sayAllFaster", String(localized: "During say all: faster, for this say all only (JAWS: Page Up)", comment: "A command, as the key list and keyboard help say it"), gestures: [], category: text) { _ in
            SayAll.changeRate(by: 0.05)
        }
        script("jaws_sayAllSlower", String(localized: "During say all: slower, for this say all only (JAWS: Page Down)", comment: "A command, as the key list and keyboard help say it"), gestures: [], category: text) { _ in
            SayAll.changeRate(by: -0.05)
        }
        script("find", String(localized: "Finds text: type it, then Return; the match is where you are left (VO-F; NVDA+Control+F)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+f", "kb:turnover+control+f"], category: text) { _ in
            FindPrompt.shared.open()
        }
        script("findNext", String(localized: "Finds the next match of the last search (VO-G; NVDA+F3)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+g", "kb:turnover+f3"], category: text) { _ in
            FindPrompt.shared.again(forward: true)
        }
        script("findPrevious", String(localized: "Finds the previous match of the last search (VO-Shift-G; NVDA+Shift+F3)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+shift+g", "kb:turnover+shift+f3"], category: text) { _ in
            FindPrompt.shared.again(forward: false)
        }
        // The Windows style is NVDA's: NVDA+F reports the formatting, and find is NVDA+Control+F (Caps Lock F opened
        // the find prompt in Word, 7 Oct 2026). Declared after "find", so it is tried first.
        script("nvdaReportFormatting", String(localized: "Reports the formatting at the caret (NVDA+F)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+f"], category: text) { g in
            (ScriptHandler.findScript(named: "reportFormatting") ?? GlobalCommands.shared.script(named: "reportFormatting"))?.handler(g)
        }.isAvailable = { config.general.windowsKeys }
        script("reportFormatting", String(localized: "Formatting; reports the formatting at the caret, or of the selection's first character; pressed twice, the detail: colour, background, alignment (on VO-T, in VoiceOverKeys)", comment: "A command, as the key list and keyboard help say it"), gestures: [], category: text) { _ in
            // With text selected, the caret sits at the selection's end (the next line, after Shift Down), so the
            // formatting read was the wrong line's (a tester, 8 Oct 2026): the first selected character's instead.
            guard let obj = API.caretObject else { Speech.speakMessage(String(localized: "no text", comment: "No text at the cursor")); return }
            let selection = try? obj.makeTextInfo(.selection)
            let info: TextInfo?
            if let selection, !selection.isCollapsed { info = selection } else { info = try? obj.makeTextInfo(.caret) }
            guard let info, let f = info.formatField() else { Speech.speakMessage(String(localized: "no formatting", comment: "No formatting information here")); return }
            let detail = ScriptHandler.lastScriptRepeatCount > 0
            let formatting = detail ? f.detailedDescription : f.fullDescription
            Speech.speakMessage(selection.map { !$0.isCollapsed } ?? false ? String(localized: "selected, \(formatting)", comment: "The selection's formatting: %@ is the formatting") : formatting)
            // Word: the paragraph's alignment and spacing too, from Word itself ().
            if detail, f.alignment == nil, let word = obj.appModule as? WordAppModule {
                word.script.paragraphFormat { words in if !words.isEmpty { Speech.speakMessage(words) } }
            }
        }
        script("reportCaretLocation", String(localized: "Reports where the caret is: the page and line where the application knows them", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+delete", "kb:turnover+shift+l"], category: text) { _ in
            guard let obj = API.caretObject, let info = try? obj.makeTextInfo(.caret) else { Speech.speakMessage(String(localized: "no text", comment: "No text at the cursor")); return }
            info.locationText { Speech.speakMessage($0 ?? String(localized: "location unknown", comment: "The application doesn't say where the caret is")) }
        }
        script("cycleSymbolLevel", String(localized: "Cycles the punctuation and symbol level", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+p"], category: speechCat) { _ in
            let all = SymbolLevel.allCases
            config.speech.symbolLevel = all[(config.speech.symbolLevel.rawValue + 1) % all.count]
            config.save()
            Speech.speakMessage(String(localized: "symbol level \(config.speech.symbolLevel.name)", comment: "The punctuation level changed: %@ is none, some, most or all"))
        }
        script("increaseRate", String(localized: "Speaks faster", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+control+upArrow"], category: speechCat) { _ in GlobalCommands.changeRate(0.05) }
        script("decreaseRate", String(localized: "Speaks slower", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+control+downArrow"], category: speechCat) { _ in GlobalCommands.changeRate(-0.05) }
        script("help", String(localized: "Shortcuts list; lists the shortcuts that work here, the application's own first; Enter runs one", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+/", "kb:turnover+?"], category: sys) { _ in
            GlobalCommands.openShortcutsList()
        }
        script("toggleVirtualBufferPassThrough", String(localized: "Switches between browse mode and focus mode in a document", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+space"], category: "Browse mode") { _ in
            guard let d = API.focusTreeInterceptor else { Speech.speakMessage(String(localized: "not in a document", comment: "Browse mode is only in documents")); return }
            d.disableAutoPassThrough = !d.passThrough   // NVDA: a manual switch to focus mode sticks until focus leaves
            // By hand: VoiceOver's own Quick Nav sounds (its single-key Quick Nav is browse mode's twin); the automatic
            // switch as a field takes the focus stays silent, as VoiceOver's is (17 Oct 2026).
            let browse = d.passThrough   // about to be
            d.setPassThrough(!d.passThrough, announce: !VoiceOverSounds.play(browse ? "QuickNavOn.wav" : "QuickNavOff.wav"))
        }
        // Object navigation: everything in the window, whether or not the keyboard reaches it. TurnOver Left and Right
        // step through every item in reading order, going in and out of groups by themselves, as Narrator's Caps Lock
        // arrows do (7 Oct 2026: NVDA's TurnOver Shift arrows are "far more messy"); TurnOver Shift arrows
        // stay, as in NVDA's laptop layout. In the Mac style, VoiceOver's keys have TurnOver Left and Right.
        let review = "Object navigation"
        script("reviewNext", String(localized: "Next item in the window; moves to the next item in the window, whether or not it can take the focus", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+rightArrow", "kb:turnover+shift+rightArrow"], category: review) { _ in if config.general.movesByGroups { ObjectNavigator.shared.groupStep(forward: true) } else { ObjectNavigator.shared.next() } }
        script("reviewPrevious", String(localized: "Moves to the previous item in the window", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+leftArrow", "kb:turnover+shift+leftArrow"], category: review) { _ in if config.general.movesByGroups { ObjectNavigator.shared.groupStep(forward: false) } else { ObjectNavigator.shared.previous() } }
        script("reviewParent", String(localized: "Moves out, to the item that contains this one", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+shift+upArrow"], category: review) { _ in ObjectNavigator.shared.parent() }
        script("reviewFirstChild", String(localized: "Moves in, to the first item inside this one", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+shift+downArrow"], category: review) { _ in ObjectNavigator.shared.firstChild() }
        script("reviewCurrent", String(localized: "Reports the item object navigation is on", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+shift+o"], category: review) { _ in ObjectNavigator.shared.reportCurrent() }
        script("reviewActivate", String(localized: "Activates the item object navigation is on: presses it, or puts the focus in it for typing", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+enter"], category: review) { _ in ObjectNavigator.shared.activate() }
        script("reviewMoveFocus", String(localized: "Move focus here; moves the keyboard focus to the item object navigation is on", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+shift+backspace"], category: review) { _ in ObjectNavigator.shared.moveFocusHere() }
        script("reviewToFocus", String(localized: "Brings object navigation back to the focus", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+backspace"], category: review) { _ in ObjectNavigator.shared.toFocus() }
        script("copyLastSpoken", String(localized: "Copies the last thing spoken to the clipboard, as written", comment: "A command, as the key list and keyboard help say it"), gestures: [], category: speechCat) { _ in
            Speech.copyLastSpoken()
        }
        script("repeatLastSpoken", String(localized: "Repeats the last thing spoken", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+shift+z"], category: speechCat) { _ in
            let t = Speech.lastRaw.isEmpty ? Speech.lastSpoken : Speech.lastRaw
            if t.isEmpty { Speech.speakMessage(String(localized: "nothing spoken yet", comment: "Copying the last phrase when there is none"), remember: false) } else { Speech.speakText(t) }
        }
        script("quit", String(localized: "Quits TurnOver", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:turnover+q"], category: sys) { _ in
            Speech.speakMessage(String(localized: "TurnOver quitting", comment: "TurnOver is about to quit"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { NSApp.terminate(nil) }
        }
        // NVDA's commands for the Windows style (NVDAParity.swift), last so they answer first there.
        addNVDAParity()
    }

    /// NVDA's review_current* on the caret: the unit, or spelled on a repeat.
    static func reportUnit(_ unit: TextUnit) {
        guard let obj = API.caretObject else { Speech.speakMessage(String(localized: "no focus", comment: "Nothing has the keyboard focus")); return }
        guard let info = try? obj.makeTextInfo(.caret) else {
            // Not text: the object's name and value, NVDA's basicText.
            Speech.speakMessage([obj.name, obj.value ?? ""].filter { !$0.isEmpty }.joined(separator: " "))
            return
        }
        info.expand(unit)
        if ScriptHandler.lastScriptRepeatCount > 0 {
            Speech.speakSpelling(info.text.trimmingCharacters(in: .newlines))
        } else {
            Speech.speakTextInfo(info, unit: unit, reason: .caret)
        }
    }

    /// JAWS's Insert+Home and Insert+Page Up: the line up to the cursor, or from it to the end. Twice spells it.
    static func reportLinePart(toCursor: Bool) {
        guard let obj = API.caretObject, let caret = try? obj.makeTextInfo(.caret) else { Speech.speakMessage(String(localized: "no text", comment: "No text at the cursor")); return }
        let part = caret.copy()
        part.expand(.line)
        if toCursor { part.setEndPoint(caret, .endToStart) } else { part.setEndPoint(caret, .startToStart) }
        let text = part.text.trimmingCharacters(in: .newlines)
        if text.trimmingCharacters(in: .whitespaces).isEmpty { Speech.speakMessage(Phrases.blank); return }
        if ScriptHandler.lastScriptRepeatCount > 0 { Speech.speakSpelling(text) } else { Speech.speakTextInfo(part, unit: .line, reason: .caret) }
    }

    static func changeRate(_ delta: Float) {
        // Through VoiceOver first, as the speech settings ring is (SpeechParity): one rate for both readers.
        if SpeechParity.applies("rate") {
            SpeechParity.step("rate", by: Int((delta / 0.05).rounded())) { percent in
                if let percent { config.speech.rate = min(1.0, max(0.1, Float(percent) / 100)) }
                else { config.speech.rate = min(1.0, max(0.1, config.speech.rate + delta)) }
                Speech.player.rate = config.speech.rate
                config.save()
                Speech.speakMessage(Phrases.rate(Int((config.speech.rate * 100).rounded())))
            }
            return
        }
        config.speech.rate = min(1.0, max(0.1, config.speech.rate + delta))
        Speech.player.rate = config.speech.rate
        config.save()
        Speech.speakMessage(Phrases.rate(Int((config.speech.rate * 100).rounded())))
    }

    static func batteryText() -> String {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef], let first = list.first,
              let desc = IOPSGetPowerSourceDescription(info, first)?.takeUnretainedValue() as? [String: Any] else { return String(localized: "no battery", comment: "The Mac has no battery") }
        let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
        let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
        let onPower = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        let charged = desc[kIOPSIsChargedKey] as? Bool ?? false
        // How long, as the menu bar's battery item says it (a tester, 14 Oct 2026): to full while charging, left
        // on battery; -1 while the Mac is still working it out.
        func span(_ minutes: Int) -> String? {
            guard minutes > 0 else { return nil }
            let h = minutes / 60, m = minutes % 60
            let mins = String(localized: "\(String(m)) minutes", comment: "A battery's time: minutes")
            guard h > 0 else { return mins }
            let hours = h == 1 ? String(localized: "1 hour", comment: "A battery's time: hours") : String(localized: "\(String(h)) hours", comment: "A battery's time: hours")
            return m > 0 ? String(localized: "\(hours) \(mins)", comment: "A battery's time: the hours, then the minutes") : hours
        }
        var parts = [String(localized: "battery \(String(max > 0 ? current * 100 / max : current)) percent", comment: "The battery's charge: %@ is the percentage")]
        if charged, onPower { parts.append(String(localized: "charged, on power", comment: "The battery")) }
        else if charging { parts.append(String(localized: "charging", comment: "The battery")); if let t = span(desc[kIOPSTimeToFullChargeKey] as? Int ?? -1) { parts.append(String(localized: "\(t) to full", comment: "The battery: %@ is how long until it is full")) } }
        else if onPower { parts.append(String(localized: "on power, not charging", comment: "The battery")) }
        else { parts.append(String(localized: "on battery", comment: "The battery")); if let t = span(desc[kIOPSTimeToEmptyKey] as? Int ?? -1) { parts.append(String(localized: "\(t) left", comment: "The battery: %@ is how long it will last")) } }
        return parts.joined(separator: ", ")
    }

    /// The shortcuts list (NVDA: Input Gestures, spoken): every script that would answer a key right
    /// now, in resolution order, so an app module's or add-on's own shortcuts come first. The front
    /// application's group comes first; each category is a submenu. Enter on a shortcut runs it.
    public static func openShortcutsList() {
        var seen = Set<String>()
        var collected: [(String, [(String, Script)])] = []   // category → its (binding, script), in order
        func add(_ obj: ScriptableObject, _ fallbackCategory: String) {
            for (id, s) in obj.allBindings where !id.hasPrefix("kb(") || id.hasPrefix("kb(\(config.keyboard.layout))") {
                guard !seen.contains(id) else { continue }   // an app's binding hides the global one, as in use
                // Only what the key does now: the VoiceOver keys in the Mac style, NVDA's in the Windows style (the
                // VoiceOver keys hid the Windows ones in the list, 7 Oct 2026). Keys for a held list, only while held.
                if let available = s.isAvailable, !available() { continue }
                // Only a key that would really run this command here: Word's TurnOver H was listed in the Mac style
                // while VO-H opens Help (the code review, 12 Oct 2026). The real owner is listed when its turn comes.
                if let g = KeyboardGesture(identifier: id.replacingOccurrences(of: "kb(\(config.keyboard.layout)):", with: "kb:")),
                   let real = ScriptHandler.findScript(for: g), real !== s { continue }
                seen.insert(id)
                let category = s.category == ScriptableObject.defaultCategory ? fallbackCategory : s.category
                if let i = collected.firstIndex(where: { $0.0 == category }) { collected[i].1.append((id, s)) } else { collected.append((category, [(id, s)])) }
            }
        }
        let appName = API.focusPid.map { AppModuleHandler.shared.appModule(for: $0) }?.appName ?? ""
        if let pid = API.focusPid { add(AppModuleHandler.shared.appModule(for: pid), appName) }
        if let d = API.focusTreeInterceptor { add(d, "Browse mode") }
        if let f = API.focusObject {
            add(f, "This control")
            for a in API.focusAncestors { add(a, "This control") }
        }
        for p in GlobalPluginHandler.shared.plugins { add(p, "Add-ons") }
        add(GlobalCommands.shared, "TurnOver")
        // Keys that do the same thing are one entry ("a to z, jumps to the item starting with the letter";
        // "up arrow, down arrow, home, end…, moves in the open menu"), not one entry a key.
        var groups: [(String, [MenuItem])] = collected.map { category, entries in
            var byDescription: [(String, [(String, Script)])] = []
            for e in entries {
                if let i = byDescription.firstIndex(where: { $0.0 == e.1.description }) { byDescription[i].1.append(e) } else { byDescription.append((e.1.description, [e])) }
            }
            let items: [MenuItem] = byDescription.map { description, keys in
                if Set(keys.map { spoken($0.0) }).count == 1, let (id, sc) = keys.first {
                    return MenuItem("\(spoken(id)), \(description)", .action { [weak sc] in
                        guard let sc, let g = KeyboardGesture(identifier: id) else { return }
                        ScriptHandler.queueScript(sc, gesture: g)
                    })
                }
                return MenuItem("\(keyList(keys.map { $0.0 })), \(description)", .action {})
            }
            return (category, items)
        }
        if config.general.windowsKeys, let i = groups.firstIndex(where: { $0.0 == "Windows keys" }) {
            let taps: [(String, String)] = [(String(localized: "command on its own", comment: "A key pressed and let go alone"), "openMenus"),
                                            (String(localized: "left option on its own", comment: "A key pressed and let go alone"), "focusDock"),
                                            (String(localized: "right option on its own", comment: "A key pressed and let go alone"), "contextMenu")]
            for (key, name) in taps {
                guard let s = GlobalCommands.shared.script(named: name) else { continue }
                groups[i].1.insert(MenuItem("\(key), \(s.description)", .action { [weak s] in
                    guard let s, let g = KeyboardGesture(identifier: "kb:control+f2") else { return }
                    ScriptHandler.queueScript(s, gesture: g)
                }), at: 0)
            }
        }
        var items: [MenuItem] = groups.map { category, group in MenuItem(verbatim: "\(Script.categoryName(category)), \(group.count)", .submenu { group }) }
        // A braille display connected: its keys and the space-with-dots commands.
        items += BrailleHelp.shortcutItems()
        let speechKeys = config.general.windowsKeys ? String(localized: "Control alone stops speech; Shift alone pauses it and carries on", comment: "In the key list")
            : String(localized: "Control alone pauses speech, and again carries on", comment: "In the key list")
        items.append(MenuItem(verbatim: speechKeys + (config.general.capsIsTurnOver ? String(localized: ". Caps Lock pressed twice toggles caps lock", comment: "In the key list, after the speech keys") : ""), .action {}))
        items.append(MenuItem(verbatim: String(localized: "Command Control Comma opens the TurnOver menu in any app", comment: "In the key list"), .action {}))
        TurnOverMenu.shared.openList("Shortcuts", items: items)
    }

    /// Set by the app: what changes with the style (the top row: F1 to F12 in Windows style).
    public static var onKeyboardStyleChanged: (() -> Void)?

    /// The styles Command Control Comma, K goes round, in order (Narrator's joins when its key table is built).
    public static let offeredStyles: [KeyboardStyle] = [.voiceOver, .nvda, .jaws]

    /// The next style round: Mac (VoiceOver's keys), Windows (NVDA's keys), JAWS keys, then Mac again. JAWS keys were
    /// built on 20 Oct 2026 but K only went between the first two, so they couldn't be chosen.
    public static func toggleKeyboardStyle(quietly: Bool = false) {
        let now = offeredStyles.firstIndex(of: config.general.style) ?? 0
        setKeyboardStyle(offeredStyles[(now + 1) % offeredStyles.count], quietly: quietly)
    }

    /// `quietly`: the caller says the name itself (the layer under VoiceOver, where both readers said it: an echo,
    /// 28 Oct 2026).
    public static func setKeyboardStyle(_ style: KeyboardStyle, quietly: Bool = false) {
        config.general.keyboardStyle = style.rawValue
        config.save()
        KeySettings.refresh()
        onKeyboardStyleChanged?()
        Log.info("keyboard style: \(config.general.keyboardStyle)")
        if !quietly { Speech.speakMessage(style.spokenName) }
    }

    /// Several bindings spoken as one: a run of single letters as "a to z", otherwise the keys in turn.
    static func keyList(_ ids: [String]) -> String {
        var spokenKeys: [String] = []
        for k in ids.map(spoken) where !spokenKeys.contains(k) { spokenKeys.append(k) }   // a layout's binding and the general one
        let letters = spokenKeys.filter { $0.count == 1 && $0.first!.isLetter }.sorted()
        if letters.count == spokenKeys.count, letters.count > 3, let first = letters.first, let last = letters.last { return String(localized: "\(first) to \(last)", comment: "A run of letter keys: a to z") }
        if spokenKeys.count > 8 { return String(localized: "\(spokenKeys.prefix(8).joined(separator: ", ")) and others", comment: "Some of many keys: %@ is the first eight") }
        return spokenKeys.joined(separator: ", ")
    }

    /// Alt in Windows: open the menus, or close them when they are open.
    /// Where TurnOver, not the app, holds the place (a chat's messages): the shortcut menu is TurnOver's list of the
    /// item's actions. True when handled.
    public static var contextMenuHandler: (() -> Bool)?
    /// The context menu for what TurnOver is on, before the app's own: a view's item (contextMenuHandler), or on a
    /// page in browse mode, the link or control at the reading position, as NVDA and VoiceOver open it (a tester,
    /// 13 Oct 2026: on a link the page's menu came up, without "open in a new tab", until he interacted with it).
    public static func openContextMenu() -> Bool {
        if contextMenuHandler?() == true { return true }
        if let d = API.focusTreeInterceptor, !d.passThrough, d.showContextMenuAtCaret() { return true }
        return false
    }

    /// In text, the shortcut menu at the caret: a right click where the caret is, which is how Word offers the
    /// corrections for a misspelled word (VoiceOver's VO Shift M does; Control Return did nothing, 17 Oct 2026).
    public static func contextMenuAtCaret() -> Bool {
        guard let f = API.focusObject, let info = try? f.makeTextInfo(.caret) else { return false }
        // Only when the VoiceOver cursor is in this text: on a toolbar button it is the button's menu VoiceOver opens
        // (the code review, 17 Oct 2026).
        guard ObjectNavigator.shared.isWithin(f.element) else { return false }
        var v: CFTypeRef?
        // A selection: clicked at its start, inside it (the caret is at its end, so the click landed after a word
        // Command Semicolon had selected, and the menu was the space's, without the corrections: 19 Oct 2026).
        let at = (try? f.makeTextInfo(.selection)).flatMap { $0.isCollapsed ? nil : $0.start } ?? info.start
        guard AXUIElementCopyParameterizedAttributeValue(f.element, kAXBoundsForRangeParameterizedAttribute as CFString, axRangeValue(at, 1), &v) == .success,
              let v, CFGetTypeID(v) == AXValueGetTypeID() else { return false }
        var r = CGRect.zero
        guard axValue(v, .cgRect, &r), r.width >= 0, r.height > 0 else { return false }
        // Inside the field on screen, or a scrolled-off caret would click whatever window is there.
        if let frame = TurnOverObject.frame(f.element), !frame.insetBy(dx: -2, dy: -2).contains(CGPoint(x: r.midX, y: r.midY)) { Log.io("context menu: the caret is off the field (\(Int(r.midX)), \(Int(r.midY))); not clicked"); return false }
        let p = CGPoint(x: r.minX + max(1, min(r.width, 4)), y: r.midY)
        Log.io("context menu: right click at the caret (\(Int(p.x)), \(Int(p.y)))")
        rightClick(at: p)
        return true
    }

    /// A right click at `p`, the pointer put back after, as VO-Shift-Space leaves it, once the menu has opened.
    private static func rightClick(at p: CGPoint) {
        TurnOverObject.contextMenuRequestedAt = Date()
        let src = CGEventSource(stateID: .hidSystemState)
        let before = CGEvent(source: nil)?.location
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .right)?.post(tap: .cghidEventTap)
        for type in [CGEventType.rightMouseDown, .rightMouseUp] {
            CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .right)?.post(tap: .cghidEventTap)
        }
        if let before { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { CGWarpMouseCursorPosition(before) } }
    }

    /// The context menu of the item TurnOver is on, where the page or the caret had none: its own AXShowMenu action
    /// if it has one, else a right click in the middle of it. Control Return, the fallback until 26 Oct 2026, opened
    /// nothing here in Finder or Safari, and on one Mac the desktop's menu (New Folder, Change Wallpaper) instead of
    /// the item's: the click, or the key, landed where no item was (an AppleVis reader). With nothing to open a menu
    /// for, TurnOver says so rather than clicking whatever lies under the pointer.
    public static func contextMenuForItem() -> Bool {
        guard var e = ObjectNavigator.shared.reviewElement ?? API.focusObject?.element else {
            Speech.speakMessage(String(localized: "No item to open a menu for", comment: "Spoken message")); return true
        }
        // In a list, outline or table the item is the selected row, not the list: Finder's list answered AXShowMenu
        // with a two-second timeout and the click would land on whichever row is at the list's middle.
        if ["AXOutline", "AXTable", "AXList"].contains(e.role),
           let row = e.elements(kAXSelectedRowsAttribute).first ?? e.elements(kAXSelectedChildrenAttribute).first { e = row }
        var acts: CFArray?
        if AXUIElementCopyActionNames(e, &acts) == .success, ((acts as? [String]) ?? []).contains("AXShowMenu") {
            TurnOverObject.contextMenuRequestedAt = Date()
            AXUIElementSetMessagingTimeout(e, 0.3)   // never a long wait on main for a menu (AGENTS.md)
            let r = AXUIElementPerformAction(e, "AXShowMenu" as CFString)
            AXUIElementSetMessagingTimeout(e, 0)
            Log.io("context menu: AXShowMenu on \(e.role) → \(r.rawValue)")
            if r == .success { return true }
        }
        guard let frame = TurnOverObject.frame(e), frame.width > 0, frame.height > 0 else {
            Speech.speakMessage(String(localized: "No item to open a menu for", comment: "Spoken message")); return true
        }
        let p = CGPoint(x: frame.midX, y: frame.midY)
        Log.io("context menu: right click on \(e.role) at (\(Int(p.x)), \(Int(p.y)))")
        rightClick(at: p)
        return true
    }

    public static func toggleMenus() {
        if AXHandler.shared.isMenuOpen {
            for m in AXHandler.shared.openMenus.reversed() { _ = AXUIElementPerformAction(m, kAXCancelAction as CFString) }
            AXHandler.shared.menusClosed()
            if let pid = API.focusPid { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { AXHandler.shared.refocus(pid: pid) } }
            return
        }
        // Mac style: the bar's titles, as VoiceOver (a second VO M leaves them).
        if !config.general.windowsKeys {
            if MenuNavigationPlugin.heldBar != nil { MenuNavigationPlugin.releaseBar(); Braille.releaseItem(); if let pid = API.focusPid { MenuNavigationPlugin.backFromBar(pid: pid) }; return }
            MenuNavigationPlugin.holdMenuBar(); return
        }
        // The handler itself, not executeScript: that would make this the last script run, and the caller's
        // second press (VO-M-M) would no longer count as a repeat.
        guard let g = KeyboardGesture(identifier: "kb:control+f2"), let s = ScriptHandler.findScript(for: g) else { return }
        s.handler(g)
    }

    static func spoken(_ identifier: String) -> String {
        guard let colon = identifier.firstIndex(of: ":") else { return identifier }
        return identifier[identifier.index(after: colon)...].split(separator: "+").map { part -> String in
            let p = String(part)
            if p == "turnover" || p == "bosun" { return config.general.turnOverKeyName }
            if let code = KeyNames.code(for: p) { return KeyNames.spoken(for: code, characters: p) }
            return p
        }.joined(separator: " ")
    }
}
