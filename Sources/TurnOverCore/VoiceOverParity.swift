// SPDX-License-Identifier: GPL-3.0-or-later
// VoiceOver's own commands that TurnOver's Mac style lacked (12 Oct 2026: "this is all the voiceover stuff that
// should be in perfect parity"; Apple's VoiceOver User Guide, vo14111 and its seven command pages). The Mac style
// matches VoiceOver; where an NVDA command sat on a VoiceOver key, the Mac style now does VoiceOver's (the Windows style
// keeps NVDA's). Keys where a TurnOver-only command sits are not here: they are the maintainer's to decide
// (docs/VOICEOVER-PARITY.md).
import Foundation
import AppKit
import ApplicationServices

extension VoiceOverKeysPlugin {
    func addVoiceOverParity(_ add: (String, String, [String], @escaping (KeyboardGesture) -> Void) -> Void,
                            run: @escaping (String, KeyboardGesture) -> Void) {
        let count = { ScriptHandler.lastScriptRepeatCount }

        // MARK: Help (VO-H, VO-H-H, VO-Shift-F)
        add("helpMenu", "The help menu; pressed twice, the commands (VO-H, VO-H-H)", ["kb:turnover+h"]) { g in
            if count() > 0 { TurnOverMenu.shared.close(); GlobalCommands.openShortcutsList(); return }
            TurnOverMenu.shared.openList("Help", items: [
                MenuItem("Commands", .action { GlobalCommands.openShortcutsList() }),
                MenuItem("Keyboard help", .action { InputManager.toggleInputHelp() }),
                MenuItem("Find commands", .action { Self.findCommandsMenu() }),
            ])
        }
        add("findCommandsMenu", "The find commands: bold, headings, links… (VO-Shift-F)", ["kb:turnover+shift+f"]) { _ in Self.findCommandsMenu() }

        // MARK: Finding by kind on a page (VO-Command-letter): WebKit's own searches
        for (key, name, spoken, searchKey) in Self.webSearches {
            add("next\(name)", "Next \(spoken) (VO-Command-\(key.uppercased()))", ["kb:turnover+command+\(key)"]) { _ in Self.webSearch(searchKey, spoken, forward: true) }
            add("previous\(name)", "Previous \(spoken) (VO-Command-Shift-\(key.uppercased()))", ["kb:turnover+command+shift+\(key)"]) { _ in Self.webSearch(searchKey, spoken, forward: false) }
        }

        // MARK: Reading
        add("readToHere", "Reads from the beginning to here (VO-B)", ["kb:turnover+b"]) { _ in
            if let d = API.focusTreeInterceptor {
                let t = d.buffer.text.substring(to: min(d.position, d.buffer.text.length))
                Speech.speakText(t.isEmpty ? "blank" : t)
            } else if let obj = API.caretObject, let info = try? obj.makeTextInfo(.caret) {
                let all = info.copy(); all.expand(.story); all.setEndPoint(info, .endToStart)
                Speech.speakText(all.text.isEmpty ? "blank" : all.text)
            } else { Speech.speakMessage("not available here") }
        }
        add("nextParagraph", "Reads the next paragraph (VO-Shift-Page Down)", ["kb:turnover+shift+pageDown"]) { _ in Self.paragraph(forward: true) }
        add("previousParagraph", "Reads the previous paragraph (VO-Shift-Page Up)", ["kb:turnover+shift+pageUp"]) { _ in Self.paragraph(forward: false) }
        add("nextSentence", "Reads the next sentence (VO-Command-Page Down)", ["kb:turnover+command+pageDown"]) { _ in Self.sentence(forward: true) }
        add("previousSentence", "Reads the previous sentence (VO-Command-Page Up)", ["kb:turnover+command+pageUp"]) { _ in Self.sentence(forward: false) }
        add("word", "Reads the word; twice, spells it; three times, spells it phonetically (VO-W)", ["kb:turnover+w"]) { g in
            if count() >= 2, let w = Self.unitText(.word) { Speech.speakMessage(Self.phonetic(w)); return }
            run("reportCurrentWord", g)
        }
        add("line", "Reads the line (VO-L)", ["kb:turnover+l"]) { g in run("reportCurrentLine", g) }
        add("selectAllText", "Selects all the text in the VoiceOver cursor (VO-Shift-A)", ["kb:turnover+shift+a"]) { _ in
            guard let f = API.focusObject, f.hasNavigableText else { Speech.speakMessage("not in text"); return }
            KeyboardGesture(identifier: "kb:command+a")?.send()
            Speech.speakMessage("selected all")
        }
        add("additionalContent", "Reads additional content for the item (VO-Command-Slash)", ["kb:turnover+command+/"]) { _ in
            guard let e = Self.cursorElement() else { return }
            let extra = (e.attr("AXCustomContent") as? [Any] ?? []).compactMap { item -> String? in
                guard let d = item as? [String: Any] else { return nil }
                let label = d["label"] as? String ?? d["AXCustomContentLabel"] as? String ?? ""
                let value = d["value"] as? String ?? d["AXCustomContentValue"] as? String ?? ""
                return [label, value].filter { !$0.isEmpty }.joined(separator: ": ")
            }
            Speech.speakMessage(extra.isEmpty ? "no additional content" : extra.joined(separator: ". "))
        }

        // MARK: Tables (VO-R, VO-C, VO-Shift-T): in a table cell; VO-C elsewhere is the character
        add("rowHeader", "Reads the row header; twice, the row from here to its end (VO-R, VO-R-R)", ["kb:turnover+r"]) { _ in
            guard let (cell, table) = Self.tableCell() else { Speech.speakMessage("not in a table"); return }
            if count() > 0 { Speech.speakMessage(Self.rowFromHere(cell).joined(separator: ", ")); return }
            Speech.speakMessage(Self.rowHeader(cell, table) ?? "no row header")
        }
        add("columnHeaderOrCharacter", "In a table, the column header (twice, the column from here down); elsewhere the character (twice, phonetically) (VO-C, VO-C-C)", ["kb:turnover+c"]) { g in
            if let (cell, table) = Self.tableCell(), !(API.focusObject?.hasNavigableText ?? false) {
                if count() > 0 { Speech.speakMessage(Self.columnFromHere(cell, table).joined(separator: ", ")); return }
                Speech.speakMessage(Self.columnHeader(cell, table) ?? "no column header"); return
            }
            if count() > 0, let c = Self.unitText(.character) { Speech.speakMessage(Self.phonetic(c)); return }
            run("reportCurrentCharacter", g)
        }
        add("tablePosition", "Reads the row and column number; twice, how many rows and columns (VO-Shift-T, VO-Shift-T-T)", ["kb:turnover+shift+t"]) { _ in
            guard let (cell, table) = Self.tableCell() else { Speech.speakMessage("not in a table"); return }
            if count() > 0 {
                let rows = table.elements(kAXRowsAttribute).count, cols = table.elements(kAXColumnsAttribute).count
                Speech.speakMessage("\(rows) row\(rows == 1 ? "" : "s"), \(cols) column\(cols == 1 ? "" : "s")"); return
            }
            let r = Self.index(cell, "AXRowIndexRange").map { $0 + 1 }, c = Self.index(cell, "AXColumnIndexRange").map { $0 + 1 }
            Speech.speakMessage([r.map { "row \($0)" }, c.map { "column \($0)" }].compactMap { $0 }.joined(separator: ", "))
        }

        // MARK: Orientation (F-keys)
        add("describeOrWordAndCharacter", "The item's description; in text, the word and character; twice, how many lines (VO-F3, VO-F3-F3)", ["kb:turnover+f3"]) { g in
            if let f = API.focusObject, f.hasNavigableText {
                if count() > 0 { Speech.speakMessage(Self.lineCounts(f.element)); return }
                Speech.speakMessage([Self.unitText(.word), Self.unitText(.character).map { Symbols.name(of: Character($0.isEmpty ? " " : $0)) }].compactMap { $0 }.joined(separator: ", "))
                return
            }
            // Not text: the item in the VoiceOver cursor, as VoiceOver's VO-F3 (it described the keyboard focus).
            ObjectNavigator.shared.reportCurrent()
        }
        add("readContents", "Reads the VoiceOver cursor's contents: in text or a page, from the cursor on; elsewhere everything in the item (VO-A)", ["kb:turnover+a"]) { g in
            if API.focusTreeInterceptor.map({ !$0.passThrough }) ?? false || (API.focusObject?.hasNavigableText ?? false) { run("sayAll", g); return }
            ObjectNavigator.shared.readContents()
        }
        add("selectedItem", "Reads the selected item (VO-F6)", ["kb:turnover+f6"]) { g in
            if let f = API.focusObject, f.hasNavigableText { run("reportCurrentSelection", g); return }
            let rows = API.focusObject?.element.elements(kAXSelectedRowsAttribute) ?? []
            let kids = rows.isEmpty ? (API.focusObject?.element.elements(kAXSelectedChildrenAttribute) ?? []) : rows
            Speech.speakMessage(kids.isEmpty ? "nothing selected" : kids.prefix(10).map { ObjectFactory.make($0).name }.joined(separator: ", "))
        }
        add("windowGeometry", "The window's size and where it is on the screen (VO-Command-F2)", ["kb:turnover+command+f2"]) { _ in
            guard let w = Self.cursorElement()?.element(kAXWindowAttribute) ?? API.focusObject?.element.element(kAXWindowAttribute) else { Speech.speakMessage("no window"); return }
            Speech.speakMessage(Self.geometry(w, overlaps: count() > 0))
        }
        add("itemGeometry", "The item's size and where it is on the screen (VO-Command-F3)", ["kb:turnover+command+f3"]) { _ in
            guard let e = Self.cursorElement() else { return }
            Speech.speakMessage(Self.geometry(e, overlaps: count() > 0))
        }
        add("pointerItem", "The item under the mouse pointer; twice, where the pointer is on the screen; three times, in the window (VO-F5)", ["kb:turnover+f5"]) { _ in
            let p = Self.mouseLocation()
            switch count() {
            case 0:
                guard let e = Self.element(at: p) else { Speech.speakMessage("nothing under the pointer"); return }
                Speech.speakObject(ObjectFactory.make(e), reason: .focus)
            case 1: Speech.speakMessage("x \(Int(p.x)), y \(Int(p.y))")
            default:
                if let w = Self.element(at: p)?.element(kAXWindowAttribute), let o = TurnOverObject.frame(w)?.origin { Speech.speakMessage("x \(Int(p.x - o.x)), y \(Int(p.y - o.y)) in the window") }
                else { Speech.speakMessage("x \(Int(p.x)), y \(Int(p.y))") }
            }
        }
        add("cursorToMouse", "The VoiceOver cursor to the item under the mouse pointer (VO-Shift-F5)", ["kb:turnover+shift+f5"]) { _ in
            guard let e = Self.element(at: Self.mouseLocation()) else { Speech.speakMessage("nothing under the pointer"); return }
            ObjectNavigator.shared.moveTo(e)
        }
        add("mouseToCursor", "The mouse pointer to the VoiceOver cursor (VO-Command-F5)", ["kb:turnover+command+f5"]) { _ in
            guard let e = Self.cursorElement(), let r = TurnOverObject.frame(e) else { return }
            CGWarpMouseCursorPosition(CGPoint(x: r.midX, y: r.midY))
            Speech.speakMessage("mouse moved")
        }
        add("windowToFront", "Brings the VoiceOver cursor's window to the front (VO-Shift-F2)", ["kb:turnover+shift+f2"]) { _ in
            guard let e = Self.cursorElement(), let w = e.element(kAXWindowAttribute) else { Speech.speakMessage("no window"); return }
            _ = AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            NSRunningApplication(processIdentifier: e.pid)?.activate()
            Speech.speakMessage(w.string(kAXTitleAttribute) ?? "window")
        }
        add("saveLastPhrase", "Save the last phrase to the Desktop; saves the last spoken phrase, with TurnOver's log, to a file on the Desktop (VO-Shift-Z)", ["kb:turnover+shift+z"]) { _ in
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].appendingPathComponent("TurnOver last phrase.txt")
            try? (Speech.lastSpoken + "\n").write(to: desktop, atomically: true, encoding: .utf8)
            Speech.speakMessage("saved on the Desktop")
        }

        // MARK: Places: the desktop, Notification Centre, Control Centre, the parent folder, scroll bars, groups
        add("desktop", "Moves to the desktop (VO-Shift-D)", ["kb:turnover+shift+d"]) { _ in Self.goToDesktop() }
        add("notificationCentre", "Opens Notification Centre and goes to its first notification; again closes it (VO-O)", ["kb:turnover+o"]) { _ in NotificationCentrePanel.toggle() }
        add("controlCentre", "Opens or closes Control Centre (VO-Shift-O)", ["kb:turnover+shift+o"]) { _ in _ = Self.pressMenuExtra("com.apple.menuextra.controlcenter", "Control Centre") }
        add("parentFolder", "Jumps back to the parent folder (VO-Command-Backslash)", ["kb:turnover+command+\\"]) { _ in KeyboardGesture(identifier: "kb:command+upArrow")?.send() }
        add("scrollBars", "Scrolls the area the VoiceOver cursor is in: arrows, Page Up and Page Down, Shift Page Up and Down to the top and bottom; Escape stops (VO-Shift-S)", ["kb:turnover+shift+s"]) { _ in
            var p = Self.cursorElement(); var hops = 0
            while let x = p, hops < 10 {
                if x.role == "AXScrollArea", !x.elements(kAXChildrenAttribute).filter({ $0.role == "AXScrollBar" }).isEmpty { Self.scrollMode(x); return }
                p = x.element(kAXParentAttribute); hops += 1
            }
            Speech.speakMessage("no scroll bars")
        }
        add("nextGroup", "The next group, without going into it (VO-Shift-Right)", ["kb:turnover+shift+rightArrow"]) { _ in ObjectNavigator.shared.groupStep(forward: true) }
        add("previousGroup", "The previous group, without going into it (VO-Shift-Left)", ["kb:turnover+shift+leftArrow"]) { _ in ObjectNavigator.shared.groupStep(forward: false) }
        add("nextWindowSpot", "The next part of the window: sidebar, toolbar, content (VO-Right Bracket)", ["kb:turnover+]"]) { _ in Self.windowSpot(forward: true) }
        add("previousWindowSpot", "The previous part of the window (VO-Left Bracket)", ["kb:turnover+["]) { _ in Self.windowSpot(forward: false) }
        add("pageStatistics", "On a page, how many headings, links, tables…; in a table, the column's sort button (VO-Shift-Vertical Line)", ["kb:turnover+shift+\\"]) { _ in
            if let (cell, table) = Self.tableCell(), let sort = Self.sortButton(cell, table) { ObjectNavigator.shared.moveTo(sort); return }
            Speech.speakMessage(Self.pageStatistics() ?? "not on a page")
        }

        // MARK: Settings and modes
        add("screenCurtain", "Screen Curtain on or off (VO-Shift-F11)", ["kb:turnover+shift+f11"]) { g in run("screenCurtain", g) }
        add("describeImage", "Describes the image or photo (VO-Shift-L)", ["kb:turnover+shift+l"]) { _ in ImageDescriber.describeCurrent() }
    }

    // MARK: - Helpers

    /// Where the VoiceOver cursor is: the reading position on a page, else the review cursor, else the focus.
    static func cursorElement() -> AXUIElement? {
        if let d = API.focusTreeInterceptor, !d.passThrough, let e = (d.buffer.segment(at: d.position)?.element ?? d.buffer.lineIndex(at: d.position).flatMap { d.buffer.lines[$0].element }) { return e }
        return ObjectNavigator.shared.reviewElement ?? API.focusObject?.element
    }

    static func unitText(_ unit: TextUnit) -> String? {
        guard let obj = API.caretObject, let info = try? obj.makeTextInfo(.caret) else { return nil }
        info.expand(unit)
        let t = info.text.trimmingCharacters(in: .newlines)
        return t.isEmpty ? nil : t
    }

    static let alphabet: [Character: String] = [
        "a": "alpha", "b": "bravo", "c": "charlie", "d": "delta", "e": "echo", "f": "foxtrot", "g": "golf", "h": "hotel", "i": "india",
        "j": "juliet", "k": "kilo", "l": "lima", "m": "mike", "n": "november", "o": "oscar", "p": "papa", "q": "quebec", "r": "romeo",
        "s": "sierra", "t": "tango", "u": "uniform", "v": "victor", "w": "whiskey", "x": "x-ray", "y": "yankee", "z": "zulu",
    ]
    /// VoiceOver's phonetic spelling: "c, charlie".
    static func phonetic(_ text: String) -> String {
        text.prefix(60).map { c in
            let lower = Character(c.lowercased())
            let name = alphabet[lower].map { "\(c.isUppercase ? "cap " : "")\(c), \($0)" } ?? Symbols.name(of: c)
            return name
        }.joined(separator: "; ")
    }

    /// VoiceOver's VO-Shift-Page Down goes to the start of the next paragraph. The Mac's own Option-Down Arrow only goes
    /// to the end of this one, so the caret is placed through the text itself (as for sentences).
    static func paragraph(forward: Bool) {
        if API.focusTreeInterceptor != nil, let s = ScriptHandler.findScript(named: forward ? "moveByParagraph_forward" : "moveByParagraph_back"), let g = KeyboardGesture(identifier: "kb:option+\(forward ? "downArrow" : "upArrow")") { s.handler(g); return }
        guard let obj = API.caretObject, let info = try? obj.makeTextInfo(.caret) else { Speech.speakMessage("not in text"); return }
        // Blank lines between paragraphs are passed over, as VoiceOver does.
        var moved = false
        for _ in 0..<50 {
            guard info.move(.paragraph, forward ? 1 : -1) != 0 else { break }
            moved = true
            let probe = info.copy(); probe.expand(.paragraph)
            if !probe.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
        }
        guard moved else { Tones.edge(); return }
        info.updateCaret()
        info.expand(.paragraph)
        Speech.speakTextInfo(info, unit: .paragraph, reason: .caret)
    }

    static func sentence(forward: Bool) {
        if let d = API.focusTreeInterceptor { d.move(.sentence, forward ? 1 : -1); return }
        guard let obj = API.caretObject, let info = try? obj.makeTextInfo(.caret) else { Speech.speakMessage("not in text"); return }
        guard info.move(.sentence, forward ? 1 : -1) != 0 else { Tones.edge(); return }
        info.updateCaret()
        info.expand(.sentence)
        Speech.speakTextInfo(info, unit: .sentence, reason: .caret)
    }

    // MARK: Tables

    static func tableCell() -> (AXUIElement, AXUIElement)? {
        var p = cursorElement(); var hops = 0; var cell: AXUIElement?
        while let x = p, hops < 12 {
            if cell == nil, x.role == "AXCell" { cell = x }
            if let c = cell, ["AXTable", "AXGrid", "AXOutline"].contains(x.role) { return (c, x) }
            p = x.element(kAXParentAttribute); hops += 1
        }
        return nil
    }
    static func index(_ e: AXUIElement, _ attr: String) -> Int? {
        guard let v = e.attr(attr) else { return nil }
        var r = CFRange()
        guard CFGetTypeID(v) == AXValueGetTypeID(), axValue(v, .cfRange, &r) else { return nil }
        return r.location
    }
    static func text(_ e: AXUIElement) -> String {
        let t = ElementMatcher.text(of: e)
        return t.isEmpty ? ObjectFactory.make(e).name : t
    }
    static func rowCells(_ cell: AXUIElement) -> [AXUIElement] {
        (cell.element(kAXParentAttribute)?.elements(kAXChildrenAttribute) ?? []).filter { $0.role == "AXCell" }
    }
    static func rowHeader(_ cell: AXUIElement, _ table: AXUIElement) -> String? {
        let row = index(cell, "AXRowIndexRange")
        if let h = table.elements("AXRowHeaderUIElements").first(where: { index($0, "AXRowIndexRange") == row }) { return text(h) }
        return rowCells(cell).first.map(text).flatMap { $0.isEmpty ? nil : $0 }
    }
    static func columnHeader(_ cell: AXUIElement, _ table: AXUIElement) -> String? {
        guard let col = index(cell, "AXColumnIndexRange") else { return nil }
        if let h = table.elements("AXColumnHeaderUIElements").first(where: { index($0, "AXColumnIndexRange") == col }) { return text(h) }
        let first = table.elements(kAXRowsAttribute).first.map { ($0.elements(kAXChildrenAttribute)).filter { $0.role == "AXCell" } } ?? []
        return first.first { index($0, "AXColumnIndexRange") == col }.map(text)
    }
    static func rowFromHere(_ cell: AXUIElement) -> [String] {
        let cells = rowCells(cell)
        guard let i = cells.firstIndex(where: { $0.isSame(cell) }) else { return [text(cell)] }
        return cells[i...].map(text)
    }
    static func columnFromHere(_ cell: AXUIElement, _ table: AXUIElement) -> [String] {
        guard let col = index(cell, "AXColumnIndexRange"), let row = index(cell, "AXRowIndexRange") else { return [text(cell)] }
        return table.elements(kAXRowsAttribute).compactMap { r in
            r.elements(kAXChildrenAttribute).first { $0.role == "AXCell" && index($0, "AXColumnIndexRange") == col && (index($0, "AXRowIndexRange") ?? -1) >= row }
        }.map(text)
    }
    static func sortButton(_ cell: AXUIElement, _ table: AXUIElement) -> AXUIElement? {
        guard let col = index(cell, "AXColumnIndexRange"),
              let h = table.elements("AXColumnHeaderUIElements").first(where: { index($0, "AXColumnIndexRange") == col }) else { return nil }
        return h.role == "AXButton" ? h : h.elements(kAXChildrenAttribute).first { $0.role == "AXButton" }
    }

    // MARK: Geometry and the pointer

    static func geometry(_ e: AXUIElement, overlaps: Bool) -> String {
        guard let r = TurnOverObject.frame(e), let screen = NSScreen.screens.first?.frame else { return "unknown size" }
        if overlaps { return "left edge \(Int(r.minX)), top edge \(Int(r.minY)) from the top left of the screen" }
        let h = r.midX < screen.width / 3 ? "left" : r.midX > screen.width * 2 / 3 ? "right" : "centre"
        let v = r.midY < screen.height / 3 ? "top" : r.midY > screen.height * 2 / 3 ? "bottom" : "middle"
        return "\(Int(r.width)) by \(Int(r.height)) pixels, \(v == "middle" && h == "centre" ? "centre" : "\(v) \(h)") of the screen"
    }
    static func mouseLocation() -> CGPoint {
        let p = NSEvent.mouseLocation, h = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: h - p.y)   // AX's coordinates: from the top left
    }
    static func element(at p: CGPoint) -> AXUIElement? {
        var e: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &e) == .success else { return nil }
        return e
    }

    static func lineCounts(_ e: AXUIElement) -> String {
        let n = (e.attr(kAXNumberOfCharactersAttribute) as? Int) ?? 0
        let total = (e.param(kAXLineForIndexParameterizedAttribute, max(0, n - 1) as CFNumber) as? Int).map { $0 + 1 } ?? 0
        var visible = 0
        if let rv = e.attr(kAXVisibleCharacterRangeAttribute) {
            var r = CFRange(); axValue(rv, .cfRange, &r)
            let a = e.param(kAXLineForIndexParameterizedAttribute, r.location as CFNumber) as? Int ?? 0
            let b = e.param(kAXLineForIndexParameterizedAttribute, max(r.location, r.location + r.length - 1) as CFNumber) as? Int ?? a
            visible = b - a + 1
        }
        return "\(total) line\(total == 1 ? "" : "s"), \(visible) visible"
    }

    // MARK: Places

    /// Presses one of the system's menu bar items (the clock opens Notification Centre, the Control Centre item opens
    /// Control Centre). The item is looked for in the system processes that host such items, with the status menus
    /// list's unwrapping of the holder: until 23 Oct 2026 only Control Centre's own process was asked, which on
    /// macOS 27.2 hosts none of them, and every press said the panel was not available.
    /// Whether the item was found and pressed. A press that answers an error can still have opened the panel (a
    /// slow process), so the answer is logged and the press counts.
    @discardableResult
    static func pressMenuExtra(_ identifier: String, _ spoken: String) -> Bool {
        guard let extra = StatusMenus.find(identifier: identifier) else {
            Log.io("menu extra \(identifier): not found in any process")
            Speech.speakMessage("\(spoken) is not available")
            return false
        }
        let result = AXUIElementPerformAction(extra.element, kAXPressAction as CFString)
        Log.io("menu extra \(identifier): pressed in pid \(extra.pid) → \(result.rawValue)")
        return true
    }

    static func goToDesktop() {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return }
        finder.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let app = AXUIElementCreateApplication(finder.processIdentifier)
            guard let desk = app.elements(kAXWindowsAttribute).first(where: { $0.string(kAXSubroleAttribute) == "AXDesktop" }) ??
                    app.elements(kAXChildrenAttribute).first(where: { $0.string(kAXSubroleAttribute) == "AXDesktop" }) else { Speech.speakMessage("desktop"); return }
            var queue = [desk]; var n = 0
            while !queue.isEmpty, n < 300 {
                let e = queue.removeFirst(); n += 1
                if e.role == "AXImage" { _ = e.set(kAXFocusedAttribute, kCFBooleanTrue); ObjectNavigator.shared.moveTo(e); return }
                queue += e.elements(kAXChildrenAttribute)
            }
            Speech.speakMessage("desktop, empty")
        }
    }

    /// VoiceOver's window spots: the window's main parts in turn (its sidebar, toolbar, content), round.
    static func windowSpot(forward: Bool) {
        guard let e = cursorElement(), let w = e.role == "AXWindow" ? e : e.element(kAXWindowAttribute) else { Tones.edge(); return }
        let parts = w.elements(kAXChildrenAttribute).filter { !["AXButton", "AXStaticText", "AXImage"].contains($0.role) || $0.string(kAXSubroleAttribute) == nil }
            .filter { !["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"].contains($0.string(kAXSubroleAttribute) ?? "") }
        guard !parts.isEmpty else { Tones.edge(); return }
        var here = 0
        var p: AXUIElement? = e; var hops = 0
        while let x = p, hops < 30 { if let i = parts.firstIndex(where: { $0.isSame(x) }) { here = i; break }; p = x.element(kAXParentAttribute); hops += 1 }
        let next = parts[((here + (forward ? 1 : -1)) % parts.count + parts.count) % parts.count]
        ObjectNavigator.shared.moveTo(next)
    }

    static func pageStatistics() -> String? {
        guard let d = API.focusTreeInterceptor else { return nil }
        var counts: [String: Int] = [:]
        // A heading wrapped over three lines is one heading: the lines that end an element, not every line (code review, 16 Oct 2026).
        for (j, l) in d.buffer.lines.enumerated() where !d.buffer.lineContinues(j) { if let r = l.element?.role { counts[r, default: 0] += 1 } }
        let kinds: [(String, String)] = [("AXHeading", "heading"), ("AXLink", "link"), ("AXTable", "table"), ("AXList", "list"), ("AXImage", "image"),
                                         ("AXTextField", "text field"), ("AXButton", "button")]
        let parts = kinds.compactMap { k, w in counts[k].map { "\($0) \(w)\($0 == 1 ? "" : "s")" } }
        return parts.isEmpty ? "nothing to count" : parts.joined(separator: ", ")
    }

    // MARK: Finding by kind (WebKit's search keys, as VoiceOver uses them)

    static let webSearches: [(String, String, String, String)] = [
        ("b", "Bold", "bold text", "AXBoldFontSearchKey"), ("i", "Italic", "italic text", "AXItalicFontSearchKey"),
        ("u", "Underline", "underlined text", "AXUnderlineSearchKey"), ("k", "ColourChange", "colour change", "AXFontColorChangeSearchKey"),
        ("o", "FontChange", "font change", "AXFontChangeSearchKey"), ("p", "PlainText", "plain text", "AXPlainTextSearchKey"),
        ("v", "VisitedLink", "visited link", "AXVisitedLinkSearchKey"), ("q", "Blockquote", "blockquote", "AXBlockquoteSearchKey"),
        ("w", "BlockquoteSameLevel", "blockquote of the same level", "AXBlockquoteSameLevelSearchKey"),
        ("d", "DifferentItem", "different item", "AXDifferentTypeSearchKey"), ("s", "SameType", "item of the same type", "AXSameTypeSearchKey"),
        ("f", "Frame", "frame", "AXFrameSearchKey"),
    ]

    static func webSearch(_ key: String, _ spoken: String, forward: Bool) {
        guard let d = API.focusTreeInterceptor else {
            // A document (Word, TextEdit): bold, italic, underline, plain, colour and font are searched there too.
            if FormatSearch.find(key, spoken: spoken, forward: forward) { return }
            Speech.speakMessage(FormatSearch.kinds[key] == nil ? "only on web pages" : "not in a document"); return
        }
        d.searchKey(key, spoken: spoken, forward: forward)
    }

    static func findCommandsMenu() {
        let all: [(String, String)] = [("Heading", "heading"), ("Link", "link"), ("FormField", "control"), ("Table", "table"), ("List", "list"), ("Graphic", "graphic"),
                                       ("SpellingError", "misspelt word")] + webSearches.map { ($0.1, $0.2) }
        TurnOverMenu.shared.openList("Find", items: all.map { name, spoken in
            MenuItem("Next \(spoken)", .action {
                // The format searches are this plugin's own scripts, which findScript never reaches (12 of 19 items
                // did nothing: code review, 16 Oct 2026).
                let own = GlobalPluginHandler.shared.plugins.compactMap { $0 as? VoiceOverKeysPlugin }.first?.script(named: "vo_next\(name)")
                guard let s = own ?? ScriptHandler.findScript(named: "vo_next\(name)"), let g = KeyboardGesture(identifier: "kb:turnover+command+h") else { Speech.speakMessage("not available here"); return }
                s.handler(g)
            })
        })
    }
}

extension BrowseModeDocument {
    /// VoiceOver's find-by-kind on a page: WebKit's search key from where the reading is, then read it there.
    public func searchKey(_ key: String, spoken: String, forward: Bool) {
        guard ensureContent() else { return }
        if buffer.isDirty { buffer.build() }
        let from = lastQuickNavTarget ?? (buffer.segment(at: position)?.element ?? buffer.lineIndex(at: position).flatMap { buffer.lines[$0].element }) ?? bridge.webArea
        var found = bridge.search(key: key, from: from, forward: forward, limit: 1).first
        var at = found.flatMap { buffer.offset(of: $0) }
        // A run of styled text inside a paragraph: the buffer knows the paragraph.
        var hops = 0
        while at == nil, let f = found, hops < 4 { found = f.element(kAXParentAttribute); at = found.flatMap { buffer.offset(of: $0) }; hops += 1 }
        guard let el = found, let offset = at else { Tones.edge(); Speech.speakMessage(forward ? "no next \(spoken)" : "no previous \(spoken)"); return }
        position = offset
        lastQuickNavTarget = el
        speakQuickNavText(at: offset, link: el.role == "AXLink", element: el)
    }
}

// MARK: - Batch 2: modes and the mouse (12 Oct 2026)

extension VoiceOverKeysPlugin {
    func addVoiceOverParity2(_ add: (String, String, [String], @escaping (KeyboardGesture) -> Void) -> Void) {
        add("lockKey", "Locks or unlocks the VO keys: every key is a VO key until unlocked (VO-Semicolon)", ["kb:turnover+;"]) { _ in
            InputManager.turnOverKeyLocked.toggle()
            Speech.speakMessage(InputManager.turnOverKeyLocked ? "VO keys locked" : "VO keys unlocked")
        }
        add("cursorTracking", "Cursor tracking off or on for now: the VoiceOver cursor stays put as the focus moves (VO-Shift-F3)", ["kb:turnover+shift+f3"]) { _ in
            ObjectNavigator.shared.tracksFocus.toggle()
            Speech.speakMessage(ObjectNavigator.shared.tracksFocus ? "cursor tracking on" : "cursor tracking off")
        }
        add("moveWindow", "Moves the window with the arrow keys; Escape stops (VO-Grave Accent)", ["kb:turnover+`"]) { _ in Self.adjust(window: true, resize: false) }
        add("resizeWindow", "Resizes the window with the arrow keys; Escape stops (VO-Tilde)", ["kb:turnover+shift+`"]) { _ in Self.adjust(window: true, resize: true) }
        add("moveObject", "Moves the item with the arrow keys, where it can be moved; Escape stops (VO-Command-Grave Accent)", ["kb:turnover+command+`"]) { _ in Self.adjust(window: false, resize: false) }
        add("resizeObject", "Resizes the item with the arrow keys, where it can be; Escape stops (VO-Command-Tilde)", ["kb:turnover+command+shift+`"]) { _ in Self.adjust(window: false, resize: true) }
        add("multipleSelection", "Add to or remove from the selection; adds the item to the selection, or takes it out, keeping the others (VO-Command-Return)", ["kb:turnover+command+enter"]) { _ in Self.toggleInSelection() }
        add("stickyMouse", "Mouse button down at the VoiceOver cursor; again, up where the cursor is then: a drag (VO-Command-Shift-Space)", ["kb:turnover+command+shift+space"]) { _ in Self.stickyMouse() }
        add("createWindowSpot", "Makes the item a window spot of your own (VO-Command-Shift-Right Bracket)", ["kb:turnover+command+shift+]"]) { _ in Self.ownSpot(create: true) }
        add("removeWindowSpot", "Removes your window spot here (VO-Command-Shift-Left Bracket)", ["kb:turnover+command+shift+["]) { _ in Self.ownSpot(create: false) }
        add("nextOwnWindowSpot", "Your next window spot (VO-Command-Right Bracket)", ["kb:turnover+command+]"]) { _ in Self.cycleOwnSpot(forward: true) }
        add("previousOwnWindowSpot", "Your previous window spot (VO-Command-Left Bracket)", ["kb:turnover+command+["]) { _ in Self.cycleOwnSpot(forward: false) }
        add("arrowQuickNav", "Arrow-key Quick Nav on or off: Left and Right move the VoiceOver cursor, Up and Down the item above and below (VO-Shift-Q; Left and Right Arrow together)", ["kb:turnover+shift+q"]) { _ in
            ArrowQuickNav.toggle()
        }
        // The arrows alone, while Quick Nav is on: the keyboard handler holds each one until it is let go (or a second
        // arrow joins it, a chord) and hands it here, ArrowQuickNav.single. These scripts answer the same keys when
        // the handler didn't hold them (Quick Nav switched on between a press and its release).
        for key in ["leftArrow", "rightArrow", "upArrow", "downArrow"] {
            script("vo_quickNav_\(key)", "Quick Nav: the VoiceOver cursor (\(key))", gestures: ["kb:\(key)"], category: "VoiceOver keys") { _ in
                ArrowQuickNav.run(key)
            }.isAvailable = { ArrowQuickNav.isActiveHere }
        }
    }

    static var arrowQuickNav: Bool { ArrowQuickNav.on }
}

/// VoiceOver's arrow-key Quick Nav (the parity audit, 13 Oct 2026): Left and Right move the VoiceOver cursor; Up and
/// Down move by the Quick Nav rotor's kind (headings, links … on a page) or to the item above and below; two arrows
/// together are VoiceOver's chords:
///   Up and Down: the item's default action. Right and Down: interact. Left and Down: stop interacting.
///   Right and Up / Left and Up: the next / previous Quick Nav rotor kind. Left and Right: Quick Nav off.
/// On a web page it works in browse mode too (Left and Right by item, Up and Down by the rotor's kind), as VoiceOver
/// users use it most there; not while typing in a field.
public enum ArrowQuickNav {
    nonisolated(unsafe) static var on = false   // main thread only
    /// Read by the keyboard thread: whether the arrows are Quick Nav's at this moment (refreshed on the main thread).
    nonisolated public static let applies = Locked(false)
    private static var timer: Timer?
    /// The Quick Nav rotor's kind on pages: nil is item by item.
    private static var kind: Int?
    static let kinds = ["Heading", "Link", "Control", "Table", "List", "Landmark", "Graphic", "Button"]
    static let kindNames = ["Headings", "Links", "Form controls", "Tables", "Lists", "Landmarks", "Images", "Buttons"]

    /// On is on everywhere, as VoiceOver's: in a text field too the arrows are Quick Nav's until it is turned off
    /// (it stood aside in text, so Quick Nav "didn't work" in Claude's prompt, 17 Oct 2026).
    static var isActiveHere: Bool { on && config.general.macKeys }

    /// VoiceOver's own arrow Quick Nav, as far as TurnOver knows (nil: not known). Coexisting, VoiceOver runs all the
    /// time and its Quick Nav took the arrows TurnOver passed to its apps: every list in TurnOver's apps went dead,
    /// silently, since VoiceOver is quiet there (19 Oct 2026; the Activity that used to keep it off is gone).
    /// So the two are kept in step: one Quick Nav, on or off in every app. The keyboard thread reads this to send the
    /// arrows it passes to the app alone while VoiceOver's may be on (KeyboardHandler).
    nonisolated public static let voiceOverMayBeOn = Locked(true)
    nonisolated(unsafe) static var voiceOverOn: Bool? { didSet { voiceOverMayBeOn.value = voiceOverOn ?? true } }   // main thread only

    /// The Quick Nav setting VoiceOver keeps (its own default profile), read at start where TurnOver may read
    /// VoiceOver's settings (Full Disk Access): TurnOver's starts the same. Elsewhere VoiceOver's is taken to be TurnOver's.
    public static func startInStep() {
        guard Coexist.on else { return }
        if let vo = VoiceOverSettings.arrowQuickNav() {
            voiceOverOn = vo
            Log.info("Quick Nav: VoiceOver's is \(vo ? "on" : "off"); TurnOver's the same")
            if vo != on { set(vo, sound: false) }
        } else {
            voiceOverOn = nil
            Log.info("Quick Nav: VoiceOver's setting can't be read; the arrows TurnOver passes go to the app alone")
        }
    }

    /// Left and Right pressed together in one of VoiceOver's apps (QuickNavWatch): VoiceOver's turned over, and
    /// TurnOver's follows it, quietly (VoiceOver plays its own sound there).
    public static func voiceOverToggled() {
        let vo = !(voiceOverOn ?? on)
        voiceOverOn = vo
        Log.io("Quick Nav: VoiceOver's \(vo ? "on" : "off") in its app; TurnOver's the same")
        if vo != on { set(vo, sound: false) }
    }

    static func toggle() {
        set(!on, sound: true)
        // In a document the chord is also the way between browse mode and focus mode (VoiceOver has no focus mode:
        // Quick Nav off is when the arrows go to the page). Quick Nav off: focus mode, kept until the focus leaves, as
        // NVDA's by-hand switch is; on: browse mode. The VoiceOver keys had no deliberate way into focus mode, since
        // TurnOver Space is VO-Space there (a contributor, 21 Oct 2026). The Quick Nav sound says enough.
        if config.general.macKeys, let d = API.focusTreeInterceptor {
            d.disableAutoPassThrough = !on
            d.setPassThrough(!on, announce: false)
        }
        // VoiceOver's follows: its own chord, posted where VoiceOver hears it. Only when it differs, so two out of step
        // come back into step. (Tried on 17 Oct 2026 and undone, because VoiceOver's Quick Nav then took the arrows
        // TurnOver passed to its apps; those now go to the app alone, so it can be on.)
        guard Coexist.on, !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.VoiceOver").isEmpty,
              voiceOverOn != on else { return }
        voiceOverOn = on
        Log.io("Quick Nav: VoiceOver's turned \(on ? "on" : "off") with TurnOver's")
        let post = KeyboardGesture.chordPoster
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15) { post?([123, 124]) }
    }

    private static func set(_ value: Bool, sound: Bool) {
        on = value
        timer?.invalidate(); timer = nil
        if on {
            // Kept current four times a second while on, for the keyboard thread (focus and browse mode change often).
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in MainActor.assumeIsolated { applies.value = isActiveHere } }
        }
        applies.value = isActiveHere
        guard sound else { return }
        if !VoiceOverSounds.play(on ? "QuickNavArrowKeyOn.wav" : "QuickNavArrowKeyOff.wav") { Speech.speakMessage(on ? "Quick Nav on" : "Quick Nav off") }
    }

    /// Left and Right together with Quick Nav off (the keyboard handler): on, as VoiceOver's chord does. The first
    /// arrow already went to the app as usual; only the second is taken.
    public static func turnOnFromChord() {
        // Quick Nav on but not applying here (a text field): the chord still toggles, as VoiceOver's does; it was
        // ignored, and the chord did nothing in Claude's prompt (17 Oct 2026).
        guard config.general.macKeys else { return }
        toggle()
    }

    /// One arrow, let go without another joining it. Not Quick Nav's here after all: the key goes to the app.
    public static func single(_ key: String) {
        guard isActiveHere else { KeyboardGesture(identifier: "kb:\(key)")?.send(); return }
        run(key)
    }

    static func run(_ key: String) {
        if let d = API.focusTreeInterceptor, !d.passThrough {
            switch key {
            case "leftArrow": d.move(.line, -1)
            case "rightArrow": d.move(.line, 1)
            default:
                let down = key == "downArrow"
                if let k = kind, let q = BrowseModeDocument.voiceOverQuickNav.first(where: { $0.name == kinds[k] }) { d.quickNav(q, forward: down) }
                else { d.move(.line, down ? 1 : -1) }
            }
            return
        }
        switch key {
        case "leftArrow": ObjectNavigator.shared.previous()
        case "rightArrow": ObjectNavigator.shared.next()
        case "upArrow": ObjectNavigator.shared.verticalStep(down: false)
        default: ObjectNavigator.shared.verticalStep(down: true)
        }
    }

    /// Two arrows pressed together, in either order.
    public static func chord(_ a: String, _ b: String) {
        let pair = Set([a, b])
        Log.io("Quick Nav chord: \(pair.sorted().joined(separator: " and "))")
        let page = API.focusTreeInterceptor.flatMap { $0.passThrough ? nil : $0 }
        switch pair {
        case ["upArrow", "downArrow"]:
            if let page, let enter = KeyboardGesture(identifier: "kb:enter") { page.activate(enter) } else { ObjectNavigator.shared.activate() }
        case ["rightArrow", "downArrow"]: ObjectNavigator.shared.interact()
        case ["leftArrow", "downArrow"]: ObjectNavigator.shared.stopInteracting()
        case ["rightArrow", "upArrow"], ["leftArrow", "upArrow"]:
            guard page != nil else { Speech.speakMessage("no Quick Nav kinds here"); return }
            let forward = pair.contains("rightArrow")
            let n = kinds.count + 1   // and "item by item"
            let at = (kind.map { $0 + 1 } ?? 0)
            let next = (at + (forward ? 1 : n - 1)) % n
            kind = next == 0 ? nil : next - 1
            Speech.speakMessage(kind.map { kindNames[$0] } ?? "Items")
        case ["leftArrow", "rightArrow"]: toggle()
        default: break
        }
    }
}

extension VoiceOverKeysPlugin {
    /// Move or resize the window (or the item) with the arrows, 10 points a press (Shift: 1); Escape or Return ends.
    static func adjust(window: Bool, resize: Bool) {
        guard let e = cursorElement() else { return }
        let target = window ? (e.role == "AXWindow" ? e : e.element(kAXWindowAttribute)) : e
        guard let t = target else { Speech.speakMessage("no window"); return }
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(t, (resize ? kAXSizeAttribute : kAXPositionAttribute) as CFString, &settable)
        guard settable.boolValue else { Speech.speakMessage(resize ? "can't be resized" : "can't be moved"); return }
        Speech.speakMessage("\(resize ? "resizing" : "moving") \(window ? "the window" : "the item"). Arrows, Shift for small steps. Escape stops")
        func next() {
            InputManager.captureNext = { g in
                guard let g, !["enter", "numpadEnter"].contains(g.keyName) else { Speech.speakMessage("done"); return }
                let step: CGFloat = g.modifiers.contains(.shift) ? 1 : 10
                var dx: CGFloat = 0, dy: CGFloat = 0
                switch g.keyName { case "leftArrow": dx = -step; case "rightArrow": dx = step; case "upArrow": dy = -step; case "downArrow": dy = step; default: Tones.edge(); next(); return }
                if let r = TurnOverObject.frame(t) {
                    if resize { var s = CGSize(width: max(50, r.width + dx), height: max(50, r.height + dy)); if let v = AXValueCreate(.cgSize, &s) { _ = t.set(kAXSizeAttribute, v) } }
                    else { var p = CGPoint(x: r.minX + dx, y: r.minY + dy); if let v = AXValueCreate(.cgPoint, &p) { _ = t.set(kAXPositionAttribute, v) } }
                    if let n = TurnOverObject.frame(t) { Speech.speakMessage(resize ? "\(Int(n.width)) by \(Int(n.height))" : "\(Int(n.minX)), \(Int(n.minY))") }
                }
                next()
            }
        }
        next()
    }

    static func toggleInSelection() {
        guard let e = cursorElement() else { return }
        var p: AXUIElement? = e; var row: AXUIElement?; var hops = 0
        while let x = p, hops < 6 { if ["AXRow", "AXOutlineRow"].contains(x.role) || x.string(kAXSubroleAttribute) == "AXOutlineRow" { row = x; break }; p = x.element(kAXParentAttribute); hops += 1 }
        guard let r = row, let list = r.element(kAXParentAttribute) else { Speech.speakMessage("not in a list"); return }
        var sel = list.elements(kAXSelectedRowsAttribute)
        let was = sel.contains { $0.isSame(r) }
        if was { sel.removeAll { $0.isSame(r) } } else { sel.append(r) }
        guard list.set(kAXSelectedRowsAttribute, sel as CFArray) == .success else { Speech.speakMessage("this list takes one selection only"); return }
        Speech.speakMessage("\(was ? "deselected" : "selected"), \(sel.count) selected")
    }

    nonisolated(unsafe) static var mouseIsDown = false   // main thread only
    static func stickyMouse() {
        guard let e = cursorElement(), let r = TurnOverObject.frame(e) else { return }
        let p = CGPoint(x: r.midX, y: r.midY)
        let type: CGEventType = mouseIsDown ? .leftMouseUp : .leftMouseDown
        if mouseIsDown { CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap) }
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        mouseIsDown.toggle()
        Speech.speakMessage(mouseIsDown ? "mouse down" : "mouse up")
    }

    /// Your own window spots, per app and window title (VoiceOver keeps them per window too).
    nonisolated(unsafe) static var ownSpots: [String: [AXUIElement]] = [:]   // main thread only
    static func spotKey(_ e: AXUIElement) -> String {
        let app = NSRunningApplication(processIdentifier: e.pid)?.bundleIdentifier ?? "\(e.pid)"
        return app + "|" + (e.element(kAXWindowAttribute)?.string(kAXTitleAttribute) ?? "")
    }
    static func ownSpot(create: Bool) {
        guard let e = cursorElement() else { return }
        let k = spotKey(e)
        var list = ownSpots[k] ?? []
        if create { if !list.contains(where: { $0.isSame(e) }) { list.append(e) }; Speech.speakMessage("window spot \(list.count) made") }
        else if let i = list.firstIndex(where: { $0.isSame(e) }) { list.remove(at: i); Speech.speakMessage("window spot removed") }
        else { Speech.speakMessage("no window spot here") }
        ownSpots[k] = list
    }
    static func cycleOwnSpot(forward: Bool) {
        guard let e = cursorElement() else { return }
        let list = (ownSpots[spotKey(e)] ?? []).filter { $0.role != "?" }
        guard !list.isEmpty else { Speech.speakMessage("no window spots of your own"); return }
        let here = list.firstIndex { $0.isSame(e) }
        let i = here.map { (($0 + (forward ? 1 : -1)) % list.count + list.count) % list.count } ?? (forward ? 0 : list.count - 1)
        ObjectNavigator.shared.moveTo(list[i])
    }
}
