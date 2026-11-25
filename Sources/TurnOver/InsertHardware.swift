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
        var proof = InsertDeviceProof(data: UserDefaults.standard.data(forKey: "insertDeviceProof"))
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

    private static func persistentIdentity(_ device: IOHIDDevice) -> String? {
        let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String
        let uniqueID = IOHIDDeviceGetProperty(device, kIOHIDPhysicalDeviceUniqueIDKey as CFString) as? String
        let vendor = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String
        return InsertDeviceProof.identity(serial: serial, vendor: vendor?.intValue,
                                          product: product?.intValue, transport: transport, uniqueID: uniqueID)
    }

    private static func connected(_ device: IOHIDDevice) {
        state.lock.lock()
        let identity = ObjectIdentifier(device)
        guard state.unsafeValue.connections[identity] == nil else { state.lock.unlock(); return }
        state.unsafeValue.nextConnection += 1
        let connection = state.unsafeValue.nextConnection
        state.unsafeValue.connections[identity] = connection
        state.unsafeValue.history.connect(connection)
        let proven = state.unsafeValue.proof.keys(for: persistentIdentity(device))
        state.lock.unlock()
        // Restore capability only, never a held press. Known reconnects are quiet.
        updateAvailability(announce: false) {
            $0.connect(connection)
            for code in proven { $0.observePress(connection: connection, code: code) }
        }
    }

    private static func disconnected(_ device: IOHIDDevice) {
        state.lock.lock()
        guard let connection = state.unsafeValue.connections.removeValue(forKey: ObjectIdentifier(device)) else { state.lock.unlock(); return }
        state.unsafeValue.history.disconnect(connection)
        state.lock.unlock()
        // Bluetooth idle sleep is not distinguishable from a disconnect. Enable recovery
        // immediately, but do not interrupt reading with a device-lifecycle notification.
        let bluetooth = (IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String)?.lowercased().contains("bluetooth") == true
        updateAvailability(announce: !bluetooth) { $0.disconnect(connection) }
    }

    private static func observed(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usage = IOHIDElementGetUsage(element)
        guard usage == 0x49 || usage == 0x62 else { return }
        let code: Int64 = usage == 0x49 ? 114 : 82
        let ticks = IOHIDValueGetTimeStamp(value)
        // HID is Mach absolute ticks; Quartz event timestamps already use nanoseconds.
        let timestamp = nanoseconds(ticks)
        let device = IOHIDElementGetDevice(element)
        let down = IOHIDValueGetIntegerValue(value) != 0
        state.lock.lock()
        guard let connection = state.unsafeValue.connections[ObjectIdentifier(device)] else { state.lock.unlock(); return }
        let changed = down && state.unsafeValue.proof.observe(code, identity: persistentIdentity(device))
        let data = changed ? state.unsafeValue.proof.data : nil
        state.unsafeValue.history.record(connection: connection, code: code, down: down, timestamp: timestamp)
        state.lock.unlock()
        if down { updateAvailability { $0.observePress(connection: connection, code: code) } }
        // No disk or IOHIDSystem work while the tap's history lock is held.
        if let data { UserDefaults.standard.set(data, forKey: "insertDeviceProof") }
    }

    private static func updateAvailability(announce: Bool = true, _ update: (inout InsertAvailability) -> Void) {
        let settings = KeySettings.current
        // All device callbacks run on the observer queue. Prepare the next snapshot
        // without blocking readers while IOHIDSystem samples a real loss of Insert.
        var next = InsertAvailability.current.value
        let before = next.isAvailable(keypadCommands: settings.keypadCommands)
        update(&next)
        let after = next.isAvailable(keypadCommands: settings.keypadCommands)
        if settings.insertIsTurnOver, before, !after { CapsLockRecovery.capture() }
        InsertAvailability.current.value = next
        guard announce, settings.insertIsTurnOver, before != after else { return }
        onMain {
            let current = KeySettings.current
            guard current.insertIsTurnOver, current.capsIsTurnOver == !after else { return }
            announceAvailability(current.capsIsTurnOver
                ? String(localized: "Caps Lock is now the TurnOver key", comment: "Insert is unavailable; recovery modifier")
                : String(localized: "Insert is available. Caps Lock is now a lock key", comment: "Insert recovered; modifier fallback ended"), turnOverActive: Core.active, fallback: current.capsIsTurnOver)
        }
    }

    @MainActor static func announceAvailability(_ message: String, turnOverActive: Bool, fallback: Bool) {
        if turnOverActive {
            Speech.speakMessage(message)
        } else if KeySettings.current.windowsKeys, config.general.keysWhereVoiceOverReads,
                  HandOver.voiceOverReading {
            WindowsKeyLayer.shared.sayAvailability(message, fallback: fallback)
        }
    }

    static func nanoseconds(_ ticks: UInt64) -> UInt64 {
        ticks / timebase.denom * timebase.numer + ticks % timebase.denom * timebase.numer / timebase.denom
    }

    static func overlapsDown(_ code: Int64, at timestamp: UInt64) -> Bool {
        state.value.history.overlapsDown(code: code, at: timestamp)
    }

    static func observedDown(_ code: Int64, at timestamp: UInt64, currentDown: Bool, after capturedAt: UInt64) -> Bool? {
        // Never block the tap on device opening or callback delivery. Unseen reports remain unknown.
        state.value.history.observedDown(code: code, at: timestamp, currentDown: currentDown, after: capturedAt)
    }
}
