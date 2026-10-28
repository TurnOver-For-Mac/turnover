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
        if n.isEmpty { Self.diagnose(e) }
        return n.isEmpty ? nil : n
    }

    /// What the raw calls say when a row answers blank (at most twice a second): a dead handle, no children, or an
    /// error; the measurement the engine's design turns on (27 Oct 2026).
    nonisolated(unsafe) private static var lastDiagnosis = Date.distantPast
    private static let diagLock = NSLock()
    nonisolated static func diagnose(_ e: AXUIElement) {
        diagLock.lock(); let due = Date().timeIntervalSince(lastDiagnosis) > 0.5; if due { lastDiagnosis = Date() }; diagLock.unlock()
        guard due else { return }
        func errName(_ r: AXError) -> String {
            switch r { case .success: return "ok"; case .cannotComplete: return "cannotComplete"; case .noValue: return "noValue"; case .invalidUIElement: return "invalidElement"
                       case .attributeUnsupported: return "unsupported"; default: return "err\(r.rawValue)" }
        }
        var v: AnyObject?
        let rk = AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v)
        let kids = (v as? [AXUIElement]) ?? []
        var vi: AnyObject?
        let ri = AXUIElementCopyAttributeValue(e, kAXIdentifierAttribute as CFString, &vi)
        var childPart = "no child"
        if let c = kids.first {
            var vt: AnyObject?
            let rt = AXUIElementCopyAttributeValue(c, kAXTitleAttribute as CFString, &vt)
            var vd: AnyObject?
            let rd = AXUIElementCopyAttributeValue(c, kAXDescriptionAttribute as CFString, &vd)
            childPart = "child \(c.role): title \(errName(rt)) \(((vt as? String) ?? "").isEmpty ? "empty" : "there"), description \(errName(rd)) \(((vd as? String) ?? "").isEmpty ? "empty" : "there")"
        }
        Log.io("flat view diagnosis: row blank: children \(errName(rk)) \(kids.count), identifier \(errName(ri)) \(((vi as? String) ?? "").isEmpty ? "empty" : "there"); \(childPart)")
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
    nonisolated func unsafeHit(_ e: AXUIElement) -> Bool { (e.string(kAXIdentifierAttribute) ?? "").contains("offerButton") || e.role == "AXToolbar" || e.role == "AXMenuBar" }
    /// The window less its toolbar, which floats over the top of the page (a click there hit the toolbar, 18 Oct).
    nonisolated func screenArea() -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        guard let w = app.element(kAXFocusedWindowAttribute), var area = TurnOverObject.frame(w) else { return nil }
        if let tb = w.elements(kAXChildrenAttribute).first(where: { $0.role == "AXToolbar" }), let tf = TurnOverObject.frame(tb), tf.maxY > area.minY {
            let cut = min(area.height, tf.maxY - area.minY)
            area.origin.y += cut; area.size.height -= cut
        }
        return area
    }
}


/// The results page's own host (docs/FLAT-VIEW-PLAN.md, 27 Oct 2026): the keys, the speech and the waits for a
/// search results page, around the flat screen and nothing of the old page machinery. AppStoreView hands over to it
/// when a results page is up and takes back when the page changes.
final class AppStoreResults {
    let view: FlatScreen
    private(set) var items: [FlatItem] = []
    private(set) var index = 0
    private var spokeFirst = false
    private var extending = false
    private var active = false
    private var generation = 0
    private var navigation = 0
    /// Opens a row at the point the hit test confirmed (AppStoreView clicks there and waits for the page).
    private let openRow: (String, CGPoint) -> Void

    init(pid: pid_t, openRow: @escaping (String, CGPoint) -> Void) {
        self.openRow = openRow
        view = FlatScreen(name: "App Store results", adapter: AppStoreFlatAdapter(pid: pid))
        view.onChange = { [weak self] items in self?.changed(items) }
    }

    func start() { generation += 1; active = true; items = []; index = 0; spokeFirst = false; extending = false; view.begin() }
    func stop() { generation += 1; active = false; items = []; extending = false; view.end() }

    private func changed(_ new: [FlatItem]) {
        guard active else { return }
        items = new
        index = min(index, max(0, items.count - 1))
        if !spokeFirst, !items.isEmpty { spokeFirst = true; speak(index) }
    }

    private func speak(_ i: Int) {
        guard active, items.indices.contains(i) else { return }
        Speech.speakItem(items[i].label)
        Hints.schedule("Return opens the app's page. Up and Down move; Escape goes back.")
    }

    private func newNavigation() -> Int {
        navigation += 1
        extending = false
        view.cancelResolution()
        return navigation
    }

    func move(_ d: Int) {
        guard active else { return }
        guard !items.isEmpty else { Speech.speakMessage("still reading the results; a moment"); return }
        let j = index + d
        if items.indices.contains(j) { _ = newNavigation(); index = j; speak(j); return }
        guard d > 0, !extending else { Tones.edge(); speak(index); return }
        // Past the last tile seen: the next screen, then the first new tile.
        let request = newNavigation()
        extending = true
        let had = items.count, g = generation
        view.extend { [weak self] count in
            guard let self, active, generation == g, navigation == request else { return }
            extending = false
            if count > had { index = had; speak(index) } else { Tones.edge(); speak(index) }
        }
    }
    func toEnd(_ last: Bool) {
        guard active, !items.isEmpty else { return }
        let request = newNavigation()
        if !last { index = 0; speak(0); return }
        sweep(upTo: 40, request: request) { [weak self] in guard let self else { return }; index = items.count - 1; speak(index) }
    }
    func letter(_ ch: Character) {
        guard active, !items.isEmpty else { return }
        let request = newNavigation()
        if let j = next(ch, after: index) { index = j; speak(j); return }
        sweep(upTo: 40, request: request, until: { [weak self] in self?.next(ch, after: self?.index ?? 0) != nil }) { [weak self] in
            guard let self else { return }
            if let j = next(ch, after: index) { index = j; speak(j) } else { Tones.edge() }
        }
    }
    private func next(_ ch: Character, after i: Int) -> Int? {
        guard !items.isEmpty else { return nil }
        for k in 1...items.count { let j = (i + k) % items.count; if items[j].name?.lowercased().first == ch { return j } }
        return nil
    }
    /// Screens scanned one after another until `until` holds, the end, or `upTo` screens.
    private func sweep(upTo: Int, request: Int, until: @escaping () -> Bool = { false }, then: @escaping () -> Void) {
        guard active, navigation == request else { return }
        guard upTo > 0, !until() else { then(); return }
        let had = items.count, g = generation
        view.extend { [weak self] count in
            guard let self, active, generation == g, navigation == request else { return }
            if count == had { then() } else { sweep(upTo: upTo - 1, request: request, until: until, then: then) }
        }
    }
    func open() {
        guard active else { return }
        guard items.indices.contains(index), let name = items[index].name else { Speech.speakMessage("nothing to open yet"); return }
        let g = generation, request = newNavigation()
        view.resolve(items[index]) { [weak self] point in
            guard let self, active, generation == g, navigation == request else { return }
            guard let point else { Speech.speakMessage("Not opened: the row isn't on screen now."); return }
            openRow(name, point)
        }
    }
}
