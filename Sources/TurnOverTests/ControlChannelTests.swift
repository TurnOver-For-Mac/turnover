// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import os
import TurnOverControl

private func controlPair(reusing fd: Int32? = nil) throws -> (local: Int32, peer: Int32) {
    var pair: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw POSIXError(.ENFILE) }
    if let fd, pair[0] != fd {
        // Keep the peer if socketpair chose the requested number for that end.
        if pair[1] == fd { pair.swapAt(0, 1) }
        else {
            guard dup2(pair[0], fd) == fd else { close(pair[0]); close(pair[1]); throw POSIXError(.EBADF) }
            close(pair[0]); pair[0] = fd
        }
    }
    for socket in pair {
        guard ControlChannel.prepareSocket(socket) else { close(pair[0]); close(pair[1]); throw POSIXError(.EINVAL) }
        var size: Int32 = 4096
        setsockopt(socket, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    }
    return (pair[0], pair[1])
}

private func controlLine(_ message: [String: Any]) throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: message, options: .sortedKeys)
    data.append(0x0A)
    return data
}

private nonisolated func controlRead(_ fd: Int32, count: Int) -> Data {
    let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(3))
    var result = Data(), chunk = [UInt8](repeating: 0, count: 8192)
    while result.count < count && clock.now < deadline {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        if poll(&p, 1, 50) <= 0 { continue }
        let n = recv(fd, &chunk, min(chunk.count, count - result.count), MSG_DONTWAIT)
        if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
        guard n > 0 else { break }
        result.append(contentsOf: chunk.prefix(n))
    }
    return result
}

/// Run main-actor callbacks until the observed event, with a deadline only to fail a stuck test.
private func controlWait(_ condition: () -> Bool) -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition() && ContinuousClock.now < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    }
    return condition()
}

private func controlHasNoBytes(_ fd: Int32) -> Bool {
    var byte: UInt8 = 0
    return recv(fd, &byte, 1, MSG_DONTWAIT) == -1 && (errno == EAGAIN || errno == EWOULDBLOCK)
}

func controlChannelTests() {
    test("control: short writes and EINTR preserve the suffix across EAGAIN") {
        let first = try controlLine(["text": "café 🌍"]), second = try controlLine(["text": "next"])
        var output = ControlOutput(), received = Data(), calls = 0
        check(output.append(first), "first message accepted")
        let result = output.flush { bytes in
            calls += 1
            if calls == 1 { errno = EINTR; return -1 }
            if calls == 3 { errno = EAGAIN; return -1 }
            let n = min(3, bytes.count)
            received.append(contentsOf: bytes.prefix(n))
            return n
        }
        expect(result, .blocked)
        expect(output.pending, Data(first.dropFirst(3)))
        check(output.append(second), "second message accepted behind the suffix")
        expect(output.flush { bytes in
            let n = min(2, bytes.count)
            received.append(contentsOf: bytes.prefix(n))
            return n
        }, .complete)
        expect(received, first + second, "whole JSON lines in order")
        check(output.pending.isEmpty, "nothing left to resend")
    }
    test("control: zero writes and fatal errors stop without losing the unsent bytes") {
        for error: Int32 in [0, EPIPE, ECONNRESET] {
            var output = ControlOutput()
            let line = try controlLine(["op": "ask"])
            check(output.append(line), "message accepted")
            expect(output.flush { _ in errno = error; return error == 0 ? 0 : -1 }, .failed(error == 0 ? EPIPE : error))
            expect(output.pending, line)
        }
    }
    test("control: outgoing buffer limit rejects a whole message") {
        var output = ControlOutput()
        let full = Data(repeating: 65, count: ControlOutput.limit)
        check(output.append(full), "limit is accepted")
        check(!output.append(Data([0x0A])), "overflow refused")
        expect(output.pending, full, "no truncated extra message")
    }
    test("control: synchronous writes finish a message larger than the socket buffer") {
        let pair = try controlPair()
        defer { close(pair.local); close(pair.peer) }
        let data = try controlLine(["text": String(repeating: "é", count: 150_000)])
        let received = OSAllocatedUnfairLock(initialState: Data())
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let bytes = controlRead(pair.peer, count: data.count)
            received.withLock { $0 = bytes }
            finished.signal()
        }
        check(ControlChannel.writeAll(data, to: pair.local), "all bytes sent")
        expect(finished.wait(timeout: .now() + 4), .success)
        expect(received.withLock { $0 }, data)
    }
    test("control: a synchronous write times out when the peer stops reading") {
        let pair = try controlPair()
        defer { close(pair.local); close(pair.peer) }
        let start = ContinuousClock.now
        check(!ControlChannel.writeAll(Data(repeating: 65, count: 300_000), to: pair.local, timeout: .milliseconds(30)), "full socket fails")
        check(start.duration(to: .now) < .seconds(1), "the write has a total deadline")
    }
    test("control: a closed peer makes synchronous writes fail without SIGPIPE") {
        let pair = try controlPair()
        defer { close(pair.local) }
        close(pair.peer)
        check(!ControlChannel.writeAll(Data([65, 10]), to: pair.local), "closed peer fails")
    }
    test("control: concurrent persistent sends stay as complete JSON lines") {
        let pair = try controlPair()
        defer { close(pair.peer) }
        let connection = ControlClient.Connection(fd: pair.local, received: { _ in }, ended: {})
        let texts = [String(repeating: "a", count: 150_000), String(repeating: "b", count: 150_000)]
        let byteCount = try texts.reduce(0) { try $0 + controlLine(["text": $1]).count }
        let received = OSAllocatedUnfairLock(initialState: Data())
        let results = OSAllocatedUnfairLock(initialState: [Bool]())
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let bytes = controlRead(pair.peer, count: byteCount)
            received.withLock { $0 = bytes }
            finished.signal()
        }
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            let sent = connection.send(["text": texts[i]])
            results.withLock { $0.append(sent) }
        }
        expect(results.withLock { $0 }, [true, true])
        expect(finished.wait(timeout: .now() + 4), .success)
        let lines = received.withLock { $0 }.split(separator: 0x0A)
        let decoded = try lines.map { (try JSONSerialization.jsonObject(with: Data($0)) as? [String: String])?["text"] ?? "" }
        expect(decoded.sorted(), texts)
        withExtendedLifetime(connection) {}
    }
    test("control: failed persistent send ends once and cannot use a recycled descriptor") {
        let pair = try controlPair()
        var endings = 0
        let connection = ControlClient.Connection(fd: pair.local, received: { _ in }, ended: { endings += 1 })
        close(pair.peer)
        check(!connection.send(["op": "ask"]), "send fails")
        guard controlWait({ endings == 1 && fcntl(pair.local, F_GETFD) == -1 }) else { throw POSIXError(.ETIMEDOUT) }
        let replacement = try controlPair(reusing: pair.local)
        defer { close(replacement.local); close(replacement.peer) }
        check(!connection.send(["op": "patch"]), "closed connection refuses another send")
        check(controlHasNoBytes(replacement.peer), "no bytes sent to the replacement")
        expect(endings, 1)
        withExtendedLifetime(connection) {}
    }
    test("control: a partial persistent send that times out closes the stream") {
        let pair = try controlPair()
        defer { close(pair.peer) }
        var endings = 0
        let connection = ControlClient.Connection(fd: pair.local, received: { _ in }, ended: { endings += 1 })
        check(!connection.send(["text": String(repeating: "a", count: 300_000)]), "partial message fails after the write deadline")
        check(!connection.send(["text": "later"]), "another message cannot follow a truncated line")
        check(controlWait { endings == 1 }, "ended delivered once")
        let prefix = controlRead(pair.peer, count: 300_001)
        check(!prefix.isEmpty && !prefix.contains(0x0A), "only the first message's incomplete prefix reached the peer")
        withExtendedLifetime(connection) {}
    }
    test("control: a slow subscriber preserves reply and broadcast order without blocking another client") {
        let queue = DispatchQueue(label: "turnover.test.control")
        let server = ControlServer(queue: queue)
        let slow = try controlPair(), fast = try controlPair()
        defer { queue.sync { server.drop(slow.local); server.drop(fast.local) }; close(slow.peer); close(fast.peer) }
        queue.sync { server.addClient(slow.local); server.addClient(fast.local) }
        var reply: (@Sendable ([String: Any]) -> Void)?
        server.handlers["subscribe"] = { _, answer in reply = answer }
        expect(ControlChannel.writeAll(try controlLine(["op": "subscribe"]), to: slow.peer), true, "subscribe sent")
        check(controlWait { reply != nil }, "subscription handled")
        let text = String(repeating: "é", count: 150_000)
        let expected = try controlLine(["text": text]) + controlLine(["text": "broadcast"])
        reply?(["text": text])
        server.broadcast(["text": "broadcast"])
        // This barrier must complete while the first client's send buffer is still full.
        let responsive = DispatchSemaphore(value: 0)
        queue.async { responsive.signal() }
        expect(responsive.wait(timeout: .now() + 1), .success, "server queue stays responsive")
        var handled = false
        server.handlers["ask"] = { _, answer in answer(["text": "ready"]); handled = true }
        expect(ControlChannel.writeAll(try controlLine(["op": "ask"]), to: fast.peer), true, "second request sent")
        check(controlWait { handled }, "second request handled")
        let ready = try controlLine(["text": "ready"])
        expect(controlRead(fast.peer, count: ready.count), ready)
        expect(controlRead(slow.peer, count: expected.count), expected, "partial reply followed by complete broadcast")
    }
    test("control: delayed replies cannot reach a replacement client with the same descriptor") {
        let queue = DispatchQueue(label: "turnover.test.control.reuse")
        let server = ControlServer(queue: queue)
        let old = try controlPair()
        queue.sync { server.addClient(old.local) }
        var replies: [@Sendable ([String: Any]) -> Void] = []
        server.handlers["ask"] = { _, reply in replies.append(reply) }
        expect(ControlChannel.writeAll(try controlLine(["op": "ask"]), to: old.peer), true, "old request sent")
        check(controlWait { replies.count == 1 }, "old reply captured")
        queue.sync { server.drop(old.local) }
        expect(controlRead(old.peer, count: 1), Data(), "old connection closed")
        guard controlWait({ fcntl(old.local, F_GETFD) == -1 }) else { throw POSIXError(.ETIMEDOUT) }
        close(old.peer)
        let replacement = try controlPair(reusing: old.local)
        defer { queue.sync { server.drop(replacement.local) }; close(replacement.peer) }
        expect(replacement.local, old.local, "descriptor really reused")
        queue.sync { server.addClient(replacement.local) }
        replies.first?(["text": "stale"])
        queue.sync {}
        check(controlHasNoBytes(replacement.peer), "stale reply discarded")
        expect(ControlChannel.writeAll(try controlLine(["op": "ask"]), to: replacement.peer), true, "new request sent")
        check(controlWait { replies.count == 2 }, "new reply captured")
        replies.last?(["text": "fresh"])
        let fresh = try controlLine(["text": "fresh"])
        expect(controlRead(replacement.peer, count: fresh.count), fresh)
    }
    test("control: an overflowing subscriber is dropped while a reading subscriber keeps receiving") {
        let queue = DispatchQueue(label: "turnover.test.control.limit")
        let server = ControlServer(queue: queue)
        let slow = try controlPair(), fast = try controlPair()
        defer { queue.sync { server.drop(slow.local); server.drop(fast.local) }; close(slow.peer); close(fast.peer) }
        queue.sync { server.addClient(slow.local); server.addClient(fast.local) }
        var subscriptions = 0
        server.handlers["subscribe"] = { _, _ in subscriptions += 1 }
        for fd in [slow.peer, fast.peer] {
            expect(ControlChannel.writeAll(try controlLine(["op": "subscribe"]), to: fd), true, "subscription sent")
        }
        check(controlWait { subscriptions == 2 }, "both subscribers registered")
        let text = String(repeating: "a", count: 900_000)
        let line = try controlLine(["text": text])
        for _ in 0..<6 {
            server.broadcast(["text": text])
            expect(controlRead(fast.peer, count: line.count), line, "reading subscriber receives a complete line")
        }
        guard controlWait({ fcntl(slow.local, F_GETFD) == -1 }) else { throw POSIXError(.ETIMEDOUT) }
        server.broadcast(["text": "still here"])
        let final = try controlLine(["text": "still here"])
        expect(controlRead(fast.peer, count: final.count), final)
    }
}
