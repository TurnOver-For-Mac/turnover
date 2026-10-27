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
        AXUIElementSetMessagingTimeout(app, 0.3)   // never the system's six seconds while the Store is busy
        guard let w = app.element(kAXFocusedWindowAttribute) ?? app.elements(kAXWindowsAttribute).first else { return nil }
        AXUIElementSetMessagingTimeout(w, 0.3)
        return AppStoreView.first(in: w, depth: 6) { AXUIElementSetMessagingTimeout($0, 0.3); return $0.role == "AXList" && $0.string(kAXIdentifierAttribute) == "AppStore.search.result" }
    }
    nonisolated func isItem(_ e: AXUIElement) -> Bool { AppStoreView.isItem(e) }
    /// The app's name as the Store names the tile (the first named thing inside that is not artwork or the offer
    /// button); nil while the Store answers blank.
    nonisolated func name(for e: AXUIElement) -> String? {
        let n = (AppStoreView.identity(of: e).components(separatedBy: ",").first ?? "").trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? nil : n
    }
    /// The tile's title as the Store gives it (name, subtitle, stars) and its button.
    nonisolated func label(for e: AXUIElement, name: String) -> String {
        let full = AppStoreView.identity(of: e)
        let offer = AppStoreView.first(in: e, depth: 4) { ($0.string(kAXIdentifierAttribute) ?? "").contains("offerButton") }
            .flatMap { $0.string(kAXTitleAttribute) ?? $0.string(kAXDescriptionAttribute) } ?? ""
        let base = full.isEmpty ? name : full
        // (The Store's own title already ends with the button's wording on some rows: not twice.)
        return offer.isEmpty || base.hasSuffix(offer) || base.contains(", \(offer),") ? base : "\(base), \(offer)"
    }
    /// The icon's middle, else the tile's left edge (as AppStoreView.clickIcon chooses).
    nonisolated func clickPoint(for e: AXUIElement) -> CGPoint? {
        guard let f = TurnOverObject.frame(e) else { return nil }
        let icon = AppStoreView.first(in: e, depth: 5) { $0.role == "AXImage" && ($0.string(kAXDescriptionAttribute) ?? "Artwork") != "Artwork" }.flatMap { TurnOverObject.frame($0) }
        return icon.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: f.minX + min(20, f.width * 0.1), y: f.midY)
    }
    nonisolated func unsafeHit(_ e: AXUIElement) -> Bool { (e.string(kAXIdentifierAttribute) ?? "").contains("offerButton") || e.role == "AXToolbar" }
}
