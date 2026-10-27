// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// Unsent bytes on one connection, in message order. Owned by that connection's serial queue.
package struct ControlOutput {
    // A Settings window that stops reading must not grow the reader's memory without bound (27 Oct 2026).
    package static let limit = 4_000_000
    package private(set) var pending = Data()

    package init() {}

    package mutating func append(_ data: Data) -> Bool {
        guard data.count <= Self.limit - pending.count else { return false }
        pending.append(data)
        return true
    }

    package enum Result: Equatable { case complete, blocked, failed(Int32) }

    /// Keep the unwritten suffix on EAGAIN. The caller resumes on socket writability, never by spinning.
    package mutating func flush(using write: (UnsafeRawBufferPointer) -> Int) -> Result {
        var offset = 0
        defer { pending.removeFirst(offset) }
        while offset < pending.count {
            let n = pending.withUnsafeBytes { bytes in
                write(UnsafeRawBufferPointer(rebasing: bytes[offset...]))
            }
            if n > 0 { offset += n; continue }
            if n == 0 { return .failed(EPIPE) }
            let error = errno
            if error == EINTR { continue }
            if error == EAGAIN || error == EWOULDBLOCK { return .blocked }
            return .failed(error)
        }
        return .complete
    }
}

extension ControlChannel {
    /// A large Unix-socket send blocked despite MSG_DONTWAIT on macOS 27.0.1 (27 Oct 2026, socket-pair test).
    /// Set O_NONBLOCK on the socket itself, and turn a disconnected peer into EPIPE rather than SIGPIPE.
    package static func prepareSocket(_ fd: Int32) -> Bool {
        var on: Int32 = 1
        let flags = fcntl(fd, F_GETFL)
        return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
            && setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    /// Synchronous clients have a total write deadline, including partial writes and interrupted waits.
    /// The socket must have been configured with prepareSocket before use.
    /// Callers close the connection on failure: a partly sent JSON line cannot be followed by another message.
    package static func writeAll(_ data: Data, to fd: Int32, timeout: Duration = .seconds(1)) -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        return data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard clock.now < deadline else { return false }
                let n = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, MSG_DONTWAIT)
                if n > 0 { offset += n; continue }
                if n == 0 { return false }
                let error = errno
                if error == EINTR { continue }
                guard error == EAGAIN || error == EWOULDBLOCK else { return false }
                let remaining = clock.now.duration(to: deadline).components
                let milliseconds = Double(remaining.seconds) * 1000 + Double(remaining.attoseconds) / 1e15
                guard milliseconds > 0 else { return false }
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&p, 1, Int32(min(Double(Int32.max), max(1, milliseconds.rounded(.up)))))
                if ready < 0 && errno == EINTR { continue }
                guard ready > 0, p.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 else { return false }
            }
            return true
        }
    }
}
