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
// - With VoiceOver running the App Store shows a smaller tree (no prices, no offer buttons); TurnOver reads it
//   while VoiceOver is off, so it has the full one.
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
        add("previous", "Previous item", ["upArrow"]) { [weak self] _ in self?.view.move(-1) }
        add("next", "Next item", ["downArrow"]) { [weak self] _ in self?.view.move(1) }
        add("previousShelf", "Previous shelf of the page", ["leftArrow"]) { [weak self] _ in self?.view.jumpShelf(-1) }
        add("nextShelf", "Next shelf of the page", ["rightArrow"]) { [weak self] _ in self?.view.jumpShelf(1) }
        add("first", "First item", ["home"]) { [weak self] _ in self?.view.toEnd(false) }
        add("last", "Last item", ["end"]) { [weak self] _ in self?.view.toEnd(true) }
        add("open", "Opens the app's page, or presses the button", ["enter", "numpadEnter"]) { [weak self] _ in self?.view.open() }
        add("offer", "The app's button: Open, Get, Update or Re-download; a price needs a second press; while downloading, how far it has got", ["space"]) { [weak self] _ in self?.view.offer() }
        add("cancelDownload", "Cancels the app's download", ["backspace", "delete"]) { [weak self] _ in self?.view.cancelDownload() }
        add("nextArea", "Next area: sidebar, page", ["tab"]) { [weak self] _ in self?.view.switchArea() }
        add("previousArea", "Previous area", ["shift+tab"]) { [weak self] _ in self?.view.switchArea() }
        add("back", "Goes back a page", ["escape"]) { [weak self] _ in self?.view.back() }
        for ch in "abcdefghijklmnopqrstuvwxyz" {
            add("letter_\(ch)", "Jumps to the next item starting with the letter", [String(ch)]) { [weak self] _ in self?.view.letter(ch) }
        }
        script("appStore_search", "Goes to the search field", gestures: ["kb:command+f"], category: cat) { [weak self] _ in self?.view.focusSearch() }
        // Return in the search field: the App Store searches; the results are read and the keys come back to the page.
        script("appStore_submitSearch", "Searches, then reads the results", gestures: ["kb:enter"], category: cat) { [weak self] g in
            // The term is read before the Store starts searching: afterwards its accessibility stops answering for
            // seconds (a read of the sidebar then took 2 s and the keys were dead for 3 s more, 27 Oct 2026).
            let term = API.focusObject.flatMap { $0.element.string(kAXValueAttribute) ?? $0.value } ?? ""
            g.send()
            self?.view.afterSearch(term: term)
        }.isAvailable = { API.focusObject?.role == .searchField }
    }

    override func event_appModuleGainFocus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            // (Or the frontmost app: at launch TurnOver's focus can still be on the app before, 7 Oct 2026.)
            guard let self, API.focusPid == self.pid || NSWorkspace.shared.frontmostApplication?.processIdentifier == self.pid else { return }
            self.view.arrive()
        }
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
