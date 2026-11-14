// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// 14 Nov 2026: helper stdout is a stream, not one reply per read. No requested
// state is accepted as evidence; missing, stale or mismatched status fails closed.
public struct VoiceOverMuteConfirmation {
    private var buffer = Data()
    private var request: String?
    public mutating func expect(_ token: String) { request = token; status = nil }
    private var status: (pid: Int32, silent: Bool, time: Double)?
    public init() {}
    public mutating func reset() { buffer.removeAll(); status = nil; request = nil }
    public mutating func consume(_ data: Data, now: Double) -> [String] {
        buffer.append(data)
        guard buffer.count <= 4096 else { reset(); return [] }
        var lines: [String] = []
        while let end = buffer.firstIndex(of: 10) {
            let line = String(decoding: buffer[..<end], as: UTF8.self)
            buffer.removeSubrange(...end)
            lines.append(line)
            let fields = line.split(separator: " ")
            if fields.count == 4,
               let request,
               fields[3] == request,
               fields[0] == "status",
               let pid = Int32(fields[1]),
               fields[2] == "on" || fields[2] == "off" {
                status = (pid, fields[2] == "on", now)
            } else if line == "off" || line.hasPrefix("error") { status = nil }
        }
        return lines
    }
    public func value(pid: Int32, wanted: Bool, now: Double) -> Bool? {
        guard let status, status.pid == pid, status.silent == wanted,
              now >= status.time, now - status.time <= 0.75 else { return nil }
        return status.silent
    }
}
