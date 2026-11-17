// SPDX-License-Identifier: GPL-3.0-or-later
// Finder in the Windows keyboard style: Return opens the selection, as in Windows Explorer (Finder's own Return
// renames, and Command+Down opens); F2 or Shift Return renames. In the Mac style, Finder's own keys. Only in a file view of a
// Finder window: in the rename field, the search field, the sidebar, a sheet or
// a dialog, Return is Return.
import Foundation
import UniformTypeIdentifiers
import ApplicationServices
import AppKit

package final class FinderAppModule: AppModule {
    static let bundleID = "com.apple.finder"

    package required init(pid: pid_t, bundleIdentifier: String, appName: String) {
        super.init(pid: pid, bundleIdentifier: bundleIdentifier, appName: appName)
        let cat = "Finder"
        // Command Down with nothing selected (after Command Up to the top: Finder selects nothing there) does nothing
        // at all: say so, rather than silence (a tester, 9 Oct 2026). With a selection, Finder's own key, untouched.
        script("finder_openNothing", String(localized: "Command Down with nothing selected: says so", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+downArrow"], category: cat) { _ in
            Speech.speakMessage(String(localized: "nothing selected; Down arrow to choose an item", comment: "Spoken message"))
        }.isAvailable = { [weak self] in
            guard let self, inFileView(), let f = API.focusObject else { return false }
            let e = f.element
            let selected = e.elements(kAXSelectedRowsAttribute) + e.elements(kAXSelectedChildrenAttribute)
            let hasItems = !(e.elements(kAXRowsAttribute).isEmpty && e.elements(kAXChildrenAttribute).isEmpty)
            return hasItems && selected.isEmpty && [Role.outline, .list, .table].contains(f.role)
        }
        // Command Down on a folder and Command Up are sometimes ignored by Finder: about one press in twenty did nothing,
        // the key reached Finder (a tap after VoiceOver's saw it, 21 Oct 2026) and no synthetic press ever failed.
        // A symptom fix, the cause in Finder unknown: the key is sent on, and if nothing changes within 350 ms it is
        // sent once more. Down only for a folder (a file would open twice), and only while Finder is still in front.
        script("finder_openSelected", String(localized: "Opens the selected item (Command Down); a folder is asked for again if Finder ignored it", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+downArrow"], category: cat) { [weak self] g in
            guard let self else { g.send(); return }
            FinderRows.openSelection(in: API.focusObject?.element) {
                self.sendAgainIfIgnored(g, what: "Command Down", foldersOnly: true)
            }
        }.isAvailable = { [weak self] in
            guard let self, inFileView(), let f = API.focusObject else { return false }
            return !(f.element.elements(kAXSelectedRowsAttribute) + f.element.elements(kAXSelectedChildrenAttribute)).isEmpty
        }
        // Quick Look open (17 Nov 2026): the window has the focus, not the list, so Finder moved the selection under it
        // and the arrow said nothing (two stretches in the log). The key goes on; the file the selection moved to is said.
        script("finder_quickLookArrows", String(localized: "With Quick Look open, an arrow says the file the selection moved to", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:upArrow", "kb:downArrow", "kb:leftArrow", "kb:rightArrow"], category: cat) { [weak self] g in
            guard let self else { g.send(); return }
            self.arrowUnderQuickLook(g)
        }.isAvailable = { [weak self] in self?.quickLookHasFocus() ?? false }
        script("finder_enclosingFolder", String(localized: "Goes to the enclosing folder (Command Up); asked for again if Finder ignored it", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+upArrow"], category: cat) { [weak self] g in
            self?.sendAgainIfIgnored(g, what: "Command Up", foldersOnly: false)
        }.isAvailable = { [weak self] in self?.inFileView() ?? false }
        // Windows style only: in Mac style Finder keeps its own keys (Return renames, Command Down opens), the muscle
        // memory VoiceOver users have (6 Oct 2026).
        script("finder_open", String(localized: "Opens the selected item, as in Windows Explorer (Windows style; on a Mac, Command Down)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:enter", "kb:numpadEnter"], category: cat) { [weak self] g in
            guard let self, inFileView() else { g.send(); return }
            Tones.press()
            KeyboardGesture(identifier: "kb:command+downArrow")?.send()
        }.isAvailable = { config.general.windowsKeys }
        script("finder_rename", String(localized: "Renames the selected item: F2, as in Windows Explorer, or Shift Return (Windows style)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:f2", "kb:shift+enter"], category: cat) { [weak self] g in
            guard let self, inFileView() else { g.send(); return }
            KeyboardGesture(identifier: "kb:enter")?.send()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Speech.speakMessage(String(localized: "rename", comment: "Spoken message")) }
        }.isAvailable = { config.general.windowsKeys }
        // Tab and Shift Tab between the parts of the window, as in Windows Explorer: toolbar … search, files, sidebar,
        // and round. Finder's own Tab in the files chose the next file, and its sidebar never takes the keyboard, so
        // TurnOver holds the sidebar (ObjectNavigator.hold) (7 Oct 2026).
        script("finder_tabToSidebar", String(localized: "From the files, Tab goes to the sidebar", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:tab"], category: cat) { [weak self] g in
            guard let self, let sb = sidebar() else { g.send(); return }
            ObjectNavigator.shared.enterHold(sb, name: "sidebar")
        }.isAvailable = { [weak self] in self?.inFileView() == true }
        script("finder_shiftTabToSearch", String(localized: "To the search field; from the files, Shift Tab goes back to the toolbar's search", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+tab"], category: cat) { [weak self] g in
            guard let self, focusSearch() else { g.send(); return }
        }.isAvailable = { [weak self] in self?.inFileView() == true }
        script("finder_shiftTabToSidebar", String(localized: "To the sidebar; from the toolbar's first button, Shift Tab goes back to the sidebar", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+tab"], category: cat) { [weak self] g in
            guard let self, let sb = sidebar() else { g.send(); return }
            ObjectNavigator.shared.enterHold(sb, name: "sidebar")
        }.isAvailable = { [weak self] in
            guard let self, let f = API.focusObject, f.pid == pid,
                  let tb = window()?.elements(kAXChildrenAttribute).first(where: { $0.role == "AXToolbar" }),
                  let first = Self.firstFocusable(in: tb) else { return false }
            return CFEqual(first, f.element)
        }
        ObjectNavigator.shared.heldTab = { [weak self] forward in
            guard let self, API.focusPid == pid else { return false }
            if forward {   // the sidebar's Tab: round to the toolbar's first control
                guard let w = window(), let first = Self.firstFocusable(in: w.elements(kAXChildrenAttribute).first { $0.role == "AXToolbar" }) else { return false }
                _ = first.set(kAXFocusedAttribute, kCFBooleanTrue)
                return true
            }
            // The sidebar's Shift Tab: back to the files.
            guard let f = API.focusObject else { return false }
            Speech.speakObject(f, reason: .focus)
            return true
        }
    }

    // View > Sort By (Oliver's decision, 17 Nov 2026): choosing an order says "sorted by <its name>" once the menu has
    // closed, and nothing more. Return in a menu must reach Finder untouched (a key TurnOver re-posts is ignored by menu
    // menus, measured on Word, 1 Oct 2026), so this is no script: the key is only looked at, as it passes.
    // Finder gives no sign that the list has re-sorted (nothing recorded; its notifications are unknown), so the words
    // come a moment after the menu closes, once the focus has read the list again.
    /// The open menu that is Finder's, if any; a test puts in its own.
    package lazy var openMenu: () -> AXUIElement? = { [pid] in
        guard AXHandler.shared.isMenuOpen else { return nil }
        guard let menu = AXHandler.shared.openMenus.last else { return nil }
        return menu.pid == pid ? menu : nil
    }
    /// How long after the menu closes the words are said: the list's first row is read in that time (0.44 s in the log).
    package var sortSayDelay: TimeInterval = 0.6
    private var sortWatch = 0

    package override func script(for gesture: KeyboardGesture) -> Script? {
        noteSortChoice(gesture)
        return super.script(for: gesture)
    }

    private func noteSortChoice(_ gesture: KeyboardGesture) {
        let chooses = ["enter", "numpadEnter", "space"].contains(gesture.keyName)
        guard chooses, gesture.modifiers.isEmpty else { return }
        guard let menu = openMenu() else { return }
        guard let order = Self.sortOrder(inMenu: menu) else { return }
        sortWatch += 1
        let token = sortWatch
        let began = Date()
        func look() {
            guard token == sortWatch else { return }
            if openMenu() != nil, Date().timeIntervalSince(began) < 3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { look() }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + sortSayDelay) { [weak self] in
                guard let self, token == sortWatch else { return }
                Log.io("Finder: sort order chosen, \"\(Log.words(order))\"")
                Speech.speakMessage(String(localized: "sorted by \(order)", comment: "Spoken message after choosing an order in Finder's View, Sort By menu: %@ is the order's name, such as Date Created"))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { look() }
    }

    /// The order the highlighted item of Finder's Sort By submenu names, nil in any other menu.
    package static func sortOrder(inMenu menu: AXUIElement) -> String? {
        guard let parent = menu.element(kAXParentAttribute) else { return nil }
        guard parent.role == "AXMenuItem" else { return nil }
        guard parent.string(kAXTitleAttribute) == "Sort By" else { return nil }
        guard let item = menu.elements(kAXSelectedChildrenAttribute).first else { return nil }
        guard let title = item.string(kAXTitleAttribute), !title.isEmpty else { return nil }
        return title
    }

    private func window() -> AXUIElement? { AXUIElementCreateApplication(pid).element(kAXFocusedWindowAttribute) }

    /// The desktop's icons and an icon view's are pictures to accessibility ("graphic"): read them as files, by kind.
    package override func objectClass(for element: AXUIElement, role: Role, subrole: String?) -> TurnOverObject.Type? {
        // A file's picture has a file address (AXURL), or at least its name (AXFilename); on the Desktop every picture is
        // a file. A tester's Desktop items have no AXURL, so the fallback in `kind` was never reached (19 Oct 2026).
        if element.role == "AXImage", FinderItem.fileURL(of: element) != nil || element.attr("AXFilename") != nil
            || element.element(kAXWindowAttribute)?.string(kAXSubroleAttribute) == "AXDesktop" { return FinderItem.self }
        // Column view: each item is a group in a list, with its index (AXIndex) but no list-item role, so it was read
        // without its place ("name", no "3 of 28"; the Finder scenario, 9 and 10 Oct 2026).
        if element.role == "AXGroup", element.element(kAXParentAttribute)?.role == "AXList", element.attr("AXIndex") != nil { return FinderColumnItem.self }
        return nil
    }

    private func sidebar() -> AXUIElement? {
        guard let w = window() else { return nil }
        func find(_ e: AXUIElement, _ d: Int) -> AXUIElement? {
            if e.role == "AXOutline", (e.string(kAXDescriptionAttribute) ?? "").lowercased() == "sidebar" { return e }
            guard d < 8 else { return nil }
            for c in e.elements(kAXChildrenAttribute) where c.role != "AXToolbar" { if let f = find(c, d + 1) { return f } }
            return nil
        }
        return find(w, 0)
    }

    /// Escape from a toolbar control goes to the window's file view (ToolbarKeys; 15 Nov 2026).
    package override func toolbarEscapeTarget(in window: AXUIElement) -> AXUIElement? { Self.fileView(in: window) }

    /// The window's file view (list, icon, column or table view), outside the toolbar and the sidebar.
    static func fileView(in window: AXUIElement) -> AXUIElement? {
        func find(_ e: AXUIElement, _ d: Int) -> AXUIElement? {
            if ["AXOutline", "AXBrowser", "AXTable", "AXList"].contains(e.role), (e.string(kAXDescriptionAttribute) ?? "").lowercased() != "sidebar" { return e }
            guard d < 8 else { return nil }
            for c in e.elements(kAXChildrenAttribute) where c.role != "AXToolbar" { if let f = find(c, d + 1) { return f } }
            return nil
        }
        return find(window, 0)
    }

    private func focusSearch() -> Bool {
        guard let tb = window()?.elements(kAXChildrenAttribute).first(where: { $0.role == "AXToolbar" }) else { return false }
        func find(_ e: AXUIElement, _ d: Int) -> AXUIElement? {
            if e.string(kAXSubroleAttribute) == "AXSearchField" || e.role == "AXSearchField" { return e }
            guard d < 4 else { return nil }
            for c in e.elements(kAXChildrenAttribute) { if let f = find(c, d + 1) { return f } }
            return nil
        }
        guard let field = find(tb, 0) else { return false }
        return field.set(kAXFocusedAttribute, kCFBooleanTrue) == .success
    }

    static func firstFocusable(in e: AXUIElement?) -> AXUIElement? {
        guard let e else { return nil }
        for c in e.elements(kAXChildrenAttribute) {
            var st: DarwinBoolean = false
            if AXUIElementIsAttributeSettable(c, kAXFocusedAttribute as CFString, &st) == .success, st.boolValue,
               (c.attr(kAXEnabledAttribute) as? Bool) != false { return c }
            if let f = firstFocusable(in: c) { return f }
        }
        return nil
    }

    /// The focus is a file view (list, icon, column or gallery view) in an ordinary Finder window.
    /// The key goes to Finder; if Finder shows no change within 350 ms (no focus or selection event, the same window
    /// title and selected row), it is sent once more. See the comment at the scripts.
    private func sendAgainIfIgnored(_ g: KeyboardGesture, what: String, foldersOnly: Bool) {
        let before = Self.viewState()
        g.send()
        let changed = Poll.pumping(limit: 0.35) {
            EventHandler.isPending(.gainFocus) || EventHandler.isPending(.selection) || !Self.same(Self.viewState(), before)
        }
        if changed { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { Log.io("finder: \(what) did nothing within 350 ms; another app is in front, not sent again"); return }
        if foldersOnly, let f = API.focusObject, !Self.selectedIsFolder(in: f.element) { Log.io("finder: \(what) did nothing within 350 ms on a file; not sent again"); return }
        Log.io("finder: \(what) did nothing within 350 ms (Finder ignored the key, 21 Oct 2026); sent again")
        g.send()
    }

    /// The window's title and the selected row's identity, as a view-change check.
    private static func viewState() -> (String, AXUIElement?) {
        guard let f = API.focusObject else { return ("", nil) }
        let title = f.element.element(kAXWindowAttribute)?.string(kAXTitleAttribute) ?? ""
        let sel = (f.element.elements(kAXSelectedRowsAttribute) + f.element.elements(kAXSelectedChildrenAttribute)).first
        return (title, sel)
    }
    private static func same(_ a: (String, AXUIElement?), _ b: (String, AXUIElement?)) -> Bool {
        guard a.0 == b.0 else { return false }
        switch (a.1, b.1) {
        case (nil, nil): return true
        case let (x?, y?): return x.isSame(y)
        default: return false
        }
    }

    /// Whether the selected row is a folder: in list view its Kind cell says Folder, or its Size cell is the folder's
    /// dashes. Icon and column views give no cells: not known, so no second send.
    static func selectedIsFolder(in list: AXUIElement) -> Bool {
        guard let row = list.elements(kAXSelectedRowsAttribute).first else { return false }
        let cells = row.elements(kAXChildrenAttribute)
        let texts = cells.map { c in c.elements(kAXChildrenAttribute).compactMap { $0.string(kAXValueAttribute) }.joined(separator: " ") }
        return FinderRows.isFolderRow(cellTexts: texts)
    }

    /// Finder's own window itself has the focus (Quick Look's panel), and it is not a file window or a dialog.
    /// A text field or a button in a dialog is not the window itself, so the arrows there stay Finder's own.
    func quickLookHasFocus() -> Bool {
        guard let f = API.focusObject, f.pid == pid, f.axRole == "AXWindow" else { return false }
        let sub = f.element.string(kAXSubroleAttribute) ?? ""
        guard !["AXDesktop", "AXDialog", "AXSystemDialog"].contains(sub), Self.fileView(in: f.element) == nil else { return false }
        return Self.mainFileView(pid: pid) != nil
    }

    /// The file view of Finder's main window, or of the first standard window that has one.
    static func mainFileView(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        if let w = app.element(kAXMainWindowAttribute), let v = fileView(in: w) { return v }
        for w in app.elements(kAXWindowsAttribute) where w.string(kAXSubroleAttribute) == "AXStandardWindow" {
            if let v = fileView(in: w) { return v }
        }
        return nil
    }

    static func firstSelected(in view: AXUIElement) -> AXUIElement? {
        (view.elements(kAXSelectedRowsAttribute) + view.elements(kAXSelectedChildrenAttribute)).first
    }

    /// Whether the selection is on another row than before (nothing before, something now, counts).
    static func selectionMoved(from before: AXUIElement?, to after: AXUIElement?) -> Bool {
        switch (before, after) {
        case (_, nil): return false
        case (nil, _?): return true
        case let (x?, y?): return !x.isSame(y)
        }
    }

    private func arrowUnderQuickLook(_ g: KeyboardGesture) {
        guard let view = Self.mainFileView(pid: pid) else { g.send(); return }
        let before = Self.firstSelected(in: view)
        let focus = API.focusObject
        Log.io("finder: \(g.keyName) with the focus on a window (\(focus?.element.string(kAXSubroleAttribute) ?? "no subrole"), \(focus?.element.string(kAXTitleAttribute)?.prefix(1) ?? "")…); watching the file list")
        // On the first or last row, Up or Down cannot move the selection: said at once, without the 400 ms wait that
        // ended in silence (28 times in Oliver's log, 17 Nov 2026). The key still goes on, for the system's own bump.
        if let end = Self.listEnd(of: view, key: g.keyName, modifiers: g.modifiers, selected: before) {
            g.send()
            Log.io("finder: at the \(end.log) of the list under Quick Look")
            Speech.speakMessage(end.said)
            return
        }
        g.send()
        var after = before
        let moved = Poll.pumping(every: 0.02, limit: 0.4) { after = Self.firstSelected(in: view); return Self.selectionMoved(from: before, to: after) }
        guard moved, let row = after else {
            Log.io("finder: the selection did not move within 400 ms of \(g.keyName)")
            // A list that was not known to be at its end before the key (rows still loading) may be known now.
            if let end = Self.listEnd(of: view, key: g.keyName, modifiers: g.modifiers, selected: after) { Speech.speakMessage(end.said) }
            return
        }
        Speech.speakObject(ObjectFactory.make(row), reason: .focus)
    }

    /// "top" or "bottom" (the words the lists and browse mode say at their ends) when a plain Up or Down Arrow cannot
    /// move the selection of a list view: it is on the first row and the key is Up, or on the last and it is Down.
    /// Nil in an icon or column view (no rows to know the end by), with a modifier, or for any other key.
    static func listEnd(of view: AXUIElement, key: String, modifiers: Modifiers, selected: AXUIElement?) -> (said: String, log: String)? {
        guard modifiers.isEmpty, key == "upArrow" || key == "downArrow", let selected else { return nil }
        let rows = view.elements(kAXRowsAttribute)
        guard let end = key == "upArrow" ? rows.first : rows.last, selected.isSame(end) else { return nil }
        return key == "upArrow" ? (String(localized: "top", comment: "Spoken message"), "top") : (String(localized: "bottom", comment: "Spoken message"), "bottom")
    }

    private func inFileView() -> Bool {
        guard let f = API.focusObject, f.pid == pid else { return false }
        let fileRoles: [Role] = [.outline, .list, .browser, .table, .tableRow, .listItem, .treeViewItem]
        guard fileRoles.contains(f.role) || f.axRole == "AXOutline" || f.axRole == "AXList" || f.axRole == "AXBrowser" || f.axRole == "AXScrollArea" else { return false }
        if (f.element.string(kAXDescriptionAttribute) ?? "").lowercased() == "sidebar" { return false }
        guard let window = f.element.element(kAXWindowAttribute), ["AXStandardWindow", "AXDesktop"].contains(window.string(kAXSubroleAttribute) ?? "") else { return false }
        return true
    }
}

/// A file or folder on the desktop or in an icon view: "3d Printing, folder, 1 of 30", as VoiceOver reads it (a tester,
/// 10 Oct 2026: they were "graphic"). The kind is the Mac's own (Get Info's Kind): folder, alias, volume, PDF document.
final class FinderItem: TurnOverObject {
    override var role: Role { .listItem }
    override var roleText: String? { kind }
    private lazy var kind: String? = {
        var url = Self.fileURL(of: element)
        if url == nil {
            // No file address from Finder (a tester, 14 and 19 Oct 2026: an alias and a volume, no kind): the item found by
            // its name, on the Desktop or among the mounted volumes. A symptom fix: why Finder gives no address there
            // is unknown, and the log keeps the cause in view.
            let found = Self.urlByName(of: element, name: name)
            Log.io("finder: no file address for \"\(name.prefix(1))…\"; found by \(found?.route ?? "nothing")")
            url = found?.url
        }
        guard let url else {
            // Not found either: the kind from the name's extension, else "file".
            let ext = (name as NSString).pathExtension
            let guessed = ext.isEmpty ? nil : UTType(filenameExtension: ext)?.localizedDescription
            Log.io("finder: kind from \(ext.isEmpty ? "no extension" : "." + ext): \(guessed ?? "unknown")")
            return guessed ?? "file"
        }
        let v = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .isAliasFileKey, .isVolumeKey, .isPackageKey, .isDirectoryKey])
        // A mounted disk takes the Mac's own word for it ("Volume", «Том») rather than an English literal read
        // under a Russian interface (a tester, 8 Nov 2026).
        if v?.isVolume == true, let k = v?.localizedTypeDescription, !k.isEmpty { return Self.kindWord(k) }
        if v?.isVolume == true { return "volume" }
        if v?.isAliasFile == true { return "alias" }
        guard let k = v?.localizedTypeDescription, !k.isEmpty else { return v?.isDirectory == true ? "folder" : nil }
        return Self.kindWord(k)
    }()

    /// Get Info's kind as a word: "Folder" → "folder"; a name ("Microsoft Word document", "PDF document") stays as it is.
    static func kindWord(_ k: String) -> String {
        let first = k.split(separator: " ").first.map(String.init) ?? k
        return first.dropFirst().allSatisfy(\.isLowercase) && !["Microsoft", "Apple", "Adobe", "QuickTime", "Keynote", "Pages", "Numbers"].contains(first)
            ? k.prefix(1).lowercased() + k.dropFirst() : k
    }

    /// No file address: the item by its shown name, on the Desktop (the extension may be hidden), else a mounted volume
    /// of that name. Never /Volumes/<name>: for the startup disk that is a link to / and reads as an alias (19 Oct 2026).
    static func urlByName(of e: AXUIElement, name: String) -> (url: URL, route: String)? {
        let fm = FileManager.default
        let shown = e.string("AXFilename").flatMap { $0.isEmpty ? nil : $0 } ?? name
        guard !shown.isEmpty, !shown.contains("/") else { return nil }
        if e.element(kAXWindowAttribute)?.string(kAXSubroleAttribute) == "AXDesktop" {
            let desk = fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
            let exact = desk.appendingPathComponent(shown)
            if fm.fileExists(atPath: exact.path) { return (exact, "desktop name") }
            if let hit = (try? fm.contentsOfDirectory(atPath: desk.path))?.first(where: { fm.displayName(atPath: desk.appendingPathComponent($0).path) == shown }) {
                return (desk.appendingPathComponent(hit), "desktop display name")
            }
        }
        let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeLocalizedNameKey], options: [.skipHiddenVolumes]) ?? []
        if let v = volumes.first(where: { (try? $0.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName == shown }) {
            return (v, "volume name")
        }
        return nil
    }

    /// The element's file, as a path URL (Finder gives file reference URLs: file:///.file/id=…).
    static func fileURL(of e: AXUIElement) -> URL? {
        guard let v = e.attr(kAXURLAttribute) else { return nil }
        let u = (v as? URL) ?? (v as? NSURL).map { $0 as URL }
        guard let u, u.isFileURL else { return nil }
        return (u as NSURL).filePathURL ?? u
    }
}

/// An item in a column-view column: "name, 3 of 28", as in a list.
final class FinderColumnItem: TurnOverObject {
    override var role: Role { .listItem }
    override var positionInfo: PositionInfo? {
        guard let i = (element.attr("AXIndex") as? NSNumber)?.intValue, let parent = element.element(kAXParentAttribute) else { return nil }
        var count: CFIndex = 0
        AXUIElementGetAttributeValueCount(parent, kAXChildrenAttribute as CFString, &count)
        return PositionInfo(index: i + 1, count: count > 0 ? count : nil, level: nil)
    }
}

/// Finder's list rows as text, for the rules above and their tests.
public enum FinderRows {
    /// Acknowledge an application before sending its open key or waiting for Finder's retry.
    /// The 14 Nov 2026 Mail launch took 2.4 s to announce. AXURL on the selected item's
    /// name cell identifies app bundles without disk I/O or relying on a translated Kind column.
    public static func openSelection(in view: AXUIElement?, send: () -> Void) {
        if let view, selectedApplication(in: view) {
            Speech.speakMessage(String(localized: "opening", comment: "Spoken message"))
        }
        send()
    }

    private static func selectedApplication(in view: AXUIElement) -> Bool {
        let selected = view.elements(kAXSelectedRowsAttribute) + view.elements(kAXSelectedChildrenAttribute)
        // Inspect at most 32 nodes across selected items and their cells/name fields, never the whole file list.
        var remaining = 32
        func isApplication(_ item: AXUIElement, depth: Int) -> Bool {
            guard remaining > 0 else { return false }
            remaining -= 1
            if let url = FinderItem.fileURL(of: item) {
                return url.pathExtension.lowercased() == "app"
            }
            guard depth < 2 else { return false }
            return item.elements(kAXChildrenAttribute).prefix(32).contains { isApplication($0, depth: depth + 1) }
        }
        return selected.prefix(32).contains { isApplication($0, depth: 0) }
    }

    /// The window's file view, outside the sidebar and the toolbar (the toolbar rule's way back, and its test).
    public static func fileView(in window: AXUIElement) -> AXUIElement? { FinderAppModule.fileView(in: window) }
    public static func selectionMoved(from before: AXUIElement?, to after: AXUIElement?) -> Bool { FinderAppModule.selectionMoved(from: before, to: after) }
    /// A folder: the Kind cell says Folder, or the Size cell holds the folder's dashes (the Kind column may be hidden).
    nonisolated public static func isFolderRow(cellTexts: [String]) -> Bool {
        cellTexts.contains("Folder") || (cellTexts.count >= 3 && cellTexts[2] == "--")
    }
}
