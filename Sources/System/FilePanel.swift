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

    /// One look at the panel's folder: its value, no answer (timed out, or the pop-up gone with the panel still
    /// there), or the panel closed.
    package enum Read: Equatable { case value(String), failed, closed }

    /// What the watch does after a step.
    package enum Outcome: Equatable { case skipped, value(String), unanswered, closed, gaveUp }

    /// The watch's pace (17 Nov 2026, the coordinator's review): it runs on the main thread, and each look can wait a
    /// quarter of a second. After a look that is not answered, none for 2 s; after three in a row, the watch ends. The
    /// pop-up is looked for again at most once every 2 s. A clock and the looks are passed in, for the tests.
    package struct LookPacing {
        package private(set) var gaveUp = false
        private var unansweredInARow = 0
        private var quietUntil = -Double.infinity
        private var lastSearch = -Double.infinity
        nonisolated package init() {}

        nonisolated package mutating func step(at now: Double, hasPopUp: Bool, read: () -> Read, find: () -> Bool) -> Outcome {
            guard !gaveUp else { return .gaveUp }
            guard now >= quietUntil else { return .skipped }
            if !hasPopUp {
                guard now - lastSearch >= 2 else { return .skipped }
                lastSearch = now
                let found = find()
                guard found else { return unanswered(at: now) }
            }
            switch read() {
            case .closed:
                return .closed
            case .failed:
                return unanswered(at: now)
            case .value(let text):
                unansweredInARow = 0
                return .value(text)
            }
        }

        nonisolated private mutating func unanswered(at now: Double) -> Outcome {
            unansweredInARow += 1
            quietUntil = now + 2
            if unansweredInARow >= 3 { gaveUp = true; return .gaveUp }
            return .unanswered
        }
    }

    /// The panel's folder as it changes (Option Command L, Command Shift D, a folder chosen, Go to Folder): the new
    /// folder's name, once it has held for 0.3 s and is not the one said last. Fed the folder pop-up's value.
    package struct FolderChange {
        package private(set) var said: String?
        private var pending: (value: String, since: Double)?
        package init(said: String?) { self.said = said }

        package mutating func note(_ value: String?, at now: Double) -> String? {
            let v = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !v.isEmpty else { pending = nil; return nil }   // the pop-up gone or between values
            guard v != said else { pending = nil; return nil }
            guard let p = pending, p.value == v else { pending = (v, now); return nil }
            guard now - p.since >= 0.3 else { return nil }
            said = v
            pending = nil
            return v
        }
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
        FilePanelFolderWatch.start(panel: element, popUp: reading.folderPopUp, folder: reading.folder)
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

/// While a panel is open: its folder pop-up looked at five times a second (two questions), and a new folder said once
/// while the focus is in the panel. Ends when the panel closes, another opens, after ten minutes, or after three
/// looks in a row that the panel did not answer.
enum FilePanelFolderWatch {
    private static var timer: DispatchSourceTimer?
    private static var panel: AXUIElement?
    private static var popUp: AXUIElement?
    private static var change = FilePanel.FolderChange(said: nil)
    private static var pacing = FilePanel.LookPacing()
    private static var startedAt = Date()

    static func start(panel: AXUIElement, popUp: AXUIElement?, folder: String?) {
        stop()
        Self.panel = panel
        Self.popUp = popUp
        Self.change = FilePanel.FolderChange(said: folder)
        Self.pacing = FilePanel.LookPacing()
        Self.startedAt = Date()
        // A busy app answers late: a quarter of a second, then the look counts as unanswered.
        AXUIElementSetMessagingTimeout(panel, 0.25)
        if let popUp { AXUIElementSetMessagingTimeout(popUp, 0.25) }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.2, repeating: 0.2)
        t.setEventHandler { tick() }
        t.resume()
        timer = t
    }

    static func stop() {
        timer?.cancel()
        timer = nil
        panel = nil
        popUp = nil
    }

    /// One look: the panel still there, then the pop-up's value. Closed only when the panel is gone for certain.
    private static func read(_ panel: AXUIElement) -> FilePanel.Read {
        var role: CFTypeRef?
        let panelError = AXUIElementCopyAttributeValue(panel, kAXRoleAttribute as CFString, &role)
        if panelError == .invalidUIElement { return .closed }
        guard panelError == .success else { return .failed }   // .cannotComplete: timed out
        guard let popUp else { return .failed }
        var value: CFTypeRef?
        let popUpError = AXUIElementCopyAttributeValue(popUp, kAXValueAttribute as CFString, &value)
        if popUpError == .invalidUIElement { Self.popUp = nil }   // redrawn: looked for again, at most every 2 s
        guard popUpError == .success, let text = value as? String else { return .failed }
        return .value(text)
    }

    private static func findPopUp(_ panel: AXUIElement) -> Bool {
        popUp = FilePanelDialog.lightReading(of: panel).folderPopUp
        if let popUp { AXUIElementSetMessagingTimeout(popUp, 0.25) }
        return popUp != nil
    }

    private static func tick() {
        guard let panel else { stop(); return }
        if Date().timeIntervalSince(startedAt) > 600 { stop(); return }
        let now = ProcessInfo.processInfo.systemUptime
        let outcome = pacing.step(at: now, hasPopUp: popUp != nil, read: { read(panel) }, find: { findPopUp(panel) })
        switch outcome {
        case .skipped, .unanswered:
            return
        case .closed:
            stop()
        case .gaveUp:
            Log.io("file panel: the panel did not answer three looks in a row; its folder is no longer watched")
            stop()
        case .value(let text):
            guard let folder = change.note(text, at: now) else { return }
            // Said only while the focus is in the panel; a change seen meanwhile is not said later.
            let focusInPanel = API.focusObject is FilePanelDialog || API.focusAncestors.contains { $0 is FilePanelDialog }
            guard focusInPanel else { return }
            Log.io("file panel: the folder changed; saying it")
            Speech.speakMessage(folder)
        }
    }
}
