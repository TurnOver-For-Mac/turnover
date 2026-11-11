// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics

/// Insert is an ordinary key on macOS, so its down/up events must become a held reader modifier.
/// Owned by the calling keyboard thread. Consumed downs retain their matching ups even if settings change.
nonisolated public struct InsertKeyState: Sendable {
    private var enabled = false
    private var keypadEnabled = false
    private var held: Set<Int64> = []
    private var consumed: Set<Int64> = []
    public init() {}
    public var isHeld: Bool { !held.isEmpty }
    public var separateInsertIsHeld: Bool { held.contains(114) }

    public mutating func update(enabled: Bool, keypadEnabled: Bool) {
        self.enabled = enabled
        self.keypadEnabled = keypadEnabled
        held = held.filter { accepts($0) }
    }

    private func accepts(_ code: Int64) -> Bool {
        // kVK_Help (114) is Insert on a PC keyboard; a Mac number pad reports zero as 82.
        enabled && (code == 114 || (code == 82 && keypadEnabled))
    }

    /// True means consume this event. Repeats cannot turn an already-held ordinary key into a new modifier.
    public mutating func handle(_ type: CGEventType, code: Int64, isRepeat: Bool = false) -> Bool {
        if type == .keyUp {
            held.remove(code)
            return consumed.remove(code) != nil
        }
        guard type == .keyDown else { return false }
        if consumed.contains(code) { return true }
        guard accepts(code), !isRepeat else { return false }
        held.insert(code)
        consumed.insert(code)
        return true
    }

    public func addingModifier(to modifiers: Modifiers) -> Modifiers {
        isHeld ? modifiers.union(.turnover) : modifiers
    }

    /// A stopped or bypassed tap must not retain a modifier whose release it could have missed.
    public mutating func reset() {
        held.removeAll()
        consumed.removeAll()
    }
}
