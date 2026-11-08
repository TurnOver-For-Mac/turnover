// motion: reads the DualSense's input reports on the Mac (non-exclusive) and prints, every
// 250 ms, how much the gyro/accel bytes are changing — the rumble motors shake the IMU, so a
// burst of rumble shows as a jump in this number. Usage: motion <seconds>
import Foundation
import IOKit.hid

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "20") ?? 20
let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: 0x054C, kIOHIDProductIDKey: 0x0CE6] as CFDictionary)
var energy = 0.0, count = 0, lastId: UInt8 = 0, lastLen = 0
var prev = [UInt8](repeating: 0, count: 100)
var buf = [UInt8](repeating: 0, count: 256)
let cb: IOHIDReportCallback = { _, _, _, _, id, report, len in
    let base = id == 0x31 ? 2 : 1
    var e = 0.0
    for i in (base + 11)..<(base + 22) where i < len { e += abs(Double(report[i]) - Double(prev[i])); prev[i] = report[i] }
    energy += e; count += 1; lastId = UInt8(id); lastLen = len
}
IOHIDManagerRegisterDeviceMatchingCallback(mgr, { _, _, _, dev in
    let t = IOHIDDeviceGetProperty(dev, kIOHIDTransportKey as CFString) as? String ?? "?"
    let s = IOHIDDeviceGetProperty(dev, kIOHIDSerialNumberKey as CFString) as? String ?? "?"
    print("device: transport \(t), serial '\(s)'"); fflush(stdout)
    buf.withUnsafeMutableBufferPointer { p in IOHIDDeviceRegisterInputReportCallback(dev, p.baseAddress!, 256, cb, nil) }
}, nil)
IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
let start = Date()
let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
    let t = String(format: "%5.2f", Date().timeIntervalSince(start))
    print("\(t)s  reports \(count)  id 0x\(String(lastId, radix: 16)) len \(lastLen)  motion \(Int(energy))"); fflush(stdout)
    energy = 0; count = 0
    if Date().timeIntervalSince(start) > seconds { exit(0) }
}
RunLoop.current.add(timer, forMode: .default)
RunLoop.current.run()
