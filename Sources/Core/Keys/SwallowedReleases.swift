// SPDX-License-Identifier: GPL-3.0-or-later
// The keys whose press TurnOver took and whose release it will swallow to match (KeyboardHandler's `quarantined`).
// A release hidden by secure input left its entry behind, and the next release of that key, after a press the app did
// see, would be swallowed: the app would think the key still held (read from the code, 18 Nov 2026; not seen live).
import Foundation

nonisolated public enum SwallowedReleases {
    /// A press of `code`: if its release is still awaited from an earlier press, drop that entry and say so. A key's
    /// own repeats are not a new press. Physical keys cannot be pressed twice without a release between.
    public static func dropsStale(_ awaited: inout Set<Int64>, code: Int64, isRepeat: Bool) -> Bool {
        guard !isRepeat else { return false }
        return awaited.remove(code) != nil
    }
}
