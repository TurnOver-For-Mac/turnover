// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics

/// Insert is an ordinary key on macOS, so its down/up events must become a held reader modifier.
/// The caller serializes access; reader handover retains the same state. Consumed downs retain their matching ups even if settings change.
nonisolated public struct InsertKeyState: Sendable {
    private var enabled = false
    private var keypadEnabled = false
    private var held: Set<Int64> = []
    private var eligible: Set<Int64> = []
    private var captured: [Int64: UInt64] = [:]
    private var consumed: Set<Int64> = []
    public init() {}
    public var isHeld: Bool { !held.isEmpty }
    public var separateInsertIsHeld: Bool { held.contains(114) }
    public func capturedAt(_ code: Int64) -> UInt64 { captured[code] ?? 0 }

    public mutating func update(enabled: Bool, keypadEnabled: Bool) {
        self.enabled = enabled
        self.keypadEnabled = keypadEnabled
        eligible = eligible.filter { accepts($0) }
        held = held.intersection(eligible)
    }

    /// A missing up must not leave subsequent laptop keys interpreted as reader commands.
    /// Retain consumed-up ownership until an up or a genuinely new down resolves that press.
    public mutating func reconcile(isDown: (Int64) -> Bool) {
        held = eligible.filter(isDown)
    }

    private func accepts(_ code: Int64) -> Bool {
        // kVK_Help (114) is Insert on a PC keyboard; a Mac number pad reports zero as 82.
        enabled && (code == 114 || (code == 82 && keypadEnabled))
    }

    /// Finish an owned press before mode-specific routing. A fresh down starts new ownership.
    public mutating func continuePress(_ type: CGEventType, code: Int64, isRepeat: Bool, stillHeld: Bool = false, overlappingDown: Bool = false) -> Bool {
        if type == .keyUp {
            if stillHeld,
               consumed.contains(code) { return true }
            held.remove(code)
            eligible.remove(code)
            captured.removeValue(forKey: code)
            return consumed.remove(code) != nil
        }
        guard type == .keyDown else { return false }
        if isRepeat || overlappingDown { return consumed.contains(code) }
        held.remove(code)
        eligible.remove(code)
        captured.removeValue(forKey: code)
        consumed.remove(code)
        return false
    }

    /// True means consume this event. Repeats cannot manufacture a new modifier press.
    public mutating func handle(_ type: CGEventType, code: Int64, isRepeat: Bool = false, timestamp: UInt64 = 0) -> Bool {
        if continuePress(type, code: code, isRepeat: isRepeat) { return true }
        guard type == .keyDown,
              accepts(code),
              !isRepeat else { return false }
        held.insert(code)
        eligible.insert(code)
        captured[code] = timestamp
        consumed.insert(code)
        return true
    }

    public func addingModifier(to modifiers: Modifiers) -> Modifiers {
        isHeld ? modifiers.union(.turnover) : modifiers
    }

    /// Explicitly discard all ownership; normal reader handover must retain this state.
    public mutating func reset() {
        held.removeAll()
        eligible.removeAll()
        captured.removeAll()
        consumed.removeAll()
    }
}
