// SPDX-License-Identifier: GPL-3.0-or-later
// The eight things a plugin script may be allowed to do (docs/PLUGIN-SCRIPTS-PLAN.md, "The clear line"), and which
// of them each operation needs. TurnOver checks the table on every request, so a script cannot do more than its
// manifest asked and the person agreed to. The sentences said at approval belong to a later stage.
import Foundation
import TurnOverPluginWire

nonisolated public enum ScriptAbility: String, CaseIterable, Sendable, Comparable {
    /// The names, roles and values of items in the plugin's apps.
    case read
    /// Speak, and play TurnOver's own sounds.
    case say
    case press
    case focus
    case menu
    case keys
    /// Change an item's text or value.
    case edit
    /// Put text on the clipboard, never read it.
    case clipboard

    public static func < (a: ScriptAbility, b: ScriptAbility) -> Bool { a.rawValue < b.rawValue }
}

public typealias ScriptOperation = PluginWire.Operation

nonisolated public enum ScriptAbilities {
    /// What an operation needs, all of it. Logging, and the plugin's own stored data, need nothing: they reach
    /// nothing outside the plugin.
    public static func required(for operation: ScriptOperation) -> Set<ScriptAbility> {
        switch operation {
        case .say, .sound: return [.say]
        case .log, .storageGet, .storageSet, .storageRemove: return []
        case .focused, .find, .itemRefresh, .itemParent, .itemChildren: return [.read]
        case .itemRead: return [.read, .say]   // it reads the item and speaks it
        case .itemPress: return [.press]
        case .itemFocus: return [.focus]
        case .itemSetValue: return [.edit]
        case .menu: return [.menu]
        case .keys: return [.keys]
        case .copy: return [.clipboard]
        }
    }

    /// The abilities an operation needs that the plugin does not have, in a fixed order.
    public static func missing(for operation: ScriptOperation, granted: Set<ScriptAbility>) -> [ScriptAbility] {
        required(for: operation).subtracting(granted).sorted()
    }
}
