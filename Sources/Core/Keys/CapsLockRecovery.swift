// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import IOKit.hid

/// Read at the availability transition, before a fallback Caps press can cause a
/// native toggle. Reading at its HID down/up instead can capture that toggle.
nonisolated public enum CapsLockRecovery {
    public struct Snapshot: Sendable {
        public var timestamp: UInt64
        public var on: Bool
        public init(timestamp: UInt64, on: Bool) { self.timestamp = timestamp; self.on = on }
    }
    public static let current = Locked<Snapshot?>(nil)

    public static func capture() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection) == KERN_SUCCESS else { return }
        defer { IOServiceClose(connection) }
        var on = false
        guard IOHIDGetModifierLockState(connection, Int32(kIOHIDCapsLockState), &on) == KERN_SUCCESS else { return }
        publish(Snapshot(timestamp: DispatchTime.now().uptimeNanoseconds, on: on))
    }

    public static func publish(_ sample: Snapshot) {
        current.lock.lock()
        defer { current.lock.unlock() }
        if current.unsafeValue.map({ $0.timestamp < sample.timestamp }) ?? true {
            current.unsafeValue = sample
        }
    }
}
