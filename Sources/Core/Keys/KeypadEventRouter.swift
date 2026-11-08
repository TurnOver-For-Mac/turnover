// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics

/// The production keypad event boundary, shared by both taps. A down decides ownership until its up;
/// a modifier or settings change in between cannot turn an app's key release into a reader command.
nonisolated public struct KeypadEventRouter: Sendable {
    public enum Decision: Sendable {
        case unhandled, consume, toggleNumbers
        case command(KeyboardGesture, String)
    }
    private var downs: [Int64: Decision] = [:]
    private var zeroHeld = false
    public init() {}
    public mutating func reset() { downs.removeAll(); zeroHeld = false }

    /// The adapter has completed downstream lookup and delivered the down to an app. Its
    /// KeypadApplicationStream now owns repeats/up; this provisional entry must not survive it.
    public mutating func passedToApplication(code: Int64) {
        if case .unhandled? = downs[code] { downs.removeValue(forKey: code) }
    }


    public mutating func route(_ type: CGEventType, code: Int64, flags: CGEventFlags,
                               isRepeat: Bool, settings: KeySettings, modifierHeld: Bool,
                               passNext: Bool = false, asleep: Bool = false, capturing: Bool = false,
                               modeOnly: Bool = false) -> Decision {
        guard Keypad.codes.contains(code), type == .keyDown || type == .keyUp else { return .unhandled }
        if type == .keyUp {
            if code == Keypad.zero { zeroHeld = false }
            guard let owner = downs.removeValue(forKey: code) else { return .unhandled }
            if case .unhandled = owner { return .unhandled }
            return .consume
        }
        if let owner = downs[code] {
            if case .command(let g, let action) = owner {
                return .command(KeyboardGesture(keyCode: g.keyCode, modifiers: g.modifiers, characters: g.characters,
                                                timestamp: g.timestamp, isRepeat: true, flags: g.flags), action)
            }
            if case .unhandled = owner { return .unhandled }
            return .consume
        }
        let decision: Decision
        if isRepeat || passNext || asleep || capturing {
            decision = .unhandled
        } else if settings.windowsKeys, code == Keypad.clear, !modifierHeld,
                  flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift]).isEmpty {
            decision = .toggleNumbers
        } else if modeOnly || !(settings.windowsKeys ? settings.keypadCommands : settings.numpadCommander) {
            zeroHeld = false
            decision = .unhandled
        } else if code == Keypad.zero {
            zeroHeld = !settings.insertIsTurnOver
            decision = zeroHeld ? .consume : .unhandled
        } else {
            var mods = Modifiers()
            if flags.contains(.maskShift) { mods.insert(.shift) }
            if flags.contains(.maskCommand) { mods.insert(.command) }
            if flags.contains(.maskControl) { mods.insert(.control) }
            if flags.contains(.maskAlternate) { mods.insert(.option) }
            let vo = mods.contains(.control) && mods.contains(.option)
            if vo && !settings.windowsKeys { decision = .unhandled }
            else {
                if vo && settings.controlOptionIsTurnOver { mods.remove(.control); mods.remove(.option); mods.insert(.turnover) }
                if modifierHeld || zeroHeld { mods.insert(.turnover) }
                let g = KeyboardGesture(keyCode: code, modifiers: mods, characters: "", timestamp: 0, isRepeat: false, flags: flags)
                if let action = Keypad.action(for: g, windows: settings.windowsKeys,
                                              jawsDesktop: settings.keyboardStyle == .jaws && settings.desktopLayout) {
                    decision = .command(g, action)
                } else { decision = .unhandled }
            }
        }
        downs[code] = decision
        return decision
    }
}
