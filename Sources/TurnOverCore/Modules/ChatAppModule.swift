// SPDX-License-Identifier: GPL-3.0-or-later
// Messages and WhatsApp (7 Oct 2026): one way of working for both (ChatView in TurnOverCore), each app described
// by where its three parts are. The keyboard stays in the message box; Tab and Shift Tab take TurnOver's cursor to
// the messages and the conversations, where the arrows, Return and the shortcut menu are TurnOver's.
import Foundation
import ApplicationServices

final class ChatAppModule: AppModule {
    // Each app's parts come from its recipe (Resources/recipes/<bundle id>.json, or the user's own in
    // ~/Library/Application Support/TurnOver/recipes), since 8 Oct 2026: no code per chat app.
    static var bundles: [String] { Recipes.bundles(kind: "chat") }

    private var view: ChatView!

    required init(pid: pid_t, bundleIdentifier: String, appName: String) {
        super.init(pid: pid, bundleIdentifier: bundleIdentifier, appName: appName)
        guard let chat = Recipes.recipe(for: bundleIdentifier)?.view.chat else { Log.error("chat module for \(bundleIdentifier) with no chat recipe: the registry is stale"); fatalError("no chat recipe for \(bundleIdentifier)") }
        view = ChatView(pid: pid, spec: ChatView.Spec(chat))
        let cat = appName
        let composerID = view.spec.composerID
        // In the box, or anywhere in the window but another text field (WhatsApp moves its focus about): Tab and Shift
        // Tab are TurnOver's way round the three parts.
        // The app's search field has the keyboard. Asked of the app itself: WhatsApp's search field is a static text to
        // accessibility, and a group gains focus straight after it, so TurnOver's own focus is that group.
        let searchID = view.spec.searchFieldID
        let inSearch: () -> Bool = {
            guard let searchID else { return false }
            var v: AnyObject?
            guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &v) == .success,
                  let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return false }
            return (v as! AXUIElement).string(kAXIdentifierAttribute) == searchID
        }
        let inBox: () -> Bool = { [weak self] in
            guard let self, !view.isBrowsing, let f = API.focusObject, f.pid == pid, !view.inSheet else { return false }
            if view.isPart(f.element, composerID) { return true }
            if [.editableText, .searchField, .comboBox, .passwordEdit].contains(f.role) || inSearch() { return false }
            return view.composer != nil
        }
        let browsing: () -> Bool = { [weak self] in
            guard let self, view.isBrowsing, API.focusPid == pid, !AXHandler.shared.isMenuOpen, !TurnOverMenu.shared.isOpen, !view.inSheet else { return false }
            return true
        }
        // No conversation open (WhatsApp with its chat closed): Tab and Shift Tab reach the conversations, to open one.
        let noChat: () -> Bool = { [weak self] in
            guard let self, !view.isBrowsing, let f = API.focusObject, f.pid == pid,
                  ![.editableText, .searchField, .comboBox, .passwordEdit].contains(f.role), !inSearch(), !view.inSheet else { return false }
            return view.composer == nil
        }
        script("chat_noChatToConversations", String(localized: "With no conversation open: to the conversations", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:tab"], category: cat) { [weak self] _ in
            self?.view.enter(.conversations)
        }.isAvailable = noChat
        // The arrows too: WhatsApp opened fresh puts its focus on a nameless group or the filter buttons, where its own
        // arrows do nothing and TurnOver said nothing until Tab (10 Oct 2026). From one of the sections
        // (WhatsApp moves its focus through them itself), the arrows and Return work the sections.
        script("chat_noChatArrows", String(localized: "With no conversation open: into the conversations (or the sections, from one of them)", comment: "A command, as the key list and keyboard help say it"),
               gestures: ["kb:downArrow", "kb:upArrow", "kb:enter", "kb:numpadEnter"], category: cat) { [weak self] g in
            guard let self else { return }
            if let f = API.focusObject?.element, view.isSection(f) {
                view.enter(.sections, at: f)
                if g.identifiers.contains("kb:enter") || g.identifiers.contains("kb:numpadEnter") { view.activate() }
            } else {
                view.enter(.conversations)
            }
        }.isAvailable = noChat
        script("chat_noChatToSections", String(localized: "With no conversation open: to the sections (or the conversations)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+tab"], category: cat) { [weak self] _ in
            guard let self else { return }
            view.enter(view.spec.sectionsPrefix != nil ? .sections : .conversations)
        }.isAvailable = noChat
        // The app's search field (WhatsApp's): Tab and Down go to what it found.
        if searchID != nil {
            script("chat_toResults", String(localized: "From the search field: to the results", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:tab", "kb:downArrow"], category: cat) { [weak self] _ in
                self?.view.enter(.conversations)
            }.isAvailable = { API.focusPid == pid && inSearch() }
        }
        // Return in the box sends: say so (Messages says nothing, and TurnOver's text field said "new line" as the box
        // emptied). WhatsApp says "Message Sent" itself.
        script("chat_send", String(localized: "In the message box: sends the message", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:enter"], category: cat) { [weak self] g in
            guard let self else { g.send(); return }
            let had = !((view.composer?.string(kAXValueAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            g.send()
            guard had, !view.spec.saysSent else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, (view.composer?.string(kAXValueAttribute) ?? "").isEmpty else { return }
                Speech.speakMessage(String(localized: "sent", comment: "Spoken message"))
            }
        }.isAvailable = { [weak self] in
            guard let self, let f = API.focusObject, f.pid == pid else { return false }
            return view.isPart(f.element, composerID)
        }
        script("chat_sheetBack", String(localized: "In a sheet (Settings): back a page, or close it", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:escape"], category: cat) { [weak self] _ in
            self?.view.closeSheetPage()
        }.isAvailable = { [weak self] in
            guard let self, API.focusPid == pid, !AXHandler.shared.isMenuOpen, !TurnOverMenu.shared.isOpen else { return false }
            return view.inSheet
        }
        script("chat_toMessages", String(localized: "From the message box: on round to the sections or conversations (the screen's order)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:tab"], category: cat) { [weak self] _ in self?.view.cycle(forward: true) }.isAvailable = inBox
        script("chat_toConversations", String(localized: "From the message box: back to the messages, on the newest", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+tab"], category: cat) { [weak self] _ in self?.view.cycle(forward: false) }.isAvailable = inBox
        func add(_ name: String, _ description: String, _ keys: [String], _ run: @escaping () -> Void) {
            script("chat_\(name)", description, gestures: keys.map { "kb:" + $0 }, category: cat) { _ in run() }.isAvailable = browsing
        }
        add("previous", String(localized: "Previous message or conversation", comment: "A command, as the key list and keyboard help say it"), ["upArrow"]) { [weak self] in self?.view.move(-1) }
        add("next", String(localized: "Next message or conversation", comment: "A command, as the key list and keyboard help say it"), ["downArrow"]) { [weak self] in self?.view.move(1) }
        add("first", String(localized: "The first one", comment: "A command, as the key list and keyboard help say it"), ["home", "command+upArrow"]) { [weak self] in self?.view.toEnd(false) }
        add("last", String(localized: "The last one", comment: "A command, as the key list and keyboard help say it"), ["end", "command+downArrow"]) { [weak self] in self?.view.toEnd(true) }
        add("open", String(localized: "Opens the conversation, or presses the message (a link, a photo)", comment: "A command, as the key list and keyboard help say it"), ["enter", "numpadEnter"]) { [weak self] in self?.view.activate() }
        add("nextPart", String(localized: "On to the next part, in the screen's order: sections, conversations, messages, the message box", comment: "A command, as the key list and keyboard help say it"), ["tab"]) { [weak self] in self?.view.cycle(forward: true) }
        add("previousPart", String(localized: "Back to the previous part", comment: "A command, as the key list and keyboard help say it"), ["shift+tab"]) { [weak self] in self?.view.cycle(forward: false) }
        add("toBox", String(localized: "Back to the message box", comment: "A command, as the key list and keyboard help say it"), ["escape"]) { [weak self] in self?.view.toComposer() }
        // Messages: Command T opens the Tapback picker as a TurnOver list (a tester). Only where the recipe is Messages'.
        if bundleIdentifier == "com.apple.MobileSMS" {
            script("chat_react", String(localized: "Reacts to the message: a list of Tapbacks, Return to choose (Command T)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+t"], category: cat) { [weak self] _ in
                self?.view.reactionChooser()
            }.isAvailable = { [weak self] in
                guard let self else { return false }
                let ok = API.focusPid == pid && !AXHandler.shared.isMenuOpen && !TurnOverMenu.shared.isOpen && !view.inSheet
                if !ok { Log.io("chat_react not available: focus pid \(API.focusPid ?? -1) vs \(pid), menu \(AXHandler.shared.isMenuOpen), TurnOver menu \(TurnOverMenu.shared.isOpen), sheet \(view.inSheet)") }
                return ok
            }
        }
        for n in 1...9 {
            script("chat_latest\(n)", n == 1 ? String(localized: "Reads the newest message", comment: "A command, as the key list and keyboard help say it") : String(localized: "Reads the message \(String(n)) from the newest", comment: "A command: %@ is how far back"), gestures: ["kb:control+command+\(n)"], category: cat) { [weak self] _ in
                self?.view.readLatest(n)
            }.isAvailable = { API.focusPid == pid }
        }
    }

    override func event_appModuleGainFocus() {
        GlobalCommands.contextMenuHandler = { [weak self] in
            guard let self, view.isBrowsing, API.focusPid == pid else { return false }
            view.actionsMenu()
            return true
        }
        view.startWatching()
        // WhatsApp, come back to with Command Tab, has its focus on a nameless group and says nothing but its name:
        // say the open chat and put the keyboard in its box.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, API.focusPid == pid, !view.isBrowsing, !view.inSheet else { return }
            var v: AnyObject?
            guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &v) == .success,
                  let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return }
            let f = v as! AXUIElement
            guard f.role == "AXGroup", (f.string(kAXDescriptionAttribute) ?? "").isEmpty else { return }
            if view.composer != nil {
                if let t = view.openTitle() { Speech.speakMessage(t) }
                view.toComposer()
            } else if let t = view.pageTitle() {
                // No chat open (Calls, Updates): the section, and the way into it.
                Speech.speakMessage(t)
                Hints.schedule(String(localized: "Tab goes to the list.", comment: "Spoken message"))
            }
        }
    }

    override func terminate() {
        view.stopWatching()
        if GlobalCommands.contextMenuHandler != nil, API.focusPid == pid { GlobalCommands.contextMenuHandler = nil }
    }

    override func event_appModuleLoseFocus() {
        view.stopWatching()
        view.focusLeft()
        GlobalCommands.contextMenuHandler = nil
    }

    override func handleEvent(_ event: Event, next: () -> Void) {
        // A focus that moves by itself (a click, a sheet, the app's own Tab) ends TurnOver's browsing of the lists.
        // (A menu opened from the shortcut menu, and the box getting its focus back after it, leave the place as it is.)
        // (WhatsApp also moves its focus to a nameless group by itself, a moment after a press: not a move of the user's.)
        let r = event.obj.role
        let drift = r == .groupBox && event.obj.name.isEmpty
        if event.kind == .gainFocus, view.isBrowsing, !drift, !view.isPart(event.obj.element, view.spec.composerID),
           ![.menu, .menuItem, .checkMenuItem, .radioMenuItem, .popupMenu].contains(r) {
            view.focusLeft()
        }
        // A page opened in a sheet (WhatsApp's Settings): the app puts its focus on a nameless group, which says
        // nothing. Say the page's title instead, from the sheet's navigation bar.
        if event.kind == .gainFocus, drift, view.inSheet, let title = view.sheetTitle(), title != lastSheetTitle {
            lastSheetTitle = title
            Speech.speakMessage(title)
            return
        }
        if event.kind == .gainFocus, !view.inSheet { lastSheetTitle = nil }
        // WhatsApp hands its focus to a nameless group a moment after the box gets it (opening a chat with Return),
        // while the keyboard stays in the box: typing went to the group, which TurnOver doesn't echo, so nothing you
        // typed was said (13 Oct 2026). The box keeps TurnOver's focus, quietly.
        if event.kind == .gainFocus, drift, !view.inSheet, let c = view.composer, (c.attr(kAXFocusedAttribute) as? Bool) == true {
            Log.io("chat: focus drifted to a nameless group; the box keeps it")
            API.setFocusObject(ObjectFactory.make(c), ancestors: API.focusAncestors)
            return
        }
        next()
    }
    private var lastSheetTitle: String?
}
