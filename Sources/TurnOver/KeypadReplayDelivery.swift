// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreGraphics
import TurnOverCore

extension KeypadApplicationDelivery {
    // Retained events belong to state.lock. The posting worker receives private copies only.
    nonisolated enum OutputBatch {
        case sleeping([SleepInsertRouter.Replay])
        case single(CGEvent, Int32?)
        case discard([SleepInsertRouter.Replay])
    }
    nonisolated struct Output {
        let event: CGEvent
        let pid: Int32?
    }
    // Reference nodes avoid copying the accumulated backlog on each callback append.
    // Their mutable links, cursors and events are accessed only under state.lock.
    nonisolated final class OutputNode {
        let batch: OutputBatch
        var next: OutputNode?
        init(_ batch: consuming OutputBatch) { self.batch = batch }
    }
    nonisolated final class OutputQueue {
        var head: OutputNode?
        var tail: OutputNode?
        var run = 0
        var repetition = 0
        var active = false
    }
    nonisolated static var hasPendingOutput: Bool {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.unsafeValue.output.active
    }
    nonisolated static let outputBatchLimit = 32
    private nonisolated static let postingQueue = DispatchQueue(label: "turnover.keypad-output")

    /// The caller consumes its result before unlocking. Large discarded wake buffers then have
    /// no callback-owned reference; their final destruction happens on the posting worker.
    nonisolated static func consumeResult(_ result: consuming SleepInsertRouter.Result) {
        replay(result.replay)
        if !result.discarded.isEmpty { enqueue(.discard(result.discarded)) }
    }

    nonisolated static func consumeRetirement(_ retirement: consuming SleepInsertRouter.Retirement) {
        state.unsafeValue.retired.formUnion(retirement.releasedCodes)
        replay(retirement.replay)
    }

    /// Called under state.lock. Small deliveries retain the existing synchronous path.
    nonisolated static func replay(_ events: consuming [SleepInsertRouter.Replay]) {
        guard !events.isEmpty else { return }
        var count = 0
        for index in events.indices {
            count += events[index].count
            if count > outputBatchLimit { break }
        }
        if !state.unsafeValue.output.active,
           count <= outputBatchLimit {
            for item in events {
                item.event.setIntegerValueField(.eventSourceUserData, value: KeyboardHandler.marker)
                for _ in 0..<item.count { item.event.postToPid(item.pid) }
            }
            return
        }
        enqueue(.sleeping(events))
    }

    /// Called under state.lock. Every explicit destination joins preceding replay output.
    nonisolated static func postOrQueue(_ event: CGEvent, pid: Int32) {
        if state.unsafeValue.output.active {
            enqueue(.single(event, pid))
        } else {
            event.setIntegerValueField(.eventSourceUserData, value: KeyboardHandler.marker)
            event.postToPid(pid)
        }
    }

    /// Preserve normal system delivery (including Command Tab), rather than inventing an app PID.
    nonisolated static func deferSession(_ event: CGEvent) -> Bool {
        state.lock.lock()
        defer { state.lock.unlock() }
        guard state.unsafeValue.output.active else { return false }
        enqueue(.single(event, nil))
        return true
    }

    nonisolated static func enqueueSessionLocked(_ event: CGEvent) {
        enqueue(.single(event, nil))
    }

    /// Called under state.lock. A batch retains the existing run array without expanding repeats.
    private nonisolated static func enqueue(_ batch: consuming OutputBatch) {
        let node = OutputNode(batch)
        if let tail = state.unsafeValue.output.tail { tail.next = node }
        else { state.unsafeValue.output.head = node }
        state.unsafeValue.output.tail = node
        guard !state.unsafeValue.output.active else { return }
        state.unsafeValue.output.active = true
        scheduleDrain()
    }

    private nonisolated static func scheduleDrain() {
        postingQueue.async { drainOutputBatch() }
    }

    /// At most 32 private event copies leave the lock. The gate remains active while they post.
    private nonisolated static func reserveOutputBatch() -> ([Output], [OutputNode]) {
        state.lock.lock()
        defer { state.lock.unlock() }
        var result: [Output] = []
        var retired: [OutputNode] = []
        var reserved = 0
        while reserved < outputBatchLimit,
              let node = state.unsafeValue.output.head {
            reserved += 1
            var finished = false
            let event: CGEvent
            let pid: Int32?
            switch node.batch {
            case .discard:
                state.unsafeValue.output.head = node.next
                if node.next == nil { state.unsafeValue.output.tail = nil }
                retired.append(node)
                continue
            case .single(let single, let destination):
                event = single
                pid = destination
                finished = true
            case .sleeping(let runs):
                let run = state.unsafeValue.output.run
                let item = runs[run]
                event = item.event
                pid = item.pid
                state.unsafeValue.output.repetition += 1
                if state.unsafeValue.output.repetition == item.count {
                    state.unsafeValue.output.repetition = 0
                    state.unsafeValue.output.run += 1
                }
                if state.unsafeValue.output.run == runs.count {
                    state.unsafeValue.output.run = 0
                    finished = true
                }
            }
            if finished {
                state.unsafeValue.output.head = node.next
                if node.next == nil { state.unsafeValue.output.tail = nil }
                retired.append(node)
            }
            // No other thread may mutate the posted copy while the delivery lock is released.
            guard let copy = event.copy() else { continue }
            copy.setIntegerValueField(.eventSourceUserData, value: KeyboardHandler.marker)
            result.append(Output(event: copy, pid: pid))
        }
        return (result, retired)
    }

    private nonisolated static func drainOutputBatch() {
        let (batch, retired) = reserveOutputBatch()
        withExtendedLifetime(retired) {
            for output in batch {
                if let pid = output.pid { output.event.postToPid(pid) }
                else { output.event.post(tap: .cghidEventTap) }
            }
        }
        state.lock.lock()
        let more = state.unsafeValue.output.head != nil
        if !more { state.unsafeValue.output = OutputQueue() }
        let scheduleMore = more && !state.unsafeValue.closing
        state.lock.unlock()
        if scheduleMore { scheduleDrain() }
    }
    /// Called only at process exit, after reader stop requests. No new down may acquire ownership.
    /// Unlike a tap callback, graceful shutdown waits for all already accepted output.
    nonisolated static func finishForExit() {
        state.lock.lock()
        state.unsafeValue.closing = true
        for release in state.unsafeValue.streams.finishAll() {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(release.code), keyDown: false) else { continue }
            event.flags = release.flags
            state.unsafeValue.retired.insert(release.physicalCode)
            postOrQueue(event, pid: release.pid)
        }
        while let owner = state.unsafeValue.sleeping.keys.first,
              var router = state.unsafeValue.sleeping.removeValue(forKey: owner) {
            let retirement = router.finish()
            consumeRetirement(consume retirement)
        }
        state.lock.unlock()
        postingQueue.sync {
            while hasPendingOutput { drainOutputBatch() }
        }
    }

}
