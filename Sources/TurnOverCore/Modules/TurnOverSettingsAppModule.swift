// SPDX-License-Identifier: GPL-3.0-or-later
// TurnOver Settings, the SwiftUI app inside TurnOver.app: its controls get their labels late, and some not at all by
// the element a focus change hands over, so this module's objects look harder for a name. This used to sit in the
// generic name getter behind a bundle check; an app's quirks belong in its module (a contributor, 20 Oct 2026).
import Foundation
import ApplicationServices

final class TurnOverSettingsAppModule: AppModule {
    static let bundleID = "com.turnover.settings"
    override func objectClass(for element: AXUIElement, role: Role, subrole: String?) -> TurnOverObject.Type? { SettingsLabelledObject.self }
}

/// A control in TurnOver Settings: when it has no name, its row is asked once (SwiftUI builds the label's link only
/// when something asks for the row's contents), then the window is searched for the same control by role and frame
/// (the element a focus change hands over can be a stand-in that never gets the label: "slider, 61 percent").
final class SettingsLabelledObject: TurnOverObject {
    private var askedRow = false
    private var waitedForLabel = false

    override var name: String {
        let base = super.name
        guard base.isEmpty else { return base }
        if !askedRow, let row = element.element(kAXParentAttribute) {
            askedRow = true
            _ = row.elements(kAXChildrenAttribute)
            if let l = swiftUILabel() { return l }
        }
        // A switch arrives the same way: Tab forward from the sidebar, after arrowing to the section, handed over a
        // stand-in AXButton with no name ("switch, on"), while the real control at the same place is an AXCheckBox
        // whose label is its description (25 Oct 2026). So the label is also taken from a title or description.
        if !waitedForLabel, Thread.isMainThread, [.popUpButton, .slider, .checkBox, .comboBox, .radioButton, .spinButton, .editableText, .switchControl].contains(role),
           let mine = Self.frame(element), let window = element.element(kAXWindowAttribute) {
            waitedForLabel = true
            var queue = [window], seen = 0
            let wanted = element.role
            // Only the switch stand-in matches across roles (a switch that came as AXButton, matched to an AXCheckBox),
            // and only a single named control at that place counts: two would be a guess (a code review, 25 Oct 2026).
            let roles: Set<String> = role == .switchControl ? ["AXCheckBox", "AXButton"] : [wanted]
            var found: [String] = []
            while !queue.isEmpty, seen < 600 {
                let e = queue.removeFirst(); seen += 1
                if roles.contains(e.role), !e.isSame(element), let f = Self.frame(e), f == mine {
                    let candidates = [e.element(kAXTitleUIElementAttribute)?.string(kAXValueAttribute), e.string(kAXTitleAttribute), e.string(kAXDescriptionAttribute)]
                    if let l = candidates.compactMap({ $0?.trimmingCharacters(in: CharacterSet(charactersIn: ": \n")) }).first(where: { !$0.isEmpty && $0.count <= 120 }) {
                        found.append(l)
                        if found.count > 1 { break }
                    }
                }
                queue.append(contentsOf: e.elements(kAXChildrenAttribute))
            }
            if found.count == 1 { return found[0] }
        }
        return rawName
    }
}
