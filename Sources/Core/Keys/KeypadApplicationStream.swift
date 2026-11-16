// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics

/// Final app delivery, rather than a router's "unhandled", owns a keypad press.
/// Repeats and the matching up bypass command lookup, retaining any down-time translation.
nonisolated public struct KeypadApplicationStream: Sendable {
    private struct Translation: Sendable {
        let code: Int64
        let pid: Int32?
        let owner: ObjectIdentifier?
        let flags: CGEventFlags
        let added: CGEventFlags
        let removed: CGEventFlags
    }
    public struct Release: Sendable {
        public let physicalCode: Int64
        public let code: Int64
        public let flags: CGEventFlags
        public let pid: Int32
    }
    private var passed: [Int64: Translation] = [:]
    public private(set) var destination: Int32?
    public init() {}
    public mutating func reset() { passed.removeAll(); destination = nil }

    /// Ordinary session ownership survives reader replacement. Only this owner's explicit
    /// destinations need synthetic releases when its tap ends.
    public mutating func finish(owner: ObjectIdentifier? = nil) -> [Release] {
        var releases: [Release] = []
        for code in passed.keys.sorted() {
            guard let entry = passed[code], entry.owner == owner, let pid = entry.pid else { continue }
            releases.append(Release(physicalCode: code, code: entry.code, flags: entry.flags, pid: pid))
            passed.removeValue(forKey: code)
        }
        return releases
    }

    public mutating func continuePress(_ type: CGEventType, event: CGEvent) -> Bool {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard let translation = passed[code], type == .keyDown || type == .keyUp else { return false }
        if type == .keyUp { passed.removeValue(forKey: code) }
        else if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            // A fresh down retires a stale entry after a missed hardware release.
            passed.removeValue(forKey: code)
            return false
        }
        destination = translation.pid
        event.setIntegerValueField(.keyboardEventKeycode, value: translation.code)
        event.flags.subtract(translation.removed)
        event.flags.formUnion(translation.added)
        return true
    }

    public mutating func recordDown(code: Int64, flags: CGEventFlags, delivered: CGEvent, pid: Int32? = nil, owner: ObjectIdentifier? = nil) {
        guard Keypad.codes.contains(code) else { return }
        passed[code] = Translation(code: delivered.getIntegerValueField(.keyboardEventKeycode), pid: pid, owner: owner, flags: delivered.flags,
                                   added: delivered.flags.subtracting(flags), removed: flags.subtracting(delivered.flags))
    }
}
