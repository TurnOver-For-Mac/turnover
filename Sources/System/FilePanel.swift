// SPDX-License-Identifier: GPL-3.0-or-later
// The Open and Save panels (17 Nov 2026). Every app's panel is drawn by one system service,
// com.apple.appkit.xpc.openAndSavePanelService, and shown in the app as a sheet (Mail's Save Attachments, TextEdit's
// Save) or a window of its own (TextEdit's Open). Read as an ordinary dialog, the panel's opening walked the whole
// panel for its text: up to 600 visits to another process and a 12-level walk for its choices, through a file list
// of 70 rows. Nothing was found, the main thread was held 0.6 to 1.3 s and the keys pressed meanwhile waited behind it
// (Mail, 17 Nov 2026, 15:44). The panel's own window inside the sheet was then said as a second dialog.
// Here the panel is read the light way: its title and the folder it is in, once. Only for the service's panels: the
// service must be serving the app in front, by its bundle id; every other dialog keeps Dialog's reading.
import Foundation
import ApplicationServices
import AppKit

/// The parts that decide, without asking any app (for the tests).
package enum FilePanel {
    nonisolated package static let serviceBundle = "com.apple.appkit.xpc.openAndSavePanelService"

    /// The folder the panel shows: the first pop-up with a value, in the order the light walk meets them. A Save
    /// panel's first pop-up is Where; an Open panel's is the folder pop-up in its toolbar (17 Nov 2026: a [guess],
    /// not yet recorded; the log line "file panel: read lightly" says how many pop-ups were met).
    nonisolated package static func folder(popUpValues: [String]) -> String? {
        let trimmed = popUpValues.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return trimmed.first { !$0.isEmpty }
    }

    /// What is said as the panel opens: its title, the word for a dialog, and the folder.
    nonisolated package static func openingWords(title: String, dialogWord: String, folder: String?) -> String {
        let parts = [title, dialogWord, folder ?? ""]
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// The panel has two parts that each come as a dialog: the app's sheet (or window) and the service's window
    /// inside it. Said once: the same part within a minute, or another part said within a minute that still shows.
    nonisolated package static func staysSilent(isSamePart: Bool, secondsSinceSaid: Double, saidPartStillShows: Bool) -> Bool {
        let recently = secondsSinceSaid < 60
        if isSamePart { return recently }
        return recently && saidPartStillShows
    }

}

/// Which dialogs are the panel. Main thread or any: the answers are kept under a lock.
enum FilePanelDetector {
    nonisolated(unsafe) private static var known: [(AXUIElement, Bool)] = []   // under `lock`
    nonisolated private static let lock = NSLock()

    static func isPanel(_ e: AXUIElement) -> Bool {
        lock.lock()
        let hit = known.first { $0.0.isSame(e) }
        lock.unlock()
        if let hit { return hit.1 }
        // No panel service serving the app in front: no, and not kept (the service may start a moment later).
        guard let answer = look(e) else { return false }
        lock.lock()
        known.append((e, answer))
        if known.count > 16 { known.removeFirst() }
        lock.unlock()
        return answer
    }

    /// The service's processes serving the app in front ("Open and Save Panel Service (Mail)"). No question to any app.
    private static func servicePidsForFrontApp() -> [pid_t] {
        let frontName = NSWorkspace.shared.frontmostApplication?.localizedName
        let services = NSRunningApplication.runningApplications(withBundleIdentifier: FilePanel.serviceBundle)
        let serving = services.filter {
            AXHandler.servesPanel(helperBundle: $0.bundleIdentifier, helperName: $0.localizedName, frontName: frontName)
        }
        return serving.map(\.processIdentifier)
    }

    /// A few questions at most: its parent, and for a sheet or dialog its children's roles.
    private static func look(_ e: AXUIElement) -> Bool? {
        let servicePids = servicePidsForFrontApp()
        guard !servicePids.isEmpty else { return nil }   // no panel serves the app in front: an ordinary dialog
        // The service's own element (TextEdit's panel arrives from the service's process).
        if servicePids.contains(e.pid) { return true }
        // The service's window as the app hosts it: its parent is the service's application, or the app's sheet.
        let parent = e.element(kAXParentAttribute)
        let parentRole = parent?.role ?? ""
        if parentRole == "AXApplication", let parent, servicePids.contains(parent.pid) { return true }
        let isWindow = e.role == "AXWindow"
        if isWindow, parentRole == "AXSheet" { return true }   // a window inside a sheet is a hosted one
        // The app's sheet or window holding the service's window.
        let children = e.elements(kAXChildrenAttribute).prefix(8)
        return children.contains { $0.role == "AXWindow" }
    }
}

/// Puts the panel's dialogs in the hands of FilePanelDialog.
final class FilePanelPlugin: GlobalPlugin {
    override func objectClass(for element: AXUIElement, role: Role, subrole: String?) -> TurnOverObject.Type? {
        guard role == .dialog || role == .sheet else { return nil }   // every other element: no question at all
        guard FilePanelDetector.isPanel(element) else { return nil }
        return FilePanelDialog.self
    }
}

/// The Open or Save panel: its title and folder, said once, with no walk of its file list.
final class FilePanelDialog: Dialog {
    /// The part of the panel last said, when, and the pop-up its folder was read from.
    static var said: (part: AXUIElement, at: Date)?   // main thread

    /// Never the whole-panel walk (its file list is no message).
    override var dialogText: String { "" }

    override var description: String? { Self.lightReading(of: element).folder }

    override func event_focusEntered() { sayOnce() }
    override func event_gainFocus() { sayOnce() }

    private func sayOnce() {
        let now = Date()
        if let said = Self.said {
            let isSamePart = said.part.isSame(element)
            let seconds = now.timeIntervalSince(said.at)
            // One question, only when it can matter: whether the part said before still shows.
            let stillShows = !isSamePart && seconds < 60 && said.part.role != "?"
            if FilePanel.staysSilent(isSamePart: isSamePart, secondsSinceSaid: seconds, saidPartStillShows: stillShows) {
                Log.io("file panel: \(axRole) already said as part of this panel; not said again")
                return
            }
        }
        Self.said = (element, now)
        Dialog.spokenAt = (element, now)
        let reading = Self.lightReading(of: element)
        let title = name.isEmpty ? reading.innerTitle : name
        Speech.speakMessage(FilePanel.openingWords(title: title, dialogWord: Role.dialog.displayString, folder: reading.folder))
    }

    /// The light walk: at most 30 elements, never into the file list, the sidebar or a text area.
    struct LightReading { var folder: String?; var innerTitle: String; var folderPopUp: AXUIElement? }
    static let notEntered: Set<String> = ["AXOutline", "AXTable", "AXList", "AXBrowser", "AXScrollArea", "AXRow", "AXCell",
                                          "AXWebArea", "AXTextArea", "AXTextField", "AXSearchField", "AXComboBox"]

    static func lightReading(of panel: AXUIElement) -> LightReading {
        var queue = panel.elements(kAXChildrenAttribute)
        var visited = 0
        var popUps: [(AXUIElement, String)] = []
        var innerTitle = ""
        while !queue.isEmpty, visited < 30 {
            let e = queue.removeFirst()
            visited += 1
            let role = e.role
            if role == "AXPopUpButton" {
                popUps.append((e, e.string(kAXValueAttribute) ?? ""))
                continue
            }
            if role == "AXWindow", innerTitle.isEmpty { innerTitle = e.string(kAXTitleAttribute) ?? "" }
            if notEntered.contains(role) { continue }
            queue.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
        let folder = FilePanel.folder(popUpValues: popUps.map(\.1))
        let popUp = popUps.first { $0.1.trimmingCharacters(in: .whitespacesAndNewlines) == folder }?.0
        Log.io("file panel: read lightly from \(visited) elements; \(popUps.count) pop-ups, folder \(folder == nil ? "not found" : "found")")
        return LightReading(folder: folder, innerTitle: innerTitle, folderPopUp: popUp)
    }
}

