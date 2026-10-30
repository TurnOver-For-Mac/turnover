// SPDX-License-Identifier: GPL-3.0-or-later
// Contacts (18 Oct 2026, the Apple apps sweep). What Contacts gives accessibility (probe, names masked): the people
// as an outline ("personList"), each row "level 2"; a search field; and the chosen person's card, a SwiftUI pane
// (identifier "contactDetailPane") whose scroll area holds the name as a heading, the quick actions (message, call,
// video, mail), each detail as a label and a text area (mobile, email, address…), and buttons (Share Contact…).
// Tab from the list went to the search field and the card's buttons, never to the details (driver).
// What TurnOver changes:
// - A person in the list is said without "level 2".
// - Tab from the list goes into the card, read as a document: Down through the name, each detail, the buttons;
//   Return presses a button. Shift-Tab goes back to the list.
import Foundation
import ApplicationServices

final class ContactsAppModule: AppModule {
    static let bundleID = "com.apple.AddressBook"

    required init(pid: pid_t, bundleIdentifier: String, appName: String) {
        super.init(pid: pid, bundleIdentifier: bundleIdentifier, appName: appName)
        script("contacts_toCard", String(localized: "From the list to the person's card, read as a page", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:tab"], category: "Contacts") { [weak self] _ in
            guard let self, let card = self.card() else { Tones.edge(); return }
            AXHandler.shared.focusChanged(card, pid: self.pid)
        }.isAvailable = { [weak self] in self?.inList() == true }
        script("contacts_toList", String(localized: "From the card back to the list", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+tab"], category: "Contacts") { [weak self] _ in
            guard let self, let list = self.list() else { return }
            _ = list.set(kAXFocusedAttribute, kCFBooleanTrue)
            AXHandler.shared.focusChanged(list, pid: self.pid)
        }.isAvailable = { [weak self] in self?.inCard() == true }
    }

    private func window() -> AXUIElement? { AXUIElementCreateApplication(pid).element(kAXFocusedWindowAttribute) }

    private func find(_ id: String, in root: AXUIElement?, limit: Int = 60) -> AXUIElement? {
        guard let root else { return nil }
        var queue = [root], seen = 0
        while !queue.isEmpty, seen < limit {
            let e = queue.removeFirst(); seen += 1
            if e.string(kAXIdentifierAttribute) == id { return e }
            // Not into the list's hundreds of rows.
            if e.role != "AXOutline" { queue.append(contentsOf: e.elements(kAXChildrenAttribute)) }
        }
        return nil
    }
    private func list() -> AXUIElement? { find("personList", in: window()) }
    /// The card's contents: the scroll area inside the detail pane.
    private func card() -> AXUIElement? {
        guard let pane = find("contactDetailPane", in: window()) else { return nil }
        var queue = [pane], seen = 0
        while !queue.isEmpty, seen < 20 {
            let e = queue.removeFirst(); seen += 1
            if e.role == "AXScrollArea" { return e }
            queue.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
        return nil
    }

    private func inList() -> Bool {
        guard let f = API.focusObject, f.pid == pid, let l = list() else { return false }
        var e: AXUIElement? = f.element; var hops = 0
        while let x = e, hops < 5 { if x.isSame(l) { return true }; e = x.element(kAXParentAttribute); hops += 1 }
        return false
    }
    private func inCard() -> Bool {
        guard let doc = API.focusTreeInterceptor, doc.webArea.pid == pid, let c = card() else { return false }
        return doc.webArea.isSame(c)
    }

    /// The card is read as a document whenever the focus is on it or inside it.
    override func browseRoot(for element: AXUIElement, ancestors: [TurnOverObject]) -> AXUIElement? {
        guard let c = card() else { return nil }
        if element.isSame(c) || ancestors.contains(where: { $0.element.isSame(c) }) { return c }
        return nil
    }

    /// The card taking the focus says its first line (the person's name), not "scroll area".
    override func handleEvent(_ event: Event, next: () -> Void) {
        next()
        guard event.kind == .gainFocus, event.obj.pid == pid, event.obj.element.role == "AXScrollArea",
              let c = card(), event.obj.element.isSame(c) else { return }
        DispatchQueue.main.async {
            guard let doc = API.focusTreeInterceptor, doc.webArea.isSame(c), !doc.passThrough else { return }
            Speech.cancel()
            doc.position = 0
            doc.speakUnit(.line)
        }
    }

    override func objectClass(for element: AXUIElement, role: Role, subrole: String?) -> TurnOverObject.Type? {
        [.treeViewItem, .tableRow].contains(role) ? RowWithoutLevel.self : nil
    }
}

/// A row said without its outline level ("level 2" on every name in Contacts' list).
final class RowWithoutLevel: TurnOverObject {
    override var positionInfo: PositionInfo? {
        guard var p = super.positionInfo else { return nil }
        p.level = nil
        return p
    }
}
