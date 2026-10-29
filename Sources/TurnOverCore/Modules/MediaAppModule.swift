// SPDX-License-Identifier: GPL-3.0-or-later
// Music, Podcasts and TV: one way of working for all three (MediaView in TurnOverCore).
// The keys belong to the media view only while the focus is not somewhere to type (the search
// field) and no menu is open; there the app has them as usual.
import Foundation
import AppKit
import ApplicationServices

final class MediaAppModule: AppModule {
    /// The apps read this way come from their recipes (Resources/recipes, kind "media"; a user's own can add one).
    static var bundles: [String] { Recipes.bundles(kind: "media") }
    // TV's cell AXPress returned success while its Search row remained selected (29 Oct 2026, #186).
    // The shared owner receives a strategy; Music, Podcasts and other recipe apps retain cell presses.
    private lazy var view = MediaView(pid: pid, sidebarNavigation: bundleIdentifier == "com.apple.TV" ? .selectRow : .pressCell,
                                      bundleIdentifier: bundleIdentifier)
    private static let arrivalTries = 6
    private var focusGeneration = 0
    private var terminated = false

    required init(pid: pid_t, bundleIdentifier: String, appName: String) {
        super.init(pid: pid, bundleIdentifier: bundleIdentifier, appName: appName)
        let cat = appName
        let active: () -> Bool = {
            if AXHandler.shared.isMenuOpen || TurnOverMenu.shared.isOpen { return false }
            guard let f = API.focusObject else { return true }
            // A dialog or sheet has the keys (TV's notification sheet): the media view stands aside.
            if f.role == .dialog || f.role == .sheet || API.focusAncestors.contains(where: { $0.role == .dialog || $0.role == .sheet }) { return false }
            if [.editableText, .searchField, .comboBox, .passwordEdit].contains(f.role) { return false }
            return !MediaView.showsVideo(pid: f.pid)
        }
        // The catalog's list (Catalog.swift) is read while the search field still has the focus: the arrows, Home, End,
        // Return and Escape are the list's then; the letters stay the field's, for the next search.
        let activeOrCatalog: () -> Bool = { [weak self] in
            if active() { return true }
            guard let self, self.view.catalogDrives, let f = API.focusObject, f.role == .searchField else { return false }
            return !(AXHandler.shared.isMenuOpen || TurnOverMenu.shared.isOpen)
        }
        func add(_ name: String, _ description: String, _ keys: [String], listKeys: Bool = false, _ run: @escaping (KeyboardGesture) -> Void) {
            script("media_\(name)", description, gestures: keys.map { "kb:" + $0 }, category: cat, run).isAvailable = listKeys ? activeOrCatalog : active
        }
        add("previous", "Previous item", ["upArrow"], listKeys: true) { [weak self] _ in self?.view.move(-1) }
        add("next", "Next item", ["downArrow"], listKeys: true) { [weak self] _ in self?.view.move(1) }
        add("previousShelf", "Previous shelf of the page", ["leftArrow"]) { [weak self] _ in self?.view.jumpShelf(-1) }
        add("nextShelf", "Next shelf of the page", ["rightArrow"]) { [weak self] _ in self?.view.jumpShelf(1) }
        add("first", "First item", ["home"], listKeys: true) { [weak self] _ in self?.view.toEnd(false) }
        add("last", "Last item", ["end"], listKeys: true) { [weak self] _ in self?.view.toEnd(true) }
        add("open", "Plays the item when it can be played, otherwise opens it; in the sidebar, goes to that section", ["enter", "numpadEnter"], listKeys: true) { [weak self] _ in self?.view.activate() }
        add("openDetails", "Opens the item's page (an episode's details) instead of playing it", ["shift+enter"], listKeys: true) { [weak self] _ in self?.view.activate(openOnly: true) }
        add("play", "Plays the item, or plays and pauses", ["space"]) { [weak self] g in self?.view.playOrPause(g) }
        add("nextArea", "Next area: sidebar, page, player", ["tab"]) { [weak self] _ in self?.view.switchPane(1) }
        add("previousArea", "Previous area", ["shift+tab"]) { [weak self] _ in self?.view.switchPane(-1) }
        add("back", "Goes back a page", ["escape"], listKeys: true) { [weak self] _ in self?.view.back() }
        for ch in "abcdefghijklmnopqrstuvwxyz" {
            add("letter_\(ch)", "Jumps to the next item starting with the letter", [String(ch)]) { [weak self] _ in self?.view.letter(ch) }
        }
        script("media_submitSearch", "Searches, then reads the results", gestures: ["kb:enter", "kb:numpadEnter"], category: cat) { [weak self] g in
            let term = API.focusObject.flatMap { $0.element.string(kAXValueAttribute) ?? $0.value } ?? ""   // read before the app starts searching (it answers slowly then)
            // Return again on the same term while the catalog's list is up opens the item it is on.
            if let self, let t = self.view.catalogTerm, t == term.trimmingCharacters(in: .whitespacesAndNewlines) { self.view.activate(); return }
            g.send()
            self?.view.afterSearch(term: term)
        }.isAvailable = { [weak self] in API.focusObject?.role == .searchField && API.focusPid == self?.pid }
        script("media_nowPlaying", "Says what is playing", gestures: ["kb:turnover+shift+n"], category: cat) { [weak self] _ in self?.view.nowPlaying() }
    }

    override func event_appModuleGainFocus() {
        guard !terminated else { return }
        focusGeneration += 1
        view.beginSession()
        arrive(tries: Self.arrivalTries, generation: focusGeneration, keys: ScriptHandler.keysArrivedCount)
    }

    override func event_appModuleLoseFocus() { focusGeneration += 1; view.stop() }

    override func terminate() {
        terminated = true; focusGeneration += 1; view.stop()
        super.terminate()
    }

    /// Arriving in the app: where the media view is, after the app has said its window. An app just launched has
    /// nothing to read yet ("Podcasts, starting… Home, window", then silence, 7 Oct 2026): look again until it has.
    private func arrive(tries: Int, generation: Int, keys: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (tries == Self.arrivalTries ? 0.4 : 1.0)) { [weak self] in
            guard let self, !terminated, focusGeneration == generation, Core.active,
                  ScriptHandler.keysArrivedCount == keys else { return }
            // (The frontmost application, not only TurnOver's focus: a launch can hand the focus to a helper first.)
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            Log.io("media: arriving (\(Self.arrivalTries + 1 - tries)), focus pid \(API.focusPid ?? 0), front \(front ?? 0)")
            guard front == self.pid else { return }
            self.view.refresh { [weak self] in
                guard let self, !terminated, focusGeneration == generation, Core.active,
                      ScriptHandler.keysArrivedCount == keys,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == self.pid else { return }
                if self.view.shelves.isEmpty, tries > 1 { self.arrive(tries: tries - 1, generation: generation, keys: keys); return }
                self.view.pane = .page
                self.view.switchPane(0)
            }
        }
    }

    override func handleEvent(_ event: Event, next: () -> Void) {
        // Music's video player: its buttons speak as anywhere else. Leaving it, the page is read again.
        if event.kind == .gainFocus || event.kind == .focusEntered {
            if MediaView.showsVideo(pid: pid) { next(); return }
            if view.inVideo {
                view.inVideo = false
                let generation = focusGeneration, keys = ScriptHandler.keysArrivedCount
                view.refresh { [weak self] in
                    guard let self, !terminated, focusGeneration == generation, Core.active,
                          ScriptHandler.keysArrivedCount == keys,
                          NSWorkspace.shared.frontmostApplication?.processIdentifier == self.pid else { return }
                    view.pane = .page; view.switchPane(0)
                }
                return
            }
        }
        // The media view speaks for the app; its own focus moves (rows, groups) would only repeat or confuse,
        // except where the user is typing, in a menu, or in a dialog.
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
