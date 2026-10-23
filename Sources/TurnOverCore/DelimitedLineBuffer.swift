// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Accumulates UTF-8, newline-delimited responses whose reads may split or combine lines.
nonisolated public struct DelimitedLineBuffer: Sendable {
    private var data = Data()

    public init() {}

    /// Appends a byte chunk and returns every complete, trimmed line in it.
    public mutating func append(_ chunk: Data) -> [String] {
        data.append(chunk)
        var lines: [String] = []
        while let newline = data.firstIndex(of: 0x0A) {
            let line = data[..<newline]
            lines.append(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            data.removeSubrange(...newline)
        }
        return lines
    }
}
