// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreGraphics
import IOKit.hid
import TurnOverCore

/// One non-seizing observer survives reader handover. It never posts events or changes permissions.
nonisolated enum InsertHardware {
    private struct State {
        var manager: IOHIDManager?
        var nextConnection: UInt64 = 0
        var connections: [ObjectIdentifier: UInt64] = [:]
        var history = InsertHardwareHistory()
    }
    private static let state = Locked(State())
    private static let queue = DispatchQueue(label: "turnover.insert-hardware")
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var value = mach_timebase_info_data_t()
        mach_timebase_info(&value)
        return (UInt64(value.numer), UInt64(value.denom))
    }()

    static func start() {
        queue.async {
            guard state.value.manager == nil else { return }
            let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            state.lock.lock()
            state.unsafeValue.manager = manager
            state.lock.unlock()
            let matches = [kHIDUsage_GD_Keyboard, kHIDUsage_GD_Keypad].map {
                [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: $0]
            }
            IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
            let keys = [0x49, 0x62].map {
                [kIOHIDElementUsagePageKey: kHIDPage_KeyboardOrKeypad, kIOHIDElementUsageKey: $0]
            }
            IOHIDManagerSetInputValueMatchingMultiple(manager, keys as CFArray)
            IOHIDManagerRegisterDeviceMatchingCallback(manager, { _, _, _, device in InsertHardware.connected(device) }, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, { _, _, _, device in InsertHardware.disconnected(device) }, nil)
            IOHIDManagerRegisterInputValueCallback(manager, { _, _, _, value in InsertHardware.observed(value) }, nil)
            IOHIDManagerSetDispatchQueue(manager, queue)
            let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            if result != kIOReturnSuccess { Log.warning("Insert physical observer could not open: \(result)") }
            IOHIDManagerActivate(manager)
        }
    }

    private static func connected(_ device: IOHIDDevice) {
        state.lock.lock()
        defer { state.lock.unlock() }
        let identity = ObjectIdentifier(device)
        guard state.unsafeValue.connections[identity] == nil else { return }
        state.unsafeValue.nextConnection += 1
        let connection = state.unsafeValue.nextConnection
        state.unsafeValue.connections[identity] = connection
        state.unsafeValue.history.connect(connection)
    }

    private static func disconnected(_ device: IOHIDDevice) {
        state.lock.lock()
        defer { state.lock.unlock() }
        guard let connection = state.unsafeValue.connections.removeValue(forKey: ObjectIdentifier(device)) else { return }
        state.unsafeValue.history.disconnect(connection)
    }

    private static func observed(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usage = IOHIDElementGetUsage(element)
        guard usage == 0x49 || usage == 0x62 else { return }
        let code: Int64 = usage == 0x49 ? 114 : 82
        let ticks = IOHIDValueGetTimeStamp(value)
        // HID is Mach absolute ticks; Quartz event timestamps already use nanoseconds.
        let timestamp = ticks / timebase.denom * timebase.numer
            + ticks % timebase.denom * timebase.numer / timebase.denom
        let device = IOHIDElementGetDevice(element)
        state.lock.lock()
        defer { state.lock.unlock() }
        guard let connection = state.unsafeValue.connections[ObjectIdentifier(device)] else { return }
        state.unsafeValue.history.record(connection: connection, code: code,
                                        down: IOHIDValueGetIntegerValue(value) != 0, timestamp: timestamp)
    }

    static func overlapsDown(_ code: Int64, at timestamp: UInt64) -> Bool {
        state.value.history.overlapsDown(code: code, at: timestamp)
    }

    static func observedDown(_ code: Int64, at timestamp: UInt64, currentDown: Bool, after capturedAt: UInt64) -> Bool? {
        // Never block the tap on device opening or callback delivery. Unseen reports remain unknown.
        state.value.history.observedDown(code: code, at: timestamp, currentDown: currentDown, after: capturedAt)
    }
}
