// SPDX-License-Identifier: GPL-3.0-or-later
// A list that will not take the keyboard (Finder's sidebar), held by TurnOver while its cursor is in it: the
// arrows, Return and Space are TurnOver's there (ObjectNavigator.hold). A global plugin, so these come before the
// focused list's own keys (the file list still has the keyboard).
import Foundation

final class HeldListPlugin: GlobalPlugin {
    required init() {
        super.init()
        let cat = "Object navigation"
        // A list that will not take the keyboard, held by TurnOver while its cursor is in it (Finder's sidebar).
        for (name, desc, keys, run) in [
            ("held_previous", "In a list TurnOver is holding: the previous item", ["kb:upArrow"], { ObjectNavigator.shared.heldMove(-1) }),
            ("held_next", "In a list TurnOver is holding: the next item", ["kb:downArrow"], { ObjectNavigator.shared.heldMove(1) }),
            ("held_first", "In a list TurnOver is holding: the first item", ["kb:home", "kb:command+upArrow"], { ObjectNavigator.shared.heldEdge(last: false) }),
            ("held_last", "In a list TurnOver is holding: the last item", ["kb:end", "kb:command+downArrow"], { ObjectNavigator.shared.heldEdge(last: true) }),
            ("held_choose", "In a list TurnOver is holding: chooses the item", ["kb:enter", "kb:space"], { ObjectNavigator.shared.heldChoose() }),
            ("held_collapse", "In a list TurnOver is holding: closes the item", ["kb:leftArrow"], { ObjectNavigator.shared.heldDisclose(open: false) }),
            ("held_expand", "In a list TurnOver is holding: opens the item", ["kb:rightArrow"], { ObjectNavigator.shared.heldDisclose(open: true) }),
        ] as [(String, String, [String], () -> Void)] {
            script(name, desc, gestures: keys, category: cat) { _ in run() }.isAvailable = { ObjectNavigator.shared.isHolding }
        }
        script("held_tab", String(localized: "In a list TurnOver is holding: on to the next part of the window", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:tab"], category: cat) { _ in
            ObjectNavigator.shared.leaveHold(forward: true)
        }.isAvailable = { ObjectNavigator.shared.isHolding }
        script("held_shiftTab", String(localized: "In a list TurnOver is holding: back to the previous part of the window", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+tab"], category: cat) { _ in
            ObjectNavigator.shared.leaveHold(forward: false)
        }.isAvailable = { ObjectNavigator.shared.isHolding }
        script("held_leave", String(localized: "In a list TurnOver is holding: back to the keyboard focus", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:escape"], category: cat) { _ in
            ObjectNavigator.shared.releaseHold(); ObjectNavigator.shared.toFocus()
        }.isAvailable = { ObjectNavigator.shared.isHolding }
    }
}
