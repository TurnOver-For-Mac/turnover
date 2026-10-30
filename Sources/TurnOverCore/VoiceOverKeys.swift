// SPDX-License-Identifier: GPL-3.0-or-later
// The Mac keyboard style: VoiceOver's own commands on the TurnOver key, so VO-M is
// the menu bar and VO-D the Dock whether the TurnOver key is Caps Lock or
// Control+Option. Listed in reference/apple-docs/voiceover-commands.md, from
// Apple's VoiceOver User Guide. A global plugin, so in Mac style these come
// before the NVDA-style bindings they share keys with (VO-P is a paragraph here,
// not the symbol level). Off in the Windows style.
import Foundation
import AppKit
import ApplicationServices

public final class VoiceOverKeysPlugin: GlobalPlugin {
    /// The keyboard is in a document or a text area, and the VoiceOver cursor with it.
    static func inTextArea() -> Bool {
        guard let f = API.focusObject, f.hasNavigableText, f.role == .document || f.element.role == "AXTextArea",
              ObjectNavigator.shared.isWithin(f.element), !ObjectNavigator.shared.landedByStep else { return false }
        // An empty box (Shortcuts' prompt, as it opens) has no characters to move by: VO-Left and VO-Right go on by
        // item, as VoiceOver's do (the regression pass, 12 Oct 2026: only the edge sound, and no way out).
        if (f.element.attr(kAXNumberOfCharactersAttribute) as? Int ?? 1) == 0 { return false }
        return true
    }

    public required init() {
        super.init()
        let cat = "VoiceOver keys"
        let on: () -> Bool = { config.general.macKeys }
        func add(_ name: String, _ description: String, _ gestures: [String], _ run: @escaping (KeyboardGesture) -> Void) {
            script("vo_\(name)", description, gestures: gestures, category: cat, run).isAvailable = on
        }
        /// Run another command by name, or say why not.
        func run(_ name: String, _ g: KeyboardGesture, otherwise: String = String(localized: "not available here", comment: "Spoken message")) {
            if let s = ScriptHandler.findScript(named: name) { s.handler(g) } else { Speech.speakMessage(otherwise) }
        }
        /// VO-Command-letter: the next or previous heading, link, control… VoiceOver finds them anywhere, not only
        /// while reading a page (7 Oct 2026: VO Command Shift H said "not in a document" in Claude's prompt).
        /// A document's own (browse mode, Word), even while its keys go to the page; else through the window.
        let windowRoles: [String: Set<String>] = [
            "Heading": ["AXHeading"], "Link": ["AXLink"], "Table": ["AXTable", "AXGrid"], "List": ["AXList", "AXOutline"], "Graphic": ["AXImage"],
            "FormField": ["AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXSlider", "AXButton", "AXMenuButton", "AXSearchField"],
        ]
        func find(_ name: String, _ spoken: String, forward: Bool, _ g: KeyboardGesture) {
            let scriptName = (forward ? "next" : "previous") + name
            if let s = ScriptHandler.findScript(named: scriptName) { s.handler(g); return }
            // The keys were going to the page (focus mode, Claude's prompt): move to the heading, and read on from it.
            if let d = API.focusTreeInterceptor, let s = d.script(named: scriptName) {
                if d.passThrough { d.setPassThrough(false, announce: false) }
                s.handler(g); return
            }
            if let roles = windowRoles[name] { ObjectNavigator.shared.findInWindow(roles: roles, forward: forward, kind: spoken); return }
            Speech.speakMessage(String(localized: "not in a document", comment: "Spoken message"))
        }

        add("menuBar", String(localized: "The application's menus (VO-M); pressed twice, the status menus (VO-M-M)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+m"]) { _ in
            if ScriptHandler.lastScriptRepeatCount > 0 {
                for m in AXHandler.shared.openMenus.reversed() { _ = AXUIElementPerformAction(m, kAXCancelAction as CFString) }
                AXHandler.shared.menusClosed()
                if config.general.windowsKeys { StatusMenus.openList() } else { MenuNavigationPlugin.holdStatusItems() }
            } else {
                GlobalCommands.toggleMenus()
            }
        }
        add("dock", String(localized: "The Dock (VO-D)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+d"]) { _ in KeyboardGesture(identifier: "kb:control+f3")?.send() }
        add("shortcutMenu", String(localized: "The shortcut menu for the item (VO-Shift-M)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+shift+m"]) { _ in if GlobalCommands.openContextMenu() { return }; if SpellingCorrections.offer() { return }; if GlobalCommands.contextMenuAtCaret() { return }; _ = GlobalCommands.contextMenuForItem() }
        add("keyboardHelp", String(localized: "Keyboard help: every key says what it does (VO-K)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+k"]) { _ in InputManager.toggleInputHelp() }
        // VO-H (the commands list) is left out: TurnOver+H is Word's next heading, and TurnOver+slash lists the
        // shortcuts everywhere (4 Oct 2026).
        add("paragraph", String(localized: "Reads the paragraph (VO-P)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+p"]) { g in run("reportCurrentParagraph", g) }
        add("sentence", String(localized: "Reads the sentence (VO-S)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+s"]) { g in run("reportCurrentSentence", g) }
        add("attributes", String(localized: "Reads the text attributes (VO-T)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+t"]) { g in run("reportFormatting", g) }
        add("repeatLast", String(localized: "Repeats the last thing spoken (VO-Z)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+z"]) { _ in
            let t = Speech.lastRaw.isEmpty ? Speech.lastSpoken : Speech.lastRaw
            if t.isEmpty { Speech.speakMessage(String(localized: "nothing spoken yet", comment: "Spoken message"), remember: false) } else { Speech.speakText(t) }
        }
        add("copyLast", String(localized: "Copies the last thing spoken (VO-Shift-C)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+shift+c"]) { _ in Speech.copyLastSpoken() }
        add("appSummary", String(localized: "Says the application and its windows; pressed twice, the application chooser (VO-F1, VO-F1-F1)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+f1"]) { _ in
            if ScriptHandler.lastScriptRepeatCount > 0 { DispatchQueue.main.async { ApplicationChooser.open() }; return }
            guard let pid = API.focusPid, let app = NSRunningApplication(processIdentifier: pid) else { return }
            let windows = AXUIElementCreateApplication(pid).elements(kAXWindowsAttribute).filter { $0.string(kAXSubroleAttribute) == "AXStandardWindow" }
            // With its plugins, so you always know what's working in it (the plugin design notes 13).
            let plugins = ProfilesPlugin.pluginNames(for: app.bundleIdentifier ?? "")
            // Big Picture's process is "Steam Helper"; to the person it is Steam (a tester, 16 Oct 2026).
            let name = app.bundleIdentifier == Games.steamHelperBundle ? "Steam" : (app.localizedName ?? Role.application.displayString)
            let count = windows.count == 1 ? String(localized: "\(name), 1 window", comment: "An application and how many windows it has")
                : String(localized: "\(name), \(String(windows.count)) windows", comment: "An application and how many windows it has")
            Speech.speakMessage(count + (plugins.isEmpty ? "" : String(localized: ", plugins: \(plugins.joined(separator: ", "))", comment: "The plugins an app has, after its name")))
        }
        add("windowSummary", String(localized: "Says the window's title; pressed twice, the window chooser (VO-F2, VO-F2-F2)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+f2"]) { g in
            guard ScriptHandler.lastScriptRepeatCount > 0 else { run("title", g); return }
            Self.windowChooser()
        }
        add("describeItem", String(localized: "Describes the item with keyboard focus; twice, more about it (in text, where the insertion point is) (VO-F4, VO-F4-F4)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+f4"]) { g in
            if ScriptHandler.lastScriptRepeatCount > 0 { Self.focusDetails(); return }
            run("reportCurrentFocus", g)
        }
        add("dateTime", String(localized: "The date and time; twice, the battery; three times, the network (VO-F7, VO-F7-F7, VO-F7-F7-F7)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+f7"]) { g in
            if ScriptHandler.lastScriptRepeatCount > 1 { Self.networkStatus(); return }
            if ScriptHandler.lastScriptRepeatCount > 0 { Speech.speakMessage(GlobalCommands.batteryText()); return }
            let f = DateFormatter(); f.dateStyle = .full; f.timeStyle = .short
            Speech.speakMessage(f.string(from: Date()))
        }
        add("rotor", String(localized: "The rotor: headings, links, form controls, landmarks… Left and Right change kind (VO-U)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+u"]) { g in
            if let s = ScriptHandler.findScript(named: "elementsList") { s.handler(g) } else { ItemChooser.openRotor() }
        }
        add("itemChooser", String(localized: "Everything in the window or page, narrowed as you type; Enter goes there (VO-I)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+i"]) { _ in
            ItemChooser.open()
        }
        add("quickNav", String(localized: "Browse mode on or off: single-letter navigation (VO-Q)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+q"]) { g in
            if API.focusTreeInterceptor != nil { run("toggleVirtualBufferPassThrough", g, otherwise: String(localized: "not in a document", comment: "Spoken message")) }
            else { ArrowQuickNav.toggle() }   // outside a document VoiceOver's Quick Nav toggles all the same (the code review, 17 Oct 2026)
        }
        add("defaultAction", String(localized: "Activates the item under the VoiceOver cursor (VO-Space)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+space"]) { g in
            // By accessibility's press, as VoiceOver's VO-Space is: a page that ignores the real key (Squarespace's
            // switches are links styled as switches; Space scrolls, Enter and a click work, 25 Oct 2026) still answers
            // the press. Enter and Space themselves go to the page as real keys (activatePosition).
            if let d = API.focusTreeInterceptor, !d.passThrough { d.activate(g, byAccessibility: true); return }
            ObjectNavigator.shared.activate()
        }
        // The VoiceOver cursor: TurnOver's object navigation. In a page in browse mode, the next and previous line; in
        // a document or text area with the cursor in it (Word's page, TextEdit), the next and previous character, as
        // VoiceOver (VO-Left went out to Word's sidebar, 7 Oct 2026).
        // A table's own moves (Word's cells): the focused object's, or the application module's, which finds the
        // cell from the live caret (Word keeps its focus on the page while the caret is in a table, so the object
        // was the page and VO Down moved by line, a tester, 8 Oct 2026).
        func tableScript(_ name: String) -> Script? {
            if let s = API.focusObject?.script(named: name) { return s }
            if let pid = API.focusPid, let s = AppModuleHandler.shared.appModule(for: pid).script(named: name), s.isAvailable?() ?? true { return s }
            return nil
        }
        add("next", String(localized: "Next item (VO-Right)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+rightArrow"]) { g in
            if let s = tableScript("table_nextColumn") { s.handler(g); return }   // Word: the next cell in the row
            if let d = API.focusTreeInterceptor, !d.passThrough, ObjectNavigator.shared.isWithin(d.webArea), let s = d.script(named: "moveByLine_forward") { s.handler(g); return }
            // At the end of the text, VO-Right leaves the field for the next item, as VoiceOver's cursor does (it bumped
            // for 300 ms at the end of Claude's prompt, 17 Oct 2026).
            if Self.inTextArea(), let f = API.focusObject, let s = f.script(named: "caret_moveByCharacter") {
                if let i = try? f.makeTextInfo(.caret), i.storyLength() > 0, i.start >= i.storyLength() { Log.io("VO-Right at the end of the text: the next item") }
                else { s.handler(KeyboardGesture(identifier: "kb:rightArrow")!); return }
            }
            if config.general.navigateByGroups { ObjectNavigator.shared.groupStep(forward: true) } else { ObjectNavigator.shared.next() }
        }
        add("previous", String(localized: "Previous item (VO-Left)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+leftArrow"]) { g in
            if let s = tableScript("table_previousColumn") { s.handler(g); return }
            if let d = API.focusTreeInterceptor, !d.passThrough, ObjectNavigator.shared.isWithin(d.webArea), let s = d.script(named: "moveByLine_back") { s.handler(g); return }
            if Self.inTextArea(), let f = API.focusObject, let s = f.script(named: "caret_moveByCharacter") {
                if let i = try? f.makeTextInfo(.caret), i.start <= 0 { Log.io("VO-Left at the start of the text: the previous item") }
                else { s.handler(KeyboardGesture(identifier: "kb:leftArrow")!); return }
            }
            if config.general.navigateByGroups { ObjectNavigator.shared.groupStep(forward: false) } else { ObjectNavigator.shared.previous() }
        }
        // An application's own interact first (Pages: into the table on the caret's line, 17 Oct 2026).
        func appInteract(_ name: String) -> Script? {
            guard let pid = API.focusPid, let s = AppModuleHandler.shared.appModule(for: pid).script(named: name), s.isAvailable?() ?? true else { return nil }
            return s
        }
        add("interact", String(localized: "Into the item: its first part (VO-Shift-Down)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+shift+downArrow"]) { g in
            if let s = appInteract("app_interact") { s.handler(g); return }
            if config.general.navigateByGroups { ObjectNavigator.shared.interact() } else { ObjectNavigator.shared.firstChild() }
        }
        add("stopInteracting", String(localized: "Out of the item: what holds it (VO-Shift-Up)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+shift+upArrow"]) { g in
            if let s = appInteract("app_stopInteracting") { s.handler(g); return }
            if config.general.navigateByGroups { ObjectNavigator.shared.stopInteracting() } else { ObjectNavigator.shared.parent() }
        }
        // VO-Up and VO-Down: the previous and next line in text or a page; elsewhere the item above or below.
        for (name, down) in [("up", false), ("down", true)] {
            add(name, down ? String(localized: "Next line in text; elsewhere the item below (VO-Down)", comment: "A command, as the key list and keyboard help say it")
                           : String(localized: "Previous line in text; elsewhere the item above (VO-Up)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+\(name)Arrow"]) { g in
                // Word: the cell below or above, as VO-Right goes to the next cell (VO-Down left the table, 7 Oct 2026).
                if let s = tableScript(down ? "table_nextRow" : "table_previousRow") { s.handler(g); return }
                // Terminal: the lines of output, as VoiceOver reads the screen (VO-Up landed on the window, 8 Oct 2026).
                if let s = API.focusObject?.script(named: down ? "terminal_reviewNext" : "terminal_reviewPrevious") { s.handler(g); return }
                let key = KeyboardGesture(identifier: down ? "kb:downArrow" : "kb:upArrow")!
                if let d = API.focusTreeInterceptor, !d.passThrough, ObjectNavigator.shared.isWithin(d.webArea), let s = d.script(named: down ? "moveByLine_forward" : "moveByLine_back") { s.handler(key); return }
                if let f = API.focusObject, f.hasNavigableText, ObjectNavigator.shared.isWithin(f.element), let s = f.script(named: "caret_moveByLine") { s.handler(key); return }
                ObjectNavigator.shared.verticalStep(down: down)
            }
        }
        // In text, VoiceOver's text commands: VO-Home and VO-End the start and end of the text, VO-Shift-Home and
        // VO-Shift-End the first and last word in view; on a page, its top and bottom; elsewhere the group's first and
        // last item (the parity audit, 13 Oct 2026: in text they went to the group's items).
        for (key, last, visible) in [("home", false, false), ("end", true, false), ("shift+home", false, true), ("shift+end", true, true)] {
            add(visible ? (last ? "lastVisibleWord" : "firstVisibleWord") : (last ? "groupEnd" : "groupStart"),
                visible ? (last ? String(localized: "In text, the last word in view; elsewhere the last item in the group (VO-Shift-End)", comment: "A command, as the key list and keyboard help say it")
                                : String(localized: "In text, the first word in view; elsewhere the first item in the group (VO-Shift-Home)", comment: "A command, as the key list and keyboard help say it"))
                        : (last ? String(localized: "In text, the end of the text; elsewhere the last item in the group (VO-End)", comment: "A command, as the key list and keyboard help say it")
                                : String(localized: "In text, the start of the text; elsewhere the first item in the group (VO-Home)", comment: "A command, as the key list and keyboard help say it")),
                ["kb:turnover+\(key)"]) { g in
                if let d = API.focusTreeInterceptor, !d.passThrough, ObjectNavigator.shared.isWithin(d.webArea),
                   let s = d.script(named: last ? "bottomOfDocument" : "topOfDocument") { s.handler(g); return }
                if Self.inTextArea() || (API.focusObject?.hasNavigableText ?? false), let f = API.focusObject, ObjectNavigator.shared.isWithin(f.element) {
                    Self.textEdge(f, last: last, visible: visible); return
                }
                ObjectNavigator.shared.groupEdge(last: last)
            }
        }
        add("windowStart", String(localized: "The first item in the window (VO-Command-Home)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+command+home"]) { _ in ObjectNavigator.shared.windowEdge(last: false) }
        add("windowEnd", String(localized: "The last item in the window (VO-Command-End)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+command+end"]) { _ in ObjectNavigator.shared.windowEdge(last: true) }
        add("topLevel", String(localized: "Out to the top level of the window (VO-Shift-Escape)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+shift+escape"]) { _ in ObjectNavigator.shared.topLevel() }
        add("jumpLinked", String(localized: "Jump to the linked item; jumps to the linked item, such as from the message list to the message (VO-J)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+j"]) { _ in ObjectNavigator.shared.jumpLinked() }
        add("selectItem", String(localized: "In a text field, starts or stops selecting text; elsewhere selects the list or menu item (VO-Return)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+enter"]) { _ in
            if let f = API.focusObject, f.hasNavigableText, ObjectNavigator.shared.isWithin(f.element) { Self.textSelection(f); return }
            ObjectNavigator.shared.selectItem()
        }
        add("disclosure", String(localized: "Opens or closes the disclosure triangle (VO-Backslash)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+\\"]) { _ in ObjectNavigator.shared.toggleDisclosure() }
        add("click", String(localized: "Clicks the item with the mouse; pressed twice, a double click (VO-Shift-Space, VO-Shift-Space-Space)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+shift+space"]) { _ in
            ObjectNavigator.shared.click(double: ScriptHandler.lastScriptRepeatCount > 0)
        }
        add("helpTag", String(localized: "Reads the item's help tag (VO-Shift-H)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+shift+h"]) { _ in ObjectNavigator.shared.readHelp() }
        add("hint", String(localized: "Reads the hint for the item (VO-Shift-N)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+shift+n"]) { g in
            // Music, Podcasts and TV: what is playing (the app's own script; the table's hint won before, 8 Oct 2026).
            if let s = ScriptHandler.findScript(named: "media_nowPlaying") { s.handler(g); return }
            let h = API.focusObject.map { Hints.forObject($0) } ?? ""
            Speech.speakMessage(h.isEmpty ? String(localized: "no hint", comment: "Spoken message") : h)
        }
        add("readWindow", String(localized: "Reads everything in the window (VO-Shift-W)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+shift+w"]) { _ in ObjectNavigator.shared.readWindow() }
        add("linkAddress", String(localized: "Reads a link's address (VO-Shift-U)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+shift+u"]) { _ in ObjectNavigator.shared.readURL() }
        add("actions", String(localized: "The item's actions, to choose from (VO-Command-Space)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+command+space"]) { _ in ObjectNavigator.shared.actionsMenu() }
        add("focusToCursor", String(localized: "The keyboard focus to the VoiceOver cursor (VO-Command-F4)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+command+f4"]) { _ in ObjectNavigator.shared.moveFocusHere() }
        add("cursorToFocus", String(localized: "The VoiceOver cursor to the keyboard focus (VO-Shift-F4)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+shift+f4"]) { _ in ObjectNavigator.shared.toFocus() }
        add("closeWindow", String(localized: "Closes the window (VO-Command-Escape)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+command+escape"]) { _ in KeyboardGesture(identifier: "kb:command+w")?.send() }
        add("passNextKey", String(localized: "The next key goes to the application untouched (VO-Tab)", comment: "A command, as the key list and keyboard help say it"), ["kb:turnover+tab"]) { _ in
            InputManager.passNextKey = true
            Speech.speakMessage(String(localized: "pass next key", comment: "Spoken message"))
        }
        // VoiceOver's web navigation (VO-Command-letter; Shift for previous), in any document TurnOver reads.
        for (key, name, spoken) in [("h", "Heading", Role.heading.displayString), ("l", "Link", Role.link.displayString), ("j", "FormField", String(localized: "form control", comment: "A kind of thing to find, after next or previous")),
                                    ("t", "Table", Role.table.displayString), ("x", "List", Role.list.displayString), ("g", "Graphic", Role.graphic.displayString),
                                    // Word's own (VO-Command-M is VoiceOver's same-level heading: comments are in the rotor, 12 Oct 2026)
                                    ("r", "Revision", String(localized: "tracked change", comment: "A kind of thing to find, after next or previous")),
                                    ("e", "SpellingError", String(localized: "spelling error", comment: "Said before a misspelled word"))] {
            add("next\(name)", String(localized: "Next \(spoken) (VO-Command-\(key.uppercased()))", comment: "A command: %1$@ is a kind of thing to find (bold text), %2$@ a letter"), ["kb:turnover+command+\(key)"]) { g in find(name, spoken, forward: true, g) }
            add("previous\(name)", String(localized: "Previous \(spoken) (VO-Command-Shift-\(key.uppercased()))", comment: "A command: %1$@ is a kind of thing to find (bold text), %2$@ a letter"), ["kb:turnover+command+shift+\(key)"]) { g in find(name, spoken, forward: false, g) }
        }
        // The rest of VoiceOver's commands (VoiceOverParity.swift; 12 Oct 2026).
        addVoiceOverParity(add, run: { name, g in run(name, g) })
        addVoiceOverParity2(add)
        // the decisions on VoiceOver keys TurnOver had given to its own commands (VoiceOverDecisions.swift).
        addVoiceOverDecisions(add)
    }
}

extension VoiceOverKeysPlugin {
    /// The window chooser (VO-F2-F2; the keypad's Slash).
    static func windowChooser() {
        guard let pid = API.focusPid else { return }
        let windows = AXUIElementCreateApplication(pid).elements(kAXWindowsAttribute)
        let items = windows.map { w -> MenuItem in
            let t = w.string(kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "untitled window", comment: "A window with no title")
            return MenuItem(verbatim: t, .action {
                _ = AXUIElementPerformAction(w, kAXRaiseAction as CFString)
                _ = w.set(kAXMainAttribute, kCFBooleanTrue)
                AXHandler.shared.refocus(pid: pid)
            })
        }
        DispatchQueue.main.async { TurnOverMenu.shared.openList("Windows", items: items) }
    }
}
