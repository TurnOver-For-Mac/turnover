// SPDX-License-Identifier: GPL-3.0-or-later
// BAUM displays over USB HID (the VarioUltra: vendor 0x0904, products 0x6101 for 20 cells, 0x6102 for 40, 0x6103
// for 32). The HID interface carries BAUM's own protocol in its reports, not the standard HID braille page: a
// command byte, then its data. Protocol facts (BRLTTY's documentation of it): 0x01 writes the cells; input 0x22 is
// the routing keys (a bit per cell), 0x24 the display keys (a bit per key, d1 to d8), 0x33 the entry keys (two
// bytes), 0x34 the joystick; 0x84 asks for the device's name. TurnOver's own code, written from those facts.
//
// Displays are looked for only while TurnOver leads, and let go when it hands back, so VoiceOver can have them.
import Foundation
import AppKit
import IOKit.hid
import TurnOverBraille

public final class BrailleDisplays {
    public static let shared = BrailleDisplays()
    private var manager: IOHIDManager?
    private var drivers: [IOHIDDevice: BaumHIDDriver] = [:]

    private var apple: AppleBrailleDriver?
    private var lookAgain: Timer?

    /// TurnOver leads: look for displays (and any that come later). Apple's drivers first; TurnOver's own BAUM
    /// driver only if none of them takes a display.
    public func start() {
        guard manager == nil, apple == nil, lookAgain == nil else { return }
        if !useApple() { startOwn() }
        // A display plugged in, switched on or lost later; and USB taking over from Bluetooth. (Started even when a
        // display was found at once: with the early return, a display lost later was never looked for again.)
        scanStarted = Date()
        lookAgain = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in MainActor.assumeIsolated {
            guard let self else { return }
            // USB before Bluetooth: a display plugged in while TurnOver has it over Bluetooth switches to USB (and
            // stops answering over Bluetooth), so move to the cable (6 Oct 2026).
            if let a = self.apple, a.display.isBluetooth, let usb = TOAppleBrailleDisplay.detect().first {
                Log.info("braille: \(a.name) is on USB now; moving to it")
                Braille.detach(a); a.close(); self.apple = nil
                self.adopt(usb)
                return
            }
            // With no display: the full scan (27 driver bundles, IOKit) every 3 s for the first minute, then every
            // 10 s; it ran on the main thread for everyone, for ever (a code review, 14 Oct 2026).
            guard self.apple == nil, self.drivers.isEmpty,
                  Date().timeIntervalSince(self.lastFullScan) >= (Date().timeIntervalSince(self.scanStarted) < 60 ? 3 : 10) else { return }
            self.lastFullScan = Date()
            if self.useApple() { self.stopOwn() }
        } }
    }

    private var lastBluetoothLook = Date.distantPast
    private var scanStarted = Date.distantPast
    private var lastFullScan = Date.distantPast

    /// Look again now (Bluetooth just turned on in the menu).
    public func lookNow() {
        guard manager != nil || lookAgain != nil, apple == nil else { return }
        lastBluetoothLook = .distantPast
        if useApple() { stopOwn() }
    }

    private var bluetoothLooking = false

    private func useApple() -> Bool {
        // Bluetooth only when asked for, and not more than every 15 s (connecting takes a few seconds, on the
        // braille thread; the answer comes back here).
        // Just after VoiceOver's braille server let go, the display can take a few seconds to be free: look again
        // every 4 s for half a minute, then every 15.
        let every: TimeInterval = Date() < quickRetryUntil ? 4 : 15
        if config.braille.bluetooth, !bluetoothLooking, Date().timeIntervalSince(lastBluetoothLook) > every,
           TOAppleBrailleDisplay.detect().isEmpty {
            lastBluetoothLook = Date()
            bluetoothLooking = true
            let freed = Self.quitVoiceOversBrailleServer()
            if freed { quickRetryUntil = Date().addingTimeInterval(30) }
            // Give the display a moment to notice the old connection has gone.
            DispatchQueue.main.asyncAfter(deadline: .now() + (freed ? 2 : 0)) { [weak self] in
            TOAppleBrailleDisplay.detectBluetooth { [weak self] found in
                // The display object is handed to the main thread whole; nothing else holds it.
                nonisolated(unsafe) let found = found
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.bluetoothLooking = false
                    Log.info("braille: Bluetooth: \(TOAppleBrailleDisplay.lastBluetoothReport)")
                    guard let found, self.apple == nil, self.lookAgain != nil || self.manager != nil else { found?.close(); return }
                    self.adopt(found)
                    self.stopOwn()
                }
            }
            }
        }
        guard let d = TOAppleBrailleDisplay.detect().first else { noteUnopened(); return false }
        adopt(d)
        return true
    }

    /// A display a driver claims but couldn't load: with VoiceOver off, its braille server (scrod) can still hold a USB
    /// display too, showing "VoiceOver off" for ever (a Focus 5 by USB with CoExist off, 20 Oct 2026). Ask scrod to
    /// quit and look again; if the display still won't open, say so once, as nothing on the display can.
    private var lastDetectReport: String?   // nil until the first look, which is always logged, even finding nothing
    private var lastUSBFree = Date.distantPast
    private var retryPending = false
    private var toldUnopened = false

    private func noteUnopened() {
        let report = TOAppleBrailleDisplay.lastDetectReport
        if report != lastDetectReport {
            lastDetectReport = report
            Log.info("braille: looked for displays:\(report.isEmpty ? " none connected that a driver claims" : report)")
        }
        guard TOAppleBrailleDisplay.lastDetectFoundUnopened else { return }
        // VoiceOver still on (a hand-over under way): it has the display by right; the scan looks again in 3 s.
        if NSWorkspace.shared.isVoiceOverEnabled { return }
        // scrod was just asked to quit (here, or for Bluetooth) and the look again is still to come: not said yet.
        if Date() < quickRetryUntil || retryPending { return }
        if Date().timeIntervalSince(lastUSBFree) > 30 {
            lastUSBFree = Date()
            guard Self.quitVoiceOversBrailleServer() else { tellUnopened(); return }
            // Give the display a moment to be free, then look again (the 3 s scan would too, later).
            retryPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                self.retryPending = false
                guard self.apple == nil, self.lookAgain != nil || self.manager != nil else { return }
                if self.useApple() { self.stopOwn() }
            }
            return
        }
        tellUnopened()
    }

    private func tellUnopened() {
        guard !toldUnopened else { return }
        toldUnopened = true
        Speech.speakMessage("A braille display is connected, but TurnOver couldn't open it. If VoiceOver is on, it may be holding the display.")
    }

    /// VoiceOver's braille server (scrod) keeps a Bluetooth display's one connection open even with VoiceOver off,
    /// so TurnOver could never connect (6 Oct 2026). While TurnOver leads, it asks scrod to quit; VoiceOver starts
    /// it again when it comes back, and it reconnects the display by itself. A USB display can need it too (noteUnopened).
    private var quickRetryUntil = Date.distantPast

    @discardableResult
    static func quitVoiceOversBrailleServer() -> Bool {
        guard !NSWorkspace.shared.isVoiceOverEnabled else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["scrod"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        if p.terminationStatus == 0 { Log.info("braille: VoiceOver's braille server asked to quit, so TurnOver can connect to the display") }
        return p.terminationStatus == 0
    }

    private func adopt(_ d: TOAppleBrailleDisplay) {
        let driver = AppleBrailleDriver(d)
        driver.onLost = { [weak self, weak driver] in
            guard let self, let driver else { return }
            Braille.detach(driver); self.apple = nil
        }
        apple = driver
        Braille.attach(driver)
    }

    private func startOwn() {
        guard manager == nil else { return }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(m, [[kIOHIDVendorIDKey: BaumHIDDriver.vendor]] as CFArray)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, device in
            Unmanaged<BrailleDisplays>.fromOpaque(ctx!).takeUnretainedValue().found(device)
        }, me)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, device in
            Unmanaged<BrailleDisplays>.fromOpaque(ctx!).takeUnretainedValue().lost(device)
        }, me)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let r = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        if r != kIOReturnSuccess { Log.info("braille: looking for displays: \(String(format: "0x%x", r))") }
        manager = m
    }

    /// TurnOver hands back: close every display, so VoiceOver can take it.
    public func stop() {
        lookAgain?.invalidate(); lookAgain = nil
        if let a = apple { Braille.detach(a); a.close(); apple = nil }
        stopOwn()
    }

    private func stopOwn() {
        guard let m = manager else { return }
        for (_, d) in drivers { Braille.detach(d); d.close() }
        drivers.removeAll()
        IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil
    }

    private func found(_ device: IOHIDDevice) {
        guard drivers[device] == nil, let d = BaumHIDDriver(device: device) else { return }
        drivers[device] = d
        Braille.attach(d)
    }

    private func lost(_ device: IOHIDDevice) {
        guard let d = drivers.removeValue(forKey: device) else { return }
        d.disconnect()   // (its report callback pointed at the driver after it was freed, 8 Oct 2026)
        Braille.detach(d)
    }
}

final class BaumHIDDriver: BrailleDisplayDriver {
    static let vendor = 0x0904
    private static let cellsByProduct = [0x6101: 20, 0x6102: 40, 0x6103: 32]

    let name: String
    private(set) var cellCount: Int
    private let device: IOHIDDevice
    private let outputSize: Int
    private var inputBuffer: UnsafeMutablePointer<UInt8>
    private let inputSize: Int
    private var reportsLogged = 0

    init?(device: IOHIDDevice) {
        func prop(_ k: String) -> Any? { IOHIDDeviceGetProperty(device, k as CFString) }
        let product = prop(kIOHIDProductIDKey) as? Int ?? 0
        self.device = device
        name = (prop(kIOHIDProductKey) as? String) ?? String(format: "BAUM display 0x%04x", product)
        cellCount = Self.cellsByProduct[product] ?? 40
        outputSize = prop(kIOHIDMaxOutputReportSizeKey) as? Int ?? 0
        inputSize = max(prop(kIOHIDMaxInputReportSizeKey) as? Int ?? 64, 2)
        inputBuffer = .allocate(capacity: inputSize)
        let r = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else {
            Log.info("braille: \(name) would not open (\(String(format: "0x%x", r))): VoiceOver may still have it")
            inputBuffer.deallocate()
            return nil
        }
        Log.info("braille: opened \(name) (product \(String(format: "0x%04x", product)), reports in \(inputSize), out \(outputSize))")
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, inputSize, { ctx, _, _, _, _, report, length in
            let me = Unmanaged<BaumHIDDriver>.fromOpaque(ctx!).takeUnretainedValue()
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            DispatchQueue.main.async { me.received(bytes) }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        send([0x84])   // its name and model, for the log
    }

    func write(_ cells: [UInt8]) { send([0x01] + cells) }

    func close() {
        guard !closed else { return }
        write(Array(repeating: 0, count: cellCount))
        disconnect()
    }

    /// The device has gone, or is being let go: no more reports to this driver, and the device closed. Once.
    private var closed = false
    func disconnect() {
        guard !closed else { return }
        closed = true
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, inputSize, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    isolated deinit { disconnect(); inputBuffer.deallocate() }

    private func send(_ bytes: [UInt8]) {
        var report = bytes
        if outputSize > report.count { report += Array(repeating: 0, count: outputSize - report.count) }
        let r = report.withUnsafeBufferPointer { IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, $0.baseAddress!, $0.count) }
        if r != kIOReturnSuccess { Log.info("braille: \(name): report \(String(format: "0x%02x", bytes.first ?? 0)) refused (\(String(format: "0x%x", r)))") }
    }

    // MARK: Keys. BAUM reports which keys are down; a press is acted on when every key is up again, so chords work.

    private var down = Set<String>()
    private var pressed = Set<String>()

    private func received(_ bytes: [UInt8]) {
        guard let command = bytes.first else { return }
        // The first reports in full, to learn the device's layout from a tester's log.
        if reportsLogged < 40 { reportsLogged += 1; Log.info("braille: \(name) report " + bytes.prefix(24).map { String(format: "%02x", $0) }.joined(separator: " ")) }
        let data = Array(bytes.dropFirst())
        switch command {
        case 0x84:
            let id = String(decoding: data.prefix(16), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            if !id.isEmpty { Log.info("braille: device says \"\(id)\"") }
        case 0x01:
            if let n = data.first, n > 0, Int(n) != cellCount { cellCount = Int(n); Log.info("braille: \(cellCount) cells") }
        case 0x22:
            var keys = Set<String>()
            for (i, b) in data.enumerated() { for bit in 0..<8 where b & (1 << bit) != 0 { keys.insert("routing\(i * 8 + bit)") } }
            update(group: "routing", keys)
        case 0x24:
            var keys = Set<String>()
            for bit in 0..<8 where (data.first ?? 0) & (1 << bit) != 0 { keys.insert("d\(bit + 1)") }
            update(group: "d", keys)
        case 0x27:
            // One routing key, numbered from 1; 0 is all released (measured on a 20-cell braille display, 6 Oct 2026).
            let k = Int(data.first ?? 0)
            update(group: "routing", k == 0 ? [] : ["routing\(k - 1)"])
        case 0x34:
            // Joystick bits: 1 up, 2 left, 4 down, 8 right, 16 pressed in (measured).
            let v = data.first ?? 0
            var keys = Set<String>()
            for (bit, name) in [(0x01, "joystickUp"), (0x02, "joystickLeft"), (0x04, "joystickDown"), (0x08, "joystickRight"), (0x10, "joystickPress")] where Int(v) & bit != 0 { keys.insert(name) }
            update(group: "joystick", keys)
        case 0x33:
            // The braille keyboard: the second byte is dots 1 to 8 (bit n-1 for dot n), the first the thumb keys
            // (0x01 space; 0x02 a second key, to name once known). Measured, 6 Oct 2026.
            let hi = Int(data.first ?? 0), lo = Int(data.dropFirst().first ?? 0)
            var keys = Set<String>()
            for bit in 0..<8 where lo & (1 << bit) != 0 { keys.insert("dot\(bit + 1)") }
            if hi & 0x01 != 0 { keys.insert("space") }
            for bit in 1..<8 where hi & (1 << bit) != 0 { keys.insert("thumb\(bit + 1)") }
            update(group: "dot", keys.filter { $0.hasPrefix("dot") })
            update(group: "space", keys.filter { $0 == "space" })
            update(group: "thumb", keys.filter { $0.hasPrefix("thumb") })
        default:
            break
        }
    }

    /// Replace the keys of one group with what is down now; when nothing at all is down, act on what was pressed.
    private var lastDotDown: Date?, spaceDown: Date?, dotLetGoBeforeSpace = false

    private func update(group: String, _ now: Set<String>) {
        let before = down.filter { $0.hasPrefix(group) }
        if group == "dot" {
            if !now.subtracting(before).isEmpty { lastDotDown = Date() }
            if !before.subtracting(now).isEmpty, spaceDown == nil, !pressed.contains("space") { dotLetGoBeforeSpace = true }
        }
        if group == "space", now.contains("space"), spaceDown == nil { spaceDown = Date() }
        down = down.filter { !$0.hasPrefix(group) }.union(now)
        pressed.formUnion(now)
        guard down.isEmpty, !pressed.isEmpty else { return }
        let keys = pressed
        pressed.removeAll()
        // The braille keyboard: dots and space together are a chord to type or a command.
        let (dotAt, spaceAt, letGo) = (lastDotDown, spaceDown, dotLetGoBeforeSpace)
        lastDotDown = nil; spaceDown = nil; dotLetGoBeforeSpace = false
        if keys.allSatisfy({ $0.hasPrefix("dot") || $0 == "space" }) {
            let dots = Set(keys.compactMap { Int($0.dropFirst(3)) })
            var late = false
            if keys.contains("space"), !dots.isEmpty, let s = spaceAt, let d = dotAt { late = letGo || s.timeIntervalSince(d) > BrailleInput.lateSpaceSeconds }
            BrailleInput.chord(dots: dots, space: keys.contains("space"), spaceLate: late)
            return
        }
        if keys.count == 1, let k = keys.first {
            if k.hasPrefix("routing"), let i = Int(k.dropFirst("routing".count)) { Braille.handle(.routing(i)) }
            else { Braille.handle(.key(Self.friendly(k))) }
        } else {
            Braille.handle(.key(keys.sorted().map(Self.friendly).joined(separator: "+")))
        }
    }

    /// The joystick's values as directions, once known from a log; until then its raw value.
    private static func friendly(_ k: String) -> String { k }
}
