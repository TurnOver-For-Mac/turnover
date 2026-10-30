// SPDX-License-Identifier: GPL-3.0-or-later
// An app described as parts by its recipe (PanesView): Tab and Shift Tab round the parts, Command Control 1 to 9 to one.
import Foundation
import AppKit
import ApplicationServices

final class PanesAppModule: AppModule {
    private var view: PanesView!

    required init(pid: pid_t, bundleIdentifier: String, appName: String) {
        super.init(pid: pid, bundleIdentifier: bundleIdentifier, appName: appName)
        guard let panes = Recipes.recipe(for: bundleIdentifier)?.view.panes else { Log.error("panes module for \(bundleIdentifier) with no panes recipe: the registry is stale"); fatalError("no panes recipe for \(bundleIdentifier)") }
        view = PanesView(pid: pid, panes: panes)
        let cat = appName
        // In this app, not in a menu or a dialog, and not while TurnOver's own menu is up.
        let active: () -> Bool = { [weak self] in
            guard self != nil, API.focusPid == pid, !AXHandler.shared.isMenuOpen, !TurnOverMenu.shared.isOpen else { return false }
            if let f = API.focusObject, f.role == .dialog || f.role == .sheet || API.focusAncestors.contains(where: { $0.role == .dialog || $0.role == .sheet }) { return false }
            return true
        }
        script("panes_next", String(localized: "The next part of the window: \(panes.parts.map(\.name).joined(separator: ", "))", comment: "A command: %@ lists the window's parts"), gestures: ["kb:tab"], category: cat) { [weak self] _ in self?.view.step(forward: true) }.isAvailable = active
        script("panes_previous", String(localized: "The previous part of the window", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+tab"], category: cat) { [weak self] _ in self?.view.step(forward: false) }.isAvailable = active
        for (i, part) in panes.parts.prefix(9).enumerated() {
            script("panes_part\(i + 1)", String(localized: "Straight to \(part.name)", comment: "A command: %@ is a part of the window"), gestures: ["kb:control+command+\(i + 1)"], category: cat) { [weak self] _ in self?.view.go(to: i) }.isAvailable = active
        }
        // (No key of its own: VO Shift W is VoiceOver's "read window" in the Mac style; it is in the shortcuts list.)
        script("panes_where", String(localized: "Says which part of the window you are in", comment: "A command, as the key list and keyboard help say it"), gestures: [], category: cat) { [weak self] _ in
            guard let self else { return }
            Speech.speakMessage(view.whereAmI())
        }.isAvailable = active
    }
}
