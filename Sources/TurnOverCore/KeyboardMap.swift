// SPDX-License-Identifier: GPL-3.0-or-later
// The editor's command catalogue is a snapshot of script declarations, never a second command registry.
import Foundation
import TurnOverControl

public struct KeyboardMap {
    public struct Source {
        var commands: [KeyboardEditing.Command]
        var bindings: [(String, [String])]
        var active: [(String, String)]
        var reference: String?

        public init(_ owner: ScriptableObject, reference: String? = nil, ancestor: Bool = false) {
            let scripts = owner.allScripts.filter { !$0.description.isEmpty && !$0.name.hasPrefix("test_") && (!ancestor || $0.canPropagate) }
            let names = Set(scripts.map(\.name))
            commands = scripts.map { .init(id: $0.name, title: $0.description, category: $0.category, keys: []) }
            bindings = owner.everyBinding.map { ($0.0, $0.1.map(\.name).filter { names.contains($0) }) }
            // Each availability check is made once, while its application is still in front. Settings must not
            // repeatedly ask a background application's accessibility tree while drawing the command list.
            var available: [String: Bool] = [:]
            for (_, candidates) in owner.everyBinding {
                for s in candidates where names.contains(s.name) && available[s.name] == nil {
                    available[s.name] = s.isAvailable?() ?? true
                }
            }
            active = bindings.compactMap { id, names in names.first { available[$0] == true }.map { (id, $0) } }
            self.reference = reference
        }
    }

    private var commands: [String: KeyboardEditing.Command] = [:]
    private var defaults: [String: String] = [:]
    private var sayAllDefaults: [String: String] = [:]
    private var references: [(id: String, command: String, style: String)] = []
    private let layout: String

    public init(sources: [Source], layout: String, keypad: [(String, String)] = [],
                keypadReferences: [(String, String, String)] = [], styleKeys: [String: String] = [:],
                sayAllKeys: [String: String] = [:]) {
        self.layout = layout
        for source in sources {
            for command in source.commands where commands[command.id] == nil { commands[command.id] = command }
            // Layout-specific bindings precede the general binding within each owner, just as script(for:) does.
            for (id, name) in source.active.sorted(by: { $0.0.hasPrefix("kb(") && !$1.0.hasPrefix("kb(") }) {
                guard let key = keyInLayout(id), defaults[key] == nil else { continue }
                defaults[key] = name
            }
            if let style = source.reference {
                for (id, names) in source.bindings {
                    guard let key = keyInLayout(id) else { continue }
                    // The latest declaration is the style's default. Older declarations on the same key are
                    // fallbacks, not additional conflicting assignments (for example NVDA+F versus Find).
                    if let name = names.first { references.append((key, name, style)) }
                }
            }
        }
        let base = defaults
        for (id, value) in sayAllKeys {
            guard let key = keyInLayout(id) else { continue }
            let name = value.hasPrefix("=") ? keyInLayout(String(value.dropFirst())).flatMap { base[$0] } : value
            if let name, commands[name] != nil { sayAllDefaults[key] = name }
        }
        for (id, value) in styleKeys {
            guard let key = keyInLayout(id) else { continue }
            let name = value.hasPrefix("=") ? keyInLayout(String(value.dropFirst())).flatMap { base[$0] } : value
            if let name, commands[name] != nil { defaults[key] = name }
        }
        // The keypad is handled before ordinary bindings by the keyboard tap.
        for (id, name) in keypad where commands[name] != nil { defaults[id] = name }
        for (id, name, style) in keypadReferences where commands[name] != nil { references.append((id, name, style)) }
        if config.keyboard.optionCommander {
            for (id, target) in UserGestures.defaults {
                if case .script(let name) = UserGestures.Target(target) { defaults[id] = name }
            }
        }
    }

    private func keyInLayout(_ id: String) -> String? {
        let key: String
        if id.hasPrefix("kb(\(layout)):") { key = "kb:" + id.components(separatedBy: ":").dropFirst().joined(separator: ":") }
        else if id.hasPrefix("kb:") { key = UserGestures.normal(id) }
        else { return nil }
        return UserGestures.gesture(for: key) == nil ? nil : key
    }

    private func effective(_ overrides: [String: String], duringSayAll: Bool = false) -> [String: String] {
        var result = defaults
        if duringSayAll { result.merge(sayAllDefaults) { _, new in new } }
        for key in Set(overrides.keys.compactMap(keyInLayout)) {
            guard !Self.isEssential(key), let value = override(for: key, in: overrides) else { continue }
            switch UserGestures.Target(value) {
            case .script(let name) where commands[name] != nil: result[key] = name
            case .removed, .app, .shortcut, .file, .voiceOver: result[key] = nil
            default: break // An unknown or out-of-context command falls back to the built-in key.
            }
        }
        return result
    }

    private func override(for key: String, in overrides: [String: String]) -> String? {
        if key.hasPrefix("kb:rightoption+") { return overrides[key] }
        return overrides["kb(\(layout)):" + key.dropFirst(3)] ?? overrides[key]
    }

    public func state(overrides: [String: String], context: String, style: String, history: [KeyboardChange] = []) -> KeyboardEditing.State {
        var rows = commands
        let ordinary = effective(overrides)
        for (id, name) in ordinary {
            let custom = overrides[id] != nil || overrides["kb(\(layout)):" + id.dropFirst(3)] != nil
            rows[name]?.keys.append(.init(id: id, label: UserGestures.spoken(id), custom: custom, editable: !Self.isEssential(id)))
        }
        for (id, name) in effective(overrides, duringSayAll: true) where ordinary[id] != name {
            rows[name]?.keys.append(.init(id: id, label: UserGestures.spoken(id) + " (during Say All)", custom: false, editable: !Self.isEssential(id)))
        }
        for name in rows.keys { rows[name]?.keys.sort { $0.label < $1.label } }
        var covered = Set<String>()
        var changes: [KeyboardEditing.Change] = []
        for change in history.reversed() where change.isCurrent(in: overrides) {
            let affected = Set(change.entries.map(\.key))
            guard covered.isDisjoint(with: affected) else { continue }
            covered.formUnion(affected)
            changes.append(.init(id: "change:" + change.id,
                                 label: "Changed \(UserGestures.spoken(change.oldKey)) to \(UserGestures.spoken(change.newKey))",
                                 target: "Restore puts both keys back as they were before this change.", stored: "", undoID: change.id))
        }
        changes += overrides.sorted { $0.key < $1.key }.filter { !covered.contains($0.key) }.map { id, value in
            let target: String
            if case .script(let name) = UserGestures.Target(value) { target = commands[name]?.title ?? name }
            else { target = UserGestures.Target(value).map(UserGestures.describe) ?? value }
            let suffix = id.hasPrefix("kb(") ? " (\(id.dropFirst(3).prefix { $0 != ")" }) layout)" : ""
            return KeyboardEditing.Change(id: id, label: UserGestures.spoken(id) + suffix, target: target, stored: value)
        }
        return .init(commands: rows.values.sorted { ($0.category, $0.title, $0.id) < ($1.category, $1.title, $1.id) },
                     changes: changes, context: context, style: style, layout: layout)
    }

    public func candidate(_ id: String, for command: String, overrides: [String: String]) -> KeyboardEditing.Candidate {
        var warnings: [String] = []
        let generic = id.replacingOccurrences(of: "kb:rightoption+", with: "kb:option+")
        let existing = effective(overrides)[id] ?? effective(overrides)[generic]
        if let name = existing, name != command {
            warnings.append("Currently assigned to \(commands[name]?.title ?? name). Saving replaces that assignment.")
        } else if let value = override(for: id, in: overrides) ?? override(for: generic, in: overrides),
                  let target = UserGestures.Target(value), target != .script(command) {
            warnings.append("Currently \(UserGestures.describe(target)). Saving replaces that assignment.")
        }
        if let name = effective(overrides, duringSayAll: true)[id], name != existing, name != command {
            warnings.append("During Say All: \(commands[name]?.title ?? name). Saving replaces that assignment too.")
        }
        for ref in references where (ref.id == id || ref.id == generic) && ref.command != command {
            let text = "\(ref.style): \(commands[ref.command]?.title ?? ref.command)."
            if !warnings.contains(text) { warnings.append(text) }
        }
        if let g = UserGestures.gesture(for: id), g.modifiers.subtracting(.shift).isEmpty,
           g.keyName.count == 1 || ["space", "tab", "enter", "backspace", "delete", "leftArrow", "rightArrow", "upArrow", "downArrow"].contains(g.keyName) {
            warnings.append("This key normally types or moves in applications. Assigning it can take that key away wherever the command is available.")
        }
        let error = Self.isEssential(id) ? "This is an essential key or keypad modifier and cannot be changed." : nil
        return .init(id: id, label: UserGestures.spoken(id), warnings: warnings, error: error)
    }

    public func contains(command: String) -> Bool { commands[command] != nil }

    /// The mode switches and keypad modifier are handled outside ordinary command resolution.
    public static func isEssential(_ id: String) -> Bool {
        guard let g = UserGestures.gesture(for: id) else { return true }
        return UserGestures.isProtected(g) || g.keyName == "numpad0" || g.keyName == "numpadClear"
    }

    /// One transaction: changing a key also removes the old key, without revealing a hidden default beneath it.
    public func assigning(_ id: String, to command: String, replacing old: String?, in overrides: [String: String]) -> [String: String]? {
        guard contains(command: command), !Self.isEssential(id) else { return nil }
        var next = overrides
        if let old, old != id {
            guard !Self.isEssential(old), isAssigned(old, to: command, in: overrides) else { return nil }
            next[old] = "none"
            next["kb(\(layout)):" + old.dropFirst(3)] = nil
        }
        next[id] = "script:" + command
        next["kb(\(layout)):" + id.dropFirst(3)] = nil
        return next
    }

    public func removing(_ id: String, from command: String, in overrides: [String: String]) -> [String: String]? {
        guard !Self.isEssential(id), isAssigned(id, to: command, in: overrides) else { return nil }
        var next = overrides
        next[id] = "none"
        next["kb(\(layout)):" + id.dropFirst(3)] = nil
        return next
    }

    private func isAssigned(_ id: String, to command: String, in overrides: [String: String]) -> Bool {
        effective(overrides)[id] == command || effective(overrides, duringSayAll: true)[id] == command
    }
}
