// SPDX-License-Identifier: GPL-3.0-or-later
// NVDA's commands in the Windows style (12 Oct 2026: "parity between voiceover in mac mode and NVDA in
// windows mode"). docs/NVDA-PARITY.md lists every NVDA command, what answers it here, and the variations put to the maintainer.
// Each script here answers only in the Windows style, and is declared after GlobalCommands' own, so on a shared key
// it answers first there; the Mac style keeps VoiceOver's (VoiceOverParity.swift).
//
// Keys: NVDA's laptop layout, with Caps Lock (or Control Option) as the NVDA key. NVDA's Alt is the Mac's Command, by
// position (WINDOWS-MODE.md), and Option too where TurnOver used it already (Word's NVDA+Alt+C).
import Foundation
import AppKit
import AVFoundation
import ApplicationServices

/// NVDA's review cursor over text. It follows the caret (NVDA+6 turns that off) and, once moved, stays where it was
/// put until the caret moves or the focus goes elsewhere.
public enum TextReview {
    nonisolated(unsafe) static var info: TextInfo?
    nonisolated(unsafe) static var anchorCaret: Int?
    nonisolated(unsafe) public static var followsCaret = true
    /// NVDA+F9: the start marked for copying.
    nonisolated(unsafe) static var mark: TextInfo?

    static func caretInfo() -> TextInfo? { API.caretObject.flatMap { try? $0.makeTextInfo(.caret) } }

    /// Where the review cursor is now: where it was left, unless the caret has moved since (or it left that text).
    static func current() -> TextInfo? {
        guard let c = caretInfo() else { return nil }
        if let i = info, i.obj.isSameElement(as: c.obj), !followsCaret || c.start == anchorCaret { return i.copy() }
        return c
    }

    static func set(_ i: TextInfo) {
        info = i.copy()
        anchorCaret = caretInfo()?.start
    }

    /// NVDA's review_current*: the unit at the review cursor; spelled on a second press.
    static func report(_ unit: TextUnit) {
        guard let i = current() else { GlobalCommands.reportUnit(unit); return }
        i.expand(unit)
        if ScriptHandler.lastScriptRepeatCount > 0 { Speech.speakSpelling(i.text.trimmingCharacters(in: .newlines)) }
        else { Speech.speakTextInfo(i, unit: unit, reason: .caret) }
    }

    /// NVDA's review_previous/nextWord and the like: moves by a unit and reads it; at an edge, says so.
    static func move(_ unit: TextUnit, _ by: Int) {
        guard let i = current() else { GlobalCommands.reportUnit(unit); return }   // not text: the item's name and value
        i.expand(unit); i.collapse()
        if i.move(unit, by) == 0 {
            Speech.speakMessage(by < 0 ? "top" : "bottom")
            i.expand(unit); Speech.speakTextInfo(i, unit: unit, reason: .caret); return
        }
        set(i)
        i.expand(unit)
        Speech.speakTextInfo(i, unit: unit, reason: .caret)
    }

    /// NVDA's review_top and review_bottom: the first or last line.
    static func edge(last: Bool) {
        guard let c = current(), let i = try? c.obj.makeTextInfo(last ? .last : .first) else { Speech.speakMessage("no text"); return }
        set(i)
        i.expand(.line)
        Speech.speakTextInfo(i, unit: .line, reason: .caret)
    }
}

extension GlobalCommands {
    func addNVDAParity() {
        let cat = "NVDA keys"
        let on: () -> Bool = { config.general.windowsKeys }
        @discardableResult
        func add(_ name: String, _ description: String, _ gestures: [String], available: (() -> Bool)? = nil, _ run: @escaping (KeyboardGesture) -> Void) -> Script {
            let s = script("nvda_\(name)", description, gestures: gestures, category: cat, run)
            s.isAvailable = available.map { a in { on() && a() } } ?? on
            return s
        }
        func run(_ name: String, _ g: KeyboardGesture) {
            if let s = ScriptHandler.findScript(named: name) ?? GlobalCommands.shared.script(named: name) { s.handler(g) }
        }
        func count() -> Int { ScriptHandler.lastScriptRepeatCount }

        // MARK: Basic and system
        add("repeatLastSpoken", "Repeats the last thing spoken (NVDA+X)", ["kb:turnover+x"]) { g in run("repeatLastSpoken", g) }
        add("passNextKey", "The next key goes to the application untouched (NVDA+F2)", ["kb:turnover+f2"]) { _ in
            InputManager.passNextKey = true
            Speech.speakMessage("pass next key through")
        }
        add("reportClipboard", "Reports the text on the clipboard (NVDA+C)", ["kb:turnover+c"]) { _ in
            guard let t = NSPasteboard.general.string(forType: .string), !t.isEmpty else { Speech.speakMessage("There is no text on the clipboard"); return }
            if t.count > 1024 { Speech.speakMessage("The clipboard contains a large amount of text. It is \(t.count) characters long") }
            else { Speech.speakPrivate(t) }
        }
        add("readWindow", "Reads everything in the window in front (NVDA+B)", ["kb:turnover+b"]) { _ in ObjectNavigator.shared.readWindow() }
        add("statusBar", "Reports the status bar, if the window has one (NVDA+Shift+End)", ["kb:turnover+shift+end", "kb(desktop):turnover+end"]) { _ in
            // A Mac window has no status bar role: the strip along its bottom edge is one (Finder's "21 items", a
            // Word document's page count). Two levels down at most, 120 items, so it never holds the keys up.
            guard let w = API.focusObject?.element.element(kAXWindowAttribute), let wf = TurnOverObject.frame(w) else { Speech.speakMessage("no status bar found"); return }
            var level = [w], texts: [String] = [], seen = 0
            for _ in 0..<3 {
                var next: [AXUIElement] = []
                for e in level {
                    for k in e.elements(kAXChildrenAttribute) where seen < 120 {
                        seen += 1
                        guard let f = TurnOverObject.frame(k), f.height < 60, wf.maxY - f.maxY < 8, f.minY > wf.midY else { continue }
                        if ["AXStaticText", "AXButton", "AXPopUpButton", "AXSlider", "AXValueIndicator"].contains(k.role) {
                            let s = VoiceOverKeysPlugin.text(k); if !s.isEmpty { texts.append(s) }
                        } else { next.append(k) }
                    }
                }
                level = next
            }
            Speech.speakMessage(texts.isEmpty ? "no status bar found" : texts.joined(separator: ", "))
        }
        add("reportShortcut", "Reports the shortcut key of the item with focus (NVDA+Control+Shift+Period)", ["kb:turnover+control+shift+."]) { _ in
            Speech.speakMessage(API.focusObject?.keyboardShortcut.flatMap { $0.isEmpty ? nil : $0 } ?? "no shortcut key")
        }
        add("linkDestination", "Reports where the link goes (NVDA+K)", ["kb:turnover+k"]) { _ in
            var x = VoiceOverKeysPlugin.cursorElement(); var hops = 0
            while let y = x, hops < 4 {
                if let u = y.attr(kAXURLAttribute) { Speech.speakPrivate((u as? URL)?.absoluteString ?? "\(u)"); return }
                x = y.element(kAXParentAttribute); hops += 1
            }
            Speech.speakMessage("not a link")
        }
        add("followFocus", "Turns the review cursor following the focus on or off (NVDA+7)", ["kb:turnover+7"]) { _ in
            ObjectNavigator.shared.tracksFocus.toggle()
            Speech.speakMessage(ObjectNavigator.shared.tracksFocus ? "review cursor follows system focus" : "review cursor doesn't follow the system focus")
        }
        add("followCaret", "Turns the review cursor following the caret on or off (NVDA+6)", ["kb:turnover+6"]) { _ in
            TextReview.followsCaret.toggle()
            Speech.speakMessage(TextReview.followsCaret ? "review cursor follows system caret" : "review cursor doesn't follow the system caret")
        }

        add("sleepMode", "Sleep mode on or off for this app: TurnOver says nothing and every key goes to the app (NVDA+Shift+Z)", ["kb:turnover+shift+z", "kb(desktop):turnover+shift+s"]) { _ in
            guard let app = NSWorkspace.shared.frontmostApplication else { return }
            let on = InputManager.toggleSleep(app.processIdentifier)
            Log.info("sleep mode \(on ? "on" : "off") for \(app.bundleIdentifier ?? "pid \(app.processIdentifier)")")
            Speech.speakMessage(on ? "Sleep mode on" : "Sleep mode off")
        }
        add("screenLayout", "Screen layout on or off in browse mode: things side by side on one line (NVDA+V)", ["kb:turnover+v"]) { _ in
            config.virtualBuffers.screenLayout.toggle(); config.save()
            if let d = API.focusTreeInterceptor { d.buffer.isDirty = true; d.buffer.build() }
            Speech.speakMessage(config.virtualBuffers.screenLayout ? "Use screen layout on" : "Use screen layout off")
        }
        add("audioDucking", "Audio ducking: no ducking, duck when outputting speech, always duck (NVDA+Shift+D)", ["kb:turnover+shift+d"]) { _ in
            Ducking.cycle()
        }

        // MARK: Object navigation
        add("previousFlattened", "Moves to the previous item, in and out of groups (NVDA+Shift+Left Bracket)", ["kb:turnover+shift+["]) { _ in ObjectNavigator.shared.previous() }
        add("nextFlattened", "Moves to the next item, in and out of groups (NVDA+Shift+Right Bracket)", ["kb:turnover+shift+]"]) { _ in ObjectNavigator.shared.next() }
        add("reviewLocation", "Where the item is on screen; reports where the item object navigation is on sits on the screen (NVDA+Shift+Delete)", ["kb:turnover+shift+delete"]) { _ in
            guard let e = VoiceOverKeysPlugin.cursorElement() else { Speech.speakMessage("no object"); return }
            Speech.speakMessage(VoiceOverKeysPlugin.geometry(e, overlaps: false))
        }

        // MARK: Reviewing text
        add("reviewCurrentLine", "Reports the line at the review cursor; twice, spells it (NVDA+Shift+Period)", ["kb:turnover+shift+."]) { _ in TextReview.report(.line) }
        add("reviewCurrentWord", "Reports the word at the review cursor; twice, spells it (NVDA+Control+Period)", ["kb:turnover+control+."]) { _ in TextReview.report(.word) }
        add("reviewCurrentCharacter", "Reports the character at the review cursor; twice, spells it (NVDA+Period)", ["kb:turnover+."]) { _ in TextReview.report(.character) }
        add("reviewPreviousLine", "Moves the review cursor to the previous line (NVDA+Up Arrow, laptop)", ["kb:turnover+upArrow"]) { _ in TextReview.move(.line, -1) }
        add("reviewNextLine", "Moves the review cursor to the next line (NVDA+Down Arrow, laptop)", ["kb:turnover+downArrow"]) { _ in TextReview.move(.line, 1) }
        // In text, NVDA's review by character; elsewhere TurnOver's flattened object moves answer (12 Oct 2026:
        // same key, same purpose, the method adapted to the Mac).
        let inText: () -> Bool = { (API.focusTreeInterceptor.map { !$0.passThrough } ?? false) || (API.focusObject?.hasNavigableText ?? false) }
        add("reviewPreviousCharacter", "In text, moves the review cursor to the previous character (NVDA+Left Arrow)", ["kb:turnover+leftArrow"], available: inText) { _ in TextReview.move(.character, -1) }
        add("reviewNextCharacter", "In text, moves the review cursor to the next character (NVDA+Right Arrow)", ["kb:turnover+rightArrow"], available: inText) { _ in TextReview.move(.character, 1) }
        add("reviewTop", "Moves the review cursor to the top line (NVDA+Control+Home)", ["kb:turnover+control+home"]) { _ in TextReview.edge(last: false) }
        add("reviewBottom", "Moves the review cursor to the bottom line (NVDA+Control+End)", ["kb:turnover+control+end"]) { _ in TextReview.edge(last: true) }
        for (name, end, key) in [("reviewLineStart", false, "home"), ("reviewLineEnd", true, "end")] {
            add(name, end ? "Moves the review cursor to the end of the line (NVDA+End)" : "Moves the review cursor to the start of the line (NVDA+Home)", ["kb:turnover+\(key)"]) { _ in
                guard let i = TextReview.current() else { Speech.speakMessage("no text"); return }
                i.expand(.line)
                i.collapse(toEnd: end)
                if end { _ = i.move(.character, -1) }
                TextReview.set(i)
                i.expand(.character)
                Speech.speakTextInfo(i, unit: .character, reason: .caret)
            }
        }
        // NVDA's review by page: NVDA+Page Up and Down in the desktop layout, NVDA+Shift+Page Up and Down in the laptop.
        add("reviewPreviousPage", "Moves the review cursor to the previous page (NVDA+Page Up; laptop: NVDA+Shift+Page Up)", ["kb(desktop):turnover+pageUp", "kb(laptop):turnover+shift+pageUp"]) { _ in TextReview.move(.line, -20) }
        add("reviewNextPage", "Moves the review cursor to the next page (NVDA+Page Down; laptop: NVDA+Shift+Page Down)", ["kb(desktop):turnover+pageDown", "kb(laptop):turnover+shift+pageDown"]) { _ in TextReview.move(.line, 20) }
        add("reviewPreviousWord", "Moves the review cursor to the previous word (NVDA+Control+Left Arrow)", ["kb:turnover+control+leftArrow"]) { _ in TextReview.move(.word, -1) }
        add("reviewNextWord", "Moves the review cursor to the next word (NVDA+Control+Right Arrow)", ["kb:turnover+control+rightArrow"]) { _ in TextReview.move(.word, 1) }
        for (name, end, keys) in [("reviewSelectionStart", false, ["kb:turnover+command+home", "kb:turnover+option+home"]), ("reviewSelectionEnd", true, ["kb:turnover+command+end", "kb:turnover+option+end"])] {
            add(name, end ? "Moves the review cursor to the end of the selection (NVDA+Alt+End)" : "Moves the review cursor to the start of the selection (NVDA+Alt+Home)", keys) { _ in
                guard let s = API.caretObject.flatMap({ try? $0.makeTextInfo(.selection) }), !s.isCollapsed else { Speech.speakMessage("no selection"); return }
                s.collapse(toEnd: end)
                if end { _ = s.move(.character, -1) }
                TextReview.set(s)
                s.expand(.line)
                Speech.speakTextInfo(s, unit: .line, reason: .caret)
            }
        }
        add("reviewSayAll", "Reads from the review cursor to the end of the text (NVDA+Shift+A)", ["kb:turnover+shift+a"]) { _ in
            guard let i = TextReview.current() else { Speech.speakMessage("no text"); return }
            SayAll.readText(info: i) { TextReview.set($0) }
        }
        add("markStart", "Marks the review cursor as the start of text to copy (NVDA+F9)", ["kb:turnover+f9"]) { _ in
            guard let i = TextReview.current() else { Speech.speakMessage("no text"); return }
            i.collapse(); TextReview.mark = i
            Speech.speakMessage("start marked")
        }
        add("copyToReview", "Selects from the marked start to the review cursor; twice, copies it (NVDA+F10)", ["kb:turnover+f10"]) { _ in
            guard let m = TextReview.mark, let i = TextReview.current(), m.obj.isSameElement(as: i.obj) else { Speech.speakMessage("no start marker set"); return }
            let r = m.copy(); i.expand(.character)
            r.setEndPoint(i, .endToEnd)
            guard !r.isCollapsed else { Speech.speakMessage("no text to copy"); return }
            if count() > 0 {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(r.text, forType: .string)
                Speech.speakMessage("copied to clipboard")
            } else {
                r.updateSelection()
                Speech.speakMessage("selected; press again to copy")
            }
        }
        add("toMarkedStart", "Moves the review cursor to the marked start (NVDA+Shift+F9)", ["kb:turnover+shift+f9"]) { _ in
            guard let m = TextReview.mark else { Speech.speakMessage("no start marker set"); return }
            TextReview.set(m)
            let c = m.copy(); c.expand(.character)
            Speech.speakTextInfo(c, unit: .character, reason: .caret)
        }
        add("reviewFormatting", "Reports the formatting at the review cursor (NVDA+Shift+F)", ["kb:turnover+shift+f"]) { _ in
            guard let i = TextReview.current() else { Speech.speakMessage("no text"); return }
            i.expand(.character)
            Speech.speakMessage(i.formatField()?.fullDescription ?? "no formatting")
        }

        // MARK: Tables (Control+Alt+arrows: Control+Command on a Mac keyboard, Alt being where Command is)
        let inTable: () -> Bool = { NVDATables.hasTable() }
        for (name, spoken, kind) in [("previousColumn", "previous column", NVDATables.Move.column(-1)), ("nextColumn", "next column", .column(1)),
                                     ("previousRow", "previous row", .row(-1)), ("nextRow", "next row", .row(1)),
                                     ("firstColumn", "first column", .firstColumn), ("lastColumn", "last column", .lastColumn),
                                     ("firstRow", "first row", .firstRow), ("lastRow", "last row", .lastRow)] {
            let key: String
            switch kind {
            case .column(let d): key = d < 0 ? "leftArrow" : "rightArrow"
            case .row(let d): key = d < 0 ? "upArrow" : "downArrow"
            case .firstColumn: key = "home"; case .lastColumn: key = "end"; case .firstRow: key = "pageUp"; case .lastRow: key = "pageDown"
            }
            add("table_\(name)", "Moves to the \(spoken) in a table (Control+Alt+\(key))", ["kb:control+command+\(key)"], available: inTable) { _ in NVDATables.move(kind) }
        }
        add("table_sayAllColumn", "Reads down the column from here (NVDA+Control+Alt+Down Arrow)", ["kb:turnover+control+command+downArrow"], available: inTable) { _ in NVDATables.read(row: false, fromHere: true) }
        add("table_sayAllRow", "Reads along the row from here (NVDA+Control+Alt+Right Arrow)", ["kb:turnover+control+command+rightArrow"], available: inTable) { _ in NVDATables.read(row: true, fromHere: true) }
        add("table_readColumn", "Reads the whole column (NVDA+Control+Alt+Up Arrow)", ["kb:turnover+control+command+upArrow"], available: inTable) { _ in NVDATables.read(row: false, fromHere: false) }
        add("table_readRow", "Reads the whole row (NVDA+Control+Alt+Left Arrow)", ["kb:turnover+control+command+leftArrow"], available: inTable) { _ in NVDATables.read(row: true, fromHere: false) }

        // MARK: The mouse
        for (right, bracket) in [(false, "["), (true, "]")] {
            let side = right ? "right" : "left"
            add("\(side)Click", "Clicks the \(side) mouse button where the pointer is (NVDA+\(right ? "Right" : "Left") Bracket)", ["kb:turnover+\(bracket)"]) { _ in NVDAMouse.click(right: right) }
            add("\(side)Lock", "Holds the \(side) mouse button down, or lets it go (NVDA+Control+\(right ? "Right" : "Left") Bracket)", ["kb:turnover+control+\(bracket)"]) { _ in NVDAMouse.lock(right: right) }
        }
        add("mouseToNavigator", "Pointer to this item; moves the mouse pointer to the item object navigation is on (NVDA+Shift+M)", ["kb:turnover+shift+m"]) { _ in
            guard let e = VoiceOverKeysPlugin.cursorElement(), let r = TurnOverObject.frame(e) else { Speech.speakMessage("no object"); return }
            CGWarpMouseCursorPosition(CGPoint(x: r.midX, y: r.midY))
            Speech.speakMessage("mouse moved")
        }
        add("navigatorToMouse", "To the item under the pointer; moves object navigation to the item under the mouse pointer (NVDA+Shift+N)", ["kb:turnover+shift+n"]) { _ in
            guard let e = VoiceOverKeysPlugin.element(at: VoiceOverKeysPlugin.mouseLocation()) else { Speech.speakMessage("nothing under the pointer"); return }
            ObjectNavigator.shared.moveTo(e)
        }

        // MARK: Browse mode
        add("refreshDocument", "Rebuilds the page's browse mode view (NVDA+F5)", ["kb:turnover+f5"]) { _ in
            guard let d = API.focusTreeInterceptor else { Speech.speakMessage("not in a document"); return }
            d.buffer.isDirty = true; d.buffer.build()
            Speech.speakMessage("refreshed")
        }
        add("toggleSingleLetterNavigation", "Single-letter navigation on or off; turns single-letter navigation on or off for this page, so the page's own letter keys work (NVDA+Shift+Space)", ["kb:turnover+shift+space"]) { _ in
            guard let d = API.focusTreeInterceptor else { Speech.speakMessage("not in a document"); return }
            d.singleLetterNavigation.toggle()
            Speech.speakMessage(d.singleLetterNavigation ? "single letter navigation on" : "single letter navigation off")
        }
        add("toDocument", "Back to the page; from something inside a page, back to the page in browse mode (NVDA+Control+Space)", ["kb:turnover+control+space"]) { _ in
            guard let d = API.focusTreeInterceptor else { Speech.speakMessage("not in a document"); return }
            if d.passThrough { d.setPassThrough(false, announce: true) } else { Speech.speakMessage("browse mode") }
        }

        // MARK: Settings (NVDA's dialogs: the TurnOver menu's sections)
        for (key, section, nvda) in [("g", nil, "General"), ("v", "Speech", "Speech"), ("a", "Braille", "Select Braille Display"),
                                     ("u", "Speech", "Audio"), ("s", "Speech", "Select Synthesizer"), ("k", "Keyboard", "Keyboard"), ("m", nil, "Mouse"),
                                     ("o", "Item details", "Object Presentation"), ("b", "Web pages", "Browse Mode"),
                                     ("d", "Documents", "Document Formatting")] as [(String, String?, String)] {
            add("settings_\(nvda.replacingOccurrences(of: " ", with: ""))", "Opens TurnOver's \(section ?? "Settings") (NVDA+Control+\(key.uppercased()): \(nvda) settings)", ["kb:turnover+control+\(key)"]) { _ in
                TurnOverMenu.shared.openSettings(section)
            }
        }
        // The synth settings ring.
        add("ringNext", "Next speech setting: voice, rate, volume, punctuation (NVDA+Shift+Control+Right Arrow)", ["kb:turnover+control+shift+rightArrow", "kb(desktop):turnover+control+rightArrow"]) { _ in SynthRing.step(1) }
        add("ringPrevious", "Previous speech setting (NVDA+Shift+Control+Left Arrow)", ["kb:turnover+control+shift+leftArrow", "kb(desktop):turnover+control+leftArrow"]) { _ in SynthRing.step(-1) }
        add("ringUp", "Raises the speech setting (NVDA+Shift+Control+Up Arrow)", ["kb:turnover+control+shift+upArrow", "kb(desktop):turnover+control+upArrow"]) { _ in SynthRing.change(1, large: false) }
        add("ringDown", "Lowers the speech setting (NVDA+Shift+Control+Down Arrow)", ["kb:turnover+control+shift+downArrow", "kb(desktop):turnover+control+downArrow"]) { _ in SynthRing.change(-1, large: false) }
        add("ringUpLarge", "Raises the speech setting in a large step (NVDA+Shift+Control+Page Up)", ["kb:turnover+control+shift+pageUp", "kb(desktop):turnover+control+pageUp"]) { _ in SynthRing.change(1, large: true) }
        add("ringDownLarge", "Lowers the speech setting in a large step (NVDA+Shift+Control+Page Down)", ["kb:turnover+control+shift+pageDown", "kb(desktop):turnover+control+pageDown"]) { _ in SynthRing.change(-1, large: true) }

        add("configProfiles", "Configuration profiles: sets of speech, verbosity, web and braille settings, by hand or for an app (NVDA+Control+P)", ["kb:turnover+control+p"]) { _ in SettingsProfiles.openChooser() }
        // MARK: Braille (NVDA's Alt is Command, and Option, as elsewhere here)
        add("brailleTether", "Cycles what braille follows: automatically, the focus, or the review cursor (NVDA+Control+T)", ["kb:turnover+control+t"]) { _ in Braille.cycleTether() }
        add("brailleMode", "Braille mode; switches braille between following the cursors and showing speech (NVDA+Alt+T)", ["kb:turnover+command+t", "kb:turnover+option+t"]) { _ in Braille.cycleMode() }
        add("brailleAutoScroll", "Braille auto scroll on or off (NVDA+Alt+K)", ["kb:turnover+command+k", "kb:turnover+option+k"]) { _ in Braille.toggleAutoScroll() }
        add("brailleAutoScrollFaster", "Braille auto scroll faster (NVDA+Alt+L)", ["kb:turnover+command+l", "kb:turnover+option+l"]) { _ in Braille.autoScrollRate(faster: true) }
        add("brailleAutoScrollSlower", "Braille auto scroll slower (NVDA+Alt+J)", ["kb:turnover+command+j", "kb:turnover+option+j"]) { _ in Braille.autoScrollRate(faster: false) }
        // NVDA+Control+Shift+F1: the first press marks the log; the second copies it from the mark.
        add("copyLogPart", "Marks the log; pressed again, copies the log from the mark (NVDA+Control+Shift+F1)", ["kb:turnover+control+shift+f1"]) { _ in Log.markOrCopy() }

        // MARK: Configuration, log and plugins
        add("saveConfiguration", "Saves the settings (NVDA+Control+C)", ["kb:turnover+control+c"]) { _ in
            config.save(); Speech.speakMessage("Configuration saved")
        }
        add("revertConfiguration", "Goes back to the settings last saved (NVDA+Control+R)", ["kb:turnover+control+r"]) { _ in
            config = Config.load()
            Speech.player.rate = config.speech.rate
            Speech.player.volume = Float(config.speech.volume) / 100
            Speech.player.voiceIdentifier = config.speech.voice
            Speech.speakMessage("Configuration applied")
        }
        add("logViewer", "Open the log; writes the navigator object's details to the log and opens the log (NVDA+F1)", ["kb:turnover+f1"]) { _ in
            if let e = VoiceOverKeysPlugin.cursorElement() {
                let o = ObjectFactory.make(e)
                Log.info("developer info: role \(e.role), subrole \(e.string(kAXSubroleAttribute) ?? "-"), kind \(o.role), states \(o.states), pid \(e.pid), app module \(String(describing: type(of: AppModuleHandler.shared.appModule(for: e.pid))))")
            }
            guard !Log.path.isEmpty else { Speech.speakMessage("no log"); return }
            NSWorkspace.shared.open([URL(fileURLWithPath: Log.path)], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"), configuration: NSWorkspace.OpenConfiguration())
        }
        add("reportAppModule", "Application and module; reports the application module and the application's name and version (NVDA+Control+F1)", ["kb:turnover+control+f1"]) { _ in
            guard let pid = API.focusPid, let app = NSRunningApplication(processIdentifier: pid) else { Speech.speakMessage("no application"); return }
            let module = String(describing: type(of: AppModuleHandler.shared.appModule(for: pid)))
            let version = app.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String } ?? "unknown"
            Speech.speakMessage("\(module) module, loaded for \(app.localizedName ?? "this application"), \(app.bundleIdentifier ?? ""), version \(version)")
        }
        add("reloadPlugins", "Reloads the plugins (NVDA+Control+F3)", ["kb:turnover+control+f3"]) { _ in
            _ = ProfileStore.shared.reload(force: true, quiet: false)
            Speech.speakMessage("Plugins reloaded")
        }
    }
}

// MARK: - Tables

enum NVDATables {
    enum Move { case column(Int), row(Int), firstColumn, lastColumn, firstRow, lastRow }

    /// Word's own cell moves (the module finds the cell from the live caret), else a table's cells through Accessibility.
    static func moduleScript(_ name: String) -> Script? {
        if let s = API.focusObject?.script(named: name) { return s }
        if let pid = API.focusPid, let s = AppModuleHandler.shared.appModule(for: pid).script(named: name), s.isAvailable?() ?? true { return s }
        return nil
    }

    static func hasTable() -> Bool {
        moduleScript("table_nextColumn") != nil || VoiceOverKeysPlugin.tableCell() != nil
    }

    static func cells(_ row: AXUIElement) -> [AXUIElement] { row.elements(kAXChildrenAttribute).filter { $0.role == "AXCell" } }

    static func move(_ m: Move) {
        let word: String? = { switch m { case .column(let d): return d < 0 ? "table_previousColumn" : "table_nextColumn"; case .row(let d): return d < 0 ? "table_previousRow" : "table_nextRow"; default: return nil } }()
        if let n = word, let s = moduleScript(n), let g = KeyboardGesture(identifier: "kb:control+command+rightArrow") { s.handler(g); return }
        guard let (cell, table) = VoiceOverKeysPlugin.tableCell() else { Speech.speakMessage("not in a table"); return }
        let rows = table.elements(kAXRowsAttribute)
        guard let parent = cell.element(kAXParentAttribute), let r = rows.firstIndex(where: { $0.isSame(parent) }),
              let c = cells(rows[r]).firstIndex(where: { $0.isSame(cell) }) else { Speech.speakMessage("not in a table"); return }
        var (nr, nc) = (r, c)
        switch m {
        case .column(let d): nc += d
        case .row(let d): nr += d
        case .firstColumn: nc = 0
        case .lastColumn: nc = cells(rows[r]).count - 1
        case .firstRow: nr = 0
        case .lastRow: nr = rows.count - 1
        }
        guard rows.indices.contains(nr) else { Speech.speakMessage("edge of table"); return }
        let rowCells = cells(rows[nr])
        guard rowCells.indices.contains(nc) else { Speech.speakMessage("edge of table"); return }
        let target = rowCells[nc]
        if nr == r && nc == c { Speech.speakMessage("edge of table"); return }
        // Outside a page in browse mode, object navigation goes to the cell and reads it.
        guard inBuffer(target) else { ObjectNavigator.shared.moveTo(target); return }
        var parts: [String] = []
        if nc != c, let h = VoiceOverKeysPlugin.columnHeader(target, table), !h.isEmpty, nr != 0 { parts.append(h) }
        if nr != r, let h = VoiceOverKeysPlugin.rowHeader(target, table), !h.isEmpty, nc != 0, h != VoiceOverKeysPlugin.text(target) { parts.append(h) }
        let t = VoiceOverKeysPlugin.text(target)
        parts.append(t.isEmpty ? "blank" : t)
        if config.documentFormatting.tableCellCoordinates {
            if nr != r { parts.append("row \(nr + 1)") }
            if nc != c { parts.append("column \(nc + 1)") }
        }
        Speech.speakMessage(parts.joined(separator: ", "))
    }

    /// In a page in browse mode, the reading position goes to the cell (false: not in one).
    static func inBuffer(_ cell: AXUIElement) -> Bool {
        guard let d = API.focusTreeInterceptor, !d.passThrough else { return false }
        var e: AXUIElement? = cell; var depth = 0
        while let x = e, depth < 5 {
            if let at = d.buffer.offset(of: x) { d.position = at; return true }
            e = x.elements(kAXChildrenAttribute).first; depth += 1
        }
        return false
    }

    static func read(row: Bool, fromHere: Bool) {
        guard let (cell, table) = VoiceOverKeysPlugin.tableCell() else { Speech.speakMessage("not in a table"); return }
        let parts: [String]
        if row {
            parts = fromHere ? VoiceOverKeysPlugin.rowFromHere(cell) : VoiceOverKeysPlugin.rowCells(cell).map(VoiceOverKeysPlugin.text)
        } else if fromHere {
            parts = VoiceOverKeysPlugin.columnFromHere(cell, table)
        } else {
            // 200 rows at most: a long message list would hold the main thread (the code review, 12 Oct 2026).
            let rows = Array(table.elements(kAXRowsAttribute).prefix(200))
            let c = cell.element(kAXParentAttribute).flatMap { p in cells(p).firstIndex(where: { $0.isSame(cell) }) } ?? 0
            parts = rows.compactMap { r in let cs = cells(r); return cs.indices.contains(c) ? VoiceOverKeysPlugin.text(cs[c]) : nil }
        }
        Speech.speakText(parts.map { $0.isEmpty ? "blank" : $0 }.joined(separator: ", "))
    }
}

// MARK: - The mouse

enum NVDAMouse {
    nonisolated(unsafe) static var held: Set<Bool> = []   // true: the right button

    static func post(_ type: CGEventType, right: Bool) {
        let p = VoiceOverKeysPlugin.mouseLocation()
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: right ? .right : .left)?.post(tap: .cghidEventTap)
    }

    static func click(right: Bool) {
        Speech.speakMessage(right ? "right click" : "left click")
        post(right ? .rightMouseDown : .leftMouseDown, right: right)
        post(right ? .rightMouseUp : .leftMouseUp, right: right)
    }

    static func lock(right: Bool) {
        let side = right ? "right" : "left"
        if held.contains(right) {
            post(right ? .rightMouseUp : .leftMouseUp, right: right); held.remove(right)
            Speech.speakMessage("\(side) mouse button unlocked")
        } else {
            post(right ? .rightMouseDown : .leftMouseDown, right: right); held.insert(right)
            Speech.speakMessage("\(side) mouse button locked")
        }
    }
}

// MARK: - The synth settings ring

enum SynthRing {
    /// With Kokoro reading say all (the maintainer's Mac), its speed joins the ring.
    /// VoiceOver's ring (16 Oct 2026: the chord and what it turns must feel the same): pitch is in it.
    /// The last stop, "sync with VoiceOver" (16 Oct 2026): Up or Down there copies VoiceOver's settings.
    /// VoiceOver's order, as far as it is known (volume, rate, pitch, voice; 17 Oct 2026, to confirm by ear), then
    /// punctuation and the sync.
    static var settings: [String] { ["volume", "rate", "pitch", "voice", "punctuation"] + (KokoroVoice.available && KokoroVoice.mode != "off" ? ["Kokoro speed"] : []) + ["sync with VoiceOver"] }
    nonisolated(unsafe) static var index = 1

    static func value(_ s: String) -> String {
        switch s {
        case "voice": return AVSpeechSynthesisVoice(identifier: config.speech.voice)?.name ?? config.speech.voice
        case "rate": return "\(Int((config.speech.rate * 100).rounded()))"
        case "pitch": return "\(Int((config.speech.pitch * 100).rounded()))"
        case "volume": return "\(config.speech.volume)"
        case "Kokoro speed": return String(format: "%.1f", KokoroVoice.speed)
        case "sync with VoiceOver": return "up or down copies VoiceOver's voice, rate, pitch and volume"
        default: return config.speech.symbolLevel.name
        }
    }

    static func step(_ by: Int) {
        index = (index + by + settings.count) % settings.count
        Speech.speakMessage("\(settings[index]) \(value(settings[index]))")
    }

    static func voices() -> [AVSpeechSynthesisVoice] {
        let wanted = Set(Locale.preferredLanguages.map { String($0.prefix(2)) } + ["en"])
        let all = AVSpeechSynthesisVoice.speechVoices().filter { wanted.contains(String($0.language.prefix(2))) }.sorted { $0.name < $1.name }
        // Your own short list (Settings, Speech, Voices in the rotor), with the voice in use always among them.
        let chosen = Set(config.speech.rotorVoices)
        guard !chosen.isEmpty else { return all }
        let mine = all.filter { chosen.contains($0.identifier) || $0.identifier == config.speech.voice }
        return mine.isEmpty ? all : mine
    }

    /// One setting by name, for a VoiceOver command cloned from the export ("increase rate").
    static func change(_ setting: String, by: Int) {
        guard let i = settings.firstIndex(of: setting) else { return }
        let keep = index; index = i; change(by, large: false); index = keep
    }

    static func change(_ by: Int, large: Bool) {
        if index >= settings.count { index = 1 }   // the ring shrank (Kokoro switched off)
        let s = settings[index]
        // Rate, volume and pitch: VoiceOver's changed first and TurnOver takes its value (SpeechParity), so the two
        // readers stay in step whichever key was pressed. Large steps are four of VoiceOver's (0.2 = 4 × 5%).
        if SpeechParity.applies(s) {
            SpeechParity.step(s, by: by * (large ? 4 : 1)) { percent in
                guard let percent else { change(by, large: large, own: s); return }
                switch s {
                case "rate": config.speech.rate = min(1.0, max(0.1, Float(percent) / 100)); Speech.player.rate = config.speech.rate
                case "pitch": config.speech.pitch = min(1.0, max(0.0, Float(percent) / 100)); Speech.player.pitch = config.speech.pitchMultiplier
                default: config.speech.volume = min(200, max(10, percent)); Speech.player.volume = Float(config.speech.volume) / 100
                }
                config.save()
                Speech.speakMessage(value(s))
            }
            return
        }
        change(by, large: large, own: s)
    }

    /// TurnOver's own step (VoiceOver not paired for this setting, or it couldn't be changed).
    static func change(_ by: Int, large: Bool, own s: String) {
        switch s {
        case "voice":
            let all = voices()
            guard !all.isEmpty else { return }
            let i = all.firstIndex { $0.identifier == config.speech.voice } ?? 0
            let v = all[(i + by * (large ? 5 : 1) + all.count * 5) % all.count]
            config.speech.voice = v.identifier
            Speech.player.voiceIdentifier = v.identifier
            Languages.forget()
        case "rate":
            config.speech.rate = min(1.0, max(0.1, config.speech.rate + Float(by) * (large ? 0.2 : 0.05)))
            Speech.player.rate = config.speech.rate
        case "pitch":
            config.speech.pitch = min(1.0, max(0.0, config.speech.pitch + Float(by) * (large ? 0.2 : 0.05)))
            Speech.player.pitch = config.speech.pitchMultiplier
        case "volume":
            config.speech.volume = min(200, max(10, config.speech.volume + by * (large ? 30 : 10)))
            Speech.player.volume = Float(config.speech.volume) / 100
        case "sync with VoiceOver":
            VoiceOverSettings.startFlow()
            return
        case "Kokoro speed":
            KokoroVoice.speed = min(2.0, max(0.6, ((KokoroVoice.speed + Double(by) * (large ? 0.3 : 0.1)) * 10).rounded() / 10))
            KokoroVoice.preview(KokoroVoice.voice, text: String(format: "Kokoro speed %.1f.", KokoroVoice.speed))
            return
        default:
            let all = SymbolLevel.allCases
            let i = all.firstIndex(of: config.speech.symbolLevel) ?? 0
            config.speech.symbolLevel = all[min(all.count - 1, max(0, i + by))]
        }
        config.save()
        Speech.speakMessage(value(s))
    }
}
