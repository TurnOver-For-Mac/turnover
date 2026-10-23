// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import TurnOverCore
import TurnOverControl

func controlChannelTests() {
    test("control channel completes a large socket write") {
        var fds = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { Harness.fail("socketpair failed"); return }
        defer { close(fds[0]); close(fds[1]) }

        let expected = Data(repeating: 0x5A, count: 256 * 1024)
        let done = DispatchSemaphore(value: 0)
        let received = Locked(Data())
        let readFD = fds[0]
        let reader = Thread {
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(readFD, &chunk, chunk.count)
                if n <= 0 { break }
                received.lock.lock()
                received.unsafeValue.append(contentsOf: chunk[0..<n])
                received.lock.unlock()
            }
            done.signal()
        }
        reader.start()

        check(ControlChannel.writeAll(expected, to: fds[1]), "writeAll failed")
        close(fds[1]); fds[1] = -1
        check(done.wait(timeout: .now() + 2) == .success, "reader did not finish")
        expect(received.value, expected, "socket payload")
    }
}
