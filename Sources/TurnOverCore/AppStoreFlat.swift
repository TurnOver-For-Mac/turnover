// SPDX-License-Identifier: GPL-3.0-or-later
// The App Store's search results page on the flat view (docs/FLAT-VIEW-PLAN.md, step 3; 27 Oct 2026): the first
// area to leave its hand-made reading behind. Behind the developer switch `flatView`; AppStoreView keeps its keys,
// its waits and the rest of its pages.
import Foundation
import AppKit
import ApplicationServices

final class AppStoreFlatAdapter: FlatAdapter {
    let pid: pid_t
    init(pid: pid_t) { self.pid = pid }
    nonisolated let settleTimes: [Double] = [0.7, 1.5]

    /// The results list: an AXList (subrole AXCollectionList) identified AppStore.search.result in the front window.
    nonisolated func areaRoot() -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        guard let w = app.element(kAXFocusedWindowAttribute) ?? app.elements(kAXWindowsAttribute).first else { return nil }
        return AppStoreView.first(in: w, depth: 6) { $0.role == "AXList" && $0.string(kAXIdentifierAttribute) == "AppStore.search.result" }
    }
    nonisolated func isItem(_ e: AXUIElement) -> Bool { AppStoreView.isItem(e) }
    /// The app's name, as the Store names the tile (the first named thing inside that is not artwork or the offer
    /// button): stable within a results page. A tile with no name is readable, not actable.
    nonisolated func key(for e: AXUIElement, index: Int) -> FlatKey {
        let n = (AppStoreView.identity(of: e).components(separatedBy: ",").first ?? "").trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? .unstable("row \(index + 1)") : .name(n)
    }
    /// The tile's name and its button ("WaterMinder - Water Tracker, Get"): two shallow looks, since a wave over two
    /// hundred rows at the full label's cost (the subtitle, the stars, the price: 36 ms a row) took seven seconds. The
    /// full label is read when the item is spoken (AppStoreView refreshes the offer wording then).
    nonisolated func label(for e: AXUIElement) -> String {
        let name = AppStoreView.identity(of: e)
        let offer = AppStoreView.first(in: e, depth: 4) { ($0.string(kAXIdentifierAttribute) ?? "").contains("offerButton") }
            .flatMap { $0.string(kAXTitleAttribute) ?? $0.string(kAXDescriptionAttribute) } ?? ""
        return offer.isEmpty ? name : "\(name), \(offer)"
    }
    /// The icon's middle, else the tile's left edge (as AppStoreView.clickIcon chooses).
    nonisolated func clickPoint(for e: AXUIElement) -> CGPoint? {
        guard let f = TurnOverObject.frame(e) else { return nil }
        let icon = AppStoreView.first(in: e, depth: 5) { $0.role == "AXImage" && ($0.string(kAXDescriptionAttribute) ?? "Artwork") != "Artwork" }.flatMap { TurnOverObject.frame($0) }
        return icon.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: f.minX + min(20, f.width * 0.1), y: f.midY)
    }
    nonisolated func unsafeHit(_ e: AXUIElement) -> Bool { (e.string(kAXIdentifierAttribute) ?? "").contains("offerButton") || e.role == "AXToolbar" }
}
