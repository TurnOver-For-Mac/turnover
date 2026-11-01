// SPDX-License-Identifier: GPL-3.0-or-later
// The App Store (6 Oct 2026: "a pretty rough experience with VoiceOver"). Read as two areas, the sidebar and
// the page, with every app on the page in one list, as Music's shelves are (MediaView).
//
// Measured 6 Oct 2026 (macOS 27, App Store built on the same shelf framework as Music):
// - The page is an AXCollectionList (identifier AppStore.discover, .productPage, .updates, .search.result) of
//   AXSectionLists, the shelves. Only the shelves on screen are children; the rest are reached by
//   AXNextContentSibling, which hands them over, filled in, without scrolling (a whole Discover page in 1.5 s).
// - A shelf shows three apps; the rest of its carousel (26 in one) are reached the same way, from item to item.
//   VoiceOver users page each carousel with Backward and Forward buttons instead.
// - An app's tile (SmallLockupCollectionViewCell) has one action, "buy for £24.99"; its button inside
//   (AppStore.offerButton) is Get, Open, Update, Re-download or the price. Opening the app's page is a click on the
//   tile away from that button. TurnOver opens pages by clicking the icon, and presses the offer button only on
//   Space, a price only on a second Space.
// - The product page's badges read backwards ("GB, SIZE, 2.76"; "selfie" for the developer's picture); they are
//   put in order here. Its Accessibility section (which features the developer says the app supports) is read
//   as a shelf like the others.
// - On that October 6 build the ordinary AXChildren walk exposed fewer prices/buttons while VoiceOver ran.
//   The October 28 investigation found public navigation-order children beyond the ordinary walk (issue 174).
//   The default builder now tries that representation; matched VoiceOver-off coverage, prices and safe actions
//   still require separate checks. The earlier ordinary-tree observation does not establish full-tree parity.
//
// Keys (only while the focus is not in the search field, no menu is open and no sheet is up):
//   Up, Down        the previous and next item: every app, heading, text and button on the page, in order
//   Left, Right     the previous and next shelf (its name and how many items it has)
//   Home, End       the first and last item
//   Return          opens the app's page, or presses the button
//   Space           the app's own button: Open, Get, Update, Re-download; a price asks for a second Space
//   Tab, Shift Tab  the sidebar (search, Discover, Arcade… Updates, your account) and the page
//   Escape          back a page
//   Command F       the search field; Return there searches, and the results are read
//   a letter        the next item starting with it
import Foundation
import AppKit
import ApplicationServices

final class AppStoreAppModule: AppModule {
    static let bundleID = "com.apple.AppStore"
    private lazy var view = AppStoreView(pid: pid)
    private var focusGeneration = 0
    private var terminated = false

    required init(pid: pid_t, bundleIdentifier: String, appName: String) {
        super.init(pid: pid, bundleIdentifier: bundleIdentifier, appName: appName)
        let cat = "App Store"
        let active: () -> Bool = {
            if AXHandler.shared.isMenuOpen || TurnOverMenu.shared.isOpen { return false }
            guard let f = API.focusObject else { return true }
            if f.role == .dialog || f.role == .sheet || API.focusAncestors.contains(where: { $0.role == .dialog || $0.role == .sheet }) { return false }
            // A sheet over the window (the install sheet asking for Touch ID): its keys, Escape included, are its own.
            if AppStoreView.hasSheet(pid: f.pid) { return false }
            return ![.editableText, .searchField, .comboBox, .passwordEdit].contains(f.role)
        }
        func add(_ name: String, _ description: String, _ keys: [String], _ run: @escaping (KeyboardGesture) -> Void) {
            script("appStore_\(name)", description, gestures: keys.map { "kb:" + $0 }, category: cat, run).isAvailable = active
        }
        add("previous", String(localized: "Previous item", comment: "A command, as the key list and keyboard help say it"), ["upArrow"]) { [weak self] _ in self?.view.move(-1) }
        add("next", String(localized: "Next item", comment: "A command, as the key list and keyboard help say it"), ["downArrow"]) { [weak self] _ in self?.view.move(1) }
        add("previousShelf", String(localized: "Previous shelf of the page", comment: "A command, as the key list and keyboard help say it"), ["leftArrow"]) { [weak self] _ in self?.view.jumpShelf(-1) }
        add("nextShelf", String(localized: "Next shelf of the page", comment: "A command, as the key list and keyboard help say it"), ["rightArrow"]) { [weak self] _ in self?.view.jumpShelf(1) }
        add("first", String(localized: "First item", comment: "A command, as the key list and keyboard help say it"), ["home"]) { [weak self] _ in self?.view.toEnd(false) }
        add("last", String(localized: "Last item", comment: "A command, as the key list and keyboard help say it"), ["end"]) { [weak self] _ in self?.view.toEnd(true) }
        add("open", String(localized: "Opens the app's page, or presses the button", comment: "A command, as the key list and keyboard help say it"), ["enter", "numpadEnter"]) { [weak self] gesture in
            AppStoreActionPress.dispatch(gesture) { self?.view.open(press: $0) }
        }
        add("offer", String(localized: "The app's button: Open, Get, Update or Re-download; a price needs a second press; while downloading, how far it has got", comment: "A command, as the key list and keyboard help say it"), ["space"]) { [weak self] gesture in
            AppStoreActionPress.dispatch(gesture) { self?.view.offer(press: $0) }
        }
        add("cancelDownload", String(localized: "Cancels the app's download", comment: "A command, as the key list and keyboard help say it"), ["backspace", "delete"]) { [weak self] _ in self?.view.cancelDownload() }
        add("nextArea", String(localized: "Next area: sidebar, page", comment: "A command, as the key list and keyboard help say it"), ["tab"]) { [weak self] _ in self?.view.switchArea() }
        add("previousArea", String(localized: "Previous area", comment: "A command, as the key list and keyboard help say it"), ["shift+tab"]) { [weak self] _ in self?.view.switchArea() }
        add("back", String(localized: "Goes back a page", comment: "A command, as the key list and keyboard help say it"), ["escape"]) { [weak self] _ in self?.view.back() }
        for ch in "abcdefghijklmnopqrstuvwxyz" {
            add("letter_\(ch)", String(localized: "Jumps to the next item starting with the letter", comment: "A command, as the key list and keyboard help say it"), [String(ch)]) { [weak self] _ in self?.view.letter(ch) }
        }
        script("appStore_search", String(localized: "Goes to the search field", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+f"], category: cat) { [weak self] _ in self?.view.focusSearch() }
        // Return in the search field: the App Store searches; the results are read and the keys come back to the page.
        script("appStore_submitSearch", String(localized: "Searches, then reads the results", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:enter"], category: cat) { [weak self] g in
            // The term is read before the Store starts searching: afterwards its accessibility stops answering for
            // seconds (a read of the sidebar then took 2 s and the keys were dead for 3 s more, 27 Oct 2026).
            let term = API.focusObject.flatMap { $0.element.string(kAXValueAttribute) ?? $0.value } ?? ""
            g.send()
            self?.view.afterSearch(term: term)
        }.isAvailable = { API.focusObject?.role == .searchField }
    }

    override func event_appModuleGainFocus() {
        guard !terminated else { return }
        focusGeneration += 1
        let generation = focusGeneration
        view.beginSession()
        let keys = ScriptHandler.keysArrivedCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            // (Or the frontmost app: at launch TurnOver's focus can still be on the app before, 7 Oct 2026.)
            guard let self, !terminated, focusGeneration == generation, Core.active, ScriptHandler.keysArrivedCount == keys,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == self.pid else { return }
            self.view.arrive()
        }
    }

    override func event_appModuleLoseFocus() { focusGeneration += 1; view.stop() }

    override func terminate() {
        terminated = true; focusGeneration += 1
        view.stop()
        super.terminate()
    }

    override func handleEvent(_ event: Event, next: () -> Void) {
        // The view speaks for the App Store; its own focus moves (the collection, a cell) would only repeat it.
        if event.kind == .gainFocus || event.kind == .focusEntered {
            let r = event.obj.role
            let speaksForItself = ([.editableText, .searchField, .comboBox, .passwordEdit, .dialog, .sheet, .menu, .menuItem] as [Role]).contains(r)
            // Anything in a dialog or alert speaks: Music's "delete these songs?" alert said nothing as Tab moved
            // between Cancel and Delete Songs (7 Oct 2026).
            let inDialog = API.focusAncestors.contains { $0.role == .dialog || $0.role == .sheet }
                || ["AXDialog", "AXSystemDialog"].contains(event.obj.element.element(kAXWindowAttribute)?.string(kAXSubroleAttribute) ?? "")
            if !speaksForItself, !inDialog { return }
        }
        next()
    }
}
