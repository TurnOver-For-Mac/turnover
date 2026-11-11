// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics

/// Sleep's potential Insert chords are delayed until they become a wake command or ordinary input.
/// This value and its CGEvents belong to the primary keyboard worker, including retirement.
nonisolated public struct SleepInsertRouter {
    public struct Replay {
        public let event: CGEvent
        public let pid: Int32
        /// Consecutive identical Insert repeats share one retained event, rather than a copy per repeat.
        public var count: Int = 1
    }
    public enum Disposition: Equatable { case pass, consume, wake }
    public struct Result {
        public let disposition: Disposition
        public let replay: [Replay]
    }
    public struct Retirement {
        public let replay: [Replay]
        public let releasedCodes: Set<Int64>
    }
    private var pending: [Replay] = []
    private var forwarded: [Int64: Replay] = [:]
    private var wakeReleases: Set<Int64> = []
    public init() {}
    /// Published to overlapping readers so only this worker resolves its delayed/forwarded streams.
    public var ownedCodes: Set<Int64> {
        Set(pending.map { $0.event.getIntegerValueField(.keyboardEventKeycode) }).union(forwarded.keys).union(wakeReleases)
    }

    /// Recovery/direct routing ends chord recognition, but keeps each app's outstanding release owner.
    public mutating func retire() -> [Replay] {
        let replay = pending
        pending.removeAll()
        for item in replay { forwarded[item.event.getIntegerValueField(.keyboardEventKeycode)] = item }
        return replay
    }

    /// A stopped worker cannot wait for physical releases. Complete every delivered down at its PID,
    /// and let the adapters swallow the later physical repeats/ups across reader handover.
    public mutating func finish() -> Retirement {
        var replay = retire()
        let codes = Set(forwarded.keys).union(wakeReleases)
        for code in forwarded.keys.sorted() {
            guard let item = forwarded[code], let up = item.event.copy() else { continue }
            up.type = .keyUp
            up.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
            replay.append(Replay(event: up, pid: item.pid))
        }
        forwarded.removeAll(); wakeReleases.removeAll()
        return Retirement(replay: replay, releasedCodes: codes)
    }

    public mutating func route(_ type: CGEventType, event: CGEvent, asleep: Bool,
                               enabled: Bool, keypadEnabled: Bool, pid: Int32) -> Result {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp, wakeReleases.remove(code) != nil { return Result(disposition: .consume, replay: []) }
        if type == .keyDown, wakeReleases.contains(code) { return Result(disposition: .consume, replay: []) }
        guard type == .keyDown || type == .keyUp else { return Result(disposition: .pass, replay: []) }
        if let owner = forwarded[code], let copy = event.copy() {
            if type == .keyUp { forwarded.removeValue(forKey: code) }
            return Result(disposition: .consume, replay: [Replay(event: copy, pid: owner.pid)])
        }
        let validPending = pending.allSatisfy {
            $0.pid == pid && (keypadEnabled || $0.event.getIntegerValueField(.keyboardEventKeycode) != 82)
        }
        guard asleep, enabled, pid > 0, validPending else { return flush(type, event: event, pid: pid) }
        let isInsert = code == 114 || (code == 82 && keypadEnabled)
        let repeatKey = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let alreadyPending = pending.contains { $0.event.getIntegerValueField(.keyboardEventKeycode) == code }
        if type == .keyDown, isInsert, (!repeatKey && !alreadyPending) || (repeatKey && alreadyPending), let copy = event.copy() {
            if repeatKey, let last = pending.last, last.event.getIntegerValueField(.keyboardEventKeycode) == code,
               last.event.getIntegerValueField(.keyboardEventAutorepeat) != 0, last.event.flags == event.flags {
                pending[pending.count - 1].count += 1
            } else { pending.append(Replay(event: copy, pid: pid)) }
            return Result(disposition: .consume, replay: [])
        }
        guard !pending.isEmpty else { return Result(disposition: .pass, replay: []) }
        let mods = event.flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand])
        if type == .keyDown, code == 6, mods == .maskShift, !repeatKey {
            wakeReleases.formUnion(pending.map { $0.event.getIntegerValueField(.keyboardEventKeycode) })
            wakeReleases.insert(code)
            pending.removeAll()
            return Result(disposition: .wake, replay: [])
        }
        return flush(type, event: event, pid: pid)
    }

    private mutating func flush(_ type: CGEventType, event: CGEvent, pid: Int32) -> Result {
        guard !pending.isEmpty else { return Result(disposition: .pass, replay: []) }
        var replay = retire()
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let destination = forwarded[code]?.pid ?? (replay.first?.pid == pid ? pid : nil)
        if let destination, let copy = event.copy() {
            if type == .keyUp { forwarded.removeValue(forKey: code) }
            else { forwarded[code] = Replay(event: copy, pid: destination) }
            replay.append(Replay(event: copy, pid: destination))
            return Result(disposition: .consume, replay: replay)
        }
        return Result(disposition: .pass, replay: replay)
    }
}
