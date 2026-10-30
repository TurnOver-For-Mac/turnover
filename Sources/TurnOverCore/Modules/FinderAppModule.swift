// SPDX-License-Identifier: GPL-3.0-or-later
// Finder in the Windows keyboard style: Return opens the selection, as in Windows Explorer (Finder's own Return
// renames, and Command+Down opens); F2 or Shift Return renames. In the Mac style, Finder's own keys. Only in a file view of a
// Finder window: in the rename field, the search field, the sidebar, a sheet or
// a dialog, Return is Return.
import Foundation
import UniformTypeIdentifiers
import ApplicationServices
import AppKit

final class FinderAppModule: AppModule {
    static let bundleID = "com.apple.finder"

    required init(pid: pid_t, bundleIdentifier: String, appName: String) {
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
            self?.sendAgainIfIgnored(g, what: "Command Down", foldersOnly: true)
        }.isAvailable = { [weak self] in
            guard let self, inFileView(), let f = API.focusObject else { return false }
            return !(f.element.elements(kAXSelectedRowsAttribute) + f.element.elements(kAXSelectedChildrenAttribute)).isEmpty
        }
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

    private func window() -> AXUIElement? { AXUIElementCreateApplication(pid).element(kAXFocusedWindowAttribute) }

    /// The desktop's icons and an icon view's are pictures to accessibility ("graphic"): read them as files, by kind.
    override func objectClass(for element: AXUIElement, role: Role, subrole: String?) -> TurnOverObject.Type? {
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
        if v?.isVolume == true { return "volume" }
        if v?.isAliasFile == true { return "alias" }
        guard let k = v?.localizedTypeDescription, !k.isEmpty else { return v?.isDirectory == true ? "folder" : nil }
        // "Folder" → "folder"; a name ("Microsoft Word document", "PDF document") stays as it is.
        let first = k.split(separator: " ").first.map(String.init) ?? k
        return first.dropFirst().allSatisfy(\.isLowercase) && !["Microsoft", "Apple", "Adobe", "QuickTime", "Keynote", "Pages", "Numbers"].contains(first)
            ? k.prefix(1).lowercased() + k.dropFirst() : k
    }()

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
    /// A folder: the Kind cell says Folder, or the Size cell holds the folder's dashes (the Kind column may be hidden).
    nonisolated public static func isFolderRow(cellTexts: [String]) -> Bool {
        cellTexts.contains("Folder") || (cellTexts.count >= 3 && cellTexts[2] == "--")
    }
}
