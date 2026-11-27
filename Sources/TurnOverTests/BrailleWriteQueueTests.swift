// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

nonisolated final class BrailleWriteLog: @unchecked Sendable {
    let lock = NSLock()
    var reports: [[UInt8]] = []
    var closed = 0
}

func brailleWriteQueueTests() {
    test("braille: a display slow to answer never holds the calling thread, and a newer line replaces a waiting one") {
        let gate = DispatchSemaphore(value: 0)
        let log = BrailleWriteLog()
        let w = BaumHIDWriter(transmit: { r in
            if r.first == 0x84 { gate.wait() }   // a display still starting does not answer its first query
            log.lock.lock(); log.reports.append(r); log.lock.unlock()
            return 0
        }, close: { log.lock.lock(); log.closed += 1; log.lock.unlock() })
        let start = Date()
        w.submit([0x84]) { _, _ in }
        w.submit([0x01, 1]) { _, _ in }
        w.submit([0x01, 2]) { _, _ in }
        w.submit([0x01, 3]) { _, _ in }
        check(Date().timeIntervalSince(start) < 0.5, "submitting returns at once while the display is silent")
        gate.signal()
        w.closeDevice()
        w.submit([0x01, 9]) { _, _ in }
        w.drain()
        expect(log.reports, [[0x84], [0x01, 3]], "the query, then only the latest line; nothing after closing")
        expect(log.closed, 1, "the device is closed once, after the waiting reports")
    }
}
