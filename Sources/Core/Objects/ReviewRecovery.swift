// SPDX-License-Identifier: GPL-3.0-or-later
// The review cursor's item went away under it (25 Nov 2026). Apps re-create elements as they change: the App Store
// builds a new "22% loaded" button each time a download's progress moves, so the cursor was left holding an element
// with no window and no parent, and every VO-Left and VO-Right after it said "nothing to review" until the focus moved.
// Nothing here is about one app: any element that is destroyed or cut loose from its window is found again.
//
// What the cursor was on is remembered as plain facts (role, name, frame) when it lands, so the same item can be found
// again among what is there now. This file holds the matching, which needs no accessibility and is tested on its own.
import Foundation
import CoreGraphics

/// What the review cursor was on, kept as facts that outlive the element.
package struct ReviewMark: Equatable {
    package var role: String
    package var name: String
    package var frame: CGRect?
    package init(role: String, name: String, frame: CGRect?) { self.role = role; self.name = name; self.frame = frame }
}

package enum ReviewRecovery {
    /// How far, in points, the item's top left corner may be from where it was and still be the same item.
    nonisolated package static let nearPoints: CGFloat = 4

    /// Which of `candidates` is the item `mark` described, or nil when none can be told apart with confidence.
    /// The role must match. Then the place decides: an item of the same role where the old one was is the same item
    /// even when its name changed ("22% loaded" became "22.1% loaded"). Without a place, a name alone is trusted only
    /// when exactly one candidate has it, so one of several "Update" buttons is never guessed.
    nonisolated package static func match(_ mark: ReviewMark, among candidates: [ReviewMark]) -> Int? {
        var best: (index: Int, distance: CGFloat, sameName: Bool)?
        for (i, c) in candidates.enumerated() where c.role == mark.role {
            guard let a = mark.frame, let b = c.frame else { continue }
            let d = hypot(a.minX - b.minX, a.minY - b.minY)
            guard d <= nearPoints else { continue }
            let sameName = !mark.name.isEmpty && c.name == mark.name
            if let cur = best, (cur.sameName && !sameName) || (cur.sameName == sameName && cur.distance <= d) { continue }
            best = (i, d, sameName)
        }
        if let best { return best.index }
        guard !mark.name.isEmpty else { return nil }
        let named = candidates.indices.filter { candidates[$0].role == mark.role && candidates[$0].name == mark.name }
        return named.count == 1 ? named[0] : nil
    }
}
