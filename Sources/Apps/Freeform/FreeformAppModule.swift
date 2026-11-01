// SPDX-License-Identifier: GPL-3.0-or-later
// Freeform (18 Oct 2026, the Apple apps sweep). The boards are a grid (an AXCollectionList of sections of buttons,
// each board "<title>, <date>"). TurnOver's list keys read Up and Down; Left and Right moved the selection along a
// row in silence (driver). Here they send the key and read the board now chosen.
import Foundation
import ApplicationServices

final class FreeformAppModule: AppModule {
    static let bundleID = "com.apple.freeform"

    required init(pid: pid_t, bundleIdentifier: String, appName: String) {
        super.init(pid: pid, bundleIdentifier: bundleIdentifier, appName: appName)
        for key in ["leftArrow", "rightArrow"] {
            script("freeform_\(key)", key == "leftArrow" ? String(localized: "The board to the left", comment: "A command, as the key list and keyboard help say it") : String(localized: "The board to the right", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:\(key)"], category: "Freeform") { [weak self] g in
                guard let self, let grid = self.grid() else { g.send(); return }
                let before = self.chosen(in: grid)
                g.send()
                // Not waited for here: the key gets to Freeform sooner if this returns at once (a wait held it up, and
                // each move took a third of a second). Looked at shortly after, and once more if nothing moved yet.
                func look(_ tries: Int) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        if let now = self.chosen(in: grid), !(before.map { $0.isSame(now) } ?? false) {
                            Speech.cancel(); Speech.speakObject(ObjectFactory.make(now), reason: .focus)
                        } else if tries > 1 { look(tries - 1) } else { Tones.edge() }
                    }
                }
                look(4)
            }.isAvailable = { [weak self] in self?.grid() != nil }
        }
    }

    /// The board grid, when the keyboard is in it.
    private func grid() -> AXUIElement? {
        guard let f = API.focusObject, f.pid == pid else { return nil }
        var e: AXUIElement? = f.element; var hops = 0
        while let x = e, hops < 5 {
            if x.string(kAXSubroleAttribute) == "AXCollectionList" { return x }
            e = x.element(kAXParentAttribute); hops += 1
        }
        return nil
    }

    /// The board chosen in the grid: the selected one, else the one with the focus.
    private func chosen(in grid: AXUIElement) -> AXUIElement? {
        var queue = grid.elements(kAXChildrenAttribute), seen = 0
        var focused: AXUIElement?
        while !queue.isEmpty, seen < 300 {
            let e = queue.removeFirst(); seen += 1
            if e.role == "AXButton" {
                if (e.attr(kAXSelectedAttribute) as? Bool) == true { return e }
                if focused == nil, (e.attr(kAXFocusedAttribute) as? Bool) == true { focused = e }
            }
            queue.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
        return focused
    }
}
